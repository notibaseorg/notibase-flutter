# notibase_flutter example

A single screen that does the four things every integration does: start the
SDK, hand it a push token, tell it who the person is, and show an in-app
message.

```sh
cd example
flutter run
```

Replace `clientKey` in `lib/main.dart` with your own publishable key from
**Settings → Keys** in the console. A publishable key is safe to ship in an
app; it can register a device and read that device's own inbox, and nothing
else. The server key is the one that must never be in a build.

Push itself needs `firebase_messaging` and a Firebase project, which this
example deliberately leaves out — it would double the setup and none of it
is Notibase-specific. The one line that matters is marked in `main.dart`:
whatever `firebase_messaging` hands you, pass to `Notibase.setPushToken`.
