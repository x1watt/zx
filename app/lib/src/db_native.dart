// The database connection of the native app: ZxDatabase in a worker
// isolate (ZxDatabaseAsync), so every query, commit and page decoding
// happens off the UI isolate.

import 'package:zx/zx.dart';

import 'db_session.dart';

/// A [DbConnection] over ZxDatabaseAsync.
class AsyncDbConnection implements DbConnection {
  final ZxDatabaseAsync db;
  AsyncDbConnection(this.db);

  @override
  Future<ZxSqlResult> execute(String sql, [Object? params]) =>
      db.execute(sql, params);

  @override
  Future<List<String>> kvStores() => db.kvStores();

  @override
  Future<List<String>> seriesNames() => db.seriesNames();

  @override
  Future<void> resetSql() => db.resetSql();

  @override
  Future<void> close() => db.close();
}

/// The default [DbOpener]: checks for a database in a background isolate,
/// then opens it in a worker isolate.
Future<DbConnection?> openAsyncDb(
  String path, {
  String? password,
  bool readOnly = false,
  bool create = false,
}) async {
  if (!create && !await ZxDatabaseAsync.hasDatabase(path, password: password)) {
    return null;
  }
  final db = await ZxDatabaseAsync.open(
    path,
    password: password,
    readOnly: readOnly,
    create: create,
  );
  return AsyncDbConnection(db);
}
