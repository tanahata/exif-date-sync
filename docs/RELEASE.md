# 配布

[GitHub Releases](https://github.com/tanahata/exif-date-sync/releases)でmacOS用ZIPとAndroid用APKを配布します。導入手順と既知の制約は[README](../README.md)を、SHA-256は各リリースを参照してください。

## 採用アイコンの保管先（再ビルド時の確認用）

- 現行の正式原稿は `exif_date_sync_icon_v3_corners_clean.png`（PNG、1254×1254、1,439,746バイト）。SHA-256：`edda9fbbd569dacfece556769597912b366fc7561ba9f29c235944e1ab6595c0`。
- 原稿は所有者の非公開Google Drive「EXIF Date Sync - アイコン原稿（V1-V3）」に保管しています。V1・V2は過去案です。公開リポジトリには原稿PNGを含めていません。
- `scripts/generate_android_host.sh` / `scripts/generate_macos_host.sh` はFlutterのホストを生成しますが、正式アイコンのPNGは自動適用しません。新しい環境でビルドする場合は、原稿のSHA-256を照合してから対応するMac・Android用アイコンを適用し、実際の表示を確認してください。
- 画像の作り直し、古い版への差し替え、EXIF Marginの別アイコンの流用は不要です。アプリ本体の仕様や既存配布物は変更しません。
