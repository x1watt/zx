// Adapts the system layer's tables and functions (sys_vtab.dart,
// register.dart) to the SQL engine's virtual table interface
// (lib/src/db/sql/vtab.dart) and function registry
// (lib/src/db/sql/functions.dart).
//
// Wiring (the SQL session, once per database / archive):
//
//   final sys = ZxSystemSql(archive: ZxArchiveView.open(path));
//   sys.register(sql.registerVirtualTable, sql.functions);
//
// AS OF: a scan with ctx.asOf reads the archive as of the generation of
// ctx.snapshot (a database commit is an archive generation). The metadata
// tables read ctx.snapshot and write ctx.txn.

import '../sql/functions.dart';
import '../sql/vtab.dart';
import '../storage_api.dart';
import '../meta/fts.dart';
import '../meta/meta_store.dart';
import 'archive_view.dart';
import 'functions.dart';
import 'system_tables.dart';
import 'sys_vtab.dart';
import 'tlsh_index.dart';

SysOp? _op(ZxConstraintOp o) => switch (o) {
      ZxConstraintOp.eq || ZxConstraintOp.isOp => SysOp.eq,
      ZxConstraintOp.ne || ZxConstraintOp.isNot => SysOp.ne,
      ZxConstraintOp.lt => SysOp.lt,
      ZxConstraintOp.le => SysOp.le,
      ZxConstraintOp.gt => SysOp.gt,
      ZxConstraintOp.ge => SysOp.ge,
      ZxConstraintOp.like => SysOp.like,
      ZxConstraintOp.glob => SysOp.glob,
      ZxConstraintOp.isNull => SysOp.isNull,
      ZxConstraintOp.isNotNull => SysOp.isNotNull,
    };

/// A [SysDbAccess] bound to one statement's context.
class _CtxAccess implements SysDbAccess {
  final ZxVtabContext ctx;
  _CtxAccess(this.ctx);
  @override
  (ZxSnapshot, void Function()) read(SysAsOf? asOf) => (ctx.snapshot, () {});
  @override
  ZxWriteTxn get writeTxn {
    final t = ctx.txn;
    if (t == null) {
      throw const ZxDbException(
          'no write transaction is open', ZxDbError.readOnly);
    }
    return t;
  }
}

/// A SQL virtual table over a [SysVTable] made per statement by [make].
class SysVtabAdapter extends ZxWritableVirtualTable {
  final SysVTable Function(SysDbAccess access) make;

  /// Whether the AS OF of a scan maps to an archive generation (archive
  /// tables); database tables read ctx.snapshot directly.
  final bool archiveAsOf;
  late final SysVTable _shape = make(_NoAccess());

  SysVtabAdapter(this.make, {this.archiveAsOf = true});

  @override
  late final List<ZxVtabColumn> columns = [
    for (final c in _shape.columns) ZxVtabColumn(c.name, c.type, c.hidden)
  ];

  @override
  void bestIndex(ZxIndexInfo info) {
    // hidden (parameter) columns of table-valued functions are always
    // usable equality constraints
    final sys = SysIndexInfo([
      for (final c in info.constraints)
        () {
          final op = _op(c.op);
          final ok = c.usable && op != null && c.column >= 0;
          return SysConstraint(c.column < 0 ? 0 : c.column, op ?? SysOp.eq,
              usable: ok &&
                  !(c.op == ZxConstraintOp.isOp || c.op == ZxConstraintOp.isNot));
        }()
    ], [
      for (final o in info.orderBy) SysOrderTerm(o.column, desc: o.desc)
    ]);
    _shape.bestIndex(sys);
    for (var i = 0; i < info.constraints.length; i++) {
      info.argvIndex[i] = sys.argvIndex[i];
      info.omit[i] = sys.omit[i];
    }
    info.idxNum = sys.idxNum;
    info.idxStr = sys.idxStr;
    info.orderByConsumed = sys.orderByConsumed;
    info.estimatedCost = sys.estimatedCost;
    info.estimatedRows = sys.estimatedRows;
  }

  @override
  ZxVtabCursor open(ZxVtabContext ctx) => _Cursor(this, ctx);

  // rows of writable tables are named by their primary key; the cursor
  // hands out rowids and remembers the key of each
  final Map<int, List<Object?>> _keys = {};
  int _nextRowid = 1;
  Object? _keysOf;

  int _rowidFor(ZxVtabContext ctx, List<Object?> key) {
    if (!identical(_keysOf, ctx)) {
      _keys.clear();
      _keysOf = ctx;
    }
    final id = _nextRowid++;
    _keys[id] = key;
    return id;
  }

  SysWritableVTable _writable(ZxVtabContext ctx) {
    final t = make(_CtxAccess(ctx));
    if (t is! SysWritableVTable) {
      throw ZxDbException('${t.name} is read-only', ZxDbError.readOnly);
    }
    return t;
  }

  List<Object?> _keyOf(int rowid) {
    final k = _keys[rowid];
    if (k == null) {
      throw ZxDbException('unknown row $rowid', ZxDbError.notFound);
    }
    return k;
  }

  @override
  int insert(ZxVtabContext ctx, int? rowid, List<Object?> values) {
    final t = _writable(ctx);
    t.insert(values);
    return _rowidFor(ctx, [for (final i in t.primaryKey) values[i]]);
  }

  // INSERT OR REPLACE / OR IGNORE: rows are identified by their primary
  // key, so REPLACE is an insert that overwrites the row with that key.
  @override
  int? insertOr(ZxVtabContext ctx, int? rowid, List<Object?> values,
      ZxConflictMode mode) {
    final t = _writable(ctx);
    final key = [for (final i in t.primaryKey) values[i]];
    switch (mode) {
      case ZxConflictMode.replace:
        t.insert(values, replace: true);
        return _rowidFor(ctx, key);
      case ZxConflictMode.ignore:
        if (t.rowByKey(key) != null) return null;
        t.insert(values);
        return _rowidFor(ctx, key);
      default:
        return insert(ctx, rowid, values);
    }
  }

  // ON CONFLICT DO NOTHING / DO UPDATE: the existing row with the same
  // primary key, if any.
  @override
  (int, List<Object?>)? findConflict(
      ZxVtabContext ctx, List<Object?> values) {
    final t = _writable(ctx);
    final key = [for (final i in t.primaryKey) values[i]];
    final row = t.rowByKey(key);
    if (row == null) return null;
    return (_rowidFor(ctx, key), row);
  }

  @override
  void update(ZxVtabContext ctx, int rowid, List<Object?> values) {
    final t = _writable(ctx);
    t.update(_keyOf(rowid), values);
    _keys[rowid] = [for (final i in t.primaryKey) values[i]];
  }

  @override
  void delete(ZxVtabContext ctx, int rowid) {
    _writable(ctx).delete(_keyOf(rowid));
    _keys.remove(rowid);
  }
}

class _NoAccess implements SysDbAccess {
  @override
  (ZxSnapshot, void Function()) read(SysAsOf? asOf) =>
      throw StateError('no database');
  @override
  ZxWriteTxn get writeTxn => throw StateError('no database');
}

class _Cursor extends ZxVtabCursor {
  final SysVtabAdapter a;
  final ZxVtabContext ctx;
  SysVTable? _t;
  SysCursor? _c;
  int _rowid = 0;
  _Cursor(this.a, this.ctx);

  @override
  void filter(int idxNum, String? idxStr, List<Object?> args) {
    _c?.close();
    final t = _t ??= a.make(_CtxAccess(ctx));
    final info = SysIndexInfo(const [])
      ..idxNum = idxNum
      ..idxStr = idxStr ?? '';
    final asOf = ctx.asOf && a.archiveAsOf
        ? SysAsOf.generation(ctx.snapshot.generation)
        : null;
    _c = t.open(info, args, asOf: asOf);
  }

  @override
  bool next() {
    final c = _c;
    if (c == null || !c.moveNext()) return false;
    final t = _t!;
    if (t is SysWritableVTable) {
      _rowid = a._rowidFor(ctx, [for (final i in t.primaryKey) c.column(i)]);
    } else {
      _rowid = c.rowid;
    }
    return true;
  }

  @override
  Object? column(int i) => _c!.column(i);

  @override
  int get rowid => _rowid;

  @override
  void close() => _c?.close();
}

/// The system layer for one SQL session.
class ZxSystemSql {
  final ZxArchiveView? archive;

  /// Whether the session has a database (metadata tables, persisted TLSH
  /// band index, full-text index).
  final bool database;
  late final ZxSimilarity? similarity =
      archive == null ? null : ZxSimilarity(archive!);

  (ZxSnapshot, int, ZxFtsMatchFunction)? _ftsMatch;

  ZxSystemSql({this.archive, this.database = true});

  /// The virtual tables by name.
  Map<String, ZxVirtualTable> get tables {
    final a = archive;
    return {
      if (a != null) ...{
        'zx_files': SysVtabAdapter((_) => ZxFilesTable(a)),
        'zx_generations': SysVtabAdapter((_) => ZxGenerationsTable(a)),
        'zx_file_history': SysVtabAdapter((_) => ZxFileHistoryTable(a)),
        'similar': SysVtabAdapter((acc) {
          final s = similarity!;
          s.database = database && acc is _CtxAccess ? acc : null;
          return ZxSimilarTable(s);
        }),
      },
      if (database) ...{
        for (final spec in ZxMetaSchema.all)
          spec.name: SysVtabAdapter((acc) => ZxMetaVTable(spec, acc),
              archiveAsOf: false),
        'fts_search':
            SysVtabAdapter((acc) => ZxFtsSearchTable(acc), archiveAsOf: false),
      },
    };
  }

  /// The scalar functions.
  List<ZxScalarFunction> get functions => [
        for (final f in zxSystemFunctions)
          ZxScalarFunction(f.name, f.minArgs, f.maxArgs, (args, _) => f.fn(args),
              deterministic: f.deterministic),
        if (database)
          ZxScalarFunction('fts_match', 2, 2, (args, ctx) {
            if (args[1] is! String) return null;
            // one matcher (and its per-query cache) per statement: the
            // snapshot and the statement time name it
            var m = _ftsMatch;
            if (m == null ||
                !identical(m.$1, ctx.snapshot) ||
                m.$2 != ctx.nowNs) {
              m = _ftsMatch = (
                ctx.snapshot,
                ctx.nowNs,
                ZxFtsMatchFunction(_SnapAccess(ctx.snapshot))
              );
            }
            return m.$3.call(args);
          }, deterministic: false),
      ];

  /// Registers the tables and functions.
  void register(void Function(String name, ZxVirtualTable t) registerTable,
      ZxFunctionRegistry functionRegistry) {
    tables.forEach(registerTable);
    for (final f in functions) {
      functionRegistry.scalar(f);
    }
  }
}

class _SnapAccess implements SysDbAccess {
  final ZxSnapshot s;
  _SnapAccess(this.s);
  @override
  (ZxSnapshot, void Function()) read(SysAsOf? asOf) => (s, () {});
  @override
  ZxWriteTxn get writeTxn => throw StateError('read only');
}
