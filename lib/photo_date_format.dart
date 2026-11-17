/// Format an EXIF-derived epoch-millisecond timestamp in JST for the UI.
/// The timestamp itself is never changed; this is display-only formatting.
String formatJstTimestamp(Object? milliseconds) {
  if (milliseconds is! num || milliseconds.toInt() <= 0) return '—';
  final date = DateTime.fromMillisecondsSinceEpoch(
    milliseconds.toInt() + const Duration(hours: 9).inMilliseconds,
    isUtc: true,
  );
  String pad(int value) => value.toString().padLeft(2, '0');
  return '${date.year}-${pad(date.month)}-${pad(date.day)} '
      '${pad(date.hour)}:${pad(date.minute)}:${pad(date.second)}';
}
