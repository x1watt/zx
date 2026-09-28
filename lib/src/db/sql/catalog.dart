// The SQL catalog: tables, indexes and views, stored in the tree
// "sql:catalog".
//
// Catalog tree layout (keys are UTF-8):
//   <lower case name>   record [type, name, tbl_name, sql, tree, options]
//                       type: 'table', 'index', 'view'; sql is the
//                       canonical CREATE statement (null for automatic
//                       indexes of PRIMARY KEY / UNIQUE constraints); tree
//                       is the name of the storage tree; options is JSON
//                       text of the WITH (...) options.
//   \x00version         record [n]: bumped by every schema change
//   \x00user_version    record [n]: PRAGMA user_version
//   \x00seq:<table>     record [n]: AUTOINCREMENT high water mark
//
// Table rows live in tree "t:<name>" (key: rowid, value: record of the
// column values), index entries in "i:<index name>" (key: the indexed
// values then the rowid, value: empty). Tree names are chosen at creation
// and kept by ALTER TABLE ... RENAME (the catalog maps names to trees), so
// a rename is O(1).

import 'dart:convert';
import 'dart:typed_data';

import '../record.dart';
import '../storage_api.dart';
import 'ast.dart';
import 'parser.dart';
import 'value.dart';

const String catalogTree = 'sql:catalog';

class ColumnDef {
  String name;
  final String? type;
  final Affinity affinity;
  final ZxColumnKind kind;
  final bool notNull;
  final String? notNullConflict;
  final bool pk;
  final Expr? defaultExpr;
  final String? collation;
  final Expr? generated;
  final bool hidden;
  final List<Expr> checks; // column CHECK constraints
  final bool unique;
  final String? uniqueConflict;
  final bool pkDesc;
  final String? pkConflict;
  final bool autoincrement;

  ColumnDef(this.name, this.type,
      {this.notNull = false,
      this.notNullConflict,
      this.pk = false,
      this.defaultExpr,
      this.collation,
      this.generated,
      this.hidden = false,
      this.checks = const [],
      this.unique = false,
      this.uniqueConflict,
      this.pkDesc = false,
      this.pkConflict,
      this.autoincrement = false})
      : affinity = affinityOfType(type),
        kind = kindOfType(type);

  Collation? get coll => collation == null ? null : collationByName(collation!);
}

class IndexColumn {
  /// Table column index, or -1 for an expression.
  final int col;
  final Expr? expr;
  final bool desc;
  final String? collation;
  const IndexColumn(this.col, this.expr, this.desc, this.collation);
}

class IndexDef {
  String name;
  String table;
  final List<IndexColumn> columns;
  final bool unique;
  final Expr? where;
  String treeName;

  /// 'index' (CREATE INDEX), 'pk' or 'unique' (automatic).
  final String origin;
  final String? conflict;
  IndexDef(this.name, this.table, this.columns, this.unique, this.where,
      this.treeName, this.origin, this.conflict);

  bool get auto => origin != 'index';
  List<bool> get descs => [for (final c in columns) c.desc];
}

class TableDef {
  String name;
  final List<ColumnDef> columns;

  /// Index of the INTEGER PRIMARY KEY column (the rowid alias), or -1.
  int ipk;
  bool autoincrement;
  final List<Expr> checks;
  final List<IndexDef> indexes = [];
  String treeName;
  Map<String, Object?> options;
  final bool withoutRowid;
  final bool strict;

  /// Primary key columns when the key is not the rowid (a UNIQUE
  /// automatic index enforces it).
  List<int> pkColumns;

  TableDef(this.name, this.columns, this.ipk, this.autoincrement, this.checks,
      this.treeName, this.options, this.pkColumns,
      {this.withoutRowid = false, this.strict = false});

  int colIndex(String n) {
    final l = n.toLowerCase();
    for (var i = 0; i < columns.length; i++) {
      if (columns[i].name.toLowerCase() == l) return i;
    }
    return -1;
  }

  /// True for the names that refer to the rowid (when no column has them).
  bool isRowidName(String n) {
    final l = n.toLowerCase();
    return (l == 'rowid' || l == 'oid' || l == '_rowid_') && colIndex(n) < 0;
  }
}

class ViewDef {
  String name;
  final List<String>? columns;
  final SelectStmt select;
  final String sql;
  ViewDef(this.name, this.columns, this.select, this.sql);
}

/// Parsed catalog (cached per schema version).
class Catalog {
  final Map<String, TableDef> tables = {};
  final Map<String, IndexDef> indexes = {};
  final Map<String, ViewDef> views = {};
  int version = 0;

  TableDef? table(String name) => tables[name.toLowerCase()];
  ViewDef? view(String name) => views[name.toLowerCase()];
  IndexDef? index(String name) => indexes[name.toLowerCase()];

  bool nameTaken(String name) {
    final l = name.toLowerCase();
    return tables.containsKey(l) ||
        indexes.containsKey(l) ||
        views.containsKey(l);
  }

  static Uint8List _key(String s) => Uint8List.fromList(utf8.encode(s));

  static int readVersion(ZxSnapshot s) {
    final t = s.tree(catalogTree);
    if (t == null) return 0;
    final v = t.get(_key('\u0000version'));
    if (v == null) return 0;
    return decodeRecord(v)[0] as int;
  }

  static int readInt(ZxSnapshot s, String key) {
    final t = s.tree(catalogTree);
    if (t == null) return 0;
    final v = t.get(_key('\u0000$key'));
    if (v == null) return 0;
    return decodeRecord(v)[0] as int;
  }

  static void writeInt(ZxWriteTxn txn, String key, int value) {
    final t = txn.tree(catalogTree) ?? txn.createTree(catalogTree);
    t.put(_key('\u0000$key'), encodeRecord([value]));
  }

  static void deleteInt(ZxWriteTxn txn, String key) {
    txn.tree(catalogTree)?.delete(_key('\u0000$key'));
  }

  /// Loads the catalog from a snapshot.
  static Catalog load(ZxSnapshot s) {
    final c = Catalog();
    final t = s.tree(catalogTree);
    if (t == null) return c;
    final recs = <List<Object?>>[];
    final cur = t.scan();
    try {
      while (cur.moveNext()) {
        final k = cur.key;
        if (k.isNotEmpty && k[0] == 0) {
          if (utf8.decode(k) == '\u0000version') {
            c.version = decodeRecord(cur.value)[0] as int;
          }
          continue;
        }
        recs.add(decodeRecord(cur.value));
      }
    } finally {
      cur.close();
    }
    final autoTrees = <String, String>{};
    for (final r in recs) {
      final type = r[0] as String;
      final sql = r[3] as String?;
      final tree = r[4] as String?;
      switch (type) {
        case 'table':
          final st = Parser.parse(sql!).statements.single as CreateTableStmt;
          final td = buildTableDef(st, tree!);
          c.tables[td.name.toLowerCase()] = td;
        case 'view':
          final st = Parser.parse(sql!).statements.single as CreateViewStmt;
          c.views[st.name.toLowerCase()] =
              ViewDef(st.name, st.columns, st.select, sql);
        case 'index':
          if (sql == null) autoTrees[(r[1] as String).toLowerCase()] = tree!;
      }
    }
    for (final td in c.tables.values) {
      for (final ix in td.indexes) {
        final tr = autoTrees[ix.name.toLowerCase()];
        if (tr != null) ix.treeName = tr;
        c.indexes[ix.name.toLowerCase()] = ix;
      }
    }
    for (final r in recs) {
      if (r[0] == 'index' && r[3] != null) {
        final st = Parser.parse(r[3] as String).statements.single
            as CreateIndexStmt;
        final td = c.table(st.table);
        if (td == null) continue;
        final ix = buildIndexDef(st, td, r[4] as String);
        td.indexes.add(ix);
        c.indexes[ix.name.toLowerCase()] = ix;
      }
    }
    return c;
  }

  // ---------------------------------------------------------- writing

  static void bumpVersion(ZxWriteTxn txn) {
    final t = txn.tree(catalogTree) ?? txn.createTree(catalogTree);
    final k = _key('\u0000version');
    final v = t.get(k);
    final n = v == null ? 0 : decodeRecord(v)[0] as int;
    t.put(k, encodeRecord([n + 1]));
  }

  static void putTable(ZxWriteTxn txn, TableDef td) {
    final t = txn.tree(catalogTree) ?? txn.createTree(catalogTree);
    t.put(
        _key(td.name.toLowerCase()),
        encodeRecord([
          'table',
          td.name,
          td.name,
          tableSql(td),
          td.treeName,
          jsonEncode(td.options),
        ]));
    for (final ix in td.indexes) {
      if (ix.auto) putIndex(txn, ix, null);
    }
  }

  static void putIndex(ZxWriteTxn txn, IndexDef ix, String? sql) {
    final t = txn.tree(catalogTree) ?? txn.createTree(catalogTree);
    t.put(_key(ix.name.toLowerCase()),
        encodeRecord(['index', ix.name, ix.table, sql, ix.treeName, null]));
  }

  static void putView(ZxWriteTxn txn, ViewDef v) {
    final t = txn.tree(catalogTree) ?? txn.createTree(catalogTree);
    t.put(_key(v.name.toLowerCase()),
        encodeRecord(['view', v.name, v.name, v.sql, null, null]));
  }

  static void remove(ZxWriteTxn txn, String name) {
    txn.tree(catalogTree)?.delete(_key(name.toLowerCase()));
  }

  /// All catalog rows (for sqlite_schema): type, name, tbl_name, sql.
  static List<List<Object?>> schemaRows(ZxSnapshot s) {
    final out = <List<Object?>>[];
    final t = s.tree(catalogTree);
    if (t == null) return out;
    final cur = t.scan();
    try {
      while (cur.moveNext()) {
        if (cur.key.isNotEmpty && cur.key[0] == 0) continue;
        final r = decodeRecord(cur.value);
        out.add([r[0], r[1], r[2], r[3], r[4]]);
      }
    } finally {
      cur.close();
    }
    return out;
  }

  /// Canonical CREATE INDEX text of a user index.
  static String indexSql(IndexDef ix, TableDef td) {
    final cols = ix.columns.map((c) {
      var s = c.col >= 0 ? quoteIdent(td.columns[c.col].name) : exprToSql(c.expr!);
      if (c.collation != null) s = '$s COLLATE ${c.collation}';
      if (c.desc) s = '$s DESC';
      return s;
    }).join(', ');
    final w = ix.where == null ? '' : ' WHERE ${exprToSql(ix.where!)}';
    return 'CREATE ${ix.unique ? 'UNIQUE ' : ''}INDEX ${quoteIdent(ix.name)} '
        'ON ${quoteIdent(td.name)} ($cols)$w';
  }
}

/// Picks a free tree name (base, base#2, base#3...).
String freeTreeName(ZxSnapshot s, String base) {
  final names = s.treeNames.toSet();
  if (!names.contains(base)) return base;
  var i = 2;
  while (names.contains('$base#$i')) {
    i++;
  }
  return '$base#$i';
}

/// Builds a table definition from CREATE TABLE.
TableDef buildTableDef(CreateTableStmt st, String treeName) {
  final cols = <ColumnDef>[];
  final seen = <String>{};
  var pkCount = 0;
  for (final c in st.columns) {
    if (!seen.add(c.name.toLowerCase())) {
      throw ZxDbException('duplicate column name: ${c.name}');
    }
    var notNull = false, pk = false, unique = false, pkDesc = false;
    var auto = false;
    String? nnConf, uConf, pkConf, coll;
    Expr? def, gen;
    final checks = <Expr>[];
    for (final k in c.constraints) {
      switch (k.kind) {
        case 'PK':
          pk = true;
          pkDesc = k.desc;
          auto = k.autoincrement;
          pkConf = k.conflict;
          pkCount++;
        case 'NOTNULL':
          notNull = true;
          nnConf = k.conflict;
        case 'UNIQUE':
          unique = true;
          uConf = k.conflict;
        case 'DEFAULT':
          def = k.expr;
        case 'CHECK':
          checks.add(k.expr!);
        case 'COLLATE':
          coll = k.collation;
          collationByName(coll!);
        case 'GENERATED':
          gen = k.expr;
      }
    }
    cols.add(ColumnDef(c.name, c.type,
        notNull: notNull,
        notNullConflict: nnConf,
        pk: pk,
        defaultExpr: def,
        collation: coll,
        generated: gen,
        checks: checks,
        unique: unique,
        uniqueConflict: uConf,
        pkDesc: pkDesc,
        pkConflict: pkConf,
        autoincrement: auto));
  }
  if (cols.isEmpty) throw const ZxDbException('a table needs at least one column');
  final tableChecks = <Expr>[];
  List<IndexedColumn>? pkCols;
  String? pkConflict;
  final uniques = <(List<IndexedColumn>, String?)>[];
  for (final tc in st.constraints) {
    switch (tc.kind) {
      case 'PK':
        pkCols = tc.columns;
        pkConflict = tc.conflict;
        pkCount++;
      case 'UNIQUE':
        uniques.add((tc.columns, tc.conflict));
      case 'CHECK':
        tableChecks.add(tc.check!);
    }
  }
  if (pkCount > 1) {
    throw ZxDbException('table "${st.name}" has more than one primary key');
  }
  var ipk = -1;
  var autoinc = false;
  List<int> pkColumns = [];
  int colOf(IndexedColumn ic) {
    final e = ic.e;
    if (e is! ColumnExpr || e.table != null) {
      throw const ZxDbException(
          'expressions prohibited in PRIMARY KEY and UNIQUE constraints');
    }
    for (var i = 0; i < cols.length; i++) {
      if (cols[i].name.toLowerCase() == e.column.toLowerCase()) return i;
    }
    throw ZxDbException('no such column: ${e.column}');
  }

  for (var i = 0; i < cols.length; i++) {
    if (cols[i].pk) {
      pkColumns = [i];
      final t = (cols[i].type ?? '').toUpperCase();
      if (t == 'INTEGER' && !cols[i].pkDesc) {
        ipk = i;
        autoinc = cols[i].autoincrement;
      } else if (cols[i].autoincrement) {
        throw const ZxDbException(
            'AUTOINCREMENT is only allowed on an INTEGER PRIMARY KEY');
      }
      pkConflict = cols[i].pkConflict;
    }
  }
  if (pkCols != null) {
    pkColumns = [for (final c in pkCols) colOf(c)];
    if (pkColumns.length == 1 &&
        (cols[pkColumns[0]].type ?? '').toUpperCase() == 'INTEGER' &&
        !pkCols[0].desc) {
      ipk = pkColumns[0];
    }
  }
  final td = TableDef(st.name, cols, ipk, autoinc, tableChecks, treeName,
      Map.of(st.options), pkColumns,
      withoutRowid: st.withoutRowid, strict: st.strict);
  // Automatic indexes, in SQLite's numbering order: primary key first when
  // declared on a column, then column UNIQUEs, then table constraints.
  var n = 0;
  String autoName() => 'sqlite_autoindex_${st.name}_${++n}';
  void addAuto(List<int> colIdx, List<bool> desc, List<String?> colls,
      String origin, String? conflict) {
    // Skip duplicates of an existing automatic index.
    for (final ix in td.indexes) {
      if (ix.columns.length == colIdx.length &&
          [for (var i = 0; i < colIdx.length; i++) ix.columns[i].col == colIdx[i]]
              .every((x) => x)) {
        return;
      }
    }
    final name = autoName();
    td.indexes.add(IndexDef(
        name,
        st.name,
        [
          for (var i = 0; i < colIdx.length; i++)
            IndexColumn(colIdx[i], null, desc[i],
                colls[i] ?? td.columns[colIdx[i]].collation)
        ],
        true,
        null,
        'i:${name.toLowerCase()}',
        origin,
        conflict));
  }

  final pkOnColumn = cols.any((c) => c.pk);
  if (ipk < 0 && pkColumns.isNotEmpty && pkOnColumn) {
    addAuto(pkColumns, [cols[pkColumns[0]].pkDesc], [null], 'pk', pkConflict);
  }
  for (var i = 0; i < cols.length; i++) {
    if (cols[i].unique && i != ipk) {
      addAuto([i], [false], [null], 'unique', cols[i].uniqueConflict);
    }
  }
  if (ipk < 0 && pkColumns.isNotEmpty && !pkOnColumn) {
    addAuto(pkColumns, [for (final c in pkCols!) c.desc],
        [for (final c in pkCols) c.collation], 'pk', pkConflict);
  }
  for (final u in uniques) {
    final idx = [for (final c in u.$1) colOf(c)];
    if (idx.length == 1 && idx[0] == ipk) continue;
    addAuto(idx, [for (final c in u.$1) c.desc],
        [for (final c in u.$1) c.collation], 'unique', u.$2);
  }
  return td;
}

/// Builds an index definition from CREATE INDEX.
IndexDef buildIndexDef(CreateIndexStmt st, TableDef td, String treeName) {
  final cols = <IndexColumn>[];
  for (final ic in st.columns) {
    final e = ic.e;
    if (e is ColumnExpr && e.table == null) {
      var i = td.colIndex(e.column);
      if (i < 0 && td.isRowidName(e.column)) {
        throw ZxDbException('cannot index the rowid: ${e.column}');
      }
      if (i < 0) throw ZxDbException('no such column: ${e.column}');
      cols.add(IndexColumn(i, null, ic.desc, ic.collation ?? td.columns[i].collation));
    } else if (e is LitExpr && e.value is String) {
      // SQLite accepts a string literal naming a column.
      final i = td.colIndex(e.value as String);
      if (i < 0) throw ZxDbException('no such column: ${e.value}');
      cols.add(IndexColumn(i, null, ic.desc, ic.collation ?? td.columns[i].collation));
    } else {
      cols.add(IndexColumn(-1, e, ic.desc, ic.collation));
    }
  }
  return IndexDef(st.name, td.name, cols, st.unique, st.where, treeName,
      'index', null);
}

// ------------------------------------------------------------ SQL text

final RegExp _plainIdent = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

String quoteIdent(String s) {
  if (_plainIdent.hasMatch(s) && !_sqlKeywords.contains(s.toUpperCase())) {
    return s;
  }
  return '"${s.replaceAll('"', '""')}"';
}

const Set<String> _sqlKeywords = {
  'ADD', 'ALL', 'ALTER', 'AND', 'AS', 'ASC', 'BETWEEN', 'BY', 'CASE', //
  'CHECK', 'COLLATE', 'COLUMN', 'COMMIT', 'CONSTRAINT', 'CREATE', 'CROSS', //
  'DEFAULT', 'DELETE', 'DESC', 'DISTINCT', 'DROP', 'ELSE', 'END', //
  'ESCAPE', 'EXCEPT', 'EXISTS', 'FROM', 'FULL', 'GLOB', 'GROUP', //
  'HAVING', 'IN', 'INDEX', 'INNER', 'INSERT', 'INTERSECT', 'INTO', 'IS', //
  'ISNULL', 'JOIN', 'KEY', 'LEFT', 'LIKE', 'LIMIT', 'MATCH', 'NATURAL', //
  'NOT', 'NOTNULL', 'NULL', 'OFFSET', 'ON', 'OR', 'ORDER', 'OUTER', //
  'PRIMARY', 'REFERENCES', 'REGEXP', 'RETURNING', 'RIGHT', 'SELECT', //
  'SET', 'TABLE', 'THEN', 'TO', 'UNION', 'UNIQUE', 'UPDATE', 'USING', //
  'VALUES', 'WHEN', 'WHERE', 'WINDOW', 'WITH', 'INDEXED', 'ROLLBACK', //
  'BEGIN', 'OVER', 'FILTER', 'TRUE', 'FALSE', 'CAST', 'CURRENT_TIME', //
  'CURRENT_DATE', 'CURRENT_TIMESTAMP', 'RAISE',
};

String _lit(Object? v) {
  if (v is double) {
    final s = realToText(v);
    return s;
  }
  return quoteValue(v);
}

/// SQL text of an expression (for stored DEFAULT / CHECK / index terms).
String exprToSql(Expr e) {
  if (e is LitExpr) return _lit(e.value);
  if (e is CurrentTimeExpr) return e.kind;
  if (e is ParamExpr) return e.name ?? '?${e.index}';
  if (e is ColumnExpr) {
    return e.table == null
        ? quoteIdent(e.column)
        : '${quoteIdent(e.table!)}.${quoteIdent(e.column)}';
  }
  if (e is UnaryExpr) {
    if (e.op == 'NOT') return 'NOT ${_paren(e.e)}';
    return '${e.op}${_paren(e.e)}';
  }
  if (e is BinaryExpr) return '${_paren(e.l)} ${e.op} ${_paren(e.r)}';
  if (e is LikeExpr) {
    final esc = e.escape == null ? '' : ' ESCAPE ${_paren(e.escape!)}';
    return '${_paren(e.e)} ${e.not ? 'NOT ' : ''}${e.op} ${_paren(e.pattern)}$esc';
  }
  if (e is BetweenExpr) {
    return '${_paren(e.e)} ${e.not ? 'NOT ' : ''}BETWEEN ${_paren(e.lo)} AND ${_paren(e.hi)}';
  }
  if (e is InListExpr) {
    return '${_paren(e.e)} ${e.not ? 'NOT ' : ''}IN (${e.list.map(exprToSql).join(', ')})';
  }
  if (e is IsNullExpr) return '${_paren(e.e)} ${e.not ? 'NOTNULL' : 'ISNULL'}';
  if (e is CaseExpr) {
    final b = StringBuffer('CASE');
    if (e.base != null) b.write(' ${exprToSql(e.base!)}');
    for (final w in e.whens) {
      b.write(' WHEN ${exprToSql(w.$1)} THEN ${exprToSql(w.$2)}');
    }
    if (e.orElse != null) b.write(' ELSE ${exprToSql(e.orElse!)}');
    b.write(' END');
    return b.toString();
  }
  if (e is CastExpr) return 'CAST(${exprToSql(e.e)} AS ${e.type})';
  if (e is CollateExpr) return '${_paren(e.e)} COLLATE ${e.collation}';
  if (e is FuncExpr) {
    if (e.star) return '${e.name}(*)';
    return '${e.name}(${e.distinct ? 'DISTINCT ' : ''}${e.args.map(exprToSql).join(', ')})';
  }
  if (e is RowExpr) return '(${e.items.map(exprToSql).join(', ')})';
  if (e is SubqueryExpr) return '(${e.select.sql})';
  if (e is ExistsExpr) return 'EXISTS (${e.select.sql})';
  if (e is InSelectExpr) {
    return '${_paren(e.e)} ${e.not ? 'NOT ' : ''}IN (${e.select.sql})';
  }
  throw ZxDbException('cannot render expression ${e.runtimeType}');
}

String _paren(Expr e) {
  if (e is LitExpr || e is ColumnExpr || e is FuncExpr || e is ParamExpr ||
      e is CastExpr || e is CaseExpr) {
    return exprToSql(e);
  }
  return '(${exprToSql(e)})';
}

String _optValue(Object? v) {
  if (v is String) return "'${v.replaceAll("'", "''")}'";
  if (v == true) return 'true';
  return '$v';
}

String optionsSql(Map<String, Object?> o) =>
    o.entries.map((e) => '${e.key} = ${_optValue(e.value)}').join(', ');

/// Canonical CREATE TABLE text of a table definition.
String tableSql(TableDef td) {
  final parts = <String>[];
  final pkOnColumn = td.pkColumns.length == 1 && td.columns[td.pkColumns[0]].pk;
  for (var i = 0; i < td.columns.length; i++) {
    final c = td.columns[i];
    final b = StringBuffer(quoteIdent(c.name));
    if (c.type != null) b.write(' ${c.type}');
    if (c.pk && pkOnColumn) {
      b.write(' PRIMARY KEY');
      if (c.pkDesc) b.write(' DESC');
      if (c.pkConflict != null) b.write(' ON CONFLICT ${c.pkConflict}');
      if (c.autoincrement) b.write(' AUTOINCREMENT');
    }
    if (c.notNull) {
      b.write(' NOT NULL');
      if (c.notNullConflict != null) b.write(' ON CONFLICT ${c.notNullConflict}');
    }
    if (c.unique) {
      b.write(' UNIQUE');
      if (c.uniqueConflict != null) b.write(' ON CONFLICT ${c.uniqueConflict}');
    }
    for (final k in c.checks) {
      b.write(' CHECK (${exprToSql(k)})');
    }
    if (c.defaultExpr != null) b.write(' DEFAULT (${exprToSql(c.defaultExpr!)})');
    if (c.collation != null) b.write(' COLLATE ${c.collation}');
    if (c.generated != null) b.write(' AS (${exprToSql(c.generated!)})');
    parts.add(b.toString());
  }
  if (td.pkColumns.isNotEmpty && !pkOnColumn) {
    final pkIx = td.indexes.where((x) => x.origin == 'pk').toList();
    final cols = <String>[];
    for (var k = 0; k < td.pkColumns.length; k++) {
      var s = quoteIdent(td.columns[td.pkColumns[k]].name);
      if (pkIx.isNotEmpty && pkIx[0].columns[k].desc) s = '$s DESC';
      cols.add(s);
    }
    parts.add('PRIMARY KEY (${cols.join(', ')})');
  }
  for (final ix in td.indexes) {
    if (ix.origin != 'unique') continue;
    if (ix.columns.length == 1 && td.columns[ix.columns[0].col].unique) continue;
    final cols = ix.columns.map((c) {
      var s = quoteIdent(td.columns[c.col].name);
      if (c.desc) s = '$s DESC';
      return s;
    }).join(', ');
    parts.add('UNIQUE ($cols)${ix.conflict != null ? ' ON CONFLICT ${ix.conflict}' : ''}');
  }
  for (final k in td.checks) {
    parts.add('CHECK (${exprToSql(k)})');
  }
  final b = StringBuffer('CREATE TABLE ${quoteIdent(td.name)} (${parts.join(', ')})');
  if (td.options.isNotEmpty) b.write(' WITH (${optionsSql(td.options)})');
  return b.toString();
}

/// TreeOptions from WITH (...) options.
TreeOptions treeOptionsOf(Map<String, Object?> o) {
  String? comp;
  int? page;
  final c = o['compression'];
  if (c != null) comp = c.toString();
  final p = o['page_size'];
  if (p != null) page = parseSize(p);
  return TreeOptions(compression: comp, pageSize: page);
}

/// Parses sizes such as 16384, '16k', '64K', '1m'.
int parseSize(Object v) {
  if (v is int) return v;
  final s = v.toString().trim().toLowerCase();
  final m = RegExp(r'^(\d+)\s*([kmg]?)b?$').firstMatch(s);
  if (m == null) throw ZxDbException('bad size: $v');
  var n = int.parse(m.group(1)!);
  switch (m.group(2)) {
    case 'k':
      n *= 1024;
    case 'm':
      n *= 1024 * 1024;
    case 'g':
      n *= 1024 * 1024 * 1024;
  }
  return n;
}
