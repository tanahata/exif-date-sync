import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('obsolete prototypes and dated instructions are not active files', () {
    for (final path in [
      'macos/exif_date_sync.py',
      'android/probe/MainActivity.kt',
      'docs/CODEX_HANDOFF.md',
      'docs/UI_REVIEW.md',
      'docs/ANDROID_PROBE.md',
      'docs/ANDROID_STORAGE.md',
      'docs/INTEGRATION_AND_HOME_TEST.md',
    ]) {
      expect(File(path).existsSync(), isFalse, reason: path);
    }
  });

  test('both pages delegate photo rows to the extracted widgets', () {
    final androidPage = File('lib/folder_sync_page.dart').readAsStringSync();
    final macPage = File('lib/macos_exif_preview_page.dart').readAsStringSync();
    expect(androidPage, contains('AndroidPhotoRow('));
    expect(androidPage, contains('FolderBrowserDialog('));
    expect(androidPage, isNot(contains('class _FolderBrowserDialog')));
    expect(macPage, contains('MacPhotoRow('));
    expect(androidPage, isNot(contains('String _jst(')));
    expect(macPage, isNot(contains('String _date(')));
  });

  test('single current source of truth is documented', () {
    final instructions = File('AGENTS.md').readAsStringSync();
    for (final current in [
      'docs/SPEC.md',
      'docs/WORK_TEST_RUNBOOK.md',
      'docs/RELEASE.md',
      'lib/photo_date_format.dart',
      'lib/photo_preview_dialog.dart',
    ]) {
      expect(instructions, contains(current));
    }
  });
}
