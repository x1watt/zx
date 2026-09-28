// SQLite import and export (lib/src/db/sqlite_io/): files made by the
// sqlite3 program are read into zxdb and compared with what sqlite3 says;
// files written from zxdb pass sqlite3's PRAGMA integrity_check and give
// the same query results.

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/db/sqlite_io/sqlite_format.dart';
import 'package:zx/src/db/sqlite_io/sqlite_io.dart';
import 'package:zx/src/db/zxdb.dart';

String? _findSqlite() {
  for (final p in [
    'ref/tools/root/usr/bin/sqlite3',
    '/usr/bin/sqlite3',
    '/usr/local/bin/sqlite3',
  ]) {
    if (File(p).existsSync()) return File(p).absolute.path;
  }
  try {
    final r = Process.runSync('which', ['sqlite3']);
    final s = (r.stdout as String).trim();
    if (r.exitCode == 0 && s.isNotEmpty) return s;
  } on ProcessException {
    // no which
  }
  return null;
}

final String? sqlite3 = _findSqlite();

/// Runs [script] with sqlite3 on [db]; returns stdout (fails on errors).
String _runScript(String db, String script) {
  final f = File('$db.script.sql')..writeAsStringSync(script);
  try {
    final r = Process.runSync(
        '/bin/sh', ['-c', '"${sqlite3!}" -bail -batch "$db" < "${f.path}"']);
    if (r.exitCode != 0) fail('sqlite3 failed: ${r.stderr}\n$script');
    return r.stdout as String;
  } finally {
    f.deleteSync();
  }
}

/// A column as text that sqlite3 and zxdb print alike (they print some
/// REAL values with different digits).
String _q(String c) => "CASE WHEN typeof(\"$c\") = 'real' THEN "
    "'R' || printf('%.15g', \"$c\") ELSE quote(\"$c\") END";

List<String> lines(String s) =>
    s.split('\n').where((l) => l.isNotEmpty).toList();

/// Rows of [query] as "quote(a)|quote(b)" lines, from sqlite3.
List<String> sqliteRows(String db, String table, List<String> cols,
    {String order = 'rowid'}) {
  final q = 'SELECT ${cols.map(_q).join(" || '|' || ")} '
      'FROM "$table" ORDER BY $order;';
  return lines(_runScript(db, '$q\n'));
}

/// The same from zxdb.
List<String> zxRows(ZxDatabase db, String table, List<String> cols,
    {String order = 'rowid'}) {
  final q = 'SELECT ${cols.map(_q).join(" || '|' || ")} '
      'FROM "$table" ORDER BY $order';
  return [for (final r in db.sql.select(q)) r[0] as String];
}

/// Compares row lines, failing with the first difference (shortened).
void expectSameRows(List<String> actual, List<String> expected, String what) {
  String cut(String s) => s.length > 200 ? '${s.substring(0, 200)}...' : s;
  for (var i = 0; i < actual.length && i < expected.length; i++) {
    if (actual[i] != expected[i]) {
      fail('$what: row $i differs:\n  ${cut(actual[i])}\n  ${cut(expected[i])}');
    }
  }
  expect(actual.length, expected.length, reason: '$what: row count');
}

void main() {
  late Directory tmp;
  var n = 0;
  String newPath(String ext) => '${tmp.path}/f${n++}.$ext';
  setUp(() => tmp = Directory.systemTemp.createTempSync('sqlite_io_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('format', () {
    test('varints', () {
      final b = Uint8List(9);
      for (final v in [
        0, 1, 127, 128, 16383, 16384, 0x1fffff, 0x200000,
        0xffffffff, 1 << 40, 0x00ffffffffffffff, 0x0100000000000000,
        -1, -9223372036854775808, 9223372036854775807,
      ]) {
        final l = writeVarint(b, 0, v);
        expect(l, varintLength(v));
        expect(readVarint(b, 0), (v, l));
      }
    });

    test('records', () {
      final vals = <Object?>[
        null, 0, 1, -1, 127, -128, 300, -40000, 8388607, 1 << 31,
        -(1 << 40), 1 << 50, -9223372036854775808, 1.5, -0.0, 'abc', '',
        'x' * 300, Uint8List.fromList([1, 2, 3]), Uint8List(0),
      ];
      final r = decodeSqliteRecord(encodeSqliteRecord(vals));
      expect(r.length, vals.length);
      for (var i = 0; i < vals.length; i++) {
        expect(r[i], vals[i], reason: 'field $i');
      }
      // a header whose size needs two bytes
      final many = List<Object?>.generate(200, (i) => 'v$i');
      expect(decodeSqliteRecord(encodeSqliteRecord(many)), many);
    });

    test('key order', () {
      expect(compareSqliteValues(null, 0), lessThan(0));
      expect(compareSqliteValues(1, 1.5), lessThan(0));
      expect(compareSqliteValues(2, 1.5), greaterThan(0));
      expect(compareSqliteValues(3, 3.0), 0);
      expect(compareSqliteValues(99, 'a'), lessThan(0));
      expect(compareSqliteValues('b', Uint8List(0)), lessThan(0));
      expect(compareSqliteValues('B', 'a'), lessThan(0));
      expect(compareSqliteValues('B', 'a', SqliteCollation.nocase),
          greaterThan(0));
      expect(compareSqliteValues('a  ', 'a', SqliteCollation.rtrim), 0);
      // UTF-8 byte order, not UTF-16 code unit order
      expect(compareSqliteValues('\u{1F600}', '\uFFFD'), greaterThan(0));
    });
  });

  group('with sqlite3', () {
    final skip = sqlite3 == null ? 'sqlite3 not found' : null;

    const script = '''
CREATE TABLE t1 (id INTEGER PRIMARY KEY, a TEXT, b REAL, c BLOB, d);
INSERT INTO t1 VALUES (1, 'one', 1.5, x'00ff', NULL);
INSERT INTO t1 VALUES (2, NULL, -2.25, NULL, -7);
INSERT INTO t1 VALUES (5, 'caf\u00e9 \u{1F600}', 1e300, x'', 9223372036854775807);
INSERT INTO t1 VALUES (-3, '', 0.0, randomblob(20), -9223372036854775808);
INSERT INTO t1 VALUES (7, 'x', 3, '12', 1.0);
CREATE TABLE big (k INTEGER, v TEXT, w BLOB);
WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM c WHERE i < 6000)
  INSERT INTO big SELECT i * 7 - 20000, 'row ' || i || ' ' || hex(randomblob(i % 40)), NULL FROM c;
CREATE INDEX big_k ON big (k);
CREATE UNIQUE INDEX big_v ON big (v DESC);
CREATE TABLE ov (id INTEGER PRIMARY KEY, t TEXT, b BLOB, s TEXT);
INSERT INTO ov VALUES (1, replace(hex(zeroblob(50000)), '0', 'ab'), randomblob(300000), substr(hex(randomblob(600)), 1, 990));
INSERT INTO ov VALUES (2, 'small', randomblob(4000), 'short');
INSERT INTO ov VALUES (3, hex(randomblob(2000)), randomblob(1000), substr(hex(randomblob(600)), 1, 980));
CREATE INDEX ov_s ON ov (s);
CREATE TABLE wr (a TEXT, b INTEGER, c, PRIMARY KEY (b, a)) WITHOUT ROWID;
INSERT INTO wr VALUES ('x', 1, 'one'), ('y', 1, 'two'), ('a', 2, randomblob(500)), ('b', -5, NULL);
CREATE INDEX wr_c ON wr (c);
CREATE TABLE nc (name TEXT COLLATE NOCASE UNIQUE, n INT, UNIQUE (n, name));
INSERT INTO nc VALUES ('Bob', 1), ('alice', 2), ('Carol', NULL), ('dave', NULL);
CREATE TABLE alt (a);
INSERT INTO alt VALUES (1), (2);
ALTER TABLE alt ADD COLUMN b TEXT DEFAULT 'dflt';
INSERT INTO alt VALUES (3, 'three');
CREATE TABLE ai (id INTEGER PRIMARY KEY AUTOINCREMENT, v);
INSERT INTO ai (v) VALUES ('a'), ('b');
CREATE VIEW v1 AS SELECT id, a FROM t1 WHERE id > 1;
''';

    String makeDb({String pragmas = ''}) {
      final p = newPath('db');
      _runScript(p, '$pragmas\n$script');
      final many = StringBuffer();
      for (var i = 0; i < 60; i++) {
        many.writeln('CREATE TABLE m$i (x INTEGER PRIMARY KEY, y TEXT);');
        many.writeln("INSERT INTO m$i VALUES ($i, 'tab$i');");
      }
      _runScript(p, many.toString());
      return p;
    }

    final checks = <(String, List<String>, String)>[
      ('t1', ['id', 'a', 'b', 'c', 'd'], 'rowid'),
      ('big', ['rowid', 'k', 'v', 'w'], 'rowid'),
      ('ov', ['id', 't', 'b', 's'], 'rowid'),
      ('wr', ['a', 'b', 'c'], 'b, a'),
      ('nc', ['rowid', 'name', 'n'], 'rowid'),
      ('alt', ['rowid', 'a', 'b'], 'rowid'),
      ('ai', ['id', 'v'], 'rowid'),
      ('m59', ['x', 'y'], 'rowid'),
    ];

    void compareImport(String dbFile) {
      final zp = newPath('zx');
      final db = ZxDatabase.open(zp, create: true);
      try {
        final rep = sqliteImport(db.sql, dbFile);
        expect(rep.tables, 67);
        expect(rep.warnings, isEmpty);
        expect(rep.views, 1);
        expect(rep.indexes, 4);
        for (final (t, cols, order) in checks) {
          expectSameRows(zxRows(db, t, cols, order: order),
              sqliteRows(dbFile, t, cols, order: order), 'table $t');
        }
        expect(db.sql.select('SELECT count(*) FROM big WHERE k < 0')[0][0],
            int.parse(lines(_runScript(
                dbFile, 'SELECT count(*) FROM big WHERE k < 0;'))[0]));
        expect(db.sql.select('SELECT count(*) FROM v1')[0][0], 3);
        expect(
            () => db.sql.execute("INSERT INTO nc VALUES ('BOB', 9)"),
            throwsA(isA<ZxDbException>()));
        // importing again: the tables exist
        expect(() => sqliteImport(db.sql, dbFile, tables: ['t1']),
            throwsA(isA<ZxDbException>()));
        final again = sqliteImport(db.sql, dbFile, tables: ['t1'], replace: true);
        expect(again.tables, 1);
        expect(again.rows, 5);
      } finally {
        db.close();
      }
    }

    test('import a UTF-8 database', () => compareImport(makeDb()),
        skip: skip);
    test('import UTF-16le and UTF-16be databases', () {
      compareImport(makeDb(pragmas: "PRAGMA encoding = 'UTF-16le';"));
      compareImport(makeDb(pragmas: "PRAGMA encoding = 'UTF-16be';"));
    }, skip: skip);
    test('import 512 and 65536 byte pages', () {
      compareImport(makeDb(pragmas: 'PRAGMA page_size = 512;'));
      compareImport(makeDb(pragmas: 'PRAGMA page_size = 65536;'));
    }, skip: skip);

    test('reader: schema, freelist pages are skipped', () {
      final p = makeDb();
      _runScript(p, 'DELETE FROM big WHERE k > 0; DROP TABLE m3;');
      final r = SqliteFileReader.open(p);
      try {
        expect(r.freelistPages, greaterThan(0));
        expect(r.tableNames, contains('wr'));
        expect(r.tableNames, isNot(contains('m3')));
        expect(r.shape('wr').withoutRowid, true);
        expect(r.shape('t1').ipk, 0);
        final n = int.parse(lines(_runScript(p, 'SELECT count(*) FROM big;'))[0]);
        expect(r.rows('big').length, n);
      } finally {
        r.close();
      }
    }, skip: skip);

    test('import falls back for values JSON columns refuse', () {
      final p = newPath('db');
      _runScript(p, '''
CREATE TABLE j (id INTEGER PRIMARY KEY, doc JSON, tags ARRAY, when_ DATETIME);
INSERT INTO j VALUES (1, '{"a":1}', '["x"]', '2024-01-02 03:04:05');
INSERT INTO j VALUES (2, 'not json', 'nope', NULL);
''');
      final db = ZxDatabase.open(newPath('zx'), create: true);
      try {
        final rep = sqliteImport(db.sql, p);
        expect(rep.rows, 2);
        expect(rep.warnings.join(), contains('JSON'));
        expect(db.sql.select('SELECT doc FROM j WHERE id = 2')[0][0], 'not json');
      } finally {
        db.close();
      }
    }, skip: skip);

    ZxDatabase makeZx() {
      final db = ZxDatabase.open(newPath('zx'), create: true);
      final s = db.sql;
      s.execute('BEGIN');
      s.execute('CREATE TABLE people (id INTEGER PRIMARY KEY AUTOINCREMENT, '
          'name TEXT NOT NULL COLLATE NOCASE, age INT CHECK (age >= 0), '
          'email TEXT UNIQUE, born DATETIME, info JSON, pic BLOB, '
          'score REAL DEFAULT 1.5)');
      s.execute('CREATE INDEX people_name ON people (name DESC, age)');
      s.execute('CREATE INDEX people_lower ON people (lower(email))');
      s.execute('CREATE INDEX people_old ON people (age) WHERE age > 50');
      final st = s.prepare('INSERT INTO people (name, age, email, born, info, '
          'pic, score) VALUES (?, ?, ?, ?, ?, ?, ?)');
      for (var i = 0; i < 3000; i++) {
        st.execute([
          i % 7 == 0 ? 'Name$i' : 'name${i % 100}',
          i % 11 == 0 ? null : i % 90,
          i % 13 == 0 ? null : 'u$i@x.org',
          '2020-01-01 00:00:${(i % 60).toString().padLeft(2, '0')}',
          '{"i":$i}',
          i % 500 == 0 ? Uint8List(20000 + i) : null,
          i / 3,
        ]);
      }
      s.execute('CREATE TABLE kv (k TEXT, g INT, v, PRIMARY KEY (k, g DESC)) '
          'WITHOUT ROWID');
      for (var i = 0; i < 1500; i++) {
        s.execute('INSERT INTO kv VALUES (?, ?, ?)',
            ['key${i % 300}', i ~/ 300, i.isEven ? 'x' * (i % 5000) : i]);
      }
      s.execute('CREATE INDEX kv_g ON kv (g, k)');
      s.execute('CREATE TABLE pk2 (a TEXT, b TEXT, c, PRIMARY KEY (a, b), '
          'UNIQUE (c), UNIQUE (b, a))');
      s.execute("INSERT INTO pk2 VALUES ('a', 'b', 1), ('b', 'a', 2), "
          "('a', 'c', NULL), ('A', 'c', NULL)");
      s.execute('CREATE TABLE empty (x)');
      s.execute('CREATE VIEW adults AS SELECT name FROM people WHERE age >= 18');
      s.execute('PRAGMA user_version = 42');
      s.execute('COMMIT');
      return db;
    }

    final exportChecks = <(String, List<String>, String)>[
      ('people', ['id', 'name', 'age', 'email', 'born', 'info', 'pic', 'score'],
          'id'),
      ('kv', ['k', 'g', 'v'], 'k, g DESC'),
      ('pk2', ['rowid', 'a', 'b', 'c'], 'rowid'),
      ('empty', ['x'], 'rowid'),
    ];

    test('export: integrity_check ok, same rows, indexes used', () {
      final db = makeZx();
      try {
        final out = newPath('db');
        final rep = sqliteExport(db.sql, out);
        expect(rep.tables, 4);
        expect(rep.rows, 3000 + 1500 + 4);
        expect(rep.views, 1);
        expect(lines(_runScript(out, 'PRAGMA integrity_check;')), ['ok']);
        for (final (t, cols, order) in exportChecks) {
          expectSameRows(sqliteRows(out, t, cols, order: order),
              zxRows(db, t, cols, order: order), 'table $t');
        }
        expect(lines(_runScript(out, 'PRAGMA user_version;')), ['42']);
        expect(
            lines(_runScript(out,
                "SELECT count(*) FROM people INDEXED BY people_name WHERE name = 'NAME7';")),
            ['${db.sql.select("SELECT count(*) FROM people WHERE name = 'NAME7'")[0][0]}']);
        expect(lines(_runScript(out, 'SELECT count(*) FROM adults;')),
            ['${db.sql.select('SELECT count(*) FROM adults')[0][0]}']);
        expect(lines(_runScript(out, "SELECT seq FROM sqlite_sequence WHERE name = 'people';")),
            ['3000']);
        // sqlite3 can write to it and it stays consistent
        final w = _runScript(out, '''
INSERT INTO people (name, age) VALUES ('new', 3);
SELECT max(id) FROM people;
DELETE FROM kv WHERE g = 1;
UPDATE pk2 SET c = 10 WHERE a = 'a' AND b = 'b';
PRAGMA integrity_check;
''');
        expect(lines(w), ['3001', 'ok']);
        // UNIQUE and PRIMARY KEY constraints are enforced by sqlite3
        final bad = Process.runSync('/bin/sh', [
          '-c',
          '"$sqlite3" "$out" "INSERT INTO pk2 VALUES (\'b\', \'a\', 99);"'
        ]);
        expect(bad.exitCode, isNot(0));
        expect('${bad.stderr}', contains('UNIQUE'));
      } finally {
        db.close();
      }
    }, skip: skip);

    test('round trip zxdb -> sqlite -> zxdb -> sqlite', () {
      final db = makeZx();
      final db2 = ZxDatabase.open(newPath('zx'), create: true);
      try {
        final f1 = newPath('db');
        sqliteExport(db.sql, f1);
        final rep = sqliteImport(db2.sql, f1);
        expect(rep.warnings, isEmpty);
        for (final (t, cols, order) in exportChecks) {
          expectSameRows(zxRows(db2, t, cols, order: order),
              zxRows(db, t, cols, order: order), 'table $t');
        }
        final f2 = newPath('db');
        sqliteExport(db2.sql, f2, tables: ['people', 'kv']);
        expect(lines(_runScript(f2, 'PRAGMA integrity_check;')), ['ok']);
        expect(lines(_runScript(f2, "SELECT name FROM sqlite_schema WHERE type = 'table' ORDER BY 1;")),
            ['kv', 'people', 'sqlite_sequence']);
      } finally {
        db.close();
        db2.close();
      }
    }, skip: skip);

    test('round trip sqlite -> zxdb -> sqlite', () {
      final src = makeDb();
      final db = ZxDatabase.open(newPath('zx'), create: true);
      try {
        sqliteImport(db.sql, src);
        final out = newPath('db');
        sqliteExport(db.sql, out);
        expect(lines(_runScript(out, 'PRAGMA integrity_check;')), ['ok']);
        for (final (t, cols, order) in checks) {
          expectSameRows(sqliteRows(out, t, cols, order: order),
              sqliteRows(src, t, cols, order: order), 'table $t');
        }
      } finally {
        db.close();
      }
    }, skip: skip);

    test('export many tables (schema spills out of page 1), metadata', () {
      final db = ZxDatabase.open(newPath('zx'), create: true);
      try {
        db.sql.execute('BEGIN');
        for (var i = 0; i < 150; i++) {
          db.sql.execute('CREATE TABLE table_with_a_long_name_$i '
              '(id INTEGER PRIMARY KEY, value TEXT UNIQUE, other INTEGER)');
          db.sql.execute('CREATE INDEX idx_$i ON table_with_a_long_name_$i (other)');
          db.sql.execute(
              'INSERT INTO table_with_a_long_name_$i VALUES ($i, ?, $i)', ['v$i']);
        }
        db.sql.execute('COMMIT');
        final out = newPath('db');
        final rep = sqliteExport(db.sql, out, includeMeta: true);
        expect(rep.tables, 150 + 4);
        expect(lines(_runScript(out, 'PRAGMA integrity_check;')), ['ok']);
        expect(
            lines(_runScript(out,
                "SELECT count(*) FROM sqlite_schema WHERE type = 'index';")),
            ['300']);
        expect(
            lines(_runScript(out, 'SELECT value FROM table_with_a_long_name_149;')),
            ['v149']);
        final r = SqliteFileReader.open(out);
        try {
          expect(r.tableNames.length, 154);
        } finally {
          r.close();
        }
      } finally {
        db.close();
      }
    }, skip: skip);
  });
}
