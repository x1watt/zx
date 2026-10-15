// CREATE INDEX on a filled table streams the rows and writes the keys in
// sorted chunks of bounded size (indexBuildChunkBytes); the result must be
// the same as an index maintained row by row.
import 'package:test/test.dart';
import 'package:zx/src/db/memory_store.dart';
import 'package:zx/src/db/sql/zx_sql.dart';
import 'package:zx/src/db/storage_api.dart';

void main() {
  late int saved;
  setUp(() => saved = indexBuildChunkBytes);
  tearDown(() => indexBuildChunkBytes = saved);

  List<List<Object?>> fill(ZxSql sql, {required bool indexFirst}) {
    sql.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, a INTEGER, b TEXT)');
    if (indexFirst) sql.execute('CREATE INDEX ta ON t (a, b DESC)');
    sql.execute('BEGIN');
    for (var i = 1; i <= 3000; i++) {
      sql.execute('INSERT INTO t VALUES (?, ?, ?)',
          [i, (i * 7919) % 101, i.isEven ? 'x$i' : null]);
    }
    sql.execute('COMMIT');
    if (!indexFirst) sql.execute('CREATE INDEX ta ON t (a, b DESC)');
    return sql.select('SELECT a, b, id FROM t WHERE a BETWEEN 10 AND 20 '
        'ORDER BY a, b DESC');
  }

  test('chunked build equals row by row maintenance', () {
    indexBuildChunkBytes = 2000; // about 25 keys a chunk
    final built = fill(ZxSql(ZxMemoryStore()), indexFirst: false);
    final kept = fill(ZxSql(ZxMemoryStore()), indexFirst: true);
    expect(built, isNotEmpty);
    expect(built, kept);
    // The index is used and complete.
    final sql = ZxSql(ZxMemoryStore());
    fill(sql, indexFirst: false);
    expect(sql.select('SELECT count(*) FROM t INDEXED BY ta WHERE a >= 0'),
        sql.select('SELECT count(*) FROM t'));
  });

  test('a unique violation is found across chunks', () {
    indexBuildChunkBytes = 500;
    final sql = ZxSql(ZxMemoryStore());
    sql.execute('CREATE TABLE u (id INTEGER PRIMARY KEY, k TEXT)');
    sql.execute('BEGIN');
    for (var i = 1; i <= 400; i++) {
      sql.execute('INSERT INTO u VALUES (?, ?)', [i, 'k$i']);
    }
    // Same key as row 1, far away in rowid order (another chunk).
    sql.execute("INSERT INTO u VALUES (401, 'k1')");
    sql.execute('COMMIT');
    expect(
        () => sql.execute('CREATE UNIQUE INDEX uk ON u (k)'),
        throwsA(isA<ZxDbException>()
            .having((e) => e.kind, 'kind', ZxDbError.constraint)));
    // Unique without duplicates works and NULLs never conflict.
    sql.execute('DELETE FROM u WHERE id = 401');
    sql.execute('INSERT INTO u VALUES (402, NULL), (403, NULL)');
    sql.execute('CREATE UNIQUE INDEX uk ON u (k)');
    expect(sql.select("SELECT id FROM u WHERE k = 'k7'"), [
      [7]
    ]);
  });

  test('a failed statement in a transaction undoes its index entries', () {
    final sql = ZxSql(ZxMemoryStore());
    sql.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, a INT, b TEXT UNIQUE)');
    sql.execute('CREATE INDEX ta ON t (a)');
    sql.execute('BEGIN');
    sql.execute("INSERT INTO t VALUES (1, 10, 'x'), (2, 20, 'y')");
    // The third row breaks UNIQUE(b): rows 3 and 4 and their index
    // entries must go, rows 1 and 2 stay.
    expect(
        () => sql.execute(
            "INSERT INTO t VALUES (3, 30, 'z'), (4, 40, 'w'), (5, 50, 'x')"),
        throwsA(isA<ZxDbException>()));
    // An update that fails half way puts the old entries back.
    expect(
        () => sql.execute("UPDATE t SET a = a + 1, b = 'y' WHERE id = 1"),
        throwsA(isA<ZxDbException>()));
    sql.execute('DELETE FROM t WHERE id = 2');
    sql.execute('COMMIT');
    expect(sql.select('SELECT id, a, b FROM t INDEXED BY ta WHERE a > 0'), [
      [1, 10, 'x']
    ]);
    expect(sql.select("SELECT id FROM t WHERE b = 'z'"), isEmpty);
    expect(sql.select('SELECT id FROM t WHERE a = 30'), isEmpty);
    expect(sql.select('SELECT id FROM t WHERE a = 20'), isEmpty);
    expect(sql.select('SELECT count(*) FROM t INDEXED BY ta WHERE a >= 0'), [
      [1]
    ]);
  });
}
