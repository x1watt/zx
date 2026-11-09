// ZxSqlDb: a database file used the way an application uses SQLite: one
// object, synchronous SQL with rows by column name, prepared statements,
// transactions, plus zxdb's own KV stores and time series, and the upkeep
// an append-only file needs (stats, compaction). docs/api.md "An
// application database".
//
// It is ZxDatabase (zxdb.dart) with a SQL session of its own: the tables,
// KV stores and time series as SQL, without the system tables over the
// archive's files unless asked for (they open a reader of the whole
// archive). On a memory store (tests, a scratch database) there is SQL
// only.

import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import '../host/io.dart';
import 'kv_sql.dart';
import 'memory_store.dart';
import 'sql/zx_sql.dart';
import 'system/archive_view.dart';
import 'system/sql_adapter.dart';
import 'ts/ts_sql.dart';
import 'zxdb.dart';

/// A row of [ZxSqlDb.select]: the values by column name (a Map), or by
/// position ([columnAt]). Values are `dynamic`, as in the SQLite bindings,
/// so `row['name']` passes where a String is expected.
class ZxRow extends MapBase<String, dynamic> {
  ZxRow(this._names, this._values);
  final Map<String, int> _names;
  final List<Object?> _values;

  /// The value of result column [i].
  dynamic columnAt(int i) => _values[i];

  /// The values in column order.
  @override
  List<Object?> get values => _values;

  @override
  dynamic operator [](Object? key) {
    final i = _names[key];
    return i == null ? null : _values[i];
  }

  @override
  void operator []=(String key, dynamic value) =>
      throw UnsupportedError('a result row is read only');
  @override
  void clear() => throw UnsupportedError('a result row is read only');
  @override
  dynamic remove(Object? key) =>
      throw UnsupportedError('a result row is read only');
  @override
  Iterable<String> get keys => _names.keys;
  @override
  bool containsKey(Object? key) => _names.containsKey(key);
  @override
  int get length => _names.length;
}

/// The rows of a query, with the names of its columns.
class ZxRows extends ListBase<ZxRow> {
  ZxRows._(this.columnNames, this._rows);
  final List<String> columnNames;
  final List<ZxRow> _rows;

  static ZxRows of(List<String> columns, List<List<Object?>> rows) {
    final names = <String, int>{};
    for (var i = 0; i < columns.length; i++) {
      names.putIfAbsent(columns[i], () => i);
    }
    return ZxRows._(columns, [for (final r in rows) ZxRow(names, r)]);
  }

  @override
  int get length => _rows.length;
  @override
  set length(int n) => throw UnsupportedError('result rows are read only');
  @override
  ZxRow operator [](int i) => _rows[i];
  @override
  void operator []=(int i, ZxRow v) =>
      throw UnsupportedError('result rows are read only');
}

/// A prepared statement of [ZxSqlDb.prepare].
class ZxSqlDbStatement {
  ZxSqlDbStatement._(this._db, this._st);
  final ZxSqlDb _db;
  final ZxSqlStatement _st;

  /// Runs it for its effect; [ZxSqlDb.updatedRows] tells the rows changed.
  void execute([List<Object?> params = const []]) =>
      _db._note(_st.execute(params));

  /// Runs it and returns its rows.
  ZxRows select([List<Object?> params = const []]) {
    final r = _st.execute(params);
    _db._note(r);
    return ZxRows.of(r.columns, r.rows);
  }

  /// Nothing to free (kept for code written against SQLite bindings).
  void dispose() {}
}

/// Sizes of a [ZxSqlDb] file.
class ZxSqlDbStats {
  const ZxSqlDbStats(this.fileBytes, this.baselineBytes, this.generations);

  /// The archive's size on disk.
  final int fileBytes;

  /// Its size right after the last compaction (or creation): what the
  /// data needed then. Growth beyond it is mostly superseded pages.
  final int baselineBytes;

  /// Generations (commits) kept in the file.
  final int generations;
}

/// A database in a `.zx` file, for application code (see the top of this
/// file).
class ZxSqlDb {
  ZxSqlDb._(this._db, this.sql);

  final ZxDatabase? _db;

  /// The SQL session (for what this class does not wrap).
  final ZxSql sql;
  ZxArchiveView? _view;
  int _updated = 0;
  int _lastRowid = 0;
  bool _closed = false;

  /// The KV store holding this class's own bookkeeping.
  static const _metaStore = r'zx$sqldb';

  /// Opens (or with [create] makes) the database at [path].
  ///
  /// - [password]: the archive is encrypted (created encrypted; must match
  ///   to open). A program that passes a random secret of full strength
  ///   (64 hex characters) should pass [scryptLog2N] 1 at creation: the
  ///   secret needs no stretching and opening then costs no KDF time.
  ///   Derived keys are cached per process, so reopening and following
  ///   other writers' commits cost nothing either.
  /// - [lockWaitMs]: how long a write waits for another writer (another
  ///   isolate or process on the same file) before [ZxDbError.busy].
  /// - [durable]: flush to the disk at each commit (slower; for data that
  ///   must survive a power cut the moment it is written).
  /// - [compression]: the default for new tables and KV stores ('fast'
  ///   gives reads in microseconds; 'max' is much smaller and slow to read
  ///   cold).
  /// - [systemTables]: also the archive's system tables (zx_files, ...),
  ///   the metadata tables and full-text search over files.
  /// - [refreshMicros]: how often a read checks for other writers'
  ///   commits; 0 checks at every statement (several isolates share it).
  /// - [pageSize]: the default page of new tables. A commit rewrites the
  ///   pages it touches, so a store of many small commits writes less with
  ///   small pages (4096); big scans read faster with big ones.
  static ZxSqlDb open(String path,
      {String? password,
      bool readOnly = false,
      bool create = true,
      int lockWaitMs = 4000,
      bool durable = false,
      String compression = 'fast',
      bool systemTables = false,
      int refreshMicros = 0,
      int scryptLog2N = 15,
      int pageCacheBytes = 16 << 20,
      int blockCacheBytes = 4 << 20,
      int pageSize = 16384}) {
    final db = ZxDatabase.open(path,
        password: password,
        readOnly: readOnly,
        create: create,
        options: ZxDbStoreOptions(
            compression: compression,
            durable: durable,
            refreshMicros: refreshMicros,
            scryptLog2N: scryptLog2N,
            pageCacheBytes: pageCacheBytes,
            blockCacheBytes: blockCacheBytes,
            pageSize: pageSize));
    final q = ZxSql(db.store)..lockWaitMs = lockWaitMs;
    final out = ZxSqlDb._(db, q);
    if (systemTables) {
      final v = out._view = ZxArchiveView.open(path, password: password);
      ZxSystemSql(archive: v, database: true)
          .register(q.registerVirtualTable, q.functions);
    }
    zxTsRegisterSql(q, nowMs: () => db.nowMs());
    zxKvRegisterSql(q,
        vacuum: (ultra) => db.vacuum(ultra: ultra, recompress: ultra));
    return out;
  }

  /// A database in memory: SQL only (no KV stores or time series), gone
  /// when dropped. For tests and scratch work.
  static ZxSqlDb memory() => ZxSqlDb._(null, ZxSql(ZxMemoryStore()));

  /// The underlying database (null for [memory]).
  ZxDatabase? get database => _db;

  void _check() {
    if (_closed) throw StateError('the database is closed');
  }

  void _note(ZxSqlResult r) {
    _updated = r.changes;
    _lastRowid = r.lastInsertRowid;
  }

  /// Runs [sqlText] (one or more statements) for its effect.
  void execute(String sqlText, [List<Object?> params = const []]) {
    _check();
    _note(sql.execute(sqlText, params));
  }

  /// Runs a query and returns its rows.
  ZxRows select(String sqlText, [List<Object?> params = const []]) {
    _check();
    final r = sql.execute(sqlText, params);
    _note(r);
    return ZxRows.of(r.columns, r.rows);
  }

  /// Parses [sqlText] once for many executions.
  ZxSqlDbStatement prepare(String sqlText) {
    _check();
    return ZxSqlDbStatement._(this, sql.prepare(sqlText));
  }

  /// Rows changed by the last statement.
  int get updatedRows => _updated;

  /// The rowid of the last row inserted.
  int get lastInsertRowId => _lastRowid;

  /// Whether a [transaction] (or a SQL BEGIN) is open.
  bool get inTransaction => sql.inTransaction;

  /// Runs [body] in one write transaction (one generation): committed when
  /// it returns, rolled back when it throws. Nested calls join the outer
  /// one. [body] must not await: the writer lock is held meanwhile.
  T transaction<T>(T Function() body) {
    _check();
    if (sql.inTransaction) return body();
    sql.execute('BEGIN IMMEDIATE');
    try {
      final out = body();
      sql.execute('COMMIT');
      return out;
    } catch (_) {
      if (sql.inTransaction) sql.execute('ROLLBACK');
      rethrow;
    }
  }

  ZxDatabase _need(String what) => _db ??
      (throw ZxDbException(
          '$what needs a database file, not a memory one',
          ZxDbError.unsupported));

  /// KV store [name], created (with [ttl] and 'fast' compression) when it
  /// does not exist. Its writes commit on their own, so do not write to it
  /// inside [transaction]: use SQL on the store's table (`name (key,
  /// value)`) there.
  ZxKvStore kv(String name, {Duration? ttl}) {
    final db = _need('a KV store');
    _check();
    if (db.kvStores.contains(name)) return db.kv(name);
    return db.createKvStore(name, ttl: ttl);
  }

  /// Time series [name] (create it with CREATE TIMESERIES).
  ZxSeries series(String name) => _need('a time series').series(name);

  /// Sizes of the file (on a memory database, zeros).
  ZxSqlDbStats stats() {
    _check();
    final db = _db;
    if (db == null) return const ZxSqlDbStats(0, 0, 0);
    final size = File(db.store.path).lengthSync();
    final base = _baseline(db) ?? size;
    return ZxSqlDbStats(size, base, db.generations.length);
  }

  int? _baseline(ZxDatabase db) {
    if (!db.kvStores.contains(_metaStore)) return null;
    final v = db.kv(_metaStore).getString('baseline');
    return v == null ? null : int.tryParse(v);
  }

  /// Compacts the file when it has grown past [factor] times its size after
  /// the last compaction and by at least [minGrowth] bytes: removes
  /// expired KV values, seals time series, folds, and rewrites the file
  /// keeping one generation. Returns true when it compacted. Holds the
  /// writer lock while it rewrites; run it when the program is idle, or in
  /// another isolate that opens the same file.
  bool maybeCompact({double factor = 2, int minGrowth = 16 << 20,
      bool force = false}) {
    _check();
    final db = _db;
    if (db == null || db.readOnly) return false;
    final st = stats();
    final grown = st.fileBytes > st.baselineBytes * factor &&
        st.fileBytes - st.baselineBytes >= minGrowth;
    if (!force && !grown && _baseline(db) != null) return false;
    if (!force && !grown) {
      // first look: remember where it stands
      _setBaseline(db, st.fileBytes);
      return false;
    }
    db.vacuum();
    _setBaseline(db, File(db.store.path).lengthSync());
    return true;
  }

  void _setBaseline(ZxDatabase db, int bytes) {
    final kv = db.kvStores.contains(_metaStore)
        ? db.kv(_metaStore)
        : db.createKvStore(_metaStore);
    kv.putString('baseline', '$bytes');
  }

  /// Commits what is pending and closes the file. An open transaction is
  /// rolled back.
  void dispose() {
    if (_closed) return;
    _closed = true;
    sql.close();
    _view?.close();
    _db?.close();
  }
}

/// UTF-8 bytes of [s] (a KV key or value).
Uint8List zxUtf8(String s) => Uint8List.fromList(utf8.encode(s));
