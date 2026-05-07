// ignore_for_file: deprecated_member_use

import 'dart:async';
import 'dart:math' as math;
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'package:web/web.dart' as web;
import 'dart:ui_web' as ui_web;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../services/api_service.dart';
import '../services/file_download_launcher.dart';
import '../services/native_browser_upload.dart';
import '../theme/app_theme.dart';
import '../theme/app_terminal_typography.dart';
import '../theme/app_typography.dart';
import '../utils/app_format.dart';
import '../utils/web_context_menu_lock.dart';
import '../utils/web_fs_helper.dart';
import '../widgets/app_toast.dart';
import '../widgets/app_ui.dart';
import '../widgets/app_iframe_view.dart';

const double _controlRadius = 6;
const double _panelRadius = 10;
const double _titleFontSize = 13;
const double _bodyFontSize = 12;
const int _browserUploadChunkSize = 2 * 1024 * 1024;
const int _browserUploadRetryCount = 2;

class FileManagerPanel extends StatefulWidget {
  final VoidCallback? onMinimize;
  final VoidCallback? onClose;

  const FileManagerPanel({
    super.key,
    this.onMinimize,
    this.onClose,
  });

  @override
  State<FileManagerPanel> createState() => _FileManagerPanelState();
}

class _FileManagerPanelState extends State<FileManagerPanel> {
  final AppHeaderSearchRefreshController _searchController =
      AppHeaderSearchRefreshController();
  String _currentPath = '/';
  String? _parentPath;
  bool _loading = true;
  String? _loadError;
  List<_RemoteFileEntry> _entries = const <_RemoteFileEntry>[];
  String _searchQuery = '';
  _RemoteFileEntry? _selectedEntry;
  Set<String> _selectedPaths = <String>{};
  _ClipboardAction? _clipboardAction;
  List<String> _clipboardPaths = const <String>[];

  final Map<String, List<_RemoteFileEntry>> _directoryTree =
      <String, List<_RemoteFileEntry>>{};
  final Set<String> _expandedDirs = <String>{'/'};
  final Set<String> _loadingDirs = <String>{};
  final TextEditingController _pathController = TextEditingController();
  final FocusNode _pathFocusNode = FocusNode();
  final GlobalKey _dropAreaKey = GlobalKey();
  StreamSubscription<web.Event>? _webDragOverSub;
  StreamSubscription<web.Event>? _webDropSub;
  StreamSubscription<web.Event>? _webDragLeaveSub;
  StreamSubscription<web.KeyboardEvent>? _webKeyDownSub;

  bool _editingPath = false;
  bool _showHiddenFiles = false;
  _FileSortField _sortField = _FileSortField.name;
  bool _sortAscending = true;
  _FileDisplayMode _displayMode = _FileDisplayMode.list;
  bool _displayModeInitialized = false;
  int _toolbarBusyCount = 0;
  String? _toolbarBusyLabel;
  bool _draggingUpload = false;
  bool _nativeUploadBusy = false;
  bool _mobileSelectionMode = false;
  OverlayEntry? _activeContextMenuEntry;
  VoidCallback? _activeContextMenuClose;
  Offset? _lastGridEntryMenuPosition;
  DateTime? _lastGridEntryMenuTime;
  int _directoryLoadRequestSeq = 0;
  final GlobalKey _settingsMenuKey = GlobalKey();

  // 搜索防抖
  Timer? _searchDebounce;

  // 缓存 _displayEntries
  List<_RemoteFileEntry>? _cachedDisplayEntries;
  String? _cachedSearchQuery;
  bool? _cachedShowHidden;
  _FileSortField? _cachedSortField;
  bool? _cachedSortAsc;
  List<_RemoteFileEntry>? _cachedSourceEntries;

  @override
  void initState() {
    super.initState();
    if (kIsWeb) {
      WebContextMenuLock.acquire();
      _installWebDropFallback();
      _installWebShortcutFallback();
      _installBeforeUnloadListener();
    }
    DesktopDrop.instance.init();
    DesktopDrop.instance.addRawDropEventListener(_handleRawDropEvent);
    _pathController.text = _currentPath;
    _pathFocusNode.addListener(_onPathFocusChange);
    _refreshCurrentDirectory();
    _loadDirectoryChildren('/');
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_displayModeInitialized) {
      _displayModeInitialized = true;
      final double width = MediaQuery.sizeOf(context).width;
      _displayMode = width < 700
          ? _FileDisplayMode.grid
          : _FileDisplayMode.list;
    }
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _dismissActiveContextMenu();
    _webDragOverSub?.cancel();
    _webDropSub?.cancel();
    _webDragLeaveSub?.cancel();
    _webKeyDownSub?.cancel();
    DesktopDrop.instance.removeRawDropEventListener(_handleRawDropEvent);
    if (kIsWeb) {
      WebContextMenuLock.release();
    }
    _pathFocusNode.removeListener(_onPathFocusChange);
    _pathFocusNode.dispose();
    _pathController.dispose();
    super.dispose();
  }

  void _onPathFocusChange() {
    if (!_pathFocusNode.hasFocus && _editingPath) {
      _submitPathEdit();
    }
  }

  void _installWebShortcutFallback() {
    _webKeyDownSub =
        web.window.onKeyDown.listen((web.KeyboardEvent keyboardEvent) {
      if (!mounted || !_isShortcutTargetActive()) {
        return;
      }
      if (_isEditableEventTarget(keyboardEvent.target)) {
        return;
      }
      final String key = keyboardEvent.key.toLowerCase();
      if ((keyboardEvent.ctrlKey || keyboardEvent.metaKey) && key == 'f') {
        keyboardEvent.preventDefault();
        keyboardEvent.stopPropagation();
        _searchController.focus();
      }
    });
  }

  void _installBeforeUnloadListener() {
    final handler = (web.Event event) {
      final isDownloading =
          (web.window as JSObject).getProperty('_downloading'.toJS);
      if (isDownloading == true.toJS) return;
      event.preventDefault();
      (event as JSObject).setProperty('returnValue'.toJS, ''.toJS);
    }.toJS;
    web.window.addEventListener('beforeunload', handler);
  }

  bool _isShortcutTargetActive() {
    if (!mounted) {
      return false;
    }
    final RenderObject? renderObject = context.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.attached) {
      return false;
    }
    bool offstage = false;
    context.visitAncestorElements((Element element) {
      final Widget widget = element.widget;
      if (widget is Offstage && widget.offstage) {
        offstage = true;
        return false;
      }
      return true;
    });
    return !offstage;
  }

  bool _isEditableEventTarget(Object? target) {
    if (target is web.HTMLInputElement || target is web.HTMLTextAreaElement) {
      return true;
    }
    if (target is web.HTMLElement) {
      return target.contentEditable == 'true';
    }
    return false;
  }

  void _logDropTrace(String message) {}

  String _normalizeUploadError(Object error) {
    var message = error.toString().replaceFirst('Exception: ', '').trim();
    const wrappers = <String>[
      'pickAndUploadFilesWithBrowser failed:',
      'uploadBrowserFilesWithBrowser failed:',
    ];
    for (final prefix in wrappers) {
      if (message.startsWith(prefix)) {
        message = message.substring(prefix.length).trim();
      }
    }
    if (message.startsWith('Error:')) {
      message = message.substring('Error:'.length).trim();
    }
    if (message.contains('上传已取消')) {
      return '已取消上传';
    }
    return message;
  }

  void _installWebDropFallback() {
    _webDragOverSub = web.EventStreamProviders.dragOverEvent.forTarget(web.window).listen((web.Event rawEvent) {
      final web.MouseEvent event = rawEvent as web.MouseEvent;
      final Offset point =
          Offset(event.clientX.toDouble(), event.clientY.toDouble());
      if (!_isPointInsideDropArea(point) || _isUploadActionDisabled) {
        return;
      }
      rawEvent.preventDefault();
      rawEvent.stopPropagation();
      if (!_draggingUpload && mounted) {
        setState(() => _draggingUpload = true);
      }
    });

    _webDragLeaveSub = web.EventStreamProviders.dragLeaveEvent.forTarget(web.window).listen((web.Event rawEvent) {
      if (!_draggingUpload || !mounted) {
        return;
      }
      rawEvent.preventDefault();
      rawEvent.stopPropagation();
      setState(() => _draggingUpload = false);
    });

    _webDropSub = web.EventStreamProviders.dropEvent
        .forTarget(web.window)
        .listen((web.Event rawEvent) async {
      final web.DragEvent dropEvent = rawEvent as web.DragEvent;
      final Offset point = Offset(
        dropEvent.clientX.toDouble(),
        dropEvent.clientY.toDouble(),
      );
      final bool inside = _isPointInsideDropArea(point);
      if (!inside || _isUploadActionDisabled) {
        return;
      }
      dropEvent.preventDefault();
      dropEvent.stopPropagation();

      if (_draggingUpload && mounted) {
        setState(() => _draggingUpload = false);
      }

      final web.DataTransfer? transfer = dropEvent.dataTransfer;
      try {
        _logDropTrace('drop start: transfer=${transfer != null}');
        final List<({Object browserFile, String relativeDir})> picked =
            await _readDroppedEntriesFromWeb(
          transfer,
        );
        _logDropTrace('drop read done: files=${picked.length}');
        await _uploadDroppedBrowserEntries(picked);
        _logDropTrace('drop upload done');
      } catch (error, stack) {
        _logDropTrace('drop failed: $error');
        _logDropTrace('$stack');
        rethrow;
      }
    });
  }

  Future<void> _collectWebEntryFiles(
    web.FileSystemEntry entry,
    String relativeDir,
    List<({Object browserFile, String relativeDir})> result,
  ) async {
    if (entry.isFile) {
      final web.File file = await getFileFromEntry(entry as web.FileSystemFileEntry);
      if (file.name.trim().isNotEmpty) {
        result.add((browserFile: file, relativeDir: relativeDir));
      }
      return;
    }
    if (entry.isDirectory) {
      final String dirName = entry.name.trim();
      final String nextRelativeDir = dirName.isEmpty
          ? relativeDir
          : (relativeDir.isEmpty ? dirName : '$relativeDir/$dirName');
      final web.FileSystemDirectoryReader reader =
          (entry as web.FileSystemDirectoryEntry).createReader();
      while (true) {
        final List<web.FileSystemEntry> batch =
            await readEntriesFromReader(reader);
        if (batch.isEmpty) {
          break;
        }
        for (final web.FileSystemEntry child in batch) {
          await _collectWebEntryFiles(child, nextRelativeDir, result);
        }
      }
    }
  }

  Future<List<({Object browserFile, String relativeDir})>>
      _readDroppedEntriesFromWeb(web.DataTransfer? transfer) async {
    if (transfer == null) {
      _logDropTrace('read: transfer null');
      return const <({Object browserFile, String relativeDir})>[];
    }

    final List<({Object browserFile, String relativeDir})> result =
        <({Object browserFile, String relativeDir})>[];
    final web.DataTransferItemList? items = transfer.items;
    if (items != null) {
      final int itemCount = items.length;
      _logDropTrace('read: transfer.items=$itemCount');
      for (int i = 0; i < itemCount; i++) {
        final web.DataTransferItem? item = items[i];
        if (item == null || item.kind != 'file') {
          continue;
        }
        final web.FileSystemEntry? entry = item.webkitGetAsEntry();
        if (entry != null) {
          _logDropTrace('read: webkit entry type=${entry.runtimeType} name=${entry.name}');
          await _collectWebEntryFiles(entry, '', result);
          continue;
        }
        final web.File? file = item.getAsFile();
        if (file != null && file.name.trim().isNotEmpty) {
          result.add((browserFile: file, relativeDir: ''));
        }
      }
    }
    if (result.isNotEmpty) {
      _logDropTrace('read: resolved from entries=${result.length}');
      return result;
    }

    final web.FileList? files = transfer.files;
    _logDropTrace('read: fallback fileList=${files?.length ?? 0}');
    if (files == null || files.length == 0) {
      return result;
    }
    for (int i = 0; i < files.length; i++) {
      final web.File? file = files.item(i);
      if (file != null && file.name.trim().isNotEmpty) {
        result.add((browserFile: file, relativeDir: ''));
      }
    }
    _logDropTrace('read: final result=${result.length}');
    return result;
  }

  Set<String> _expandRelativeDirs(Iterable<String> dirs) {
    final Set<String> result = <String>{};
    for (final String dir in dirs) {
      final String normalized = dir.trim().replaceAll('\\', '/');
      if (normalized.isEmpty) {
        continue;
      }
      final List<String> parts =
          normalized.split('/').where((p) => p.trim().isNotEmpty).toList();
      String current = '';
      for (final String part in parts) {
        current = current.isEmpty ? part : '$current/$part';
        result.add(current);
      }
    }
    return result;
  }

  Future<void> _uploadDroppedBrowserEntries(
    List<({Object browserFile, String relativeDir})> files,
  ) async {
    if (files.isEmpty) {
      _showSnack('未检测到可上传文件', isError: true);
      return;
    }
    if (_isUploadActionDisabled) {
      _showSnack('当前有任务正在执行，请稍后重试', isError: true);
      return;
    }

    setState(() => _nativeUploadBusy = true);
    try {
      _logDropTrace('upload-start: incoming=${files.length} currentPath=$_currentPath');
      final ApiService api = context.read<ApiService>();
      final Set<String> allRelativeDirs = _expandRelativeDirs(
        files
            .map((entry) => entry.relativeDir)
            .where((dir) => dir.trim().isNotEmpty),
      );
      final List<String> sortedRelativeDirs = allRelativeDirs.toList()
        ..sort((a, b) {
          final int depthA = '/'.allMatches(a).length;
          final int depthB = '/'.allMatches(b).length;
          if (depthA != depthB) {
            return depthA.compareTo(depthB);
          }
          return a.compareTo(b);
        });

      _logDropTrace('upload: mkdir count=${sortedRelativeDirs.length}');
      for (final String relativeDir in sortedRelativeDirs) {
        final int splitAt = relativeDir.lastIndexOf('/');
        final String parentRelative =
            splitAt >= 0 ? relativeDir.substring(0, splitAt) : '';
        final String dirName =
            splitAt >= 0 ? relativeDir.substring(splitAt + 1) : relativeDir;
        final String parentPath = parentRelative.isEmpty
            ? _currentPath
            : _normalizePath('$_currentPath/$parentRelative');
        try {
          await api.createDirectory(
            parent: parentPath,
            name: dirName,
          );
        } catch (error) {
          final String message = error.toString();
          if (!message.contains('已存在') &&
              !message.toLowerCase().contains('exists')) {
            rethrow;
          }
        }
      }

      // 按目标目录分组
      final Map<String, List<Object>> filesByDir = {};
      for (final entry in files) {
        final web.File? rawFile = entry.browserFile as web.File?;
        if (rawFile == null) continue;
        final String fileName = rawFile.name.trim();
        if (fileName.isEmpty) continue;
        
        final String targetParent = entry.relativeDir.isEmpty
            ? _currentPath
            : _normalizePath('$_currentPath/${entry.relativeDir}');
        
        if (!filesByDir.containsKey(targetParent)) {
          filesByDir[targetParent] = [];
        }
        filesByDir[targetParent]!.add(entry.browserFile);
      }

      _logDropTrace('upload: grouped dirs=${filesByDir.length}');
      // 按目录分批上传
      for (final entry in filesByDir.entries) {
        _logDropTrace('upload: sending dir=${entry.key} files=${entry.value.length}');
        final NativeBrowserUploadResult result =
            await uploadBrowserFilesWithBrowser(
          endpointUrl: api.uploadUrl,
          chunkInitUrl: '${api.uploadUrl}/init',
          chunkUrl: '${api.uploadUrl}/chunk',
          completeUrl: '${api.uploadUrl}/complete',
          cancelUrl: '${api.uploadUrl}/cancel',
          chunkSize: 2 * 1024 * 1024,
          retryCount: 2,
          token: api.token ?? '',
          query: <String, String>{'parent': entry.key},
          browserFiles: entry.value,
          title: '正在上传文件',
        );
        _logDropTrace('upload: result dir=${entry.key} uploaded=${result.uploadedCount} skipped=${result.skippedCount}');
      }

      await _refreshCurrentDirectory();
      _showSnack('已上传 ${files.length} 个文件');
    } catch (error, stack) {
      _logDropTrace('upload failed: $error');
      _logDropTrace('$stack');
      _showSnack(_normalizeUploadError(error), isError: true);
    } finally {
      if (mounted) {
        setState(() => _nativeUploadBusy = false);
      }
    }
  }

  bool _isPointInsideDropArea(Offset globalPosition) {
    final BuildContext? dropContext = _dropAreaKey.currentContext;
    if (dropContext == null) {
      return false;
    }
    final RenderObject? renderObject = dropContext.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) {
      return false;
    }
    final Offset local = renderObject.globalToLocal(globalPosition);
    return renderObject.paintBounds.contains(local);
  }

  void _handleRawDropEvent(dynamic event) {
    if (!mounted || _isUploadActionDisabled) {
      return;
    }
    final String eventType = event.runtimeType.toString();
    final Offset location =
        event.location is Offset ? event.location as Offset : Offset.zero;
    final bool inside = _isPointInsideDropArea(location);

    if (eventType == 'DropEnterEvent' || eventType == 'DropUpdateEvent') {
      if ((inside || kIsWeb) && !_draggingUpload) {
        setState(() => _draggingUpload = true);
      } else if (!inside && _draggingUpload) {
        setState(() => _draggingUpload = false);
      }
      return;
    }

    if (eventType == 'DropExitEvent') {
      if (_draggingUpload) {
        setState(() => _draggingUpload = false);
      }
      return;
    }

    if (eventType == 'DropDoneEvent') {
      if (kIsWeb) {
        if (_draggingUpload) {
          setState(() => _draggingUpload = false);
        }
        // Web uses native window.onDrop fallback which keeps File objects
        // streamable; desktop_drop path may force full in-memory reads.
        return;
      }
      final List<DropItem> dropped = (event.files as List<dynamic>)
          .whereType<DropItem>()
          .toList(growable: false);
      final bool shouldHandle =
          dropped.isNotEmpty && (inside || _draggingUpload);
      if (_draggingUpload) {
        setState(() => _draggingUpload = false);
      }
      if (shouldHandle) {
        unawaited(_uploadDroppedFiles(dropped));
      }
    }
  }

  bool get _isToolbarBusy => _toolbarBusyCount > 0;
  bool get _isUploadInProgress => _nativeUploadBusy;
  bool get _isInteractionLocked => _isToolbarBusy;
  bool get _isUploadActionDisabled => _isToolbarBusy || _isUploadInProgress;
  bool get _supportsAdvancedActions => true;
  bool get _canEditSelectedFile =>
      _selectedEntry != null &&
      _selectedPaths.length == 1 &&
      !_selectedEntry!.isDir;

  bool _isImageEntry(_RemoteFileEntry entry) {
    final String lower = entry.name.toLowerCase();
    return lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.bmp') ||
        lower.endsWith('.ico') ||
        lower.endsWith('.avif');
  }

  bool _isPdfEntry(_RemoteFileEntry entry) {
    return entry.name.toLowerCase().endsWith('.pdf');
  }

  void _beginToolbarBusy(String label) {
    if (!mounted) {
      return;
    }
    setState(() {
      _toolbarBusyCount += 1;
      _toolbarBusyLabel = label;
    });
  }

  void _endToolbarBusy() {
    if (!mounted) {
      return;
    }
    setState(() {
      _toolbarBusyCount = (_toolbarBusyCount - 1).clamp(0, 1 << 30);
      if (_toolbarBusyCount == 0) {
        _toolbarBusyLabel = null;
      }
    });
  }

  String _toolbarBusySubtitle() {
    switch (_toolbarBusyLabel) {
      case '本地读取中':
        return '浏览器正在准备上传文件';
      case '远程上传中':
        return '面板服务器正在转发文件到远程主机';
      case '刷新中':
        return '正在刷新当前目录内容';
      case '删除中':
        return '正在删除选中的文件或目录';
      case '复制中':
        return '正在复制所选内容到目标目录';
      case '移动中':
        return '正在移动所选内容到目标目录';
      case '压缩中':
        return '正在创建压缩包';
      case '解压中':
        return '正在释放压缩包内容';
      default:
        return '请稍候，当前目录操作正在执行';
    }
  }

  Future<T> _runToolbarBusyAction<T>(
    String label,
    Future<T> Function() action,
  ) async {
    if (!mounted) {
      return action();
    }

    _beginToolbarBusy(label);

    try {
      return await action();
    } finally {
      _endToolbarBusy();
    }
  }

  Future<void> _refreshCurrentDirectory(
      {bool showBusyIndicator = false}) async {
    if (showBusyIndicator) {
      await _runToolbarBusyAction(
        '正在刷新',
        () => _loadDirectory(_currentPath, keepSelection: true),
      );
      return;
    }
    await _loadDirectory(_currentPath, keepSelection: true);
  }

  Future<void> _loadDirectory(String path, {bool keepSelection = false}) async {
    final int requestSeq = ++_directoryLoadRequestSeq;
    setState(() {
      _loading = true;
      _loadError = null;
      _currentPath = path;
      if (!keepSelection) {
        _selectedEntry = null;
        _selectedPaths = <String>{};
      }
    });

    try {
      final api = context.read<ApiService>();
      final data = await api.listFiles(path: path);
      final entries = (data['entries'] as List<dynamic>? ?? <dynamic>[])
          .map((dynamic item) =>
              _RemoteFileEntry.fromJson(Map<String, dynamic>.from(item as Map)))
          .toList();

      if (!mounted || requestSeq != _directoryLoadRequestSeq) return;
      setState(() {
        _currentPath = data['path']?.toString() ?? path;
        _parentPath = _nullIfEmpty(data['parent']?.toString());
        _pathController.text = _currentPath;
        _entries = entries;
        _loading = false;
        _directoryTree[_currentPath] = entries.where((e) => e.isDir).toList();
        if (keepSelection) {
          _selectedPaths = entries
              .where((e) => _selectedPaths.contains(e.path))
              .map((e) => e.path)
              .toSet();
          if (_selectedEntry != null) {
            final match = entries.where((e) => e.path == _selectedEntry!.path);
            _selectedEntry = match.isEmpty
                ? (_selectedPaths.isEmpty
                    ? null
                    : entries
                        .firstWhere((e) => _selectedPaths.contains(e.path)))
                : match.first;
          } else if (_selectedPaths.isNotEmpty) {
            _selectedEntry = entries.firstWhere(
              (e) => _selectedPaths.contains(e.path),
            );
          }
        }
      });
    } catch (error) {
      if (!mounted || requestSeq != _directoryLoadRequestSeq) return;
      setState(() {
        _loading = false;
        _loadError = error.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _loadDirectoryChildren(String path) async {
    if (_loadingDirs.contains(path)) return;
    setState(() => _loadingDirs.add(path));
    try {
      final api = context.read<ApiService>();
      final data = await api.listFiles(path: path);
      final entries = (data['entries'] as List<dynamic>? ?? <dynamic>[])
          .map((dynamic item) =>
              _RemoteFileEntry.fromJson(Map<String, dynamic>.from(item as Map)))
          .where((entry) => entry.isDir)
          .toList();
      if (!mounted) return;
      setState(() {
        _directoryTree[path] = entries;
      });
    } catch (_) {
      if (!mounted) return;
    } finally {
      if (!mounted) return;
      setState(() => _loadingDirs.remove(path));
    }
  }

  Future<void> _openEntry(_RemoteFileEntry entry) async {
    _selectOnly(entry);
    if (entry.isDir) {
      await _loadDirectory(entry.path);
      await _loadDirectoryChildren(entry.path);
      _expandedDirs.add(entry.path);
      return;
    }

    await _openPreviewOrEditor(fallback: entry);
  }

  void _showShellDialog() {
    final api = context.read<ApiService>();
    final wsUrl = api.shellWsUrl();
    final query = <String, String>{'ws': wsUrl};
    final uri = Uri(path: 'xterm_terminal.html', queryParameters: query);
    final src = uri.toString();

    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: AppColors.surface,
        insetPadding: const EdgeInsets.all(20),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width - 40,
            maxHeight: MediaQuery.sizeOf(context).height - 40,
          ),
          child: Container(
            decoration: BoxDecoration(
              color: AppColors.background,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  height: 36,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                    border: Border(bottom: BorderSide(color: AppColors.border)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.terminal, size: 14, color: AppColors.textSecondary),
                      const SizedBox(width: 6),
                      const Expanded(
                        child: Text(
                          'Shell',
                          style: TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 28,
                        height: 28,
                        child: IconButton(
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.close, size: 14, color: AppColors.textMuted),
                          tooltip: '关闭',
                          padding: EdgeInsets.zero,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ClipRRect(
                    borderRadius: const BorderRadius.vertical(bottom: Radius.circular(12)),
                    child: AppIframeView(src: src),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showUserDialog() {
    final api = context.read<ApiService>();
    final oldPasswordController = TextEditingController();
    final newPasswordController = TextEditingController();
    bool isLoading = false;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          backgroundColor: AppColors.surface,
          title: const Text('修改密码', style: TextStyle(color: AppColors.textPrimary)),
          content: SizedBox(
            width: 350,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '当前用户: ${api.username}',
                  style: const TextStyle(color: AppColors.textSecondary, fontSize: 14),
                ),
                const SizedBox(height: 20),
                const Text('原密码', style: TextStyle(color: AppColors.textMuted, fontSize: 12)),
                const SizedBox(height: 4),
                TextField(
                  controller: oldPasswordController,
                  obscureText: true,
                  style: const TextStyle(color: AppColors.textPrimary),
                  decoration: InputDecoration(
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                ),
                const SizedBox(height: 12),
                const Text('新密码', style: TextStyle(color: AppColors.textMuted, fontSize: 12)),
                const SizedBox(height: 4),
                TextField(
                  controller: newPasswordController,
                  obscureText: true,
                  style: const TextStyle(color: AppColors.textPrimary),
                  decoration: InputDecoration(
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: isLoading ? null : () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: isLoading
                  ? null
                  : () async {
                      setState(() => isLoading = true);
                      try {
                        await api.updateUserSettings(
                          oldPassword: oldPasswordController.text,
                          newPassword: newPasswordController.text,
                        );
                        if (context.mounted) {
                          Navigator.pop(context);
                          _showSnack('密码修改成功');
                        }
                      } catch (e) {
                        if (context.mounted) {
                          _showSnack(e.toString().replaceFirst('Exception: ', ''), isError: true);
                        }
                      } finally {
                        if (context.mounted) {
                          setState(() => isLoading = false);
                        }
                      }
                    },
              child: isLoading
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }

  void _logout() {
    showDialog(
      context: context,
      barrierColor: Colors.black54,
      builder: (context) => Dialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 280),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  '退出登录',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  '确定要退出登录吗？',
                  style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
                ),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: () async {
                    await context.read<ApiService>().logout();
                    if (context.mounted) {
                      Navigator.pop(context);
                    }
                  },
                  child: const Text('退出'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _createDirectory() async {
    final name = await _showNameDialog(
      title: '新建目录',
      label: '目录名称',
      initialValue: '',
      confirmLabel: '创建',
    );
    if (name == null || name.isEmpty) return;
    try {
      await _runToolbarBusyAction('正在创建目录', () async {
        await context.read<ApiService>().createDirectory(
              parent: _currentPath,
              name: name,
            );
        await _refreshCurrentDirectory();
        await _loadDirectoryChildren(_currentPath);
      });
      _showSnack('目录已创建');
    } catch (error) {
      _showSnack(_normalizeUploadError(error), isError: true);
    }
  }

  Future<void> _createFile() async {
    final name = await _showNameDialog(
      title: '新建文件',
      label: '文件名称',
      initialValue: '',
      confirmLabel: '创建',
    );
    if (name == null || name.isEmpty) return;
    try {
      await _runToolbarBusyAction('创建中', () async {
        await context.read<ApiService>().createFile(
              parent: _currentPath,
              name: name,
            );
        await _refreshCurrentDirectory();
      });
      _showSnack('文件已创建');
    } catch (error) {
      _showSnack(_normalizeUploadError(error), isError: true);
    }
  }

  Future<void> _uploadFile() async {
    if (_isUploadActionDisabled) {
      _showSnack('当前有任务正在执行，请稍后重试', isError: true);
      return;
    }
    try {
      final ApiService api = context.read<ApiService>();
      setState(() => _nativeUploadBusy = true);
      final NativeBrowserUploadResult result =
          await pickAndUploadFilesWithBrowser(
        endpointUrl: api.uploadUrl,
        chunkInitUrl: '${api.uploadUrl}/init',
        chunkUrl: '${api.uploadUrl}/chunk',
        completeUrl: '${api.uploadUrl}/complete',
        cancelUrl: '${api.uploadUrl}/cancel',
        chunkSize: _browserUploadChunkSize,
        retryCount: _browserUploadRetryCount,
        token: api.token ?? '',
        query: <String, String>{'parent': _currentPath},
        multiple: true,
        title: '正在上传文件',
      );
      if (result.uploadedCount == 0) {
        return;
      }
      await _refreshCurrentDirectory();
      if (result.uploadedCount == 1 && result.skippedCount == 0) {
        _showSnack('文件上传成功');
      } else if (result.skippedCount > 0) {
        _showSnack(
            '已上传 ${result.uploadedCount} 个文件，跳过 ${result.skippedCount} 项');
      } else {
        _showSnack('已上传 ${result.uploadedCount} 个文件');
      }
    } catch (error) {
      _showSnack(error.toString().replaceFirst('Exception: ', ''),
          isError: true);
    } finally {
      if (mounted) {
        setState(() => _nativeUploadBusy = false);
      }
    }
  }

  Future<void> _uploadBrowserFiles(List<Object> files) async {
    if (files.isEmpty) {
      _showSnack('未检测到可上传文件', isError: true);
      return;
    }
    if (_isUploadActionDisabled) {
      _showSnack('当前有任务正在执行，请稍后重试', isError: true);
      return;
    }

    try {
      final ApiService api = context.read<ApiService>();
      setState(() => _nativeUploadBusy = true);
      final NativeBrowserUploadResult result =
          await uploadBrowserFilesWithBrowser(
        endpointUrl: api.uploadUrl,
        chunkInitUrl: '${api.uploadUrl}/init',
        chunkUrl: '${api.uploadUrl}/chunk',
        completeUrl: '${api.uploadUrl}/complete',
        cancelUrl: '${api.uploadUrl}/cancel',
        chunkSize: _browserUploadChunkSize,
        retryCount: _browserUploadRetryCount,
        token: api.token ?? '',
        query: <String, String>{'parent': _currentPath},
        browserFiles: files,
        title: '正在上传文件',
      );
      if (result.uploadedCount == 0) {
        _showSnack('未检测到可上传文件', isError: true);
        return;
      }
      await _refreshCurrentDirectory();
      if (result.uploadedCount == 1 && result.skippedCount == 0) {
        _showSnack('文件上传成功');
      } else if (result.skippedCount > 0) {
        _showSnack(
          '已上传 ${result.uploadedCount} 个文件，跳过 ${result.skippedCount} 项',
        );
      } else {
        _showSnack('已上传 ${result.uploadedCount} 个文件');
      }
    } catch (error) {
      _showSnack(error.toString().replaceFirst('Exception: ', ''),
          isError: true);
    } finally {
      if (mounted) {
        setState(() => _nativeUploadBusy = false);
      }
    }
  }

  Iterable<DropItem> _flattenDropItems(Iterable<DropItem> items) sync* {
    for (final DropItem item in items) {
      if (item is DropItemDirectory) {
        yield* _flattenDropItems(item.children);
      } else {
        yield item;
      }
    }
  }

  Future<void> _uploadDroppedFiles(List<DropItem> files) async {
    if (files.isEmpty) {
      return;
    }
    final List<Object> browserFiles = <Object>[];
    for (final DropItem file in _flattenDropItems(files)) {
      try {
        final dynamic rawFile = file;
        final Object? browserFile =
            rawFile.webFile is Object ? rawFile.webFile as Object : null;
        if (browserFile == null) {
          continue;
        }
        browserFiles.add(browserFile);
      } catch (_) {
        // Ignore unreadable item and continue.
      }
    }
    await _uploadBrowserFiles(browserFiles);
  }

  Future<void> _renameSelected() async {
    final entry = _selectedEntry;
    if (entry == null || _selectedPaths.length != 1) return;
    final newName = await _showNameDialog(
      title: '重命名',
      label: '新名称',
      initialValue: entry.name,
      confirmLabel: '保存',
    );
    if (newName == null || newName.isEmpty || newName == entry.name) return;
    try {
      await _runToolbarBusyAction('重命名中', () async {
        await context.read<ApiService>().renameFile(
              path: entry.path,
              newName: newName,
            );
        await _refreshCurrentDirectory();
        await _loadDirectoryChildren(_currentPath);
        if (entry.isDir) {
          _directoryTree.remove(entry.path);
        }
        _clearSelection();
      });
      _showSnack('已重命名');
    } catch (error) {
      _showSnack(error.toString().replaceFirst('Exception: ', ''),
          isError: true);
    }
  }

  Future<void> _deleteSelected() async {
    final List<String> paths = _selectedTargets();
    if (paths.isEmpty) return;
    final List<_RemoteFileEntry> entries = _selectedEntries;
    final bool containsDirectory = entries.any((entry) => entry.isDir);
    final String message = paths.length == 1
        ? '确定删除 ${entries.first.name} 吗？${containsDirectory ? ' 目录会递归删除。' : ''}'
        : '确定删除选中的 ${paths.length} 项吗？${containsDirectory ? ' 其中目录会递归删除。' : ''}';
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AppConfirmDialog(
        title: '删除确认',
        message: message,
        confirmLabel: '删除',
        tone: AppTone.danger,
      ),
    );

    if (confirmed != true) return;

    try {
      await _runToolbarBusyAction('删除中', () async {
        for (final String path in paths) {
          await context.read<ApiService>().deleteFile(
                path: path,
              );
        }
        await _refreshCurrentDirectory();
        await _loadDirectoryChildren(_currentPath);
        for (final _RemoteFileEntry entry
            in entries.where((item) => item.isDir)) {
          _directoryTree.remove(entry.path);
          _expandedDirs.remove(entry.path);
        }
        _clearSelection();
      });
      _showSnack('已删除');
    } catch (error) {
      _showSnack(error.toString().replaceFirst('Exception: ', ''),
          isError: true);
    }
  }

  Future<void> _showPropertiesDialog() async {
    final _RemoteFileEntry? entry = _selectedEntry;
    if (entry == null || _selectedPaths.length != 1) return;

    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.45),
      builder: (BuildContext dialogContext) {
        return _FilePropertiesDialog(
          entry: entry,
        );
      },
    );
  }

  Future<void> _openTextEditor({_RemoteFileEntry? fallback}) async {
    final _RemoteFileEntry? entry = fallback ?? _selectedEntry;
    final List<String> paths = _selectedTargets(fallback: fallback);
    if (entry == null || entry.isDir || paths.length != 1) return;

    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.52),
      builder: (BuildContext dialogContext) {
        return _TextFileEditorDialog(
          path: entry.path,
          name: entry.name,
        );
      },
    );

    if (!mounted) return;
    await _refreshCurrentDirectory();
  }

  bool _isEditableTextEntry(_RemoteFileEntry entry) {
    final String lower = entry.name.toLowerCase();
    final List<String> editableExtensions = <String>[
      '.txt', '.md', '.markdown', '.json', '.xml', '.yaml', '.yml', '.toml',
      '.ini', '.cfg', '.conf', '.properties', '.env', '.gitignore',
      '.log', '.csv', '.tsv',
      '.js', '.jsx', '.ts', '.tsx', '.mjs', '.cjs',
      '.py', '.rb', '.pl', '.php', '.sh', '.bash', '.zsh', '.fish',
      '.c', '.h', '.cpp', '.hpp', '.cc', '.cxx', '.hxx',
      '.java', '.kt', '.kts', '.scala', '.go', '.rs', '.swift',
      '.html', '.htm', '.css', '.scss', '.sass', '.less',
      '.sql', '.graphql', '.gql',
      '.dart', '.lua', '.r', '.R', '.m', '.mm',
      '.vue', '.svelte', '.astro',
      '.dockerfile', '.makefile', '.cmake',
      '.diff', '.patch',
      '.lock',
    ];
    for (final String ext in editableExtensions) {
      if (lower.endsWith(ext)) {
        return true;
      }
    }
    return false;
  }

  Future<void> _openPreviewOrEditor({_RemoteFileEntry? fallback}) async {
    final _RemoteFileEntry? entry = fallback ?? _selectedEntry;
    final List<String> paths = _selectedTargets(fallback: fallback);
    if (entry == null || entry.isDir || paths.length != 1) {
      return;
    }

    if (_isImageEntry(entry)) {
      await showDialog<void>(
        context: context,
        barrierColor: Colors.black.withValues(alpha: 0.52),
        builder: (BuildContext dialogContext) {
          return _ImageFilePreviewDialog(
            entry: entry,
          );
        },
      );
      return;
    }

    if (_isPdfEntry(entry)) {
      await showDialog<void>(
        context: context,
        barrierColor: Colors.black.withValues(alpha: 0.52),
        builder: (BuildContext dialogContext) {
          return _PdfFilePreviewDialog(
            entry: entry,
          );
        },
      );
      return;
    }

    if (!_isEditableTextEntry(entry)) {
      await _showUnsupportedFileDownloadDialog(entry);
      return;
    }

    await _openTextEditor(fallback: entry);
  }

  Future<void> _showUnsupportedFileDownloadDialog(_RemoteFileEntry entry) async {
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.45),
      builder: (BuildContext dialogContext) {
        return Dialog(
          backgroundColor: const Color(0xFF161B22),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: const BorderSide(color: Color(0xFF30363D)),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 340),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Icon(
                    Icons.insert_drive_file_outlined,
                    size: 32,
                    color: Color(0xFF58A6FF),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    entry.name,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${AppFormat.bytes(entry.size)} · 此文件类型不支持在线预览',
                    style: const TextStyle(
                      color: Color(0xFF8B949E),
                      fontSize: 12,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: <Widget>[
                      ElevatedButton.icon(
                        onPressed: () {
                          Navigator.of(dialogContext).pop();
                          _downloadSelection(fallback: entry);
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF1F6FEB),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        ),
                        icon: const Icon(Icons.file_download_outlined, size: 16, color: Colors.white),
                        label: const Text(
                          '下载',
                          style: TextStyle(color: Colors.white, fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<String?> _showNameDialog({
    required String title,
    required String label,
    required String initialValue,
    required String confirmLabel,
  }) async {
    final controller = TextEditingController(text: initialValue);
    return showAppDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AppDialogFrame(
          title: title,
          size: AppDialogSize.compact,
          showCloseButton: true,
          child: TextField(
            controller: controller,
            autofocus: true,
            style: const TextStyle(color: AppColors.textPrimary),
            decoration: AppInputDecorations.outlined(
              labelText: label,
              fillColor: AppColors.backgroundCanvas,
              radius: _controlRadius,
            ),
          ),
          actions: <Widget>[
            AppSecondaryButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              label: '取消',
            ),
            const SizedBox(width: 10),
            AppPrimaryButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(controller.text.trim()),
              icon: Icons.check,
              label: confirmLabel,
            ),
          ],
        );
      },
    );
  }

  void _showSnack(String message, {bool isError = false}) {
    AppToast.show(
      context,
      message,
      type: isError ? AppToastType.error : AppToastType.success,
    );
  }

  String? _nullIfEmpty(String? value) {
    if (value == null || value.isEmpty) return null;
    return value;
  }

  List<_RemoteFileEntry> get _displayEntries {
    if (_cachedDisplayEntries != null &&
        _cachedSearchQuery == _searchQuery &&
        _cachedShowHidden == _showHiddenFiles &&
        _cachedSortField == _sortField &&
        _cachedSortAsc == _sortAscending &&
        identical(_cachedSourceEntries, _entries)) {
      return _cachedDisplayEntries!;
    }
    final List<_RemoteFileEntry> entries = _entries
        .where((entry) => _showHiddenFiles || !entry.name.startsWith('.'))
        .where((entry) {
      final String keyword = _searchQuery.trim().toLowerCase();
      if (keyword.isEmpty) {
        return true;
      }
      return entry.name.toLowerCase().contains(keyword) ||
          entry.path.toLowerCase().contains(keyword);
    }).toList();
    entries.sort(_compareEntries);
    _cachedDisplayEntries = entries;
    _cachedSearchQuery = _searchQuery;
    _cachedShowHidden = _showHiddenFiles;
    _cachedSortField = _sortField;
    _cachedSortAsc = _sortAscending;
    _cachedSourceEntries = _entries;
    return entries;
  }

  List<_RemoteFileEntry> _sortedTreeEntries(String path) {
    final List<_RemoteFileEntry> entries = List<_RemoteFileEntry>.from(
            _directoryTree[path] ?? const <_RemoteFileEntry>[])
        .where((entry) => _showHiddenFiles || !entry.name.startsWith('.'))
        .toList();
    entries.sort(_compareEntries);
    return entries;
  }

  int _compareEntries(_RemoteFileEntry a, _RemoteFileEntry b) {
    if (a.isDir != b.isDir) {
      return a.isDir ? -1 : 1;
    }

    int result;
    switch (_sortField) {
      case _FileSortField.name:
        result = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      case _FileSortField.createdAt:
        result = a.createdAt.compareTo(b.createdAt);
      case _FileSortField.modifiedAt:
        result = a.modifiedAt.compareTo(b.modifiedAt);
    }

    return _sortAscending ? result : -result;
  }

  void _togglePathEditing() {
    setState(() {
      _editingPath = true;
      _pathController.text = _currentPath;
    });
  }

  Future<void> _submitPathEdit() async {
    final String nextPath = _normalizePath(_pathController.text);
    setState(() => _editingPath = false);
    if (nextPath == _currentPath) return;
    await _loadDirectory(nextPath);
  }

  void _cancelPathEdit() {
    setState(() {
      _editingPath = false;
      _pathController.text = _currentPath;
    });
  }

  String _normalizePath(String value) {
    final String trimmed = value.trim();
    if (trimmed.isEmpty || trimmed == '.') return '/';
    final List<String> parts = <String>[];
    for (final String part in trimmed.split('/')) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') {
        if (parts.isNotEmpty) {
          parts.removeLast();
        }
        continue;
      }
      parts.add(part);
    }
    return '/${parts.join('/')}';
  }

  bool _isMobileLayout(BoxConstraints constraints) =>
      constraints.maxWidth < 700;

  List<_RemoteFileEntry> get _selectedEntries => _entries
      .where((entry) => _selectedPaths.contains(entry.path))
      .toList(growable: false);

  bool get _hasSelection => _selectedPaths.isNotEmpty;

  bool get _hasClipboardItems =>
      _clipboardAction != null && _clipboardPaths.isNotEmpty;

  List<String> _selectedTargets({_RemoteFileEntry? fallback}) {
    if (_selectedPaths.isNotEmpty) {
      return _selectedEntries
          .map((entry) => entry.path)
          .toList(growable: false);
    }
    if (fallback != null) {
      return <String>[fallback.path];
    }
    if (_selectedEntry != null) {
      return <String>[_selectedEntry!.path];
    }
    return const <String>[];
  }

  bool _isEntrySelected(_RemoteFileEntry entry) =>
      _selectedPaths.contains(entry.path);

  void _selectOnly(_RemoteFileEntry entry) {
    if (!mounted) return;
    setState(() {
      _selectedEntry = entry;
      _selectedPaths = <String>{entry.path};
    });
  }

  void _toggleSelection(_RemoteFileEntry entry) {
    if (!mounted) return;
    setState(() {
      if (_selectedPaths.contains(entry.path)) {
        _selectedPaths.remove(entry.path);
        if (_selectedEntry?.path == entry.path) {
          _selectedEntry = _selectedPaths.isEmpty
              ? null
              : _entries.firstWhere(
                  (item) => _selectedPaths.contains(item.path),
                );
        }
      } else {
        _selectedPaths = <String>{..._selectedPaths, entry.path};
        _selectedEntry = entry;
      }
    });
  }

  void _clearSelection() {
    _dismissActiveContextMenu();
    if (!mounted) return;
    setState(() {
      _selectedEntry = null;
      _selectedPaths = <String>{};
      _mobileSelectionMode = false;
    });
  }

  bool _isMultiSelectModifierPressed() {
    final Set<LogicalKeyboardKey> keys =
        HardwareKeyboard.instance.logicalKeysPressed;
    return keys.contains(LogicalKeyboardKey.controlLeft) ||
        keys.contains(LogicalKeyboardKey.controlRight) ||
        keys.contains(LogicalKeyboardKey.metaLeft) ||
        keys.contains(LogicalKeyboardKey.metaRight);
  }

  void _handleDesktopEntryTap(_RemoteFileEntry entry) {
    if (_isMultiSelectModifierPressed()) {
      _toggleSelection(entry);
      return;
    }
    _selectOnly(entry);
  }

  Future<void> _toggleTreeNode(String path, bool expanded) async {
    if (expanded) {
      setState(() => _expandedDirs.remove(path));
      return;
    }
    setState(() => _expandedDirs.add(path));
    await _loadDirectoryChildren(path);
  }

  Future<void> _copySelection() async {
    final List<String> paths = _selectedTargets();
    if (paths.isEmpty) return;
    setState(() {
      _clipboardAction = _ClipboardAction.copy;
      _clipboardPaths = paths;
    });
    _showSnack('已加入复制列表');
  }

  Future<void> _moveSelection() async {
    final List<String> paths = _selectedTargets();
    if (paths.isEmpty) return;
    setState(() {
      _clipboardAction = _ClipboardAction.move;
      _clipboardPaths = paths;
    });
    _showSnack('已加入移动列表');
  }

  Future<void> _applyClipboardAction() async {
    if (!_hasClipboardItems || _clipboardAction == null) return;
    try {
      final ApiService api = context.read<ApiService>();
      final _ClipboardAction action = _clipboardAction!;
      await _runToolbarBusyAction(
        action == _ClipboardAction.copy ? '复制中' : '移动中',
        () async {
          if (action == _ClipboardAction.copy) {
            await api.copyFiles(
              paths: _clipboardPaths,
              targetDir: _currentPath,
            );
          } else {
            await api.moveFiles(
              paths: _clipboardPaths,
              targetDir: _currentPath,
            );
          }
          await _refreshCurrentDirectory();
          await _loadDirectoryChildren(_currentPath);
          setState(() {
            _clipboardAction = null;
            _clipboardPaths = const <String>[];
          });
        },
      );
      _showSnack(
        action == _ClipboardAction.copy ? '已粘贴到当前目录' : '已移动到当前目录',
      );
    } catch (error) {
      _showSnack(error.toString().replaceFirst('Exception: ', ''),
          isError: true);
    }
  }

  Future<void> _archiveSelection({_RemoteFileEntry? fallback}) async {
    final List<String> paths = _selectedTargets(fallback: fallback);
    if (paths.isEmpty) return;
    final String initialName = paths.length == 1
        ? '${(fallback ?? _selectedEntry)?.name ?? 'archive'}.tar'
        : 'archive.tar';
    final String? archiveName = await _showNameDialog(
      title: '压缩为 tar',
      label: '压缩包名称',
      initialValue: initialName,
      confirmLabel: '压缩',
    );
    if (archiveName == null || archiveName.isEmpty) return;

    try {
      await _runToolbarBusyAction('压缩中', () async {
        await context.read<ApiService>().archiveFiles(
              paths: paths,
              targetDir: _currentPath,
              archiveName: archiveName,
            );
        await _refreshCurrentDirectory();
      });
      _showSnack('压缩包已创建');
    } catch (error) {
      _showSnack(error.toString().replaceFirst('Exception: ', ''),
          isError: true);
    }
  }

  Future<void> _downloadSelection({_RemoteFileEntry? fallback}) async {
    final List<String> paths = _selectedTargets(fallback: fallback);
    if (paths.isEmpty) return;

    try {
      final String url = context.read<ApiService>().filesDownloadUrl(
            paths: paths,
          );
      await launchFileDownload(url);
      _showSnack('开始下载');
    } catch (error) {
      _showSnack(error.toString().replaceFirst('Exception: ', ''),
          isError: true);
    }
  }

  Future<void> _extractSelection({_RemoteFileEntry? fallback}) async {
    final _RemoteFileEntry? entry = fallback ?? _selectedEntry;
    final List<String> paths = _selectedTargets(fallback: fallback);
    if (entry == null ||
        entry.isDir ||
        paths.length != 1 ||
        !_isArchiveFileName(entry.name)) {
      return;
    }

    try {
      await _runToolbarBusyAction('解压中', () async {
        await context.read<ApiService>().extractArchive(
              path: entry.path,
            );
        await _refreshCurrentDirectory();
        await _loadDirectoryChildren(_currentPath);
      });
      _showSnack('解压完成');
    } catch (error) {
      _showSnack(error.toString().replaceFirst('Exception: ', ''),
          isError: true);
    }
  }

  void _dismissActiveContextMenu() {
    final VoidCallback? close = _activeContextMenuClose;
    if (close != null) {
      _activeContextMenuClose = null;
      close();
    }
  }

  void _markGridEntryMenuGesture(Offset position) {
    _lastGridEntryMenuPosition = position;
    _lastGridEntryMenuTime = DateTime.now();
  }

  bool _shouldIgnoreGridBlankMenuGesture(Offset position) {
    final DateTime? lastTime = _lastGridEntryMenuTime;
    final Offset? lastPos = _lastGridEntryMenuPosition;
    if (lastTime == null || lastPos == null) return false;
    final int dtMs = DateTime.now().difference(lastTime).inMilliseconds;
    if (dtMs > 120) return false;
    return (lastPos - position).distance <= 28;
  }

  Future<void> _showEntryContextMenu(
    _RemoteFileEntry entry,
    Offset globalPosition,
    {bool mobile = false}
  ) async {
    if (!_isEntrySelected(entry)) {
      _selectOnly(entry);
    }

    final bool singleSelection = _selectedTargets(fallback: entry).length == 1;
    final List<_ContextMenuOption<_FileContextAction>> options =
        <_ContextMenuOption<_FileContextAction>>[
      if (singleSelection && entry.isDir)
        const _ContextMenuOption<_FileContextAction>(
          value: _FileContextAction.open,
          label: '打开',
        ),
      if (singleSelection && !entry.isDir)
        const _ContextMenuOption<_FileContextAction>(
          value: _FileContextAction.edit,
          label: '预览 / 编辑',
        ),
      const _ContextMenuOption<_FileContextAction>(
        value: _FileContextAction.download,
        label: '下载',
      ),
      if (_supportsAdvancedActions)
        const _ContextMenuOption<_FileContextAction>(
          value: _FileContextAction.archive,
          label: '压缩为 tar',
        ),
      if (_supportsAdvancedActions &&
          singleSelection &&
          !entry.isDir &&
          _isArchiveFileName(entry.name))
        const _ContextMenuOption<_FileContextAction>(
          value: _FileContextAction.extract,
          label: '解压',
        ),
      if (_supportsAdvancedActions)
        const _ContextMenuOption<_FileContextAction>.divider(),
      if (_supportsAdvancedActions)
        const _ContextMenuOption<_FileContextAction>(
          value: _FileContextAction.copy,
          label: '复制',
        ),
      if (_supportsAdvancedActions)
        const _ContextMenuOption<_FileContextAction>(
          value: _FileContextAction.move,
          label: '移动',
        ),
      if (singleSelection)
        const _ContextMenuOption<_FileContextAction>(
          value: _FileContextAction.rename,
          label: '重命名',
        ),
      const _ContextMenuOption<_FileContextAction>(
        value: _FileContextAction.delete,
        label: '删除',
      ),
      if (singleSelection)
        const _ContextMenuOption<_FileContextAction>(
          value: _FileContextAction.properties,
          label: '属性',
        ),
    ];
    final _FileContextAction? action =
        await _showContextMenu<_FileContextAction>(
      globalPosition: globalPosition,
      options: options,
      dismissOnOutsideTap: true,
      onOutsideTap: mobile
          ? () {
              if (!mounted) return;
              setState(() {
                _selectedEntry = null;
                _selectedPaths = <String>{};
                _mobileSelectionMode = false;
              });
            }
          : null,
    );

    if (!mounted || action == null) return;
    switch (action) {
      case _FileContextAction.open:
        await _openEntry(entry);
        break;
      case _FileContextAction.edit:
        await _openPreviewOrEditor(fallback: entry);
        break;
      case _FileContextAction.download:
        await _downloadSelection(fallback: entry);
        break;
      case _FileContextAction.archive:
        await _archiveSelection(fallback: entry);
        break;
      case _FileContextAction.extract:
        await _extractSelection(fallback: entry);
        break;
      case _FileContextAction.copy:
        await _copySelection();
        break;
      case _FileContextAction.move:
        await _moveSelection();
        break;
      case _FileContextAction.rename:
        await _renameSelected();
        break;
      case _FileContextAction.properties:
        await _showPropertiesDialog();
        break;
      case _FileContextAction.delete:
        await _deleteSelected();
        break;
    }
  }

  Future<void> _showMobileLongPressMenu(
    _RemoteFileEntry entry,
    LongPressStartDetails details,
  ) async {
    if (_isToolbarBusy) return;
    _dismissActiveContextMenu();
    if (_mobileSelectionMode && mounted) {
      setState(() => _mobileSelectionMode = false);
    }
    if (!_isEntrySelected(entry) || _selectedPaths.length != 1) {
      _selectOnly(entry);
    }
    await _showEntryContextMenu(entry, details.globalPosition, mobile: true);
  }

  Future<void> _showBlankContextMenu(Offset globalPosition) async {
    _clearSelection();
    final List<_ContextMenuOption<_BlankContextAction>> options =
        <_ContextMenuOption<_BlankContextAction>>[
      if (_supportsAdvancedActions && _hasClipboardItems)
        _ContextMenuOption<_BlankContextAction>(
          value: _BlankContextAction.paste,
          label: _clipboardAction == _ClipboardAction.copy ? '粘贴到此' : '移动到此',
        ),
      if (_supportsAdvancedActions && _hasClipboardItems)
        const _ContextMenuOption<_BlankContextAction>.divider(),
      if (!_isUploadInProgress)
        const _ContextMenuOption<_BlankContextAction>(
          value: _BlankContextAction.upload,
          label: '上传',
        ),
      const _ContextMenuOption<_BlankContextAction>(
        value: _BlankContextAction.newFile,
        label: '新建文件',
      ),
      const _ContextMenuOption<_BlankContextAction>(
        value: _BlankContextAction.newDirectory,
        label: '新建目录',
      ),
      const _ContextMenuOption<_BlankContextAction>.divider(),
      const _ContextMenuOption<_BlankContextAction>(
        value: _BlankContextAction.refresh,
        label: '刷新',
      ),
    ];
    final _BlankContextAction? action =
        await _showContextMenu<_BlankContextAction>(
      globalPosition: globalPosition,
      options: options,
    );

    if (!mounted || action == null) return;
    switch (action) {
      case _BlankContextAction.paste:
        await _applyClipboardAction();
        break;
      case _BlankContextAction.upload:
        await _uploadFile();
        break;
      case _BlankContextAction.newFile:
        await _createFile();
        break;
      case _BlankContextAction.newDirectory:
        await _createDirectory();
        break;
      case _BlankContextAction.refresh:
        await _refreshCurrentDirectory(showBusyIndicator: true);
        break;
    }
  }

  Future<T?> _showContextMenu<T>({
    required Offset globalPosition,
    required List<_ContextMenuOption<T>> options,
    bool dismissOnOutsideTap = true,
    VoidCallback? onOutsideTap,
  }) {
    if (_isToolbarBusy) {
      return Future<T?>.value(null);
    }
    final OverlayState overlay = Overlay.of(context);
    _dismissActiveContextMenu();
    final Completer<T?> completer = Completer<T?>();
    final Size screenSize = MediaQuery.sizeOf(context);
    const double menuWidth = 186;
    const double itemHeight = 36;
    const double dividerHeight = 9;
    const double menuPadding = 6;
    const double screenPadding = 10;
    final double menuHeight = menuPadding * 2 +
        options.fold<double>(
          0,
          (double sum, _ContextMenuOption<T> option) =>
              sum + (option.isDivider ? dividerHeight : itemHeight),
        );

    double left = globalPosition.dx;
    double top = globalPosition.dy;
    if (left + menuWidth + screenPadding > screenSize.width) {
      left = screenSize.width - menuWidth - screenPadding;
    }
    if (top + menuHeight + screenPadding > screenSize.height) {
      top = screenSize.height - menuHeight - screenPadding;
    }
    if (left < screenPadding) {
      left = screenPadding;
    }
    if (top < screenPadding) {
      top = screenPadding;
    }

    late final OverlayEntry entry;
    void close([T? value]) {
      if (entry.mounted) {
        entry.remove();
      }
      if (identical(_activeContextMenuEntry, entry)) {
        _activeContextMenuEntry = null;
        _activeContextMenuClose = null;
      }
      if (!completer.isCompleted) {
        completer.complete(value);
      }
    }

    entry = OverlayEntry(
      builder: (BuildContext context) {
        return Material(
          color: Colors.transparent,
          child: Stack(
            children: <Widget>[
              Positioned.fill(
                child: dismissOnOutsideTap
                    ? GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          onOutsideTap?.call();
                          close();
                        },
                        onSecondaryTapDown: (TapDownDetails details) {
                          onOutsideTap?.call();
                          close();
                        },
                        child: const SizedBox.expand(),
                      )
                    : const IgnorePointer(child: SizedBox.expand()),
              ),
              Positioned(
                left: left,
                top: top,
                width: menuWidth,
                child: Material(
                  color: Colors.transparent,
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: menuPadding),
                    decoration: BoxDecoration(
                      color: const Color(0xFF161B22),
                      borderRadius: BorderRadius.circular(_controlRadius),
                      border: Border.all(color: const Color(0xFF30363D)),
                      boxShadow: <BoxShadow>[
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.32),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: options.map((_ContextMenuOption<T> option) {
                        if (option.isDivider) {
                          return const Padding(
                            padding: EdgeInsets.symmetric(vertical: 4),
                            child: Divider(height: 1, color: Color(0xFF21262D)),
                          );
                        }
                        return _ContextMenuActionItem<T>(
                          option: option,
                          height: itemHeight,
                          onTap: () => close(option.value),
                        );
                      }).toList(),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );

    _activeContextMenuEntry = entry;
    _activeContextMenuClose = () => close();
    overlay.insert(entry);
    return completer.future;
  }

  Widget _buildBlankArea({required double minHeight}) {
    final bool isMobile = MediaQuery.sizeOf(context).width < 700;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: _clearSelection,
      onSecondaryTapDown: (TapDownDetails details) =>
          _showBlankContextMenu(details.globalPosition),
      onLongPressStart: isMobile
          ? (LongPressStartDetails details) =>
              _showBlankContextMenu(details.globalPosition)
          : null,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: minHeight < 80 ? 80 : minHeight,
          minWidth: double.infinity,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.keyF, control: true):
            _ActivateFileManagerSearchIntent(),
        SingleActivator(LogicalKeyboardKey.keyF, meta: true):
            _ActivateFileManagerSearchIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _ActivateFileManagerSearchIntent:
              CallbackAction<_ActivateFileManagerSearchIntent>(
            onInvoke: (_ActivateFileManagerSearchIntent intent) {
              _searchController.focus();
              return null;
            },
          ),
        },
        child: Column(
          children: <Widget>[
            _buildHeader(),
            Expanded(
              child: Container(
                key: _dropAreaKey,
                child: Stack(
                  children: <Widget>[
                    Positioned.fill(
                      child: IgnorePointer(
                        ignoring: _isInteractionLocked,
                        child: LayoutBuilder(
                          builder: (BuildContext context,
                              BoxConstraints constraints) {
                            if (_isMobileLayout(constraints)) {
                              return _buildMainList(isMobile: true);
                            }

                            if (constraints.maxWidth < 900) {
                              return _buildMainList();
                            }

                            return Row(
                              children: <Widget>[
                                SizedBox(
                                    width: 250, child: _buildDirectoryRail()),
                                const VerticalDivider(
                                    width: 1, color: Color(0xFF21262D)),
                                Expanded(flex: 5, child: _buildMainList()),
                              ],
                            );
                          },
                        ),
                      ),
                    ),
                    if (_draggingUpload && !_isUploadActionDisabled)
                      Positioned.fill(
                        child: Container(
                          color:
                              const Color(0xFF081018).withValues(alpha: 0.58),
                          alignment: Alignment.center,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 22, vertical: 14),
                            decoration: BoxDecoration(
                              color: const Color(0xFF111827),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: AppColors.primary),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                Icon(
                                  Icons.file_upload_outlined,
                                  color: AppColors.primaryGlow,
                                  size: 18,
                                ),
                                SizedBox(width: 10),
                                Text(
                                  '松开以上传到当前目录',
                                  style: TextStyle(
                                    color: AppColors.textPrimary,
                                    fontSize: _bodyFontSize,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    if (_isToolbarBusy)
                      Positioned.fill(
                        child: _buildBusyContentOverlay(),
                      ),
                  ],
                ),
              ),
            ),
            _buildFooter(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.surfaceMuted)),
      ),
      child: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              children: <Widget>[
                Text(
                  '文件管理器',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                PopupMenuButton<String>(
                  onSelected: (value) {
                    switch (value) {
                      case 'password':
                        _showUserDialog();
                        break;
                      case 'logout':
                        _logout();
                        break;
                    }
                  },
                  tooltip: '',
                  color: AppColors.surface,
                  position: PopupMenuPosition.under,
                  popUpAnimationStyle: AnimationStyle.noAnimation,
                  padding: EdgeInsets.zero,
                  offset: const Offset(0, 0),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6),
                    side: const BorderSide(color: AppColors.border),
                  ),
                  itemBuilder: (context) => [
                    const PopupMenuItem(
                      value: 'password',
                      height: 36,
                      child: Row(
                        children: [
                          Icon(Icons.lock_outline, size: 16),
                          SizedBox(width: 8),
                          Text('修改密码'),
                        ],
                      ),
                    ),
                    const PopupMenuDivider(height: 1),
                    const PopupMenuItem(
                      value: 'logout',
                      height: 36,
                      child: Row(
                        children: [
                          Icon(Icons.logout, size: 16),
                          SizedBox(width: 8),
                          Text('退出登录'),
                        ],
                      ),
                    ),
                  ],
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.primaryFill,
                    ),
                    child: Center(
                      child: Text(
                        (context.read<ApiService>().username ?? 'A')[0].toUpperCase(),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              children: <Widget>[
                _iconButton(
                  Icons.arrow_upward,
                  _isInteractionLocked || _parentPath == null
                      ? null
                      : () => _loadDirectory(_parentPath!),
                ),
                const SizedBox(width: 8),
                Expanded(child: _buildAddressBar()),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: <Widget>[
                        _headerButton(
                          Icons.file_download_outlined,
                          '下载',
                          _isInteractionLocked
                              ? null
                              : (_hasSelection
                                  ? () => _downloadSelection()
                                  : null),
                        ),
                        const SizedBox(width: 8),
                        _headerButton(
                          Icons.edit_note_outlined,
                          '预览 / 编辑',
                          _isInteractionLocked
                              ? null
                              : (_canEditSelectedFile
                                  ? _openPreviewOrEditor
                                  : null),
                        ),
                        if (_supportsAdvancedActions &&
                            _hasClipboardItems) ...<Widget>[
                          const SizedBox(width: 8),
                          _headerButton(
                            _clipboardAction == _ClipboardAction.copy
                                ? Icons.content_paste_outlined
                                : Icons.drive_file_move_outline,
                            _clipboardAction == _ClipboardAction.copy
                                ? '粘贴到此'
                                : '移动到此',
                            _isInteractionLocked ? null : _applyClipboardAction,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                AppHeaderSearchRefresh(
                  controller: _searchController,
                  value: _searchQuery,
                  hintText: '搜索当前目录',
                  onChanged: (String value) {
                    _searchDebounce?.cancel();
                    _searchDebounce =
                        Timer(const Duration(milliseconds: 300), () {
                      if (mounted) setState(() => _searchQuery = value);
                    });
                  },
                  onRefresh: _isInteractionLocked
                      ? null
                      : () => _refreshCurrentDirectory(showBusyIndicator: true),
                  expandedWidth: 220,
                ),
                if (context.read<ApiService>().isAdmin) ...[
                  const SizedBox(width: 6),
                  SizedBox(
                    width: 36,
                    height: 36,
                    child: OutlinedButton(
                      onPressed: _isInteractionLocked ? null : _showShellDialog,
                      style: AppButtonStyles.outlined(
                        background: AppColors.surface,
                        minimumSize: const Size(36, 36),
                        padding: EdgeInsets.zero,
                        radius: 8,
                      ),
                      child: const Icon(
                        Icons.terminal,
                        size: 16,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ),
                ],
                const SizedBox(width: 6),
                _buildSettingsMenu(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAddressBar() {
    if (_editingPath) {
      return Container(
        height: 34,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(_controlRadius),
          color: AppColors.background,
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                controller: _pathController,
                focusNode: _pathFocusNode,
                enabled: !_isInteractionLocked,
                autofocus: true,
                onSubmitted:
                    _isInteractionLocked ? null : (_) => _submitPathEdit(),
                style: const TextStyle(
                    color: AppColors.textPrimary, fontSize: _bodyFontSize),
                decoration: InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(_controlRadius),
                    borderSide: const BorderSide(color: AppColors.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(_controlRadius),
                    borderSide: const BorderSide(color: AppColors.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(_controlRadius),
                    borderSide: const BorderSide(color: AppColors.primaryGlow, width: 1.5),
                  ),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                ),
              ),
            ),
            _iconButton(
              Icons.check,
              _isInteractionLocked ? null : _submitPathEdit,
            ),
            const SizedBox(width: 2),
            _iconButton(Icons.close, _cancelPathEdit),
            const SizedBox(width: 6),
          ],
        ),
      );
    }

    final parts = _currentPath == '/'
        ? <String>[]
        : _currentPath
            .split('/')
            .where((String part) => part.isNotEmpty)
            .toList();
    final crumbs = <_BreadcrumbItem>[_BreadcrumbItem('/', '/')];
    var cursor = '';
    for (final String part in parts) {
      cursor = '$cursor/$part';
      crumbs.add(_BreadcrumbItem(part, cursor));
    }

    return InkWell(
      onTap: _isInteractionLocked ? null : _togglePathEditing,
      borderRadius: BorderRadius.circular(_controlRadius),
      child: Container(
        width: double.infinity,
        height: 34,
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 2),
        decoration: BoxDecoration(
          border: Border.all(color: AppColors.border),
          borderRadius: BorderRadius.circular(_controlRadius),
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: crumbs.expand((item) {
              final bool active = item.path == _currentPath;
              final int index = crumbs.indexOf(item);
              final bool isRoot = index == 0;
              return <Widget>[
                InkWell(
                  onTap: _isInteractionLocked
                      ? null
                      : (active
                          ? _togglePathEditing
                          : () => _loadDirectory(item.path)),
                  borderRadius: BorderRadius.circular(_controlRadius),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                    child: isRoot
                        ? Icon(
                            Icons.home_outlined,
                            size: 15,
                            color: active
                                ? AppColors.primaryGlow
                                : AppColors.textSecondary,
                          )
                        : Text(
                            item.label,
                            style: TextStyle(
                              color: active
                                  ? AppColors.primaryGlow
                                  : AppColors.textSecondary,
                              fontSize: _bodyFontSize,
                              fontWeight:
                                  active ? FontWeight.w600 : FontWeight.w400,
                            ),
                          ),
                  ),
                ),
                if (index < crumbs.length - 1)
                  const Text(
                    ' / ',
                    style: TextStyle(
                        color: AppColors.textSubtle, fontSize: _bodyFontSize),
                  ),
              ];
            }).toList(),
          ),
        ),
      ),
    );
  }

  Widget _buildDirectoryRail() {
    return Container(
      color: AppColors.surfaceElevated,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: <Widget>[
          const Text(
            '目录树',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: _titleFontSize,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          const Divider(color: AppColors.surfaceMuted, height: 1),
          const SizedBox(height: 12),
          RepaintBoundary(
            child: _buildTreeNode('/', '/', 0),
          ),
        ],
      ),
    );
  }

  Widget _buildTreeNode(String path, String label, int depth) {
    final bool expanded = _expandedDirs.contains(path);
    final bool active = path == _currentPath;
    final List<_RemoteFileEntry> children = _sortedTreeEntries(path);
    final bool loading = _loadingDirs.contains(path);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Container(
          height: 34,
          margin: EdgeInsets.only(left: depth * 14.0, bottom: 4),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: active
                ? const Color(0xFF58A6FF).withValues(alpha: 0.18)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(_controlRadius),
          ),
          child: Row(
            children: <Widget>[
              InkWell(
                onTap: () => _toggleTreeNode(path, expanded),
                splashFactory: NoSplash.splashFactory,
                hoverColor: Colors.transparent,
                splashColor: Colors.transparent,
                highlightColor: Colors.transparent,
                overlayColor: const WidgetStatePropertyAll<Color>(
                  Colors.transparent,
                ),
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: loading
                      ? const Padding(
                          padding: EdgeInsets.all(4),
                          child: CircularProgressIndicator(
                              strokeWidth: 1.4, color: Color(0xFF8B949E)),
                        )
                      : Icon(
                          expanded ? Icons.expand_more : Icons.chevron_right,
                          size: 16,
                          color: active
                              ? const Color(0xFF58A6FF)
                              : const Color(0xFF8B949E),
                        ),
                ),
              ),
              const SizedBox(width: 2),
              Expanded(
                child: InkWell(
                  onTap: () => _loadDirectory(path),
                  splashFactory: NoSplash.splashFactory,
                  hoverColor: Colors.transparent,
                  splashColor: Colors.transparent,
                  highlightColor: Colors.transparent,
                  overlayColor:
                      const WidgetStatePropertyAll<Color>(Colors.transparent),
                  child: Row(
                    children: <Widget>[
                      Icon(Icons.folder_open,
                          size: 15,
                          color: active
                              ? const Color(0xFF58A6FF)
                              : const Color(0xFF58A6FF)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          label,
                          style: TextStyle(
                            color:
                                active ? Colors.white : const Color(0xFFCDD5DF),
                            fontSize: _bodyFontSize,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        if (expanded)
          ...children.map(
            (child) => _buildTreeNode(child.path, child.name, depth + 1),
          ),
      ],
    );
  }

  Widget _buildFooter() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.surfaceMuted)),
      ),
      child: const Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Text(
            'Powered by kiss.sx | 2026',
            style: TextStyle(
              color: AppColors.textMuted,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMainList({bool isMobile = false}) {
    final List<_RemoteFileEntry> entries = _displayEntries;

    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.primary),
      );
    }

    if (_loadError != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.error_outline, size: 28, color: Color(0xFFC93C37)),
            const SizedBox(height: 10),
            Text(
              _loadError!,
              style: const TextStyle(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 10),
            OutlinedButton(
              onPressed: _refreshCurrentDirectory,
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }

    return Container(
      color: AppColors.background,
      child: Column(
        children: <Widget>[
          if (_displayMode == _FileDisplayMode.list) _buildListHeader(),
          Expanded(
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                if (entries.isEmpty) {
                  final bool isMobile = _isMobileLayout(constraints);
                  return GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: _clearSelection,
                    onSecondaryTapDown: (TapDownDetails details) =>
                        _showBlankContextMenu(details.globalPosition),
                    onLongPressStart: isMobile
                        ? (LongPressStartDetails details) =>
                            _showBlankContextMenu(details.globalPosition)
                        : null,
                    child: Center(
                      child: Text(
                        _searchQuery.trim().isNotEmpty ? '没有匹配的文件' : '当前目录为空',
                        style: const TextStyle(color: Color(0xFF8B949E)),
                      ),
                    ),
                  );
                }

                return RepaintBoundary(
                  child: _displayMode == _FileDisplayMode.list
                      ? _buildEntriesList(
                          entries,
                          isMobile: isMobile,
                          viewportHeight: constraints.maxHeight,
                        )
                      : _buildEntriesGrid(
                          entries,
                          isMobile: isMobile,
                          viewportHeight: constraints.maxHeight,
                        ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildListHeader() {
    return Container(
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: const BoxDecoration(
        color: AppColors.surfaceElevated,
        border: Border(bottom: BorderSide(color: AppColors.surfaceMuted)),
      ),
      child: const Row(
        children: <Widget>[
          Expanded(
              flex: 5,
              child: Text('名称',
                  style: TextStyle(
                      color: AppColors.textMuted, fontSize: _bodyFontSize))),
          Expanded(
              flex: 3,
              child: Text('修改时间',
                  style: TextStyle(
                      color: AppColors.textMuted, fontSize: _bodyFontSize))),
          Expanded(
              flex: 2,
              child: Text('大小',
                  style: TextStyle(
                      color: AppColors.textMuted, fontSize: _bodyFontSize))),
          Expanded(
              flex: 2,
              child: Text('权限',
                  style: TextStyle(
                      color: AppColors.textMuted, fontSize: _bodyFontSize))),
        ],
      ),
    );
  }

  Widget _buildEntriesList(List<_RemoteFileEntry> entries,
      {required bool isMobile, required double viewportHeight}) {
    const double rowHeight = 52;
    const double separatorHeight = 1;
    final double contentHeight = entries.isEmpty
        ? 0
        : entries.length * rowHeight + (entries.length - 1) * separatorHeight;
    final double fillerHeight = viewportHeight - contentHeight;

    return ListView.builder(
      itemCount: entries.length + 1,
      itemBuilder: (BuildContext context, int index) {
        if (index == entries.length) {
          return _buildBlankArea(minHeight: fillerHeight);
        }

        final entry = entries[index];
        final bool active = _isEntrySelected(entry);
        return Column(
          key: ValueKey(entry.path),
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (PointerDownEvent event) {
                if (isMobile) {
                  if (event.kind != PointerDeviceKind.touch) return;
                  _selectOnly(entry);
                  return;
                }
                if ((event.buttons & kPrimaryMouseButton) == 0) return;
                _handleDesktopEntryTap(entry);
              },
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onLongPressStart: isMobile
                    ? (LongPressStartDetails details) =>
                        _showMobileLongPressMenu(entry, details)
                    : null,
                child: InkWell(
                  onTap: isMobile ? null : () => _handleDesktopEntryTap(entry),
                  onDoubleTap: () => _openEntry(entry),
                  onSecondaryTapDown: isMobile
                      ? null
                      : (TapDownDetails details) =>
                          _showEntryContextMenu(entry, details.globalPosition),
                  splashFactory: NoSplash.splashFactory,
                  hoverColor: Colors.transparent,
                  splashColor: Colors.transparent,
                  highlightColor: Colors.transparent,
                  overlayColor:
                      const WidgetStatePropertyAll<Color>(Colors.transparent),
                  child: Container(
                    height: rowHeight,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    color:
                        active ? const Color(0xFF102846) : Colors.transparent,
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          flex: 5,
                          child: Row(
                            children: <Widget>[
                              Icon(
                                _iconForEntry(entry),
                                size: 18,
                                color: _iconColorForEntry(entry),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  entry.name,
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: _titleFontSize),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Expanded(
                          flex: 3,
                          child: Text(
                            entry.modifiedAt,
                            style: const TextStyle(
                                color: Color(0xFF8B949E),
                                fontSize: _bodyFontSize),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Expanded(
                          flex: 2,
                          child: Text(
                            entry.isDir ? '-' : _formatSize(entry.size),
                            style: const TextStyle(
                                color: Color(0xFFCDD5DF),
                                fontSize: _bodyFontSize),
                          ),
                        ),
                        Expanded(
                          flex: 2,
                          child: Text(
                            entry.permissions,
                            style: const TextStyle(
                                color: Color(0xFF8B949E),
                                fontSize: _bodyFontSize),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (index < entries.length - 1)
              const Divider(height: separatorHeight, color: Color(0xFF161B22)),
          ],
          );
        },
      );
    }

  Widget _buildEntriesGrid(List<_RemoteFileEntry> entries,
      {required bool isMobile, required double viewportHeight}) {
    const double minItemWidth = 100;
    const double childAspectRatio = 0.85;
    const double spacing = 8;
    const double padding = 10;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double availableWidth = constraints.maxWidth - padding * 2;
        final int crossAxisCount =
            (availableWidth / (minItemWidth + spacing)).floor().clamp(2, 12);
        final double totalSpacing = spacing * (crossAxisCount - 1);
        final double itemWidth =
            (availableWidth - totalSpacing) / crossAxisCount;
        final double itemHeight = itemWidth / childAspectRatio;
        final int rowCount = (entries.length / crossAxisCount).ceil();
        final double contentHeight = rowCount == 0
            ? 0
            : rowCount * itemHeight + (rowCount - 1) * spacing + 20;
        final int remainder = entries.length % crossAxisCount;
        final int fillerCells = remainder == 0 ? 0 : crossAxisCount - remainder;

        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: _clearSelection,
          onSecondaryTapDown: (TapDownDetails details) {
            if (_shouldIgnoreGridBlankMenuGesture(details.globalPosition)) {
              return;
            }
            _showBlankContextMenu(details.globalPosition);
          },
          onLongPressStart: isMobile
              ? (LongPressStartDetails details) {
                  if (_shouldIgnoreGridBlankMenuGesture(
                      details.globalPosition)) {
                    return;
                  }
                  _showBlankContextMenu(details.globalPosition);
                }
              : null,
          child: GridView.builder(
            padding: const EdgeInsets.all(10),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: crossAxisCount,
              mainAxisSpacing: spacing,
              crossAxisSpacing: spacing,
              childAspectRatio: childAspectRatio,
            ),
            itemCount: entries.length + fillerCells + 1,
            itemBuilder: (BuildContext context, int index) {
              if (index >= entries.length) {
                if (index == entries.length + fillerCells) {
                  return _buildBlankArea(
                      minHeight: viewportHeight - contentHeight);
                }
                return GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: _clearSelection,
                  onSecondaryTapDown: (TapDownDetails details) =>
                      _showBlankContextMenu(details.globalPosition),
                  onLongPressStart: isMobile
                      ? (LongPressStartDetails details) =>
                          _showBlankContextMenu(details.globalPosition)
                      : null,
                  child: const SizedBox.expand(),
                );
              }

              final entry = entries[index];
              final bool active = _isEntrySelected(entry);
              return Listener(
                key: ValueKey(entry.path),
                behavior: HitTestBehavior.opaque,
                onPointerDown: (PointerDownEvent event) {
                  if (isMobile) {
                    if (event.kind != PointerDeviceKind.touch) return;
                    _selectOnly(entry);
                    return;
                  }
                  if ((event.buttons & kPrimaryMouseButton) == 0) return;
                  _handleDesktopEntryTap(entry);
                },
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onLongPressStart: isMobile
                      ? (LongPressStartDetails details) {
                          _markGridEntryMenuGesture(details.globalPosition);
                          _showMobileLongPressMenu(entry, details);
                        }
                      : null,
                  child: InkWell(
                    onTap:
                        isMobile ? null : () => _handleDesktopEntryTap(entry),
                    onDoubleTap: () => _openEntry(entry),
                    onSecondaryTapDown: isMobile
                        ? null
                        : (TapDownDetails details) {
                            _markGridEntryMenuGesture(details.globalPosition);
                            _showEntryContextMenu(
                                entry, details.globalPosition);
                          },
                    borderRadius: BorderRadius.circular(_panelRadius),
                    splashFactory: NoSplash.splashFactory,
                    hoverColor: Colors.transparent,
                    splashColor: Colors.transparent,
                    highlightColor: Colors.transparent,
                    overlayColor:
                        const WidgetStatePropertyAll<Color>(Colors.transparent),
                    child: Container(
                      decoration: BoxDecoration(
                        color: active
                            ? const Color(0xFF102846)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(_panelRadius),
                        border: Border.all(
                          color: active
                              ? const Color(0xFF58A6FF)
                              : Colors.transparent,
                        ),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: <Widget>[
                          Icon(
                            _iconForEntry(entry),
                            size: 48,
                            color: _iconColorForEntry(entry),
                          ),
                          const SizedBox(height: 6),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: Text(
                              entry.name,
                              style: TextStyle(
                                color: active
                                    ? Colors.white
                                    : const Color(0xFFCDD5DF),
                                fontSize: 12,
                                fontWeight: FontWeight.w400,
                              ),
                              textAlign: TextAlign.center,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        );
        },
      );
    }

  Widget _headerButton(IconData icon, String label, VoidCallback? onTap,
      {bool danger = false}) {
    return OutlinedButton.icon(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        foregroundColor:
            danger ? const Color(0xFFF85149) : const Color(0xFFCDD5DF),
        side: BorderSide(
            color: danger ? const Color(0xFF7F1D1D) : const Color(0xFF30363D)),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        backgroundColor: const Color(0xFF0D1117),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_controlRadius),
        ),
      ),
      icon: Icon(icon, size: 15),
      label: Text(label, style: const TextStyle(fontSize: _bodyFontSize)),
    );
  }

  Widget _buildSettingsMenu() {
    return InkWell(
      onTap: _isInteractionLocked ? null : _showSettingsPanel,
      borderRadius: BorderRadius.circular(_controlRadius),
      child: Container(
        key: _settingsMenuKey,
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          border: Border.all(
            color: _isInteractionLocked
                ? const Color(0xFF21262D)
                : const Color(0xFF30363D),
          ),
          borderRadius: BorderRadius.circular(_controlRadius),
          color: _isInteractionLocked
              ? const Color(0xFF10151B)
              : const Color(0xFF0D1117),
        ),
        child: Icon(
          Icons.more_horiz,
          size: 18,
          color: _isInteractionLocked
              ? const Color(0xFF5A6673)
              : const Color(0xFF8B949E),
        ),
      ),
    );
  }

  Widget _buildBusyContentOverlay() {
    final bool animated = _toolbarBusyLabel != '本地读取中';
    return AbsorbPointer(
      child: Container(
        color: const Color(0xFF081018).withValues(alpha: 0.42),
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _BusyPill(
              key: const ValueKey('busy-pill'),
              label: _toolbarBusyLabel ?? '处理中',
              subtitle: _toolbarBusySubtitle(),
              compact: false,
              animated: animated,
            ),
            const SizedBox(height: 14),
            const Text(
              '文件列表与右键菜单已暂时锁定',
              style: TextStyle(
                color: Color(0xFF9BA7B4),
                fontSize: _bodyFontSize,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showSettingsPanel() async {
    const double panelWidth = 320;
    const double panelGap = 8;
    const double screenPadding = 10;
    final RenderObject? renderObject =
        _settingsMenuKey.currentContext?.findRenderObject();
    final RenderBox? buttonBox =
        renderObject is RenderBox ? renderObject : null;
    final Size screen = MediaQuery.sizeOf(context);
    final Offset buttonOffset =
        buttonBox?.localToGlobal(Offset.zero) ??
            Offset(screen.width - panelWidth - screenPadding, 56);
    final Size buttonSize = buttonBox?.size ?? const Size(34, 34);
    double left = buttonOffset.dx + buttonSize.width - panelWidth;
    double top = buttonOffset.dy + buttonSize.height + panelGap;
    if (left < screenPadding) {
      left = screenPadding;
    }
    if (left + panelWidth > screen.width - screenPadding) {
      left = screen.width - panelWidth - screenPadding;
    }
    if (top < screenPadding) {
      top = screenPadding;
    }

    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.45),
      barrierDismissible: true,
      builder: (BuildContext dialogContext) {
        return StatefulBuilder(
          builder: (BuildContext context,
              void Function(void Function()) setModalState) {
            void updatePanel(void Function() action) {
              setModalState(action);
              setState(() {});
            }

            return Stack(
              children: <Widget>[
                Positioned(
                  left: left,
                  top: top,
                  child: SizedBox(
                    width: panelWidth,
                    child: Material(
                      color: Colors.transparent,
                      child: Container(
                        decoration: BoxDecoration(
                          color: AppColors.surface,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: AppColors.border),
                          boxShadow: <BoxShadow>[
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.32),
                              blurRadius: 12,
                              offset: const Offset(0, 6),
                            ),
                          ],
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
                              child: Row(
                                children: <Widget>[
                                  const Expanded(
                                    child: Text(
                                      '文件管理设置',
                                      style: TextStyle(
                                        color: AppColors.textPrimary,
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  IconButton(
                                    onPressed: () =>
                                        Navigator.of(dialogContext).pop(),
                                    icon: const Icon(
                                      Icons.close,
                                      color: AppColors.textMuted,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const Divider(height: 1, color: AppColors.surfaceMuted),
                            Padding(
                              padding: const EdgeInsets.fromLTRB(14, 14, 14, 16),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Row(
                                    children: <Widget>[
                                      if (!_isUploadInProgress)
                                        Expanded(
                                          child: _settingsActionButton(
                                            icon: Icons.upload_file_outlined,
                                            label: '上传',
                                            onTap: () async {
                                              Navigator.of(dialogContext).pop();
                                              await _uploadFile();
                                            },
                                          ),
                                        ),
                                      if (!_isUploadInProgress)
                                        const SizedBox(width: 10),
                                      Expanded(
                                        child: _settingsActionButton(
                                          icon: Icons.note_add_outlined,
                                          label: '新建文件',
                                          onTap: () async {
                                            Navigator.of(dialogContext).pop();
                                            await _createFile();
                                          },
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: _settingsActionButton(
                                          icon: Icons.create_new_folder_outlined,
                                          label: '新建目录',
                                          onTap: () async {
                                            Navigator.of(dialogContext).pop();
                                            await _createDirectory();
                                          },
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 16),
                                  const Divider(color: AppColors.surfaceMuted, height: 1),
                                  const SizedBox(height: 16),
                                  Row(
                                    children: <Widget>[
                                      const Expanded(
                                        child: Text(
                                          '显示隐藏文件',
                                          style: TextStyle(
                                            color: AppColors.textPrimary,
                                            fontSize: _bodyFontSize,
                                          ),
                                        ),
                                      ),
                                      Switch(
                                        value: _showHiddenFiles,
                                        activeThumbColor: AppColors.primary,
                                        activeTrackColor:
                                            AppColors.primary.withValues(alpha: 0.35),
                                        onChanged: (bool value) {
                                          updatePanel(() {
                                            _showHiddenFiles = value;
                                            if (!_showHiddenFiles) {
                                              _selectedPaths = _entries
                                                  .where((entry) =>
                                                      _selectedPaths.contains(entry.path) &&
                                                      !entry.name.startsWith('.'))
                                                  .map((entry) => entry.path)
                                                  .toSet();
                                              if (_selectedEntry != null &&
                                                  _selectedEntry!.name.startsWith('.')) {
                                                _selectedEntry = _selectedPaths.isEmpty
                                                    ? null
                                                    : _entries.firstWhere(
                                                        (entry) => _selectedPaths
                                                            .contains(entry.path),
                                                      );
                                              }
                                            }
                                          });
                                        },
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 12),
                                  const Text(
                                    '显示模式',
                                    style: TextStyle(
                                      color: AppColors.textMuted,
                                      fontSize: _bodyFontSize,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Row(
                                    children: <Widget>[
                                      Expanded(
                                        child: _settingsSegmentButton(
                                          label: '列表',
                                          active: _displayMode == _FileDisplayMode.list,
                                          onTap: () => updatePanel(
                                            () => _displayMode = _FileDisplayMode.list,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: _settingsSegmentButton(
                                          label: '网格',
                                          active: _displayMode == _FileDisplayMode.grid,
                                          onTap: () => updatePanel(
                                            () => _displayMode = _FileDisplayMode.grid,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 14),
                                  const Text(
                                    '排序方式',
                                    style: TextStyle(
                                      color: AppColors.textMuted,
                                      fontSize: _bodyFontSize,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Row(
                                    children: <Widget>[
                                      Expanded(
                                        child: _buildSettingsSelector<_FileSortField>(
                                          value: _sortField,
                                          items: const <_SettingsOption<_FileSortField>>[
                                            _SettingsOption(
                                              value: _FileSortField.name,
                                              label: '名称',
                                            ),
                                            _SettingsOption(
                                              value: _FileSortField.createdAt,
                                              label: '创建日期',
                                            ),
                                            _SettingsOption(
                                              value: _FileSortField.modifiedAt,
                                              label: '修改日期',
                                            ),
                                          ],
                                          onChanged: (_FileSortField? value) {
                                            if (value == null) return;
                                            updatePanel(() => _sortField = value);
                                          },
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: _buildSettingsSelector<bool>(
                                          value: _sortAscending,
                                          items: const <_SettingsOption<bool>>[
                                            _SettingsOption(
                                              value: true,
                                              label: '正序',
                                            ),
                                            _SettingsOption(
                                              value: false,
                                              label: '倒序',
                                            ),
                                          ],
                                          onChanged: (bool? value) {
                                            if (value == null) return;
                                            updatePanel(() => _sortAscending = value);
                                          },
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _settingsActionButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(_panelRadius),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(_panelRadius),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          children: <Widget>[
            Icon(icon, size: 18, color: AppColors.primaryGlow),
            const SizedBox(height: 8),
            Text(
              label,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: _bodyFontSize,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _settingsSegmentButton({
    required String label,
    required bool active,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(_controlRadius),
      child: Container(
        height: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active ? AppColors.primaryFill : AppColors.background,
          borderRadius: BorderRadius.circular(_controlRadius),
          border: Border.all(
            color: active ? AppColors.primary : AppColors.border,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: active ? Colors.white : AppColors.textSecondary,
            fontSize: _bodyFontSize,
            fontWeight: active ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }

  Widget _buildSettingsSelector<T>({
    required T value,
    required List<_SettingsOption<T>> items,
    required ValueChanged<T?> onChanged,
  }) {
    return _SettingsDropdown<T>(
      value: value,
      items: items,
      onChanged: onChanged,
    );
  }

  Widget _iconButton(IconData icon, VoidCallback? onTap, {String? tooltip}) {
    final button = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(_controlRadius),
      child: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(_controlRadius),
          color: onTap == null ? AppColors.surfaceElevated : Colors.transparent,
        ),
        child: Icon(
          icon,
          size: 16,
          color: onTap == null ? AppColors.borderStrong : AppColors.textMuted,
        ),
      ),
    );

    if (tooltip != null) {
      return Tooltip(
        message: tooltip,
        child: button,
      );
    }
    return button;
  }

  String _formatSize(int size) {
    return AppFormat.bytes(size);
  }

  IconData _iconForEntry(_RemoteFileEntry entry) {
    if (entry.isDir) return Icons.folder_outlined;
    if (_isArchiveFileName(entry.name)) return Icons.archive_outlined;
    return _iconForExtension(entry.name);
  }

  static const Map<String, IconData> _extIcons = {
    '.pdf': Icons.picture_as_pdf_outlined,
    '.doc': Icons.article_outlined,
    '.docx': Icons.article_outlined,
    '.xls': Icons.table_chart_outlined,
    '.xlsx': Icons.table_chart_outlined,
    '.csv': Icons.table_chart_outlined,
    '.ppt': Icons.slideshow_outlined,
    '.pptx': Icons.slideshow_outlined,
    '.txt': Icons.notes_outlined,
    '.md': Icons.notes_outlined,
    '.rtf': Icons.article_outlined,
    '.odt': Icons.article_outlined,
    '.ods': Icons.table_chart_outlined,
    '.odp': Icons.slideshow_outlined,
    '.jpg': Icons.image_outlined,
    '.jpeg': Icons.image_outlined,
    '.png': Icons.image_outlined,
    '.gif': Icons.image_outlined,
    '.bmp': Icons.image_outlined,
    '.webp': Icons.image_outlined,
    '.svg': Icons.image_outlined,
    '.ico': Icons.image_outlined,
    '.tiff': Icons.image_outlined,
    '.tif': Icons.image_outlined,
    '.mp4': Icons.movie_outlined,
    '.avi': Icons.movie_outlined,
    '.mkv': Icons.movie_outlined,
    '.mov': Icons.movie_outlined,
    '.wmv': Icons.movie_outlined,
    '.flv': Icons.movie_outlined,
    '.webm': Icons.movie_outlined,
    '.mp3': Icons.music_note_outlined,
    '.wav': Icons.music_note_outlined,
    '.flac': Icons.music_note_outlined,
    '.aac': Icons.music_note_outlined,
    '.ogg': Icons.music_note_outlined,
    '.wma': Icons.music_note_outlined,
    '.m4a': Icons.music_note_outlined,
    '.js': Icons.javascript_outlined,
    '.mjs': Icons.javascript_outlined,
    '.ts': Icons.javascript_outlined,
    '.jsx': Icons.javascript_outlined,
    '.tsx': Icons.javascript_outlined,
    '.py': Icons.code_outlined,
    '.java': Icons.code_outlined,
    '.c': Icons.code_outlined,
    '.cpp': Icons.code_outlined,
    '.h': Icons.code_outlined,
    '.go': Icons.code_outlined,
    '.rs': Icons.code_outlined,
    '.rb': Icons.code_outlined,
    '.php': Icons.code_outlined,
    '.swift': Icons.code_outlined,
    '.kt': Icons.code_outlined,
    '.dart': Icons.code_outlined,
    '.html': Icons.code_outlined,
    '.css': Icons.code_outlined,
    '.scss': Icons.code_outlined,
    '.less': Icons.code_outlined,
    '.sh': Icons.terminal_outlined,
    '.bash': Icons.terminal_outlined,
    '.zsh': Icons.terminal_outlined,
    '.bat': Icons.terminal_outlined,
    '.cmd': Icons.terminal_outlined,
    '.ps1': Icons.terminal_outlined,
    '.json': Icons.data_object_outlined,
    '.xml': Icons.data_object_outlined,
    '.yaml': Icons.data_object_outlined,
    '.yml': Icons.data_object_outlined,
    '.toml': Icons.data_object_outlined,
    '.ini': Icons.data_object_outlined,
    '.sql': Icons.storage_outlined,
    '.db': Icons.storage_outlined,
    '.sqlite': Icons.storage_outlined,
    '.log': Icons.description_outlined,
    '.env': Icons.lock_outlined,
    '.pem': Icons.lock_outlined,
    '.key': Icons.lock_outlined,
    '.crt': Icons.lock_outlined,
    '.cer': Icons.lock_outlined,
    '.exe': Icons.apps_outlined,
    '.msi': Icons.apps_outlined,
    '.dmg': Icons.apps_outlined,
    '.app': Icons.apps_outlined,
    '.deb': Icons.apps_outlined,
    '.rpm': Icons.apps_outlined,
    '.iso': Icons.disc_full_outlined,
    '.img': Icons.disc_full_outlined,
    '.ttf': Icons.font_download_outlined,
    '.otf': Icons.font_download_outlined,
    '.woff': Icons.font_download_outlined,
    '.woff2': Icons.font_download_outlined,
    '.eot': Icons.font_download_outlined,
  };

  static IconData _iconForExtension(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0) return Icons.insert_drive_file_outlined;
    final ext = name.substring(dot).toLowerCase();
    return _extIcons[ext] ?? Icons.insert_drive_file_outlined;
  }

  Color _iconColorForEntry(_RemoteFileEntry entry) {
    if (entry.isDir) return const Color(0xFF58A6FF);
    if (_isArchiveFileName(entry.name)) return const Color(0xFF8B5CF6);
    final dot = entry.name.lastIndexOf('.');
    if (dot < 0) return const Color(0xFF8B949E);
    final ext = entry.name.substring(dot).toLowerCase();
    switch (ext) {
      case '.pdf':
        return const Color(0xFFEF4444);
      case '.doc':
      case '.docx':
      case '.rtf':
      case '.odt':
        return const Color(0xFF3B82F6);
      case '.xls':
      case '.xlsx':
      case '.csv':
      case '.ods':
        return const Color(0xFF22C55E);
      case '.ppt':
      case '.pptx':
      case '.odp':
        return const Color(0xFFF97316);
      case '.jpg':
      case '.jpeg':
      case '.png':
      case '.gif':
      case '.bmp':
      case '.webp':
      case '.svg':
      case '.ico':
      case '.tiff':
      case '.tif':
        return const Color(0xFFEC4899);
      case '.mp4':
      case '.avi':
      case '.mkv':
      case '.mov':
      case '.wmv':
      case '.flv':
      case '.webm':
        return const Color(0xFFF59E0B);
      case '.mp3':
      case '.wav':
      case '.flac':
      case '.aac':
      case '.ogg':
      case '.wma':
      case '.m4a':
        return const Color(0xFF8B5CF6);
      case '.js':
      case '.mjs':
      case '.ts':
      case '.jsx':
      case '.tsx':
        return const Color(0xFFFBBF24);
      case '.py':
        return const Color(0xFF3B82F6);
      case '.dart':
        return const Color(0xFF06B6D4);
      case '.go':
        return const Color(0xFF22D3EE);
      case '.rs':
        return const Color(0xFFF97316);
      case '.java':
      case '.kt':
        return const Color(0xFFEF4444);
      case '.html':
      case '.css':
      case '.scss':
      case '.less':
        return const Color(0xFF6366F1);
      case '.json':
      case '.xml':
      case '.yaml':
      case '.yml':
      case '.toml':
        return const Color(0xFF10B981);
      case '.sh':
      case '.bash':
      case '.zsh':
      case '.bat':
      case '.cmd':
      case '.ps1':
        return const Color(0xFF6B7280);
      case '.sql':
      case '.db':
      case '.sqlite':
        return const Color(0xFF14B8A6);
      case '.ttf':
      case '.otf':
      case '.woff':
      case '.woff2':
      case '.eot':
        return const Color(0xFFF472B6);
      case '.exe':
      case '.msi':
      case '.dmg':
      case '.app':
      case '.deb':
      case '.rpm':
        return const Color(0xFF6B7280);
      case '.iso':
      case '.img':
        return const Color(0xFF78716C);
      case '.env':
      case '.pem':
      case '.key':
      case '.crt':
      case '.cer':
        return const Color(0xFFEF4444);
      default:
        return const Color(0xFF58A6FF);
    }
  }

  bool _isArchiveFileName(String name) {
    final String lower = name.toLowerCase();
    const List<String> extensions = <String>[
      '.tar',
      '.tar.gz',
      '.tgz',
      '.tar.bz2',
      '.tbz2',
      '.tar.xz',
      '.txz',
      '.tar.zst',
      '.tzst',
      '.zip',
      '.7z',
      '.rar',
      '.gz',
      '.bz2',
      '.xz',
      '.zst',
    ];
    return extensions.any(lower.endsWith);
  }

}

class _BusyPill extends StatefulWidget {
  final String label;
  final String? subtitle;
  final bool compact;
  final bool animated;

  const _BusyPill({
    super.key,
    required this.label,
    this.subtitle,
    this.compact = false,
    this.animated = true,
  });

  @override
  State<_BusyPill> createState() => _BusyPillState();
}

class _BusyPillState extends State<_BusyPill>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    if (widget.animated) {
      _controller.repeat();
    }
  }

  @override
  void didUpdateWidget(covariant _BusyPill oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animated == widget.animated) {
      return;
    }
    if (widget.animated) {
      _controller.repeat();
    } else {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final double minHeight = widget.compact ? 34 : 60;
    final double spinnerSize = widget.compact ? 15 : 18;
    final EdgeInsets padding = widget.compact
        ? const EdgeInsets.symmetric(horizontal: 12, vertical: 8)
        : const EdgeInsets.symmetric(horizontal: 16, vertical: 12);

    Widget buildContent(double slide) {
      return Container(
        constraints: BoxConstraints(
          minHeight: minHeight,
          minWidth: widget.compact ? 0 : 280,
          maxWidth: widget.compact ? 188 : 360,
        ),
        padding: padding,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(widget.compact ? 10 : 16),
          border: Border.all(color: const Color(0xFF2A3A4D)),
          gradient: const LinearGradient(
            colors: <Color>[Color(0xFF0D1117), Color(0xFF121A24)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: const Color(0xFF58A6FF).withValues(alpha: 0.10),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(widget.compact ? 10 : 16),
          child: Stack(
            children: <Widget>[
              if (widget.animated)
                Positioned.fill(
                  child: IgnorePointer(
                    child: Align(
                      alignment: Alignment(slide, 0),
                      child: Container(
                        width: widget.compact ? 48 : 76,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: <Color>[
                              Colors.transparent,
                              const Color(0xFF58A6FF).withValues(alpha: 0.16),
                              Colors.transparent,
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              Row(
                children: <Widget>[
                  widget.animated
                      ? Transform.rotate(
                          angle: _controller.value * math.pi * 2,
                          child: CustomPaint(
                            size: Size.square(spinnerSize),
                            painter: const _BusySpinnerPainter(),
                          ),
                        )
                      : Icon(
                          Icons.description_outlined,
                          size: spinnerSize + 2,
                          color: const Color(0xFF79C0FF),
                        ),
                  SizedBox(width: widget.compact ? 8 : 10),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          widget.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: const Color(0xFFE6EDF3),
                            fontSize: widget.compact ? 12 : 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (!widget.compact &&
                            widget.subtitle != null) ...<Widget>[
                          const SizedBox(height: 4),
                          Text(
                            widget.subtitle!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Color(0xFF9BA7B4),
                              fontSize: AppTypography.caption,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    if (!widget.animated) {
      return buildContent(0);
    }

    return AnimatedBuilder(
      animation: _controller,
      builder: (BuildContext context, Widget? child) {
        final double slide = -1.2 + (_controller.value * 2.4);
        return buildContent(slide);
      },
    );
  }
}

class _BusySpinnerPainter extends CustomPainter {
  const _BusySpinnerPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final Offset center = size.center(Offset.zero);
    final double radius = (size.shortestSide / 2) - 1.4;
    final Rect rect = Rect.fromCircle(center: center, radius: radius);
    final Paint basePaint = Paint()
      ..color = const Color(0xFF243244)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round;
    final Paint accentPaint = Paint()
      ..shader = const LinearGradient(
        colors: <Color>[Color(0xFF79C0FF), Color(0xFF58A6FF)],
      ).createShader(rect)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(rect, 0, math.pi * 2, false, basePaint);
    canvas.drawArc(rect, -math.pi / 2, math.pi * 1.35, false, accentPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _RemoteFileEntry {
  final String name;
  final String path;
  final bool isDir;
  final int size;
  final String permissions;
  final String permissionMode;
  final String owner;
  final String group;
  final String createdAt;
  final String modifiedAt;

  const _RemoteFileEntry({
    required this.name,
    required this.path,
    required this.isDir,
    required this.size,
    required this.permissions,
    required this.permissionMode,
    required this.owner,
    required this.group,
    required this.createdAt,
    required this.modifiedAt,
  });

  factory _RemoteFileEntry.fromJson(Map<String, dynamic> json) {
    return _RemoteFileEntry(
      name: json['name']?.toString() ?? '',
      path: json['path']?.toString() ?? '/',
      isDir: json['is_dir'] == true,
      size: (json['size'] as num?)?.toInt() ?? 0,
      permissions: json['permissions']?.toString() ?? '',
      permissionMode: json['permission_mode']?.toString() ?? '',
      owner: json['owner']?.toString() ?? '',
      group: json['group']?.toString() ?? '',
      createdAt: (json['created_at'] ?? json['modified_at'])?.toString() ?? '',
      modifiedAt: json['modified_at']?.toString() ?? '',
    );
  }
}

class _BreadcrumbItem {
  final String label;
  final String path;

  const _BreadcrumbItem(this.label, this.path);
}

enum _FileSortField { name, createdAt, modifiedAt }

enum _FileDisplayMode { list, grid }

enum _ClipboardAction { copy, move }

enum _FileContextAction {
  open,
  edit,
  download,
  archive,
  extract,
  copy,
  move,
  rename,
  properties,
  delete,
}

class _FilePropertiesDialog extends StatefulWidget {
  final _RemoteFileEntry entry;

  const _FilePropertiesDialog({
    required this.entry,
  });

  @override
  State<_FilePropertiesDialog> createState() => _FilePropertiesDialogState();
}

class _ImageFilePreviewDialog extends StatefulWidget {
  final _RemoteFileEntry entry;

  const _ImageFilePreviewDialog({
    required this.entry,
  });

  @override
  State<_ImageFilePreviewDialog> createState() =>
      _ImageFilePreviewDialogState();
}

class _ImageFilePreviewDialogState extends State<_ImageFilePreviewDialog> {
  bool _loading = true;
  String? _error;
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  Future<void> _loadImage() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final ApiService api = context.read<ApiService>();
      final String url = api.filePreviewUrl(
        path: widget.entry.path,
      );
      final http.Response response = await http.get(Uri.parse(url));
      if (response.statusCode != 200) {
        throw Exception('图片加载失败 (${response.statusCode})');
      }
      if (!mounted) return;
      setState(() {
        _bytes = response.bodyBytes;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString().replaceFirst('Exception: ', '');
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      backgroundColor: const Color(0xFF161B22),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1120, maxHeight: 820),
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 12, 18),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          widget.entry.name,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: AppTypography.section,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '${widget.entry.path} · ${AppFormat.bytes(widget.entry.size)}${widget.entry.modifiedAt.isNotEmpty ? ' · 修改于 ${widget.entry.modifiedAt}' : ''}',
                          style: const TextStyle(
                            color: Color(0xFF8B949E),
                            fontSize: AppTypography.bodyS,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: '刷新图片',
                    onPressed: _loading ? null : _loadImage,
                    icon: const Icon(Icons.refresh, color: Color(0xFF9BA7B4)),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, color: Color(0xFF9BA7B4)),
                  ),
                ],
              ),
            ),
            const Divider(color: Color(0xFF263244), height: 1),
            Expanded(
              child: Container(
                width: double.infinity,
                color: const Color(0xFF0D1117),
                child: _loading
                    ? const Center(
                        child: CircularProgressIndicator(
                          color: Color(0xFF58A6FF),
                        ),
                      )
                    : _error != null
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Text(
                                _error!,
                                style: const TextStyle(
                                  color: Color(0xFFC93C37),
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ),
                          )
                        : InteractiveViewer(
                            minScale: 0.2,
                            maxScale: 8,
                            child: Center(
                              child: Image.memory(
                                _bytes!,
                                fit: BoxFit.contain,
                                filterQuality: FilterQuality.high,
                                errorBuilder: (
                                  BuildContext context,
                                  Object error,
                                  StackTrace? stackTrace,
                                ) {
                                  return const Padding(
                                    padding: EdgeInsets.all(24),
                                    child: Text(
                                      '图片解码失败，可能格式不受支持。',
                                      style: TextStyle(
                                        color: Color(0xFFC93C37),
                                      ),
                                      textAlign: TextAlign.center,
                                    ),
                                  );
                                },
                              ),
                            ),
                          ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TextFileEditorDialog extends StatefulWidget {
  final String path;
  final String name;

  const _TextFileEditorDialog({
    required this.path,
    required this.name,
  });

  @override
  State<_TextFileEditorDialog> createState() => _TextFileEditorDialogState();
}

class _TextFileEditorDialogState extends State<_TextFileEditorDialog> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  bool _loading = true;
  bool _saving = false;
  bool _truncated = false;
  bool _dirty = false;
  String? _error;
  String _modifiedAt = '';
  int _size = 0;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_handleChanged);
    _load();
  }

  @override
  void dispose() {
    _controller.removeListener(_handleChanged);
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _handleChanged() {
    if (!_loading && mounted && !_dirty) {
      setState(() => _dirty = true);
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _dirty = false;
    });
    try {
      final Map<String, dynamic> data =
          await context.read<ApiService>().getFileContent(
                path: widget.path,
              );
      if (!mounted) return;
      _controller.text = (data['content'] ?? '').toString();
      _controller.selection =
          TextSelection.collapsed(offset: _controller.text.length);
      setState(() {
        _size = (data['size'] as num?)?.toInt() ?? 0;
        _modifiedAt = (data['modified_at'] ?? '').toString();
        _truncated = data['truncated'] == true;
        _loading = false;
        _dirty = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await context.read<ApiService>().updateFileContent(
            path: widget.path,
            content: _controller.text,
          );
      if (!mounted) return;
      AppToast.show(context, '文件已保存', type: AppToastType.success);
      setState(() => _dirty = false);
      await _load();
    } catch (error) {
      if (!mounted) return;
      AppToast.show(
        context,
        error.toString().replaceFirst('Exception: ', ''),
        type: AppToastType.error,
      );
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  String _formatSize(int size) {
    return AppFormat.bytes(size);
  }

  Widget _buildEditorContextMenu(
    BuildContext context,
    EditableTextState editableTextState,
  ) {
    final List<ContextMenuButtonItem> buttonItems =
        editableTextState.contextMenuButtonItems;
    final List<_EditorContextAction> actions = <_EditorContextAction>[];

    for (final ContextMenuButtonItem item in buttonItems) {
      final String? label = switch (item.type) {
        ContextMenuButtonType.cut => '剪切',
        ContextMenuButtonType.copy => '复制',
        ContextMenuButtonType.delete => '删除',
        ContextMenuButtonType.paste => '粘贴',
        ContextMenuButtonType.selectAll => '全选',
        ContextMenuButtonType.lookUp => '查询',
        ContextMenuButtonType.searchWeb => '网页搜索',
        ContextMenuButtonType.share => '分享',
        ContextMenuButtonType.liveTextInput => '实时文本输入',
        ContextMenuButtonType.custom => item.label,
      };
      if (label == null || label.trim().isEmpty || item.onPressed == null) {
        continue;
      }
      actions.add(
        _EditorContextAction(
          label: label,
          onPressed: () {
            item.onPressed!();
            editableTextState.hideToolbar();
          },
        ),
      );
    }

    if (actions.isEmpty) {
      return const SizedBox.shrink();
    }

    final TextSelectionToolbarAnchors anchors =
        editableTextState.contextMenuAnchors;
    final Offset anchor = anchors.primaryAnchor;

    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: editableTextState.hideToolbar,
          ),
        ),
        Positioned(
          left: anchor.dx.clamp(12.0, MediaQuery.sizeOf(context).width - 196),
          top: anchor.dy.clamp(12.0, MediaQuery.sizeOf(context).height - 220),
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: 184,
              padding: const EdgeInsets.symmetric(vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFF161B22),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFF30363D)),
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.32),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: actions.map((action) {
                  return InkWell(
                    onTap: action.onPressed,
                    child: Container(
                      height: 36,
                      alignment: Alignment.centerLeft,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text(
                        action.label,
                        style: const TextStyle(
                          color: Color(0xFFCDD5DF),
                          fontSize: _bodyFontSize,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      backgroundColor: const Color(0xFF161B22),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1100, maxHeight: 820),
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 12, 18),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          widget.name,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: AppTypography.section,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '${widget.path} · ${_formatSize(_size)}${_modifiedAt.isNotEmpty ? ' · 修改于 $_modifiedAt' : ''}',
                          style: const TextStyle(
                            color: Color(0xFF8B949E),
                            fontSize: AppTypography.bodyS,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  ElevatedButton(
                    onPressed: _loading || _saving || !_dirty || _truncated
                        ? null
                        : _save,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1F6FEB),
                    ),
                    child: Text(
                      _saving ? '保存中...' : '保存',
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, color: Color(0xFF9BA7B4)),
                  ),
                ],
              ),
            ),
            const Divider(color: Color(0xFF263244), height: 1),
            if (_truncated)
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                color: const Color(0xFF2D1F0A),
                child: const Text(
                  '当前只预览了文件前 128 KB，截断内容不允许直接保存。请先缩小文件或通过终端处理大文件。',
                  style: TextStyle(
                    color: Color(0xFFF2CC60),
                    fontSize: AppTypography.bodyS,
                  ),
                ),
              ),
            Expanded(
              child: _loading
                  ? const Center(
                      child:
                          CircularProgressIndicator(color: Color(0xFF58A6FF)),
                    )
                  : _error != null
                      ? Center(
                          child: Text(
                            _error!,
                            style: const TextStyle(color: Color(0xFFC93C37)),
                          ),
                        )
                      : Padding(
                          padding: const EdgeInsets.all(18),
                          child: Container(
                            decoration: BoxDecoration(
                              color: const Color(0xFF0D1117),
                              borderRadius: BorderRadius.circular(12),
                              border:
                                  Border.all(color: const Color(0xFF263244)),
                            ),
                            child: ScrollConfiguration(
                              behavior: const MaterialScrollBehavior().copyWith(
                                scrollbars: false,
                              ),
                              child: TextField(
                                controller: _controller,
                                scrollController: _scrollController,
                                contextMenuBuilder: _buildEditorContextMenu,
                                expands: true,
                                maxLines: null,
                                minLines: null,
                                textAlignVertical: TextAlignVertical.top,
                                readOnly: _truncated,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: AppTypography.bodyM,
                                  height: 1.5,
                                  fontFamily: AppTerminalTypography.monoFamily,
                                  fontFamilyFallback:
                                      AppTerminalTypography.monoFallback,
                                ),
                                decoration: const InputDecoration(
                                  border: InputBorder.none,
                                  contentPadding: EdgeInsets.all(16),
                                ),
                              ),
                            ),
                          ),
                        ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PdfFilePreviewDialog extends StatefulWidget {
  final _RemoteFileEntry entry;

  const _PdfFilePreviewDialog({
    required this.entry,
  });

  @override
  State<_PdfFilePreviewDialog> createState() => _PdfFilePreviewDialogState();
}

class _PdfFilePreviewDialogState extends State<_PdfFilePreviewDialog> {
  String? _downloadUrl;
  String? _objectUrl;
  String? _viewType;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _preparePdfPreview();
  }

  void _preparePdfPreview() {
    if (!kIsWeb) {
      _error = '当前运行环境暂不支持内嵌 PDF 预览，请使用下载功能查看。';
      _loading = false;
      return;
    }

    _loadPdfContent();
  }

  Future<void> _loadPdfContent() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final ApiService api = context.read<ApiService>();
      final String previewUrl = api.filePreviewUrl(
        path: widget.entry.path,
      );
      final String downloadUrl = api.filesDownloadUrl(
        paths: <String>[widget.entry.path],
      );
      final http.Response response = await http.get(Uri.parse(previewUrl));
      if (response.statusCode != 200) {
        throw Exception('PDF 加载失败 (${response.statusCode})');
      }

      _revokeObjectUrl();
      final web.Blob blob =
          web.Blob(<JSObject>[response.bodyBytes.toJS as JSObject].jsify() as JSArray<JSObject>);
      final String objectUrl = web.URL.createObjectURL(blob);
      final String viewType =
          'pdf-preview-${DateTime.now().microsecondsSinceEpoch}';
      ui_web.platformViewRegistry.registerViewFactory(viewType, (int viewId) {
        return web.HTMLIFrameElement()
          ..src = objectUrl
          ..style.border = '0'
          ..style.width = '100%'
          ..style.height = '100%'
          ..style.backgroundColor = '#0D1117';
      });

      if (!mounted) {
        web.URL.revokeObjectURL(objectUrl);
        return;
      }
      setState(() {
        _objectUrl = objectUrl;
        _downloadUrl = downloadUrl;
        _viewType = viewType;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString().replaceFirst('Exception: ', '');
        _loading = false;
      });
    }
  }

  void _revokeObjectUrl() {
    if (_objectUrl == null || _objectUrl!.isEmpty) {
      return;
    }
    web.URL.revokeObjectURL(_objectUrl!);
    _objectUrl = null;
  }

  @override
  void dispose() {
    _revokeObjectUrl();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      backgroundColor: const Color(0xFF161B22),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1120, maxHeight: 820),
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 12, 18),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          widget.entry.name,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: AppTypography.section,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '${widget.entry.path} · ${AppFormat.bytes(widget.entry.size)}${widget.entry.modifiedAt.isNotEmpty ? ' · 修改于 ${widget.entry.modifiedAt}' : ''}',
                          style: const TextStyle(
                            color: Color(0xFF8B949E),
                            fontSize: AppTypography.bodyS,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, color: Color(0xFF9BA7B4)),
                  ),
                ],
              ),
            ),
            const Divider(color: Color(0xFF263244), height: 1),
            Expanded(
              child: Container(
                width: double.infinity,
                color: const Color(0xFF0D1117),
                child: _error != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            _error!,
                            style: const TextStyle(color: Color(0xFFC93C37)),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      )
                    : _loading || _viewType == null
                        ? const Center(
                            child: CircularProgressIndicator(
                              color: Color(0xFF58A6FF),
                            ),
                          )
                        : Stack(
                            children: <Widget>[
                              Positioned.fill(
                                child: HtmlElementView(viewType: _viewType!),
                              ),
                              Positioned(
                                right: 12,
                                bottom: 12,
                                child: FilledButton.icon(
                                  onPressed: _downloadUrl == null
                                      ? null
                                      : () =>
                                          launchFileDownload(_downloadUrl!),
                                  icon: const Icon(Icons.download_outlined),
                                  label: const Text('下载'),
                                ),
                              ),
                            ],
                          ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FilePropertiesDialogState extends State<_FilePropertiesDialog> {
  late _RemoteFileProperties _properties;
  bool _loading = false;
  bool _calculatingSize = false;

  @override
  void initState() {
    super.initState();
    _properties = _RemoteFileProperties.fromEntry(widget.entry);
    _refreshProperties();
  }

  Future<void> _refreshProperties({bool calculateSize = false}) async {
    setState(() {
      _loading = !calculateSize;
      _calculatingSize = calculateSize;
    });
    try {
      final Map<String, dynamic> data =
          await context.read<ApiService>().getFileProperties(
                path: widget.entry.path,
                calculateSize: calculateSize,
              );
      if (!mounted) return;
      setState(() {
        _properties = _RemoteFileProperties.fromJson(data);
      });
    } catch (error) {
      if (!mounted) return;
      AppToast.show(
        context,
        error.toString().replaceFirst('Exception: ', ''),
        type: AppToastType.error,
      );
    } finally {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _calculatingSize = false;
      });
    }
  }

  Future<void> _copyPath() async {
    await Clipboard.setData(ClipboardData(text: _properties.path));
    if (!mounted) return;
    AppToast.show(context, '路径已复制');
  }

  String _formatSize(int size) {
    return AppFormat.bytes(size);
  }

  Widget _buildRow({
    required String label,
    required Widget value,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: const TextStyle(
                color: Color(0xFF8B949E),
                fontSize: AppTypography.bodyS,
              ),
            ),
          ),
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: value,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final String permissions = _properties.permissionMode.isNotEmpty
        ? _properties.permissionMode
        : _properties.permissions;

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      backgroundColor: const Color(0xFF161B22),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 860),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 12, 18),
              child: Row(
                children: <Widget>[
                  const Expanded(
                    child: Text(
                      '文件属性',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: AppTypography.section,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, color: Color(0xFF9BA7B4)),
                  ),
                ],
              ),
            ),
            const Divider(color: Color(0xFF263244), height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 22, 20, 20),
              child: _loading && _properties.path.isEmpty
                  ? const SizedBox(
                      height: 220,
                      child: Center(
                        child: CircularProgressIndicator(
                          color: Color(0xFF58A6FF),
                        ),
                      ),
                    )
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        _buildRow(
                          label: '路径',
                          value: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Flexible(
                                child: Text(
                                  _properties.path,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: AppTypography.bodyS,
                                  ),
                                  textAlign: TextAlign.right,
                                ),
                              ),
                              const SizedBox(width: 14),
                              OutlinedButton(
                                onPressed: _copyPath,
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: const Color(0xFFCDD5DF),
                                  side: const BorderSide(
                                    color: Color(0xFF304055),
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  minimumSize: const Size(76, 40),
                                ),
                                child: const Text('复制'),
                              ),
                            ],
                          ),
                        ),
                        _buildRow(
                          label: '类型',
                          value: Text(
                            _properties.type,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: AppTypography.bodyS,
                            ),
                          ),
                        ),
                        _buildRow(
                          label: '权限',
                          value: Text(
                            permissions.isEmpty ? '-' : permissions,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: AppTypography.bodyS,
                            ),
                          ),
                        ),
                        _buildRow(
                          label: '大小',
                          value: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Text(
                                _properties.isDir
                                    ? (_properties.sizeCalculated
                                        ? _formatSize(_properties.size)
                                        : '-')
                                    : _formatSize(_properties.size),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: AppTypography.bodyS,
                                ),
                              ),
                              if (_properties.isDir) ...<Widget>[
                                const SizedBox(width: 14),
                                OutlinedButton(
                                  onPressed: _calculatingSize
                                      ? null
                                      : () => _refreshProperties(
                                            calculateSize: true,
                                          ),
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: const Color(0xFFCDD5DF),
                                    side: const BorderSide(
                                      color: Color(0xFF304055),
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    minimumSize: const Size(106, 40),
                                  ),
                                  child: Text(
                                    _calculatingSize ? '计算中...' : '计算大小',
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        _buildRow(
                          label: '修改时间',
                          value: Text(
                            _properties.modifiedAt.isEmpty
                                ? '-'
                                : _properties.modifiedAt,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: AppTypography.bodyS,
                            ),
                          ),
                        ),
                        _buildRow(
                          label: '添加时间',
                          value: Text(
                            _properties.createdAt.isEmpty
                                ? '-'
                                : _properties.createdAt,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: AppTypography.bodyS,
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RemoteFileProperties {
  final String path;
  final String type;
  final String permissions;
  final String permissionMode;
  final String owner;
  final String group;
  final int size;
  final bool sizeCalculated;
  final String modifiedAt;
  final String createdAt;

  const _RemoteFileProperties({
    required this.path,
    required this.type,
    required this.permissions,
    required this.permissionMode,
    required this.owner,
    required this.group,
    required this.size,
    required this.sizeCalculated,
    required this.modifiedAt,
    required this.createdAt,
  });

  bool get isDir => type == 'dir';

  factory _RemoteFileProperties.fromEntry(_RemoteFileEntry entry) {
    return _RemoteFileProperties(
      path: entry.path,
      type: entry.isDir ? 'dir' : 'file',
      permissions: entry.permissions,
      permissionMode: entry.permissionMode,
      owner: entry.owner,
      group: entry.group,
      size: entry.size,
      sizeCalculated: !entry.isDir,
      modifiedAt: entry.modifiedAt,
      createdAt: entry.createdAt,
    );
  }

  factory _RemoteFileProperties.fromJson(Map<String, dynamic> json) {
    return _RemoteFileProperties(
      path: json['path']?.toString() ?? '',
      type: json['type']?.toString() ?? 'file',
      permissions: json['permissions']?.toString() ?? '',
      permissionMode: json['permission_mode']?.toString() ?? '',
      owner: json['owner']?.toString() ?? '',
      group: json['group']?.toString() ?? '',
      size: (json['size'] as num?)?.toInt() ?? 0,
      sizeCalculated: json['size_calculated'] == true,
      modifiedAt: json['modified_at']?.toString() ?? '',
      createdAt: json['created_at']?.toString() ?? '',
    );
  }
}

enum _BlankContextAction { paste, upload, newFile, newDirectory, refresh }

class _ActivateFileManagerSearchIntent extends Intent {
  const _ActivateFileManagerSearchIntent();
}

class _ContextMenuOption<T> {
  final T? value;
  final String? label;
  final bool danger;
  final bool isDivider;

  const _ContextMenuOption({
    required this.value,
    required this.label,
    this.danger = false,
  }) : isDivider = false;

  const _ContextMenuOption.divider()
      : value = null,
        label = null,
        danger = false,
        isDivider = true;
}

class _ContextMenuActionItem<T> extends StatefulWidget {
  final _ContextMenuOption<T> option;
  final double height;
  final VoidCallback onTap;

  const _ContextMenuActionItem({
    required this.option,
    required this.height,
    required this.onTap,
  });

  @override
  State<_ContextMenuActionItem<T>> createState() =>
      _ContextMenuActionItemState<T>();
}

class _ContextMenuActionItemState<T> extends State<_ContextMenuActionItem<T>> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) {
        if (!_hovered) setState(() => _hovered = true);
      },
      onExit: (_) {
        if (_hovered) setState(() => _hovered = false);
      },
      child: InkWell(
        onTap: widget.onTap,
        hoverColor: Colors.transparent,
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
        child: Container(
          height: widget.height,
          alignment: Alignment.centerLeft,
          margin: const EdgeInsets.symmetric(horizontal: 4),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: _hovered ? const Color(0xFF21262D) : Colors.transparent,
            borderRadius: BorderRadius.circular(_controlRadius),
            border: Border.all(
              color: _hovered ? const Color(0xFF30363D) : Colors.transparent,
            ),
          ),
          child: Text(
            widget.option.label ?? '',
            style: const TextStyle(
              color: Color(0xFFCDD5DF),
              fontSize: _bodyFontSize,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

class _SettingsOption<T> {
  final T value;
  final String label;

  const _SettingsOption({
    required this.value,
    required this.label,
  });
}

class _EditorContextAction {
  final String label;
  final VoidCallback onPressed;

  const _EditorContextAction({
    required this.label,
    required this.onPressed,
  });
}

class _SettingsDropdown<T> extends StatefulWidget {
  final T value;
  final List<_SettingsOption<T>> items;
  final ValueChanged<T?> onChanged;

  const _SettingsDropdown({
    required this.value,
    required this.items,
    required this.onChanged,
  });

  @override
  State<_SettingsDropdown<T>> createState() => _SettingsDropdownState<T>();
}

class _SettingsDropdownState<T> extends State<_SettingsDropdown<T>> {
  final GlobalKey _triggerKey = GlobalKey();
  OverlayEntry? _overlay;

  void _toggle() {
    if (_overlay != null) {
      _close();
      return;
    }

    final RenderBox? box =
        _triggerKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;

    final Offset position = box.localToGlobal(Offset.zero);
    _overlay = OverlayEntry(
      builder: (BuildContext context) => _buildOverlay(position, box.size),
    );
    Overlay.of(context).insert(_overlay!);
    setState(() {});
  }

  void _close() {
    _overlay?.remove();
    _overlay = null;
    if (mounted) {
      setState(() {});
    }
  }

  Widget _buildOverlay(Offset position, Size triggerSize) {
    final double maxHeight =
        (widget.items.length * 38.0 + 8.0).clamp(84.0, 220.0);

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: _close,
      child: Stack(
        children: <Widget>[
          Positioned(
            left: position.dx,
            top: position.dy + triggerSize.height + 4,
            width: triggerSize.width,
            child: Material(
              color: Colors.transparent,
              child: Container(
                constraints: BoxConstraints(maxHeight: maxHeight),
                decoration: BoxDecoration(
                  color: const Color(0xFF161B22),
                  borderRadius: BorderRadius.circular(_controlRadius),
                  border: Border.all(color: const Color(0xFF30363D)),
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.32),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: ListView(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  shrinkWrap: true,
                  children: widget.items.map((_SettingsOption<T> option) {
                    final bool isSelected = option.value == widget.value;
                    return InkWell(
                      onTap: () {
                        _close();
                        widget.onChanged(option.value);
                      },
                      child: Container(
                        height: 36,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        color: isSelected
                            ? const Color(0xFF21262D)
                            : Colors.transparent,
                        child: Row(
                          children: <Widget>[
                            Expanded(
                              child: Text(
                                option.label,
                                style: TextStyle(
                                  color: isSelected
                                      ? Colors.white
                                      : const Color(0xFFCDD5DF),
                                  fontSize: _bodyFontSize,
                                  fontWeight: isSelected
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (isSelected)
                              const Icon(
                                Icons.check,
                                size: 14,
                                color: Color(0xFF58A6FF),
                              ),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final _SettingsOption<T> selected = widget.items.firstWhere(
      (_SettingsOption<T> option) => option.value == widget.value,
    );

    return GestureDetector(
      key: _triggerKey,
      onTap: _toggle,
      child: Container(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: const Color(0xFF0D1117),
          borderRadius: BorderRadius.circular(_controlRadius),
          border: Border.all(
            color: _overlay != null
                ? const Color(0xFF58A6FF)
                : const Color(0xFF30363D),
          ),
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                selected.label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: _bodyFontSize,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              _overlay == null ? Icons.expand_more : Icons.expand_less,
              size: 18,
              color: const Color(0xFF8B949E),
            ),
          ],
        ),
      ),
    );
  }
}
