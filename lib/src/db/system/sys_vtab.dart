// The small virtual table interface the system and metadata tables are
// written against (docs/zxdb-design.md, 1.1 and 1.2). It follows SQLite's
// xBestIndex / xFilter / xColumn model so that an adapter to the SQL
// engine's own interface (lib/src/db/sql/vtab.dart) is a thin wrapper:
//
//   bestIndex(info)  the planner offers the usable constraints and the
//                    wanted order; the table picks a plan (idxNum, idxStr),
//                    says which constraint values it wants as arguments
//                    (argvIndex) and whether the engine may skip checking
//                    them again (omit), and gives a cost.
//   open(plan, args) runs the plan with the constraint values.
//
// Table-valued functions (similar(), fts_search()) are tables with hidden
// argument columns, as SQLite's eponymous virtual tables: `similar(x, 20)`
// is `similar WHERE query = x AND n = 20`.
//
// SQL values are plain Dart objects: null, int, double, String, Uint8List,
// bool (as 0/1 by the engine), and List<Object?> for ARRAY columns.

import 'dart:typed_data';

import '../storage_api.dart';

/// Constraint operators a table can use.
enum SysOp { eq, ne, lt, le, gt, ge, like, glob, isNull, isNotNull, match }

class SysColumn {
  final String name;

  /// Declared type: INTEGER, REAL, TEXT, BLOB, DATETIME, JSON, ARRAY.
  final String type;

  /// Argument columns of a table-valued function (not in SELECT *).
  final bool hidden;
  const SysColumn(this.name, this.type, {this.hidden = false});
}

/// One WHERE term the planner offers: column [column] [op] value.
class SysConstraint {
  final int column;
  final SysOp op;

  /// False when the value is not available at this point of the plan
  /// (for example a join column of a later table).
  final bool usable;
  const SysConstraint(this.column, this.op, {this.usable = true});
}

class SysOrderTerm {
  final int column;
  final bool desc;
  const SysOrderTerm(this.column, {this.desc = false});
}

/// The input and the output of [SysVTable.bestIndex].
class SysIndexInfo {
  final List<SysConstraint> constraints;
  final List<SysOrderTerm> orderBy;

  /// Outputs: the plan id and text, for [SysVTable.open].
  int idxNum = 0;
  String idxStr = '';

  /// Per constraint: 1-based position of its value in the args of
  /// [SysVTable.open], or 0 when not used.
  final List<int> argvIndex;

  /// Per constraint: the table guarantees it, the engine need not check.
  final List<bool> omit;

  /// The rows come out in [orderBy] order already.
  bool orderByConsumed = false;
  double estimatedCost = 1e9;
  int estimatedRows = 1000000;

  SysIndexInfo(this.constraints, [this.orderBy = const []])
      : argvIndex = List<int>.filled(constraints.length, 0),
        omit = List<bool>.filled(constraints.length, false);

  /// Uses constraint [i] as the next argument; returns its position.
  int use(int i, {bool omit = true}) {
    var next = 0;
    for (final a in argvIndex) {
      if (a > next) next = a;
    }
    argvIndex[i] = next + 1;
    this.omit[i] = omit;
    return next + 1;
  }
}

/// A point in the history of the archive and database: `AS OF GENERATION
/// n`, `AS OF 'YYYY-MM-DD[ HH:MM[:SS]]'` (local time, the end of that day,
/// minute or second, as zx -mversion does) or `AS OF` a time in ns.
class SysAsOf {
  final int? generation;
  final String? date;
  final int? timeNs;
  const SysAsOf.generation(int this.generation)
      : date = null,
        timeNs = null;
  const SysAsOf.date(String this.date)
      : generation = null,
        timeNs = null;
  const SysAsOf.time(int this.timeNs)
      : generation = null,
        date = null;

  @override
  String toString() => generation != null
      ? 'AS OF GENERATION $generation'
      : date != null
          ? "AS OF '$date'"
          : 'AS OF $timeNs';
}

/// A cursor over the rows of one [SysVTable.open].
abstract class SysCursor {
  /// Advances to the next row; false at the end.
  bool moveNext();

  /// The value of column [i] of the current row.
  Object? column(int i);

  /// A stable id of the current row (SQLite's rowid), for UPDATE/DELETE.
  int get rowid;

  void close() {}
}

abstract class SysVTable {
  String get name;
  List<SysColumn> get columns;

  /// Picks a plan for the constraints; fills [info]'s outputs.
  void bestIndex(SysIndexInfo info);

  /// Runs plan [info] with [args] (values of the used constraints in
  /// argvIndex order), as of [asOf] (null: the current state).
  SysCursor open(SysIndexInfo info, List<Object?> args, {SysAsOf? asOf});

  int columnIndex(String name) {
    final c = columns;
    for (var i = 0; i < c.length; i++) {
      if (c[i].name == name) return i;
    }
    return -1;
  }
}

/// A virtual table that accepts INSERT, UPDATE and DELETE (the metadata
/// tables). Rows are full column value lists; rows are identified by their
/// primary key values ([primaryKey] gives the key columns), as a WITHOUT
/// ROWID table.
abstract class SysWritableVTable extends SysVTable {
  /// Column numbers of the primary key, in key order.
  List<int> get primaryKey;

  /// Inserts [row]; with [replace] an existing row with the same key is
  /// replaced, otherwise that is a constraint error.
  void insert(List<Object?> row, {bool replace = false});

  /// Replaces the row with key [oldKey] by [row] (the key may change).
  void update(List<Object?> oldKey, List<Object?> row);

  /// Deletes the row with key [key]; true when it existed.
  bool delete(List<Object?> key);

  /// The row stored under [key] in the write transaction, or null (used
  /// for ON CONFLICT handling). Tables without key lookup return null.
  List<Object?>? rowByKey(List<Object?> key) => null;
}

/// A cursor over precomputed rows.
class SysListCursor extends SysCursor {
  final List<List<Object?>> rows;
  int _i = -1;
  SysListCursor(this.rows);
  @override
  bool moveNext() => ++_i < rows.length;
  @override
  Object? column(int i) => rows[_i][i];
  @override
  int get rowid => _i;
}

/// Reads every row of [t] (no constraints): tests and tools.
List<List<Object?>> sysScanAll(SysVTable t, {SysAsOf? asOf}) =>
    sysQuery(t, const [], asOf: asOf);

/// Runs [t] with equality and range constraints given as (column name, op,
/// value), letting the table pick its plan, and checks the constraints the
/// table did not omit (what the SQL engine does). For tests and tools.
List<List<Object?>> sysQuery(SysVTable t, List<(String, SysOp, Object?)> where,
    {SysAsOf? asOf}) {
  final cols = [for (final w in where) t.columnIndex(w.$1)];
  for (var i = 0; i < cols.length; i++) {
    if (cols[i] < 0) throw ArgumentError('no column ${where[i].$1}');
  }
  final info = SysIndexInfo(
      [for (var i = 0; i < where.length; i++) SysConstraint(cols[i], where[i].$2)]);
  t.bestIndex(info);
  var n = 0;
  for (final a in info.argvIndex) {
    if (a > n) n = a;
  }
  final args = List<Object?>.filled(n, null);
  for (var i = 0; i < where.length; i++) {
    if (info.argvIndex[i] > 0) args[info.argvIndex[i] - 1] = where[i].$3;
  }
  final c = t.open(info, args, asOf: asOf);
  final out = <List<Object?>>[];
  final width = t.columns.length;
  while (c.moveNext()) {
    final row = [for (var i = 0; i < width; i++) c.column(i)];
    var ok = true;
    for (var i = 0; i < where.length && ok; i++) {
      if (info.omit[i]) continue;
      ok = sysCheck(row[cols[i]], where[i].$2, where[i].$3);
    }
    if (ok) out.add(row);
  }
  c.close();
  return out;
}

/// Evaluates `a op b` with SQLite-like comparison rules (numbers before
/// text before blobs; NULL compares false).
bool sysCheck(Object? a, SysOp op, Object? b) {
  switch (op) {
    case SysOp.isNull:
      return a == null;
    case SysOp.isNotNull:
      return a != null;
    case SysOp.like:
      return a is String && b is String && sysLike(b, a);
    case SysOp.glob:
      return a is String && b is String && sysGlob(b, a);
    case SysOp.match:
      return false;
    default:
  }
  if (a == null || b == null) return false;
  final c = sysCompare(a, b);
  return switch (op) {
    SysOp.eq => c == 0,
    SysOp.ne => c != 0,
    SysOp.lt => c < 0,
    SysOp.le => c <= 0,
    SysOp.gt => c > 0,
    SysOp.ge => c >= 0,
    _ => false,
  };
}

int _rank(Object v) => v is num
    ? 1
    : v is String
        ? 2
        : 3;

/// Orders two non-null values as SQLite does.
int sysCompare(Object a, Object b) {
  final ra = _rank(a), rb = _rank(b);
  if (ra != rb) return ra - rb;
  if (a is num && b is num) return a.compareTo(b);
  if (a is String && b is String) return a.compareTo(b);
  if (a is Uint8List && b is Uint8List) return sysCompareBytes(a, b);
  return 0;
}

int sysCompareBytes(Uint8List a, Uint8List b) {
  final n = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    final d = a[i] - b[i];
    if (d != 0) return d;
  }
  return a.length - b.length;
}

/// SQL LIKE: `%` any run, `_` one character, ASCII case insensitive.
bool sysLike(String pattern, String s) {
  final re = StringBuffer('^');
  for (final r in pattern.runes) {
    final c = String.fromCharCode(r);
    if (c == '%') {
      re.write('.*');
    } else if (c == '_') {
      re.write('.');
    } else {
      re.write(RegExp.escape(c));
    }
  }
  re.write(r'$');
  return RegExp(re.toString(), caseSensitive: false, dotAll: true).hasMatch(s);
}

/// SQL GLOB: `*`, `?`, case sensitive (character classes as literals).
bool sysGlob(String pattern, String s) {
  final re = StringBuffer('^');
  for (final r in pattern.runes) {
    final c = String.fromCharCode(r);
    if (c == '*') {
      re.write('.*');
    } else if (c == '?') {
      re.write('.');
    } else {
      re.write(RegExp.escape(c));
    }
  }
  re.write(r'$');
  return RegExp(re.toString(), dotAll: true).hasMatch(s);
}

/// The literal prefix of a LIKE pattern before its first wildcard, when
/// the rest is a single trailing `%` (so the pattern is `prefix%`), else
/// null. LIKE is case insensitive, so the prefix is usable for a range
/// scan only when it has no letters.
String? sysLikePrefix(String pattern) {
  final i = pattern.indexOf(RegExp(r'[%_]'));
  if (i < 0 || i != pattern.length - 1 || pattern[i] != '%') return null;
  return pattern.substring(0, i);
}

/// The literal prefix of a GLOB pattern `prefix*` (case sensitive, so a
/// range scan is exact), else null.
String? sysGlobPrefix(String pattern) {
  final i = pattern.indexOf(RegExp(r'[*?\[]'));
  if (i < 0 || i != pattern.length - 1 || pattern[i] != '*') return null;
  return pattern.substring(0, i);
}

/// Where database-backed tables read from and write to: the latest state
/// or the one of an AS OF, and the current write transaction.
abstract class SysDbAccess {
  /// A read view as of [asOf] (null: the latest, the open transaction
  /// included). The caller calls the returned release function when done.
  (ZxSnapshot, void Function() release) read(SysAsOf? asOf);

  /// The write transaction statements write into.
  ZxWriteTxn get writeTxn;
}
