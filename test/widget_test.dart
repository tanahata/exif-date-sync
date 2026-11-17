import 'dart:io' show Platform;

import 'package:exif_date_sync/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const android = MethodChannel('dev.exifdatesync/storage_probe');
  const macos = MethodChannel('dev.exifdatesync/macos');
  final messenger = TestDefaultBinaryMessengerBinding
      .instance.defaultBinaryMessenger;

  setUp(() {
    messenger.setMockMethodCallHandler(android, (call) async {
      switch (call.method) {
        case 'hasPermission':
          return false;
        case 'lastBatch':
          return <String, Object>{'exists': false};
        default:
          throw PlatformException(code: 'UNEXPECTED', message: call.method);
      }
    });
    messenger.setMockMethodCallHandler(macos, (call) async {
      if (call.method == 'checkExifTool') {
        return {'path': '/opt/homebrew/bin/exiftool', 'version': '13.0'};
      }
      if (call.method == 'lastBatch') return {'exists': false};
      throw PlatformException(code: 'UNEXPECTED', message: call.method);
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(android, null);
    messenger.setMockMethodCallHandler(macos, null);
  });

  testWidgets('entrypoint routes to platform-specific safe landing page',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const ExifDateSyncApp());
    await tester.pumpAndSettle();

    if (Platform.isMacOS) {
      expect(find.text('EXIF Date Sync'), findsOneWidget);
      expect(find.text('フォルダを選択'), findsOneWidget);
      expect(find.byTooltip('ヘルプ'), findsOneWidget);
    } else {
      expect(find.text('EXIF Date Sync'), findsOneWidget);
      expect(find.text('ファイルアクセスを許可'), findsOneWidget);
      expect(find.text('フォルダ未選択'), findsOneWidget);
    }
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
