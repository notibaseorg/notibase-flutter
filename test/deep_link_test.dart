/// Handing the same deep link in twice.
///
/// This is not a theoretical case. A cold start from a campaign link
/// delivers the URL twice on both platforms — once from the initial-link
/// read and once from the link stream — and most routers call the handler on
/// every redirect evaluation as well. The de-duplication has to survive
/// that, and it did not: it was checking the *pending* click id, which is
/// deleted as soon as its id has been attached to an event, so the guard
/// stopped working the moment it had done its job. The second call reported
/// a second session and re-credited the campaign that produced the install.
///
/// Its own file because `configure` is one-shot per process by design.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notibase_flutter/notibase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the same campaign link is acted on once, however often it arrives', () async {
    // A returning install: a device already registered, and the install event
    // already reported. That is the state a deep link actually arrives in.
    SharedPreferences.setMockInitialValues({
      'nb_device_id': '00000000-0000-0000-0000-0000000000d1',
      'nb_install_reported': true,
    });

    final events = <Map<String, dynamic>>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final base = 'http://127.0.0.1:${server.port}';
    server.listen((req) async {
      final raw = await utf8.decoder.bind(req).join();
      if (req.uri.path == '/v1/events') {
        events.add(raw.isEmpty
            ? <String, dynamic>{}
            : jsonDecode(raw) as Map<String, dynamic>);
      }
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({'id': '00000000-0000-0000-0000-000000000001'}));
      await req.response.close();
    });
    addTearDown(() => server.close(force: true));

    await Notibase.configure('ck_test_deeplink', apiUrl: base);
    // configure reports the cold start; that one is not what is being counted.
    await Future<void>.delayed(const Duration(milliseconds: 80));
    events.clear();

    const url = 'darlivo://open?nb_click=1742';
    await Notibase.handleDeepLink(url);
    await Notibase.handleDeepLink(url);
    await Notibase.handleDeepLink(url);
    await Future<void>.delayed(const Duration(milliseconds: 120));

    // One event, not three. Three would be three sessions in the console and
    // one campaign credited three times for the same install.
    expect(events, hasLength(1));
    expect(events.single['name'], 'session_start');
    expect(
      (events.single['properties'] as Map<String, dynamic>)['nb_click'],
      '1742',
    );

    // A genuinely different campaign still gets through — the guard
    // de-duplicates a repeat, it does not latch shut.
    await Notibase.handleDeepLink('darlivo://open?nb_click=1743');
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(events, hasLength(2));
    expect(
      (events.last['properties'] as Map<String, dynamic>)['nb_click'],
      '1743',
    );
  });
}
