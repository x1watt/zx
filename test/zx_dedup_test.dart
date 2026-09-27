// Tests of .zx deduplication (docs/zx-format.md, section 6.4): the
// chunker, dedup of copies, renamed files and shared parts, across
// appended generations, the whole-file fast path, dedup off, the chunk
// table (record 0x34) and its fingerprint, compaction keeping only the
// chunks still used and repacking partly used blocks; and the memory
// guard of the block workers.

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/common/method_props.dart';
import 'package:zx/src/format/archive_types.dart';
import 'package:zx/src/format/zx/zx_codecs.dart';
import 'package:zx/src/format/zx/zx_dedup.dart';
import 'package:zx/src/format/zx/zx_format.dart';
import 'package:zx/src/format/zx/zx_handler.dart';
import 'package:zx/src/format/zx/zx_reader.dart';
import 'package:zx/src/format/zx/zx_writer.dart';
import 'package:zx/src/io/streams.dart';

import 'zx_test_util.dart';

Uint8List _cat(List<Uint8List> parts) {
  final b = BytesBuilder(copy: false);
  for (final p in parts) {
    b.add(p);
  }
  return b.toBytes();
}

/// Dedup options for the tests: 8 KiB chunks (so that a few hundred KB
/// hold many chunks), 256 KiB blocks, LZMA2 level 1 (fast).
ZxWriteOptions dd({bool dedup = true, int threads = 1}) =>
    testOptions(threads: threads, blockSize: 256 << 10)
      ..dedup = dedup
      ..chunkLog2 = 13
      ..level = 1
      ..coders = const [ZxCoderSpec(ZxCodecId.lzma2, ZxCoderConfig(level: 1))];

ZxArchiveReader _reader(Uint8List a) =>
    ZxArchiveReader.open(MemoryInStream(a), const ZxOpenParams())!;

/// A new generation after [old]: [add] replaces or adds, [delete] removes.
(Uint8List, ZxWriteResult) _append(Uint8List old, ZxWriteOptions o,
    {Map<String, Uint8List> add = const {}, Set<String> delete = const {}}) {
  final r = _reader(old);
  final out = MemoryOutStream()..write(old, 0, r.validEnd);
  final w = ZxWriter.append(r, o, ZxStreamSink(out, r.validEnd));
  for (final e in r.lastIndex.entries) {
    if (!delete.contains(e.path) && !add.containsKey(e.path)) w.addKept(e);
  }
  for (final e in add.entries) {
    w.addNew(ZxEntry(e.key, ZxKind.file), MemoryInStream(e.value),
        knownSize: e.value.length);
  }
  final res = w.finish();
  return (Uint8List.fromList(out.toBytes()), res);
}

(Uint8List, ZxWriteResult) _create(
    Map<String, Uint8List> files, ZxWriteOptions o) {
  final out = MemoryOutStream();
  final w = ZxWriter.create(o, (h) => ZxStreamSink(out));
  for (final e in files.entries) {
    w.addNew(ZxEntry(e.key, ZxKind.file), MemoryInStream(e.value),
        knownSize: e.value.length);
  }
  final res = w.finish();
  return (Uint8List.fromList(out.toBytes()), res);
}

Uint8List _compact(Uint8List a, int keep, {ZxWriteOptions? o}) {
  final r = _reader(a);
  final out = MemoryOutStream();
  zxCompact(r, keep, (h) => ZxStreamSink(out), options: o ?? dd());
  return Uint8List.fromList(out.toBytes());
}

void _expectFiles(Uint8List a, Map<String, Uint8List> want,
    {String? version}) {
  final got = extractAll(openMem(a, version: version));
  expect(got.keys.toSet(), want.keys.toSet());
  for (final k in want.keys) {
    expect(got[k], want[k], reason: k);
  }
}

/// Every chunk of the chunk table lies inside an extent of an entry, and
/// inside its block.
void _expectChunksUsed(ZxIndex idx) {
  final t = idx.chunksValid!;
  for (var i = 0; i < t.length; i++) {
    final b = t.locs[3 * i], off = t.locs[3 * i + 1], len = t.locs[3 * i + 2];
    expect(off + len, lessThanOrEqualTo(idx.blocks[b].unpackedSize));
    var inside = false;
    for (final e in idx.entries) {
      for (var k = 0; k < e.extents.length; k += 3) {
        if (e.extents[k] == b &&
            e.extents[k + 1] <= off &&
            off + len <= e.extents[k + 1] + e.extents[k + 2]) {
          inside = true;
        }
      }
    }
    expect(inside, true, reason: 'chunk $i (block $b, $off+$len) is unused');
  }
}

void main() {
  // incompressible data, so that the sizes show what dedup saves
  final a = lcgBytes(300000, 11);
  final b = lcgBytes(200000, 12);
  final m = lcgBytes(512 << 10, 13);
  final x = lcgBytes(70000, 14), y = lcgBytes(90000, 15);

  group('chunker', () {
    List<int> cuts(Uint8List d, ZxChunker c) {
      c.reset();
      final out = <int>[];
      var p = 0;
      for (;;) {
        final q = c.scan(d, p, d.length);
        if (q < 0) break;
        out.add(q);
        p = q;
      }
      return out;
    }

    test('bounds and the average', () {
      final c = ZxChunker(13);
      expect(c.minSize, 512);
      expect(c.maxSize, 8192 * 127 ~/ 16);
      final d = lcgBytes(2 << 20, 3);
      final l = cuts(d, c);
      var prev = 0;
      for (final q in l) {
        expect(q - prev, inInclusiveRange(c.minSize, c.maxSize));
        prev = q;
      }
      final avg = d.length / l.length;
      expect(avg, inInclusiveRange(4096, 16384));
      // the largest chunk is at most the block size
      expect(ZxChunker(16, maxLimit: 4096).maxSize, 4096);
    });

    test('the cuts resynchronize after an insertion', () {
      final c = ZxChunker(13);
      final d = lcgBytes(1 << 20, 4);
      final p = lcgBytes(777, 5);
      final c1 = cuts(d, c).toSet();
      final c2 = {for (final q in cuts(_cat([p, d]), c)) q - p.length};
      final common = c1.intersection(c2).length;
      expect(common, greaterThan(c1.length - 3));
    });

    test('scanning in pieces gives the same cuts', () {
      final c = ZxChunker(12);
      final d = lcgBytes(300000, 6);
      final whole = cuts(d, c);
      c.reset();
      final pieces = <int>[];
      var p = 0;
      for (var s = 0; s < d.length; s += 1000) {
        final e = s + 1000 < d.length ? s + 1000 : d.length;
        var from = s;
        for (;;) {
          final q = c.scan(d, from, e);
          if (q < 0) break;
          pieces.add(q);
          p = q;
          from = q;
        }
      }
      expect(p, whole.last);
      expect(pieces, whole);
    });
  });

  group('dedup', () {
    test('copies and renamed files are stored once', () {
      final files = {'a': a, 'dir/a copy': a, 'b': b, 'other/b.bak': b};
      final (on, res) = _create(files, dd());
      final (off, _) = _create(files, dd(dedup: false));
      _expectFiles(on, files);
      _expectFiles(off, files);
      expect(on.length * 19 ~/ 10, lessThan(off.length));
      expect(on.length, lessThan(a.length + b.length + 20000));
      expect(res.dedupBytes, a.length + b.length);
      final r = _reader(on);
      expect(r.lastIndex.requiredFeatures & ZxFeature.dedup, isNot(0));
      expect(r.header.required & ZxFeature.dedup, isNot(0));
      // the copies share the extents of the first ones
      final e = {for (final e in r.lastIndex.entries) e.path: e};
      expect(e['dir/a copy']!.extents, e['a']!.extents);
      _expectChunksUsed(r.lastIndex);
      // no dedup: no chunk table, no dedup feature
      final r2 = _reader(off);
      expect(r2.lastIndex.chunkTable, isNull);
      expect(r2.lastIndex.requiredFeatures & ZxFeature.dedup, 0);
      expect(r2.header.required & ZxFeature.dedup, 0);
    });

    test('files sharing a middle part', () {
      final f1 = _cat([x, m, y]);
      final f2 = _cat([y, m, x, a]);
      final files = {'f1': f1, 'f2': f2};
      final (on, res) = _create(files, dd());
      final (off, _) = _create(files, dd(dedup: false));
      _expectFiles(on, files);
      // m is stored once (but its first and last chunks)
      expect(off.length - on.length, greaterThan(m.length * 3 ~/ 4));
      expect(res.reusedChunks, greaterThan(0));
      expect(res.reusedFiles, 0);
      // random access across shared extents
      final h = openMem(on);
      final i = h.reader!.index.entries.indexWhere((e) => e.path == 'f2');
      final s = h.getStream(i)!;
      s.position = y.length + 1000;
      final part = Uint8List(m.length);
      expect(readFully(s, part, 0, part.length), part.length);
      expect(part, f2.sublist(y.length + 1000, y.length + 1000 + m.length));
      expect(testAll(openMem(on)).values.toSet(), {OperationResult.ok});
    });

    test('appended generations dedup against earlier ones', () {
      final (g1, _) = _create({'a': _cat([x, m])}, dd());
      final (g2, r2) = _append(g1, dd(), add: {'b': _cat([m, y])});
      // the new generation stores y (and the chunks at the edges of m)
      expect(r2.packedBytes, lessThan(y.length + m.length ~/ 4));
      expect(r2.dedupBytes, greaterThan(m.length * 3 ~/ 4));
      final (g3, r3) = _append(g2, dd(), add: {'a': _cat([x, m, b])});
      expect(r3.packedBytes, lessThan(b.length + 40000));
      _expectFiles(g3, {'a': _cat([x, m, b]), 'b': _cat([m, y])});
      _expectFiles(g3, {'a': _cat([x, m])}, version: '1');
      _expectFiles(g3, {'a': _cat([x, m]), 'b': _cat([m, y])}, version: '2');
      final r = _reader(g3);
      _expectChunksUsed(r.indexOf(r.generations[1]));
      // the table of the last generation lists the chunks of all three
      expect(r.lastIndex.chunksValid!.length,
          greaterThan(r.indexOf(r.generations[0]).chunksValid!.length));
    });

    test('a file identical to a stored one reuses its extents', () {
      // generation 1 without dedup: no chunk table, only the SHA-256
      final (g1, _) = _create({'a': a, 'b': b}, dd(dedup: false));
      final (g2, r2) = _append(g1, dd(), add: {'copy of a': a});
      expect(r2.reusedFiles, 1);
      expect(r2.newBlocks, 0);
      final r = _reader(g2);
      final e = {for (final e in r.lastIndex.entries) e.path: e};
      expect(e['copy of a']!.extents, e['a']!.extents);
      expect(r.lastIndex.requiredFeatures & ZxFeature.dedup, isNot(0));
      _expectFiles(g2, {'a': a, 'b': b, 'copy of a': a});
      // in one generation too
      final (_, r3) = _create({'p': b, 'q': b}, dd());
      expect(r3.reusedFiles, 1);
    });

    test('dedup off by switch, chunk size by switch', () {
      final h = ZxHandler();
      h.setProperties([MapEntry('dedup', PropVariant.bstr('off'))]);
      expect(h.options.write.dedup, false);
      h.setProperties([MapEntry('dedup', PropVariant.bstr('32k'))]);
      expect(h.options.write.dedup, true);
      expect(h.options.write.chunkLog2, 15);
      h.setProperties([MapEntry('chunk', PropVariant.bstr('1m'))]);
      expect(h.options.write.chunkLog2, 20);
      expect(
          () => h.setProperties([MapEntry('chunk', PropVariant.bstr('1k'))]),
          throwsA(isA<InvalidArgException>()));
      h.setProperties([MapEntry('memuse', PropVariant.bstr('512m'))]);
      expect(h.options.memoryLimit, 512 << 20);
      expect(h.options.write.memoryLimit, 512 << 20);
    });

    test('streamed files do not dedup', () {
      final (s, _) = _create({'a': a, 'b': a}, dd()..streamed = true);
      final r = _reader(s);
      expect(r.header.streamed, true);
      expect(r.lastIndex.chunkTable, isNull);
      expect(s.length, greaterThan(2 * a.length));
      final h = ZxHandler();
      expect(h.openSeq(MemoryInStream(s)), true);
      expect(extractAll(h), {'a': a, 'b': a});
    });

    test('encryption: no chunk table in a clear Index', () {
      final (clear, _) = _create({'a': a, 'b': a},
          dd()
            ..password = 'pw'
            ..scryptLog2N = 10
            ..encryptMetadata = false);
      final r = _reader(clear);
      expect(r.lastIndex.chunkTable, isNull);
      expect(clear.length, lessThan(a.length + 20000));
      expect(extractAll(openMem(clear, password: 'pw'), password: 'pw'),
          {'a': a, 'b': a});
      final (hidden, _) = _create({'a': a},
          dd()
            ..password = 'pw'
            ..scryptLog2N = 10);
      final r1 = ZxArchiveReader.open(
          MemoryInStream(hidden), ZxOpenParams(password: () => 'pw'))!;
      expect(r1.lastIndex.chunksValid, isNotNull);
      final out = MemoryOutStream()..write(hidden, 0, r1.validEnd);
      final w = ZxWriter.append(
          r1, dd()..password = 'pw', ZxStreamSink(out, r1.validEnd));
      w.addKept(r1.lastIndex.entries.single);
      w.addNew(ZxEntry('b', ZxKind.file), MemoryInStream(a));
      final res = w.finish();
      expect(res.dedupBytes, a.length);
      expect(extractAll(openMem(out.toBytes(), password: 'pw'), password: 'pw'),
          {'a': a, 'b': a});
    });

    test('a chunk table of another block table is ignored', () {
      final (g, _) = _create({'a': a}, dd());
      final idx = _reader(g).lastIndex;
      expect(idx.chunksValid, isNotNull);
      // the record copied into an Index with other blocks (what an older
      // writer copying unknown records after a renumbering would do)
      final raw = idx.encode(multiVolume: false);
      final rec = zxRecords(raw).firstWhere((r) => r.type == ZxRec.chunkTable);
      final other = ZxIndex()
        ..blocks = [...idx.blocks.skip(1), idx.blocks.first]
        ..other.add(rec);
      final back = ZxIndex.decode(other.encode(multiVolume: false),
          multiVolume: false);
      expect(back.chunkTable, isNotNull);
      expect(back.chunksValid, isNull);
      final same = ZxIndex.decode(raw, multiVolume: false);
      expect(same.chunksValid!.length, idx.chunksValid!.length);
    });

    test('the output does not depend on the number of threads', () {
      final files = {'a': a, 'f': _cat([x, m, y]), 'g': _cat([m, a])};
      final (one, _) = _create(files, dd());
      final (three, r3) = _create(files, dd(threads: 3));
      expect(r3.workers, 3);
      expect(three, one);
    });
  });

  group('compaction', () {
    test('keeps only the chunks still used and repacks their blocks', () {
      final (g1, _) = _create({'a': a, 'b': b, 'c': _cat([x, m])}, dd());
      final (g2, _) = _append(g1, dd(), delete: {'b'});
      final r = _reader(g2);
      expect(r.wastedBytes(), greaterThan(b.length * 9 ~/ 10));
      final before = r.lastIndex.chunksValid!.length;
      final c = _compact(g2, 1);
      expect(c.length, lessThan(g2.length - b.length * 9 ~/ 10));
      _expectFiles(c, {'a': a, 'c': _cat([x, m])});
      final rc = _reader(c);
      expect(rc.wastedBytes(), 0);
      final t = rc.lastIndex.chunksValid!;
      expect(t.length, lessThan(before));
      _expectChunksUsed(rc.lastIndex);
      // dedup goes on against the compacted file, and b is new again
      final (g3, r3) = _append(c, dd(), add: {'a2': a, 'b': b});
      expect(r3.dedupBytes, a.length);
      expect(r3.packedBytes, greaterThan(b.length));
      _expectFiles(g3, {'a': a, 'c': _cat([x, m]), 'a2': a, 'b': b});
    });

    test('keeps the chunks of the kept generations', () {
      final (g1, _) = _create({'a': a, 'b': b}, dd());
      final (g2, _) = _append(g1, dd(), delete: {'b'}, add: {'m': m});
      final (g3, _) = _append(g2, dd(), delete: {'a'});
      final c = _compact(g3, 2);
      _expectFiles(c, {'a': a, 'm': m}, version: '2');
      _expectFiles(c, {'m': m});
      final rc = _reader(c);
      _expectChunksUsed(rc.indexOf(rc.generations.first));
      expect(rc.generations.map((g) => g.number), [2, 3]);
      expect(c.length, lessThan(g3.length - b.length * 9 ~/ 10));
    });

    test('solid blocks used in part are repacked', () {
      final t1 = textBytes(120000, 1), t2 = textBytes(150000, 2);
      final o = dd(dedup: false);
      final (g1, _) = _create({'t1': t1, 't2': t2, 'b': b}, o);
      final (g2, _) = _append(g1, o, delete: {'t2'});
      final c = _compact(g2, 1, o: dd(dedup: false));
      _expectFiles(c, {'t1': t1, 'b': b});
      expect(_reader(c).wastedBytes(), 0);
      final whole = _reader(g2);
      final cr = _reader(c);
      expect(cr.lastIndex.blocks.fold<int>(0, (s, x) => s + x.unpackedSize),
          lessThan(whole.lastIndex.blocks.fold<int>(0, (s, x) => s + x.unpackedSize)));
      // without repacking the blocks are copied whole
      final out = MemoryOutStream();
      zxCompact(_reader(g2), 1, (h) => ZxStreamSink(out), repack: false);
      expect(out.toBytes().length, greaterThan(c.length));
      _expectFiles(out.toBytes(), {'t1': t1, 'b': b});
    });

    test('repacking keeps the chain of each block', () {
      final o = dd()
        ..coders = const [
          ZxCoderSpec(
              ZxCodecId.ppmd7, ZxCoderConfig(level: 5, params: 'o=4:mem=16m'))
        ];
      final t1 = textBytes(200000, 3), t2 = textBytes(200000, 4);
      final (g1, _) = _create({'t1': t1, 't2': t2}, o);
      final (g2, _) = _append(g1, o, delete: {'t2'});
      final c = _compact(g2, 1);
      _expectFiles(c, {'t1': t1});
      Set<String> names(Uint8List z) => {
            for (final ch in _reader(z).lastIndex.chains.values)
              zxChainName(ch)
          };
      expect(names(c), names(g1));
      expect(names(c).single, startsWith('PPMd:o4:'));
    });
  });

  group('memory guard', () {
    test('fewer workers when the limit is small', () {
      final o = dd(threads: 4);
      final per = zxWorkerMemory(o.coders, o.blockSize);
      expect(zxWorkersFor(4, per, per * 2), 2);
      expect(zxWorkersFor(4, per, 1), 1);
      expect(zxWorkersFor(4, per, per * 100), 4);
      o.memoryLimit = per * 2 + 1;
      final w = ZxWriter.create(o, (h) => ZxStreamSink(MemoryOutStream()));
      expect(w.workers, 2);
      w.finish();
      expect(o.warnings, isEmpty);
      // an explicit thread count is lowered too, with a warning
      final o2 = dd(threads: 4)
        ..threadsExplicit = true
        ..memoryLimit = per;
      final w2 = ZxWriter.create(o2, (h) => ZxStreamSink(MemoryOutStream()));
      expect(w2.workers, 1);
      w2.finish();
      expect(o2.warnings.single, contains('-mmemuse'));
    });

    test('the estimate follows the chain', () {
      const bs = 16 << 20;
      final lz = zxWorkerMemory(
          const [ZxCoderSpec(ZxCodecId.lzma2, ZxCoderConfig(level: 5))], bs);
      final small = zxWorkerMemory(const [
        ZxCoderSpec(ZxCodecId.lzma2, ZxCoderConfig(level: 5, params: 'd=1m'))
      ], bs);
      expect(small, lessThan(lz));
      final ppmd = zxWorkerMemory(const [
        ZxCoderSpec(ZxCodecId.ppmd7, ZxCoderConfig(params: 'mem=192m'))
      ], bs);
      expect(ppmd, greaterThan(192 << 20));
      final zcm = zxWorkerMemory(const [
        ZxCoderSpec(0x10000, ZxCoderConfig(level: 5, params: 'level=6'))
      ], bs);
      expect(zcm, greaterThan(64 << 20));
      final ch = ZxChain(2, [
        ZxCoder(ZxCodecId.ppmd7,
            Uint8List.fromList([6, 0, 0, 0, 12])) // 192 MiB
      ]);
      expect(zxDecodeMemory(ch, 1 << 20), greaterThan(192 << 20));
      expect(zxDefaultMemoryLimit(), greaterThanOrEqualTo(64 << 20));
    });

    test('extraction under a tiny limit decodes one block at a time', () {
      final files = {'a': a, 'b': b, 'f': _cat([x, m, y])};
      final (arc, _) = _create(files, dd());
      final h = openMem(arc);
      h.options.memoryLimit = 1;
      h.options.threads = 3;
      final got = extractAll(h);
      for (final k in files.keys) {
        expect(got[k], files[k]);
      }
    });
  });
}
