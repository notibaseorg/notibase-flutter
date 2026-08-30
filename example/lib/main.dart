// A whole Notibase integration, in one file.
//
// The four things every app does, in the order they have to happen:
//
//   1. configure()              once, before anything else touches the SDK
//   2. registerPushToken()      whatever firebase_messaging hands you
//   3. identify()               once you know who this person is
//   4. enableInAppMessages()    hand it your navigator, and it draws itself
//                               (paused here until the first screen is up)
//
// Ordering is the part a snippet cannot teach, which is why this is an app
// rather than a code block in the README.
import 'package:flutter/material.dart';
import 'package:notibase_flutter/notibase_flutter.dart';

/// From Settings → Keys in the console.
///
/// A publishable key is meant to ship inside an app: it can register a
/// device and read that device's own inbox, and nothing else. The server
/// key (`sk_…`) is the one that must never be in a build, and the SDK
/// throws loudly rather than quietly accepting one.
const clientKey = 'ck_live_replace_me';

/// The SDK pushes an in-app message as a route through your own app, so it
/// needs the navigator. This is the one thing Flutter needs that the Android
/// and iOS SDKs do not — a consequence of the package having no platform
/// channels, which is also why it has a single dependency.
final navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Notibase.configure(clientKey);

  // Held until the app is on a screen worth interrupting. Your navigator
  // exists from the first frame, so without this a message set to "every
  // app open" draws on top of whatever you show while you are still
  // starting up — a splash, a login screen, a "Loading…". Nothing here can
  // tell one of those from a real screen; only your app can.
  //
  // This example has no splash, so it resumes as soon as the home page is
  // mounted. An app with a real startup sequence resumes at the end of it.
  Notibase.pauseInAppMessages();

  // Fires on app open, and whenever you set a trigger. `onPromptPush` is
  // what an "Ask for push permission" button calls: asking belongs to
  // firebase_messaging, and taking a dependency on it to make one call
  // would cost this package the promise it is built on.
  await Notibase.enableInAppMessages(
    navigatorKey: navigatorKey,
    // onPromptPush: () => FirebaseMessaging.instance.requestPermission(),
  );

  // With firebase_messaging in your app, this is the whole of push:
  //
  //   final token = await FirebaseMessaging.instance.getToken();
  //   if (token != null) await Notibase.registerPushToken(token);
  //
  // or `Notibase.attachFirebase(...)`, which also handles refreshes.

  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Notibase example',
        navigatorKey: navigatorKey,
        theme: ThemeData(
          useMaterial3: true,
          colorSchemeSeed: const Color(0xFF6366F1),
        ),
        home: const HomePage(),
      );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String _status = 'Ready.';
  List<InboxItem>? _inbox;

  @override
  void initState() {
    super.initState();
    // The other half of the pause in `main`. This is the first screen a
    // person actually looks at, so this is the moment a message may
    // interrupt them. Anything held until now is evaluated here.
    Notibase.resumeInAppMessages();
  }

  /// Runs one call and reports what it said.
  ///
  /// The body returns the line to show rather than having the caller write
  /// one afterwards — otherwise a call with something to say (the setup
  /// test) has its answer overwritten by a generic tick.
  Future<void> _run(String label, Future<String> Function() body) async {
    try {
      final said = await body();
      if (mounted) setState(() => _status = said);
    } catch (e) {
      // Every call already swallows its own network failures — a
      // notification SDK must never be the reason an app crashes. This
      // catch is for the one thing that does throw: a server key.
      if (mounted) setState(() => _status = '$label failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const AppBar(title: Text('Notibase example')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(_status, style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 16),
          FilledButton(
            // Ties this device to a person. Everything they own — this
            // phone, their laptop, their email address — becomes one
            // audience member, and their inbox follows them across all of
            // it. Call it when they sign in, not before.
            onPressed: () => _run('identify', () async {
              final ok = await Notibase.identify(
                'user-42',
                attributes: const {'plan': 'pro'},
              );
              return ok ? 'Identified as user-42.' : 'identify was refused.';
            }),
            child: const Text('identify as user-42'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () => _run('track', () async {
              final ok = await Notibase.track(
                'viewed_cart',
                properties: const {'items': 3},
              );
              return ok ? 'Tracked viewed_cart.' : 'track was refused.';
            }),
            child: const Text('track an event'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            // A local fact, not an event that travels to us. Any in-app
            // message keyed on it is evaluated on this device, right now —
            // which is the point: the moment worth acting on is happening
            // here, and a server is not present for it.
            onPressed: () => _run('setTrigger', () async {
              Notibase.setTrigger('cart_value', 240);
              return 'cart_value is 240. A rule keyed on it fires now.';
            }),
            child: const Text("setTrigger('cart_value', 240)"),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () => _run('inbox', () async {
              final items = await Notibase.inbox();
              if (mounted) setState(() => _inbox = items);
              if (items == null) return 'The inbox needs an identified device.';
              return '${items.length} inbox ${items.length == 1 ? "item" : "items"}.';
            }),
            child: const Text('load the inbox'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            // Answers "is this app actually wired up?" from the device,
            // rather than leaving you to infer it from a notification that
            // never arrived.
            onPressed: () => _run('setup test', () async {
              final checks = await Notibase.runSetupTest();
              return checks.map(_line).join('\n');
            }),
            child: const Text('run the setup test'),
          ),
          if (_inbox != null) ...[
            const Divider(height: 32),
            Text(
              'Inbox (${_inbox!.length})',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            // An item's copy lives in `content`, which is whatever the
            // campaign put there. It is not a fixed shape, so read it
            // defensively rather than assuming a title exists.
            for (final item in _inbox!)
              ListTile(
                title: Text('${item.content['title'] ?? '(no title)'}'),
                subtitle: item.content['body'] == null
                    ? null
                    : Text('${item.content['body']}'),
                trailing: item.readAt == null
                    ? const Icon(Icons.circle, size: 10)
                    : null,
                onTap: () => Notibase.inboxMarkRead([item.id]),
              ),
          ],
        ],
      ),
    );
  }

  static String _line(SetupCheck c) {
    final mark = c.level == 'pass' ? '✓' : (c.level == 'warn' ? '!' : '✗');
    final detail = c.detail == null ? '' : ' — ${c.detail}';
    return '$mark ${c.title}$detail';
  }
}
