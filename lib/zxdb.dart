/// zxdb, the database inside a `.zx` archive, for application code: an
/// application database with SQL (SQLite's dialect), KV stores and time
/// series, without the rest of the archiver (docs/api.md, "An application
/// database"; docs/zxdb-sql.md for the SQL).
///
/// ```dart
/// final db = ZxSqlDb.open('notes.zx');
/// db.execute('CREATE TABLE IF NOT EXISTS n (id INTEGER PRIMARY KEY, t TEXT)');
/// db.transaction(() => db.execute('INSERT INTO n (t) VALUES (?)', ['hi']));
/// for (final r in db.select('SELECT id, t FROM n')) print(r['t']);
/// db.dispose();
/// ```
library;

export 'src/db/zx_sql_db.dart'
    show ZxSqlDb, ZxRow, ZxRows, ZxSqlDbStatement, ZxSqlDbStats, zxUtf8;
export 'src/db/zxdb.dart' show ZxDatabase;
export 'src/db/engine/store.dart' show ZxDbStoreOptions;
export 'src/db/kv.dart'
    show ZxKvStore, ZxKvEntry, ZxKvChange, ZxKvBatch, ZxKvSettings;
export 'src/db/ts/ts_api.dart' show ZxSeries;
export 'src/db/storage_api.dart' show ZxDbException, ZxDbError;
export 'src/db/sql/zx_sql.dart'
    show ZxSql, ZxSqlResult, ZxSqlStatement, ZxSqlCursor, zxFormatDatetimeNs;
export 'src/format/zx/zx_crypto.dart' show ZxKeys, zxKdfRuns;
