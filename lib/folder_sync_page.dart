
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'photo_preview_dialog.dart';
import 'android_photo_row.dart';
import 'folder_browser_dialog.dart';

/// Android shared-storage frontend. Native methods own filesystem writes.
/// The native layer is responsible for all filesystem access and validation.
class FolderSyncPage extends StatefulWidget {
  const FolderSyncPage({super.key});

  @override
  State<FolderSyncPage> createState() => _FolderSyncPageState();
}

class _FolderSyncPageState extends State<FolderSyncPage>
    with WidgetsBindingObserver {
  static const channel = MethodChannel('dev.exifdatesync/storage_probe');
  final List<Map<String, dynamic>> _rows = [];
  final Set<String> _selected = {};
  String? _folder;
  bool _permission = false;
  bool _recursive = false;
  bool _scanning = false;
  bool _scanComplete = false;
  bool _applying = false;
  bool _batchCancelable = false;
  String _sort = 'needsUpdate';
  String _notice = '';
  int _excluded = 0;
  int _failedDirectories = 0;
  Map<String, dynamic> _previous = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    channel.setMethodCallHandler(_nativeEvent);
    _refreshPermission();
    _refreshHistory();
  }

  final ScrollController _listScroll = ScrollController();

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    channel.setMethodCallHandler(null);
    _listScroll.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshPermission();
    }
  }

  Future<void> _nativeEvent(MethodCall call) async {
    if (call.method == 'scanRows' && mounted && _scanning) {
      final batch = (call.arguments as List).map(
        (item) => Map<String, dynamic>.from(item as Map),
      );
      setState(() {
        for (final row in batch) {
          _rows.add(row);
          if (row['status'] == 'NEEDS_UPDATE') {
            _selected.add(row['path'] as String);
          }
        }
      });
    }
    if (call.method == 'batchProgress' && mounted) {
      final progress = Map<String, dynamic>.from(call.arguments as Map);
      setState(() {
        _notice = '処理中：${progress['done']}/${progress['total']}件'
            '（成功 ${progress['applied']}件・失敗 ${progress['failed']}件）';
      });
    }
  }

  Future<void> _refreshPermission() async {
    try {
      final allowed = await channel.invokeMethod<bool>('hasPermission') ?? false;
      if (mounted) setState(() {
        _permission = allowed;
        if (!allowed) _scanComplete = false;
      });
    } on PlatformException catch (error) {
      // Fail closed: a permission read error cannot be treated as approval.
      if (mounted) setState(() {
        _permission = false;
        _scanComplete = false;
      });
      _notify('権限確認エラー: ${error.message}');
    } on MissingPluginException {
      if (mounted) setState(() {
        _permission = false;
        _scanComplete = false;
      });
      _notify('Android版のファイルアクセス機能を確認できません。');
    }
  }

  Future<void> _refreshHistory() async {
    try {
      final result = await channel.invokeMapMethod<String, dynamic>('lastBatch');
      if (mounted) setState(() => _previous = result ?? {});
    } on MissingPluginException {
      // Mac platform channel is not yet implemented.
    } on PlatformException catch (error) {
      _notify('Undo履歴の確認に失敗: ${error.message}');
    }
  }

  void _notify(String message) {
    if (mounted) setState(() => _notice = message);
  }

  Future<void> _openSettings() async {
    try {
      await channel.invokeMethod<void>('openPermissionSettings');
    } on PlatformException catch (error) {
      _notify('設定を開けません: ${error.message}');
    }
  }

  Future<void> _chooseFolder() async {
    if (!_permission || _scanning || _applying) return;
    final path = await showDialog<String>(
      context: context,
      builder: (_) => const FolderBrowserDialog(),
    );
    if (path == null || !mounted) return;
    setState(() => _folder = path);
    await _scan();
  }

  Future<void> _scan({String? resultMessage}) async {
    if (_folder == null || !_permission || _scanning || _applying) return;
    setState(() {
      _scanning = true;
      _scanComplete = false;
      _rows.clear();
      _selected.clear(); // Re-scan intentionally resets all manual checks.
      _excluded = 0;
      _failedDirectories = 0;
      _notice = 'EXIFを解析しています。全件完了まで更新できません。';
    });
    try {
      final result = await channel.invokeMapMethod<String, dynamic>(
        'scanFolder', {'path': _folder, 'recursive': _recursive},
      );
      if (!mounted) return;
      setState(() {
        _excluded = (result?['excluded'] as num?)?.toInt() ?? 0;
        _failedDirectories = (result?['failedDirectories'] as num?)?.toInt() ?? 0;
        _scanComplete = result?['complete'] == true && _failedDirectories == 0;
        _notice = _scanComplete
            ? resultMessage ?? 'スキャン完了：対象${_rows.length}件・対象外$_excluded件'
            : _failedDirectories > 0
                ? '読み取れないフォルダがあるため、日時更新を禁止しました。'
                : 'スキャン中止：一覧は不完全です。更新するには再スキャンしてください。';
      });
    } on PlatformException catch (error) {
      _notify('スキャン失敗：${error.message}。日時更新はできません。');
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _cancelScan() async {
    if (!_scanning) return;
    _notify('安全な位置でスキャンを停止しています…');
    await channel.invokeMethod<void>('cancelScan');
  }

  Future<void> _cancelBatch() async {
    if (!_applying) return;
    _notify('ファイル単位で処理を中止しています…');
    await channel.invokeMethod<void>('cancelBatch');
  }

  List<Map<String, dynamic>> get _sorted {
    // During a progressive scan, append in discovery order. Sort once at completion.
    if (_scanning) return _rows;
    final ordered = [..._rows];
    int compare(Map<String, dynamic> a, Map<String, dynamic> b) {
      final nameA = (a['relativePath'] as String? ?? '').toLowerCase();
      final nameB = (b['relativePath'] as String? ?? '').toLowerCase();
      int compareTime(String key) {
        final timeA = (a[key] as num?)?.toInt();
        final timeB = (b[key] as num?)?.toInt();
        // Unknown dates stay at the end.
        if (timeA == null && timeB == null) return 0;
        if (timeA == null) return 1;
        if (timeB == null) return -1;
        return timeA.compareTo(timeB);
      }
      final value = switch (_sort) {
        'needsUpdate' => (b['status'] == 'NEEDS_UPDATE' ? 1 : 0)
            .compareTo(a['status'] == 'NEEDS_UPDATE' ? 1 : 0),
        'captureAsc' => compareTime('targetMs'),
        _ => nameA.compareTo(nameB),
      };
      return value != 0 ? value : nameA.compareTo(nameB);
    }
    ordered.sort(compare);
    return ordered;
  }

  void _checkAll(bool checked) {
    if (_scanning || _applying || !_scanComplete) return;
    setState(() {
      _selected.clear();
      if (checked) {
        for (final row in _rows) {
          if (row['status'] == 'NEEDS_UPDATE') _selected.add(row['path'] as String);
        }
      }
    });
  }

  Future<void> _previewImage(List<Map<String, dynamic>> rows, int index,
      double rowHeight) async {
    if (_folder == null || !_permission || _scanning || _applying) return;
    final folder = _folder!;
    final last = await showPhotoPreview(
      context: context,
      paths: rows.map((row) => (row['relativePath'] ?? row['path']) as String).toList(),
      initialIndex: index,
      rows: rows,
      loadThumbnail: (relativePath) async {
        try {
          return await channel.invokeMethod<Uint8List>('thumbnail', {
            'root': folder,
            'relativePath': relativePath,
          });
        } catch (_) {
          return null;
        }
      },
      openExternal: _openImage,
    );
    if (!mounted || _folder != folder || !_listScroll.hasClients || last == index) return;
    _listScroll.jumpTo((last * rowHeight).clamp(0.0, _listScroll.position.maxScrollExtent));
  }

  Future<void> _openImage(String relativePath) async {
    if (_folder == null || !_permission || _scanning || _applying) return;
    try {
      await channel.invokeMethod<void>('openFile', {
        'root': _folder,
        'relativePath': relativePath,
      });
    } on PlatformException catch (error) {
      _notify('画像を開けませんでした：${error.message ?? error.code}');
    } on MissingPluginException {
      _notify('端末の写真起動機能を確認できません。');
    }
  }

  Future<void> _apply() async {
    if (!_permission || !_scanComplete || _scanning || _applying || _selected.isEmpty) return;
    final chosen = _rows.where((row) => _selected.contains(row['path'])).toList();
    final existingUndo = _previous['exists'] == true;
    final approved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ファイルの変更日時を更新しますか？'),
        content: Text(
          '選択した${chosen.length}件のファイル変更日時を、撮影日時に合わせます。'
          '${existingUndo ? '\n\n前回のUndo情報は新しい処理で置き換わります。' : ''}',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false),
              child: const Text('キャンセル')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true),
              child: const Text('更新する')),
        ],
      ),
    );
    if (approved != true || !mounted) return;
    setState(() {
      _applying = true;
      _batchCancelable = true;
      _scanComplete = false; // Cannot start another batch from stale preview.
      _notice = '変更処理を開始します…';
    });
    String? resultMessage;
    try {
      final result = await channel.invokeMapMethod<String, dynamic>(
        'applyBatch', {'root': _folder, 'selected': chosen},
      );
      resultMessage = '更新結果：成功 ${result?['applied'] ?? 0}件、'
          '失敗 ${result?['failed'] ?? 0}件。';
      await _refreshHistory();
    } on PlatformException catch (error) {
      resultMessage = '更新できませんでした：${error.message}';
    } finally {
      if (mounted) setState(() => _applying = false);
      // Refresh the list without erasing the operation result.
      if (mounted) await _scan(resultMessage: resultMessage);
    }
  }

  Future<void> _undo() async {
    if (_scanning || _applying || _previous['exists'] != true) return;
    final agreed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('直近の処理をUndoしますか？'),
        content: const Text('直近の処理で変更されたファイルを確認し、復元できるものだけ元の変更日時に戻します。'
            'ファイルが移動・変更されていれば、そのファイルは復元せず記録します。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false),
              child: const Text('キャンセル')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Undoする')),
        ],
      ),
    );
    if (agreed != true || !mounted) return;
    setState(() { _applying = true; _batchCancelable = false; });
    String? resultMessage;
    try {
      final result = await channel.invokeMapMethod<String, dynamic>('undoLastBatch');
      resultMessage = 'Undo：復元 ${result?['restored'] ?? 0}件、'
          '要確認 ${result?['conflicts'] ?? 0}件';
      await _refreshHistory();
    } on PlatformException catch (error) {
      resultMessage = 'Undoエラー：${error.message}';
    } finally {
      if (mounted) setState(() => _applying = false);
      if (mounted) {
        if (_folder == null) {
          if (resultMessage != null) _notify(resultMessage);
        } else {
          await _scan(resultMessage: resultMessage);
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final rowHeight = 32 + 3 * MediaQuery.textScalerOf(context).scale(14);
    final sorted = _sorted; // Sort once per rebuild, not once per ListView row.
    final filesToUpdate = _rows.where(
      (row) => row['status'] == 'NEEDS_UPDATE',
    ).length;
    final running = _scanning || _applying;
    return Scaffold(
      appBar: AppBar(title: const Text('EXIF Date Sync')),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!_permission)
                    Wrap(
                      spacing: 8,
                      children: [
                        OutlinedButton(onPressed: _openSettings,
                            child: const Text('ファイルアクセスを許可')),
                        TextButton(onPressed: _refreshPermission,
                            child: const Text('許可状態を確認')),
                      ],
                    )
                  else
                    Wrap(
                      spacing: 8,
                      children: [
                        FilledButton.tonal(
                          onPressed: running ? null : _chooseFolder,
                          child: const Text('フォルダを選択'),
                        ),
                        IconButton(
                          tooltip: '再スキャン',
                          onPressed: running || _folder == null ? null : _scan,
                          icon: const Icon(Icons.refresh),
                        ),
                      ],
                    ),
                  Text(_folder ?? 'フォルダ未選択', maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    Checkbox(
                      visualDensity: VisualDensity.compact,
                      value: _recursive,
                      onChanged: running ? null : (value) async {
                        setState(() => _recursive = value ?? false);
                        if (_folder != null) await _scan();
                      },
                    ),
                    const Text('サブフォルダを含める'),
                  ]),
                  if (_scanning)
                    Row(children: [
                      const Expanded(child: LinearProgressIndicator()),
                      TextButton(onPressed: _cancelScan, child: const Text('中止')),
                    ]),
                  if (_applying)
                    Row(children: [
                      const Expanded(child: LinearProgressIndicator()),
                      TextButton(onPressed: _batchCancelable ? _cancelBatch : null,
                          child: Text(_batchCancelable ? '中止' : '復元中')),
                    ]),
                  if (_notice.isNotEmpty) Text(_notice, style: const TextStyle(fontSize: 12)),
                  if (_failedDirectories > 0)
                    Text('読めないフォルダ：$_failedDirectories件',
                        style: const TextStyle(fontSize: 12)),
                  const SizedBox(height: 2),
                  Wrap(spacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    Text('一覧 ${_rows.length}件 ／ 要更新 $filesToUpdate件',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    DropdownButton<String>(
                      value: _sort,
                      isDense: true,
                      onChanged: (value) => setState(() => _sort = value ?? 'needsUpdate'),
                      items: const [
                        DropdownMenuItem(value: 'needsUpdate', child: Text('要更新優先')),
                        DropdownMenuItem(value: 'filenameAsc', child: Text('ファイル名順')),
                        DropdownMenuItem(value: 'captureAsc', child: Text('撮影日時順')),
                      ],
                    ),
                  ]),
                  Row(children: [
                    TextButton(onPressed: _scanComplete && !running
                        ? () => _checkAll(true) : null, child: const Text('全選択')),
                    TextButton(onPressed: _scanComplete && !running
                        ? () => _checkAll(false) : null, child: const Text('全解除')),
                    const Spacer(),
                    Text('${_selected.length}件選択'),
                  ]),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                controller: _listScroll,
                itemExtent: rowHeight,
                itemCount: _rows.length,
                itemBuilder: (context, index) {
                  final row = sorted[index];
                  final path = row['path'] as String;
                  final enabled = _scanComplete && !running &&
                      row['status'] == 'NEEDS_UPDATE';
                  final relative = row['relativePath'] as String? ?? path;
                  return AndroidPhotoRow(
                    key: ValueKey('photo-row-$relative'),
                    row: row,
                    selected: _selected.contains(path),
                    onSelected: enabled ? (checked) => setState(() {
                      if (checked == true) {
                        _selected.add(path);
                      } else {
                        _selected.remove(path);
                      }
                    }) : null,
                    onPreview: _permission && !running
                        ? () => _previewImage(sorted, index, rowHeight) : null,
                    onOpenExternal: _permission && !running
                        ? () => _openImage(relative) : null,
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Column(children: [
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _permission && _scanComplete && !running && _selected.isNotEmpty
                        ? _apply : null,
                    child: Text('選択した${_selected.length}件の変更日時を更新'),
                  ),
                ),
                if (_previous['canUndo'] == true)
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: running || !_permission ? null : _undo,
                      child: const Text('直近の処理をUndo'),
                    ),
                  ),
              ]),
            ),
          ],
        ),
      ),
    );
  }

}
