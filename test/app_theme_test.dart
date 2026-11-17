import 'package:exif_date_sync/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Material 3 remains enabled in light and dark modes', () {
    final light = AppTheme.light();
    final dark = AppTheme.dark();

    expect(light.useMaterial3, isTrue);
    expect(dark.useMaterial3, isTrue);
    expect(light.brightness, Brightness.light);
    expect(dark.brightness, Brightness.dark);
    expect(light.colorScheme.primary, isNot(dark.colorScheme.primary));
    expect(
      light.filledButtonTheme.style?.minimumSize?.resolve({})?.height,
      48,
    );
    expect(
      dark.outlinedButtonTheme.style?.minimumSize?.resolve({})?.height,
      48,
    );
  });

  testWidgets('default buttons and checkbox are still standard Material widgets',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      home: const Scaffold(
        body: Column(children: [
          FilledButton(onPressed: null, child: Text('変更日時を更新')),
          OutlinedButton(onPressed: null, child: Text('再スキャン')),
          Checkbox(value: false, onChanged: null),
        ]),
      ),
    ));

    expect(find.byType(FilledButton), findsOneWidget);
    expect(find.byType(OutlinedButton), findsOneWidget);
    expect(find.byType(Checkbox), findsOneWidget);
  });
}
