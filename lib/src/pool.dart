// Worker isolates for one operation (the Dart counterpart of the SDK's
// MtCoder threads).

import 'dart:async';
import 'dart:collection';
import 'host/io.dart';
import 'dart:isolate';

/// Default number of worker isolates: half of the processors on a computer
/// (1..8) and at most 4 on a phone, so the device stays usable.
int defaultThreads() {
  final n = Platform.numberOfProcessors;
  if (Platform.isAndroid || Platform.isIOS) {
    return (n ~/ 2).clamp(1, 4);
  }
  return (n ~/ 2).clamp(1, 8);
}

/// A fixed set of long-lived worker isolates running submitted closures.
///
/// The isolates are spawned once per operation, not per item. Callers keep
/// the amount of work in flight bounded by awaiting results in order.
/// Closures must capture only sendable data; wrap large buffers in
/// `TransferableTypedData` to avoid copies.
class WorkerPool {
  final List<Isolate> _isolates = [];
  final List<SendPort?> _ports;
  final List<bool> _busy;
  final ReceivePort _results = ReceivePort();
  final Map<int, Completer<Object?>> _pending = {};
  final ListQueue<(int, Object? Function())> _queue = ListQueue();
  int _nextId = 0;

  WorkerPool._(int size)
      : _ports = List.filled(size, null),
        _busy = List.filled(size, false);

  int get size => _ports.length;

  /// Spawns [size] workers. [onSpawn] sees each new isolate, so that the
  /// owner of the operation can kill them on cancellation.
  static Future<WorkerPool> spawn(int size,
      {void Function(Isolate isolate)? onSpawn}) async {
    final pool = WorkerPool._(size);
    final ready = Completer<void>();
    var count = 0;
    pool._results.listen((m) {
      if (m is (int, SendPort)) {
        pool._ports[m.$1] = m.$2;
        if (++count == size) ready.complete();
      } else {
        pool._onResult(m as (int, int, bool, Object?));
      }
    });
    for (var i = 0; i < size; ++i) {
      final iso = await Isolate.spawn(_workerMain, (pool._results.sendPort, i));
      pool._isolates.add(iso);
      onSpawn?.call(iso);
    }
    await ready.future;
    return pool;
  }

  void _onResult((int, int, bool, Object?) m) {
    final (worker, id, ok, value) = m;
    final c = _pending.remove(id);
    _busy[worker] = false;
    if (c != null) {
      if (ok) {
        c.complete(value);
      } else {
        c.completeError(value ?? 'worker error');
      }
    }
    _dispatch();
  }

  void _dispatch() {
    while (_queue.isNotEmpty) {
      final free = _busy.indexOf(false);
      if (free < 0) return;
      final job = _queue.removeFirst();
      _busy[free] = true;
      _ports[free]!.send(job);
    }
  }

  /// Runs [fn] on a worker and returns its result.
  Future<T> run<T>(FutureOr<T> Function() fn) {
    final id = _nextId++;
    final c = Completer<Object?>();
    _pending[id] = c;
    _queue.add((id, fn));
    _dispatch();
    return c.future.then((v) => v as T);
  }

  void close() {
    for (final i in _isolates) {
      i.kill(priority: Isolate.immediate);
    }
    _results.close();
  }
}

void _workerMain((SendPort, int) args) {
  final (results, index) = args;
  final port = ReceivePort();
  results.send((index, port.sendPort));
  port.listen((m) async {
    final (id, fn) = m as (int, Object? Function());
    try {
      var r = fn();
      if (r is Future) r = await r;
      results.send((index, id, true, r));
    } catch (e) {
      try {
        results.send((index, id, false, e));
      } catch (_) {
        String msg;
        try {
          msg = e.toString();
        } catch (_) {
          msg = 'worker error';
        }
        results.send((index, id, false, msg));
      }
    }
  });
}
