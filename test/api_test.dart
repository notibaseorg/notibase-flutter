/// Unit tests for the pure-Dart core — run on the VM with an in-process
/// mock HTTP server (dart:io HttpServer), no network, no Flutter bindings.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notibase_flutter/notibase_flutter.dart';

void main() {
  group('rich payload parsing', () {
    // The two platforms encode nb_buttons differently and neither choice was
    // ours: FCM data values must be strings, APNs payloads are JSON. A parser
    // that only handled one would work perfectly on the platform its author
    // happened to test on.
    test('Android: buttons arrive JSON-encoded in a string', () {
      final n = NotibaseNotification.parse({
        'nb_buttons': '[{"id":"yes","text":"Accept","url":"https://x.test/y"},{"id":"no","text":"Later"}]',
        'nb_m': 'msg-1',
      });
      expect(n.buttons, hasLength(2));
      expect(n.buttons.first.id, 'yes');
      expect(n.buttons.first.url, 'https://x.test/y');
      expect(n.buttons.last.url, isNull);
      expect(n.isNotibase, isTrue);
    });

    test('iOS: the same key arrives as a real list', () {
      final n = NotibaseNotification.parse({
        'nb_buttons': [
          {'id': 'yes', 'text': 'Accept'},
        ],
        'nb_m': 'msg-1',
      });
      expect(n.buttons, hasLength(1));
      expect(n.buttons.first.text, 'Accept');
    });

    test('media and large icon come through', () {
      final n = NotibaseNotification.parse({
        'nb_media': 'https://x.test/a.jpg',
        'nb_large_icon': 'https://x.test/i.png',
        'url': 'https://x.test/open',
      });
      expect(n.mediaUrl, 'https://x.test/a.jpg');
      expect(n.largeIconUrl, 'https://x.test/i.png');
      expect(n.url, 'https://x.test/open');
    });

    test('a foreign notification is recognisable and empty', () {
      final n = NotibaseNotification.parse({'some': 'other service'});
      expect(n.isNotibase, isFalse);
      expect(n.buttons, isEmpty);
    });

    test('malformed input costs the buttons, never the notification', () {
      for (final raw in <Object?>[
        'not json',
        '{"id":"a","text":"A"}', // object where an array belongs
        '',
        null,
        [
          {'text': 'no id'},
        ],
        [
          {'id': 'a', 'text': ''},
        ],
      ]) {
        expect(NotibaseNotification.parse({'nb_buttons': raw}).buttons, isEmpty,
            reason: 'input: $raw');
      }
    });

    test('one bad entry does not sink the rest', () {
      final n = NotibaseNotification.parse({
        'nb_buttons': [
          {'id': 'a', 'text': 'A'},
          'garbage',
          {'id': 'b', 'text': 'B'},
        ],
      });
      expect(n.buttons.map((b) => b.id), ['a', 'b']);
    });
  });

  group('key hygiene', () {
    test('sk_ key refused with a teaching error', () {
      expect(
        () => NotibaseApi('sk_live_oops'),
        throwsA(isA<ArgumentError>().having(
            (e) => e.message, 'message', contains('SERVER key'))),
      );
    });

    test('non-ck key refused', () {
      expect(() => NotibaseApi('random'), throwsA(isA<ArgumentError>()));
    });
  });

  group('against an in-process mock server', () {
    late HttpServer server;
    late String base;
    late List<HttpRequest> seen;
    late List<Map<String, dynamic> Function(HttpRequest)> handlers;

    setUp(() async {
      seen = [];
      handlers = [];
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = 'http://127.0.0.1:${server.port}';
      server.listen((req) async {
        seen.add(req);
        final handler = handlers.isNotEmpty ? handlers.removeAt(0) : null;
        final body = handler != null ? handler(req) : <String, dynamic>{};
        final status = body.remove('__status') as int? ?? 200;
        req.response.statusCode = status;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(body));
        await req.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('registerDevice sends auth header + payload, returns id', () async {
      handlers.add((req) => {'id': '00000000-0000-0000-0000-000000000001'});
      final api = NotibaseApi('ck_test_abc', apiUrl: base);
      final id = await api.registerDevice(
          token: 'fcm-tok', platform: 'android', locale: 'en_US');
      expect(id, '00000000-0000-0000-0000-000000000001');
      expect(seen.single.headers.value('authorization'), 'Bearer ck_test_abc');
      expect(seen.single.uri.path, '/v1/devices');
    });

    test('4xx surfaces as NotibaseException and is NOT retried', () async {
      handlers.add((req) => {'__status': 401, 'error': 'bad key'});
      final api = NotibaseApi('ck_test_abc', apiUrl: base);
      await expectLater(
        api.registerDevice(token: 't', platform: 'android'),
        throwsA(isA<NotibaseException>()
            .having((e) => e.statusCode, 'status', 401)
            .having((e) => e.message, 'message', 'bad key')),
      );
      expect(seen.length, 1); // exactly one attempt — 4xx never retried
    });

    test('429 then 200 → retried transparently', () async {
      handlers.add((req) => {'__status': 429, 'error': 'slow down'});
      handlers.add((req) => {'ok': true, 'accepted': 1});
      final api = NotibaseApi('ck_test_abc', apiUrl: base);
      await api.track('purchase',
          properties: {'value': 9.99}, deviceId: 'd-1');
      expect(seen.length, 2);
    });

    test('inbox parses items and tolerates junk rows', () async {
      handlers.add((req) => {
            'items': [
              {
                'id': 'i-1',
                'content': {'title': 'hi'},
                'read_at': null,
                'created_at': '2026-08-20T00:00:00Z',
              },
              {'garbage': true},
            ],
            'unread': 1,
          });
      final api = NotibaseApi('ck_test_abc', apiUrl: base);
      final items = await api.inboxList('d-1');
      expect(items.length, 1);
      expect(items.single.content['title'], 'hi');
      expect(items.single.readAt, isNull);
    });
  });
}
