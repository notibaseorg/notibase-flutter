/// Drawing an in-app message, as ordinary widgets.
///
/// Every block becomes a real widget — Text, Image.network, a button — so a
/// message inherits the app's own rendering and there is no WebView
/// anywhere. That is the whole reason a message is a block document rather
/// than the HTML somebody typed into a console: nothing here can turn
/// message copy into code running inside a customer's app.
///
/// The decisions — which message, whether it may be shown, how often — are
/// in `in_app.dart`, which has no Flutter import and is exercised on the
/// Dart VM. This file only draws.
library;

import 'package:flutter/material.dart';

import 'in_app.dart';

/// The message itself. Pushed as a route so the app's own back handling,
/// theming and accessibility apply to it without any of it being reinvented.
class NotibaseInAppView extends StatelessWidget {
  const NotibaseInAppView({
    super.key,
    required this.rule,
    required this.onAction,
    required this.onDismiss,
  });

  final InAppRule rule;
  final void Function(InAppAction action) onAction;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final full = rule.layout == 'full';
    final card = Container(
      constraints: full ? null : const BoxConstraints(maxWidth: 420),
      padding: EdgeInsets.all(rule.style.padding.toDouble()),
      decoration: BoxDecoration(
        color: _colour(rule.style.bg) ?? Colors.white,
        borderRadius:
            full ? null : BorderRadius.circular(rule.style.radius.toDouble()),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (rule.dismissible)
            Align(
              alignment: Alignment.centerRight,
              child: IconButton(
                icon: const Icon(Icons.close, size: 20),
                color: Colors.grey,
                tooltip: 'Close',
                onPressed: onDismiss,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ),
          ...rule.blocks.map(_widgetFor),
        ],
      ),
    );

    final scrollable = SingleChildScrollView(
      child: full
          ? SizedBox(height: MediaQuery.of(context).size.height, child: card)
          : card,
    );

    return Material(
      // Written as a literal rather than as black.withOpacity(0.45). The
      // opacity helpers are the thing that moved: withOpacity is deprecated
      // from Flutter 3.27, and withValues does not exist before it, so
      // either spelling is wrong on half the range this package supports.
      // 0x73 is 0.45 of 255. A constant needs neither.
      color: const Color(0x73000000),
      child: SafeArea(
        // A tap on the scrim closes it; a tap on the message does not. The
        // second half is why the card sits behind its own gesture detector
        // that swallows the tap rather than relying on hit-test order.
        child: GestureDetector(
          onTap: rule.dismissible ? onDismiss : null,
          child: Align(
            alignment: _alignment(),
            child: Padding(
              padding: EdgeInsets.all(full ? 0 : 16),
              child: GestureDetector(onTap: () {}, child: scrollable),
            ),
          ),
        ),
      ),
    );
  }

  Alignment _alignment() {
    switch (rule.layout) {
      case 'top':
        return Alignment.topCenter;
      case 'bottom':
        return Alignment.bottomCenter;
      default:
        return Alignment.center;
    }
  }

  Widget _widgetFor(InAppBlock b) {
    switch (b.type) {
      case 'text':
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            b.text,
            textAlign: b.align == 'left'
                ? TextAlign.left
                : (b.align == 'right' ? TextAlign.right : TextAlign.center),
            style: TextStyle(
              fontSize: b.size.toDouble(),
              fontWeight: b.bold ? FontWeight.bold : FontWeight.normal,
              color: _colour(b.color) ?? const Color(0xFF111111),
            ),
          ),
        );
      case 'image':
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Image.network(
              b.url,
              height: b.height?.toDouble(),
              fit: BoxFit.cover,
              semanticLabel: b.alt,
              // A picture that will not load is not a reason to fail the
              // message: the words are the message, the image is decoration.
              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
            ),
          ),
        );
      case 'spacer':
        return SizedBox(height: (b.height ?? 12).toDouble());
      case 'button':
        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: TextButton(
            style: TextButton.styleFrom(
              backgroundColor: _colour(b.bg) ?? const Color(0xFF111111),
              foregroundColor: _colour(b.color) ?? Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(b.radius.toDouble()),
              ),
            ),
            // Every press closes the message; the caller does the closing so
            // it happens once, on the same path as everything else.
            onPressed: () => onAction(b.action ?? const InAppAction('dismiss')),
            child: Text(
              b.label,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
            ),
          ),
        );
      default:
        return const SizedBox.shrink();
    }
  }

  /// `#rgb`, `#rrggbb` or `#rrggbbaa` from the console; null for anything else.
  static Color? _colour(String? value) {
    if (value == null || !value.startsWith('#')) return null;
    var hex = value.substring(1);
    if (hex.length == 3) {
      hex = hex.split('').map((c) => '$c$c').join();
    }
    // The console writes #rrggbb or #rrggbbaa; Flutter reads 0xaarrggbb.
    if (hex.length == 6) {
      hex = 'ff$hex';
    } else if (hex.length == 8) {
      hex = hex.substring(6) + hex.substring(0, 6);
    } else {
      return null;
    }
    final n = int.tryParse(hex, radix: 16);
    return n == null ? null : Color(n);
  }
}
