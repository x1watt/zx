// Expression evaluation: the execution context, row frames and compiled
// expression nodes (SQLite semantics: three-valued logic, affinity,
// integer overflow to REAL, collations).

import 'dart:typed_data';

import '../keycodec.dart';
import '../storage_api.dart';
import 'catalog.dart';
import 'datetime.dart' show zxFormatDatetimeNs;
import 'functions.dart';
import 'value.dart';
import 'vtab.dart';

/// Engine wide state shared by statements (set up by ZxSql).
class SqlEnv {
  final ZxStore store;
  final ZxFunctionRegistry functions;
  final Map<String, ZxVirtualTable> vtabs = {};
  final List<ZxVirtualTable? Function(String name, ZxSnapshot snap)>
      resolvers = [];
  SqlEnv(this.store, this.functions);

  ZxVirtualTable? findVtab(String name, ZxSnapshot snap) {
    final v = vtabs[name.toLowerCase()];
    if (v != null) return v;
    for (final r in resolvers) {
      final x = r(name, snap);
      if (x != null) return x;
    }
    return null;
  }
}

/// Undo log of one statement inside an explicit transaction (statement
/// atomicity: a failing statement leaves no partial changes).
class UndoLog {
  final List<(ZxWritableTree, Uint8List, Uint8List?)> entries = [];

  void undo() {
    for (var i = entries.length - 1; i >= 0; i--) {
      final (t, k, v) = entries[i];
      if (v == null) {
        t.delete(k);
      } else {
        t.put(k, v);
      }
    }
    entries.clear();
  }
}

class _UndoTree implements ZxWritableTree {
  final ZxWritableTree inner;
  final UndoLog log;
  _UndoTree(this.inner, this.log);

  @override
  String get name => inner.name;
  @override
  TreeOptions get options => inner.options;
  @override
  Uint8List? get(Uint8List key) => inner.get(key);
  @override
  ZxCursor scan({Uint8List? from, Uint8List? to, bool reverse = false}) =>
      inner.scan(from: from, to: to, reverse: reverse);
  @override
  int get length => inner.length;

  @override
  void put(Uint8List key, Uint8List value) {
    log.entries.add((inner, key, inner.get(key)));
    inner.put(key, value);
  }

  @override
  bool delete(Uint8List key) {
    final old = inner.get(key);
    if (old == null) return false;
    log.entries.add((inner, key, old));
    return inner.delete(key);
  }

  @override
  int deleteRange({Uint8List? from, Uint8List? to}) {
    final c = inner.scan(from: from, to: to);
    var n = 0;
    try {
      while (c.moveNext()) {
        log.entries.add((inner, c.key, c.value));
        n++;
      }
    } finally {
      c.close();
    }
    inner.deleteRange(from: from, to: to);
    return n;
  }
}

/// Per statement execution state.
class ExecCtx implements ZxFunctionContext {
  final SqlEnv env;
  final ZxSnapshot snap;
  @override
  final ZxWriteTxn? txn;
  final Catalog catalog;
  final List<Object?> params;
  @override
  final int nowNs;
  UndoLog? undo;

  /// Per execution caches (uncorrelated subqueries, materialized CTEs).
  final Map<Object, Object?> cache = Map.identity();
  final List<ZxSnapshot> extraSnaps = [];
  final Map<int, (ZxSnapshot, Catalog)> asOfSnaps = {};

  /// Rows of EXPLAIN QUERY PLAN while planning (null when not explaining).
  List<List<Object?>>? eqp;
  int eqpParent = 0;
  int _eqpId = 0;

  int nChanges = 0;
  int lastRowid;
  int totalChangesBase;

  ExecCtx(this.env, this.snap, this.txn, this.catalog, this.params, this.nowNs,
      {this.lastRowid = 0, this.totalChangesBase = 0});

  @override
  ZxSnapshot get snapshot => snap;
  @override
  bool argIsJson(int i) => _jsonArgs != null && i < _jsonArgs!.length && _jsonArgs![i];
  List<bool>? _jsonArgs;
  @override
  int get lastInsertRowid => lastRowid;
  @override
  int get changes => nChanges;
  @override
  int get totalChanges => totalChangesBase + nChanges;

  ZxTree? tree(String name) => snap.tree(name);

  ZxWritableTree wtree(String name) {
    final t = txn!.tree(name);
    if (t == null) throw ZxDbException('missing tree $name', ZxDbError.corrupt);
    final u = undo;
    return u == null ? t : _UndoTree(t, u);
  }

  /// Adds an EXPLAIN QUERY PLAN row; returns its id.
  int explain(String detail, [int? parent]) {
    final id = ++_eqpId;
    eqp?.add([id, parent ?? eqpParent, 0, detail]);
    return id;
  }

  void closeExtra() {
    for (final s in extraSnaps) {
      s.close();
    }
    extraSnaps.clear();
  }
}

/// Runtime row environment of one query level.
class Frame {
  final ExecCtx ctx;
  final List<List<Object?>?> rows;
  final Frame? outer;
  List<Object?>? agg;
  Frame(this.ctx, int n, this.outer) : rows = List.filled(n, null);
}

// ------------------------------------------------------------ nodes

abstract class Ev {
  Affinity aff = Affinity.none;
  Collation? coll;
  bool explicitColl = false;

  /// The value carries the JSON subtype.
  bool isJson = false;

  Object? eval(Frame f);

  /// Visits child nodes.
  void children(void Function(Ev) f) {}

  /// Bitmask of depth-0 slots this node reads (filled by the planner).
  int deps = 0;

  /// Not constant (random(), subqueries with side effects...).
  bool volatile = false;

  /// The unit of a time number (zx): 0 none, [timeUnitSeconds] for
  /// unixepoch(), [timeUnitJulian] for julianday(), kept by + and - with
  /// a plain number. A DATETIME column of a virtual table (ns) compared
  /// with such a value scales it to ns.
  int timeUnit = 0;

  /// The declared type of the column this node reads (a column reference,
  /// also through views and subqueries), else null. Result sets expose
  /// it so that UIs can format DATETIME ns values.
  String? declType;
}

const timeUnitSeconds = 1;
const timeUnitJulian = 2;

/// Converts the operand of a comparison with a DATETIME column of a
/// virtual table to ns since 1970 UTC: date/time text is parsed,
/// unixepoch() seconds and julianday() days are scaled, other values
/// pass unchanged. Its value is what the planner hands the table as a
/// constraint, so partition pruning and the executor agree.
class TimeNsEv extends Ev {
  final Ev e;
  TimeNsEv(this.e) {
    aff = Affinity.timeNs;
    volatile = e.volatile;
  }

  @override
  Object? eval(Frame f) {
    final v = e.eval(f);
    if (v == null) return null;
    switch (e.timeUnit) {
      case timeUnitSeconds:
        final n = toNumber(v);
        if (n is int) return n * 1000000000;
        if (n is double) return (n * 1e9).round();
        return v;
      case timeUnitJulian:
        final n = toNumber(v);
        if (n == null) return v;
        return ((n - 2440587.5) * 86400000.0).round() * 1000000;
    }
    return timeNsValue(v);
  }

  @override
  void children(void Function(Ev) f) => f(e);
}

/// A DATETIME column (ns since 1970 UTC) given to a date function
/// (date, time, datetime, julianday, unixepoch, strftime): the integer
/// becomes ISO text, so `datetime(ts)` works (zx; the number would be a
/// Julian day number out of range in SQLite).
class NsTimeTextEv extends Ev {
  final Ev e;
  NsTimeTextEv(this.e) {
    volatile = e.volatile;
  }

  @override
  Object? eval(Frame f) {
    final v = e.eval(f);
    return v is int ? zxFormatDatetimeNs(v) : v;
  }

  @override
  void children(void Function(Ev) f) => f(e);
}

/// True when [e] reads a DATETIME column (ns values).
bool isNsTimeColumn(Ev e) =>
    e.aff == Affinity.timeNs ||
    (e.declType != null && kindOfType(e.declType) == ZxColumnKind.datetime);

/// [x] as an operand compared with [other]: wrapped in [TimeNsEv] when
/// [other] is a DATETIME column of a virtual table and [x] is not.
Ev timeOperand(Ev x, Ev other) {
  if (other.aff != Affinity.timeNs || x.aff == Affinity.timeNs) return x;
  if (x is ConstEv && x.timeUnit == 0) {
    // literals are converted once (NULL stays a plain NULL constant)
    if (x.v == null) return x;
    return ConstEv(timeNsValue(x.v))
      ..aff = Affinity.timeNs
      ..coll = x.coll;
  }
  return TimeNsEv(x);
}

class ConstEv extends Ev {
  final Object? v;
  ConstEv(this.v);
  @override
  Object? eval(Frame f) => v;
}

class ParamEv extends Ev {
  final int index; // 1-based
  ParamEv(this.index);
  @override
  Object? eval(Frame f) {
    final p = f.ctx.params;
    return index <= p.length ? p[index - 1] : null;
  }
}

class ColEv extends Ev {
  final int depth, slot, col;
  ColEv(this.depth, this.slot, this.col);
  @override
  Object? eval(Frame f) {
    var fr = f;
    for (var i = 0; i < depth; i++) {
      fr = fr.outer!;
    }
    final r = fr.rows[slot];
    if (r == null) return null;
    return col < r.length ? r[col] : null;
  }
}

class AggRefEv extends Ev {
  final int index;
  AggRefEv(this.index);
  @override
  Object? eval(Frame f) => f.agg![index];
}

class CurrentTimeEv extends Ev {
  final String kind;
  CurrentTimeEv(this.kind);
  @override
  Object? eval(Frame f) {
    final ms = f.ctx.nowNs ~/ 1000000;
    final d = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
    String two(int x) => x.toString().padLeft(2, '0');
    final date = '${d.year.toString().padLeft(4, '0')}-${two(d.month)}-${two(d.day)}';
    final time = '${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
    switch (kind) {
      case 'CURRENT_DATE':
        return date;
      case 'CURRENT_TIME':
        return time;
      default:
        return '$date $time';
    }
  }
}

num? _arith(Object? a) {
  if (a == null) return null;
  if (a is num) return a;
  return toNumber(a);
}

const int _minInt = -0x8000000000000000;

Object? arithmetic(String op, Object? x, Object? y) {
  final a = _arith(x), b = _arith(y);
  if (a == null || b == null) return null;
  if (a is int && b is int) {
    switch (op) {
      case '+':
        final r = a + b;
        if ((a >= 0) == (b >= 0) && (r >= 0) != (a >= 0)) {
          return a.toDouble() + b.toDouble();
        }
        return r;
      case '-':
        final r = a - b;
        if ((a >= 0) != (b >= 0) && (r >= 0) != (a >= 0)) {
          return a.toDouble() - b.toDouble();
        }
        return r;
      case '*':
        if (a == 0 || b == 0) return 0;
        final r = a * b;
        if ((a == -1 && b == _minInt) ||
            (b == -1 && a == _minInt) ||
            r ~/ b != a) {
          return a.toDouble() * b.toDouble();
        }
        return r;
      case '/':
        if (b == 0) return null;
        if (a == _minInt && b == -1) return a.toDouble() / b.toDouble();
        return a ~/ b;
      case '%':
        if (b == 0) return null;
        if (b == -1) return 0;
        return a.remainder(b);
    }
  }
  final ad = a.toDouble(), bd = b.toDouble();
  switch (op) {
    case '+':
      return _real(ad + bd);
    case '-':
      return _real(ad - bd);
    case '*':
      return _real(ad * bd);
    case '/':
      if (bd == 0) return null;
      return _real(ad / bd);
    case '%':
      final ai = a is int ? a : doubleToInt(ad);
      final bi = b is int ? b : doubleToInt(bd);
      if (bi == 0) return null;
      if (bi == -1) return 0.0;
      return ai.remainder(bi).toDouble();
  }
  throw StateError(op);
}

Object? _real(double d) => d.isNaN ? null : d;

class ArithEv extends Ev {
  final String op;
  final Ev l, r;
  ArithEv(this.op, this.l, this.r) {
    // unixepoch('now') - 86400 is still seconds.
    if (op == '+' || op == '-') {
      if (r.timeUnit == 0 && r.aff != Affinity.timeNs) timeUnit = l.timeUnit;
      if (op == '+' && l.timeUnit == 0 && l.aff != Affinity.timeNs) {
        timeUnit = r.timeUnit;
      }
    }
  }
  @override
  Object? eval(Frame f) => arithmetic(op, l.eval(f), r.eval(f));
  @override
  void children(void Function(Ev) f) {
    f(l);
    f(r);
  }
}

class BitEv extends Ev {
  final String op;
  final Ev l, r;
  BitEv(this.op, this.l, this.r);
  @override
  Object? eval(Frame f) {
    final a = l.eval(f), b = r.eval(f);
    if (a == null || b == null) return null;
    // Bitwise operators take the integer prefix of text (SQLite IntValue).
    final x = toInt(a);
    final y = toInt(b);
    switch (op) {
      case '&':
        return x & y;
      case '|':
        return x | y;
      case '<<':
        if (y < 0) return _shr(x, -y);
        return y >= 64 ? 0 : x << y;
      default:
        if (y < 0) return y <= -64 ? 0 : x << -y;
        return _shr(x, y);
    }
  }

  static int _shr(int x, int y) => y >= 64 ? (x < 0 ? -1 : 0) : x >> y;

  @override
  void children(void Function(Ev) f) {
    f(l);
    f(r);
  }
}

class ConcatEv extends Ev {
  final Ev l, r;
  ConcatEv(this.l, this.r);
  @override
  Object? eval(Frame f) {
    final a = l.eval(f);
    if (a == null) return null;
    final b = r.eval(f);
    if (b == null) return null;
    return '${toText(a)}${toText(b)}';
  }

  @override
  void children(void Function(Ev) f) {
    f(l);
    f(r);
  }
}

class NegEv extends Ev {
  final Ev e;
  NegEv(this.e);
  @override
  Object? eval(Frame f) {
    final v = _arith(e.eval(f));
    if (v == null) return null;
    if (v is int) return v == _minInt ? -(v.toDouble()) : -v;
    return -v;
  }

  @override
  void children(void Function(Ev) f) => f(e);
}

class BitNotEv extends Ev {
  final Ev e;
  BitNotEv(this.e);
  @override
  Object? eval(Frame f) {
    final v = e.eval(f);
    if (v == null) return null;
    return ~toInt(v);
  }

  @override
  void children(void Function(Ev) f) => f(e);
}

/// Unary plus: the value, without affinity.
class PlusEv extends Ev {
  final Ev e;
  PlusEv(this.e);
  @override
  Object? eval(Frame f) => e.eval(f);
  @override
  void children(void Function(Ev) f) => f(e);
}

class NotEv extends Ev {
  final Ev e;
  NotEv(this.e);
  @override
  Object? eval(Frame f) {
    final t = truth(e.eval(f));
    if (t == null) return null;
    return t ? 0 : 1;
  }

  @override
  void children(void Function(Ev) f) => f(e);
}

class AndEv extends Ev {
  final Ev l, r;
  AndEv(this.l, this.r);
  @override
  Object? eval(Frame f) {
    final a = truth(l.eval(f));
    if (a == false) return 0;
    final b = truth(r.eval(f));
    if (b == false) return 0;
    if (a == null || b == null) return null;
    return 1;
  }

  @override
  void children(void Function(Ev) f) {
    f(l);
    f(r);
  }
}

class OrEv extends Ev {
  final Ev l, r;
  OrEv(this.l, this.r);
  @override
  Object? eval(Frame f) {
    final a = truth(l.eval(f));
    if (a == true) return 1;
    final b = truth(r.eval(f));
    if (b == true) return 1;
    if (a == null || b == null) return null;
    return 0;
  }

  @override
  void children(void Function(Ev) f) {
    f(l);
    f(r);
  }
}

/// Collation of a binary comparison (SQLite rules).
Collation? binaryCollation(Ev l, Ev r) {
  if (l.explicitColl) return l.coll;
  if (r.explicitColl) return r.coll;
  return l.coll ?? r.coll;
}

/// Compares two operands with affinity [aff] and collation [coll]; null
/// when either is NULL.
int? compareOperands(Object? a, Object? b, Affinity aff, Collation? coll) {
  if (a == null || b == null) return null;
  if (aff != Affinity.none && aff != Affinity.blob) {
    a = applyCompareAffinity(a, aff);
    b = applyCompareAffinity(b, aff);
  }
  return compareValues(a, b, coll);
}

class CmpEv extends Ev {
  final String op; // = != < <= > >=
  final Ev l, r;
  final Affinity cmpAff;
  final Collation? cmpColl;
  CmpEv(this.op, Ev l, Ev r)
      : l = timeOperand(l, r),
        r = timeOperand(r, l),
        cmpAff = comparisonAffinity(l.aff, r.aff),
        cmpColl = binaryCollation(l, r);

  @override
  Object? eval(Frame f) {
    final c = compareOperands(l.eval(f), r.eval(f), cmpAff, cmpColl);
    if (c == null) return null;
    return test(c) ? 1 : 0;
  }

  bool test(int c) {
    switch (op) {
      case '=':
        return c == 0;
      case '!=':
        return c != 0;
      case '<':
        return c < 0;
      case '<=':
        return c <= 0;
      case '>':
        return c > 0;
      default:
        return c >= 0;
    }
  }

  @override
  void children(void Function(Ev) f) {
    f(l);
    f(r);
  }
}

class IsEv extends Ev {
  final bool not;
  final Ev l, r;
  final Affinity cmpAff;
  final Collation? cmpColl;
  IsEv(this.not, Ev l, Ev r)
      : l = timeOperand(l, r),
        r = timeOperand(r, l),
        cmpAff = comparisonAffinity(l.aff, r.aff),
        cmpColl = binaryCollation(l, r);
  @override
  Object? eval(Frame f) {
    final a = l.eval(f), b = r.eval(f);
    bool eq;
    if (a == null || b == null) {
      eq = a == null && b == null;
    } else {
      eq = compareOperands(a, b, cmpAff, cmpColl) == 0;
    }
    return (eq != not) ? 1 : 0;
  }

  @override
  void children(void Function(Ev) f) {
    f(l);
    f(r);
  }
}

class IsNullEv extends Ev {
  final bool not;
  final Ev e;
  IsNullEv(this.not, this.e);
  @override
  Object? eval(Frame f) => ((e.eval(f) == null) != not) ? 1 : 0;
  @override
  void children(void Function(Ev) f) => f(e);
}

class BetweenEv extends Ev {
  final bool not;
  final Ev e, lo, hi;
  final Affinity affLo, affHi;
  final Collation? collLo, collHi;
  BetweenEv(this.not, this.e, Ev lo, Ev hi)
      : lo = timeOperand(lo, e),
        hi = timeOperand(hi, e),
        affLo = comparisonAffinity(e.aff, lo.aff),
        affHi = comparisonAffinity(e.aff, hi.aff),
        collLo = binaryCollation(e, lo),
        collHi = binaryCollation(e, hi);
  @override
  Object? eval(Frame f) {
    final v = e.eval(f);
    final a = compareOperands(v, lo.eval(f), affLo, collLo);
    final b = compareOperands(v, hi.eval(f), affHi, collHi);
    final t1 = a == null ? null : a >= 0;
    final t2 = b == null ? null : b <= 0;
    bool? r;
    if (t1 == false || t2 == false) {
      r = false;
    } else if (t1 == null || t2 == null) {
      r = null;
    } else {
      r = true;
    }
    if (r == null) return null;
    return (r != not) ? 1 : 0;
  }

  @override
  void children(void Function(Ev) f) {
    f(e);
    f(lo);
    f(hi);
  }
}

class InListEv extends Ev {
  final bool not;
  final Ev e;
  final List<Ev> list;
  InListEv(this.not, this.e, List<Ev> list)
      : list = [for (final x in list) timeOperand(x, e)];
  @override
  Object? eval(Frame f) {
    if (list.isEmpty) return not ? 1 : 0;
    final v = e.eval(f);
    if (v == null) return null;
    var sawNull = false;
    for (final x in list) {
      final w = x.eval(f);
      if (w == null) {
        sawNull = true;
        continue;
      }
      if (compareOperands(v, w, inListAffinity(e.aff), binaryCollation(e, x)) == 0) {
        return not ? 0 : 1;
      }
    }
    if (sawNull) return null;
    return not ? 1 : 0;
  }

  @override
  void children(void Function(Ev) f) {
    f(e);
    for (final x in list) {
      f(x);
    }
  }
}

/// Affinity of `x IN (list)` comparisons: the affinity of x alone.
Affinity inListAffinity(Affinity a) => a == Affinity.none ? Affinity.blob : a;

class LikeEv extends Ev {
  final String op;
  final bool not;
  final Ev e, pat;
  final Ev? esc;
  LikeEv(this.op, this.not, this.e, this.pat, this.esc);
  RegExp? _re;
  String? _reSrc;
  @override
  Object? eval(Frame f) {
    final v = e.eval(f);
    final p = pat.eval(f);
    // SQLite: LIKE and GLOB are false when either side is a BLOB (even
    // when the other is NULL).
    if ((op == 'LIKE' || op == 'GLOB') && (v is Uint8List || p is Uint8List)) {
      return not ? 1 : 0;
    }
    if (v == null || p == null) return null;
    final s = toText(v)!, ps = toText(p)!;
    bool m;
    switch (op) {
      case 'LIKE':
        int? ec;
        if (esc != null) {
          final ev = esc!.eval(f);
          if (ev == null) return null;
          final es = toText(ev)!;
          if (es.runes.length != 1) {
            throw const ZxDbException(
                'ESCAPE expression must be a single character');
          }
          ec = es.codeUnitAt(0);
        }
        m = likeMatch(ps, s, escape: ec);
      case 'GLOB':
        m = globMatch(ps, s);
      case 'REGEXP':
        if (_reSrc != ps) {
          _re = RegExp(ps);
          _reSrc = ps;
        }
        m = _re!.hasMatch(s);
      default:
        throw const ZxDbException('unable to use function MATCH in the requested context');
    }
    return (m != not) ? 1 : 0;
  }

  @override
  void children(void Function(Ev) f) {
    f(e);
    f(pat);
    if (esc != null) f(esc!);
  }
}

class CaseEv extends Ev {
  final Ev? base;
  final List<(Ev, Ev)> whens;
  final Ev? orElse;
  CaseEv(this.base, this.whens, this.orElse);
  @override
  Object? eval(Frame f) {
    if (base != null) {
      final b = base!.eval(f);
      if (b != null) {
        for (final (w, t) in whens) {
          final aff = comparisonAffinity(base!.aff, w.aff);
          if (compareOperands(b, w.eval(f), aff, binaryCollation(base!, w)) == 0) {
            return t.eval(f);
          }
        }
      }
    } else {
      for (final (w, t) in whens) {
        if (truth(w.eval(f)) == true) return t.eval(f);
      }
    }
    return orElse?.eval(f);
  }

  @override
  void children(void Function(Ev) f) {
    if (base != null) f(base!);
    for (final (w, t) in whens) {
      f(w);
      f(t);
    }
    if (orElse != null) f(orElse!);
  }
}

class CastEv extends Ev {
  final Ev e;
  final String type;
  CastEv(this.e, this.type) {
    aff = affinityOfType(type);
    if (aff == Affinity.blob && type.isNotEmpty) aff = Affinity.blob;
  }
  @override
  Object? eval(Frame f) => castValue(e.eval(f), type);
  @override
  void children(void Function(Ev) f) => f(e);
}

class CollateEv extends Ev {
  final Ev e;
  CollateEv(this.e, Collation? c) {
    coll = c;
    explicitColl = true;
    aff = e.aff;
    isJson = e.isJson;
  }
  @override
  Object? eval(Frame f) => e.eval(f);
  @override
  void children(void Function(Ev) f) => f(e);
}

class FuncEv extends Ev {
  final ZxScalarFunction fn;
  final List<Ev> args;
  final List<bool>? jsonArgs;
  FuncEv(this.fn, this.args)
      : jsonArgs = args.any((a) => a.isJson)
            ? [for (final a in args) a.isJson]
            : null {
    isJson = fn.resultIsJson;
    volatile = !fn.deterministic;
    if (fn.name == 'unixepoch') timeUnit = timeUnitSeconds;
    if (fn.name == 'julianday') timeUnit = timeUnitJulian;
  }
  @override
  Object? eval(Frame f) {
    final n = args.length;
    final vals = List<Object?>.filled(n, null);
    for (var i = 0; i < n; i++) {
      vals[i] = args[i].eval(f);
    }
    final ctx = f.ctx;
    final saved = ctx._jsonArgs;
    ctx._jsonArgs = jsonArgs;
    try {
      return fn.impl(vals, ctx);
    } finally {
      ctx._jsonArgs = saved;
    }
  }

  @override
  void children(void Function(Ev) f) {
    for (final a in args) {
      f(a);
    }
  }
}

class JsonArrowEv extends Ev {
  final bool text; // ->>
  final Ev l, r;
  JsonArrowEv(this.text, this.l, this.r) {
    isJson = !text;
  }
  @override
  Object? eval(Frame f) => jsonArrow(l.eval(f), r.eval(f), text);
  @override
  void children(void Function(Ev) f) {
    f(l);
    f(r);
  }
}

class RaiseEv extends Ev {
  final String action;
  final String? message;
  RaiseEv(this.action, this.message);
  @override
  Object? eval(Frame f) {
    if (action == 'IGNORE') return null;
    throw ZxDbException(message ?? 'raise', ZxDbError.constraint);
  }
}

/// A group key for hashing (equal SQL values give equal keys).
String hashKey(List<Object?> values) => groupKey(values);
