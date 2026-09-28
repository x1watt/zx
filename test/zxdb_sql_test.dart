// Tests of the zxdb SQL engine (lib/src/db/sql), including a differential
// test against the sqlite3 command line shell when it is installed.

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/db/engine/store.dart';
import 'package:zx/src/db/keycodec.dart';
import 'package:zx/src/db/memory_store.dart';
import 'package:zx/src/db/record.dart';
import 'package:zx/src/db/sql/value.dart';
import 'package:zx/src/db/sql/zx_sql.dart';
import 'package:zx/src/db/storage_api.dart';

// ------------------------------------------------------------ sqlite3

String? _sqlite3() {
  for (final p in [
    '/usr/bin/sqlite3',
    '/usr/local/bin/sqlite3',
    'ref/tools/root/usr/bin/sqlite3'
  ]) {
    if (File(p).existsSync()) return p;
  }
  return null;
}

/// Parses the output of sqlite3 in `.mode quote`.
List<List<Object?>> parseQuote(String out) {
  final rows = <List<Object?>>[];
  var row = <Object?>[];
  var i = 0;
  var any = false;
  while (i < out.length) {
    final c = out[i];
    if (c == '\n') {
      if (any) rows.add(row);
      row = [];
      any = false;
      i++;
      continue;
    }
    if (c == ',') {
      i++;
      continue;
    }
    any = true;
    if (c == "'") {
      final b = StringBuffer();
      i++;
      while (true) {
        if (out[i] == "'") {
          if (i + 1 < out.length && out[i + 1] == "'") {
            b.write("'");
            i += 2;
            continue;
          }
          i++;
          break;
        }
        b.write(out[i++]);
      }
      row.add(b.toString());
      continue;
    }
    var j = i;
    while (j < out.length && out[j] != ',' && out[j] != '\n') {
      j++;
    }
    final t = out.substring(i, j);
    i = j;
    if (t == 'NULL') {
      row.add(null);
    } else if (t.startsWith("X'")) {
      final h = t.substring(2, t.length - 1);
      row.add(Uint8List.fromList([
        for (var k = 0; k < h.length; k += 2)
          int.parse(h.substring(k, k + 2), radix: 16)
      ]));
    } else if (t.contains('.') || t.contains('e') || t.contains('Inf')) {
      row.add(t == 'Inf'
          ? double.infinity
          : (t == '-Inf' ? double.negativeInfinity : double.parse(t)));
    } else {
      row.add(int.parse(t));
    }
  }
  if (any) rows.add(row);
  return rows;
}

bool _valEq(Object? a, Object? b) {
  if (a is double && b is double) {
    if (a == b) return true;
    return (a - b).abs() <= 1e-9 * max(a.abs(), b.abs());
  }
  if (a is Uint8List && b is Uint8List) return compareBytes(a, b) == 0;
  if (a.runtimeType != b.runtimeType) return false;
  return a == b;
}

String _fmt(List<List<Object?>> rows) => rows.map((r) => r.map(quoteValue).join(',')).join('\n');

int _rowCmp(List<Object?> a, List<Object?> b) {
  for (var i = 0; i < a.length && i < b.length; i++) {
    final c = compareValues(a[i], b[i]);
    if (c != 0) return c;
  }
  return a.length - b.length;
}

class _Case {
  final String setup;
  final String query;
  _Case(this.setup, this.query);
}

// A schema and data used by most differential queries.
const String _schema = '''
CREATE TABLE emp (id INTEGER PRIMARY KEY, name TEXT NOT NULL, dept TEXT, salary REAL, age INT, boss INT, note BLOB);
CREATE INDEX emp_dept ON emp(dept);
CREATE INDEX emp_age ON emp(age DESC, name);
CREATE TABLE dept (code TEXT PRIMARY KEY, title TEXT, budget NUMERIC);
CREATE TABLE mixed (a, b TEXT, c NUMERIC, d INTEGER, e REAL);
CREATE TABLE kv (k TEXT UNIQUE COLLATE NOCASE, v);
INSERT INTO emp VALUES
 (1,'Ann','eng',120000.5,34,NULL,x'00ff'),
 (2,'Bob','eng',95000,28,1,NULL),
 (3,'Cyd','ops',70000,45,1,x'61'),
 (4,'Dee','ops',NULL,39,3,NULL),
 (5,'Eve',NULL,50000,23,2,NULL),
 (6,'fay','sales',65000.25,31,1,NULL),
 (7,'Gus','sales',65000.25,NULL,6,NULL),
 (8,'hal','eng',88000,28,2,NULL);
INSERT INTO dept VALUES ('eng','Engineering',1e6),('ops','Operations','500000'),('sales','Sales',NULL),('hr','People',42);
INSERT INTO mixed VALUES (1,'1','1','1','1'),(2.5,'2.5','2.5','2.5','2.5'),('x','x','x','x','x'),(NULL,NULL,NULL,NULL,NULL),
 (x'01',x'01',x'01',x'01',x'01'),('10',10,'10.0',' 10 ',10),(-3,'-3','-3e0','0x10','1e2');
INSERT INTO kv VALUES ('Alpha',1),('beta',2),('GAMMA',NULL);
''';

final List<String> _queries = [
  // basics
  'SELECT * FROM emp',
  'SELECT name, salary FROM emp WHERE salary > 60000 ORDER BY salary DESC, name',
  'SELECT name FROM emp WHERE dept = \'eng\' ORDER BY name',
  'SELECT name FROM emp WHERE age BETWEEN 25 AND 35 ORDER BY age, name',
  'SELECT name FROM emp WHERE age NOT BETWEEN 25 AND 35',
  'SELECT name, age FROM emp ORDER BY age, name',
  'SELECT name, age FROM emp ORDER BY age DESC, name',
  'SELECT name, age FROM emp ORDER BY age NULLS LAST, name',
  'SELECT name, age FROM emp ORDER BY age DESC NULLS FIRST, name',
  'SELECT name FROM emp ORDER BY 1 LIMIT 3',
  'SELECT name FROM emp ORDER BY name LIMIT 3 OFFSET 2',
  'SELECT name FROM emp ORDER BY name LIMIT 2, 3',
  'SELECT DISTINCT dept FROM emp',
  'SELECT DISTINCT age FROM emp ORDER BY age',
  'SELECT id, name FROM emp WHERE id = 3',
  'SELECT id FROM emp WHERE id > 2 AND id <= 6 ORDER BY id DESC',
  'SELECT id FROM emp WHERE id IN (1, 5, 9, 2)',
  'SELECT id FROM emp WHERE id IN (SELECT boss FROM emp)',
  'SELECT id FROM emp WHERE id NOT IN (SELECT boss FROM emp)',
  'SELECT id FROM emp WHERE id NOT IN (SELECT boss FROM emp WHERE boss IS NOT NULL)',
  'SELECT rowid, oid, _rowid_ FROM emp WHERE rowid < 3',
  'SELECT name FROM emp WHERE dept IS NULL',
  'SELECT name FROM emp WHERE dept IS NOT NULL AND age IS NULL',
  'SELECT name FROM emp WHERE name LIKE \'%a%\'',
  'SELECT name FROM emp WHERE name LIKE \'_o_\'',
  'SELECT name FROM emp WHERE name GLOB \'[A-D]*\'',
  'SELECT name FROM emp WHERE name NOT LIKE \'A%\'',
  "SELECT 'a%b' LIKE 'a\\%b' ESCAPE '\\', 'axb' LIKE 'a\\%b' ESCAPE '\\'",
  'SELECT name FROM emp WHERE age IN (28, 45) ORDER BY name',
  'SELECT name, age FROM emp WHERE age > 30 ORDER BY age DESC',
  'SELECT name FROM emp WHERE age = 28 AND name > \'B\'',
  // expressions
  'SELECT 1 + 2 * 3, 7 / 2, 7 % 3, -7 / 2, -7 % 3, 7.0 / 2, 1 / 0, 5 % 0',
  'SELECT 9223372036854775807 + 1, -9223372036854775808 - 1, 4611686018427387904 * 2, 3000000000 * 3000000000',
  "SELECT '3abc' + 1, '1e3' + 0, ' 12 ' * 2, 'abc' * 1, x'31' + 1",
  'SELECT 1 < 2, 2 < 1, NULL < 1, 1 = 1.0, \'a\' < \'b\', \'a\' < 1, x\'00\' > \'z\'',
  'SELECT NULL AND 0, NULL AND 1, NULL OR 1, NULL OR 0, NOT NULL, 0 OR 0',
  'SELECT 1 IS 1, NULL IS NULL, 1 IS NOT NULL, NULL IS NOT 2, 1 IS DISTINCT FROM 2',
  'SELECT 5 & 3, 5 | 3, ~5, 1 << 4, 256 >> 4, -1 >> 1, 1 << 64',
  "SELECT 'ab' || 'cd', 1 || 2, NULL || 'x', 1.5 || ''",
  'SELECT CASE WHEN 1 > 2 THEN \'a\' WHEN 2 > 1 THEN \'b\' ELSE \'c\' END, CASE 3 WHEN 1 THEN \'x\' WHEN 3 THEN \'y\' END, CASE NULL WHEN NULL THEN 1 ELSE 2 END',
  "SELECT CAST('12abc' AS INTEGER), CAST(3.9 AS INTEGER), CAST(-3.9 AS INTEGER), CAST('1e3' AS REAL), CAST(12 AS TEXT), CAST('3.0' AS NUMERIC), CAST('abc' AS NUMERIC), CAST(x'414243' AS TEXT), CAST('ab' AS BLOB), CAST(NULL AS INTEGER)",
  'SELECT CAST(1e30 AS INTEGER), CAST(-1e30 AS INTEGER), CAST(\'  -12.7e1\' AS INTEGER)',
  'SELECT 1 IN (1, 2), 3 IN (1, 2), NULL IN (1), 1 IN (NULL, 1), 3 IN (NULL, 1), 3 NOT IN (NULL, 1), 1 IN ()',
  "SELECT 1 = '1', 1 < '2', '10' > 9",
  'SELECT typeof(1), typeof(1.5), typeof(\'x\'), typeof(x\'00\'), typeof(NULL), typeof(1 + 1.0)',
  'SELECT 0.1 + 0.2, 1e300 * 1e10 > 0, 2.0 * 3, 10 / 4.0, 1.5e-7',
  // affinity
  'SELECT a, typeof(a), b, typeof(b), c, typeof(c), d, typeof(d), e, typeof(e) FROM mixed',
  'SELECT a FROM mixed WHERE a = 1',
  "SELECT b FROM mixed WHERE b = 1",
  "SELECT c FROM mixed WHERE c = '1'",
  "SELECT d FROM mixed WHERE d < 3",
  'SELECT * FROM mixed ORDER BY a',
  'SELECT * FROM mixed ORDER BY b DESC',
  "SELECT count(*) FROM mixed WHERE a > 'a'",
  'SELECT code, budget, typeof(budget) FROM dept',
  // collation
  "SELECT k FROM kv WHERE k = 'ALPHA'",
  'SELECT k FROM kv ORDER BY k',
  "SELECT k FROM kv WHERE k > 'b' ORDER BY k",
  "SELECT 'a' = 'A', 'a' = 'A' COLLATE NOCASE, 'abc ' = 'abc' COLLATE RTRIM",
  'SELECT name FROM emp ORDER BY name COLLATE NOCASE',
  // functions
  "SELECT length('hello'), length(x'0102'), length(NULL), length(123), lower('AbC'), upper('abc'), lower('ÄB')",
  "SELECT substr('hello', 2, 3), substr('hello', -3), substr('hello', 0, 2), substr('hello', 2), substr('hello', -10, 12), substr('hello', 3, -2), substr(x'0102030405', 2, 2)",
  "SELECT instr('hello', 'l'), instr('hello', 'z'), instr(NULL, 'a'), replace('aXbXc', 'X', '--'), replace('abc', '', 'x')",
  "SELECT trim('  ab  '), ltrim('xxabxx', 'x'), rtrim('xxabxx', 'x'), trim('abcba', 'ab')",
  'SELECT abs(-5), abs(-5.5), abs(NULL), abs(\'-3\'), round(2.5), round(-2.5), round(3.14159, 2), round(1234.5678, -1), round(0.5)',
  'SELECT coalesce(NULL, NULL, 3), ifnull(NULL, 4), nullif(5, 5), nullif(5, 6), iif(1 > 0, \'y\', \'n\')',
  "SELECT hex('abc'), hex(x'00ff'), hex(12), hex(NULL), unhex('616263'), unhex('6'), quote('it''s'), quote(1.5), quote(x'00'), quote(NULL)",
  "SELECT printf('%d|%5d|%-5d|%05d|%x|%X|%o', 42, 42, 42, 42, 255, 255, 8), printf('%.2f|%10.3f|%e|%g|%g', 3.14159, 2.5, 12345.678, 0.0001, 1e20)",
  "SELECT printf('%s and %s', 'a', 'b'), printf('%q', 'it''s'), printf('%Q', NULL), printf('%%'), format('%c', 'xyz'), printf('%,d', 1234567)",
  'SELECT max(1, 2, 3), min(\'b\', \'a\'), max(1, NULL), min(2, 1.5)',
  "SELECT char(72, 105), unicode('A'), sign(-3), sign(0), sign(2.5), sign('x')",
  "SELECT concat('a', NULL, 'b', 1), concat_ws('-', 'a', NULL, 'b')",
  'SELECT likely(1), unlikely(0), zeroblob(3), typeof(randomblob(4)), length(randomblob(7))',
  // date and time
  "SELECT date('2024-01-31', '+1 month'), date('2024-03-31', '-1 month'), datetime('2024-02-28 23:59:59', '+1 second')",
  "SELECT date('2023-06-15', 'start of month'), date('2023-06-15', 'start of year'), datetime('2023-06-15 12:34:56', 'start of day')",
  "SELECT date('2024-09-26', 'weekday 0'), date('2024-09-29', 'weekday 0'), date('2024-09-26', 'weekday 5')",
  "SELECT julianday('2000-01-01 12:00:00'), julianday('1970-01-01'), unixepoch('2024-01-01'), unixepoch('1969-12-31 23:59:59')",
  "SELECT datetime(1700000000, 'unixepoch'), datetime(2460000.5), date(2460000.5), time('12:30'), time('12:30:15.678')",
  "SELECT strftime('%Y-%m-%d %H:%M:%S', '2024-03-05 07:08:09'), strftime('%j %w %W', '2024-03-05'), strftime('%s', '2024-01-01 00:00:00'), strftime('%f', '2024-01-01 00:00:01.5')",
  "SELECT strftime('%e|%k|%l|%p|%P|%I', '2024-01-05 15:04:00')",
  "SELECT date('2024-02-30'), date('abc'), datetime('2024-01-01T10:00:00Z'), datetime('2024-01-01 10:00:00+02:00'), date('2024-01-01', '+1.5 days')",
  "SELECT datetime('2024-01-31 10:00', '+1 month', '-1 day'), date('2024-01-01', '+10 years'), time('23:00', '+2 hours')",
  // aggregates
  'SELECT count(*), count(age), count(DISTINCT age), sum(age), total(age), avg(age), min(age), max(age) FROM emp',
  'SELECT dept, count(*), sum(salary), avg(salary), min(name), max(name) FROM emp GROUP BY dept',
  'SELECT dept, count(*) AS n FROM emp GROUP BY dept HAVING n > 1 ORDER BY n DESC, dept',
  'SELECT dept, group_concat(name) FROM emp GROUP BY dept ORDER BY dept',
  "SELECT group_concat(name, '; ') FROM (SELECT name FROM emp ORDER BY name)",
  'SELECT age, count(*) FROM emp GROUP BY 1 ORDER BY 1',
  'SELECT count(*), sum(age) FROM emp WHERE 0',
  'SELECT dept, count(*) FROM emp WHERE 0 GROUP BY dept',
  'SELECT sum(x) FROM (SELECT 1 AS x UNION ALL SELECT 2.5 UNION ALL SELECT NULL)',
  'SELECT avg(salary) FILTER (WHERE dept = \'eng\'), count(*) FILTER (WHERE age > 30) FROM emp',
  'SELECT name, max(salary) FROM emp',
  'SELECT dept, name, min(age) FROM emp GROUP BY dept ORDER BY dept',
  'SELECT total(salary), sum(DISTINCT salary) FROM emp',
  'SELECT count(*) FROM emp HAVING count(*) > 100',
  'SELECT upper(dept) AS d, count(*) FROM emp GROUP BY d ORDER BY d',
  'SELECT dept FROM emp GROUP BY dept HAVING max(age) > 40',
  // joins
  'SELECT e.name, d.title FROM emp e JOIN dept d ON e.dept = d.code ORDER BY e.name',
  'SELECT e.name, d.title FROM emp e LEFT JOIN dept d ON e.dept = d.code ORDER BY e.name',
  'SELECT d.code, e.name FROM dept d LEFT JOIN emp e ON e.dept = d.code ORDER BY d.code, e.name',
  'SELECT d.code, count(e.id) FROM dept d LEFT JOIN emp e ON e.dept = d.code GROUP BY d.code ORDER BY d.code',
  'SELECT e.name, b.name FROM emp e LEFT JOIN emp b ON e.boss = b.id ORDER BY e.id',
  'SELECT e.name, b.name AS boss FROM emp e, emp b WHERE e.boss = b.id AND b.age > 30',
  'SELECT count(*) FROM emp a CROSS JOIN dept b',
  'SELECT d.code, e.name FROM dept d LEFT JOIN emp e ON e.dept = d.code AND e.age > 30 ORDER BY 1, 2',
  'SELECT d.code, e.name FROM dept d LEFT JOIN emp e ON e.dept = d.code WHERE e.name IS NULL',
  'SELECT a.name, b.name FROM emp a JOIN emp b ON a.age = b.age AND a.id < b.id',
  'SELECT * FROM emp JOIN dept ON dept = code WHERE budget > 100',
  'SELECT x.n, y.n FROM (SELECT 1 AS n UNION ALL SELECT 2) x JOIN (SELECT 2 AS n UNION ALL SELECT 3) y USING (n)',
  'SELECT * FROM (SELECT 1 AS a, 2 AS b) NATURAL JOIN (SELECT 2 AS b, 3 AS c)',
  'SELECT e.name FROM emp e WHERE EXISTS (SELECT 1 FROM emp s WHERE s.boss = e.id)',
  'SELECT e.name FROM emp e WHERE NOT EXISTS (SELECT 1 FROM emp s WHERE s.boss = e.id) ORDER BY 1',
  'SELECT name, (SELECT title FROM dept WHERE code = emp.dept) FROM emp ORDER BY id',
  'SELECT name, (SELECT count(*) FROM emp s WHERE s.boss = emp.id) AS reports FROM emp ORDER BY reports DESC, name',
  'SELECT name FROM emp WHERE salary > (SELECT avg(salary) FROM emp)',
  'SELECT name FROM emp e WHERE salary = (SELECT max(salary) FROM emp WHERE dept = e.dept)',
  'SELECT (SELECT 1 WHERE 0), (SELECT 2 UNION SELECT 1)',
  'SELECT t.x FROM (SELECT age AS x FROM emp WHERE age > 30) t ORDER BY t.x',
  // compound
  'SELECT dept FROM emp UNION SELECT code FROM dept',
  'SELECT dept FROM emp UNION ALL SELECT code FROM dept',
  'SELECT dept FROM emp INTERSECT SELECT code FROM dept',
  'SELECT code FROM dept EXCEPT SELECT dept FROM emp',
  'SELECT name AS x FROM emp UNION SELECT title FROM dept ORDER BY x DESC LIMIT 4',
  'SELECT 1, \'a\' UNION ALL SELECT 2, \'b\' UNION SELECT 1, \'a\' ORDER BY 1',
  'VALUES (1, 2), (3, 4)',
  'SELECT * FROM (VALUES (1, \'x\'), (2, \'y\')) ORDER BY 1 DESC',
  // CTEs
  'WITH d AS (SELECT dept, count(*) AS n FROM emp GROUP BY dept) SELECT * FROM d WHERE n > 1',
  'WITH RECURSIVE cnt(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM cnt WHERE x < 10) SELECT sum(x), count(*) FROM cnt',
  'WITH RECURSIVE chain(id, name, depth) AS (SELECT id, name, 0 FROM emp WHERE boss IS NULL UNION ALL SELECT e.id, e.name, depth + 1 FROM emp e JOIN chain c ON e.boss = c.id) SELECT * FROM chain ORDER BY depth, id',
  'WITH RECURSIVE fib(a, b) AS (SELECT 0, 1 UNION ALL SELECT b, a + b FROM fib) SELECT a FROM fib LIMIT 12',
  'WITH a AS (SELECT 1 AS v), b AS (SELECT v + 1 AS v FROM a) SELECT * FROM a, b',
  'WITH RECURSIVE u(x) AS (SELECT 1 UNION SELECT x % 3 + 1 FROM u) SELECT x FROM u ORDER BY x',
  // json
  "SELECT json('{ \"a\" : [1, 2.5, \"x\", null, true] }'), json_valid('{'), json_valid('[1]'), json_type('{\"a\":1}', '\$.a'), json_type('[1.5]', '\$[0]')",
  "SELECT json_extract('{\"a\":{\"b\":[10,20]}}', '\$.a.b[1]'), json_extract('{\"a\":\"t\"}', '\$.a'), json_extract('{\"a\":[1]}', '\$.a'), json_extract('[1,2]', '\$[#-1]'), json_extract('{\"a\":1,\"b\":2}', '\$.a', '\$.b')",
  "SELECT '{\"a\":{\"b\":1}}' -> 'a', '{\"a\":{\"b\":1}}' ->> '\$.a.b', '[5,6]' -> 1, '{\"a\":\"x\"}' -> 'a', '{\"a\":\"x\"}' ->> 'a'",
  "SELECT json_array(1, 2.5, 'x', NULL), json_object('a', 1, 'b', json_array(1)), json_array(json('{}'), '{}'), json_quote('a\"b'), json_array_length('[1,2,3]'), json_array_length('{}')",
  "SELECT json_set('{\"a\":1}', '\$.b', 2), json_insert('{\"a\":1}', '\$.a', 9), json_replace('{\"a\":1}', '\$.a', 9, '\$.c', 3), json_remove('[1,2,3]', '\$[1]'), json_set('[1]', '\$[#]', 2)",
  "SELECT json_patch('{\"a\":1,\"b\":2}', '{\"b\":null,\"c\":3}')",
  "SELECT key, value, type, atom, fullkey, path FROM json_each('{\"a\":1,\"b\":[2,3],\"c\":\"s\"}')",
  "SELECT key, value, type FROM json_each('[1,[2,3]]', '\$[1]')",
  "SELECT key, type, fullkey, path FROM json_tree('{\"a\":[1,{\"b\":2}]}')",
  "SELECT e.name, j.value FROM emp e, json_each(json_array(e.id, e.age)) j WHERE e.id < 3",
  "SELECT json_group_array(name), json_group_object(name, age) FROM emp WHERE id < 4",
  'SELECT json_group_array(json_object(\'n\', name)) FROM emp WHERE id < 3',
  // misc
  'SELECT name FROM emp WHERE +age = 28',
  'SELECT name FROM emp WHERE age = 28 OR dept = \'ops\'',
  'SELECT count(*) FROM emp WHERE note IS NOT NULL',
  'SELECT note FROM emp WHERE note = x\'61\'',
  'SELECT DISTINCT dept, age > 30 FROM emp ORDER BY 1, 2',
  "SELECT name || ' (' || coalesce(dept, '-') || ')' FROM emp ORDER BY id",
  'SELECT sum(salary) / count(*), min(salary), max(salary) FROM emp WHERE salary IS NOT NULL',
  'SELECT age, name FROM emp WHERE age >= 28 ORDER BY age DESC, name ASC',
  'SELECT name FROM emp WHERE dept IN (SELECT code FROM dept WHERE budget > 100) ORDER BY name',
  'SELECT sqlite_version() IS NOT NULL',
];

// Scripts with writes: each ends with the query that is compared.
final List<_Case> _scripts = [
  _Case('''CREATE TABLE t (id INTEGER PRIMARY KEY, a TEXT UNIQUE, n INT DEFAULT 0);
INSERT INTO t (a) VALUES ('x'), ('y'), ('z');
INSERT OR REPLACE INTO t (a, n) VALUES ('y', 5);
INSERT OR IGNORE INTO t (a, n) VALUES ('x', 9);
INSERT INTO t (a, n) VALUES ('x', 1) ON CONFLICT (a) DO UPDATE SET n = n + excluded.n;
UPDATE t SET n = n * 10 WHERE a > 'x';
DELETE FROM t WHERE a = 'z';''', 'SELECT * FROM t ORDER BY id'),
  _Case('''CREATE TABLE t (a INTEGER PRIMARY KEY AUTOINCREMENT, b);
INSERT INTO t (b) VALUES (1), (2), (3);
DELETE FROM t WHERE a = 3;
INSERT INTO t (b) VALUES (4);''', 'SELECT * FROM t'),
  _Case('''CREATE TABLE t (a INTEGER PRIMARY KEY, b);
INSERT INTO t (b) VALUES (1), (2), (3);
DELETE FROM t WHERE a = 3;
INSERT INTO t (b) VALUES (4);
UPDATE t SET a = a + 10 WHERE a < 3;''', 'SELECT * FROM t ORDER BY a'),
  _Case('''CREATE TABLE t (a, b, c);
INSERT INTO t VALUES (1, 2, 3), (4, 5, 6);
UPDATE t SET (a, b) = (b, a), c = c + a;
ALTER TABLE t ADD COLUMN d TEXT DEFAULT 'dd';
INSERT INTO t (a) VALUES (9);''', 'SELECT * FROM t ORDER BY a'),
  _Case('''CREATE TABLE p (id INTEGER PRIMARY KEY, name TEXT);
CREATE TABLE c (id INTEGER PRIMARY KEY, pid INT, v INT);
INSERT INTO p VALUES (1, 'a'), (2, 'b'), (3, 'c');
INSERT INTO c VALUES (1, 1, 10), (2, 1, 20), (3, 2, 30), (4, 9, 40);
UPDATE p SET name = name || '!' WHERE id IN (SELECT pid FROM c WHERE v > 15);
DELETE FROM c WHERE NOT EXISTS (SELECT 1 FROM p WHERE p.id = c.pid);''',
      'SELECT p.name, sum(c.v) FROM p LEFT JOIN c ON c.pid = p.id GROUP BY p.id ORDER BY p.id'),
  _Case('''CREATE TABLE t (k TEXT PRIMARY KEY, v);
INSERT INTO t VALUES ('a', 1), ('b', 2);
INSERT INTO t VALUES ('a', 5), ('c', 3) ON CONFLICT DO NOTHING;
REPLACE INTO t VALUES ('b', 20);''', 'SELECT * FROM t ORDER BY k'),
  _Case('''CREATE TABLE t (x INTEGER PRIMARY KEY, y);
WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 100) INSERT INTO t SELECT i, i * i % 13 FROM n;
DELETE FROM t WHERE y > 6;
CREATE INDEX ty ON t(y);
UPDATE t SET y = -y WHERE x % 10 = 0;''', 'SELECT y, count(*), sum(x) FROM t GROUP BY y ORDER BY y'),
  _Case('''CREATE TABLE a (v); CREATE TABLE b (v);
INSERT INTO a VALUES (1), (2), (2), (NULL), ('2'), (2.0);
INSERT INTO b VALUES (2), (NULL), (3);''',
      'SELECT v, typeof(v) FROM a WHERE v IN (SELECT v FROM b) UNION ALL SELECT count(*), 0 FROM a WHERE v NOT IN (SELECT v FROM b WHERE v IS NOT NULL)'),
  _Case('''CREATE TABLE t (a TEXT, b INT);
INSERT INTO t VALUES ('x', 1), ('X', 2), ('y', 3);
CREATE VIEW v AS SELECT upper(a) AS u, sum(b) AS s FROM t GROUP BY upper(a);''', 'SELECT * FROM v ORDER BY u'),
  _Case('''CREATE TABLE t (id INTEGER PRIMARY KEY, g INT, s TEXT);
CREATE INDEX tg ON t (g, s DESC);
INSERT INTO t (g, s) VALUES (1, 'b'), (1, 'a'), (2, 'c'), (1, 'c'), (NULL, 'z'), (2, NULL);''',
      'SELECT g, s FROM t WHERE g = 1 ORDER BY s DESC'),
  _Case('''CREATE TABLE t (id INTEGER PRIMARY KEY, g INT, s TEXT);
CREATE INDEX tg ON t (g, s DESC);
INSERT INTO t (g, s) VALUES (1, 'b'), (1, 'a'), (2, 'c'), (1, 'c'), (NULL, 'z'), (2, NULL);''',
      'SELECT g, s FROM t WHERE g >= 1 AND s < \'c\' ORDER BY g, s'),
];

String _rndExpr(Random r, int depth) {
  const cols = ['a', 'b', 'c', 'd', 'e'];
  const lits = ['1', '0', '-3', '2.5', '0.1', "'1'", "'x'", "'2.5'", "' 7 '", 'NULL', "x'41'", '10', "'10'", '1e2'];
  if (depth <= 0 || r.nextInt(4) == 0) {
    return r.nextBool() ? cols[r.nextInt(cols.length)] : lits[r.nextInt(lits.length)];
  }
  String e() => _rndExpr(r, depth - 1);
  switch (r.nextInt(20)) {
    case 0:
      const ops = ['+', '-', '*', '/', '%', '||', '&', '|'];
      return '(${e()} ${ops[r.nextInt(ops.length)]} ${e()})';
    case 1:
    case 2:
      const ops = ['=', '!=', '<', '<=', '>', '>=', 'IS', 'IS NOT'];
      return '(${e()} ${ops[r.nextInt(ops.length)]} ${e()})';
    case 3:
      return '(${e()} ${r.nextBool() ? 'AND' : 'OR'} ${e()})';
    case 4:
      return '(NOT ${e()})';
    case 5:
      return '(- ${e()})';
    case 6:
      const fns = ['abs', 'length', 'typeof', 'upper', 'lower', 'hex', 'quote', 'round', 'trim', 'unicode', 'sign', 'ceil', 'floor', 'zeroblob', 'octet_length'];
      return '${fns[r.nextInt(fns.length)]}(${e()})';
    case 7:
      const ts = ['INTEGER', 'REAL', 'TEXT', 'NUMERIC', 'BLOB'];
      return 'CAST(${e()} AS ${ts[r.nextInt(ts.length)]})';
    case 8:
      return 'CASE WHEN ${e()} THEN ${e()} ELSE ${e()} END';
    case 9:
      return '(${e()} IN (${e()}, ${e()}))';
    case 10:
      return '(${e()} BETWEEN ${e()} AND ${e()})';
    case 11:
      return 'coalesce(${e()}, ${e()})';
    case 12:
      return 'substr(${e()}, ${r.nextInt(4) - 1}, ${r.nextInt(3)})';
    case 13:
      const f2 = ['instr', 'nullif', 'ifnull', 'max', 'min', 'round', 'printf', 'glob', 'like', 'concat', 'ltrim'];
      return '${f2[r.nextInt(f2.length)]}(${e()}, ${e()})';
    case 14:
      return "printf('%d|%s|%.2f|%5.1e|%x', ${e()}, ${e()}, ${e()}, ${e()}, ${e()})";
    case 15:
      return 'replace(${e()}, ${e()}, ${e()})';
    case 16:
      return 'iif(${e()}, ${e()}, ${e()})';
    case 17:
      return '(${e()} ${r.nextBool() ? '<<' : '>>'} ${e()})';
    case 18:
      return '(${e()} COLLATE NOCASE = ${e()})';
    default:
      return '(${e()} ${r.nextBool() ? 'LIKE' : 'GLOB'} ${e()})';
  }
}

void main() {
  group('keycodec', () {
    test('order matches SQL value order', () {
      final vals = <Object?>[
        null, -1e300, -9223372036854775808, -5.5, -5, -1e-10, 0, 0.0, 1e-10,
        1, 1.5, 2, 9007199254740993, 9223372036854775807, 1e19, 1e300,
        '', 'a', 'a\u0000', 'a\u0000b', 'ab', 'b', 'é', '\u{1F600}',
        Uint8List(0), Uint8List.fromList([0]), Uint8List.fromList([0, 0]),
        Uint8List.fromList([1]), Uint8List.fromList([255]),
      ];
      for (final a in vals) {
        for (final b in vals) {
          final ka = encodeKey([a]), kb = encodeKey([b]);
          expect(compareBytes(ka, kb).sign, compareValues(a, b).sign,
              reason: '$a vs $b');
          final da = encodeKey([a, 1], [true, false]);
          final db = encodeKey([b, 1], [true, false]);
          expect(compareBytes(da, db).sign, -compareValues(a, b).sign,
              reason: 'desc $a vs $b');
        }
      }
    });
    test('round trip', () {
      final vals = <Object?>[null, 5, -7, 2.25, -0.5, 1e300, 'x\u0000y', Uint8List.fromList([0, 1, 0])];
      final k = encodeKey(vals, [false, true, false, true, false, true, false, true]);
      final d = decodeKey(k, desc: [false, true, false, true, false, true, false, true]);
      expect(d.length, vals.length);
      for (var i = 0; i < vals.length; i++) {
        expect(compareValues(d[i], vals[i]), 0);
      }
      expect(decodeRowid(encodeRowid(-42)), -42);
      expect(compareBytes(encodeRowid(-1), encodeRowid(1)), lessThan(0));
    });
    test('random tuples', () {
      final r = Random(7);
      Object? rv() => switch (r.nextInt(5)) {
            0 => null,
            1 => r.nextInt(200) - 100,
            2 => (r.nextDouble() - 0.5) * 200,
            3 => String.fromCharCodes([for (var i = 0; i < r.nextInt(4); i++) r.nextInt(3) + 97]),
            _ => Uint8List.fromList([for (var i = 0; i < r.nextInt(3); i++) r.nextInt(3)]),
          };
      for (var i = 0; i < 3000; i++) {
        final a = [rv(), rv()], b = [rv(), rv()];
        var c = compareValues(a[0], b[0]);
        if (c == 0) c = compareValues(a[1], b[1]);
        expect(compareBytes(encodeKey(a), encodeKey(b)).sign, c.sign);
      }
    });
  });

  group('record', () {
    test('round trip', () {
      final vals = <Object?>[null, 0, 1, -1, 63, -64, 1 << 40, -9223372036854775808, 9223372036854775807, 1.5, '', 'héllo', Uint8List.fromList([1, 2, 3])];
      final d = decodeRecord(encodeRecord(vals));
      expect(d.length, vals.length);
      for (var i = 0; i < vals.length; i++) {
        expect(compareValues(d[i], vals[i]), 0, reason: '${vals[i]}');
        expect(d[i].runtimeType, vals[i].runtimeType);
      }
    });
  });

  group('values', () {
    test('real to text', () {
      expect(realToText(1.0), '1.0');
      expect(realToText(1e15), '1.0e+15');
      expect(realToText(1e14), '100000000000000.0');
      expect(realToText(0.1 + 0.2), '0.3');
      expect(realToText(1.5e-7), '1.5e-07');
      expect(realToText(-2.0), '-2.0');
    });
  });

  late ZxSql sql;
  ZxSqlResult x(String s, [Object? p]) => sql.execute(s, p);
  List<List<Object?>> q(String s, [Object? p]) => sql.execute(s, p).rows;

  group('engine', () {
    setUp(() => sql = ZxSql(ZxMemoryStore()));

    test('create, insert, select', () {
      x('CREATE TABLE t (id INTEGER PRIMARY KEY, a TEXT, b INT DEFAULT 7)');
      final r = x("INSERT INTO t (a) VALUES ('x'), ('y')");
      expect(r.changes, 2);
      expect(r.lastInsertRowid, 2);
      expect(q('SELECT * FROM t'), [
        [1, 'x', 7],
        [2, 'y', 7]
      ]);
      expect(x('SELECT a AS z, b FROM t').columns, ['z', 'b']);
    });

    test('parameters', () {
      x('CREATE TABLE t (a, b)');
      x('INSERT INTO t VALUES (?, ?)', [1, 'one']);
      x('INSERT INTO t VALUES (?2, ?1)', ['two', 2]);
      x('INSERT INTO t VALUES (:a, @b)', {'a': 3, 'b': 'three'});
      x(r'INSERT INTO t VALUES ($a, :b)', {r'$a': 4, 'b': true});
      expect(q('SELECT * FROM t ORDER BY a'), [
        [1, 'one'],
        [2, 'two'],
        [3, 'three'],
        [4, 1]
      ]);
      final st = sql.prepare('SELECT b FROM t WHERE a = ?');
      expect(st.parameterCount, 1);
      expect(st.select([2]), [
        ['two']
      ]);
      expect(st.select([3]), [
        ['three']
      ]);
      x('INSERT INTO t VALUES (?, ?)', [5, Uint8List.fromList([1, 2])]);
      expect(q('SELECT typeof(b) FROM t WHERE a = 5'), [
        ['blob']
      ]);
    });

    test('streaming cursor', () {
      x('CREATE TABLE t (a INTEGER PRIMARY KEY)');
      x('WITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM c WHERE n < 1000) INSERT INTO t SELECT n FROM c');
      final c = sql.query('SELECT a FROM t ORDER BY a');
      var n = 0;
      while (c.moveNext()) {
        n++;
        if (n == 10) break;
      }
      c.close();
      expect(n, 10);
      expect(sql.select('SELECT count(*) FROM t'), [
        [1000]
      ]);
    });

    test('constraints', () {
      x('CREATE TABLE t (id INTEGER PRIMARY KEY, a TEXT NOT NULL, b INT UNIQUE, c INT CHECK (c > 0), UNIQUE (a, c))');
      x("INSERT INTO t VALUES (1, 'x', 1, 1)");
      Matcher cons(String m) => throwsA(isA<ZxDbException>()
          .having((e) => e.kind, 'kind', ZxDbError.constraint)
          .having((e) => e.message, 'msg', contains(m)));
      expect(() => x("INSERT INTO t VALUES (1, 'y', 2, 2)"), cons('UNIQUE constraint failed: t.id'));
      expect(() => x('INSERT INTO t VALUES (2, NULL, 2, 2)'), cons('NOT NULL constraint failed: t.a'));
      expect(() => x("INSERT INTO t VALUES (2, 'y', 1, 2)"), cons('UNIQUE constraint failed: t.b'));
      expect(() => x("INSERT INTO t VALUES (2, 'y', 2, 0)"), cons('CHECK constraint failed'));
      expect(() => x("INSERT INTO t VALUES (2, 'x', 2, 1)"), cons('UNIQUE constraint failed: t.a, t.c'));
      x("INSERT OR IGNORE INTO t VALUES (1, 'z', 5, 5)");
      expect(q('SELECT a FROM t'), [
        ['x']
      ]);
      x("INSERT OR REPLACE INTO t VALUES (3, 'w', 1, 3)");
      expect(q('SELECT id, a FROM t'), [
        [3, 'w']
      ]);
      x("REPLACE INTO t VALUES (3, 'v', 1, 3)");
      expect(q('SELECT id, a FROM t'), [
        [3, 'v']
      ]);
      x("INSERT INTO t VALUES (4, 'u', NULL, 4), (5, 'u2', NULL, 5)");
      expect(() => x('UPDATE t SET b = 1 WHERE id = 4'), cons('UNIQUE'));
      x('UPDATE OR IGNORE t SET b = 1 WHERE id = 4');
      expect(q('SELECT b FROM t WHERE id = 4'), [
        [null]
      ]);
      // A multi-row insert fails atomically.
      expect(() => x("INSERT INTO t VALUES (10, 'a', 10, 1), (11, 'b', 10, 1)"), cons('UNIQUE'));
      expect(q('SELECT count(*) FROM t WHERE id >= 10'), [
        [0]
      ]);
    });

    test('upsert and returning', () {
      x('CREATE TABLE c (k TEXT PRIMARY KEY, n INT DEFAULT 0)');
      for (var i = 0; i < 3; i++) {
        x("INSERT INTO c (k, n) VALUES ('a', 1) ON CONFLICT (k) DO UPDATE SET n = n + excluded.n");
      }
      x("INSERT INTO c VALUES ('a', 100) ON CONFLICT DO NOTHING");
      expect(q('SELECT * FROM c'), [
        ['a', 3]
      ]);
      final r = x("INSERT INTO c VALUES ('b', 5), ('c', 6) RETURNING k, n * 2");
      expect(r.rows, [
        ['b', 10],
        ['c', 12]
      ]);
      expect(x("UPDATE c SET n = n + 1 WHERE k > 'a' RETURNING *").rows.length, 2);
      expect(x("DELETE FROM c WHERE k = 'c' RETURNING n").rows, [
        [7]
      ]);
      x("INSERT INTO c VALUES ('b', 1) ON CONFLICT (k) DO UPDATE SET n = 0 WHERE excluded.n > 10");
      expect(q("SELECT n FROM c WHERE k = 'b'"), [
        [6]
      ]);
    });

    test('transactions', () {
      final store = ZxMemoryStore();
      sql = ZxSql(store);
      x('CREATE TABLE t (a)');
      final g0 = store.generations.length;
      x('BEGIN');
      x('INSERT INTO t VALUES (1)');
      x('INSERT INTO t VALUES (2)');
      expect(q('SELECT count(*) FROM t'), [
        [2]
      ]);
      // Another session does not see uncommitted rows.
      expect(ZxSql(store).select('SELECT count(*) FROM t'), [
        [0]
      ]);
      x('COMMIT');
      expect(store.generations.length, g0 + 1);
      expect(ZxSql(store).select('SELECT count(*) FROM t'), [
        [2]
      ]);
      x('BEGIN');
      x('DELETE FROM t');
      x('ROLLBACK');
      expect(q('SELECT count(*) FROM t'), [
        [2]
      ]);
      // A failing statement inside a transaction leaves no partial rows.
      x('CREATE TABLE u (a INTEGER PRIMARY KEY)');
      x('BEGIN');
      x('INSERT INTO u VALUES (1)');
      expect(() => x('INSERT INTO u VALUES (2), (1)'), throwsA(isA<ZxDbException>()));
      x('COMMIT');
      expect(q('SELECT a FROM u'), [
        [1]
      ]);
      expect(() => x('COMMIT'), throwsA(isA<ZxDbException>()));
    });

    test('errors', () {
      Matcher kind(ZxDbError k, [String? m]) => throwsA(isA<ZxDbException>()
          .having((e) => e.kind, 'kind', k)
          .having((e) => e.message, 'msg', contains(m ?? '')));
      expect(() => x('SELEC 1'), kind(ZxDbError.syntax, 'near "SELEC"'));
      expect(() => x('SELECT (1'), kind(ZxDbError.syntax, 'incomplete input'));
      expect(() => x('SELECT * FROM nope'), kind(ZxDbError.generic, 'no such table: nope'));
      expect(() => x('SELECT nope'), kind(ZxDbError.generic, 'no such column: nope'));
      expect(() => x('SELECT nofn(1)'), kind(ZxDbError.generic, 'no such function: nofn'));
      x('CREATE TABLE a (x); CREATE TABLE b (x)');
      expect(() => x('SELECT x FROM a, b'), kind(ZxDbError.generic, 'ambiguous column name: x'));
      expect(() => x('CREATE TABLE a (y)'), kind(ZxDbError.generic, 'already exists'));
      x('CREATE TABLE IF NOT EXISTS a (y)');
      expect(() => x('SELECT count(*) FROM a WHERE count(*) > 1'), kind(ZxDbError.generic, 'aggregate'));
      expect(() => x('CREATE KV STORE s'), kind(ZxDbError.unsupported, 'not yet'));
      expect(() => x("CREATE TIMESERIES logs (ts DATETIME, msg TEXT) PARTITION BY DAY RETENTION '400d' WITH (compression = 'max')"),
          kind(ZxDbError.unsupported, 'not yet'));
      expect(() => x("CREATE ROLLUP r AS SELECT 1 EVERY '1h'"), kind(ZxDbError.unsupported, 'not yet'));
    });

    test('ddl: drop, alter, views', () {
      x('CREATE TABLE t (a INTEGER PRIMARY KEY, b TEXT)');
      x("INSERT INTO t VALUES (1, 'x'), (2, 'y')");
      x('CREATE INDEX tb ON t(b)');
      x('ALTER TABLE t ADD COLUMN c INT DEFAULT 5');
      expect(q('SELECT * FROM t'), [
        [1, 'x', 5],
        [2, 'y', 5]
      ]);
      x('ALTER TABLE t RENAME TO t2');
      expect(q("SELECT a FROM t2 WHERE b = 'y'"), [
        [2]
      ]);
      expect(x("EXPLAIN QUERY PLAN SELECT a FROM t2 WHERE b = 'y'").rows[0][3], contains('USING COVERING INDEX tb'));
      x('ALTER TABLE t2 RENAME COLUMN b TO bb');
      expect(q("SELECT a FROM t2 WHERE bb = 'x'"), [
        [1]
      ]);
      x('ALTER TABLE t2 DROP COLUMN c');
      expect(x('SELECT * FROM t2').columns, ['a', 'bb']);
      x('CREATE VIEW v AS SELECT a * 10 AS ten, bb FROM t2');
      expect(q('SELECT * FROM v ORDER BY ten DESC'), [
        [20, 'y'],
        [10, 'x']
      ]);
      expect(() => x('INSERT INTO v VALUES (1, 2)'), throwsA(isA<ZxDbException>()));
      x('DROP VIEW v');
      x('DROP INDEX tb');
      x('DROP TABLE t2');
      expect(() => x('SELECT * FROM t2'), throwsA(isA<ZxDbException>()));
      x('DROP TABLE IF EXISTS t2');
      expect(q("SELECT count(*) FROM sqlite_schema"), [
        [0]
      ]);
    });

    test('create table as, pragma, schema', () {
      x('CREATE TABLE t (a INTEGER PRIMARY KEY, b TEXT NOT NULL DEFAULT \'q\', c REAL)');
      x('CREATE UNIQUE INDEX tc ON t(c)');
      x("INSERT INTO t VALUES (1, 'x', 1.5)");
      x('CREATE TABLE t3 AS SELECT a, b || b AS bb FROM t');
      expect(q('SELECT * FROM t3'), [
        [1, 'xx']
      ]);
      expect(q('PRAGMA table_info(t)'), [
        [0, 'a', 'INTEGER', 0, null, 1],
        [1, 'b', 'TEXT', 1, "'q'", 0],
        [2, 'c', 'REAL', 0, null, 0],
      ]);
      expect(q('PRAGMA index_list(t)').map((r) => r[1]), ['tc']);
      x('PRAGMA user_version = 7');
      expect(q('PRAGMA user_version'), [
        [7]
      ]);
      expect(q("SELECT type, name FROM sqlite_master WHERE name = 'tc'"), [
        ['index', 'tc']
      ]);
    });

    test('query plans use indexes', () {
      x('CREATE TABLE t (id INTEGER PRIMARY KEY, a INT, b TEXT, c REAL)');
      x('CREATE INDEX ta ON t(a)');
      x('CREATE INDEX tbc ON t(b, c)');
      x('CREATE TABLE u (id INTEGER PRIMARY KEY, tid INT, v TEXT)');
      x('WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 200) '
          "INSERT INTO t SELECT i, i % 17, 'b' || (i % 5), i * 0.5 FROM n");
      x('INSERT INTO u SELECT id, id, \'v\' FROM t');
      String plan(String s) => x('EXPLAIN QUERY PLAN $s').rows.map((r) => r[3]).join(' | ');
      expect(plan('SELECT * FROM t WHERE id = 5'), contains('USING INTEGER PRIMARY KEY (rowid=?)'));
      expect(plan('SELECT * FROM t WHERE a = 3'), contains('SEARCH t USING INDEX ta (a=?)'));
      expect(plan('SELECT a FROM t WHERE a > 3'), contains('USING COVERING INDEX ta (a>?)'));
      expect(plan("SELECT * FROM t WHERE b = 'b1' AND c > 10"), contains('USING INDEX tbc (b=? AND c>?)'));
      expect(plan('SELECT * FROM t WHERE a IN (1, 2)'), contains('USING INDEX ta (a=?)'));
      expect(plan('SELECT * FROM t ORDER BY a'), isNot(contains('TEMP B-TREE')));
      expect(plan('SELECT * FROM t ORDER BY c'), contains('USE TEMP B-TREE FOR ORDER BY'));
      expect(plan('SELECT * FROM t WHERE id BETWEEN 5 AND 9'), contains('rowid>=? AND rowid<=?'));
      expect(plan('SELECT * FROM u JOIN t ON t.id = u.tid'), contains('SEARCH t USING INTEGER PRIMARY KEY'));
      expect(plan('SELECT * FROM t JOIN u ON u.tid = t.a'), contains('AUTOMATIC'));
      expect(plan('SELECT * FROM t WHERE a = (SELECT max(tid) FROM u)'), contains('SCALAR SUBQUERY'));
      // Results agree with and without indexes.
      expect(q("SELECT count(*), sum(id) FROM t WHERE b = 'b1' AND c > 10"),
          q("SELECT count(*), sum(id) FROM t NOT INDEXED WHERE b = 'b1' AND c > 10"));
      expect(q('SELECT id FROM t WHERE a IN (1, 2) ORDER BY id'),
          q('SELECT id FROM t NOT INDEXED WHERE a IN (1, 2) ORDER BY id'));
      expect(q('SELECT a, id FROM t WHERE a >= 15 ORDER BY a DESC, id'),
          q('SELECT a, id FROM t NOT INDEXED WHERE a >= 15 ORDER BY a DESC, id'));
    });

    test('zx types', () {
      x('CREATE TABLE z (flag BOOLEAN, at DATETIME, doc JSON, tags ARRAY)');
      x("INSERT INTO z VALUES ('true', '2024-01-02 03:04:05.123456789', '{\"a\": 1}', '[\"x\",\"y\"]')");
      final r = q('SELECT flag, at, typeof(at), doc, tags FROM z');
      expect(r[0][0], 1);
      expect(r[0][1], DateTime.utc(2024, 1, 2, 3, 4, 5).microsecondsSinceEpoch * 1000 + 123456789);
      expect(r[0][2], 'integer');
      expect(q("SELECT json_object('d', doc), zx_datetime(at) FROM z"), [
        ['{"d":{"a":1}}', '2024-01-02 03:04:05.123456789']
      ]);
      expect(() => x("INSERT INTO z (doc) VALUES ('{bad')"), throwsA(isA<ZxDbException>()));
      expect(() => x("INSERT INTO z (tags) VALUES ('{}')"), throwsA(isA<ZxDbException>()));
      x('INSERT INTO z (at) VALUES (?)', [DateTime.utc(2000)]);
      expect(q('SELECT at FROM z WHERE flag IS NULL'), [
        [946684800000000000]
      ]);
    });

    test('table options and tree names', () {
      final store = ZxMemoryStore();
      sql = ZxSql(store);
      x("CREATE TABLE n (a INTEGER PRIMARY KEY, b) WITH (compression = 'fast', page_size = '16k')");
      final s = store.snapshot();
      expect(s.tree('t:n')!.options.compression, 'fast');
      expect(s.tree('t:n')!.options.pageSize, 16384);
      s.close();
      x("ALTER TABLE n SET (compression = 'max')");
      final s2 = store.snapshot();
      expect(s2.tree('t:n')!.options.compression, 'max');
      s2.close();
      expect(q("SELECT sql FROM sqlite_schema WHERE name = 'n'")[0][0], contains("WITH (compression = 'max', page_size = '16k')"));
    });

    test('AS OF and HISTORY OF', () {
      var clock = 1000;
      final store = ZxMemoryStore(clock: () => clock);
      sql = ZxSql(store);
      x('CREATE TABLE h (id INTEGER PRIMARY KEY, v TEXT)');
      clock = 2000;
      x("INSERT INTO h VALUES (1, 'a')");
      final g = store.generations.last.generation;
      clock = 3000;
      x("UPDATE h SET v = 'b' WHERE id = 1");
      clock = 4000;
      x("INSERT INTO h VALUES (2, 'c')");
      clock = 5000;
      x('DELETE FROM h WHERE id = 1');
      expect(q('SELECT v FROM h'), [
        ['c']
      ]);
      expect(q('SELECT v FROM h AS OF GENERATION $g'), [
        ['a']
      ]);
      expect(q('SELECT v FROM h AS OF 3500 ORDER BY id'), [
        ['b']
      ]);
      expect(q('SELECT id, v, zx_op FROM HISTORY OF h ORDER BY zx_generation, id'), [
        [1, 'a', 'insert'],
        [1, 'b', 'update'],
        [2, 'c', 'insert'],
        [1, 'b', 'delete'],
      ]);
    });

    test('virtual tables and functions', () {
      sql.registerVirtualTable('nums', _Nums());
      sql.functions.addScalar('twice', 1, (a, c) => (a[0] as int) * 2);
      expect(q('SELECT n, twice(n) FROM nums WHERE n < 4'), [
        [0, 0],
        [1, 2],
        [2, 4],
        [3, 6]
      ]);
      expect(q('SELECT count(*) FROM nums(5)'), [
        [5]
      ]);
      expect(x('EXPLAIN QUERY PLAN SELECT * FROM nums WHERE n < 4').rows[0][3], contains('VIRTUAL TABLE INDEX 1'));
      x('CREATE TABLE t (x)');
      x('INSERT INTO t SELECT n FROM nums(3)');
      expect(q('SELECT t.x, nums.n FROM t JOIN nums(3) ON nums.n = t.x ORDER BY 1'), [
        [0, 0],
        [1, 1],
        [2, 2]
      ]);
      // Writable virtual table with conflict modes.
      final w = _Kv();
      sql.registerVirtualTable('kvt', w);
      x("INSERT INTO kvt VALUES ('a', 1)");
      expect(() => x("INSERT INTO kvt VALUES ('a', 2)"), throwsA(isA<ZxDbException>()));
      x("INSERT OR IGNORE INTO kvt VALUES ('a', 3)");
      expect(w.data, {'a': 1});
      x("INSERT OR REPLACE INTO kvt VALUES ('a', 4)");
      expect(w.data, {'a': 4});
      x("INSERT INTO kvt VALUES ('a', 5) ON CONFLICT DO UPDATE SET v = v + excluded.v");
      expect(w.data, {'a': 9});
      x("UPDATE kvt SET v = v * 2 WHERE k = 'a'");
      expect(w.data, {'a': 18});
      x("DELETE FROM kvt WHERE k = 'a'");
      expect(w.data, isEmpty);
    });

    test('statement hooks', () {
      sql.registerStatementHook('CREATE KV STORE', (st, ctx) {
        final s = st as dynamic;
        ctx.txn!.createTree('kv:${s.name}');
        return ZxSqlResult(const ['name'], [
          [s.name]
        ], 0, 0);
      });
      expect(x("CREATE KV STORE cache WITH (ttl = '7d', compression = 'fast')").rows, [
        ['cache']
      ]);
    });

    test('large data and ordering', () {
      x('CREATE TABLE big (id INTEGER PRIMARY KEY, g INT, s TEXT)');
      x('CREATE INDEX big_g ON big(g, s)');
      x('BEGIN');
      final st = sql.prepare('INSERT INTO big (g, s) VALUES (?, ?)');
      final r = Random(1);
      for (var i = 0; i < 3000; i++) {
        st.execute([r.nextInt(50), 's${r.nextInt(1000)}']);
      }
      x('COMMIT');
      final a = q('SELECT g, count(*), min(s), max(s) FROM big GROUP BY g ORDER BY g');
      expect(a.length, 50);
      final b = q('SELECT g, s FROM big WHERE g = 7 ORDER BY s');
      final c = q('SELECT g, s FROM big NOT INDEXED WHERE g = 7 ORDER BY s');
      expect(b, c);
      expect(q('SELECT count(*) FROM big WHERE g BETWEEN 10 AND 19'),
          q('SELECT count(*) FROM big NOT INDEXED WHERE g BETWEEN 10 AND 19'));
    });
  });

  test('on the archive store (ZxDbStore)', () {
    final dir = Directory.systemTemp.createTempSync('zxdb_sql');
    try {
      final path = '${dir.path}/a.zx';
      var store = ZxDbStore.open(path, create: true);
      var s = ZxSql(store);
      s.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, a TEXT, n INT) WITH (compression = 'fast')");
      s.execute('CREATE INDEX tn ON t(n)');
      final g = store.generations.last.generation;
      s.execute('BEGIN');
      final st = s.prepare('INSERT INTO t (a, n) VALUES (?, ?)');
      for (var i = 0; i < 2000; i++) {
        st.execute(['row $i', i % 100]);
      }
      s.execute('COMMIT');
      s.execute("UPDATE t SET a = 'x' WHERE n = 5");
      expect(s.select('SELECT count(*), sum(n) FROM t WHERE n BETWEEN 10 AND 20'), [
        [220, 3300]
      ]);
      store.close();
      store = ZxDbStore.open(path);
      s = ZxSql(store);
      expect(s.select("SELECT count(*) FROM t WHERE a = 'x'"), [
        [20]
      ]);
      expect(s.execute('EXPLAIN QUERY PLAN SELECT * FROM t WHERE n = 3').rows[0][3], contains('USING INDEX tn'));
      expect(s.select('SELECT count(*) FROM t AS OF GENERATION $g'), [
        [0]
      ]);
      store.close();
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  // ---------------------------------------------------------- differential
  final sqlite = _sqlite3();
  group('differential vs sqlite3', () {
    final cases = [for (final qq in _queries) _Case(_schema, qq)];
    for (var i = 0; i < cases.length; i++) {
      final c = cases[i];
      test('#$i ${c.query.length > 60 ? c.query.substring(0, 60) : c.query}', () {
        final input = '${c.setup}\n.mode quote\n${c.query};\n';
        final p = Process.start(sqlite!, [':memory:']);
        final res = p.then((proc) async {
          proc.stdin.write(input);
          await proc.stdin.close();
          final out = await proc.stdout.transform(const SystemEncoding().decoder).join();
          final err = await proc.stderr.transform(const SystemEncoding().decoder).join();
          await proc.exitCode;
          return (out, err);
        });
        return res.then((r) {
          final (out, err) = r;
          final s = ZxSql(ZxMemoryStore());
          s.execute(c.setup);
          if (err.trim().isNotEmpty) {
            expect(() => s.execute(c.query), throwsA(isA<ZxDbException>()),
                reason: 'sqlite3 failed: $err');
            return;
          }
          final expected = parseQuote(out);
          var got = s.execute(c.query).rows;
          var exp = expected;
          final ordered = RegExp(r'ORDER BY [^)]*$', caseSensitive: false).hasMatch(c.query) &&
              !c.query.contains('random');
          if (!ordered) {
            got = [...got]..sort(_rowCmp);
            exp = [...exp]..sort(_rowCmp);
          }
          final ok = got.length == exp.length &&
              [for (var k = 0; k < got.length; k++) got[k].length == exp[k].length &&
                  [for (var j = 0; j < got[k].length; j++) _valEq(got[k][j], exp[k][j])].every((v) => v)]
                  .every((v) => v);
          expect(ok, isTrue, reason: 'query: ${c.query}\nsqlite3:\n${_fmt(exp)}\nzxdb:\n${_fmt(got)}');
        });
      });
    }
    for (var i = 0; i < _scripts.length; i++) {
      final c = _scripts[i];
      test('script #$i', () => _diff(sqlite!, c));
    }
    test('random expressions', () {
      final r = Random(int.tryParse(Platform.environment['ZXDB_FUZZ_SEED'] ?? '') ?? 42);
      final count = int.tryParse(Platform.environment['ZXDB_FUZZ_N'] ?? '') ?? 600;
      const setup = '''CREATE TABLE mixed (a, b TEXT, c NUMERIC, d INTEGER, e REAL);
INSERT INTO mixed VALUES (1,'1','1','1','1'),(2.5,'2.5','2.5','2.5','2.5'),('x','x','x','x','x'),(NULL,NULL,NULL,NULL,NULL),
 (x'01',x'01',x'01',x'01',x'01'),('10',10,'10.0',' 10 ',10),(-3,'-3','-3e0','0x10','1e2'),(0,'',0.0,0,-0.5);''';
      final queries = <String>[];
      for (var k = 0; k < count; k++) {
        if (k.isEven) {
          queries.add('SELECT ${_rndExpr(r, 3)}, ${_rndExpr(r, 3)} FROM mixed ORDER BY rowid');
        } else {
          queries.add('SELECT rowid FROM mixed WHERE ${_rndExpr(r, 3)} ORDER BY rowid');
        }
      }
      final input = StringBuffer('$setup\n.mode quote\n');
      for (final qq in queries) {
        input.write("$qq;\n.print '#SEP#'\n");
      }
      final tmp = File('${Directory.systemTemp.path}/zxdb_sql_fuzz_$pid.sql')
        ..writeAsStringSync(input.toString());
      final pr = Process.runSync('/bin/sh', ['-c', '$sqlite :memory: < ${tmp.path} 2>&1']);
      tmp.deleteSync();
      final chunks = (pr.stdout as String).split('#SEP#\n');
      expect(chunks.length, queries.length + 1);
      final s = ZxSql(ZxMemoryStore());
      s.execute(setup);
      var compared = 0;
      final failures = <String>[];
      for (var k = 0; k < queries.length; k++) {
        final out = chunks[k];
        if (out.contains('Error') || out.contains('error')) continue;
        List<List<Object?>> got;
        try {
          got = s.execute(queries[k]).rows;
        } catch (e) {
          failures.add('${queries[k]}\n  zxdb error: $e\n  sqlite3: $out');
          continue;
        }
        final exp = parseQuote(out);
        final ok = got.length == exp.length &&
            [for (var i = 0; i < got.length; i++) got[i].length == exp[i].length &&
                [for (var j = 0; j < got[i].length; j++) _valEq(got[i][j], exp[i][j])].every((v) => v)]
                .every((v) => v);
        compared++;
        if (!ok) failures.add('${queries[k]}\n  sqlite3:\n${_fmt(exp)}\n  zxdb:\n${_fmt(got)}');
      }
      expect(compared, greaterThan(count ~/ 2));
      expect(failures, isEmpty, reason: failures.take(8).join('\n\n'));
    });
    test('random queries (planner)', () {
      final r = Random(int.tryParse(Platform.environment['ZXDB_FUZZ_SEED'] ?? '') ?? 5);
      final count = int.tryParse(Platform.environment['ZXDB_FUZZ_N'] ?? '') ?? 300;
      final setup = StringBuffer('''CREATE TABLE t (id INTEGER PRIMARY KEY, a INT, b TEXT, c REAL, d);
CREATE INDEX ta ON t(a);
CREATE INDEX tbc ON t(b, c DESC);
CREATE UNIQUE INDEX td ON t(d);
CREATE TABLE u (k INTEGER PRIMARY KEY, a INT, s TEXT COLLATE NOCASE);
CREATE INDEX us ON u(s);
''');
      Object? val() => switch (r.nextInt(6)) {
            0 => null,
            1 => r.nextInt(10),
            2 => r.nextInt(20) / 4,
            3 => "'${String.fromCharCode(97 + r.nextInt(4))}${r.nextInt(3)}'",
            4 => "'${r.nextInt(10)}'",
            _ => r.nextInt(5) - 2,
          };
      for (var i = 1; i <= 60; i++) {
        setup.write('INSERT INTO t VALUES ($i, ${val()}, ${val()}, ${val()}, ${i % 7 == 0 ? 'NULL' : i * 3});\n');
      }
      for (var i = 1; i <= 25; i++) {
        final sv = r.nextInt(4) == 0 ? 'NULL' : "'${['x', 'X', 'y', 'Y', 'z'][r.nextInt(5)]}${r.nextInt(3)}'";
        setup.write('INSERT INTO u VALUES ($i, ${val()}, $sv);\n');
      }
      String lit() {
        final v = val();
        return v == null ? 'NULL' : '$v';
      }

      String pred(String q, int depth) {
        const cols = ['a', 'b', 'c', 'id', 'd'];
        String col() => '$q${cols[r.nextInt(cols.length)]}';
        if (depth > 0 && r.nextInt(3) == 0) {
          return '(${pred(q, depth - 1)} ${r.nextBool() ? 'AND' : 'OR'} ${pred(q, depth - 1)})';
        }
        switch (r.nextInt(7)) {
          case 0:
            return '${col()} IN (${lit()}, ${lit()}, ${lit()})';
          case 1:
            return '${col()} BETWEEN ${lit()} AND ${lit()}';
          case 2:
            return '${col()} IS ${r.nextBool() ? 'NOT ' : ''}NULL';
          case 3:
            return '${col()} IN (SELECT a FROM u WHERE k < ${r.nextInt(25)})';
          default:
            const ops = ['=', '<', '<=', '>', '>=', '!=', 'IS'];
            return '${col()} ${ops[r.nextInt(ops.length)]} ${lit()}';
        }
      }

      final queries = <String>[];
      for (var k = 0; k < count; k++) {
        switch (r.nextInt(5)) {
          case 0:
            queries.add('SELECT id, a, b, c FROM t WHERE ${pred('', 2)}');
          case 1:
            queries.add('SELECT a, count(*), sum(c), min(b), max(d) FROM t WHERE ${pred('', 1)} GROUP BY a');
          case 2:
            queries.add('SELECT t.id, u.k, u.s FROM t JOIN u ON u.a = t.a WHERE ${pred('t.', 1)}');
          case 3:
            queries.add('SELECT t.id, u.k FROM t LEFT JOIN u ON u.k = t.a AND u.s > ${lit()} WHERE ${pred('t.', 1)}');
          default:
            final o = ['a', 'b', 'c', 'd', 'id'][r.nextInt(5)];
            queries.add('SELECT $o, id FROM t WHERE ${pred('', 1)} ORDER BY $o ${r.nextBool() ? 'DESC' : 'ASC'}, id LIMIT ${r.nextInt(8) + 1}');
        }
      }
      final input = StringBuffer('$setup\n.mode quote\n');
      for (final qq in queries) {
        input.write("$qq;\n.print '#SEP#'\n");
      }
      final tmp = File('${Directory.systemTemp.path}/zxdb_sql_qfuzz_$pid.sql')
        ..writeAsStringSync(input.toString());
      final pr = Process.runSync('/bin/sh', ['-c', '$sqlite :memory: < ${tmp.path} 2>&1']);
      tmp.deleteSync();
      final chunks = (pr.stdout as String).split('#SEP#\n');
      expect(chunks.length, queries.length + 1);
      final s = ZxSql(ZxMemoryStore());
      s.execute(setup.toString());
      final failures = <String>[];
      var rowsCompared = 0;
      for (var k = 0; k < queries.length; k++) {
        final out = chunks[k];
        if (out.contains('rror')) {
          failures.add('${queries[k]}\n  sqlite3 error: $out');
          continue;
        }
        List<List<Object?>> got;
        try {
          got = s.execute(queries[k]).rows;
        } catch (e) {
          failures.add('${queries[k]}\n  zxdb error: $e');
          continue;
        }
        var exp = parseQuote(out);
        if (!queries[k].contains('ORDER BY')) {
          got = [...got]..sort(_rowCmp);
          exp = [...exp]..sort(_rowCmp);
        }
        final ok = got.length == exp.length &&
            [for (var i = 0; i < got.length; i++) got[i].length == exp[i].length &&
                [for (var j = 0; j < got[i].length; j++) _valEq(got[i][j], exp[i][j])].every((v) => v)]
                .every((v) => v);
        if (!ok) failures.add('${queries[k]}\n  sqlite3:\n${_fmt(exp)}\n  zxdb:\n${_fmt(got)}');
        rowsCompared += exp.length;
      }
      expect(rowsCompared, greaterThan(count));
      expect(failures, isEmpty, reason: failures.take(5).join('\n\n'));
    });
  }, skip: sqlite == null ? 'sqlite3 not installed' : null);
}

Future<void> _diff(String sqlite, _Case c) async {
  final proc = await Process.start(sqlite, [':memory:']);
  proc.stdin.write('${c.setup}\n.mode quote\n${c.query};\n');
  await proc.stdin.close();
  final out = await proc.stdout.transform(const SystemEncoding().decoder).join();
  final err = await proc.stderr.transform(const SystemEncoding().decoder).join();
  await proc.exitCode;
  final s = ZxSql(ZxMemoryStore());
  if (err.trim().isNotEmpty) {
    expect(() {
      s.execute(c.setup);
      s.execute(c.query);
    }, throwsA(isA<ZxDbException>()), reason: 'sqlite3 failed: $err');
    return;
  }
  s.execute(c.setup);
  final exp = parseQuote(out);
  final got = s.execute(c.query).rows;
  final ok = got.length == exp.length &&
      [for (var k = 0; k < got.length; k++) got[k].length == exp[k].length &&
          [for (var j = 0; j < got[k].length; j++) _valEq(got[k][j], exp[k][j])].every((v) => v)]
          .every((v) => v);
  expect(ok, isTrue, reason: 'query: ${c.query}\nsqlite3:\n${_fmt(exp)}\nzxdb:\n${_fmt(got)}');
}

class _Nums extends ZxVirtualTable {
  @override
  List<ZxVtabColumn> get columns => const [ZxVtabColumn('n', 'INTEGER'), ZxVtabColumn('count', null, true)];

  @override
  void bestIndex(ZxIndexInfo info) {
    for (var i = 0; i < info.constraints.length; i++) {
      final c = info.constraints[i];
      if (c.usable && c.column == 1 && c.op == ZxConstraintOp.eq) {
        info.argvIndex[i] = 1;
        info.omit[i] = true;
        info.idxNum = 2;
        return;
      }
    }
    for (var i = 0; i < info.constraints.length; i++) {
      final c = info.constraints[i];
      if (c.usable && c.column == 0 && c.op == ZxConstraintOp.lt) {
        info.argvIndex[i] = 1;
        info.idxNum = 1;
        return;
      }
    }
  }

  @override
  ZxVtabCursor open(ZxVtabContext ctx) => _NumsCursor();
}

class _NumsCursor extends ZxVtabCursor {
  int _i = -1, _end = 100, _count = 100;
  @override
  void filter(int idxNum, String? idxStr, List<Object?> args) {
    _i = -1;
    _end = 100;
    if (idxNum == 1) _end = args[0] as int;
    if (idxNum == 2) _end = _count = args[0] as int;
  }

  @override
  bool next() => ++_i < _end;
  @override
  Object? column(int i) => i == 0 ? _i : _count;
  @override
  int get rowid => _i;
}

class _Kv extends ZxWritableVirtualTable {
  final Map<String, Object?> data = {};
  final List<String> _ids = [];

  @override
  List<ZxVtabColumn> get columns => const [ZxVtabColumn('k', 'TEXT'), ZxVtabColumn('v')];

  int _id(String k) {
    var i = _ids.indexOf(k);
    if (i < 0) {
      _ids.add(k);
      i = _ids.length - 1;
    }
    return i;
  }

  @override
  ZxVtabCursor open(ZxVtabContext ctx) => _KvCursor(this);

  @override
  int insert(ZxVtabContext ctx, int? rowid, List<Object?> values) {
    final k = values[0] as String;
    if (data.containsKey(k)) throw const ZxDbException('UNIQUE constraint failed: kvt.k', ZxDbError.constraint);
    data[k] = values[1];
    return _id(k);
  }

  @override
  int? insertOr(ZxVtabContext ctx, int? rowid, List<Object?> values, ZxConflictMode mode) {
    if (mode == ZxConflictMode.replace) data.remove(values[0]);
    return super.insertOr(ctx, rowid, values, mode);
  }

  @override
  (int, List<Object?>)? findConflict(ZxVtabContext ctx, List<Object?> values) {
    final k = values[0] as String;
    if (!data.containsKey(k)) return null;
    return (_id(k), [k, data[k]]);
  }

  @override
  void update(ZxVtabContext ctx, int rowid, List<Object?> values) {
    data.remove(_ids[rowid]);
    data[values[0] as String] = values[1];
    _id(values[0] as String);
  }

  @override
  void delete(ZxVtabContext ctx, int rowid) => data.remove(_ids[rowid]);
}

class _KvCursor extends ZxVtabCursor {
  final _Kv t;
  List<String> keys = [];
  int i = -1;
  _KvCursor(this.t);
  @override
  void filter(int idxNum, String? idxStr, List<Object?> args) {
    keys = t.data.keys.toList();
    i = -1;
  }

  @override
  bool next() => ++i < keys.length;
  @override
  Object? column(int c) => c == 0 ? keys[i] : t.data[keys[i]];
  @override
  int get rowid => t._id(keys[i]);
}
