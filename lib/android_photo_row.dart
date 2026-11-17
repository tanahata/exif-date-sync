import 'package:flutter/material.dart';
import 'photo_date_format.dart';

/// Compact read-only photo information row. Parent owns selection and actions.
class AndroidPhotoRow extends StatelessWidget {
  const AndroidPhotoRow({
    super.key,
    required this.row,
    required this.selected,
    this.onSelected,
    this.onPreview,
    this.onOpenExternal,
  });

  final Map<String, dynamic> row;
  final bool selected;
  final ValueChanged<bool?>? onSelected;
  final VoidCallback? onPreview;
  final VoidCallback? onOpenExternal;

  String get status => switch (row['status']) {
        'NEEDS_UPDATE' => '要更新',
        'UNCHANGED' => '変更不要',
        'NO_DATE' => '撮影日時なし',
        _ => '読み取りエラー',
      };

  @override
  Widget build(BuildContext context) {
    final relative = (row['relativePath'] as String?) ??
        (row['path'] as String?) ?? '';
    final message = row['message'];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Tooltip(
                        message: relative,
                        child: TextButton(
                          onPressed: onPreview,
                          style: TextButton.styleFrom(
                            alignment: Alignment.centerLeft,
                            padding: EdgeInsets.zero,
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            visualDensity: VisualDensity.compact,
                          ),
                          child: Text(
                            relative,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 110),
                      child: Text(
                        status,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
                Text(
                  '撮影：${formatJstTimestamp(row['targetMs'])}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12),
                ),
                Text(
                  '変更：${formatJstTimestamp(row['beforeMs'])}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '関連付けアプリで開く',
            icon: const Icon(Icons.open_in_new),
            onPressed: onOpenExternal,
          ),
          if (status == '読み取りエラー' &&
              message is String && message.isNotEmpty)
            IconButton(
              tooltip: '読み取りエラーの理由',
              icon: const Icon(Icons.info_outline),
              onPressed: () => showDialog<void>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('読み取りエラー'),
                  content: Text(message),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('閉じる'),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
