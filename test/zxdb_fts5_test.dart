// Tests of the fts5 virtual tables of zxdb SQL (lib/src/db/sql/fts5.dart):
// the statements of the XPRS app's stores, persistence, transactions, the
// query syntax and BM25 against values computed by SQLite 3.46 (FTS5).

import 'dart:io';

import 'package:test/test.dart';
import 'package:zx/src/db/memory_store.dart';
import 'package:zx/src/db/sql/zx_sql.dart';
import 'package:zx/src/db/zxdb.dart';

ZxDbStoreOptions _opts() => ZxDbStoreOptions(
    pageSize: 4096,
    autoFoldBytes: 0,
    durable: false,
    refreshMicros: 0,
    threads: 1);

const _schema = '''
CREATE TABLE IF NOT EXISTS events(id TEXT PRIMARY KEY, raw TEXT, kind INT,
  created_at INT, deleted INT);
CREATE TABLE IF NOT EXISTS tags(event_id TEXT, name TEXT, value TEXT);
CREATE VIRTUAL TABLE IF NOT EXISTS events_fts USING fts5(
  content, meta, event_id UNINDEXED, tokenize = 'unicode61'
);
''';

const _docs = [
  ('e1', 'Hello world, this is the first note', 'alice', 1, 100),
  ('e2', 'World news: hello again and hello there', 'bob', 1, 200),
  ('e3', 'Olá mundo! Ação rápida no mercado', 'carla', 2, 300),
  ('e4', 'A worldwide gathering of world travellers', 'dave hello', 1, 400),
  ('e5', 'Nothing to see here, move along', 'erin', 3, 500),
  ('e6', 'hello hello hello wonderful wording', '', 1, 600),
  ('e7', 'Straße und Größe in München', 'fritz', 2, 700),
  ('e8', 'the quick brown fox jumps over the lazy dog', 'gina world', 1, 800),
];

void _fill(ZxSql sql) {
  sql.execute(_schema);
  for (final (id, content, meta, kind, ts) in _docs) {
    sql.execute('INSERT INTO events VALUES(?,?,?,?,0)', [id, 'raw-$id', kind, ts]);
    sql.execute('INSERT INTO events_fts(content, meta, event_id) VALUES(?,?,?)',
        [content, meta, id]);
  }
  sql.execute("UPDATE events SET deleted = 1 WHERE id = 'e5'");
  sql.execute("INSERT INTO tags VALUES('e2','t','news'),('e4','t','travel'),"
      "('e6','t','news')");
}

const _search = '''
SELECT e.raw, bm25(events_fts) FROM events_fts
  JOIN events e ON e.id = events_fts.event_id
  WHERE e.deleted = 0 AND events_fts MATCH ?
  ORDER BY bm25(events_fts), e.created_at DESC LIMIT ?''';

// Output of SQLite 3.46.1 (FTS5) for _search on the same corpus.
const Map<String, List<(String, double)>> _sqlite = {
  '"hello" "wor"*': [
    ('raw-e6', -2.8502024291497974e-06),
    ('raw-e4', -2.323144578967371e-06),
    ('raw-e2', -2.323144578967371e-06),
    ('raw-e1', -1.9469026548672567e-06),
  ],
  '"hello"': [
    ('raw-e6', -1.6923076923076924e-06),
    ('raw-e2', -1.3496932515337425e-06),
    ('raw-e4', -9.734513274336284e-07),
    ('raw-e1', -9.734513274336284e-07),
  ],
  '"world"': [
    ('raw-e4', -9.734513274336284e-07),
    ('raw-e2', -9.734513274336284e-07),
    ('raw-e1', -9.734513274336284e-07),
    ('raw-e8', -8.396946564885496e-07),
  ],
  '"wor"*': [
    ('raw-e4', -1.3496932515337425e-06),
    ('raw-e6', -1.1578947368421053e-06),
    ('raw-e2', -9.734513274336284e-07),
    ('raw-e1', -9.734513274336284e-07),
    ('raw-e8', -8.396946564885496e-07),
  ],
  'hello OR world': [
    ('raw-e2', -2.323144578967371e-06),
    ('raw-e4', -1.9469026548672567e-06),
    ('raw-e1', -1.9469026548672567e-06),
    ('raw-e6', -1.6923076923076924e-06),
    ('raw-e8', -8.396946564885496e-07),
  ],
  '"acao"': [('raw-e3', -1.6545623398855243)],
  '"mundo" "ola"': [('raw-e3', -3.3091246797710485)],
  '"quick brown"': [('raw-e8', -1.3514364150210003)],
  '"brown quick"': [],
  '""': [],
  '"munchen"': [('raw-e7', -1.7528531719579312)],
  'hello NOT world': [('raw-e6', -1.6923076923076924e-06)],
  'content:hello': [
    ('raw-e6', -0.76489790171902),
    ('raw-e2', -0.6100412713096479),
    ('raw-e1', -0.4399855186879319),
  ],
  'meta:hello': [('raw-e4', -1.566709472280983)],
  '^hello': [('raw-e6', -1.1063816731896632), ('raw-e1', -0.9301438845399824)],
  '"the"': [('raw-e8', -1.1613951265526852), ('raw-e1', -0.9301438845399824)],
};

void _checkSearches(ZxSql sql) {
  for (final e in _sqlite.entries) {
    final rows = sql.select(_search, [e.key, 50]);
    expect([for (final r in rows) r[0]], [for (final x in e.value) x.$1],
        reason: e.key);
    for (var i = 0; i < rows.length; i++) {
      final got = rows[i][1] as double, want = e.value[i].$2;
      expect((got - want).abs() <= want.abs() * 1e-12, true,
          reason: '${e.key} row $i: $got vs $want');
    }
  }
}

// The media store's statements.
void _media(ZxSql sql) {
  sql.execute('CREATE TABLE IF NOT EXISTS media(sha256 TEXT PRIMARY KEY, '
      'last_seen INT)');
  sql.execute('''CREATE VIRTUAL TABLE IF NOT EXISTS media_fts USING fts5(
  name, description, tags, folder, parent, sha256 UNINDEXED, tokenize = 'unicode61'
)''');
  expect(sql.select('SELECT COUNT(*) c FROM media_fts'), [
    [0]
  ]);
  void put(String sha, String name, String desc, String tags, int seen) {
    sql.execute('INSERT OR REPLACE INTO media VALUES(?,?)', [sha, seen]);
    sql.execute('DELETE FROM media_fts WHERE sha256=?', [sha]);
    sql.execute(
        'INSERT INTO media_fts(name,description,tags,folder,parent,sha256) '
        'VALUES (?,?,?,?,?,?)',
        [name, desc, tags, 'photos', 'home', sha]);
  }

  put('aa', 'beach.jpg', 'Sunset at the beach', 'summer holiday', 10);
  put('bb', 'dog.png', 'My dog at the park', 'pets', 20);
  put('cc', 'beach2.jpg', 'Beach volleyball', 'summer sport', 30);
  put('aa', 'beach.jpg', 'Sunrise at the beach', 'summer holiday', 40);
  expect(sql.select('SELECT COUNT(*) c FROM media_fts'), [
    [3]
  ]);
  const q = 'SELECT m.sha256 FROM media_fts JOIN media m ON m.sha256 = '
      'media_fts.sha256 WHERE media_fts MATCH ? ORDER BY bm25(media_fts), '
      'm.last_seen DESC LIMIT ?';
  // orders from SQLite 3.46.1
  expect(sql.select(q, ['"summer"', 10]).map((r) => r[0]), ['cc', 'aa']);
  expect(sql.select(q, ['"sunset"', 10]), isEmpty);
  expect(sql.select(q, ['"sunrise"', 10]).map((r) => r[0]), ['aa']);
  expect(sql.select(q, ['"photos" "be"*', 10]).map((r) => r[0]), ['cc', 'aa']);
  expect(sql.select(q, ['"pets"', 1]).map((r) => r[0]), ['bb']);
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('zxdb_fts5_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('memory store', () {
    late ZxSql sql;
    setUp(() {
      sql = ZxSql(ZxMemoryStore());
      _fill(sql);
    });

    test('searches and BM25 equal SQLite', () => _checkSearches(sql));

    test('joins with more terms and EXISTS', () {
      final r = sql.select('''
SELECT e.raw FROM events_fts JOIN events e ON e.id = events_fts.event_id
  WHERE e.deleted = 0 AND e.kind IN (1,2) AND EXISTS (SELECT 1 FROM tags t
    WHERE t.event_id = e.id AND t.name = 't' AND t.value = 'news')
  AND events_fts MATCH ? ORDER BY bm25(events_fts), e.created_at DESC
  LIMIT ?''', ['"hello"', 10]);
      expect(r.map((x) => x[0]), ['raw-e6', 'raw-e2']);
      // LIMIT, and the deleted event is filtered by the join
      expect(sql.select(_search, ['"along"', 10]), isEmpty);
      expect(sql.select(_search, ['"hello" "wor"*', 2]).map((x) => x[0]),
          ['raw-e6', 'raw-e4']);
      // the fts table joined on the right (MATCH plus = on event_id)
      final inner = sql.select('''
SELECT e.raw, bm25(events_fts) FROM events e
  JOIN events_fts ON events_fts.event_id = e.id
  WHERE events_fts MATCH ? ORDER BY e.created_at''', ['"hello"']);
      expect(inner.map((x) => x[0]), ['raw-e1', 'raw-e2', 'raw-e4', 'raw-e6']);
      expect(inner.last[1], closeTo(-1.6923076923076924e-06, 1e-18));
      expect(
          sql.select("SELECT COUNT(*), MIN(rank) < 0 FROM events_fts "
              "WHERE events_fts MATCH 'hello'"),
          [
            [4, 1]
          ]);
    });

    test('plain reads, rank, rowid, delete, update', () {
      expect(sql.select('SELECT COUNT(*) c FROM events_fts'), [
        [8]
      ]);
      expect(sql.select('SELECT event_id FROM events_fts WHERE rowid = 3'), [
        ['e3']
      ]);
      expect(sql.select('SELECT * FROM events_fts WHERE event_id = ?', ['e8']), [
        ['the quick brown fox jumps over the lazy dog', 'gina world', 'e8']
      ]);
      expect(
          sql
              .select("SELECT event_id FROM events_fts WHERE events_fts MATCH "
                  "'hello' ORDER BY rank")
              .map((r) => r[0]),
          ['e6', 'e2', 'e1', 'e4']);
      expect(
          sql
              .select("SELECT rowid FROM events_fts WHERE events_fts MATCH "
                  "'hello'")
              .map((r) => r[0]),
          [1, 2, 4, 6]);
      expect(
          sql
              .select("SELECT event_id FROM events_fts WHERE content MATCH "
                  "'hello'")
              .map((r) => r[0]),
          ['e1', 'e2', 'e6']);
      expect(
          sql
              .select("SELECT event_id FROM events_fts WHERE events_fts = "
                  "'world'")
              .map((r) => r[0]),
          ['e1', 'e2', 'e4', 'e8']);
      expect(sql.select('SELECT event_id FROM events_fts(?)', ['mundo']), [
        ['e3']
      ]);
      expect(sql.select('SELECT rank FROM events_fts WHERE rowid = 1'), [
        [0.0]
      ]);
      sql.execute('DELETE FROM events_fts WHERE event_id = ?', ['e6']);
      expect(sql.changes, 1);
      expect(
          sql
              .select("SELECT event_id FROM events_fts WHERE events_fts MATCH "
                  "'hello'")
              .map((r) => r[0]),
          ['e1', 'e2', 'e4']);
      sql.execute('DELETE FROM events_fts WHERE rowid = 1');
      sql.execute(
          "UPDATE events_fts SET content = 'goodbye moon' WHERE event_id = 'e2'");
      expect(
          sql
              .select("SELECT event_id FROM events_fts WHERE events_fts MATCH "
                  "'hello'")
              .map((r) => r[0]),
          ['e4']);
      expect(
          sql
              .select("SELECT event_id, meta FROM events_fts WHERE events_fts "
                  "MATCH 'moon'"),
          [
            ['e2', 'bob']
          ]);
      expect(sql.select('SELECT COUNT(*) FROM events_fts'), [
        [6]
      ]);
      // explicit rowid, conflicts
      sql.execute(
          'INSERT INTO events_fts(rowid, content, event_id) VALUES(100, ?, ?)',
          ['zebra', 'z']);
      expect(sql.lastInsertRowid, 100);
      expect(
          () => sql.execute(
              'INSERT INTO events_fts(rowid, content) VALUES(100, ?)', ['x']),
          throwsA(isA<ZxDbException>()));
      sql.execute(
          'INSERT OR REPLACE INTO events_fts(rowid, content, event_id) '
          'VALUES(100, ?, ?)',
          ['yak', 'y']);
      expect(sql.select("SELECT event_id FROM events_fts WHERE events_fts "
          "MATCH 'yak OR zebra'"), [
        ['y']
      ]);
      sql.execute('INSERT INTO events_fts(content) VALUES(?)', ['next']);
      expect(sql.lastInsertRowid, 101);
      sql.execute("INSERT INTO events_fts(events_fts) VALUES('optimize')");
      sql.execute("INSERT INTO events_fts(events_fts) VALUES('delete-all')");
      expect(sql.select('SELECT COUNT(*) FROM events_fts'), [
        [0]
      ]);
    });

    test('query syntax', () {
      List<Object?> ids(String q) => sql
          .select('SELECT event_id FROM events_fts WHERE events_fts MATCH ?',
              [q])
          .map((r) => r[0])
          .toList();
      expect(ids('"hello" "wor"*'), ['e1', 'e2', 'e4', 'e6']);
      expect(ids('hello wor*'), ['e1', 'e2', 'e4', 'e6']);
      expect(ids('HELLO'), ['e1', 'e2', 'e4', 'e6']);
      expect(ids('hello AND world'), ['e1', 'e2', 'e4']);
      expect(ids('quick OR mundo'), ['e3', 'e8']);
      expect(ids('quick or mundo'), isEmpty); // "or" is a word
      expect(ids('(quick OR mundo) AND NOT_A_WORD'), isEmpty);
      expect(ids('world NOT hello'), ['e8']);
      expect(ids('quick+brown'), ['e8']);
      expect(ids('"quick brow"*'), ['e8']);
      expect(ids('{meta}:world'), ['e8']);
      expect(ids('-meta:world'), ['e1', 'e2', 'e4']);
      expect(ids('event_id:e1'), isEmpty); // UNINDEXED
      expect(ids('""'), isEmpty);
      expect(ids('"" OR mundo'), ['e3']);
      expect(ids('hello ""'), ['e1', 'e2', 'e4', 'e6']);
      expect(ids('"!!"'), isEmpty);
      expect(ids('ACAO'), ['e3']);
      expect(ids('ação'), ['e3']);
      expect(ids('größe'), ['e7']);
      for (final bad in ['hello AND', 'OR hello', 'x.y', '"open', 'a-b']) {
        expect(() => ids(bad), throwsA(isA<ZxDbException>()), reason: bad);
      }
      expect(() => ids('nope:x'), throwsA(isA<ZxDbException>()));
      expect(
          () => ids('NEAR(hello world)'),
          throwsA(isA<ZxDbException>()
              .having((e) => e.kind, 'kind', ZxDbError.unsupported)));
      // MATCH where the table cannot take it
      expect(
          () => sql.select("SELECT * FROM events_fts WHERE events_fts MATCH "
              "'a' OR rowid = 1"),
          throwsA(isA<ZxDbException>()));
    });

    test('rollback undoes the index', () {
      sql.execute('BEGIN');
      sql.execute('INSERT INTO events_fts(content, event_id) VALUES(?, ?)',
          ['platypus', 'p1']);
      sql.execute('DELETE FROM events_fts WHERE event_id = ?', ['e1']);
      expect(sql.select("SELECT event_id FROM events_fts WHERE events_fts "
          "MATCH 'platypus'"), [
        ['p1']
      ]);
      sql.execute('ROLLBACK');
      expect(sql.select("SELECT event_id FROM events_fts WHERE events_fts "
          "MATCH 'platypus'"), isEmpty);
      expect(sql.select('SELECT COUNT(*) FROM events_fts'), [
        [8]
      ]);
      _checkSearches(sql);
      // a failing statement in a transaction leaves no partial change
      sql.execute('BEGIN');
      expect(
          () => sql.execute(
              'INSERT INTO events_fts(rowid, content) VALUES(50, ?), (1, ?)',
              ['kangaroo', 'x']),
          throwsA(isA<ZxDbException>()));
      expect(sql.select("SELECT rowid FROM events_fts WHERE events_fts "
          "MATCH 'kangaroo'"), isEmpty);
      sql.execute('COMMIT');
      _checkSearches(sql);
    });

    test('options and errors', () {
      for (final bad in [
        "CREATE VIRTUAL TABLE x1 USING fts5(a, tokenize = 'porter')",
        "CREATE VIRTUAL TABLE x2 USING fts5(a, content = '')",
        "CREATE VIRTUAL TABLE x3 USING fts5(a, detail = none)",
        'CREATE VIRTUAL TABLE x4 USING nope(a)',
      ]) {
        expect(() => sql.execute(bad), throwsA(isA<ZxDbException>()),
            reason: bad);
      }
      expect(() => sql.execute('CREATE VIRTUAL TABLE x5 USING fts5(rank)'),
          throwsA(isA<ZxDbException>()));
      sql.execute("CREATE VIRTUAL TABLE x6 USING fts5(a, prefix = '2 3', "
          "tokenize = 'unicode61 remove_diacritics 2')");
      expect(() => sql.execute('CREATE VIRTUAL TABLE x6 USING fts5(b)'),
          throwsA(isA<ZxDbException>()));
      expect(() => sql.execute('CREATE TABLE x6 (a)'),
          throwsA(isA<ZxDbException>()));
      sql.execute('CREATE VIRTUAL TABLE IF NOT EXISTS x6 USING fts5(b)');
      expect(
          sql.select("SELECT sql FROM sqlite_schema WHERE name = 'x6'"), [
        [
          "CREATE VIRTUAL TABLE x6 USING fts5(a, prefix = '2 3', "
              "tokenize = 'unicode61 remove_diacritics 2')"
        ]
      ]);
      sql.execute('DROP TABLE x6');
      expect(() => sql.select('SELECT * FROM x6'), throwsA(isA<ZxDbException>()));
      sql.execute('DROP TABLE IF EXISTS x6');
    });

    test('media store statements', () => _media(sql));

    test('same store, new session', () {
      final store = ZxMemoryStore();
      final a = ZxSql(store);
      _fill(a);
      a.close();
      final b = ZxSql(store);
      b.execute(_schema); // IF NOT EXISTS: no-op
      _checkSearches(b);
      b.execute('DROP TABLE events_fts');
      expect(store.snapshot().treeNames.where((n) => n.startsWith('v:')),
          isEmpty);
    });
  });

  test('file database: persistence across reopen', () {
    final path = '${tmp.path}/fts5.zx';
    var db = ZxDatabase.open(path, create: true, options: _opts());
    var sql = ZxSql(db.store);
    _fill(sql);
    _media(sql);
    _checkSearches(sql);
    db.close();

    db = ZxDatabase.open(path, options: _opts());
    sql = ZxSql(db.store);
    sql.execute(_schema);
    _checkSearches(sql);
    expect(sql.select('SELECT COUNT(*) c FROM media_fts'), [
      [3]
    ]);
    sql.execute('DELETE FROM events_fts WHERE event_id = ?', ['e6']);
    db.close();

    db = ZxDatabase.open(path, options: _opts());
    sql = db.sql;
    expect(
        sql
            .select("SELECT event_id FROM events_fts WHERE events_fts MATCH "
                "'hello'")
            .map((r) => r[0]),
        ['e1', 'e2', 'e4']);
    sql.execute('DROP TABLE events_fts');
    expect(() => sql.select('SELECT * FROM events_fts'),
        throwsA(isA<ZxDbException>()));
    db.close();
  });
}
