// ZxDb under its name ZxSqlDb (lib/src/db/handle/zx_db.dart), as the XPRS stores use it.
import 'dart:io';
import 'dart:isolate';

import 'package:test/test.dart';
import 'package:zx/zxdb.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('zxsqldb'));
  tearDown(() => tmp.deleteSync(recursive: true));
  String path(String n) => '${tmp.path}/$n.zx';

  test('rows by name and by position, prepare, updatedRows, lastInsertRowId',
      () {
    final db = ZxSqlDb.open(path('a'));
    db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT, n INTEGER)');
    db.execute('INSERT INTO t (name, n) VALUES (?, ?), (?, ?)', ['a', 1, 'b', 2]);
    expect(db.updatedRows, 2);
    expect(db.lastInsertRowId, 2);
    final rows = db.select('SELECT id, name, n FROM t ORDER BY id');
    expect(rows.columnNames, ['id', 'name', 'n']);
    expect(rows.first['name'], 'a');
    expect(rows.last.columnAt(2), 2);
    expect(rows.first.containsKey('missing'), isFalse);
    expect(() => rows.first['name'] = 'x', throwsUnsupportedError);
    final st = db.prepare('UPDATE t SET n = n + 1 WHERE name = ?');
    st.execute(['a']);
    expect(db.updatedRows, 1);
    expect(st.select(['zzz']), isEmpty);
    expect(db.select('SELECT n FROM t WHERE name = ?', ['a']).single['n'], 2);
    db.dispose();
    // persisted
    final again = ZxSqlDb.open(path('a'));
    expect(again.select('SELECT COUNT(*) c FROM t').single['c'], 2);
    again.dispose();
  });

  test('transaction: one commit, rolled back on throw, nested joins', () {
    final db = ZxSqlDb.open(path('t'));
    db.execute('CREATE TABLE t (k TEXT PRIMARY KEY)');
    final gens = db.database!.generations.length;
    db.transaction(() {
      for (var i = 0; i < 50; i++) {
        db.execute('INSERT INTO t VALUES (?)', ['k$i']);
      }
      db.transaction(() => db.execute('INSERT INTO t VALUES (?)', ['inner']));
    });
    expect(db.database!.generations.length, gens + 1);
    expect(
        () => db.transaction(() {
              db.execute('INSERT INTO t VALUES (?)', ['gone']);
              throw StateError('boom');
            }),
        throwsStateError);
    expect(db.inTransaction, isFalse);
    expect(db.select("SELECT COUNT(*) c FROM t WHERE k = 'gone'").single['c'], 0);
    expect(db.select('SELECT COUNT(*) c FROM t').single['c'], 51);
    db.dispose();
  });

  test('KV stores with a TTL, and SQL over them', () {
    final db = ZxSqlDb.open(path('kv'));
    final kv = db.kv('cache', ttl: const Duration(hours: 1));
    kv.putString('a', '1');
    kv.putString('b', '2', ttl: const Duration(milliseconds: 1));
    expect(kv.getString('a'), '1');
    expect(db.select("SELECT value FROM cache WHERE key = 'a'").single['value'], '1');
    db.database!.nowMs = () => DateTime.now().millisecondsSinceEpoch + 60000;
    expect(db.kv('cache').getString('b'), isNull);
    db.dispose();
  });

  test('memory database: SQL only', () {
    final db = ZxSqlDb.memory();
    db.execute('CREATE TABLE t (a)');
    db.execute('INSERT INTO t VALUES (1)');
    expect(db.select('SELECT a FROM t').single.columnAt(0), 1);
    expect(() => db.kv('x'), throwsA(isA<ZxDbException>()));
    expect(db.stats().fileBytes, 0);
    db.dispose();
  });

  test('encrypted with a random secret: fast to open, wrong one refused', () {
    final secret = List.filled(64, 'f').join();
    final sw = Stopwatch()..start();
    final db = ZxSqlDb.open(path('enc'), password: secret, scryptLog2N: 1);
    db.execute('CREATE TABLE t (v TEXT)');
    db.execute("INSERT INTO t VALUES ('plaintext-marker')");
    db.dispose();
    expect(sw.elapsedMilliseconds, lessThan(3000));
    expect(String.fromCharCodes(File(path('enc')).readAsBytesSync())
        .contains('plaintext-marker'), isFalse);
    expect(
        () => ZxSqlDb.open(path('enc'), password: 'e' * 64),
        throwsA(isA<ZxDbException>()
            .having((e) => e.kind, 'kind', ZxDbError.wrongPassword)));
    final again = ZxSqlDb.open(path('enc'), password: secret);
    expect(again.select('SELECT v FROM t').single['v'], 'plaintext-marker');
    again.dispose();
  });

  test('maybeCompact: only after growth, then the file shrinks', () {
    final db = ZxSqlDb.open(path('grow'));
    db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)');
    expect(db.maybeCompact(minGrowth: 1), isFalse, reason: 'first look sets the baseline');
    final st = db.prepare('INSERT OR REPLACE INTO t VALUES (?, ?)');
    for (var round = 0; round < 40; round++) {
      db.transaction(() {
        for (var i = 0; i < 200; i++) {
          st.execute([i, 'value $round ${'x' * 100}']);
        }
      });
    }
    final before = db.stats().fileBytes;
    expect(db.maybeCompact(minGrowth: 1), isTrue);
    final after = db.stats();
    expect(after.fileBytes, lessThan(before ~/ 2));
    // the baseline is the size the vacuum left; recording it is one small commit
    expect(after.baselineBytes, lessThanOrEqualTo(after.fileBytes));
    expect(after.fileBytes - after.baselineBytes, lessThan(4096));
    expect(db.maybeCompact(minGrowth: 1), isFalse);
    expect(db.select('SELECT COUNT(*) c FROM t').single['c'], 200);
    db.dispose();
  });

  test('two isolates write one file; each sees the other', () async {
    final p = path('shared');
    ZxSqlDb.open(p)
      ..execute('CREATE TABLE t (who TEXT, i INTEGER)')
      ..dispose();
    Future<void> writer(String who) => Isolate.run(() {
          final db = ZxSqlDb.open(p);
          for (var b = 0; b < 20; b++) {
            db.transaction(() {
              for (var i = 0; i < 50; i++) {
                db.execute('INSERT INTO t VALUES (?, ?)', [who, b * 50 + i]);
              }
            });
          }
          db.dispose();
        });
    await Future.wait([writer('a'), writer('b')]);
    final db = ZxSqlDb.open(p);
    final r = db.select('SELECT who, COUNT(*) c FROM t GROUP BY who ORDER BY who');
    expect([for (final x in r) '${x['who']}=${x['c']}'], ['a=1000', 'b=1000']);
    db.dispose();
  });
}
