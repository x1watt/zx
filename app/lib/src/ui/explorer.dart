// The file explorer side of the browser page: the file system folder
// (listing, open, open with), copy, cut and paste and drag and drop
// between the file system and the archives (extract, add), delete to the
// trash, rename, new folder, properties, compress and extract of archive
// files, the path typed in the path bar. Part of browser_page.dart.

part of 'browser_page.dart';

/// Where a paste or a drop goes: a folder of the file system or a folder
/// of an archive level.
class PasteDest {
  final String? fsDir;
  final ArchiveModel? model;
  final String dir;
  const PasteDest.fs(String this.fsDir) : model = null, dir = '';
  const PasteDest.archive(ArchiveModel this.model, this.dir) : fsDir = null;
}

/// Documents and programs that are zip files inside: opened with their
/// program from the file system too.
bool _opensOutside(String name) => _kOpenOutside.contains(extensionOf(name));

/// The explorer actions of the browser page (public for the tests).
extension ExplorerActions on BrowserPageState {
  AppServices get _sv => widget.services;

  bool get _trashAvailable =>
      (Platform.isLinux || Platform.isMacOS) && !Platform.isAndroid;

  String get _trashDir => p.join(_sv.paths.dataHome, 'Trash');

  // ---- places, free space ----

  Future<void> _loadPlaces() async {
    final pl = _sv.places;
    try {
      final a = await pl.places();
      final v = await pl.volumes();
      _update(() {
        _places = a;
        _volumes = v;
      });
    } on Object {
      // the sidebar stays with what it has
    }
  }

  void _onFsChanged() {
    final d = _fs.dir;
    if (d != _spaceDir) {
      _spaceDir = d;
      _sv.places.space(d).then((s) {
        if (_fs.dir == d) _update(() => _space = s);
      });
    }
  }

  // ---- items of the file system ----

  ViewItem _fsItem(FsEntry e, ColorScheme cs) {
    final (icon, color) = iconForName(
      e.name,
      cs,
      isDir: e.isDir,
      isLink: e.isLink && !e.isDir,
    );
    final showThumb =
        !e.isDir && isImageName(e.name) && e.size > 0 && e.size <= 40 << 20;
    final identity =
        '${p.normalize(e.path)}\n${e.size}\n${e.modified?.microsecondsSinceEpoch ?? 0}';
    return ViewItem(
      id: e.path,
      name: e.name,
      isDir: e.isDir,
      icon: icon,
      color: color,
      thumbnail: showThumb
          ? ThumbnailRequest(
              thumbnailKey(identity),
              () => readThumbnailFile(e.path, e.size),
            )
          : null,
      subtitle: _fs.inSearch && !e.isDir
          ? p.relative(e.path, from: _fs.dir)
          : [
              if (e.isDir && _fs.sizeOf(e) > 0) formatBytes(_fs.sizeOf(e)),
              if (!e.isDir) formatBytes(e.size),
              formatDate(e.modified),
            ].join('   '),
    );
  }

  FsEntry? _fsEntry(String id) => _fs.entry(id);

  ViewHandlers _fsHandlers({required bool narrow}) {
    final selecting = narrow && _fs.selection.isNotEmpty;
    return ViewHandlers(
      selectionMode: selecting,
      touchOpens: narrow,
      onClick: (id, {ctrl = false, shift = false}) {
        _listFocus.requestFocus();
        final e = _fsEntry(id);
        if (e != null) _fs.click(e, ctrl: ctrl, shift: shift);
      },
      onOpen: (id) {
        final e = _fsEntry(id);
        if (e != null) openFsEntry(e);
      },
      onContextMenu: (id, pos) {
        final e = id == null ? null : _fsEntry(id);
        if (e != null) _fs.ensureSelected(e);
        _fsContextMenu(e, pos);
      },
      onLongPress: narrow
          ? (id) {
              final e = _fsEntry(id);
              if (e != null) _fs.toggle(e);
            }
          : null,
      dragData: narrow
          ? null
          : (id) => Transfer.files(
              _fs.selection.contains(id) ? _fs.selection.toList() : [id],
            ),
      onDrop: (id, t) => _dropTo(PasteDest.fs(id ?? _fs.dir), t),
      onBackgroundTap: () {
        _listFocus.requestFocus();
        _fs.clearSelection();
      },
    );
  }

  ViewHandlers _archiveHandlers(ArchiveModel m, {required bool narrow}) {
    return ViewHandlers(
      selectionMode: narrow && m.selection.isNotEmpty,
      touchOpens: narrow,
      onClick: (id, {ctrl = false, shift = false}) {
        _listFocus.requestFocus();
        final i = m.item(id);
        if (i != null) m.click(i, ctrl: ctrl, shift: shift);
      },
      onOpen: (id) {
        final i = m.item(id);
        if (i != null) openItem(i);
      },
      onContextMenu: (id, pos) {
        final i = id == null ? null : m.item(id);
        if (i != null) m.ensureSelected(i);
        _contextMenu(i, pos);
      },
      onLongPress: narrow
          ? (id) {
              final i = m.item(id);
              if (i != null) m.click(i, ctrl: true);
            }
          : null,
      dragData: narrow ? null : (id) => _archiveDrag(m, id),
      onDrop: (id, t) => _dropTo(PasteDest.archive(m, id ?? m.dir), t),
      onBackgroundTap: () {
        _listFocus.requestFocus();
        m.clearSelection();
      },
    );
  }

  Transfer _archiveDrag(ArchiveModel m, String id) => Transfer.archive(
    m,
    m.selection.contains(id) ? m.selection.toList() : [id],
    m.dir,
  );

  ViewItem _archiveItem(ArchiveModel m, ZxItem i, ColorScheme cs) {
    final (icon, color) = iconFor(i, cs, inContainer: m.inContainer(i));
    final showThumb =
        !i.isDir &&
        isImageName(i.name) &&
        i.size != null &&
        i.size! > 0 &&
        i.size! <= 40 << 20;
    final identity = i.sha256 == null
        ? '${m.root.archive.path}\n${m.root.archive.numVersions}\n${m.root.archive.physicalSize}\n${m.archive.path}\n${m.archive.version}\n${i.path}\n${i.size ?? 0}\n${i.crc ?? 0}\n${i.modified?.microsecondsSinceEpoch ?? 0}'
        : 'sha256:${i.sha256}:${extensionOf(i.name)}';
    return ViewItem(
      id: i.path,
      name: i.name,
      isDir: i.isDir,
      icon: icon,
      color: color,
      thumbnail: showThumb
          ? ThumbnailRequest(
              thumbnailKey(identity),
              () => m.archive
                  .readBytes(i, maxBytes: 40 << 20)
                  .catchError((Object _) => Uint8List(0)),
            )
          : null,
      subtitle: [
        if (!i.isDir) formatBytes(m.sizeOf(i)),
        formatDate(i.modified),
      ].where((s) => s.isNotEmpty).join('   '),
    );
  }

  // ---- open ----

  /// Opens [e]: a folder is entered, an archive (by its name: every
  /// format of zx, disk images and firmware) opens as a folder, any
  /// other file opens with its default program.
  Future<void> openFsEntry(FsEntry e) async {
    if (e.isDir) {
      await _fs.navigate(e.path);
      return;
    }
    if (!_opensOutside(e.name) &&
        (looksLikeArchive(e.name) || isDiskImageName(e.name))) {
      await openArchive(e.path);
      return;
    }
    await _launchFile(e.path, e.name);
  }

  Future<void> _launchFile(String path, String name) async {
    try {
      await _sv.launcher.openFile(path);
    } on ProcessException catch (e) {
      if (mounted) {
        await showErrorDialog(
          context,
          title: 'Open $name',
          message: 'No program could open it: ${e.message}',
        );
      }
    }
  }

  /// "Open with...": the chooser of the system, or the list of programs.
  Future<void> openWith(String path) async {
    final pl = _sv.places;
    if (await pl.openWithChooser(path)) return;
    final apps = await pl.appsFor(path);
    if (!mounted) return;
    final a = await showOpenWithDialog(context, p.basename(path), apps);
    if (a != null) await pl.openWith(a, path);
  }

  /// Leaves the archive shown for the folder of the file system that
  /// holds it, with the archive selected.
  Future<void> _exitToFs() async {
    final m = _model;
    if (m == null) return;
    final path = m.root.archive.path;
    _replaceModel(null);
    await _fs.navigate(p.dirname(path));
    _fs.selectPaths([path]);
    _listFocus.requestFocus();
  }

  /// A path typed in the path bar: a folder is shown, an archive opens
  /// (a path that goes on inside an archive opens it at that folder),
  /// another file opens with its program.
  Future<void> goToPath(String text) async {
    if (text.isEmpty) return;
    var path = text.startsWith('~')
        ? p.join(_sv.paths.home, text.substring(1).replaceFirst('/', ''))
        : p.absolute(text);
    path = p.normalize(path);
    if (await FileSystemEntity.isDirectory(path)) {
      if (_model != null) _replaceModel(null);
      await _fs.navigate(path);
      return;
    }
    // the longest part that is a file: an archive, the rest a folder in it
    var f = path;
    while (!await FileSystemEntity.isFile(f)) {
      final up = p.dirname(f);
      if (up == f) {
        if (mounted) {
          await showErrorDialog(
            context,
            title: 'Go to',
            message: '$path does not exist.',
          );
        }
        return;
      }
      f = up;
    }
    final rest = p.relative(path, from: f);
    if (f == path && (_opensOutside(f) || !looksLikeArchive(f))) {
      await _launchFile(f, p.basename(f));
      return;
    }
    await openArchive(f, dir: rest == '.' ? null : rest.replaceAll(r'\', '/'));
  }

  /// The text of the editable path: the folder, or the archive file
  /// followed by the nested items and the folder inside.
  String _pathText() {
    final m = _model;
    if (m == null) return _fs.dir;
    return p.joinAll([
      m.root.archive.path,
      for (final l in m.levels.skip(1)) l.entry!.path,
      if (m.dir.isNotEmpty) m.dir,
    ]);
  }

  /// The crumbs of the folders of [dir]: `/ > home > user`.
  List<Widget> _fsCrumbs(String dir, {required bool current}) {
    final out = <Widget>[];
    final root = _fsTreeRoot;
    var path = p.rootPrefix(p.normalize(dir));
    final levels = <(String, String)>[(path, path)];
    for (final part in p.split(dir).skip(1)) {
      path = p.join(path, part);
      levels.add((path, part));
    }
    for (var i = 0; i < levels.length; i++) {
      final (levelPath, part) = levels[i];
      if (i > 0) out.add(crumbSeparator(context));
      final isHome = levelPath == _sv.paths.home;
      final label = p.equals(levelPath, root)
          ? (p.equals(root, _sv.paths.home)
                ? 'Home'
                : p.basename(root).isEmpty
                ? root
                : p.basename(root))
          : part;
      out.add(
        crumbButton(
          context,
          key: Key('fscrumb:$levelPath'),
          label: label,
          icon: p.equals(levelPath, root)
              ? (p.equals(root, _sv.paths.home)
                    ? Icons.home_rounded
                    : Icons.storage_rounded)
              : isHome
              ? Icons.home_rounded
              : null,
          iconColor: Theme.of(context).colorScheme.primary,
          current: current && i == levels.length - 1,
          onTap: () async {
            if (_model != null) _replaceModel(null);
            await _fs.navigate(levelPath);
          },
        ),
      );
    }
    if (!current) out.add(crumbSeparator(context));
    return out;
  }

  // ---- clipboard ----

  /// Keeps [t] (the levels of its archive stay open until it is
  /// replaced).
  void _setClip(Transfer? t) {
    final old = _clip;
    _update(() => _clip = t);
    final om = old?.model;
    if (om != null && om != t?.model) {
      final keep = _model?.levels.toSet() ?? const <ArchiveModel>{};
      for (ArchiveModel? l = om; l != null; l = l.parent) {
        if (keep.contains(l)) break;
        unawaited(l.closeHandles().catchError((Object _) {}));
      }
    }
  }

  /// Copy (or cut) the selection of the view shown.
  void copySelection({bool cut = false}) {
    final m = _model;
    Transfer t;
    if (m == null) {
      if (_fs.selection.isEmpty) return;
      t = Transfer.files(_fs.selection.toList(), cut: cut);
    } else {
      if (m.selection.isEmpty) return;
      if (cut && _whyNot('delete') != null) {
        _snack('Can not cut here: ${_whyNot('delete')}');
        return;
      }
      t = Transfer.archive(m, m.selection.toList(), m.dir, cut: cut);
    }
    _setClip(t);
    _snack('${cut ? 'Cut' : 'Copied'} ${t.label}');
  }

  /// Pastes into the folder shown (or into [into]).
  Future<void> paste({PasteDest? into}) async {
    final t = _clip;
    if (t == null) return;
    final m = _model;
    final d =
        into ??
        (m == null ? PasteDest.fs(_fs.dir) : PasteDest.archive(m, m.dir));
    final ok = await _transfer(t, d, move: t.cut);
    if (ok && t.cut) _setClip(null);
  }

  /// A drop from the app's own views: a move between folders of the file
  /// system (a copy with Ctrl held), a copy otherwise.
  Future<void> _dropTo(PasteDest d, Transfer t) async {
    final ctrl = HardwareKeyboard.instance.isControlPressed;
    final move = !t.fromArchive && d.fsDir != null && !ctrl;
    if (d.fsDir != null && !t.fromArchive) {
      // a drop on the folder the files are in does nothing
      if (t.fsPaths.every((s) => p.equals(p.dirname(s), d.fsDir!)) && move) {
        return;
      }
    }
    await _transfer(t, d, move: move);
  }

  Future<FsConflictAnswer> _askConflict(FsConflict c) async {
    if (!mounted) return const FsConflictAnswer(FsConflictAction.cancel);
    return showFsConflictDialog(context, c);
  }

  /// Copies or moves [t] to [d]: between folders, extract (archive to
  /// folder), add (folder to archive) or both through a temporary folder
  /// (archive to archive). True when it was done.
  Future<bool> _transfer(Transfer t, PasteDest d, {required bool move}) async {
    if (t.isEmpty) return false;
    final fsDir = d.fsDir;
    if (fsDir != null) {
      if (!t.fromArchive) return _fsCopy(t.fsPaths, fsDir, move: move);
      return _extractTo(t, fsDir, move: move);
    }
    final m = d.model!;
    if (m != _model) return false;
    final why = _whyNot('add');
    if (why != null) {
      _snack('Can not add here: $why');
      return false;
    }
    if (!t.fromArchive) {
      return _addTo(m, d.dir, t.fsPaths, moveFrom: move ? t.fsPaths : null);
    }
    // archive to archive: through a temporary folder
    final tmp = p.join(
      _sv.paths.temp,
      'zx-transfer-${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      await Directory(tmp).create(recursive: true);
      final ok = await _extractTo(t, tmp, move: false, quiet: true);
      if (!ok) return false;
      final sources = [await for (final e in Directory(tmp).list()) e.path];
      final added = await _addTo(m, d.dir, sources);
      if (added && move) await _deleteFromArchive(t);
      return added;
    } finally {
      unawaited(
        Directory(tmp).delete(recursive: true).then((_) {}, onError: (_) {}),
      );
    }
  }

  Future<bool> _fsCopy(
    List<String> sources,
    String dest, {
    required bool move,
  }) async {
    final label = sources.length == 1
        ? '"${p.basename(sources.first)}"'
        : '${sources.length} items';
    final r = await _guard(move ? 'Move' : 'Copy', () {
      return runWithProgress(context, '${move ? 'Moving' : 'Copying'} $label', (
        pr,
      ) {
        return runFsOp(
          move ? FsOpKind.move : FsOpKind.copy,
          sources,
          destDir: dest,
          onProgress: pr.update,
          onConflict: _askConflict,
          cancel: pr.cancel,
        );
      });
    });
    if (r == null) {
      await _fs.reload();
      return false;
    }
    await _fs.reload(select: p.equals(dest, _fs.dir) ? r.created : null);
    await _showFsErrors(move ? 'Move' : 'Copy', r);
    return r.ok;
  }

  Future<void> _showFsErrors(String title, FsOpResult r) async {
    if (r.errors.isEmpty || !mounted) return;
    await showErrorDialog(
      context,
      title:
          '$title: ${r.errors.length} error${r.errors.length == 1 ? '' : 's'}',
      message: r.errors.take(20).join('\n'),
    );
  }

  /// Extracts the archive items of [t] into the folder [dest], keeping
  /// their paths below the folder they were taken from.
  Future<bool> _extractTo(
    Transfer t,
    String dest, {
    required bool move,
    bool quiet = false,
  }) async {
    final m = t.model!;
    final r = await _guard('Extract', () async {
      await Directory(dest).create(recursive: true);
      if (!mounted) return null;
      return runWithProgress(context, 'Extracting ${t.label}', (pr) {
        return m.archive.extract(
          dest,
          items: t.items,
          keepPaths: true,
          relativeTo: t.relDir.isEmpty ? null : t.relDir,
          overwrite: ZxOverwrite.ask,
          onOverwrite: _askOverwrite,
          onProgress: pr.update,
          cancel: pr.cancel,
        );
      });
    });
    if (r == null || !mounted) return false;
    if (!r.ok) {
      await showExtractResultDialog(
        context,
        title: 'Extracted with errors',
        result: r,
      );
      return false;
    }
    if (move) await _deleteFromArchive(t);
    if (!quiet) {
      final names = [
        for (final i in t.items) p.join(dest, _relName(i, t.relDir)),
      ];
      await _fs.reload(select: p.equals(dest, _fs.dir) ? names : null);
      _snack(
        'Extracted ${r.files} file${r.files == 1 ? '' : 's'}'
        '${r.skipped > 0 ? ' (${r.skipped} skipped)' : ''}',
      );
    }
    return true;
  }

  static String _relName(String item, String relDir) {
    final s = relDir.isEmpty ? item : item.substring(relDir.length + 1);
    final k = s.indexOf('/');
    return k < 0 ? s : s.substring(0, k);
  }

  Future<void> _deleteFromArchive(Transfer t) async {
    final m = t.model!;
    if (m.readOnlyReason != null || !m.archive.capabilities.canDelete) return;
    final r = await _guard('Move', () {
      return runWithProgress(
        context,
        'Deleting the moved items',
        (pr) =>
            m.archive.delete(t.items, onProgress: pr.update, cancel: pr.cancel),
      );
    });
    if (r != null) m.refresh(select: const []);
  }

  /// Adds [sources] into [dir] of [m] with the default settings (no
  /// dialog: the settings are asked for new archives only); names that
  /// exist are asked for. [moveFrom]: deleted after the add.
  Future<bool> _addTo(
    ArchiveModel m,
    String dir,
    List<String> sources, {
    List<String>? moveFrom,
  }) async {
    final have = {for (final i in m.archive.children(dir)) i.name};
    final keep = <String>[];
    FsConflictAnswer? all;
    for (final s in sources) {
      final name = p.basename(s);
      if (!have.contains(name)) {
        keep.add(s);
        continue;
      }
      final isDir = await FileSystemEntity.isDirectory(s);
      if (!mounted) return false;
      final a =
          all ??
          await showFsConflictDialog(
            context,
            FsConflict(
              s,
              dir.isEmpty ? name : '$dir/$name',
              isDir,
              m.archive[dir.isEmpty ? name : '$dir/$name']?.isDir ?? false,
            ),
            allowRename: false,
          );
      if (a.all) all = a;
      if (a.action == FsConflictAction.cancel) return false;
      if (a.action == FsConflictAction.overwrite) keep.add(s);
      if (!mounted) return false;
    }
    if (keep.isEmpty) return false;
    final fmt =
        formatForArchive(m.archive.format, m.archive.outerFormats) ??
        newFormatById('7z');
    final options = CompressionSettings(
      level: _sv.settings.defaultLevel,
      zx: _sv.settings.zxCompression,
    ).toOptions(fmt, allowPassword: false);
    final res = await _guard('Add', () {
      return runWithProgress(
        context,
        'Adding to ${p.basename(m.archive.path)}',
        (pr) => m.archive.add(
          [for (final s in keep) ZxSource(s)],
          destination: dir,
          options: options,
          onProgress: pr.update,
          cancel: pr.cancel,
        ),
      );
    });
    if (res == null || !mounted) return false;
    m.refresh(
      select: dir == m.dir
          ? [
              for (final s in keep)
                dir.isEmpty ? p.basename(s) : '$dir/${p.basename(s)}',
            ]
          : null,
    );
    if (moveFrom != null) {
      await runFsOp(FsOpKind.delete, [
        for (final s in moveFrom)
          if (keep.contains(s)) s,
      ]);
      await _fs.reload();
    }
    _snack('Added ${res.added} item${res.added == 1 ? '' : 's'}');
    return true;
  }

  /// Files dropped from another program on the file system view: copied
  /// into the folder shown.
  Future<void> _dropFromOs(List<String> paths) =>
      _fsCopy(paths, _fs.dir, move: false);

  // ---- file operations ----

  /// Moves the selection to the trash ([permanent]: deletes it).
  Future<void> deleteFs({bool permanent = false}) async {
    final sel = _fs.selectedEntries;
    if (sel.isEmpty) return;
    final what = sel.length == 1
        ? '"${sel.first.name}"'
        : '${sel.length} items';
    final trash = !permanent && _trashAvailable;
    if (!trash || _sv.settings.confirmDelete) {
      final ok = await showConfirmDialog(
        context,
        title: trash ? 'Move to the trash' : 'Delete permanently',
        message: trash
            ? 'Move $what to the trash?'
            : 'Delete $what permanently? This can not be undone.',
        ok: trash ? 'Move to trash' : 'Delete',
        destructive: !trash,
      );
      if (!ok || !mounted) return;
    }
    final paths = [for (final e in sel) e.path];
    final r = await _guard('Delete', () {
      return runWithProgress(
        context,
        trash ? 'Moving to the trash' : 'Deleting',
        (pr) {
          return runFsOp(
            trash ? FsOpKind.trash : FsOpKind.delete,
            paths,
            trashDir: _trashDir,
            macTrash: Platform.isMacOS,
            onProgress: pr.update,
            cancel: pr.cancel,
          );
        },
      );
    });
    if (r != null && r.notTrashed.isNotEmpty && mounted) {
      final ok = await showConfirmDialog(
        context,
        title: 'Delete permanently',
        message:
            '${r.notTrashed.length} item${r.notTrashed.length == 1 ? '' : 's'} '
            'can not be moved to the trash (another drive). Delete '
            'permanently? This can not be undone.',
        ok: 'Delete',
        destructive: true,
      );
      if (ok && mounted) {
        await _guard('Delete', () => runFsOp(FsOpKind.delete, r.notTrashed));
      }
    }
    await _fs.reload();
    if (r != null) await _showFsErrors('Delete', r);
  }

  Future<void> renameFs() async {
    final sel = _fs.selectedEntries;
    if (sel.length != 1) return;
    final e = sel.first;
    final siblings = {for (final r in _fs.rows) r.name};
    final n = await showTextInputDialog(
      context,
      title: 'Rename',
      label: 'New name',
      initial: e.name,
      ok: 'Rename',
      selectStem: !e.isDir,
      validate: (v) => v.contains('/') || v.contains('\\')
          ? 'A name can not contain / or \\'
          : v != e.name && siblings.contains(v)
          ? '"$v" exists already'
          : null,
    );
    if (n == null || n == e.name || !mounted) return;
    final to = p.join(p.dirname(e.path), n);
    await _guard('Rename', () async {
      final t = await FileSystemEntity.type(e.path, followLinks: false);
      await (t == FileSystemEntityType.directory
              ? Directory(e.path) as FileSystemEntity
              : t == FileSystemEntityType.link
              ? Link(e.path)
              : File(e.path))
          .rename(to);
    });
    await _fs.reload(select: [to]);
  }

  Future<void> newFolderFs() async {
    final siblings = {for (final r in _fs.rows) r.name};
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
    final path = p.join(_fs.dir, n);
    await _guard('New folder', () => Directory(path).create());
    await _fs.reload(select: [path]);
  }

  Future<void> propertiesFs() async {
    var sel = _fs.selectedEntries;
    if (sel.isEmpty) {
      final e = await statEntry(_fs.dir);
      if (e == null) return;
      sel = [e];
    }
    if (!mounted) return;
    await showFsPropertiesDialog(context, sel);
  }

  void pinFolder(String path) {
    _sv.settings.addBookmark(path);
    _snack('Pinned ${p.basename(path)} to the sidebar');
  }

  /// "Compress to .zx...": the new archive dialog with the selection.
  Future<void> compressFs({String format = 'zx'}) async {
    final sel = _fs.selection.toList();
    if (sel.isEmpty) return;
    await newArchive(sources: sel, formatId: format, show: false);
  }

  Future<ZxExtractResult?> _extractArchiveFile(String path, String dest) {
    return _guard<ZxExtractResult?>('Extract ${p.basename(path)}', () async {
      await Directory(dest).create(recursive: true);
      if (!mounted) return null;
      return runWithProgress<ZxExtractResult?>(
        context,
        'Extracting ${p.basename(path)}',
        (pr) async {
          final a = await ZxArchive.open(
            path,
            onPassword: _askPassword,
            cancel: pr.cancel,
          );
          try {
            return await a.extract(
              dest,
              overwrite: ZxOverwrite.ask,
              onOverwrite: _askOverwrite,
              onProgress: pr.update,
              cancel: pr.cancel,
            );
          } finally {
            await a.close();
          }
        },
      );
    });
  }

  /// "Extract here" ([toFolder] false) or "Extract to folder" (a new
  /// folder named after the archive) of the selected archive files.
  Future<void> extractFsArchives({
    bool toFolder = true,
    bool pick = false,
  }) async {
    final sel = [
      for (final e in _fs.selectedEntries)
        if (!e.isDir) e.path,
    ];
    if (sel.isEmpty) return;
    String? picked;
    if (pick) {
      picked = await _sv.picker.pickFolder(
        initialDirectory: _fs.dir,
        title: 'Extract here',
      );
      if (picked == null) return;
    }
    final created = <String>[];
    for (final a in sel) {
      final dest =
          picked ??
          (toFolder
              ? await uniqueFolder(p.dirname(a), folderNameFor(p.basename(a)))
              : p.dirname(a));
      final r = await _extractArchiveFile(a, dest);
      if (r == null || !mounted) break;
      if (!r.ok) {
        await showExtractResultDialog(
          context,
          title: 'Extracted with errors',
          result: r,
        );
      }
      if (toFolder || picked != null) created.add(dest);
    }
    await _fs.reload(select: created.isEmpty ? null : created);
  }

  // ---- context menu ----

  Future<void> _fsContextMenu(FsEntry? e, Offset pos) async {
    final sel = _fs.selectedEntries;
    final hasSel = e != null && sel.isNotEmpty;
    final archives = [
      for (final s in sel)
        if (!s.isDir && (looksLikeArchive(s.name) || isDiskImageName(s.name)))
          s,
    ];
    final clip = _clip;
    final items = <PopupMenuEntry<String>>[
      if (e != null) ...[
        _menuEntry(
          'open',
          e.isDir ? Icons.folder_open_rounded : Icons.open_in_new_rounded,
          e.isDir ? 'Open' : 'Open',
          shortcut: 'Enter',
        ),
        if (!e.isDir) ...[
          _menuEntry('open-with', Icons.apps_rounded, 'Open with...'),
          _menuEntry(
            'open-archive',
            Icons.folder_zip_outlined,
            'Open as archive',
          ),
        ],
      ],
      if (archives.isNotEmpty) ...[
        const PopupMenuDivider(),
        _menuEntry(
          'extract-folder',
          Icons.unarchive_outlined,
          archives.length == 1
              ? 'Extract to "${folderNameFor(archives.first.name)}/"'
              : 'Extract each to its folder',
        ),
        _menuEntry(
          'extract-here',
          Icons.drive_folder_upload_outlined,
          'Extract here',
        ),
        _menuEntry('extract-to', Icons.folder_copy_outlined, 'Extract to...'),
      ],
      if (hasSel) ...[
        const PopupMenuDivider(),
        _menuEntry('compress', Icons.archive_outlined, 'Compress to .zx...'),
        _menuEntry(
          'compress-other',
          Icons.inventory_2_outlined,
          'Compress to other format...',
        ),
        const PopupMenuDivider(),
        _menuEntry('cut', Icons.content_cut_rounded, 'Cut', shortcut: 'Ctrl+X'),
        _menuEntry(
          'copy',
          Icons.content_copy_rounded,
          'Copy',
          shortcut: 'Ctrl+C',
        ),
      ],
      _menuEntry(
        'paste',
        Icons.content_paste_rounded,
        e != null && e.isDir && sel.length == 1 ? 'Paste into folder' : 'Paste',
        why: clip == null ? 'Nothing to paste' : null,
        shortcut: 'Ctrl+V',
      ),
      if (hasSel) ...[
        _menuEntry('copy-path', Icons.link_rounded, 'Copy path'),
        if (sel.length == 1 && e.isDir)
          _menuEntry('pin', Icons.push_pin_outlined, 'Pin to sidebar'),
        if (_sv.places.canShare)
          _menuEntry('share', Icons.share_rounded, 'Share'),
        const PopupMenuDivider(),
        _menuEntry(
          'rename',
          Icons.drive_file_rename_outline_rounded,
          'Rename',
          why: sel.length == 1 ? null : 'Select one item to rename',
          shortcut: 'F2',
        ),
        _menuEntry(
          'delete',
          Icons.delete_outline_rounded,
          _trashAvailable ? 'Move to trash' : 'Delete',
          shortcut: 'Del',
        ),
        if (_trashAvailable)
          _menuEntry(
            'delete-permanent',
            Icons.delete_forever_outlined,
            'Delete permanently',
            shortcut: 'Shift+Del',
          ),
      ] else ...[
        _menuEntry('folder', Icons.create_new_folder_outlined, 'New folder'),
        _menuEntry('select-all', Icons.select_all_rounded, 'Select all'),
        _menuEntry('refresh', Icons.refresh_rounded, 'Refresh', shortcut: 'F5'),
      ],
      const PopupMenuDivider(),
      _menuEntry('properties', Icons.description_outlined, 'Properties'),
    ];
    final v = await _showMenuAt(pos, items);
    switch (v) {
      case 'open':
        if (e != null) await openFsEntry(e);
      case 'open-with':
        if (e != null) await openWith(e.path);
      case 'open-archive':
        if (e != null) await openArchive(e.path);
      case 'extract-folder':
        await extractFsArchives();
      case 'extract-here':
        await extractFsArchives(toFolder: false);
      case 'extract-to':
        await extractFsArchives(pick: true);
      case 'compress':
        await compressFs();
      case 'compress-other':
        await compressFs(
          format: _sv.settings.defaultFormat == 'zx'
              ? 'zip'
              : _sv.settings.defaultFormat,
        );
      case 'cut':
        copySelection(cut: true);
      case 'copy':
        copySelection();
      case 'paste':
        await paste(
          into: e != null && e.isDir && sel.length == 1
              ? PasteDest.fs(e.path)
              : null,
        );
      case 'copy-path':
        await Clipboard.setData(
          ClipboardData(text: sel.map((x) => x.path).join('\n')),
        );
      case 'pin':
        if (e != null) pinFolder(e.path);
      case 'share':
        await _sv.places.share([for (final x in sel) x.path]);
      case 'rename':
        await renameFs();
      case 'delete':
        await deleteFs();
      case 'delete-permanent':
        await deleteFs(permanent: true);
      case 'folder':
        await newFolderFs();
      case 'select-all':
        _fs.selectAll();
      case 'refresh':
        await _fs.reload();
      case 'properties':
        await propertiesFs();
    }
  }

  PopupMenuItem<String> _menuEntry(
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

  Future<String?> _showMenuAt(Offset pos, List<PopupMenuEntry<String>> items) {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    return showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        pos & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: items,
    );
  }

  // ---- keyboard of the file system view ----

  bool _fsKey(LogicalKeyboardKey k, {required bool ctrl, required bool alt}) {
    final kb = HardwareKeyboard.instance;
    final shift = kb.isShiftPressed;
    if (ctrl && k == LogicalKeyboardKey.keyA) {
      _fs.selectAll();
    } else if (ctrl && k == LogicalKeyboardKey.keyC) {
      copySelection();
    } else if (ctrl && k == LogicalKeyboardKey.keyX) {
      copySelection(cut: true);
    } else if (ctrl && k == LogicalKeyboardKey.keyV) {
      paste();
    } else if (k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.numpadEnter) {
      if (alt) {
        propertiesFs();
      } else {
        final sel = _fs.selectedEntries;
        if (sel.length == 1) {
          openFsEntry(sel.first);
        } else if (sel.isEmpty && _fs.cursorIndex >= 0) {
          openFsEntry(_fs.rows[_fs.cursorIndex]);
        }
      }
    } else if (k == LogicalKeyboardKey.backspace) {
      up();
    } else if (k == LogicalKeyboardKey.delete) {
      deleteFs(permanent: shift);
    } else if (k == LogicalKeyboardKey.f2) {
      renameFs();
    } else if (k == LogicalKeyboardKey.arrowDown) {
      _fs.moveSelection(_gridStep(1), shift: shift);
    } else if (k == LogicalKeyboardKey.arrowUp) {
      _fs.moveSelection(_gridStep(-1), shift: shift);
    } else if (k == LogicalKeyboardKey.arrowRight && _sv.settings.gridView) {
      _fs.moveSelection(1, shift: shift);
    } else if (k == LogicalKeyboardKey.arrowLeft && _sv.settings.gridView) {
      _fs.moveSelection(-1, shift: shift);
    } else if (k == LogicalKeyboardKey.pageDown) {
      _fs.moveSelection(20, shift: shift);
    } else if (k == LogicalKeyboardKey.pageUp) {
      _fs.moveSelection(-20, shift: shift);
    } else if (k == LogicalKeyboardKey.home) {
      _fs.moveSelection(-1 << 30, shift: shift);
    } else if (k == LogicalKeyboardKey.end) {
      _fs.moveSelection(1 << 30, shift: shift);
    } else if (k == LogicalKeyboardKey.escape) {
      if (_fs.inSearch) {
        _fs.stopSearch();
        _fsFilter.clear();
      } else if (_fs.filter.isNotEmpty) {
        _fs.filter = '';
        _fsFilter.clear();
      } else {
        _fs.clearSelection();
      }
    } else {
      return false;
    }
    return true;
  }

  /// Up and Down in the grid move by a row of tiles.
  int _gridStep(int d) => _sv.settings.gridView ? d * _gridColumns : d;
}
