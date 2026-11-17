import 'package:exif_date_sync/android_photo_row.dart';
import 'package:exif_date_sync/mac_photo_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final captured = DateTime.utc(2026, 11, 4, 3, 30).millisecondsSinceEpoch;

  testWidgets('Android photo row is compact and delegates actions',
      (tester) async {
    var selected = false;
    var previews = 0;
    var opens = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 480,
          child: AndroidPhotoRow(
            row: {
              'path': '/storage/emulated/0/Pictures/photo.jpg',
              'relativePath': 'photo.jpg',
              'targetMs': captured,
              'beforeMs': captured,
              'status': 'NEEDS_UPDATE',
            },
            selected: false,
            onSelected: (value) => selected = value == true,
            onPreview: () => previews++,
            onOpenExternal: () => opens++,
          ),
        ),
      ),
    ));
    expect(find.text('photo.jpg'), findsOneWidget);
    expect(find.text('要更新'), findsOneWidget);
    expect(find.text('撮影：2026-11-04 12:30:00'), findsOneWidget);
    expect(find.text('変更：2026-11-04 12:30:00'), findsOneWidget);
    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    expect(selected, isTrue);
    await tester.tap(find.text('photo.jpg'));
    await tester.pump();
    expect(previews, 1);
    await tester.tap(find.byTooltip('関連付けアプリで開く'));
    expect(opens, 1);
  });

  testWidgets('Mac photo row keeps four columns and delegates selection',
      (tester) async {
    var selected = false;
    var previews = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 950,
          child: MacPhotoRow(
            row: {
              'relativePath': 'photo.jpg',
              'targetMs': captured,
              'beforeMs': captured,
              'status': 'NEEDS_UPDATE',
            },
            selected: false,
            onSelected: (value) => selected = value == true,
            onPreview: () => previews++,
          ),
        ),
      ),
    ));
    expect(find.text('photo.jpg'), findsOneWidget);
    expect(find.text('要更新'), findsOneWidget);
    expect(find.text('2026-11-04 12:30:00'), findsNWidgets(2));
    await tester.tap(find.byType(Checkbox));
    expect(selected, isTrue);
    await tester.tap(find.text('photo.jpg'));
    expect(previews, 1);
    await tester.tap(find.text('2026-11-04 12:30:00').first);
    await tester.tap(find.text('要更新'));
    expect(previews, 3);
  });
}
