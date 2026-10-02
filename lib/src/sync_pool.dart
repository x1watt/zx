// Worker isolates for synchronous code (the .zx handler).
//
// The archive handlers run synchronously (the IInArchive / IOutArchive
// shape, docs/architecture.md section 6), and a synchronous caller can not
// receive a message from an isolate: the event loop does not run while it
// works. [WorkerPool] (pool.dart) needs it, so it serves the asynchronous
// paths (xz). This pool serves the synchronous ones: each job runs in an
// isolate spawned for it (its input travels in the spawn message), and the
// isolate writes its result to a file in a private temporary folder, which
// the caller polls while it waits (with short sleeps). The isolates start
// at once, without the event loop of the caller, so jobs run in parallel
// with each other and with the caller.
//
// Results are taken in any order by ticket; callers keep at most [threads]
// jobs in flight, so memory stays bounded by the number of workers. With
// one thread (or when the temporary folder can not be made) the jobs run
// inline, with the same results.

import 'dart:async';
import 'dart:convert';
import 'host/io.dart';
import 'dart:isolate';
import 'dart:typed_data';

import 'common/method_props.dart' show InvalidArgException;
import 'io/streams.dart';
import 'pool.dart' show defaultThreads;

/// The result of a job: its main bytes and a small metadata blob.
class SyncJobResult {
  final Uint8List data;
  final Uint8List meta;
  SyncJobResult(this.data, [Uint8List? meta]) : meta = meta ?? Uint8List(0);
}

/// A job function: runs in a worker isolate (or inline). [arg] and the
/// closure must be sendable to an isolate (typed data, numbers, strings,
/// plain objects of them).
typedef SyncJobFn = SyncJobResult Function(Object? arg);

/// Called with each temporary folder a pool makes, so that the owner of
/// the operation can delete it when the operation is cancelled
/// (zx_worker.dart sets it for its operations).
void Function(String dir)? syncPoolRegisterDir;

/// Called when the pool deletes its folder.
void Function(String dir)? syncPoolUnregisterDir;

class _Pending {
  final int ticket;
  final String? path;
  SyncJobResult? result;
  Object? error;
  final Stopwatch sinceSubmit = Stopwatch()..start();
  bool started = false;
  _Pending(this.ticket, this.path);
}

/// Runs [SyncJobFn]s in worker isolates from synchronous code.
class SyncJobPool {
  /// The number of jobs that run at once.
  final int threads;
  Directory? _dir;
  bool _noDir = false;
  int _next = 0;
  final Map<int, _Pending> _pending = {};

  SyncJobPool([int? threads]) : threads = threads ?? defaultThreads();

  /// Jobs submitted and not taken yet.
  int get inFlight => _pending.length;

  /// Jobs running in workers (not finished inline).
  int get running => _pending.values.where((p) => p.path != null).length;

  bool get _parallel => threads > 1 && !_noDir;

  String? _ensureDir() {
    if (_dir != null) return _dir!.path;
    try {
      final d = Directory.systemTemp.createTempSync('zx-jobs-');
      _dir = d;
      syncPoolRegisterDir?.call(d.path);
      return d.path;
    } on FileSystemException {
      _noDir = true;
      return null;
    }
  }

  /// Submits [fn] with [arg]; returns its ticket. Runs it inline when the
  /// pool has one thread; otherwise the caller should not have more than
  /// [threads] jobs running (take results first).
  int submit(SyncJobFn fn, Object? arg) {
    final ticket = _next++;
    final dir = _parallel ? _ensureDir() : null;
    if (dir == null) {
      final p = _Pending(ticket, null);
      try {
        p.result = fn(arg);
      } catch (e) {
        p.error = e;
      }
      _pending[ticket] = p;
      return ticket;
    }
    final path = '$dir${Platform.pathSeparator}$ticket';
    final p = _Pending(ticket, path);
    _pending[ticket] = p;
    try {
      unawaited(Isolate.spawn(_jobEntry, (path, fn, arg)).then((_) {},
          onError: (Object e) {
        // reported through the missing start file (see take)
      }));
    } catch (e) {
      p.error = e;
    }
    return ticket;
  }

  /// Waits for the job [ticket] and returns its result, or throws its
  /// error (a [SevenZipException] crosses unchanged).
  SyncJobResult take(int ticket) {
    final p = _pending.remove(ticket);
    if (p == null) throw StateError('no job $ticket');
    if (p.path == null || p.error != null) {
      final e = p.error;
      if (e != null) _rethrow(e);
      return p.result!;
    }
    final path = p.path!;
    final res = File('$path.r');
    var wait = 100;
    for (;;) {
      if (res.existsSync()) break;
      if (!p.started) {
        if (File('$path.s').existsSync()) {
          p.started = true;
        } else if (p.sinceSubmit.elapsed > const Duration(seconds: 120)) {
          throw SevenZipException(
              'zx: a worker isolate did not start', SevenZipError.io);
        }
      }
      sleep(Duration(microseconds: wait));
      if (wait < 20000) wait += wait >> 1;
    }
    final bytes = res.readAsBytesSync();
    try {
      res.deleteSync();
      File('$path.s').deleteSync();
    } on FileSystemException {
      // ignore
    }
    return _decode(bytes);
  }

  /// Deletes the temporary folder. Jobs still running finish in their
  /// isolates and their results are dropped.
  void close() {
    _pending.clear();
    final d = _dir;
    _dir = null;
    if (d != null) {
      try {
        d.deleteSync(recursive: true);
      } on FileSystemException {
        // ignore
      }
      syncPoolUnregisterDir?.call(d.path);
    }
  }
}

Never _rethrow(Object e) {
  if (e is Error) throw e;
  if (e is Exception) throw e;
  throw Exception('$e');
}

// result file: 'Z' 'J', status (0 ok, 1 error), then
//   ok: u32 meta length, meta, data
//   error: u8 kind (SevenZipError index, 255 other, 254 InvalidArg), text
Uint8List _encodeOk(SyncJobResult r) {
  final out = Uint8List(7 + r.meta.length + r.data.length);
  out[0] = 0x5A;
  out[1] = 0x4A;
  out[2] = 0;
  setUint32LE(out, 3, r.meta.length);
  out.setRange(7, 7 + r.meta.length, r.meta);
  out.setRange(7 + r.meta.length, out.length, r.data);
  return out;
}

Uint8List _encodeError(Object e) {
  int kind;
  String msg;
  if (e is InvalidArgException) {
    kind = 254;
    msg = e.message;
  } else if (e is SevenZipException) {
    kind = e.kind.index;
    msg = e.message;
  } else {
    kind = 255;
    msg = '$e';
  }
  final t = utf8.encode(msg);
  final out = Uint8List(4 + t.length);
  out[0] = 0x5A;
  out[1] = 0x4A;
  out[2] = 1;
  out[3] = kind;
  out.setRange(4, out.length, t);
  return out;
}

SyncJobResult _decode(Uint8List b) {
  if (b.length < 4 || b[0] != 0x5A || b[1] != 0x4A) {
    throw const SevenZipException('zx: bad worker result', SevenZipError.io);
  }
  if (b[2] == 0) {
    final ml = getUint32LE(b, 3);
    return SyncJobResult(
        Uint8List.sublistView(b, 7 + ml), Uint8List.sublistView(b, 7, 7 + ml));
  }
  final kind = b[3];
  final msg = utf8.decode(Uint8List.sublistView(b, 4), allowMalformed: true);
  if (kind < SevenZipError.values.length) {
    throw SevenZipException(msg, SevenZipError.values[kind]);
  }
  if (kind == 254) throw InvalidArgException(msg);
  throw SevenZipException(msg, SevenZipError.io);
}

void _jobEntry((String, SyncJobFn, Object?) m) {
  final (path, fn, arg) = m;
  try {
    File('$path.s').writeAsBytesSync(const []);
  } on FileSystemException {
    return; // the pool is gone
  }
  Uint8List out;
  try {
    out = _encodeOk(fn(arg));
  } catch (e) {
    out = _encodeError(e);
  }
  try {
    final tmp = File('$path.w');
    tmp.writeAsBytesSync(out);
    tmp.renameSync('$path.r');
  } on FileSystemException {
    // the pool is gone
  }
}
