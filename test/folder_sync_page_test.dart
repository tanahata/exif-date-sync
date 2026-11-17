import 'dart:async';

import 'package:exif_date_sync/folder_sync_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const native = MethodChannel('dev.exifdatesync/storage_probe');
  final messenger = TestDefaultBinaryMessengerBinding
      .instance.defaultBinaryMessenger;
  final calls = <String>[];

  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(native, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'hasPermission':
          return false;
        case 'lastBatch':
          return <String, Object>{'exists': false};
        default:
          throw PlatformException(
            code: 'UNEXPECTED',
            message: 'Unexpected method: ${call.method}',
          );
      }
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(native, null);
  });

  testWidgets('no permission: keeps file updates disabled', (tester) async {
    tester.view.physicalSize = const Size(480, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MaterialApp(
      home: const FolderSyncPage(),
    ));
    await tester.pumpAndSettle();

    expect(find.text('フォルダ未選択'), findsOneWidget);
    expect(find.text('ファイルアクセスを許可'), findsOneWidget);
    expect(find.text('許可状態を確認'), findsOneWidget);
    expect(calls, contains('hasPermission'));
    expect(calls, contains('lastBatch'));
    expect(calls, isNot(contains('applyBatch')));

    final update = tester.widget<FilledButton>(find.widgetWithText(
      FilledButton,
      '選択した0件の変更日時を更新',
    ));
    expect(update.onPressed, isNull);
    expect(find.text('直近の処理をUndo'), findsNothing);
  });

  testWidgets('permission granted: folder browsing does not write', (tester) async {
    tester.view.physicalSize = const Size(480, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    messenger.setMockMethodCallHandler(native, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'hasPermission':
          return true;
        case 'lastBatch':
          return <String, Object>{'exists': false};
        case 'rootFolders':
          return [
            {'name': 'Pictures', 'path': '/storage/emulated/0/Pictures'},
          ];
        case 'childFolders':
          return [
            {'name': 'EXIFDateSyncTest',
             'path': '/storage/emulated/0/Pictures/EXIFDateSyncTest'},
          ];
        case 'scanFolder':
          return {
            'complete': true, 'excluded': 2, 'included': 0,
            'failedDirectories': 0,
          };
        default:
          throw PlatformException(
            code: 'UNEXPECTED',
            message: 'Unexpected method: ${call.method}',
          );
      }
    });

    await tester.pumpWidget(MaterialApp(
      home: const FolderSyncPage(),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('フォルダを選択'));
    await tester.pumpAndSettle();
    expect(find.text('Pictures'), findsOneWidget);
    await tester.tap(find.text('Pictures'));
    await tester.pumpAndSettle();

    expect(find.text('EXIFDateSyncTest'), findsOneWidget);
    await tester.tap(find.text('EXIFDateSyncTest'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('このフォルダを選択'));
    await tester.pumpAndSettle();

    expect(find.textContaining('スキャン完了'), findsOneWidget);
    expect(find.textContaining('対象外2件'), findsOneWidget);
    expect(calls, contains('scanFolder'));
    expect(calls, isNot(contains('applyBatch')));
    expect(calls, isNot(contains('undoLastBatch')));
  });

  testWidgets('partial scan cannot update even when a candidate was found', (tester) async {
    tester.view.physicalSize = const Size(480, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final scanResult = Completer<Map<String, Object>>();
    messenger.setMockMethodCallHandler(native, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'hasPermission':
          return true;
        case 'lastBatch':
          return <String, Object>{'exists': false};
        case 'rootFolders':
          return [
            {'name': 'Pictures', 'path': '/storage/emulated/0/Pictures'},
          ];
        case 'childFolders':
          return [
            {'name': 'EXIFDateSyncTest',
             'path': '/storage/emulated/0/Pictures/EXIFDateSyncTest'},
          ];
        case 'scanFolder':
          return scanResult.future;
        case 'cancelScan':
          scanResult.complete({
            'complete': false, 'included': 1, 'excluded': 0,
            'failedDirectories': 0,
          });
          return null;
        default:
          throw PlatformException(code: 'UNEXPECTED', message: call.method);
      }
    });
    await tester.pumpWidget(MaterialApp(
      home: const FolderSyncPage(),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('フォルダを選択'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pictures'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('EXIFDateSyncTest'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('このフォルダを選択'));
    await tester.pump();

    // The native scanner may stream rows before it declares the folder complete.
    final packet = const StandardMethodCodec().encodeMethodCall(MethodCall(
      'scanRows',
      [
        {
          'path': '/storage/emulated/0/Pictures/EXIFDateSyncTest/photo.jpg',
          'relativePath': 'photo.jpg',
          'status': 'NEEDS_UPDATE',
          'targetMs': 1710000000000,
          'beforeMs': 1760000000000,
          'size': 512,
          'dateSource': 'DateTimeOriginal',
          'offset': '+09:00',
        },
      ],
    ));
    unawaited(messenger.handlePlatformMessage(native.name, packet, null));
    await tester.pump();
    await tester.pump();

    expect(find.text('photo.jpg'), findsOneWidget);
    // The current row has one filename/status line and two date lines.
    expect(tester.getSize(find.byKey(
      const ValueKey('photo-row-photo.jpg'),
    )).height, lessThan(112));
    expect(find.textContaining('1件選択'), findsOneWidget);
    final update = tester.widget<FilledButton>(find.widgetWithText(
      FilledButton, '選択した1件の変更日時を更新',
    ));
    expect(update.onPressed, isNull, reason: 'No writing while scan is incomplete');

    await tester.tap(find.text('中止'));
    await tester.pumpAndSettle();
    expect(find.textContaining('スキャン中止'), findsOneWidget);
    final afterCancel = tester.widget<FilledButton>(find.widgetWithText(
      FilledButton, '選択した1件の変更日時を更新',
    ));
    expect(afterCancel.onPressed, isNull, reason: 'Cancelled scan is incomplete');
    expect(calls, isNot(contains('applyBatch')));
  });

  testWidgets('completed scan requires explicit confirmation before update', (tester) async {
    tester.view.physicalSize = const Size(480, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final scanResult = Completer<Map<String, Object>>();
    var scanCount = 0;
    messenger.setMockMethodCallHandler(native, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'hasPermission':
          return true;
        case 'lastBatch':
          return <String, Object>{'exists': false};
        case 'rootFolders':
          return [
            {'name': 'Pictures', 'path': '/storage/emulated/0/Pictures'},
          ];
        case 'childFolders':
          return [
            {'name': 'PhotoCopies',
             'path': '/storage/emulated/0/Pictures/PhotoCopies'},
          ];
        case 'scanFolder':
          if (scanCount++ == 0) return scanResult.future;
          return {'complete': true, 'included': 1, 'excluded': 0,
            'failedDirectories': 0};
        case 'thumbnail':
          final args = Map<String, dynamic>.from(call.arguments as Map);
          calls.add('thumbnail:${args['relativePath']}');
          return null;
        case 'openFile':
          final args = Map<String, dynamic>.from(call.arguments as Map);
          expect(args['root'], '/storage/emulated/0/Pictures/PhotoCopies');
          expect(args['relativePath'], 'photo.jpg');
          return null;
        case 'applyBatch':
          return {'applied': 1, 'failed': 0};
        default:
          throw PlatformException(code: 'UNEXPECTED', message: call.method);
      }
    });
    await tester.pumpWidget(MaterialApp(
      home: const FolderSyncPage(),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('フォルダを選択'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pictures'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('PhotoCopies'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('このフォルダを選択'));
    await tester.pump();

    final packet = const StandardMethodCodec().encodeMethodCall(MethodCall(
      'scanRows',
      [
        {
          'path': '/storage/emulated/0/Pictures/PhotoCopies/untouched.jpg',
          'relativePath': 'untouched.jpg',
          'status': 'UNCHANGED',
          'targetMs': 1710000000000,
          'beforeMs': 1710000000000,
          'size': 512,
        },
        {
          'path': '/storage/emulated/0/Pictures/PhotoCopies/photo.jpg',
          'relativePath': 'photo.jpg',
          'status': 'NEEDS_UPDATE',
          'targetMs': 1710000000000,
          'beforeMs': 1760000000000,
          'size': 512,
          'dateSource': 'DateTimeOriginal',
          'offset': '+09:00',
        },
      ],
    ));
    unawaited(messenger.handlePlatformMessage(native.name, packet, null));
    await tester.pump();
    // During scanning the native discovery order is shown without repeated sorts.
    expect(tester.getTopLeft(find.text('untouched.jpg')).dy,
        lessThan(tester.getTopLeft(find.text('photo.jpg')).dy));
    scanResult.complete({
      'complete': true, 'included': 2, 'excluded': 0,
      'failedDirectories': 0,
    });
    await tester.pumpAndSettle();
    // On completion actionable rows are sorted first as before.
    expect(tester.getTopLeft(find.text('photo.jpg')).dy,
        lessThan(tester.getTopLeft(find.text('untouched.jpg')).dy));

    // Filename opens the on-demand thumbnail, without altering selection.
    await tester.tap(find.text('photo.jpg'));
    await tester.pumpAndSettle();
    expect(find.text('プレビューできません'), findsOneWidget);
    expect(calls.where((name) => name == 'thumbnail'), hasLength(1));
    expect(find.text('1件選択'), findsOneWidget);
    expect(find.text('1 / 2'), findsOneWidget);
    await tester.tap(find.text('次へ ›'));
    await tester.pumpAndSettle();
    expect(find.text('2 / 2'), findsOneWidget);
    expect(calls, contains('thumbnail:untouched.jpg'));
    await tester.fling(find.text('プレビューできません'), const Offset(160, 0), 600);
    await tester.pumpAndSettle();
    expect(find.text('1 / 2'), findsOneWidget);
    expect(find.text('1件選択'), findsOneWidget);
    await tester.tap(find.text('閉じる'));
    await tester.pumpAndSettle();

    // External viewer remains independent of metadata editing and Undo.
    final photoOpenButton = find.descendant(
      of: find.byKey(const ValueKey('photo-row-photo.jpg')),
      matching: find.byTooltip('関連付けアプリで開く'),
    );
    expect(photoOpenButton, findsOneWidget);
    await tester.tap(photoOpenButton);
    await tester.pumpAndSettle();
    expect(calls.where((name) => name == 'openFile'), hasLength(1));
    expect(calls, isNot(contains('applyBatch')));
    expect(calls, isNot(contains('undoLastBatch')));
    expect(find.text('1件選択'), findsOneWidget);

    final update = tester.widget<FilledButton>(find.widgetWithText(
      FilledButton, '選択した1件の変更日時を更新',
    ));
    expect(update.onPressed, isNotNull);
    await tester.tap(find.text('選択した1件の変更日時を更新'));
    await tester.pumpAndSettle();
    expect(find.text('ファイルの変更日時を更新しますか？'), findsOneWidget);
    expect(calls, isNot(contains('applyBatch')));

    await tester.tap(find.text('キャンセル'));
    await tester.pumpAndSettle();
    expect(calls, isNot(contains('applyBatch')));

    await tester.tap(find.text('選択した1件の変更日時を更新'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('更新する'));
    await tester.pumpAndSettle();
    expect(calls.where((name) => name == 'applyBatch'), hasLength(1));
    expect(scanCount, 2);
    expect(find.text('更新結果：成功 1件、失敗 0件。'), findsOneWidget);
  });


  testWidgets('latest-batch Undo is not invoked when user cancels', (tester) async {
    tester.view.physicalSize = const Size(480, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    messenger.setMockMethodCallHandler(native, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'hasPermission':
          return true;
        case 'lastBatch':
          return <String, Object>{
            'exists': true, 'canUndo': true, 'total': 1,
            'applied': 1, 'failed': 0, 'undone': 0,
          };
        default:
          throw PlatformException(code: 'UNEXPECTED', message: call.method);
      }
    });

    await tester.pumpWidget(MaterialApp(
      home: const FolderSyncPage(),
    ));
    await tester.pumpAndSettle();
    expect(find.text('直近の処理をUndo'), findsOneWidget);
    await tester.tap(find.text('直近の処理をUndo'));
    await tester.pumpAndSettle();
    expect(find.text('直近の処理をUndoしますか？'), findsOneWidget);
    expect(calls, isNot(contains('undoLastBatch')));
    await tester.tap(find.text('キャンセル'));
    await tester.pumpAndSettle();
    expect(calls, isNot(contains('undoLastBatch')));
  });


  testWidgets('Undo result is visible after restart without choosing a folder',
      (tester) async {
    tester.view.physicalSize = const Size(480, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    messenger.setMockMethodCallHandler(native, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'hasPermission':
          return true;
        case 'lastBatch':
          return <String, Object>{
            'exists': true, 'canUndo': true, 'applied': 1,
          };
        case 'undoLastBatch':
          return <String, Object>{'restored': 1, 'conflicts': 0};
        default:
          throw PlatformException(code: 'UNEXPECTED', message: call.method);
      }
    });

    await tester.pumpWidget(const MaterialApp(home: FolderSyncPage()));
    await tester.pumpAndSettle();
    expect(find.text('フォルダ未選択'), findsOneWidget);
    await tester.tap(find.text('直近の処理をUndo'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Undoする'));
    await tester.pumpAndSettle();

    expect(find.text('Undo：復元 1件、要確認 0件'), findsOneWidget);
    expect(calls.where((method) => method == 'undoLastBatch'), hasLength(1));
    expect(calls, isNot(contains('scanFolder')));
  });

  testWidgets('revoke permission on resume disables Undo', (tester) async {
    tester.view.physicalSize = const Size(480, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    bool permissionAllowed = true;
    messenger.setMockMethodCallHandler(native, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'hasPermission':
          return permissionAllowed;
        case 'lastBatch':
          return <String, Object>{
            'exists': true, 'canUndo': true, 'total': 2,
            'applied': 1, 'failed': 1, 'undone': 0,
          };
        default:
          throw PlatformException(code: 'UNEXPECTED', message: call.method);
      }
    });

    await tester.pumpWidget(MaterialApp(
      home: const FolderSyncPage(),
    ));
    await tester.pumpAndSettle();

    OutlinedButton undo() => tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, '直近の処理をUndo'),
    );

    expect(undo().onPressed, isNotNull);

    permissionAllowed = false;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(undo().onPressed, isNull);
    expect(calls, isNot(contains('undoLastBatch')));
  });

  testWidgets('permission check exception fails closed on resume', (tester) async {
    tester.view.physicalSize = const Size(480, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    bool permissionLookupFails = false;
    messenger.setMockMethodCallHandler(native, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'hasPermission':
          if (permissionLookupFails) {
            throw PlatformException(code: 'PERMISSION', message: 'Permission lookup failed');
          }
          return true;
        case 'lastBatch':
          return <String, Object>{
            'exists': true, 'canUndo': true, 'total': 2,
            'applied': 1, 'failed': 1, 'undone': 0,
          };
        default:
          throw PlatformException(code: 'UNEXPECTED', message: call.method);
      }
    });

    await tester.pumpWidget(MaterialApp(
      home: const FolderSyncPage(),
    ));
    await tester.pumpAndSettle();
    permissionLookupFails = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    final undo = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, '直近の処理をUndo'),
    );
    expect(undo.onPressed, isNull);
    expect(find.textContaining('権限確認エラー'), findsOneWidget);
  });

}
