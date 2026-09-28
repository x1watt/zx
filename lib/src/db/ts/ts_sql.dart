// Time series and rollups seen from SQL (docs/zxdb-sql.md, time series):
// a series is a table of its columns (the time column is DATETIME, ns
// since 1970 UTC) with a hidden column `search` when it has a full-text
// index; a rollup is a table (ts, its columns). The statements CREATE
// TIMESERIES, DROP TIMESERIES, CREATE ROLLUP and DROP ROLLUP run here.
//
// Plans: constraints on the time column (=, <, <=, >, >=; values are ns,
// or date/time text) limit the partitions and segments read; equality on
// a tag column skips the segments whose Bloom filter says no; `search =
// 'words'` uses the full-text index; ORDER BY the time column (ASC or
// DESC) is the scan order; only the columns the query uses are decoded.
// The executor still tests every constraint. DATETIME columns of virtual
// tables have the comparison affinity timeNs (sql/value.dart): text,
// unixepoch() and julianday() operands are converted to ns first, so
// `ts >= '2026-09-01'` prunes and filters the same rows.
// INSERT appends to the write buffer; UPDATE and DELETE are refused.

import 'dart:convert';
import 'dart:typed_data';

import '../sql/ast.dart';
import '../sql/datetime.dart' show parseDateTimeToNs;
import '../sql/zx_sql.dart';
import '../storage_api.dart';
import 'ts_rollup.dart';
import 'ts_store.dart';

/// A time series as a SQL table.
class ZxTsSqlTable extends ZxWritableVirtualTable
    implements ZxHistoryVirtualTable {
  final ZxTsDef def;
  final int Function() nowMs;
  int _rowid = 0;
  ZxTsSqlTable(this.def, this.nowMs);

  int get _search => def.ftsCol >= 0 ? def.columns.length : -1;

  @override
  List<ZxVtabColumn> get columns => [
        for (final c in def.columns) ZxVtabColumn(c.name, c.type),
        if (def.ftsCol >= 0) const ZxVtabColumn('search', 'TEXT', true),
      ];

  @override
  void bestIndex(ZxIndexInfo info) {
    final ops = <String>[];
    var n = 0;
    var cost = 1e6;
    for (var i = 0; i < info.constraints.length; i++) {
      final c = info.constraints[i];
      if (!c.usable) continue;
      String? op;
      if (c.column == def.tsCol) {
        op = switch (c.op) {
          ZxConstraintOp.eq => 't=',
          ZxConstraintOp.gt => 't>',
          ZxConstraintOp.ge => 't>=',
          ZxConstraintOp.lt => 't<',
          ZxConstraintOp.le => 't<=',
          _ => null,
        };
        if (op != null) cost /= 4;
      } else if (c.column == _search && c.op == ZxConstraintOp.eq) {
        op = 's';
        info.omit[i] = true;
        cost /= 20;
      } else if (c.column >= 0 &&
          def.tags.contains(c.column) &&
          c.op == ZxConstraintOp.eq) {
        op = 'e${c.column}';
        cost /= 2;
      }
      if (op == null) continue;
      info.argvIndex[i] = ++n;
      ops.add(op);
    }
    var desc = false;
    if (info.orderBy.length == 1 && info.orderBy[0].column == def.tsCol) {
      info.orderByConsumed = true;
      desc = info.orderBy[0].desc;
    }
    info.idxNum = desc ? 1 : 0;
    final used = info.columnsUsed.where((c) => c >= 0 && c < def.columns.length);
    info.idxStr = '${ops.join(',')};${used.join(',')}';
    info.estimatedCost = cost;
  }

  @override
  ZxVtabCursor open(ZxVtabContext ctx) => _TsCursor(this, ctx);

  @override
  List<ZxVtabColumn> get historyColumns => [
        for (final c in def.columns) ZxVtabColumn(c.name, c.type),
        const ZxVtabColumn('zx_generation', 'INTEGER'),
        const ZxVtabColumn('zx_time', 'DATETIME'),
        const ZxVtabColumn('zx_op', 'TEXT'),
        const ZxVtabColumn('zx_rows', 'INTEGER'),
      ];

  /// HISTORY OF a series: per generation the rows it appended ('append',
  /// in time order) and the partitions it dropped by retention (one
  /// 'retention' row: the time column is the partition start, zx_rows the
  /// rows dropped, the other columns NULL). Seals and the rewriting of
  /// buffer blocks move rows without changing them, so they give no
  /// rows. Only the partitions whose segments or buffered rows changed
  /// between two generations are read.
  @override
  Iterable<List<Object?>> historyRows(
      List<({int generation, int timeNs, String? comment})> generations,
      ZxSnapshot Function(int generation) snapshotAt) sync* {
    final nc = def.columns.length;
    final tc = def.tsCol;
    ZxSnapshot? prev;
    ZxTsDef? prevDef;
    var prevSegs = <int, Set<int>>{};
    var prevBuf = <int, List<List<Object?>>>{};
    var prevRaw = <Uint8List>[];
    try {
      for (final g in generations) {
        final snap = snapshotAt(g.generation);
        final d = zxTsDef(snap, def.name);
        if (d == null || d.uid != def.uid) {
          // not this series (yet, or an older one of the same name)
          snap.close();
          continue;
        }
        final segs = <int, Set<int>>{};
        for (final e in zxTsSegmentList(snap, d.name)) {
          (segs[e.part] ??= {}).add(e.id);
        }
        final raw = <Uint8List>[];
        final bt = snap.tree(zxTsBufTree(d.name));
        if (bt != null) {
          final c = bt.scan();
          while (c.moveNext()) {
            raw
              ..add(c.key)
              ..add(c.value);
          }
          c.close();
        }
        var bufSame = raw.length == prevRaw.length;
        for (var i = 0; bufSame && i < raw.length; i++) {
          bufSame = _sameBytes(raw[i], prevRaw[i]);
        }
        final buf = bufSame ? prevBuf : <int, List<List<Object?>>>{};
        if (!bufSame) {
          for (final r in zxTsBufferRows(snap, d)) {
            (buf[zxTsPartStart(d.partition, r[tc] as int)] ??= []).add(r);
          }
        }
        final parts = <int>{};
        for (final p in {...segs.keys, ...prevSegs.keys}) {
          final a = segs[p], b = prevSegs[p];
          if (a == null || b == null || a.length != b.length || !a.containsAll(b)) {
            parts.add(p);
          }
        }
        if (!bufSame) {
          for (final p in {...buf.keys, ...prevBuf.keys}) {
            if ((buf[p]?.length ?? 0) != (prevBuf[p]?.length ?? 0)) parts.add(p);
          }
        }
        for (final p in parts.toList()..sort()) {
          final end = zxTsPartEnd(d.partition, p);
          final now = _partRows(snap, d, p, end);
          final before = prevDef == null
              ? const <List<Object?>>[]
              : _partRows(prev!, prevDef, p, end);
          final left = <String, int>{};
          for (final r in before) {
            final k = _rowKey(r);
            left[k] = (left[k] ?? 0) + 1;
          }
          for (final r in now) {
            final k = _rowKey(r);
            final n = left[k] ?? 0;
            if (n > 0) {
              left[k] = n - 1;
              continue;
            }
            yield [...r, g.generation, g.timeNs, 'append', 1];
          }
          final gone = left.values.fold<int>(0, (a, b) => a + b);
          if (gone > 0) {
            final row = List<Object?>.filled(nc, null);
            row[tc] = p;
            yield [...row, g.generation, g.timeNs, 'retention', gone];
          }
        }
        prev?.close();
        prev = snap;
        prevDef = d;
        prevSegs = segs;
        prevBuf = buf;
        prevRaw = raw;
      }
    } finally {
      prev?.close();
    }
  }

  static List<List<Object?>> _partRows(
      ZxSnapshot s, ZxTsDef d, int from, int to) {
    final sc = ZxTsScan(s, d, ZxTsScanSpec(from: from, to: to));
    final n = d.columns.length;
    final out = <List<Object?>>[];
    while (sc.moveNext()) {
      out.add([for (var i = 0; i < n; i++) sc.value(i)]);
    }
    return out;
  }

  static String _rowKey(List<Object?> r) {
    final sb = StringBuffer();
    for (final v in r) {
      sb.write(switch (v) {
        null => 'n',
        int() => 'i$v',
        double() => 'd$v',
        String() => 's${v.length}:$v',
        Uint8List() => 'b${base64.encode(v)}',
        _ => 'o$v',
      });
      sb.write(',');
    }
    return sb.toString();
  }

  static bool _sameBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int insert(ZxVtabContext ctx, int? rowid, List<Object?> values) {
    final t = ctx.txn;
    if (t == null) {
      throw const ZxDbException('no write transaction', ZxDbError.readOnly);
    }
    final d = zxTsDef(t, def.name) ?? def;
    final row = [
      for (var c = 0; c < d.columns.length; c++)
        zxTsCoerce(d.kinds[c], c < values.length ? values[c] : null)
    ];
    if (row[d.tsCol] == null) {
      throw ZxDbException('${d.name}.${d.columns[d.tsCol].name} is NULL',
          ZxDbError.constraint);
    }
    zxTsAppendRows(t, d, [row]);
    if (zxTsBufferedRows(t, d.name) >= d.sealRows) {
      zxTsSeal(t, d.name, nowMs: nowMs(), listener: zxRollupsOnSeal);
    }
    return ++_rowid;
  }

  @override
  void update(ZxVtabContext ctx, int rowid, List<Object?> values) =>
      throw const ZxDbException(
          'a time series is append only (UPDATE)', ZxDbError.unsupported);

  @override
  void delete(ZxVtabContext ctx, int rowid) => throw const ZxDbException(
      'a time series is append only (DELETE; rows go by retention or DROP)',
      ZxDbError.unsupported);
}

/// A time constraint value as ns: an integer, or date/time text in the
/// formats the executor's DATETIME comparison accepts (anything else
/// compares as text there, so it does not limit the scan).
int? _timeArg(Object? a) {
  if (a is int) return a;
  if (a is double) return a.isFinite ? a.round() : null;
  if (a is String) return parseDateTimeToNs(a);
  return null;
}

class _TsCursor extends ZxVtabCursor {
  final ZxTsSqlTable t;
  final ZxVtabContext ctx;
  ZxTsScan? _scan;
  String? _query;
  int _rowid = 0;
  _TsCursor(this.t, this.ctx);

  @override
  void filter(int idxNum, String? idxStr, List<Object?> args) {
    final def = zxTsDef(ctx.snapshot, t.def.name);
    if (def == null) {
      throw ZxDbException('no time series "${t.def.name}"', ZxDbError.notFound);
    }
    final parts = (idxStr ?? ';').split(';');
    final ops = parts[0].isEmpty ? const <String>[] : parts[0].split(',');
    final used = parts.length < 2 || parts[1].isEmpty
        ? <int>{}
        : parts[1].split(',').map(int.parse).toSet();
    int? from, to;
    var empty = false;
    final eq = <int, Object?>{};
    String? match;
    void lower(int v) {
      if (from == null || v > from!) from = v;
    }

    void upper(int v) {
      if (to == null || v < to!) to = v;
    }

    for (var i = 0; i < ops.length && i < args.length; i++) {
      final op = ops[i];
      final a = args[i];
      if (op == 's') {
        if (a == null) empty = true;
        match = '$a';
        continue;
      }
      if (op.startsWith('e')) {
        if (a == null) empty = true;
        eq[int.parse(op.substring(1))] = a;
        continue;
      }
      if (a == null) {
        empty = true;
        continue;
      }
      // The planner converts text and unixepoch()/julianday() values to
      // ns (DATETIME comparison affinity); a REAL bounds the range
      // loosely (the executor tests the exact comparison).
      if (a is double) {
        if (!a.isFinite) continue;
        final lo = a.floor(), hi = a.ceil();
        switch (op) {
          case 't=':
            lower(lo);
            upper(hi + 1);
          case 't>' || 't>=':
            lower(lo);
          case 't<' || 't<=':
            upper(hi + 1);
        }
        continue;
      }
      final v = _timeArg(a);
      if (v == null) continue;
      switch (op) {
        case 't=':
          lower(v);
          upper(v + 1);
        case 't>':
          lower(v + 1);
        case 't>=':
          lower(v);
        case 't<':
          upper(v);
        case 't<=':
          upper(v + 1);
      }
    }
    _query = match;
    if (empty || from != null && to != null && from! >= to!) {
      _scan = null;
      return;
    }
    _scan = ZxTsScan(
        ctx.snapshot,
        def,
        ZxTsScanSpec(
            from: from,
            to: to,
            descending: idxNum & 1 != 0,
            columns: used,
            equals: eq,
            filterRows: false,
            match: match));
  }

  @override
  bool next() {
    final s = _scan;
    if (s == null || !s.moveNext()) return false;
    _rowid++;
    return true;
  }

  @override
  Object? column(int i) {
    if (i == t._search) return _query;
    return _scan!.value(i);
  }

  @override
  int get rowid => _rowid;

  @override
  void close() {
    _scan = null;
  }
}

/// A rollup as a SQL table.
class ZxRollupSqlTable extends ZxVirtualTable {
  final ZxRollupDef def;
  ZxRollupSqlTable(this.def);

  @override
  List<ZxVtabColumn> get columns => [
        const ZxVtabColumn('ts', 'DATETIME'),
        for (final n in def.names) ZxVtabColumn(n),
      ];

  @override
  void bestIndex(ZxIndexInfo info) {
    final ops = <String>[];
    var n = 0;
    for (var i = 0; i < info.constraints.length; i++) {
      final c = info.constraints[i];
      if (!c.usable || c.column != 0) continue;
      final op = switch (c.op) {
        ZxConstraintOp.eq => '=',
        ZxConstraintOp.gt => '>',
        ZxConstraintOp.ge => '>=',
        ZxConstraintOp.lt => '<',
        ZxConstraintOp.le => '<=',
        _ => null,
      };
      if (op == null) continue;
      info.argvIndex[i] = ++n;
      ops.add(op);
    }
    var desc = false;
    if (info.orderBy.length == 1 && info.orderBy[0].column == 0) {
      info.orderByConsumed = true;
      desc = info.orderBy[0].desc;
    }
    info.idxNum = desc ? 1 : 0;
    info.idxStr = ops.join(',');
    info.estimatedCost = ops.isEmpty ? 1e5 : 1e3;
  }

  @override
  ZxVtabCursor open(ZxVtabContext ctx) => _RollupCursor(this, ctx);
}

class _RollupCursor extends ZxVtabCursor {
  final ZxRollupSqlTable t;
  final ZxVtabContext ctx;
  Iterator<List<Object?>>? _it;
  List<Object?>? _row;
  int _rowid = 0;
  _RollupCursor(this.t, this.ctx);

  @override
  void filter(int idxNum, String? idxStr, List<Object?> args) {
    final def = zxRollupDef(ctx.snapshot, t.def.name);
    if (def == null) {
      throw ZxDbException('no rollup "${t.def.name}"', ZxDbError.notFound);
    }
    int? from, to;
    final ops = idxStr == null || idxStr.isEmpty ? const <String>[] : idxStr.split(',');
    for (var i = 0; i < ops.length && i < args.length; i++) {
      final v = _timeArg(args[i]);
      if (v == null) continue;
      switch (ops[i]) {
        case '=':
          if (from == null || v > from) from = v;
          if (to == null || v + 1 < to) to = v + 1;
        case '>':
          if (from == null || v + 1 > from) from = v + 1;
        case '>=':
          if (from == null || v > from) from = v;
        case '<':
          if (to == null || v < to) to = v;
        case '<=':
          if (to == null || v + 1 < to) to = v + 1;
      }
    }
    if (from != null && to != null && from >= to) {
      _it = null;
      return;
    }
    _it = zxRollupRows(ctx.snapshot, def,
            from: from,
            to: to,
            descending: idxNum & 1 != 0,
            nowMs: ctx.nowNs ~/ 1000000)
        .iterator;
  }

  @override
  bool next() {
    final it = _it;
    if (it == null || !it.moveNext()) return false;
    _row = it.current;
    _rowid++;
    return true;
  }

  @override
  Object? column(int i) => _row![i];

  @override
  int get rowid => _rowid;
}

/// Wires the time series and rollups into a SQL session: their tables
/// (resolved by name at the statement's snapshot) and the statements.
/// [nowMs] is the clock of the retention.
void zxTsRegisterSql(ZxSql sql, {int Function()? nowMs}) {
  final clock = nowMs ?? () => DateTime.now().millisecondsSinceEpoch;
  final series = <String, ZxTsSqlTable>{};
  final rollups = <String, ZxRollupSqlTable>{};
  sql.addVirtualTableResolver((name, snap) {
    final m = snap.tree(zxTsMetaTree);
    if (m != null && m.get(Uint8List.fromList(utf8.encode(name))) != null) {
      final d = zxTsDef(snap, name)!;
      final have = series[name];
      if (have != null && have.def.uid == d.uid &&
          have.def.columns.length == d.columns.length) {
        return have;
      }
      return series[name] = ZxTsSqlTable(d, clock);
    }
    final r = snap.tree(zxRollupMetaTree);
    if (r != null && r.get(Uint8List.fromList(utf8.encode(name))) != null) {
      final d = zxRollupDef(snap, name)!;
      final have = rollups[name];
      if (have != null && jsonEncode(have.def.toJson()) == jsonEncode(d.toJson())) {
        return have;
      }
      return rollups[name] = ZxRollupSqlTable(d);
    }
    return null;
  });
  ZxWriteTxn txnOf(ZxSqlHookContext ctx) {
    final t = ctx.txn;
    if (t == null) {
      throw const ZxDbException('no write transaction', ZxDbError.readOnly);
    }
    return t;
  }

  sql.registerStatementHook('CREATE TIMESERIES', (stmt, ctx) {
    final s = stmt as CreateTimeseriesStmt;
    final t = txnOf(ctx);
    if (zxTsDef(t, s.name) != null) {
      if (s.ifNotExists) return null;
      throw ZxDbException('time series "${s.name}" exists', ZxDbError.constraint);
    }
    final def = ZxTsDef.create(
        s.name, [for (final c in s.columns) ZxTsColumn(c.name, c.type ?? '')],
        partitionBy: s.partitionBy, retention: s.retention, options: s.options);
    zxTsCreate(t, def);
    return null;
  });
  sql.registerStatementHook('DROP TIMESERIES', (stmt, ctx) {
    final s = stmt as DropStmt;
    final t = txnOf(ctx);
    for (final r in zxRollups(t, series: s.name)) {
      zxRollupDrop(t, r.name);
      rollups.remove(r.name);
    }
    zxTsDrop(t, s.name, ifExists: s.ifExists);
    series.remove(s.name);
    return null;
  });
  sql.registerStatementHook('CREATE ROLLUP', (stmt, ctx) {
    final s = stmt as CreateRollupStmt;
    final t = txnOf(ctx);
    if (zxRollupDef(t, s.name) != null) {
      if (s.ifNotExists) return null;
      throw ZxDbException('rollup "${s.name}" exists', ZxDbError.constraint);
    }
    var src = s.on;
    final body = s.select.body;
    if (src == null && body is SelectCore && body.from.isNotEmpty) {
      final f = body.from.first.source;
      if (f is TableSource) src = f.name;
    }
    if (src == null) {
      throw const ZxDbException(
          'CREATE ROLLUP needs ON series or FROM series', ZxDbError.syntax);
    }
    final sdef = zxTsDef(t, src);
    if (sdef == null) {
      throw ZxDbException('no time series "$src"', ZxDbError.notFound);
    }
    zxRollupCreate(t, ZxRollupDef.compile(s, sdef));
    return null;
  });
  sql.registerStatementHook('DROP ROLLUP', (stmt, ctx) {
    final s = stmt as DropStmt;
    zxRollupDrop(txnOf(ctx), s.name, ifExists: s.ifExists);
    rollups.remove(s.name);
    return null;
  });
}
