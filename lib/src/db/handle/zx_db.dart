// ZxDb: a database handle shaped like package:sqlite3's, over zxdb.
//
// For applications moving off SQLite: the slice of package:sqlite3 that
// stores use — `execute`, `select` (rows read as maps), `prepare`,
// `updatedRows`, `lastInsertRowId`, `dispose` — so their SQL and their
// code stay as they were, plus what zxdb has beyond SQL: KV stores with a
// TTL, time series, a full-text index over keyed documents, and the upkeep
// an append-only file needs. What a store has to know about zxdb:
//
//  * A statement outside BEGIN ... COMMIT is a commit of its own (about a
//    millisecond, a few KiB appended). Write several rows in a transaction
//    ([ZxDb.transaction] or BEGIN/COMMIT): one commit for the batch.
//  * The file grows with every commit (copy-on-write). The handle compacts
//    it by itself when it has doubled since the last compaction and grown
//    by 4 MiB ([autoCompact], on by default); the size after a compaction
//    is kept in the file, so the rule holds across restarts. A program that
//    must not pause in the middle of a write (a UI) turns it off and calls
//    [ZxDb.maybeCompact] where it is idle. PRAGMAs that managed SQLite's
//    file (journal_mode, incremental_vacuum, wal_checkpoint, busy_timeout,
//    page_count) are accepted and do nothing; [ZxDb.bytes] is the file,
//    [ZxDb.liveBytes] the live data.
//  * Several writers (isolates, processes) on one file take turns through
//    zxdb's writer lock; a write waits up to [lockWaitMs] for it, then
//    fails with ZxDbError.busy. [ZxDb.transaction] takes the lock at BEGIN.
//  * Large blobs belong in files next to the database, or in pieces: a
//    compaction rewrites every live page.
//  * `:memory:` (or [ZxDb.memory]) is a database in memory (SQL only).
//  * One database per file per isolate: a second open of the same file
//    shares the first's, as SQLite connections shared one file.
//
// Two handles of this shape were written at once (ZxDb here, ZxSqlDb in the
// XPRS work); this is both, and ZxSqlDb is a name for it.

import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import '../../host/io.dart';
import '../../io/streams.dart' show SevenZipException;
import '../kv_sql.dart';
import '../memory_store.dart';
import '../sql/zx_sql.dart';
import '../system/archive_view.dart';
import '../system/sql_adapter.dart';
import '../text_index.dart';
import '../ts/ts_sql.dart';
import '../zxdb.dart';

/// One row: a read-only map from column name to value, also readable by
/// column position ([columnAt], or an int key), as package:sqlite3's Row
/// was. Values are `dynamic`, as there, so `row['n'] as int` and
/// `row['name']` passed to a String parameter read as they did. A column
/// name that repeats reads its first column.
class ZxRow extends MapBase<String, dynamic> {
  ZxRow._(this._names, this._index, this._values);
  final List<String> _names; // distinct, in column order
  final Map<String, int> _index;
  final List<Object?> _values;

  @override
  dynamic operator [](Object? key) {
    if (key is int) return _values[key];
    final i = _index[key];
    return i == null ? null : _values[i];
  }

  /// The value of column [i].
  dynamic columnAt(int i) => _values[i];

  @override
  Iterable<String> get keys => _names;

  /// The values in column order (every column, repeated names included).
  @override
  Iterable<dynamic> get values => _values;

  @override
  int get length => _names.length;

  @override
  bool containsKey(Object? key) => _index.containsKey(key);

  @override
  void operator []=(String key, dynamic value) =>
      throw UnsupportedError('a row is read only');
  @override
  void clear() => throw UnsupportedError('a row is read only');
  @override
  dynamic remove(Object? key) => throw UnsupportedError('a row is read only');
}

/// The rows of a SELECT, in order; a list, as package:sqlite3's ResultSet.
/// A row's map is made when it is read.
class ZxRows extends ListBase<ZxRow> {
  ZxRows(this.columnNames, List<List<Object?>> rows) : _rows = rows {
    for (var i = 0; i < columnNames.length; i++) {
      if (!_index.containsKey(columnNames[i])) {
        _index[columnNames[i]] = i;
        _distinct.add(columnNames[i]);
      }
    }
  }

  /// [ZxRows] of [columns] and [rows].
  static ZxRows of(List<String> columns, List<List<Object?>> rows) =>
      ZxRows(columns, rows);

  final List<String> columnNames;
  final List<List<Object?>> _rows;
  final Map<String, int> _index = {};
  final List<String> _distinct = [];

  /// The raw values, row by row.
  List<List<Object?>> get rows => _rows;

  @override
  int get length => _rows.length;
  @override
  set length(int n) => throw UnsupportedError('rows are read only');
  @override
  ZxRow operator [](int i) => ZxRow._(_distinct, _index, _rows[i]);
  @override
  void operator []=(int i, ZxRow v) =>
      throw UnsupportedError('rows are read only');
}

/// A statement parsed once and run many times. It survives a compaction
/// (it parses again on the new session).
abstract class ZxDbStatement {
  void execute([List<Object?> params = const []]);
  ZxRows select([List<Object?> params = const []]);
  void dispose();
}

/// The handle. See the file comment.
abstract class ZxDb {
  /// Opens (creating it unless [readOnly] or not [create]) the database
  /// file at [path] (`:memory:` is a database in memory); its folders are
  /// made when missing.
  ///
  /// - [password]: the file is encrypted (AES-256); null leaves it plain. A
  ///   program that passes a random secret of full strength (64 hex
  ///   characters) passes [scryptLog2N] 1: the secret needs no stretching
  ///   and opening then costs no KDF time. Derived keys are cached per
  ///   process, so reopening and following other writers' commits cost
  ///   nothing either.
  /// - [lockWaitMs]: how long a write waits for another writer (another
  ///   isolate or process on the same file) before [ZxDbError.busy].
  /// - [autoCompact]: compact when the file has doubled (file comment).
  /// - [systemTables]: also the archive's system tables (zx_files, ...),
  ///   the metadata tables and full-text search over files.
  /// - [options]: the store's options; when null they are made from
  ///   [durable] (flush to the disk at each commit), [compression] ('fast'
  ///   reads in microseconds; 'max' is smaller and slow to read cold),
  ///   [refreshMicros] (how often a read looks for other writers' commits;
  ///   0 at every statement), [scryptLog2N], the cache sizes and [pageSize]
  ///   (a commit rewrites the pages it touches: a store of many small
  ///   commits writes less with small pages, 4096). The defaults are sized
  ///   for an application holding several small databases.
  static ZxDb open(String path,
      {String? password,
      bool readOnly = false,
      bool create = true,
      int lockWaitMs = 4000,
      bool autoCompact = true,
      bool systemTables = false,
      ZxDbStoreOptions? options,
      bool durable = false,
      String compression = 'fast',
      int refreshMicros = 0,
      int scryptLog2N = 15,
      int pageCacheBytes = 16 << 20,
      int blockCacheBytes = 4 << 20,
      int pageSize = 16384}) {
    if (path == ':memory:') return memory();
    final abs = File(path).absolute.path;
    final have = _open[abs];
    if (have != null) {
      have.refs++;
      return _Handle(have);
    }
    try {
      final parent = File(abs).parent;
      if (!readOnly && create && !parent.existsSync()) {
        parent.createSync(recursive: true);
      }
      final db = ZxDatabase.open(abs,
          password: password,
          readOnly: readOnly,
          create: create && !readOnly,
          options: options ??
              ZxDbStoreOptions(
                  compression: compression,
                  durable: durable,
                  refreshMicros: refreshMicros,
                  scryptLog2N: scryptLog2N,
                  pageCacheBytes: pageCacheBytes,
                  blockCacheBytes: blockCacheBytes,
                  pageSize: pageSize));
      final f = _Open(abs, db,
          password: password,
          lockWaitMs: lockWaitMs,
          autoCompact: autoCompact && !readOnly,
          systemTables: systemTables);
      _open[abs] = f;
      return _Handle(f);
    } on SevenZipException catch (e) {
      throw ZxDbException(
          '$abs: ${e.message} (wrong password or not a database)',
          ZxDbError.corrupt);
    }
  }

  /// A database that lives in memory only: SQL, no KV stores or time
  /// series, gone when disposed. For tests and scratch work.
  static ZxDb memory() => _Handle(_Open.memory());

  /// Runs one or more statements (separated by `;`).
  void execute(String sql, [List<Object?> params = const []]);

  /// Runs a query and returns its rows.
  ZxRows select(String sql, [List<Object?> params = const []]);

  ZxDbStatement prepare(String sql);

  /// Rows inserted, updated or deleted by the last statement.
  int get updatedRows;

  /// The rowid of the last row inserted.
  int get lastInsertRowId;

  /// True between BEGIN and COMMIT / ROLLBACK.
  bool get inTransaction;

  /// Runs [body] in one write transaction (one commit), rolled back when it
  /// throws; the writer lock is taken at the start (BEGIN IMMEDIATE), so
  /// another writer cannot slip in between a read and a write of [body].
  /// Inside an open transaction it simply runs [body]. [body] must not
  /// await: the lock is held meanwhile.
  T transaction<T>(T Function() body) {
    if (inTransaction) return body();
    execute('BEGIN IMMEDIATE');
    try {
      final r = body();
      execute('COMMIT');
      return r;
    } catch (_) {
      if (inTransaction) {
        try {
          execute('ROLLBACK');
        } catch (_) {}
      }
      rethrow;
    }
  }

  /// KV store [name] (created, with [ttl], when it does not exist). Its
  /// writes commit on their own: inside [transaction] use SQL on the
  /// store's table (`name (key, value)`), or group them with its `batch`.
  ZxKvStore kv(String name, {Duration? ttl});

  /// Time series [name] (create it with CREATE TIMESERIES).
  ZxSeries series(String name);

  /// Full-text index [name] over documents with [fields] (name to weight),
  /// ranked by BM25. Its writes join an open [transaction], so a row and
  /// its index entry commit together.
  ZxSqlDbTextIndex textIndex(String name, Map<String, double> fields);

  /// The database's size on disk, bytes (0 in memory): what the disk pays,
  /// history included until the next compaction.
  int get bytes;

  /// The live data, bytes before compression: the pages the last commit
  /// uses times the page size (SQLite's page_count * page_size; 0 in
  /// memory). What a byte budget reads.
  int get liveBytes;

  /// Sizes of the file: now, after the last compaction, and the commits it
  /// keeps (zeros in memory).
  ZxSqlDbStats stats();

  /// The file, or null in memory.
  String? get path;

  /// Compacts when the file has grown past [factor] times its size after
  /// the last compaction and by at least [minGrowth] bytes (or with
  /// [force]): returns true when it did. The first call on a file only
  /// records where it stands.
  bool maybeCompact(
      {double factor = 2, int minGrowth = 16 << 20, bool force = false});

  /// Drops the history of earlier commits and rewrites the file to its live
  /// pages, now: expired KV values go, time series are sealed. Outside a
  /// transaction (inside one it does nothing).
  void compact();

  /// The database under the handle (null in memory).
  ZxDatabase? get database;

  /// The SQL session (for what the handle does not wrap). Replaced by a
  /// compaction: read it again rather than keep it.
  ZxSql get sql;

  /// Closes the handle (the file stays open while another handle of this
  /// isolate shares it). An open transaction is rolled back.
  void dispose();
}

/// Opens (creating it unless [readOnly]) the database file at [path]
/// (`:memory:` is a database in memory). [password] encrypts it (AES-256);
/// null leaves it plain. [options] tune the store (zxdb's defaults are
/// sized for one big database on a desktop; an application holding many
/// small ones passes smaller caches and `compression: 'fast'`, or uses
/// [ZxDb.open], whose defaults are those).
ZxDb zxDbOpenFile(String path,
        {String? password, bool readOnly = false, ZxDbStoreOptions? options}) =>
    ZxDb.open(path,
        password: password,
        readOnly: readOnly,
        options: options ?? ZxDbStoreOptions());

/// A database that lives in memory only.
ZxDb zxDbOpenMemory() => ZxDb.memory();

/// The handle under the name the XPRS stores used for it.
typedef ZxSqlDb = ZxDb;

/// A prepared statement, under the XPRS stores' name for it.
typedef ZxSqlDbStatement = ZxDbStatement;

/// UTF-8 bytes of [s] (a KV key or value).
Uint8List zxUtf8(String s) => Uint8List.fromList(utf8.encode(s));

/// Sizes of a database file ([ZxDb.stats]).
class ZxSqlDbStats {
  const ZxSqlDbStats(this.fileBytes, this.baselineBytes, this.generations);

  /// The file's size on disk.
  final int fileBytes;

  /// Its size right after the last compaction (or when first seen): what
  /// the data needed then. Growth beyond it is mostly superseded pages.
  final int baselineBytes;

  /// Generations (commits) kept in the file.
  final int generations;
}

/// A full-text index bound to a [ZxDb] ([ZxDb.textIndex]).
class ZxSqlDbTextIndex {
  ZxSqlDbTextIndex._(this._db, this.index);
  final ZxDb _db;
  final ZxTextIndex index;

  void _write(void Function(ZxWriteTxn t) f) {
    final sql = _db.sql;
    final open = sql.writeTxn;
    if (open != null) {
      f(open);
      return;
    }
    final t = sql.store.begin(waitMs: sql.lockWaitMs);
    try {
      f(t);
      t.commit();
    } catch (_) {
      t.rollback();
      rethrow;
    }
  }

  T _read<T>(T Function(ZxSnapshot s) f) {
    final sql = _db.sql;
    final open = sql.writeTxn;
    if (open != null) return f(open);
    final s = sql.store.snapshot();
    try {
      return f(s);
    } finally {
      s.close();
    }
  }

  /// Puts (or replaces) document [key] with [fields].
  void put(String key, Map<String, String?> fields) =>
      _write((t) => index.put(t, key, fields));

  /// Removes document [key].
  void remove(String key) => _write((t) => index.remove(t, key));

  /// The best [limit] documents for [query], best first.
  List<ZxTextHit> search(String query, {int limit = 50}) =>
      _read((s) => index.search(s, query, limit: limit));

  /// Documents in the index.
  int get length => _read(index.length);

  /// Whether document [key] is indexed.
  bool contains(String key) => _read((s) => index.contains(s, key));
}

final Map<String, _Open> _open = {};

/// One open file of this isolate, shared by its handles.
class _Open {
  _Open(this.path, ZxDatabase this.db,
      {this.password,
      required this.lockWaitMs,
      required this.autoCompact,
      required this.systemTables}) {
    sql = _session();
  }

  _Open.memory()
      : path = null,
        db = null,
        password = null,
        lockWaitMs = 0,
        autoCompact = false,
        systemTables = false {
    sql = ZxSql(ZxMemoryStore());
  }

  final String? path;
  final ZxDatabase? db;
  final String? password;
  final int lockWaitMs;
  final bool autoCompact;
  final bool systemTables;
  late ZxSql sql;
  ZxArchiveView? _view;
  int refs = 1;

  /// Bumped when [sql] is replaced (after a compaction), so prepared
  /// statements parse again.
  int epoch = 0;

  int _sinceCheck = 0;

  /// The KV store holding the handle's own bookkeeping (the compaction
  /// baseline), kept in the file.
  static const _metaStore = r'zx$sqldb';

  /// A SQL session on the store, with KV stores, time series and (when
  /// asked for) the system tables as SQL.
  ZxSql _session() {
    final d = db!;
    final q = ZxSql(d.store)..lockWaitMs = lockWaitMs;
    if (systemTables) {
      _view?.close();
      final v = _view = ZxArchiveView.open(path!, password: password);
      ZxSystemSql(archive: v, database: true)
          .register(q.registerVirtualTable, q.functions);
    }
    zxTsRegisterSql(q, nowMs: () => d.nowMs());
    zxKvRegisterSql(q,
        vacuum: (ultra) => d.vacuum(ultra: ultra, recompress: ultra));
    return q;
  }

  int length() {
    final p = path;
    if (p == null) return 0;
    try {
      return File(p).lengthSync();
    } catch (_) {
      return 0;
    }
  }

  int? baseline() {
    final d = db;
    if (d == null || !d.kvStores.contains(_metaStore)) return null;
    final v = d.kv(_metaStore).getString('baseline');
    return v == null ? null : int.tryParse(v);
  }

  void setBaseline(int bytes) {
    final d = db!;
    final kv = d.kvStores.contains(_metaStore)
        ? d.kv(_metaStore)
        : d.createKvStore(_metaStore);
    kv.putString('baseline', '$bytes');
  }

  /// After a statement outside a transaction: every 32, compact when the
  /// file has doubled since the last compaction and grown by 4 MiB.
  void afterCommit() {
    if (!autoCompact) return;
    if (++_sinceCheck < 32) return;
    _sinceCheck = 0;
    maybeCompact(2, 4 << 20, false);
  }

  bool maybeCompact(double factor, int minGrowth, bool force) {
    final d = db;
    if (d == null || d.readOnly || sql.inTransaction) return false;
    final size = length();
    final base = baseline();
    if (!force && base == null) {
      setBaseline(size); // first look: remember where it stands
      return false;
    }
    final grown = base != null && size > base * factor && size - base >= minGrowth;
    if (!force && !grown) return false;
    compact();
    return true;
  }

  void compact() {
    final d = db;
    if (d == null || d.readOnly || sql.inTransaction) return;
    sql.close();
    try {
      d.vacuum(keep: 1);
    } finally {
      sql = _session();
      epoch++;
    }
    setBaseline(length());
  }

  void close() {
    sql.close();
    _view?.close();
    db?.close();
    final p = path;
    if (p != null && identical(_open[p], this)) _open.remove(p);
  }
}

class _Handle extends ZxDb {
  _Handle(this._f);
  final _Open _f;
  bool _disposed = false;
  int _changes = 0;
  int _lastRowid = 0;

  void _checkOpen() {
    if (_disposed) {
      throw const ZxDbException('the database is closed', ZxDbError.generic);
    }
  }

  ZxDatabase _need(String what) =>
      _f.db ??
      (throw ZxDbException('$what needs a database file, not a memory one',
          ZxDbError.unsupported));

  ZxSqlResult _done(ZxSqlResult r) {
    _changes = r.changes;
    _lastRowid = r.lastInsertRowid;
    if (!_f.sql.inTransaction) _f.afterCommit();
    return r;
  }

  @override
  void execute(String sql, [List<Object?> params = const []]) {
    _checkOpen();
    _done(_f.sql.execute(sql, params));
  }

  @override
  ZxRows select(String sql, [List<Object?> params = const []]) {
    _checkOpen();
    final r = _done(_f.sql.execute(sql, params));
    return ZxRows(r.columns, r.rows);
  }

  @override
  ZxDbStatement prepare(String sql) {
    _checkOpen();
    return _Statement(this, sql);
  }

  @override
  int get updatedRows => _changes;

  @override
  int get lastInsertRowId => _lastRowid;

  @override
  bool get inTransaction => _f.sql.inTransaction;

  @override
  ZxKvStore kv(String name, {Duration? ttl}) {
    _checkOpen();
    final d = _need('a KV store');
    if (d.kvStores.contains(name)) return d.kv(name);
    return d.createKvStore(name, ttl: ttl);
  }

  @override
  ZxSeries series(String name) {
    _checkOpen();
    return _need('a time series').series(name);
  }

  @override
  ZxSqlDbTextIndex textIndex(String name, Map<String, double> fields) {
    _checkOpen();
    return ZxSqlDbTextIndex._(this, ZxTextIndex(name, fields));
  }

  @override
  int get bytes => _f.length();

  @override
  int get liveBytes {
    final d = _f.db;
    if (d == null) return 0;
    return d.store.livePages * d.store.options.pageSize;
  }

  @override
  ZxSqlDbStats stats() {
    _checkOpen();
    final d = _f.db;
    if (d == null) return const ZxSqlDbStats(0, 0, 0);
    final size = _f.length();
    return ZxSqlDbStats(size, _f.baseline() ?? size, d.generations.length);
  }

  @override
  String? get path => _f.path;

  @override
  bool maybeCompact(
      {double factor = 2, int minGrowth = 16 << 20, bool force = false}) {
    _checkOpen();
    return _f.maybeCompact(factor, minGrowth, force);
  }

  @override
  void compact() {
    _checkOpen();
    _f.compact();
  }

  @override
  ZxDatabase? get database => _f.db;

  @override
  ZxSql get sql => _f.sql;

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (--_f.refs <= 0) _f.close();
  }
}

class _Statement extends ZxDbStatement {
  _Statement(this._db, this._text);
  final _Handle _db;
  final String _text;
  ZxSqlStatement? _st;
  int _epoch = -1;

  ZxSqlResult _run(List<Object?> params) {
    _db._checkOpen();
    final f = _db._f;
    if (_st == null || _epoch != f.epoch) {
      _st = f.sql.prepare(_text);
      _epoch = f.epoch;
    }
    return _db._done(_st!.execute(params));
  }

  @override
  void execute([List<Object?> params = const []]) => _run(params);

  @override
  ZxRows select([List<Object?> params = const []]) {
    final r = _run(params);
    return ZxRows(r.columns, r.rows);
  }

  @override
  void dispose() => _st = null;
}
