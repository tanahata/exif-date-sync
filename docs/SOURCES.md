# EXIF Date Sync｜採用した標準APIと一次資料

この文書は**実装の根拠の参照先**です。外部仕様は変わるため、コードを変更する際に必要な箇所だけ公式文書を再確認してください。掲載は実機での動作保証ではありません。

## 撮影日時・mtime

- [ExifTool](https://exiftool.org/)／[FileModifyDate等のオプション](https://exiftool.org/exiftool_pod.html)／[ExifTool FAQ](https://exiftool.org/faq.html)
- [AndroidX ExifInterface](https://developer.android.com/reference/androidx/exifinterface/media/ExifInterface)（DateTimeOriginal、RAW・HEICの読取、埋め込みサムネイル）
- [Adobe XMP EXIF namespace](https://developer.adobe.com/xmp/docs/xmp-namespaces/exif/)（EXIFの日時タグとXMPは別。代替タグへフォールバックしない）
- [Android File.setLastModified](https://developer.android.com/reference/java/io/File#setLastModified(long))／[Android Os.lstat](https://developer.android.com/reference/android/system/Os)（mtimeとファイル識別）

## 縮小プレビュー・外部アプリ起動

- [Apple Quick Look Thumbnailing](https://developer.apple.com/documentation/quicklookthumbnailing/qlthumbnailgenerator)（対応形式に依存するmacOS縮小画像）
- [Android ThumbnailUtils](https://developer.android.com/reference/android/media/ThumbnailUtils)（約480pxの縮小画像、RAWは取得可否を保証しない）
- [Android FileProvider](https://developer.android.com/reference/androidx/core/content/FileProvider)／[ファイル共有](https://developer.android.com/training/secure-file-sharing)（外部アプリへの一時的な読取権限）
- [Flutter platform channels](https://docs.flutter.dev/platform-integration/platform-channels)（既存のMac/Android橋渡し）

## ファイルアクセス・デザイン・配布

- [Androidの全ファイルアクセス](https://developer.android.com/training/data-storage/manage-all-files)／[Storage Access Framework](https://developer.android.com/training/data-storage/shared/documents-files)
- [Apple App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)（現行個人用macOSビルドではSandbox無効）
- [Flutter macOSのビルド](https://docs.flutter.dev/platform-integration/macos/building)
- [デジタル庁デザインシステム](https://design.digital.go.jp/dads/)（可読性・アクセシビリティの参考）

公式APIの参照先一覧です。**実機の対応保証や現在のテスト合格を意味しません。** 最新の受入・未実施事項は[WORK_TEST_RUNBOOK.md](WORK_TEST_RUNBOOK.md)、公開判断は[RELEASE.md](RELEASE.md)に一本化します。
