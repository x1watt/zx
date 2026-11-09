// ZxTextIndex / ZxSqlDb.textIndex: application full-text search (BM25).
import 'dart:io';

import 'package:test/test.dart';
import 'package:zx/zxdb.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('zxtext'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('index, rank, prefix, OR, exclusion, field, remove, replace', () {
    final db = ZxSqlDb.open('${tmp.path}/a.zx');
    final ix = db.textIndex('media', {'name': 2, 'description': 1, 'tags': 3});
    ix.put('a', {'name': 'dipole antenna.jpg', 'description': 'the mast at nine'});
    ix.put('b', {'name': 'notes.txt', 'description': 'antenna tuning notes', 'tags': 'radio'});
    ix.put('c', {'name': 'cat.png', 'tags': 'antenna'});
    ix.put('d', {'name': 'Estação.jpg', 'description': 'a station'});
    expect(ix.length, 4);
    expect(ix.search('antenna').map((h) => h.key).toList(), ['c', 'a', 'b'],
        reason: 'tags weigh 3, name 2, description 1');
    expect(ix.search('anten*').length, 3);
    expect(ix.search('"antenna" "tun"*').map((h) => h.key), ['b'],
        reason: 'the query shape the stores build: quoted terms, prefix last');
    expect(ix.search('mast OR tuning').map((h) => h.key).toSet(), {'a', 'b'});
    expect(ix.search('antenna -radio').map((h) => h.key).toSet(), {'a', 'c'});
    expect(ix.search('tags:antenna').map((h) => h.key), ['c']);
    expect(ix.search('estacao').map((h) => h.key), ['d'], reason: 'accents fold');
    ix.remove('c');
    expect(ix.contains('c'), isFalse);
    expect(ix.search('antenna').map((h) => h.key).toSet(), {'a', 'b'});
    ix.put('a', {'name': 'yagi.jpg'});
    expect(ix.search('dipole'), isEmpty, reason: 'a replaced document loses its old words');
    expect(ix.search('yagi').single.key, 'a');
    db.dispose();
    final again = ZxSqlDb.open('${tmp.path}/a.zx');
    final ix2 = again.textIndex('media', {'name': 2, 'description': 1, 'tags': 3});
    expect(ix2.length, 3);
    expect(ix2.search('notes').single.key, 'b');
    again.dispose();
  });

  test('writes join a transaction: rows and index commit or roll back together', () {
    final db = ZxSqlDb.open('${tmp.path}/t.zx');
    db.execute('CREATE TABLE post (id TEXT PRIMARY KEY, body TEXT)');
    final ix = db.textIndex('post', {'body': 1});
    db.transaction(() {
      db.execute("INSERT INTO post VALUES ('p1', 'hello world')");
      ix.put('p1', {'body': 'hello world'});
    });
    expect(ix.search('hello').single.key, 'p1');
    expect(
        () => db.transaction(() {
              db.execute("INSERT INTO post VALUES ('p2', 'goodbye world')");
              ix.put('p2', {'body': 'goodbye world'});
              throw StateError('no');
            }),
        throwsStateError);
    expect(ix.search('goodbye'), isEmpty);
    expect(db.select('SELECT COUNT(*) c FROM post').single['c'], 1);
    db.dispose();
  });

  test('a thousand documents: a prefix query stays fast', () {
    final db = ZxSqlDb.open('${tmp.path}/big.zx');
    final ix = db.textIndex('n', {'content': 1});
    db.transaction(() {
      for (var i = 0; i < 1000; i++) {
        ix.put('e$i', {'content': 'note number $i about relay${i % 50} and antenna'});
      }
    });
    final sw = Stopwatch()..start();
    final hits = ix.search('relay1*', limit: 20);
    expect(hits.length, 20);
    expect(sw.elapsedMilliseconds, lessThan(2000));
    db.dispose();
  });
}
