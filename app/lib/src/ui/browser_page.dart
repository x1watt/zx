// The main window: menu bar, toolbar, path bar, folder tree, file list,
// preview and status bar, and every action on the open archive. The
// archive work runs in the background isolates of ZxArchive; this file
// only asks the questions and shows the results.

import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:zx/zx.dart';

import '../archive_model.dart';
import '../dialogs/add_dialogs.dart';
import '../dialogs/common_dialogs.dart';
import '../dialogs/extract_dialog.dart';
import '../dialogs/progress.dart';
import '../dialogs/properties_dialog.dart';
import '../formats.dart';
import '../services.dart';
import 'file_list.dart';
import 'format_utils.dart';
import 'panels.dart';
import 'preview_pane.dart';
import 'settings_page.dart';

Widget _withTooltip(String? message, Widget child) =>
    message == null ? child : Tooltip(message: message, child: child);

class BrowserPage extends StatefulWidget {
  final AppServices services;

  /// An archive to open at start (command line).
  final String? initialArchive;

  const BrowserPage({super.key, required this.services, this.initialArchive});

  @override
  State<BrowserPage> createState() => BrowserPageState();
}

class BrowserPageState extends State<BrowserPage> {
  ArchiveModel? _model;
  final _listFocus = FocusNode(debugLabel: 'file list');
  final _filterFocus = FocusNode(debugLabel: 'filter');
  final _filter = TextEditingController();
  bool _dragging = false;
  bool _busy = false;
  double _treeWidth = 230;
  double _previewWidth = 300;

  AppServices get _s => widget.services;

  /// The open archive (for tests).
  ArchiveModel? get model => _model;

  @override
  void initState() {
    super.initState();
    final a = widget.initialArchive;
    if (a != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => openArchive(a));
    }
    if (Platform.isMacOS) _listenToFinder();
  }

  /// macOS: Finder sends the archives to open as Apple events, which the
  /// runner passes on through the "zx/files" channel.
  Future<void> _listenToFinder() async {
    const channel = MethodChannel('zx/files');
    channel.setMethodCallHandler((call) async {
      final files = call.arguments;
      if (call.method == 'open' && files is List && files.isNotEmpty) {
        await openArchive('${files.first}');
      }
      return null;
    });
    try {
      final pending = await channel.invokeListMethod<String>('pending');
      if (pending != null && pending.isNotEmpty) {
        await openArchive(pending.first);
      }
    } on MissingPluginException {
      // an older runner
    }
  }

  @override
  void dispose() {
    _model?.removeListener(_syncFilter);
    _listFocus.dispose();
    _filterFocus.dispose();
    _filter.dispose();
    super.dispose();
  }

  void _syncFilter() {
    final m = _model;
    if (m != null && _filter.text != m.filter) _filter.text = m.filter;
  }

  void _setModel(ArchiveModel? m) {
    _model?.removeListener(_syncFilter);
    _model = m;
    m?.addListener(_syncFilter);
    _filter.text = '';
    _setWindowTitle(m == null ? 'zx' : '${p.basename(m.archive.path)} - zx');
  }

  /// Shows the archive name in the title bar (the Linux runner handles the
  /// "zx/window" channel; elsewhere the call is ignored).
  static Future<void> _setWindowTitle(String title) async {
    try {
      await const MethodChannel('zx/window').invokeMethod('setTitle', title);
    } on MissingPluginException {
      // no runner support on this platform
    } on PlatformException {
      // ignore
    }
  }

  // ---- common helpers ----

  Future<String?> _askPassword(ZxPasswordRequest r) async {
    if (!mounted) return null;
    return showPasswordDialog(context, r);
  }

  Future<ZxOverwriteAnswer> _askOverwrite(ZxOverwriteRequest r) async {
    if (!mounted) return ZxOverwriteAnswer.cancel;
    return showOverwriteDialog(context, r);
  }

  void _snack(String text, {SnackBarAction? action}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(text),
          action: action,
          behavior: SnackBarBehavior.floating,
          width: 520,
          duration: const Duration(seconds: 4),
        ),
      );
  }

  /// Runs [f]; a cancel shows a short note, other errors a dialog.
  Future<T?> _guard<T>(String what, Future<T> Function() f) async {
    if (_busy) return null;
    setState(() => _busy = true);
    try {
      return await f();
    } on SevenZipException catch (e) {
      if (e.kind == SevenZipError.cancelled) {
        _snack('$what: cancelled');
      } else if (mounted) {
        await showErrorDialog(context, title: what, message: errorText(e));
      }
    } on FileSystemException catch (e) {
      if (mounted) {
        await showErrorDialog(context, title: what, message: errorText(e));
      }
    } on ArgumentError catch (e) {
      if (mounted) {
        await showErrorDialog(context, title: what, message: '${e.message}');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    return null;
  }

  // ---- open, new, close ----

  Future<void> openArchive(String path) async {
    final full = p.absolute(path);
    if (!await File(full).exists()) {
      _s.settings.removeRecent(full);
      if (mounted) {
        await showErrorDialog(
          context,
          title: 'Open archive',
          message: '$full does not exist.',
        );
      }
      return;
    }
    if (!mounted) return;
    final a = await _guard('Open ${p.basename(full)}', () {
      return runWithProgress(
        context,
        'Opening ${p.basename(full)}',
        (pr) =>
            ZxArchive.open(full, onPassword: _askPassword, cancel: pr.cancel),
      );
    });
    if (a == null || !mounted) return;
    showArchive(a);
  }

  /// Shows [a] (opened or created by the caller).
  void showArchive(ZxArchive a) {
    a.onPassword ??= _askPassword;
    _s.settings.addRecent(a.path);
    setState(() => _setModel(ArchiveModel(a)));
    _listFocus.requestFocus();
  }

  Future<void> _openDialog() async {
    final cur = _model?.archive.path;
    final f = await _s.picker.openArchive(
      initialDirectory: cur == null ? null : p.dirname(cur),
    );
    if (f != null) await openArchive(f);
  }

  void closeArchive() => setState(() => _setModel(null));

  Future<void> newArchive({List<String> sources = const []}) async {
    final folder = sources.isNotEmpty
        ? p.dirname(sources.first)
        : _model != null
        ? p.dirname(_model!.archive.path)
        : _s.paths.home;
    final folders = await foldersOf(sources);
    if (!mounted) return;
    final r = await showNewArchiveDialog(
      context,
      folder: folder,
      sources: sources,
      folders: folders,
      formatId: _s.settings.defaultFormat,
      defaultLevel: _s.settings.defaultLevel,
      picker: _s.picker,
    );
    if (r == null || !mounted) return;
    final a = await _guard('New archive', () {
      return runWithProgress(context, 'Creating ${p.basename(r.path)}', (pr) {
        return ZxArchive.create(
          r.path,
          [for (final s in r.sources) ZxSource(s)],
          format: r.format.createFormat,
          options: r.options,
          onPassword: _askPassword,
          onProgress: pr.update,
          cancel: pr.cancel,
        );
      });
    });
    if (a == null || !mounted) return;
    showArchive(a);
    _snack('Created ${p.basename(a.path)}');
  }

  // ---- reasons an action is not available ----

  String? _whyNot(String action) {
    final m = _model;
    if (m == null) return 'Open an archive first';
    final a = m.archive;
    final c = a.capabilities;
    final ok = switch (action) {
      'add' => c.canAdd,
      'delete' => c.canDelete,
      'rename' => c.canRename,
      'folder' => c.canCreateFolder,
      'comment' => c.canSetComment,
      _ => true,
    };
    if (!ok) {
      final fmt = formatDescription(a);
      if (a.volumes.length > 1 || a.outerFormats.contains('Split')) {
        return 'Multi-volume archives can not be changed';
      }
      if (a.format == 'Rar') {
        return 'RAR 4 archives are read only (zx writes RAR5)';
      }
      if (const {'gzip', 'bzip2', 'xz', 'lzma'}.contains(a.format)) {
        return action == 'rename'
            ? 'Only gzip stores the name of its file'
            : 'A ${a.format} file holds exactly one file';
      }
      if (action == 'comment') return '$fmt archives have no comment';
      return '$fmt archives can not be changed here';
    }
    if (action == 'delete' && m.selection.isEmpty) return 'Select items first';
    if (action == 'rename' && m.selection.length != 1) {
      return 'Select one item to rename';
    }
    return null;
  }

  // ---- item actions ----

  Future<void> openItem(ZxItem item) async {
    final m = _model;
    if (m == null) return;
    if (item.isDir) {
      m.navigate(item.path);
      return;
    }
    final tmp = _s.paths.openTempDir;
    final path = await _guard('Open ${item.name}', () async {
      await Directory(tmp).create(recursive: true);
      if (!mounted) return null;
      return runWithProgress(context, 'Opening ${item.name}', (pr) {
        return m.archive.extractToTemp(
          item,
          tempDir: tmp,
          onProgress: pr.update,
          cancel: pr.cancel,
        );
      });
    });
    if (path == null) return;
    try {
      await _s.launcher.openFile(path);
    } on ProcessException catch (e) {
      if (mounted) {
        await showErrorDialog(
          context,
          title: 'Open ${item.name}',
          message: 'No program could open it: ${e.message}',
        );
      }
    }
  }

  void _openSelection() {
    final m = _model;
    if (m == null) return;
    final sel = m.selectedItems;
    if (sel.length == 1) {
      openItem(sel.first);
    } else if (sel.isEmpty && m.cursorIndex >= 0) {
      openItem(m.rows[m.cursorIndex]);
    }
  }

  String _defaultExtractDir(ArchiveModel m) {
    final a = m.archive.path;
    return p.join(p.dirname(a), folderNameFor(a));
  }

  Future<void> extract({bool selectionDefault = true}) async {
    final m = _model;
    if (m == null) return;
    final o = await showExtractDialog(
      context,
      defaultDestination: _defaultExtractDir(m),
      selectedCount: selectionDefault ? m.selection.length : 0,
      openFolderDefault: _s.settings.openFolderAfterExtract,
      picker: _s.picker,
    );
    if (o == null) return;
    _s.settings.openFolderAfterExtract = o.openFolder;
    await _runExtract(
      m,
      dest: o.destination,
      items: o.selectionOnly ? m.selection.toList() : null,
      keepPaths: o.keepPaths,
      overwrite: o.overwrite,
      openFolder: o.openFolder,
    );
  }

  Future<void> extractHere() async {
    final m = _model;
    if (m == null) return;
    await _runExtract(
      m,
      dest: p.dirname(m.archive.path),
      items: m.selection.isEmpty ? null : m.selection.toList(),
      keepPaths: true,
      overwrite: ZxOverwrite.ask,
      openFolder: false,
    );
  }

  Future<void> _runExtract(
    ArchiveModel m, {
    required String dest,
    required List<String>? items,
    required bool keepPaths,
    required ZxOverwrite overwrite,
    required bool openFolder,
  }) async {
    final r = await _guard('Extract', () async {
      await Directory(dest).create(recursive: true);
      if (!mounted) return null;
      return runWithProgress(
        context,
        'Extracting ${p.basename(m.archive.path)}',
        (pr) {
          return m.archive.extract(
            dest,
            items: items,
            keepPaths: keepPaths,
            relativeTo: items != null && m.dir.isNotEmpty ? m.dir : null,
            overwrite: overwrite,
            onOverwrite: overwrite == ZxOverwrite.ask ? _askOverwrite : null,
            onProgress: pr.update,
            cancel: pr.cancel,
          );
        },
      );
    });
    if (r == null || !mounted) return;
    if (!r.ok) {
      await showExtractResultDialog(
        context,
        title: 'Extracted with errors',
        result: r,
      );
      return;
    }
    if (openFolder) await _s.launcher.openFolder(dest);
    _snack(
      'Extracted ${r.files} file${r.files == 1 ? '' : 's'}'
      '${r.skipped > 0 ? ' (${r.skipped} skipped)' : ''} to $dest',
      action: openFolder
          ? null
          : SnackBarAction(
              label: 'Open folder',
              onPressed: () => _s.launcher.openFolder(dest),
            ),
    );
  }

  Future<void> test() async {
    final m = _model;
    if (m == null) return;
    final r = await _guard('Test', () {
      return runWithProgress(
        context,
        'Testing ${p.basename(m.archive.path)}',
        (pr) => m.archive.test(onProgress: pr.update, cancel: pr.cancel),
      );
    });
    if (r == null || !mounted) return;
    await showExtractResultDialog(
      context,
      title: 'Test of ${p.basename(m.archive.path)}',
      result: r,
      test: true,
    );
  }

  Future<void> add({List<String> sources = const []}) async {
    final m = _model;
    if (m == null || _whyNot('add') != null) return;
    final fmt =
        formatForArchive(m.archive.format, m.archive.outerFormats) ??
        newFormatById('7z');
    final folders = await foldersOf(sources);
    if (!mounted) return;
    final r = await showAddDialog(
      context,
      sources: sources,
      folders: folders,
      archiveName: p.basename(m.archive.path),
      destination: m.dir,
      format: fmt,
      caps: m.archive.capabilities,
      defaultLevel: _s.settings.defaultLevel,
      picker: _s.picker,
    );
    if (r == null || !mounted) return;
    final res = await _guard('Add', () {
      return runWithProgress(
        context,
        'Adding to ${p.basename(m.archive.path)}',
        (pr) {
          return m.archive.add(
            [for (final s in r.sources) ZxSource(s)],
            destination: m.dir,
            options: r.options,
            onProgress: pr.update,
            cancel: pr.cancel,
          );
        },
      );
    });
    if (res == null || !mounted) return;
    m.refresh(
      select: [
        for (final s in r.sources)
          m.dir.isEmpty ? p.basename(s) : '${m.dir}/${p.basename(s)}',
      ],
    );
    _snack(
      'Added ${res.added} item${res.added == 1 ? '' : 's'}'
      '${res.skipped.isEmpty ? '' : ', ${res.skipped.length} could not be read'}',
    );
  }

  Future<void> delete() async {
    final m = _model;
    if (m == null || _whyNot('delete') != null) return;
    final sel = m.selectedItems;
    if (_s.settings.confirmDelete) {
      final what = sel.length == 1
          ? '"${sel.first.name}"'
          : '${sel.length} items';
      final ok = await showConfirmDialog(
        context,
        title: 'Delete from the archive',
        message:
            'Delete $what from ${p.basename(m.archive.path)}? '
            'This can not be undone.',
        ok: 'Delete',
        destructive: true,
      );
      if (!ok || !mounted) return;
    }
    final r = await _guard('Delete', () {
      return runWithProgress(
        context,
        'Deleting',
        (pr) => m.archive.delete(
          [for (final i in sel) i.path],
          onProgress: pr.update,
          cancel: pr.cancel,
        ),
      );
    });
    if (r == null) return;
    m.refresh(select: const []);
  }

  Future<void> rename() async {
    final m = _model;
    if (m == null || _whyNot('rename') != null) return;
    final item = m.selectedItems.first;
    final siblings = {for (final r in m.archive.children(m.dir)) r.name};
    final n = await showTextInputDialog(
      context,
      title: 'Rename',
      label: 'New name',
      initial: item.name,
      ok: 'Rename',
      selectStem: !item.isDir,
      validate: (v) => v.contains('/') || v.contains('\\')
          ? 'A name can not contain / or \\'
          : v != item.name && siblings.contains(v)
          ? '"$v" exists already'
          : null,
    );
    if (n == null || n == item.name || !mounted) return;
    final to = m.dir.isEmpty ? n : '${m.dir}/$n';
    final r = await _guard('Rename', () {
      return runWithProgress(
        context,
        'Renaming',
        (pr) => m.archive.rename(
          item.path,
          to,
          onProgress: pr.update,
          cancel: pr.cancel,
        ),
      );
    });
    if (r == null) return;
    m.refresh(select: [to]);
  }

  Future<void> newFolder() async {
    final m = _model;
    if (m == null || _whyNot('folder') != null) return;
    final siblings = {for (final r in m.archive.children(m.dir)) r.name};
    final n = await showTextInputDialog(
      context,
      title: 'New folder',
      label: 'Folder name',
      initial: 'New folder',
      ok: 'Create',
      validate: (v) => v.contains('/') || v.contains('\\')
          ? 'A name can not contain / or \\'
          : siblings.contains(v)
          ? '"$v" exists already'
          : null,
    );
    if (n == null || !mounted) return;
    final path = m.dir.isEmpty ? n : '${m.dir}/$n';
    final r = await _guard('New folder', () {
      return runWithProgress(
        context,
        'Creating the folder',
        (pr) => m.archive.createFolder(path, cancel: pr.cancel),
      );
    });
    if (r == null) return;
    m.refresh(select: [path]);
  }

  Future<void> info() async {
    final m = _model;
    if (m == null) return;
    await showArchiveInfoDialog(
      context,
      m,
      onSaveComment: _whyNot('comment') != null
          ? null
          : (text) async {
              String? err;
              await _guard('Comment', () async {
                try {
                  await m.archive.setComment(text);
                  m.refresh();
                } on SevenZipException catch (e) {
                  err = errorText(e);
                }
              });
              return err;
            },
    );
  }

  Future<void> properties() async {
    final m = _model;
    if (m == null) return;
    final sel = m.selectedItems;
    if (sel.isEmpty) {
      await info();
    } else {
      await showItemPropertiesDialog(context, m, sel);
    }
  }

  void copyPath() {
    final m = _model;
    if (m == null || m.selection.isEmpty) return;
    Clipboard.setData(
      ClipboardData(text: m.selectedItems.map((i) => i.path).join('\n')),
    );
    _snack(
      'Copied ${m.selection.length == 1 ? 'the path' : '${m.selection.length} paths'}',
    );
  }

  Future<void> openSettings() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => SettingsPage(services: _s)));
  }

  // ---- context menu ----

  Future<void> _contextMenu(ZxItem? item, Offset pos) async {
    final m = _model;
    if (m == null) return;
    PopupMenuItem<String> entry(
      String id,
      IconData icon,
      String label, {
      String? why,
      String? shortcut,
    }) {
      return PopupMenuItem<String>(
        key: Key('menu-$id'),
        value: id,
        enabled: why == null,
        height: 36,
        child: _withTooltip(
          why,
          Row(
            children: [
              Icon(icon, size: 18),
              const SizedBox(width: 12),
              Expanded(child: Text(label)),
              if (shortcut != null) const SizedBox(width: 24),
              if (shortcut != null)
                Text(
                  shortcut,
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
      );
    }

    final hasSel = m.selection.isNotEmpty;
    final items = <PopupMenuEntry<String>>[
      if (item != null)
        entry(
          'open',
          item.isDir ? Icons.folder_open_rounded : Icons.open_in_new_rounded,
          item.isDir ? 'Open folder' : 'Open',
          shortcut: 'Enter',
        ),
      if (hasSel) ...[
        entry(
          'extract-to',
          Icons.unarchive_outlined,
          'Extract to...',
          shortcut: 'Ctrl+E',
        ),
        entry(
          'extract-here',
          Icons.drive_folder_upload_outlined,
          'Extract here',
        ),
        entry('copy-path', Icons.content_copy_rounded, 'Copy path'),
        const PopupMenuDivider(),
        entry(
          'rename',
          Icons.drive_file_rename_outline_rounded,
          'Rename',
          why: _whyNot('rename'),
          shortcut: 'F2',
        ),
        entry(
          'delete',
          Icons.delete_outline_rounded,
          'Delete',
          why: _whyNot('delete'),
          shortcut: 'Del',
        ),
        const PopupMenuDivider(),
        entry('properties', Icons.description_outlined, 'Properties'),
      ] else ...[
        entry(
          'add',
          Icons.add_box_outlined,
          'Add files...',
          why: _whyNot('add'),
        ),
        entry(
          'folder',
          Icons.create_new_folder_outlined,
          'New folder',
          why: _whyNot('folder'),
        ),
        entry('extract-to', Icons.unarchive_outlined, 'Extract all...'),
        const PopupMenuDivider(),
        entry('info', Icons.info_outline_rounded, 'Archive info'),
      ],
    ];
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final v = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        pos & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: items,
    );
    switch (v) {
      case 'open':
        if (item != null) await openItem(item);
      case 'extract-to':
        await extract(selectionDefault: hasSel);
      case 'extract-here':
        await extractHere();
      case 'copy-path':
        copyPath();
      case 'rename':
        await rename();
      case 'delete':
        await delete();
      case 'properties':
        await properties();
      case 'add':
        await add();
      case 'folder':
        await newFolder();
      case 'info':
        await info();
    }
  }

  // ---- keyboard ----

  bool get _textFocused {
    final c = FocusManager.instance.primaryFocus?.context;
    return c != null &&
        (c.widget is EditableText ||
            c.findAncestorWidgetOfExactType<EditableText>() != null);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final kb = HardwareKeyboard.instance;
    final ctrl = kb.isControlPressed || kb.isMetaPressed;
    final alt = kb.isAltPressed;
    final k = e.logicalKey;
    final m = _model;
    bool handled = true;
    // global
    if (ctrl && k == LogicalKeyboardKey.keyO) {
      _openDialog();
    } else if (ctrl && k == LogicalKeyboardKey.keyN) {
      newArchive();
    } else if (ctrl && k == LogicalKeyboardKey.keyE && m != null) {
      extract();
    } else if (ctrl && k == LogicalKeyboardKey.keyW && m != null) {
      closeArchive();
    } else if (ctrl && k == LogicalKeyboardKey.keyF && m != null) {
      _filterFocus.requestFocus();
    } else if (ctrl && k == LogicalKeyboardKey.keyQ) {
      exit(0);
    } else if (alt && k == LogicalKeyboardKey.arrowLeft && m != null) {
      m.back();
    } else if (alt && k == LogicalKeyboardKey.arrowRight && m != null) {
      m.forward();
    } else if (alt && k == LogicalKeyboardKey.arrowUp && m != null) {
      m.up();
    } else if (_textFocused || m == null) {
      handled = false;
    } else if (ctrl && k == LogicalKeyboardKey.keyA) {
      m.selectAll();
    } else if (k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.numpadEnter) {
      if (alt) {
        properties();
      } else {
        _openSelection();
      }
    } else if (k == LogicalKeyboardKey.backspace) {
      m.up();
    } else if (k == LogicalKeyboardKey.delete) {
      delete();
    } else if (k == LogicalKeyboardKey.f2) {
      rename();
    } else if (k == LogicalKeyboardKey.arrowDown) {
      m.moveSelection(1, shift: kb.isShiftPressed);
    } else if (k == LogicalKeyboardKey.arrowUp) {
      m.moveSelection(-1, shift: kb.isShiftPressed);
    } else if (k == LogicalKeyboardKey.pageDown) {
      m.moveSelection(20, shift: kb.isShiftPressed);
    } else if (k == LogicalKeyboardKey.pageUp) {
      m.moveSelection(-20, shift: kb.isShiftPressed);
    } else if (k == LogicalKeyboardKey.home) {
      m.moveSelection(-1 << 30, shift: kb.isShiftPressed);
    } else if (k == LogicalKeyboardKey.end) {
      m.moveSelection(1 << 30, shift: kb.isShiftPressed);
    } else if (k == LogicalKeyboardKey.escape) {
      if (m.filter.isNotEmpty) {
        m.filter = '';
      } else {
        m.clearSelection();
      }
    } else {
      handled = false;
    }
    return handled ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  // ---- drag and drop ----

  Future<void> _onDrop(DropDoneDetails d) async {
    setState(() => _dragging = false);
    await handleDrop([for (final f in d.files) f.path]);
  }

  /// Files dropped on the window: with no archive open, an archive opens
  /// and other files start a new archive; with an archive open they are
  /// added to its current folder (or, when it can not change, a dropped
  /// archive opens instead).
  Future<void> handleDrop(List<String> dropped) async {
    final paths = dropped.where((s) => s.isNotEmpty).toList();
    if (paths.isEmpty) return;
    final m = _model;
    if (m == null) {
      if (paths.length == 1 &&
          looksLikeArchive(paths.first) &&
          await FileSystemEntity.isFile(paths.first)) {
        await openArchive(paths.first);
      } else {
        await newArchive(sources: paths);
      }
      return;
    }
    if (_whyNot('add') == null) {
      await add(sources: paths);
    } else if (paths.length == 1 && looksLikeArchive(paths.first)) {
      await openArchive(paths.first);
    } else {
      _snack('Can not add here: ${_whyNot('add')}');
    }
  }

  // ---- layout ----

  List<ToolAction?> _toolActions() {
    final none = _model == null ? 'Open an archive first' : null;
    return [
      ToolAction(
        'open',
        Icons.folder_open_rounded,
        'Open',
        'Open an archive (Ctrl+O)',
        null,
        _openDialog,
      ),
      ToolAction(
        'new',
        Icons.add_circle_outline_rounded,
        'New',
        'Create a new archive (Ctrl+N)',
        null,
        () => newArchive(),
      ),
      null,
      ToolAction(
        'add',
        Icons.add_box_outlined,
        'Add',
        'Add files and folders to the current folder',
        _whyNot('add'),
        () => add(),
      ),
      ToolAction(
        'extract',
        Icons.unarchive_outlined,
        'Extract',
        'Extract files (Ctrl+E)',
        none,
        () => extract(),
      ),
      ToolAction(
        'test',
        Icons.fact_check_outlined,
        'Test',
        'Test the archive for errors',
        none,
        test,
      ),
      null,
      ToolAction(
        'delete',
        Icons.delete_outline_rounded,
        'Delete',
        'Delete the selected items (Del)',
        _whyNot('delete'),
        delete,
      ),
      ToolAction(
        'rename',
        Icons.drive_file_rename_outline_rounded,
        'Rename',
        'Rename the selected item (F2)',
        _whyNot('rename'),
        rename,
      ),
      ToolAction(
        'folder',
        Icons.create_new_folder_outlined,
        'New folder',
        'Create a folder here',
        _whyNot('folder'),
        newFolder,
      ),
      null,
      ToolAction(
        'info',
        Icons.info_outline_rounded,
        'Info',
        'Archive properties and comment',
        none,
        info,
      ),
      ToolAction(
        'settings',
        Icons.settings_outlined,
        'Settings',
        'Settings and desktop integration',
        null,
        openSettings,
      ),
    ];
  }

  Widget _menuBar() {
    final m = _model;
    final st = _s.settings;
    MenuItemButton item(
      String label,
      VoidCallback? onPressed, {
      IconData? icon,
      MenuSerializableShortcut? shortcut,
      String? why,
    }) => MenuItemButton(
      onPressed: why == null ? onPressed : null,
      shortcut: shortcut,
      leadingIcon: icon == null ? null : Icon(icon, size: 18),
      child: Text(label),
    );
    return MenuBar(
      style: const MenuStyle(
        backgroundColor: WidgetStatePropertyAll(Colors.transparent),
        elevation: WidgetStatePropertyAll(0),
        padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 4)),
      ),
      children: [
        SubmenuButton(
          menuChildren: [
            item(
              'Open...',
              _openDialog,
              icon: Icons.folder_open_rounded,
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyO,
                control: true,
              ),
            ),
            item(
              'New archive...',
              () => newArchive(),
              icon: Icons.add_circle_outline_rounded,
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyN,
                control: true,
              ),
            ),
            SubmenuButton(
              leadingIcon: const Icon(Icons.history_rounded, size: 18),
              menuChildren: [
                if (st.recent.isEmpty) item('No recent archives', null),
                for (final r in st.recent) item(r, () => openArchive(r)),
                if (st.recent.isNotEmpty) ...[
                  const Divider(height: 1),
                  item('Clear the list', st.clearRecent),
                ],
              ],
              child: const Text('Recent'),
            ),
            item(
              'Close archive',
              m == null ? null : closeArchive,
              icon: Icons.close_rounded,
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyW,
                control: true,
              ),
            ),
            const Divider(height: 1),
            item(
              'Quit',
              () => exit(0),
              icon: Icons.logout_rounded,
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyQ,
                control: true,
              ),
            ),
          ],
          child: const Text('File'),
        ),
        SubmenuButton(
          menuChildren: [
            item(
              'Select all',
              m?.selectAll,
              icon: Icons.select_all_rounded,
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyA,
                control: true,
              ),
            ),
            item(
              'Copy path',
              m == null || m.selection.isEmpty ? null : copyPath,
              icon: Icons.content_copy_rounded,
            ),
            item(
              'Rename',
              rename,
              icon: Icons.drive_file_rename_outline_rounded,
              why: _whyNot('rename'),
              shortcut: const SingleActivator(LogicalKeyboardKey.f2),
            ),
            item(
              'Delete',
              delete,
              icon: Icons.delete_outline_rounded,
              why: _whyNot('delete'),
              shortcut: const SingleActivator(LogicalKeyboardKey.delete),
            ),
            item(
              'New folder',
              newFolder,
              icon: Icons.create_new_folder_outlined,
              why: _whyNot('folder'),
            ),
            item(
              'Find in folder',
              m == null ? null : _filterFocus.requestFocus,
              icon: Icons.search_rounded,
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyF,
                control: true,
              ),
            ),
          ],
          child: const Text('Edit'),
        ),
        SubmenuButton(
          menuChildren: [
            item(
              'Add files...',
              () => add(),
              icon: Icons.add_box_outlined,
              why: _whyNot('add'),
            ),
            item(
              'Extract...',
              m == null ? null : () => extract(),
              icon: Icons.unarchive_outlined,
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyE,
                control: true,
              ),
            ),
            item(
              'Extract here',
              m == null ? null : extractHere,
              icon: Icons.drive_folder_upload_outlined,
            ),
            item(
              'Test',
              m == null ? null : test,
              icon: Icons.fact_check_outlined,
            ),
            item(
              'Archive info and comment',
              m == null ? null : info,
              icon: Icons.info_outline_rounded,
            ),
          ],
          child: const Text('Archive'),
        ),
        SubmenuButton(
          menuChildren: [
            CheckboxMenuButton(
              value: st.showPreview,
              onChanged: (v) => st.showPreview = v ?? true,
              child: const Text('Preview pane'),
            ),
            SubmenuButton(
              menuChildren: [
                for (final t in ThemeMode.values)
                  RadioMenuButton<ThemeMode>(
                    value: t,
                    groupValue: st.theme,
                    onChanged: (v) => st.theme = v ?? ThemeMode.system,
                    child: Text(switch (t) {
                      ThemeMode.system => 'System',
                      ThemeMode.light => 'Light',
                      ThemeMode.dark => 'Dark',
                    }),
                  ),
              ],
              child: const Text('Theme'),
            ),
            const Divider(height: 1),
            item('Settings...', openSettings, icon: Icons.settings_outlined),
          ],
          child: const Text('View'),
        ),
        SubmenuButton(
          menuChildren: [
            item(
              'About zx',
              () => showAboutDialog(
                context: context,
                applicationName: 'zx',
                applicationVersion: '0.3.0',
                applicationIcon: Image.asset(
                  'assets/icon/zx-64.png',
                  width: 48,
                ),
                applicationLegalese:
                    'BSD 3-clause. A pure Dart port of 7-Zip (the public '
                    'domain LZMA SDK) with zip, rar, tar, gzip, bzip2, lzh '
                    'and arj.',
              ),
              icon: Icons.info_outline_rounded,
            ),
          ],
          child: const Text('Help'),
        ),
      ],
    );
  }

  Widget _splitter(void Function(double dx) onDrag) => MouseRegion(
    cursor: SystemMouseCursors.resizeColumn,
    child: GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragUpdate: (d) => setState(() => onDrag(d.delta.dx)),
      child: SizedBox(
        width: 5,
        child: Center(
          child: VerticalDivider(
            width: 1,
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final m = _model;
    return ListenableBuilder(
      listenable: Listenable.merge([_s.settings, ?m]),
      builder: (context, _) {
        Widget content;
        if (m == null) {
          content = WelcomeView(
            recent: _s.settings.recent,
            onOpen: _openDialog,
            onNew: () => newArchive(),
            onOpenRecent: openArchive,
            onRemoveRecent: _s.settings.removeRecent,
          );
        } else {
          content = Column(
            children: [
              PathBar(model: m, filter: _filter, filterFocus: _filterFocus),
              Divider(height: 1, color: cs.outlineVariant),
              Expanded(
                child: Row(
                  children: [
                    SizedBox(
                      width: _treeWidth,
                      child: ColoredBox(
                        color: cs.surfaceContainerLowest,
                        child: FolderTree(model: m),
                      ),
                    ),
                    _splitter(
                      (dx) => _treeWidth = (_treeWidth + dx).clamp(140, 520),
                    ),
                    Expanded(
                      child: Focus(
                        focusNode: _listFocus,
                        child: FileList(
                          model: m,
                          focusNode: _listFocus,
                          onOpen: openItem,
                          onContextMenu: _contextMenu,
                        ),
                      ),
                    ),
                    if (_s.settings.showPreview) ...[
                      _splitter(
                        (dx) => _previewWidth = (_previewWidth - dx).clamp(
                          200,
                          720,
                        ),
                      ),
                      SizedBox(
                        width: _previewWidth,
                        child: PreviewPane(model: m),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          );
        }
        return Focus(
          autofocus: true,
          onKeyEvent: _onKey,
          child: DropTarget(
            onDragEntered: (_) => setState(() => _dragging = true),
            onDragExited: (_) => setState(() => _dragging = false),
            onDragDone: _onDrop,
            child: Scaffold(
              body: Stack(
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        color: cs.surfaceContainerLow,
                        child: Row(children: [Expanded(child: _menuBar())]),
                      ),
                      Container(
                        color: cs.surfaceContainerLow,
                        child: Toolbar(actions: _toolActions()),
                      ),
                      Divider(height: 1, color: cs.outlineVariant),
                      Expanded(child: content),
                      StatusBar(model: m, message: _busy ? 'Working...' : null),
                    ],
                  ),
                  if (_dragging)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: Container(
                          margin: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: cs.primary.withValues(alpha: 0.08),
                            border: Border.all(color: cs.primary, width: 2),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          alignment: Alignment.center,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 12,
                            ),
                            decoration: BoxDecoration(
                              color: cs.primary,
                              borderRadius: BorderRadius.circular(24),
                            ),
                            child: Text(
                              m == null
                                  ? 'Drop to open or to make a new archive'
                                  : _whyNot('add') == null
                                  ? 'Drop to add to ${m.dir.isEmpty ? p.basename(m.archive.path) : m.dir}'
                                  : 'Drop an archive to open it',
                              style: TextStyle(
                                color: cs.onPrimary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
