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

import 'in_app.dart';

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

/// One line of the setup test's answer. [level] is "pass", "warn" or "fail".
class SetupCheck {
  SetupCheck({
    required this.id,
    required this.level,
    required this.title,
    this.detail,
  });

  final String id;
  final String level;
  final String title;

  /// What to do about it. Null for a pass.
  final String? detail;
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

  // Keep in step with pubspec.yaml — this is what our telemetry sees.
  static const String version = '0.7.5';
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
    // Which push service actually holds this token. Sent only when the
    // caller knows, because on iOS the platform does not decide it: a
    // Firebase build holds an FCM token and must be relayed by Google,
    // a native one holds an APNs token and goes straight to Apple.
    String? channel,
    // The device this install was using until now. A device row is keyed
    // on its token, so a changed token is a new row — and without this the
    // old one stays active and targeted for a token the device no longer
    // has.
    String? replaces,
  }) async {
    final res = await _request('POST', '/v1/devices', {
      'platform': platform,
      'token': token,
      if (locale != null) 'locale': locale,
      if (timezone != null) 'timezone': timezone,
      if (channel != null) 'channel': channel,
      if (replaces != null) 'replaces': replaces,
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

  /// POST /v1/setup-test — hand the server what this device can see of the
  /// integration, and get back what the server can see of it.
  ///
  /// Almost everything that goes wrong during an integration is invisible
  /// from inside the app: credentials that were never uploaded, an APNs key
  /// minted for a different bundle, a key belonging to another app.
  Future<List<SetupCheck>> setupTest(Map<String, dynamic> report) async {
    final res = await _request('POST', '/v1/setup-test', report);
    final checks = res['checks'];
    if (checks is! List) return [];
    return checks
        .whereType<Map<String, dynamic>>()
        .map((c) => SetupCheck(
              id: c['id'] as String? ?? '',
              level: c['level'] as String? ?? 'warn',
              title: c['title'] as String? ?? '',
              detail: c['detail'] as String?,
            ))
        .where((c) => c.id.isNotEmpty)
        .toList();
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

  /// GET /v1/in-app — the rules this device may act on.
  ///
  /// Already filtered server-side to live, in-window and in-segment, so a
  /// caller that shows everything it is given is still correct. What it does
  /// NOT contain is the segment: an audience definition must not be readable
  /// with a key that ships inside an app.
  Future<List<InAppRule>> inAppRules(String deviceId) async {
    final res = await _request(
        'GET', '/v1/in-app?device_id=${Uri.encodeQueryComponent(deviceId)}', null);
    final items = res['messages'];
    if (items is! List) return [];
    final out = <InAppRule>[];
    for (final raw in items) {
      final rule = InAppParse.rule(raw);
      if (rule != null) out.add(rule);
    }
    return out;
  }

  /// POST /v1/in-app/event — what the device did with one.
  ///
  /// [tag] is the KEY of a tag_user button that was pressed, and only the
  /// key: the value is the campaign's, so this cannot be used to write an
  /// arbitrary attribute onto a person.
  Future<void> inAppEvent(String deviceId, String id, String event,
      {String? tag}) async {
    await _request('POST', '/v1/in-app/event', {
      'device_id': deviceId,
      'id': id,
      'event': event,
      if (tag != null) 'tag': tag,
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
    // Its own client, with its own connect timeout. `postUrl` is where DNS
    // and the TCP handshake happen, and this client had none — so against a
    // blackholed host that first await pended for the OS default, minutes,
    // and the five-second timeout on `close()` below was never reached.
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 5);
    try {
      final req = await client
          .postUrl(Uri.parse('$origin/v1/push/click'))
          .timeout(const Duration(seconds: 5));
      req.headers.contentType = ContentType.json;
      req.headers.set('user-agent', 'notibase-flutter/$version');
      req.add(utf8.encode(jsonEncode({'m': messageId, 'd': deviceId})));
      final res = await req.close().timeout(const Duration(seconds: 5));
      await res.drain<void>().timeout(const Duration(seconds: 5));
    } catch (_) {/* beacon only */} finally {
      // In a `finally`, because closing only on the success path leaked a
      // client and its socket on every failed beacon — which is every
      // beacon, during the outage this is meant to survive.
      client.close(force: true);
    }
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
    // The body read needs its own timeout and its own catch. It had
    // neither: a server that returns headers and then stalls the body — a
    // proxy dying mid-response, a half-written 502 — hung here forever, and
    // anything it did raise came out as a bare SocketException rather than
    // a NotibaseException, so `_request` did not recognise it as retryable
    // and gave up on the first attempt.
    final String text;
    try {
      text = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 15));
    } catch (e) {
      throw NotibaseException(0, 'network: reading the response failed: $e');
    }
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
