import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A tiny in-app folder picker: only DCIM/Pictures/Download and their descendants.
/// SAF directory URIs are intentionally not converted into direct paths.
class FolderBrowserDialog extends StatefulWidget {
  const FolderBrowserDialog({super.key});

  @override
  State<FolderBrowserDialog> createState() => _FolderBrowserDialogState();
}

class _FolderBrowserDialogState extends State<FolderBrowserDialog> {
  static const channel = MethodChannel('dev.exifdatesync/storage_probe');
  final List<Map<String, String>> _trail = [];
  List<Map<String, String>> _folders = [];
  bool _busy = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
      _folders = []; // Do not show a previous directory's entries after failure.
    });
    try {
      final result = await channel.invokeListMethod<dynamic>(
        _trail.isEmpty ? 'rootFolders' : 'childFolders',
        _trail.isEmpty ? null : {'path': _trail.last['path']},
      );
      if (!mounted) return;
      setState(() => _folders = (result ?? []).map((item) =>
          Map<String, String>.from(item as Map)).toList());
    } on PlatformException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('フォルダを選択'),
        content: SizedBox(
          width: 420,
          height: 380,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_trail.isEmpty ? '本体の共有ストレージ' : _trail.last['path']!,
                maxLines: 2, overflow: TextOverflow.ellipsis),
            Row(children: [
              TextButton.icon(
                onPressed: _busy || _trail.isEmpty ? null : () {
                  setState(() => _trail.removeLast());
                  _load();
                },
                icon: const Icon(Icons.arrow_back),
                label: const Text('戻る'),
              ),
              const Spacer(),
              if (_trail.isNotEmpty)
                FilledButton(
                  onPressed: () => Navigator.pop(context, _trail.last['path']),
                  child: const Text('このフォルダを選択'),
                ),
            ]),
            const Divider(),
            if (_busy) const LinearProgressIndicator(),
            if (_error != null) Text('読み込み失敗：$_error'),
            Expanded(child: ListView.builder(
              itemCount: _folders.length,
              itemBuilder: (ctx, index) {
                final folder = _folders[index];
                return ListTile(
                  dense: true,
                  leading: const Icon(Icons.folder_outlined),
                  title: Text(folder['name'] ?? ''),
                  onTap: _busy ? null : () {
                    setState(() => _trail.add(folder));
                    _load();
                  },
                );
              },
            )),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('閉じる')),
        ],
      );
}
