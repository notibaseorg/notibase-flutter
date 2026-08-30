/// Which push service a token belongs to, and saying so.
///
/// On an iPhone `firebase_messaging` will hand you either of two tokens and
/// the difference decides how the message is delivered. `getToken()` returns
/// Google's, which means Firebase relays to Apple using the key uploaded to
/// the Firebase project. `getAPNSToken()` returns Apple's own, which
/// Notibase delivers to directly.
///
/// The SDK used to register the first one and declare it `fcm`, the server
/// used to ignore the declaration and route iOS to Apple, and so a Google
/// token was posted to Apple on every send. Apple answered `BadDeviceToken`
/// and the console reported a dead device. Nothing anywhere was red.
///
/// So what is pinned here is the half of the contract that lives in this
/// package: when the caller knows which service issued a token, that travels
/// with it, and it is remembered — because `configure` re-registers from the
/// cache on every launch after the first, and a forgotten channel there
/// would reintroduce the whole bug on the second run of the app.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notibase_flutter/notibase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a token carries the service that issued it, and is remembered', () async {
    SharedPreferences.setMockInitialValues({});

    final bodies = <Map<String, dynamic>>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final raw = await utf8.decoder.bind(req).join();
      if (req.uri.path == '/v1/devices' && raw.isNotEmpty) {
        bodies.add(jsonDecode(raw) as Map<String, dynamic>);
      }
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({'id': '00000000-0000-0000-0000-000000000002'}));
      await req.response.close();
    });
    addTearDown(() => server.close(force: true));

    await Notibase.configure('ck_test_channel',
        apiUrl: 'http://127.0.0.1:${server.port}');

    // An explicit channel is still honoured — it is the escape hatch for a
    // channel this SDK has not heard of.
    await Notibase.registerPushToken('a' * 64, channel: 'apns');
    expect(bodies, hasLength(1));
    expect(bodies.single['token'], 'a' * 64);
    expect(bodies.single['channel'], 'apns');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('nb_push_token'), 'a' * 64);

    // These tests run on the host VM, where `Platform.isIOS` is false, so
    // what is provable here is the other half of the contract: off iOS the
    // channel is left out entirely and the server routes by platform.
    // Android is always FCM and the web is always web push — naming either
    // would be a second copy of a fact the platform already carries.
    await Notibase.registerPushToken('some-other-token');
    expect(bodies, hasLength(2));
    expect(bodies.last.containsKey('channel'), isFalse);
  });

  test('an iOS token is read, not asked about', () {
    // The SDK's own rule, called directly — the host VM cannot be an
    // iPhone, so going through registerPushToken would exercise the
    // Android branch and prove nothing about iOS.
    //
    // An APNs device token is 32 bytes hex-encoded; an FCM registration
    // token is several times longer and carries a colon. So the shape is
    // not a hint about the channel, it is the only channel that could ever
    // deliver to that address — which is why reading it is safe and why
    // the server enforces the same rule from the channel's own manifest.
    final apns = 'c3' * 32;
    final fcm = 'dQw4w9WgXcQ:APA91b' + 'H' * 140;

    expect(Notibase.channelForToken('ios', apns), 'apns');
    expect(Notibase.channelForToken('ios', apns.toUpperCase()), 'apns');
    expect(Notibase.channelForToken('ios', '  \$apns  '), 'apns');
    expect(Notibase.channelForToken('ios', fcm), 'fcm');
    // 64 characters but not hexadecimal — length alone is not the test.
    expect(Notibase.channelForToken('ios', 'z' * 64), 'fcm');
    // …and one character past the APNs length is not an APNs token.
    expect(Notibase.channelForToken('ios', apns + 'a'), 'fcm');

    // Android is always FCM and the web is always web push, which the
    // platform already says. Naming it here would be a second copy of a
    // fact that can then disagree with the first.
    expect(Notibase.channelForToken('android', fcm), isNull);
    expect(Notibase.channelForToken('android', apns), isNull);
    expect(Notibase.channelForToken('web', 'https://push/x'), isNull);
  });
}
