/// E2E against the REAL Notibase API — run by apps/api/scripts/
/// e2e-flutter-core.mjs (which boots buildServer on PGlite and sets the
/// NB_* environment). Skips itself when the harness env is absent, so
/// plain `flutter test` stays green locally.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notibase_flutter/notibase_flutter.dart';

String hmacHex(String secret, String data) =>
    Hmac(sha256, utf8.encode(secret)).convert(utf8.encode(data)).toString();

Future<Map<String, dynamic>> serverPost(
    String apiUrl, String serverKey, String path, Object body) async {
  final client = HttpClient();
  final req = await client.postUrl(Uri.parse('$apiUrl$path'));
  req.headers.set('authorization', 'Bearer $serverKey');
  req.headers.contentType = ContentType.json;
  req.add(utf8.encode(jsonEncode(body)));
  final res = await req.close();
  final text = await res.transform(utf8.decoder).join();
  expect(res.statusCode, lessThan(400),
      reason: 'server POST $path → ${res.statusCode}: $text');
  return jsonDecode(text) as Map<String, dynamic>;
}

void main() {
  final env = Platform.environment;
  final apiUrl = env['NB_API_URL'];
  final skip = apiUrl == null
      ? 'harness env absent — run via apps/api/scripts/e2e-flutter-core.mjs'
      : null;

  test('full loop: register → identify (HMAC) → track → send → inbox → read',
      () async {
    final clientKey = env['NB_CLIENT_KEY']!;
    final serverKey = env['NB_SERVER_KEY']!;
    final identifySecret = env['NB_IDENTIFY_SECRET']!;
    final api = NotibaseApi(clientKey, apiUrl: apiUrl!);

    // invalid key → 401
    final bad = NotibaseApi('ck_live_definitely_not_valid_000000', apiUrl: apiUrl);
    await expectLater(
      bad.registerDevice(token: 'x-token-x', platform: 'android'),
      throwsA(isA<NotibaseException>().having((e) => e.statusCode, 's', 401)),
    );

    // register — idempotent
    final deviceId = await api.registerDevice(
        token: 'flutter-fcm-token-1', platform: 'android', locale: 'en_US');
    expect(deviceId.length, 36);
    final again = await api.registerDevice(
        token: 'flutter-fcm-token-1', platform: 'android');
    expect(again, deviceId);

    // identify: unsigned + forged → 403; signed → user id
    const externalId = 'flutter-user-1';
    await expectLater(
      api.identify(externalId: externalId, deviceId: deviceId),
      throwsA(isA<NotibaseException>().having((e) => e.statusCode, 's', 403)),
    );
    await expectLater(
      api.identify(
          externalId: externalId,
          deviceId: deviceId,
          signature: hmacHex('wrong-secret', externalId)),
      throwsA(isA<NotibaseException>().having((e) => e.statusCode, 's', 403)),
    );
    final userId = await api.identify(
        externalId: externalId,
        deviceId: deviceId,
        signature: hmacHex(identifySecret, externalId),
        attributes: {'tier': 'gold'});
    expect(userId.length, 36);

    // track
    await api.track('session_start', deviceId: deviceId);
    await api.track('level_complete',
        properties: {'level': 3, 'boss': true}, deviceId: deviceId);

    // send with inapp → poll inbox → markRead
    await serverPost(apiUrl, serverKey, '/v1/messages', {
      'audience': {'all': true},
      'content': {
        'title': 'Hello Flutter',
        'inapp': {'title': 'Hello Flutter', 'body': 'from the e2e'},
      },
    });
    var items = <InboxItem>[];
    for (var i = 0; i < 25; i++) {
      items = await api.inboxList(deviceId);
      if (items.isNotEmpty) break;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    expect(items.length, 1);
    expect(items.single.content['title'], 'Hello Flutter');
    expect(items.single.readAt, isNull);
    await api.inboxMarkRead(deviceId, [items.single.id]);
    final after = await api.inboxList(deviceId);
    expect(after.single.readAt, isNotNull);
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));
}
