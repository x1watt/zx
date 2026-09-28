// The file system work of the explorer, all of it off the UI isolate:
// listing a folder, the recursive search, copy, move, delete and the
// trash (a worker isolate each, with progress, conflict questions and
// cancel), the size of a folder and the SHA-256 of a file.

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:zx/zx.dart' show Sha256, ZxCancelToken, ZxProgress;

/// One file or folder of the file system.
class FsEntry {
  final String path;
  final String name;
  final bool isDir;
  final bool isLink;
  final int size;
  final DateTime? modified;

  /// The permission bits (stat mode), 0 when unknown.
  final int mode;

  const FsEntry({
    required this.path,
    required this.name,
    required this.isDir,
    this.isLink = false,
    this.size = 0,
    this.modified,
    this.mode = 0,
  });

  bool get hidden => name.startsWith('.');
}

Future<FsEntry?> _entryOf(FileSystemEntity e) async {
  try {
    final link = e is Link;
    // a link shows what it points to (a link to a folder is a folder)
    final st = await FileStat.stat(e.path);
    final isDir = st.type == FileSystemEntityType.directory;
    return FsEntry(
      path: e.path,
      name: p.basename(e.path),
      isDir: isDir,
      isLink: link,
      size: isDir
          ? 0
          : (st.type == FileSystemEntityType.notFound ? 0 : st.size),
      modified: st.type == FileSystemEntityType.notFound ? null : st.modified,
      mode: st.mode,
    );
  } on FileSystemException {
    return null;
  }
}

/// The entries of [dir] (read in a worker isolate).
Future<List<FsEntry>> listDirectory(String dir) =>
    Isolate.run(() => _list(dir));

Future<List<FsEntry>> _list(String dir) async {
  final out = <FsEntry>[];
  await for (final e in Directory(dir).list(followLinks: false)) {
    final x = await _entryOf(e);
    if (x != null) out.add(x);
  }
  return out;
}

/// The entry of [path], or null when it does not exist.
Future<FsEntry?> statEntry(String path) async {
  final t = await FileSystemEntity.type(path, followLinks: false);
  if (t == FileSystemEntityType.notFound) return null;
  return _entryOf(
    t == FileSystemEntityType.link
        ? Link(path)
        : t == FileSystemEntityType.directory
        ? Directory(path)
        : File(path),
  );
}

// ---------------------------------------------------------------------------
// Search

/// A recursive search of file names below a folder in a worker isolate;
/// matches arrive in batches on [results]. [cancel] stops it.
class FsSearch {
  final String root;
  final String query;
  final bool showHidden;
  final _results = StreamController<List<FsEntry>>();
  Isolate? _isolate;
  ReceivePort? _port;
  bool _done = false;

  FsSearch(this.root, this.query, {this.showHidden = false});

  Stream<List<FsEntry>> get results => _results.stream;

  Future<void> start() async {
    final port = ReceivePort();
    _port = port;
    port.listen((m) {
      if (m == null) {
        _finish();
      } else if (m is List<FsEntry>) {
        if (!_results.isClosed) _results.add(m);
      }
    });
    _isolate = await Isolate.spawn(_searchMain, (
      port.sendPort,
      root,
      query.toLowerCase(),
      showHidden,
    ), onExit: port.sendPort);
    if (_done) _isolate?.kill(priority: Isolate.immediate);
  }

  void _finish() {
    if (_done) return;
    _done = true;
    _port?.close();
    if (!_results.isClosed) _results.close();
  }

  void cancel() {
    _isolate?.kill(priority: Isolate.immediate);
    _finish();
  }
}

Future<void> _searchMain((SendPort, String, String, bool) a) async {
  final (out, root, q, hidden) = a;
  var batch = <FsEntry>[];
  var last = DateTime.now();
  final stack = <String>[root];
  while (stack.isNotEmpty) {
    final d = stack.removeLast();
    try {
      await for (final e in Directory(d).list(followLinks: false)) {
        final name = p.basename(e.path);
        if (!hidden && name.startsWith('.')) continue;
        if (e is Directory) stack.add(e.path);
        if (name.toLowerCase().contains(q)) {
          final x = await _entryOf(e);
          if (x != null) batch.add(x);
        }
        final now = DateTime.now();
        if (batch.isNotEmpty &&
            (batch.length >= 200 ||
                now.difference(last).inMilliseconds > 150)) {
          out.send(batch);
          batch = [];
          last = now;
        }
      }
    } on FileSystemException {
      // a folder we may not read
    }
  }
  if (batch.isNotEmpty) out.send(batch);
  out.send(null);
}

// ---------------------------------------------------------------------------
// Copy, move, delete, trash

enum FsOpKind { copy, move, delete, trash }

/// A name that exists already at the destination.
class FsConflict {
  final String source;
  final String target;
  final bool sourceIsDir;
  final bool targetIsDir;
  const FsConflict(
    this.source,
    this.target,
    this.sourceIsDir,
    this.targetIsDir,
  );
}

enum FsConflictAction { overwrite, skip, rename, cancel }

/// The answer to a conflict; [all]: the same for the next conflicts.
class FsConflictAnswer {
  final FsConflictAction action;
  final bool all;
  const FsConflictAnswer(this.action, {this.all = false});
}

class FsOpResult {
  /// Files and folders done (top level items).
  final int done;
  final int skipped;

  /// The paths created at the destination (top level).
  final List<String> created;

  /// The items that could not be moved to the trash.
  final List<String> notTrashed;
  final List<String> errors;
  const FsOpResult({
    this.done = 0,
    this.skipped = 0,
    this.created = const [],
    this.notTrashed = const [],
    this.errors = const [],
  });
  bool get ok => errors.isEmpty;
}

class FsCancelled implements Exception {
  @override
  String toString() => 'cancelled';
}

/// Runs [kind] on [sources] in a worker isolate: copy and move into
/// [destDir], delete (permanently) and trash (into [trashDir], the
/// freedesktop.org home trash, or ~/.Trash on macOS when [macTrash]).
/// [onConflict] answers the names that exist; [cancel] stops the work
/// (a file being written is deleted) and throws [FsCancelled].
Future<FsOpResult> runFsOp(
  FsOpKind kind,
  List<String> sources, {
  String? destDir,
  String? trashDir,
  bool macTrash = false,
  void Function(ZxProgress p)? onProgress,
  Future<FsConflictAnswer> Function(FsConflict c)? onConflict,
  ZxCancelToken? cancel,
}) async {
  final port = ReceivePort();
  final exit = ReceivePort();
  final iso = await Isolate.spawn(
    _opMain,
    (port.sendPort, kind.index, sources, destDir, trashDir, macTrash),
    onExit: exit.sendPort,
    onError: exit.sendPort,
  );
  final done = Completer<FsOpResult>();
  SendPort? toWorker;
  void onCancel() => toWorker?.send(const ['cancel']);
  cancel?.addCancelListener(onCancel);
  port.listen((m) async {
    final l = m as List;
    switch (l[0]) {
      case 'port':
        toWorker = l[1] as SendPort;
        if (cancel?.isCancelled ?? false) onCancel();
      case 'progress':
        onProgress?.call(ZxProgress(l[1] as int, l[2] as int, l[3] as String?));
      case 'conflict':
        final c = FsConflict(
          l[1] as String,
          l[2] as String,
          l[3] as bool,
          l[4] as bool,
        );
        final a =
            await onConflict?.call(c) ??
            const FsConflictAnswer(FsConflictAction.skip);
        toWorker?.send(['answer', a.action.index, a.all]);
      case 'done':
        if (!done.isCompleted) {
          done.complete(
            FsOpResult(
              done: l[1] as int,
              skipped: l[2] as int,
              created: (l[3] as List).cast<String>(),
              notTrashed: (l[4] as List).cast<String>(),
              errors: (l[5] as List).cast<String>(),
            ),
          );
        }
      case 'cancelled':
        if (!done.isCompleted) done.completeError(FsCancelled());
    }
  });
  exit.listen((m) {
    if (!done.isCompleted) {
      done.completeError(
        FileSystemException(m is List ? '${m.first}' : 'the worker stopped'),
      );
    }
  });
  try {
    return await done.future;
  } finally {
    cancel?.removeCancelListener(onCancel);
    port.close();
    exit.close();
    iso.kill();
  }
}

class _Worker {
  final SendPort out;
  final ReceivePort inbox = ReceivePort();
  final _answerQueue = <List>[];
  Completer<List>? _waiting;
  bool cancelled = false;
  int doneBytes = 0;
  int totalBytes = 0;
  DateTime _lastSend = DateTime.fromMillisecondsSinceEpoch(0);
  FsConflictAnswer? _all;
  int skipped = 0;
  final errors = <String>[];

  _Worker(this.out) {
    inbox.listen((m) {
      final l = m as List;
      if (l[0] == 'cancel') {
        cancelled = true;
        _waiting?.complete(const ['answer', 3, false]);
        _waiting = null;
      } else {
        final w = _waiting;
        if (w != null) {
          _waiting = null;
          w.complete(l);
        } else {
          _answerQueue.add(l);
        }
      }
    });
    out.send(['port', inbox.sendPort]);
  }

  void check() {
    if (cancelled) throw FsCancelled();
  }

  void progress(String? file, {bool force = false}) {
    final now = DateTime.now();
    if (!force && now.difference(_lastSend).inMilliseconds < 100) return;
    _lastSend = now;
    out.send(['progress', doneBytes, totalBytes, file]);
  }

  Future<FsConflictAnswer> ask(
    String src,
    String dst,
    bool srcDir,
    bool dstDir,
  ) async {
    final a = _all;
    if (a != null) return a;
    out.send(['conflict', src, dst, srcDir, dstDir]);
    final c = Completer<List>();
    if (_answerQueue.isNotEmpty) {
      c.complete(_answerQueue.removeAt(0));
    } else {
      _waiting = c;
    }
    final l = await c.future;
    final r = FsConflictAnswer(
      FsConflictAction.values[l[1] as int],
      all: l[2] as bool,
    );
    if (r.action == FsConflictAction.cancel) throw FsCancelled();
    if (r.all) _all = r;
    return r;
  }
}

Future<void> _opMain(
  (SendPort, int, List<String>, String?, String?, bool) a,
) async {
  final (out, kindIndex, sources, destDir, trashDir, macTrash) = a;
  final kind = FsOpKind.values[kindIndex];
  final w = _Worker(out);
  final created = <String>[];
  final notTrashed = <String>[];
  var done = 0;
  try {
    if (kind == FsOpKind.copy || kind == FsOpKind.move) {
      for (final s in sources) {
        w.totalBytes += await _sizeOf(s);
      }
      w.progress(null, force: true);
      for (final s in sources) {
        w.check();
        final r = await _transfer(w, s, destDir!, kind == FsOpKind.move);
        if (r != null) {
          created.add(r);
          done++;
        }
      }
    } else if (kind == FsOpKind.delete) {
      for (final s in sources) {
        w.check();
        try {
          await _deleteAny(s);
          done++;
        } on FileSystemException catch (e) {
          w.errors.add('$s: ${e.osError?.message ?? e.message}');
        }
        w.progress(s);
      }
    } else {
      for (final s in sources) {
        w.check();
        final ok = macTrash
            ? await _macTrash(s)
            : await _xdgTrash(s, trashDir!);
        if (ok) {
          done++;
        } else {
          notTrashed.add(s);
        }
      }
    }
    out.send(['done', done, w.skipped, created, notTrashed, w.errors]);
  } on FsCancelled {
    out.send(['cancelled']);
  }
  w.inbox.close();
}

Future<int> _sizeOf(String path) async {
  final t = await FileSystemEntity.type(path, followLinks: false);
  if (t == FileSystemEntityType.file) return (await File(path).stat()).size;
  if (t != FileSystemEntityType.directory) return 0;
  var n = 0;
  try {
    await for (final e in Directory(
      path,
    ).list(recursive: true, followLinks: false)) {
      if (e is File) n += (await e.stat()).size;
    }
  } on FileSystemException {
    // unreadable parts are not counted
  }
  return n;
}

/// The size of everything below [path] (a worker isolate).
Future<(int bytes, int files, int folders)> folderSize(String path) =>
    Isolate.run(() async {
      var n = 0, files = 0, dirs = 0;
      try {
        await for (final e in Directory(
          path,
        ).list(recursive: true, followLinks: false)) {
          if (e is File) {
            n += (await e.stat()).size;
            files++;
          } else if (e is Directory) {
            dirs++;
          }
        }
      } on FileSystemException {
        // partial
      }
      return (n, files, dirs);
    });

/// The SHA-256 of the file [path] in hex (a worker isolate).
Future<String> sha256OfFile(String path) => Isolate.run(() async {
  final h = Sha256();
  await for (final chunk in File(path).openRead()) {
    h.update(chunk is Uint8List ? chunk : Uint8List.fromList(chunk));
  }
  final b = StringBuffer();
  for (final x in h.digest()) {
    b.write(x.toRadixString(16).padLeft(2, '0'));
  }
  return b.toString();
});

/// "name (2).ext", "name (3).ext"... the first that does not exist in
/// [dir]. [copy]: "name (copy).ext" first.
Future<String> uniqueName(String dir, String name, {bool copy = false}) async {
  final ext = _extOf(name);
  final stem = name.substring(0, name.length - ext.length);
  if (copy) {
    final c = p.join(dir, '$stem (copy)$ext');
    if (!await _exists(c)) return c;
  }
  for (var k = 2; ; k++) {
    final c = p.join(dir, '$stem ($k)$ext');
    if (!await _exists(c)) return c;
  }
}

String _extOf(String name) {
  if (name.startsWith('.') && name.indexOf('.', 1) < 0) return '';
  for (final d in const ['.tar.gz', '.tar.bz2', '.tar.xz', '.tar.zst']) {
    if (name.toLowerCase().endsWith(d)) {
      return name.substring(name.length - d.length);
    }
  }
  final k = name.lastIndexOf('.');
  return k <= 0 ? '' : name.substring(k);
}

Future<bool> _exists(String path) async =>
    await FileSystemEntity.type(path, followLinks: false) !=
    FileSystemEntityType.notFound;

/// Copies or moves [src] into [destDir]; the path created, or null when
/// skipped.
Future<String?> _transfer(
  _Worker w,
  String src,
  String destDir,
  bool move,
) async {
  final name = p.basename(src);
  var dst = p.join(destDir, name);
  final srcType = await FileSystemEntity.type(src, followLinks: false);
  if (srcType == FileSystemEntityType.notFound) {
    w.errors.add('$src: not found');
    return null;
  }
  final srcDir = srcType == FileSystemEntityType.directory;
  if (srcDir && p.isWithin(src, destDir)) {
    w.errors.add('$name: a folder can not be copied into itself');
    return null;
  }
  if (p.equals(src, dst)) {
    if (move) {
      w.skipped++;
      return null;
    }
    dst = await uniqueName(destDir, name, copy: true);
  } else if (await _exists(dst)) {
    final dstDir = await FileSystemEntity.isDirectory(dst);
    final a = await w.ask(src, dst, srcDir, dstDir);
    switch (a.action) {
      case FsConflictAction.skip:
        w.skipped++;
        return null;
      case FsConflictAction.rename:
        dst = await uniqueName(destDir, name);
      case FsConflictAction.overwrite:
        if (!(srcDir && dstDir)) await _deleteAny(dst);
      case FsConflictAction.cancel:
        throw FsCancelled();
    }
  }
  if (move && !await _exists(dst)) {
    try {
      await (srcType == FileSystemEntityType.link
              ? Link(src)
              : srcDir
              ? Directory(src)
              : File(src))
          .rename(dst);
      w.doneBytes += await _sizeOf(dst);
      w.progress(dst);
      return dst;
    } on FileSystemException {
      // another file system: copy, then delete
    }
  }
  final ok = await _copyAny(w, src, dst, srcType);
  if (ok && move) {
    try {
      await _deleteAny(src);
    } on FileSystemException catch (e) {
      w.errors.add('$src: ${e.osError?.message ?? e.message}');
    }
  }
  return ok ? dst : null;
}

Future<bool> _copyAny(
  _Worker w,
  String src,
  String dst,
  FileSystemEntityType t,
) async {
  w.check();
  try {
    if (t == FileSystemEntityType.link) {
      await Link(dst).create(await Link(src).target());
      return true;
    }
    if (t == FileSystemEntityType.directory) {
      await Directory(dst).create(recursive: true);
      var ok = true;
      await for (final e in Directory(src).list(followLinks: false)) {
        final to = p.join(dst, p.basename(e.path));
        final et = await FileSystemEntity.type(e.path, followLinks: false);
        if (await _exists(to)) {
          final toDir = await FileSystemEntity.isDirectory(to);
          final isDir = et == FileSystemEntityType.directory;
          if (!(isDir && toDir)) {
            final a = await w.ask(e.path, to, isDir, toDir);
            if (a.action == FsConflictAction.skip) {
              w.skipped++;
              continue;
            }
            if (a.action == FsConflictAction.rename) {
              ok &= await _copyAny(
                w,
                e.path,
                await uniqueName(dst, p.basename(e.path)),
                et,
              );
              continue;
            }
            await _deleteAny(to);
          }
        }
        ok &= await _copyAny(w, e.path, to, et);
      }
      return ok;
    }
    return await _copyFile(w, src, dst);
  } on FileSystemException catch (e) {
    w.errors.add('$src: ${e.osError?.message ?? e.message}');
    return false;
  }
}

Future<bool> _copyFile(_Worker w, String src, String dst) async {
  final inF = File(src);
  final st = await inF.stat();
  final tmp = File(dst);
  final sink = tmp.openWrite();
  try {
    await for (final chunk in inF.openRead()) {
      if (w.cancelled) {
        await sink.close();
        await tmp.delete();
        throw FsCancelled();
      }
      sink.add(chunk);
      w.doneBytes += chunk.length;
      w.progress(src);
    }
    await sink.flush();
    await sink.close();
  } on FileSystemException {
    try {
      await sink.close();
    } on Object {
      // closed
    }
    rethrow;
  }
  try {
    await tmp.setLastModified(st.modified);
  } on FileSystemException {
    // not allowed on this file system
  }
  return true;
}

Future<void> _deleteAny(String path) async {
  final t = await FileSystemEntity.type(path, followLinks: false);
  switch (t) {
    case FileSystemEntityType.directory:
      await Directory(path).delete(recursive: true);
    case FileSystemEntityType.link:
      await Link(path).delete();
    case FileSystemEntityType.notFound:
      return;
    default:
      await File(path).delete();
  }
}

/// The freedesktop.org Trash specification (home trash): the item moves
/// to trash/files and its original path and date go to
/// `trash/info/NAME.trashinfo`. False when the item is on another file
/// system (then the caller asks for a permanent delete).
Future<bool> _xdgTrash(String path, String trash) async {
  try {
    final files = Directory(p.join(trash, 'files'));
    final info = Directory(p.join(trash, 'info'));
    await files.create(recursive: true);
    await info.create(recursive: true);
    final base = p.basename(path);
    var name = base;
    for (
      var k = 2;
      await _exists(p.join(files.path, name)) ||
          await File(p.join(info.path, '$name.trashinfo')).exists();
      k++
    ) {
      final ext = _extOf(base);
      name = '${base.substring(0, base.length - ext.length)}.$k$ext';
    }
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final date =
        '${now.year}-${two(now.month)}-${two(now.day)}T'
        '${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
    final infoFile = File(p.join(info.path, '$name.trashinfo'));
    await infoFile.writeAsString(
      '[Trash Info]\nPath=${Uri(path: p.absolute(path)).toString()}\n'
      'DeletionDate=$date\n',
    );
    final t = await FileSystemEntity.type(path, followLinks: false);
    final e = t == FileSystemEntityType.directory
        ? Directory(path) as FileSystemEntity
        : t == FileSystemEntityType.link
        ? Link(path)
        : File(path);
    try {
      await e.rename(p.join(files.path, name));
    } on FileSystemException {
      await infoFile.delete();
      return false;
    }
    return true;
  } on FileSystemException {
    return false;
  }
}

Future<bool> _macTrash(String path) async {
  final home = Platform.environment['HOME'];
  if (home == null) return false;
  try {
    final t = p.join(home, '.Trash');
    final dst = await _exists(p.join(t, p.basename(path)))
        ? await uniqueName(t, p.basename(path))
        : p.join(t, p.basename(path));
    final type = await FileSystemEntity.type(path, followLinks: false);
    await (type == FileSystemEntityType.directory
            ? Directory(path) as FileSystemEntity
            : File(path))
        .rename(dst);
    return true;
  } on FileSystemException {
    return false;
  }
}
