// ZxDb: a database handle shaped like package:sqlite3's, over zxdb.
//
// For applications moving off SQLite: the slice of package:sqlite3 that
// stores use — `execute`, `select` (rows read as maps), `prepare`,
// `updatedRows`, `lastInsertRowId`, `dispose` — so their SQL and their
// code stay as they were. What a store has to know about zxdb:
//
//  * A statement outside BEGIN ... COMMIT is a commit of its own (about a
//    millisecond, a few KiB appended). Write several rows in a transaction
//    ([ZxDb.transaction] or BEGIN/COMMIT): one commit for the batch.
//  * The file grows with every commit (copy-on-write); the handle compacts
//    it by itself when it has doubled since the last compaction. PRAGMAs
//    that managed SQLite's file (journal_mode, incremental_vacuum,
//    wal_checkpoint, busy_timeout, page_count) are accepted and do nothing;
//    [ZxDb.bytes] is the file, [ZxDb.liveBytes] the live data.
//  * Large blobs belong in files next to the database: a compaction
//    rewrites every live page.
//  * `:memory:` (or [zxDbOpenMemory]) is a database in memory.
//  * One database per file per isolate: a second open of the same file
//    shares the first's, as SQLite connections shared one file.

import 'dart:collection';

import '../../host/io.dart';
import '../../io/streams.dart' show SevenZipException;
import '../memory_store.dart';
import '../sql/zx_sql.dart';
import '../zxdb.dart';

/// One row: a read-only map from column name to value, also readable by
/// column position ([columnAt]), as package:sqlite3's Row was. Values are
/// `dynamic`, as there, so `row['n'] as int` and `row['name']` passed to a
/// String parameter read as they did.
class ZxRow extends MapBase<String, dynamic> {
  ZxRow._(this._names, this._index, this._values);
  final List<String> _names;
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
class ZxRows extends ListBase<ZxRow> {
  ZxRows(this.columnNames, List<List<Object?>> rows)
      : _rows = rows,
        _index = {
          for (var i = columnNames.length - 1; i >= 0; i--) columnNames[i]: i
        };

  final List<String> columnNames;
  final List<List<Object?>> _rows;
  final Map<String, int> _index;

  /// The raw values, row by row.
  List<List<Object?>> get rows => _rows;

  @override
  int get length => _rows.length;
  @override
  set length(int n) => throw UnsupportedError('rows are read only');
  @override
  ZxRow operator [](int i) => ZxRow._(columnNames, _index, _rows[i]);
  @override
  void operator []=(int i, ZxRow v) =>
      throw UnsupportedError('rows are read only');
}

/// A statement parsed once and run many times.
abstract class ZxDbStatement {
  void execute([List<Object?> params = const []]);
  ZxRows select([List<Object?> params = const []]);
  void dispose();
}

/// The handle. See the file comment.
abstract class ZxDb {
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

  /// Runs [body] in one transaction (one commit), rolled back when it
  /// throws. Inside an open transaction it simply runs [body].
  T transaction<T>(T Function() body) {
    if (inTransaction) return body();
    execute('BEGIN');
    try {
      final r = body();
      execute('COMMIT');
      return r;
    } catch (_) {
      try {
        execute('ROLLBACK');
      } catch (_) {}
      rethrow;
    }
  }

  /// The database's size on disk, bytes (0 in memory): what the disk pays,
  /// history included until the next compaction.
  int get bytes;

  /// The live data, bytes before compression: the pages the last commit
  /// uses times the page size (SQLite's page_count * page_size; 0 in
  /// memory). What a byte budget reads.
  int get liveBytes;

  /// The file, or null in memory.
  String? get path;

  /// Drops the history of earlier commits and rewrites the file to its live
  /// pages. Runs by itself when the file has doubled; call it only where
  /// SQLite needed an explicit VACUUM, outside a transaction.
  void compact();

  /// Closes the handle (the file stays open while another handle of this
  /// isolate shares it).
  void dispose();
}

/// Opens (creating it unless [readOnly]) the database file at [path]
/// (`:memory:` is a database in memory). [password] encrypts it (AES-256);
/// null leaves it plain. [options] tune the store (zxdb's defaults are
/// sized for one big database on a desktop; an application holding many
/// small ones passes smaller caches and `compression: 'fast'`).
ZxDb zxDbOpenFile(String path,
    {String? password, bool readOnly = false, ZxDbStoreOptions? options}) {
  if (path == ':memory:') return zxDbOpenMemory();
  final abs = File(path).absolute.path;
  final have = _open[abs];
  if (have != null) {
    have.refs++;
    return _Handle(have);
  }
  try {
    final parent = File(abs).parent;
    if (!readOnly && !parent.existsSync()) parent.createSync(recursive: true);
    final db = ZxDatabase.open(abs,
        password: password,
        readOnly: readOnly,
        create: !readOnly,
        options: options);
    final f = _Open(abs, db);
    _open[abs] = f;
    return _Handle(f);
  } on SevenZipException catch (e) {
    throw ZxDbException(
        '$abs: ${e.message} (wrong password or not a database)',
        ZxDbError.corrupt);
  }
}

/// A database that lives in memory only.
ZxDb zxDbOpenMemory() => _Handle(_Open.memory());

final Map<String, _Open> _open = {};

class _Open {
  _Open(this.path, ZxDatabase this.db) : sql = ZxSql(db.store) {
    _baseline = _length();
  }

  _Open.memory()
      : path = null,
        db = null,
        sql = ZxSql(ZxMemoryStore());

  final String? path;
  final ZxDatabase? db;
  ZxSql sql;
  int refs = 1;

  /// Bumped when [sql] is replaced (after a compaction), so prepared
  /// statements parse again.
  int epoch = 0;

  int _baseline = 0;
  int _sinceCheck = 0;

  int _length() {
    final p = path;
    if (p == null) return 0;
    try {
      return File(p).lengthSync();
    } catch (_) {
      return 0;
    }
  }

  /// After a statement outside a transaction: every so often, compact when
  /// the file has doubled since the last compaction (plus 4 MiB, so a small
  /// store is not rewritten over a few KiB).
  void afterCommit() {
    final d = db;
    if (d == null || d.readOnly) return;
    if (++_sinceCheck < 32) return;
    _sinceCheck = 0;
    if (_length() > 2 * _baseline + (4 << 20)) compact();
  }

  void compact() {
    final d = db;
    if (d == null || d.readOnly || sql.inTransaction) return;
    sql.close();
    try {
      d.vacuum(keep: 1);
    } finally {
      sql = ZxSql(d.store);
      epoch++;
      _baseline = _length();
    }
  }

  void close() {
    sql.close();
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
  ZxDbStatement prepare(String sql) => _Statement(this, sql);

  @override
  int get updatedRows => _changes;

  @override
  int get lastInsertRowId => _lastRowid;

  @override
  bool get inTransaction => _f.sql.inTransaction;

  @override
  int get bytes => _f._length();

  @override
  int get liveBytes {
    final d = _f.db;
    if (d == null) return 0;
    return d.store.livePages * d.store.options.pageSize;
  }

  @override
  String? get path => _f.path;

  @override
  void compact() => _f.compact();

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
