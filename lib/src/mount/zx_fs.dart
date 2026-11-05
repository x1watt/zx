// ZxFs: an archive as a POSIX-like file system (the model behind
// `zx mount`, docs/mount.md). Pure Dart, no FUSE here: lib/src/mount/
// fuse_bridge.dart speaks to the C daemon native/fuse/zx-mount.c, and this
// class answers path based requests (getattr, readdir, read, write...).
//
// Reading: a file is extracted once to the cache folder (ZxArchive has no
// range reads), then read by offset from that copy. The cache is a LRU
// bounded by [ZxFsOptions.cacheBytes].
//
// Writing: a file that is created or changed lives in the staging folder.
// Deletes, renames and new folders are recorded in a journal. [commit]
// replays the journal on the archive, then adds every staged file in one
// update (one new generation for .zx), and reads the listing again.
// Nothing is written to the archive between commits, so a crash loses the
// changes since the last commit and never damages the archive.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../io/streams.dart' show SevenZipException;
import '../zx_api.dart';

/// POSIX errors as the FUSE layer wants them (positive numbers).
class FsError implements Exception {
  final int errno;
  final String message;
  const FsError(this.errno, this.message);

  static const int eperm = 1;
  static const int enoent = 2;
  static const int eio = 5;
  static const int eacces = 13;
  static const int eexist = 17;
  static const int enotdir = 20;
  static const int eisdir = 21;
  static const int einval = 22;
  static const int erofs = 30;
  static const int enotempty = 39;

  @override
  String toString() => 'FsError($errno): $message';
}

/// The archive operations ZxFs needs; [ZxArchive] implements them through
/// [ZxArchiveBackend], tests can use a fake.
abstract class FsBackend {
  /// All items (files, folders, implied folders) of the current state.
  List<ZxItem> get items;

  /// Whether the archive can be changed.
  bool get writable;

  /// Extracts the file [path] into a new file below [dir]; returns it.
  Future<String> extract(String path, String dir);

  Future<void> delete(String path);
  Future<void> rename(String from, String to);
  Future<void> createFolder(String path);

  /// Adds the files (stored path to file on disk) in one update.
  Future<void> addAll(Map<String, String> files);

  /// Reads the listing again after an update.
  Future<void> reload();
}

/// [FsBackend] on a [ZxArchive].
class ZxArchiveBackend implements FsBackend {
  final ZxArchive archive;
  ZxArchiveBackend(this.archive);

  @override
  List<ZxItem> get items => archive.items;

  @override
  bool get writable =>
      archive.capabilities.canAdd &&
      archive.capabilities.canDelete &&
      archive.capabilities.canRename;

  @override
  Future<String> extract(String path, String dir) async {
    final it = archive[path];
    if (it == null) throw FsError(FsError.enoent, path);
    return archive.extractToTemp(it, tempDir: dir);
  }

  @override
  Future<void> delete(String path) => archive.delete([path]);

  @override
  Future<void> rename(String from, String to) => archive.rename(from, to);

  @override
  Future<void> createFolder(String path) => archive.createFolder(path);

  @override
  Future<void> addAll(Map<String, String> files) => archive.add([
        for (final e in files.entries) ZxSource(e.value, storedAs: e.key)
      ]);

  @override
  Future<void> reload() => archive.reload();
}

class ZxFsOptions {
  /// Folder for the extracted and staged files (created if missing).
  final String workDir;

  /// The most extracted bytes kept for reading (staged files not counted).
  final int cacheBytes;

  /// Mount read only even if the archive can be changed.
  final bool readOnly;

  /// Commit when this long passes with no change and no open writer;
  /// null: only on fsync and unmount.
  final Duration? idleCommit;

  /// uid, gid of the files, and the modes for items with no POSIX mode.
  final int uid, gid;
  final int fileMode, dirMode;

  const ZxFsOptions(
    this.workDir, {
    this.cacheBytes = 1 << 30,
    this.readOnly = false,
    this.idleCommit = const Duration(seconds: 5),
    this.uid = 0,
    this.gid = 0,
    this.fileMode = 420, // 0644
    this.dirMode = 493, // 0755
  });
}

/// What getattr tells.
class FsStat {
  final bool isDir;
  final bool isSymlink;
  final int size;
  final int mode; // permission bits only
  final int mtimeSec;
  final int nlink;
  const FsStat(this.isDir, this.isSymlink, this.size, this.mode,
      this.mtimeSec, this.nlink);
}

class _Node {
  String name;
  bool isDir;
  int size;
  int mode;
  int mtimeSec;
  String? link;

  /// The staged copy (a changed or new file), null for archive content.
  String? staged;
  bool dirty = false;

  /// Open handles on this node.
  int handles = 0;
  final Map<String, _Node>? kids;
  _Node(this.name, this.isDir, this.size, this.mode, this.mtimeSec,
      {this.link})
      : kids = isDir ? <String, _Node>{} : null;
}

class _Handle {
  final _Node node;
  final RandomAccessFile file; // reads
  final RandomAccessFile? out; // writes (not truncating, not appending)
  _Handle(this.node, this.file, this.out);
}

sealed class _Op {}

class _Del extends _Op {
  final String path;
  _Del(this.path);
}

class _Ren extends _Op {
  final String from, to;
  _Ren(this.from, this.to);
}

class _Mk extends _Op {
  final String path;
  _Mk(this.path);
}

class ZxFs {
  final FsBackend backend;
  final ZxFsOptions opt;
  late _Node _root;
  final _journal = <_Op>[];
  final _handles = <int, _Handle>{};
  var _nextFh = 1;
  var _stageN = 0;

  // extracted copies: path (with the generation of the tree) to file
  final _cache = <String, ({String file, int size})>{};
  final _pending = <String, Future<String>>{};
  var _cacheTotal = 0;
  var _epoch = 0;

  Timer? _idle;
  Future<void> _commitLock = Future.value();
  var _closed = false;

  /// The last commit error, null when the last commit worked.
  Object? lastCommitError;

  ZxFs(this.backend, this.opt) {
    Directory(opt.workDir).createSync(recursive: true);
    _build();
  }

  bool get writable => backend.writable && !opt.readOnly;

  /// True when changes wait for a commit.
  bool get hasChanges =>
      _journal.isNotEmpty || _walk(_root, '').any((e) => e.$2.dirty);

  // ---- tree ----

  void _build() {
    final keep = <String, _Node>{};
    if (_handles.isNotEmpty) {
      for (final e in _walk(_root, '')) {
        if (e.$2.handles > 0 && e.$2.staged != null) keep[e.$1] = e.$2;
      }
    }
    _root = _Node('', true, 0, opt.dirMode, 0);
    for (final it in backend.items) {
      if (it.path.isEmpty) continue;
      final parts = it.path.split('/');
      var d = _root;
      for (var i = 0; i < parts.length - 1; i++) {
        d = d.kids!.putIfAbsent(parts[i],
            () => _Node(parts[i], true, 0, opt.dirMode, 0));
      }
      final name = parts.last;
      final m = it.posixMode;
      final perm = m == null ? null : m & 0xFFF;
      final mtime = (it.modified?.millisecondsSinceEpoch ?? 0) ~/ 1000;
      if (it.isDir) {
        final n = d.kids!.putIfAbsent(
            name, () => _Node(name, true, 0, opt.dirMode, mtime));
        if (perm != null) n.mode = perm;
        n.mtimeSec = mtime;
      } else {
        d.kids![name] = _Node(name, false, it.size ?? 0,
            perm ?? opt.fileMode, mtime,
            link: it.isSymlink ? it.symlinkTarget : null);
      }
    }
    for (final e in keep.entries) {
      final parent = _lookup(_parentOf(e.key));
      if (parent != null && parent.isDir) {
        parent.kids![e.value.name] = e.value;
      }
    }
    _epoch++;
  }

  static String _parentOf(String p) {
    final i = p.lastIndexOf('/');
    return i < 0 ? '' : p.substring(0, i);
  }

  static String norm(String p) {
    final parts = p.split('/').where((s) => s.isNotEmpty && s != '.');
    return parts.join('/');
  }

  _Node? _lookup(String path) {
    var n = _root;
    if (path.isEmpty) return n;
    for (final s in path.split('/')) {
      if (!n.isDir) return null;
      final k = n.kids![s];
      if (k == null) return null;
      n = k;
    }
    return n;
  }

  Iterable<(String, _Node)> _walk(_Node n, String path) sync* {
    if (!n.isDir) return;
    for (final k in n.kids!.values) {
      final p = path.isEmpty ? k.name : '$path/${k.name}';
      yield (p, k);
      yield* _walk(k, p);
    }
  }

  _Node _need(String path) {
    final n = _lookup(norm(path));
    if (n == null) throw FsError(FsError.enoent, path);
    return n;
  }

  void _needWritable() {
    if (!writable) throw const FsError(FsError.erofs, 'read only');
  }

  // ---- queries ----

  FsStat getattr(String path) {
    final n = _need(path);
    final size = n.isDir ? 0 : (n.link != null ? n.link!.length : n.size);
    final nlink = n.isDir ? 2 + n.kids!.values.where((k) => k.isDir).length : 1;
    return FsStat(n.isDir, n.link != null, size, n.mode, n.mtimeSec, nlink);
  }

  /// Names (with isDir) in the folder [path].
  List<(String, bool)> readdir(String path) {
    final n = _need(path);
    if (!n.isDir) throw FsError(FsError.enotdir, path);
    return [for (final k in n.kids!.values) (k.name, k.isDir)];
  }

  String readlink(String path) {
    final n = _need(path);
    final l = n.link;
    if (l == null) throw FsError(FsError.einval, path);
    return l;
  }

  // ---- open, read, write ----

  Future<String> _cached(String path, _Node n) {
    final key = '$_epoch:$path';
    final hit = _cache.remove(key);
    if (hit != null) {
      _cache[key] = hit; // most recently used last
      return Future.value(hit.file);
    }
    return _pending[key] ??= () async {
      try {
        final dir = Directory(opt.workDir).createTempSync('x_').path;
        final file = await backend.extract(path, dir);
        final size = File(file).lengthSync();
        _cache[key] = (file: file, size: size);
        _cacheTotal += size;
        _evict(key);
        return file;
      } on FsError {
        rethrow;
      } on SevenZipException catch (e) {
        throw FsError(FsError.eio, e.message);
      } finally {
        _pending.remove(key);
      }
    }();
  }

  void _evict(String keep) {
    while (_cacheTotal > opt.cacheBytes && _cache.length > 1) {
      final k = _cache.keys.first;
      if (k == keep) break;
      final e = _cache.remove(k)!;
      _cacheTotal -= e.size;
      _deleteQuiet(e.file, parent: true);
    }
  }

  static void _deleteQuiet(String file, {bool parent = false}) {
    try {
      if (parent) {
        Directory(File(file).parent.path).deleteSync(recursive: true);
      } else {
        File(file).deleteSync();
      }
    } on FileSystemException {
      // already gone
    }
  }

  String _newStage() => '${opt.workDir}/stage_${_stageN++}';

  /// Opens the file [path]; returns the handle. [write] copies the content
  /// to the staging folder first (unless [truncate]).
  Future<int> open(String path, {bool write = false, bool truncate = false}) {
    return _serial(() async {
      final p = norm(path);
      final n = _need(p);
      if (n.isDir) throw FsError(FsError.eisdir, path);
      if (write) _needWritable();
      if (write && n.staged == null) {
        final stage = _newStage();
        if (truncate || n.size == 0) {
          File(stage).createSync();
        } else {
          final src = await _cached(p, n);
          File(src).copySync(stage);
        }
        n.staged = stage;
        n.size = File(stage).lengthSync();
      }
      if (write && truncate) {
        File(n.staged!).writeAsBytesSync(const []);
        n.size = 0;
        n.dirty = true;
      }
      final src = n.staged ?? await _cached(p, n);
      final fh = _nextFh++;
      n.handles++;
      _handles[fh] = _Handle(
          n,
          File(src).openSync(),
          write ? File(src).openSync(mode: FileMode.append) : null);
      return fh;
    });
  }

  /// Creates the empty file [path] and opens it for writing.
  Future<int> create(String path, {int? mode}) {
    return _serial(() async {
      _needWritable();
      final p = norm(path);
      if (p.isEmpty) throw FsError(FsError.eexist, path);
      final parent = _lookup(_parentOf(p));
      if (parent == null) throw FsError(FsError.enoent, path);
      if (!parent.isDir) throw FsError(FsError.enotdir, path);
      final name = p.substring(p.lastIndexOf('/') + 1);
      final old = parent.kids![name];
      if (old != null && old.isDir) throw FsError(FsError.eisdir, path);
      final stage = _newStage();
      File(stage).createSync();
      final n = _Node(name, false, 0, mode ?? opt.fileMode,
          DateTime.now().millisecondsSinceEpoch ~/ 1000)
        ..staged = stage
        ..dirty = true;
      // an old archive file at the same path is replaced by the add
      parent.kids![name] = n;
      final fh = _nextFh++;
      n.handles++;
      _handles[fh] = _Handle(n, File(stage).openSync(),
          File(stage).openSync(mode: FileMode.append));
      _touch();
      return fh;
    });
  }

  _Handle _h(int fh) {
    final h = _handles[fh];
    if (h == null) throw const FsError(FsError.einval, 'bad handle');
    return h;
  }

  Uint8List read(int fh, int offset, int size) {
    final h = _h(fh);
    final f = h.file;
    f.setPositionSync(offset);
    final b = Uint8List(size);
    final got = f.readIntoSync(b);
    return got == size ? b : Uint8List.sublistView(b, 0, got);
  }

  int write(int fh, int offset, Uint8List data) {
    final h = _h(fh);
    final w = h.out;
    if (w == null) throw const FsError(FsError.eacces, 'not open for writing');
    // writing past the end leaves a hole of zeros (the file system does it)
    w.setPositionSync(offset);
    w.writeFromSync(data);
    h.node.size = w.lengthSync();
    h.node.dirty = true;
    h.node.mtimeSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    _touch();
    return data.length;
  }

  /// Frees the handle.
  void release(int fh) {
    final h = _handles.remove(fh);
    if (h == null) return;
    h.file.closeSync();
    h.out?.closeSync();
    h.node.handles--;
    _touch();
  }

  /// Sets the size of [path] (truncate), staging it when needed.
  Future<void> truncate(String path, int size) {
    return _serial(() async {
      _needWritable();
      final p = norm(path);
      final n = _need(p);
      if (n.isDir) throw FsError(FsError.eisdir, path);
      if (n.staged == null) {
        final stage = _newStage();
        if (size == 0 || n.size == 0) {
          File(stage).createSync();
        } else {
          File(await _cached(p, n)).copySync(stage);
        }
        n.staged = stage;
      }
      final f = File(n.staged!).openSync(mode: FileMode.append);
      try {
        f.truncateSync(size);
      } finally {
        f.closeSync();
      }
      n.size = size;
      n.dirty = true;
      _touch();
    });
  }

  // ---- namespace changes ----

  Future<void> mkdir(String path) {
    return _serial(() async {
      _needWritable();
      final p = norm(path);
      if (p.isEmpty) throw FsError(FsError.eexist, path);
      final parent = _lookup(_parentOf(p));
      if (parent == null) throw FsError(FsError.enoent, path);
      if (!parent.isDir) throw FsError(FsError.enotdir, path);
      final name = p.substring(p.lastIndexOf('/') + 1);
      if (parent.kids!.containsKey(name)) throw FsError(FsError.eexist, path);
      parent.kids![name] = _Node(name, true, 0, opt.dirMode,
          DateTime.now().millisecondsSinceEpoch ~/ 1000);
      _journal.add(_Mk(p));
      _touch();
    });
  }

  bool _inArchive(String p) {
    // a path the archive holds (not only staged)
    for (final it in backend.items) {
      if (it.path == p) return true;
    }
    return false;
  }

  Future<void> remove(String path, {required bool dir}) {
    return _serial(() async {
      _needWritable();
      final p = norm(path);
      if (p.isEmpty) throw FsError(FsError.eperm, path);
      final parent = _lookup(_parentOf(p));
      final n = parent?.kids?[p.substring(p.lastIndexOf('/') + 1)];
      if (n == null) throw FsError(FsError.enoent, path);
      if (dir && !n.isDir) throw FsError(FsError.enotdir, path);
      if (!dir && n.isDir) throw FsError(FsError.eisdir, path);
      if (dir && n.kids!.isNotEmpty) throw FsError(FsError.enotempty, path);
      parent!.kids!.remove(n.name);
      _dropStage(n);
      _journal.add(_Del(p));
      _touch();
    });
  }

  void _dropStage(_Node n) {
    final s = n.staged;
    if (s != null && n.handles == 0) {
      _deleteQuiet(s);
      n.staged = null;
    }
  }

  Future<void> rename(String from, String to) {
    return _serial(() async {
      _needWritable();
      final f = norm(from), t = norm(to);
      if (f.isEmpty || t.isEmpty) throw FsError(FsError.eperm, from);
      if (f == t) return;
      if (t.startsWith('$f/')) throw FsError(FsError.einval, to);
      final fp = _lookup(_parentOf(f));
      final n = fp?.kids?[f.substring(f.lastIndexOf('/') + 1)];
      if (n == null) throw FsError(FsError.enoent, from);
      final tp = _lookup(_parentOf(t));
      if (tp == null) throw FsError(FsError.enoent, to);
      if (!tp.isDir) throw FsError(FsError.enotdir, to);
      final tname = t.substring(t.lastIndexOf('/') + 1);
      final old = tp.kids![tname];
      if (old != null) {
        if (old.isDir && !n.isDir) throw FsError(FsError.eisdir, to);
        if (!old.isDir && n.isDir) throw FsError(FsError.enotdir, to);
        if (old.isDir && old.kids!.isNotEmpty) {
          throw FsError(FsError.enotempty, to);
        }
        _dropStage(old);
        if (_inArchive(t)) _journal.add(_Del(t));
      }
      fp!.kids!.remove(n.name);
      n.name = tname;
      tp.kids![tname] = n;
      _journal.add(_Ren(f, t));
      _touch();
    });
  }

  // ---- commit ----

  void _touch() {
    _idle?.cancel();
    final d = opt.idleCommit;
    if (d == null || _closed) return;
    _idle = Timer(d, () {
      if (_handles.values.any((h) => h.out != null)) {
        _touch(); // a writer is open: wait
        return;
      }
      commit().catchError((Object e) => lastCommitError = e);
    });
  }

  Future<T> _serial<T>(Future<T> Function() f) {
    final r = _commitLock.then((_) => f());
    _commitLock = r.then((_) {}, onError: (_) {});
    return r;
  }

  /// Writes the changes to the archive as one update.
  Future<void> commit() => _serial(_commit);

  Future<void> _commit() async {
    if (!writable || !hasChanges) return;
    final journal = List<_Op>.of(_journal);
    // the staged files, by final path
    final staged = <String, _Node>{};
    for (final e in _walk(_root, '')) {
      final n = e.$2;
      if (!n.isDir && n.staged != null && n.dirty) staged[e.$1] = n;
    }
    try {
      for (final op in journal) {
        switch (op) {
          case _Del(:final path):
            if (_inArchive(path)) await backend.delete(path);
          case _Ren(:final from, :final to):
            if (_inArchive(from)) {
              await backend.rename(from, to);
            }
          case _Mk(:final path):
            final dirNode = _lookup(path);
            final empty = dirNode != null && dirNode.kids!.isEmpty;
            if (empty && !_inArchive(path)) await backend.createFolder(path);
        }
        // the archive listing changes with each step
        await backend.reload();
      }
      if (staged.isNotEmpty) {
        await backend.addAll({for (final e in staged.entries) e.key: e.value.staged!});
        await backend.reload();
      }
      lastCommitError = null;
    } catch (e) {
      lastCommitError = e;
      rethrow;
    }
    _journal.removeRange(0, journal.length);
    for (final n in staged.values) {
      n.dirty = false;
    }
    // the cache of the old state is no longer valid
    _dropCache();
    _build();
  }

  void _dropCache() {
    for (final e in _cache.values) {
      _deleteQuiet(e.file, parent: true);
    }
    _cache.clear();
    _cacheTotal = 0;
  }

  /// Statistics for statfs: total and free "blocks" are the archive size.
  ({int files, int bytes}) get totals {
    var files = 0, bytes = 0;
    for (final e in _walk(_root, '')) {
      if (!e.$2.isDir) {
        files++;
        bytes += e.$2.size;
      }
    }
    return (files: files, bytes: bytes);
  }

  /// Commits what is pending, closes the handles and removes the work
  /// folder. Returns the commit error, if any (the work folder is then
  /// kept so the staged files are not lost).
  Future<Object?> close() async {
    _closed = true;
    _idle?.cancel();
    for (final h in _handles.values) {
      h.file.closeSync();
      h.out?.closeSync();
    }
    _handles.clear();
    Object? err;
    try {
      await commit();
    } catch (e) {
      err = e;
    }
    if (err == null) {
      try {
        Directory(opt.workDir).deleteSync(recursive: true);
      } on FileSystemException {
        // ignore
      }
    }
    return err;
  }
}
