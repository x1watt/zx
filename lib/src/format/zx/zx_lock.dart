// The writer lock of a .zx archive: one writer at a time across processes
// and isolates (a database commit of lib/src/db, an update or a
// compaction of zx_handler.dart).
//
// Processes: an exclusive lock (fcntl on POSIX, LockFileEx on Windows, as
// dart:io gives them) on `<archive>.zx-lock`. Such locks belong to the
// process, not to the isolate or the file handle (and on POSIX closing any
// handle of the file drops them), so isolates of one process are told
// apart first by a marker file, `<archive>.zx-lock.<pid>`, created with
// exclusive create: only the isolate that made it opens the lock file.
// The marker holds the start time of the process (Linux) so that a marker
// left by a crashed process whose pid was reused is recognised as stale.
//
// Limit: an isolate killed while it holds the lock leaves its marker; the
// other isolates of that process then wait until the process ends. Stale
// markers of dead processes are removed.

import 'dart:io';

import '../../io/streams.dart';

/// The lock of one archive, held by this isolate.
class ZxWriteLock {
  final String path;
  final String _marker;
  RandomAccessFile? _file;

  ZxWriteLock._(this.path, this._marker, this._file);

  /// The path of the lock file of [archivePath].
  static String lockPathOf(String archivePath) => '$archivePath.zx-lock';

  static String? _identity;

  // "pid starttime" (the start time from /proc/self/stat on Linux), which
  // tells a live process from a crashed one with a reused pid
  static String get _self {
    final id = _identity;
    if (id != null) return id;
    var start = '';
    if (Platform.isLinux || Platform.isAndroid) {
      start = _startTimeOf('self') ?? '';
    }
    return _identity = '$pid $start';
  }

  static String? _startTimeOf(String p) {
    try {
      final s = File('/proc/$p/stat').readAsStringSync();
      // the fields after the command (which may hold spaces)
      final close = s.lastIndexOf(')');
      final f = s.substring(close + 2).split(' ');
      return f.length > 19 ? f[19] : null;
    } on FileSystemException {
      return null;
    }
  }

  // whether the process that wrote a marker ("pid starttime") is gone; an
  // empty marker is being written, unless it is old
  static bool _isStale(File marker) {
    final content = marker.readAsStringSync();
    if (content.trim().isEmpty) {
      final age = DateTime.now().difference(marker.lastModifiedSync());
      return age.inSeconds > 10;
    }
    final parts = content.trim().split(' ');
    final p = int.tryParse(parts[0]);
    if (p == null) return true;
    if (!(Platform.isLinux || Platform.isAndroid)) return false;
    if (!Directory('/proc/$p').existsSync()) return true;
    final st = parts.length > 1 ? parts[1] : '';
    return st.isNotEmpty && _startTimeOf('$p') != st;
  }

  /// Takes the lock of [archivePath], waiting up to [waitMs] ms (0: one
  /// try). Returns null when another writer holds it that long.
  static ZxWriteLock? tryAcquire(String archivePath, {int waitMs = 0}) {
    final lockPath = lockPathOf(archivePath);
    final marker = '$lockPath.$pid';
    final sw = Stopwatch()..start();
    var nap = 1;
    for (;;) {
      final got = _tryOnce(lockPath, marker);
      if (got != null) return got;
      if (sw.elapsedMilliseconds >= waitMs) return null;
      sleep(Duration(milliseconds: nap));
      if (nap < 20) nap *= 2;
    }
  }

  /// As [tryAcquire], but throws [SevenZipException] when the lock is not
  /// free after [waitMs] ms.
  static ZxWriteLock acquire(String archivePath, {int waitMs = 5000}) {
    final l = tryAcquire(archivePath, waitMs: waitMs);
    if (l == null) {
      throw SevenZipException(
          'zx: another writer holds the archive (${lockPathOf(archivePath)})',
          SevenZipError.io);
    }
    return l;
  }

  static ZxWriteLock? _tryOnce(String lockPath, String marker) {
    final mf = File(marker);
    try {
      mf.createSync(exclusive: true);
    } on FileSystemException {
      // another isolate of this process, or a stale marker
      try {
        if (_isStale(mf)) mf.deleteSync();
      } on FileSystemException {
        // it went away meanwhile
      }
      return null;
    }
    try {
      mf.writeAsStringSync(_self, flush: true);
    } on FileSystemException {
      // the marker exists, which is what counts
    }
    RandomAccessFile? f;
    try {
      f = File(lockPath).openSync(mode: FileMode.append);
      f.lockSync(FileLock.exclusive);
      return ZxWriteLock._(lockPath, marker, f);
    } on FileSystemException {
      try {
        f?.closeSync();
      } on FileSystemException {
        // ignore
      }
      _deleteQuietly(marker);
      return null;
    }
  }

  static void _deleteQuietly(String p) {
    try {
      File(p).deleteSync();
    } on FileSystemException {
      // ignore
    }
  }

  bool get isHeld => _file != null;

  /// Releases the lock (the lock file stays, empty).
  void release() {
    final f = _file;
    if (f == null) return;
    _file = null;
    try {
      f.unlockSync();
    } on FileSystemException {
      // closing drops it anyway
    }
    try {
      f.closeSync();
    } on FileSystemException {
      // ignore
    }
    _deleteQuietly(_marker);
  }
}
