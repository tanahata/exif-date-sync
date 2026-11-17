import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'app_theme.dart';
import 'folder_sync_page.dart';
import 'macos_exif_preview_page.dart';

void main() => runApp(const ExifDateSyncApp());

/// Unified entrypoint for the personal macOS and Android mtime tool.
class ExifDateSyncApp extends StatelessWidget {
  const ExifDateSyncApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'EXIF Date Sync',
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: ThemeMode.system,
        home: Platform.isMacOS
            ? const MacExifPreviewPage()
            : const FolderSyncPage(),
      );
}
