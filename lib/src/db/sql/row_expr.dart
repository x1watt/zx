// A SQL expression evaluated over plain rows (lists of values), outside
// of a statement: the WHERE of a rollup is compiled with the SQL engine's
// planner against the columns of its series and tested on each row.
//
//   final w = ZxRowExpr.compile('level = ''error'' AND latency > 2',
//       ['ts', 'level', 'latency'], ['DATETIME', 'TEXT', 'REAL'], snap);
//   if (w.test(row)) ...
//
// Aggregates are refused. Subqueries read the tables of [snap].

import '../storage_api.dart';
import 'ast.dart';
import 'catalog.dart';
import 'eval.dart';
import 'functions.dart';
import 'parser.dart';
import 'planner.dart';
import 'value.dart';

// SqlEnv wants a store; a row expression never opens other snapshots.
class _NoStore implements ZxStore {
  @override
  ZxSnapshot snapshot({int? generation, int? atTimeNs}) =>
      throw const ZxDbException(
          'AS OF inside a row expression', ZxDbError.unsupported);
  @override
  ZxWriteTxn begin({int waitMs = 5000}) =>
      throw const ZxDbException('read only', ZxDbError.readOnly);
  @override
  List<({int generation, int timeNs, String? comment})> get generations =>
      const [];
  @override
  void close() {}
}

final ZxFunctionRegistry _defaultFunctions = ZxFunctionRegistry();

class ZxRowExpr {
  final Ev _ev;
  final Frame _f;
  ZxRowExpr._(this._ev, this._f);

  /// Parses [sql] (one expression) and compiles it against columns [cols]
  /// with declared [types] (null entries: no type), reading tables of
  /// [snap] when it has subqueries.
  static ZxRowExpr compile(
      String sql, List<String> cols, List<String?> types, ZxSnapshot snap,
      {ZxFunctionRegistry? functions, int? nowNs}) =>
      compileExpr(Parser.parseExpr(sql), cols, types, snap,
          functions: functions, nowNs: nowNs);

  static ZxRowExpr compileExpr(
      Expr e, List<String> cols, List<String?> types, ZxSnapshot snap,
      {ZxFunctionRegistry? functions, int? nowNs}) {
    final env = SqlEnv(_NoStore(), functions ?? _defaultFunctions);
    final ctx = ExecCtx(env, snap, null, Catalog.load(snap), const [],
        nowNs ?? DateTime.now().microsecondsSinceEpoch * 1000);
    final pl = Planner(ctx);
    final sc = Scope(null, null);
    sc.sources.add(SourceInfo(
        null,
        'row',
        cols,
        [
          // series rows: a DATETIME is ns, compared as time
          for (final t in types)
            kindOfType(t) == ZxColumnKind.datetime
                ? Affinity.timeNs
                : affinityOfType(t)
        ],
        List<Collation?>.filled(cols.length, null),
        [
          for (final t in types)
            kindOfType(t) == ZxColumnKind.json ||
                kindOfType(t) == ZxColumnKind.array
        ],
        List<bool>.filled(cols.length, false),
        0)
      ..types = types);
    final ev = pl.compileTop(e, sc);
    return ZxRowExpr._(ev, Frame(ctx, 1, null));
  }

  /// The value of the expression for [row].
  Object? eval(List<Object?> row) {
    _f.rows[0] = row;
    return _ev.eval(_f);
  }

  /// True when the expression is true for [row] (NULL and false: false).
  bool test(List<Object?> row) => truth(eval(row)) == true;
}
