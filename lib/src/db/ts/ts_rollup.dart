// Rollups of time series (docs/zxdb-design.md 2.3 and section 12):
// materialized aggregates per time bucket, kept up to date when the
// series is sealed (the rows being sealed are added to their buckets),
// and filled from the sealed data when the rollup is created.
//
//   CREATE ROLLUP hourly ON logs EVERY '1h' RETENTION '5y'
//     AS SELECT level, count(*) AS n, avg(latency) AS lat
//        FROM logs WHERE status >= 500 GROUP BY level;
//
// The query is one SELECT over the series: plain columns that are in
// GROUP BY, aggregates count(*), count(x), sum, total, avg, min, max,
// first(x) and last(x) (by time), an optional WHERE that is an AND of
// comparisons of a column with literals (=, <>, <, <=, >, >=, IN, IS
// [NOT] NULL, LIKE). The bucket is implicit: the rollup's rows are
// (ts = bucket start, the select's columns); a reference to the series'
// time column in the select is the bucket.
//
// Trees: zx$rollup (name: the definition, JSON), rollup:<name> (key
// (bucket, group values...) with keycodec.dart, value the aggregate
// states as tagged values).

import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import '../keycodec.dart';
import '../sql/ast.dart';
import '../storage_api.dart';
import 'ts_codec.dart';
import 'ts_store.dart';

const String zxRollupMetaTree = r'zx$rollup';
String zxRollupTree(String name) => 'rollup:$name';

Uint8List _utf8(String s) => Uint8List.fromList(utf8.encode(s));

const _aggs = {'count', 'sum', 'total', 'avg', 'min', 'max', 'first', 'last'};

/// A rollup definition.
class ZxRollupDef {
  final String name;
  final String series;
  final int everyMs;
  final int? retentionMs;

  /// Series columns of the GROUP BY.
  final List<int> groups;

  /// Aggregates: (function, series column or -1 for count(*)).
  final List<(String, int)> aggs;

  /// Output columns after ts: ('g', index in groups) or ('a', index in
  /// aggs), with their names.
  final List<(String, int)> outs;
  final List<String> names;

  /// The WHERE: an AND of (column, op, literal or list of literals).
  final List<(int, String, Object?)> where;

  const ZxRollupDef(this.name, this.series, this.everyMs, this.retentionMs,
      this.groups, this.aggs, this.outs, this.names, this.where);

  Map<String, Object?> toJson() => {
        'series': series,
        'every': everyMs,
        'retention': retentionMs,
        'groups': groups,
        'aggs': [
          for (final a in aggs) [a.$1, a.$2]
        ],
        'outs': [
          for (final o in outs) [o.$1, o.$2]
        ],
        'names': names,
        'where': [
          for (final w in where) [w.$1, w.$2, w.$3]
        ],
      };

  static ZxRollupDef fromJson(String name, Map<String, Object?> j) =>
      ZxRollupDef(
          name,
          j['series'] as String,
          j['every'] as int,
          j['retention'] as int?,
          (j['groups'] as List).cast<int>(),
          [
            for (final a in j['aggs'] as List)
              ((a as List)[0] as String, a[1] as int)
          ],
          [
            for (final o in j['outs'] as List)
              ((o as List)[0] as String, o[1] as int)
          ],
          (j['names'] as List).cast<String>(),
          [
            for (final w in j['where'] as List)
              ((w as List)[0] as int, w[1] as String, w[2])
          ]);

  /// The output column names, ts first.
  List<String> get columns => ['ts', ...names];

  /// Compiles CREATE ROLLUP against series [def].
  static ZxRollupDef compile(
      CreateRollupStmt st, ZxTsDef def, {String? every, String? retention}) {
    final body = st.select.body;
    if (body is! SelectCore) {
      throw const ZxDbException(
          'a rollup is one SELECT', ZxDbError.unsupported);
    }
    if (body.having != null || body.distinct) {
      throw const ZxDbException(
          'a rollup has no HAVING or DISTINCT', ZxDbError.unsupported);
    }
    int col(Expr e) {
      if (e is ColumnExpr) {
        final i = def.columnIndex(e.column);
        if (i >= 0) return i;
        throw ZxDbException('no column ${e.column} in ${def.name}',
            ZxDbError.syntax);
      }
      throw const ZxDbException(
          'a rollup groups by columns only', ZxDbError.unsupported);
    }

    final groups = [for (final g in body.groupBy) col(g)];
    final aggs = <(String, int)>[];
    final outs = <(String, int)>[];
    final names = <String>[];
    for (final rc in body.columns) {
      final e = rc.e;
      if (rc.star || e == null) {
        throw const ZxDbException(
            'SELECT * in a rollup', ZxDbError.unsupported);
      }
      if (e is ColumnExpr) {
        final c = col(e);
        if (c == def.tsCol) continue; // the bucket
        final gi = groups.indexOf(c);
        if (gi < 0) {
          throw ZxDbException(
              '${e.column} must be in GROUP BY', ZxDbError.syntax);
        }
        outs.add(('g', gi));
        names.add(rc.alias ?? def.columns[c].name);
        continue;
      }
      if (e is FuncExpr && _aggs.contains(e.name) && !e.distinct &&
          e.filter == null) {
        int arg;
        if (e.star || e.args.isEmpty) {
          if (e.name != 'count') {
            throw ZxDbException('${e.name}(*)', ZxDbError.syntax);
          }
          arg = -1;
        } else {
          if (e.args.length != 1) {
            throw ZxDbException('${e.name} takes one column', ZxDbError.syntax);
          }
          arg = col(e.args[0]);
        }
        outs.add(('a', aggs.length));
        aggs.add((e.name, arg));
        names.add(rc.alias ?? rc.text);
        continue;
      }
      throw ZxDbException(
          'a rollup selects group columns and aggregates (${rc.text})',
          ZxDbError.unsupported);
    }
    if (st.columns != null) {
      for (var i = 0; i < st.columns!.length && i < names.length; i++) {
        names[i] = st.columns![i];
      }
    }
    final where = <(int, String, Object?)>[];
    void cond(Expr e) {
      if (e is BinaryExpr && e.op.toUpperCase() == 'AND') {
        cond(e.l);
        cond(e.r);
        return;
      }
      if (e is BinaryExpr &&
          const {'=', '==', '<>', '!=', '<', '<=', '>', '>='}.contains(e.op)) {
        var op = e.op == '==' ? '=' : e.op == '<>' ? '!=' : e.op;
        if (e.l is ColumnExpr && e.r is LitExpr) {
          where.add((col(e.l), op, (e.r as LitExpr).value));
          return;
        }
        if (e.r is ColumnExpr && e.l is LitExpr) {
          op = switch (op) {
            '<' => '>',
            '<=' => '>=',
            '>' => '<',
            '>=' => '<=',
            _ => op
          };
          where.add((col(e.r), op, (e.l as LitExpr).value));
          return;
        }
      }
      if (e is IsNullExpr) {
        where.add((col(e.e), e.not ? 'notnull' : 'null', null));
        return;
      }
      if (e is InListExpr && e.list.every((x) => x is LitExpr)) {
        where.add((
          col(e.e),
          e.not ? 'notin' : 'in',
          [for (final x in e.list) (x as LitExpr).value]
        ));
        return;
      }
      if (e is LikeExpr && e.op.toUpperCase() == 'LIKE' &&
          e.pattern is LitExpr && e.escape == null) {
        where.add((col(e.e), e.not ? 'notlike' : 'like',
            (e.pattern as LitExpr).value));
        return;
      }
      throw const ZxDbException(
          'a rollup WHERE is an AND of column comparisons with literals',
          ZxDbError.unsupported);
    }

    if (body.where != null) cond(body.where!);
    final ev = every ?? st.every;
    if (ev == null) {
      throw const ZxDbException('a rollup needs EVERY', ZxDbError.syntax);
    }
    final ret = retention ?? st.retention;
    return ZxRollupDef(st.name, def.name, zxTsParseDurationMs(ev),
        ret == null ? null : zxTsParseDurationMs(ret), groups, aggs, outs,
        names, where);
  }

  bool _accepts(List<Object?> row) {
    for (final (c, op, lit) in where) {
      final v = row[c];
      switch (op) {
        case 'null':
          if (v != null) return false;
        case 'notnull':
          if (v == null) return false;
        case 'in':
          if (v == null || !(lit as List).any((x) => _cmp(v, x) == 0)) {
            return false;
          }
        case 'notin':
          if (v == null || (lit as List).any((x) => _cmp(v, x) == 0)) {
            return false;
          }
        case 'like':
        case 'notlike':
          if (v == null || lit == null) return false;
          final m = _likeRe('$lit').hasMatch('$v');
          if (m != (op == 'like')) return false;
        default:
          if (v == null || lit == null) return false;
          final d = _cmp(v, lit);
          final ok = switch (op) {
            '=' => d == 0,
            '!=' => d != 0,
            '<' => d < 0,
            '<=' => d <= 0,
            '>' => d > 0,
            _ => d >= 0,
          };
          if (!ok) return false;
      }
    }
    return true;
  }
}

final Map<String, RegExp> _likeCache = {};
RegExp _likeRe(String p) => _likeCache[p] ??= RegExp(
    '^${p.split('').map((c) => c == '%' ? '.*' : c == '_' ? '.' : RegExp.escape(c)).join()}\$',
    caseSensitive: false,
    dotAll: true);

// SQL order of values: NULL, numbers, text, blobs
int _cmp(Object? a, Object? b) {
  int cls(Object? v) => v == null
      ? 0
      : v is num
          ? 1
          : v is String
              ? 2
              : 3;
  final ca = cls(a), cb = cls(b);
  if (ca != cb) return ca - cb;
  if (a is num && b is num) return a.compareTo(b);
  if (a is String && b is String) return a.compareTo(b);
  if (a is Uint8List && b is Uint8List) return zxCompareKeys(a, b);
  return 0;
}

// ---------------------------------------------------------- states

// the state of one aggregate: [count, sum, min, max, firstTs, first,
// lastTs, last] (only what the function needs is kept up to date)
List<Object?> _newState() => [0, null, null, null, null, null, null, null];

void _add(List<Object?> s, String fn, Object? v, int ts, bool star) {
  if (star) {
    s[0] = (s[0] as int) + 1;
    return;
  }
  if (v == null) return;
  s[0] = (s[0] as int) + 1;
  switch (fn) {
    case 'sum':
    case 'total':
    case 'avg':
      final n = v is num ? v : (v is String ? num.tryParse(v) ?? 0 : 0);
      final cur = s[1];
      s[1] = cur == null ? n : (cur as num) + n;
    case 'min':
      if (s[2] == null || _cmp(v, s[2]) < 0) s[2] = v;
    case 'max':
      if (s[3] == null || _cmp(v, s[3]) > 0) s[3] = v;
    case 'first':
      if (s[4] == null || ts < (s[4] as int)) {
        s[4] = ts;
        s[5] = v;
      }
    case 'last':
      if (s[6] == null || ts >= (s[6] as int)) {
        s[6] = ts;
        s[7] = v;
      }
  }
}

// merges [b] (newer rows) into [a]
void _merge(List<Object?> a, List<Object?> b) {
  a[0] = (a[0] as int) + (b[0] as int);
  if (b[1] != null) a[1] = a[1] == null ? b[1] : (a[1] as num) + (b[1] as num);
  if (b[2] != null && (a[2] == null || _cmp(b[2], a[2]) < 0)) a[2] = b[2];
  if (b[3] != null && (a[3] == null || _cmp(b[3], a[3]) > 0)) a[3] = b[3];
  if (b[4] != null && (a[4] == null || (b[4] as int) < (a[4] as int))) {
    a[4] = b[4];
    a[5] = b[5];
  }
  if (b[6] != null && (a[6] == null || (b[6] as int) >= (a[6] as int))) {
    a[6] = b[6];
    a[7] = b[7];
  }
}

Object? _final(List<Object?> s, String fn) {
  final n = s[0] as int;
  switch (fn) {
    case 'count':
      return n;
    case 'sum':
      return n == 0 ? null : s[1];
    case 'total':
      return n == 0 ? 0.0 : (s[1] as num).toDouble();
    case 'avg':
      return n == 0 ? null : (s[1] as num) / n;
    case 'min':
      return s[2];
    case 'max':
      return s[3];
    case 'first':
      return s[5];
    case 'last':
      return s[7];
  }
  return null;
}

Uint8List _encodeStates(List<List<Object?>> states) {
  final w = TsWriter(64);
  w.varint(states.length);
  for (final s in states) {
    for (final v in s) {
      tsWriteValue(w, v);
    }
  }
  return w.copy();
}

List<List<Object?>> _decodeStates(Uint8List b) {
  final r = TsReader(b);
  final n = r.varint();
  return [
    for (var i = 0; i < n; i++) [for (var k = 0; k < 8; k++) tsReadValue(r)]
  ];
}

// ---------------------------------------------------------- storage

ZxRollupDef? zxRollupDef(ZxSnapshot s, String name) {
  final v = s.tree(zxRollupMetaTree)?.get(_utf8(name));
  if (v == null) return null;
  return ZxRollupDef.fromJson(
      name, jsonDecode(utf8.decode(v)) as Map<String, Object?>);
}

List<ZxRollupDef> zxRollups(ZxSnapshot s, {String? series}) {
  final m = s.tree(zxRollupMetaTree);
  if (m == null) return const [];
  final out = <ZxRollupDef>[];
  final c = m.scan();
  while (c.moveNext()) {
    final d = ZxRollupDef.fromJson(utf8.decode(c.key),
        jsonDecode(utf8.decode(c.value)) as Map<String, Object?>);
    if (series == null || d.series == series) out.add(d);
  }
  c.close();
  return out;
}

/// Creates rollup [def] and fills it from the sealed rows of its series.
bool zxRollupCreate(ZxWriteTxn t, ZxRollupDef def, {bool ifNotExists = false}) {
  final m = t.tree(zxRollupMetaTree) ?? t.createTree(zxRollupMetaTree);
  final k = _utf8(def.name);
  if (m.get(k) != null) {
    if (ifNotExists) return false;
    throw ZxDbException('rollup "${def.name}" exists', ZxDbError.constraint);
  }
  final sdef = zxTsDef(t, def.series);
  if (sdef == null) {
    throw ZxDbException('no time series "${def.series}"', ZxDbError.notFound);
  }
  m.put(k, _utf8(jsonEncode(def.toJson())));
  t.createTree(zxRollupTree(def.name), const TreeOptions(compression: 'fast'));
  final scan = ZxTsScan(t, sdef, const ZxTsScanSpec(buffer: false));
  final rows = <List<Object?>>[];
  while (scan.moveNext()) {
    rows.add(scan.row());
    if (rows.length >= 65536) {
      _feed(t, sdef, def, rows);
      rows.clear();
    }
  }
  _feed(t, sdef, def, rows);
  return true;
}

bool zxRollupDrop(ZxWriteTxn t, String name, {bool ifExists = false}) {
  final m = t.tree(zxRollupMetaTree);
  final k = _utf8(name);
  if (m == null || m.get(k) == null) {
    if (ifExists) return false;
    throw ZxDbException('no rollup "$name"', ZxDbError.notFound);
  }
  m.delete(k);
  if (t.tree(zxRollupTree(name)) != null) t.dropTree(zxRollupTree(name));
  return true;
}

void _feed(ZxWriteTxn t, ZxTsDef sdef, ZxRollupDef def, List<List<Object?>> rows) {
  if (rows.isEmpty) return;
  final tree = t.tree(zxRollupTree(def.name))!;
  final every = def.everyMs * 1000000;
  final acc = HashMap<String, (Uint8List, List<List<Object?>>)>();
  final tc = sdef.tsCol;
  for (final r in rows) {
    if (!def._accepts(r)) continue;
    final ts = r[tc] as int;
    final q = ts ~/ every;
    final b = (ts % every != 0 && ts < 0 ? q - 1 : q) * every;
    final kv = <Object?>[b, for (final g in def.groups) r[g]];
    final key = encodeKey(kv);
    final ks = latin1.decode(key);
    var e = acc[ks];
    if (e == null) {
      e = (key, [for (var i = 0; i < def.aggs.length; i++) _newState()]);
      acc[ks] = e;
    }
    for (var i = 0; i < def.aggs.length; i++) {
      final (fn, c) = def.aggs[i];
      _add(e.$2[i], fn, c < 0 ? null : r[c], ts, c < 0);
    }
  }
  for (final e in acc.values) {
    final old = tree.get(e.$1);
    List<List<Object?>> st = e.$2;
    if (old != null) {
      final o = _decodeStates(old);
      for (var i = 0; i < o.length && i < st.length; i++) {
        _merge(o[i], st[i]);
      }
      st = o;
    }
    tree.put(e.$1, _encodeStates(st));
  }
}

/// The seal listener: feeds the rollups of the series with the rows being
/// sealed and applies their retention.
void zxRollupsOnSeal(
    ZxWriteTxn t, ZxTsDef sdef, List<List<Object?>> rows, int nowMs) {
  for (final d in zxRollups(t, series: sdef.name)) {
    _feed(t, sdef, d, rows);
    final r = d.retentionMs;
    if (r != null) {
      final cutoff = (nowMs - r) * 1000000;
      t.tree(zxRollupTree(d.name))!.deleteRange(to: encodeKey([cutoff]));
    }
  }
}

/// The rows of rollup [def] at [s] with buckets in [from, to):
/// ts, then the output columns.
Iterable<List<Object?>> zxRollupRows(ZxSnapshot s, ZxRollupDef def,
    {int? from, int? to, bool descending = false}) sync* {
  final tree = s.tree(zxRollupTree(def.name));
  if (tree == null) return;
  final c = tree.scan(
      from: from == null ? null : encodeKey([from]),
      to: to == null ? null : encodeKey([to]),
      reverse: descending);
  try {
    while (c.moveNext()) {
      final k = decodeKey(c.key);
      final st = _decodeStates(c.value);
      final row = <Object?>[k[0]];
      for (final (kind, i) in def.outs) {
        if (kind == 'g') {
          row.add(k[1 + i]);
        } else {
          row.add(_final(st[i], def.aggs[i].$1));
        }
      }
      yield row;
    }
  } finally {
    c.close();
  }
}
