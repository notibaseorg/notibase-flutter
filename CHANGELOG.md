## 0.7.4

- **An Apple token from a simulator is read as Apple's.** `channelForToken`
  asked for exactly 32 hex-encoded bytes, because that is what a real device
  issues. An Xcode simulator issues **80**, so a perfectly good APNs token
  was read as Firebase's and every iOS send went to the wrong service — the
  same symptom as the bug 0.7.0 fixed, from the opposite direction, and with
  no log line to distinguish them.

  Apple's documentation says not to assume the length. The rule now asserts
  only what is true: hexadecimal, in whole bytes, long enough that nothing
  else could be mistaken for one, and no upper bound. A Firebase token
  carries a colon and is not hex, so the distinction this exists to make
  still holds.

  The server's own guard had the same assumption and would have refused an
  80-byte token outright. Both are fixed; nothing to change in your app
  beyond upgrading.

## 0.7.3

- **The registration log says which push service the token belongs to.**

  ```
  [Notibase] device registered: 75ecf2a2-… — ios via fcm
  ```

  One word, and it is the word that has been missing. An iPhone can be
  delivered through Apple or through Firebase depending on which token your
  app hands over, and until now the log said only that *a* device
  registered — so an app quietly registering Firebase's token looked
  identical to one registering Apple's, and the difference only showed up
  on the server.

  If this says `via fcm` on iOS and you expected Apple, your app is handing
  `registerPushToken` the token from `getToken()`. Either call
  `attachFirebase`, which asks iOS for Apple's token itself, or pass
  `getAPNSToken()`.

## 0.7.2

- **One phone stops becoming two audience members.** A device row is keyed on
  its token, so a token that changes is a new row — and the old one stayed
  active and targeted for a token the device no longer had. Ordinary rotation
  cleaned itself up eventually, because the dead token gets reported as gone.
  Moving from Firebase's token to Apple's never did: the old Firebase token
  stays perfectly valid at Google, so nothing would ever have retired it.
  Upgrading from an older version registered a second device and left the
  first one there for good, and every campaign attempted both.

  The SDK now tells the server which device it is replacing, and that row is
  retired in the same call. Nothing to change in your app. If you see two
  devices for one phone in the console after upgrading, the next launch
  cleans it up.

## 0.7.1

- **You no longer say which push service issued a token — the SDK reads it.**
  `registerPushToken(token)` takes whichever token you have. On iOS an Apple
  device token is 64 hexadecimal characters and a Firebase registration token
  is several times longer with a colon in it, so there is nothing to pass and
  nothing to get wrong:

  ```dart
  final apns = await FirebaseMessaging.instance.getAPNSToken();
  final fcm  = await FirebaseMessaging.instance.getToken();
  await Notibase.registerPushToken(apns ?? fcm!);   // same call, either token
  ```

  0.7.0 introduced a `channel:` argument for this, which meant anyone wiring
  the token up by hand — rather than through `attachFirebase` — had to know
  the difference between two tokens their app has no reason to care about.
  That was a question with a silent wrong answer, which is the opposite of
  what an SDK is for.

  Reading the token is not a heuristic. An Apple token cannot be delivered by
  Firebase and a Firebase token cannot be delivered by Apple, so the shape is
  the only channel that could ever reach the device. The server enforces the
  same rule at registration, from the channel's own manifest.

- **`Notibase.channelForToken(platform, token)`** returns the same answer, if
  you want to see what the SDK decided. The `channel:` argument still
  overrides it — an escape hatch for a channel this SDK has not heard of,
  rather than something an app needs.

- Nothing to change if you call `attachFirebase`; it already did the right
  thing in 0.7.0 and now shares one implementation with the manual path, so
  the two cannot reach different answers.

## 0.7.0

- **iOS notifications go straight to Apple.** `attachFirebase` now asks for
  Apple's own device token — `getAPNSToken()` — and registers it as an APNs
  token. It used to take `getToken()`, which is Google's, and register it
  with `channel: 'fcm'`. Notibase ignored that declaration and routed iOS to
  Apple by platform, so a Google token was posted to Apple on every send.
  Apple answered `BadDeviceToken`, the console reported "the token is
  malformed or belongs to another app", and nothing anywhere was red: the
  APNs key was valid, the bundle id matched, and the setup test said nothing
  was blocking. **iOS push has never worked through this package.** It does
  now, with the key you already uploaded to Notibase, and Firebase is no
  longer in the delivery path at all.

  Nothing to change in your app if you call `attachFirebase`. Upgrade,
  rebuild, and the next launch re-registers each device correctly. Devices
  registered by an older version are corrected server-side.

  Where Apple's token genuinely is not available — a simulator, or a target
  missing the Push Notifications capability — this falls back to Firebase
  and says so in the log. That path needs your `.p8` uploaded to the
  Firebase project too, because there Google is the one relaying to Apple.

- **`registerPushToken` takes a `channel`.** Pass `'apns'` for a token from
  `getAPNSToken()`, `'fcm'` for one from `getToken()`. Leave it out and the
  server routes by platform, which is right for Android, for the web, and
  for a native iOS build. The value is remembered alongside the token, so
  the re-registration `configure` performs on every later launch does not
  quietly lose it. (0.7.1 removes the need to pass it at all.)

- The server now refuses a token that cannot be an address on the channel
  it claims — a Firebase token registered as Apple's is a 400 at
  registration rather than a device that fails on every send for as long as
  it exists.

## 0.6.3

No change to this package beyond the version. Published alongside the
Android and iOS SDKs, which needed it: both had the deep-link attribution
bug this package fixed in 0.6.2 — the same campaign link arriving twice
reported a second session and re-credited the campaign that produced the
install — and the three mobile SDKs share one version number.

## 0.6.2

- **The same deep link is acted on once, however often it arrives.** A cold
  start from a campaign link delivers the URL twice on both platforms — the
  initial-link read and the link stream both produce it — and most routers
  call the handler again on every redirect evaluation. The guard against that
  was checking the *pending* click id, which is deleted as soon as its id has
  been attached to an event, so it stopped working the moment it had done its
  job. Each repeat reported another `session_start` and re-credited the
  campaign that produced the install. The id we last acted on is now
  remembered separately, and kept.

  Nothing to change in your app. If your attribution report has campaigns
  with more installs than seems plausible, this is a likely reason.

- Android and iOS are unchanged; they share the version number.

## 0.6.1

- No API change. This release exists so pub.dev re-reads the package: it
  carries five topics, a description inside pub.dev's 60–180 character
  window, and a runnable `example/` — the three things costing the package
  30 of its 160 pub points, which feed search ranking directly.
- The scrim behind an in-app message is written as a colour constant rather
  than `Colors.black.withOpacity(0.45)`. `withOpacity` is deprecated from
  Flutter 3.27 and `withValues` does not exist before it, so either spelling
  is wrong across half the range this package supports. `0x73000000` is the
  same colour and belongs to neither era.
- The example is analyzed in CI. It is the only Dart in the repo that calls
  the public API the way a customer does, so a signature that moves under it
  now fails a build rather than somebody's first afternoon.

## 0.6.0

- **In-app messages.** `Notibase.enableInAppMessages(navigatorKey: …)` fetches
  the rules this device is eligible for, caches them, and evaluates them on the
  device — on every foreground, and whenever you call
  `Notibase.setTrigger(key, value)`. A message therefore still fires for
  somebody who was offline when you published it.

  Three checks run here, because no server can make them honestly: has the
  trigger fired, has this person seen it enough times, has the gap between
  displays elapsed. The counts are per install, so a reinstall forgets and two
  devices belonging to one person count separately.

  The message is pushed as a route through your navigator, so your theming,
  back handling and accessibility apply to it. Every block is an ordinary
  widget — there is no WebView, and nothing in a message can become code
  running in your app.
- `onPromptPush:` on `enableInAppMessages`. A message can carry a button that
  asks for push permission, which is the reason to reach for this first: both
  platforms give an app one system prompt per install and a decline is close to
  permanent, so asking in your own UI first makes a "no" free. This package has
  no platform channels, so it cannot ask by itself — pass
  `() => FirebaseMessaging.instance.requestPermission()` and the button works.
- `Notibase.setTrigger` / `removeTrigger` / `clearTriggers`. A trigger is a
  local fact for messages to test against and never leaves the device. Values
  are not coerced across types: the string `"240"` does not satisfy a rule
  configured for `over 100`.
- A link button reuses `Notibase.onNotificationUrl`, the same handler a tapped
  notification uses — for the same reason: no `url_launcher` dependency.

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
