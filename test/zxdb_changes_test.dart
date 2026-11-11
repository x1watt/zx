// changes() and total_changes(), as SQLite defines them: changes() is the row
// count of the most recently COMPLETED INSERT, UPDATE or DELETE on the
// connection, so `SELECT changes()` right after a write reports that write.
// An application that asks "did my INSERT OR IGNORE add a row?" this way
// (the XPRS Chat wapp does, for every correction) depends on it.

import 'package:test/test.dart';
import 'package:zx/zxdb.dart';

void main() {
  late ZxSqlDb db;
  int changes() => db.select('SELECT changes() AS n').first['n'] as int;
  int total() => db.select('SELECT total_changes() AS n').first['n'] as int;

  setUp(() {
    db = ZxSqlDb.memory();
    db.execute('CREATE TABLE v (id TEXT PRIMARY KEY, n INTEGER)');
  });
  tearDown(() => db.dispose());

  test('a SELECT after a write reports the write', () {
    db.execute('INSERT OR IGNORE INTO v (id, n) VALUES (?, ?)', ['a', 1]);
    expect(changes(), 1);
    expect(changes(), 1, reason: 'asking again does not reset it');
    db.execute('INSERT OR IGNORE INTO v (id, n) VALUES (?, ?)', ['a', 2]);
    expect(changes(), 0, reason: 'ignored: nothing added');
  });

  test('UPDATE and DELETE count the rows they touched', () {
    db.execute("INSERT INTO v (id, n) VALUES ('a', 1), ('b', 1), ('c', 2)");
    expect(changes(), 3);
    db.execute('UPDATE v SET n = 5 WHERE n = 1');
    expect(changes(), 2);
    db.execute('DELETE FROM v WHERE id = ?', ['zz']);
    expect(changes(), 0);
    db.execute('DELETE FROM v');
    expect(changes(), 3);
  });

  test('other statements leave changes() as it was', () {
    db.execute("INSERT INTO v (id, n) VALUES ('a', 1), ('b', 1)");
    db.execute('CREATE TABLE w (x INTEGER)');
    expect(changes(), 2, reason: 'a CREATE TABLE is not a row change');
  });

  test('total_changes() counts every row since the connection opened', () {
    db.execute("INSERT INTO v (id, n) VALUES ('a', 1)");
    db.execute("INSERT OR IGNORE INTO v (id, n) VALUES ('a', 1)");
    db.execute('UPDATE v SET n = 2');
    expect(total(), 2);
  });

  test('inside a write, changes() is the previous statement', () {
    db.execute("INSERT INTO v (id, n) VALUES ('a', 1), ('b', 1)");
    db.execute("INSERT INTO v (id, n) VALUES ('c', changes())");
    expect(db.select("SELECT n FROM v WHERE id = 'c'").first['n'], 2);
  });
}
