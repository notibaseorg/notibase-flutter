/// The Google Play install referrer, which is the only thing that can carry
/// a campaign click into an Android store install.
///
/// The Play listing is a web page. It drops every query parameter it does
/// not recognise, so the `nb_click` on the link a person tapped never
/// reaches the app they end up installing — which left the server guessing
/// from a 24-hour IP window, and missing whenever the browser and the app
/// left the phone on different addresses. `referrer` is the one string Play
/// hands back, through Google's Install Referrer API on first launch.
///
/// A referrer is a bare query string, not a URL, which is the whole reason
/// it needs its own parser: `Uri.parse('nb_click=42')` reads that as a
/// *path* and finds no parameters at all. Getting that wrong is silent —
/// attribution simply never works and nothing says why — so it is pinned
/// here rather than left to the end-to-end test.
import 'package:flutter_test/flutter_test.dart';
import 'package:notibase_flutter/notibase_flutter.dart';

void main() {
  group('reading a click id out of an install referrer', () {
    test('finds it alone, and beside a campaign\'s own utm tags', () {
      expect(Notibase.clickIdFromReferrer('nb_click=42'), '42');
      // What the server actually writes: ours first, so a truncation from
      // the end loses their tags rather than the id.
      expect(
        Notibase.clickIdFromReferrer('nb_click=42&utm_source=newsletter'),
        '42',
      );
      expect(
        Notibase.clickIdFromReferrer('utm_source=x&nb_click=42&utm_medium=y'),
        '42',
      );
      // Play percent-encodes the value it stored; splitQueryString decodes.
      expect(Notibase.clickIdFromReferrer('nb_click%3D42'), isNull);
    });

    test('says nothing for an organic install', () {
      // The referrer Play returns when nobody sent the person anywhere:
      // this must be a no-op, not a warning and not a bad attribution.
      expect(
        Notibase.clickIdFromReferrer('utm_source=google-play&utm_medium=organic'),
        isNull,
      );
      expect(Notibase.clickIdFromReferrer(''), isNull);
      expect(Notibase.clickIdFromReferrer(null), isNull);
    });

    test('refuses anything that is not a plain number', () {
      // The value is a bigint primary key on its way to a parameterised
      // query, and a referrer is a stranger's input in exactly the way a
      // deep link is: anyone can install from any referrer they like.
      expect(Notibase.clickIdFromReferrer('nb_click=1 OR 1=1'), isNull);
      expect(Notibase.clickIdFromReferrer('nb_click=abc'), isNull);
      expect(Notibase.clickIdFromReferrer('nb_click=-1'), isNull);
      expect(Notibase.clickIdFromReferrer('nb_click=4.2'), isNull);
      expect(Notibase.clickIdFromReferrer('nb_click='), isNull);
      // Longer than any bigint, so it cannot be one.
      expect(Notibase.clickIdFromReferrer('nb_click=${'9' * 20}'), isNull);
      expect(Notibase.clickIdFromReferrer('nb_click=${'9' * 19}'), '9' * 19);
    });

    test('survives a malformed referrer without throwing', () {
      // Never crash the host app (Arch §8.2). This runs on a launch path.
      expect(Notibase.clickIdFromReferrer('%%%'), isNull);
      expect(Notibase.clickIdFromReferrer('&&&'), isNull);
      expect(Notibase.clickIdFromReferrer('nb_click'), isNull);
    });
  });

  group('a referrer is not a URL, and a URL is not a referrer', () {
    test('the URL parser cannot read a referrer, which is why both exist', () {
      // The mistake this guards against: reusing clickIdFrom for the
      // referrer looks right, compiles, and silently never matches —
      // `Uri.parse` reads a bare query string as a path.
      expect(Notibase.clickIdFrom('nb_click=42'), isNull);
      expect(Notibase.clickIdFromReferrer('nb_click=42'), '42');
    });

    test('and the referrer parser is not used for deep links', () {
      expect(Notibase.clickIdFrom('darlivo://open?nb_click=42'), '42');
      expect(Notibase.clickIdFrom('https://x.test/launch?nb_click=42'), '42');
      // A whole URL handed to the referrer parser finds nothing, because
      // the scheme and host are not query parameters.
      expect(Notibase.clickIdFromReferrer('https://x.test/?nb_click=42'), isNull);
    });
  });
}
