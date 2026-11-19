# 開発ガイド

- 現行仕様は `docs/SPEC.md`、試験手順は `docs/WORK_TEST_RUNBOOK.md`、配布情報は `docs/RELEASE.md` を参照してください。
- 日時表示には `lib/photo_date_format.dart`、共通プレビューには `lib/photo_preview_dialog.dart` を使います。
- 書き込み試験には合成画像か試験用コピーを使ってください。

## 次回更新時の正式アイコン管理（2026-11-19 本人確定）

- EXIF Date Syncを次に更新する際、採用済みV3アイコン `exif_date_sync_icon_v3_corners_clean.png` をGitHubのソース管理に含め、`scripts/generate_android_host.sh`・`scripts/generate_macos_host.sh` が再生成時に正式アイコンを適用できるようにする。目的はビルド時のGoogle Drive依存をなくし、GitHubだけで正式アイコンを再現できるようにすること。
- 原稿のSHA-256は `edda9fbbd569dacfece556769597912b366fc7561ba9f29c235944e1ab6595c0`（1254×1254 PNG）。現行の非公開Drive保存原稿を照合して取り込む。**再生成・別案採用・他アプリのアイコン流用はしない。**
- 現行の`*.png`除外・生成ホストのGit除外がある場合、正式アイコン原稿だけを追跡できるように最小限変更する。生成されたOSホストや無関係な写真原本・試作画像・APK/ZIP・署名鍵は登録しない。
- Mac/Androidのホスト再生成後、正式V3がアプリアイコンに反映されることを関連ビルドと必要最小限の表示確認で検証する。既存のv0.1.0 Releaseは変更しない。
- **この記録は次回更新の作業指示であり、現時点で画像追加・生成スクリプト変更・再ビルドを完了した意味ではない。** 現在の原稿保管先は`docs/RELEASE.md`を参照。
