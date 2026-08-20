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
