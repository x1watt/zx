// The main window: the header (navigation, path bar, search, view, the
// menu), the action bar, folder tree, file list, preview and status bar, and every action on the open archive. The
// archive work runs in the background isolates of ZxArchive; this file
// only asks the questions and shows the results.

import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:zx/zx.dart';

import '../archive_model.dart';
import '../db_session.dart';
import '../dialogs/db_dialogs.dart';
import '../dialogs/add_dialogs.dart';
import '../dialogs/common_dialogs.dart';
import '../dialogs/compression_form.dart' show CompressionSettings;
import '../dialogs/fs_dialogs.dart';
import '../dialogs/extract_dialog.dart';
import '../dialogs/progress.dart';
import '../dialogs/properties_dialog.dart';
import '../formats.dart';
import '../platform/android_access.dart';
import '../platform/android_channel.dart';
import '../platform/android_places.dart';
import '../fs/fs_model.dart';
import '../fs/fs_ops.dart';
import '../platform/places.dart';
import '../services.dart';
import 'extract_to_folder.dart' show uniqueFolder;
import 'file_list.dart';
import 'format_utils.dart';
import 'panels.dart';
import 'preview_pane.dart';
import 'readme_view.dart';
import 'seal_badge.dart';
import 'data_view.dart';
import 'settings_page.dart';
import 'sidebar.dart';
import 'transfer.dart';
import 'views.dart';
import 'thumbnail_cache.dart';
import 'indexer.dart' show FileIndexer, IndexerPanel;

part 'explorer.dart';

/// Files that are zip or similar inside but documents to the user: they
/// open with their program ("Open as archive" still opens them here).
const _kOpenOutside = {
  'docx',
  'xlsx',
  'pptx',
  'odt',
  'ods',
  'odp',
  'odg',
  'epub',
  'jar',
  'apk',
  'appimage',
  'pdf',
};

Widget _withTooltip(String? message, Widget child) =>
    message == null ? child : Tooltip(message: message, child: child);

/// Rebuilds the desktop shell when archive navigation changes; selection
/// redraws remain inside the list, toolbar, preview and status widgets.
class _WidePageModelListener extends StatefulWidget {
  final ArchiveModel? model;
  final Widget Function() builder;

  const _WidePageModelListener({required this.model, required this.builder});

  @override
  State<_WidePageModelListener> createState() => _WidePageModelListenerState();
}

class _WidePageModelListenerState extends State<_WidePageModelListener> {
  String? _dir;

  @override
  void initState() {
    super.initState();
    _dir = widget.model?.dir;
    widget.model?.addListener(_changed);
  }

  @override
  void didUpdateWidget(_WidePageModelListener oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.model != widget.model) {
      oldWidget.model?.removeListener(_changed);
      _dir = widget.model?.dir;
      widget.model?.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.model?.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    final dir = widget.model?.dir;
    if (_dir == dir) return;
    _dir = dir;
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => widget.builder();
}

/// Rebuilds a narrow page when its archive model changes without subscribing
/// the full explorer shell to every selection update.
class _NarrowPageModelListener extends StatefulWidget {
  final ArchiveModel? model;
  final Widget Function() builder;

  const _NarrowPageModelListener({required this.model, required this.builder});

  @override
  State<_NarrowPageModelListener> createState() =>
      _NarrowPageModelListenerState();
}

class _NarrowPageModelListenerState extends State<_NarrowPageModelListener> {
  @override
  void initState() {
    super.initState();
    widget.model?.addListener(_changed);
  }

  @override
  void didUpdateWidget(_NarrowPageModelListener oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.model != widget.model) {
      oldWidget.model?.removeListener(_changed);
      widget.model?.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.model?.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => widget.builder();
}

/// Converts only rows requested by a lazy ListView/GridView builder.
class _LazyViewItems<T> extends ListBase<ViewItem> {
  final List<T> rows;
  final ViewItem Function(T row) make;
  final Map<int, ViewItem> _cache = {};

  _LazyViewItems(this.rows, this.make);

  @override
  int get length => rows.length;

  @override
  set length(int value) => throw UnsupportedError('read-only view');

  @override
  ViewItem operator [](int index) =>
      _cache.putIfAbsent(index, () => make(rows[index]));

  @override
  void operator []=(int index, ViewItem value) =>
      throw UnsupportedError('read-only view');
}

class BrowserPage extends StatefulWidget {
  final AppServices services;

  /// An archive to open at start (command line).
  final String? initialArchive;

  /// The folder shown at start (the home folder by default).
  final String? startDir;

  const BrowserPage({
    super.key,
    required this.services,
    this.initialArchive,
    this.startDir,
  });

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

  /// The database of the shown .zx archive (checked when it is opened).
  DbSession? _db;
  String? _dbKey;
  int _seenGeneration = -1;

  /// The Data view is shown instead of the files.
  bool _dataTab = false;

  /// The folder of the file system shown when no archive is.
  late final FsModel _fs;
  late final ThumbnailCache _thumbnails;
  late final FileIndexer _indexer;
  final _fsFilter = TextEditingController();
  late final PathEdit _pathEdit;
  List<Place> _places = const [];
  List<Place> _volumes = const [];
  SpaceInfo? _space;
  String? _spaceDir;

  /// What copy or cut took.
  Transfer? _clip;

  /// The filter box searches below the folder (the file system).
  bool _recursive = false;

  /// The tiles in a row of the grid (for the arrow keys).
  int _gridColumns = 1;

  /// The search field of a phone is open.
  bool _narrowSearch = false;
  StreamSubscription<IncomingIntent>? _androidIntentSubscription;
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _menu = MenuController();

  void _update(VoidCallback f) {
    if (mounted) setState(f);
  }

  /// The file system view (for tests).
  FsModel get fs => _fs;

  /// What copy or cut took (for tests).
  Transfer? get clipboard => _clip;

  AppServices get _s => widget.services;

  /// The open archive (for tests).
  ArchiveModel? get model => _model;

  /// The database session of the open archive (for tests).
  DbSession? get database => _db;

  /// Shows the Data view (true) or the files.
  void showData(bool on) => setState(() => _dataTab = on);

  @override
  void initState() {
    super.initState();
    _fs = FsModel(widget.startDir ?? _s.paths.home);
    _thumbnails = ThumbnailCache(
      archivePath: p.join(_s.paths.dataHome, 'zx', 'thumbnails.zx'),
      tempDir: _s.paths.temp,
    );
    _indexer = FileIndexer(
      cache: _thumbnails,
      places: _s.places,
      home: _s.paths.home,
      excludedDataPath: p.join(_s.paths.dataHome, 'zx'),
    );
    _fs.folderSizeResolver = _indexer.folderSize;
    _indexer.addListener(_onIndexerChanged);
    unawaited(_indexer.start());
    _fs.showHidden = _s.settings.showHidden;
    _fs.addListener(_onFsChanged);
    _pathEdit = PathEdit(
      text: () => _pathText(),
      onSubmit: goToPath,
      onDone: _listFocus.requestFocus,
    );
    unawaited(_fs.reload());
    unawaited(_loadPlaces());
    final a = widget.initialArchive;
    if (a != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => goToPath(a));
    }
    if (Platform.isMacOS) _listenToFinder();
    if (Platform.isAndroid) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _listenToAndroid());
    }
  }

  /// Android: the archives other apps open with zx (ACTION_VIEW), the
  /// files shared to zx (ACTION_SEND: a new archive of them), and the
  /// storage permission, asked for with an explanation at the first start.
  Future<void> _listenToAndroid() async {
    AndroidPlaces.explainer = () => showStorageAccessDialog(context);
    _androidIntentSubscription = AndroidIntents.instance.stream.listen(
      _onAndroidIntent,
    );
    final i = await AndroidIntents.instance.initial();
    if (i != null) {
      await _onAndroidIntent(i);
    } else {
      await const AndroidPlaces().ensureAccess();
    }
  }

  Future<void> _onAndroidIntent(IncomingIntent i) async {
    if (!mounted) return;
    final paths = i.paths;
    if (paths.isEmpty) {
      final why = i.files.map((f) => f.error).whereType<String>().join(', ');
      _snack('Can not read the file${why.isEmpty ? '' : ': $why'}');
      return;
    }
    if (i.action == IncomingAction.view) {
      await openArchive(paths.first);
      if (mounted && i.files.first.copied) {
        _snack('Opened a copy: changes do not reach the original file');
      }
      return;
    }
    final copied = i.files.any((f) => f.copied);
    await newArchive(
      sources: paths,
      folder: copied ? await const AndroidPlaces().outputFolder() : null,
    );
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
    final m = _model;
    if (m != null) _closeLevels(m);
    _model?.removeListener(_syncFilter);
    _model?.removeListener(_onModelGeneration);
    final db = _db;
    _db = null;
    if (db != null) unawaited(db.close().catchError((Object _) {}));
    final cm = _clip?.model;
    if (cm != null && cm.root != m?.root) _closeLevels(cm);
    unawaited(_androidIntentSubscription?.cancel());
    _listFocus.dispose();
    _filterFocus.dispose();
    _filter.dispose();
    _fsFilter.dispose();
    _indexer.removeListener(_onIndexerChanged);
    _fs.dispose();
    unawaited(_closeIndexerAndThumbnails());
    _pathEdit.dispose();
    super.dispose();
  }

  void _onIndexerChanged() {
    if (!mounted) return;
    _fs.refreshIndexedSizes();
    setState(() {});
  }

  Future<void> _closeIndexerAndThumbnails() async {
    try {
      await _indexer.close();
    } on Object {
      // Cache and indexer shutdown are best effort.
    }
    try {
      await _thumbnails.close();
    } on Object {
      // Cache writes may be unavailable on a read-only home.
    }
  }

  void _syncFilter() {
    final m = _model;
    if (m != null && _filter.text != m.filter) _filter.text = m.filter;
  }

  void _setModel(ArchiveModel? m) {
    _model?.removeListener(_syncFilter);
    _model?.removeListener(_onModelGeneration);
    _model = m;
    m?.addListener(_syncFilter);
    m?.addListener(_onModelGeneration);
    _seenGeneration = m?.generation ?? -1;
    _filter.text = '';
    _syncDb(m);
    _setWindowTitle(m == null ? 'zx' : '${titleOf(m)} - zx');
  }

  // ---- the database of a .zx archive ----

  /// The model's archive changed (files added...): the SQL session reads
  /// the archive again.
  void _onModelGeneration() {
    final m = _model;
    if (m == null || m.generation == _seenGeneration) return;
    _seenGeneration = m.generation;
    final db = _db;
    if (db != null && db.available) {
      unawaited(db.archiveChanged().catchError((Object _) {}));
    }
  }

  /// Opens (or keeps, or closes) the database session for [m]: one per
  /// archive file, version and read-only reason.
  void _syncDb(ArchiveModel? m) {
    final root = m?.root;
    String? key;
    if (m != null && root!.archive.format == 'zx') {
      key =
          '${root.archive.path}\n${root.archive.version}\n'
          '${root.isOldVersion}\n${m.readOnlyWhy}';
    }
    if (key == _dbKey) return;
    final old = _db;
    _db = null;
    _dbKey = key;
    _dataTab = false;
    if (old != null) unawaited(old.close().catchError((Object _) {}));
    if (key == null || m == null) return;
    final a = root!.archive;
    final db = DbSession(
      a.path,
      password: a.password,
      readOnlyWhy: m.readOnlyWhy,
      asOfGeneration: root.isOldVersion ? a.version : null,
      opener: _s.dbOpener,
    );
    db.onWrite = _afterDbWrite;
    db.addListener(() {
      if (mounted && _db == db) setState(() {});
    });
    _db = db;
    unawaited(db.start());
  }

  /// A SQL write appended a generation: the listing is read again, so the
  /// archive's own writes see the current file.
  Future<void> _afterDbWrite() async {
    final m = _model;
    if (m == null || m.parent != null || m.archive.flattened) return;
    final old = m.archive;
    try {
      final a = await ZxArchive.open(
        old.path,
        password: old.password,
        onPassword: _askPassword,
      );
      if (!mounted || _model != m) {
        await a.close();
        return;
      }
      _seenGeneration = m.generation + 1;
      m.refresh(archive: a);
      await old.close();
    } on SevenZipException {
      // the listing stays as it was
    }
  }

  /// Why the database actions are not available, or null.
  String? _whyNotDb() {
    final m = _model;
    if (m == null) return 'Open an archive first';
    if (m.root.archive.format != 'zx') {
      return 'Only .zx archives hold a database';
    }
    final db = _db;
    if (db == null || !db.checked) return 'Checking for a database';
    if (!db.available) return 'The archive has no database';
    if (m.parent != null) return 'Inside a nested archive';
    return null;
  }

  String? _whyNotNewDb() {
    final m = _model;
    if (m == null) return 'Open an archive first';
    if (m.archive.format != 'zx' || m.parent != null) {
      return 'Only a .zx archive file can hold a database';
    }
    final ro = m.readOnlyReason;
    if (ro != null) return ro;
    final db = _db;
    if (db == null || !db.checked) return 'Checking for a database';
    if (db.available) return 'The archive has a database';
    return null;
  }

  Future<void> newDatabase() async {
    final db = _db;
    if (db == null || _whyNotNewDb() != null) return;
    try {
      await db.create();
      if (!mounted) return;
      setState(() => _dataTab = true);
      _snack('Created a database in ${p.basename(db.path)}');
    } catch (e) {
      if (mounted) {
        await showErrorDialog(
          context,
          title: 'New database',
          message: dbErrorText(e),
        );
      }
    }
  }

  /// Shows the file at [path] in the file list (selected).
  void _reveal(String path) {
    final m = _model;
    if (m == null) return;
    final k = path.lastIndexOf('/');
    final dir = k < 0 ? '' : path.substring(0, k);
    if (m.dir != dir) m.navigate(dir);
    m.selectPaths([path]);
    setState(() => _dataTab = false);
    _listFocus.requestFocus();
  }

  Future<void> findSimilar([ZxItem? item]) async {
    final m = _model;
    final db = _db;
    final it =
        item ?? (m?.selectedItems.length == 1 ? m!.selectedItems.first : null);
    if (db == null || it == null || it.isDir || _whyNotDb() != null) return;
    final r = await showSimilarFilesDialog(context, db, it.path);
    if (r != null && mounted) _reveal(r);
  }

  Future<void> findBySha() async {
    final db = _db;
    if (db == null || _whyNotDb() != null) return;
    final r = await showFindShaDialog(context, db);
    if (r != null && mounted) _reveal(r);
  }

  /// The chain of archives of [m] for the title bar:
  /// `firmware.pak > rootfs`, with the version of a zpaq archive shown at
  /// an older one.
  static String titleOf(ArchiveModel m) {
    final names = m.levels.map((l) => l.displayName).join(' > ');
    final a = m.root.archive;
    return m.root.isOldVersion
        ? '$names (version ${a.version} of ${a.numVersions})'
        : names;
  }

  /// Closes the handles of [m] and of its parents up to [keep] (not
  /// included); their temporary files are deleted in the background.
  void _closeLevels(ArchiveModel m, {ArchiveModel? keep}) {
    // the levels of what the clipboard holds stay open until it is replaced
    final held = _clip?.model?.levels.toSet() ?? const <ArchiveModel>{};
    for (ArchiveModel? l = m; l != null && l != keep; l = l.parent) {
      if (held.contains(l)) continue;
      unawaited(l.closeHandles().catchError((Object _) {}));
    }
  }

  /// Replaces the shown archive with [m], closing the levels of the old
  /// one that [m] does not use.
  void _replaceModel(ArchiveModel? m) {
    final old = _model;
    if (old != null && old != m) {
      final keep = m == null ? null : _commonLevel(old, m);
      _closeLevels(old, keep: keep);
    }
    setState(() => _setModel(m));
  }

  static ArchiveModel? _commonLevel(ArchiveModel a, ArchiveModel b) {
    final bl = b.levels.toSet();
    for (ArchiveModel? l = a; l != null; l = l.parent) {
      if (bl.contains(l)) return l;
    }
    return null;
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
    } on FsCancelled {
      _snack('$what: cancelled');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    return null;
  }

  // ---- open, new, close ----

  Future<void> openArchive(
    String path, {
    int? version,
    List<ZxVersion>? allVersions,
    String? dir,
  }) async {
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
      return runWithProgress(context, 'Opening ${p.basename(full)}', (
        pr,
      ) async {
        final flat = _s.settings.showInnerFilesystems;
        var a = await ZxArchive.open(
          full,
          onPassword: _askPassword,
          cancel: pr.cancel,
          flatten: flat,
          version: version,
        );
        if (flat && !a.items.any((i) => i.isNested)) {
          // nothing nested: the plain archive, which may be changed
          await a.close();
          a = await ZxArchive.open(
            full,
            password: a.password,
            onPassword: _askPassword,
            cancel: pr.cancel,
            version: version,
          );
        }
        return a;
      });
    });
    if (a == null || !mounted) return;
    showArchive(a, allVersions: allVersions, dir: dir);
  }

  /// Shows [a] (opened or created by the caller), at the folder [dir] or
  /// the nearest one above it that exists.
  void showArchive(ZxArchive a, {List<ZxVersion>? allVersions, String? dir}) {
    a.onPassword ??= _askPassword;
    _s.settings.addRecent(a.path);
    final all = allVersions != null && allVersions.length > a.versions.length
        ? allVersions
        : null;
    final m = ArchiveModel(a, allVersions: all);
    var d = dir ?? '';
    while (d.isNotEmpty && !(a[d]?.isDir ?? false)) {
      final k = d.lastIndexOf('/');
      d = k < 0 ? '' : d.substring(0, k);
    }
    if (d.isNotEmpty) m.navigate(d, record: false);
    _replaceModel(m);
    _listFocus.requestFocus();
  }

  /// Opens the archive again: with or without its inner file systems
  /// (View, Show inner filesystems) or at another [version] (zpaq). The
  /// folder shown stays when it exists in the new view.
  Future<void> reopen({int? version, bool keepVersion = true}) async {
    final m = _model;
    if (m == null) return;
    final root = m.root;
    final a = root.archive;
    // the folder in the tree of the archive file: the nested levels are
    // folders there when the inner file systems are shown (else the
    // nearest folder that exists is shown)
    final dir = [
      for (final l in m.levels.skip(1)) l.entry!.path,
      if (m.dir.isNotEmpty) m.dir,
    ].join('/');
    final v = version ?? (keepVersion && root.isOldVersion ? a.version : null);
    await openArchive(
      a.path,
      version: v == a.numVersions ? null : v,
      allVersions: root.allVersions,
      dir: dir,
    );
  }

  Future<void> _setShowInner(bool on) async {
    if (_s.settings.showInnerFilesystems == on) return;
    _s.settings.showInnerFilesystems = on;
    await reopen();
  }

  Future<void> _openDialog() async {
    final cur = _model?.archive.path;
    final f = await _s.picker.openArchive(
      initialDirectory: cur == null ? null : p.dirname(cur),
    );
    if (f != null) await openArchive(f);
  }

  /// Closes the archive: back to the folder that holds it.
  void closeArchive() => _exitToFs();

  /// The new archive dialog (in [folder], by default next to the
  /// sources); the archive is shown afterwards ([show]), or selected in
  /// the folder shown.
  Future<void> newArchive({
    List<String> sources = const [],
    String? folder,
    String? formatId,
    bool show = true,
  }) async {
    folder ??= sources.isNotEmpty
        ? p.dirname(sources.first)
        : _model != null
        ? p.dirname(_model!.archive.path)
        : _fs.dir;
    final folders = await foldersOf(sources);
    if (!mounted) return;
    final r = await showNewArchiveDialog(
      context,
      folder: folder,
      sources: sources,
      folders: folders,
      formatId: formatId ?? _s.settings.defaultFormat,
      defaultLevel: _s.settings.defaultLevel,
      picker: _s.picker,
      zxDefaults: _s.settings.zxCompression,
      estimator: _s.estimator,
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
    if (show || _model != null) {
      showArchive(a);
    } else {
      await a.close();
      await _fs.reload(
        select: p.equals(p.dirname(a.path), _fs.dir) ? [a.path] : null,
      );
    }
    _snack('Created ${p.basename(a.path)}');
  }

  // ---- reasons an action is not available ----

  String? _whyNot(String action) {
    final m = _model;
    if (m == null) return 'Open an archive first';
    final a = m.archive;
    final c = a.capabilities;
    final ro = m.readOnlyReason;
    if (ro != null &&
        const {
          'add',
          'delete',
          'rename',
          'folder',
          'comment',
        }.contains(action)) {
      return ro;
    }
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

  /// Opens [item]: a folder is entered, a file that is an archive (its
  /// start matches a known format, or it is a section of a firmware or a
  /// partition) opens as a nested level, any other file opens with its
  /// default program.
  Future<void> openItem(ZxItem item) async {
    final m = _model;
    if (m == null) return;
    if (item.isDir) {
      m.navigate(item.path);
      return;
    }
    if (!_kOpenOutside.contains(extensionOf(item.name))) {
      final fmt = await _guard('Open ${item.name}', () {
        return runWithProgress(
          context,
          'Opening ${item.name}',
          (pr) => m.archive.probeNested(item, cancel: pr.cancel),
        );
      });
      if (!mounted || _model != m) return;
      if (fmt != null) {
        final ok = await openAsArchive(item, quiet: true);
        if (ok || !mounted) return;
      }
    }
    await openOutside(item);
  }

  /// Opens the file [item] with its default program (it is extracted to a
  /// temporary folder first).
  Future<void> openOutside(ZxItem item) async {
    final m = _model;
    if (m == null || item.isDir) return;
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

  /// Opens the file [item] as a nested archive: a new level of the path
  /// bar, read-only, left with Back or Up. [quiet]: when it is not an
  /// archive, false is returned without an error dialog. A nested archive
  /// that holds a single archive (a UBI image with one volume) shows the
  /// files of that one directly.
  Future<bool> openAsArchive(ZxItem item, {bool quiet = false}) async {
    final m = _model;
    if (m == null) return false;
    var notArc = false;
    final r = await _guard('Open ${item.name} as archive', () {
      return runWithProgress(context, 'Opening ${item.name}', (pr) async {
        ZxArchive a;
        try {
          a = await m.archive.openNested(item, cancel: pr.cancel);
        } on SevenZipException catch (e) {
          if (quiet && e.kind == SevenZipError.isNotArc) {
            notArc = true;
            return null;
          }
          rethrow;
        }
        final passed = <ZxArchive>[];
        try {
          while (passed.length < 3 &&
              a.items.length == 1 &&
              !a.items.first.isDir) {
            final only = a.items.first;
            final f = await a.probeNested(only, cancel: pr.cancel);
            if (f == null) break;
            final ZxArchive inner;
            try {
              inner = await a.openNested(only, cancel: pr.cancel);
            } on SevenZipException catch (e) {
              if (e.kind == SevenZipError.cancelled) rethrow;
              break;
            }
            passed.add(a);
            a = inner;
          }
        } catch (_) {
          await a.close();
          for (final x in passed) {
            await x.close();
          }
          rethrow;
        }
        return (a, passed);
      });
    });
    if (r == null) return !notArc;
    final (a, passed) = r;
    if (!mounted || _model != m) {
      // the view changed meanwhile
      await a.close();
      for (final x in passed) {
        await x.close();
      }
      return true;
    }
    a.onPassword ??= _askPassword;
    final level = ArchiveModel(a, parent: m, entry: item, passed: passed);
    setState(() => _setModel(level));
    _listFocus.requestFocus();
    return true;
  }

  /// Leaves the nested level shown, back to its parent with the item it
  /// was opened from selected.
  void leaveNested() {
    final m = _model;
    final parent = m?.parent;
    if (m == null || parent == null) return;
    _replaceModel(parent);
    parent.selectPaths([m.entry!.path]);
  }

  /// Shows the folder [dir] of [level], one of the levels of the path
  /// bar (the nested levels below it are closed).
  void goToLevel(ArchiveModel level, String dir) {
    if (level != _model) _replaceModel(level);
    level.navigate(dir);
  }

  /// Back: the folder before, or out of a nested archive.
  void back() {
    final m = _model;
    if (m == null) {
      _fs.back();
      return;
    }
    if (m.canBack) {
      m.back();
    } else if (m.parent != null) {
      leaveNested();
    } else {
      _exitToFs();
    }
  }

  /// Forward in the history of the view shown.
  void forward() {
    final m = _model;
    if (m == null) {
      _fs.forward();
    } else {
      m.forward();
    }
  }

  /// Up: the parent folder, or out of a nested archive at its top level.
  void up() {
    final m = _model;
    if (m == null) {
      _fs.up();
      return;
    }
    if (m.canUp) {
      m.up();
    } else if (m.parent != null) {
      leaveNested();
    } else {
      _exitToFs();
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
    return p.join(p.dirname(a), folderNameFor(m.displayName));
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
      return runWithProgress(context, 'Extracting ${m.displayName}', (pr) {
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
      });
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
    if (openFolder) await _showFolder(dest);
    _snack(
      'Extracted ${r.files} file${r.files == 1 ? '' : 's'}'
      '${r.skipped > 0 ? ' (${r.skipped} skipped)' : ''} to $dest',
      action: openFolder
          ? null
          : SnackBarAction(
              label: 'Open folder',
              onPressed: () => _showFolder(dest),
            ),
    );
  }

  /// "Open folder": a phone shows it in the explorer, a desktop opens its
  /// file manager.
  Future<void> _showFolder(String dir) async {
    if (Platform.isAndroid) {
      if (_model != null) _replaceModel(null);
      await _fs.navigate(dir);
    } else {
      await _s.launcher.openFolder(dir);
    }
  }

  Future<void> test() async {
    final m = _model;
    if (m == null) return;
    final r = await _guard('Test', () {
      return runWithProgress(
        context,
        'Testing ${m.displayName}',
        (pr) => m.archive.test(onProgress: pr.update, cancel: pr.cancel),
      );
    });
    if (r == null || !mounted) return;
    await showExtractResultDialog(
      context,
      title: 'Test of ${m.displayName}',
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
      zxDefaults: _s.settings.zxCompression,
      estimator: _s.estimator,
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
      await showItemPropertiesDialog(
        context,
        m,
        sel,
        db: m.parent == null ? _db : null,
      );
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
      if (item != null && !item.isDir) ...[
        entry('open-archive', Icons.folder_zip_outlined, 'Open as archive'),
        entry(
          'open-outside',
          Icons.launch_rounded,
          'Open with default program',
        ),
      ],
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
        entry('copy', Icons.content_copy_rounded, 'Copy', shortcut: 'Ctrl+C'),
        entry(
          'cut',
          Icons.content_cut_rounded,
          'Cut',
          why: _whyNot('delete'),
          shortcut: 'Ctrl+X',
        ),
        entry('copy-path', Icons.link_rounded, 'Copy path'),
        if (item != null && !item.isDir && _whyNotDb() == null)
          entry('similar', Icons.compare_arrows_rounded, 'Find similar files'),
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
          'paste',
          Icons.content_paste_rounded,
          'Paste',
          why: _clip == null ? 'Nothing to paste' : _whyNot('add'),
          shortcut: 'Ctrl+V',
        ),
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
      case 'open-archive':
        if (item != null) await openAsArchive(item);
      case 'open-outside':
        if (item != null) await openOutside(item);
      case 'extract-to':
        await extract(selectionDefault: hasSel);
      case 'extract-here':
        await extractHere();
      case 'copy-path':
        copyPath();
      case 'copy':
        copySelection();
      case 'cut':
        copySelection(cut: true);
      case 'paste':
        await paste();
      case 'similar':
        if (item != null) await findSimilar(item);
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

  /// F5: reads the folder (or the archive) again.
  Future<void> _refresh() async {
    final m = _model;
    if (m == null) {
      await _fs.reload();
    } else if (m.parent == null && !m.archive.flattened) {
      await reopen();
    }
  }

  void _setShowHidden(bool on) {
    _s.settings.showHidden = on;
    _fs.showHidden = on;
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
    } else if (ctrl && k == LogicalKeyboardKey.keyF) {
      _filterFocus.requestFocus();
    } else if (ctrl && k == LogicalKeyboardKey.keyL) {
      _pathEdit.editing = true;
    } else if (ctrl && k == LogicalKeyboardKey.keyH) {
      _setShowHidden(!_s.settings.showHidden);
    } else if (k == LogicalKeyboardKey.f5) {
      _refresh();
    } else if (k == LogicalKeyboardKey.f10) {
      _toggleMenu();
    } else if (ctrl && k == LogicalKeyboardKey.keyQ) {
      exit(0);
    } else if (alt && k == LogicalKeyboardKey.arrowLeft) {
      back();
    } else if (alt && k == LogicalKeyboardKey.arrowRight) {
      forward();
    } else if (alt && k == LogicalKeyboardKey.arrowUp) {
      up();
    } else if (k == LogicalKeyboardKey.escape && _filterFocus.hasFocus) {
      // Escape in the search box: clears it, back to the list
      _filter.clear();
      _fsFilter.clear();
      m?.filter = '';
      _fs.stopSearch();
      _fs.filter = '';
      _listFocus.requestFocus();
    } else if (_textFocused) {
      handled = false;
    } else if (m == null) {
      handled = _fsKey(k, ctrl: ctrl, alt: alt);
    } else if (ctrl && k == LogicalKeyboardKey.keyC) {
      copySelection();
    } else if (ctrl && k == LogicalKeyboardKey.keyX) {
      copySelection(cut: true);
    } else if (ctrl && k == LogicalKeyboardKey.keyV) {
      paste();
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
      up();
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

  /// Files dropped on the window from another program: in a folder of
  /// the file system they are copied there; with an archive open they
  /// are added to its current folder (or, when it can not change, a
  /// dropped archive opens instead).
  Future<void> handleDrop(List<String> dropped) async {
    final paths = dropped.where((s) => s.isNotEmpty).toList();
    if (paths.isEmpty) return;
    final m = _model;
    if (m == null) {
      await _dropFromOs(paths);
      return;
    }
    if (_whyNot('add') == null) {
      await _addTo(m, m.dir, paths);
    } else if (paths.length == 1 && looksLikeArchive(paths.first)) {
      await openArchive(paths.first);
    } else {
      _snack('Can not add here: ${_whyNot('add')}');
    }
  }

  // ---- layout ----

  /// The actions of the open archive, in a slim bar under the header.
  /// Null in a folder: nothing here appears or disappears with the
  /// selection, because a bar that pops in under the pointer moves the
  /// rows below it and the file under the cursor is no longer the file
  /// that was clicked. The actions of a folder are in its context menu.
  Widget? _actionBar(ColorScheme cs) {
    final m = _model;
    if (m == null) return null;
    final clip = _clip;
    final label = TextStyle(fontSize: 13, color: cs.onSurfaceVariant);
    final pasteAction = clip == null
        ? null
        : ToolAction(
            'paste',
            Icons.content_paste_rounded,
            'Paste',
            'Paste ${clip.label} here (Ctrl+V)',
            paste,
          );
    final readOnly = _whyNot('add');
    final selected = m.selection.isNotEmpty;
    return ActionBar(
      key: const Key('archive-actions'),
      leading: selected
          ? Padding(
              padding: const EdgeInsets.only(left: 8, right: 8),
              child: Text('${m.selection.length} selected', style: label),
            )
          : null,
      actions: [
        ToolAction(
          'extract',
          Icons.unarchive_outlined,
          'Extract',
          'Extract files (Ctrl+E)',
          () => extract(),
        ),
        if (readOnly == null)
          ToolAction(
            'add',
            Icons.add_box_outlined,
            'Add',
            'Add files and folders to the current folder',
            () => add(),
          ),
        ToolAction(
          'test',
          Icons.fact_check_outlined,
          'Test',
          'Test the archive for errors',
          test,
        ),
        ToolAction(
          'info',
          Icons.info_outline_rounded,
          'Info',
          'Archive properties and comment',
          info,
        ),
        if (selected || (pasteAction != null && readOnly == null)) null,
        if (selected)
          ToolAction(
            'copy',
            Icons.content_copy_rounded,
            'Copy',
            'Copy the selection, to paste in a folder (Ctrl+C)',
            copySelection,
          ),
        if (readOnly == null) ?pasteAction,
        if (selected && _whyNot('rename') == null && m.selection.length == 1)
          ToolAction(
            'rename',
            Icons.drive_file_rename_outline_rounded,
            'Rename',
            'Rename the selected item (F2)',
            rename,
          ),
        if (selected && _whyNot('delete') == null)
          ToolAction(
            'delete',
            Icons.delete_outline_rounded,
            'Delete',
            'Delete the selected items (Del)',
            delete,
          ),
      ],
      trailing: readOnly == null
          ? null
          : Tooltip(
              key: const Key('read-only'),
              message: readOnly,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.lock_outline_rounded,
                      size: 14,
                      color: cs.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    Text('Read-only', style: label.copyWith(fontSize: 12)),
                  ],
                ),
              ),
            ),
    );
  }

  /// Shows version [n] of the zpaq archive (read-only unless it is the
  /// latest).
  Future<void> showVersion(int n) async {
    final m = _model;
    if (m == null) return;
    final a = m.root.archive;
    if (n == (a.version ?? a.numVersions)) return;
    await reopen(version: n, keepVersion: false);
  }

  static String versionLabel(ZxVersion v, int latest) =>
      'Version ${v.number}   ${formatDate(v.time)}   '
      '${v.added} added${v.deleted > 0 ? ', ${v.deleted} deleted' : ''}'
      '${v.number == latest ? '   (latest)' : ''}';

  /// The version selector of a zpaq archive in the status bar.
  // a version's line in the picker, with its seal when the archive has
  // seals
  String _withSeal(String label, ZxArchive a, int number) {
    final g = SealCache.generation(a, number);
    if (g == null || g.state == ZxSealState.plain) return label;
    return '$label  [${sealStateText(g)}]';
  }

  Widget? _versionPicker(ArchiveModel m) {
    final root = m.root;
    final a = root.archive;
    if (a.numVersions == 0) return null;
    final cur = a.version ?? a.numVersions;
    final cs = Theme.of(context).colorScheme;
    final style = TextStyle(
      fontSize: 12,
      color: root.isOldVersion ? cs.tertiary : cs.onSurfaceVariant,
      fontWeight: root.isOldVersion ? FontWeight.w600 : FontWeight.normal,
    );
    return PopupMenuButton<int>(
      key: const Key('version-picker'),
      tooltip: 'Show another version of the archive',
      onSelected: showVersion,
      position: PopupMenuPosition.over,
      // one line per version (the default menu width wraps them)
      constraints: const BoxConstraints(minWidth: 280, maxWidth: 520),
      itemBuilder: (_) => [
        for (final v in root.allVersions.reversed)
          CheckedPopupMenuItem<int>(
            key: Key('version:${v.number}'),
            value: v.number,
            checked: v.number == cur,
            height: 34,
            child: Text(
              _withSeal(versionLabel(v, a.numVersions), a, v.number),
              style: const TextStyle(fontSize: 13),
            ),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.history_rounded, size: 14, color: style.color),
            const SizedBox(width: 4),
            Text(
              'Version $cur of ${a.numVersions}'
              '${root.isOldVersion ? ' (read-only)' : ''}',
              style: style,
            ),
            Icon(Icons.arrow_drop_up_rounded, size: 16, color: style.color),
          ],
        ),
      ),
    );
  }

  /// The one menu of the header (also F10): everything that is not in
  /// the action bar, the context menu or a shortcut. An item that does
  /// not apply now is left out. The anchor builds the items into
  /// elements only while it is open.
  Widget _appMenu() => MenuAnchor(
    controller: _menu,
    menuChildren: _menuItems(),
    builder: (context, c, _) => IconButton(
      key: const Key('app-menu'),
      tooltip: 'Menu (F10)',
      visualDensity: VisualDensity.compact,
      isSelected: c.isOpen,
      onPressed: _toggleMenu,
      icon: const Icon(Icons.menu_rounded, size: 20),
    ),
  );

  void _toggleMenu() {
    if (_menu.isOpen) {
      _menu.close();
    } else {
      _menu.open();
    }
  }

  List<Widget> _menuItems() {
    final m = _model;
    final st = _s.settings;
    MenuItemButton item(
      String label,
      VoidCallback? onPressed, {
      Key? key,
      IconData? icon,
      MenuSerializableShortcut? shortcut,
    }) => MenuItemButton(
      key: key,
      onPressed: onPressed,
      shortcut: shortcut,
      leadingIcon: icon == null ? null : Icon(icon, size: 18),
      child: Text(label),
    );
    const div = Divider(height: 1);
    final canFolder = m == null || _whyNot('folder') == null;
    final canPaste = _clip != null && (m == null || _whyNot('add') == null);
    return [
      item(
        'Open archive...',
        _openDialog,
        key: const Key('tool-open'),
        icon: Icons.folder_open_rounded,
        shortcut: const SingleActivator(LogicalKeyboardKey.keyO, control: true),
      ),
      item(
        'New archive...',
        () => newArchive(),
        key: const Key('tool-new'),
        icon: Icons.add_circle_outline_rounded,
        shortcut: const SingleActivator(LogicalKeyboardKey.keyN, control: true),
      ),
      SubmenuButton(
        leadingIcon: const Icon(Icons.history_rounded, size: 18),
        menuChildren: [
          if (st.recent.isEmpty) item('No recent archives', null),
          for (final r in st.recent) item(r, () => openArchive(r)),
          if (st.recent.isNotEmpty) ...[
            div,
            item('Clear the list', st.clearRecent),
          ],
        ],
        child: const Text('Recent archives'),
      ),
      if (m != null)
        item(
          'Close archive',
          closeArchive,
          icon: Icons.close_rounded,
          shortcut: const SingleActivator(
            LogicalKeyboardKey.keyW,
            control: true,
          ),
        ),
      div,
      if (canFolder)
        item(
          'New folder',
          m == null ? newFolderFs : newFolder,
          key: const Key('tool-folder'),
          icon: Icons.create_new_folder_outlined,
        ),
      if (canPaste)
        item(
          'Paste',
          paste,
          icon: Icons.content_paste_rounded,
          shortcut: const SingleActivator(
            LogicalKeyboardKey.keyV,
            control: true,
          ),
        ),
      item(
        'Select all',
        m?.selectAll ?? _fs.selectAll,
        icon: Icons.select_all_rounded,
        shortcut: const SingleActivator(LogicalKeyboardKey.keyA, control: true),
      ),
      if (m != null && m.selection.isNotEmpty)
        item('Copy path', copyPath, icon: Icons.link_rounded),
      item(
        'Go to path',
        () => _pathEdit.editing = true,
        icon: Icons.edit_location_alt_outlined,
        shortcut: const SingleActivator(LogicalKeyboardKey.keyL, control: true),
      ),
      item(
        'Find in folder',
        _filterFocus.requestFocus,
        icon: Icons.search_rounded,
        shortcut: const SingleActivator(LogicalKeyboardKey.keyF, control: true),
      ),
      div,
      if (m != null) _archiveSubmenu(m, item),
      SubmenuButton(
        leadingIcon: const Icon(Icons.visibility_outlined, size: 18),
        menuChildren: [
          CheckboxMenuButton(
            key: const Key('menu-grid'),
            value: st.gridView,
            onChanged: (v) => st.gridView = v ?? false,
            child: const Text('Icons and thumbnails'),
          ),
          CheckboxMenuButton(
            key: const Key('menu-hidden'),
            value: st.showHidden,
            onChanged: (v) => _setShowHidden(v ?? false),
            shortcut: const SingleActivator(
              LogicalKeyboardKey.keyH,
              control: true,
            ),
            child: const Text('Show hidden folders and files'),
          ),
          if (_model == null)
            SubmenuButton(
              key: const Key('menu-left-pane'),
              menuChildren: [
                for (final (value, label) in const [
                  ('tree', 'Folder tree'),
                  ('places', 'Places and bookmarks'),
                  ('indexer', 'Indexer summary'),
                ])
                  RadioMenuButton<String>(
                    value: value,
                    groupValue: st.leftPane,
                    onChanged: (v) => st.leftPane = v ?? 'tree',
                    child: Text(label),
                  ),
              ],
              child: const Text('Left pane'),
            ),
          SubmenuButton(
            menuChildren: [
              for (final (k, label) in const [
                (FsSort.name, 'Name'),
                (FsSort.size, 'Size'),
                (FsSort.type, 'Type'),
                (FsSort.modified, 'Modified'),
              ])
                RadioMenuButton<FsSort>(
                  value: k,
                  groupValue: _fs.sort,
                  onChanged: (v) => _fs.sortBy(v ?? k),
                  child: Text(label),
                ),
            ],
            child: const Text('Sort folders by'),
          ),
          item(
            'Refresh',
            _refresh,
            icon: Icons.refresh_rounded,
            shortcut: const SingleActivator(LogicalKeyboardKey.f5),
          ),
          div,
          CheckboxMenuButton(
            value: st.showPreview,
            onChanged: (v) => st.showPreview = v ?? true,
            child: const Text('Preview pane'),
          ),
          CheckboxMenuButton(
            key: const Key('menu-show-readme'),
            value: st.showReadme,
            onChanged: (v) => st.showReadme = v ?? true,
            child: const Text('README of the folder'),
          ),
          CheckboxMenuButton(
            key: const Key('menu-show-inner'),
            value: st.showInnerFilesystems,
            onChanged: (v) => _setShowInner(v ?? false),
            child: const Text('Show inner filesystems'),
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
        ],
        child: const Text('View'),
      ),
      div,
      item(
        'Settings...',
        openSettings,
        key: const Key('tool-settings'),
        icon: Icons.settings_outlined,
      ),
      item(
        'About zx',
        () => showAboutDialog(
          context: context,
          applicationName: 'zx',
          applicationVersion: '0.5.0',
          applicationIcon: Image.asset('assets/icon/zx-64.png', width: 48),
          applicationLegalese:
              'BSD 3-clause. A pure Dart port of 7-Zip (the public '
              'domain LZMA SDK) with zip, rar, tar, gzip, bzip2, lzh, '
              'arj, zpaq, disc and file system images and firmware.',
        ),
        icon: Icons.info_outline_rounded,
      ),
      item(
        'Quit',
        () => exit(0),
        icon: Icons.logout_rounded,
        shortcut: const SingleActivator(LogicalKeyboardKey.keyQ, control: true),
      ),
    ];
  }

  /// The archive part of the menu (what the action bar does not show).
  Widget _archiveSubmenu(
    ArchiveModel m,
    MenuItemButton Function(
      String label,
      VoidCallback? onPressed, {
      Key? key,
      IconData? icon,
      MenuSerializableShortcut? shortcut,
    })
    item,
  ) {
    final zx = m.root.archive.format == 'zx';
    return SubmenuButton(
      leadingIcon: const Icon(Icons.inventory_2_outlined, size: 18),
      menuChildren: [
        item(
          'Extract...',
          () => extract(),
          icon: Icons.unarchive_outlined,
          shortcut: const SingleActivator(
            LogicalKeyboardKey.keyE,
            control: true,
          ),
        ),
        item(
          'Extract here',
          extractHere,
          icon: Icons.drive_folder_upload_outlined,
        ),
        if (_whyNot('add') == null)
          item('Add files...', () => add(), icon: Icons.add_box_outlined),
        item('Test', test, icon: Icons.fact_check_outlined),
        item(
          'Archive info and comment',
          info,
          icon: Icons.info_outline_rounded,
        ),
        if (m.root.archive.numVersions > 0)
          SubmenuButton(
            leadingIcon: const Icon(Icons.history_rounded, size: 18),
            menuChildren: [
              for (final v in m.root.allVersions.reversed)
                RadioMenuButton<int>(
                  value: v.number,
                  groupValue:
                      m.root.archive.version ?? m.root.archive.numVersions,
                  onChanged: (n) => showVersion(n ?? v.number),
                  child: Text(versionLabel(v, m.root.archive.numVersions)),
                ),
            ],
            child: const Text('Show version'),
          ),
        if (zx && _whyNotNewDb() == null)
          item('New database', newDatabase, icon: Icons.storage_rounded),
        if (zx && _whyNotDb() == null) ...[
          CheckboxMenuButton(
            value: _dataTab,
            onChanged: (v) => showData(v ?? false),
            child: const Text('Data view'),
          ),
          if (m.selectedItems.length == 1 && !m.selectedItems.first.isDir)
            item(
              'Find similar files',
              findSimilar,
              icon: Icons.compare_arrows_rounded,
            ),
          item(
            'Find by SHA-256...',
            findBySha,
            icon: Icons.fingerprint_rounded,
          ),
        ],
        if (m.parent != null)
          item(
            'Leave the nested archive',
            leaveNested,
            icon: Icons.arrow_upward_rounded,
          ),
      ],
      child: const Text('Archive'),
    );
  }

  /// Rows are converted when a visible tile is built, not eagerly for every
  /// entry in the folder.
  List<ViewItem> _itemsOf<T>(
    List<T> rows,
    Object key,
    ViewItem Function(T row) make,
  ) {
    if (identical(rows, _itemsRows) && key == _itemsKey) return _items;
    _itemsRows = rows;
    _itemsKey = key;
    return _items = _LazyViewItems(rows, make);
  }

  Object? _itemsRows;
  Object? _itemsKey;
  List<ViewItem> _items = const [];

  /// Details or icons, at the end of the header.
  Widget _viewToggle() {
    final grid = _s.settings.gridView;
    return IconButton(
      key: const Key('tool-view'),
      tooltip: grid ? 'Show the details list' : 'Show icons and thumbnails',
      visualDensity: VisualDensity.compact,
      onPressed: () => _s.settings.gridView = !grid,
      icon: Icon(
        grid ? Icons.view_list_rounded : Icons.grid_view_rounded,
        size: 20,
      ),
    );
  }

  /// Files | Data, above the view of an archive with a database.
  Widget _viewSwitch(ColorScheme cs) => Container(
    color: cs.surfaceContainerLow,
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    alignment: Alignment.centerLeft,
    child: SegmentedButton<bool>(
      key: const Key('view-switch'),
      showSelectedIcon: false,
      style: const ButtonStyle(visualDensity: VisualDensity.compact),
      segments: const [
        ButtonSegment(
          value: false,
          icon: Icon(Icons.folder_outlined, size: 16),
          label: Text('Files', key: Key('tab-files')),
        ),
        ButtonSegment(
          value: true,
          icon: Icon(Icons.storage_rounded, size: 16),
          label: Text('Data', key: Key('tab-data')),
        ),
      ],
      selected: {_dataTab},
      onSelectionChanged: (v) => showData(v.first),
    ),
  );

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

  /// The view of the folder shown: the file system or the archive, as
  /// details, icons or (a phone) large rows; the Data view of a .zx.
  /// Whether the README panel under the items is open (docs/readme.md).
  bool _readmeOpen = true;

  /// The items of the current folder, with its README below them (the
  /// archive's own description, docs/readme.md).
  Widget _mainView(bool narrow, ColorScheme cs) {
    final view = _mainListView(narrow, cs);
    final m = _model;
    if (m == null ||
        (_dataTab && _whyNotDb() == null) ||
        !_s.settings.showReadme ||
        m.filter.isNotEmpty) {
      return view;
    }
    final readme = m.archive.readmeIn(m.dir);
    if (readme == null) return view;
    final header = Material(
      color: cs.surfaceContainerLow,
      child: InkWell(
        key: const Key('readme-toggle'),
        onTap: () => _update(() => _readmeOpen = !_readmeOpen),
        child: SizedBox(
          height: 30,
          child: Row(
            children: [
              const SizedBox(width: 8),
              Icon(
                _readmeOpen
                    ? Icons.expand_more_rounded
                    : Icons.chevron_right_rounded,
                size: 18,
                color: cs.onSurfaceVariant,
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.menu_book_outlined,
                size: 16,
                color: cs.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  readme.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium!.copyWith(
                    color: cs.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              // the admin of a sealed archive (its seals are checked)
              FutureBuilder<List<ZxGenerationSeal>>(
                future: SealCache.of(m.root.archive),
                builder: (context, _) {
                  final admin = SealCache.admin(m.root.archive);
                  if (admin == null) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Tooltip(
                      message: 'The admin of this sealed archive\n$admin',
                      child: Text(
                        'maintained by ${shortNpub(admin)}',
                        key: const Key('readme-admin'),
                        style: TextStyle(
                          fontSize: 12,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(flex: 3, child: view),
        Divider(height: 1, color: cs.outlineVariant),
        header,
        if (_readmeOpen) ...[
          Divider(height: 1, color: cs.outlineVariant),
          Expanded(
            flex: 4,
            child: ReadmeView(
              key: ValueKey(('readme', m.archive, readme.path)),
              archive: m.archive,
              item: readme,
              onInternal: (t) => _readmeInternal(m, t),
              onExternal: _readmeExternal,
            ),
          ),
        ],
      ],
    );
  }

  /// A README link to an entry of the archive: a folder is opened, a file
  /// is selected (and so previewed).
  void _readmeInternal(ArchiveModel m, ReadmeInternal t) {
    final item = t.path.isEmpty ? null : m.archive[t.path];
    if (t.path.isEmpty || (item != null && item.isDir)) {
      m.navigate(t.path);
      return;
    }
    if (item == null) {
      _snack('${t.url}: not in the archive');
      return;
    }
    if (m.dir != item.parent) m.navigate(item.parent);
    m.selectPaths([item.path]);
  }

  /// A README link to another place: opened only after the reader agrees.
  Future<void> _readmeExternal(String url) async {
    final r = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.open_in_new_rounded),
        title: const Text('Open this link?'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: SelectableText(url, key: const Key('readme-link-url')),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'copy'),
            child: const Text('Copy'),
          ),
          FilledButton(
            key: const Key('readme-link-open'),
            onPressed: () => Navigator.pop(context, 'open'),
            child: const Text('Open'),
          ),
        ],
      ),
    );
    if (r == null || !mounted) return;
    if (r == 'open' && await _s.launcher.openUrl(url)) return;
    await Clipboard.setData(ClipboardData(text: url));
    if (mounted) _snack('Link copied');
  }

  Widget _mainListView(bool narrow, ColorScheme cs) {
    final m = _model;
    final grid = _s.settings.gridView;
    Widget withHint(Widget view, bool empty, String hint) => !empty
        ? view
        : Stack(
            children: [
              Positioned.fill(child: view),
              IgnorePointer(
                child: Center(
                  child: Text(
                    hint,
                    style: TextStyle(color: cs.onSurfaceVariant),
                  ),
                ),
              ),
            ],
          );
    Widget gridOf(List<ViewItem> items, Set<String> sel, ViewHandlers h) {
      final tile = narrow ? 104.0 : 116.0;
      return LayoutBuilder(
        builder: (context, box) {
          _gridColumns = ((box.maxWidth - 16) / (tile + 4)).ceil().clamp(1, 99);
          return ItemGrid(
            items: items,
            selection: sel,
            handlers: h,
            thumbnailCache: _thumbnails,
            tile: tile,
          );
        },
      );
    }

    if (m == null) {
      final items = _itemsOf(_fs.rows, (
        cs,
        _fs.inSearch,
        _fs.dir,
      ), (FsEntry e) => _fsItem(e, cs));
      final h = _fsHandlers(narrow: narrow);
      final hint = _fs.loading
          ? 'Reading...'
          : _fs.error ??
                (_fs.inSearch
                    ? (_fs.searching ? 'Searching...' : 'Nothing found')
                    : _fs.filter.isNotEmpty
                    ? 'No items match the filter'
                    : 'This folder is empty');
      if (grid) {
        return withHint(gridOf(items, _fs.selection, h), items.isEmpty, hint);
      }
      if (narrow) {
        return withHint(
          TileList(
            items: items,
            selection: _fs.selection,
            handlers: h,
            thumbnailCache: _thumbnails,
          ),
          items.isEmpty,
          hint,
        );
      }
      return FsDetailsList(model: _fs, items: items, handlers: h);
    }
    if (_dataTab && _whyNotDb() == null) {
      return DataView(
        session: _db!,
        picker: _s.picker,
        exportDirectory: p.dirname(m.root.archive.path),
      );
    }
    if (grid || narrow) {
      final items = _itemsOf(m.rows, (
        cs,
        m,
      ), (ZxItem i) => _archiveItem(m, i, cs));
      final h = _archiveHandlers(m, narrow: narrow);
      final hint = m.filter.isNotEmpty
          ? 'No items match the filter'
          : 'This folder is empty';
      return withHint(
        grid
            ? gridOf(items, m.selection, h)
            : TileList(
                items: items,
                selection: m.selection,
                handlers: h,
                thumbnailCache: _thumbnails,
              ),
        items.isEmpty,
        hint,
      );
    }
    return FileList(
      model: m,
      focusNode: _listFocus,
      onOpen: openItem,
      onContextMenu: _contextMenu,
      dragData: (i) => _archiveDrag(m, i.path, m.selection),
      onDrop: (folder, t) =>
          _dropTo(PasteDest.archive(m, folder?.path ?? m.dir), t),
    );
  }

  void _toggleRecursive() {
    _update(() => _recursive = !_recursive);
    final q = _fsFilter.text;
    if (_recursive) {
      _fs.filter = '';
      if (q.isNotEmpty) unawaited(_fs.startSearch(q));
    } else {
      _fs.stopSearch();
      _fs.filter = q;
    }
  }

  Widget _pathBar(bool narrow) {
    final m = _model;
    if (m != null) {
      return PathBar(
        model: m,
        filter: _filter,
        filterFocus: _filterFocus,
        onBack: back,
        onUp: up,
        onLevel: goToLevel,
        prefix: _fsCrumbs(p.dirname(m.root.archive.path), current: false),
        edit: _pathEdit,
        compact: narrow,
      );
    }
    final cs = Theme.of(context).colorScheme;
    return PathBarFrame(
      crumbs: _fsCrumbs(_fs.dir, current: true),
      edit: _pathEdit,
      compact: narrow,
      onBack: _fs.canBack ? back : null,
      onForward: _fs.canForward ? forward : null,
      onUp: _fs.canUp ? up : null,
      backTooltip: 'Back (Alt+Left)',
      upTooltip: 'Up one folder (Backspace)',
      filter: _fsFilter,
      filterFocus: _filterFocus,
      filterHint: _recursive
          ? 'Search below this folder (Enter)'
          : 'Filter this folder',
      filterActive: _fsFilter.text.isNotEmpty || _fs.inSearch,
      onFilter: (v) {
        if (!_recursive) {
          _fs.filter = v;
        } else if (v.isEmpty) {
          _fs.stopSearch();
        }
      },
      onFilterSubmit: (v) {
        if (_recursive) unawaited(_fs.startSearch(v));
        _listFocus.requestFocus();
      },
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(width: 4),
          IconButton(
            key: const Key('search-recursive'),
            isSelected: _recursive,
            tooltip: _recursive
                ? 'Searching below this folder: click to filter this folder only'
                : 'Search in the sub folders too',
            visualDensity: VisualDensity.compact,
            color: _recursive ? cs.primary : null,
            onPressed: _toggleRecursive,
            icon: const Icon(Icons.account_tree_outlined, size: 20),
          ),
          if (_fs.searching)
            IconButton(
              key: const Key('search-stop'),
              tooltip: 'Stop the search',
              visualDensity: VisualDensity.compact,
              onPressed: () => _fs.stopSearch(keepResults: true),
              icon: const Icon(Icons.stop_circle_outlined, size: 20),
            ),
        ],
      ),
    );
  }

  String get _fsTreeRoot =>
      p.isWithin(_s.paths.home, _fs.dir) || p.equals(_s.paths.home, _fs.dir)
      ? _s.paths.home
      : p.rootPrefix(p.normalize(_fs.dir));

  Widget _sidebar({bool drawer = false}) {
    final m = _model;
    void close() {
      if (drawer) _scaffoldKey.currentState?.closeDrawer();
    }

    if (!drawer) {
      final pane = _s.settings.leftPane;
      Widget selectedPane = switch (pane) {
        'indexer' => IndexerPanel(indexer: _indexer),
        'places' => Sidebar(
          places: _places,
          volumes: _volumes,
          bookmarks: _s.settings.bookmarks,
          recent: _s.settings.recent,
          current: m == null ? _fs.dir : null,
          onPlace: (path) {
            if (_model != null) _replaceModel(null);
            unawaited(_fs.navigate(path));
          },
          onArchive: (path) => unawaited(openArchive(path)),
          onRemoveBookmark: _s.settings.removeBookmark,
          onDrop: (path, t) => _dropTo(PasteDest.fs(path), t),
        ),
        _ when m != null && !_dataTab => FolderTree(model: m),
        _ when m != null => const Center(
          child: Text('No folder tree in this view'),
        ),
        _ => FsFolderTree(
          model: _fs,
          root: _fsTreeRoot,
          volumes: _volumes,
          showHidden: _s.settings.showHidden,
          onNavigate: (path) => unawaited(_fs.navigate(path)),
          onContextMenu: (entry, position) =>
              _fsContextMenu(entry, position, treeEntry: entry),
        ),
      };
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
            child: Row(
              children: [
                Icon(
                  Icons.view_sidebar_outlined,
                  size: 17,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('Left pane', style: TextStyle(fontSize: 12)),
                ),
                DropdownButton<String>(
                  key: const Key('left-pane-selector'),
                  value: pane,
                  underline: const SizedBox.shrink(),
                  isDense: true,
                  items: const [
                    DropdownMenuItem(value: 'tree', child: Text('Tree')),
                    DropdownMenuItem(value: 'places', child: Text('Places')),
                    DropdownMenuItem(value: 'indexer', child: Text('Indexer')),
                  ],
                  onChanged: (value) {
                    if (value != null) _s.settings.leftPane = value;
                  },
                ),
              ],
            ),
          ),
          Divider(
            height: 1,
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
          Expanded(child: selectedPane),
        ],
      );
    }
    return Sidebar(
      places: _places,
      volumes: _volumes,
      bookmarks: _s.settings.bookmarks,
      recent: _s.settings.recent,
      current: m == null ? _fs.dir : null,
      onPlace: (path) {
        close();
        if (_model != null) _replaceModel(null);
        unawaited(_fs.navigate(path));
      },
      onArchive: (path) {
        close();
        unawaited(openArchive(path));
      },
      onRemoveBookmark: _s.settings.removeBookmark,
      onDrop: drawer ? null : (path, t) => _dropTo(PasteDest.fs(path), t),
      bottom: !drawer && m != null && !_dataTab ? FolderTree(model: m) : null,
    );
  }

  /// The status bar texts of the file system view.
  (String, String) _fsStatus() {
    final rows = _fs.rows;
    final selection = _fs.selection;
    final left = _fs.searching
        ? 'Searching... ${rows.length} found'
        : selection.isEmpty
        ? '${rows.length} item${rows.length == 1 ? '' : 's'}'
              '${_fs.inSearch ? ' found' : ''}, ${formatBytes(_fs.rowsBytes)}'
        : '${selection.length} of ${rows.length} selected, '
              '${formatBytes(_fs.selectedBytes)}';
    // What the folder and the clipboard are, in the bar that never
    // moves: the actions of a folder live in its context menu.
    final folder = _indexer.folderSize(_fs.dir);
    final bits = <String>[
      if (folder != null) 'folder ${formatBytes(folder)}',
      if (_clip != null) 'clipboard ${_clip!.label}',
    ];
    final sp = _space;
    final right = sp == null
        ? ''
        : '${formatBytes(sp.free)} free of ${formatBytes(sp.total)}';
    return (bits.isEmpty ? left : '$left · ${bits.join(' · ')}', right);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _s.settings,
      builder: (context, _) => LayoutBuilder(
        builder: (context, box) {
          final narrow = box.maxWidth < 600;
          final page = narrow
              ? ListenableBuilder(
                  listenable: Listenable.merge([_fs, _s.settings]),
                  builder: (context, _) {
                    final model = _model;
                    return _NarrowPageModelListener(
                      model: model,
                      builder: () => _narrowPage(context),
                    );
                  },
                )
              : _WidePageModelListener(
                  model: _model,
                  builder: () => _widePage(context),
                );
          return Focus(
            autofocus: true,
            onKeyEvent: _onKey,
            child: DropTarget(
              onDragEntered: (_) => setState(() => _dragging = true),
              onDragExited: (_) => setState(() => _dragging = false),
              onDragDone: _onDrop,
              child: page,
            ),
          );
        },
      ),
    );
  }

  Widget _mainViewPane(bool narrow, ColorScheme cs) => ListenableBuilder(
    listenable: _model ?? _fs,
    builder: (context, _) => ListenableBuilder(
      listenable: _s.settings,
      builder: (context, _) => _mainView(narrow, cs),
    ),
  );

  Widget _actionBarPane(ColorScheme cs) => ListenableBuilder(
    listenable: _model ?? _fs,
    builder: (context, _) {
      final actions = _actionBar(cs);
      return actions == null
          ? const SizedBox.shrink()
          : ColoredBox(color: cs.surfaceContainerLow, child: actions);
    },
  );

  Widget _sidebarPane() => _sidebar();

  Widget _widePage(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final m = _model;
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  color: cs.surfaceContainerLow,
                  child: Row(
                    children: [
                      Expanded(
                        child: ListenableBuilder(
                          listenable: _fs,
                          builder: (context, _) => _pathBar(false),
                        ),
                      ),
                      _viewToggle(),
                      _appMenu(),
                      const SizedBox(width: 8),
                    ],
                  ),
                ),
                _actionBarPane(cs),
                Divider(height: 1, color: cs.outlineVariant),
                if (m != null && _whyNotDb() == null) ...[
                  _viewSwitch(cs),
                  Divider(height: 1, color: cs.outlineVariant),
                ],
                Expanded(
                  child: Row(
                    children: [
                      SizedBox(
                        width: _treeWidth,
                        child: ColoredBox(
                          color: cs.surfaceContainerLowest,
                          child: ListenableBuilder(
                            listenable: _s.settings,
                            builder: (context, _) => _sidebarPane(),
                          ),
                        ),
                      ),
                      _splitter(
                        (dx) => _treeWidth = (_treeWidth + dx).clamp(160, 520),
                      ),
                      Expanded(
                        child: Focus(
                          focusNode: _listFocus,
                          child: _mainViewPane(false, cs),
                        ),
                      ),
                      if (m != null &&
                          !_dataTab &&
                          _s.settings.showPreview) ...[
                        _splitter(
                          (dx) => _previewWidth = (_previewWidth - dx).clamp(
                            200,
                            720,
                          ),
                        ),
                        SizedBox(
                          width: _previewWidth,
                          child: PreviewPane(
                            model: m,
                            db: m.parent == null ? _db : null,
                            onInternalLink: (t) => _readmeInternal(m, t),
                            onExternalLink: _readmeExternal,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (m == null)
                  ListenableBuilder(
                    listenable: _fs,
                    builder: (context, _) {
                      final (left, right) = _fsStatus();
                      return StatusBar(
                        model: null,
                        message: _busy ? 'Working...' : null,
                        leftText: left,
                        rightText: right,
                      );
                    },
                  )
                else
                  StatusBar(
                    model: m,
                    message: _busy ? 'Working...' : null,
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SealBadge(archive: m.root.archive),
                        ?_versionPicker(m),
                      ],
                    ),
                  ),
              ],
            ),
            if (_dragging) _dropOverlay(cs),
          ],
        ),
      ),
    );
  }

  Widget _dropOverlay(ColorScheme cs) {
    final m = _model;
    return Positioned.fill(
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
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            decoration: BoxDecoration(
              color: cs.primary,
              borderRadius: BorderRadius.circular(24),
            ),
            child: Text(
              m == null
                  ? 'Drop to copy into ${p.basename(_fs.dir)}'
                  : _whyNot('add') == null
                  ? 'Drop to add to ${m.dir.isEmpty ? m.displayName : m.dir}'
                  : 'Drop an archive to open it',
              style: TextStyle(
                color: cs.onPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ---- the phone layout ----

  int get _selCount => _model?.selection.length ?? _fs.selection.length;

  void _clearSel() {
    final m = _model;
    if (m == null) {
      _fs.clearSelection();
    } else {
      m.clearSelection();
    }
  }

  /// The system back button of a phone: the selection, the search, then
  /// the history and the parent folders.
  void _narrowBack() {
    final m = _model;
    if (_selCount > 0) {
      _clearSel();
    } else if (_narrowSearch) {
      _closeNarrowSearch();
    } else if (m != null) {
      back();
    } else if (_fs.canBack) {
      back();
    } else if (_fs.canUp) {
      up();
    } else {
      unawaited(SystemNavigator.pop());
    }
  }

  void _closeNarrowSearch() {
    _update(() => _narrowSearch = false);
    _fsFilter.clear();
    _filter.clear();
    _fs.stopSearch();
    _fs.filter = '';
    _model?.filter = '';
  }

  String _narrowTitle() {
    final m = _model;
    if (m == null) {
      final b = p.basename(_fs.dir);
      return b.isEmpty ? _fs.dir : b;
    }
    if (m.dir.isEmpty) return m.displayName;
    return m.dir.substring(m.dir.lastIndexOf('/') + 1);
  }

  Widget _narrowPage(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final m = _model;
    final n = _selCount;
    final selecting = n > 0;
    final clip = _clip;
    PreferredSizeWidget appBar;
    if (selecting) {
      appBar = AppBar(
        key: const Key('selection-bar'),
        backgroundColor: cs.secondaryContainer,
        leading: IconButton(
          tooltip: 'Clear the selection',
          icon: const Icon(Icons.close_rounded),
          onPressed: _clearSel,
        ),
        title: Text('$n selected'),
        actions: [
          IconButton(
            key: const Key('select-all'),
            tooltip: 'Select all',
            icon: const Icon(Icons.select_all_rounded),
            onPressed: m?.selectAll ?? _fs.selectAll,
          ),
        ],
      );
    } else {
      final ctrl = m == null ? _fsFilter : _filter;
      appBar = AppBar(
        title: _narrowSearch
            ? TextField(
                key: const Key('narrow-search'),
                controller: ctrl,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: m == null
                      ? 'Search below this folder'
                      : 'Filter this folder',
                  border: InputBorder.none,
                ),
                textInputAction: TextInputAction.search,
                onChanged: (v) {
                  if (m != null) {
                    m.filter = v;
                  } else if (v.isEmpty) {
                    _fs.stopSearch();
                  }
                },
                onSubmitted: (v) {
                  if (m == null) unawaited(_fs.startSearch(v));
                },
              )
            : Text(_narrowTitle(), overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            key: const Key('narrow-search-button'),
            tooltip: _narrowSearch ? 'Close the search' : 'Search',
            icon: Icon(
              _narrowSearch ? Icons.close_rounded : Icons.search_rounded,
            ),
            onPressed: () => _narrowSearch
                ? _closeNarrowSearch()
                : _update(() => _narrowSearch = true),
          ),
          IconButton(
            key: const Key('nav-up'),
            tooltip: 'Up',
            icon: const Icon(Icons.arrow_upward_rounded),
            onPressed: m != null || _fs.canUp ? up : null,
          ),
          _narrowMenu(),
        ],
      );
    }
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _narrowBack();
      },
      child: Scaffold(
        key: _scaffoldKey,
        drawer: Drawer(
          key: const Key('drawer'),
          child: SafeArea(child: _sidebar(drawer: true)),
        ),
        appBar: appBar,
        body: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (m != null && _whyNotDb() == null) _viewSwitch(cs),
                _pathBar(true),
                Expanded(
                  child: Focus(
                    focusNode: _listFocus,
                    child: _mainView(true, cs),
                  ),
                ),
              ],
            ),
            if (_dragging) _dropOverlay(cs),
          ],
        ),
        bottomNavigationBar: selecting
            ? _selectionActions(cs)
            : clip != null
            ? _pasteBar(cs, clip)
            : null,
      ),
    );
  }

  Widget _narrowMenu() {
    final m = _model;
    final st = _s.settings;
    return PopupMenuButton<String>(
      key: const Key('narrow-menu'),
      tooltip: 'More',
      onSelected: (v) async {
        switch (v) {
          case 'folder':
            await (m == null ? newFolderFs() : newFolder());
          case 'view':
            st.gridView = !st.gridView;
          case 'hidden':
            _setShowHidden(!st.showHidden);
          case 'sort-name':
            _fs.sortBy(FsSort.name);
          case 'sort-size':
            _fs.sortBy(FsSort.size);
          case 'sort-modified':
            _fs.sortBy(FsSort.modified);
          case 'new':
            await newArchive();
          case 'open':
            await _openDialog();
          case 'extract':
            await extract();
          case 'info':
            await info();
          case 'close':
            closeArchive();
          case 'properties':
            await (m == null ? propertiesFs() : properties());
          case 'settings':
            await openSettings();
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem(
          value: 'folder',
          enabled: m == null || _whyNot('folder') == null,
          child: const Text('New folder'),
        ),
        PopupMenuItem(
          value: 'view',
          child: Text(st.gridView ? 'Show as list' : 'Show as grid'),
        ),
        CheckedPopupMenuItem(
          value: 'hidden',
          checked: st.showHidden,
          child: const Text('Show hidden folders and files'),
        ),
        if (m == null) ...[
          const PopupMenuDivider(),
          const PopupMenuItem(value: 'sort-name', child: Text('Sort by name')),
          const PopupMenuItem(value: 'sort-size', child: Text('Sort by size')),
          const PopupMenuItem(
            value: 'sort-modified',
            child: Text('Sort by date'),
          ),
        ],
        const PopupMenuDivider(),
        if (m != null) ...[
          const PopupMenuItem(value: 'extract', child: Text('Extract...')),
          const PopupMenuItem(value: 'info', child: Text('Archive info')),
          const PopupMenuItem(value: 'close', child: Text('Close archive')),
        ] else ...[
          const PopupMenuItem(value: 'new', child: Text('New archive...')),
          const PopupMenuItem(value: 'open', child: Text('Open archive...')),
        ],
        const PopupMenuItem(value: 'properties', child: Text('Properties')),
        const PopupMenuItem(value: 'settings', child: Text('Settings')),
      ],
    );
  }

  /// The actions of the selection on a phone.
  Widget _selectionActions(ColorScheme cs) {
    final m = _model;
    Widget action(String id, IconData icon, String label, VoidCallback? f) =>
        Expanded(
          child: InkWell(
            key: Key('sel-$id'),
            onTap: f,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, color: f == null ? cs.outline : cs.onSurface),
                const SizedBox(height: 2),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    color: f == null ? cs.outline : cs.onSurface,
                  ),
                ),
              ],
            ),
          ),
        );
    final one = _selCount == 1;
    return BottomAppBar(
      height: 64,
      padding: EdgeInsets.zero,
      child: Row(
        children: [
          action('copy', Icons.content_copy_rounded, 'Copy', copySelection),
          action(
            'cut',
            Icons.content_cut_rounded,
            'Cut',
            m == null || _whyNot('delete') == null
                ? () => copySelection(cut: true)
                : null,
          ),
          action(
            'delete',
            Icons.delete_outline_rounded,
            'Delete',
            m == null ? deleteFs : (_whyNot('delete') == null ? delete : null),
          ),
          action(
            'rename',
            Icons.drive_file_rename_outline_rounded,
            'Rename',
            !one
                ? null
                : m == null
                ? renameFs
                : (_whyNot('rename') == null ? rename : null),
          ),
          if (m == null && _s.places.canShare)
            action(
              'share',
              Icons.share_rounded,
              'Share',
              () => _s.places.share(_fs.selection.toList()),
            ),
          Expanded(
            child: Builder(
              builder: (bc) => InkWell(
                key: const Key('sel-more'),
                onTap: () {
                  final box = bc.findRenderObject() as RenderBox;
                  final pos = box.localToGlobal(Offset(box.size.width / 2, 0));
                  if (m == null) {
                    final sel = _fs.selectedEntries;
                    _fsContextMenu(sel.isEmpty ? null : sel.first, pos);
                  } else {
                    final sel = m.selectedItems;
                    _contextMenu(sel.isEmpty ? null : sel.first, pos);
                  }
                },
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.more_horiz_rounded, color: cs.onSurface),
                    const SizedBox(height: 2),
                    Text(
                      'More',
                      style: TextStyle(fontSize: 11, color: cs.onSurface),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// "3 items to copy  [Cancel] [Paste here]" at the bottom of a phone.
  Widget _pasteBar(ColorScheme cs, Transfer clip) {
    final why = _model == null ? null : _whyNot('add');
    return BottomAppBar(
      height: 64,
      child: Row(
        children: [
          Expanded(
            child: Text(
              '${clip.label} to ${clip.cut ? 'move' : 'copy'}',
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton(
            key: const Key('paste-cancel'),
            onPressed: () => _setClip(null),
            child: const Text('Cancel'),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            key: const Key('paste-here'),
            onPressed: why == null ? paste : null,
            icon: const Icon(Icons.content_paste_rounded, size: 18),
            label: const Text('Paste here'),
          ),
        ],
      ),
    );
  }
}
