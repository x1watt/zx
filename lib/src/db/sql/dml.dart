// INSERT, UPDATE and DELETE: row encoding, index maintenance, constraint
// checks (NOT NULL, CHECK, UNIQUE / PRIMARY KEY), conflict resolution
// (ABORT, FAIL, IGNORE, REPLACE, ROLLBACK), upserts and RETURNING.

import 'dart:typed_data';

import '../keycodec.dart';
import '../record.dart';
import '../storage_api.dart';
import 'ast.dart';
import 'catalog.dart';
import 'datetime.dart';
import 'eval.dart';
import 'json.dart';
import 'planner.dart';
import 'value.dart';
import 'vtab.dart';

/// Thrown for ON CONFLICT ROLLBACK: the caller rolls the transaction back.
class RollbackSignal implements Exception {
  final ZxDbException error;
  RollbackSignal(this.error);
}

/// Result of a DML statement.
class DmlResult {
  final int changes;
  final List<String> columns;
  final List<List<Object?>> rows;
  DmlResult(this.changes, [this.columns = const [], this.rows = const []]);
}

ZxDbException _constraint(String m) => ZxDbException(m, ZxDbError.constraint);

/// Converts a value for a column (affinity and zx types).
Object? columnValue(ColumnDef c, Object? v, String table) {
  v = applyAffinity(v, c.affinity);
  switch (c.kind) {
    case ZxColumnKind.plain:
      return v;
    case ZxColumnKind.boolean:
      if (v is String) {
        final l = v.toLowerCase();
        if (l == 'true') return 1;
        if (l == 'false') return 0;
      }
      return v;
    case ZxColumnKind.datetime:
      if (v is String) {
        final ns = parseDateTimeToNs(v);
        if (ns != null) return ns;
      }
      if (v is double) return v.round();
      return v;
    case ZxColumnKind.json:
      if (v == null || v is num) return v;
      if (v is Uint8List) {
        throw _constraint('JSON column $table.${c.name}: BLOB is not JSON');
      }
      if (!isValidJson(v as String)) {
        throw _constraint('JSON column $table.${c.name}: malformed JSON');
      }
      return v;
    case ZxColumnKind.array:
      if (v == null) return v;
      if (v is String) {
        Object? j;
        try {
          j = parseJson(v);
        } on ZxDbException {
          j = null;
        }
        if (j is List) return v;
      }
      throw _constraint('ARRAY column $table.${c.name}: not a JSON array');
  }
}

/// Writes rows of one table and maintains its indexes.
class TableWriter {
  final ExecCtx ctx;
  final Planner pl;
  final TableDef td;
  late final ZxWritableTree tree = ctx.wtree(td.treeName);
  late final List<ZxWritableTree> itrees = [
    for (final ix in td.indexes) ctx.wtree(ix.treeName)
  ];
  late final TableReader rd = TableReader(td, tree, pl.tableDefaults(td));
  late final Frame _f = Frame(ctx, 1, null);
  late final List<List<Ev?>> _ixExprs;
  late final List<Ev?> _ixWhere;
  late final List<Ev> _checks;
  late final List<String> _checkNames;

  TableWriter(this.ctx, this.pl, this.td) {
    final sc = tableScope(pl, td, td.name);
    _ixExprs = [
      for (final ix in td.indexes)
        [for (final c in ix.columns) c.expr == null ? null : pl.compileTop(c.expr!, sc)]
    ];
    _ixWhere = [
      for (final ix in td.indexes) ix.where == null ? null : pl.compileTop(ix.where!, sc)
    ];
    _checks = [];
    _checkNames = [];
    for (final c in td.columns) {
      for (final k in c.checks) {
        _checks.add(pl.compileTop(k, sc));
        _checkNames.add(exprToSql(k));
      }
    }
    for (final k in td.checks) {
      _checks.add(pl.compileTop(k, sc));
      _checkNames.add(exprToSql(k));
    }
  }

  /// Key values of index [i] for [row] (row includes the rowid at the
  /// end); null when a partial index does not cover the row.
  List<Object?>? keyValues(int i, List<Object?> row) {
    final ix = td.indexes[i];
    _f.rows[0] = row;
    final w = _ixWhere[i];
    if (w != null && truth(w.eval(_f)) != true) return null;
    final out = <Object?>[];
    for (var k = 0; k < ix.columns.length; k++) {
      final c = ix.columns[k];
      final v = c.col >= 0 ? row[c.col] : _ixExprs[i][k]!.eval(_f);
      out.add(collKey(v, c.collation));
    }
    return out;
  }

  Uint8List indexKey(int i, List<Object?> kv, int rowid) {
    final ix = td.indexes[i];
    final w = KeyWriter();
    for (var k = 0; k < kv.length; k++) {
      encodeKeyValue(w, kv[k], desc: ix.columns[k].desc);
    }
    encodeKeyValue(w, rowid);
    return w.take();
  }

  /// Rowid of a row conflicting with [kv] in unique index [i], ignoring
  /// [self]; null when none.
  int? conflict(int i, List<Object?> kv, int self) {
    if (kv.any((v) => v == null)) return null;
    final ix = td.indexes[i];
    final w = KeyWriter();
    for (var k = 0; k < kv.length; k++) {
      encodeKeyValue(w, kv[k], desc: ix.columns[k].desc);
    }
    final prefix = w.take();
    final c = itrees[i].scan(from: prefix, to: prefixEnd(prefix));
    try {
      while (c.moveNext()) {
        final vals = decodeKey(c.key, count: kv.length + 1, desc: [...ix.descs, false]);
        final r = vals.last as int;
        if (r != self) return r;
      }
    } finally {
      c.close();
    }
    return null;
  }

  Uint8List recordOf(List<Object?> row) {
    final n = td.columns.length;
    final w = RecordWriter();
    for (var i = 0; i < n; i++) {
      w.add(i == td.ipk ? null : row[i]);
    }
    return w.take();
  }

  void writeRow(int rowid, List<Object?> row) {
    tree.put(encodeRowid(rowid), recordOf(row));
    for (var i = 0; i < td.indexes.length; i++) {
      final kv = keyValues(i, row);
      if (kv != null) itrees[i].put(indexKey(i, kv, rowid), Uint8List(0));
    }
  }

  void deleteRow(int rowid, List<Object?> row) {
    tree.delete(encodeRowid(rowid));
    for (var i = 0; i < td.indexes.length; i++) {
      final kv = keyValues(i, row);
      if (kv != null) itrees[i].delete(indexKey(i, kv, rowid));
    }
  }

  int maxRowid() {
    final c = tree.scan(reverse: true);
    try {
      if (c.moveNext()) return decodeRowid(c.key);
      return 0;
    } finally {
      c.close();
    }
  }

  int newRowid() {
    var m = maxRowid();
    if (td.autoincrement) {
      final s = Catalog.readInt(ctx.txn!, 'seq:${td.name.toLowerCase()}');
      if (s > m) m = s;
    }
    if (m == 0x7FFFFFFFFFFFFFFF) {
      if (td.autoincrement) throw const ZxDbException('database or disk is full');
      // Pick an unused rowid.
      for (var r = 1;; r++) {
        if (tree.get(encodeRowid(r)) == null) return r;
      }
    }
    return m + 1;
  }

  void noteRowid(int rowid) {
    if (!td.autoincrement) return;
    final k = 'seq:${td.name.toLowerCase()}';
    if (rowid > Catalog.readInt(ctx.txn!, k)) Catalog.writeInt(ctx.txn!, k, rowid);
  }

  /// NOT NULL and CHECK. Returns false when the row must be skipped
  /// (IGNORE).
  bool checkRow(List<Object?> row, String? or, List<Object?> defaults) {
    for (var i = 0; i < td.columns.length; i++) {
      final c = td.columns[i];
      if (c.notNull && row[i] == null && i != td.ipk) {
        final mode = or ?? c.notNullConflict ?? 'ABORT';
        if (mode == 'IGNORE') return false;
        if (mode == 'REPLACE' && defaults[i] != null) {
          row[i] = defaults[i];
          continue;
        }
        _fail(mode, 'NOT NULL constraint failed: ${td.name}.${c.name}');
      }
    }
    if (_checks.isNotEmpty) {
      _f.rows[0] = row;
      for (var k = 0; k < _checks.length; k++) {
        final v = _checks[k].eval(_f);
        if (v != null && truth(v) == false) {
          final mode = or ?? 'ABORT';
          if (mode == 'IGNORE') return false;
          _fail(mode == 'REPLACE' ? 'ABORT' : mode,
              'CHECK constraint failed: ${_checkNames[k]}');
        }
      }
    }
    return true;
  }

  Never _fail(String mode, String msg) {
    final e = _constraint(msg);
    if (mode == 'ROLLBACK') throw RollbackSignal(e);
    throw e;
  }

  String uniqueMessage(int i) {
    final ix = td.indexes[i];
    final cols = ix.columns
        .map((c) => c.col >= 0 ? '${td.name}.${td.columns[c.col].name}' : 'index \'${ix.name}\'')
        .join(', ');
    return 'UNIQUE constraint failed: $cols';
  }
}

/// A scope with [td] as source 0 (and optionally 'excluded' as source 1).
Scope tableScope(Planner pl, TableDef td, String alias, {bool excluded = false}) {
  final sc = Scope(null, null);
  SourceInfo mk(String a, int slot) {
    final s = SourceInfo(
        a,
        td.name,
        [for (final c in td.columns) c.name],
        [for (final c in td.columns) c.affinity],
        [for (final c in td.columns) c.coll],
        [for (final c in td.columns) c.kind == ZxColumnKind.json || c.kind == ZxColumnKind.array],
        [for (final c in td.columns) c.hidden],
        slot);
    s.rowidCol = td.columns.length;
    s.table = td;
    return s;
  }

  sc.sources.add(mk(alias, 0));
  if (excluded) {
    // Unqualified names refer to the target table.
    final ex = mk('excluded', 1);
    ex.usingHidden.addAll([for (final c in td.columns) c.name.toLowerCase()]);
    sc.sources.add(ex);
  }
  return sc;
}

class Dml {
  final ExecCtx ctx;
  final Planner pl;
  Dml(this.ctx) : pl = Planner(ctx);

  ZxDbException err(String m, [ZxDbError k = ZxDbError.generic]) =>
      ZxDbException(m, k);

  CteEnv? _ctes(WithClause? w) {
    if (w == null) return null;
    final env = CteEnv(null);
    for (final c in w.ctes) {
      env.defs[c.name.toLowerCase()] = CteDef(c.name, c.columns, c.select,
          w.recursive, env);
    }
    return env;
  }

  (List<Ev>, List<String>) _returning(List<ResultColumn> rc, Scope sc) {
    final evs = <Ev>[];
    final names = <String>[];
    for (final r in rc) {
      if (r.star) {
        final s = sc.sources[0];
        for (var k = 0; k < s.cols.length; k++) {
          evs.add(ColEv(0, 0, k)..aff = s.affs[k]);
          names.add(s.cols[k]);
        }
        continue;
      }
      evs.add(pl.compileTop(r.e!, sc));
      names.add(r.alias ?? (r.e is ColumnExpr ? (r.e as ColumnExpr).column : r.text));
    }
    return (evs, names);
  }

  // ---------------------------------------------------------- INSERT

  DmlResult insert(InsertStmt st) {
    final td = ctx.catalog.table(st.table);
    if (td == null) {
      if (ctx.catalog.view(st.table) != null) {
        throw err('cannot modify ${st.table} because it is a view');
      }
      final vt = ctx.env.findVtab(st.table, ctx.snap);
      if (vt != null) return _insertVtab(st, vt);
      throw err('no such table: ${st.table}');
    }
    final n = td.columns.length;
    // Column mapping.
    final targets = <int>[]; // column index, or n for the rowid
    if (st.columns != null) {
      for (final c in st.columns!) {
        var i = td.colIndex(c);
        if (i < 0 && td.isRowidName(c)) i = n;
        if (i < 0) throw err('table ${td.name} has no column named $c');
        targets.add(i == n && td.ipk >= 0 ? td.ipk : i);
      }
    } else {
      for (var i = 0; i < n; i++) {
        if (!td.columns[i].hidden) targets.add(i);
      }
    }
    // Source rows.
    List<List<Object?>> source;
    if (st.defaultValues) {
      source = [[]];
    } else {
      final plan = pl.planSelect(st.select!, null, _ctes(st.withClause));
      if (plan.columns.length != targets.length) {
        if (st.columns == null) {
          throw err('table ${td.name} has ${targets.length} columns but ${plan.columns.length} values were supplied');
        }
        throw err('${plan.columns.length} values for ${targets.length} columns');
      }
      source = drain(plan.open(null));
    }
    final w = TableWriter(ctx, pl, td);
    // Defaults evaluated per row (they may be CURRENT_TIMESTAMP).
    final emptyScope = Scope(null, null);
    final defEvs = [
      for (final c in td.columns)
        c.defaultExpr == null ? null : pl.compileTop(c.defaultExpr!, emptyScope)
    ];
    final ef = Frame(ctx, 0, null);
    // Upsert and RETURNING scopes.
    final alias = st.alias ?? td.name;
    Scope? upScope;
    final upSets = <List<(int, Ev)>>[];
    final upWhere = <Ev?>[];
    final upTargets = <List<int>?>[];
    if (st.upserts.isNotEmpty) {
      upScope = tableScope(pl, td, alias, excluded: true);
      for (var u = 0; u < st.upserts.length; u++) {
        final up = st.upserts[u];
        if (up.target == null && u != st.upserts.length - 1) {
          throw err('ON CONFLICT clause does not match any PRIMARY KEY or UNIQUE constraint');
        }
        List<int>? tcols;
        if (up.target != null) {
          tcols = [];
          for (final e in up.target!) {
            final x = e is CollateExpr ? e.e : e;
            if (x is! ColumnExpr) throw err('unsupported ON CONFLICT target');
            var i = td.colIndex(x.column);
            if (i < 0 && td.isRowidName(x.column)) i = td.ipk;
            if (i < 0) throw err('no such column: ${x.column}');
            tcols.add(i);
          }
          final ok = (tcols.length == 1 && tcols[0] == td.ipk && td.ipk >= 0) ||
              td.indexes.any((ix) =>
                  ix.unique &&
                  ix.where == null &&
                  ix.columns.length == tcols!.length &&
                  ix.columns.every((c) => tcols!.contains(c.col)));
          if (!ok) {
            throw err('ON CONFLICT clause does not match any PRIMARY KEY or UNIQUE constraint');
          }
        }
        upTargets.add(tcols);
        upSets.add(_compileSets(up.sets, td, upScope));
        upWhere.add(up.where == null ? null : pl.compileTop(up.where!, upScope));
      }
    }
    List<Ev>? retEvs;
    List<String> retNames = const [];
    if (st.returning != null) {
      final (e, nm) = _returning(st.returning!, tableScope(pl, td, alias));
      retEvs = e;
      retNames = nm;
    }
    final retRows = <List<Object?>>[];
    final rf = Frame(ctx, 2, null);
    var changes = 0;
    final defaults = pl.tableDefaults(td);

    int? upsertFor(int ixi) {
      // Which upsert clause handles a conflict on index ixi (-1: rowid).
      for (var u = 0; u < upTargets.length; u++) {
        final t = upTargets[u];
        if (t == null) return u;
        if (ixi < 0) {
          if (t.length == 1 && t[0] == td.ipk) return u;
          continue;
        }
        final ix = td.indexes[ixi];
        if (ix.columns.length == t.length && ix.columns.every((c) => t.contains(c.col))) {
          return u;
        }
      }
      return null;
    }

    for (final src in source) {
      final row = List<Object?>.filled(n + 1, null);
      final given = List<bool>.filled(n + 1, false);
      Object? explicitRowid;
      for (var k = 0; k < targets.length && k < src.length; k++) {
        final t = targets[k];
        if (t == n) {
          explicitRowid = src[k];
          given[n] = true;
        } else {
          row[t] = src[k];
          given[t] = true;
        }
      }
      for (var i = 0; i < n; i++) {
        if (!given[i]) row[i] = defEvs[i]?.eval(ef);
        if (i != td.ipk) row[i] = columnValue(td.columns[i], row[i], td.name);
      }
      // Rowid.
      Object? rv = td.ipk >= 0 ? row[td.ipk] : explicitRowid;
      int rowid;
      if (rv != null) {
        rv = applyAffinity(rv, Affinity.integer);
        if (rv is! int) throw const ZxDbException('datatype mismatch', ZxDbError.constraint);
        rowid = rv;
      } else {
        rowid = w.newRowid();
      }
      if (td.ipk >= 0) row[td.ipk] = rowid;
      row[n] = rowid;
      final or = st.orAction;
      if (!w.checkRow(row, or, defaults)) continue;
      // Rowid (primary key) conflict.
      var skip = false;
      final existing = w.rd.read(rowid);
      if (existing != null) {
        final u = upsertFor(-1);
        if (u != null) {
          _doUpsert(w, st.upserts[u], upSets[u], upWhere[u], existing, row, rf,
              retEvs, retRows);
          if (!st.upserts[u].doNothing) changes++;
          continue;
        }
        final mode = or ?? (td.ipk >= 0 ? td.columns[td.ipk].pkConflict : null) ?? 'ABORT';
        if (mode == 'IGNORE') continue;
        if (mode == 'REPLACE') {
          w.deleteRow(rowid, existing);
        } else {
          final name = td.ipk >= 0 ? '${td.name}.${td.columns[td.ipk].name}' : '${td.name}.rowid';
          w._fail(mode, 'UNIQUE constraint failed: $name');
        }
      }
      // Unique indexes.
      for (var i = 0; i < td.indexes.length && !skip; i++) {
        final ix = td.indexes[i];
        if (!ix.unique) continue;
        final kv = w.keyValues(i, row);
        if (kv == null) continue;
        final other = w.conflict(i, kv, rowid);
        if (other == null) continue;
        final u = upsertFor(i);
        if (u != null) {
          final ex = w.rd.read(other)!;
          _doUpsert(w, st.upserts[u], upSets[u], upWhere[u], ex, row, rf,
              retEvs, retRows);
          if (!st.upserts[u].doNothing) changes++;
          skip = true;
          break;
        }
        final mode = or ?? ix.conflict ?? 'ABORT';
        if (mode == 'IGNORE') {
          skip = true;
          break;
        }
        if (mode == 'REPLACE') {
          final ex = w.rd.read(other);
          if (ex != null) w.deleteRow(other, ex);
          continue;
        }
        w._fail(mode, w.uniqueMessage(i));
      }
      if (skip) continue;
      w.writeRow(rowid, row);
      w.noteRowid(rowid);
      ctx.lastRowid = rowid;
      changes++;
      if (retEvs != null) {
        rf.rows[0] = row;
        retRows.add([for (final e in retEvs) e.eval(rf)]);
      }
    }
    ctx.nChanges = changes;
    return DmlResult(changes, retNames, retRows);
  }

  List<(int, Ev)> _compileSets(List<SetClause> sets, TableDef td, Scope sc) {
    final out = <(int, Ev)>[];
    for (final s in sets) {
      if (s.columns.length != 1) {
        final v = s.value;
        if (v is RowExpr && v.items.length == s.columns.length) {
          for (var k = 0; k < s.columns.length; k++) {
            out.add((_setCol(td, s.columns[k]), pl.compileTop(v.items[k], sc)));
          }
          continue;
        }
        if (v is SubqueryExpr) {
          throw err('row value subqueries in SET are not supported', ZxDbError.unsupported);
        }
        throw err('${s.columns.length} columns assigned ${v is RowExpr ? v.items.length : 1} values');
      }
      out.add((_setCol(td, s.columns[0]), pl.compileTop(s.value, sc)));
    }
    return out;
  }

  int _setCol(TableDef td, String c) {
    var i = td.colIndex(c);
    if (i < 0 && td.isRowidName(c)) i = td.columns.length;
    if (i < 0) throw err('no such column: $c');
    return i;
  }

  void _doUpsert(TableWriter w, Upsert up, List<(int, Ev)> sets, Ev? where,
      List<Object?> existing, List<Object?> proposed, Frame rf,
      List<Ev>? retEvs, List<List<Object?>> retRows) {
    if (up.doNothing) return;
    rf.rows[0] = existing;
    rf.rows[1] = proposed;
    if (where != null && truth(where.eval(rf)) != true) return;
    final td = w.td;
    final n = td.columns.length;
    final newRow = List<Object?>.of(existing);
    for (final (col, ev) in sets) {
      final v = ev.eval(rf);
      if (col == n) {
        newRow[n] = v;
        if (td.ipk >= 0) newRow[td.ipk] = v;
      } else {
        newRow[col] = col == td.ipk ? v : columnValue(td.columns[col], v, td.name);
      }
    }
    _updateRow(w, existing[n] as int, existing, newRow, null);
    if (retEvs != null) {
      rf.rows[0] = newRow;
      retRows.add([for (final e in retEvs) e.eval(rf)]);
    }
  }

  /// Applies an update; returns false when skipped (IGNORE).
  bool _updateRow(TableWriter w, int oldRowid, List<Object?> oldRow,
      List<Object?> newRow, String? or) {
    final td = w.td;
    final n = td.columns.length;
    var nr = td.ipk >= 0 ? newRow[td.ipk] : newRow[n];
    nr = applyAffinity(nr, Affinity.integer);
    if (nr == null && td.ipk >= 0) {
      throw _constraint('NOT NULL constraint failed: ${td.name}.${td.columns[td.ipk].name}');
    }
    if (nr is! int) throw const ZxDbException('datatype mismatch', ZxDbError.constraint);
    final newRowid = nr;
    if (td.ipk >= 0) newRow[td.ipk] = newRowid;
    newRow[n] = newRowid;
    if (!w.checkRow(newRow, or, w.pl.tableDefaults(td))) return false;
    if (newRowid != oldRowid) {
      final ex = w.rd.read(newRowid);
      if (ex != null) {
        final mode = or ?? 'ABORT';
        if (mode == 'IGNORE') return false;
        if (mode == 'REPLACE') {
          w.deleteRow(newRowid, ex);
        } else {
          w._fail(mode, 'UNIQUE constraint failed: ${td.name}.${td.ipk >= 0 ? td.columns[td.ipk].name : 'rowid'}');
        }
      }
    }
    for (var i = 0; i < td.indexes.length; i++) {
      final ix = td.indexes[i];
      if (!ix.unique) continue;
      final kv = w.keyValues(i, newRow);
      if (kv == null) continue;
      var other = w.conflict(i, kv, newRowid);
      if (other == oldRowid) other = null;
      if (other == null) continue;
      final mode = or ?? ix.conflict ?? 'ABORT';
      if (mode == 'IGNORE') return false;
      if (mode == 'REPLACE') {
        final ex = w.rd.read(other);
        if (ex != null) w.deleteRow(other, ex);
        continue;
      }
      w._fail(mode, w.uniqueMessage(i));
    }
    w.deleteRow(oldRowid, oldRow);
    w.writeRow(newRowid, newRow);
    w.noteRowid(newRowid);
    return true;
  }

  // ---------------------------------------------------------- UPDATE

  DmlResult update(UpdateStmt st) {
    final td = ctx.catalog.table(st.table);
    if (td == null) {
      final vt = ctx.env.findVtab(st.table, ctx.snap);
      if (vt != null) return _updateVtab(st, vt);
      if (ctx.catalog.view(st.table) != null) {
        throw err('cannot modify ${st.table} because it is a view');
      }
      throw err('no such table: ${st.table}');
    }
    final alias = st.alias ?? td.name;
    final n = td.columns.length;
    late List<int> cols;
    final scan = pl.planDmlScan(td, alias, st.where, st.from, (sc) {
      final sets = _compileSets(st.sets, td, sc);
      cols = [for (final s in sets) s.$1];
      sc.sources[0].used.add(sc.sources[0].rowidCol);
      return [
        ColEv(0, 0, sc.sources[0].rowidCol)..aff = Affinity.integer,
        for (final s in sets) s.$2,
      ];
    }, _ctes(st.withClause));
    final hits = drain(scan());
    final w = TableWriter(ctx, pl, td);
    List<Ev>? retEvs;
    List<String> retNames = const [];
    if (st.returning != null) {
      final (e, nm) = _returning(st.returning!, tableScope(pl, td, alias));
      retEvs = e;
      retNames = nm;
    }
    final rf = Frame(ctx, 1, null);
    final retRows = <List<Object?>>[];
    var changes = 0;
    final seen = <int>{};
    for (final h in hits) {
      final rowid = h[0] as int;
      if (!seen.add(rowid)) continue;
      final old = w.rd.read(rowid);
      if (old == null) continue;
      final nw = List<Object?>.of(old);
      for (var k = 0; k < cols.length; k++) {
        final c = cols[k];
        final v = h[k + 1];
        if (c == n) {
          nw[n] = v;
          if (td.ipk >= 0) nw[td.ipk] = v;
        } else if (c == td.ipk) {
          nw[c] = v;
          nw[n] = v;
        } else {
          nw[c] = columnValue(td.columns[c], v, td.name);
        }
      }
      if (!_updateRow(w, rowid, old, nw, st.orAction)) continue;
      changes++;
      if (retEvs != null) {
        rf.rows[0] = nw;
        retRows.add([for (final e in retEvs) e.eval(rf)]);
      }
    }
    ctx.nChanges = changes;
    return DmlResult(changes, retNames, retRows);
  }

  // ---------------------------------------------------------- DELETE

  DmlResult delete(DeleteStmt st) {
    final td = ctx.catalog.table(st.table);
    if (td == null) {
      final vt = ctx.env.findVtab(st.table, ctx.snap);
      if (vt != null) return _deleteVtab(st, vt);
      if (ctx.catalog.view(st.table) != null) {
        throw err('cannot modify ${st.table} because it is a view');
      }
      throw err('no such table: ${st.table}');
    }
    final alias = st.alias ?? td.name;
    final w = TableWriter(ctx, pl, td);
    List<Ev>? retEvs;
    List<String> retNames = const [];
    if (st.returning != null) {
      final (e, nm) = _returning(st.returning!, tableScope(pl, td, alias));
      retEvs = e;
      retNames = nm;
    }
    // Fast path: DELETE without WHERE on a table without RETURNING.
    if (st.where == null && retEvs == null) {
      final count = w.tree.length;
      w.tree.deleteRange();
      for (final t in w.itrees) {
        t.deleteRange();
      }
      ctx.nChanges = count;
      return DmlResult(count);
    }
    final scan = pl.planDmlScan(td, alias, st.where, null, (sc) {
      sc.sources[0].used.add(sc.sources[0].rowidCol);
      return [ColEv(0, 0, sc.sources[0].rowidCol)..aff = Affinity.integer];
    }, _ctes(st.withClause));
    final hits = drain(scan());
    final rf = Frame(ctx, 1, null);
    final retRows = <List<Object?>>[];
    var changes = 0;
    for (final h in hits) {
      final rowid = h[0] as int;
      final old = w.rd.read(rowid);
      if (old == null) continue;
      if (retEvs != null) {
        rf.rows[0] = old;
        retRows.add([for (final e in retEvs) e.eval(rf)]);
      }
      w.deleteRow(rowid, old);
      changes++;
    }
    ctx.nChanges = changes;
    return DmlResult(changes, retNames, retRows);
  }

  // ---------------------------------------------------------- vtabs

  ZxWritableVirtualTable _writable(ZxVirtualTable vt, String name) {
    if (vt is! ZxWritableVirtualTable) {
      throw err('table $name may not be modified', ZxDbError.readOnly);
    }
    return vt;
  }

  ZxVtabContext get _vctx =>
      ZxVtabContext(ctx.txn ?? ctx.snap, ctx.txn, ctx.nowNs);

  static ZxConflictMode _mode(String? or) {
    switch (or) {
      case 'REPLACE':
        return ZxConflictMode.replace;
      case 'IGNORE':
        return ZxConflictMode.ignore;
      case 'FAIL':
        return ZxConflictMode.fail;
      case 'ROLLBACK':
        return ZxConflictMode.rollback;
    }
    return ZxConflictMode.abort;
  }

  DmlResult _insertVtab(InsertStmt st, ZxVirtualTable vt0) {
    final vt = _writable(vt0, st.table);
    final cols = vt.columns;
    final n = cols.length;
    final targets = <int>[];
    if (st.columns != null) {
      for (final c in st.columns!) {
        final i = cols.indexWhere((x) => x.name.toLowerCase() == c.toLowerCase());
        final isRowid = i < 0 && ['rowid', 'oid', '_rowid_'].contains(c.toLowerCase());
        if (i < 0 && !isRowid) throw err('table ${st.table} has no column named $c');
        targets.add(i < 0 ? n : i);
      }
    } else {
      for (var i = 0; i < n; i++) {
        if (!cols[i].hidden) targets.add(i);
      }
    }
    List<List<Object?>> source;
    if (st.defaultValues) {
      source = [[]];
    } else {
      final plan = pl.planSelect(st.select!, null, _ctes(st.withClause));
      if (plan.columns.length != targets.length) {
        throw err('${plan.columns.length} values for ${targets.length} columns');
      }
      source = drain(plan.open(null));
    }
    // Upsert support through findConflict.
    final affs = [for (final c in cols) affinityOfType(c.type)];
    Scope? upScope;
    final upSets = <List<(int, Ev)>>[];
    final upWhere = <Ev?>[];
    if (st.upserts.isNotEmpty) {
      upScope = Scope(null, null);
      SourceInfo mk(String a, int slot) {
        final s = SourceInfo(a, st.table, [for (final c in cols) c.name], affs,
            List.filled(n, null), List.filled(n, false), List.filled(n, false), slot);
        s.rowidCol = n;
        return s;
      }

      upScope.sources.add(mk(st.alias ?? st.table, 0));
      upScope.sources.add(mk('excluded', 1)
        ..usingHidden.addAll([for (final c in cols) c.name.toLowerCase()]));
      for (final up in st.upserts) {
        final sets = <(int, Ev)>[];
        for (final s in up.sets) {
          for (final c in s.columns) {
            final i = cols.indexWhere((x) => x.name.toLowerCase() == c.toLowerCase());
            if (i < 0) throw err('no such column: $c');
            sets.add((i, pl.compileTop(s.value, upScope)));
          }
        }
        upSets.add(sets);
        upWhere.add(up.where == null ? null : pl.compileTop(up.where!, upScope));
      }
    }
    final vc = _vctx;
    final rf = Frame(ctx, 2, null);
    var changes = 0;
    for (final src in source) {
      final row = List<Object?>.filled(n, null);
      int? rowid;
      for (var k = 0; k < targets.length; k++) {
        if (targets[k] == n) {
          rowid = toInt(src[k]);
        } else {
          row[targets[k]] = applyAffinity(src[k], affs[targets[k]]);
        }
      }
      if (st.upserts.isNotEmpty) {
        final c = vt.findConflict(vc, row);
        if (c != null) {
          final up = st.upserts[0];
          if (up.doNothing) continue;
          rf.rows[0] = [...c.$2, c.$1];
          rf.rows[1] = [...row, null];
          if (upWhere[0] != null && truth(upWhere[0]!.eval(rf)) != true) continue;
          final nw = List<Object?>.of(c.$2);
          for (final (i, ev) in upSets[0]) {
            nw[i] = applyAffinity(ev.eval(rf), affs[i]);
          }
          vt.update(vc, c.$1, nw);
          changes++;
          continue;
        }
      }
      final mode = _mode(st.orAction);
      try {
        final r = vt.insertOr(vc, rowid, row, mode);
        if (r == null) continue;
        ctx.lastRowid = r;
      } on ZxDbException catch (e) {
        if (mode == ZxConflictMode.rollback && e.kind == ZxDbError.constraint) {
          throw RollbackSignal(e);
        }
        rethrow;
      }
      changes++;
    }
    ctx.nChanges = changes;
    return DmlResult(changes);
  }

  List<List<Object?>> _vtabScan(String table, String? alias, Expr? where,
      List<SetClause> sets, List<ZxVtabColumn> cols) {
    // SELECT rowid, <all columns with SET values> FROM table WHERE ...
    final n = cols.length;
    final setMap = <int, Expr>{};
    for (final s in sets) {
      for (var k = 0; k < s.columns.length; k++) {
        final i = cols.indexWhere((x) => x.name.toLowerCase() == s.columns[k].toLowerCase());
        if (i < 0) throw err('no such column: ${s.columns[k]}');
        final v = s.value;
        setMap[i] = s.columns.length == 1 ? v : (v as RowExpr).items[k];
      }
    }
    final q = alias ?? table;
    final rcs = <ResultColumn>[
      ResultColumn(ColumnExpr(q, 'rowid'), null, 'rowid'),
      for (var i = 0; i < n; i++)
        ResultColumn(setMap[i] ?? ColumnExpr(q, cols[i].name), null, cols[i].name),
    ];
    final core = SelectCore(false, rcs, [JoinItem('', TableSource(table, alias))],
        where, const [], null);
    final plan = pl.planSelect(SelectStmt(null, core, const [], null, null), null, null);
    return drain(plan.open(null));
  }

  DmlResult _updateVtab(UpdateStmt st, ZxVirtualTable vt0) {
    final vt = _writable(vt0, st.table);
    final cols = vt.columns;
    final affs = [for (final c in cols) affinityOfType(c.type)];
    final rows = _vtabScan(st.table, st.alias, st.where, st.sets, cols);
    final vc = _vctx;
    final mode = _mode(st.orAction);
    var changes = 0;
    for (final r in rows) {
      final vals = [for (var i = 0; i < cols.length; i++) applyAffinity(r[i + 1], affs[i])];
      if (vt.updateOr(vc, r[0] as int, vals, mode)) changes++;
    }
    ctx.nChanges = changes;
    return DmlResult(changes);
  }

  DmlResult _deleteVtab(DeleteStmt st, ZxVirtualTable vt0) {
    final vt = _writable(vt0, st.table);
    final rows = _vtabScan(st.table, st.alias, st.where, const [], vt.columns);
    final vc = _vctx;
    for (final r in rows) {
      vt.delete(vc, r[0] as int);
    }
    ctx.nChanges = rows.length;
    return DmlResult(rows.length);
  }
}
