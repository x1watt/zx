// ZxDb (lib/src/db/handle/zx_db.dart): the package:sqlite3-shaped handle —
// rows by name and position, statements across a compaction, transactions,
// sharing one file per isolate, passwords, :memory:, live size.
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/zxdb.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('zxdb_handle_'));
  tearDown(() => dir.deleteSync(recursive: true));

  ZxDbStoreOptions small() => ZxDbStoreOptions(
      compression: 'fast',
      durable: false,
      pageCacheBytes: 4 << 20,
      blockCacheBytes: 2 << 20);

  test('rows read by name and by position, blobs come back as bytes', () {
    final db = zxDbOpenMemory();
    db.execute('CREATE TABLE t (k TEXT PRIMARY KEY, n INTEGER, b BLOB)');
    db.execute('INSERT INTO t VALUES (?, ?, ?)',
        ['a', 1, Uint8List.fromList([1, 2, 3])]);
    expect(db.updatedRows, 1);
    final rows = db.select('SELECT k, n, b, COUNT(*) AS c FROM t');
    expect(rows.columnNames, ['k', 'n', 'b', 'c']);
    expect(rows.single['k'], 'a');
    expect(rows.single.columnAt(1), 1);
    expect(rows.single['b'], [1, 2, 3]);
    expect(rows.single.keys, ['k', 'n', 'b', 'c']);
    expect(db.select('SELECT * FROM t WHERE k = ?', ['zz']), isEmpty);
    db.dispose();
  });

  test("a failing statement throws ZxDbException with SQLite's message", () {
    final db = zxDbOpenMemory();
    db.execute('CREATE TABLE t (k TEXT PRIMARY KEY)');
    db.execute("INSERT INTO t VALUES ('a')");
    expect(
        () => db.execute("INSERT INTO t VALUES ('a')"),
        throwsA(isA<ZxDbException>().having(
            (e) => e.message, 'message', contains('UNIQUE constraint failed'))));
    db.dispose();
  });

  test('transaction commits once, and rolls back when the body throws', () {
    final db = zxDbOpenMemory();
    db.execute('CREATE TABLE t (n INTEGER)');
    db.transaction(() {
      for (var i = 0; i < 5; i++) {
        db.execute('INSERT INTO t VALUES (?)', [i]);
      }
    });
    expect(db.select('SELECT COUNT(*) c FROM t').single['c'], 5);
    expect(
        () => db.transaction(() {
              db.execute('INSERT INTO t VALUES (99)');
              throw StateError('no');
            }),
        throwsStateError);
    expect(db.select('SELECT COUNT(*) c FROM t').single['c'], 5);
    expect(db.inTransaction, isFalse);
    db.dispose();
  });

  test(':memory: is a fresh database each time, never a file', () {
    final a = zxDbOpenFile(':memory:');
    a.execute('CREATE TABLE t (n INTEGER)');
    final b = zxDbOpenFile(':memory:');
    expect(() => b.select('SELECT * FROM t'), throwsA(isA<ZxDbException>()));
    a.dispose();
    b.dispose();
    expect(File(':memory:').existsSync(), isFalse);
  });

  test('two handles of one file share it; the last dispose closes it', () {
    final path = '${dir.path}/s.zx';
    final a = zxDbOpenFile(path, options: small());
    a.execute('CREATE TABLE t (n INTEGER)');
    final b = zxDbOpenFile(path, options: small());
    b.execute('INSERT INTO t VALUES (1)');
    expect(a.select('SELECT n FROM t').single['n'], 1);
    a.dispose();
    expect(b.select('SELECT n FROM t').single['n'], 1);
    b.dispose();
    final c = zxDbOpenFile(path, options: small());
    expect(c.select('SELECT n FROM t').single['n'], 1, reason: 'persisted');
    c.dispose();
  });

  test('a password protects the file', () {
    final path = '${dir.path}/p.zx';
    final a = zxDbOpenFile(path, password: 'aabbcc', options: small());
    a.execute('CREATE TABLE t (n INTEGER)');
    a.execute('INSERT INTO t VALUES (7)');
    a.dispose();
    expect(() => zxDbOpenFile(path, password: 'wrong', options: small()),
        throwsA(isA<ZxDbException>()));
    final b = zxDbOpenFile(path, password: 'aabbcc', options: small());
    expect(b.select('SELECT n FROM t').single['n'], 7);
    b.dispose();
  });

  test('the file is compacted when it doubles; statements survive it; '
      'liveBytes is the live data', () {
    final path = '${dir.path}/g.zx';
    final db = zxDbOpenFile(path, options: small());
    db.execute('CREATE TABLE t (k INTEGER PRIMARY KEY, v TEXT)');
    db.transaction(() {
      for (var i = 0; i < 2000; i++) {
        db.execute('INSERT INTO t VALUES (?, ?)', [i, 'value $i' * 4]);
      }
    });
    final st = db.prepare('UPDATE t SET v = ? WHERE k = ?');
    var peak = 0;
    for (var i = 0; i < 1500; i++) {
      st.execute(['changed $i', i]);
      if (db.bytes > peak) peak = db.bytes;
    }
    expect(db.bytes, lessThan(peak), reason: 'a compaction ran');
    expect(db.liveBytes, greaterThan(0));
    expect(db.liveBytes, lessThan(peak));
    expect(db.select('SELECT v FROM t WHERE k = 1499').single['v'],
        'changed 1499');
    st.execute(['after', 0]);
    expect(db.select('SELECT v FROM t WHERE k = 0').single['v'], 'after');
    db.dispose();
  });

  test('a cheap scrypt cost keeps an encrypted open fast and survives '
      'compaction', () {
    final path = '${dir.path}/k.zx';
    final key = 'f' * 64;
    var db = zxDbOpenFile(path,
        password: key, options: ZxDbStoreOptions(scryptLog2N: 1));
    db.execute('CREATE TABLE t (v TEXT)');
    db.execute("INSERT INTO t VALUES ('x')");
    db.compact();
    db.dispose();
    final sw = Stopwatch()..start();
    for (var i = 0; i < 10; i++) {
      // the cost is read from the header: default options open it fast
      db = zxDbOpenFile(path, password: key);
      expect(db.select('SELECT v FROM t').single['v'], 'x');
      db.dispose();
    }
    expect(sw.elapsedMilliseconds, lessThan(3000));
    expect(() => zxDbOpenFile(path, password: 'g' * 64),
        throwsA(isA<ZxDbException>()));
  });

  test('KV stores and a text index work across a compaction and a shared '
      'open; the compaction baseline survives a reopen', () {
    final path = '${dir.path}/m.zx';
    final a = ZxDb.open(path, options: small());
    final b = ZxDb.open(path, options: small()); // shares a's file
    a.execute('CREATE TABLE doc (k TEXT PRIMARY KEY, body TEXT)');
    final fts = a.textIndex('doc', {'body': 1});
    a.transaction(() {
      for (var i = 0; i < 200; i++) {
        a.execute('INSERT INTO doc VALUES (?, ?)', ['d$i', 'word$i common']);
        fts.put('d$i', {'body': 'word$i common'});
      }
    });
    a.kv('cfg').putString('k', 'v');
    expect(b.select('SELECT COUNT(*) n FROM doc').single['n'], 200);

    expect(a.maybeCompact(), isFalse, reason: 'the first look records');
    final base = a.stats().baselineBytes;
    expect(base, greaterThan(0));
    a.compact();
    expect(fts.search('word7').map((h) => h.key), ['d7']);
    expect(fts.length, 200);
    expect(b.kv('cfg').getString('k'), 'v');
    expect(b.select('SELECT body FROM doc WHERE k = ?', ['d3']).single['body'],
        'word3 common');
    a.dispose();
    expect(b.select('SELECT COUNT(*) n FROM doc').single[0], 200,
        reason: 'b still holds the file');
    b.dispose();

    // The size after the compaction, read back from the file: recording
    // it is itself a small commit, so the file is that much larger.
    final c = ZxDb.open(path, options: small());
    final st = c.stats();
    expect(st.baselineBytes, lessThanOrEqualTo(st.fileBytes));
    expect(st.fileBytes - st.baselineBytes, lessThan(4096));
    expect(c.maybeCompact(), isFalse, reason: 'it has not grown since');
    c.dispose();
  });
}
