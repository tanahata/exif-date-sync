import 'dart:async';

import 'package:exif_date_sync/macos_exif_preview_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const native = MethodChannel('dev.exifdatesync/macos');
  final messenger = TestDefaultBinaryMessengerBinding
      .instance.defaultBinaryMessenger;

  setUp(() {
    messenger.setMockMethodCallHandler(native, (call) async {
      switch (call.method) {
        case 'checkExifTool':
          return {'path': '/opt/homebrew/bin/exiftool', 'version': '13.0'};
        case 'lastBatch':
          return {'exists': false};
        case 'checkWriteScope':
          return false;
        default:
          throw PlatformException(code: 'UNEXPECTED', message: call.method);
      }
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(native, null);
  });

  testWidgets('compact Mac window keeps actions and keyboard help accessible',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(500, 480));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(1.3)),
        child: child!,
      ),
      home: const MacExifPreviewPage(),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(tester.getBottomLeft(find.byType(ListView)).dy,
        lessThan(tester.getTopLeft(find.text('選択した0件を更新')).dy));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.textContaining('作成日時も変わる'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('recursive switch has an accessibility label', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final handle = tester.ensureSemantics();
    try {
      await tester.pumpWidget(const MaterialApp(home: MacExifPreviewPage()));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('サブフォルダを含める'), findsWidgets);
    } finally {
      handle.dispose();
    }
  });

  testWidgets('preview shows fixed JST date and does not write',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final calls = <String>[];
    final scanResult = Completer<Map<String, Object>>();
    messenger.setMockMethodCallHandler(native, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'checkExifTool':
          return {'path': '/opt/homebrew/bin/exiftool', 'version': '13.0'};
        case 'lastBatch':
          return {'exists': false};
        case 'checkWriteScope':
          return false;
        case 'pickFolder':
          return '/tmp/EXIFDateSyncTest';
        case 'scanFolder':
          return scanResult.future;
        default:
          throw PlatformException(code: 'UNEXPECTED', message: call.method);
      }
    });

    await tester.pumpWidget(
      const MaterialApp(home: MacExifPreviewPage()),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('ExifTool 13.0'), findsNothing);

    await tester.tap(find.text('フォルダを選択'));
    // pickFolder -> checkWriteScope -> scanFolder each completes asynchronously.
    // Wait for the scanning state before emitting the native row event.
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    // 2026-11-04 03:30 UTC == 2026-11-04 12:30 JST.
    final at = DateTime.utc(2026, 11, 4, 3, 30).millisecondsSinceEpoch;
    final packet = const StandardMethodCodec().encodeMethodCall(MethodCall(
      'macRows',
      [
        {
          'relativePath': 'photo.jpg',
          'targetMs': at,
          'beforeMs': at + const Duration(minutes: 30).inMilliseconds,
          'status': 'NEEDS_UPDATE',
        },
      ],
    ));
    unawaited(messenger.handlePlatformMessage(native.name, packet, null));
    await tester.pump();
    scanResult.complete({
      'complete': true, 'total': 1, 'excluded': 0, 'unreadable': 0,
    });
    await tester.pumpAndSettle();
    expect(find.text('photo.jpg'), findsOneWidget);
    expect(find.text('2026-11-04 12:30:00'), findsOneWidget);
    expect(find.text('2026-11-04 13:00:00'), findsOneWidget);
    expect(find.text('要更新'), findsOneWidget);
    expect(calls, isNot(contains('applyBatch')));
    expect(calls, isNot(contains('undoLastBatch')));
  });

  testWidgets('synthetic update is blocked without confirmation',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 850);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final calls = <String>[];
    final scanResult = Completer<Map<String, Object>>();
    var scanNumber = 0;
    messenger.setMockMethodCallHandler(native, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'checkExifTool':
          return {'path': '/opt/homebrew/bin/exiftool', 'version': '13.0'};
        case 'lastBatch':
          return {'exists': true, 'applied': 1, 'root': '/tmp/exif-date-sync-smoke.TEST'};
        case 'checkWriteScope':
          return true; // Native gate is separately tested on macOS.
        case 'pickFolder':
          return '/tmp/exif-date-sync-smoke.TEST';
        case 'scanFolder':
          scanNumber++;
          if (scanNumber == 1) return scanResult.future;
          return {'complete': true, 'total': 1, 'excluded': 0, 'unreadable': 0};
        case 'applyBatch':
          expect((call.arguments as Map)['replaceConfirmed'], isTrue);
          return {'exists': true, 'applied': 1, 'skipped': 0,
            'undone': 0, 'unresolved': 0};
        default:
          throw PlatformException(code: 'UNEXPECTED', message: call.method);
      }
    });
    await tester.pumpWidget(const MaterialApp(home: MacExifPreviewPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('フォルダを選択'));
    // pickFolder -> checkWriteScope -> scanFolder each completes asynchronously.
    // Wait for the scanning state before emitting the native row event.
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }

    final t = DateTime.utc(2024, 1, 1, 18, 4, 5).millisecondsSinceEpoch;
    final packet = const StandardMethodCodec().encodeMethodCall(MethodCall(
      'macRows',
      [{
        'relativePath': 'sample.jpg',
        'targetMs': t,
        'beforeMs': t + 100000,
        'status': 'NEEDS_UPDATE',
      }],
    ));
    unawaited(messenger.handlePlatformMessage(native.name, packet, null));
    await tester.pump();
    scanResult.complete({'complete': true, 'total': 1,
      'excluded': 0, 'unreadable': 0});
    await tester.pumpAndSettle();

    expect(find.text('選択した1件を更新'), findsOneWidget);
    await tester.tap(find.text('選択した1件を更新'));
    await tester.pumpAndSettle();
    expect(find.text('ファイルの日時を更新しますか？'), findsOneWidget);
    expect(find.textContaining('前回のUndo履歴は、この更新で置き換わります。'), findsOneWidget);
    expect(calls.where((x) => x == 'applyBatch'), isEmpty);

    await tester.tap(find.text('キャンセル'));
    await tester.pumpAndSettle();
    expect(calls.where((x) => x == 'applyBatch'), isEmpty);

    await tester.tap(find.text('選択した1件を更新'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('更新する'));
    await tester.pumpAndSettle();
    expect(calls.where((x) => x == 'applyBatch'), hasLength(1));
    expect(find.text('1件の変更日時を更新しました。'), findsOneWidget);
  });
  testWidgets('unreadable and undated rows do not block valid images',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 850);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final calls = <String>[];
    final scanResult = Completer<Map<String, Object>>();
    Map<dynamic, dynamic>? submitted;
    var scans = 0;
    messenger.setMockMethodCallHandler(native, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'checkExifTool':
          return {'path': '/opt/homebrew/bin/exiftool', 'version': '13.0'};
        case 'lastBatch':
          return {'exists': false};
        case 'checkWriteScope':
          return true;
        case 'pickFolder':
          return '/tmp/exif-test/Portraits';
        case 'scanFolder':
          if (scans++ == 0) return scanResult.future;
          return {'complete': true, 'total': 3, 'excluded': 0, 'unreadable': 1};
        case 'applyBatch':
          submitted = Map<dynamic, dynamic>.from(call.arguments as Map);
          return {'exists': true, 'applied': 1, 'undone': 0, 'unresolved': 0};
        default:
          throw PlatformException(code: 'UNEXPECTED', message: call.method);
      }
    });

    await tester.pumpWidget(const MaterialApp(home: MacExifPreviewPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('フォルダを選択'));
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    final timestamp = DateTime.utc(2024, 1, 1).millisecondsSinceEpoch;
    final packet = const StandardMethodCodec().encodeMethodCall(MethodCall(
      'macRows',
      [
        {
          'relativePath': 'sample.jpg',
          'targetMs': timestamp,
          'beforeMs': timestamp + 100000,
          'status': 'NEEDS_UPDATE',
        },
        {
          'relativePath': 'unreadable.jpg',
          'beforeMs': timestamp,
          'status': 'ERROR',
        },
        {
          'relativePath': 'old-photo.jpg',
          'beforeMs': timestamp,
          'status': 'NO_DATE',
        },
      ],
    ));
    unawaited(messenger.handlePlatformMessage(native.name, packet, null));
    await tester.pump();
    scanResult.complete({
      'complete': true, 'total': 3, 'excluded': 0, 'unreadable': 1,
    });
    await tester.pumpAndSettle();

    expect(find.text('読み取りエラー：1 件'), findsOneWidget);
    expect(find.text('old-photo.jpg'), findsOneWidget);
    expect(find.text('日時なし'), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '選択した1件を更新'),
    );
    expect(button.onPressed, isNotNull);
    expect(calls, isNot(contains('applyBatch')));
    await tester.tap(find.text('選択した1件を更新'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('更新する'));
    await tester.pumpAndSettle();
    expect(calls.where((name) => name == 'applyBatch'), hasLength(1));
    final items = submitted!['items'] as List;
    expect(items, hasLength(1));
    expect((items.single as Map)['relativePath'], 'sample.jpg');
  });

  testWidgets('undated scan entry is shown but cannot be updated',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 850);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final calls = <String>[];
    final scanResult = Completer<Map<String, Object>>();
    messenger.setMockMethodCallHandler(native, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'checkExifTool':
          return {'path': '/opt/homebrew/bin/exiftool', 'version': '13.0'};
        case 'lastBatch':
          return {'exists': false};
        case 'checkWriteScope':
          return true;
        case 'pickFolder':
          return '/tmp/exif-date-sync-smoke.TEST';
        case 'scanFolder':
          return scanResult.future;
        default:
          throw PlatformException(code: 'UNEXPECTED', message: call.method);
      }
    });
    await tester.pumpWidget(const MaterialApp(home: MacExifPreviewPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('フォルダを選択'));
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    final packet = const StandardMethodCodec().encodeMethodCall(MethodCall(
      'macRows',
      [{
        'relativePath': 'digitized-only.jpg',
        'beforeMs': DateTime.utc(2026, 11, 4).millisecondsSinceEpoch,
        'status': 'NO_DATE',
      }],
    ));
    unawaited(messenger.handlePlatformMessage(native.name, packet, null));
    await tester.pump();
    scanResult.complete({
      'complete': true, 'total': 1, 'excluded': 0, 'unreadable': 0,
    });
    await tester.pumpAndSettle();
    expect(find.text('digitized-only.jpg'), findsOneWidget);
    expect(find.text('日時なし'), findsOneWidget);
    final update = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '選択した0件を更新'),
    );
    expect(update.onPressed, isNull);
    expect(calls, isNot(contains('applyBatch')));
  });


  testWidgets('cancelled Mac scan keeps partial rows but forbids update until rescan',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 850);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final calls = <String>[];
    final firstScan = Completer<Map<String, Object>>();
    final secondScan = Completer<Map<String, Object>>();
    var scanCount = 0;
    messenger.setMockMethodCallHandler(native, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'checkExifTool':
          return {'path': '/opt/homebrew/bin/exiftool', 'version': '13.0'};
        case 'lastBatch':
          return {'exists': false};
        case 'pickFolder':
          return '/tmp/exif-date-sync-cancel-test';
        case 'checkWriteScope':
          return true;
        case 'scanFolder':
          return scanCount++ == 0 ? firstScan.future : secondScan.future;
        case 'cancelScan':
          return null;
        default:
          throw PlatformException(code: 'UNEXPECTED', message: call.method);
      }
    });

    await tester.pumpWidget(const MaterialApp(home: MacExifPreviewPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('フォルダを選択'));
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }

    // The first scan has produced a selectable-looking row but is incomplete.
    final at = DateTime.utc(2024, 1, 1, 18, 4, 5).millisecondsSinceEpoch;
    final packet = const StandardMethodCodec().encodeMethodCall(MethodCall(
      'macRows',
      [{
        'relativePath': 'partial.dng',
        'beforeMs': at + 120000,
        'targetMs': at,
        'status': 'NEEDS_UPDATE',
      }],
    ));
    unawaited(messenger.handlePlatformMessage(native.name, packet, null));
    await tester.pump();
    expect(find.text('partial.dng'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '選択した1件を更新'),
      ).onPressed,
      isNull,
    );

    await tester.tap(find.text('中止'));
    await tester.pump();
    expect(calls, contains('cancelScan'));
    firstScan.complete({
      'complete': false, 'total': 1, 'excluded': 0, 'unreadable': 0,
    });
    await tester.pumpAndSettle();
    expect(find.text('partial.dng'), findsOneWidget);
    expect(find.text('スキャンを中止しました。部分一覧を表示しています。'),
        findsOneWidget);
    expect(
      tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '選択した1件を更新'),
      ).onPressed,
      isNull,
    );
    expect(calls, isNot(contains('applyBatch')));

    // A new scan must drop partial results and must not retain their selection.
    await tester.tap(find.byTooltip('再スキャン'));
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    expect(find.text('partial.dng'), findsNothing);
    expect(find.text('選択した0件を更新'), findsOneWidget);

    final newPacket = const StandardMethodCodec().encodeMethodCall(MethodCall(
      'macRows',
      [{
        'relativePath': 'fresh.jpg',
        'beforeMs': at + 120000,
        'targetMs': at,
        'status': 'NEEDS_UPDATE',
      }],
    ));
    unawaited(messenger.handlePlatformMessage(native.name, newPacket, null));
    await tester.pump();
    secondScan.complete({
      'complete': true, 'total': 1, 'excluded': 0, 'unreadable': 0,
    });
    await tester.pumpAndSettle();
    expect(find.text('fresh.jpg'), findsOneWidget);
    expect(find.text('partial.dng'), findsNothing);
    expect(
      tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '選択した1件を更新'),
      ).onPressed,
      isNotNull,
    );
    expect(calls.where((x) => x == 'scanFolder'), hasLength(2));
    expect(calls, isNot(contains('applyBatch')));
  });

  testWidgets('Mac list sorts, filters, keeps columns, and opens without writing',
      (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final calls = <String>[];
    Map<dynamic, dynamic>? opened;
    final scan = Completer<Map<String, Object>>();
    messenger.setMockMethodCallHandler(native, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'checkExifTool':
          return {'path': '/opt/homebrew/bin/exiftool', 'version': '13.55'};
        case 'lastBatch':
          return {'exists': false};
        case 'pickFolder':
          return '/tmp/exif-date-sync-table';
        case 'checkWriteScope':
          return true;
        case 'scanFolder':
          return scan.future;
        case 'thumbnail':
          final args = Map<dynamic, dynamic>.from(call.arguments as Map);
          expect(args['relativePath'], 'z-needs.jpg');
          return null; // Unsupported thumbnail must still offer external viewing.
        case 'openFile':
          opened = Map<dynamic, dynamic>.from(call.arguments as Map);
          return null;
        default:
          throw PlatformException(code: 'UNEXPECTED', message: call.method);
      }
    });

    await tester.pumpWidget(const MaterialApp(home: MacExifPreviewPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('フォルダを選択'));
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    final packet = const StandardMethodCodec().encodeMethodCall(MethodCall(
      'macRows',
      [
        {
          'relativePath': 'a-unchanged.jpg',
          'beforeMs': 1794096000000,
          'targetMs': 1794096000000,
          'status': 'UNCHANGED',
        },
        {
          'relativePath': 'z-needs.jpg',
          'beforeMs': 1794182400000,
          'targetMs': 1794096000000,
          'status': 'NEEDS_UPDATE',
        },
        {
          'relativePath': 'm-undated.dng',
          'beforeMs': 1794182400000,
          'status': 'NO_DATE',
        },
      ],
    ));
    unawaited(messenger.handlePlatformMessage(native.name, packet, null));
    await tester.pump();
    scan.complete({
      'complete': true, 'total': 3, 'excluded': 0, 'unreadable': 0,
    });
    await tester.pumpAndSettle();
    expect(find.text('表示 3 / 3 件'), findsOneWidget);
    expect(find.text('選択した1件を更新'), findsOneWidget);
    // Default: update-needed rows are shown first, even if filename is last.
    expect(tester.getTopLeft(find.text('z-needs.jpg')).dy,
        lessThan(tester.getTopLeft(find.text('a-unchanged.jpg')).dy));
    expect(
      tester.getTopLeft(find.text('a-unchanged.jpg')).dy -
          tester.getTopLeft(find.text('z-needs.jpg')).dy,
      lessThan(60),
    );

    await tester.tap(find.text('ファイル'));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('a-unchanged.jpg')).dy,
        lessThan(tester.getTopLeft(find.text('z-needs.jpg')).dy));
    await tester.tap(find.text('ファイル')); // Descending.
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('z-needs.jpg')).dy,
        lessThan(tester.getTopLeft(find.text('a-unchanged.jpg')).dy));

    // All four headers select a sort key and can be toggled.
    await tester.tap(find.text('撮影日時'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('現在の変更日時'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('状態'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('要更新のみ'));
    await tester.pumpAndSettle();
    expect(find.text('z-needs.jpg'), findsOneWidget);
    expect(find.text('a-unchanged.jpg'), findsNothing);
    expect(find.text('m-undated.dng'), findsNothing);
    expect(find.text('表示 1 / 3 件'), findsOneWidget);
    expect(find.text('選択した1件を更新'), findsOneWidget);

    expect(find.text('表示列'), findsNothing);
    expect(find.text('撮影日時'), findsOneWidget);
    expect(find.text('現在の変更日時'), findsOneWidget);

    // The lightweight preview must leave selection and Undo untouched.
    await tester.tap(find.text('z-needs.jpg'));
    await tester.pumpAndSettle();
    expect(find.text('プレビューできません'), findsOneWidget);
    expect(find.text('選択した1件を更新'), findsOneWidget);
    expect(calls.where((name) => name == 'thumbnail'), hasLength(1));
    await tester.tap(find.text('関連付けアプリで開く'));
    await tester.pumpAndSettle();
    expect(opened?['path'], '/tmp/exif-date-sync-table');
    expect(opened?['relativePath'], 'z-needs.jpg');
    await tester.tap(find.text('要更新のみ'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'z-needs.jpg'));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pumpAndSettle();
    await tester.tap(find.text('関連付けアプリで開く'));
    await tester.pumpAndSettle();
    expect(opened?['relativePath'], isNot('z-needs.jpg'));
    expect(find.text('選択した1件を更新'), findsOneWidget);
    expect(calls, isNot(contains('applyBatch')));
    expect(calls, isNot(contains('undoLastBatch')));
  });

  testWidgets('update results identify successful and skipped rows until rescan', (tester) async {
    tester.view.physicalSize = const Size(1280, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final scans = <Completer<Map<String, Object>>>[];
    messenger.setMockMethodCallHandler(native, (call) async {
      switch (call.method) {
        case 'checkExifTool': return {'path': '/tool', 'version': '13'};
        case 'lastBatch': return {'exists': false};
        case 'checkWriteScope': return true;
        case 'pickFolder': return '/tmp/synthetic';
        case 'scanFolder':
          final result = Completer<Map<String, Object>>();
          scans.add(result);
          return result.future;
        case 'applyBatch': return {'applied': 1, 'skipped': 1,
          'appliedPaths': ['ok.jpg'], 'skippedPaths': ['stale.jpg']};
        default: throw PlatformException(code: 'UNEXPECTED');
      }
    });
    Future<void> finishScan(int number, bool updated) async {
      for (var i = 0; i < 8 && scans.length <= number; i++) { await tester.pump(); }
      expect(scans.length, greaterThan(number));
      final rows = [
        {'relativePath': 'ok.jpg', 'beforeMs': updated ? 1700000000000 : 1700000100000,
          'targetMs': 1700000000000, 'status': updated ? 'UNCHANGED' : 'NEEDS_UPDATE'},
        {'relativePath': 'stale.jpg', 'beforeMs': 1700000100000,
          'targetMs': 1700000000000, 'status': 'NEEDS_UPDATE'},
        {'relativePath': 'other.jpg', 'beforeMs': 1700000000000,
          'targetMs': 1700000000000, 'status': 'UNCHANGED'},
      ];
      final packet = const StandardMethodCodec().encodeMethodCall(MethodCall('macRows', rows));
      unawaited(messenger.handlePlatformMessage(native.name, packet, null));
      await tester.pump();
      scans[number].complete({'complete': true, 'total': 3, 'excluded': 0, 'unreadable': 0});
      await tester.pumpAndSettle();
    }
    await tester.pumpWidget(const MaterialApp(home: MacExifPreviewPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('フォルダを選択'));
    await finishScan(0, false);
    await tester.tap(find.text('要更新のみ'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('選択した2件を更新'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('更新する'));
    await finishScan(1, true);
    expect(find.text('更新済み'), findsOneWidget);
    expect(find.text('更新失敗（スキップ）'), findsOneWidget);
    expect(find.text('更新結果：成功 1件・スキップ 1件'), findsOneWidget);
    expect(find.text('選択した0件を更新'), findsOneWidget);
    expect(find.text('今回の対象のみ'), findsOneWidget);
    expect(find.text('other.jpg'), findsNothing);
    await tester.tap(find.text('今回の対象のみ'));
    await tester.pumpAndSettle();
    expect(find.text('other.jpg'), findsOneWidget);
    await tester.tap(find.byTooltip('再スキャン'));
    await finishScan(2, true);
    expect(find.text('更新済み'), findsNothing);
    expect(find.text('更新失敗（スキップ）'), findsNothing);
    expect(find.text('変更不要'), findsNWidgets(2));
    expect(find.text('要更新'), findsOneWidget);
  });


  testWidgets('RAW scan scope can be toggled', (tester) async {
    tester.view.physicalSize = const Size(1280, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final scopes = <bool>[];
    messenger.setMockMethodCallHandler(native, (call) async {
      switch (call.method) {
        case 'checkExifTool': return {'path': '/tool', 'version': '13'};
        case 'lastBatch': return {'exists': false};
        case 'checkWriteScope': return true;
        case 'pickFolder': return '/tmp/synthetic';
        case 'scanFolder':
          scopes.add((call.arguments as Map)['includeRaw'] as bool);
          return {'complete': true, 'total': 0, 'excluded': 0, 'unreadable': 0};
        default: throw PlatformException(code: 'UNEXPECTED');
      }
    });
    await tester.pumpWidget(const MaterialApp(home: MacExifPreviewPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('フォルダを選択'));
    await tester.pumpAndSettle();
    expect(scopes, [true]);
    expect(find.text('RAWを含める'), findsOneWidget);
    await tester.tap(find.byType(Checkbox).at(1));
    await tester.pumpAndSettle();
    expect(scopes, [true, false]);
  });

  testWidgets('Mac select all or none leaves non-updatable rows untouched and exposes error reasons',
      (tester) async {
    tester.view.physicalSize = const Size(1440, 950);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final scan = Completer<Map<String, Object>>();
    messenger.setMockMethodCallHandler(native, (call) async {
      switch (call.method) {
        case 'checkExifTool': return {'path': '/tool', 'version': '13'};
        case 'lastBatch': return {'exists': false};
        case 'pickFolder': return '/tmp/selection-test';
        case 'checkWriteScope': return true;
        case 'scanFolder': return scan.future;
        default: throw PlatformException(code: 'UNEXPECTED', message: call.method);
      }
    });
    await tester.pumpWidget(const MaterialApp(home: MacExifPreviewPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('フォルダを選択'));
    for (var i = 0; i < 5; i++) { await tester.pump(); }
    final rows = [
      {'relativePath': 'a.jpg', 'status': 'NEEDS_UPDATE',
        'targetMs': 1700000000000, 'beforeMs': 1700000100000},
      {'relativePath': 'b.jpg', 'status': 'NEEDS_UPDATE',
        'targetMs': 1700000000000, 'beforeMs': 1700000100000},
      {'relativePath': 'c.jpg', 'status': 'UNCHANGED',
        'targetMs': 1700000000000, 'beforeMs': 1700000000000},
      {'relativePath': 'broken.jpg', 'status': 'ERROR',
        'beforeMs': 1700000100000, 'message': 'ExifToolの結果を読み取れません'},
    ];
    final packet = const StandardMethodCodec().encodeMethodCall(
      MethodCall('macRows', rows));
    unawaited(messenger.handlePlatformMessage(native.name, packet, null));
    await tester.pump();
    scan.complete({'complete': true, 'total': 4, 'excluded': 0, 'unreadable': 1});
    await tester.pumpAndSettle();

    expect(find.text('選択した2件を更新'), findsOneWidget);
    await tester.tap(find.text('全解除'));
    await tester.pumpAndSettle();
    expect(find.text('選択した0件を更新'), findsOneWidget);
    await tester.tap(find.text('全選択'));
    await tester.pumpAndSettle();
    expect(find.text('選択した2件を更新'), findsOneWidget);

    final reason = find.ancestor(
      of: find.byIcon(Icons.info_outline),
      matching: find.byType(Tooltip),
    );
    expect(reason, findsOneWidget);
    expect(tester.widget<Tooltip>(reason).message,
        'ExifToolの結果を読み取れません');
  });

  testWidgets('Mac cancel requests a file-boundary stop and shows partial result',
      (tester) async {
    tester.view.physicalSize = const Size(1440, 950);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final scans = <Completer<Map<String, Object>>>[];
    final update = Completer<Map<String, Object>>();
    var cancelledCalls = 0;
    Map<String, Object> history = {'exists': false};
    messenger.setMockMethodCallHandler(native, (call) async {
      switch (call.method) {
        case 'checkExifTool': return {'path': '/tool', 'version': '13'};
        case 'lastBatch': return history;
        case 'pickFolder': return '/tmp/cancel-test';
        case 'checkWriteScope': return true;
        case 'scanFolder':
          final completer = Completer<Map<String, Object>>();
          scans.add(completer);
          return completer.future;
        case 'applyBatch': return update.future;
        case 'cancelBatch':
          cancelledCalls++;
          return null;
        default: throw PlatformException(code: 'UNEXPECTED', message: call.method);
      }
    });
    Future<void> finishScan(int index, {required bool afterUpdate}) async {
      for (var i = 0; i < 12 && scans.length <= index; i++) {
        await tester.pump();
      }
      expect(scans.length, greaterThan(index));
      final rows = [
        {'relativePath': 'done.jpg', 'status': afterUpdate ? 'UNCHANGED' : 'NEEDS_UPDATE',
          'targetMs': 1700000000000,
          'beforeMs': afterUpdate ? 1700000000000 : 1700000100000},
        {'relativePath': 'pending.jpg', 'status': 'NEEDS_UPDATE',
          'targetMs': 1700000000000, 'beforeMs': 1700000100000},
      ];
      final packet = const StandardMethodCodec().encodeMethodCall(
        MethodCall('macRows', rows));
      unawaited(messenger.handlePlatformMessage(native.name, packet, null));
      await tester.pump();
      scans[index].complete({'complete': true, 'total': 2,
        'excluded': 0, 'unreadable': 0});
      await tester.pumpAndSettle();
    }
    await tester.pumpWidget(const MaterialApp(home: MacExifPreviewPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('フォルダを選択'));
    await finishScan(0, afterUpdate: false);
    await tester.tap(find.text('選択した2件を更新'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('更新する'));
    await tester.pump();
    expect(find.text('更新を中止'), findsOneWidget);
    await tester.tap(find.text('更新を中止'));
    // The update is intentionally still pending. Its indeterminate progress
    // indicator never settles until the fake native result completes.
    await tester.pump();
    expect(cancelledCalls, 1);
    expect(find.text('停止中…'), findsOneWidget);
    expect(tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, '停止中…')).onPressed, isNull);

    history = {'exists': true, 'applied': 1, 'unresolved': 0,
      'root': '/tmp/cancel-test'};
    update.complete({'applied': 1, 'skipped': 0, 'remaining': 1,
      'cancelled': true, 'appliedPaths': ['done.jpg'],
      'skippedPaths': <String>[]});
    await finishScan(1, afterUpdate: true);
    expect(find.text('更新を中止：成功 1件・未処理 1件・スキップ 0件'),
        findsOneWidget);
    expect(find.text('更新済み'), findsOneWidget);
    expect(find.text('直近の処理をUndo'), findsOneWidget);
    expect(find.text('停止中…'), findsNothing);
  });

}
