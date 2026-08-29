<p align="center">
  <img src="https://notibase.com/icon-512.png" width="72" alt="Notibase">
</p>
<h1 align="center">notibase_flutter</h1>
<p align="center">
  Push notifications, in-app messages, an in-app inbox and click tracking
  for Flutter — <b>pure Dart, one dependency</b>.<br>
  <a href="https://notibase.dev/flutter.html">Documentation</a> ·
  <a href="https://pub.dev/packages/notibase_flutter">pub.dev</a> ·
  <a href="https://app.notibase.com">Console</a>
</p>

---

Official Flutter SDK for [Notibase](https://notibase.com). Pure Dart —
**no native code and a single dependency** (`shared_preferences`), so it
adds nothing to your build complexity and can never conflict with your
Firebase setup.

```sh
flutter pub add notibase_flutter firebase_messaging url_launcher
```

New to push? The guide walks Firebase *and* APNs from empty accounts:
**[notibase.dev/flutter.html](https://notibase.dev/flutter.html)**

## Coming from OneSignal, or straight from Firebase

Notibase is an alternative to OneSignal, and the device-side model is the
same shape: register a token, identify the person behind it, tag them, send
to a segment. Most of a port is renaming calls. What is arranged differently
is that push, in-app messages, an in-app inbox, email and SMS are one
audience and one API here rather than several products with separate lists.

It is not an alternative to Firebase Cloud Messaging, and does not try to
be. You keep FCM and hand us the token: FCM delivers, Notibase decides who
to deliver to — and then carries the same campaign to iOS, the web, an
inbox, an email and a text without you writing any of it a second time.


## How it fits together

Your app keeps using [`firebase_messaging`](https://pub.dev/packages/firebase_messaging)
for the platform push plumbing (you likely already do). `attachFirebase`
takes the object you already have and wires everything to it:

```dart
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:notibase_flutter/notibase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

await Notibase.configure('ck_live_…');   // client key — public by design

await Notibase.attachFirebase(
  FirebaseMessaging.instance,
  onMessageOpenedApp: FirebaseMessaging.onMessageOpenedApp,
  onUrl: (url) => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
);

// after login — signature minted by YOUR backend (docs → Security)
await Notibase.identify('user-42', signature: sig, attributes: {'plan': 'pro'});

await Notibase.track('level_complete', properties: {'level': 3});

final items = await Notibase.inbox();
await Notibase.inboxMarkRead([items!.first.id]);
```

That one call requests notification permission, registers the current token,
registers it again every time Firebase rotates it, and records notification
opens on both paths — a tap that resumed a backgrounded app, and a tap that
cold-started it. Every piece is still public if you would rather wire it
yourself: `registerPushToken`, `trackNotificationOpen`.

`onMessageOpenedApp` is a static on the `FirebaseMessaging` class rather than
something the instance can reach, so it has to be handed in separately.

**`firebase_messaging` is your dependency, not ours.** This package never
imports it — `attachFirebase` calls it structurally, so apps that obtain a
token another way pay nothing for the convenience and a Firebase major
version cannot break this package's build.

## Where a tap goes

`onUrl` is where a message composed with a URL goes, and it is the one line
that stays yours. Flutter cannot open a URL without a plugin, and making
`url_launcher` a dependency of this package would force it on every app —
including the many that route notifications through their own navigator and
never want a browser. Point it at your router instead:

```dart
onUrl: (url) => navigatorKey.currentState?.pushNamed(Uri.parse(url).path),
```

Leave it out and a notification's URL is quietly dropped, so the SDK logs one
line the first time that happens. `Notibase.onNotificationUrl` sets the same
hook outside `attachFirebase`.

## Attribution

Installs, sessions and revenue are reported for you. `install` goes out once
and `session_start` on each cold start, as soon as the device is registered —
which is what lets a campaign link be credited with the installs it drove.

```dart
// a deep link that opened the app
await Notibase.handleDeepLink(uri.toString());

await Notibase.trackPurchase(9.99, productId: 'pro_monthly');
```

`Notibase.autoTrackSessions = false` turns the automatic events off.
Full model: [notibase.dev/attribution.html](https://notibase.dev/attribution.html)

## Setup test

Most of what goes wrong during an integration is invisible from inside the
app: credentials that were never uploaded, a client key belonging to another
app, a device that never actually registered. One call prints the answer —
and it shows up in the console under Settings → Push platforms:

```dart
if (kDebugMode) await Notibase.runSetupTest();
```

## Rich payloads

Pure Dart with no platform channels means this package does not draw
notifications — `firebase_messaging` and the OS do. What it gives you is the
structured extras, already parsed, for wiring into
`flutter_local_notifications`:

```dart
final n = NotibaseNotification.parse(message.data);
if (!n.isNotibase) return;              // someone else's notification
for (final b in n.buttons) { /* b.id, b.text, b.url */ }
n.mediaUrl;      // ios.media / image
n.largeIconUrl;  // Android only
```

## Verification

CI is the gate (`.github/workflows/flutter-sdk.yml`): `flutter analyze`,
unit tests against an in-process mock server (auth headers, retry policy,
4xx no-retry, parsing), and a full e2e where the exact shipped core runs
against the real Notibase API (register idempotency, HMAC identify
enforcement, track, send → inbox → markRead) with database-side assertions.

## Security model

The `ck_` client key ships inside the app and is public by design (Arch
§5.3): it can only register devices, identify **with an HMAC signature your
backend mints**, track events, and read its own device's inbox. Server keys
(`sk_`) are refused at `configure` time with a teaching error.

## In-app messages

A message shown *inside* your app rather than sent to it. You publish a rule in the
console; the SDK caches it and decides on the device when to show it — on app open, or
when you put a value in front of it.

```dart
final navigatorKey = GlobalKey<NavigatorState>();

MaterialApp(navigatorKey: navigatorKey, /* … */);

await Notibase.enableInAppMessages(
  navigatorKey: navigatorKey,
  // This package has no platform channels, so it cannot ask for push
  // permission itself — that belongs to firebase_messaging. Pass it in and
  // an "Ask for push permission" button works.
  onPromptPush: () => FirebaseMessaging.instance.requestPermission(),
);

// A local fact for rules to test against. Never leaves the device.
Notibase.setTrigger('cart_value', 240);
```

The message is pushed as a route through your navigator, so your theming, back handling
and accessibility apply to it. A link button uses `Notibase.onNotificationUrl`, the same
handler a tapped notification uses — for the same reason: no `url_launcher` dependency.

How often somebody sees a message is counted on the device, so an app opened in airplane
mode still knows it showed one yesterday. A reinstall forgets, and two devices belonging
to one person count separately.

## Support

- Docs: [notibase.dev/flutter.html](https://notibase.dev/flutter.html)
- Issues & feature requests: [support@notibase.com](mailto:support@notibase.com)
- Security reports: [security@notibase.com](mailto:security@notibase.com)

## License

MIT © Notibase — see [LICENSE](LICENSE).

<sub>This repository is a published snapshot of the Notibase SDK, updated
automatically on each release.</sub>

## Changelog

[CHANGELOG.md](./CHANGELOG.md).
