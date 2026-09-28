// Virtual tables: the interface other zxdb modules implement to appear as
// tables in SQL (system tables such as zx_files, KV stores seen as
// two-column tables, table-valued functions such as json_each).
//
// The model follows SQLite's virtual table API (xBestIndex / xFilter /
// xNext / xColumn), reduced to what zxdb needs:
//
// 1. Registration. `ZxSql.registerVirtualTable('zx_files', vt)` makes a
//    table name resolve to [vt] (an "eponymous" virtual table: it exists
//    without CREATE). `ZxSql.addVirtualTableResolver(fn)` resolves names
//    dynamically (called for names that are not in the SQL catalog, for
//    example the KV stores created by CREATE KV STORE).
//
// 2. Planning. For each use of the table in a query the planner calls
//    [ZxVirtualTable.bestIndex] once with the constraints of the WHERE /
//    ON clauses that apply to it (`column op value`, where the value does
//    not depend on this table) and the ORDER BY terms. The table marks the
//    constraints it wants as arguments (argvIndex, 1-based position in the
//    filter argument list) and those it fully enforces itself (omit: the
//    executor does not test them again), and chooses an idxNum / idxStr
//    to recognise its plan in [ZxVtabCursor.filter]. A constraint that is
//    not marked is simply tested by the executor on every row, so a
//    minimal implementation can ignore bestIndex entirely (full scan).
//
// 3. Execution. For each scan the executor calls [ZxVirtualTable.open],
//    then [ZxVtabCursor.filter] with the chosen idxNum, idxStr and the
//    argument values, then [ZxVtabCursor.next] until it returns false,
//    reading [ZxVtabCursor.column] for the needed columns.
//
// Table-valued functions: hidden columns are parameters. In
// `SELECT * FROM json_each(x, '$.a')` the call arguments become equality
// constraints on the hidden columns in declaration order, exactly as in
// SQLite, and are always usable. [ZxTableFunction] is a simpler base
// class for functions that just produce rows from their arguments.
//
// Writes: a table implementing [ZxWritableVirtualTable] accepts INSERT,
// UPDATE and DELETE; rows are identified by [ZxVtabCursor.rowid]. The
// engine calls insertOr / updateOr with the statement's conflict mode
// (INSERT OR REPLACE, REPLACE INTO, UPDATE OR IGNORE...; abort by
// default), and for upserts (ON CONFLICT DO NOTHING / DO UPDATE) asks
// findConflict for the existing row, then calls update on it.
//
// Time travel: `FROM t AS OF ...` on a virtual table passes the requested
// snapshot in [ZxVtabContext.snapshot].

import '../storage_api.dart';

class ZxVtabColumn {
  final String name;

  /// Declared type (affinity and zx kind, as for ordinary columns).
  final String? type;

  /// Hidden columns are not part of `SELECT *`; they are the parameters
  /// of table-valued functions.
  final bool hidden;
  const ZxVtabColumn(this.name, [this.type, this.hidden = false]);
}

enum ZxConstraintOp { eq, gt, ge, lt, le, ne, isNull, isNotNull, like, glob, isOp, isNot }

class ZxIndexConstraint {
  /// Column index in [ZxVirtualTable.columns]; -1 is the rowid.
  final int column;
  final ZxConstraintOp op;

  /// False when the value is not available for this plan (it depends on a
  /// table joined later); such constraints must not get an argvIndex.
  final bool usable;
  const ZxIndexConstraint(this.column, this.op, this.usable);
}

class ZxIndexOrderBy {
  final int column;
  final bool desc;
  const ZxIndexOrderBy(this.column, this.desc);
}

class ZxIndexInfo {
  final List<ZxIndexConstraint> constraints;
  final List<ZxIndexOrderBy> orderBy;

  /// Columns the query reads (projection pushdown hint).
  final Set<int> columnsUsed;

  /// Outputs, one per constraint: 1-based position of the constraint's
  /// value in the filter arguments (0: not used).
  final List<int> argvIndex;

  /// Outputs: the table enforces the constraint itself.
  final List<bool> omit;
  int idxNum = 0;
  String? idxStr;

  /// True when rows come out in the requested ORDER BY order.
  bool orderByConsumed = false;
  double estimatedCost = 1e6;
  int estimatedRows = 1000000;

  ZxIndexInfo(this.constraints, this.orderBy, this.columnsUsed)
      : argvIndex = List.filled(constraints.length, 0),
        omit = List.filled(constraints.length, false);
}

/// What a virtual table sees of the statement.
class ZxVtabContext {
  /// The snapshot the statement reads: the current one, the write
  /// transaction, or the AS OF snapshot.
  final ZxSnapshot snapshot;

  /// The write transaction, when the statement writes.
  final ZxWriteTxn? txn;

  /// Statement time, ns since the Unix epoch.
  final int nowNs;

  /// True when this scan is `AS OF` an older state.
  final bool asOf;
  const ZxVtabContext(this.snapshot, this.txn, this.nowNs, {this.asOf = false});
}

abstract class ZxVtabCursor {
  /// Starts a scan. [args] holds the values of the constraints given an
  /// argvIndex, in argvIndex order.
  void filter(int idxNum, String? idxStr, List<Object?> args);

  /// Moves to the next row (the first row on the first call); false at the
  /// end.
  bool next();

  /// Value of column [i] of the current row (SQL value: null, int, double,
  /// String or Uint8List).
  Object? column(int i);

  /// Rowid of the current row (for writable tables; any unique int else).
  int get rowid;

  void close() {}
}

abstract class ZxVirtualTable {
  List<ZxVtabColumn> get columns;

  /// Chooses a plan (see the file comment). The default is a full scan.
  void bestIndex(ZxIndexInfo info) {}

  ZxVtabCursor open(ZxVtabContext ctx);
}

/// Conflict resolution of INSERT OR ... / UPDATE OR ... (SQLite's ON
/// CONFLICT algorithms). [abort] is the default: fail the statement.
enum ZxConflictMode { abort, fail, ignore, replace, rollback }

abstract class ZxWritableVirtualTable extends ZxVirtualTable {
  /// Inserts a row (values for every column in [columns] order, hidden
  /// columns included, with the requested rowid or null); returns the
  /// rowid. A key conflict throws ZxDbException(constraint).
  int insert(ZxVtabContext ctx, int? rowid, List<Object?> values);

  void update(ZxVtabContext ctx, int rowid, List<Object?> values);

  void delete(ZxVtabContext ctx, int rowid);

  /// INSERT with a conflict mode (INSERT OR REPLACE / IGNORE, REPLACE
  /// INTO). Returns the rowid, or null when the row was skipped
  /// ([ZxConflictMode.ignore] on a conflict). With
  /// [ZxConflictMode.replace] an existing row with the same key is
  /// replaced. The default implementation calls [insert] (abort semantics)
  /// and, for ignore, skips rows whose insert throws a constraint error;
  /// override it to support replace.
  int? insertOr(ZxVtabContext ctx, int? rowid, List<Object?> values,
      ZxConflictMode mode) {
    if (mode == ZxConflictMode.ignore) {
      try {
        return insert(ctx, rowid, values);
      } on ZxDbException catch (e) {
        if (e.kind == ZxDbError.constraint) return null;
        rethrow;
      }
    }
    return insert(ctx, rowid, values);
  }

  /// UPDATE with a conflict mode; returns false when the row was skipped
  /// (ignore). With replace, a different row holding the new key is
  /// removed first. Default: [update], ignore skips constraint errors.
  bool updateOr(ZxVtabContext ctx, int rowid, List<Object?> values,
      ZxConflictMode mode) {
    if (mode == ZxConflictMode.ignore) {
      try {
        update(ctx, rowid, values);
        return true;
      } on ZxDbException catch (e) {
        if (e.kind == ZxDbError.constraint) return false;
        rethrow;
      }
    }
    update(ctx, rowid, values);
    return true;
  }

  /// For upserts (INSERT ... ON CONFLICT DO NOTHING / DO UPDATE): the
  /// existing row whose key conflicts with the proposed [values] (full
  /// column list), as (rowid usable with [update], its values), or null.
  /// The default returns null, so an upsert behaves as a plain INSERT
  /// (a conflict then fails with the error of [insert]).
  (int, List<Object?>)? findConflict(ZxVtabContext ctx, List<Object?> values) =>
      null;
}

/// A table-valued function: parameters are hidden columns after [outputs].
abstract class ZxTableFunction extends ZxVirtualTable {
  List<String> get outputs;
  List<String> get parameters;

  /// Number of leading parameters that must be given.
  int get requiredParameters => parameters.length;

  Iterable<List<Object?>> rows(List<Object?> args, ZxVtabContext ctx);

  @override
  List<ZxVtabColumn> get columns => [
        for (final o in outputs) ZxVtabColumn(o),
        for (final p in parameters) ZxVtabColumn(p, null, true),
      ];

  @override
  void bestIndex(ZxIndexInfo info) {
    final n = outputs.length;
    // Use equality constraints on the parameters as arguments.
    final pos = List<int>.filled(parameters.length, -1);
    for (var i = 0; i < info.constraints.length; i++) {
      final c = info.constraints[i];
      if (c.usable && c.op == ZxConstraintOp.eq && c.column >= n) {
        pos[c.column - n] = i;
      }
    }
    var k = 0;
    var mask = 0;
    for (var p = 0; p < parameters.length; p++) {
      if (pos[p] >= 0) {
        info.argvIndex[pos[p]] = ++k;
        info.omit[pos[p]] = true;
        mask |= 1 << p;
      }
    }
    info.idxNum = mask;
    info.estimatedCost = mask == 0 ? 1e12 : 100;
  }

  @override
  ZxVtabCursor open(ZxVtabContext ctx) => _TfCursor(this, ctx);
}

class _TfCursor extends ZxVtabCursor {
  final ZxTableFunction f;
  final ZxVtabContext ctx;
  Iterator<List<Object?>>? _it;
  List<Object?> _args = const [];
  List<Object?>? _row;
  int _rowid = 0;
  _TfCursor(this.f, this.ctx);

  @override
  void filter(int idxNum, String? idxStr, List<Object?> args) {
    final full = List<Object?>.filled(f.parameters.length, null);
    var k = 0;
    var given = 0;
    for (var p = 0; p < f.parameters.length; p++) {
      if (idxNum & (1 << p) != 0) {
        full[p] = args[k++];
        given = p + 1;
      }
    }
    if (given < f.requiredParameters) {
      throw ZxDbException(
          'too few arguments for table-valued function ${f.runtimeType}');
    }
    _args = full;
    _it = f.rows(full, ctx).iterator;
    _rowid = 0;
  }

  @override
  bool next() {
    if (_it == null || !_it!.moveNext()) {
      _row = null;
      return false;
    }
    _row = _it!.current;
    _rowid++;
    return true;
  }

  @override
  Object? column(int i) {
    final n = f.outputs.length;
    if (i >= n) return _args[i - n];
    return _row![i];
  }

  @override
  int get rowid => _rowid;
}
