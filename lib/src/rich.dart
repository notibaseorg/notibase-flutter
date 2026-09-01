/// Reading the rich parts of a Notibase payload.
///
/// `notibase_flutter` is pure Dart with no platform channels, so it does not
/// render notifications — `firebase_messaging` and the OS do. What it can do
/// is hand you the structured extras the send pipeline puts in the data
/// payload, already parsed, so wiring them into `flutter_local_notifications`
/// (or your own UI) is a few lines instead of an afternoon of guessing at
/// encodings.
///
/// The encodings are not the same on both platforms and that is not a choice
/// we made: FCM data values must all be strings, so `nb_buttons` arrives
/// JSON-encoded on Android, while an APNs payload is JSON throughout and the
/// same key arrives as a real list on iOS. This handles both.
library;

import 'dart:convert';

/// One action button, as composed in the Notibase console.
class NotibaseButton {
  const NotibaseButton({required this.id, required this.text, this.url});

  /// Echoed back to your app when tapped.
  final String id;
  final String text;

  /// Per-button destination; falls back to the notification's own [url].
  final String? url;

  @override
  String toString() => 'NotibaseButton($id, $text${url == null ? '' : ', $url'})';
}

/// The parts of a push payload that need rendering rather than just reading.
class NotibaseNotification {
  const NotibaseNotification({
    required this.buttons,
    this.url,
    this.mediaUrl,
    this.largeIconUrl,
    this.messageId,
  });

  final List<NotibaseButton> buttons;

  /// Where a plain body tap should go.
  final String? url;

  /// Image to attach — `ios.media` or the message's `image`.
  final String? mediaUrl;

  /// Android's large icon. iOS has no equivalent, so it is null there.
  final String? largeIconUrl;

  /// Null for a notification that did not come from Notibase.
  final String? messageId;

  /// True when this payload came from Notibase at all — the cheapest way to
  /// leave other services' notifications alone.
  bool get isNotibase => messageId != null;

  /// Parse a `RemoteMessage.data` map. Never throws: a payload you cannot
  /// parse should cost you the buttons, not the notification.
  static NotibaseNotification parse(Map<String, dynamic> data) {
    return NotibaseNotification(
      buttons: _buttons(data['nb_buttons']),
      url: data['url'] as String?,
      mediaUrl: data['nb_media'] as String?,
      largeIconUrl: data['nb_large_icon'] as String?,
      messageId: data['nb_m'] as String?,
    );
  }

  static List<NotibaseButton> _buttons(Object? raw) {
    if (raw == null) return const [];
    Object? decoded = raw;
    // Android: a JSON string, because FCM data values are always strings.
    if (raw is String) {
      if (raw.trim().isEmpty) return const [];
      try {
        decoded = jsonDecode(raw);
      } catch (_) {
        return const [];
      }
    }
    if (decoded is! List) return const [];
    final out = <NotibaseButton>[];
    for (final item in decoded) {
      if (item is! Map) continue;
      final id = item['id'];
      final text = item['text'];
      if (id is! String || id.isEmpty) continue;
      if (text is! String || text.isEmpty) continue;
      final url = item['url'];
      out.add(NotibaseButton(
        id: id,
        text: text,
        url: url is String && url.isNotEmpty ? url : null,
      ));
    }
    return out;
  }
}
