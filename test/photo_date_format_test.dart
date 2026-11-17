import 'package:exif_date_sync/photo_date_format.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('JST formatter is stable across OS and device timezones', () {
    final instant = DateTime.utc(2026, 11, 4, 3, 30, 0);
    expect(
      formatJstTimestamp(instant.millisecondsSinceEpoch),
      '2026-11-04 12:30:00',
    );
  });

  test('missing or invalid values use the same placeholder', () {
    expect(formatJstTimestamp(null), '—');
    expect(formatJstTimestamp('not a timestamp'), '—');
    expect(formatJstTimestamp(0), '—');
  });
}
