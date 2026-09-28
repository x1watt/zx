// The asynchronous API of zxdb for Flutter apps: ZxDatabase (zxdb.dart)
// runs in a worker isolate, and every call is a message to it, so nothing
// heavy (page decoding, commits, fsync, folds with zcm) runs on the
// caller's isolate. The worker keeps the database open between calls
// (caches stay warm), commits group commits by its timer, forwards the
// changes of the KV stores for watch(), and folds the write buffer in a
// second isolate when it grows past ZxDbStoreOptions.autoFoldBytes (the
// coding runs without the writer lock, see ZxDbStore.fold).
//
// Time series (ZxSeriesAsync): rows cross the isolate boundary packed by
// column (_packColumns): integers as an Int64List, floats as a
// Float64List, anything else (texts) as a List; big typed sections go as
// TransferableTypedData (no copy). A column of Lists crosses the boundary
// much faster than a List of row Lists (fewer objects to copy). A query is a cursor in the worker that yields one packed batch
// per request: the Stream asks for the next batch only while it is not
// paused, so a slow listener holds at most one batch in flight.

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
        final s =
            ZxDbStore.open(archivePath, password: password, readOnly: true);
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
      _changes.add(ZxKvChange(
          l[1] as String, l[2] as Uint8List, l[3] as Uint8List?, l[4] as int));
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
    return ZxSqlResult(
        (l[0] as List).cast<String>(),
        [for (final r in l[1] as List) (r as List).cast<Object?>()],
        l[2] as int,
        l[3] as int,
        types: l.length > 4 ? (l[4] as List).cast<String?>() : const []);
  }

  /// The names of the time series (ZxDatabase.seriesNames).
  Future<List<String>> seriesNames() async =>
      (await _call('series') as List).cast<String>();

  // ---- time series

  /// Time series [name] (not checked until it is used).
  ZxSeriesAsync series(String name) => ZxSeriesAsync._(this, name);

  /// See ZxDatabase.createSeries.
  Future<ZxSeriesAsync> createSeries(String name, List<ZxTsColumn> columns,
      {String? partitionBy,
      String? retention,
      String? compression,
      String? fts,
      List<String> tags = const [],
      int? segmentRows,
      int? sealRows}) async {
    await _call('tsCreate', [
      name,
      [
        for (final c in columns) [c.name, c.type]
      ],
      partitionBy,
      retention,
      compression,
      fts,
      tags,
      segmentRows,
      sealRows
    ]);
    return series(name);
  }

  /// Drops series [name], its data and its rollups.
  Future<void> dropSeries(String name) => _call('tsDrop', [name]);

  /// Seals every series (ZxDatabase.sealAllSeries).
  Future<void> sealAllSeries() => _call('tsSealAll');

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

/// A time series of a [ZxDatabaseAsync]: the calls of ZxSeries, with rows
/// packed by column across the isolate boundary.
class ZxSeriesAsync {
  final ZxDatabaseAsync db;
  final String name;
  List<String>? _columns;
  ZxSeriesAsync._(this.db, this.name);

  /// The column names in order (asked once, then cached).
  Future<List<String>> columns() async =>
      _columns ??= (await db._call('tsColumns', [name]) as List).cast<String>();

  /// Appends [rows] (Lists in column order or Maps by column name; times
  /// as ns, DateTime or text) in one transaction of the worker; seals
  /// when the buffer reaches the series' seal_rows. The rows go as one
  /// packed message, so call it with batches (thousands of rows), not
  /// row by row.
  Future<void> appendAll(Iterable<Object> rows) async {
    final list = rows is List<Object> ? rows : rows.toList();
    if (list.isEmpty) return;
    List<String>? names;
    if (list.any((r) => r is Map)) names = await columns();
    final nc = names?.length ??
        list.fold<int>(0, (m, r) => r is List && r.length > m ? r.length : m);
    final cols =
        List.generate(nc, (_) => List<Object?>.filled(list.length, null));
    for (var i = 0; i < list.length; i++) {
      final r = list[i];
      if (r is List) {
        for (var c = 0; c < r.length && c < nc; c++) {
          cols[c][i] = r[c];
        }
      } else if (r is Map) {
        for (final e in r.entries) {
          final c = names!.indexOf('${e.key}');
          if (c < 0) {
            throw ZxDbException(
                'no column ${e.key} in $name', ZxDbError.constraint);
          }
          cols[c][i] = e.value;
        }
      } else {
        throw ArgumentError('a row is a List or a Map');
      }
    }
    await db._call('tsAppend', [name, _packColumns(list.length, cols)]);
  }

  /// Appends one row (a message and a transaction: prefer [appendAll]).
  Future<void> append(Object row) => appendAll([row]);

  /// See ZxSeries.seal.
  Future<ZxTsSealResult> seal({int threads = 4}) async {
    final l = await db._call('tsSeal', [name, threads]) as List;
    return ZxTsSealResult(l[0] as int, l[1] as int, l[2] as int, l[3] as int);
  }

  /// See ZxSeries.stats.
  Future<({int rows, int segments, int bytes, int buffered, int partitions})>
      stats() async {
    final l = await db._call('tsStats', [name]) as List;
    return (
      rows: l[0] as int,
      segments: l[1] as int,
      bytes: l[2] as int,
      buffered: l[3] as int,
      partitions: l[4] as int
    );
  }

  /// The rows of a scan (see ZxSeries.scan) as batches of at most
  /// [batchRows] rows, each a List of rows (Lists of [columns], all by
  /// default). The worker reads the next batch only when the listener
  /// is ready for it (pause holds it back; cancel ends the scan). The
  /// scan reads the snapshot of the moment it starts; [generation] reads
  /// the series as of that generation.
  Stream<List<List<Object?>>> scanBatches(
      {Object? from,
      Object? to,
      List<String>? columns,
      Map<String, Object?> where = const {},
      String? match,
      bool descending = false,
      int? limit,
      int? generation,
      int batchRows = 4096}) {
    int? cursor;
    var pending = false;
    var done = false;
    var cancelled = false;
    late StreamController<List<List<Object?>>> ctl;
    Future<void> closeCursor() async {
      cancelled = true;
      final c = cursor;
      if (c == null || done) return;
      done = true;
      try {
        await db._call('tsClose', [c]);
      } catch (_) {}
    }

    void pull() {
      if (pending || done || cancelled || ctl.isPaused || ctl.isClosed) {
        return;
      }
      pending = true;
      Future<void> step() async {
        cursor ??= await db._call('tsOpen', [
          name,
          _timeArg(from),
          _timeArg(to),
          columns,
          where,
          match,
          descending,
          limit,
          generation
        ]) as int;
        if (cancelled) {
          pending = false;
          done = false;
          await closeCursor();
          return;
        }
        final l = await db._call('tsNext', [cursor, batchRows]) as List;
        pending = false;
        if (cancelled) {
          if (l[1] != true) {
            done = false;
            await closeCursor();
          }
          return;
        }
        final rows = _unpackRows(l[0] as List);
        if (l[1] == true) done = true;
        if (ctl.isClosed) return;
        if (rows.isNotEmpty) ctl.add(rows);
        if (done) {
          await ctl.close();
        } else {
          pull();
        }
      }

      step().catchError((Object e) {
        pending = false;
        done = true;
        if (!ctl.isClosed) {
          ctl.addError(e);
          ctl.close();
        }
      });
    }

    ctl = StreamController<List<List<Object?>>>(
        onListen: pull, onResume: pull, onCancel: closeCursor);
    return ctl.stream;
  }

  /// All rows of a scan (see [scanBatches]).
  Future<List<List<Object?>>> query(
      {Object? from,
      Object? to,
      List<String>? columns,
      Map<String, Object?> where = const {},
      String? match,
      bool descending = false,
      int? limit,
      int? generation}) async {
    final out = <List<Object?>>[];
    await for (final b in scanBatches(
        from: from,
        to: to,
        columns: columns,
        where: where,
        match: match,
        descending: descending,
        limit: limit,
        generation: generation,
        batchRows: 16384)) {
      out.addAll(b);
    }
    return out;
  }
}

Object? _timeArg(Object? v) =>
    v is DateTime ? v.microsecondsSinceEpoch * 1000 : v;

// ---------------------------------------------------------------------------
// rows packed by column

const _transferBytes = 64 * 1024;

Object _typed(TypedData d) =>
    d.lengthInBytes >= _transferBytes ? TransferableTypedData.fromList([d]) : d;

ByteBuffer _bufferOf(Object o) =>
    o is TransferableTypedData ? o.materialize() : (o as TypedData).buffer;

/// Packs [n] rows given as columns: per column [kind, data, nulls]:
/// 0 all NULL, 1 Int64List, 2 Float64List, 4 a List of any values
/// (texts go as a List of Strings: sending one is a flat copy, cheaper
/// than joining them). nulls is a Uint8List (1 = NULL) or null.
List<Object?> _packColumns(int n, List<List<Object?>> cols) => [
      n,
      for (final c in cols) _packColumn(n, c),
    ];

List<Object?> _packColumn(int n, List<Object?> c) {
  var ints = true, doubles = true, nulls = 0;
  for (var i = 0; i < n; i++) {
    var v = c[i];
    if (v is DateTime) c[i] = v = v.microsecondsSinceEpoch * 1000;
    if (v == null) {
      nulls++;
      continue;
    }
    if (v is! int) ints = false;
    if (v is! double) doubles = false;
    if (!ints && !doubles) break;
  }
  if (nulls == n) return const [0];
  Uint8List? mask;
  if (nulls > 0 && (ints || doubles)) {
    mask = Uint8List(n);
    for (var i = 0; i < n; i++) {
      if (c[i] == null) mask[i] = 1;
    }
  }
  if (ints) {
    final d = Int64List(n);
    for (var i = 0; i < n; i++) {
      final v = c[i];
      if (v != null) d[i] = v as int;
    }
    return [1, _typed(d), mask];
  }
  if (doubles) {
    final d = Float64List(n);
    for (var i = 0; i < n; i++) {
      final v = c[i];
      if (v != null) d[i] = v as double;
    }
    return [2, _typed(d), mask];
  }
  return [4, c];
}

/// The columns of a packed batch (see [_packColumns]).
List<List<Object?>> _unpackColumns(List p) {
  final n = p[0] as int;
  final out = <List<Object?>>[];
  for (var k = 1; k < p.length; k++) {
    final c = p[k] as List;
    final kind = c[0] as int;
    if (kind == 0) {
      out.add(List<Object?>.filled(n, null));
      continue;
    }
    if (kind == 4) {
      out.add((c[1] as List).cast<Object?>());
      continue;
    }
    final mask = c[2] as Uint8List?;
    final col = List<Object?>.filled(n, null);
    switch (kind) {
      case 1:
        final d = _bufferOf(c[1]!).asInt64List(0, n);
        for (var i = 0; i < n; i++) {
          if (mask == null || mask[i] == 0) col[i] = d[i];
        }
      default:
        final d = _bufferOf(c[1]!).asFloat64List(0, n);
        for (var i = 0; i < n; i++) {
          if (mask == null || mask[i] == 0) col[i] = d[i];
        }
    }
    out.add(col);
  }
  return out;
}

/// Rows of a packed batch.
List<List<Object?>> _unpackRows(List p) {
  final n = p[0] as int;
  final cols = _unpackColumns(p);
  return [
    for (var i = 0; i < n; i++) [for (final c in cols) c[i]]
  ];
}

/// Test hooks: packs rows (Lists) and unpacks them again.
List<Object?> zxTsPackRowsForTest(List<List<Object?>> rows, int columns) =>
    _packColumns(rows.length, [
      for (var c = 0; c < columns; c++)
        [for (final r in rows) c < r.length ? r[c] : null]
    ]);
List<List<Object?>> zxTsUnpackRowsForTest(List<Object?> packed) =>
    _unpackRows(packed);

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
  final scans = <int, (ZxTsScan, List<int>, int?)>{};
  var nextScan = 0;

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
          db.changes.listen(
              (c) => out.send([-1, c.store, c.key, c.value, c.generation]));
        case 'sql':
          final res = db.sql.execute(l[2] as String, l[3]);
          r = [
            res.columns,
            res.rows,
            res.changes,
            res.lastInsertRowid,
            res.types
          ];
        case 'series':
          r = db.seriesNames;
        case 'tsCreate':
          db.createSeries(
              l[2] as String,
              [
                for (final c in l[3] as List)
                  ZxTsColumn((c as List)[0] as String, c[1] as String)
              ],
              partitionBy: l[4] as String?,
              retention: l[5] as String?,
              compression: l[6] as String?,
              fts: l[7] as String?,
              tags: (l[8] as List).cast<String>(),
              segmentRows: l[9] as int?,
              sealRows: l[10] as int?);
        case 'tsDrop':
          db.dropSeries(l[2] as String);
        case 'tsSealAll':
          db.sealAllSeries();
        case 'tsColumns':
          r = [for (final c in db.series(l[2] as String).def.columns) c.name];
        case 'tsAppend':
          final p = l[3] as List;
          final n = p[0] as int;
          final cols = _unpackColumns(p);
          db.series(l[2] as String).appendAll([
            for (var i = 0; i < n; i++) [for (final c in cols) c[i]]
          ]);
        case 'tsSeal':
          final s = db
              .series(l[2] as String)
              .seal(options: ZxTsSealOptions(threads: l[3] as int));
          r = [s.rows, s.segments, s.partitionsDropped, s.bytes];
        case 'tsStats':
          final s = db.series(l[2] as String).stats;
          r = [s.rows, s.segments, s.bytes, s.buffered, s.partitions];
        case 'tsOpen':
          final g = l[10] as int?;
          final sr = db.series(l[2] as String, generation: g);
          final names = (l[5] as List?)?.cast<String>();
          final sc = sr.scan(
              from: l[3],
              to: l[4],
              columns: names,
              where: (l[6] as Map).cast<String, Object?>(),
              match: l[7] as String?,
              descending: l[8] as bool);
          final d = sc.def;
          final idx = names == null
              ? [for (var i = 0; i < d.columns.length; i++) i]
              : [for (final c in names) d.columnIndex(c)];
          r = nextScan++;
          scans[r as int] = (sc, idx, l[9] as int?);
        case 'tsNext':
          final k = l[2] as int;
          final e = scans[k];
          if (e == null) {
            throw const ZxDbException('no such scan', ZxDbError.notFound);
          }
          final (sc, idx, left) = e;
          var want = l[3] as int;
          if (left != null && left < want) want = left;
          final cols = [for (final _ in idx) <Object?>[]];
          var n = 0;
          var end = false;
          while (n < want) {
            if (!sc.moveNext()) {
              end = true;
              break;
            }
            for (var j = 0; j < idx.length; j++) {
              cols[j].add(sc.value(idx[j]));
            }
            n++;
          }
          final rest = left == null ? null : left - n;
          if (rest == 0) end = true;
          if (end) {
            scans.remove(k);
          } else {
            scans[k] = (sc, idx, rest);
          }
          r = [_packColumns(n, cols), end];
        case 'tsClose':
          scans.remove(l[2] as int);
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
