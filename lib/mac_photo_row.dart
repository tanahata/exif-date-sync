import 'package:flutter/material.dart';
import 'photo_date_format.dart';

/// A single macOS table row. Sorting and selection stay in the parent page.
class MacPhotoRow extends StatelessWidget {
  const MacPhotoRow({
    super.key,
    required this.row,
    required this.selected,
    this.previewed = false,
    this.onSelected,
    this.onPreview,
  });

  final Map<String, dynamic> row;
  final bool selected;
  final bool previewed;
  final ValueChanged<bool?>? onSelected;
  final VoidCallback? onPreview;

  static String statusLabel(Object? status) => switch (status) {
        'NEEDS_UPDATE' => '要更新',
        'UNCHANGED' => '変更不要',
        'UPDATED' => '更新済み',
        'UPDATE_FAILED' => '更新失敗（スキップ）',
        'NO_DATE' => '日時なし',
        _ => '読み取りエラー',
      };

  @override
  Widget build(BuildContext context) {
    final relative = row['relativePath'] as String? ?? '';
    final error = row['status'] == 'ERROR' || row['status'] == 'UPDATE_FAILED';

    final status = statusLabel(row['status']);
    return Material(
      color:
          previewed ? Theme.of(context).colorScheme.secondaryContainer : null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPreview,
        child: Row(
          children: [
            SizedBox(
              width: 44,
              child: Checkbox(
                visualDensity: VisualDensity.compact,
                value: selected,
                onChanged: onSelected,
              ),
            ),
            Expanded(
              flex: 4,
              child: Tooltip(
                message: '$relative\n縮小プレビューを表示',
                child: TextButton(
                  onPressed: onPreview,
                  style: TextButton.styleFrom(
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                  ),
                  child: Text(
                    relative,
                    textAlign: TextAlign.left,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
            Expanded(
              flex: 3,
              child: Text(
                formatJstTimestamp(row['targetMs']),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Expanded(
              flex: 3,
              child: Text(
                formatJstTimestamp(row['beforeMs']),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Expanded(
              flex: 2,
              child: error
                  ? Tooltip(
                      message: row['message']?.toString() ??
                          '処理できませんでした。ファイル形式とアクセス権を確認してください。',
                      child: Row(
                        children: [
                          Flexible(
                            child:
                                Text(status, overflow: TextOverflow.ellipsis),
                          ),
                          const SizedBox(width: 4),
                          const Icon(Icons.info_outline, size: 16),
                        ],
                      ),
                    )
                  : Text(status),
            ),
          ],
        ),
      ),
    );
  }
}
