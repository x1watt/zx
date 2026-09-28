// The asynchronous API of zxdb for Flutter apps: ZxDatabase (zxdb.dart)
// runs in a worker isolate, and every call is a message to it, so nothing
// heavy (page decoding, commits, fsync, folds with zcm) runs on the
// caller's isolate. The worker keeps the database open between calls
// (caches stay warm), commits group commits by its timer, forwards the
// changes of the KV stores for watch(), and folds the write buffer in a
// second isolate when it grows past ZxDbStoreOptions.autoFoldBytes (the
// coding runs without the writer lock, see ZxDbStore.fold).

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'sql/zx_sql.dart' show ZxSqlResult;
import 'zxdb.dart';

/// A [ZxDatabase] in a worker isolate.
class ZxDatabaseAsync {
  final SendPort _cmd;
  final ReceivePort _replies;
  final Isolate _isolate;
  final Map<int, Completer<Object?>> _calls = {};
  int _next = 0;
  bool _closed = false;
  bool _watching = false;
  final StreamController<ZxKvChange> _changes =
      StreamController<ZxKvChange>.broadcast();

  ZxDatabaseAsync._(this._cmd, this._replies, this._isolate) {
    _replies.listen(_onReply);
  }

  /// Opens the database of the archive at [archivePath] in a worker
  /// isolate (see ZxDatabase.open).
  static Future<ZxDatabaseAsync> open(String archivePath,
      {String? password,
      bool readOnly = false,
      bool create = false,
      Duration? groupCommit,
      ZxDbStoreOptions? options}) async {
    final replies = ReceivePort();
    final first = Completer<Object?>();
    late StreamSubscription<Object?> sub;
    final ready = ReceivePort();
    sub = ready.listen((m) {
      if (!first.isCompleted) first.complete(m);
    });
    final iso = await Isolate.spawn(_worker, [
      ready.sendPort,
      replies.sendPort,
      archivePath,
      password,
      readOnly,
      create,
      groupCommit?.inMicroseconds,
      options ?? ZxDbStoreOptions(),
    ]);
    final m = await first.future;
    await sub.cancel();
    ready.close();
    if (m is SendPort) return ZxDatabaseAsync._(m, replies, iso);
    replies.close();
    iso.kill();
    throw _error(m as List);
  }

  /// Whether the archive at [archivePath] holds a database (checked in a
  /// background isolate, which reads the archive's last Index).
  static Future<bool> hasDatabase(String archivePath, {String? password}) =>
      Isolate.run(() {
        final s = ZxDbStore.open(archivePath,
            password: password, readOnly: true);
        try {
          return s.root != null;
        } finally {
          s.close();
        }
      });

  static Object _error(List m) {
    final kind = m[1] as int;
    if (kind < 0) return StateError(m[0] as String);
    return ZxDbException(m[0] as String, ZxDbError.values[kind]);
  }

  void _onReply(Object? m) {
    final l = m as List;
    final id = l[0] as int;
    if (id < 0) {
      // a change of a KV store
      _changes.add(ZxKvChange(l[1] as String, l[2] as Uint8List,
          l[3] as Uint8List?, l[4] as int));
      return;
    }
    final c = _calls.remove(id);
    if (c == null) return;
    if (l[1] == true) {
      c.complete(l[2]);
    } else {
      c.completeError(_error(l[2] as List));
    }
  }

  Future<Object?> _call(String op, [List<Object?> args = const []]) {
    if (_closed) return Future.error(StateError('the database is closed'));
    final id = _next++;
    final c = Completer<Object?>();
    _calls[id] = c;
    _cmd.send([id, op, ...args]);
    return c.future;
  }

  // ---- key-value stores

  /// KV store [name] (not checked until it is used).
  ZxKvStoreAsync kv(String name) => ZxKvStoreAsync._(this, name);

  Future<ZxKvStoreAsync> createKvStore(String name,
      {Duration? ttl, String? compression = 'fast', int? pageSize}) async {
    await _call('create', [name, ttl?.inMilliseconds, compression, pageSize]);
    return kv(name);
  }

  Future<void> dropKvStore(String name) => _call('drop', [name]);

  Future<List<String>> kvStores() async =>
      (await _call('stores') as List).cast<String>();

  /// The changes of KV store [store] committed by this database (keys
  /// with [prefix]).
  Stream<ZxKvChange> watch(String store, {Uint8List? prefix}) {
    if (!_watching) {
      _watching = true;
      _call('watch');
    }
    return _changes.stream.where((c) {
      if (c.store != store) return false;
      if (prefix == null) return true;
      if (c.key.length < prefix.length) return false;
      for (var i = 0; i < prefix.length; i++) {
        if (c.key[i] != prefix[i]) return false;
      }
      return true;
    });
  }

  // ---- SQL

  /// Runs SQL in the worker's session (ZxDatabase.sql); [params] is a
  /// list or a map of SQL values (null, int, double, String, Uint8List).
  Future<ZxSqlResult> execute(String sql, [Object? params]) async {
    final l = await _call('sql', [sql, params]) as List;
    return ZxSqlResult((l[0] as List).cast<String>(),
        [for (final r in l[1] as List) (r as List).cast<Object?>()],
        l[2] as int, l[3] as int);
  }

  /// The names of the time series (ZxDatabase.seriesNames).
  Future<List<String>> seriesNames() async =>
      (await _call('series') as List).cast<String>();

  /// Makes a new SQL session (ZxDatabase.resetSql): it sees the files the
  /// archive has now (after an update of the archive).
  Future<void> resetSql() => _call('resetSql');

  /// The rows of a query.
  Future<List<List<Object?>>> select(String sql, [Object? params]) async =>
      (await execute(sql, params)).rows;

  // ---- generations and maintenance

  Future<List<({int generation, int timeNs, String? comment})>>
      generations() async {
    final l = await _call('generations') as List;
    return [
      for (final g in l)
        (
          generation: (g as List)[0] as int,
          timeNs: g[1] as int,
          comment: g[2] as String?
        )
    ];
  }

  /// Commits a pending group commit.
  Future<void> flush() => _call('flush');

  /// See ZxDatabase.fold.
  Future<ZxDbFoldResult> fold() async {
    final l = await _call('fold') as List;
    return ZxDbFoldResult(l[0] as int, l[1] as int, l[2] as int, l[3] as int?);
  }

  /// See ZxDatabase.vacuum.
  Future<int> vacuum(
          {int keep = 1, bool recompress = false, bool ultra = false}) async =>
      await _call('vacuum', [keep, recompress, ultra]) as int;

  /// Commits what is pending, waits for a background fold, closes.
  Future<void> close() async {
    if (_closed) return;
    try {
      await _call('close');
    } finally {
      _closed = true;
      _replies.close();
      _isolate.kill();
      await _changes.close();
    }
  }
}

/// A KV store of a [ZxDatabaseAsync].
class ZxKvStoreAsync {
  final ZxDatabaseAsync db;
  final String name;
  ZxKvStoreAsync._(this.db, this.name);

  /// The value of [key] (at [generation] when given), or null.
  Future<Uint8List?> get(Uint8List key, {int? generation}) async =>
      await db._call('get', [name, key, generation]) as Uint8List?;

  Future<void> put(Uint8List key, Uint8List value, {Duration? ttl}) =>
      db._call('put', [name, key, value, ttl?.inMilliseconds]);

  Future<bool> delete(Uint8List key) async =>
      await db._call('delete', [name, key]) as bool;

  /// Applies the writes of [build] in one transaction.
  Future<void> batch(void Function(ZxKvBatch b) build) {
    final b = ZxKvBatch();
    build(b);
    return db._call('batch', [
      name,
      [
        for (final (k, v, ttl) in b.ops) [k, v, ttl?.inMilliseconds]
      ]
    ]);
  }

  /// The live entries with [prefix] or in [from, to), at most [limit].
  Future<List<ZxKvEntry>> scan(
      {Uint8List? prefix,
      Uint8List? from,
      Uint8List? to,
      bool reverse = false,
      int? limit,
      int? generation}) async {
    final l = await db._call(
        'scan', [name, prefix, from, to, reverse, limit, generation]) as List;
    return [
      for (final e in l)
        ZxKvEntry((e as List)[0] as Uint8List, e[1] as Uint8List, e[2] as int?)
    ];
  }

  Stream<ZxKvChange> watch({Uint8List? prefix}) =>
      db.watch(name, prefix: prefix);

  Future<int> purgeExpired() async => await db._call('purge', [name]) as int;
}

// ---------------------------------------------------------------------------
// the worker isolate

List<Object?> _errorOf(Object e) {
  if (e is ZxDbException) return [e.message, e.kind.index];
  return ['$e', -1];
}

void _worker(List<Object?> args) {
  final ready = args[0] as SendPort;
  final out = args[1] as SendPort;
  final path = args[2] as String;
  final password = args[3] as String?;
  final readOnly = args[4] as bool;
  final create = args[5] as bool;
  final gcUs = args[6] as int?;
  final options = args[7] as ZxDbStoreOptions;
  ZxDatabase db;
  try {
    db = ZxDatabase.open(path,
        password: password,
        readOnly: readOnly,
        create: create,
        groupCommit: gcUs == null ? null : Duration(microseconds: gcUs),
        options: options);
  } catch (e) {
    ready.send(_errorOf(e));
    return;
  }
  final cmd = ReceivePort();
  Future<void>? folding;

  void maybeFold() {
    final limit = options.autoFoldBytes;
    if (limit <= 0 || folding != null || readOnly) return;
    if (db.store.foldBacklogBytes <= limit) return;
    folding = Isolate.run(() {
      final s = ZxDbStore.open(path, password: password, options: options);
      try {
        s.fold(waitMs: 60000);
      } finally {
        s.close();
      }
    }).catchError((Object _) {}).whenComplete(() => folding = null);
  }

  db.onCommit = (_) => maybeFold();

  cmd.listen((m) async {
    final l = m as List;
    final id = l[0] as int;
    final op = l[1] as String;
    try {
      Object? r;
      switch (op) {
        case 'get':
          final g = l[4] as int?;
          r = db.kv(l[2] as String, generation: g).get(l[3] as Uint8List);
        case 'put':
          final ttl = l[5] as int?;
          db.kv(l[2] as String).put(l[3] as Uint8List, l[4] as Uint8List,
              ttl: ttl == null ? null : Duration(milliseconds: ttl));
        case 'delete':
          r = db.kv(l[2] as String).delete(l[3] as Uint8List);
        case 'batch':
          final ops = l[3] as List;
          db.kvApply(l[2] as String, [
            for (final o in ops)
              (
                (o as List)[0] as Uint8List,
                o[1] as Uint8List?,
                o[2] == null ? null : Duration(milliseconds: o[2] as int)
              )
          ]);
        case 'scan':
          final g = l[8] as int?;
          r = [
            for (final e in db.kv(l[2] as String, generation: g).scan(
                prefix: l[3] as Uint8List?,
                from: l[4] as Uint8List?,
                to: l[5] as Uint8List?,
                reverse: l[6] as bool,
                limit: l[7] as int?))
              [e.key, e.value, e.expiresAtMs]
          ];
        case 'purge':
          r = db.kvPurge(l[2] as String);
        case 'create':
          final ttl = l[3] as int?;
          db.createKvStore(l[2] as String,
              ttl: ttl == null ? null : Duration(milliseconds: ttl),
              compression: l[4] as String?,
              pageSize: l[5] as int?);
        case 'drop':
          db.dropKvStore(l[2] as String);
        case 'stores':
          r = db.kvStores;
        case 'watch':
          db.changes.listen((c) =>
              out.send([-1, c.store, c.key, c.value, c.generation]));
        case 'sql':
          final res = db.sql.execute(l[2] as String, l[3]);
          r = [res.columns, res.rows, res.changes, res.lastInsertRowid];
        case 'series':
          r = db.seriesNames;
        case 'resetSql':
          db.resetSql();
        case 'generations':
          r = [
            for (final g in db.generations) [g.generation, g.timeNs, g.comment]
          ];
        case 'flush':
          db.flush();
        case 'fold':
          await folding;
          final f = db.fold();
          r = [f.pages, f.bytesIn, f.bytesOut, f.generation];
        case 'vacuum':
          await folding;
          r = db.vacuum(
              keep: l[2] as int, recompress: l[3] as bool, ultra: l[4] as bool);
        case 'close':
          await folding;
          db.close();
          out.send([id, true, null]);
          cmd.close();
          return;
        default:
          throw ZxDbException('unknown operation $op', ZxDbError.unsupported);
      }
      out.send([id, true, r]);
    } catch (e) {
      out.send([id, false, _errorOf(e)]);
    }
  });
  ready.send(cmd.sendPort);
}
