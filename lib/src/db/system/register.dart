// Everything the system layer adds to a database session, in one place,
// for the SQL engine to register: the virtual tables (system tables over
// the archive, table-valued functions, the arca metadata tables) and the
// scalar functions. See docs/zxdb-design.md "Implementation notes: system
// tables and metadata" for the wiring calls.

import '../meta/fts.dart';
import '../meta/meta_store.dart';
import '../storage_api.dart';
import 'archive_view.dart';
import 'functions.dart';
import 'system_tables.dart';
import 'sys_vtab.dart';
import 'tlsh_index.dart';

class ZxSystemCatalog {
  /// The archive (null for a database that is not inside an archive: then
  /// only the metadata tables and the functions exist).
  final ZxArchiveView? archive;

  /// The database (null for an archive without one: then the metadata
  /// tables do not exist and similar() uses the lazy index).
  final SysDbAccess? db;

  late final ZxSimilarity? similarity =
      archive == null ? null : ZxSimilarity(archive!, database: db);
  late final ZxFtsMatchFunction? _ftsMatch =
      db == null ? null : ZxFtsMatchFunction(db!);

  ZxSystemCatalog({this.archive, this.db});

  /// The virtual tables by name.
  late final Map<String, SysVTable> tables = {
    if (archive != null) ...{
      'zx_files': ZxFilesTable(archive!),
      'zx_generations': ZxGenerationsTable(archive!),
      'zx_file_history': ZxFileHistoryTable(archive!),
      'similar': ZxSimilarTable(similarity!),
    },
    if (db != null) ...{
      for (final t in zxMetaTables(db!)) t.name: t,
      'fts_search': ZxFtsSearchTable(db!),
    },
  };

  /// The scalar functions.
  late final List<SysFunction> functions = [
    ...zxSystemFunctions,
    if (_ftsMatch != null)
      SysFunction('fts_match', 2, 2, _ftsMatch.call, deterministic: false),
  ];

  /// Call at the start of each statement (drops per-statement caches).
  void beginStatement() => _ftsMatch?.reset();

  /// The CREATE statements of the metadata tables (for .schema).
  List<String> get schema => [for (final s in ZxMetaSchema.all) s.ddl];

  /// Creates the metadata schema in [txn] (idempotent).
  static void createSchema(ZxWriteTxn txn) => ZxMetaSchema.create(txn);

  /// Before a database commit that also writes an archive generation:
  /// brings the persisted TLSH band index up to the archive's latest
  /// generation (cheap when nothing new has a digest).
  void beforeCommit(ZxWriteTxn txn) {
    final a = archive;
    if (a != null) ZxTlshStore.sync(txn, a);
  }
}
