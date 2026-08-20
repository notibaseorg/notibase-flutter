/// Unit tests for the pure-Dart core — run on the VM with an in-process
/// mock HTTP server (dart:io HttpServer), no network, no Flutter bindings.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notibase_flutter/notibase_flutter.dart';

void main() {
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
