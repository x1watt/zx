// Files for the library in a browser (docs/architecture.md section 20, "A
// writable database in the browser"): the synchronous part of dart:io that
// the database, its lock, its compaction and the .zx writer use, over files
// held in memory. host/io.dart exports these names instead of dart:io's
// (which throw in a browser) when compiled for the web, so the store runs
// unchanged.
//
// Persistence is the host's: [ZxWebFs.changes] lists what changed since the
// last call (whole files by 64 KiB chunks, deletions, renames), which the
// host writes to IndexedDB or OPFS after each commit (asynchronously), and
// [ZxWebFs.restore] puts the files back when the page loads. One tab, one
// thread: locks are always granted.
//
// Plain Dart (no dart:io, no JS), so the VM tests it as it is.

import 'dart:convert';
import 'dart:typed_data';

/// The size of the pieces in which changes are reported.
const int zxWebChunk = 64 * 1024;

class _MemFile {
  _MemFile(this.id);
  final int id;
  Uint8List data = Uint8List(0);
  int length = 0;
  DateTime modified = DateTime.now();
  final Set<int> dirty = {};
  bool metaDirty = true;

  void ensure(int n) {
    if (n <= data.length) return;
    var c = data.length < 4096 ? 4096 : data.length;
    while (c < n) {
      c *= 2;
    }
    final d = Uint8List(c)..setRange(0, length, data);
    data = d;
  }

  void touch(int from, int to) {
    for (var c = from ~/ zxWebChunk; c <= (to - 1) ~/ zxWebChunk; c++) {
      dirty.add(c);
    }
    metaDirty = true;
    modified = DateTime.now();
  }
}

/// A change for the host to persist.
sealed class ZxWebFsChange {
  const ZxWebFsChange();
}

/// File [path] (stored as [id]; the host keeps one record per id, so a
/// rename is the same id with a new path) is [length] bytes, modified at
/// [modified];
/// [chunks] are the 64 KiB pieces whose bytes changed (index to bytes; the
/// last may be short). Pieces beyond the length are gone.
class ZxWebFsFile extends ZxWebFsChange {
  const ZxWebFsFile(this.path, this.id, this.length, this.modified, this.chunks);
  final String path;
  final int id;
  final int length;
  final DateTime modified;
  final Map<int, Uint8List> chunks;
}

/// The file stored as [id] is gone (deleted, or replaced by a rename).
class ZxWebFsDelete extends ZxWebFsChange {
  const ZxWebFsDelete(this.id);
  final int id;
}

/// Directory [path] exists.
class ZxWebFsDir extends ZxWebFsChange {
  const ZxWebFsDir(this.path);
  final String path;
}

/// The files of the library in a browser.
class ZxWebFs {
  ZxWebFs._();
  static final ZxWebFs instance = ZxWebFs._();

  final Map<String, _MemFile> _files = {};
  final Set<String> _dirs = {'/'};
  final Set<String> _newDirs = {};
  final Set<int> _deleted = {};
  int _nextId = 1;

  /// Called after every change (debounce it and persist [changes]).
  void Function()? onChange;

  static String norm(String p) {
    var s = p.replaceAll('\\', '/');
    while (s.contains('//')) {
      s = s.replaceAll('//', '/');
    }
    if (s.length > 1 && s.endsWith('/')) s = s.substring(0, s.length - 1);
    return s;
  }

  static String parentOf(String p) {
    final s = norm(p);
    final i = s.lastIndexOf('/');
    if (i <= 0) return '/';
    return s.substring(0, i);
  }

  void _changed() => onChange?.call();

  /// Puts back a file read from the host's storage (at load).
  void restore(String path, int id, Uint8List bytes, DateTime modified) {
    final f = _MemFile(id)
      ..data = bytes
      ..length = bytes.length
      ..modified = modified
      ..metaDirty = false;
    _files[norm(path)] = f;
    if (id >= _nextId) _nextId = id + 1;
    var d = parentOf(path);
    while (_dirs.add(d)) {
      d = parentOf(d);
    }
  }

  /// Puts back a directory read from the host's storage.
  void restoreDir(String path) => _dirs.add(norm(path));

  /// What changed since the last call, for the host to persist in order.
  List<ZxWebFsChange> changes() {
    final out = <ZxWebFsChange>[];
    for (final d in _newDirs) {
      out.add(ZxWebFsDir(d));
    }
    _newDirs.clear();
    for (final id in _deleted) {
      out.add(ZxWebFsDelete(id));
    }
    _deleted.clear();
    _files.forEach((path, f) {
      if (!f.metaDirty && f.dirty.isEmpty) return;
      final chunks = <int, Uint8List>{};
      for (final c in f.dirty) {
        final from = c * zxWebChunk;
        if (from >= f.length) continue;
        final to = from + zxWebChunk > f.length ? f.length : from + zxWebChunk;
        chunks[c] = Uint8List.fromList(Uint8List.sublistView(f.data, from, to));
      }
      out.add(ZxWebFsFile(path, f.id, f.length, f.modified, chunks));
      f.dirty.clear();
      f.metaDirty = false;
    });
    return out;
  }

  /// Marks every file as changed in all its chunks, so the next [changes]
  /// lists everything: a host whose last write failed calls it, since
  /// [changes] had already cleared what that write carried.
  void markAllDirty() {
    for (final f in _files.values) {
      for (var c = 0; c * zxWebChunk < f.length; c += 1) {
        f.dirty.add(c);
      }
      f.metaDirty = true;
    }
    _newDirs.addAll(_dirs.where((d) => d != '/'));
    _changed();
  }

  /// Forgets everything (tests).
  void reset() {
    _files.clear();
    _dirs
      ..clear()
      ..add('/');
    _newDirs.clear();
    _deleted.clear();
    _nextId = 1;
  }

  _MemFile? _get(String p) => _files[norm(p)];

  _MemFile _create(String p) {
    final f = _MemFile(_nextId++);
    _files[norm(p)] = f;
    _mkdirs(parentOf(p));
    _changed();
    return f;
  }

  void _mkdirs(String d) {
    var x = norm(d);
    while (!_dirs.contains(x)) {
      _dirs.add(x);
      _newDirs.add(x);
      x = parentOf(x);
    }
  }

  void _delete(String p) {
    final f = _files.remove(norm(p));
    if (f != null) {
      _deleted.add(f.id);
      _changed();
    }
  }
}

ZxWebFs get _fs => ZxWebFs.instance;

/// dart:io's FileSystemException, as the library catches it.
class FileSystemException implements Exception {
  const FileSystemException([this.message = '', this.path = '', this.osError]);
  final String message;
  final String? path;
  final OSError? osError;
  @override
  String toString() => 'FileSystemException: $message, path = \'$path\'';
}

/// dart:io's OSError.
class OSError implements Exception {
  const OSError([this.message = '', this.errorCode = -1]);
  final String message;
  final int errorCode;
  @override
  String toString() => 'OS Error: $message, errno = $errorCode';
}

/// dart:io's FileMode.
class FileMode {
  const FileMode._(this._m);
  final int _m;
  static const read = FileMode._(0);
  static const write = FileMode._(1);
  static const append = FileMode._(2);
  static const writeOnly = FileMode._(3);
  static const writeOnlyAppend = FileMode._(4);
  @override
  String toString() =>
      const ['read', 'write', 'append', 'writeOnly', 'writeOnlyAppend'][_m];
}

/// dart:io's FileSystemEntityType.
class FileSystemEntityType {
  const FileSystemEntityType._(this._t);
  final int _t;
  static const file = FileSystemEntityType._(0);
  static const directory = FileSystemEntityType._(1);
  static const link = FileSystemEntityType._(2);
  static const notFound = FileSystemEntityType._(3);
  @override
  String toString() => const ['file', 'directory', 'link', 'notFound'][_t];
}

/// dart:io's FileStat.
class FileStat {
  const FileStat._(this.type, this.size, this.modified);
  final FileSystemEntityType type;
  final int size;
  final DateTime modified;
  DateTime get changed => modified;
  DateTime get accessed => modified;
  int get mode => 420;

  static FileStat statSync(String path) {
    final f = _fs._get(path);
    if (f != null) return FileStat._(FileSystemEntityType.file, f.length, f.modified);
    if (_fs._dirs.contains(ZxWebFs.norm(path))) {
      return FileStat._(FileSystemEntityType.directory, 0, DateTime.now());
    }
    return FileStat._(FileSystemEntityType.notFound, -1,
        DateTime.fromMillisecondsSinceEpoch(0));
  }
}

/// dart:io's FileSystemEntity (the common part).
abstract class FileSystemEntity {
  String get path;
  bool existsSync();
  FileStat statSync() => FileStat.statSync(path);
  Directory get parent => Directory(ZxWebFs.parentOf(path));
  Uri get uri => Uri.file(path);
  FileSystemEntity get absolute => this;
}

/// dart:io's File, over [ZxWebFs].
class File extends FileSystemEntity {
  File(String path) : path = ZxWebFs.norm(path);
  @override
  final String path;

  @override
  bool existsSync() => _fs._get(path) != null;

  @override
  File get absolute => this;

  void createSync({bool recursive = false, bool exclusive = false}) {
    if (_fs._get(path) != null) {
      if (exclusive) {
        throw FileSystemException('Cannot create file', path,
            const OSError('File exists', 17));
      }
      return;
    }
    final d = ZxWebFs.parentOf(path);
    if (!recursive && !_fs._dirs.contains(d)) {
      throw FileSystemException('Cannot create file', path,
          const OSError('No such file or directory', 2));
    }
    _fs._create(path);
  }

  void deleteSync({bool recursive = false}) {
    if (_fs._get(path) == null) {
      throw FileSystemException('Cannot delete file', path,
          const OSError('No such file or directory', 2));
    }
    _fs._delete(path);
  }

  File renameSync(String newPath) {
    final f = _fs._files.remove(path) ??
        (throw FileSystemException('Cannot rename file', path,
            const OSError('No such file or directory', 2)));
    final to = ZxWebFs.norm(newPath);
    final old = _fs._files.remove(to);
    if (old != null) _fs._deleted.add(old.id);
    _fs._files[to] = f;
    _fs._mkdirs(ZxWebFs.parentOf(to));
    // the host keeps one record per file id, holding its path: the
    // file's next change carries the new path
    f.metaDirty = true;
    _fs._changed();
    return File(to);
  }

  File copySync(String newPath) {
    final src = _fs._get(path) ??
        (throw FileSystemException('Cannot copy file', path,
            const OSError('No such file or directory', 2)));
    final dst = _fs._get(newPath) ?? _fs._create(newPath);
    dst.ensure(src.length);
    dst.data.setRange(0, src.length, src.data);
    dst.length = src.length;
    dst.touch(0, dst.length == 0 ? 1 : dst.length);
    _fs._changed();
    return File(newPath);
  }

  int lengthSync() => (_fs._get(path) ??
          (throw FileSystemException('Cannot retrieve length of file', path,
              const OSError('No such file or directory', 2))))
      .length;

  DateTime lastModifiedSync() => (_fs._get(path) ??
          (throw FileSystemException('Cannot retrieve modification time', path,
              const OSError('No such file or directory', 2))))
      .modified;

  Uint8List readAsBytesSync() {
    final f = _fs._get(path) ??
        (throw FileSystemException('Cannot open file', path,
            const OSError('No such file or directory', 2)));
    return Uint8List.fromList(Uint8List.sublistView(f.data, 0, f.length));
  }

  String readAsStringSync({Encoding encoding = utf8}) =>
      encoding.decode(readAsBytesSync());

  List<String> readAsLinesSync({Encoding encoding = utf8}) =>
      const LineSplitter().convert(readAsStringSync(encoding: encoding));

  void writeAsBytesSync(List<int> bytes,
      {FileMode mode = FileMode.write, bool flush = false}) {
    final raf = openSync(mode: mode == FileMode.append ? FileMode.append : FileMode.write);
    try {
      if (mode == FileMode.append) raf.setPositionSync(raf.lengthSync());
      raf.writeFromSync(bytes);
    } finally {
      raf.closeSync();
    }
  }

  void writeAsStringSync(String contents,
          {FileMode mode = FileMode.write,
          Encoding encoding = utf8,
          bool flush = false}) =>
      writeAsBytesSync(encoding.encode(contents), mode: mode, flush: flush);

  RandomAccessFile openSync({FileMode mode = FileMode.read}) {
    var f = _fs._get(path);
    if (f == null) {
      if (mode == FileMode.read) {
        throw FileSystemException('Cannot open file', path,
            const OSError('No such file or directory', 2));
      }
      // the host's own files (and their folders) live elsewhere in a
      // browser: a file opened for writing gets its folders
      f = _fs._create(path);
    } else if (mode == FileMode.write || mode == FileMode.writeOnly) {
      f.length = 0;
      f.touch(0, 1);
      _fs._changed();
    }
    final raf = RandomAccessFile._(path, f, mode != FileMode.read);
    if (mode == FileMode.append || mode == FileMode.writeOnlyAppend) {
      raf._pos = f.length;
    }
    return raf;
  }

  @override
  String toString() => "File: '$path'";
}

/// dart:io's RandomAccessFile, over [ZxWebFs].
class RandomAccessFile {
  RandomAccessFile._(this.path, this._f, this._writable);
  final String path;
  final _MemFile _f;
  final bool _writable;
  int _pos = 0;
  bool _closed = false;

  void _check() {
    if (_closed) throw FileSystemException('File closed', path);
  }

  int lengthSync() {
    _check();
    return _f.length;
  }

  int positionSync() {
    _check();
    return _pos;
  }

  RandomAccessFile setPositionSync(int position) {
    _check();
    _pos = position;
    return this;
  }

  Uint8List readSync(int count) {
    _check();
    final end = _pos + count > _f.length ? _f.length : _pos + count;
    if (end <= _pos) return Uint8List(0);
    final out = Uint8List.fromList(Uint8List.sublistView(_f.data, _pos, end));
    _pos = end;
    return out;
  }

  int readIntoSync(List<int> buffer, [int start = 0, int? end]) {
    _check();
    final want = (end ?? buffer.length) - start;
    final n = _pos + want > _f.length ? _f.length - _pos : want;
    if (n <= 0) return 0;
    buffer.setRange(start, start + n, _f.data, _pos);
    _pos += n;
    return n;
  }

  int readByteSync() {
    _check();
    if (_pos >= _f.length) return -1;
    return _f.data[_pos++];
  }

  RandomAccessFile writeFromSync(List<int> buffer, [int start = 0, int? end]) {
    _check();
    if (!_writable) {
      throw FileSystemException('File not open for writing', path);
    }
    final stop = end ?? buffer.length;
    final n = stop - start;
    if (n <= 0) return this;
    _f.ensure(_pos + n);
    _f.data.setRange(_pos, _pos + n, buffer, start);
    _f.touch(_pos, _pos + n);
    _pos += n;
    if (_pos > _f.length) _f.length = _pos;
    _fs._changed();
    return this;
  }

  RandomAccessFile writeByteSync(int value) => writeFromSync([value]);

  RandomAccessFile writeStringSync(String s, {Encoding encoding = utf8}) =>
      writeFromSync(encoding.encode(s));

  RandomAccessFile truncateSync(int length) {
    _check();
    if (!_writable) {
      throw FileSystemException('File not open for writing', path);
    }
    if (length < _f.length) {
      _f.length = length;
      if (length > 0) _f.touch(length - 1, length);
      _f.metaDirty = true;
    } else if (length > _f.length) {
      _f.ensure(length);
      _f.data.fillRange(_f.length, length, 0);
      _f.touch(_f.length, length);
      _f.length = length;
    }
    _fs._changed();
    return this;
  }

  /// Persisting is the host's ([ZxWebFs.changes]); nothing to do here.
  RandomAccessFile flushSync() {
    _check();
    return this;
  }

  /// One tab, one thread: always granted.
  RandomAccessFile lockSync([Object? mode, int start = 0, int end = -1]) => this;

  RandomAccessFile unlockSync([int start = 0, int end = -1]) => this;

  void closeSync() => _closed = true;
}

/// dart:io's Directory, over [ZxWebFs].
class Directory extends FileSystemEntity {
  Directory(String path) : path = ZxWebFs.norm(path);
  @override
  final String path;

  static Directory get systemTemp => Directory('/tmp');
  static Directory get current => Directory('/');

  @override
  Directory get absolute => this;

  @override
  bool existsSync() => _fs._dirs.contains(path);

  void createSync({bool recursive = false}) {
    if (!recursive && !_fs._dirs.contains(ZxWebFs.parentOf(path))) {
      throw FileSystemException('Creation failed', path,
          const OSError('No such file or directory', 2));
    }
    _fs._mkdirs(path);
    _fs._changed();
  }

  Directory createTempSync([String prefix = '']) {
    var i = DateTime.now().microsecondsSinceEpoch;
    while (_fs._dirs.contains('$path/$prefix$i')) {
      i++;
    }
    return Directory('$path/$prefix$i')..createSync(recursive: true);
  }

  void deleteSync({bool recursive = false}) {
    final pre = '$path/';
    final inside = [
      for (final p in _fs._files.keys) if (p.startsWith(pre)) p,
    ];
    if (inside.isNotEmpty && !recursive) {
      throw FileSystemException('Directory not empty', path,
          const OSError('Directory not empty', 39));
    }
    for (final p in inside) {
      _fs._delete(p);
    }
    _fs._dirs.removeWhere((d) => d == path || d.startsWith(pre));
    _fs._changed();
  }

  List<FileSystemEntity> listSync(
      {bool recursive = false, bool followLinks = true}) {
    final pre = path == '/' ? '/' : '$path/';
    bool direct(String p) =>
        p.startsWith(pre) && p != path && (recursive || !p.substring(pre.length).contains('/'));
    return [
      for (final d in _fs._dirs) if (direct(d)) Directory(d),
      for (final f in _fs._files.keys) if (direct(f)) File(f),
    ];
  }

  @override
  String toString() => "Directory: '$path'";
}

/// The process id in a browser (one page, one "process").
const int pid = 1;
