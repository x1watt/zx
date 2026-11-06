/// zxdb, synchronously: the database of a `.zx` file opened in the calling
/// isolate, and its SQL session.
///
/// `package:zx/zx.dart` exports the asynchronous API ([ZxDatabaseAsync],
/// which runs the database in a worker isolate). An application whose
/// stores are synchronous today (they were SQLite connections) uses this
/// library instead: [ZxDatabase.open] and [ZxSql] on its store, or [ZxSql]
/// on a [ZxMemoryStore] for a database that lives only in memory (tests,
/// caches).
///
/// ```dart
/// final db = ZxDatabase.open('notes.zx', create: true,
///     options: ZxDbStoreOptions(compression: 'fast'));
/// final sql = ZxSql(db.store);
/// sql.execute('CREATE TABLE IF NOT EXISTS t (k TEXT PRIMARY KEY, v)');
/// sql.execute('INSERT INTO t VALUES (?, ?)', ['a', 1]);
/// sql.execute('SELECT v FROM t WHERE k = ?', ['a']).rows; // [[1]]
/// db.close();
/// ```
///
/// [ZxDb] ([zxDbOpenFile], [zxDbOpenMemory]) is the same database behind a
/// handle shaped like package:sqlite3's, for stores moving off SQLite.
///
/// Not for the browser (it reads and writes files with dart:io).
library;

export 'src/db/zxdb.dart' show ZxDatabase;
export 'src/db/sql/zx_sql.dart'
    show ZxSql, ZxSqlStatement, ZxSqlCursor, zxFormatDatetimeNs, zxIsDatetimeType;
export 'src/db/sql/sql_result.dart';
export 'src/db/memory_store.dart' show ZxMemoryStore;
export 'src/db/engine/store.dart' show ZxDbStoreOptions, ZxDbFoldResult;
export 'src/db/storage_api.dart' show ZxDbException, ZxDbError, ZxStore;
export 'src/db/handle/zx_db.dart'
    show ZxDb, ZxRow, ZxRows, ZxDbStatement, zxDbOpenFile, zxDbOpenMemory;
