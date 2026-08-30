/// The three decisions an in-app message leaves to the device.
///
/// The API hands over rules it has already filtered by status, display
/// window and segment. What is left is the part no server can answer — has
/// the trigger fired, has this person seen it enough, has the gap elapsed —
/// and it has to give the same answers the web, Android and iOS SDKs give,
/// or one campaign means two things.
///
/// All of it runs on the VM: `in_app.dart` has no Flutter import, which is
/// the point of the file existing separately from the widget.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:notibase_flutter/notibase_flutter.dart';

void main() {
  group('comparing a trigger', () {
    test('numbers compare as numbers', () {
      expect(InAppTriggers.compare(240, 'gt', 100), isTrue);
      expect(InAppTriggers.compare(40, 'gt', 100), isFalse);
      expect(InAppTriggers.compare(100.0, 'eq', 100), isTrue);
      expect(InAppTriggers.compare(99, 'lte', 100), isTrue);
    });

    test('a string is never compared against a number', () {
      // The same refusal the other three SDKs make. A value that sometimes
      // arrives as a string should show up as a message that did not fire,
      // not one that fired for the wrong people.
      expect(InAppTriggers.compare('240', 'gt', 100), isFalse);
      expect(InAppTriggers.compare('100', 'eq', 100), isFalse);
    });

    test('a boolean is not the number one', () {
      expect(InAppTriggers.compare(true, 'gt', 0), isFalse);
      expect(InAppTriggers.compare(true, 'eq', true), isTrue);
    });

    test('exists is about presence, not value', () {
      expect(InAppTriggers.compare(null, 'exists', null), isFalse);
      expect(InAppTriggers.compare(false, 'exists', null), isTrue);
      expect(InAppTriggers.compare(null, 'gt', 100), isFalse);
    });
  });

  group('whether a trigger has fired', () {
    test('app_open always has', () {
      expect(InAppTriggers.satisfied({'kind': 'app_open'}, {}, 1), isTrue);
    });

    test('session_count counts launches', () {
      final t = {'kind': 'session_count', 'op': 'gte', 'value': 3};
      expect(InAppTriggers.satisfied(t, {}, 3), isTrue);
      expect(InAppTriggers.satisfied(t, {}, 2), isFalse);
    });

    test('an event trigger reads the value the app set', () {
      final t = {'kind': 'event', 'key': 'cart_value', 'op': 'gt', 'value': 100};
      expect(InAppTriggers.satisfied(t, {'cart_value': 240}, 1), isTrue);
      expect(InAppTriggers.satisfied(t, {'cart_value': 40}, 1), isFalse);
      expect(InAppTriggers.satisfied(t, {}, 1), isFalse);
    });

    test('a kind from a newer console does not fire', () {
      // Showing it would mean ignoring a condition somebody deliberately
      // set, which is worse than not showing it at all.
      expect(InAppTriggers.satisfied({'kind': 'phase_of_moon'}, {}, 1), isFalse);
    });
  });

  group('how often somebody sees it', () {
    const json = '''
    {"id":"m1","layout":"center","content":{"blocks":[
      {"type":"text","text":"hi","size":16,"weight":"bold","align":"center"}],
      "style":{"bg":"#fff","radius":16,"padding":24},"dismissible":true},
     "trigger":{"kind":"app_open"},"max_displays":2,"min_gap_seconds":3600}''';

    String? store;
    InAppMemory memory() =>
        InAppMemory(load: () => store, save: (v) => store = v);

    setUp(() => store = null);

    test('the cap and the gap are both enforced here', () {
      final rule = InAppParse.rule(jsonDecode(json));
      expect(rule, isNotNull);
      final rules = [rule!];
      var now = 1000000000000;

      expect(InAppPicker.choose(
        rules: rules, memory: memory(), triggers: {}, sessions: 1, now: now,
      )?.id, 'm1');

      memory().record('m1', now);
      expect(InAppPicker.choose(
        rules: rules, memory: memory(), triggers: {}, sessions: 1, now: now,
      ), isNull, reason: 'showed again inside the gap');

      now += 3600001;
      expect(InAppPicker.choose(
        rules: rules, memory: memory(), triggers: {}, sessions: 1, now: now,
      )?.id, 'm1', reason: 'did not show once the gap had passed');

      memory().record('m1', now);
      now += 10 * 3600000;
      expect(InAppPicker.choose(
        rules: rules, memory: memory(), triggers: {}, sessions: 1, now: now,
      ), isNull, reason: 'the display limit did not hold');
    });

    test('the count survives the process', () {
      // The whole point of writing it down: an app reopened tomorrow must
      // remember it showed this today.
      memory().record('m1', 1);
      memory().record('m1', 2);
      expect(memory().count('m1'), 2);
      expect(store, isNotNull);
    });

    test('shows one message, not every eligible one', () {
      // Two messages stacked on each other is the failure mode this feature
      // has, and "the newest wins" is a rule nobody could predict.
      final a = InAppParse.rule(jsonDecode(json.replaceAll('"m1"', '"a"')))!;
      final b = InAppParse.rule(jsonDecode(json.replaceAll('"m1"', '"b"')))!;
      expect(InAppPicker.choose(
        rules: [a, b], memory: memory(), triggers: {}, sessions: 1, now: 1,
      )?.id, 'a');
    });
  });

  group('reading a rule off the wire', () {
    test('a rule with nothing to draw is not a rule', () {
      expect(InAppParse.rule(jsonDecode('{"id":"x","content":{"blocks":[]}}')), isNull);
      expect(InAppParse.rule('not an object'), isNull);
    });

    test('a block type we cannot draw is dropped, not guessed', () {
      final rule = InAppParse.rule(jsonDecode('''
        {"id":"x","layout":"top","content":{"blocks":[
          {"type":"hologram"},{"type":"text","text":"still here","size":14}]},
         "trigger":{"kind":"app_open"}}'''));
      expect(rule!.blocks, hasLength(1));
      expect(rule.blocks.first.text, 'still here');
      expect(rule.layout, 'top');
    });

    test('a message with no dismissible field keeps its close button', () {
      // A message that loses its way out to a parsing gap is one somebody
      // cannot escape.
      final rule = InAppParse.rule(jsonDecode('''
        {"id":"x","content":{"blocks":[{"type":"text","text":"hi"}]}}'''));
      expect(rule!.dismissible, isTrue);
      expect(rule.maxDisplays, isNull, reason: 'absent should mean unlimited');
      expect(rule.minGapSeconds, 0);
    });

    test('a button with no action still closes the message', () {
      final rule = InAppParse.rule(jsonDecode('''
        {"id":"x","content":{"blocks":[{"type":"button","label":"OK"}]}}'''));
      expect(rule!.blocks.first.action!.kind, 'dismiss');
    });
  });
}
