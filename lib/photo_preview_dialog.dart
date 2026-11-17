import 'dart:typed_data';
import 'photo_date_format.dart';

import 'package:flutter/material.dart';

/// Displays one thumbnail at a time in the order of the visible list.
Future<int> showPhotoPreview({
  required BuildContext context,
  required List<String> paths,
  required int initialIndex,
  required List<Map<String, dynamic>> rows,
  required Future<Uint8List?> Function(String path) loadThumbnail,
  required ValueChanged<String> openExternal,
}) async {
  var index = initialIndex;
  var generation = 0;
  var thumbnail = loadThumbnail(paths[index]);
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(builder: (context, setState) {
      void move(int step) {
        final next = index + step;
        if (next < 0 || next >= paths.length) return;
        setState(() {
          index = next;
          final request = ++generation;
          // Keep one native request in flight. Skip requests for passed images.
          thumbnail = thumbnail.then((_) {
            if (request != generation || !dialogContext.mounted) return null;
            return loadThumbnail(paths[next]);
          });
        });
      }

      return AlertDialog(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(paths[index].split('/').last,
                maxLines: 2, overflow: TextOverflow.ellipsis),
            Text('${index + 1} / ${paths.length}',
                style: Theme.of(context).textTheme.bodyMedium),
          ],
        ),
        scrollable: true,
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(
            width: 460,
            height: (MediaQuery.sizeOf(dialogContext).height * 0.38)
                .clamp(100.0, 420.0)
                .toDouble(),
            child: GestureDetector(
              onHorizontalDragEnd: (details) {
                final velocity = details.primaryVelocity ?? 0;
                if (velocity.abs() > 100) move(velocity < 0 ? 1 : -1);
              },
              child: FutureBuilder<Uint8List?>(
                key: ValueKey(index),
                future: thumbnail,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final bytes = snapshot.data;
                  if (bytes == null || bytes.isEmpty || snapshot.hasError) {
                    return const Center(child: Text('プレビューできません'));
                  }
                  return Image.memory(
                    bytes,
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stackTrace) =>
                        const Center(child: Text('プレビューできません')),
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                  'フォルダ：${paths[index].contains('/') ? paths[index].substring(0, paths[index].lastIndexOf('/')) : '選択したフォルダ'}'),
              Text('撮影：${formatJstTimestamp(rows[index]['targetMs'])}'),
              Text('変更：${formatJstTimestamp(rows[index]['beforeMs'])}'),
              Text(switch (rows[index]['status']) {
                'NEEDS_UPDATE' => '要更新',
                'UNCHANGED' => '変更不要',
                'NO_DATE' => '撮影日時なし',
                _ => '読み取りエラー',
              }),
            ]),
          ),
        ]),
        actions: [
          TextButton(
            onPressed: index > 0 ? () => move(-1) : null,
            child: const Text('‹ 前へ'),
          ),
          TextButton(
            onPressed: index + 1 < paths.length ? () => move(1) : null,
            child: const Text('次へ ›'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('閉じる'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              openExternal(paths[index]);
            },
            child: const Text('関連付けアプリで開く'),
          ),
        ],
      );
    }),
  );
  return index;
}
