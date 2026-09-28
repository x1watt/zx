// `zx sql`: batch runs, scripts on the standard input, the dot commands
// and the output modes (checked against fixed text and, where the sqlite3
// program is installed, against its output for the same statements).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/cli/line_editor.dart';
import 'package:zx/src/cli/main.dart';
import 'package:zx/src/cli/sql_shell.dart';
import 'package:zx/src/crypto/sha256.dart';

class Run {
  final int code;
  final String out;
  final String err;
  Run(this.code, this.out, this.err);
  @override
  String toString() => 'exit $code\n--- out\n$out--- err\n$err';
}

Future<Run> zx(List<String> args, {String? stdin, String? cwd}) async {
  final o = BytesBuilder();
  final e = BytesBuilder();
  final code = await runSevenZipCli(args,
      stdout: o.add,
      stderr: e.add,
      stdin: stdin == null ? null : Uint8List.fromList(utf8.encode(stdin)),
      workingDirectory: cwd);
  return Run(code, utf8.decode(o.takeBytes()), utf8.decode(e.takeBytes()));
}

String? findSqlite3() {
  for (final p in ['/usr/bin/sqlite3', 'ref/tools/root/usr/bin/sqlite3']) {
    if (File(p).existsSync()) return p;
  }
  return null;
}

const setupSql = [
  'CREATE TABLE t (a INTEGER, b TEXT, c REAL)',
  "INSERT INTO t VALUES (1, 'x,y', 1.5), (22, 'he said \"hi\"', NULL), "
      "(-3, 'u v', 1e20), (4, '', 0.1)",
];

void main() {
  late Directory tmp;
  late String arc;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('zx_sql_');
    arc = '${tmp.path}/a.zx';
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  group('splitting', () {
    test('statements, quotes and comments', () {
      final (s, rest) = splitSqlStatements(
          "select 'a;b';\n-- x;\nselect \"c;\" /* ; */ ;\nselect [d;]; sel");
      expect([for (final x in s) x.$1],
          ["select 'a;b'", '-- x;\nselect "c;" /* ; */', 'select [d;]']);
      expect([for (final x in s) x.$2], [1, 3, 4]);
      expect(rest.trim(), 'sel');
      expect(sqlIsComplete("select 'it''s;"), isFalse);
      expect(sqlIsComplete("select 'it''s';"), isTrue);
      expect(sqlIsComplete('-- only a comment'), isFalse);
      final (s2, r2) = splitSqlStatements('select 1; -- trailing');
      expect(s2.length, 1);
      expect(r2, '');
    });

    test('csv parsing', () {
      expect(parseCsv('a,b\r\n"x ""y""",\n1,"2\n3"\n'), [
        ['a', 'b'],
        ['x "y"', ''],
        ['1', '2\n3'],
      ]);
    });
  });

  group('batch', () {
    test('modes', () async {
      var r = await zx(['sql', arc, ...setupSql, 'SELECT * FROM t']);
      expect(r.code, 0, reason: '$r');
      expect(r.out, '1|x,y|1.5\n22|he said "hi"|\n-3|u v|1.0e+20\n4||0.1\n');
      r = await zx(['sql', '-table', arc, 'SELECT * FROM t']);
      expect(r.out, '''
+----+--------------+---------+
| a  |      b       |    c    |
+----+--------------+---------+
| 1  | x,y          | 1.5     |
| 22 | he said "hi" |         |
| -3 | u v          | 1.0e+20 |
| 4  |              | 0.1     |
+----+--------------+---------+
''');
      r = await zx(['sql', '-csv', '-header', arc, 'SELECT * FROM t']);
      expect(r.out,
          'a,b,c\n1,"x,y",1.5\n22,"he said ""hi""",\n-3,"u v",1.0e+20\n4,"",0.1\n');
      r = await zx(['sql', '-json', arc, 'SELECT * FROM t WHERE a > 0']);
      expect(r.out, '[{"a":1,"b":"x,y","c":1.5},\n'
          '{"a":22,"b":"he said \\"hi\\"","c":null},\n'
          '{"a":4,"b":"","c":0.1}]\n');
      r = await zx(['sql', '-line', arc, 'SELECT a, b AS longname FROM t LIMIT 2']);
      expect(r.out, '       a = 1\nlongname = x,y\n\n       a = 22\n'
          'longname = he said "hi"\n');
      r = await zx(['sql', '-markdown', arc, 'SELECT a, b FROM t LIMIT 1']);
      expect(r.out, '| a |  b  |\n|---|-----|\n| 1 | x,y |\n');
      r = await zx(['sql', '-box', arc, 'SELECT a FROM t LIMIT 1']);
      expect(r.out, '\u250c\u2500\u2500\u2500\u2510\n\u2502 a \u2502\n'
          '\u251c\u2500\u2500\u2500\u2524\n\u2502 1 \u2502\n'
          '\u2514\u2500\u2500\u2500\u2518\n');
      r = await zx(['sql', '-quote', arc, "SELECT 1, 'it''s', x'00ff', NULL"]);
      expect(r.out, "1,'it''s',X'00ff',NULL\n");
      // no rows: no output, also no header
      r = await zx(['sql', '-header', '-table', arc, 'SELECT * FROM t WHERE 0']);
      expect(r.out, '');
    });

    test('same output as sqlite3', () async {
      final sq = findSqlite3();
      if (sq == null) {
        markTestSkipped('no sqlite3');
        return;
      }
      final db = '${tmp.path}/s.db';
      // reals that print the same with 15 digits (json and quote modes
      // print more digits than sqlite3's 20 digit rendering, see
      // docs/zxdb-sql.md)
      final setup = [
        for (final s in setupSql) s.replaceAll('0.1)', '0.25)')
      ];
      final p = Process.runSync(sq, [db, ...setup]);
      expect(p.exitCode, 0, reason: '${p.stderr}');
      await zx(['sql', arc, ...setup]);
      const queries = [
        'SELECT * FROM t',
        'SELECT a, b, c, a * 2.5, typeof(c) FROM t ORDER BY a',
        'SELECT 1.0 / 3, 0.1 + 0.2 FROM t LIMIT 1',
        "SELECT 'multi\nline' AS m, 'tab\there' AS t2, 42 AS n",
        'SELECT count(*), sum(a), avg(a), 1e15, 2.0 FROM t',
      ];
      for (final mode in [
        'list', 'csv', 'json', 'line', 'table', 'box', 'markdown', 'quote', //
        'tabs',
      ]) {
        for (final q in queries) {
          if (q.contains('1.0 / 3') && (mode == 'json' || mode == 'quote')) {
            continue;
          }
          for (final h in ['-header', '-noheader']) {
            final s = Process.runSync(sq, ['-$mode', h, db, q],
                stdoutEncoding: utf8);
            final z = await zx(['sql', '-$mode', h, arc, q]);
            expect(z.out, s.stdout, reason: '$mode $h $q');
          }
        }
      }
      // .mode csv in a script uses CRLF, as sqlite3 does
      final s = Process.runSync(sq, [db],
          stdoutEncoding: utf8)..toString();
      expect(s.exitCode, 0);
      const script = '.mode csv\n.headers on\nSELECT * FROM t;\n'
          '.mode line\nSELECT * FROM t;\n.tables\n';
      final ps = await Process.start(sq, [db]);
      ps.stdin.write(script);
      await ps.stdin.close();
      final so = await ps.stdout.transform(utf8.decoder).join();
      await ps.exitCode;
      final z = await zx(['sql', arc], stdin: script);
      expect(z.out, so);
    });

    test('errors and exit codes', () async {
      await zx(['sql', arc, ...setupSql]);
      var r = await zx(['sql', arc, 'SELECT 1', 'SELECT nosuch FROM t', 'SELECT 2']);
      expect(r.code, 1);
      expect(r.out, '1\n2\n');
      expect(r.err, 'Parse error: no such column: nosuch\n');
      r = await zx(['sql', '-bail', arc, 'SELECT x FROM nope', 'SELECT 2']);
      expect(r.code, 1);
      expect(r.out, '');
      r = await zx(['sql', '-readonly', arc, 'INSERT INTO t VALUES (1, 2, 3)']);
      expect(r.code, 1);
      expect(r.err, contains('read'));
      r = await zx(['sql', '-readonly', '${tmp.path}/missing.zx', 'SELECT 1']);
      expect(r.code, 1);
      r = await zx(['sql']);
      expect(r.code, 1);
      expect(r.err, contains('Usage: zx sql'));
    });

    test('help mentions sql', () async {
      final r = await zx(['--help']);
      expect(r.out, contains('sql : (zx) run SQL'));
      final h = await zx(['sql', '-help']);
      expect(h.out, contains('-readonly'));
    });
  });

  group('shell script on stdin', () {
    test('multi-line statements, errors with lines, dot commands', () async {
      File('${tmp.path}/in.csv')
          .writeAsStringSync('id,name,score\n1,alice,3.5\n2,"bob, jr",4\n');
      File('${tmp.path}/in.jsonl')
          .writeAsStringSync('{"k":1,"v":"a"}\n{"k":2,"v":[1,2],"w":true}\n');
      File('${tmp.path}/more.sql')
          .writeAsStringSync('SELECT count(*) FROM people;\n.print from file\n');
      final r = await zx(['sql', arc], cwd: tmp.path, stdin: '''
CREATE TABLE t (a INTEGER PRIMARY KEY, b TEXT);
INSERT INTO t (b) VALUES ('one'),
  ('two;still text');
SELECT b
  FROM t
  WHERE a = 2;
SELECT nope;
.tables
.schema t
CREATE INDEX tb ON t (b);
.indexes
.indexes t
.import in.csv people
.import in.jsonl j
.headers on
SELECT * FROM people;
SELECT k, v, w FROM j;
.headers off
.param set :x 2
.param set @name 'two'
SELECT a FROM t WHERE a = :x;
.param list
.read more.sql
.mode csv
.export out.csv people
.export out.json SELECT a, b FROM t ORDER BY a
.export out.jsonl t
.bogus
.mode list
.nullvalue NULL
SELECT NULL, 1;
.separator ;
SELECT 1, 2;
''');
      expect(r.code, 1, reason: '$r');
      expect(r.out, '''
two;still text
t
CREATE TABLE t (a INTEGER PRIMARY KEY, b TEXT);
tb
tb
id|name|score
1|alice|3.5
2|bob, jr|4
k|v|w
1|a|
2|[1,2]|1
2
:x    2
@name 'two'
2
from file
exported 2 rows to out.csv
exported 2 rows to out.json
exported 2 rows to out.jsonl
NULL|1
1;2
''');
      expect(r.err, 'Parse error near line 7: no such column: nope\n'
          'Error: unknown command or invalid arguments:  "bogus". '
          'Enter ".help" for help\n');
      expect(File('${tmp.path}/out.csv').readAsStringSync(),
          'id,name,score\r\n1,alice,3.5\r\n2,"bob, jr",4\r\n');
      expect(jsonDecode(File('${tmp.path}/out.json').readAsStringSync()), [
        {'a': 1, 'b': 'one'},
        {'a': 2, 'b': 'two;still text'},
      ]);
      expect(
          const LineSplitter()
              .convert(File('${tmp.path}/out.jsonl').readAsStringSync())
              .length,
          2);
      // the imported table, read back by a new process
      final r2 = await zx(['sql', arc, 'SELECT typeof(id), name FROM people']);
      expect(r2.out, 'text|alice\ntext|bob, jr\n');
      // import into an existing table: every CSV row is data
      File('${tmp.path}/more.csv').writeAsStringSync('3,carol,1\n');
      final r3 = await zx(['sql', arc, '.import more.csv people',
        'SELECT count(*) FROM people'], cwd: tmp.path);
      expect(r3.out, '3\n', reason: '$r3');
    });

    test('.asof, .generations, .kv, .vacuum, .timer, .quit', () async {
      await zx(['sql', arc, 'CREATE TABLE t (a)', 'INSERT INTO t VALUES (1)']);
      final gens = await zx(['sql', '-csv', arc, '.generations']);
      final lines = const LineSplitter().convert(gens.out);
      expect(lines.length, greaterThanOrEqualTo(3));
      final before = int.parse(lines.last.split(',').first);
      await zx(['sql', arc, 'INSERT INTO t VALUES (2)']);
      final r = await zx(['sql', arc], stdin: '''
SELECT count(*) FROM t;
.asof $before
SELECT count(*) FROM t;
INSERT INTO t VALUES (3);
.asof off
SELECT count(*) FROM t;
CREATE KV STORE cache;
INSERT INTO cache VALUES ('k', 'v');
.mode csv
.kv
.vacuum
SELECT count(*) FROM t;
.timer on
SELECT 5;
.quit
SELECT 6;
''');
      expect(r.err, contains('Runtime error near line 4: read only'));
      final out = r.out.split('\n');
      expect(out.sublist(0, 4), ['2', 'reading generation $before', '1', '2']);
      expect(r.out, contains('cache,,1'));
      expect(r.out, contains('bytes freed'));
      expect(r.out, contains('Run Time: real '));
      expect(r.out, isNot(contains('6')));
      // a date
      final d = await zx(['sql', arc, '.asof 2000-01-01', 'SELECT 1']);
      expect(d.code, isNonZero); // no generation that old
    });

    test('.import-arca and .export-arca', () async {
      final dir = Directory('${tmp.path}/coll')..createSync();
      final bytes = utf8.encode('hello arca');
      File('${dir.path}/a.txt').writeAsBytesSync(bytes);
      final hex = [
        for (final b in Sha256.hash(Uint8List.fromList(bytes)))
          b.toRadixString(16).padLeft(2, '0')
      ].join();
      File('${dir.path}/a.arca.json').writeAsStringSync(
          '${const JsonEncoder.withIndent('  ').convert({
                'format': 'arca-manifest/1',
                'file': 'a.txt',
                'size': bytes.length,
                'sha256': hex,
                'mime': 'text/plain',
                'title': 'Greeting',
                'description': 'a test',
                'tags': ['x', 'y'],
                'added': '2026-09-21T14:13:20.000Z',
                'layers': [],
              })}\n');
      var r = await zx(['sql', arc, '.import-arca coll',
        'SELECT title, tags FROM zx_meta'], cwd: tmp.path);
      expect(r.code, 0, reason: '$r');
      expect(r.out, contains('1 manifests'));
      expect(r.out, contains('Greeting|["x","y"]'));
      r = await zx(['sql', arc, '.export-arca out'], cwd: tmp.path);
      expect(r.code, 0, reason: '$r');
      expect(File('${tmp.path}/out/a.arca.json').readAsStringSync(),
          File('${dir.path}/a.arca.json').readAsStringSync());
    });

    test('.export-sqlite and .import-sqlite', () async {
      final sq = findSqlite3();
      await zx(['sql', arc, ...setupSql, 'CREATE INDEX tb ON t (b)']);
      final db = '${tmp.path}/out.db';
      var r = await zx(['sql', arc, '.export-sqlite out.db'], cwd: tmp.path);
      expect(r.code, 0, reason: '$r');
      expect(r.out, contains('1 tables, 4 rows, 1 indexes'));
      if (sq != null) {
        final c = Process.runSync(sq, [db, 'PRAGMA integrity_check']);
        expect((c.stdout as String).trim(), 'ok');
        final q = Process.runSync(sq, [db, 'SELECT * FROM t ORDER BY a']);
        final z = await zx(['sql', arc, 'SELECT * FROM t ORDER BY a']);
        expect(q.stdout, z.out);
      }
      final arc2 = '${tmp.path}/b.zx';
      r = await zx(['sql', arc2, '.import-sqlite out.db',
        'SELECT * FROM t ORDER BY a', '.indexes'], cwd: tmp.path);
      expect(r.code, 0, reason: '$r');
      expect(r.out, contains('-3|u v|1.0e+20\n1|x,y|1.5\n4||0.1\n22|he said "hi"|\n'));
      expect(r.out, contains('tb'));
    });

    test('system tables are listed by pattern', () async {
      final r = await zx(['sql', arc, '.tables zx_%', '.schema zx_meta']);
      expect(r.out, contains('zx_files'));
      expect(r.out, contains('CREATE TABLE zx_meta'));
    });
  });

  group('line editor', () {
    String edit(List<int> keys, {List<String> history = const []}) {
      var i = 0;
      final ed = LineEditor(
          readByte: () => i < keys.length ? keys[i++] : -1,
          write: (_) {},
          setRaw: (_) {});
      ed.history.addAll(history);
      return ed.readLine('> ') ?? '<eof>';
    }

    test('keys', () {
      expect(edit([...'abc'.codeUnits, 13]), 'abc');
      expect(edit([...'abc'.codeUnits, 0x7F, 13]), 'ab');
      // left twice, insert
      expect(edit([...'ac'.codeUnits, 27, 91, 68, ...'b'.codeUnits, 13]), 'abc');
      // Ctrl-A, insert, Ctrl-E
      expect(edit([...'bc'.codeUnits, 1, ...'a'.codeUnits, 5, ...'d'.codeUnits, 13]),
          'abcd');
      // Ctrl-W, Ctrl-U
      expect(edit([...'one two'.codeUnits, 0x17, 13]), 'one ');
      expect(edit([...'one two'.codeUnits, 0x15, 13]), '');
      // history
      expect(edit([27, 91, 65, 27, 91, 65, 13], history: ['first', 'second']),
          'first');
      expect(edit([27, 91, 65, 27, 91, 66, 13], history: ['h']), '');
      // UTF-8 and Ctrl-D
      expect(edit([...utf8.encode('\u00e9t\u00e9'), 13]), '\u00e9t\u00e9');
      expect(edit([4]), '<eof>');
      expect(edit([...'x'.codeUnits, 3]), '');
    });
  });
}
