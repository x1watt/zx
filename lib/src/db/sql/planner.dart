// Query planner and executor for SELECT: name resolution, expression
// compilation, access path choice (rowid and index lookups, ranges, IN,
// covering indexes, automatic hash indexes for joins), nested loop joins,
// hash aggregation, sorting, DISTINCT, compound selects, CTEs and
// subqueries.

import 'dart:collection';
import 'dart:typed_data';

import '../keycodec.dart';
import '../record.dart';
import '../storage_api.dart';
import 'ast.dart';
import 'catalog.dart';
import 'datetime.dart';
import 'eval.dart';
import 'functions.dart';
import 'json.dart';
import 'value.dart';
import 'vtab.dart';

// ------------------------------------------------------------ iterators

abstract class RowIter {
  bool moveNext();
  List<Object?> get current;
  void close() {}
}

class ListIter extends RowIter {
  final List<List<Object?>> rows;
  int _i = -1;
  ListIter(this.rows);
  @override
  bool moveNext() => ++_i < rows.length;
  @override
  List<Object?> get current => rows[_i];
}

class _FnIter extends RowIter {
  final bool Function() _next;
  final List<Object?> Function() _cur;
  final void Function()? _close;
  _FnIter(this._next, this._cur, [this._close]);
  @override
  bool moveNext() => _next();
  @override
  List<Object?> get current => _cur();
  @override
  void close() => _close?.call();
}

List<List<Object?>> drain(RowIter it) {
  final out = <List<Object?>>[];
  try {
    while (it.moveNext()) {
      out.add(it.current);
    }
  } finally {
    it.close();
  }
  return out;
}

/// A planned SELECT.
class SelectPlan {
  final List<String> columns;

  /// Per column: affinity / collation / JSON flag holder.
  final List<Ev> colInfo;
  final RowIter Function(Frame? outer) open;
  final Scope? scope;
  SelectPlan(this.columns, this.colInfo, this.open, this.scope);
  bool get correlated => scope?.correlated ?? false;
}

// ------------------------------------------------------------ scopes

class CteDef {
  final String name;
  final List<String>? columns;
  final SelectStmt select;
  final bool recursive;
  final CteEnv? env; // CTEs visible inside the body
  CteDef(this.name, this.columns, this.select, this.recursive, this.env);
}

class CteEnv {
  final Map<String, CteDef> defs = {};
  final CteEnv? parent;
  CteEnv(this.parent);
  CteDef? find(String n) {
    final l = n.toLowerCase();
    for (CteEnv? e = this; e != null; e = e.parent) {
      final d = e.defs[l];
      if (d != null) return d;
    }
    return null;
  }
}

class SourceInfo {
  final String? alias; // qualifier (lower case compare)
  final String display;
  final List<String> cols;
  final List<Affinity> affs;
  final List<Collation?> colls;
  final List<bool> json;
  final List<bool> hidden;
  final int slot;
  int rowidCol = -1;
  TableDef? table;
  ZxSnapshot? snap; // AS OF snapshot (or the statement snapshot)
  ZxVirtualTable? vtab;
  List<Ev>? vtabArgs;
  SelectPlan? sub;
  bool subCacheable = true;
  List<List<Object?>> Function()? rowsLoader;
  final Set<String> usingHidden = {};
  final Set<int> used = {};
  bool allUsed = false;
  bool left = false;
  String kind = 'table'; // table, vtab, sub, list
  String? indexedBy;
  bool notIndexed = false;

  /// Declared column types (null: unknown).
  List<String?>? types;
  SourceInfo(this.alias, this.display, this.cols, this.affs, this.colls,
      this.json, this.hidden, this.slot);

  int find(String name) {
    final l = name.toLowerCase();
    for (var i = 0; i < cols.length; i++) {
      if (cols[i].toLowerCase() == l) return i;
    }
    if (rowidCol >= 0 &&
        (l == 'rowid' || l == 'oid' || l == '_rowid_')) {
      return rowidCol;
    }
    return -1;
  }
}

class AggSpec {
  final String name;
  final ZxAggregateFunction? fn;
  final List<Ev> args;
  final bool distinct;
  final bool star;
  final Ev? filter;
  final List<(Ev, bool)>? orderBy;
  AggSpec(this.name, this.fn, this.args, this.distinct, this.star, this.filter,
      this.orderBy);

  ZxAggregateState create() {
    if (star) return countStar();
    if (name == 'json_group_array') {
      final j = args[0].isJson;
      return jsonGroupArray(() => j);
    }
    if (name == 'json_group_object') {
      final j = args[1].isJson;
      return jsonGroupObject(() => j);
    }
    final s = fn!.create();
    if ((name == 'min' || name == 'max') && args[0].coll != null) {
      setMinMaxCollation(s, args[0].coll);
    }
    return s;
  }
}

class Scope {
  final Scope? parent;
  final CteEnv? ctes;
  final List<SourceInfo> sources = [];
  bool correlated = false;
  int parentSlots = 0;
  List<AggSpec>? aggs;
  bool aggAllowed = false;
  bool inAggArg = false;
  Map<String, Expr>? aliases;
  final Set<String> resolving = {};
  Scope(this.parent, this.ctes);
}

// ------------------------------------------------------------ subquery evs

class ScalarSubEv extends Ev {
  final SelectPlan plan;
  ScalarSubEv(this.plan) {
    if (plan.colInfo.isNotEmpty) {
      aff = plan.colInfo[0].aff;
      coll = plan.colInfo[0].coll;
    }
  }
  @override
  Object? eval(Frame f) {
    if (!plan.correlated) {
      final c = f.ctx.cache;
      if (c.containsKey(this)) return c[this];
      final v = _run(f);
      c[this] = v;
      return v;
    }
    return _run(f);
  }

  Object? _run(Frame f) {
    final it = plan.open(f);
    try {
      if (it.moveNext()) return it.current[0];
      return null;
    } finally {
      it.close();
    }
  }
}

class ExistsEv extends Ev {
  final SelectPlan plan;
  ExistsEv(this.plan);
  @override
  Object? eval(Frame f) {
    if (!plan.correlated) {
      final c = f.ctx.cache;
      if (c.containsKey(this)) return c[this];
      final v = _run(f);
      c[this] = v;
      return v;
    }
    return _run(f);
  }

  Object? _run(Frame f) {
    final it = plan.open(f);
    try {
      return it.moveNext() ? 1 : 0;
    } finally {
      it.close();
    }
  }
}

class InSet {
  final Set<String> keys = {};
  bool hasNull = false;
  final List<Object?> values = [];
}

class InSubEv extends Ev {
  final bool not;
  final Ev e;
  final SelectPlan plan;
  final Affinity cmpAff;
  InSubEv(this.not, this.e, this.plan)
      : cmpAff = comparisonAffinity(e.aff, plan.colInfo[0].aff);

  InSet _build(Frame f) {
    final s = InSet();
    final it = plan.open(f);
    try {
      while (it.moveNext()) {
        final v = it.current[0];
        if (v == null) {
          s.hasNull = true;
        } else {
          final a = applyCompareAffinity(v, cmpAff);
          if (s.keys.add(hashKey([a]))) s.values.add(a);
        }
      }
    } finally {
      it.close();
    }
    return s;
  }

  InSet set(Frame f) {
    if (plan.correlated) return _build(f);
    final c = f.ctx.cache;
    var s = c[this] as InSet?;
    if (s == null) {
      s = _build(f);
      c[this] = s;
    }
    return s;
  }

  @override
  Object? eval(Frame f) {
    final v = e.eval(f);
    final s = set(f);
    if (s.keys.isEmpty && !s.hasNull) return not ? 1 : 0;
    if (v == null) return null;
    final found = s.keys.contains(hashKey([applyCompareAffinity(v, cmpAff)]));
    if (found) return not ? 0 : 1;
    if (s.hasNull) return null;
    return not ? 1 : 0;
  }

  @override
  void children(void Function(Ev) f) => f(e);
}

class CoalesceEv extends Ev {
  final List<Ev> args;
  CoalesceEv(this.args);
  @override
  Object? eval(Frame f) {
    for (final a in args) {
      final v = a.eval(f);
      if (v != null) return v;
    }
    return null;
  }

  @override
  void children(void Function(Ev) f) {
    for (final a in args) {
      f(a);
    }
  }
}

// ------------------------------------------------------------ table rows

class TableReader {
  final TableDef td;
  final ZxTree tree;
  final List<Object?> defaults;
  TableReader(this.td, this.tree, this.defaults);

  List<Object?> decode(int rowid, Uint8List rec) {
    final n = td.columns.length;
    final row = decodeRecord(rec, <Object?>[]);
    if (row.length > n) row.length = n;
    while (row.length < n) {
      row.add(defaults[row.length]);
    }
    row.add(rowid);
    if (td.ipk >= 0) row[td.ipk] = rowid;
    return row;
  }

  List<Object?>? read(int rowid) {
    final rec = tree.get(encodeRowid(rowid));
    if (rec == null) return null;
    return decode(rowid, rec);
  }
}

/// A row of a table scan decoded on first use (count(*) and filters on
/// the rowid do not decode the record).
class LazyRow extends ListBase<Object?> {
  final TableReader rd;
  final int rowid;
  final Uint8List rec;
  List<Object?>? _r;
  LazyRow(this.rd, this.rowid, this.rec);

  List<Object?> get _row => _r ??= rd.decode(rowid, rec);

  @override
  int get length => _r?.length ?? rd.td.columns.length + 1;

  @override
  set length(int n) => _row.length = n;

  @override
  Object? operator [](int i) => _row[i];

  @override
  void operator []=(int i, Object? v) => _row[i] = v;
}

// ------------------------------------------------------------ cursors

abstract class LevelCursor {
  void open(Frame f);
  bool next(Frame f);
  void close() {}
}

class RowidRangeCursor extends LevelCursor {
  final int slot;
  final TableReader rd;
  final Ev? lo, hi;
  final bool loIncl, hiIncl, reverse;
  ZxCursor? _c;
  bool _empty = false;
  RowidRangeCursor(this.slot, this.rd,
      {this.lo, this.hi, this.loIncl = true, this.hiIncl = true, this.reverse = false});

  @override
  void open(Frame f) {
    _c?.close();
    _c = null;
    _empty = false;
    Uint8List? from, to;
    if (lo != null) {
      final v = applyCompareAffinity(lo!.eval(f), Affinity.integer);
      if (v == null) {
        _empty = true;
        return;
      }
      if (v is num) {
        int b;
        if (v is int) {
          b = loIncl ? v : (v == 0x7FFFFFFFFFFFFFFF ? v : v + 1);
          if (!loIncl && v == 0x7FFFFFFFFFFFFFFF) {
            _empty = true;
            return;
          }
        } else {
          final d = v as double;
          if (d > 9.2e18) {
            _empty = true;
            return;
          }
          if (d < -9.2e18) {
            b = -0x8000000000000000;
          } else {
            final c = d.ceilToDouble();
            b = c.toInt();
            if (!loIncl && c == d) b++;
          }
        }
        from = encodeRowid(b);
      } else {
        _empty = true; // text/blob > every integer
        return;
      }
    }
    if (hi != null) {
      final v = applyCompareAffinity(hi!.eval(f), Affinity.integer);
      if (v == null) {
        _empty = true;
        return;
      }
      if (v is num) {
        int b; // inclusive upper bound
        if (v is int) {
          if (!hiIncl && v == -0x8000000000000000) {
            _empty = true;
            return;
          }
          b = hiIncl ? v : v - 1;
        } else {
          final d = v as double;
          if (d < -9.2e18) {
            _empty = true;
            return;
          }
          if (d > 9.2e18) {
            b = 0x7FFFFFFFFFFFFFFF;
          } else {
            final fl = d.floorToDouble();
            b = fl.toInt();
            if (!hiIncl && fl == d) b--;
          }
        }
        if (b != 0x7FFFFFFFFFFFFFFF) to = encodeRowid(b + 1);
      }
      // text/blob upper bound: every integer is below it.
    }
    _c = rd.tree.scan(from: from, to: to, reverse: reverse);
  }

  @override
  bool next(Frame f) {
    if (_empty || _c == null) return false;
    if (!_c!.moveNext()) return false;
    f.rows[slot] = LazyRow(rd, decodeRowid(_c!.key), _c!.value);
    return true;
  }

  @override
  void close() {
    _c?.close();
    _c = null;
  }
}

class RowidListCursor extends LevelCursor {
  final int slot;
  final TableReader rd;
  final List<Ev> values; // each an eq value
  final Ev? inSub; // InSubEv set
  List<int> _ids = const [];
  int _i = 0;
  RowidListCursor(this.slot, this.rd, this.values, [this.inSub]);

  @override
  void open(Frame f) {
    final ids = <int>{};
    void add(Object? v) {
      final a = applyCompareAffinity(v, Affinity.integer);
      if (a is int) ids.add(a);
      if (a is double && a == a.truncateToDouble() && a.abs() < 9.2e18) {
        ids.add(a.toInt());
      }
    }

    for (final e in values) {
      add(e.eval(f));
    }
    if (inSub != null) {
      for (final v in (inSub as InSubEv).set(f).values) {
        add(v);
      }
    }
    _ids = ids.toList()..sort();
    _i = 0;
  }

  @override
  bool next(Frame f) {
    while (_i < _ids.length) {
      final id = _ids[_i++];
      final row = rd.read(id);
      if (row != null) {
        f.rows[slot] = row;
        return true;
      }
    }
    return false;
  }
}

/// Transforms a value for an index key under a collation.
Object? collKey(Object? v, String? coll) {
  if (v is String && coll != null) {
    final c = coll.toUpperCase();
    if (c == 'NOCASE') return asciiLower(v);
    if (c == 'RTRIM') return v.replaceFirst(RegExp(r' +$'), '');
  }
  return v;
}

class IndexCursor extends LevelCursor {
  final int slot;
  final IndexDef ix;
  final ZxTree itree;
  final TableReader rd;
  final bool covering;
  final List<Ev> eq; // values for the first eq.length columns
  final List<bool> eqIsNullOk; // IS (null matches null)
  final List<Affinity> eqAff;
  final int inPos; // index in eq holding an IN list (-1: none)
  final List<Ev>? inList;
  final InSubEv? inSub;
  final Ev? lo, hi;
  final bool loIncl, hiIncl;
  final Affinity rangeAff;
  final bool reverse;
  final int ncols; // table columns
  final List<bool> descs;

  final List<(Uint8List?, Uint8List?)> _ranges = [];
  int _ri = 0;
  ZxCursor? _c;

  IndexCursor(this.slot, this.ix, this.itree, this.rd, this.covering, this.eq,
      this.eqIsNullOk, this.eqAff,
      {this.inPos = -1,
      this.inList,
      this.inSub,
      this.lo,
      this.hi,
      this.loIncl = true,
      this.hiIncl = true,
      this.rangeAff = Affinity.none,
      this.reverse = false})
      : ncols = rd.td.columns.length,
        descs = ix.descs;

  Object? _k(int col, Object? v, Affinity a) =>
      collKey(applyCompareAffinity(v, a), ix.columns[col].collation);

  @override
  void open(Frame f) {
    _c?.close();
    _c = null;
    _ranges.clear();
    _ri = 0;
    final base = <Object?>[];
    for (var i = 0; i < eq.length; i++) {
      if (i == inPos) {
        base.add(null);
        continue;
      }
      final v = eq[i].eval(f);
      if (v == null && !eqIsNullOk[i]) return;
      base.add(_k(i, v, eqAff[i]));
    }
    final prefixes = <List<Object?>>[];
    if (inPos >= 0) {
      final vals = <Object?>[];
      final seen = <String>{};
      void add(Object? v) {
        if (v == null) return;
        final k = _k(inPos, v, eqAff[inPos]);
        if (seen.add(hashKey([k]))) vals.add(k);
      }

      if (inList != null) {
        for (final e in inList!) {
          add(e.eval(f));
        }
      } else {
        for (final v in inSub!.set(f).values) {
          add(v);
        }
      }
      vals.sort(compareValues);
      for (final v in vals) {
        final p = List<Object?>.of(base);
        p[inPos] = v;
        prefixes.add(p);
      }
    } else {
      prefixes.add(base);
    }
    Object? loV, hiV;
    if (lo != null) {
      loV = lo!.eval(f);
      if (loV == null) return;
      loV = _k(eq.length, loV, rangeAff);
    }
    if (hi != null) {
      hiV = hi!.eval(f);
      if (hiV == null) return;
      hiV = _k(eq.length, hiV, rangeAff);
    }
    for (final p in prefixes) {
      final w = KeyWriter();
      for (var i = 0; i < p.length; i++) {
        encodeKeyValue(w, p[i], desc: descs[i]);
      }
      final prefix = w.take();
      Uint8List? from = prefix.isEmpty ? null : prefix;
      Uint8List? to = prefix.isEmpty ? null : prefixEnd(prefix);
      if (lo != null || hi != null) {
        final k = eq.length;
        final d = descs[k];
        Uint8List comp(Object? v) {
          final w2 = KeyWriter()..bytes(prefix);
          encodeKeyValue(w2, v, desc: d);
          return w2.take();
        }

        // NULLs never satisfy a range.
        if (!d) {
          from = prefixEnd(comp(null));
        } else {
          to = comp(null);
        }
        if (loV != null || lo != null) {
          final c = comp(loV);
          if (!d) {
            from = loIncl ? c : prefixEnd(c);
          } else {
            to = loIncl ? prefixEnd(c) : c;
          }
        }
        if (hi != null) {
          final c = comp(hiV);
          if (!d) {
            to = hiIncl ? prefixEnd(c) : c;
          } else {
            from = hiIncl ? c : prefixEnd(c);
          }
        }
      }
      _ranges.add((from, to));
    }
    if (reverse) {
      final r = _ranges.reversed.toList();
      _ranges
        ..clear()
        ..addAll(r);
    }
  }

  @override
  bool next(Frame f) {
    while (true) {
      if (_c == null) {
        if (_ri >= _ranges.length) return false;
        final (from, to) = _ranges[_ri++];
        if (from != null && to != null && compareBytes(from, to) >= 0) {
          continue;
        }
        _c = itree.scan(from: from, to: to, reverse: reverse);
      }
      if (!_c!.moveNext()) {
        _c!.close();
        _c = null;
        continue;
      }
      final key = _c!.key;
      final vals = decodeKey(key,
          count: ix.columns.length + 1, desc: [...descs, false]);
      final rowid = vals.last as int;
      if (covering) {
        final row = List<Object?>.filled(ncols + 1, null);
        for (var i = 0; i < ix.columns.length; i++) {
          final col = ix.columns[i].col;
          if (col >= 0) {
            var v = vals[i];
            if (v is int && rd.td.columns[col].affinity == Affinity.real) {
              v = v.toDouble();
            }
            row[col] = v;
          }
        }
        row[ncols] = rowid;
        if (rd.td.ipk >= 0) row[rd.td.ipk] = rowid;
        f.rows[slot] = row;
        return true;
      }
      final row = rd.read(rowid);
      if (row == null) continue; // stale index entry
      f.rows[slot] = row;
      return true;
    }
  }

  @override
  void close() {
    _c?.close();
    _c = null;
  }
}

class ListCursor extends LevelCursor {
  final int slot;
  final List<List<Object?>> Function(Frame f) rows;
  List<List<Object?>> _rows = const [];
  int _i = 0;
  ListCursor(this.slot, this.rows);
  @override
  void open(Frame f) {
    _rows = rows(f);
    _i = 0;
  }

  @override
  bool next(Frame f) {
    if (_i >= _rows.length) return false;
    f.rows[slot] = _rows[_i++];
    return true;
  }
}

class StreamCursor extends LevelCursor {
  final int slot;
  final RowIter Function(Frame f) openIt;
  RowIter? _it;
  StreamCursor(this.slot, this.openIt);
  @override
  void open(Frame f) {
    _it?.close();
    _it = openIt(f);
  }

  @override
  bool next(Frame f) {
    if (_it == null || !_it!.moveNext()) return false;
    f.rows[slot] = _it!.current;
    return true;
  }

  @override
  void close() {
    _it?.close();
    _it = null;
  }
}

/// Hash lookup on materialized rows (SQLite's automatic index).
class HashCursor extends LevelCursor {
  final int slot;
  final List<List<Object?>> Function(Frame f) load;
  final List<int> cols;
  final List<Ev> probes;
  final List<Affinity> affs; // comparison affinity per column
  final List<String?> colls;
  final Object cacheKey = Object();
  final bool cacheable;
  List<List<Object?>> _match = const [];
  int _i = 0;
  HashCursor(this.slot, this.load, this.cols, this.probes, this.affs,
      this.colls, this.cacheable);

  Map<String, List<List<Object?>>> _table(Frame f) {
    final c = f.ctx.cache;
    var m = cacheable ? c[cacheKey] as Map<String, List<List<Object?>>>? : null;
    if (m != null) return m;
    m = {};
    final key = List<Object?>.filled(cols.length, null);
    outer:
    for (final r in load(f)) {
      for (var i = 0; i < cols.length; i++) {
        final v = r[cols[i]];
        if (v == null) continue outer;
        key[i] = collKey(applyCompareAffinity(v, affs[i]), colls[i]);
      }
      (m[hashKey(key)] ??= []).add(r);
    }
    if (cacheable) c[cacheKey] = m;
    return m;
  }

  @override
  void open(Frame f) {
    _i = 0;
    _match = const [];
    final key = List<Object?>.filled(cols.length, null);
    for (var i = 0; i < cols.length; i++) {
      final v = probes[i].eval(f);
      if (v == null) return;
      key[i] = collKey(applyCompareAffinity(v, affs[i]), colls[i]);
    }
    _match = _table(f)[hashKey(key)] ?? const [];
  }

  @override
  bool next(Frame f) {
    if (_i >= _match.length) return false;
    f.rows[slot] = _match[_i++];
    return true;
  }
}

class VtabCursor extends LevelCursor {
  final int slot;
  final ZxVirtualTable vt;
  final ZxIndexInfo info;
  final List<Ev> argEvs; // in argv order
  final int ncols;
  final ZxSnapshot Function(Frame f) snapOf;
  final bool asOf;
  ZxVtabCursor? _c;
  VtabCursor(this.slot, this.vt, this.info, this.argEvs, this.ncols,
      this.snapOf, this.asOf);

  @override
  void open(Frame f) {
    _c?.close();
    final ctx = f.ctx;
    _c = vt.open(ZxVtabContext(snapOf(f), ctx.txn, ctx.nowNs, asOf: asOf));
    _c!.filter(info.idxNum, info.idxStr, [for (final e in argEvs) e.eval(f)]);
  }

  @override
  bool next(Frame f) {
    final c = _c;
    if (c == null || !c.next()) return false;
    final row = List<Object?>.filled(ncols + 1, null);
    for (var i = 0; i < ncols; i++) {
      row[i] = c.column(i);
    }
    row[ncols] = c.rowid;
    f.rows[slot] = row;
    return true;
  }

  @override
  void close() {
    _c?.close();
    _c = null;
  }
}

// ------------------------------------------------------------ join loop

class Level {
  final SourceInfo src;
  final List<Ev> filters = [];
  final List<Ev> post = [];
  LevelCursor? cursor;
  bool matched = false, nullDone = false, exhausted = false;
  Level(this.src);
}

bool _passes(List<Ev> fs, Frame f) {
  for (final e in fs) {
    if (truth(e.eval(f)) != true) return false;
  }
  return true;
}

class JoinRunner {
  final Frame f;
  final List<Level> levels;
  final List<Ev> pre;
  int _k = -1;
  bool _started = false, _done = false;
  JoinRunner(this.f, this.levels, this.pre);

  void _openLevel(int k) {
    final l = levels[k];
    l.matched = false;
    l.nullDone = false;
    l.exhausted = false;
    l.cursor!.open(f);
  }

  bool next() {
    if (_done) return false;
    final n = levels.length;
    if (!_started) {
      _started = true;
      if (!_passes(pre, f)) {
        _done = true;
        return false;
      }
      if (n == 0) return true;
      _k = 0;
      _openLevel(0);
    } else {
      if (n == 0) {
        _done = true;
        return false;
      }
      _k = n - 1;
    }
    while (_k >= 0) {
      final l = levels[_k];
      var got = false;
      if (!l.exhausted) {
        while (l.cursor!.next(f)) {
          if (!_passes(l.filters, f)) continue;
          l.matched = true;
          if (!_passes(l.post, f)) continue;
          got = true;
          break;
        }
        if (!got) l.exhausted = true;
      }
      if (!got && l.src.left && !l.matched && !l.nullDone) {
        l.nullDone = true;
        f.rows[l.src.slot] = null;
        if (_passes(l.post, f)) got = true;
      }
      if (got) {
        if (_k == n - 1) return true;
        _k++;
        _openLevel(_k);
        continue;
      }
      l.cursor!.close();
      f.rows[l.src.slot] = null;
      _k--;
    }
    _done = true;
    return false;
  }

  void close() {
    for (final l in levels) {
      l.cursor?.close();
    }
  }
}

// ------------------------------------------------------------ planner

class _Term {
  final Ev ev; // the conjunct
  final int col;
  final String op; // =, IS, <, <=, >, >=, IN, INSUB
  final Ev? value;
  final List<Ev>? list;
  final InSubEv? sub;
  final Affinity cmpAff;
  final Collation? coll;
  _Term(this.ev, this.col, this.op, this.value, this.cmpAff, this.coll,
      {this.list, this.sub});
}

class _OrderCol {
  final int col; // column in source 0
  final bool desc;
  final bool nullsFirst;
  final Collation? coll;
  _OrderCol(this.col, this.desc, this.nullsFirst, this.coll);
}

class Planner {
  final ExecCtx ctx;
  Planner(this.ctx);

  SqlEnv get env => ctx.env;
  ZxFunctionRegistry get fns => env.functions;

  ZxDbException err(String m, [ZxDbError k = ZxDbError.generic]) =>
      ZxDbException(m, k);

  // ---------------------------------------------------------- dependencies

  static int computeDeps(Ev e) {
    var d = 0;
    var vol = e.volatile;
    if (e is ColEv) {
      if (e.depth == 0) d |= 1 << e.slot;
    }
    if (e is ScalarSubEv) d |= e.plan.scope?.parentSlots ?? 0;
    if (e is ExistsEv) d |= e.plan.scope?.parentSlots ?? 0;
    if (e is InSubEv) d |= e.plan.scope?.parentSlots ?? 0;
    e.children((c) {
      d |= computeDeps(c);
      if (c.volatile) vol = true;
    });
    e.deps = d;
    e.volatile = vol;
    return d;
  }

  // ---------------------------------------------------------- expressions

  bool isAggregateCall(FuncExpr f) {
    if (f.star) return f.name == 'count';
    if (f.name == 'json_group_array' && f.args.length == 1) return true;
    if (f.name == 'json_group_object' && f.args.length == 2) return true;
    final a = fns.findAggregate(f.name, f.args.length);
    if (a == null) return false;
    if ((f.name == 'min' || f.name == 'max') && f.args.length != 1) {
      return false;
    }
    return true;
  }

  /// True when [e] contains an aggregate call (not inside subqueries).
  bool hasAggregate(Expr? e) {
    if (e == null) return false;
    var found = false;
    void walk(Expr x) {
      if (found) return;
      if (x is FuncExpr) {
        if (isAggregateCall(x)) {
          found = true;
          return;
        }
        x.args.forEach(walk);
        return;
      }
      _exprChildren(x, walk);
    }

    walk(e);
    return found;
  }

  static void _exprChildren(Expr x, void Function(Expr) f) {
    if (x is UnaryExpr) {
      f(x.e);
    } else if (x is BinaryExpr) {
      f(x.l);
      f(x.r);
    } else if (x is LikeExpr) {
      f(x.e);
      f(x.pattern);
      if (x.escape != null) f(x.escape!);
    } else if (x is BetweenExpr) {
      f(x.e);
      f(x.lo);
      f(x.hi);
    } else if (x is InListExpr) {
      f(x.e);
      x.list.forEach(f);
    } else if (x is InSelectExpr) {
      f(x.e);
    } else if (x is IsNullExpr) {
      f(x.e);
    } else if (x is CaseExpr) {
      if (x.base != null) f(x.base!);
      for (final w in x.whens) {
        f(w.$1);
        f(w.$2);
      }
      if (x.orElse != null) f(x.orElse!);
    } else if (x is CastExpr) {
      f(x.e);
    } else if (x is CollateExpr) {
      f(x.e);
    } else if (x is FuncExpr) {
      x.args.forEach(f);
    } else if (x is RowExpr) {
      x.items.forEach(f);
    }
  }

  Ev compileTop(Expr e, Scope sc) {
    final ev = compile(e, sc);
    computeDeps(ev);
    return ev;
  }

  Ev compile(Expr e, Scope sc) {
    if (e is LitExpr) return ConstEv(e.value);
    if (e is ParamExpr) return ParamEv(e.index);
    if (e is ColumnExpr) return _column(e, sc);
    if (e is CurrentTimeExpr) return CurrentTimeEv(e.kind);
    if (e is UnaryExpr) {
      final x = compile(e.e, sc);
      switch (e.op) {
        case '-':
          if (x is ConstEv && x.v is num) {
            final v = x.v as num;
            if (v is int && v == -0x8000000000000000) {
              return ConstEv(-(v.toDouble()));
            }
            return ConstEv(-v);
          }
          return NegEv(x);
        case '+':
          return PlusEv(x)..coll = x.coll;
        case '~':
          return BitNotEv(x);
        default:
          return NotEv(x);
      }
    }
    if (e is BinaryExpr) return _binary(e, sc);
    if (e is LikeExpr) {
      return LikeEv(e.op, e.not, compile(e.e, sc), compile(e.pattern, sc),
          e.escape == null ? null : compile(e.escape!, sc));
    }
    if (e is BetweenExpr) {
      return BetweenEv(
          e.not, compile(e.e, sc), compile(e.lo, sc), compile(e.hi, sc));
    }
    if (e is InListExpr) {
      if (e.e is RowExpr) {
        throw err('row value misused');
      }
      return InListEv(
          e.not, compile(e.e, sc), [for (final x in e.list) compile(x, sc)]);
    }
    if (e is InSelectExpr) {
      if (e.e is RowExpr) throw err('row value misused');
      final lhs = compile(e.e, sc);
      final plan = _subPlan(e.select, sc, 'LIST SUBQUERY');
      if (plan.columns.length != 1) {
        throw err('sub-select returns ${plan.columns.length} columns - expected 1');
      }
      return InSubEv(e.not, lhs, plan);
    }
    if (e is IsNullExpr) return IsNullEv(e.not, compile(e.e, sc));
    if (e is CaseExpr) {
      return CaseEv(
          e.base == null ? null : compile(e.base!, sc),
          [for (final w in e.whens) (compile(w.$1, sc), compile(w.$2, sc))],
          e.orElse == null ? null : compile(e.orElse!, sc));
    }
    if (e is CastExpr) return CastEv(compile(e.e, sc), e.type);
    if (e is CollateExpr) {
      return CollateEv(compile(e.e, sc), collationByName(e.collation));
    }
    if (e is FuncExpr) return _func(e, sc);
    if (e is SubqueryExpr) {
      final plan = _subPlan(e.select, sc, 'SCALAR SUBQUERY');
      return ScalarSubEv(plan);
    }
    if (e is ExistsExpr) {
      return ExistsEv(_subPlan(e.select, sc, 'EXISTS SUBQUERY'));
    }
    if (e is RowExpr) {
      if (e.items.length == 1) return compile(e.items[0], sc);
      throw err('row value misused');
    }
    if (e is RaiseExpr) return RaiseEv(e.action, e.message);
    throw err('unsupported expression ${e.runtimeType}');
  }

  SelectPlan _subPlan(SelectStmt s, Scope sc, String label) {
    int? id;
    final savedParent = ctx.eqpParent;
    if (ctx.eqp != null) {
      id = ctx.explain(label);
      ctx.eqpParent = id;
    }
    try {
      final p = planSelect(s, sc, sc.ctes);
      if (id != null && p.correlated) {
        final row = ctx.eqp!.firstWhere((r) => r[0] == id);
        row[3] = 'CORRELATED $label';
      }
      return p;
    } finally {
      ctx.eqpParent = savedParent;
    }
  }

  Ev _binary(BinaryExpr e, Scope sc) {
    final op = e.op;
    if ((op == '=' || op == '!=' || op == 'IS' || op == 'IS NOT') &&
        e.l is RowExpr &&
        e.r is RowExpr) {
      final a = (e.l as RowExpr).items, b = (e.r as RowExpr).items;
      if (a.length != b.length) throw err('row value misused');
      final eqOp = (op == 'IS' || op == 'IS NOT') ? 'IS' : '=';
      Expr acc = BinaryExpr(eqOp, a[0], b[0]);
      for (var i = 1; i < a.length; i++) {
        acc = BinaryExpr('AND', acc, BinaryExpr(eqOp, a[i], b[i]));
      }
      if (op == '!=' || op == 'IS NOT') acc = UnaryExpr('NOT', acc);
      return compile(acc, sc);
    }
    if (e.l is RowExpr || e.r is RowExpr) throw err('row value misused');
    final l = compile(e.l, sc);
    final r = compile(e.r, sc);
    switch (op) {
      case 'AND':
        return AndEv(l, r);
      case 'OR':
        return OrEv(l, r);
      case '=':
      case '!=':
      case '<':
      case '<=':
      case '>':
      case '>=':
        return CmpEv(op, l, r);
      case 'IS':
        return IsEv(false, l, r);
      case 'IS NOT':
        return IsEv(true, l, r);
      case '+':
      case '-':
      case '*':
      case '/':
      case '%':
        return ArithEv(op, l, r);
      case '&':
      case '|':
      case '<<':
      case '>>':
        return BitEv(op, l, r);
      case '||':
        return ConcatEv(l, r);
      case '->':
        return JsonArrowEv(false, l, r);
      case '->>':
        return JsonArrowEv(true, l, r);
    }
    throw err('unsupported operator $op');
  }

  Ev _func(FuncExpr f, Scope sc) {
    final name = f.name;
    if (isAggregateCall(f)) {
      if (sc.aggs == null || !sc.aggAllowed) {
        throw err('misuse of aggregate: $name()');
      }
      if (sc.inAggArg) {
        throw err('misuse of aggregate function $name()');
      }
      sc.inAggArg = true;
      List<Ev> args;
      Ev? filter;
      List<(Ev, bool)>? order;
      try {
        args = [for (final a in f.args) compile(a, sc)];
        if (f.filter != null) filter = compile(f.filter!, sc);
        if (f.orderBy != null) {
          order = [for (final o in f.orderBy!) (compile(o.e, sc), o.desc)];
        }
      } finally {
        sc.inAggArg = false;
      }
      for (final a in args) {
        computeDeps(a);
      }
      if (filter != null) computeDeps(filter);
      if (f.distinct && args.length != 1) {
        throw err('DISTINCT aggregates must have exactly one argument');
      }
      final fn = (name == 'json_group_array' || name == 'json_group_object' ||
              f.star)
          ? null
          : fns.findAggregate(name, args.length);
      final spec = AggSpec(name, fn, args, f.distinct, f.star, filter, order);
      sc.aggs!.add(spec);
      final ev = AggRefEv(sc.aggs!.length - 1);
      if (name == 'json_group_array' || name == 'json_group_object') {
        ev.isJson = true;
      }
      if ((name == 'min' || name == 'max') && args.isNotEmpty) {
        ev.aff = Affinity.none;
        ev.coll = args[0].coll;
      }
      return ev;
    }
    if (f.star) throw err('wrong number of arguments to function $name()');
    if (f.distinct) {
      throw err('DISTINCT is only for aggregate functions');
    }
    final args = [for (final a in f.args) compile(a, sc)];
    switch (name) {
      case 'coalesce':
      case 'ifnull':
        if (args.length < 2 || (name == 'ifnull' && args.length != 2)) {
          throw err('wrong number of arguments to function $name()');
        }
        return CoalesceEv(args);
      case 'iif':
        if (args.length != 3) {
          throw err('wrong number of arguments to function iif()');
        }
        return CaseEv(null, [(args[0], args[1])], args[2]);
    }
    final fn = fns.findScalar(name, args.length);
    if (fn == null) {
      if (fns.hasName(name)) {
        throw err('wrong number of arguments to function $name()');
      }
      throw err('no such function: $name');
    }
    // zx: a DATETIME column given to a date function is ns, not a
    // Julian day number.
    final tArg = switch (name.toLowerCase()) {
      'date' || 'time' || 'datetime' || 'julianday' || 'unixepoch' => 0,
      'strftime' => 1,
      _ => -1,
    };
    if (tArg >= 0 && tArg < args.length && isNsTimeColumn(args[tArg])) {
      args[tArg] = NsTimeTextEv(args[tArg]);
    }
    final ev = FuncEv(fn, args);
    if (name == 'likely' || name == 'unlikely' || name == 'likelihood') {
      ev.aff = args[0].aff;
      ev.coll = args[0].coll;
    }
    return ev;
  }

  Ev _column(ColumnExpr c, Scope sc) {
    Scope? s = sc;
    var depth = 0;
    while (s != null) {
      final r = _findIn(s, c);
      if (r != null) {
        final (src, col) = r;
        if (depth > 0) {
          Scope x = sc;
          for (var i = 0; i < depth; i++) {
            x.correlated = true;
            if (i == depth - 1) x.parentSlots |= 1 << src.slot;
            x = x.parent!;
          }
        }
        if (col == src.rowidCol) {
          src.used.add(col);
        } else {
          src.used.add(col);
        }
        final ev = ColEv(depth, src.slot, col);
        if (col < src.affs.length) {
          ev.aff = src.affs[col];
          ev.coll = src.colls[col];
          ev.isJson = src.json[col];
          final ty = src.types;
          if (ty != null && col < ty.length) ev.declType = ty[col];
        } else {
          ev.aff = Affinity.integer;
        }
        return ev;
      }
      if (c.table == null && s.aliases != null) {
        final a = s.aliases![c.column.toLowerCase()];
        if (a != null && !s.resolving.contains(c.column.toLowerCase())) {
          if (depth > 0) {
            // Aliases of an outer query are not visible in subqueries.
          } else {
            s.resolving.add(c.column.toLowerCase());
            try {
              return compile(a, s);
            } finally {
              s.resolving.remove(c.column.toLowerCase());
            }
          }
        }
      }
      s = s.parent;
      depth++;
    }
    final n = c.table == null ? c.column : '${c.table}.${c.column}';
    throw err('no such column: $n');
  }

  (SourceInfo, int)? _findIn(Scope s, ColumnExpr c) {
    if (c.table != null) {
      final t = c.table!.toLowerCase();
      SourceInfo? hit;
      for (final src in s.sources) {
        if ((src.alias ?? '').toLowerCase() == t) {
          if (hit != null) throw err('ambiguous column name: ${c.table}.${c.column}');
          hit = src;
        }
      }
      if (hit == null) return null;
      final i = hit.find(c.column);
      if (i < 0) throw err('no such column: ${c.table}.${c.column}');
      return (hit, i);
    }
    (SourceInfo, int)? found;
    final l = c.column.toLowerCase();
    for (final src in s.sources) {
      if (src.usingHidden.contains(l)) continue;
      final i = src.find(c.column);
      if (i < 0) continue;
      if (i == src.rowidCol && src.cols.length > i) continue;
      if (found != null) {
        throw err('ambiguous column name: ${c.column}');
      }
      found = (src, i);
    }
    return found;
  }

  // ---------------------------------------------------------- SELECT

  SelectPlan planSelect(SelectStmt st, Scope? parent, CteEnv? ctes) {
    var env = ctes;
    if (st.withClause != null) {
      env = CteEnv(ctes);
      for (final c in st.withClause!.ctes) {
        final rec = st.withClause!.recursive && _refersTo(c.select, c.name);
        env.defs[c.name.toLowerCase()] =
            CteDef(c.name, c.columns, c.select, rec, rec ? env : env);
      }
    }
    final body = st.body;
    if (body is CompoundSelect) {
      return _planCompound(st, body, parent, env);
    }
    final core = _planCore(body, parent, env, st.orderBy);
    return _finish(core, st, parent);
  }

  bool _refersTo(SelectStmt s, String name) =>
      _bodyRefersTo(s.body, name.toLowerCase());

  bool _bodyRefersTo(SelectBody b, String l) {
    if (b is SelectCore) {
      for (final j in b.from) {
        final src = j.source;
        if (src is TableSource && src.name.toLowerCase() == l) return true;
        if (src is SubquerySource && _bodyRefersTo(src.select.body, l)) {
          return true;
        }
      }
    } else if (b is CompoundSelect) {
      for (final p in b.parts) {
        if (_bodyRefersTo(p, l)) return true;
      }
    }
    return false;
  }

  SelectPlan _finish(_CorePlan core, SelectStmt st, Scope? parent) {
    final lim = st.limit == null ? null : _constOrOuter(st.limit!, parent);
    final off = st.offset == null ? null : _constOrOuter(st.offset!, parent);
    final nRes = core.columns.length;
    final needSort = core.orderKeys.isNotEmpty && !core.orderSatisfied;
    if (needSort && ctx.eqp != null) ctx.explain('USE TEMP B-TREE FOR ORDER BY');
    final keys = core.orderKeys;
    return SelectPlan(core.columns, core.colInfo, (outer) {
      var it = core.open(outer);
      if (needSort) {
        it = _sortIter(it, nRes, keys);
      } else if (keys.isNotEmpty) {
        it = _stripIter(it, nRes);
      }
      if (lim != null || off != null) {
        final f = Frame(ctx, 0, outer);
        it = _limitIter(it, lim?.eval(f), off?.eval(f));
      }
      return it;
    }, core.scope);
  }

  Ev _constOrOuter(Expr e, Scope? parent) {
    final sc = Scope(parent, null);
    final ev = compileTop(e, sc);
    if (sc.correlated) {
      // LIMIT referencing outer columns: evaluate in the outer frame.
    }
    return ev;
  }

  RowIter _limitIter(RowIter it, Object? limV, Object? offV) {
    var lim = limV == null ? -1 : toInt(applyCompareAffinity(limV, Affinity.integer));
    if (limV != null && limV is! int) {
      final n = applyCompareAffinity(limV, Affinity.integer);
      if (n is! num) throw err('datatype mismatch');
      lim = toInt(n);
    }
    var off = offV == null ? 0 : toInt(applyCompareAffinity(offV, Affinity.integer));
    if (off < 0) off = 0;
    var skipped = false;
    var count = 0;
    return _FnIter(() {
      if (!skipped) {
        skipped = true;
        for (var i = 0; i < off; i++) {
          if (!it.moveNext()) return false;
        }
      }
      if (lim >= 0 && count >= lim) return false;
      if (!it.moveNext()) return false;
      count++;
      return true;
    }, () => it.current, it.close);
  }

  RowIter _stripIter(RowIter it, int n) {
    return _FnIter(it.moveNext, () {
      final c = it.current;
      return c.length == n ? c : c.sublist(0, n);
    }, it.close);
  }

  RowIter _sortIter(RowIter it, int n, List<(Ev, bool, bool?)> keys) {
    List<List<Object?>>? rows;
    var i = -1;
    return _FnIter(() {
      if (rows == null) {
        final all = drain(it);
        final idx = List<int>.generate(all.length, (k) => k);
        idx.sort((a, b) {
          final ra = all[a], rb = all[b];
          for (var k = 0; k < keys.length; k++) {
            final (ev, desc, nf) = keys[k];
            final x = ra[n + k], y = rb[n + k];
            int c;
            if (x == null || y == null) {
              if (x == null && y == null) {
                c = 0;
              } else {
                final nullsFirst = nf ?? !desc;
                c = (x == null) == nullsFirst ? -1 : 1;
                if (c != 0) return c;
              }
            } else {
              c = compareValues(x, y, ev.coll);
              if (desc) c = -c;
            }
            if (c != 0) return c;
          }
          return a - b;
        });
        rows = [for (final k in idx) all[k].sublist(0, n)];
      }
      return ++i < rows!.length;
    }, () => rows![i], it.close);
  }

  SelectPlan _planCompound(
      SelectStmt st, CompoundSelect body, Scope? parent, CteEnv? env) {
    int? id;
    final saved = ctx.eqpParent;
    if (ctx.eqp != null) {
      id = ctx.explain('COMPOUND QUERY');
      ctx.eqpParent = id;
    }
    final parts = <_CorePlan>[];
    try {
      for (var i = 0; i < body.parts.length; i++) {
        if (ctx.eqp != null) {
          final pid = ctx.explain(i == 0 ? 'LEFT-MOST SUBQUERY' : body.ops[i - 1]);
          ctx.eqpParent = pid;
        }
        final p = body.parts[i];
        if (p is CompoundSelect) throw err('nested compound');
        parts.add(_planCore(p, parent, env, const []));
        ctx.eqpParent = id ?? saved;
      }
    } finally {
      ctx.eqpParent = saved;
    }
    final n = parts[0].columns.length;
    for (final p in parts) {
      if (p.columns.length != n) {
        throw err('SELECTs to the left and right of ${body.ops[0]} do not have the same number of result columns');
      }
    }
    final first = parts[0];
    // ORDER BY terms refer to output columns.
    final keys = <(int, bool, bool?, Collation?)>[];
    for (final o in st.orderBy) {
      final idx = _compoundOrderIndex(o.e, body, first);
      Collation? coll = first.colInfo[idx].coll;
      if (o.e is CollateExpr) coll = collationByName((o.e as CollateExpr).collation);
      keys.add((idx, o.desc, o.nullsFirst, coll));
    }
    final lim = st.limit == null ? null : _constOrOuter(st.limit!, parent);
    final off = st.offset == null ? null : _constOrOuter(st.offset!, parent);
    final allUnionAll = body.ops.every((o) => o == 'UNION ALL');
    if (keys.isNotEmpty && ctx.eqp != null) {
      ctx.explain('USE TEMP B-TREE FOR ORDER BY');
    }
    final scope = Scope(parent, env);
    for (final p in parts) {
      if (p.scope.correlated) {
        scope.correlated = true;
        scope.parentSlots |= p.scope.parentSlots;
      }
    }
    return SelectPlan(first.columns, first.colInfo, (outer) {
      RowIter it;
      if (allUnionAll) {
        var pi = 0;
        RowIter? cur;
        it = _FnIter(() {
          while (true) {
            cur ??= _stripIter(parts[pi].open(outer), n);
            if (cur!.moveNext()) return true;
            cur!.close();
            cur = null;
            if (++pi >= parts.length) return false;
          }
        }, () => cur!.current, () => cur?.close());
      } else {
        var acc = drain(_stripIter(parts[0].open(outer), n));
        for (var i = 1; i < parts.length; i++) {
          final next = drain(_stripIter(parts[i].open(outer), n));
          switch (body.ops[i - 1]) {
            case 'UNION ALL':
              acc = [...acc, ...next];
            case 'UNION':
              acc = _distinct([...acc, ...next]);
            case 'INTERSECT':
              final ks = {for (final r in next) hashKey(r)};
              acc = _distinct(acc).where((r) => ks.contains(hashKey(r))).toList();
            case 'EXCEPT':
              final ks = {for (final r in next) hashKey(r)};
              acc = _distinct(acc).where((r) => !ks.contains(hashKey(r))).toList();
          }
        }
        if (keys.isEmpty && !allUnionAll) {
          // SQLite returns UNION / INTERSECT / EXCEPT results sorted.
          acc.sort((a, b) {
            for (var k = 0; k < n; k++) {
              final c = compareValues(a[k], b[k], first.colInfo[k].coll);
              if (c != 0) return c;
            }
            return 0;
          });
        }
        it = ListIter(acc);
      }
      if (keys.isNotEmpty) {
        final ks = [
          for (final k in keys)
            (ConstEv(null)..coll = k.$4, k.$2, k.$3)
        ];
        final src = it;
        it = _sortIter(
            _FnIter(src.moveNext, () {
              final r = src.current;
              return [...r, for (final k in keys) r[k.$1]];
            }, src.close),
            n,
            ks);
      }
      if (lim != null || off != null) {
        final f = Frame(ctx, 0, outer);
        it = _limitIter(it, lim?.eval(f), off?.eval(f));
      }
      return it;
    }, scope);
  }

  List<List<Object?>> _distinct(List<List<Object?>> rows) {
    final seen = <String>{};
    return [
      for (final r in rows)
        if (seen.add(hashKey(r))) r
    ];
  }

  int _compoundOrderIndex(Expr e, CompoundSelect body, _CorePlan first) {
    var x = e;
    if (x is CollateExpr) x = x.e;
    if (x is LitExpr && x.value is int) {
      final k = x.value as int;
      if (k < 1 || k > first.columns.length) {
        throw err('ORDER BY term out of range - should be between 1 and ${first.columns.length}');
      }
      return k - 1;
    }
    if (x is ColumnExpr) {
      for (final part in body.parts) {
        if (part is! SelectCore) continue;
        final names = _resultNames(part);
        for (var i = 0; i < names.length; i++) {
          if (names[i] != null && names[i]!.toLowerCase() == x.column.toLowerCase()) {
            return i;
          }
        }
      }
    }
    final txt = exprToSql(x);
    for (final part in body.parts) {
      if (part is! SelectCore) continue;
      for (var i = 0; i < part.columns.length; i++) {
        final rc = part.columns[i];
        if (rc.e != null && exprToSql(rc.e!) == txt) return i;
      }
    }
    throw err('1st ORDER BY term does not match any column in the result set');
  }

  List<String?> _resultNames(SelectCore c) => [
        for (final rc in c.columns)
          rc.alias ?? (rc.e is ColumnExpr ? (rc.e as ColumnExpr).column : null)
      ];

  // ---------------------------------------------------------- core

  _CorePlan _planCore(SelectBody body, Scope? parent, CteEnv? env,
      List<OrderTerm> order,
      {List<Ev> Function(Scope sc)? extra, bool forUpdate = false}) {
    if (body is ValuesCore) return _planValues(body, parent, env, order);
    final c = body as SelectCore;
    final sc = Scope(parent, env);
    for (final j in c.from) {
      _addSource(j, sc);
    }
    // Result aliases usable in WHERE / GROUP BY / HAVING / ORDER BY.
    final aliases = <String, Expr>{};
    for (final rc in c.columns) {
      if (rc.alias != null && rc.e != null) {
        aliases.putIfAbsent(rc.alias!.toLowerCase(), () => rc.e!);
      }
    }
    sc.aliases = aliases;
    final isAgg = c.groupBy.isNotEmpty ||
        c.having != null ||
        c.columns.any((rc) => hasAggregate(rc.e)) ||
        order.any((o) => hasAggregate(o.e));
    sc.aggs = [];

    final levels = [for (final s in sc.sources) Level(s)];
    final pre = <Ev>[];

    void place(Ev ev, {int? leftLevel}) {
      final d = ev.deps;
      if (leftLevel != null) {
        levels[leftLevel].filters.add(ev);
        return;
      }
      if (d == 0) {
        pre.add(ev);
        return;
      }
      final m = d.bitLength - 1;
      if (levels[m].src.left) {
        levels[m].post.add(ev);
      } else {
        levels[m].filters.add(ev);
      }
    }

    // ON and USING conditions.
    for (var i = 0; i < c.from.length; i++) {
      final j = c.from[i];
      final conds = <Ev>[];
      if (j.on != null) {
        for (final x in _conjuncts(j.on!)) {
          conds.add(compileTop(x, sc));
        }
      }
      conds.addAll(_usingConds(j, i, sc));
      for (final ev in conds) {
        if (j.type == 'LEFT') {
          place(ev, leftLevel: i);
        } else {
          place(ev);
        }
      }
    }
    if (c.where != null) {
      if (hasAggregate(c.where)) throw err('misuse of aggregate function in WHERE');
      for (final x in _conjuncts(c.where!)) {
        final ev = compileTop(x, sc);
        // Split BETWEEN into two range terms for index use.
        place(ev);
      }
    }
    // Result columns.
    sc.aggAllowed = isAgg;
    final results = <Ev>[];
    final names = <String>[];
    for (final rc in c.columns) {
      if (rc.star) {
        var any = false;
        for (final s in sc.sources) {
          if (rc.starTable != null &&
              (s.alias ?? '').toLowerCase() != rc.starTable!.toLowerCase()) {
            continue;
          }
          any = true;
          for (var k = 0; k < s.cols.length; k++) {
            if (s.hidden[k]) continue;
            if (rc.starTable == null && s.usingHidden.contains(s.cols[k].toLowerCase())) {
              continue;
            }
            s.used.add(k);
            final ev = ColEv(0, s.slot, k)
              ..aff = s.affs[k]
              ..coll = s.colls[k]
              ..isJson = s.json[k];
            computeDeps(ev);
            results.add(ev);
            names.add(s.cols[k]);
          }
        }
        if (!any) {
          throw err(rc.starTable != null
              ? 'no such table: ${rc.starTable}'
              : 'no tables specified');
        }
        continue;
      }
      final ev = compileTop(rc.e!, sc);
      results.add(ev);
      names.add(rc.alias ??
          (rc.e is ColumnExpr ? _colName(rc.e as ColumnExpr, sc) : rc.text));
    }
    final extraEvs = extra?.call(sc) ?? const <Ev>[];
    for (final e in extraEvs) {
      computeDeps(e);
    }
    // GROUP BY.
    final group = <Ev>[];
    for (final g in c.groupBy) {
      if (g is LitExpr && g.value is int) {
        final k = g.value as int;
        if (k < 1 || k > results.length) {
          throw err('GROUP BY term out of range - should be between 1 and ${results.length}');
        }
        group.add(results[k - 1]);
        continue;
      }
      if (hasAggregate(g)) throw err('aggregate functions are not allowed in the GROUP BY clause');
      sc.aggAllowed = false;
      group.add(compileTop(g, sc));
      sc.aggAllowed = isAgg;
    }
    Ev? having;
    if (c.having != null) having = compileTop(c.having!, sc);
    // ORDER BY keys (in this core's scope).
    final orderKeys = <(Ev, bool, bool?)>[];
    for (final o in order) {
      orderKeys.add((_orderKey(o.e, sc, results, c), o.desc, o.nullsFirst));
    }
    for (final k in orderKeys) {
      computeDeps(k.$1);
    }
    // Access paths.
    final orderCols = <_OrderCol>[];
    var orderSimple = !isAgg && !c.distinct && orderKeys.isNotEmpty && levels.isNotEmpty;
    if (orderSimple) {
      for (final (ev, desc, nf) in orderKeys) {
        var x = ev;
        if (x is ColEv && x.depth == 0 && x.slot == 0) {
          final nullsFirst = nf ?? !desc;
          orderCols.add(_OrderCol(x.col, desc, nullsFirst, x.coll));
        } else {
          orderSimple = false;
          break;
        }
      }
    }
    var orderSatisfied = false;
    for (var i = 0; i < levels.length; i++) {
      final sat = _chooseAccess(levels[i], i, orderSimple && i == 0 ? orderCols : null,
          forUpdate: forUpdate && i == 0);
      if (i == 0) orderSatisfied = sat;
    }
    if (isAgg && ctx.eqp != null && group.isNotEmpty) {
      ctx.explain('USE TEMP B-TREE FOR GROUP BY');
    }
    if (c.distinct && ctx.eqp != null) ctx.explain('USE TEMP B-TREE FOR DISTINCT');

    final nSlots = sc.sources.length;
    final aggs = sc.aggs!;
    final plan = _CorePlan(
        sc,
        names,
        results,
        orderKeys,
        orderSatisfied || orderKeys.isEmpty,
        (outer) {
          final f = Frame(ctx, nSlots, outer);
          final jr = JoinRunner(f, levels, pre);
          if (!isAgg) {
            return _projectIter(f, jr, results, extraEvs, orderKeys, c.distinct);
          }
          return _aggIter(f, jr, results, extraEvs, orderKeys, group, having,
              aggs, c.distinct, nSlots);
        });
    return plan;
  }

  String _colName(ColumnExpr c, Scope sc) => c.column;

  Ev _orderKey(Expr e, Scope sc, List<Ev> results, SelectCore c) {
    var x = e;
    Collation? coll;
    var explicit = false;
    if (x is CollateExpr) {
      coll = collationByName(x.collation);
      explicit = true;
      x = x.e;
    }
    Ev ev;
    if (x is LitExpr && x.value is int) {
      final k = x.value as int;
      if (k < 1 || k > results.length) {
        throw err('ORDER BY term out of range - should be between 1 and ${results.length}');
      }
      ev = results[k - 1];
    } else if (x is ColumnExpr && x.table == null &&
        _aliasIndex(c, x.column) >= 0) {
      ev = results[_aliasIndex(c, x.column)];
    } else {
      ev = compile(x, sc);
      computeDeps(ev);
    }
    if (explicit) {
      final w = CollateEv(ev, coll);
      computeDeps(w);
      return w;
    }
    return ev;
  }

  int _aliasIndex(SelectCore c, String name) {
    final l = name.toLowerCase();
    var k = 0;
    for (final rc in c.columns) {
      if (rc.star) return -1;
      if (rc.alias != null && rc.alias!.toLowerCase() == l) return k;
      k++;
    }
    return -1;
  }

  _CorePlan _planValues(
      ValuesCore v, Scope? parent, CteEnv? env, List<OrderTerm> order) {
    final sc = Scope(parent, env);
    final rows = [
      for (final r in v.rows) [for (final e in r) compileTop(e, sc)]
    ];
    final n = rows[0].length;
    final names = [for (var i = 1; i <= n; i++) 'column$i'];
    final info = [for (final e in rows[0]) ConstEv(null)..aff = Affinity.none..coll = e.coll];
    final keys = <(Ev, bool, bool?)>[];
    for (final o in order) {
      var x = o.e;
      if (x is CollateExpr) x = x.e;
      if (x is LitExpr && x.value is int) {
        final k = x.value as int;
        keys.add((_OutCol(k - 1)..coll = info[k - 1].coll, o.desc, o.nullsFirst));
      } else if (x is ColumnExpr && names.contains(x.column.toLowerCase())) {
        final k = names.indexOf(x.column.toLowerCase());
        keys.add((_OutCol(k), o.desc, o.nullsFirst));
      } else {
        throw err('1st ORDER BY term does not match any column in the result set');
      }
    }
    return _CorePlan(sc, names, info, keys, keys.isEmpty, (outer) {
      final f = Frame(ctx, 0, outer);
      var i = -1;
      List<Object?>? cur;
      return _FnIter(() {
        if (++i >= rows.length) return false;
        final r = [for (final e in rows[i]) e.eval(f)];
        if (keys.isNotEmpty) {
          r.addAll([for (final k in keys) r[(k.$1 as _OutCol).index]]);
        }
        cur = r;
        return true;
      }, () => cur!);
    });
  }

  Iterable<Expr> _conjuncts(Expr e) sync* {
    if (e is BinaryExpr && e.op == 'AND') {
      yield* _conjuncts(e.l);
      yield* _conjuncts(e.r);
    } else if (e is BetweenExpr && !e.not && _simpleColumn(e.e)) {
      yield BinaryExpr('>=', e.e, e.lo);
      yield BinaryExpr('<=', e.e, e.hi);
    } else {
      yield e;
    }
  }

  bool _simpleColumn(Expr e) => e is ColumnExpr;

  List<Ev> _usingConds(JoinItem j, int i, Scope sc) {
    if (i == 0) return const [];
    final right = sc.sources[i];
    List<String> names;
    if (j.natural) {
      names = [];
      for (var k = 0; k < right.cols.length; k++) {
        if (right.hidden[k]) continue;
        final n = right.cols[k];
        for (var p = 0; p < i; p++) {
          if (sc.sources[p].find(n) >= 0 &&
              sc.sources[p].find(n) != sc.sources[p].rowidCol) {
            names.add(n);
            break;
          }
        }
      }
    } else if (j.using != null) {
      names = j.using!;
    } else {
      return const [];
    }
    final out = <Ev>[];
    for (final n in names) {
      final rc = right.find(n);
      if (rc < 0) {
        throw err('cannot join using column $n - column not present in both tables');
      }
      SourceInfo? left;
      int lc = -1;
      for (var p = 0; p < i; p++) {
        final s = sc.sources[p];
        if (s.usingHidden.contains(n.toLowerCase())) continue;
        final k = s.find(n);
        if (k >= 0) {
          left = s;
          lc = k;
          break;
        }
      }
      if (left == null) {
        throw err('cannot join using column $n - column not present in both tables');
      }
      left.used.add(lc);
      right.used.add(rc);
      final a = ColEv(0, left.slot, lc)
        ..aff = left.affs[lc]
        ..coll = left.colls[lc];
      final b = ColEv(0, right.slot, rc)
        ..aff = right.affs[rc]
        ..coll = right.colls[rc];
      final ev = IsEv(false, a, b);
      final cmp = CmpEv('=', a, b);
      computeDeps(cmp);
      computeDeps(ev);
      out.add(cmp);
      right.usingHidden.add(n.toLowerCase());
    }
    return out;
  }

  // ---------------------------------------------------------- sources

  void _addSource(JoinItem j, Scope sc) {
    if (j.type == 'RIGHT' || j.type == 'FULL') {
      throw err('${j.type} JOIN is not supported', ZxDbError.unsupported);
    }
    final slot = sc.sources.length;
    final s = j.source;
    SourceInfo info;
    if (s is TableSource) {
      info = _tableSource(s, sc, slot);
    } else if (s is SubquerySource) {
      final saved = ctx.eqpParent;
      int? id;
      if (ctx.eqp != null) {
        id = ctx.explain('MATERIALIZE ${s.alias ?? 'subquery-${slot + 1}'}');
        ctx.eqpParent = id;
      }
      final Scope? subParent = sc.parent;
      SelectPlan plan;
      try {
        plan = planSelect(s.select, subParent, sc.ctes);
      } finally {
        ctx.eqpParent = saved;
      }
      info = _planSource(plan, s.alias, s.alias ?? '(subquery-${slot + 1})', slot);
      if (plan.correlated) {
        // Correlated with an outer query: the enclosing scope becomes
        // correlated too.
        sc.correlated = true;
        sc.parentSlots |= plan.scope?.parentSlots ?? 0;
        info.subCacheable = false;
      }
    } else if (s is FuncSource) {
      info = _funcSource(s, sc, slot);
    } else {
      throw err('unsupported FROM item');
    }
    info.left = j.type == 'LEFT';
    sc.sources.add(info);
  }

  SourceInfo _planSource(SelectPlan plan, String? alias, String display, int slot) {
    final n = plan.columns.length;
    final names = <String>[];
    final seen = <String, int>{};
    for (final c in plan.columns) {
      final l = c.toLowerCase();
      final k = seen[l];
      if (k == null) {
        seen[l] = 1;
        names.add(c);
      } else {
        seen[l] = k + 1;
        names.add('$c:$k');
      }
    }
    final info = SourceInfo(
        alias,
        display,
        names,
        [for (final e in plan.colInfo) e.aff == Affinity.none ? Affinity.none : e.aff],
        [for (final e in plan.colInfo) e.coll],
        [for (final e in plan.colInfo) e.isJson],
        List.filled(n, false),
        slot);
    info.kind = 'sub';
    info.sub = plan;
    info.types = [for (final e in plan.colInfo) e.declType];
    return info;
  }

  (ZxSnapshot, Catalog) _asOfSnapshot(AsOf a, Scope sc) {
    final ev = compileTop(a.generation ?? a.time!, Scope(null, null));
    final v = ev.eval(Frame(ctx, 0, null));
    ZxSnapshot snap;
    if (a.generation != null) {
      if (v is! int) throw err('AS OF GENERATION needs an integer');
      final c = ctx.asOfSnaps[v];
      if (c != null) return c;
      snap = env.store.snapshot(generation: v);
    } else {
      int ns;
      if (v is int) {
        ns = v;
      } else if (v is double) {
        ns = (v * 1e9).round();
      } else if (v is String) {
        final p = parseDateTimeToNs(v);
        if (p == null) throw err('AS OF: bad date/time: $v');
        ns = p;
        // A bare date means the end of that day? No: the instant given.
      } else {
        throw err('AS OF needs a date/time');
      }
      snap = env.store.snapshot(atTimeNs: ns);
    }
    final key = snap.generation;
    final c = ctx.asOfSnaps[key];
    if (c != null) {
      snap.close();
      return c;
    }
    ctx.extraSnaps.add(snap);
    final r = (snap, Catalog.load(snap));
    ctx.asOfSnaps[key] = r;
    return r;
  }

  SourceInfo _tableSource(TableSource s, Scope sc, int slot) {
    final alias = s.alias ?? s.name;
    // CTE?
    if (s.asOf == null && !s.history) {
      final cte = sc.ctes?.find(s.name);
      if (cte != null) return _cteSource(cte, alias, sc, slot);
    }
    var snap = ctx.snap;
    var catalog = ctx.catalog;
    var asOf = false;
    if (s.asOf != null) {
      final r = _asOfSnapshot(s.asOf!, sc);
      snap = r.$1;
      catalog = r.$2;
      asOf = true;
    }
    if (s.history) return _historySource(s, alias, slot);
    final td = catalog.table(s.name);
    if (td != null) {
      final n = td.columns.length;
      final info = SourceInfo(
          alias,
          td.name,
          [for (final c in td.columns) c.name],
          [for (final c in td.columns) c.affinity],
          [for (final c in td.columns) c.coll],
          [for (final c in td.columns) c.kind == ZxColumnKind.json || c.kind == ZxColumnKind.array],
          [for (final c in td.columns) c.hidden],
          slot);
      info.rowidCol = td.ipk >= 0 ? td.ipk : n;
      if (td.ipk >= 0) info.rowidCol = n; // rowid names map to the row end
      info.table = td;
      info.types = [for (final c in td.columns) c.type];
      info.snap = snap;
      info.indexedBy = s.indexedBy;
      info.notIndexed = s.notIndexed;
      return info;
    }
    final view = catalog.view(s.name);
    if (view != null) {
      if (sc.resolving.contains('view:${view.name.toLowerCase()}')) {
        throw err('view ${view.name} is circularly defined');
      }
      final saved = ctx.eqpParent;
      sc.resolving.add('view:${view.name.toLowerCase()}');
      SelectPlan plan;
      try {
        plan = planSelect(view.select, null, null);
      } finally {
        sc.resolving.remove('view:${view.name.toLowerCase()}');
        ctx.eqpParent = saved;
      }
      final info = _planSource(plan, alias, view.name, slot);
      if (view.columns != null) {
        for (var i = 0; i < view.columns!.length && i < info.cols.length; i++) {
          info.cols[i] = view.columns![i];
        }
      }
      return info;
    }
    final vt = env.findVtab(s.name, snap);
    if (vt != null) {
      final info = _vtabInfo(vt, alias, s.name, slot);
      info.snap = snap;
      if (asOf) info.kind = 'vtab-asof';
      return info;
    }
    if (s.name.toLowerCase() == 'sqlite_schema' ||
        s.name.toLowerCase() == 'sqlite_master' ||
        s.name.toLowerCase() == 'zx_schema') {
      final rows = Catalog.schemaRows(snap);
      final info = SourceInfo(alias, s.name, ['type', 'name', 'tbl_name', 'rootpage', 'sql'],
          List.filled(5, Affinity.blob), List.filled(5, null), List.filled(5, false),
          List.filled(5, false), slot);
      info.kind = 'list';
      info.rowsLoader = () => [
            for (final r in rows) [r[0], r[1], r[2], r[4], r[3]]
          ];
      return info;
    }
    throw err('no such table: ${s.name}');
  }

  SourceInfo _vtabInfo(ZxVirtualTable vt, String? alias, String name, int slot) {
    final cols = vt.columns;
    final info = SourceInfo(
        alias,
        name,
        [for (final c in cols) c.name],
        [
          for (final c in cols)
            // DATETIME columns of virtual tables hold ns: compare as time.
            kindOfType(c.type) == ZxColumnKind.datetime
                ? Affinity.timeNs
                : affinityOfType(c.type)
        ],
        List.filled(cols.length, null),
        [for (final c in cols) kindOfType(c.type) == ZxColumnKind.json],
        [for (final c in cols) c.hidden],
        slot);
    info.types = [for (final c in cols) c.type];
    info.rowidCol = cols.length;
    info.vtab = vt;
    info.kind = 'vtab';
    return info;
  }

  SourceInfo _funcSource(FuncSource s, Scope sc, int slot) {
    ZxVirtualTable? vt;
    if (s.name == 'json_each' || s.name == 'json_tree') {
      vt = _JsonEach(s.name == 'json_tree');
    } else {
      vt = env.findVtab(s.name, ctx.snap);
    }
    if (vt == null) throw err('no such table-valued function: ${s.name}');
    final info = _vtabInfo(vt, s.alias ?? s.name, s.name, slot);
    info.snap = ctx.snap;
    // Arguments may refer to sources to the left (lateral).
    info.vtabArgs = [for (final a in s.args) compileTop(a, sc)];
    final hidden = [
      for (var i = 0; i < vt.columns.length; i++)
        if (vt.columns[i].hidden) i
    ];
    if (info.vtabArgs!.length > hidden.length) {
      throw err('too many arguments on ${s.name}() - max ${hidden.length}');
    }
    return info;
  }

  SourceInfo _cteSource(CteDef cte, String alias, Scope sc, int slot) {
    final key = cte;
    final wt = _workingTables[cte];
    if (wt != null) {
      final n = cte.columns!.length;
      final info = SourceInfo(alias, cte.name, List.of(cte.columns!),
          List.filled(n, Affinity.none), List.filled(n, null),
          List.filled(n, false), List.filled(n, false), slot);
      info.kind = 'list';
      info.subCacheable = false;
      info.rowsLoader = wt;
      return info;
    }
    if (cte.recursive) return _recursiveCte(cte, alias, sc, slot);
    final saved = ctx.eqpParent;
    int? id;
    if (ctx.eqp != null) {
      id = ctx.explain('MATERIALIZE ${cte.name}');
      ctx.eqpParent = id;
    }
    SelectPlan plan;
    try {
      // A CTE body sees the CTEs defined before it, not outer columns.
      plan = planSelect(cte.select, null, cte.env?.parent == null ? cte.env : cte.env);
    } finally {
      ctx.eqpParent = saved;
    }
    final info = _planSource(plan, alias, cte.name, slot);
    if (cte.columns != null) {
      if (cte.columns!.length != plan.columns.length) {
        throw err('table ${cte.name} has ${plan.columns.length} values for ${cte.columns!.length} columns');
      }
      for (var i = 0; i < cte.columns!.length; i++) {
        info.cols[i] = cte.columns![i];
      }
    }
    info.kind = 'list';
    info.rowsLoader = () {
      final c = ctx.cache;
      var rows = c[key] as List<List<Object?>>?;
      if (rows == null) {
        rows = drain(plan.open(null));
        c[key] = rows;
      }
      return rows;
    };
    return info;
  }

  SourceInfo _recursiveCte(CteDef cte, String alias, Scope sc, int slot) {
    final body = cte.select.body;
    if (body is! CompoundSelect) {
      throw err('recursive CTE ${cte.name} needs a compound select');
    }
    // Split parts into the initial (non recursive) and recursive ones.
    final init = <SelectBody>[], rec = <SelectBody>[];
    final recOps = <String>[];
    for (var i = 0; i < body.parts.length; i++) {
      final p = body.parts[i];
      final isRec = _refersTo(SelectStmt(null, p, [], null, null), cte.name);
      if (isRec) {
        rec.add(p);
        recOps.add(body.ops[i - 1]);
      } else {
        if (rec.isNotEmpty) throw err('recursive reference in a subquery: ${cte.name}');
        init.add(p);
      }
    }
    if (init.isEmpty || rec.isEmpty) {
      throw err('circular reference: ${cte.name}');
    }
    final unionAll = recOps.every((o) => o == 'UNION ALL');
    final initStmt = init.length == 1
        ? SelectStmt(null, init[0], [], null, null)
        : SelectStmt(null, CompoundSelect(init, body.ops.sublist(0, init.length - 1)), [], null, null);
    final saved = ctx.eqpParent;
    int? id;
    if (ctx.eqp != null) {
      id = ctx.explain('MATERIALIZE ${cte.name}');
      ctx.eqpParent = id;
      ctx.explain('SETUP');
    }
    final initPlan = planSelect(initStmt, null, cte.env);
    final ncols = initPlan.columns.length;
    final names = cte.columns ?? initPlan.columns;
    if (names.length != ncols) {
      throw err('table ${cte.name} has $ncols values for ${names.length} columns');
    }
    // The working table: a CTE env where the name resolves to the queue.
    var working = <List<Object?>>[];
    final wenv = CteEnv(cte.env);
    wenv.defs[cte.name.toLowerCase()] = CteDef(
        cte.name, names, SelectStmt(null, ValuesCore([[for (var i = 0; i < ncols; i++) const LitExpr(null)]]), [], null, null), false, null);
    final workDef = wenv.defs[cte.name.toLowerCase()]!;
    if (ctx.eqp != null) ctx.explain('RECURSIVE STEP');
    _workingTables[workDef] = () => working;
    final recPlans = [
      for (final r in rec) planSelect(SelectStmt(null, r, [], null, null), null, wenv)
    ];
    ctx.eqpParent = saved;
    final info = SourceInfo(
        alias,
        cte.name,
        List.of(names),
        [for (final e in initPlan.colInfo) e.aff],
        [for (final e in initPlan.colInfo) e.coll],
        List.filled(ncols, false),
        List.filled(ncols, false),
        slot);
    info.kind = 'recursive';
    info.sub = SelectPlan(names, initPlan.colInfo, (outer) {
      final queue = Queue<List<Object?>>();
      final seen = <String>{};
      void push(List<Object?> r) {
        final row = r.length == ncols ? r : r.sublist(0, ncols);
        if (!unionAll && !seen.add(hashKey(row))) return;
        queue.add(row);
      }

      final it0 = initPlan.open(null);
      try {
        while (it0.moveNext()) {
          push(it0.current);
        }
      } finally {
        it0.close();
      }
      List<Object?>? cur;
      return _FnIter(() {
        if (queue.isEmpty) return false;
        cur = queue.removeFirst();
        working = [cur!];
        for (final p in recPlans) {
          final it = p.open(null);
          try {
            while (it.moveNext()) {
              push(it.current);
            }
          } finally {
            it.close();
          }
        }
        return true;
      }, () => cur!);
    }, null);
    return info;
  }

  final Map<CteDef, List<List<Object?>> Function()> _workingTables = Map.identity();

  SourceInfo _historySource(TableSource s, String alias, int slot) {
    final store = env.store;
    final gens = store.generations;
    if (ctx.catalog.table(s.name) == null) {
      final vt = env.findVtab(s.name, ctx.snap);
      if (vt is ZxHistoryVirtualTable) {
        final h = vt as ZxHistoryVirtualTable;
        final cols = h.historyColumns;
        final info = SourceInfo(
            alias,
            'HISTORY OF ${s.name}',
            [for (final c in cols) c.name],
            [
              for (final c in cols)
                kindOfType(c.type) == ZxColumnKind.datetime
                    ? Affinity.timeNs
                    : affinityOfType(c.type)
            ],
            List.filled(cols.length, null),
            [for (final c in cols) kindOfType(c.type) == ZxColumnKind.json],
            List.filled(cols.length, false),
            slot);
        info.types = [for (final c in cols) c.type];
        info.rowidCol = cols.length;
        info.kind = 'list';
        List<List<Object?>>? rows;
        info.rowsLoader = () => rows ??= [
              for (final (i, r) in h
                  .historyRows(gens, (g) => store.snapshot(generation: g))
                  .indexed)
                [...r, i + 1]
            ];
        return info;
      }
    }
    TableDef? last;
    final out = <List<Object?>>[];
    Map<int, Uint8List> prev = {};
    for (final g in gens) {
      final snap = store.snapshot(generation: g.generation);
      try {
        final cat = Catalog.load(snap);
        final td = cat.table(s.name);
        final cur = <int, Uint8List>{};
        if (td != null) {
          last = td;
          final t = snap.tree(td.treeName);
          if (t != null) {
            final c = t.scan();
            try {
              while (c.moveNext()) {
                cur[decodeRowid(c.key)] = c.value;
              }
            } finally {
              c.close();
            }
          }
        }
        final rd = td == null ? null : TableReader(td, snap.tree(td.treeName)!, _defaults(td));
        for (final e in cur.entries) {
          final p = prev[e.key];
          if (p == null || compareBytes(p, e.value) != 0) {
            final row = rd!.decode(e.key, e.value);
            row.removeLast();
            out.add([...row, g.generation, g.timeNs, p == null ? 'insert' : 'update', e.key]);
          }
        }
        for (final e in prev.entries) {
          if (!cur.containsKey(e.key) && last != null) {
            final rd2 = TableReader(last, snap.tree(last.treeName) ?? _EmptyTree(), _defaults(last));
            final row = rd2.decode(e.key, e.value);
            row.removeLast();
            out.add([...row, g.generation, g.timeNs, 'delete', e.key]);
          }
        }
        prev = cur;
      } finally {
        snap.close();
      }
    }
    final td = last ?? ctx.catalog.table(s.name);
    if (td == null) throw err('no such table: ${s.name}');
    final n = td.columns.length;
    for (final r in out) {
      while (r.length < n + 4) {
        r.insert(r.length - 4, null);
      }
    }
    final info = SourceInfo(
        alias,
        'HISTORY OF ${td.name}',
        [...td.columns.map((c) => c.name), 'zx_generation', 'zx_time', 'zx_op'],
        [...td.columns.map((c) => c.affinity), Affinity.integer, Affinity.integer, Affinity.text],
        [...td.columns.map((c) => c.coll), null, null, null],
        List.filled(n + 3, false),
        List.filled(n + 3, false),
        slot);
    info.rowidCol = n + 3;
    info.kind = 'list';
    info.rowsLoader = () => out;
    return info;
  }

  List<Object?> _defaults(TableDef td) => tableDefaults(td);

  List<Object?> tableDefaults(TableDef td) {
    final cached = _defaultsCache[td];
    if (cached != null) return cached;
    final d = <Object?>[];
    for (final c in td.columns) {
      if (c.defaultExpr == null) {
        d.add(null);
      } else {
        try {
          final ev = compileTop(c.defaultExpr!, Scope(null, null));
          d.add(applyAffinity(ev.eval(Frame(ctx, 0, null)), c.affinity));
        } on ZxDbException {
          d.add(null);
        }
      }
    }
    _defaultsCache[td] = d;
    return d;
  }

  final Map<TableDef, List<Object?>> _defaultsCache = Map.identity();

  // ---------------------------------------------------------- access paths

  List<_Term> _terms(Level l, int level) {
    final out = <_Term>[];
    final mask = 1 << l.src.slot;
    final laterMask = ~((1 << (level + 1)) - 1);
    bool okValue(Ev v) => (v.deps & mask) == 0 && (v.deps & laterMask) == 0;
    int? colOf(Ev e) {
      if (e is ColEv && e.depth == 0 && e.slot == l.src.slot) return e.col;
      return null;
    }

    for (final ev in l.filters) {
      if (ev is CmpEv && ev.op != '!=') {
        final lc = colOf(ev.l), rc = colOf(ev.r);
        if (lc != null && okValue(ev.r)) {
          out.add(_Term(ev, lc, ev.op, ev.r, ev.cmpAff, ev.cmpColl));
        } else if (rc != null && okValue(ev.l)) {
          const flip = {'=': '=', '<': '>', '<=': '>=', '>': '<', '>=': '<='};
          out.add(_Term(ev, rc, flip[ev.op]!, ev.l, ev.cmpAff, ev.cmpColl));
        }
      } else if (ev is IsEv && !ev.not) {
        final lc = colOf(ev.l), rc = colOf(ev.r);
        if (lc != null && okValue(ev.r)) {
          out.add(_Term(ev, lc, 'IS', ev.r, ev.cmpAff, ev.cmpColl));
        } else if (rc != null && okValue(ev.l)) {
          out.add(_Term(ev, rc, 'IS', ev.l, ev.cmpAff, ev.cmpColl));
        }
      } else if (ev is IsNullEv && !ev.not) {
        final c = colOf(ev.e);
        if (c != null) {
          out.add(_Term(ev, c, 'IS', ConstEv(null), Affinity.none, null));
        }
      } else if (ev is InListEv && !ev.not) {
        final c = colOf(ev.e);
        if (c != null && ev.list.every(okValue)) {
          out.add(_Term(ev, c, 'IN', null, inListAffinity(ev.e.aff), ev.e.coll,
              list: ev.list));
        }
      } else if (ev is InSubEv && !ev.not) {
        final c = colOf(ev.e);
        if (c != null && !ev.plan.correlated) {
          out.add(_Term(ev, c, 'INSUB', null, ev.cmpAff, ev.e.coll, sub: ev));
        }
      }
    }
    return out;
  }

  /// Chooses the access path of a level; returns true when its row order
  /// satisfies [order].
  bool _chooseAccess(Level l, int level, List<_OrderCol>? order,
      {bool forUpdate = false}) {
    final src = l.src;
    final slot = src.slot;
    final name = src.alias != null && src.alias!.toLowerCase() != src.display.toLowerCase()
        ? '${src.display} AS ${src.alias}'
        : src.display;
    if (src.table != null) return _tableAccess(l, level, order, name);
    if (src.vtab != null) return _vtabAccess(l, level, order, name);
    // Materialized or streamed rows.
    List<List<Object?>> Function(Frame f) loader;
    if (src.rowsLoader != null) {
      final ld = src.rowsLoader!;
      loader = (f) => ld();
    } else {
      final plan = src.sub!;
      final key = Object();
      final cacheable = src.subCacheable && src.kind != 'recursive';
      loader = (f) {
        if (!cacheable) return drain(plan.open(f.outer));
        final c = f.ctx.cache;
        var rows = c[key] as List<List<Object?>>?;
        if (rows == null) {
          rows = drain(plan.open(f.outer));
          c[key] = rows;
        }
        return rows;
      };
      if (level == 0 || src.kind == 'recursive') {
        final terms = level == 0 ? const <_Term>[] : _terms(l, level);
        if (terms.isEmpty || src.kind == 'recursive' && level == 0) {
          l.cursor = StreamCursor(slot, (f) => plan.open(f.outer));
          if (ctx.eqp != null) ctx.explain('SCAN $name');
          return false;
        }
      }
    }
    final terms = level == 0 ? const <_Term>[] : _terms(l, level);
    final eqs = terms.where((t) => t.op == '=' && (t.coll == null)).toList();
    if (eqs.isNotEmpty) {
      final seen = <int>{};
      final use = [for (final t in eqs) if (seen.add(t.col)) t];
      l.cursor = HashCursor(
          slot,
          loader,
          [for (final t in use) t.col],
          [for (final t in use) t.value!],
          [for (final t in use) comparisonAffinity(src.affs[t.col], t.value!.aff)],
          List<String?>.filled(use.length, null),
          src.subCacheable);
      if (ctx.eqp != null) {
        ctx.explain('SEARCH $name USING AUTOMATIC COVERING INDEX (${use.map((t) => '${src.cols[t.col]}=?').join(' AND ')})');
      }
      return false;
    }
    l.cursor = ListCursor(slot, loader);
    if (ctx.eqp != null) ctx.explain('SCAN $name');
    return false;
  }

  // returns true when the table says its rows come in [order]
  bool _vtabAccess(Level l, int level, List<_OrderCol>? order, String name) {
    final src = l.src;
    final vt = src.vtab!;
    final terms = _terms(l, level);
    final cons = <ZxIndexConstraint>[];
    final vals = <Ev>[];
    // Table-valued function arguments: equality on hidden columns.
    final hidden = [
      for (var i = 0; i < vt.columns.length; i++)
        if (vt.columns[i].hidden) i
    ];
    final args = src.vtabArgs ?? const [];
    for (var i = 0; i < args.length; i++) {
      cons.add(ZxIndexConstraint(hidden[i], ZxConstraintOp.eq, true));
      vals.add(args[i]);
    }
    const opMap = {
      '=': ZxConstraintOp.eq,
      'IS': ZxConstraintOp.isOp,
      '<': ZxConstraintOp.lt,
      '<=': ZxConstraintOp.le,
      '>': ZxConstraintOp.gt,
      '>=': ZxConstraintOp.ge,
    };
    for (final t in terms) {
      final op = opMap[t.op];
      if (op == null) continue;
      final col = t.col == src.rowidCol ? -1 : t.col;
      var o = op;
      if (t.op == 'IS' && t.value is ConstEv && (t.value as ConstEv).v == null) {
        o = ZxConstraintOp.isNull;
      }
      cons.add(ZxIndexConstraint(col, o, true));
      vals.add(t.value!);
    }
    // x BETWEEN a AND b gives the table x >= a and x <= b (the executor
    // still tests the BETWEEN).
    final mask = 1 << src.slot;
    final laterMask = ~((1 << (level + 1)) - 1);
    bool okValue(Ev v) => (v.deps & mask) == 0 && (v.deps & laterMask) == 0;
    for (final ev in l.filters) {
      if (ev is! BetweenEv || ev.not) continue;
      final e = ev.e;
      if (e is! ColEv || e.depth != 0 || e.slot != src.slot) continue;
      if (!okValue(ev.lo) || !okValue(ev.hi)) continue;
      final col = e.col == src.rowidCol ? -1 : e.col;
      cons.add(ZxIndexConstraint(col, ZxConstraintOp.ge, true));
      vals.add(ev.lo);
      cons.add(ZxIndexConstraint(col, ZxConstraintOp.le, true));
      vals.add(ev.hi);
    }
    final ob = <ZxIndexOrderBy>[];
    if (order != null) {
      for (final o in order) {
        // only plain orders (default NULL placement and collation)
        if (o.coll != null || o.nullsFirst == o.desc) {
          ob.clear();
          break;
        }
        ob.add(ZxIndexOrderBy(o.col, o.desc));
      }
    }
    final info = ZxIndexInfo(cons, ob, Set.of(src.used));
    vt.bestIndex(info);
    final argv = <int, Ev>{};
    for (var i = 0; i < cons.length; i++) {
      final k = info.argvIndex[i];
      if (k > 0) argv[k] = vals[i];
    }
    for (var i = 0; i < args.length; i++) {
      if (info.argvIndex[i] == 0) {
        // An argument the function did not take: filter on it.
        final hc = hidden[i];
        final col = ColEv(0, src.slot, hc)..aff = src.affs[hc];
        final eq = IsEv(false, col, args[i]);
        computeDeps(eq);
        l.filters.add(eq);
      }
    }
    final argEvs = [for (var k = 1; k <= argv.length; k++) argv[k]!];
    final snap = src.snap ?? ctx.snap;
    l.cursor = VtabCursor(src.slot, vt, info, argEvs, vt.columns.length,
        (f) => snap, src.kind == 'vtab-asof');
    if (ctx.eqp != null) {
      ctx.explain('SCAN $name VIRTUAL TABLE INDEX ${info.idxNum}:${info.idxStr ?? ''}');
    }
    return ob.isNotEmpty && info.orderByConsumed;
  }

  bool _coverable(TableDef td, int col) {
    final c = td.columns[col];
    if (c.collation != null && c.collation!.toUpperCase() != 'BINARY') return false;
    return c.affinity != Affinity.blob && c.affinity != Affinity.none;
  }

  bool _tableAccess(Level l, int level, List<_OrderCol>? order, String name) {
    final src = l.src;
    final td = src.table!;
    final slot = src.slot;
    final snap = src.snap ?? ctx.snap;
    final tree = snap.tree(td.treeName);
    final rd = TableReader(td, tree ?? _EmptyTree(), tableDefaults(td));
    final nrows = tree == null
        ? 0
        : tree is ZxLengthEstimate
            ? (tree as ZxLengthEstimate).estimatedLength
            : tree.length;
    final terms = src.notIndexed ? const <_Term>[] : _terms(l, level);
    final rowidCols = {src.rowidCol, if (td.ipk >= 0) td.ipk};

    // Rowid lookups.
    if (src.indexedBy == null) {
      final rEq = terms.where((t) => rowidCols.contains(t.col) && (t.op == '=' || t.op == 'IS')).toList();
      if (rEq.isNotEmpty) {
        l.cursor = RowidListCursor(slot, rd, [rEq.first.value!]);
        if (ctx.eqp != null) ctx.explain('SEARCH $name USING INTEGER PRIMARY KEY (rowid=?)');
        return true;
      }
      final rIn = terms.where((t) => rowidCols.contains(t.col) && (t.op == 'IN' || t.op == 'INSUB')).toList();
      if (rIn.isNotEmpty) {
        final t = rIn.first;
        l.cursor = RowidListCursor(slot, rd, t.list ?? const [], t.sub);
        if (ctx.eqp != null) ctx.explain('SEARCH $name USING INTEGER PRIMARY KEY (rowid=?)');
        return order != null && order.length == 1 && rowidCols.contains(order[0].col) && !order[0].desc;
      }
    }

    // Candidate indexes.
    _IxChoice? best;
    final bestFullCost = nrows.toDouble() + 1;
    for (final ix in td.indexes) {
      if (ix.where != null) continue; // partial indexes are not used for reads
      if (src.indexedBy != null && ix.name.toLowerCase() != src.indexedBy!.toLowerCase()) {
        continue;
      }
      final ch = _matchIndex(ix, td, terms, src, order);
      if (ch == null) continue;
      if (best == null || ch.cost < best.cost) best = ch;
    }
    if (src.indexedBy != null && best == null) {
      // INDEXED BY: a full index scan is acceptable.
      final ix = td.indexes.where((x) => x.name.toLowerCase() == src.indexedBy!.toLowerCase()).toList();
      if (ix.isEmpty) throw err('no such index: ${src.indexedBy}');
      best = _IxChoice(ix[0], [], null, null, false, _isCovering(ix[0], td, src), 0, nrows.toDouble(), false, false);
    }
    // Rowid ranges.
    final rLo = terms.where((t) => rowidCols.contains(t.col) && (t.op == '>' || t.op == '>=')).toList();
    final rHi = terms.where((t) => rowidCols.contains(t.col) && (t.op == '<' || t.op == '<=')).toList();
    var rowidOrder = false, rowidReverse = false;
    if (order != null && order.length == 1 && rowidCols.contains(order[0].col)) {
      rowidOrder = true;
      rowidReverse = order[0].desc;
    }
    double scanCost = nrows.toDouble() + 1;
    if (rLo.isNotEmpty || rHi.isNotEmpty) {
      scanCost = nrows / ((rLo.isNotEmpty && rHi.isNotEmpty) ? 64 : 4) + 1;
    }
    final sortPenalty = order == null || order.isEmpty
        ? 0.0
        : (nrows + 1) * 3.0;
    final scanTotal = scanCost + (rowidOrder || order == null ? 0 : sortPenalty);
    if (best != null &&
        (src.indexedBy != null ||
            best.cost + (best.ordered || order == null ? 0 : sortPenalty) < scanTotal)) {
      return _useIndex(l, best, td, rd, snap, name, bestFullCost);
    }
    // Automatic hash index for inner loops.
    if (level > 0 && rLo.isEmpty && rHi.isEmpty) {
      final eqs = terms.where((t) => t.op == '=' && !rowidCols.contains(t.col)).toList();
      if (eqs.isNotEmpty) {
        final seen = <int>{};
        final use = [for (final t in eqs) if (seen.add(t.col)) t];
        final colls = [
          for (final t in use)
            t.coll == null ? null : (t.coll == nocaseCompare ? 'NOCASE' : (t.coll == rtrimCompare ? 'RTRIM' : 'X'))
        ];
        if (!colls.contains('X')) {
          l.cursor = HashCursor(
              slot,
              (f) => _scanAll(rd),
              [for (final t in use) t.col],
              [for (final t in use) t.value!],
              [for (final t in use) t.cmpAff],
              colls,
              true);
          if (ctx.eqp != null) {
            ctx.explain('SEARCH $name USING AUTOMATIC COVERING INDEX (${use.map((t) => '${src.cols[t.col]}=?').join(' AND ')})');
          }
          return false;
        }
      }
    }
    final lo = rLo.isEmpty ? null : rLo.first;
    final hi = rHi.isEmpty ? null : rHi.first;
    l.cursor = RowidRangeCursor(slot, rd,
        lo: lo?.value,
        loIncl: lo?.op != '>',
        hi: hi?.value,
        hiIncl: hi?.op != '<',
        reverse: rowidReverse);
    if (ctx.eqp != null) {
      if (lo != null || hi != null) {
        final parts = [if (lo != null) 'rowid${lo.op}?', if (hi != null) 'rowid${hi.op}?'];
        ctx.explain('SEARCH $name USING INTEGER PRIMARY KEY (${parts.join(' AND ')})');
      } else {
        ctx.explain('SCAN $name');
      }
    }
    return rowidOrder;
  }

  List<List<Object?>> _scanAll(TableReader rd) {
    final out = <List<Object?>>[];
    final c = rd.tree.scan();
    try {
      while (c.moveNext()) {
        out.add(rd.decode(decodeRowid(c.key), c.value));
      }
    } finally {
      c.close();
    }
    return out;
  }

  bool _isCovering(IndexDef ix, TableDef td, SourceInfo src) {
    if (src.allUsed) return false;
    final have = <int>{src.rowidCol, if (td.ipk >= 0) td.ipk};
    for (final c in ix.columns) {
      if (c.col >= 0 && _coverable(td, c.col)) {
        final cc = c.collation;
        if (cc == null || cc.toUpperCase() == 'BINARY') have.add(c.col);
      }
    }
    return src.used.every(have.contains);
  }

  bool _termUsable(_Term t, IndexColumn ic, TableDef td) {
    final colAff = td.columns[ic.col].affinity;
    final a = t.cmpAff;
    if (a == Affinity.text && colAff != Affinity.text) return false;
    if (isNumericAffinity(a) && !isNumericAffinity(colAff)) return false;
    final ixColl = ic.collation?.toUpperCase();
    Collation? want = ixColl == null || ixColl == 'BINARY' ? null : collationByName(ixColl);
    return t.coll == want;
  }

  _IxChoice? _matchIndex(IndexDef ix, TableDef td, List<_Term> terms,
      SourceInfo src, List<_OrderCol>? order) {
    final eq = <_Term>[];
    var inUsed = false;
    _Term? lo, hi;
    for (var k = 0; k < ix.columns.length; k++) {
      final ic = ix.columns[k];
      if (ic.col < 0) break;
      _Term? e;
      for (final t in terms) {
        if (t.col != ic.col || !_termUsable(t, ic, td)) continue;
        if (t.op == '=' || t.op == 'IS') {
          e = t;
          break;
        }
        if ((t.op == 'IN' || t.op == 'INSUB') && !inUsed) e ??= t;
      }
      if (e != null) {
        if (e.op == 'IN' || e.op == 'INSUB') inUsed = true;
        eq.add(e);
        continue;
      }
      for (final t in terms) {
        if (t.col != ic.col || !_termUsable(t, ic, td)) continue;
        if (t.op == '>' || t.op == '>=') lo ??= t;
        if (t.op == '<' || t.op == '<=') hi ??= t;
      }
      break;
    }
    final covering = _isCovering(ix, td, src);
    // Order satisfaction.
    var ordered = false, reverse = false;
    if (order != null && order.isNotEmpty && !inUsed) {
      final eqCols = {for (final t in eq) t.col};
      final rest = order.where((o) => !eqCols.contains(o.col)).toList();
      if (rest.isEmpty) {
        ordered = true;
      } else {
        var k = eq.length;
        bool? rev;
        var ok = true;
        for (final o in rest) {
          if (k >= ix.columns.length || ix.columns[k].col != o.col) {
            ok = false;
            break;
          }
          final ic = ix.columns[k];
          final r = o.desc != ic.desc;
          if (rev != null && rev != r) {
            ok = false;
            break;
          }
          rev = r;
          // The scan yields NULLs first exactly when it yields values in
          // ascending order, which is when the term is ascending.
          if (o.nullsFirst != !o.desc && _mayBeNull(td, o.col)) {
            ok = false;
            break;
          }
          final ixColl = ic.collation?.toUpperCase();
          final want = ixColl == null || ixColl == 'BINARY' ? null : collationByName(ixColl);
          if (o.coll != want) {
            ok = false;
            break;
          }
          k++;
        }
        if (ok) {
          ordered = true;
          reverse = rev ?? false;
        }
      }
    }
    if (eq.isEmpty && lo == null && hi == null && !ordered) {
      // A full scan of a covering index is still useful when it is
      // narrower than the table, but we keep it simple.
      return null;
    }
    final tr = (src.snap ?? ctx.snap).tree(td.treeName);
    final n = tr == null
        ? 0
        : tr is ZxLengthEstimate
            ? (tr as ZxLengthEstimate).estimatedLength
            : tr.length;
    var rows = n.toDouble() + 1;
    for (final t in eq) {
      rows = (t.op == 'IN' || t.op == 'INSUB')
          ? rows / 10 * ((t.list?.length ?? 10))
          : rows / 10;
    }
    final fullUnique = ix.unique &&
        eq.length == ix.columns.length &&
        eq.every((t) => t.op == '=' || t.op == 'IS');
    if (fullUnique) rows = 1;
    if (lo != null && hi != null) {
      rows /= 64;
    } else if (lo != null || hi != null) {
      rows /= 4;
    }
    if (rows < 1) rows = 1;
    final cost = rows * (covering ? 1.0 : 2.0) + eq.length * 0.1;
    return _IxChoice(ix, eq, lo, hi, inUsed, covering, 0, cost, ordered, reverse);
  }

  bool _mayBeNull(TableDef td, int col) =>
      !(td.columns[col].notNull || col == td.ipk);

  bool _useIndex(Level l, _IxChoice ch, TableDef td, TableReader rd,
      ZxSnapshot snap, String name, double fullCost) {
    final ix = ch.ix;
    final itree = snap.tree(ix.treeName) ?? _EmptyTree();
    final eqEvs = <Ev>[];
    final nullOk = <bool>[];
    final affs = <Affinity>[];
    var inPos = -1;
    List<Ev>? inList;
    InSubEv? inSub;
    for (var i = 0; i < ch.eq.length; i++) {
      final t = ch.eq[i];
      affs.add(t.cmpAff);
      if (t.op == 'IN' || t.op == 'INSUB') {
        inPos = i;
        inList = t.list;
        inSub = t.sub;
        eqEvs.add(ConstEv(null));
        nullOk.add(false);
      } else {
        eqEvs.add(t.value!);
        nullOk.add(t.op == 'IS');
      }
    }
    final lo = ch.lo, hi = ch.hi;
    final rangeAff = (lo ?? hi)?.cmpAff ?? Affinity.none;
    l.cursor = IndexCursor(l.src.slot, ix, itree, rd, ch.covering, eqEvs,
        nullOk, affs,
        inPos: inPos,
        inList: inList,
        inSub: inSub,
        lo: lo?.value,
        loIncl: lo?.op != '>',
        hi: hi?.value,
        hiIncl: hi?.op != '<',
        rangeAff: rangeAff,
        reverse: ch.reverse);
    if (ctx.eqp != null) {
      final parts = <String>[];
      for (var i = 0; i < ch.eq.length; i++) {
        final cn = td.columns[ix.columns[i].col].name;
        parts.add('$cn=?');
      }
      if (lo != null || hi != null) {
        final cn = td.columns[ix.columns[ch.eq.length].col].name;
        if (lo != null) parts.add('$cn${lo.op}?');
        if (hi != null) parts.add('$cn${hi.op}?');
      }
      final kind = ch.covering ? 'COVERING INDEX' : 'INDEX';
      if (parts.isEmpty) {
        ctx.explain('SCAN $name USING $kind ${ix.name}');
      } else {
        ctx.explain('SEARCH $name USING $kind ${ix.name} (${parts.join(' AND ')})');
      }
    }
    return ch.ordered;
  }

  // ---------------------------------------------------------- projection

  RowIter _projectIter(Frame f, JoinRunner jr, List<Ev> results,
      List<Ev> extra, List<(Ev, bool, bool?)> keys, bool distinct) {
    final seen = distinct ? <String>{} : null;
    final n = results.length;
    List<Object?>? cur;
    return _FnIter(() {
      while (jr.next()) {
        final row = List<Object?>.filled(n + extra.length + keys.length, null);
        for (var i = 0; i < n; i++) {
          row[i] = results[i].eval(f);
        }
        if (seen != null && !seen.add(hashKey(row.sublist(0, n)))) continue;
        for (var i = 0; i < extra.length; i++) {
          row[n + i] = extra[i].eval(f);
        }
        for (var i = 0; i < keys.length; i++) {
          row[n + extra.length + i] = keys[i].$1.eval(f);
        }
        cur = row;
        return true;
      }
      return false;
    }, () => cur!, jr.close);
  }

  RowIter _aggIter(
      Frame f,
      JoinRunner jr,
      List<Ev> results,
      List<Ev> extra,
      List<(Ev, bool, bool?)> keys,
      List<Ev> group,
      Ev? having,
      List<AggSpec> aggs,
      bool distinct,
      int nSlots) {
    List<List<Object?>>? out;
    var i = -1;
    final bareMinMax = aggs.length == 1 &&
        (aggs[0].name == 'min' || aggs[0].name == 'max') &&
        !aggs[0].star;
    return _FnIter(() {
      if (out == null) {
        final groups = <String, _Group>{};
        try {
          while (jr.next()) {
            final gk = group.isEmpty
                ? ''
                : hashKey([for (final g in group) collKeyOf(g, g.eval(f))]);
            var g = groups[gk];
            if (g == null) {
              g = _Group(aggs);
              groups[gk] = g;
            }
            var changed = false;
            for (var a = 0; a < aggs.length; a++) {
              final spec = aggs[a];
              if (spec.filter != null && truth(spec.filter!.eval(f)) != true) {
                continue;
              }
              final args = [for (final e in spec.args) e.eval(f)];
              if (spec.distinct) {
                if (args[0] == null) continue;
                final dk = hashKey([collKeyOf(spec.args[0], args[0])]);
                if (!g.distinct[a]!.add(dk)) continue;
              }
              if (spec.orderBy != null) {
                g.ordered[a]!.add((args, [for (final o in spec.orderBy!) o.$1.eval(f)]));
                continue;
              }
              g.states[a].step(args);
              if (bareMinMax && minMaxChanged(g.states[a])) changed = true;
            }
            if (!bareMinMax || changed || g.rep == null) {
              g.rep = List.of(f.rows);
            }
          }
        } finally {
          jr.close();
        }
        if (groups.isEmpty && group.isEmpty) {
          groups[''] = _Group(aggs)..rep = List.filled(nSlots, null);
        }
        final rows = <List<Object?>>[];
        final seen = distinct ? <String>{} : null;
        for (final g in groups.values) {
          for (var a = 0; a < aggs.length; a++) {
            final ob = aggs[a].orderBy;
            if (ob != null) {
              final items = g.ordered[a]!;
              final idx = List<int>.generate(items.length, (k) => k);
              idx.sort((x, y) {
                for (var k = 0; k < ob.length; k++) {
                  var c = compareValues(items[x].$2[k], items[y].$2[k], ob[k].$1.coll);
                  if (ob[k].$2) c = -c;
                  if (c != 0) return c;
                }
                return x - y;
              });
              for (final k in idx) {
                g.states[a].step(items[k].$1);
              }
            }
          }
          f.agg = [for (final s in g.states) s.finish()];
          for (var s = 0; s < nSlots; s++) {
            f.rows[s] = g.rep![s];
          }
          if (having != null && truth(having.eval(f)) != true) continue;
          final n = results.length;
          final row = List<Object?>.filled(n + extra.length + keys.length, null);
          for (var k = 0; k < n; k++) {
            row[k] = results[k].eval(f);
          }
          if (seen != null && !seen.add(hashKey(row.sublist(0, n)))) continue;
          for (var k = 0; k < extra.length; k++) {
            row[n + k] = extra[k].eval(f);
          }
          for (var k = 0; k < keys.length; k++) {
            row[n + extra.length + k] = keys[k].$1.eval(f);
          }
          rows.add(row);
        }
        out = rows;
      }
      return ++i < out!.length;
    }, () => out![i], jr.close);
  }

  static Object? collKeyOf(Ev e, Object? v) {
    final c = e.coll;
    if (c == null || v is! String) return v;
    if (c == nocaseCompare) return asciiLower(v);
    if (c == rtrimCompare) return v.replaceFirst(RegExp(r' +$'), '');
    return v;
  }

  // ---------------------------------------------------------- DML helpers

  /// Plans a scan of [td] (as [alias]) with [where] and optional [from]
  /// items, producing rows of [extra] values.
  RowIter Function() planDmlScan(TableDef td, String? alias, Expr? where,
      List<JoinItem>? from, List<Ev> Function(Scope sc) extra, CteEnv? ctes) {
    final items = <JoinItem>[
      JoinItem('', TableSource(td.name, alias)),
      ...?from,
    ];
    final core = SelectCore(false, const [], items, where, const [], null);
    final plan = _planCore(core, null, ctes, const [], extra: extra, forUpdate: true);
    return () => plan.open(null);
  }
}

class _EmptyTree implements ZxTree {
  @override
  String get name => '';
  @override
  TreeOptions get options => const TreeOptions();
  @override
  Uint8List? get(Uint8List key) => null;
  @override
  ZxCursor scan({Uint8List? from, Uint8List? to, bool reverse = false}) =>
      _EmptyCursor();
  @override
  int get length => 0;
}

class _EmptyCursor implements ZxCursor {
  @override
  bool moveNext() => false;
  @override
  Uint8List get key => throw StateError('empty');
  @override
  Uint8List get value => throw StateError('empty');
  @override
  void close() {}
}

class _Group {
  final List<ZxAggregateState> states;
  final List<Set<String>?> distinct;
  final List<List<(List<Object?>, List<Object?>)>?> ordered;
  List<List<Object?>?>? rep;
  _Group(List<AggSpec> aggs)
      : states = [for (final a in aggs) a.create()],
        distinct = [for (final a in aggs) a.distinct ? <String>{} : null],
        ordered = [for (final a in aggs) a.orderBy != null ? [] : null];
}

class _IxChoice {
  final IndexDef ix;
  final List<_Term> eq;
  final _Term? lo, hi;
  final bool inUsed;
  final bool covering;
  final int unused;
  final double cost;
  final bool ordered;
  final bool reverse;
  _IxChoice(this.ix, this.eq, this.lo, this.hi, this.inUsed, this.covering,
      this.unused, this.cost, this.ordered, this.reverse);
}

/// Reference to an output column (VALUES ORDER BY).
class _OutCol extends Ev {
  final int index;
  _OutCol(this.index);
  @override
  Object? eval(Frame f) => null;
}

class _CorePlan {
  final Scope scope;
  final List<String> columns;
  final List<Ev> colInfo;
  final List<(Ev, bool, bool?)> orderKeys;
  final bool orderSatisfied;
  final RowIter Function(Frame? outer) open;
  _CorePlan(this.scope, this.columns, this.colInfo, this.orderKeys,
      this.orderSatisfied, this.open);
}

// ------------------------------------------------------------ json_each

class _JsonEach extends ZxVirtualTable {
  final bool tree;
  _JsonEach(this.tree);

  @override
  List<ZxVtabColumn> get columns => const [
        ZxVtabColumn('key'),
        ZxVtabColumn('value'),
        ZxVtabColumn('type'),
        ZxVtabColumn('atom'),
        ZxVtabColumn('id'),
        ZxVtabColumn('parent'),
        ZxVtabColumn('fullkey'),
        ZxVtabColumn('path'),
        ZxVtabColumn('json', null, true),
        ZxVtabColumn('root', null, true),
      ];

  @override
  void bestIndex(ZxIndexInfo info) {
    var mask = 0;
    final pos = [-1, -1];
    for (var i = 0; i < info.constraints.length; i++) {
      final c = info.constraints[i];
      if (c.usable && c.op == ZxConstraintOp.eq && (c.column == 8 || c.column == 9)) {
        pos[c.column - 8] = i;
      }
    }
    var k = 0;
    for (var p = 0; p < 2; p++) {
      if (pos[p] >= 0) {
        info.argvIndex[pos[p]] = ++k;
        info.omit[pos[p]] = true;
        mask |= 1 << p;
      }
    }
    info.idxNum = mask;
  }

  @override
  ZxVtabCursor open(ZxVtabContext ctx) => _JsonEachCursor(tree);
}

class _JsonEachCursor extends ZxVtabCursor {
  final bool tree;
  _JsonEachCursor(this.tree);
  List<JsonEachRow> _rows = const [];
  int _i = -1;
  Object? _json, _root;

  @override
  void filter(int idxNum, String? idxStr, List<Object?> args) {
    var k = 0;
    _json = (idxNum & 1) != 0 ? args[k++] : null;
    _root = (idxNum & 2) != 0 ? args[k++] : null;
    _i = -1;
    if ((idxNum & 1) == 0 || _json == null) {
      _rows = const [];
      return;
    }
    final doc = docArg(_json);
    final root = _root == null ? r'$' : toText(_root)!;
    _rows = jsonEach(doc, root, tree);
  }

  @override
  bool next() => ++_i < _rows.length;

  @override
  Object? column(int i) {
    final r = _rows[_i];
    switch (i) {
      case 0:
        return r.key;
      case 1:
        final v = r.value;
        if (v is List || v is Map) return renderJson(v);
        return jsonToSql(v);
      case 2:
        return jsonTypeName(r.value);
      case 3:
        final v = r.value;
        if (v is List || v is Map) return null;
        return jsonToSql(v);
      case 4:
        return r.id;
      case 5:
        return r.parent;
      case 6:
        return r.fullkey;
      case 7:
        return r.path;
      case 8:
        return _json;
      case 9:
        return _root ?? r'$';
    }
    return null;
  }

  @override
  int get rowid => _rows[_i].id;
}
