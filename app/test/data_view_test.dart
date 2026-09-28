// Widget tests of the database parts of the app: the Data view (object
// groups, table paging and sorting, the query box, errors, read-only
// views, export), the metadata in the Properties dialog and the preview,
// "Find similar files", "Find by SHA-256" and Archive, New database. The
// archives are real .zx files; the queries run through a synchronous
// connection (helpers.dart) so the tests need no isolates for them.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zx/src/db/zxdb.dart';
import 'package:zx/zx.dart';
import 'package:zx_app/src/app.dart';
import 'package:zx_app/src/db_session.dart';
import 'package:zx_app/src/services.dart';
import 'package:zx_app/src/ui/browser_page.dart';
import 'package:zx_app/src/ui/data_view.dart';

import 'helpers.dart';

// a 1x1 PNG
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGA'
  'hKmMIQAAAABJRU5ErkJggg==',
);

String _words(int seed, int n) {
  final r = Random(seed);
  const w = [
    'antenna',
    'dipole',
    'station',
    'radio',
    'signal',
    'packet',
    'beacon',
    'relay',
    'frequency',
    'band',
    'repeater',
    'mast',
    'cable',
    'tuner',
  ];
  return [for (var i = 0; i < n; i++) w[r.nextInt(w.length)]].join(' ');
}

void main() {
  late Directory tmp;
  late String src;
  late String dbArchive; // a .zx with a database
  late String plainArchive; // a .zx without one

  setUpAll(() async {
    tmp = Directory.systemTemp.createTempSync('zx_data_');
    src = p.join(tmp.path, 'in', 'media');
    void f(String rel, String text) {
      final file = File(p.join(src, rel));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(text);
    }

    final a = _words(1, 400);
    f('talks/a.txt', a);
    f('talks/b.txt', a.replaceFirst('antenna', 'aerial'));
    f('talks/c.txt', _words(2, 400));
    f('notes.md', '# Notes\n\n${_words(3, 80)}\n');
    dbArchive = p.join(tmp.path, 'db.zx');
    plainArchive = p.join(tmp.path, 'plain.zx');
    for (final path in [dbArchive, plainArchive]) {
      final z = await ZxArchive.create(path, [ZxSource(src)]);
      await z.close();
    }
    final db = ZxDatabase.open(dbArchive, create: true);
    final q = db.sql;
    q.execute('CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT, n INT)');
    q.execute('BEGIN');
    for (var i = 1; i <= 250; i++) {
      q.execute('INSERT INTO items (name, n) VALUES (?, ?)', [
        'item $i',
        (i * 37) % 101,
      ]);
    }
    q.execute('COMMIT');
    q.execute('CREATE VIEW big AS SELECT * FROM items WHERE n > 50');
    q.execute('CREATE KV STORE settings');
    q.execute(
      'CREATE TIMESERIES logs (ts DATETIME, level TEXT, message TEXT) '
      'PARTITION BY DAY',
    );
    q.execute(
      "INSERT INTO logs (ts, level, message) VALUES "
      "('2026-09-01 10:00:00', 'info', 'up')",
    );
    final sha = q
        .execute("SELECT sha256 FROM zx_files WHERE path = 'media/talks/a.txt'")
        .scalar;
    q.execute(
      'INSERT INTO zx_meta (sha256, path, title, description, tags) '
      'VALUES (?, ?, ?, ?, ?)',
      [
        sha,
        'media/talks/a.txt',
        'Antenna talk',
        'A talk about dipoles.',
        '["radio","dipole-antenna"]',
      ],
    );
    q.execute(
      'INSERT INTO zx_layers (sha256, n, kind, language, file, content) '
      'VALUES (?, 0, ?, ?, ?, ?)',
      [
        sha,
        'subtitles',
        'en',
        'a.en.srt',
        '1\n00:00:01,000 --> 00:00:02,000\nHi\n',
      ],
    );
    q.execute(
      'INSERT INTO zx_layers (sha256, n, kind, language, file, content) '
      'VALUES (?, 1, ?, ?, ?, ?)',
      [sha, 'subtitles', 'pt-BR', 'a.pt-BR.srt', '1\n'],
    );
    q.execute(
      'INSERT INTO zx_media (sha256, kind, n, caption, data) '
      'VALUES (?, ?, 0, ?, ?)',
      [sha, 'screenshot', 'first slide', _png],
    );
    db.close();
  });
  tearDownAll(() => tmp.deleteSync(recursive: true));
  tearDown(closeTestDbs);

  Future<BrowserPageState> pumpApp(WidgetTester tester, AppServices s) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey<BrowserPageState>();
    await tester.pumpWidget(ZxApp(services: s, browserKey: key));
    await tester.pump();
    return key.currentState!;
  }

  Future<BrowserPageState> openDb(
    WidgetTester tester, {
    String? path,
    FakePicker? picker,
    bool preview = false,
  }) async {
    final s = testServices(tmp.path, picker: picker);
    s.settings.showPreview = preview;
    final st = await pumpApp(tester, s);
    final a = await tester.runAsync(() => ZxArchive.open(path ?? dbArchive));
    st.showArchive(a!);
    await tester.pump();
    await tester.pump();
    return st;
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  String pageLabel(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(const Key('page-label'))).data!;

  testWidgets('Data tab: groups, paging, sorting', (tester) async {
    final st = await openDb(tester);
    expect(st.database!.available, isTrue);
    expect(find.byKey(const Key('view-switch')), findsOneWidget);
    await tester.tap(find.byKey(const Key('tab-data')));
    await settle(tester);
    expect(find.byType(DataView), findsOneWidget);
    expect(find.text('Tables (1)'), findsOneWidget);
    expect(find.text('Views (1)'), findsOneWidget);
    expect(find.text('KV stores (1)'), findsOneWidget);
    expect(find.text('Time series (1)'), findsOneWidget);
    expect(find.byKey(const Key('obj:logs')), findsOneWidget);
    expect(
      find.text('System tables (${kSystemTables.length})'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('obj:zx_files')), findsOneWidget);
    expect(find.byKey(const Key('obj:settings')), findsOneWidget);

    await tester.tap(find.byKey(const Key('obj:items')));
    await settle(tester);
    expect(pageLabel(tester), 'Rows 1-100 of 250');
    expect(find.text('item 1'), findsOneWidget);
    await tester.tap(find.byKey(const Key('page-next')));
    await settle(tester);
    expect(pageLabel(tester), 'Rows 101-200 of 250');
    await tester.tap(find.byKey(const Key('page-next')));
    await settle(tester);
    expect(pageLabel(tester), 'Rows 201-250 of 250');
    expect(
      tester.widget<IconButton>(find.byKey(const Key('page-next'))).onPressed,
      isNull,
    );
    await tester.tap(find.byKey(const Key('page-prev')));
    await settle(tester);
    expect(pageLabel(tester), 'Rows 101-200 of 250');

    // sort by n descending: two clicks on the header
    await tester.tap(find.byKey(const Key('col:n')));
    await settle(tester);
    expect(pageLabel(tester), 'Rows 1-100 of 250');
    await tester.tap(find.byKey(const Key('col:n')));
    await settle(tester);
    final calls = (st.database!.opener == syncDbOpener)
        ? openTestDbs.last.calls
        : <String>[];
    expect(
      calls.where((c) => c.contains('ORDER BY "n" DESC LIMIT 100 OFFSET 0')),
      isNotEmpty,
    );
    expect(find.text('100'), findsWidgets); // n = 100 is the largest

    // a time series
    await tester.tap(find.byKey(const Key('obj:logs')));
    await settle(tester);
    expect(pageLabel(tester), 'Rows 1-1 of 1');
    expect(find.text('up'), findsOneWidget);

    // the system table of the files
    await tester.tap(find.byKey(const Key('obj:zx_files')));
    await settle(tester);
    expect(find.text('media/notes.md'), findsOneWidget);

    // back to the files
    await tester.tap(find.byKey(const Key('tab-files')));
    await settle(tester);
    expect(find.byType(DataView), findsNothing);
  });

  testWidgets('query box: results, errors, writes, export', (tester) async {
    final picker = FakePicker();
    final st = await openDb(tester, picker: picker);
    st.showData(true);
    await settle(tester);
    expect(find.byKey(const Key('sql-input')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('sql-input')),
      'SELECT name, n FROM items WHERE id <= 3 ORDER BY id',
    );
    await tester.tap(find.byKey(const Key('sql-run')));
    await settle(tester);
    expect(find.text('item 2'), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('sql-note'))).data,
      startsWith('3 rows'),
    );

    // export to CSV and JSON
    final csv = p.join(tmp.path, 'out.csv');
    final json = p.join(tmp.path, 'out.json');
    picker.saveAnswers.addAll([csv, json]);
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('export-csv')));
      await Future<void>.delayed(const Duration(milliseconds: 600));
    });
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('export-json')));
      await Future<void>.delayed(const Duration(milliseconds: 600));
    });
    await tester.pump();
    expect(
      File(csv).readAsStringSync(),
      'name,n\r\nitem 1,37\r\nitem 2,74\r\nitem 3,10\r\n',
    );
    final j = jsonDecode(File(json).readAsStringSync()) as List;
    expect(j[1], {'name': 'item 2', 'n': 74});

    // an error is shown, not thrown
    await tester.enterText(
      find.byKey(const Key('sql-input')),
      'SELECT * FROM nope',
    );
    await tester.tap(find.byKey(const Key('sql-run')));
    await settle(tester);
    expect(find.byKey(const Key('sql-error')), findsOneWidget);
    expect(find.textContaining('no such table: nope'), findsOneWidget);

    // a write: the new table appears in the list
    await tester.enterText(
      find.byKey(const Key('sql-input')),
      'CREATE TABLE extra (a TEXT)',
    );
    await tester.tap(find.byKey(const Key('sql-run')));
    await settle(tester);
    expect(find.byKey(const Key('sql-error')), findsNothing);
    expect(find.text('Tables (2)'), findsOneWidget);
    expect(find.byKey(const Key('obj:extra')), findsOneWidget);
  });

  testWidgets('an older version is read-only', (tester) async {
    final s = testServices(tmp.path);
    final st = await pumpApp(tester, s);
    final cur = await tester.runAsync(() => ZxArchive.open(dbArchive));
    final n = cur!.numVersions;
    await tester.runAsync(cur.close);
    final a = await tester.runAsync(
      () => ZxArchive.open(dbArchive, version: n - 1),
    );
    st.showArchive(a!);
    await tester.pump();
    await tester.pump();
    expect(st.database!.readOnly, isTrue);
    expect(st.database!.asOfGeneration, n - 1);
    st.showData(true);
    await settle(tester);
    expect(find.byKey(const Key('data-readonly')), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('sql-input')),
      'DELETE FROM items',
    );
    await tester.tap(find.byKey(const Key('sql-run')));
    await settle(tester);
    expect(find.textContaining('read-only'), findsWidgets);
    // reads use AS OF
    await tester.tap(find.byKey(const Key('obj:items')));
    await settle(tester);
    expect(
      openTestDbs.last.calls.where(
        (c) => c.contains('"items" AS OF GENERATION ${n - 1}'),
      ),
      isNotEmpty,
    );
  });

  testWidgets('metadata in Properties and in the preview', (tester) async {
    final st = await openDb(tester, preview: true);
    final m = st.model!;
    m.navigate('media/talks');
    m.selectPaths(['media/talks/a.txt']);
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await settle(tester);
    expect(find.byKey(const Key('preview-meta')), findsOneWidget);
    expect(find.text('Antenna talk'), findsOneWidget);
    expect(find.text('A talk about dipoles.'), findsOneWidget);
    expect(find.text('dipole-antenna'), findsOneWidget);
    expect(find.text('subtitles (en) a.en.srt'), findsOneWidget);
    expect(find.text('subtitles (pt-BR) a.pt-BR.srt'), findsOneWidget);
    expect(find.byType(Image), findsWidgets);

    var dialog = st.properties();
    await settle(tester);
    expect(find.byKey(const Key('item-properties')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('item-properties')),
        matching: find.text('Antenna talk'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Close'));
    await settle(tester);
    await dialog;

    // a file without metadata
    m.selectPaths(['media/talks/c.txt']);
    dialog = st.properties();
    await settle(tester);
    expect(find.byKey(const Key('meta-empty')), findsOneWidget);
    await tester.tap(find.text('Close'));
    await settle(tester);
    await dialog;
  });

  testWidgets('find similar files and find by SHA-256', (tester) async {
    final st = await openDb(tester);
    final m = st.model!;
    m.navigate('media/talks');
    m.selectPaths(['media/talks/a.txt']);
    await tester.pump();
    final similar = st.findSimilar();
    await settle(tester);
    expect(find.byKey(const Key('similar-dialog')), findsOneWidget);
    expect(find.byKey(const Key('result:media/talks/b.txt')), findsOneWidget);
    await tester.tap(find.byKey(const Key('result:media/talks/b.txt')));
    await settle(tester);
    await similar;
    expect(m.selection, {'media/talks/b.txt'});

    // the SHA-256 of b.txt
    final bytes = File(p.join(src, 'talks', 'b.txt')).readAsBytesSync();
    final hex = Sha256.hash(Uint8List.fromList(bytes))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final found = st.findBySha();
    await settle(tester);
    expect(find.byKey(const Key('sha-dialog')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('sha-input')), 'abc');
    await tester.tap(find.byKey(const Key('sha-find')));
    await settle(tester);
    expect(find.text('A SHA-256 is 64 hexadecimal digits.'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('sha-input')), '0' * 64);
    await tester.tap(find.byKey(const Key('sha-find')));
    await settle(tester);
    expect(find.byKey(const Key('sha-none')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('sha-input')), hex);
    await tester.tap(find.byKey(const Key('sha-find')));
    await settle(tester);
    expect(find.byKey(const Key('found:media/talks/b.txt')), findsOneWidget);
    await tester.tap(find.byKey(const Key('found:media/talks/b.txt')));
    await settle(tester);
    await found;
    expect(m.selection, {'media/talks/b.txt'});
  });

  testWidgets('Archive, New database', (tester) async {
    final copy = p.join(tmp.path, 'new_db.zx');
    File(plainArchive).copySync(copy);
    final st = await openDb(tester, path: copy);
    expect(st.database!.checked, isTrue);
    expect(st.database!.available, isFalse);
    expect(find.byKey(const Key('view-switch')), findsNothing);
    await st.newDatabase();
    await settle(tester);
    expect(st.database!.available, isTrue);
    expect(find.byType(DataView), findsOneWidget);
    expect(
      find.text('System tables (${kSystemTables.length})'),
      findsOneWidget,
    );
    await closeTestDbs();
    final s = ZxDbStore.open(copy, readOnly: true);
    expect(s.root, isNotNull);
    s.close();
  });

  test('CSV and JSON export text', () {
    final r = DbRows(
      ['a', 'b'],
      [
        ['x,y', null],
        [
          1,
          Uint8List.fromList([1, 255]),
        ],
      ],
    );
    expect(rowsToCsv(r), 'a,b\r\n"x,y",\r\n1,01ff\r\n');
    expect(jsonDecode(rowsToJson(r)), [
      {'a': 'x,y', 'b': null},
      {'a': 1, 'b': '01ff'},
    ]);
    expect(parseSha256('ab' * 32)!.length, 32);
    expect(parseSha256('xyz'), isNull);
    expect(sqlIsRead(' select 1'), isTrue);
    expect(sqlIsRead('PRAGMA user_version = 3'), isFalse);
    expect(sqlIsRead('insert into t values (1)'), isFalse);
  });

  test('the async connection (worker isolate)', () async {
    expect(await ZxDatabaseAsync.hasDatabase(plainArchive), isFalse);
    expect(await ZxDatabaseAsync.hasDatabase(dbArchive), isTrue);
    final s = DbSession(dbArchive, readOnlyWhy: 'test');
    await s.start();
    expect(s.available, isTrue);
    expect(await s.count('items'), 250);
    final meta = await s.fileMeta('media/talks/a.txt');
    expect(meta.title, 'Antenna talk');
    expect(meta.tags, ['radio', 'dipole-antenna']);
    expect(meta.layers.map((l) => l.language), ['en', 'pt-BR']);
    expect(meta.media.single.data, _png);
    expect(
      (await s.similar('media/talks/a.txt')).first.path,
      'media/talks/b.txt',
    );
    await expectLater(
      s.execute('DELETE FROM items'),
      throwsA(isA<ZxDbException>()),
    );
    await s.close();
  });
}
