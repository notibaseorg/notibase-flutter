<p align="center">
  <img src="https://notibase.com/icon-512.png" width="72" alt="Notibase">
</p>
<h1 align="center">notibase_flutter</h1>
<p align="center">
  Push notifications, in-app inbox and click tracking for Flutter —
  <b>pure Dart, one dependency</b>.<br>
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
flutter pub add notibase_flutter firebase_messaging
```

New to push? The guide walks Firebase *and* APNs from empty accounts:
**[notibase.dev/flutter.html](https://notibase.dev/flutter.html)**

## How it fits together

Your app keeps using [`firebase_messaging`](https://pub.dev/packages/firebase_messaging)
for the platform push plumbing (you likely already do). Notibase takes the
token from there — registration, identity, events, attribution and the
in-app inbox are then one call each:

```dart
import 'package:notibase_flutter/notibase_flutter.dart';

await Notibase.configure('ck_live_…');   // client key — public by design

// hand over the FCM token (Android) / APNs-backed token (iOS)
final token = await FirebaseMessaging.instance.getToken();
if (token != null) await Notibase.registerPushToken(token);
FirebaseMessaging.instance.onTokenRefresh.listen(Notibase.registerPushToken);

// after login — signature minted by YOUR backend (docs → Security)
await Notibase.identify('user-42', signature: sig,
    attributes: {'plan': 'pro'});

// events → segments + attribution
await Notibase.track('level_complete', properties: {'level': 3});

// in-app inbox
final items = await Notibase.inbox();
await Notibase.inboxMarkRead([items!.first.id]);
```

Sending goes through **your** APNs/FCM credentials uploaded in the
Notibase dashboard — the SDK only registers tokens and talks to the API.

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

## Click tracking

Two listeners cover every notification-open path, and light up the Clicked /
CTR columns in the console:

```dart
// app opened from a background-state tap
FirebaseMessaging.onMessageOpenedApp.listen(
    (m) => Notibase.trackNotificationOpen(m.data));

// app cold-started by a tap
final initial = await FirebaseMessaging.instance.getInitialMessage();
if (initial != null) await Notibase.trackNotificationOpen(initial.data);
```

## Support

- Docs: [notibase.dev/flutter.html](https://notibase.dev/flutter.html)
- Issues & feature requests: [support@notibase.com](mailto:support@notibase.com)
- Security reports: [security@notibase.com](mailto:security@notibase.com)

## License

MIT © Notibase — see [LICENSE](LICENSE).

<sub>This repository is a published snapshot of the Notibase SDK, updated
automatically on each release.</sub>
