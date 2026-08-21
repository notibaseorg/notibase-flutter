/// Notibase Flutter SDK — public entry point.
///
/// Design rules (Arch §8.2), identical to the Android/iOS SDKs:
///  - ONE dependency (shared_preferences, for device-id persistence).
///    No native code: your app obtains its push token with
///    firebase_messaging and hands it to [registerPushToken].
///  - Never crash the host app: public calls are fire-and-forget with an
///    optional result; failures are logged via debugPrint, not thrown.
///  - The client key is public by design (ck_…); anything sensitive
///    (identify signatures) is minted by the app's own backend.
///
/// Quickstart:
///   await Notibase.configure('ck_live_…');
///   FirebaseMessaging.instance.onTokenRefresh.listen(Notibase.registerPushToken);
///   final token = await FirebaseMessaging.instance.getToken();
///   if (token != null) await Notibase.registerPushToken(token);
///   await Notibase.identify('user-42', signature: sigFromYourBackend);
///   await Notibase.track('level_complete', properties: {'level': 3});
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';

class Notibase {
  Notibase._();

  static const _deviceIdKey = 'nb_device_id';
  static const _tokenKey = 'nb_push_token';

  static NotibaseApi? _api;
  static SharedPreferences? _prefs;

  /// Initialize once, e.g. in main(). Safe to call again (no-op).
  /// Re-registers a token cached from a previous launch automatically.
  static Future<void> configure(String clientKey,
      {String apiUrl = 'https://api.notibase.com'}) async {
    if (_api != null) return;
    _api = NotibaseApi(clientKey, apiUrl: apiUrl); // throws LOUDLY on sk_ keys
    _prefs = await SharedPreferences.getInstance();
    final cached = _prefs!.getString(_tokenKey);
    if (cached != null) {
      await registerPushToken(cached);
    }
  }

  /// Register the push token from firebase_messaging (FCM token on
  /// Android, APNs-backed FCM token on iOS). Wire onTokenRefresh here too.
  static Future<void> registerPushToken(String token) async {
    final api = _api;
    final prefs = _prefs;
    if (api == null || prefs == null) return _warnNotConfigured();
    await prefs.setString(_tokenKey, token);
    final platform = kIsWeb
        ? 'web'
        : Platform.isIOS
            ? 'ios'
            : 'android';
    try {
      final deviceId = await api.registerDevice(
        token: token,
        platform: platform,
        locale: Platform.localeName,
        timezone: DateTime.now().timeZoneName,
        // firebase_messaging tokens are ALWAYS FCM tokens — on iOS, FCM
        // relays to APNs using the APNs key you uploaded to Firebase. The
        // platform stays 'ios' for segmentation; delivery goes via fcm.
        channel: kIsWeb ? null : 'fcm',
      );
      await prefs.setString(_deviceIdKey, deviceId);
      debugPrint('[Notibase] device registered: $deviceId');
    } catch (e) {
      debugPrint(
          '[Notibase] device registration failed (will retry on next token refresh): $e');
    }
  }

  /// Link this device to your user. When identity verification is enabled
  /// (recommended), pass the HMAC [signature] your backend minted.
  /// Returns true on success.
  static Future<bool> identify(String externalId,
      {String? signature, Map<String, dynamic> attributes = const {}}) async {
    final api = _api;
    if (api == null) {
      _warnNotConfigured();
      return false;
    }
    try {
      await api.identify(
        externalId: externalId,
        deviceId: _prefs?.getString(_deviceIdKey),
        signature: signature,
        attributes: attributes,
      );
      return true;
    } catch (e) {
      debugPrint('[Notibase] identify failed: $e');
      return false;
    }
  }

  /// Track a custom event (feeds segments + attribution, Arch §7.3).
  static Future<void> track(String name,
      {Map<String, dynamic> properties = const {}}) async {
    final api = _api;
    if (api == null) return _warnNotConfigured();
    try {
      await api.track(name,
          properties: properties, deviceId: _prefs?.getString(_deviceIdKey));
    } catch (e) {
      debugPrint('[Notibase] track($name) failed: $e');
    }
  }

  /// Fetch the in-app inbox for the identified user behind this device.
  /// Returns null when unavailable (not configured / not registered / error).
  static Future<List<InboxItem>?> inbox({int limit = 50}) async {
    final api = _api;
    final deviceId = _prefs?.getString(_deviceIdKey);
    if (api == null || deviceId == null) return null;
    try {
      return await api.inboxList(deviceId, limit: limit);
    } catch (e) {
      debugPrint('[Notibase] inbox fetch failed: $e');
      return null;
    }
  }

  /// Mark inbox items read.
  static Future<void> inboxMarkRead(List<String> ids) async {
    final api = _api;
    final deviceId = _prefs?.getString(_deviceIdKey);
    if (api == null || deviceId == null) return;
    try {
      await api.inboxMarkRead(deviceId, ids);
    } catch (e) {
      debugPrint('[Notibase] markRead failed: $e');
    }
  }

  /// The stored Notibase device id, once registration has succeeded.
  /// Record a notification open. Wire it to firebase_messaging:
  ///
  ///   FirebaseMessaging.onMessageOpenedApp.listen(
  ///       (m) => Notibase.trackNotificationOpen(m.data));
  ///   final initial = await FirebaseMessaging.instance.getInitialMessage();
  ///   if (initial != null) Notibase.trackNotificationOpen(initial.data);
  ///
  /// The nb_m / nb_d / nb_o keys are placed in the data payload by the
  /// Notibase send pipeline; foreign notifications are ignored safely.
  static Future<void> trackNotificationOpen(Map<String, dynamic> data) async {
    final m = data['nb_m'], d = data['nb_d'], o = data['nb_o'];
    if (m is! String || d is! String || o is! String) return;
    await NotibaseApi.postClick(o, m, d);
  }

  static String? get deviceId => _prefs?.getString(_deviceIdKey);

  static void _warnNotConfigured() {
    debugPrint('[Notibase] Notibase.configure(clientKey) has not been called');
  }
}
