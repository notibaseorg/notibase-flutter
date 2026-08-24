## 0.5.1

- **`configure()` no longer waits on the network.** It awaited a device
  registration and a session event, both through a three-attempt retry chain —
  so on the returning-user path, which is every launch after the first, an
  unreachable Notibase meant a blank screen for up to about two minutes. Our
  own docs tell you to `await` it in `main()` before `runApp()`, which made
  that the default experience of our outage. It now waits only for local
  preferences and starts the rest in the background. No other Notibase SDK had
  this problem; the Android and iOS ones hand the work to a background queue
  and return.
- **A notification tap opens its destination before the click beacon.** The
  beacon was awaited in front of your `onUrl` handler, so during an outage a
  tap opened the app and then sat there. The beacon is a metric; the tap is a
  person.
- `postClick` got a connect timeout. It built a fresh `HttpClient` with none,
  so against a blackholed host the five-second timeout on the line below was
  never reached — and it leaked a client on every failure, which during an
  outage is every call.
- The response-body read is bounded and caught. A server that returned headers
  and then stalled the body hung forever, and any error it did raise escaped as
  a bare `SocketException` that the retry logic did not recognise.
- `track` and `trackPurchase` return `Future<bool>` rather than `Future<void>`.
  Neither ever threw, so a boolean was the only way to know whether an event
  landed — and `identify` already worked this way, which made the answer to
  "did that land?" depend on which method you happened to ask.

## 0.5.0

- A message composed with a URL now goes somewhere. `onUrl:` on `attachFirebase`
  (or `Notibase.onNotificationUrl`) receives it on every open path; before this,
  a notification's destination was dropped without a word. It stays one line
  rather than a dependency, because a package cannot know whether your app wants
  a browser or its own navigator — and a notification arriving with a URL and
  nowhere to send it now logs once instead of failing silently.
- `install` and `session_start` are reported for you as soon as a device is
  registered, which is what lets a campaign link be credited with the installs it
  drove. Mobile attribution has never worked before this: the server side was
  complete, and nothing on the client ever reported an install.
  `Notibase.autoTrackSessions = false` opts out.
- `Notibase.handleDeepLink(url)` takes a URL that opened the app, so a campaign
  match is deterministic rather than inferred from an IP and a time window.
- `Notibase.trackPurchase(9.99, productId: …)` — the revenue rollup's `value`
  property, written out so it cannot be guessed wrong.
- `Notibase.runSetupTest()` prints what Notibase can see of your integration:
  credentials, key, device, permission. The result also appears in the console.

## 0.4.0

- `Notibase.attachFirebase(FirebaseMessaging.instance, onMessageOpenedApp: …)`
  replaces the seven lines every app used to write by hand: it requests
  notification permission, registers the current token, registers it again on
  every refresh, and records notification opens both when a tap resumed the app
  and when a tap cold-started it.
- `firebase_messaging` is still not a dependency of this package. The new method
  takes the object you already have and calls it structurally, so apps that get
  their token elsewhere pay nothing and a Firebase major version cannot break
  this package's build.
- Everything it does is still available individually — `registerPushToken` and
  `trackNotificationOpen` are unchanged and public.

## 0.3.0

- `NotibaseNotification.parse(message.data)` returns the rich parts of a push
  payload — action buttons, media URL, Android large icon — already parsed, so
  wiring them into `flutter_local_notifications` is a few lines.
- Handles both wire encodings: FCM data values must be strings, so `nb_buttons`
  arrives JSON-encoded on Android, while an APNs payload keeps it a real list.
  Malformed input costs the buttons, never the notification.

## 0.2.1

- Package metadata now points at the public source mirror
  (github.com/notibaseorg/notibase-flutter) and the dedicated Flutter guide
  at notibase.dev/flutter.html. No API changes.

## 0.2.0

- Notification-open (click) tracking: `Notibase.trackNotificationOpen(data)`
  reports taps back to Notibase — wire it to firebase_messaging's
  `onMessageOpenedApp` and `getInitialMessage`. Opens power the Clicked/CTR
  columns in the console.

## 0.1.0

- Initial release: device registration (token hand-off from
  firebase_messaging), HMAC-verified identify, event tracking
  (attribution-ready), in-app inbox (list + mark read).
- Pure Dart, one dependency (shared_preferences). CI-verified against the
  real Notibase API.
