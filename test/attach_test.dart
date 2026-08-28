/// attachFirebase, against a fake that quacks like FirebaseMessaging.
///
/// The point of the method is that an app writes one call instead of seven
/// lines, so the thing worth testing is that all seven still happen: the token
/// is registered, a refreshed token is registered again, and a notification
/// that cold-started the app is recorded as an open.
///
/// It is one long test on purpose. `configure` and `attachFirebase` are both
/// one-shot by design — calling either twice is a deliberate no-op — so the
/// sequence can only be exercised once per process.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notibase_flutter/notibase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Everything attachFirebase reaches for, and nothing else. If this is enough
/// to drive it, the SDK is not secretly depending on the rest of Firebase.
class FakeMessaging {
  FakeMessaging({this.initialMessage});

  final refresh = StreamController<String>.broadcast();
  final FakeRemoteMessage? initialMessage;
  int permissionRequests = 0;
  int tokenReads = 0;

  Future<Object?> requestPermission() async {
    permissionRequests++;
    return null;
  }

  Future<String?> getToken() async {
    tokenReads++;
    return 'fcm-token-one';
  }

  Stream<String> get onTokenRefresh => refresh.stream;

  Future<FakeRemoteMessage?> getInitialMessage() async => initialMessage;
}

class FakeRemoteMessage {
  FakeRemoteMessage(this.data);
  final Map<String, dynamic> data;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('attachFirebase wires token, refresh and the cold-start open', () async {
    SharedPreferences.setMockInitialValues({});

    final seen = <String, List<Map<String, dynamic>>>{};
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final base = 'http://127.0.0.1:${server.port}';
    final firstClick = Completer<void>();

    server.listen((req) async {
      final raw = await utf8.decoder.bind(req).join();
      final body = raw.isEmpty ? <String, dynamic>{} : jsonDecode(raw) as Map<String, dynamic>;
      (seen[req.uri.path] ??= []).add(body);
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({'id': '00000000-0000-0000-0000-000000000001'}));
      await req.response.close();
      if (req.uri.path == '/v1/push/click' && !firstClick.isCompleted) firstClick.complete();
    });
    addTearDown(() => server.close(force: true));

    await Notibase.configure('ck_test_attach', apiUrl: base);

    final fm = FakeMessaging(
      initialMessage: FakeRemoteMessage({
        'nb_m': 'msg-1',
        'nb_d': 'dev-1',
        'nb_o': base,
      }),
    );

    await Notibase.attachFirebase(fm);

    // Permission asked for, token read and registered — none of which the app
    // had to write.
    expect(fm.permissionRequests, 1);
    expect(fm.tokenReads, 1);
    expect(seen['/v1/devices'], hasLength(1));
    expect(seen['/v1/devices']!.single['token'], 'fcm-token-one');

    // A rotated token registers itself. This is the one people forget by hand,
    // and the failure is silent: sends keep succeeding against a token the
    // device no longer has.
    fm.refresh.add('fcm-token-two');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(seen['/v1/devices'], hasLength(2));
    expect(seen['/v1/devices']!.last['token'], 'fcm-token-two');

    // The notification that cold-started the app was recorded as an open.
    await firstClick.future.timeout(const Duration(seconds: 2));
    expect(seen['/v1/push/click']!.single['m'], 'msg-1');
    expect(seen['/v1/push/click']!.single['d'], 'dev-1');

    // Attaching again does nothing, so a hot-reload or a second call in a
    // widget's initState cannot double-register.
    await Notibase.attachFirebase(fm);
    expect(fm.tokenReads, 1);
  });

  test('a tapped notification is sent to its url', () async {
    // The destination is the whole point of composing a message with a URL,
    // and on Flutter it is the one step the SDK cannot take by itself — so
    // what is pinned here is that the hook fires with the right value, on the
    // same path that reports the open.
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final base = 'http://127.0.0.1:${server.port}';
    server.listen((req) async {
      req.response.headers.contentType = ContentType.json;
      req.response.write('{}');
      await req.response.close();
    });
    addTearDown(() => server.close(force: true));

    final opened = <String>[];
    Notibase.onNotificationUrl = opened.add;
    addTearDown(() => Notibase.onNotificationUrl = null);

    await Notibase.trackNotificationOpen({
      'nb_m': 'msg-9',
      'nb_d': 'dev-9',
      'nb_o': base,
      'url': 'https://darlivo.test/drop/9',
    });
    expect(opened, ['https://darlivo.test/drop/9']);

    // No url on the message means nothing to open — not an empty-string call
    // that an app would have to guard against.
    await Notibase.trackNotificationOpen({'nb_m': 'm', 'nb_d': 'd', 'nb_o': base});
    expect(opened, hasLength(1));

    // Someone else's notification carries no Notibase keys, so it is not our
    // open to report — and not our destination to open either.
    await Notibase.trackNotificationOpen({'url': 'https://someone-else.test/'});
    expect(opened, hasLength(1));
  });

  test('a handler that throws does not take the app down', () async {
    Notibase.onNotificationUrl = (_) => throw StateError('router is not ready yet');
    addTearDown(() => Notibase.onNotificationUrl = null);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      req.response.write('{}');
      await req.response.close();
    });
    addTearDown(() => server.close(force: true));

    await Notibase.trackNotificationOpen({
      'nb_m': 'm',
      'nb_d': 'd',
      'nb_o': 'http://127.0.0.1:${server.port}',
      'url': 'https://darlivo.test/x',
    });
  });

  test('reads a campaign click id off a deep link', () {
    // The deterministic half of attribution, and the one input a stranger can
    // drive: anyone can open the app with any URL they like.
    expect(Notibase.clickIdFrom('https://darlivo.test/launch?nb_click=1742'), '1742');
    expect(Notibase.clickIdFrom('darlivo://open?utm_source=x&nb_click=9&z=1'), '9');
    expect(Notibase.clickIdFrom('https://x.test/a?NB_CLICK=9'), isNull);
    expect(Notibase.clickIdFrom('https://x.test/a#nb_click=9'), isNull);
    expect(Notibase.clickIdFrom('https://x.test/a'), isNull);
    expect(Notibase.clickIdFrom(null), isNull);
    expect(Notibase.clickIdFrom(''), isNull);
    expect(Notibase.clickIdFrom('https://x.test/a?nb_click='), isNull);
    // A click id is a bigint key on its way to a parameterised query.
    expect(Notibase.clickIdFrom('https://x.test/a?nb_click=1;DROP TABLE links'), isNull);
    expect(Notibase.clickIdFrom('https://x.test/a?nb_click=-1'), isNull);
    expect(Notibase.clickIdFrom('https://x.test/a?nb_click=${'9' * 40}'), isNull);
  });

  test('a message with no Notibase keys is not reported as an open', () async {
    // Apps hand us every notification they receive; someone else's push must
    // not turn into a click on a message id we never sent.
    var called = false;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      called = true;
      await req.response.close();
    });
    addTearDown(() => server.close(force: true));

    await Notibase.trackNotificationOpen({'title': 'from some other SDK'});
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(called, isFalse);
  });
}
