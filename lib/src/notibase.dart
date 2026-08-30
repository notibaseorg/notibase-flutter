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

import 'dart:async' show unawaited;
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
// Needed for the navigator an in-app message is pushed onto, and for the
// lifecycle observer that notices the app coming back to the front.
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'in_app.dart';
import 'in_app_view.dart';

class Notibase {
  Notibase._();

  static const _deviceIdKey = 'nb_device_id';
  static const _tokenKey = 'nb_push_token';

  /// An APNs device token: 32 bytes, hex-encoded, and nothing else.
  ///
  /// Apple has documented that length since push existed and has never
  /// shipped anything else. An FCM registration token is several times
  /// longer and carries a colon, so the two cannot be mistaken for one
  /// another — which is what makes reading the token enough to know which
  /// service issued it, and why no app has to tell us.
  static final _apnsTokenShape = RegExp(r'^[0-9a-fA-F]{64}$');
  /// How often each in-app message has been shown on this device.
  static const _inAppStateKey = 'nb_in_app_state';
  /// Cold starts counted on this device, for the session_count trigger.
  static const _inAppSessionsKey = 'nb_in_app_sessions';

  static NotibaseApi? _api;
  static SharedPreferences? _prefs;
  static bool _firebaseAttached = false;

  /// Initialize once, e.g. in main(). Safe to call again (no-op).
  /// Re-registers a token cached from a previous launch automatically.
  ///
  /// **This never waits on the network.** Awaiting it — which is what the
  /// docs tell you to do, and what everybody does in `main()` before
  /// `runApp()` — waits only for local preferences to open. The device
  /// re-registration and the session event are started and deliberately not
  /// awaited, because they are our problem and not the reason your app is
  /// launching. If Notibase is unreachable, your first frame is not.
  ///
  /// It used to await both. On the returning-user path — which is every
  /// launch after the first — an unreachable API meant a blank screen for as
  /// long as the retry chain took, up to about two minutes. That is our
  /// outage becoming yours, and no other Notibase SDK does it: the Android
  /// and iOS ones hand this work to a background queue and return.
  static Future<void> configure(String clientKey,
      {String apiUrl = 'https://api.notibase.com'}) async {
    if (_api != null) return;
    _api = NotibaseApi(clientKey, apiUrl: apiUrl); // throws LOUDLY on sk_ keys
    _prefs = await SharedPreferences.getInstance();
    final cached = _prefs!.getString(_tokenKey);
    if (cached != null) {
      // Unawaited on purpose. `registerPushToken` catches everything, so
      // there is no rejection to go unhandled — see its own catch.
      unawaited(registerPushToken(cached));
    } else {
      // A brand-new install reports as soon as registration lands, so the
      // lifecycle call only belongs here when there was nothing to register.
      unawaited(_reportLifecycle());
    }
  }

  /// Register a push token yourself. [attachFirebase] calls this for you,
  /// including on every refresh — reach for this directly only when your app
  /// obtains its token some other way.
  ///
  /// Hand it whichever token you have. On iOS the two push services issue
  /// tokens of different shapes, so this works out which one you are
  /// holding and routes it accordingly — there is nothing to pass and
  /// nothing to get wrong.
  ///
  /// [channel] overrides that, and exists for a channel this SDK has not
  /// heard of rather than for everyday use. Getting it wrong is now
  /// refused by the server rather than silently accepted.
  static Future<void> registerPushToken(String token, {String? channel}) async {
    final api = _api;
    final prefs = _prefs;
    if (api == null || prefs == null) return _warnNotConfigured();
    await prefs.setString(_tokenKey, token);
    final platform = kIsWeb
        ? 'web'
        : Platform.isIOS
            ? 'ios'
            : 'android';
    final resolved = channel ?? channelForToken(platform, token);
    try {
      final deviceId = await api.registerDevice(
        token: token,
        platform: platform,
        locale: Platform.localeName,
        timezone: DateTime.now().timeZoneName,
        channel: resolved,
        // Whatever this install was registered as until now. The server
        // ignores it when it is the same device, so re-registering an
        // unchanged token costs nothing.
        replaces: prefs.getString(_deviceIdKey),
      );
      await prefs.setString(_deviceIdKey, deviceId);
      // The channel is on this line because its absence cost days. Two
      // registrations in one launch, an iPhone delivered through Firebase,
      // and an app that turned out never to call `attachFirebase` — all of
      // it was visible from the server and none of it from here. One word
      // per registration answers "which token did it just send us?" without
      // anybody having to ask.
      debugPrint('[Notibase] device registered: $deviceId'
          ' — $platform${resolved == null ? '' : ' via $resolved'}');
      await _reportLifecycle();
    } catch (e) {
      debugPrint(
          '[Notibase] device registration failed (will retry on next token refresh): $e');
    }
  }

  /// Which push service issued this token, where that is not obvious.
  ///
  /// Public because it is the rule the SDK applies to every registration,
  /// and a rule a test can only restate is a rule nothing checks.
  ///
  /// Only iOS is ambiguous. An iPhone running a Flutter build with
  /// Firebase holds a Google token and must be delivered through Google; the
  /// same iPhone running a native build holds an Apple token and goes
  /// straight to Apple. The operating system cannot tell you which, and the
  /// app has no reason to know the difference — so the token is read
  /// instead of the developer being asked.
  ///
  /// This is not a guess dressed up as a rule. An Apple token cannot be
  /// delivered by Firebase and a Firebase token cannot be delivered by
  /// Apple, so the shape does not merely suggest a channel, it is the only
  /// channel that could ever work. The server enforces the same rule at
  /// registration, from the channel's own manifest, so the two cannot
  /// drift apart.
  ///
  /// Android and the web return null: their platform already answers this,
  /// and a value stored where it adds nothing is one more thing that can
  /// go stale.
  static String? channelForToken(String platform, String token) {
    if (platform != 'ios') return null;
    return _apnsTokenShape.hasMatch(token.trim()) ? 'apns' : 'fcm';
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
  ///
  /// Returns whether it landed. **It never throws** — an event we could not
  /// deliver is our problem, not something to raise in the middle of your
  /// checkout — so the boolean is the only way to know, and it is there for
  /// the callers who want to count what an outage cost them. `identify`
  /// already worked this way; these two did not, which made the answer to
  /// "did that land?" depend on which method you asked.
  static Future<bool> track(String name,
      {Map<String, dynamic> properties = const {}}) async {
    final api = _api;
    if (api == null) {
      _warnNotConfigured();
      return false;
    }
    try {
      await api.track(name,
          properties: properties, deviceId: _prefs?.getString(_deviceIdKey));
      return true;
    } catch (e) {
      debugPrint('[Notibase] track($name) failed: $e');
      return false;
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
  static Future<bool> trackPurchase(
    double value, {
    String currency = 'USD',
    String? productId,
    Map<String, dynamic> properties = const {},
  }) async {
    return track('purchase', properties: {
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

  /// The last click id we acted on, kept forever.
  ///
  /// Separate from [_pendingClickKey], and the difference is a bug: the
  /// pending key is *cleared* once its id has been attached to an event, so
  /// de-duplicating against it stopped working the moment it had done its
  /// job. Handing the same URL in twice — which happens on every cold start
  /// from a link, because the initial-link read and the link stream both
  /// deliver it — then reported a second session and re-credited the
  /// campaign that produced the install.
  ///
  /// Found by the React Native SDK's tests, which exercise the same state
  /// machine. This one had no test for it.
  static const _lastClickKey = 'nb_last_click';
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
    if (prefs.getString(_lastClickKey) == click) return;
    await prefs.setString(_lastClickKey, click);
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
      await track('install', properties: props);   // result unused: nothing to retry
    } else if (force || !_sessionReported) {
      _sessionReported = true;
      await track('session_start', properties: props);   // result unused: nothing to retry
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

    await _registerFromFirebase(messaging);

    final refresh = await _guard('onTokenRefresh', () async => messaging.onTokenRefresh);
    if (refresh is Stream) {
      refresh.listen((next) {
        // Firebase refreshes its own token, not Apple's. On a device we
        // registered with Apple directly, re-registering what this hands
        // us would swap the correct address for the wrong one, so the
        // whole resolution is repeated rather than the value reused.
        if (next is String && next.isNotEmpty) _registerFromFirebase(messaging);
      });
    }

    // A tap that cold-started the app: the notification is waiting for us.
    // Not awaited — everything below this line (the refresh listener, the
    // opened-app subscription) used to sit behind it, so one slow beacon
    // could leave an app attached to nothing.
    final initial =
        await _guard('getInitialMessage', () async => messaging.getInitialMessage());
    if (initial != null) unawaited(trackNotificationOpen(_dataOf(initial)));

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

  /// Take Apple's token on iOS, Firebase's everywhere else.
  ///
  /// `firebase_messaging` hands you two different tokens on an iPhone and
  /// the difference decides how the message is delivered. `getToken()`
  /// returns Google's registration token: sending to it means Firebase
  /// relays to Apple, using the `.p8` uploaded to the *Firebase* project.
  /// `getAPNSToken()` returns Apple's own device token, which Notibase can
  /// deliver to directly with the key you uploaded here.
  ///
  /// Direct is the better default. It is one fewer service in the path,
  /// one fewer place for the key to be missing, and it does not make
  /// Google's availability a condition of your iOS notifications arriving.
  /// So Apple's token is preferred, and Firebase's is the fallback for the
  /// cases where Apple's is genuinely unavailable — a simulator, or a
  /// build with no push entitlement.
  ///
  /// The registration is asynchronous inside iOS: `getAPNSToken()` returns
  /// null for a moment after permission is granted while the device talks
  /// to Apple. So this waits a little rather than taking the first null as
  /// an answer, which would send every first launch down the fallback and
  /// make the behaviour depend on how fast the network was that morning.
  static Future<void> _registerFromFirebase(dynamic messaging) async {
    if (!kIsWeb && Platform.isIOS) {
      final apns = await _apnsToken(messaging);
      if (apns != null) {
        // No channel named here on purpose. `registerPushToken` reads the
        // token, and one place deciding this means the automatic path and
        // the hand-wired one cannot reach different answers.
        await registerPushToken(apns);
        return;
      }
      debugPrint('[Notibase] No APNs token, so this device is registered through '
          'Firebase instead. That works — and it needs your .p8 uploaded to the '
          'Firebase project as well as to Notibase, because Google is the one '
          'relaying to Apple. Expected on a simulator; on a real device it usually '
          'means the Push Notifications capability is missing from the target.');
    }

    final token = await _guard('getToken', () async => messaging.getToken());
    if (token is String && token.isNotEmpty) await registerPushToken(token);
  }

  /// Apple's device token, waiting out the registration if it is in flight.
  ///
  /// Null has two meanings and they need different handling, which is why
  /// this does not go through [_guard]. A *missing* `getAPNSToken` is an old
  /// `firebase_messaging` and will never produce one, so retrying it eight
  /// times only prints the same confusing line eight times. A *null return*
  /// is iOS still talking to Apple, which is the ordinary state for the
  /// first second or so after permission is granted — and taking that first
  /// null as the answer would send every first launch down the Firebase
  /// path, making the delivery route depend on how fast the network was.
  ///
  /// Two seconds is the budget. It is spent only on iOS, only where Apple's
  /// token never arrives, and the alternative to spending it is being wrong
  /// about how the app delivers for the lifetime of the install.
  static Future<String?> _apnsToken(dynamic messaging) async {
    for (var attempt = 0; attempt < 8; attempt++) {
      Object? token;
      try {
        token = await messaging.getAPNSToken();
      } on NoSuchMethodError {
        debugPrint('[Notibase] This firebase_messaging has no getAPNSToken(), so iOS '
            'sends are relayed by Firebase rather than going straight to Apple. '
            'Upgrading firebase_messaging removes Google from the path.');
        return null;
      } catch (e) {
        debugPrint('[Notibase] getAPNSToken failed: $e');
        return null;
      }
      if (token is String && token.isNotEmpty) return token;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return null;
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
    // Open first, count second. The beacon is a metric; the tap is the
    // person. Awaiting the beacon in front of the navigation meant that
    // when our API was unreachable, tapping a notification opened the app
    // and left it sitting there — for as long as a DNS lookup takes to
    // give up. Every other Notibase SDK fires this in parallel; this one
    // was the outlier.
    _openUrl(data);
    unawaited(NotibaseApi.postClick(o, m, d));
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


  // ── in-app messages ────────────────────────────────────────────────
  //
  // A rule the SDK caches and this device evaluates: on app open, or when
  // the host app puts a value in front of it. The decisions are in
  // in_app.dart, which has no Flutter import and runs on the Dart VM.

  static bool _inAppEnabled = false;
  static List<InAppRule> _inAppRules = const [];
  static bool _inAppShowing = false;
  static final Map<String, Object?> _inAppTriggers = {};
  static GlobalKey<NavigatorState>? _navigatorKey;
  static Future<void> Function()? _onPromptPush;
  static _InAppLifecycle? _lifecycle;

  /// Start showing in-app messages.
  ///
  /// [navigatorKey] must be the one on your `MaterialApp`. This package has
  /// no platform channels and does not own your widget tree, so a message
  /// is pushed as a route through your navigator rather than conjured from
  /// nowhere — which also means your theming, back handling and
  /// accessibility apply to it.
  ///
  /// [onPromptPush] is called when somebody presses a button configured to
  /// ask for push permission. The SDK cannot ask by itself: permission
  /// belongs to `firebase_messaging`, and taking a dependency on it to make
  /// one call would break the one-dependency promise this package is built
  /// on. Pass
  /// `() => FirebaseMessaging.instance.requestPermission()` and the button
  /// works.
  ///
  /// Opening a link uses [onNotificationUrl], the same handler a tapped
  /// notification uses, for the same reason: this package has no
  /// url_launcher either.
  static Future<void> enableInAppMessages({
    required GlobalKey<NavigatorState> navigatorKey,
    Future<void> Function()? onPromptPush,
  }) async {
    _navigatorKey = navigatorKey;
    _onPromptPush = onPromptPush;
    if (_inAppEnabled) return;
    _inAppEnabled = true;
    final prefs = _prefs;
    if (prefs == null) return _warnNotConfigured();
    // One per cold start. The trigger this feeds is "how many times has
    // this person been here", and a launch is the closest thing to that
    // question an app can answer without guessing.
    await prefs.setInt(
        _inAppSessionsKey, (prefs.getInt(_inAppSessionsKey) ?? 0) + 1);
    _lifecycle ??= _InAppLifecycle();
    WidgetsBinding.instance.addObserver(_lifecycle!);
    await _refreshInAppMessages();
  }

  /// Put a value in front of the SDK for messages to test against.
  ///
  /// `setTrigger('cart_value', 240)` and a campaign configured for
  /// `cart_value over 100` fires on the next evaluation, which happens here
  /// and now. It never leaves the device: a trigger is a local fact, not an
  /// event to report.
  static void setTrigger(String key, Object value) {
    _inAppTriggers[key] = value;
    if (_inAppEnabled) _evaluateInAppMessages();
  }

  static void removeTrigger(String key) => _inAppTriggers.remove(key);

  static void clearTriggers() => _inAppTriggers.clear();

  static Future<void> _refreshInAppMessages() async {
    final api = _api;
    final deviceId = _prefs?.getString(_deviceIdKey);
    if (api == null || deviceId == null) return;
    try {
      _inAppRules = await api.inAppRules(deviceId);
    } catch (e) {
      // A campaign that does not appear is not worth a line in somebody's
      // console on every launch.
      return;
    }
    _evaluateInAppMessages();
  }

  static void _evaluateInAppMessages() {
    if (_inAppShowing) return;
    final prefs = _prefs;
    final navigator = _navigatorKey?.currentState;
    if (prefs == null || navigator == null) return;

    final memory = InAppMemory(
      load: () => prefs.getString(_inAppStateKey),
      save: (value) => prefs.setString(_inAppStateKey, value),
    );
    final now = DateTime.now().millisecondsSinceEpoch;
    final rule = InAppPicker.choose(
      rules: _inAppRules,
      memory: memory,
      triggers: _inAppTriggers,
      sessions: prefs.getInt(_inAppSessionsKey) ?? 1,
      now: now,
    );
    if (rule == null) return;

    _inAppShowing = true;
    // Recorded before it is drawn. Somebody who kills the app the instant a
    // message appears has still seen it.
    memory.record(rule.id, now);
    _reportInApp(rule.id, 'shown');

    navigator.push(PageRouteBuilder<void>(
      opaque: false,
      barrierDismissible: false,
      pageBuilder: (_, __, ___) => NotibaseInAppView(
        rule: rule,
        onAction: (action) {
          _inAppShowing = false;
          navigator.pop();
          _runInAppAction(rule.id, action);
        },
        onDismiss: () {
          _inAppShowing = false;
          navigator.pop();
          _reportInApp(rule.id, 'dismissed');
        },
      ),
    ));
  }

  static void _runInAppAction(String ruleId, InAppAction action) {
    _reportInApp(ruleId, 'clicked',
        tag: action.kind == 'tag_user' ? action.key : null);
    switch (action.kind) {
      case 'open_url':
        {
          final url = action.url;
          if (url != null) _openUrl(<String, dynamic>{'url': url});
          break;
        }
      case 'prompt_push':
        {
          final prompt = _onPromptPush;
          if (prompt == null) {
            debugPrint('[Notibase] a message asked for push permission but nothing can ask. '
                'Pass onPromptPush: to enableInAppMessages — e.g. '
                '() => FirebaseMessaging.instance.requestPermission().');
          } else {
            // The reason this feature earns its place. Both platforms give
            // an app one system prompt per install and a decline is close
            // to permanent, so it is spent only on somebody who already
            // said yes inside the app.
            prompt();
          }
          break;
        }
      case 'track':
        {
          final name = action.name;
          if (name != null) track(name, properties: {'in_app_message': ruleId});
          break;
        }
      default:
        // tag_user is applied server-side from the campaign's own value,
        // and dismiss has already happened.
        break;
    }
  }

  static void _reportInApp(String id, String event, {String? tag}) {
    final api = _api;
    final deviceId = _prefs?.getString(_deviceIdKey);
    if (api == null || deviceId == null) return;
    // Fire and forget: an impression that fails to report is a number
    // slightly low, and never a reason to interrupt anything.
    api.inAppEvent(deviceId, id, event, tag: tag).catchError((Object _) {});
  }

  /// Re-evaluates when the app comes back to the front, which is what "app
  /// open" means for a rule and a moment no server ever hears about.
  static void _onResumed() {
    if (_inAppEnabled) _refreshInAppMessages();
  }

  /// The stored Notibase device id, once registration has succeeded.
  static String? get deviceId => _prefs?.getString(_deviceIdKey);

  static void _warnNotConfigured() {
    debugPrint('[Notibase] Notibase.configure(clientKey) has not been called');
  }
}

/// Watches for the app coming back to the foreground.
///
/// Its own class rather than making Notibase an observer, because
/// [WidgetsBindingObserver] is a mixin on an instance and Notibase is a
/// namespace of statics.
class _InAppLifecycle with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) Notibase._onResumed();
  }
}
