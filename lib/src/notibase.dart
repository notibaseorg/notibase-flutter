/// Notibase Flutter SDK — public entry point.
///
/// Design rules (Arch §8.2), identical to the Android/iOS SDKs:
///  - ONE dependency (shared_preferences, for device-id persistence).
///    No native code, and firebase_messaging is NOT a dependency of this
///    package: [attachFirebase] takes the objects your app already has and
///    talks to them structurally, so apps that get their token another way
///    pay nothing for the convenience.
///  - Never crash the host app: public calls are fire-and-forget with an
///    optional result; failures are logged via debugPrint, not thrown.
///  - The client key is public by design (ck_…); anything sensitive
///    (identify signatures) is minted by the app's own backend.
///
/// Quickstart:
///   await Notibase.configure('ck_live_…');
///   await Notibase.attachFirebase(
///     FirebaseMessaging.instance,
///     onMessageOpenedApp: FirebaseMessaging.onMessageOpenedApp,
///   );
///   await Notibase.identify('user-42', signature: sigFromYourBackend);
///   await Notibase.track('level_complete', properties: {'level': 3});
///
/// [attachFirebase] replaces the permission request, the token fetch, the
/// refresh listener and both click-tracking paths that every app used to
/// write out by hand. The pieces are still public if you would rather wire
/// them yourself.
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
  static bool _firebaseAttached = false;

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
    // A device known from a previous launch can report its session now; a
    // brand-new install reports as soon as registration lands.
    await _reportLifecycle();
  }

  /// Register a push token yourself. [attachFirebase] calls this for you,
  /// including on every refresh — reach for this directly only when your app
  /// obtains its token some other way.
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
      await _reportLifecycle();
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

  /// Record a purchase, with the revenue it earned.
  ///
  /// `purchase` is one of the three reserved event names, and its `value` is
  /// what the attribution report rolls up per campaign. Written out as a
  /// method because "which property does the money go in" is the sort of thing
  /// that gets guessed wrong once and then produces a revenue column of zeroes
  /// nobody can explain.
  ///
  ///   await Notibase.trackPurchase(9.99, productId: 'pro_monthly');
  static Future<void> trackPurchase(
    double value, {
    String currency = 'USD',
    String? productId,
    Map<String, dynamic> properties = const {},
  }) async {
    await track('purchase', properties: {
      ...properties,
      'value': value,
      'currency': currency,
      if (productId != null) 'product_id': productId,
    });
  }

  // ── attribution (Arch §7.3) ──────────────────────────────────────────

  /// Report `install` once and `session_start` on every cold start, so a
  /// campaign link can be credited with the installs it drove. Two events per
  /// launch at most. Set it before [configure].
  static bool autoTrackSessions = true;

  static const _installKey = 'nb_install_reported';
  static const _pendingClickKey = 'nb_pending_click';
  static bool _sessionReported = false;

  /// Hand Notibase a URL that opened your app — an App Link, a Universal
  /// Link, or your own scheme. If it came from a Notibase campaign link it
  /// carries the click id that makes attribution deterministic rather than a
  /// guess from an IP and a time window.
  ///
  ///   final router = GoRouter(redirect: (_, state) {
  ///     Notibase.handleDeepLink(state.uri.toString());
  ///     return null;
  ///   });
  static Future<void> handleDeepLink(String? url) async {
    final click = clickIdFrom(url);
    if (click == null) return;
    final prefs = _prefs;
    if (prefs == null) return _warnNotConfigured();
    if (prefs.getString(_pendingClickKey) == click) return;
    await prefs.setString(_pendingClickKey, click);
    // Report now rather than next launch: this is the moment the click id
    // exists, and the server's first-touch guard makes a repeat free.
    await _reportLifecycle(force: true);
  }

  /// The `nb_click` a Notibase campaign link put on a URL, or null.
  ///
  /// Only digits are accepted — the value is a bigint primary key on its way
  /// to a parameterised query, and this is the one input a stranger can drive,
  /// since anyone can open the app with any URL they like.
  static String? clickIdFrom(String? url) {
    if (url == null || url.isEmpty) return null;
    Uri parsed;
    try {
      parsed = Uri.parse(url);
    } catch (_) {
      return null;
    }
    final value = parsed.queryParameters['nb_click'];
    if (value == null || value.isEmpty || value.length > 19) return null;
    if (!RegExp(r'^[0-9]+$').hasMatch(value)) return null;
    return value;
  }

  /// Report the install once, and a session on every cold start.
  ///
  /// A no-op until a device id exists, because an event with no device cannot
  /// be attributed to anything — so it runs again once registration lands.
  /// Calling it twice is cheap and calling it too early is silent, which is
  /// the right way round.
  static Future<void> _reportLifecycle({bool force = false}) async {
    if (!autoTrackSessions) return;
    final prefs = _prefs;
    if (prefs == null || _api == null) return;
    if (prefs.getString(_deviceIdKey) == null) return;

    final click = prefs.getString(_pendingClickKey);
    final props = <String, dynamic>{if (click != null) 'nb_click': click};

    if (!(prefs.getBool(_installKey) ?? false)) {
      await prefs.setBool(_installKey, true);
      await track('install', properties: props);
    } else if (force || !_sessionReported) {
      _sessionReported = true;
      await track('session_start', properties: props);
    } else {
      return;
    }
    // A click id belongs to the install it produced; keeping it would
    // re-attach it to every session for the life of the install.
    if (click != null) await prefs.remove(_pendingClickKey);
  }

  // ── setup test ───────────────────────────────────────────────────────

  /// Check the integration and print what is wrong with it.
  ///
  /// Call it once from a debug build. Everything that usually goes wrong is
  /// invisible from inside the app — credentials that were never uploaded, an
  /// APNs key minted for a different bundle, a device that never actually
  /// registered — so this reports what the app can see and prints what the
  /// server makes of it, as a checklist.
  ///
  ///   if (kDebugMode) await Notibase.runSetupTest();
  ///
  /// Returns the checks so you can render them yourself, or fail a test on
  /// them in CI.
  static Future<List<SetupCheck>> runSetupTest() async {
    final api = _api;
    if (api == null) {
      _warnNotConfigured();
      return const [];
    }
    // Pure Dart with no platform channels means there is no bundle id and no
    // notification-permission status to report. The server leaves out the
    // checks it has no input for rather than inventing them — an SDK that
    // cannot tell must not have to guess.
    final report = <String, dynamic>{
      'platform': kIsWeb ? 'web' : (Platform.isIOS ? 'ios' : 'android'),
      'sdk': 'notibase-flutter',
      'sdk_version': NotibaseApi.version,
      'device_id': _prefs?.getString(_deviceIdKey),
      'has_push_token': _prefs?.getString(_tokenKey) != null,
    };
    List<SetupCheck> checks;
    try {
      checks = await api.setupTest(report);
    } catch (e) {
      // The one failure the server cannot report on: it was never reached.
      debugPrint('[Notibase] setup test could not reach ${api.apiUrl} — check the '
          'API URL and this device\'s network: $e');
      return const [];
    }
    debugPrint('[Notibase] ── setup test ──');
    for (final c in checks) {
      final mark = c.level == 'pass' ? '\u2714' : (c.level == 'warn' ? '!' : '\u2718');
      debugPrint('[Notibase] $mark ${c.title}');
      if (c.detail != null) debugPrint('[Notibase]     ${c.detail}');
    }
    if (!checks.any((c) => c.level == 'fail')) {
      debugPrint('[Notibase] ── nothing blocking ──');
    }
    return checks;
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

  /// Wire an existing [FirebaseMessaging] instance up to Notibase in one call.
  ///
  /// This does everything the quickstart used to ask you to write by hand:
  /// requests notification permission, registers the current token, keeps
  /// registering it when Firebase rotates it, and records notification opens
  /// both when the app was backgrounded and when a tap cold-started it.
  ///
  /// The parameter is deliberately untyped. Adding firebase_messaging as a
  /// dependency would force it on every app — including the ones that get
  /// their APNs token elsewhere — so this calls the methods structurally
  /// instead. If Firebase ever renames one, you get a named log line rather
  /// than a crash in someone's release build.
  ///
  ///   await Notibase.configure('ck_live_…');
  ///   await Notibase.attachFirebase(
  ///     FirebaseMessaging.instance,
  ///     onMessageOpenedApp: FirebaseMessaging.onMessageOpenedApp,
  ///   );
  ///
  /// [onMessageOpenedApp] is a static on the FirebaseMessaging class rather
  /// than a member of the instance, so it cannot be reached from here and has
  /// to be handed in. Leave it out and everything else still works — you just
  /// won't see opens from notifications tapped while the app sat in the
  /// background, which is most of them. A log line says so at attach time
  /// rather than leaving you to notice the gap in a report weeks later.
  ///
  /// Safe to call more than once; the second call is a no-op.
  static Future<void> attachFirebase(
    dynamic messaging, {
    Stream<dynamic>? onMessageOpenedApp,
    bool requestPermission = true,
    void Function(String url)? onUrl,
  }) async {
    if (_api == null) return _warnNotConfigured();
    if (_firebaseAttached) return;
    _firebaseAttached = true;
    if (onUrl != null) onNotificationUrl = onUrl;

    if (requestPermission) {
      await _guard('requestPermission', () async => messaging.requestPermission());
    }

    final token = await _guard('getToken', () async => messaging.getToken());
    if (token is String && token.isNotEmpty) await registerPushToken(token);

    final refresh = await _guard('onTokenRefresh', () async => messaging.onTokenRefresh);
    if (refresh is Stream) {
      refresh.listen((next) {
        if (next is String && next.isNotEmpty) registerPushToken(next);
      });
    }

    // A tap that cold-started the app: the notification is waiting for us.
    final initial =
        await _guard('getInitialMessage', () async => messaging.getInitialMessage());
    if (initial != null) await trackNotificationOpen(_dataOf(initial));

    // A tap that resumed a backgrounded app.
    if (onMessageOpenedApp == null) {
      debugPrint('[Notibase] attachFirebase: no onMessageOpenedApp stream was passed, so '
          'taps on notifications that arrive while your app is backgrounded will not be '
          'recorded. Pass onMessageOpenedApp: FirebaseMessaging.onMessageOpenedApp to fix it.');
    } else {
      onMessageOpenedApp.listen((message) {
        if (message != null) trackNotificationOpen(_dataOf(message));
      });
    }
  }

  /// The `data` map off a RemoteMessage, without depending on its type.
  static Map<String, dynamic> _dataOf(dynamic message) {
    try {
      final data = message.data;
      if (data is Map) return Map<String, dynamic>.from(data);
    } catch (e) {
      debugPrint('[Notibase] could not read .data off the message: $e');
    }
    return const {};
  }

  /// Structural calls into someone else's package can fail in ways a typed
  /// call cannot. None of them are worth crashing a host app over, and each
  /// one names itself in the log so the failure is findable.
  static Future<Object?> _guard(String what, Future<Object?> Function() body) async {
    try {
      return await body();
    } on NoSuchMethodError {
      debugPrint('[Notibase] attachFirebase: the object passed in has no $what(). '
          'Pass FirebaseMessaging.instance, or wire the token up yourself with '
          'Notibase.registerPushToken.');
    } catch (e) {
      debugPrint('[Notibase] attachFirebase: $what failed: $e');
    }
    return null;
  }

  /// Record a notification open. [attachFirebase] calls this on both paths
  /// already — reach for it directly only if you are wiring Firebase yourself,
  /// or delivering notifications through something other than Firebase.
  ///
  /// The nb_m / nb_d / nb_o keys are placed in the data payload by the
  /// Notibase send pipeline; foreign notifications are ignored safely, so it
  /// is harmless to pass every notification your app receives.
  static Future<void> trackNotificationOpen(Map<String, dynamic> data) async {
    final m = data['nb_m'], d = data['nb_d'], o = data['nb_o'];
    if (m is! String || d is! String || o is! String) return;
    await NotibaseApi.postClick(o, m, d);
    _openUrl(data);
  }

  /// Where a tapped notification should go.
  ///
  /// Flutter has no way to open a URL without a plugin, and adding one to
  /// this package would force it on every app — including the many that route
  /// notifications inside their own navigator and never want a browser. So
  /// this is the one line that stays yours:
  ///
  ///   Notibase.onNotificationUrl = (url) =>
  ///       launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  ///
  /// or, to route in-app:
  ///
  ///   Notibase.onNotificationUrl = (url) => navigatorKey.currentState
  ///       ?.pushNamed(Uri.parse(url).path);
  ///
  /// [attachFirebase]'s `onUrl:` sets this for you. If nothing is set and a
  /// message arrives with a url, one log line says so — a notification whose
  /// destination is quietly dropped is exactly the kind of thing nobody
  /// notices until a campaign has already run.
  static void Function(String url)? onNotificationUrl;

  static bool _warnedNoUrlHandler = false;

  static void _openUrl(Map<String, dynamic> data) {
    final url = data['url'];
    if (url is! String || url.isEmpty) return;
    final handler = onNotificationUrl;
    if (handler == null) {
      if (_warnedNoUrlHandler) return;
      _warnedNoUrlHandler = true;
      debugPrint('[Notibase] a notification carried url "$url" but nothing is set to open '
          'it. Set Notibase.onNotificationUrl, or pass onUrl: to attachFirebase — e.g. '
          '(url) => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication).');
      return;
    }
    try {
      handler(url);
    } catch (e) {
      // The host app's routing throwing must not turn a notification tap
      // into a crash report.
      debugPrint('[Notibase] onNotificationUrl threw for "$url": $e');
    }
  }

  /// The stored Notibase device id, once registration has succeeded.
  static String? get deviceId => _prefs?.getString(_deviceIdKey);

  static void _warnNotConfigured() {
    debugPrint('[Notibase] Notibase.configure(clientKey) has not been called');
  }
}
