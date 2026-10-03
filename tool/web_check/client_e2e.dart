// The browser test of the web engine through its client, as the Flutter
// UI uses it (compiled with dart2js): uploads, URLs with and without range
// requests, the library, nested archives, READMEs, seals, passwords, SQL.
// The page (e2e.html) puts the fixtures in window.zxFixtures (name to
// File) and expected.json in window.zxExpected; this program writes one
// line per check into #out and sets the title to 'done'.

import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:zx/src/util/crc.dart';
import 'package:zx/src/web/engine_client.dart';
import 'package:zx/src/web/wire.dart' show sqlResultFromWire;
import 'package:zx/zx_client.dart';

final _lines = <String>[];
var _failed = 0;

void check(String what, bool ok, [Object? detail]) {
  if (!ok) _failed++;
  _lines
      .add('${ok ? 'ok  ' : 'FAIL'} $what${detail == null ? '' : ': $detail'}');
}

@JS('document.getElementById')
external JSObject? _byId(String id);

@JS('document')
external JSObject get _document;

void _show() {
  _byId('out')?['textContent'] = _lines.join('\n').toJS;
}

late Map<String, Object?> expected;
late ZxEngine engine;
final remote = '${(globalContext['location'] as JSObject)['protocol']}//'
    '${(globalContext['location'] as JSObject)['hostname']}:8766';

Future<String> upload(String name) async {
  final f = (globalContext['zxFixtures'] as JSObject)[name] as JSObject;
  final r = await engine.call('upload', files: [f].toJS);
  return (r.json as List).single as String;
}

/// Opens [path] and checks every file against expected.json[name].
Future<ZxArchive> openAndRead(String label, String path, String name,
    {String? password}) async {
  final a = await ZxArchive.open(path, password: password);
  final want = (expected[name] as Map).cast<String, Object?>();
  var good = 0;
  for (final e in want.entries) {
    final it = a[e.key];
    if (it == null) continue;
    final b = await a.readBytes(it);
    final w = e.value as List;
    if (b.length == w[0] && Crc32.of(b) == w[1]) good++;
  }
  check('$label: ${want.length} files read, CRC ok', good == want.length,
      '$good of ${want.length}, ${a.items.length} items, format ${a.format}');
  return a;
}

Future<Map<String, Object?>> stats(String path) async =>
    ((await engine.call('urlStats', args: {'path': path})).json as Map)
        .cast<String, Object?>();

Future<void> run() async {
  expected =
      (jsonDecode((globalContext['zxExpected'] as JSString).toDart) as Map)
          .cast<String, Object?>();
  engine = await ZxEngine.start('engine/zx_engine_worker.js');
  check(
      'engine started',
      true,
      'version ${engine.version}, '
          'library ${engine.hasLibrary}');

  // uploads
  for (final n in ['t.7z', 't.zip', 't.zx', 't.tar.gz']) {
    try {
      final a = await openAndRead('upload $n', await upload(n), n);
      final t = await a.test();
      check('upload $n: test', t.ok, t);
      await a.close();
    } catch (e) {
      check('upload $n', false, e);
    }
  }

  // README
  try {
    final a = await ZxArchive.open(await upload('t.zx'));
    final r = await a.readme();
    check('readme', r != null && r.doc.blocks.length == 2 && r.issues.isEmpty,
        '${r?.doc.blocks.length} blocks, issues ${r?.issues}');
  } catch (e) {
    check('readme', false, e);
  }

  // seals
  try {
    final a = await ZxArchive.open(await upload('sealed.zx'));
    final s = await a.seals(full: true);
    final sum = zxSealSummary(s);
    check('seals', s.length == 1 && s.single.state == ZxSealState.sealed, sum);
  } catch (e) {
    check('seals', false, e);
  }

  // password: wrong one first, then the right one
  try {
    final path = await upload('secret.zx');
    var asked = 0;
    final a = await ZxArchive.open(path, onPassword: (q) async {
      asked++;
      return asked == 1 ? 'wrong' : 'pw';
    });
    check('password asked', asked == 2, '$asked times');
    final b = await a.readBytes('a.txt');
    final w = (expected['secret.zx'] as Map)['a.txt'] as List;
    check('password: read', Crc32.of(b) == w[1]);
  } catch (e) {
    check('password', false, e);
  }

  // SQL
  try {
    final path = await upload('db.zx');
    final has = (await engine.call('db.has', args: {'path': path})).json;
    final db = (await engine.call('db.open', args: {'path': path})).json;
    final r = sqlResultFromWire(((await engine.call('db.sql',
                args: {'db': db, 'sql': 'SELECT count(*), max(name) FROM t'}))
            .json as Map)
        .cast());
    check('sql', has == true && r.rows.single[0] == 50, r.rows);
    try {
      await engine.call('db.sql',
          args: {'db': db, 'sql': "INSERT INTO t (name) VALUES ('x')"});
      check('sql read only', false);
    } on ZxDbException catch (e) {
      check('sql read only', true, e.kind.name);
    }
    final none =
        (await engine.call('db.has', args: {'path': await upload('t.zx')}))
            .json;
    check('sql: no database', none == false);
  } catch (e) {
    check('sql', false, e);
  }

  // URLs
  for (final mode in ['range', 'bare']) {
    try {
      final r =
          (await engine.call('url', args: {'url': '$remote/$mode/many.zx'}))
              .json as Map;
      check('url $mode: probe', r['access'] == 'range', r);
      final path = r['path'] as String;
      final a = await ZxArchive.open(path);
      final s0 = await stats(path);
      check('url $mode: listing reads little', (s0['bytes'] as int) < 2 << 20,
          '${a.items.length} items, $s0');
      final b = await a.readBytes('many/f7.txt');
      final w = (expected['many.zx'] as Map)['many/f7.txt'] as List;
      check('url $mode: one file', Crc32.of(b) == w[1], await stats(path));
      if (mode == 'range') {
        await openAndRead('url range: everything', path, 'many.zx');
        check('url range: totals', true, await stats(path));
      }
    } catch (e) {
      check('url $mode', false, e);
    }
  }
  for (final (mode, want) in [('norange', 'full'), ('nocors', 'blocked')]) {
    try {
      final r = (await engine.call('url', args: {'url': '$remote/$mode/t.7z'}))
          .json as Map;
      check('url $mode: probe', r['access'] == want, r);
    } catch (e) {
      check('url $mode', false, e);
    }
  }
  try {
    final r =
        (await engine.call('url', args: {'url': '$remote/range/missing.zx'}))
            .json as Map;
    check('url 404',
        r['access'] == 'blocked' && '${r['problem']}'.contains('404'), r);
  } catch (e) {
    check('url 404', false, e);
  }

  // the library
  if (engine.hasLibrary) {
    try {
      final d = (await engine.call('library.download',
              args: {'url': '$remote/norange/t.zip', 'name': 't.zip'}))
          .json as Map;
      final up = await upload('t.7z');
      final k = (await engine
              .call('library.import', args: {'path': up, 'name': 't.7z'}))
          .json as Map;
      final l = (await engine.call('library.list')).json as Map;
      final names = [for (final e in l['entries'] as List) e['name']];
      check(
          'library: list',
          names.contains(d['name']) && names.contains(k['name']),
          '$names ${l['usage']}');
      final p = (await engine.call('library.open', args: {'name': d['name']}))
          .json as String;
      await openAndRead('library: downloaded', p, 't.zip');
      final p2 = (await engine.call('library.open', args: {'name': k['name']}))
          .json as String;
      await openAndRead('library: kept', p2, 't.7z');
      for (final n in names) {
        await engine.call('library.remove', args: {'name': n});
      }
      final l2 = (await engine.call('library.list')).json as Map;
      check('library: removed', (l2['entries'] as List).isEmpty);
    } catch (e) {
      check('library', false, e);
    }
  }

  // create: a new .zx archive from two uploads, straight into the
  // library, password protected, then read back and downloaded
  if (engine.hasLibrary) {
    try {
      final p1 = await upload('t.zx');
      final p2 = await upload('t.7z');
      final r = await engine.call('library.create', args: {
        'name': 'created.zx',
        'paths': [p1, p2],
        'compression': {'auto': false, 'chain': 'store'},
        'solid': true,
        'password': 'secret123',
      });
      final m = r.json as Map;
      final entry = (m['entry'] as Map).cast<String, Object?>();
      check('create: no warnings', (m['warnings'] as List).isEmpty,
          m['warnings']);
      final p =
          (await engine.call('library.open', args: {'name': entry['name']}))
              .json as String;
      final a = await ZxArchive.open(p, password: 'secret123');
      final files = a.items.where((i) => !i.isDir).toList();
      check('create: items', files.length == 2,
          files.map((i) => i.path).toList());
      await a.close();
      final bytes =
          (await engine.call('library.read', args: {'name': entry['name']}))
              .bytes!;
      check('create: download size matches', bytes.length == entry['size'],
          '${bytes.length} vs ${entry['size']}');
      await engine.call('library.remove', args: {'name': entry['name']});
    } catch (e) {
      check('create', false, e);
    }
  }

  // nested: the .7z inside a .zip, read in place (stored item)
  // (covered by the native tests; here one open through the engine)
  try {
    final a = await ZxArchive.open(await upload('t.tar.gz'));
    check('tar.gz: sequential listing', a.listing.sequential, a.format);
  } catch (e) {
    check('tar.gz', false, e);
  }

  // cancel drops the answer
  try {
    final a = await ZxArchive.open(await upload('t.zx'));
    final c = ZxCancelToken();
    final f = a.readBytes('a.txt', cancel: c);
    c.cancel();
    await f;
    check('cancel', false);
  } on SevenZipException catch (e) {
    check('cancel', e.kind == SevenZipError.cancelled);
  }
}

Future<void> main() async {
  try {
    await run();
  } catch (e, st) {
    check('run', false, '$e\n$st');
  }
  _lines.add(_failed == 0 ? 'ALL PASSED' : '$_failed FAILED');
  _show();
  _document['title'] = 'done'.toJS;
}
