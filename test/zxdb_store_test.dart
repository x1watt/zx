// Tests of the zxdb storage engine (lib/src/db/engine) and of the
// in-memory store (lib/src/db/memory_store.dart): the storage contract on
// both, the B+tree against a reference map under random operations over
// many generations, snapshots, crash safety, the writer lock between two
// isolates, the page cache, fold, compression levels, file entries in the
// same archive, reopen, encryption and vacuum.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/db/engine/store.dart';
import 'package:zx/src/db/memory_store.dart';
import 'package:zx/src/db/storage_api.dart';
import 'package:zx/src/format/archive_types.dart';
import 'package:zx/src/format/zx/zx_handler.dart';
import 'package:zx/src/io/streams.dart';

import 'zx_test_util.dart';

Uint8List k(String s) => Uint8List.fromList(utf8.encode(s));
String s(Uint8List b) => utf8.decode(b);

List<(String, String)> scanAll(ZxTree t,
    {Uint8List? from, Uint8List? to, bool reverse = false}) {
  final c = t.scan(from: from, to: to, reverse: reverse);
  final out = <(String, String)>[];
  while (c.moveNext()) {
    out.add((s(c.key), latin1.decode(c.value)));
  }
  c.close();
  return out;
}

/// An update callback: (0, path, data) is a new file, (-1, path, null) a
/// kept item of [h] by path.
class _Items extends ArchiveUpdateCallback {
  final List<(int, String, Uint8List?)> items;
  final ZxHandler h;
  _Items(this.items, this.h);

  @override
  UpdateItemInfo getUpdateItemInfo(int index) {
    final (kind, p, _) = items[index];
    final r = h.reader;
    final old = r == null
        ? -1
        : r.lastIndex.entries.indexWhere((e) => e.path == p);
    return kind == -1
        ? UpdateItemInfo(false, false, old)
        : const UpdateItemInfo(true, true, -1);
  }

  @override
  Object? getProperty(int index, int propId) {
    final (_, p, d) = items[index];
    return switch (propId) {
      Kpid.path => p,
      Kpid.size => d?.length,
      Kpid.isDir => false,
      _ => null,
    };
  }

  @override
  InStream? getStream(int index) => MemoryInStream(items[index].$3!);
}

/// The storage contract, on any store [make] gives.
void contractTests(String name, ZxStore Function() make) {
  group('$name contract', () {
    late ZxStore st;
    setUp(() => st = make());
    tearDown(() => st.close());

    test('put, get, delete, scan, bounds, reverse, deleteRange', () {
      final t = st.begin();
      final a = t.createTree('a');
      for (var i = 0; i < 100; i++) {
        a.put(k('k${i.toString().padLeft(3, '0')}'), k('v$i'));
      }
      expect(a.length, 100);
      expect(s(a.get(k('k042'))!), 'v42');
      expect(a.get(k('nope')), isNull);
      expect(a.delete(k('k042')), true);
      expect(a.delete(k('k042')), false);
      expect(a.length, 99);
      expect(scanAll(a, from: k('k010'), to: k('k013')).map((e) => e.$1),
          ['k010', 'k011', 'k012']);
      expect(
          scanAll(a, from: k('k010'), to: k('k013'), reverse: true)
              .map((e) => e.$1),
          ['k012', 'k011', 'k010']);
      expect(scanAll(a, to: k('k002'), reverse: true).map((e) => e.$1),
          ['k001', 'k000']);
      expect(a.deleteRange(from: k('k090')), 10);
      expect(a.deleteRange(to: k('k005')), 5);
      expect(a.length, 84);
      final g = t.commit();
      final sn = st.snapshot();
      expect(sn.generation, g);
      expect(sn.tree('a')!.length, 84);
      expect(scanAll(sn.tree('a')!).first.$1, 'k005');
      sn.close();
    });

    test('snapshot isolation, rollback, generations, time', () {
      var t = st.begin();
      t.createTree('a').put(k('x'), k('1'));
      final g1 = t.commit(comment: 'one');
      final s1 = st.snapshot();
      t = st.begin();
      t.tree('a')!.put(k('x'), k('2'));
      t.tree('a')!.put(k('y'), k('3'));
      // the transaction reads its own writes, the snapshot does not
      expect(s(t.tree('a')!.get(k('x'))!), '2');
      expect(s(s1.tree('a')!.get(k('x'))!), '1');
      final g2 = t.commit();
      expect(g2, g1 + 1);
      expect(s(s1.tree('a')!.get(k('x'))!), '1');
      expect(s1.tree('a')!.length, 1);
      expect(s(st.snapshot().tree('a')!.get(k('x'))!), '2');
      t = st.begin();
      t.tree('a')!.put(k('x'), k('3'));
      t.rollback();
      expect(() => t.tree('a'), throwsStateError);
      expect(s(st.snapshot().tree('a')!.get(k('x'))!), '2');
      final gens = st.generations;
      expect(gens.last.generation, g2);
      expect(gens.firstWhere((e) => e.generation == g1).comment, 'one');
      expect(st.snapshot(generation: g1).tree('a')!.length, 1);
      final t1 = gens.firstWhere((e) => e.generation == g1).timeNs;
      expect(st.snapshot(atTimeNs: t1).generation, greaterThanOrEqualTo(g1));
      expect(() => st.snapshot(generation: 999999),
          throwsA(isA<ZxDbException>()));
      expect(() => st.snapshot(atTimeNs: 1), throwsA(isA<ZxDbException>()));
    });

    test('trees: create, drop, options, errors', () {
      var t = st.begin();
      t.createTree('a', const TreeOptions(compression: 'fast'));
      t.createTree('b');
      expect(
          () => t.createTree('a'),
          throwsA(isA<ZxDbException>()
              .having((e) => e.kind, 'kind', ZxDbError.constraint)));
      expect(t.treeNames, ['a', 'b']);
      t.tree('b')!.put(k('1'), k('1'));
      t.commit();
      t = st.begin();
      t.dropTree('b');
      expect(t.tree('b'), isNull);
      expect(
          () => t.dropTree('b'),
          throwsA(isA<ZxDbException>()
              .having((e) => e.kind, 'kind', ZxDbError.notFound)));
      // dropped and created again: empty
      t.createTree('b').put(k('2'), k('2'));
      expect(t.tree('b')!.length, 1);
      t.setTreeOptions('a', const TreeOptions(compression: 'store'));
      t.commit();
      final sn = st.snapshot();
      expect(sn.treeNames, ['a', 'b']);
      expect(sn.tree('a')!.options.compression, 'store');
      expect(scanAll(sn.tree('b')!).map((e) => e.$1), ['2']);
      expect(sn.tree('zz'), isNull);
    });

    test('a second writer is busy; long keys are refused', () {
      final t = st.begin();
      expect(
          () => st.begin(waitMs: 0),
          throwsA(isA<ZxDbException>()
              .having((e) => e.kind, 'kind', ZxDbError.busy)));
      final a = t.createTree('a');
      expect(() => a.put(Uint8List(zxMaxKeyLength + 1), k('v')),
          throwsA(isA<ZxDbException>()));
      a.put(Uint8List(zxMaxKeyLength), k('v'));
      t.commit();
      st.begin().rollback();
    });

    test('a cursor follows the writes of its transaction', () {
      final t = st.begin();
      final a = t.createTree('a');
      for (var i = 0; i < 50; i++) {
        a.put(k('k${i.toString().padLeft(2, '0')}'), k('v'));
      }
      final c = a.scan();
      final seen = <String>[];
      while (c.moveNext()) {
        final key = s(c.key);
        seen.add(key);
        // delete ahead and behind, insert ahead
        a.delete(c.key);
        if (key == 'k10') a.delete(k('k11'));
        if (key == 'k20') a.put(k('k20x'), k('new'));
      }
      expect(seen.contains('k11'), false);
      expect(seen.contains('k20x'), true);
      expect(seen.length, 50);
      expect(a.length, 0);
      t.commit();
    });

    test('empty commits add no generation', () {
      final g0 = st.snapshot().generation;
      final t = st.begin();
      expect(t.commit(), g0);
      expect(st.snapshot().generation, g0);
    });
  });
}

// the i of the put that wrote key[j] in the spill test (7919 is prime to
// 30000, so each key is written once)
int _src(int j) {
  for (var i = 0; i < 30000; i++) {
    if ((i * 7919) % 30000 == j) return i;
  }
  return -1;
}

late Directory tmp;
var _n = 0;
String newPath() => '${tmp.path}/db${_n++}.zx';

ZxDbStoreOptions small({int pageSize = 4096}) => ZxDbStoreOptions(
    pageSize: pageSize,
    compression: 'fast',
    autoFoldBytes: 0,
    durable: false,
    refreshMicros: 0,
    threads: 1);

// every write through the delta layer, small memtables, many runs,
// frequent folds
ZxDbStoreOptions lsm({int pageSize = 4096}) => small(pageSize: pageSize)
  ..lsmMinEntries = 0
  ..lsmDirectRatio = 0
  ..lsmMemBytes = 6000
  ..lsmMaxRuns = 3
  ..lsmFoldRatio = 0.6
  ..lsmFoldMin = 0;

// the lock holder of the isolate test: begins, tells, waits, commits
void _holdLock(List<Object> args) {
  final path = args[0] as String;
  final port = args[1] as SendPort;
  final st = ZxDbStore.open(path, options: small());
  final t = st.begin();
  t.tree('a')!.put(k('from-isolate'), k('1'));
  port.send('locked');
  sleep(const Duration(milliseconds: 400));
  t.commit();
  st.close();
  port.send('done');
}

void main() {
  setUpAll(() => tmp = Directory.systemTemp.createTempSync('zxdb_store_'));
  tearDownAll(() => tmp.deleteSync(recursive: true));

  contractTests('memory', () => ZxMemoryStore());
  contractTests(
      'engine', () => ZxDbStore.open(newPath(), create: true, options: small()));
  contractTests('engine (delta layer)',
      () => ZxDbStore.open(newPath(), create: true, options: lsm()));
  deltaAndIndexTests();

  group('B+tree against a reference', () {
    for (final pageSize in [4096, 16384]) {
      test('random operations over 40 generations (page $pageSize)', () {
        final st =
            ZxDbStore.open(newPath(), create: true, options: small(pageSize: pageSize));
        final mem = ZxMemoryStore();
        final rnd = Random(pageSize);
        final ref = <String, Uint8List>{};
        final snaps = <int, Map<String, Uint8List>>{};
        String key() {
          final n = rnd.nextInt(3000);
          // shared prefixes, varied lengths
          return 'user/${(n % 37).toString().padLeft(2, '0')}/item$n'
              '${'x' * (n % 11)}';
        }

        Uint8List value() {
          final r = rnd.nextInt(100);
          final len = r < 90
              ? rnd.nextInt(200)
              : r < 98
                  ? rnd.nextInt(pageSize)
                  : 70000 + rnd.nextInt(90000); // overflow pages
          final v = Uint8List(len);
          for (var i = 0; i < len; i += 7) {
            v[i] = rnd.nextInt(256);
          }
          return v;
        }

        for (var g = 0; g < 40; g++) {
          final t = st.begin();
          final m = mem.begin();
          final tt = t.tree('t') ?? t.createTree('t');
          final mt = m.tree('t') ?? m.createTree('t');
          final ops = 50 + rnd.nextInt(400);
          for (var i = 0; i < ops; i++) {
            final op = rnd.nextInt(10);
            final kk = key();
            if (op < 6 || (g < 3 && op < 9)) {
              final v = value();
              tt.put(k(kk), v);
              mt.put(k(kk), v);
              ref[kk] = v;
            } else if (op < 9) {
              expect(tt.delete(k(kk)), ref.remove(kk) != null);
              mt.delete(k(kk));
            } else {
              // a range delete
              final a = key(), b = key();
              final lo = a.compareTo(b) < 0 ? a : b;
              final hi = a.compareTo(b) < 0 ? b : a;
              final n1 = tt.deleteRange(from: k(lo), to: k(hi));
              final n2 = mt.deleteRange(from: k(lo), to: k(hi));
              expect(n1, n2);
              ref.removeWhere(
                  (x, _) => x.compareTo(lo) >= 0 && x.compareTo(hi) < 0);
            }
          }
          expect(tt.length, ref.length);
          final gen = t.commit();
          m.commit();
          if (g % 7 == 0) snaps[gen] = Map.of(ref);
          // the committed state against the reference
          final sn = st.snapshot();
          final tr = sn.tree('t')!;
          expect(tr.length, ref.length);
          final keys = ref.keys.toList()..sort();
          final got = scanAll(tr);
          expect(got.map((e) => e.$1).toList(), keys);
          for (var i = 0; i < 30 && keys.isNotEmpty; i++) {
            final kk = keys[rnd.nextInt(keys.length)];
            expect(tr.get(k(kk)), ref[kk]);
          }
          // a bounded reverse scan against the memory store
          final a = key(), b = key();
          expect(scanAll(tr, from: k(a), to: k(b), reverse: true),
              scanAll(mem.snapshot().tree('t')!,
                  from: k(a), to: k(b), reverse: true));
        }
        // old generations are unchanged
        snaps.forEach((gen, m) {
          final tr = st.snapshot(generation: gen).tree('t')!;
          expect(tr.length, m.length);
          final got = scanAll(tr);
          final keys = m.keys.toList()..sort();
          expect(got.map((e) => e.$1).toList(), keys);
          for (final e in got.take(50)) {
            expect(latin1.encode(e.$2), m[e.$1]);
          }
        });
        // and after a reopen
        final path = st.path;
        st.close();
        final st2 = ZxDbStore.open(path, options: small());
        final tr = st2.snapshot().tree('t')!;
        expect(tr.length, ref.length);
        for (final e in ref.entries.take(200)) {
          expect(tr.get(k(e.key)), e.value);
        }
        st2.close();
      });
    }
  });

  test('crash safety: a partial commit is ignored and cut', () {
    final path = newPath();
    final st = ZxDbStore.open(path, create: true, options: small());
    var t = st.begin();
    final a = t.createTree('a');
    for (var i = 0; i < 2000; i++) {
      a.put(k('k$i'), k('v$i'));
    }
    final g1 = t.commit();
    final good = File(path).lengthSync();
    t = st.begin();
    for (var i = 0; i < 2000; i++) {
      t.tree('a')!.put(k('k$i'), k('w$i'));
    }
    t.commit();
    st.close();
    final full = File(path).readAsBytesSync();
    // cut the second commit at several places
    for (final cut in [good + 1, good + 100, (good + full.length) ~/ 2,
        full.length - 1, full.length - 33]) {
      File(path).writeAsBytesSync(Uint8List.sublistView(full, 0, cut));
      final s2 = ZxDbStore.open(path, options: small());
      expect(s2.snapshot().generation, g1);
      expect(s(s2.snapshot().tree('a')!.get(k('k7'))!), 'v7');
      // the next commit cuts the partial one
      final t2 = s2.begin();
      t2.tree('a')!.put(k('k7'), k('again'));
      t2.commit();
      s2.close();
      final s3 = ZxDbStore.open(path, options: small());
      expect(s(s3.snapshot().tree('a')!.get(k('k7'))!), 'again');
      expect(s(s3.snapshot().tree('a')!.get(k('k8'))!), 'v8');
      s3.close();
    }
  });

  test('identical large values share their overflow pages', () {
    final path = newPath();
    final st = ZxDbStore.open(path, create: true, options: small());
    final big = lcgBytes(300000, 5);
    final other = lcgBytes(200000, 6);
    var t = st.begin();
    final a = t.createTree('a');
    t.createTree('b');
    a.put(k('x'), big);
    t.commit();
    final one = File(path).lengthSync();
    t = st.begin();
    for (var i = 0; i < 5; i++) {
      t.tree('a')!.put(k('copy$i'), big);
      t.tree('b')!.put(k('copy$i'), big);
    }
    t.tree('b')!.put(k('other'), other);
    t.commit();
    // ten more copies cost a few pages, the other value its own
    expect(File(path).lengthSync() - one, lessThan(200000 + 50000));
    final sn = st.snapshot();
    expect(sn.tree('a')!.get(k('copy3')), big);
    expect(sn.tree('b')!.get(k('copy4')), big);
    expect(sn.tree('b')!.get(k('other')), other);
    // deleting some copies keeps the others; dropping a tree releases
    t = st.begin();
    t.tree('a')!.delete(k('x'));
    t.tree('a')!.put(k('copy0'), k('small now'));
    t.dropTree('b');
    t.commit();
    expect(s(st.snapshot().tree('a')!.get(k('copy0'))!), 'small now');
    expect(st.snapshot().tree('a')!.get(k('copy1')), big);
    final used = st.root!.nextPageId;
    t = st.begin();
    t.tree('a')!.deleteRange();
    t.commit();
    // every overflow page is free again, and new values reuse them
    final free = st.root!.free;
    var nFree = 0;
    for (var i = 1; i < free.length; i += 2) {
      nFree += free[i];
    }
    expect(nFree, greaterThanOrEqualTo(5));
    t = st.begin();
    t.tree('a')!.put(k('again'), other);
    t.commit();
    expect(st.root!.nextPageId, lessThanOrEqualTo(used + 2));
    expect(st.snapshot().tree('a')!.get(k('again')), other);
    // the old generations still read their values
    expect(sn.tree('b')!.get(k('copy2')), big);
    st.close();
  });

  test('a large transaction spills its pages before the commit', () {
    final path = newPath();
    final o = small()..txnMemoryBytes = 256 << 10;
    final st = ZxDbStore.open(path, create: true, options: o);
    var t = st.begin();
    final a = t.createTree('a');
    for (var i = 0; i < 30000; i++) {
      a.put(k('key${(i * 7919) % 30000}'), textBytes(60, i));
    }
    // another reader sees the last generation while pages are spilled
    final other = ZxDbStore.open(path, options: small());
    final g0 = other.snapshot().generation;
    expect(File(path).lengthSync(), greaterThan(200000));
    expect(other.snapshot().generation, g0);
    expect(other.snapshot().tree('a'), isNull);
    // updates of spilled pages, reads through them
    for (var i = 0; i < 30000; i += 3) {
      a.delete(k('key$i'));
    }
    expect(a.length, 20000);
    expect(a.get(k('key1')), textBytes(60, _src(1)));
    final g1 = t.commit();
    expect(other.snapshot().generation, g1);
    expect(other.snapshot().tree('a')!.length, 20000);
    // a large transaction rolled back leaves nothing
    final size = File(path).lengthSync();
    t = st.begin();
    for (var i = 0; i < 30000; i++) {
      t.tree('a')!.put(k('key$i'), k('changed'));
    }
    expect(File(path).lengthSync(), greaterThan(size));
    t.rollback();
    expect(File(path).lengthSync(), size);
    expect(st.snapshot().tree('a')!.get(k('key0')), isNull);
    expect(st.snapshot().tree('a')!.get(k('key1')), isNot(k('changed')));
    t = st.begin();
    t.tree('a')!.put(k('key0'), k('back'));
    t.commit();
    st.close();
    other.close();
    final st2 = ZxDbStore.open(path, options: small());
    expect(s(st2.snapshot().tree('a')!.get(k('key0'))!), 'back');
    expect(st2.snapshot().tree('a')!.length, 20001);
    st2.close();
  });

  test('the writer lock between two isolates', () async {
    final path = newPath();
    final st = ZxDbStore.open(path, create: true, options: small());
    final t = st.begin();
    t.createTree('a');
    t.commit();
    final port = ReceivePort();
    final events = StreamIterator(port);
    await Isolate.spawn(_holdLock, [path, port.sendPort]);
    expect(await events.moveNext(), true);
    expect(events.current, 'locked');
    // busy while the other isolate holds it
    expect(
        () => st.begin(waitMs: 50),
        throwsA(isA<ZxDbException>()
            .having((e) => e.kind, 'kind', ZxDbError.busy)));
    // waits for it; then sees its commit
    final sw = Stopwatch()..start();
    final t2 = st.begin(waitMs: 10000);
    expect(sw.elapsedMilliseconds, greaterThan(100));
    expect(s(t2.tree('a')!.get(k('from-isolate'))!), '1');
    t2.tree('a')!.put(k('main'), k('2'));
    t2.commit();
    expect(await events.moveNext(), true);
    expect(events.current, 'done');
    port.close();
    st.close();
  });

  test('page cache: hits, misses and budget', () {
    final path = newPath();
    final o = small()..pageCacheBytes = 256 << 10;
    final st = ZxDbStore.open(path, create: true, options: o);
    final t = st.begin();
    final a = t.createTree('a');
    for (var i = 0; i < 20000; i++) {
      a.put(k('key$i'), Uint8List(40));
    }
    t.commit();
    st.clearCaches();
    final tr = st.snapshot().tree('a')!;
    for (var i = 0; i < 20000; i += 7) {
      tr.get(k('key$i'));
    }
    final s1 = st.pageCacheStats;
    expect(s1.misses, greaterThan(10));
    expect(s1.bytes, lessThanOrEqualTo(256 << 10));
    // hot reads of one key hit
    for (var i = 0; i < 100; i++) {
      st.snapshot().tree('a')!.get(k('key5'));
    }
    final s2 = st.pageCacheStats;
    expect(s2.hits, greaterThan(s1.hits));
    st.close();
  });

  test('fold: the write buffer is coded again with the tree chain', () {
    final path = newPath();
    final st = ZxDbStore.open(path,
        create: true, options: small()..compression = 'balanced');
    final t = st.begin();
    final a = t.createTree('a');
    final ref = <String, Uint8List>{};
    for (var i = 0; i < 3000; i++) {
      final v = textBytes(50 + i % 300, i);
      a.put(k('doc/$i'), v);
      ref['doc/$i'] = v;
    }
    t.createTree('f', const TreeOptions(compression: 'fast'))
        .put(k('x'), k('y'));
    t.commit();
    expect(st.unfoldedBytes, greaterThan(100000));
    final before = File(path).lengthSync();
    final r = st.fold();
    expect(r.pages, greaterThan(10));
    expect(r.bytesOut, lessThan(r.bytesIn));
    expect(st.unfoldedBytes, 0);
    expect(st.fold().pages, 0);
    expect(File(path).lengthSync(), greaterThan(before));
    st.close();
    final st2 = ZxDbStore.open(path, options: small());
    final tr = st2.snapshot().tree('a')!;
    ref.forEach((key, v) => expect(tr.get(k(key)), v));
    expect(s(st2.snapshot().tree('f')!.get(k('x'))!), 'y');
    expect(st2.unfoldedBytes, 0);
    st2.close();
  });

  test('compression levels round trip', () {
    final path = newPath();
    final st = ZxDbStore.open(path, create: true, options: small());
    final levels = [
      'store',
      'fast',
      'balanced',
      'max',
      'LZMA2:d=1m',
      'zcm:level=1',
      'Delta:1+LZ4'
    ];
    final data = <String, Uint8List>{};
    var t = st.begin();
    for (final l in levels) {
      final tr = t.createTree('t:$l', TreeOptions(compression: l));
      for (var i = 0; i < 200; i++) {
        final v = textBytes(100 + i, i + l.length);
        tr.put(k('$i'), v);
        data['$l/$i'] = v;
      }
    }
    t.commit();
    t = st.begin();
    expect(() => t.createTree('bad', const TreeOptions(compression: 'nosuch')),
        throwsA(isA<ZxDbException>()));
    t.rollback();
    st.fold();
    st.close();
    final st2 = ZxDbStore.open(path, options: small());
    for (final l in levels) {
      final tr = st2.snapshot().tree('t:$l')!;
      expect(tr.options.compression, l);
      for (var i = 0; i < 200; i++) {
        expect(tr.get(k('$i')), data['$l/$i']);
      }
    }
    st2.close();
  });

  test('file entries and the database in one archive', () {
    final path = newPath();
    final fa = textBytes(30000, 1), fb = lcgBytes(20000, 2);
    // an archive of files first
    final h = ZxHandler();
    h.options.write
      ..threads = 1
      ..blockSize = 64 << 10;
    h.updateFile(path, 2, _Items([(0, 'a.txt', fa), (0, 'b.bin', fb)], h));
    // a database commit
    final st = ZxDbStore.open(path, options: small());
    final t = st.begin();
    t.createTree('kv').put(k('hello'), k('world'));
    final g = t.commit();
    // the files are there, the zx handler reads them
    Map<String, Uint8List?> files() => extractAll(
        openMem(Uint8List.fromList(File(path).readAsBytesSync())));
    expect(files(), {'a.txt': fa, 'b.bin': fb});
    // a file update through the handler keeps the database
    final fc = textBytes(5000, 9);
    final s0 = FileInStream.open(path);
    final h2 = ZxHandler()..options.write.threads = 1;
    expect(h2.open(s0, path: path), true);
    h2.updateFile(path, 2, _Items([(-1, 'a.txt', null), (0, 'c.txt', fc)], h2),
        releaseInput: s0.close);
    h2.close();
    s0.close();
    expect(files(), {'a.txt': fa, 'c.txt': fc});
    expect(s(st.snapshot().tree('kv')!.get(k('hello'))!), 'world');
    expect(st.snapshot().generation, g + 1);
    // and a database commit after it keeps the files
    final t2 = st.begin();
    t2.tree('kv')!.put(k('after'), k('files'));
    t2.commit();
    expect(files(), {'a.txt': fa, 'c.txt': fc});
    // an update of a handler opened before a database commit is refused
    final s1 = FileInStream.open(path);
    final h3 = ZxHandler()..options.write.threads = 1;
    expect(h3.open(s1, path: path), true);
    final t3 = st.begin();
    t3.tree('kv')!.put(k('race'), k('1'));
    t3.commit();
    expect(
        () => h3.updateFile(
            path, 1, _Items([(0, 'd.txt', fc)], h3),
            releaseInput: s1.close),
        throwsA(isA<SevenZipException>()));
    h3.close();
    s1.close();
    expect(s(st.snapshot().tree('kv')!.get(k('race'))!), '1');
    // a compaction by the handler keeps the database
    final s2 = FileInStream.open(path);
    final h4 = ZxHandler()..options.write.threads = 1;
    expect(h4.open(s2, path: path), true);
    s2.close();
    h4.compact(path, 1);
    h4.close();
    expect(files(), {'a.txt': fa, 'c.txt': fc});
    final kv = st.snapshot().tree('kv')!;
    expect(scanAll(kv).map((e) => e.$1), ['after', 'hello', 'race']);
    st.close();
  });

  test('encryption: pages and Index are encrypted', () {
    final path = newPath();
    final st = ZxDbStore.open(path,
        create: true, password: 'secret', options: small());
    final t = st.begin();
    final a = t.createTree('a');
    for (var i = 0; i < 500; i++) {
      a.put(k('plainkey$i'), k('plainvalue$i'));
    }
    t.commit();
    st.close();
    final raw = latin1.decode(File(path).readAsBytesSync());
    expect(raw.contains('plainkey'), false);
    expect(raw.contains('plainvalue'), false);
    expect(() => ZxDbStore.open(path, options: small()),
        throwsA(isA<ZxDbException>()));
    expect(() => ZxDbStore.open(path, password: 'wrong', options: small()),
        throwsA(isA<ZxDbException>()));
    final st2 = ZxDbStore.open(path, password: 'secret', options: small());
    expect(s(st2.snapshot().tree('a')!.get(k('plainkey7'))!), 'plainvalue7');
    final t2 = st2.begin();
    t2.tree('a')!.put(k('more'), k('x'));
    t2.commit();
    st2.fold();
    expect(st2.vacuum(), greaterThan(0));
    expect(s(st2.snapshot().tree('a')!.get(k('plainkey9'))!), 'plainvalue9');
    st2.close();
  });

  test('vacuum keeps the last generations and the data', () {
    final path = newPath();
    final st = ZxDbStore.open(path,
        create: true, options: small()..compression = 'balanced');
    for (var g = 0; g < 10; g++) {
      final t = st.begin();
      final a = t.tree('a') ?? t.createTree('a');
      for (var i = 0; i < 500; i++) {
        a.put(k('k$i'), textBytes(80, g * 1000 + i));
      }
      t.commit();
    }
    final last = st.snapshot().generation;
    final ref = scanAll(st.snapshot().tree('a')!);
    final prev = scanAll(st.snapshot(generation: last - 1).tree('a')!);
    final before = File(path).lengthSync();
    final freed = st.vacuum(keep: 2, recompress: true);
    expect(freed, greaterThan(0));
    expect(File(path).lengthSync(), lessThan(before));
    expect(st.generations.map((g) => g.generation), [last, last + 1]);
    expect(scanAll(st.snapshot().tree('a')!), ref);
    expect(scanAll(st.snapshot(generation: last).tree('a')!), ref);
    expect(prev.length, ref.length);
    // commits go on after it
    final t = st.begin();
    t.tree('a')!.put(k('new'), k('1'));
    t.commit();
    st.close();
    final st2 = ZxDbStore.open(path, options: small());
    expect(st2.snapshot().tree('a')!.length, 501);
    st2.close();
  });
}

// the delta layer (random operations against a model, folds interleaved,
// AS OF across folds) and the incremental Index (crash truncation at every
// stage of a commit, file updates and compaction in between)
void deltaAndIndexTests() {
  group('delta layer', () {
    for (final seed in [1, 2]) {
      test('random operations with folds against a model (seed $seed)', () {
        final st = ZxDbStore.open(newPath(), create: true, options: lsm());
        final rnd = Random(seed);
        final ref = <String, Uint8List>{};
        final snaps = <int, Map<String, Uint8List>>{};
        var sawRuns = 0, folds = 0;
        String key() => 'k${rnd.nextInt(1500).toString().padLeft(4, '0')}'
            '${'y' * rnd.nextInt(4)}';
        Uint8List value() {
          final r = rnd.nextInt(100);
          final len = r < 95 ? rnd.nextInt(120) : 3000 + rnd.nextInt(80000);
          final v = Uint8List(len);
          for (var i = 0; i < len; i += 5) {
            v[i] = rnd.nextInt(256);
          }
          return v;
        }

        for (var g = 0; g < 60; g++) {
          final t = st.begin();
          final tt = t.tree('t') ?? t.createTree('t');
          final ops = 20 + rnd.nextInt(g < 5 ? 600 : 150);
          for (var i = 0; i < ops; i++) {
            final op = rnd.nextInt(20);
            final kk = key();
            if (op < 13) {
              final v = value();
              tt.put(k(kk), v);
              ref[kk] = v;
            } else if (op < 18) {
              expect(tt.delete(k(kk)), ref.remove(kk) != null);
            } else if (op < 19) {
              final a = key(), b = key();
              final lo = a.compareTo(b) < 0 ? a : b;
              final hi = a.compareTo(b) < 0 ? b : a;
              final want = ref.keys
                  .where((x) => x.compareTo(lo) >= 0 && x.compareTo(hi) < 0)
                  .length;
              expect(tt.deleteRange(from: k(lo), to: k(hi)), want);
              ref.removeWhere(
                  (x, _) => x.compareTo(lo) >= 0 && x.compareTo(hi) < 0);
            } else {
              // reads inside the transaction see its writes
              expect(tt.get(k(kk)), ref[kk]);
            }
          }
          // (asked in a third of the transactions only: the others
          // commit a count settled later, by a snapshot or a fold)
          if (g % 3 == 0) expect(tt.length, ref.length);
          // a bounded scan inside the transaction
          final a = key(), b = key();
          final lo = a.compareTo(b) < 0 ? a : b;
          final hi = a.compareTo(b) < 0 ? b : a;
          final want = (ref.keys
                  .where((x) => x.compareTo(lo) >= 0 && x.compareTo(hi) < 0)
                  .toList()
                ..sort())
              .reversed
              .toList();
          expect(
              scanAll(tt, from: k(lo), to: k(hi), reverse: true)
                  .map((e) => e.$1)
                  .toList(),
              want);
          final gen = t.commit();
          final m = st.root; // the catalog holds the runs
          expect(m, isNotNull);
          final tr0 = st.snapshot().tree('t')!;
          if (_runsOf(st) > 0) sawRuns++;
          expect(tr0.length, ref.length);
          if (g % 6 == 0) snaps[gen] = Map.of(ref);
          if (g % 9 == 8) {
            st.fold();
            folds++;
            expect(_runsOf(st), 0);
          }
          final sn = st.snapshot();
          final tr = sn.tree('t')!;
          expect(tr.length, ref.length);
          final keys = ref.keys.toList()..sort();
          final got = scanAll(tr);
          expect(got.map((e) => e.$1).toList(), keys);
          for (var i = 0; i < 40 && keys.isNotEmpty; i++) {
            final kk = keys[rnd.nextInt(keys.length)];
            expect(tr.get(k(kk)), ref[kk]);
          }
          expect(tr.get(k('absent')), isNull);
        }
        expect(sawRuns, greaterThan(10));
        expect(folds, greaterThan(3));
        // AS OF: the generations before and after folds are unchanged
        void checkSnaps(ZxDbStore st) {
          snaps.forEach((gen, m) {
            final tr = st.snapshot(generation: gen).tree('t')!;
            expect(tr.length, m.length);
            final got = scanAll(tr);
            final keys = m.keys.toList()..sort();
            expect(got.map((e) => e.$1).toList(), keys);
            for (final e in got) {
              expect(latin1.encode(e.$2), m[e.$1]);
            }
          });
        }

        checkSnaps(st);
        final path = st.path;
        st.close();
        final st2 = ZxDbStore.open(path, options: lsm());
        checkSnaps(st2);
        // a vacuum keeping everything, then the last state only
        st2.vacuum(keep: 1000);
        checkSnaps(st2);
        st2.vacuum();
        final tr = st2.snapshot().tree('t')!;
        expect(tr.length, ref.length);
        for (final e in ref.entries) {
          expect(tr.get(k(e.key)), e.value);
        }
        st2.close();
      });
    }

    test('drop a tree with runs, large values in runs', () {
      final st = ZxDbStore.open(newPath(), create: true, options: lsm());
      final big = Uint8List(100000)..fillRange(0, 100000, 7);
      for (var g = 0; g < 6; g++) {
        final t = st.begin();
        final a = t.tree('a') ?? t.createTree('a');
        for (var i = 0; i < 300; i++) {
          a.put(k('a${(i * 37 + g) % 997}'), k('v$g'));
        }
        a.put(k('big$g'), big);
        t.commit();
      }
      expect(_runsOf(st), greaterThan(0));
      expect(st.snapshot().tree('a')!.get(k('big3')), big);
      final t = st.begin();
      t.dropTree('a');
      t.commit();
      expect(st.snapshot().tree('a'), isNull);
      final t2 = st.begin();
      t2.createTree('a').put(k('x'), k('y'));
      t2.commit();
      expect(scanAll(st.snapshot().tree('a')!), [('x', 'y')]);
      st.close();
    });
  });

  group('incremental Index', () {
    // an archive with many files (a large full Index) and a database
    String filesArchive() {
      final path = newPath();
      final h = ZxHandler();
      h.options.write.threads = 1;
      h.updateFile(path, 300, _Items([
        for (var i = 0; i < 300; i++) (0, 'dir/file$i.txt', textBytes(200, i))
      ], h));
      h.close();
      return path;
    }

    test('commits write deltas, checkpoints, reopen, files kept', () {
      final path = filesArchive();
      final st = ZxDbStore.open(path,
          options: small()..indexCheckpointCommits = 5);
      final sizes = <int>[];
      var deltas = 0;
      for (var g = 0; g < 13; g++) {
        final before = File(path).lengthSync();
        final t = st.begin();
        (t.tree('kv') ?? t.createTree('kv')).put(k('g$g'), k('v$g'));
        t.commit();
        sizes.add(File(path).lengthSync() - before);
        final r = st.root;
        expect(r, isNotNull);
      }
      // most commits are small deltas; one in about 6 is a checkpoint
      final sorted = List.of(sizes)..sort();
      final small0 = sorted.first;
      for (final x in sizes) {
        if (x < small0 * 3) deltas++;
      }
      expect(deltas, greaterThanOrEqualTo(9));
      expect(sorted.last, greaterThan(small0 * 3));
      final gens = st.generations;
      st.close();
      final st2 = ZxDbStore.open(path, options: small());
      expect(st2.generations.map((g) => g.generation),
          gens.map((g) => g.generation));
      for (var g = 0; g < 13; g++) {
        expect(s(st2.snapshot().tree('kv')!.get(k('g$g'))!), 'v$g');
      }
      // every generation opens (AS OF through deltas)
      for (final g in gens) {
        final sn = st2.snapshot(generation: g.generation);
        final n = sn.tree('kv')?.length ?? 0;
        expect(n, lessThanOrEqualTo(13));
      }
      st2.close();
      // the handler lists the files at the last generation (a delta)
      final files = extractAll(
          openMem(Uint8List.fromList(File(path).readAsBytesSync())));
      expect(files.length, 300, reason: files.keys.take(5).join(','));
      expect(files['dir/file7.txt'], textBytes(200, 7));
    });

    test('crash truncation at every stage of delta commits', () {
      final path = filesArchive();
      final st = ZxDbStore.open(path,
          options: small()..indexCheckpointCommits = 3);
      final ends = <int>[];
      final gens = <int>[];
      for (var g = 0; g < 5; g++) {
        final t = st.begin();
        final a = t.tree('kv') ?? t.createTree('kv');
        for (var i = 0; i < 50; i++) {
          a.put(k('k$i'), k('g$g'));
        }
        gens.add(t.commit());
        ends.add(File(path).lengthSync());
      }
      st.close();
      final full = File(path).readAsBytesSync();
      final start = ends.first;
      // every cut between the end of the first commit and the end
      var tried = 0;
      final cuts = <int>{
        for (var c = start; c <= full.length; c += 29) c,
        for (final e in ends) ...[e - 1, e, e + 1, e - 20, e - 32, e - 33],
        for (var c = full.length - 64; c <= full.length; c++) c,
      }.where((c) => c >= start && c <= full.length).toList()
        ..sort();
      for (final cut in cuts) {
        File(path).writeAsBytesSync(Uint8List.sublistView(full, 0, cut));
        var want = 0;
        for (var i = 0; i < ends.length; i++) {
          if (ends[i] <= cut) want = i;
        }
        final s2 = ZxDbStore.open(path, options: small());
        expect(s2.snapshot().generation, gens[want], reason: 'cut $cut');
        expect(s(s2.snapshot().tree('kv')!.get(k('k7'))!), 'g$want');
        s2.close();
        tried++;
      }
      expect(tried, greaterThan(50));
      // the next commit after a cut in the middle cuts the partial one
      final mid = (ends[2] + ends[3]) ~/ 2;
      File(path).writeAsBytesSync(Uint8List.sublistView(full, 0, mid));
      final s3 = ZxDbStore.open(path, options: small());
      final t = s3.begin();
      t.tree('kv')!.put(k('k7'), k('after'));
      t.commit();
      s3.close();
      final s4 = ZxDbStore.open(path, options: small());
      expect(s(s4.snapshot().tree('kv')!.get(k('k7'))!), 'after');
      expect(s(s4.snapshot().tree('kv')!.get(k('k8'))!), 'g2');
      s4.close();
      final files = extractAll(
          openMem(Uint8List.fromList(File(path).readAsBytesSync())));
      expect(files.length, 300);
    });

    test('file updates and compaction between delta commits', () {
      final path = filesArchive();
      final st = ZxDbStore.open(path, options: small());
      for (var g = 0; g < 4; g++) {
        final t = st.begin();
        (t.tree('kv') ?? t.createTree('kv')).put(k('a$g'), k('1'));
        t.commit();
      }
      // a file update (a full Index) then more deltas
      final s0 = FileInStream.open(path);
      final h = ZxHandler()..options.write.threads = 1;
      expect(h.open(s0, path: path), true);
      h.updateFile(path, 2,
          _Items([(-1, 'dir/file1.txt', null), (0, 'new.txt', k('new'))], h),
          releaseInput: s0.close);
      h.close();
      s0.close();
      for (var g = 4; g < 8; g++) {
        final t = st.begin();
        t.tree('kv')!.put(k('a$g'), k('1'));
        t.commit();
      }
      var files = extractAll(
          openMem(Uint8List.fromList(File(path).readAsBytesSync())));
      expect(files.keys.toSet(), {'dir/file1.txt', 'new.txt'});
      final g4 = st.generations[st.generations.length - 5].generation;
      expect(st.snapshot(generation: g4).tree('kv')!.length, 4);
      // compaction keeping 3 generations
      st.vacuum(keep: 3);
      expect(st.snapshot().tree('kv')!.length, 8);
      expect(st.generations.length, 3);
      files = extractAll(
          openMem(Uint8List.fromList(File(path).readAsBytesSync())));
      expect(files.keys.toSet(), {'dir/file1.txt', 'new.txt'});
      final t = st.begin();
      t.tree('kv')!.put(k('z'), k('1'));
      t.commit();
      st.close();
    });
  });
}

// the delta runs of tree 't' (or 'a') in the last generation
int _runsOf(ZxDbStore st) => st.deltaRunCount('t') + st.deltaRunCount('a');
