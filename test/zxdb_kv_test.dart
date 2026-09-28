// Tests of the KV stores of zxdb (lib/src/db/kv.dart), the ZxDatabase
// entry (lib/src/db/zxdb.dart) and its isolate API (zxdb_async.dart).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/db/meta/meta_store.dart';
import 'package:zx/src/db/system/tlsh_index.dart';
import 'package:zx/src/db/zxdb.dart';
import 'package:zx/src/db/zxdb_async.dart';
import 'package:zx/src/format/archive_types.dart';
import 'package:zx/src/format/zx/zx_handler.dart';
import 'package:zx/src/io/streams.dart';

import 'zx_test_util.dart';

Uint8List b(String s) => Uint8List.fromList(utf8.encode(s));

ZxDbStoreOptions opts() => ZxDbStoreOptions(
    pageSize: 4096,
    autoFoldBytes: 0,
    durable: false,
    refreshMicros: 0,
    threads: 1);

class _NewFiles extends ArchiveUpdateCallback {
  final List<(String, Uint8List)> files;
  _NewFiles(this.files);
  @override
  UpdateItemInfo getUpdateItemInfo(int index) =>
      const UpdateItemInfo(true, true, -1);
  @override
  Object? getProperty(int index, int propId) => switch (propId) {
        Kpid.path => files[index].$1,
        Kpid.size => files[index].$2.length,
        Kpid.isDir => false,
        _ => null,
      };
  @override
  InStream? getStream(int index) => MemoryInStream(files[index].$2);
}

void main() {
  late Directory tmp;
  var n = 0;
  String newPath() => '${tmp.path}/kv${n++}.zx';
  setUp(() => tmp = Directory.systemTemp.createTempSync('zxdb_kv_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('get, put, delete, scans, batch, reopen', () {
    final path = newPath();
    final db = ZxDatabase.open(path, create: true, options: opts());
    expect(ZxMetaSchema.exists(db.snapshot()), true);
    final kv = db.createKvStore('settings');
    expect(() => db.createKvStore('settings'), throwsA(isA<ZxDbException>()));
    expect(() => db.kv('nope'), throwsA(isA<ZxDbException>()));
    kv.putString('ui.theme', 'dark');
    kv.putString('ui.lang', 'de');
    kv.putString('net.proxy', 'none');
    kv.put(b('bin'), Uint8List.fromList([0, 1, 2, 255]));
    expect(kv.getString('ui.theme'), 'dark');
    expect(kv.get(b('bin')), [0, 1, 2, 255]);
    expect(kv.getString('missing'), isNull);
    expect(kv.scan(prefix: b('ui.')).map((e) => e.keyString),
        ['ui.lang', 'ui.theme']);
    expect(
        kv.scan(prefix: b('ui.'), reverse: true).map((e) => e.valueString),
        ['dark', 'de']);
    expect(kv.scan(from: b('bin'), to: b('ui')).map((e) => e.keyString),
        ['bin', 'net.proxy']);
    expect(kv.scan(limit: 2).length, 2);
    expect(kv.deleteString('net.proxy'), true);
    expect(kv.deleteString('net.proxy'), false);
    final g0 = db.snapshot().generation;
    kv.batch((w) {
      for (var i = 0; i < 1000; i++) {
        w.putString('item/$i', 'v$i');
      }
      w.deleteString('ui.lang');
    });
    expect(db.snapshot().generation, g0 + 1);
    expect(kv.length, 1002);
    expect(kv.getString('ui.lang'), isNull);
    expect(db.kvStores, ['settings']);
    // what SQL sees: the stored value with its header
    final raw = db.snapshot().tree(zxKvTreeName('settings'))!.get(b('ui.theme'))!;
    expect(zxKvDecode(raw)!.value, b('dark'));
    db.close();
    final db2 = ZxDatabase.open(path, options: opts());
    expect(db2.kv('settings').getString('item/999'), 'v999');
    expect(db2.kv('settings').scan(prefix: b('item/')).length, 1000);
    db2.dropKvStore('settings');
    expect(db2.kvStores, isEmpty);
    db2.close();
  });

  test('time to live: per store and per key, invisible, purged at fold', () {
    final db = ZxDatabase.open(newPath(), create: true, options: opts());
    var now = 1000000;
    db.nowMs = () => now;
    final cache =
        db.createKvStore('cache', ttl: const Duration(seconds: 10));
    final plain = db.createKvStore('plain');
    cache.putString('a', '1');
    cache.putString('b', '2', ttl: const Duration(seconds: 100));
    plain.putString('p', '1');
    plain.putString('q', '2', ttl: const Duration(seconds: 5));
    expect(plain.settings.mayExpire, true);
    now += 6000;
    expect(plain.getString('q'), isNull);
    expect(plain.getString('p'), '1');
    expect(cache.getString('a'), '1');
    now += 5000;
    expect(cache.getString('a'), isNull);
    expect(cache.getString('b'), '2');
    expect(cache.scan().map((e) => e.keyString), ['b']);
    expect(cache.scan().first.expiresAtMs, 1000000 + 100000);
    expect(cache.length, 2);
    db.fold();
    expect(cache.length, 1);
    expect(plain.length, 1);
    db.close();
  });

  test('watch: the changes of this process after commit', () async {
    final db = ZxDatabase.open(newPath(), create: true, options: opts());
    final kv = db.createKvStore('w');
    final all = <ZxKvChange>[];
    final users = <ZxKvChange>[];
    final s1 = kv.watch().listen(all.add);
    final s2 = kv.watch(prefix: b('user/')).listen(users.add);
    kv.putString('user/1', 'a');
    kv.putString('other', 'b');
    kv.deleteString('user/1');
    kv.batch((w) => w
      ..putString('user/2', 'c')
      ..putString('user/3', 'd'));
    await Future<void>.delayed(Duration.zero);
    expect(all.length, 5);
    expect(users.map((c) => (utf8.decode(c.key), c.deleted)),
        [('user/1', false), ('user/1', true), ('user/2', false), ('user/3', false)]);
    expect(users[2].generation, users[3].generation);
    expect(users[0].generation, lessThan(users[2].generation));
    await s1.cancel();
    await s2.cancel();
    db.close();
  });

  test('group commit: one generation for many writes', () async {
    final path = newPath();
    final db = ZxDatabase.open(path,
        create: true,
        groupCommit: const Duration(milliseconds: 200),
        options: opts());
    final kv = db.createKvStore('g');
    db.flush();
    final g0 = db.snapshot().generation;
    for (var i = 0; i < 500; i++) {
      kv.putString('k$i', 'v$i');
    }
    // pending: visible here, not committed yet
    expect(kv.getString('k499'), 'v499');
    expect(db.snapshot().generation, g0);
    // the timer commits it
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(db.snapshot().generation, g0 + 1);
    kv.putString('late', 'x');
    db.close();
    final db2 = ZxDatabase.open(path, options: opts());
    expect(db2.kv('g').getString('late'), 'x');
    expect(db2.kv('g').length, 501);
    db2.close();
  });

  test('past generations are read only views', () {
    final db = ZxDatabase.open(newPath(), create: true, options: opts());
    final kv = db.createKvStore('h');
    kv.putString('x', '1');
    final g1 = db.snapshot().generation;
    kv.putString('x', '2');
    final old = db.kv('h', generation: g1);
    expect(old.getString('x'), '1');
    expect(kv.getString('x'), '2');
    expect(() => old.putString('x', '3'), throwsA(isA<ZxDbException>()));
    final t1 = db.generations.firstWhere((g) => g.generation == g1).timeNs;
    expect(db.kv('h', atTimeNs: t1).getString('x'), '1');
    db.close();
  });

  test('the TLSH band index follows the file generations', () {
    final path = newPath();
    final h = ZxHandler()..options.write.threads = 1;
    h.updateFile(
        path,
        3,
        _NewFiles([
          ('a.txt', textBytes(20000, 1)),
          ('b.txt', textBytes(30000, 2)),
          ('c.bin', lcgBytes(10000, 3)),
        ]));
    final db = ZxDatabase.open(path, options: opts());
    db.createKvStore('x');
    final s = db.snapshot();
    expect(ZxTlshStore.indexedGeneration(s), 1);
    expect(s.tree(ZxTlshStore.digestsTree)!.length, 3);
    expect(ZxMetaSchema.exists(s), true);
    db.close();
  });

  test('KV stores in SQL: tables, CREATE and DROP KV STORE', () {
    final db = ZxDatabase.open(newPath(), create: true, options: opts());
    final sql = db.sql;
    sql.execute("CREATE KV STORE settings WITH (ttl = '7d', compression = 'fast')");
    sql.execute('CREATE KV STORE IF NOT EXISTS settings');
    expect(db.kv('settings').settings.ttlMs, 7 * 86400000);
    final kv = db.kv('settings');
    kv.putString('ui.theme', 'dark');
    kv.putString('ui.lang', 'de');
    kv.put(b('bin'), Uint8List.fromList([0xFF, 0]));
    expect(sql.select("SELECT key, value FROM settings WHERE key LIKE 'ui.%' ORDER BY key"),
        [
          ['ui.lang', 'de'],
          ['ui.theme', 'dark']
        ]);
    expect(sql.select("SELECT value FROM settings WHERE key = 'bin'"), [
      [Uint8List.fromList([0xFF, 0])]
    ]);
    expect(sql.select('SELECT count(*) FROM settings'), [
      [3]
    ]);
    sql.execute("INSERT INTO settings (key, value) VALUES ('net.proxy', 'none')");
    expect(kv.getString('net.proxy'), 'none');
    expect(() => sql.execute("INSERT INTO settings (key, value) VALUES ('net.proxy', 'x')"),
        throwsA(isA<ZxDbException>()));
    sql.execute("UPDATE settings SET value = 'fr' WHERE key = 'ui.lang'");
    expect(kv.getString('ui.lang'), 'fr');
    sql.execute("DELETE FROM settings WHERE key LIKE 'ui.%'");
    expect(kv.getString('ui.theme'), isNull);
    expect(sql.select('SELECT key FROM settings ORDER BY key'), [
      ['bin'],
      ['net.proxy']
    ]);
    // the system tables are there too
    expect(sql.select('SELECT count(*) FROM zx_generations').single.single,
        greaterThan(1));
    sql.execute('DROP KV STORE settings');
    expect(db.kvStores, isEmpty);
    sql.execute('DROP KV STORE IF EXISTS settings');
    db.close();
  });

  test('async API in a worker isolate', () async {
    final path = newPath();
    final db = await ZxDatabaseAsync.open(path,
        create: true,
        options: opts()
          ..compression = 'balanced'
          ..autoFoldBytes = 64 << 10);
    final kv = await db.createKvStore('a', compression: null);
    final changes = <ZxKvChange>[];
    final sub = kv.watch(prefix: b('k/')).listen(changes.add);
    await kv.put(b('k/1'), b('one'));
    expect(await kv.get(b('k/1')), b('one'));
    await kv.batch((w) {
      for (var i = 0; i < 3000; i++) {
        w.putString('k/$i', 'value number $i ' * 3);
      }
    });
    expect((await kv.scan(prefix: b('k/1'), limit: 3)).map((e) => e.keyString),
        ['k/1', 'k/10', 'k/100']);
    expect(await kv.delete(b('k/2')), true);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(changes.length, 3002);
    expect(await db.kvStores(), ['a']);
    final gens = await db.generations();
    expect(gens.length, greaterThan(3));
    expect(() => db.kv('none').get(b('x')), throwsA(isA<ZxDbException>()));
    // SQL in the worker
    expect(await db.select("SELECT count(*) FROM a WHERE key LIKE 'k/1%'"), [
      [1111]
    ]);
    await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)');
    await db.execute('INSERT INTO t (name) VALUES (?)', ['x']);
    expect(await db.select('SELECT name FROM t'), [
      ['x']
    ]);
    // the write buffer was folded in the background, or is now
    await db.fold();
    expect((await kv.get(b('k/77')))!.length, greaterThan(10));
    await sub.cancel();
    await db.close();
    final db2 = ZxDatabase.open(path, options: opts());
    expect(db2.store.unfoldedBytes, 0);
    expect(db2.kv('a').getString('k/2999'), 'value number 2999 ' * 3);
    db2.close();
  });
}
