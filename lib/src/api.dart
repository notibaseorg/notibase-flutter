/// NotibaseApi — pure-Dart HTTP core (dart:io + dart:convert, no packages).
///
/// This file has no Flutter imports, so the exact shipped code is exercised
/// by `flutter test` on the Dart VM: unit tests against an in-process mock
/// server, and a full e2e against the real Notibase API in CI (mirrors the
/// Android/iOS SDK harnesses).
///
/// Security model (Arch §5.3): carries a ck_ ("client") key — public by
/// design. It can register devices, identify with an HMAC signature minted
/// by YOUR backend, track events, and read this device's inbox. Server
/// keys (sk_) are refused at construction so nobody ships one in an app.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

class NotibaseException implements Exception {
  NotibaseException(this.statusCode, this.message);

  /// HTTP status, or 0 for network/parse failures.
  final int statusCode;
  final String message;

  @override
  String toString() => 'NotibaseException($statusCode): $message';
}

class InboxItem {
  InboxItem({
    required this.id,
    required this.content,
    required this.createdAt,
    this.readAt,
  });

  final String id;
  final Map<String, dynamic> content;
  final String createdAt;
  final String? readAt;
}

class NotibaseApi {
  NotibaseApi(String clientKey, {this.apiUrl = 'https://api.notibase.com'})
      : _key = clientKey {
    if (clientKey.startsWith('sk_')) {
      throw ArgumentError(
          'You passed a SERVER key (sk_…) to the Flutter SDK. Server keys '
          'grant full account access and must never ship inside an app — use '
          'your client key (ck_…) from the Notibase dashboard instead.');
    }
    if (!clientKey.startsWith('ck_')) {
      throw ArgumentError('Notibase client keys start with ck_');
    }
  }

  static const String version = '0.2.0';
  static const int _maxRetries = 2;

  final String _key;
  final String apiUrl;
  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10);
  final Random _random = Random();

  /// POST /v1/devices → device id. Idempotent server-side per (app, token).
  Future<String> registerDevice({
    required String token,
    required String platform, // 'ios' | 'android' | 'web'
    String? locale,
    String? timezone,
    String? channel, // delivery-channel override (Flutter iOS → 'fcm')
  }) async {
    final res = await _request('POST', '/v1/devices', {
      'platform': platform,
      'token': token,
      if (locale != null) 'locale': locale,
      if (timezone != null) 'timezone': timezone,
      if (channel != null) 'channel': channel,
    });
    final id = res['id'];
    if (id is! String) throw NotibaseException(0, 'no device id in response');
    return id;
  }

  /// POST /v1/identify → user id. [signature] = hex(hmac_sha256(
  /// identify_secret, externalId)) — minted by YOUR backend, never in-app.
  Future<String> identify({
    required String externalId,
    String? deviceId,
    String? signature,
    Map<String, dynamic> attributes = const {},
  }) async {
    final res = await _request('POST', '/v1/identify', {
      'external_id': externalId,
      'attributes': attributes,
      if (deviceId != null) 'device_id': deviceId,
      if (signature != null) 'signature': signature,
    });
    final id = res['id'];
    if (id is! String) throw NotibaseException(0, 'no user id in response');
    return id;
  }

  /// POST /v1/events. Reserved names (install, session_start, purchase)
  /// feed attribution (Arch §7.3).
  Future<void> track(
    String name, {
    Map<String, dynamic> properties = const {},
    String? deviceId,
  }) async {
    await _request('POST', '/v1/events', {
      'name': name,
      'properties': properties,
      if (deviceId != null) 'device_id': deviceId,
    });
  }

  /// GET /v1/inbox — messages for the identified user behind this device.
  Future<List<InboxItem>> inboxList(String deviceId, {int limit = 50}) async {
    final res = await _request(
        'GET', '/v1/inbox?device_id=$deviceId&limit=$limit', null);
    final items = res['items'];
    if (items is! List) return [];
    return items.whereType<Map<String, dynamic>>().map((m) {
      return InboxItem(
        id: m['id'] as String? ?? '',
        content: (m['content'] as Map?)?.cast<String, dynamic>() ?? {},
        createdAt: m['created_at'] as String? ?? '',
        readAt: m['read_at'] as String?,
      );
    }).where((i) => i.id.isNotEmpty).toList();
  }

  /// POST /v1/inbox/read — mark items read.
  Future<void> inboxMarkRead(String deviceId, List<String> ids) async {
    if (ids.isEmpty) return;
    await _request('POST', '/v1/inbox/read', {
      'device_id': deviceId,
      'ids': ids,
    });
  }

  // ── plumbing ────────────────────────────────────────────
  Future<Map<String, dynamic>> _request(
      String method, String path, Map<String, dynamic>? body) async {
    NotibaseException? lastError;
    for (var attempt = 0; attempt <= _maxRetries; attempt++) {
      if (attempt > 0) {
        // 500ms, 2s — jittered; never hammer a struggling API.
        final base = 500 * pow(4, attempt - 1).toDouble();
        await Future<void>.delayed(Duration(
            milliseconds: (base + _random.nextDouble() * base * 0.25).round()));
      }
      try {
        return await _requestOnce(method, path, body);
      } on NotibaseException catch (e) {
        // Retry only what retrying can fix: 429, 5xx, network (0).
        if (e.statusCode == 429 || e.statusCode >= 500 || e.statusCode == 0) {
          lastError = e;
        } else {
          rethrow; // 4xx are ours — never retried
        }
      }
    }
    throw lastError ?? NotibaseException(0, 'request failed');
  }

  /// Notification-click beacon — unauthenticated by design (the server only
  /// counts pairs it delivered, once). Never throws: a lost beacon must not
  /// break a notification tap.
  static Future<void> postClick(
      String origin, String messageId, String deviceId) async {
    try {
      final client = HttpClient();
      final req = await client.postUrl(Uri.parse('$origin/v1/push/click'));
      req.headers.contentType = ContentType.json;
      req.headers.set('user-agent', 'notibase-flutter/$version');
      req.add(utf8.encode(jsonEncode({'m': messageId, 'd': deviceId})));
      final res = await req.close().timeout(const Duration(seconds: 5));
      await res.drain<void>();
      client.close();
    } catch (_) {/* beacon only */}
  }

  Future<Map<String, dynamic>> _requestOnce(
      String method, String path, Map<String, dynamic>? body) async {
    HttpClientResponse response;
    try {
      final req = await _client.openUrl(method, Uri.parse('$apiUrl$path'));
      req.headers.set('authorization', 'Bearer $_key');
      req.headers.set('user-agent', 'notibase-flutter/$version');
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.add(utf8.encode(jsonEncode(body)));
      }
      response = await req.close().timeout(const Duration(seconds: 15));
    } catch (e) {
      throw NotibaseException(0, 'network: $e');
    }
    final text = await response.transform(utf8.decoder).join();
    if (response.statusCode >= 400) {
      var message = text.length > 200 ? text.substring(0, 200) : text;
      try {
        final parsed = jsonDecode(text);
        if (parsed is Map && parsed['error'] is String) {
          message = parsed['error'] as String;
        }
      } catch (_) {/* keep raw */}
      throw NotibaseException(response.statusCode, message);
    }
    try {
      final parsed = jsonDecode(text);
      if (parsed is Map<String, dynamic>) return parsed;
      return {};
    } catch (_) {
      return {};
    }
  }
}
