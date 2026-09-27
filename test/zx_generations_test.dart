// Tests of .zx generations (docs/zx-format.md, section 9): appends,
// selection by number and date, the timeline of a file, compaction, crash
// safety, and multi-volume sets (section 10) with destination and search
// folders; then the same through ZxArchive.

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/format/archive_types.dart';
import 'package:zx/src/format/zx/zx_reader.dart';
import 'package:zx/zx.dart';

import 'zx_test_util.dart';

int _ns(DateTime t) => t.microsecondsSinceEpoch * 1000;

/// A new generation after [old]: [add] replaces or adds, [delete] removes.
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

void main() {
  final t1 = _ns(DateTime(2026, 3, 1, 12));
  final t2 = _ns(DateTime(2026, 3, 5, 9, 30));
  final t3 = _ns(DateTime(2026, 3, 5, 18));
  final t4 = _ns(DateTime(2026, 3, 9, 8));
  final a1 = textBytes(20000, 1), a2 = textBytes(21000, 2);
  final b = lcgBytes(9000, 3), c = textBytes(4000, 4);

  // gen 1: a (v1), b; gen 2: a (v2), c; gen 3: b deleted; gen 4: a (v1)
  // again, b again
  late Uint8List g4;
  setUpAll(() {
    final g1 = makeArchive({'a': a1, 'b': b}, testOptions()..time = t1);
    final g2 = appendGen(g1, add: {'a': a2, 'c': c}, time: t2, comment: 'two');
    final g3 = appendGen(g2, delete: {'b'}, time: t3);
    g4 = appendGen(g3, add: {'a': a1, 'b': b}, time: t4);
  });

  group('generations', () {
    test('an append keeps the earlier bytes', () {
      final g1 = makeArchive({'a': a1}, testOptions()..time = t1);
      final g2 = appendGen(g1, add: {'x': c}, time: t2);
      final r = ZxArchiveReader.open(MemoryInStream(g1), const ZxOpenParams())!;
      expect(g2.sublist(0, r.validEnd), g1.sublist(0, r.validEnd));
      final h = openMem(g2);
      expect(extractAll(h), {'a': a1, 'x': c});
      // the kept entry points to the block of generation 1
      final e = h.reader!.index.entries.firstWhere((e) => e.path == 'a');
      expect(e.extents[0], 0);
      expect(e.since, 1);
    });

    test('every generation is readable by number', () {
      expect(extractAll(openMem(g4, version: '1')), {'a': a1, 'b': b});
      expect(extractAll(openMem(g4, version: '2')), {'a': a2, 'b': b, 'c': c});
      expect(extractAll(openMem(g4, version: '3')), {'a': a2, 'c': c});
      expect(extractAll(openMem(g4)), {'a': a1, 'c': c, 'b': b});
      final h = openMem(g4);
      expect(h.getArchiveProperty(ZxKpid.numVersions), 4);
      final gens = h.reader!.generations;
      expect([for (final g in gens) g.number], [1, 2, 3, 4]);
      expect([for (final g in gens) g.time], [t1, t2, t3, t4]);
      expect(gens[1].comment, 'two');
      expect(
          () => openMem(g4, version: '5'), throwsA(isA<SevenZipException>()));
    });

    test('selection by date (local time)', () {
      String? a(String d) {
        final x = extractAll(openMem(g4, version: d))['a'];
        return x == null ? null : (x == a1 ? 'a1' : 'a2');
      }

      int gen(String d) => openMem(g4, version: d).reader!.shownGeneration;
      expect(gen('2026-03-01'), 1);
      expect(gen('2026-03-04'), 1);
      expect(gen('2026-03-05 09:29'), 1);
      expect(gen('2026-03-05 09:30'), 2);
      expect(gen('2026-03-05 09:30:00'), 2);
      expect(gen('2026-03-05 10:00'), 2);
      expect(gen('2026-03-05'), 3);
      expect(gen('2026-03-05T17:59:59'), 2);
      expect(gen('2027-01-01'), 4);
      expect(a('2026-03-05 12:00'), 'a2');
      expect(() => openMem(g4, version: '2026-02-28'),
          throwsA(isA<SevenZipException>()));
      expect(() => openMem(g4, version: '2026-13-01'),
          throwsA(isA<SevenZipException>()));
      expect(zxParseGenerationDate('26-03-01'), isNull);
    });

    test('the timeline of a file', () {
      final h = openMem(g4);
      final ta = h.timeline('a');
      // a1 in gen 1, a2 in gen 2, a1 again in gen 4
      expect([for (final v in ta) v.generation], [1, 2, 4]);
      expect([for (final v in ta) v.endGeneration], [2, 4, null]);
      expect([for (final v in ta) v.deleted], [false, false, false]);
      expect(ta[0].time, t1);
      final tb = h.timeline('b');
      expect([for (final v in tb) v.generation], [1, 4]);
      expect(tb[0].endGeneration, 3);
      expect(tb[0].deleted, true);
      expect(h.timeline('c').single.generation, 2);
      expect(h.timeline('nothing'), isEmpty);
      // the listing of -mtimeline
      final l = ZxHandler()..setProperties([]);
      l.options.timeline = 'a';
      l.open(MemoryInStream(g4));
      expect(l.numberOfItems, 3);
      expect(l.getProperty(1, ZxKpid.version), 2);
      expect(
          l.getProperty(1, Kpid.comment), contains('replaced in generation 4'));
    });

    test('an interrupted update: the last valid Footer, then overwritten', () {
      final tmp = Directory.systemTemp.createTempSync('zx_crash_');
      try {
        final f = File('${tmp.path}/x.zx');
        final g1 = makeArchive({'a': a1}, testOptions()..time = t1);
        // a partial generation after the Footer
        final part = appendGen(g1, add: {'x': c}, time: t2);
        f.writeAsBytesSync(part.sublist(0, part.length - 40));
        var h = ZxHandler();
        var s = FileInStream.open(f.path);
        expect(h.open(s, path: f.path), true);
        expect(extractAll(h), {'a': a1});
        expect(h.getArchiveProperty(Kpid.warning), contains('ignored'));
        // the next update writes after the valid Footer
        h.options.write
          ..threads = 1
          ..blockSize = 64 << 10;
        h.updateFile(f.path, 2, _Items([(-1, 'a', null), (0, 'y', b)], h));
        h.close();
        s.close();
        s = FileInStream.open(f.path);
        h = ZxHandler()..open(s, path: f.path);
        expect(extractAll(h), {'a': a1, 'y': b});
        expect(h.getArchiveProperty(Kpid.warning), isNull);
        expect(h.reader!.generations.length, 2);
        // the new generation starts where the valid part ended
        expect(f.readAsBytesSync().sublist(0, g1.length), g1);
        expect(h.reader!.lastIndex.blocks.last.offset, g1.length);
        h.close();
        s.close();
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });

    test('compaction', () {
      final tmp = Directory.systemTemp.createTempSync('zx_compact_');
      try {
        final f = File('${tmp.path}/x.zx')..writeAsBytesSync(g4);
        for (final keep in [2, 1]) {
          f.writeAsBytesSync(g4);
          final s = FileInStream.open(f.path);
          final h = ZxHandler()..open(s, path: f.path);
          final wasted = h.reader!.wastedBytes();
          expect(wasted, greaterThan(0));
          final freed = h.compact(f.path, keep);
          s.close();
          expect(freed, greaterThan(0));
          expect(f.lengthSync(), g4.length - freed);
          final h2 = openMem(f.readAsBytesSync());
          expect(extractAll(h2), {'a': a1, 'c': c, 'b': b});
          final gens = h2.reader!.generations;
          expect([for (final g in gens) g.number], keep == 1 ? [4] : [3, 4]);
          expect(gens.last.time, t4);
          expect(h2.reader!.header.archiveId, Uint8List(16));
          if (keep == 2) {
            expect(extractAll(openMem(f.readAsBytesSync(), version: '3')),
                {'a': a2, 'c': c});
          }
          expect(h2.reader!.wastedBytes(), 0);
        }
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });
  });

  group('volumes', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('zx_vol_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    ZxUpdateFileResult write(String path, Map<String, Uint8List> files,
        List<int> sizes, List<ZxVolumeDir> dirs) {
      final h = ZxHandler();
      h.options.write
        ..threads = 1
        ..blockSize = 64 << 10
        ..volumeDirs = dirs;
      return h.updateFile(path, files.length,
          _Items([for (final e in files.entries) (0, e.key, e.value)], h),
          volumeSizes: sizes);
    }

    test('two destination folders, search folders, a missing volume', () {
      final d1 = Directory('${tmp.path}/disk1')..createSync();
      final d2 = Directory('${tmp.path}/disk2')..createSync();
      final files = {
        'r1': lcgBytes(150000, 1),
        'r2': lcgBytes(150000, 2),
        't': textBytes(30000, 3),
      };
      final res = write('${tmp.path}/x.zx', files, [60000, 90000],
          [ZxVolumeDir(d1.path, budget: 150000), ZxVolumeDir(d2.path)]);
      final names = [for (final p in res.files) p.split('/').last];
      expect(names.first, 'x.zx.001');
      final in1 = d1.listSync().length, in2 = d2.listSync().length;
      expect(in1, 2); // 60000 + 90000 fill the budget
      expect(in2, greaterThanOrEqualTo(2));
      expect(
          File('${d1.path}/x.zx.001').lengthSync(), lessThanOrEqualTo(60000));
      expect(
          File('${d1.path}/x.zx.002').lengthSync(), lessThanOrEqualTo(90000));
      // opened from the first volume, the others in a search folder
      var s = FileInStream.open('${d1.path}/x.zx.001');
      var h = ZxHandler();
      h.options.searchDirs.add(d2.path);
      expect(h.open(s, path: '${d1.path}/x.zx.001'), true);
      expect(extractAll(h), files);
      expect(h.getArchiveProperty(Kpid.numVolumes), in1 + in2);
      h.close();
      s.close();
      // renamed and moved volumes are found by their header
      File('${d2.path}/x.zx.003').renameSync('${d2.path}/renamed.bin');
      s = FileInStream.open('${d1.path}/x.zx.002');
      h = ZxHandler();
      h.options.searchDirs.add(d2.path);
      expect(h.open(s, path: '${d1.path}/x.zx.002'), true);
      expect(extractAll(h), files);
      h.close();
      s.close();
      // a missing volume fails only the entries that use it
      File('${d1.path}/x.zx.002').renameSync('${tmp.path}/away');
      s = FileInStream.open('${d1.path}/x.zx.001');
      h = ZxHandler();
      h.options.searchDirs.add(d2.path);
      expect(h.open(s, path: '${d1.path}/x.zx.001'), true);
      final got = extractAll(h);
      expect(got['t'], files['t']);
      expect(got.values.where((v) => v == null), isNotEmpty);
      final cb = MemExtract();
      h.extract(null, true, cb);
      expect(cb.results.values, contains(OperationResult.unavailable));
      h.close();
      s.close();
    });

    test('an append goes to new volumes, the old ones stay as they were', () {
      final files = {'r': lcgBytes(100000, 1), 't': textBytes(10000, 2)};
      final res = write('${tmp.path}/x.zx', files, [50000], const []);
      final before = {for (final p in res.files) p: File(p).readAsBytesSync()};
      final s = FileInStream.open(res.files.first);
      final h = ZxHandler()..open(s, path: res.files.first);
      h.options.write
        ..threads = 1
        ..blockSize = 64 << 10;
      final r2 = h.updateFile(
          res.files.first,
          3,
          _Items(
              [(-1, 'r', null), (-1, 't', null), (0, 'n', textBytes(500, 5))],
              h));
      h.close();
      s.close();
      for (final e in before.entries) {
        expect(File(e.key).readAsBytesSync(), e.value);
      }
      expect(r2.files, isNotEmpty);
      expect(
          r2.files.first
              .endsWith('.${'${res.files.length + 1}'.padLeft(3, '0')}'),
          true);
      final s2 = FileInStream.open(res.files.first);
      final h2 = ZxHandler()..open(s2, path: res.files.first);
      expect(extractAll(h2), {...files, 'n': textBytes(500, 5)});
      expect(h2.reader!.generations.length, 2);
      // compaction rewrites the set
      final freed = h2.compact(res.files.first, 1);
      s2.close();
      expect(freed, greaterThanOrEqualTo(0));
      final s3 = FileInStream.open(res.files.first);
      final h3 = ZxHandler()..open(s3, path: res.files.first);
      expect(extractAll(h3), {...files, 'n': textBytes(500, 5)});
      h3.close();
      s3.close();
    });
  });

  group('ZxArchive', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('zx_api_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('create, add, delete, rename, versions, timeline, compact', () async {
      final src = Directory('${tmp.path}/src')..createSync();
      File('${src.path}/a.txt').writeAsBytesSync(a1);
      File('${src.path}/b.bin').writeAsBytesSync(b);
      final path = '${tmp.path}/x.zx';
      final z = await ZxArchive.create(path, [ZxSource(src.path)],
          options: const ZxOptions(switches: {'mt': '1'}));
      expect(z.format, 'zx');
      expect(z.numVersions, 1);
      expect(z['src/a.txt']!.sha256, isNotNull);
      expect(z['src/a.txt']!.tlsh, startsWith('T1'));
      File('${src.path}/a.txt').writeAsBytesSync(a2);
      await z.add([ZxSource('${src.path}/a.txt', storedAs: 'src/a.txt')],
          options: const ZxOptions(switches: {'mt': '1'}));
      expect(z.numVersions, 2);
      await z.rename('src/b.bin', 'src/b2.bin');
      await z.delete(['src/a.txt']);
      expect(z.numVersions, 4);
      expect(z['src/a.txt'], isNull);
      expect(z['src/b2.bin'], isNotNull);
      final old = await ZxArchive.open(path, version: 2);
      expect(await old.readBytes('src/a.txt'), a2);
      final today = await ZxArchive.open(path,
          date: DateTime.now().toIso8601String().substring(0, 10));
      expect(today.version, 4);
      final tl = await z.timeline('src/a.txt');
      expect(tl.length, 2);
      expect(tl.last.deleted, true);
      expect(tl.last.endGeneration, 4);
      expect(
          z.findBySha256(z['src/b2.bin']!.sha256!).single.path, 'src/b2.bin');
      final size = File(path).lengthSync();
      final freed = await z.compact();
      expect(freed, greaterThan(0));
      expect(File(path).lengthSync(), size - freed);
      // the generation kept keeps its number
      expect(z.versions.length, 1);
      expect(z.versions.single.number, 4);
      expect(z.numVersions, 4);
      expect(z.version, 4);
      expect(await z.readBytes('src/b2.bin'), b);
    });

    test('encrypted with volumes, search folders', () async {
      File('${tmp.path}/r.bin').writeAsBytesSync(lcgBytes(120000, 7));
      final dir2 = Directory('${tmp.path}/d2')..createSync();
      final path = '${tmp.path}/v.zx';
      final z = await ZxArchive.create(path, [ZxSource('${tmp.path}/r.bin')],
          options: ZxOptions(
              password: 'pw',
              encryptHeaders: true,
              volumeSizes: const [50000],
              volumeDirs: ['${tmp.path}:60000', dir2.path],
              switches: const {'mt': '1', 'kdf': '10'}));
      expect(z.volumes.length, greaterThanOrEqualTo(3));
      expect(z.encryptedHeaders, true);
      await expectLater(ZxArchive.open(z.volumes.first, password: 'bad'),
          throwsA(isA<SevenZipException>()));
      final z2 = await ZxArchive.open(z.volumes.first,
          password: 'pw', searchDirs: [dir2.path]);
      expect(await z2.readBytes('r.bin'), lcgBytes(120000, 7));
      final r = await z2.test();
      expect(r.errors, isEmpty);
      // an update of the encrypted set: new volumes, the same key
      File('${tmp.path}/n.txt').writeAsBytesSync(textBytes(3000, 1));
      await z2.add([ZxSource('${tmp.path}/n.txt')],
          options: const ZxOptions(switches: {'mt': '1'}));
      expect(z2.numVersions, 2);
      expect(await z2.readBytes('n.txt'), textBytes(3000, 1));
    });

    test('an encrypted archive with visible names', () async {
      File('${tmp.path}/s.txt').writeAsBytesSync(textBytes(9000, 3));
      final path = '${tmp.path}/e.zx';
      final z = await ZxArchive.create(path, [ZxSource('${tmp.path}/s.txt')],
          options: const ZxOptions(
              password: 'pw',
              encryptHeaders: false,
              switches: {'mt': '1', 'kdf': '10'}));
      expect(z.encryptedHeaders, false);
      expect(z['s.txt']!.encrypted, true);
      final z2 = await ZxArchive.open(path, password: 'pw');
      expect(await z2.readBytes('s.txt'), textBytes(9000, 3));
      File('${tmp.path}/t.txt').writeAsBytesSync(textBytes(100, 4));
      await z2.add([ZxSource('${tmp.path}/t.txt')],
          options: const ZxOptions(switches: {'mt': '1'}));
      expect(await z2.readBytes('t.txt'), textBytes(100, 4));
      final bad = await ZxArchive.open(path);
      final res = await bad.test();
      expect(res.errors, isNotEmpty);
    });
  });
}

/// An update callback: (0, path, data) is a new file, (-1, path, null) a
/// kept item of [h] by path.
class _Items extends ArchiveUpdateCallback {
  final List<(int, String, Uint8List?)> items;
  final ZxHandler h;
  _Items(this.items, this.h);

  int _oldIndex(String p) {
    final r = h.reader;
    if (r == null) return -1;
    return r.lastIndex.entries.indexWhere((e) => e.path == p);
  }

  @override
  UpdateItemInfo getUpdateItemInfo(int index) {
    final (k, p, _) = items[index];
    return k == -1
        ? UpdateItemInfo(false, false, _oldIndex(p))
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
