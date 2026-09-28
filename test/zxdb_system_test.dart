// Tests of the zxdb system layer (docs/zxdb-design.md 1.1): the virtual
// tables zx_files, zx_generations and zx_file_history over an archive
// with generations (plans, AS OF), the functions sha256, tlsh and
// tlsh_distance, the TLSH band index (in memory and persisted) and the
// table-valued function similar().

import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/crypto/sha256.dart';
import 'package:zx/src/db/memory_store.dart';
import 'package:zx/src/db/storage_api.dart';
import 'package:zx/src/db/system/archive_view.dart';
import 'package:zx/src/db/system/functions.dart';
import 'package:zx/src/db/meta/meta_store.dart';
import 'package:zx/src/db/sql/functions.dart';
import 'package:zx/src/db/sql/vtab.dart';
import 'package:zx/src/db/system/register.dart';
import 'package:zx/src/db/system/sql_adapter.dart';
import 'package:zx/src/db/system/sys_vtab.dart';
import 'package:zx/src/db/system/system_tables.dart';
import 'package:zx/src/db/system/tlsh_index.dart';
import 'package:zx/src/format/zx/zx_format.dart';
import 'package:zx/src/format/zx/zx_reader.dart';
import 'package:zx/src/format/zx/zx_writer.dart';
import 'package:zx/src/io/streams.dart';
import 'package:zx/src/util/tlsh.dart';

import 'zx_test_util.dart';

int _ns(DateTime t) => t.microsecondsSinceEpoch * 1000;

Uint8List appendGen(Uint8List old,
    {Map<String, Uint8List> add = const {},
    Set<String> delete = const {},
    required int time,
    String comment = ''}) {
  final r = ZxArchiveReader.open(MemoryInStream(old), const ZxOpenParams())!;
  final out = MemoryOutStream()..write(old, 0, r.validEnd);
  final o = testOptions()
    ..time = time
    ..generationComment = comment;
  final w = ZxWriter.append(r, o, ZxStreamSink(out, r.validEnd));
  for (final e in r.lastIndex.entries) {
    if (!delete.contains(e.path) && !add.containsKey(e.path)) w.addKept(e);
  }
  for (final e in add.entries) {
    w.addNew(ZxEntry(e.key, ZxKind.file), MemoryInStream(e.value));
  }
  w.finish();
  return Uint8List.fromList(out.toBytes());
}

/// A mutated copy of [b]: [n] bytes changed.
Uint8List mutate(Uint8List b, int n, int seed) {
  final r = Random(seed);
  final c = Uint8List.fromList(b);
  for (var i = 0; i < n; i++) {
    c[r.nextInt(c.length)] = 0x61 + r.nextInt(26);
  }
  return c;
}

class _Access implements SysDbAccess {
  final ZxStore store;
  ZxWriteTxn? txn;
  _Access(this.store);
  @override
  (ZxSnapshot, void Function()) read(SysAsOf? asOf) {
    final t = txn;
    if (t != null) return (t, () {});
    final s = store.snapshot();
    return (s, s.close);
  }

  @override
  ZxWriteTxn get writeTxn => txn!;
}

List<Object?> col(List<List<Object?>> rows, int i) => [for (final r in rows) r[i]];

void main() {
  final t1 = _ns(DateTime(2026, 3, 1, 12));
  final t2 = _ns(DateTime(2026, 3, 5, 9, 30));
  final t3 = _ns(DateTime(2026, 3, 5, 18));
  final t4 = _ns(DateTime(2026, 3, 9, 8));
  final a1 = textBytes(20000, 1), a2 = textBytes(21000, 2);
  final b = lcgBytes(9000, 3), c = textBytes(4000, 4);
  final d1 = textBytes(3000, 9);

  // gen 1: a (v1), b, docs/x; gen 2: a (v2), c; gen 3: b deleted;
  // gen 4: a (v1) again, b again
  late Uint8List g4;
  late ZxArchiveView av;
  setUpAll(() {
    final g1 = makeArchive(
        {'a': a1, 'b': b, 'docs': null, 'docs/x.txt': d1, 'docs/y.txt': a1},
        testOptions()..time = t1);
    final g2 = appendGen(g1, add: {'a': a2, 'c': c}, time: t2, comment: 'two');
    final g3 = appendGen(g2, delete: {'b'}, time: t3);
    g4 = appendGen(g3, add: {'a': a1, 'b': b}, time: t4);
    av = ZxArchiveView.memory(g4)!;
  });
  tearDownAll(() => av.close());

  group('zx_files', () {
    test('lists the current entries with their attributes', () {
      final t = ZxFilesTable(av);
      final rows = sysScanAll(t);
      expect(col(rows, 0), ['docs', 'docs/x.txt', 'docs/y.txt', 'c', 'a', 'b']);
      final a = rows.firstWhere((r) => r[0] == 'a');
      expect(a[ZxFilesTable.cKind], 'file');
      expect(a[ZxFilesTable.cSize], a1.length);
      expect(a[ZxFilesTable.cSha256], Sha256.hash(a1));
      expect(a[ZxFilesTable.cTlsh], Tlsh.of(a1));
      expect(a[ZxFilesTable.cSince], 4);
      expect(a[ZxFilesTable.cPacked], greaterThan(0));
      expect(a[ZxFilesTable.cMethod], isNotEmpty);
      expect(a[ZxFilesTable.cEncrypted], 0);
      final dir = rows.firstWhere((r) => r[0] == 'docs');
      expect(dir[ZxFilesTable.cKind], 'dir');
      expect(rows.firstWhere((r) => r[0] == 'c')[ZxFilesTable.cSince], 2);
    });

    test('sha256 equality uses the lookup table', () {
      final t = ZxFilesTable(av);
      final info = SysIndexInfo(
          [const SysConstraint(ZxFilesTable.cSha256, SysOp.eq)]);
      t.bestIndex(info);
      expect(info.idxNum, 1);
      expect(info.omit[0], isTrue);
      final rows = sysQuery(t, [('sha256', SysOp.eq, Sha256.hash(a1))]);
      expect(col(rows, 0)..sort(), ['a', 'docs/y.txt']);
      expect(sysQuery(t, [('sha256', SysOp.eq, Uint8List(32))]), isEmpty);
      expect(sysQuery(t, [('sha256', SysOp.eq, 'nope')]), isEmpty);
    });

    test('path equality, ranges, GLOB and LIKE prefixes', () {
      final t = ZxFilesTable(av);
      expect(col(sysQuery(t, [('path', SysOp.eq, 'c')]), 0), ['c']);
      expect(sysQuery(t, [('path', SysOp.eq, 'zz')]), isEmpty);
      expect(col(sysQuery(t, [('path', SysOp.glob, 'docs/*')]), 0),
          ['docs/x.txt', 'docs/y.txt']);
      expect(col(sysQuery(t, [('path', SysOp.like, 'DOCS/%')]), 0),
          ['docs/x.txt', 'docs/y.txt']);
      expect(col(sysQuery(t, [('path', SysOp.like, '%.txt')]), 0),
          ['docs/x.txt', 'docs/y.txt']);
      expect(
          col(
              sysQuery(t, [
                ('path', SysOp.ge, 'b'),
                ('path', SysOp.lt, 'docs/y'),
              ]),
              0),
          ['b', 'c', 'docs', 'docs/x.txt']);
      final info = SysIndexInfo([const SysConstraint(0, SysOp.glob)],
          [const SysOrderTerm(0)]);
      t.bestIndex(info);
      expect(info.idxNum, 3);
      expect(info.orderByConsumed, isTrue);
    });

    test('since_generation filters', () {
      final t = ZxFilesTable(av);
      expect(col(sysQuery(t, [('since_generation', SysOp.ge, 2)]), 0)..sort(),
          ['a', 'b', 'c']);
      expect(col(sysQuery(t, [('since_generation', SysOp.eq, 1)]), 0)..sort(),
          ['docs', 'docs/x.txt', 'docs/y.txt']);
    });

    test('AS OF a generation and a date', () {
      final t = ZxFilesTable(av);
      final g3 = sysScanAll(t, asOf: const SysAsOf.generation(3));
      expect(col(g3, 0)..sort(), ['a', 'c', 'docs', 'docs/x.txt', 'docs/y.txt']);
      expect(g3.firstWhere((r) => r[0] == 'a')[ZxFilesTable.cSha256],
          Sha256.hash(a2));
      final d = sysScanAll(t, asOf: const SysAsOf.date('2026-03-01'));
      expect(col(d, 0)..sort(), ['a', 'b', 'docs', 'docs/x.txt', 'docs/y.txt']);
      final byTime = sysScanAll(t, asOf: SysAsOf.time(t2));
      expect(byTime.length, 6);
      expect(() => sysScanAll(t, asOf: const SysAsOf.generation(9)),
          throwsA(isA<ZxDbException>()));
      expect(() => sysScanAll(t, asOf: const SysAsOf.date('2020-01-01')),
          throwsA(isA<ZxDbException>()));
      // sha lookup as of generation 2
      expect(
          col(
              sysQuery(t, [('sha256', SysOp.eq, Sha256.hash(a2))],
                  asOf: const SysAsOf.generation(2)),
              0),
          ['a']);
    });
  });

  group('zx_generations', () {
    test('lists the generations', () {
      final t = ZxGenerationsTable(av);
      final rows = sysScanAll(t);
      expect(col(rows, 0), [1, 2, 3, 4]);
      expect(col(rows, 1), [t1, t2, t3, t4]);
      expect(rows[1][2], 'two');
      expect(rows[2][4], 1); // b deleted
      expect(col(sysScanAll(t, asOf: const SysAsOf.generation(2)), 0), [1, 2]);
      expect(col(sysQuery(t, [('number', SysOp.ge, 3)]), 0), [3, 4]);
    });
  });

  group('zx_file_history', () {
    test('events of the whole archive', () {
      final t = ZxFileHistoryTable(av);
      final rows = sysScanAll(t);
      final ev = [for (final r in rows) '${r[5]} ${r[0]} ${r[1]}'];
      expect(ev, [
        'added a 1',
        'added b 1',
        'added docs 1',
        'added docs/x.txt 1',
        'added docs/y.txt 1',
        'changed a 2',
        'added c 2',
        'deleted b 3',
        'changed a 4',
        'added b 4',
      ]);
      final del = rows.firstWhere((r) => r[5] == 'deleted');
      expect(del[3], Sha256.hash(b));
      expect(del[4], b.length);
    });

    test('path = ? skips unchanged generations and agrees with the scan', () {
      final t = ZxFileHistoryTable(av);
      final all = sysScanAll(t);
      for (final p in ['a', 'b', 'c', 'docs/x.txt', 'nothing']) {
        final info = SysIndexInfo([const SysConstraint(0, SysOp.eq)]);
        t.bestIndex(info);
        expect(info.idxNum, 1);
        final one = sysQuery(t, [('path', SysOp.eq, p)]);
        expect(one, [
          for (final r in all)
            if (r[0] == p) r
        ], reason: p);
      }
      final a = sysQuery(t, [('path', SysOp.eq, 'a')]);
      expect(col(a, 5), ['added', 'changed', 'changed']);
      expect(a.last[3], Sha256.hash(a1));
    });

    test('generation filters and AS OF', () {
      final t = ZxFileHistoryTable(av);
      final g3 = sysQuery(t, [('generation', SysOp.eq, 3)]);
      expect([for (final r in g3) '${r[5]} ${r[0]}'], ['deleted b']);
      final upTo2 = sysScanAll(t, asOf: const SysAsOf.generation(2));
      expect(upTo2.every((r) => (r[1] as int) <= 2), isTrue);
      expect(upTo2.length, 7);
      final b2 = sysQuery(t, [('path', SysOp.eq, 'b')],
          asOf: const SysAsOf.generation(3));
      expect(col(b2, 5), ['added', 'deleted']);
    });
  });

  group('functions', () {
    test('sha256, tlsh, tlsh_distance', () {
      final f = {for (final x in zxSystemFunctions) x.name: x.fn};
      expect(f['sha256']!([a1]), Sha256.hash(a1));
      expect(f['sha256']!(['abc']), Sha256.hash(Uint8List.fromList('abc'.codeUnits)));
      expect(f['sha256']!([null]), isNull);
      expect(f['tlsh']!([a1]), Tlsh.of(a1));
      expect(f['tlsh']!([Uint8List(10)]), isNull);
      final x = Tlsh.of(a1)!, y = Tlsh.of(mutate(a1, 200, 1))!;
      expect(f['tlsh_distance']!([x, y]), tlshDistance(x, y));
      expect(f['tlsh_distance']!([x, 'bad']), isNull);
    });
  });

  group('TLSH band index', () {
    test('the binary distance equals tlshDistance', () {
      final r = Random(5);
      for (var i = 0; i < 200; i++) {
        final p = textBytes(2000 + r.nextInt(5000), r.nextInt(1 << 30));
        final q = mutate(p, r.nextInt(400), i);
        final x = Tlsh.of(p)!, y = Tlsh.of(q)!;
        expect(
            tlshBinDistance(tlshToBinary(x)!, 0, tlshToBinary(y)!, 0),
            tlshDistance(x, y));
      }
    });

    test('band query finds near copies; exact equals brute force', () {
      final r = Random(7);
      final texts = <String>[];
      // 2000 random digests plus 20 families of near copies
      for (var i = 0; i < 2000; i++) {
        texts.add(Tlsh.of(lcgBytes(600, i + 1))!);
      }
      final bases = <int>[];
      for (var f = 0; f < 20; f++) {
        final base = textBytes(8000, 1000 + f);
        bases.add(texts.length);
        texts.add(Tlsh.of(base)!);
        for (var k = 0; k < 5; k++) {
          texts.add(Tlsh.of(mutate(base, 20 + r.nextInt(60), f * 10 + k))!);
        }
      }
      final idx = TlshBandIndex.fromTexts(texts);
      final bins = [for (final t in texts) tlshToBinary(t)!];
      var found = 0, wanted = 0;
      for (final bi in bases) {
        final q = bins[bi];
        final brute = [
          for (var i = 0; i < texts.length; i++)
            (i, tlshBinDistance(q, 0, bins[i], 0))
        ]..sort((a, b) => a.$2 != b.$2 ? a.$2 - b.$2 : a.$1 - b.$1);
        final top6 = brute.take(6).toList();
        expect(idx.exact(q, 6), top6);
        final band = idx.query(q, 6);
        // recall of the true 6 nearest (the text families are all close
        // to each other: same vocabulary)
        final truth = {for (final h in top6) h.$1};
        wanted += truth.length;
        found += band.where((h) => truth.contains(h.$1)).length;
        // every hit carries its exact distance
        for (final (id, d) in band) {
          expect(d, tlshBinDistance(q, 0, bins[id], 0));
        }
      }
      expect(found / wanted, greaterThan(0.95));
      expect(idx.query(bins[0], 3, maxDistance: 0).map((h) => h.$2),
          everyElement(0));
    });

    test('similar() over the archive: lazy, exact, persisted', () {
      final files = <String, Uint8List?>{};
      final base = textBytes(12000, 77);
      files['base.txt'] = base;
      for (var k = 0; k < 6; k++) {
        files['near$k.txt'] = mutate(base, 10 + 15 * k, k);
      }
      for (var k = 0; k < 30; k++) {
        files['other$k.bin'] = lcgBytes(3000, 500 + k);
      }
      final arc = ZxArchiveView.memory(makeArchive(files, testOptions()))!;
      final sim = ZxSimilarity(arc);
      final lazy = sim.similar('base.txt', 5);
      expect(sim.lastMode, 'lazy');
      expect(lazy.length, 5);
      expect(lazy.every((h) => h.path.startsWith('near')), isTrue);
      final exact = sim.similar('base.txt', 5, exact: true);
      expect([for (final h in exact) h.distance],
          [for (final h in lazy) h.distance]);
      // by digest: the base itself first at distance 0
      final byDigest = sim.similar(Tlsh.of(base)!, 1);
      expect(byDigest.single.path, 'base.txt');
      expect(byDigest.single.distance, 0);

      // persisted in a database
      final store = ZxMemoryStore();
      final access = _Access(store);
      final txn = store.begin();
      expect(ZxTlshStore.sync(txn, arc), 37);
      txn.commit();
      final sim2 = ZxSimilarity(arc, database: access);
      final pers = sim2.similar('base.txt', 5);
      expect(sim2.lastMode, 'persisted');
      expect([for (final h in pers) h.distance],
          [for (final h in lazy) h.distance]);
      // a second sync adds nothing
      final txn2 = store.begin();
      expect(ZxTlshStore.sync(txn2, arc), 0);
      txn2.rollback();

      // the table-valued function
      final t = ZxSimilarTable(sim);
      final rows = sysQuery(t, [
        ('query', SysOp.eq, 'base.txt'),
        ('n', SysOp.eq, 3),
      ]);
      expect(rows.length, 3);
      expect(col(rows, 3), [for (final h in lazy.take(3)) h.distance]);
      arc.close();
    });

    test('the catalog bundles tables and functions', () {
      final store = ZxMemoryStore();
      final cat = ZxSystemCatalog(archive: av, db: _Access(store));
      expect(cat.tables.keys, containsAll([
        'zx_files', 'zx_generations', 'zx_file_history', 'similar', //
        'zx_meta', 'zx_layers', 'zx_media', 'zx_fingerprints', 'fts_search',
      ]));
      expect([for (final f in cat.functions) f.name],
          ['sha256', 'tlsh', 'tlsh_distance', 'fts_match']);
      expect(cat.schema.first, startsWith('CREATE TABLE zx_meta ('));
    });
  });

  group('SQL adapter', () {
    List<List<Object?>> run(ZxVirtualTable t, ZxVtabContext ctx,
        List<(int, ZxConstraintOp, Object?)> where) {
      final info = ZxIndexInfo(
          [for (final w in where) ZxIndexConstraint(w.$1, w.$2, true)],
          const [],
          const {});
      t.bestIndex(info);
      final args = List<Object?>.filled(
          info.argvIndex.fold(0, (a, b) => a > b ? a : b), null);
      for (var i = 0; i < where.length; i++) {
        if (info.argvIndex[i] > 0) args[info.argvIndex[i] - 1] = where[i].$3;
      }
      final c = t.open(ctx)..filter(info.idxNum, info.idxStr, args);
      final out = <List<Object?>>[];
      while (c.next()) {
        out.add([for (var i = 0; i < t.columns.length; i++) c.column(i)]);
      }
      c.close();
      return out;
    }

    test('archive tables, similar(), functions, metadata writes', () {
      final store = ZxMemoryStore();
      final sys = ZxSystemSql(archive: av);
      final tables = <String, ZxVirtualTable>{};
      final reg = ZxFunctionRegistry(builtins: false);
      sys.register((n, t) => tables[n] = t, reg);
      final snap = store.snapshot();
      final ctx = ZxVtabContext(snap, null, 1);
      final files = tables['zx_files']!;
      expect(files.columns.map((c) => c.name).first, 'path');
      final r = run(files, ctx, [(7, ZxConstraintOp.eq, Sha256.hash(a1))]);
      expect(col(r, 0)..sort(), ['a', 'docs/y.txt']);
      expect(run(files, ctx, [(0, ZxConstraintOp.glob, 'docs/*')]).length, 2);
      final hist = run(tables['zx_file_history']!, ctx,
          [(0, ZxConstraintOp.eq, 'a')]);
      expect(col(hist, 5), ['added', 'changed', 'changed']);
      final sim = run(tables['similar']!, ctx, [
        (4, ZxConstraintOp.eq, 'docs/x.txt'),
        (5, ZxConstraintOp.eq, 2),
      ]);
      expect(sim.length, 2);
      expect(reg.findScalar('tlsh', 1), isNotNull);
      expect(reg.findScalar('fts_match', 2), isNotNull);
      final sha = reg.findScalar('sha256', 1)!;
      expect(sha.impl([a1], _NoCtx()), Sha256.hash(a1));

      // metadata through the adapter: insert, scan with rowids, update,
      // delete
      final txn = store.begin();
      ZxMetaSchema.create(txn);
      final wctx = ZxVtabContext(txn, txn, 2);
      final meta = tables['zx_meta']! as ZxWritableVirtualTable;
      meta.insert(wctx, null, [Sha256.hash(a1), 'a', 1, 'Alpha']);
      meta.insert(wctx, null, [Sha256.hash(b), 'b', 2, 'Beta']);
      final c = meta.open(wctx)..filter(0, '', const []);
      final ids = <String, int>{};
      while (c.next()) {
        ids[c.column(1) as String] = c.rowid;
      }
      expect(ids.length, 2);
      meta.update(wctx, ids['a']!,
          [Sha256.hash(a1), 'a', 1, 'Alpha 2', null, null, null, null, null, null]);
      meta.delete(wctx, ids['b']!);
      final rows = run(meta, wctx, const []);
      expect(col(rows, 3), ['Alpha 2']);
      txn.commit();
    });
  });
}

class _NoCtx implements ZxFunctionContext {
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError();
}
