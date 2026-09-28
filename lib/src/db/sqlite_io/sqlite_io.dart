// SQLite interop of zxdb (docs/zxdb-design.md section 6): import the
// tables, rows, indexes and views of a SQLite database file into a zxdb
// SQL session, and export the tables of a session to a new SQLite file
// that the sqlite3 program reads (PRAGMA integrity_check says ok). Both
// work on the file format directly (sqlite_reader.dart,
// sqlite_writer.dart); the SQLite library is not needed.

import 'dart:io';
import 'dart:typed_data';

import '../sql/catalog.dart';
import '../sql/lexer.dart';
import '../sql/zx_sql.dart';
import '../storage_api.dart';
import 'sqlite_format.dart';
import 'sqlite_reader.dart';
import 'sqlite_writer.dart';

export 'sqlite_reader.dart'
    show SqliteFileReader, SqliteSchemaEntry, SqliteRow, SqliteTableShape;

/// What an import or an export did.
class SqliteIoReport {
  int tables = 0;
  int rows = 0;
  int indexes = 0;
  int views = 0;
  final List<String> warnings = [];

  @override
  String toString() => '$tables tables, $rows rows, $indexes indexes, '
      '$views views${warnings.isEmpty ? '' : ', ${warnings.length} warnings'}';
}

String _q(String s) => '"${s.replaceAll('"', '""')}"';

const _metaTables = ['zx_meta', 'zx_layers', 'zx_media', 'zx_fingerprints'];

// ------------------------------------------------------------------ import

/// Imports every table of the SQLite file at [path] (its schema as zxdb
/// SQL, its rows with their rowids, its indexes) and its views into
/// [sql], in one transaction. [tables]: only these (views are imported
/// only when all tables are). A table that exists already is an error
/// (ZxDbException, constraint) unless [replace], which drops it first.
/// Triggers and virtual tables are skipped with a warning.
SqliteIoReport sqliteImport(ZxSql sql, String path,
    {List<String>? tables, bool replace = false}) {
  final rep = SqliteIoReport();
  final r = SqliteFileReader.open(path);
  final own = !sql.inTransaction;
  try {
    final want = tables?.map((t) => t.toLowerCase()).toSet();
    final existing = {
      for (final row in sql
          .execute("SELECT name FROM sqlite_schema WHERE type IN ('table', 'view')")
          .rows)
        (row[0] as String).toLowerCase()
    };
    if (own) sql.execute('BEGIN');
    final imported = <String>{};
    for (final e in r.schema) {
      if (e.type != 'table') continue;
      final l = e.name.toLowerCase();
      if (l.startsWith('sqlite_')) continue;
      if (want != null && !want.contains(l)) continue;
      if (e.isVirtual || e.sql == null) {
        rep.warnings.add('skipped virtual table ${e.name}');
        continue;
      }
      if (existing.contains(l)) {
        if (!replace) {
          throw ZxDbException('table ${e.name} already exists', ZxDbError.constraint);
        }
        sql.execute('DROP TABLE IF EXISTS ${_q(e.name)}');
      }
      final SqliteTableShape shape;
      try {
        shape = SqliteTableShape.parse(e.sql!);
        sql.execute(e.sql!);
      } on Object catch (x) {
        rep.warnings.add('skipped table ${e.name}: ${_msg(x)}');
        continue;
      }
      try {
        rep.rows += _copyRows(sql, r, e, shape);
      } on ZxDbException catch (x) {
        if (x.kind != ZxDbError.constraint ||
            !(x.message.startsWith('JSON column') ||
                x.message.startsWith('ARRAY column'))) {
          rethrow;
        }
        // values the zx types refuse: the SQLite affinity of those types
        final fixed = _plainTypes(e.sql!);
        sql.execute('DROP TABLE ${_q(e.name)}');
        sql.execute(fixed);
        rep.warnings.add('table ${e.name}: JSON / ARRAY columns imported as '
            'NUMERIC (${x.message})');
        rep.rows += _copyRows(sql, r, e, shape);
      }
      imported.add(l);
      rep.tables++;
    }
    for (final e in r.schema) {
      if (e.type == 'index') {
        if (e.sql == null) continue; // made by its CREATE TABLE
        if (!imported.contains(e.tableName.toLowerCase())) continue;
        if (existing.contains(e.name.toLowerCase()) && replace) {
          sql.execute('DROP INDEX IF EXISTS ${_q(e.name)}');
        }
        try {
          sql.execute(e.sql!);
          rep.indexes++;
        } on ZxDbException catch (x) {
          rep.warnings.add('skipped index ${e.name}: ${x.message}');
        }
      } else if (e.type == 'trigger') {
        if (imported.contains(e.tableName.toLowerCase())) {
          rep.warnings.add('skipped trigger ${e.name} (not supported)');
        }
      }
    }
    if (want == null) {
      for (final e in r.schema) {
        if (e.type != 'view' || e.sql == null) continue;
        final l = e.name.toLowerCase();
        if (existing.contains(l)) {
          if (!replace) {
            rep.warnings.add('skipped view ${e.name}: it exists');
            continue;
          }
          sql.execute('DROP VIEW IF EXISTS ${_q(e.name)}');
        }
        try {
          sql.execute(e.sql!);
          rep.views++;
        } on ZxDbException catch (x) {
          rep.warnings.add('skipped view ${e.name}: ${x.message}');
        }
      }
    }
    if (own) sql.execute('COMMIT');
  } catch (_) {
    if (own && sql.inTransaction) sql.execute('ROLLBACK');
    rethrow;
  } finally {
    r.close();
  }
  return rep;
}

String _msg(Object x) => x is ZxDbException
    ? x.message
    : x is FormatException
        ? x.message
        : '$x';

int _copyRows(ZxSql sql, SqliteFileReader r, SqliteSchemaEntry e,
    SqliteTableShape s) {
  final lower = {for (final c in s.columns) c.toLowerCase()};
  String? rowidName;
  if (!s.withoutRowid && s.ipk < 0) {
    for (final n in const ['rowid', '_rowid_', 'oid']) {
      if (!lower.contains(n)) {
        rowidName = n;
        break;
      }
    }
  }
  final cols = [if (rowidName != null) rowidName, ...s.columns.map(_q)];
  final st = sql.prepare('INSERT INTO ${_q(e.name)} (${cols.join(', ')}) '
      'VALUES (${List.filled(cols.length, '?').join(', ')})');
  var n = 0;
  for (final row in r.rows(e.name)) {
    st.execute([if (rowidName != null) row.rowid, ...row.values]);
    n++;
  }
  return n;
}

// CREATE TABLE text with the zx JSON and ARRAY column types replaced by
// NUMERIC (their affinity in SQLite)
String _plainTypes(String createSql) {
  final t = Lexer(createSql).tokenize();
  const stops = {
    'CONSTRAINT', 'PRIMARY', 'NOT', 'NULL', 'UNIQUE', 'CHECK', 'DEFAULT', //
    'COLLATE', 'REFERENCES', 'GENERATED', 'AS',
  };
  const tableCons = {'CONSTRAINT', 'PRIMARY', 'UNIQUE', 'CHECK', 'FOREIGN'};
  final edits = <(int, int)>[];
  var i = 0;
  while (i < t.length && !(t[i].type == Tok.op && t[i].text == '(')) {
    i++;
  }
  i++;
  while (i < t.length && t[i].type != Tok.eof) {
    // a column definition or a table constraint starts at t[i]
    if (tableCons.contains(t[i].kw)) break;
    i++; // the column name
    final ts = i;
    while (i < t.length &&
        t[i].type == Tok.ident &&
        !stops.contains(t[i].kw)) {
      i++;
    }
    if (i < t.length && t[i].type == Tok.op && t[i].text == '(' && i > ts) {
      var d = 0;
      do {
        if (t[i].text == '(') d++;
        if (t[i].text == ')') d--;
        i++;
      } while (i < t.length && d > 0);
    }
    if (i > ts) {
      final type = createSql.substring(t[ts].pos, t[i - 1].end).toUpperCase();
      if (type.startsWith('JSON') || type.startsWith('ARRAY')) {
        edits.add((t[ts].pos, t[i - 1].end));
      }
    }
    // skip to the next comma at depth 0
    var d = 0;
    while (i < t.length && t[i].type != Tok.eof) {
      final x = t[i];
      if (x.type == Tok.op && x.text == '(') d++;
      if (x.type == Tok.op && x.text == ')') {
        if (d == 0) break;
        d--;
      }
      if (x.type == Tok.op && x.text == ',' && d == 0) {
        i++;
        break;
      }
      i++;
    }
    if (i < t.length && t[i].type == Tok.op && t[i].text == ')') break;
  }
  var out = createSql;
  for (final (s, e) in edits.reversed) {
    out = '${out.substring(0, s)}NUMERIC${out.substring(e)}';
  }
  return out;
}

// ------------------------------------------------------------------ export

class _IxSpec {
  final String name;
  final String? sql;
  final List<int> cols; // -1: expression
  final List<String> terms; // SQL of each term
  final List<String> colls;
  final List<bool> descs;
  final String? where;
  _IxSpec(this.name, this.sql, this.cols, this.terms, this.colls, this.descs,
      this.where);
}

/// Writes the tables of [sql] (not the virtual and system tables; the
/// zx_meta, zx_layers, zx_media and zx_fingerprints tables only with
/// [includeMeta]) with their rows and indexes, and the views, to a new
/// SQLite file at [path] (replaced when it exists). [tables]: only these
/// (views are written only when all tables are).
SqliteIoReport sqliteExport(ZxSql sql, String path,
    {List<String>? tables, bool includeMeta = false}) {
  final rep = SqliteIoReport();
  final want = tables?.map((t) => t.toLowerCase()).toSet();
  final snap = sql.store.snapshot();
  final Catalog cat;
  try {
    cat = Catalog.load(snap);
  } catch (_) {
    snap.close();
    rethrow;
  }
  final userVersion = Catalog.readInt(snap, 'user_version');
  final seqs = <String, int>{
    for (final td in cat.tables.values)
      if (td.autoincrement) td.name: Catalog.readInt(snap, 'seq:${td.name.toLowerCase()}')
  };
  snap.close();
  final tmp = '$path.tmp${DateTime.now().microsecondsSinceEpoch}';
  final w = SqliteFileWriter.create(tmp);
  final schema = <List<Object?>>[];
  try {
    var seqDone = false;
    for (final td in cat.tables.values) {
      final l = td.name.toLowerCase();
      if (l.startsWith('sqlite_')) continue;
      if (want != null && !want.contains(l)) continue;
      final maxRowid = _exportTable(sql, w, td, schema, rep);
      rep.tables++;
      if (td.autoincrement && !td.withoutRowid) {
        final v = seqs[td.name] ?? 0;
        seqs[td.name] = v > maxRowid ? v : maxRowid;
        if (!seqDone) {
          seqDone = true;
          schema.add(['table', 'sqlite_sequence', 'sqlite_sequence', -1,
              'CREATE TABLE sqlite_sequence(name,seq)']);
        }
      }
    }
    if (seqDone) {
      final b = w.table();
      var id = 0;
      for (final e in seqs.entries) {
        if (want != null && !want.contains(e.key.toLowerCase())) continue;
        b.add(++id, encodeSqliteRecord([e.key, e.value]));
      }
      final root = b.finish();
      for (final s in schema) {
        if (s[1] == 'sqlite_sequence') s[3] = root;
      }
    }
    if (includeMeta) {
      for (final m in _metaTables) {
        if (want != null && !want.contains(m)) continue;
        ZxSqlResult res;
        try {
          res = sql.execute('SELECT * FROM $m');
        } on ZxDbException {
          continue;
        }
        final b = w.table();
        var id = 0;
        for (final row in res.rows) {
          b.add(++id, encodeSqliteRecord(row));
        }
        schema.add(['table', m, m, b.finish(),
            'CREATE TABLE ${_q(m)} (${res.columns.map(_q).join(', ')})']);
        rep.tables++;
        rep.rows += res.rows.length;
      }
    }
    if (want == null) {
      for (final v in cat.views.values) {
        schema.add(['view', v.name, v.name, 0, v.sql]);
        rep.views++;
      }
    }
    final sb = w.table(page1: true);
    for (var i = 0; i < schema.length; i++) {
      sb.add(i + 1, encodeSqliteRecord(schema[i]));
    }
    sb.finish();
    w.finish(sb.page1Bytes, userVersion: userVersion);
  } catch (_) {
    w.abort();
    try {
      File(tmp).deleteSync();
    } on FileSystemException {
      // already gone
    }
    rethrow;
  }
  File(tmp).renameSync(path);
  return rep;
}

// the CREATE TABLE text SQLite gets, and the automatic indexes it implies
// (in SQLite's order and numbering)
(String, List<_IxSpec>, _IxSpec?) _tableDdl(TableDef td, SqliteIoReport rep) {
  final parts = <String>[];
  for (var i = 0; i < td.columns.length; i++) {
    final c = td.columns[i];
    final b = StringBuffer(_q(c.name));
    if (c.type != null) b.write(' ${c.type}');
    if (i == td.ipk) {
      b.write(' PRIMARY KEY');
      if (td.autoincrement) b.write(' AUTOINCREMENT');
    }
    if (c.notNull) b.write(' NOT NULL');
    if (c.defaultExpr != null) b.write(' DEFAULT (${exprToSql(c.defaultExpr!)})');
    if (c.collation != null) b.write(' COLLATE ${c.collation}');
    for (final k in c.checks) {
      b.write(' CHECK (${exprToSql(k)})');
    }
    parts.add(b.toString());
  }
  String collOf(IndexColumn ic) =>
      (ic.collation ??
              (ic.col >= 0 ? td.columns[ic.col].collation : null) ??
              'BINARY')
          .toUpperCase();
  final autos = <_IxSpec>[];
  _IxSpec? pkSpec;
  var n = 0;
  bool dup(List<int> cols, List<String> colls) {
    for (final a in [if (pkSpec != null) pkSpec, ...autos]) {
      if (a.cols.length != cols.length) continue;
      var same = true;
      for (var k = 0; k < cols.length; k++) {
        if (a.cols[k] != cols[k] || a.colls[k] != colls[k]) same = false;
      }
      if (same) return true;
    }
    return false;
  }

  if (td.pkColumns.isNotEmpty && td.ipk < 0) {
    final pkIx = td.indexes.where((x) => x.origin == 'pk').firstOrNull;
    final cols = <int>[], colls = <String>[], descs = <bool>[];
    for (var k = 0; k < td.pkColumns.length; k++) {
      final ic = pkIx != null && k < pkIx.columns.length
          ? pkIx.columns[k]
          : IndexColumn(td.pkColumns[k], null, false, null);
      cols.add(td.pkColumns[k]);
      colls.add(collOf(ic));
      descs.add(ic.desc);
    }
    parts.add('PRIMARY KEY (${[
      for (var k = 0; k < cols.length; k++)
        '${_q(td.columns[cols[k]].name)}'
            '${pkIx != null && pkIx.columns[k].collation != null ? ' COLLATE ${pkIx.columns[k].collation}' : ''}'
            '${descs[k] ? ' DESC' : ''}'
    ].join(', ')})');
    n++;
    pkSpec = _IxSpec('sqlite_autoindex_${td.name}_$n', null, cols,
        [for (final c in cols) _q(td.columns[c].name)], colls, descs, null);
  }
  for (final ix in td.indexes) {
    if (ix.origin != 'unique') continue;
    if (ix.columns.any((c) => c.col < 0)) continue;
    final cols = [for (final c in ix.columns) c.col];
    final colls = [for (final c in ix.columns) collOf(c)];
    if (dup(cols, colls)) continue;
    parts.add('UNIQUE (${[
      for (final c in ix.columns)
        '${_q(td.columns[c.col].name)}'
            '${c.collation != null ? ' COLLATE ${c.collation}' : ''}'
            '${c.desc ? ' DESC' : ''}'
    ].join(', ')})');
    n++;
    autos.add(_IxSpec('sqlite_autoindex_${td.name}_$n', null, cols,
        [for (final c in cols) _q(td.columns[c].name)], colls,
        [for (final c in ix.columns) c.desc], null));
  }
  for (final k in td.checks) {
    parts.add('CHECK (${exprToSql(k)})');
  }
  var ddl = 'CREATE TABLE ${_q(td.name)} (${parts.join(', ')})';
  if (td.withoutRowid) ddl += ' WITHOUT ROWID';
  if (td.strict) {
    rep.warnings.add('table ${td.name}: STRICT dropped (zx types are not '
        'SQLite STRICT types)');
  }
  if (!td.withoutRowid && pkSpec != null) autos.insert(0, pkSpec);
  return (ddl, autos, td.withoutRowid ? pkSpec : null);
}

// writes one table and its indexes; returns the largest rowid
int _exportTable(ZxSql sql, SqliteFileWriter w, TableDef td,
    List<List<Object?>> schema, SqliteIoReport rep) {
  final (ddl, autos, wrPk) = _tableDdl(td, rep);
  final lower = {for (final c in td.columns) c.name.toLowerCase()};
  String? rowidName;
  for (final n in const ['rowid', '_rowid_', 'oid']) {
    if (!lower.contains(n)) {
      rowidName = n;
      break;
    }
  }
  final cols = td.columns.map((c) => _q(c.name)).join(', ');
  final n = td.columns.length;
  var maxRowid = 0;
  final tableRow = <Object?>['table', td.name, td.name, 0, ddl];
  schema.add(tableRow);
  if (!td.withoutRowid) {
    if (rowidName == null) {
      throw ZxDbException(
          'table ${td.name}: no name left for the rowid', ZxDbError.unsupported);
    }
    final b = w.table();
    final cur = sql.query(
        'SELECT $rowidName${n == 0 ? '' : ', $cols'} FROM ${_q(td.name)} '
        'ORDER BY $rowidName');
    try {
      while (cur.moveNext()) {
        final r = cur.current;
        final rowid = r[0] as int;
        final vals = r.sublist(1);
        if (td.ipk >= 0) vals[td.ipk] = null;
        b.add(rowid, encodeSqliteRecord(vals));
        if (rowid > maxRowid) maxRowid = rowid;
        rep.rows++;
      }
    } finally {
      cur.close();
    }
    tableRow[3] = b.finish();
  } else {
    final pk = wrPk!;
    final order = [
      ...pk.cols,
      for (var i = 0; i < n; i++)
        if (!pk.cols.contains(i)) i
    ];
    final fields = [
      for (var k = 0; k < pk.cols.length; k++)
        SqliteKeyField(collationOf(pk.colls[k]), pk.descs[k])
    ];
    final rows = <List<Object?>>[];
    for (final r in sql.select('SELECT $cols FROM ${_q(td.name)}')) {
      rows.add([for (final i in order) r[i]]);
    }
    rows.sort((a, b) => compareSqliteKeys(a, b, fields));
    rep.rows += rows.length;
    tableRow[3] = w.index([for (final r in rows) encodeSqliteRecord(r)]);
  }
  final user = <_IxSpec>[
    for (final ix in td.indexes)
      if (ix.origin == 'index')
        _IxSpec(
            ix.name,
            Catalog.indexSql(ix, td),
            [for (final c in ix.columns) c.col],
            [
              for (final c in ix.columns)
                c.col >= 0 ? _q(td.columns[c.col].name) : exprToSql(c.expr!)
            ],
            [
              for (final c in ix.columns)
                (c.collation ??
                        (c.col >= 0 ? td.columns[c.col].collation : null) ??
                        'BINARY')
                    .toUpperCase()
            ],
            [for (final c in ix.columns) c.desc],
            ix.where == null ? null : exprToSql(ix.where!))
  ];
  for (final ix in [...autos, ...user]) {
    // the key suffix: the rowid, or the primary key columns not in the index
    final suffix = <String>[];
    final fields = <SqliteKeyField>[
      for (var k = 0; k < ix.terms.length; k++)
        SqliteKeyField(collationOf(ix.colls[k]), ix.descs[k])
    ];
    if (wrPk == null) {
      suffix.add(rowidName!);
      fields.add(const SqliteKeyField(SqliteCollation.binary, false));
    } else {
      for (var k = 0; k < wrPk.cols.length; k++) {
        var isDup = false;
        for (var j = 0; j < ix.cols.length; j++) {
          if (ix.cols[j] == wrPk.cols[k] && ix.colls[j] == wrPk.colls[k]) {
            isDup = true;
          }
        }
        if (isDup) continue;
        suffix.add(wrPk.terms[k]);
        fields.add(SqliteKeyField(collationOf(wrPk.colls[k]), wrPk.descs[k]));
      }
    }
    final q = 'SELECT ${[...ix.terms, ...suffix].join(', ')} '
        'FROM ${_q(td.name)}${ix.where == null ? '' : ' WHERE ${ix.where}'}';
    final keys = sql.select(q);
    keys.sort((a, b) => compareSqliteKeys(a, b, fields));
    final root = w.index([for (final k in keys) encodeSqliteRecord(k)]);
    schema.add(['index', ix.name, td.name, root, ix.sql]);
    rep.indexes++;
  }
  return maxRowid;
}

/// Reads the rows of [table] in the SQLite file at [path] (a convenience
/// for tools and tests).
List<List<Object?>> sqliteReadTable(String path, String table) {
  final r = SqliteFileReader.open(path);
  try {
    return [for (final row in r.rows(table)) row.values];
  } finally {
    r.close();
  }
}

/// True when [bytes] start like a SQLite database file.
bool isSqliteFile(Uint8List bytes) {
  if (bytes.length < 16) return false;
  for (var i = 0; i < 16; i++) {
    if (bytes[i] != sqliteMagic[i]) return false;
  }
  return true;
}
