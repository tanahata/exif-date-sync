import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'mac_photo_row.dart';
import 'photo_date_format.dart';

/// macOS ExifTool frontend for user-selected folders.
class MacExifPreviewPage extends StatefulWidget {
  const MacExifPreviewPage({super.key});

  @override
  State<MacExifPreviewPage> createState() => _MacExifPreviewPageState();
}

class _MacExifPreviewPageState extends State<MacExifPreviewPage> {
  static const _channel = MethodChannel('dev.exifdatesync/macos');
  String? _tool;
  String? _toolError;
  String? _folder;
  String _status = 'フォルダを選択してください。';
  bool _recursive = false;
  bool _includeRaw = true;
  bool _scanning = false;
  bool _scanComplete = false;
  bool _updating = false;
  bool _batchApplying = false;
  bool _cancelRequested = false;
  bool _writeAllowed = false;
  Map<String, dynamic>? _history;
  final Set<String> _selected = {};
  int _excluded = 0;
  int _unreadable = 0;
  final List<Map<String, dynamic>> _rows = [];
  final ScrollController _listScrollController = ScrollController();
  final FocusNode _listFocus = FocusNode(debugLabel: 'Photo list');
  String? _previewPath;
  Timer? _previewDelay;
  Future<Uint8List?>? _thumbnail;
  final _recentThumbnails = <String, Uint8List>{};
  int _previewGeneration = 0;
  bool _thumbnailBusy = false;
  bool _thumbnailQueued = false;
  String _sortColumn = 'status'; // Put actionable rows first on initial scan.
  bool _sortAscending = true;
  bool _onlyNeedsUpdate = false;
  Set<String>? _resultFilterPaths;

  static const _columns = <String, String>{
    'file': 'ファイル',
    'capture': '撮影日時',
    'modified': '現在の変更日時',
    'status': '状態',
  };

  int _statusRank(Object? value) => switch (value) {
    'NEEDS_UPDATE' => 0,
    'UPDATE_FAILED' => 1,
    'UPDATED' => 1,
    'UNCHANGED' => 1,
    'NO_DATE' => 2,
    _ => 3,
  };

  List<Map<String, dynamic>> get _displayRows {
    final sorted = _rows.where((row) => !_onlyNeedsUpdate ||
        (_resultFilterPaths != null
            ? _resultFilterPaths!.contains(row['relativePath'])
            : row['status'] == 'NEEDS_UPDATE')).toList();
    // Keep progressive rows in discovery order; sort after the scan finishes.
    if (_scanning) return sorted;
    sorted.sort((a, b) {
      final fileOrder = (a['relativePath'] as String? ?? '').toLowerCase()
          .compareTo((b['relativePath'] as String? ?? '').toLowerCase());
      int comparison;
      if (_sortColumn == 'file') {
        comparison = fileOrder;
      } else if (_sortColumn == 'status') {
        comparison = _statusRank(a['status']).compareTo(_statusRank(b['status']));
      } else {
        final key = _sortColumn == 'capture' ? 'targetMs' : 'beforeMs';
        final left = (a[key] as num?)?.toInt();
        final right = (b[key] as num?)?.toInt();
        // Missing dates stay at the bottom in either direction.
        if (left == null || right == null) {
          if (left == null && right == null) return fileOrder;
          return left == null ? 1 : -1;
        }
        comparison = left.compareTo(right);
      }
      if (comparison != 0) return _sortAscending ? comparison : -comparison;
      return fileOrder;
    });
    return sorted;
  }

  void _sortBy(String column) {
    _scrollToTop();
    setState(() {
      if (_sortColumn == column) {
        _sortAscending = !_sortAscending;
      } else {
        _sortColumn = column;
        _sortAscending = true;
      }
    });
  }

  void _scrollToTop() {
    if (_listScrollController.hasClients) _listScrollController.jumpTo(0);
  }

  Widget _heading(String column, int flex) {
    final active = _sortColumn == column;
    return Expanded(
      flex: flex,
      child: TextButton(
        onPressed: () => _sortBy(column),
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          alignment: Alignment.centerLeft,
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Flexible(child: Text(_columns[column]!,
              overflow: TextOverflow.ellipsis)),
          if (active) Icon(
            _sortAscending ? Icons.arrow_upward : Icons.arrow_downward,
            size: 16,
          ),
        ]),
      ),
    );
  }

  void _selectPreview(String relativePath, {bool byKeyboard = false}) {
    if (_folder == null || _updating || relativePath.isEmpty) return;
    _listFocus.requestFocus();
    if (_previewPath == relativePath) return;
    _previewDelay?.cancel();
    _thumbnailQueued = false;
    setState(() {
      _previewPath = relativePath;
      _thumbnail = null;
    });
    final cached = _recentThumbnails.remove(relativePath);
    if (cached != null) {
      _recentThumbnails[relativePath] = cached;
      setState(() { _thumbnail = Future.value(cached); });
    } else if (byKeyboard) {
      _previewDelay = Timer(const Duration(milliseconds: 100), _loadPreview);
    } else {
      _loadPreview();
    }
  }

  void _loadPreview() {
    if (!mounted || _previewPath == null || _folder == null) return;
    if (_thumbnailBusy) {
      _thumbnailQueued = true;
      return;
    }
    _thumbnailBusy = true;
    final path = _previewPath!;
    final generation = _previewGeneration;
    final future = _channel.invokeMethod<Uint8List>('thumbnail', {
      'path': _folder,
      'relativePath': path,
    }).onError((_, __) => null).then((bytes) {
      if (mounted && generation == _previewGeneration && bytes != null && bytes.isNotEmpty) {
        _recentThumbnails[path] = bytes;
        if (_recentThumbnails.length > 12) {
          _recentThumbnails.remove(_recentThumbnails.keys.first);
        }
      }
      return bytes;
    }).whenComplete(() {
      _thumbnailBusy = false;
      if (_thumbnailQueued) {
        _thumbnailQueued = false;
        _loadPreview();
      }
    });
    setState(() { _thumbnail = future; });
  }

  Widget _previewPane(Map<String, dynamic>? row) {
    final path = row?['relativePath'] as String?;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: path == null
          ? const Center(child: Text('画像を選択してください'))
          : Column(children: [
              Expanded(
                child: FutureBuilder<Uint8List?>(
                  key: ValueKey(path),
                  future: _thumbnail,
                  builder: (context, snapshot) {
                    if (_thumbnail == null || snapshot.connectionState != ConnectionState.done) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    final bytes = snapshot.data;
                    if (bytes == null || bytes.isEmpty) {
                      return const Center(child: Text('プレビューできません'));
                    }
                    return Image.memory(bytes, fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) =>
                          const Center(child: Text('プレビューできません')));
                  },
                ),
              ),
              Flexible(
                child: ListView(shrinkWrap: true, children: [
                  Text(path.split('/').last, maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text('フォルダ：${path.contains('/') ? path.substring(0, path.lastIndexOf('/')) : '選択したフォルダ'}'),
                  Text('撮影：${formatJstTimestamp(row!['targetMs'])}'),
                  Text('変更：${formatJstTimestamp(row['beforeMs'])}'),
                  Text(MacPhotoRow.statusLabel(row['status'])),
                ]),
              ),
              TextButton(
                onPressed: _updating ? null : () => _openFile(path),
                child: const Text('関連付けアプリで開く'),
              ),
            ]),
    );
  }

  Future<void> _openFile(String relativePath) async {
    if (_folder == null || _updating) return;
    try {
      await _channel.invokeMethod<void>('openFile', {
        'path': _folder,
        'relativePath': relativePath,
      });
    } on PlatformException catch (error) {
      if (mounted) setState(() =>
          _status = '画像を開けませんでした：${error.message ?? error.code}');
    } on MissingPluginException {
      if (mounted) setState(() => _status = 'Mac版の起動機能が見つかりません。');
    }
  }

  @override
  void initState() {
    super.initState();
    _channel.setMethodCallHandler((event) async {
      if (event.method == 'macRows' && mounted && _scanning) {
        final incoming = (event.arguments as List)
            .map((x) => Map<String, dynamic>.from(x as Map));
        setState(() {
          for (final row in incoming) {
            _rows.add(row);
            if (row['status'] == 'NEEDS_UPDATE' && row['relativePath'] is String) {
              _selected.add(row['relativePath'] as String);
            }
          }
        });
      }
    });
    _checkTool();
    _loadHistory();
  }

  @override
  void dispose() {
    _channel.setMethodCallHandler(null);
    _previewDelay?.cancel();
    _listFocus.dispose();
    _listScrollController.dispose();
    super.dispose();
  }

  Future<void> _checkTool() async {
    try {
      final info = await _channel.invokeMapMethod<String, dynamic>('checkExifTool');
      if (mounted) {
        setState(() => _tool = 'ExifTool ${info?['version']} (${info?['path']})');
      }
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() => _toolError = error.message ?? 'ExifToolを起動できませんでした');
      }
    } on MissingPluginException {
      if (mounted) setState(() => _toolError = 'macOS専用のネイティブ機能です。');
    }
  }

  Future<void> _loadHistory() async {
    try {
      final value = await _channel.invokeMapMethod<String, dynamic>('lastBatch');
      if (mounted) setState(() => _history = value);
    } on PlatformException {
      if (mounted) setState(() => _history = null);
    } on MissingPluginException {
      if (mounted) setState(() => _history = null);
    }
  }

  int get _selectedCount => _rows.where((row) =>
      row['status'] == 'NEEDS_UPDATE' &&
      _selected.contains(row['relativePath'])).length;

  void _selectAll(bool checked) {
    if (!_scanComplete || _scanning || _updating) return;
    setState(() {
      _selected.clear();
      if (checked) {
        for (final row in _rows) {
          if (row['status'] == 'NEEDS_UPDATE' && row['relativePath'] is String) {
            _selected.add(row['relativePath'] as String);
          }
        }
      }
    });
  }

  Future<void> _cancelBatch() async {
    if (!_batchApplying || _cancelRequested) return;
    setState(() {
      _cancelRequested = true;
      _status = '更新を停止しています。現在のファイルを完了してから止めます…';
    });
    try {
      await _channel.invokeMethod<void>('cancelBatch');
    } on PlatformException catch (error) {
      if (mounted) setState(() {
        _cancelRequested = false;
        _status = '中止要求に失敗しました：${error.message ?? error.code}';
      });
    } on MissingPluginException {
      if (mounted) setState(() {
        _cancelRequested = false;
        _status = '更新中止機能が見つかりません。更新完了まで終了しないでください。';
      });
    }
  }

  Future<bool> _confirm(String title, String message, String action) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false),
            child: const Text('キャンセル')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true),
            child: Text(action)),
        ],
      ),
    );
    return accepted == true;
  }

  Future<void> _apply() async {
    if (!_scanComplete || _scanning || _updating || !_writeAllowed ||
        _selectedCount == 0 || _folder == null) return;
    final plans = _rows.where((row) =>
        row['status'] == 'NEEDS_UPDATE' &&
        _selected.contains(row['relativePath'])).map((row) => {
          'relativePath': row['relativePath'],
          'beforeMs': row['beforeMs'],
          'targetMs': row['targetMs'],
        }).toList();
    final replacing = _history?['exists'] == true;
    final filterResults = _onlyNeedsUpdate;
    final message = '選択した${plans.length}件のファイル変更日時を、撮影日時に合わせます。'
        '${replacing ? "\n前回のUndo履歴は、この更新で置き換わります。" : ""}';
    if (!await _confirm('ファイルの日時を更新しますか？', message, '更新する') || !mounted) return;
    setState(() {
      _updating = true;
      _batchApplying = true;
      _cancelRequested = false;
      _status = 'ExifToolで変更日時を更新しています…';
    });
    String? resultMessage;
    Map<String, dynamic>? updateResult;
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>('applyBatch', {
        'path': _folder,
        'items': plans,
        'replaceConfirmed': replacing,
      });
      updateResult = result;
      resultMessage = result?['cancelled'] == true
          ? '更新を中止：成功 ${result?['applied'] ?? 0}件・'
              '未処理 ${result?['remaining'] ?? 0}件・'
              'スキップ ${result?['skipped'] ?? 0}件'
          : result != null && result['skipped'] == 0
              ? '${result['applied']}件の変更日時を更新しました。'
              : '更新結果：成功 ${result?['applied'] ?? 0}件・'
              'スキップ ${result?['skipped'] ?? 0}件';
    } on PlatformException catch (e) {
      resultMessage = '更新を中断しました：${e.message ?? e.code}。履歴を確認してください。';
    } finally {
      if (mounted) setState(() {
        _updating = false;
        _batchApplying = false;
        _cancelRequested = false;
      });
      await _loadHistory();
    }
    if (mounted) await _scan(resultMessage: resultMessage, updateResult: updateResult,
      filterResults: filterResults);
  }

  Future<void> _undo() async {
    if (_scanning || _updating || !_writeAllowed || _folder == null ||
        (_history?['applied'] as num? ?? 0) == 0 ||
        (_history?['unresolved'] as num? ?? 0) > 0 ||
        _history?['root'] != _folder) return;
    if (!await _confirm('直近バッチをUndo',
        '前回更新したファイルの変更日時を元に戻します。',
        'Undoする') || !mounted) return;
    setState(() {
      _updating = true;
      _status = 'Undoを実行しています…';
    });
    String? resultMessage;
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
          'undoLastBatch', {'path': _folder});
      resultMessage = 'Undo結果：復元済 ${result?['undone'] ?? 0}件・'
          '要確認 ${result?['unresolved'] ?? 0}件';
    } on PlatformException catch (e) {
      resultMessage = 'Undoを中断しました：${e.message ?? e.code}。履歴を保持しています。';
    } finally {
      if (mounted) setState(() => _updating = false);
      await _loadHistory();
    }
    if (mounted) await _scan(resultMessage: resultMessage);
  }

  Future<void> _chooseFolder() async {
    if (_scanning || _updating) return;
    try {
      final folder = await _channel.invokeMethod<String>('pickFolder');
      if (!mounted || folder == null) return;
      final writable = await _channel.invokeMethod<bool>(
        'checkWriteScope', {'path': folder},
      ) ?? false;
      if (!mounted) return;
      setState(() {
        _folder = folder;
        _writeAllowed = writable;
      });
      await _scan();
    } on PlatformException catch (error) {
      if (mounted) setState(() => _status = error.message ?? 'フォルダ選択エラー');
    }
  }

  Future<void> _scan({String? resultMessage, Map<String, dynamic>? updateResult,
      bool filterResults = false}) async {
    if (_scanning || _updating || _folder == null) return;
    _scrollToTop();
    setState(() {
      _scanning = true;
      _scanComplete = false;
      _previewDelay?.cancel();
      _thumbnailQueued = false;
      _previewGeneration++;
      _recentThumbnails.clear();
      _previewPath = null;
      _thumbnail = null;
      _rows.clear();
      _selected.clear();
      _onlyNeedsUpdate = false;
      _resultFilterPaths = null;
      _excluded = 0;
      _unreadable = 0;
      _status = '画像の日時情報を順に読み取っています…';
    });
    try {
      final report = await _channel.invokeMapMethod<String, dynamic>(
        'scanFolder', {'path': _folder, 'recursive': _recursive, 'includeRaw': _includeRaw},
      );
      if (!mounted) return;
      setState(() {
        _scanComplete = report?['complete'] == true;
        _excluded = (report?['excluded'] as num?)?.toInt() ?? 0;
        _unreadable = (report?['unreadable'] as num?)?.toInt() ?? 0;
        if (_scanComplete && updateResult != null) {
          final applied = (updateResult['appliedPaths'] as List? ?? []).whereType<String>().toSet();
          final skipped = (updateResult['skippedPaths'] as List? ?? []).whereType<String>().toSet();
          if (filterResults) {
            _onlyNeedsUpdate = true;
            _resultFilterPaths = {...applied, ...skipped};
          }
          for (final row in _rows) {
            final path = row['relativePath'];
            if (applied.contains(path) && row['status'] == 'UNCHANGED') {
              row['status'] = 'UPDATED';
              _selected.remove(path);
            } else if (skipped.contains(path)) {
              row['status'] = 'UPDATE_FAILED';
              row['message'] = '更新直前のファイル・日時照合でスキップしました。';
              _selected.remove(path);
            }
          }
        }
        _status = _scanComplete
            ? resultMessage ?? 'スキャン完了。対象 ${_rows.length} 件、対象外 $_excluded 件。'
            : 'スキャンを中止しました。部分一覧を表示しています。';
      });
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() => _status = '読み取りに失敗：${error.message}');
      }
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _cancel() async {
    if (!_scanning) return;
    if (mounted) setState(() => _status = '停止しています…');
    await _channel.invokeMethod<void>('cancelScan');
  }

  @override
  Widget build(BuildContext context) {
    final displayRows = _displayRows;
    final hasUndo = (_history?['applied'] as num? ?? 0) > 0;
    final unresolved = (_history?['unresolved'] as num? ?? 0) > 0;
    final undoFolderMatches = _folder != null && _history?['root'] == _folder;
    return Scaffold(
      appBar: AppBar(title: const Text('EXIF Date Sync'), actions: [
        IconButton(
          tooltip: 'ヘルプ',
          icon: const Icon(Icons.help_outline),
          onPressed: () => showDialog<void>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('EXIF Date Syncについて'),
              content: SingleChildScrollView(child: Text(
                '画像本体とEXIFは変更しません。最初はコピーでお試しください。'
                '\n\nMacでは更新時に作成日時も変わることがあります。'
                'Undoで元に戻せるのは、直近の処理の変更日時だけです。'
                '${_tool == null ? "" : "\n\n$_tool"}',
              )),
              actions: [TextButton(onPressed: () => Navigator.pop(context),
                child: const Text('閉じる'))],
            ),
          ),
        ),
      ]),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (_toolError != null) Text('$_toolError\nExifToolをインストールまたは確認して、アプリを開き直してください。'),
          Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, children: [
            FilledButton.tonal(
              onPressed: _scanning || _updating ? null : _chooseFolder,
              child: const Text('フォルダを選択'),
            ),
            IconButton(
              tooltip: '再スキャン',
              onPressed: _scanning || _updating || _folder == null ? null : _scan,
              icon: const Icon(Icons.refresh),
            ),
            const SizedBox(width: 18),
            Row(mainAxisSize: MainAxisSize.min, children: [
              Checkbox(value: _recursive, onChanged: _scanning || _updating ? null : (value) async {
                setState(() => _recursive = value ?? false);
                if (_folder != null) await _scan();
              }),
              const Text('サブフォルダを含める'),
            ]),
            Row(mainAxisSize: MainAxisSize.min, children: [
              Checkbox(value: _includeRaw, onChanged: _scanning || _updating ? null : (value) async {
                setState(() => _includeRaw = value ?? true);
                if (_folder != null) await _scan();
              }),
              const Text('RAWを含める'),
            ]),
            if (_scanning)
              OutlinedButton(onPressed: _cancel, child: const Text('中止')),
            if (_batchApplying)
              OutlinedButton(
                onPressed: _cancelRequested ? null : _cancelBatch,
                child: Text(_cancelRequested ? '停止中…' : '更新を中止'),
              ),
          ]),
          Tooltip(
            message: _folder ?? 'フォルダ未選択',
            child: SelectableText(_folder ?? 'フォルダ未選択', maxLines: 1),
          ),
          const SizedBox(height: 4),
          if (_scanning || _updating) const LinearProgressIndicator(),
          Text(_status),
          if (_unreadable > 0) Text('読み取りエラー：$_unreadable 件'),
          const SizedBox(height: 4),
          Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, children: [
            TextButton(
              onPressed: _scanComplete && !_scanning && !_updating
                  ? () => _selectAll(true) : null,
              child: const Text('全選択'),
            ),
            TextButton(
              onPressed: _scanComplete && !_scanning && !_updating
                  ? () => _selectAll(false) : null,
              child: const Text('全解除'),
            ),
            const SizedBox(width: 8),
            FilterChip(
              label: Text(_resultFilterPaths != null ? '今回の対象のみ' : '要更新のみ'),
              selected: _onlyNeedsUpdate,
              onSelected: (value) {
                _scrollToTop();
                setState(() {
                  _onlyNeedsUpdate = value;
                  if (!value) _resultFilterPaths = null;
                });
              },
            ),
            Text('表示 ${displayRows.length} / ${_rows.length} 件'),
          ]),
          const Divider(height: 1),
          Expanded(child: LayoutBuilder(builder: (context, constraints) {
            final rowHeight = 10 + 2 * MediaQuery.textScalerOf(context).scale(16);
            final width = constraints.maxWidth;
            final previewWidth = width < 900
                ? width * 0.29
                : (width * 0.34).clamp(280.0, 440.0);
            final previewRow = displayRows.where((row) => row['relativePath'] == _previewPath).firstOrNull;
            return Row(children: [
              Expanded(child: Focus(
                focusNode: _listFocus,
                onKeyEvent: (_, event) {
                  final key = event.logicalKey;
                  if (event is KeyUpEvent ||
                      (key != LogicalKeyboardKey.arrowDown && key != LogicalKeyboardKey.arrowUp) ||
                      displayRows.isEmpty || _updating) return KeyEventResult.ignored;
                  final current = displayRows.indexWhere((row) => row['relativePath'] == _previewPath);
                  final index = (current < 0 ? 0 :
                      current + (key == LogicalKeyboardKey.arrowDown ? 1 : -1))
                      .clamp(0, displayRows.length - 1);
                  _selectPreview(displayRows[index]['relativePath'] as String, byKeyboard: true);
                  if (_listScrollController.hasClients) {
                    final position = _listScrollController.position;
                    final top = index * rowHeight;
                    final bottom = top + rowHeight;
                    final offset = top < position.pixels ? top
                        : bottom > position.pixels + position.viewportDimension
                            ? bottom - position.viewportDimension : position.pixels;
                    _listScrollController.jumpTo(offset.clamp(0.0, position.maxScrollExtent));
                  }
                  return KeyEventResult.handled;
                },
                child: Column(children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(children: [
                      const SizedBox(width: 44),
                      _heading('file', 4),
                      _heading('capture', 3),
                      _heading('modified', 3),
                      _heading('status', 2),
                    ]),
                  ),
                  Expanded(
                    child: ListView.builder(
                      controller: _listScrollController,
                      itemExtent: rowHeight,
                      itemCount: displayRows.length,
                      itemBuilder: (context, index) {
                        final row = displayRows[index];
                        final relative = row['relativePath'] as String? ?? '';
                        return MacPhotoRow(
                          row: row,
                          selected: _selected.contains(relative),
                          onSelected: row['status'] == 'NEEDS_UPDATE' &&
                              !_scanning && !_updating ? (checked) {
                            setState(() {
                              if (checked == true) {
                                _selected.add(relative);
                              } else {
                                _selected.remove(relative);
                              }
                            });
                          } : null,
                          previewed: relative == _previewPath,
                          onPreview: _updating ? null : () => _selectPreview(relative),
                        );
                      },
                    ),
                  ),
                ]),
              )),
              const VerticalDivider(width: 1),
              SizedBox(width: previewWidth, child: _previewPane(previewRow)),
            ]);
          })),
          const Divider(),
          if (unresolved)
            const Text('前回の処理が完了していないため、更新とUndoを停止しています。'
                '前回の処理結果を確認してください。'),
          if (hasUndo && !unresolved && !undoFolderMatches)
            const Text('前回の更新を元に戻すには、対象のフォルダを選択してください。'),
          Wrap(spacing: 12, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton(
                onPressed: _scanComplete && !_scanning && !_updating &&
                    _writeAllowed && _selectedCount > 0 && !unresolved ? _apply : null,
                child: Text('選択した$_selectedCount件を更新'),
              ),
              if (hasUndo && !unresolved && undoFolderMatches)
                OutlinedButton(
                  onPressed: !_scanning && !_updating && _writeAllowed ? _undo : null,
                  child: const Text('直近の処理をUndo'),
                ),
            ],
          ),
          if (!_scanComplete && _rows.isNotEmpty)
            const Text('中止またはエラーのため一覧は不完全です。'),
        ]),
      ),
    );
  }
}
