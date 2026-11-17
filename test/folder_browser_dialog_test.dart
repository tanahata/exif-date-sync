import 'package:exif_date_sync/folder_browser_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.exifdatesync/storage_probe');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  testWidgets('folder load failure does not display stale parent rows',
      (tester) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'rootFolders') {
        return [
          {'name': 'Pictures', 'path': '/storage/emulated/0/Pictures'},
        ];
      }
      if (call.method == 'childFolders') {
        throw PlatformException(
          code: 'FOLDERS', message: 'フォルダを読み込めません',
        );
      }
      throw PlatformException(code: 'UNEXPECTED', message: call.method);
    });

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: FolderBrowserDialog()),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Pictures'), findsOneWidget);

    await tester.tap(find.text('Pictures'));
    await tester.pumpAndSettle();

    expect(find.textContaining('読み込み失敗'), findsOneWidget);
    expect(find.text('Pictures'), findsNothing);
    expect(find.text('このフォルダを選択'), findsOneWidget);
  });
}
