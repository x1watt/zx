/// zxdb, synchronously: the database of a `.zx` file opened in the calling
/// isolate, for application code: SQL (SQLite's dialect), KV stores, time
/// series and a full-text index, without the rest of the archiver
/// (docs/api.md, "An application database"; docs/zxdb-sql.md for the SQL).
///
/// `package:zx/zx.dart` exports the asynchronous API ([ZxDatabaseAsync],
/// which runs the database in a worker isolate). An application whose
/// stores are synchronous (they were SQLite connections) uses this library:
///
/// ```dart
/// final db = ZxDb.open('notes.zx');
/// db.execute('CREATE TABLE IF NOT EXISTS n (id INTEGER PRIMARY KEY, t TEXT)');
/// db.transaction(() => db.execute('INSERT INTO n (t) VALUES (?)', ['hi']));
/// for (final r in db.select('SELECT id, t FROM n')) print(r['t']);
/// db.dispose();
/// ```
///
/// [ZxSqlDb] is the same handle under the name the XPRS stores use, and
/// [zxDbOpenFile] / [zxDbOpenMemory] open one with zxdb's own defaults. Below it, [ZxDatabase.open] and [ZxSql] on its store, or
/// [ZxSql] on a [ZxMemoryStore], are the database and its SQL session
/// directly. In a browser, see package:zx/zxdb_web.dart for the files.
library;

export 'src/db/handle/zx_db.dart'
    show
        ZxDb,
        ZxDbStatement,
        ZxRow,
        ZxRows,
        zxDbOpenFile,
        zxDbOpenMemory,
        ZxSqlDb,
        ZxSqlDbStatement,
        ZxSqlDbStats,
        ZxSqlDbTextIndex,
        zxUtf8;
export 'src/db/text_index.dart' show ZxTextIndex, ZxTextHit;
export 'src/db/zxdb.dart' show ZxDatabase;
export 'src/db/engine/store.dart' show ZxDbStoreOptions, ZxDbFoldResult;
export 'src/db/kv.dart'
    show ZxKvStore, ZxKvEntry, ZxKvChange, ZxKvBatch, ZxKvSettings;
export 'src/db/ts/ts_api.dart' show ZxSeries;
export 'src/db/storage_api.dart' show ZxDbException, ZxDbError, ZxStore;
export 'src/db/memory_store.dart' show ZxMemoryStore;
export 'src/db/sql/zx_sql.dart'
    show
        ZxSql,
        ZxSqlStatement,
        ZxSqlCursor,
        zxFormatDatetimeNs,
        zxIsDatetimeType;
export 'src/db/sql/sql_result.dart';
export 'src/format/zx/zx_crypto.dart' show ZxKeys, zxKdfRuns;
export 'src/format/zx/zx_pack.dart'
    show zxPackBytes, zxUnpackBytes, zxLooksPacked;
export 'src/io/streams.dart' show SevenZipException, SevenZipError;
