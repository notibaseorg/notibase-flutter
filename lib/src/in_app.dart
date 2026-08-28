/// In-app messages: the decisions, with no Flutter in them.
///
/// An in-app message is a rule, not a send. The API hands over the ones this
/// device is eligible for — already filtered by status, display window and
/// segment — and everything left is a question only the device can answer:
/// has the trigger fired, has this person seen it enough times, has the gap
/// elapsed.
///
/// Those three answers are the whole feature and the part that breaks, so
/// they live here, with no `package:flutter` import, which is what lets the
/// Dart VM run them under `flutter test` and the e2e harness. Drawing the
/// message is `in_app_view.dart`.
///
/// The rules match the web, Android and iOS SDKs exactly, including their
/// refusal to compare across types. A customer who writes "cart_value over
/// 100" in one console must get one answer on every platform.
library;

import 'dart:convert';

/// What a button does. [kind] is closed; an unknown one does nothing.
class InAppAction {
  const InAppAction(this.kind, {this.url, this.key, this.value, this.name});

  final String kind;
  final String? url;
  final String? key;
  final Object? value;
  final String? name;
}

/// One piece of a message. [type] is text, image, button or spacer.
class InAppBlock {
  const InAppBlock({
    required this.type,
    this.text = '',
    this.size = 16,
    this.bold = false,
    this.align = 'center',
    this.color,
    this.url = '',
    this.alt = '',
    this.height,
    this.label = '',
    this.action,
    this.bg,
    this.radius = 8,
  });

  final String type;
  // text
  final String text;
  final int size;
  final bool bold;
  final String align;
  final String? color;
  // image
  final String url;
  final String alt;
  final int? height;
  // button
  final String label;
  final InAppAction? action;
  final String? bg;
  final int radius;
}

class InAppStyle {
  const InAppStyle({this.bg = '#ffffff', this.radius = 16, this.padding = 24});

  final String bg;
  final int radius;
  final int padding;
}

class InAppRule {
  const InAppRule({
    required this.id,
    required this.layout,
    required this.blocks,
    required this.style,
    required this.dismissible,
    required this.trigger,
    required this.maxDisplays,
    required this.minGapSeconds,
  });

  final String id;

  /// top | center | bottom | full
  final String layout;
  final List<InAppBlock> blocks;
  final InAppStyle style;
  final bool dismissible;
  final Map<String, dynamic> trigger;

  /// Null is unlimited.
  final int? maxDisplays;
  final int minGapSeconds;
}

/// Turning what the API said into something we can draw.
class InAppParse {
  InAppParse._();

  /// One rule off the wire, or null if it is a shape we do not understand.
  static InAppRule? rule(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final content = raw['content'];
    if (id is! String || content is! Map) return null;
    final rawBlocks = content['blocks'];
    if (rawBlocks is! List) return null;
    final blocks = <InAppBlock>[];
    for (final b in rawBlocks) {
      final parsed = _block(b);
      if (parsed != null) blocks.add(parsed);
    }
    if (blocks.isEmpty) return null;
    final style = content['style'];
    return InAppRule(
      id: id,
      layout: raw['layout'] as String? ?? 'center',
      blocks: blocks,
      style: InAppStyle(
        bg: (style is Map ? style['bg'] as String? : null) ?? '#ffffff',
        radius: (style is Map ? asInt(style['radius']) : null) ?? 16,
        padding: (style is Map ? asInt(style['padding']) : null) ?? 24,
      ),
      // Absent means dismissible. A message that loses its close button to
      // a parsing gap is one somebody cannot escape.
      dismissible: content['dismissible'] as bool? ?? true,
      trigger: (raw['trigger'] as Map?)?.cast<String, dynamic>() ??
          <String, dynamic>{'kind': 'app_open'},
      maxDisplays: asInt(raw['max_displays']),
      minGapSeconds: asInt(raw['min_gap_seconds']) ?? 0,
    );
  }

  static InAppBlock? _block(Object? raw) {
    if (raw is! Map) return null;
    switch (raw['type']) {
      case 'text':
        final text = raw['text'];
        if (text is! String) return null;
        return InAppBlock(
          type: 'text',
          text: text,
          size: asInt(raw['size']) ?? 16,
          bold: raw['weight'] == 'bold',
          align: raw['align'] as String? ?? 'center',
          color: raw['color'] as String?,
        );
      case 'image':
        final url = raw['url'];
        if (url is! String) return null;
        return InAppBlock(
          type: 'image',
          url: url,
          alt: raw['alt'] as String? ?? '',
          height: asInt(raw['height']),
        );
      case 'button':
        final label = raw['label'];
        if (label is! String) return null;
        return InAppBlock(
          type: 'button',
          label: label,
          action: _action(raw['action']) ?? const InAppAction('dismiss'),
          bg: raw['bg'] as String?,
          color: raw['color'] as String?,
          radius: asInt(raw['radius']) ?? 8,
        );
      case 'spacer':
        return InAppBlock(type: 'spacer', height: asInt(raw['height']) ?? 12);
      default:
        // A block type from a console newer than this SDK. Dropped rather
        // than guessed: a placeholder for something we cannot draw puts a
        // hole in somebody's campaign.
        return null;
    }
  }

  static InAppAction? _action(Object? raw) {
    if (raw is! Map) return null;
    final kind = raw['kind'];
    if (kind is! String) return null;
    return InAppAction(
      kind,
      url: raw['url'] as String?,
      key: raw['key'] as String?,
      value: raw['value'],
      name: raw['name'] as String?,
    );
  }

  /// A JSON number as an int, whichever way it decoded.
  static int? asInt(Object? v) {
    if (v is int) return v;
    if (v is double) return v.toInt();
    return null;
  }
}

/// Comparing a trigger against what the app told us.
class InAppTriggers {
  InAppTriggers._();

  /// 100 and 100.0 are the same number; "100" is not that number.
  static bool _same(Object? left, Object? right) {
    if (left is num && right is num) return left.toDouble() == right.toDouble();
    return left == right;
  }

  /// The same comparison the other three SDKs make, deliberately including
  /// what it refuses to do.
  ///
  /// A trigger set to the string "100" does not satisfy `over 100`. A
  /// customer whose values sometimes arrive as strings should find that out
  /// from a message that did not fire, not from one that fired for the wrong
  /// people — and two SDKs disagreeing about it would be worse than either
  /// answer.
  ///
  /// Dart makes this easier than the other platforms: `true is num` is
  /// false here, where a JSON boolean on iOS is an NSNumber and needs
  /// keeping out by hand.
  static bool compare(Object? left, String op, Object? right) {
    if (op == 'exists') return left != null;
    if (left == null) return false;
    if (op == 'eq') return _same(left, right);
    if (op == 'neq') return !_same(left, right);
    if (left is! num || right is! num) return false;
    final a = left.toDouble();
    final b = right.toDouble();
    switch (op) {
      case 'gt':
        return a > b;
      case 'gte':
        return a >= b;
      case 'lt':
        return a < b;
      case 'lte':
        return a <= b;
      default:
        return false;
    }
  }

  static bool satisfied(
    Map<String, dynamic> trigger,
    Map<String, Object?> values,
    int sessions,
  ) {
    switch (trigger['kind']) {
      case 'app_open':
        return true;
      case 'session_count':
        return compare(sessions, trigger['op'] as String? ?? '', trigger['value']);
      case 'event':
        return compare(
          values[trigger['key'] as String? ?? ''],
          trigger['op'] as String? ?? '',
          trigger['value'],
        );
      default:
        // A kind authored by a console newer than this SDK. Not showing it
        // is the only safe reading — showing it would mean ignoring a
        // condition somebody deliberately set.
        return false;
    }
  }
}

/// How often each message has been shown on THIS device.
///
/// Device-local on purpose, and the cost is worth writing down: a reinstall
/// forgets, and two devices belonging to one person count separately. Both
/// err towards showing a message again, which a person can dismiss — where
/// asking a server on every launch would put a network call in front of
/// every cold start, and an app opened on a train would show nothing.
///
/// Reading and writing are callbacks so this file needs no
/// shared_preferences either, and a test can drive it with a string.
class InAppMemory {
  InAppMemory({required String? Function() load, required void Function(String) save})
      : _load = load,
        _save = save;

  final String? Function() _load;
  final void Function(String) _save;
  final Map<String, int> _counts = {};
  final Map<String, int> _lastAt = {};
  bool _loaded = false;

  void _hydrate() {
    if (_loaded) return;
    _loaded = true;
    final raw = _load();
    if (raw == null) return;
    Object? parsed;
    try {
      parsed = jsonDecode(raw);
    } catch (_) {
      return;
    }
    if (parsed is! Map) return;
    parsed.forEach((key, value) {
      if (value is! Map) return;
      _counts[key as String] = InAppParse.asInt(value['n']) ?? 0;
      _lastAt[key] = InAppParse.asInt(value['at']) ?? 0;
    });
  }

  int count(String id) {
    _hydrate();
    return _counts[id] ?? 0;
  }

  int lastShownAt(String id) {
    _hydrate();
    return _lastAt[id] ?? 0;
  }

  /// Recorded before the message is drawn, never after.
  ///
  /// Somebody who kills the app the instant a message appears has still
  /// seen it. A counter that only advances on a clean dismissal shows the
  /// same message every launch to whoever closes it fastest.
  void record(String id, int now) {
    _hydrate();
    _counts[id] = (_counts[id] ?? 0) + 1;
    _lastAt[id] = now;
    final out = <String, dynamic>{};
    _counts.forEach((key, n) {
      out[key] = <String, dynamic>{'n': n, 'at': _lastAt[key] ?? 0};
    });
    _save(jsonEncode(out));
  }
}

/// Choosing which message, if any, to show.
class InAppPicker {
  InAppPicker._();

  /// The first rule this device may show, or none.
  ///
  /// First, not all of them: two messages stacked on each other is the
  /// failure mode this feature has, and "the newest wins" is a rule nobody
  /// could predict from the console. The API returns them oldest first, so
  /// the oldest eligible campaign shows and the rest wait for the next open.
  static InAppRule? choose({
    required List<InAppRule> rules,
    required InAppMemory memory,
    required Map<String, Object?> triggers,
    required int sessions,
    required int now,
  }) {
    for (final rule in rules) {
      final cap = rule.maxDisplays;
      if (cap != null && memory.count(rule.id) >= cap) continue;
      if (rule.minGapSeconds > 0 &&
          now - memory.lastShownAt(rule.id) < rule.minGapSeconds * 1000) {
        continue;
      }
      if (!InAppTriggers.satisfied(rule.trigger, triggers, sessions)) continue;
      return rule;
    }
    return null;
  }
}
