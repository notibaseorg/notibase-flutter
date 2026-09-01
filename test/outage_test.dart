/// What this SDK does when Notibase is unreachable.
///
/// The rule the whole package is supposed to follow is that our outage is
/// never the customer's outage. This file is the one that checks it, because
/// it is the property most easily lost by accident: an `await` in front of a
/// network call reads as tidier code and turns a blank screen into a
/// two-minute blank screen.
///
/// The tests drive a server that **accepts the connection and never
/// answers**. That is the failure mode that matters — a refused connection
/// fails in milliseconds and would hide the bug, while a black hole is what a
/// struggling load balancer, a saturated host and a DNS timeout all look like
/// from inside a phone.
///
/// Its own file: `configure` is one-shot by design, so it needs a process
/// where it has not run yet.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notibase_flutter/notibase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A server that completes the handshake and then says nothing, ever.
class BlackHole {
  BlackHole._(this._server, this._held);

  final HttpServer _server;
  final List<HttpRequest> _held;

  String get url => 'http://127.0.0.1:${_server.port}';

  static Future<BlackHole> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final held = <HttpRequest>[];
    server.listen(held.add); // never responds, never closes
    return BlackHole._(server, held);
  }

  /// Let the held requests fail so nothing is still in flight at teardown.
  Future<void> stop() async {
    for (final r in _held) {
      try {
        await r.response.close();
      } catch (_) {/* already gone */}
    }
    await _server.close(force: true);
  }
}

/// A port with nothing behind it — the other half of "unreachable".
Future<String> deadPort() async {
  final probe = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final url = 'http://127.0.0.1:${probe.port}';
  await probe.close(force: true);
  return url;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('configure() returns immediately when the API is a black hole', () async {
    // The returning-user path — a token cached from a previous launch — is
    // every launch after the first, and it is the one that used to await a
    // device registration through a three-attempt retry chain. An app that
    // calls this in main() before runApp(), as our own docs say to, showed
    // nothing at all until that chain gave up.
    SharedPreferences.setMockInitialValues(
        {'nb_push_token': 'fcm-token-from-last-launch'});
    final hole = await BlackHole.start();
    addTearDown(hole.stop);

    final watch = Stopwatch()..start();
    await Notibase.configure('ck_test_outage', apiUrl: hole.url);
    watch.stop();

    // Generous on purpose: what is pinned is "does not wait for the
    // network", not a millisecond budget. The old behaviour was fifteen
    // seconds at the very best and about two minutes at worst.
    expect(watch.elapsed, lessThan(const Duration(seconds: 2)),
        reason: 'configure() must not await a network round-trip');
  });

  test('a notification tap opens its URL before the beacon is answered', () async {
    // The beacon is a metric. The tap is a person. Awaiting the beacon in
    // front of the navigation meant that during an outage the app opened and
    // then sat there, going nowhere, until DNS or TCP gave up.
    final hole = await BlackHole.start();
    addTearDown(hole.stop);
    final opened = <String>[];
    Notibase.onNotificationUrl = opened.add;
    addTearDown(() => Notibase.onNotificationUrl = null);

    final watch = Stopwatch()..start();
    await Notibase.trackNotificationOpen({
      'nb_m': 'msg-1',
      'nb_d': 'dev-1',
      'nb_o': hole.url,
      'url': 'https://darlivo.test/drop/1',
    });
    watch.stop();

    expect(opened, ['https://darlivo.test/drop/1']);
    expect(watch.elapsed, lessThan(const Duration(seconds: 2)),
        reason: 'the destination must not wait on the click beacon');
  });

  test('a beacon to a dead port is silent, and the tap still lands', () async {
    final dead = await deadPort();
    final opened = <String>[];
    Notibase.onNotificationUrl = opened.add;
    addTearDown(() => Notibase.onNotificationUrl = null);

    await Notibase.trackNotificationOpen({
      'nb_m': 'msg-2',
      'nb_d': 'dev-2',
      'nb_o': dead,
      'url': 'https://darlivo.test/drop/2',
    });
    expect(opened, ['https://darlivo.test/drop/2']);

    // Give the unawaited beacon a moment to fail on its own. If it threw
    // into the zone rather than swallowing, the run reports it here.
    await Future<void>.delayed(const Duration(milliseconds: 300));
  });
}
