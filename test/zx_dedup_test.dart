// Tests of .zx deduplication (docs/zx-format.md, section 6.4): the
// chunker, dedup of copies, renamed files and shared parts, across
// appended generations, the whole-file check (streamed: a file is never
// held whole), dedup off, the chunk runs (record 0x36, section 6.4.1) and
// their fingerprint, a chunk table of zx 0.5.0 (record 0x34) migrated,
// compaction keeping only the chunks still used and repacking partly used
// blocks (zpaq with its method); and the memory guard of the block
// workers.

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/common/method_props.dart';
import 'package:zx/src/format/archive_types.dart';
import 'package:zx/src/format/zx/zx_blocks.dart';
import 'package:zx/src/format/zx/zx_chunkrun.dart';
import 'package:zx/src/format/zx/zx_codecs.dart';
import 'package:zx/src/format/zx/zx_crypto.dart';
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

void _expectFiles(Uint8List a, Map<String, Uint8List> want, {String? version}) {
  final got = extractAll(openMem(a, version: version));
  expect(got.keys.toSet(), want.keys.toSet());
  for (final k in want.keys) {
    expect(got[k], want[k], reason: k);
  }
}

/// Every chunk known to [idx] (its runs), sorted by block and offset.
ZxChunkTable _chunksOf(ZxArchiveReader r, ZxIndex idx) =>
    zxAllChunks(r.volumes, idx, r.keys);

/// Every chunk of the runs of [idx] lies inside an extent of an entry (of
/// [idx], or of [users]), and inside its block.
void _expectChunksUsed(ZxArchiveReader r, ZxIndex idx,
    {List<ZxIndex> users = const []}) {
  expect(idx.chunkRunsValid, isNotNull);
  final t = _chunksOf(r, idx);
  expect(t.length, greaterThan(0));
  final entries = [...idx.entries, for (final u in users) ...u.entries];
  for (var i = 0; i < t.length; i++) {
    final b = t.locs[3 * i], off = t.locs[3 * i + 1], len = t.locs[3 * i + 2];
    expect(off + len, lessThanOrEqualTo(idx.blocks[b].unpackedSize));
    var inside = false;
    for (final e in entries) {
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
      final c2 = {
        for (final q in cuts(_cat([p, d]), c)) q - p.length
      };
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
      _expectChunksUsed(r, r.lastIndex);
      // no dedup: no chunk runs, no dedup feature
      final r2 = _reader(off);
      expect(r2.lastIndex.chunkTable, isNull);
      expect(r2.lastIndex.chunkRuns, isNull);
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
      final (g1, _) = _create({
        'a': _cat([x, m])
      }, dd());
      final (g2, r2) = _append(g1, dd(), add: {
        'b': _cat([m, y])
      });
      // the new generation stores y (and the chunks at the edges of m)
      expect(r2.packedBytes, lessThan(y.length + m.length ~/ 4));
      expect(r2.dedupBytes, greaterThan(m.length * 3 ~/ 4));
      final (g3, r3) = _append(g2, dd(), add: {
        'a': _cat([x, m, b])
      });
      expect(r3.packedBytes, lessThan(b.length + 40000));
      _expectFiles(g3, {
        'a': _cat([x, m, b]),
        'b': _cat([m, y])
      });
      _expectFiles(
          g3,
          {
            'a': _cat([x, m])
          },
          version: '1');
      _expectFiles(
          g3,
          {
            'a': _cat([x, m]),
            'b': _cat([m, y])
          },
          version: '2');
      final r = _reader(g3);
      _expectChunksUsed(r, r.indexOf(r.generations[1]));
      // the runs of the last generation list the chunks of all three
      expect(_chunksOf(r, r.lastIndex).length,
          greaterThan(_chunksOf(r, r.indexOf(r.generations[0])).length));
      // no chunk table of zx 0.5.0 is written any more
      expect(r.lastIndex.chunkTable, isNull);
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
      expect(() => h.setProperties([MapEntry('chunk', PropVariant.bstr('1k'))]),
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

    test('encryption: encrypted runs, also with a clear Index', () {
      final (clear, _) = _create(
          {'a': a, 'b': a},
          dd()
            ..password = 'pw'
            ..scryptLog2N = 10
            ..encryptMetadata = false);
      final r = _reader(clear);
      expect(r.lastIndex.chunkTable, isNull);
      // the Index lists the runs (no hashes); the runs are encrypted: no
      // SHA-256 of a chunk is in the file
      expect(r.lastIndex.chunkRunsValid, isNotNull);
      expect(clear.length, lessThan(a.length + 20000));
      expect(extractAll(openMem(clear, password: 'pw'), password: 'pw'),
          {'a': a, 'b': a});
      final rk = ZxArchiveReader.open(
          MemoryInStream(clear), ZxOpenParams(password: () => 'pw'))!;
      rk.keysFor(() => 'pw');
      final chunks = _chunksOf(rk, rk.lastIndex);
      expect(chunks.length, greaterThan(10));
      bool contains(Uint8List hay, Uint8List needle) {
        outer:
        for (var i = 0; i + needle.length <= hay.length; i++) {
          for (var k = 0; k < needle.length; k++) {
            if (hay[i + k] != needle[k]) continue outer;
          }
          return true;
        }
        return false;
      }

      expect(contains(clear, Uint8List.sublistView(chunks.sha, 0, 32)), false);
      // an append deduplicates against them (a clear Index held no chunk
      // table in zx 0.5.0, so it could not)
      final outc = MemoryOutStream()..write(clear, 0, rk.validEnd);
      final wc = ZxWriter.append(
          rk,
          dd()
            ..password = 'pw'
            ..encryptMetadata = false,
          ZxStreamSink(outc, rk.validEnd));
      for (final e in rk.lastIndex.entries) {
        wc.addKept(e);
      }
      wc.addNew(ZxEntry('c', ZxKind.file), MemoryInStream(_cat([x, a])));
      final rc = wc.finish();
      expect(rc.dedupBytes, greaterThan(a.length * 9 ~/ 10));
      expect(
          extractAll(openMem(outc.toBytes(), password: 'pw'), password: 'pw'), {
        'a': a,
        'b': a,
        'c': _cat([x, a])
      });
      final (hidden, _) = _create(
          {'a': a},
          dd()
            ..password = 'pw'
            ..scryptLog2N = 10);
      final r1 = ZxArchiveReader.open(
          MemoryInStream(hidden), ZxOpenParams(password: () => 'pw'))!;
      expect(r1.lastIndex.chunkRunsValid, isNotNull);
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

    test('chunk runs of another block table are ignored', () {
      final (g, _) = _create({'a': a}, dd());
      final idx = _reader(g).lastIndex;
      expect(idx.chunkRunsValid, isNotNull);
      // the record copied into an Index with other blocks (what an older
      // writer copying unknown records after a renumbering would do)
      final raw = idx.encode(multiVolume: false);
      final rec = zxRecords(raw).firstWhere((r) => r.type == ZxRec.chunkRuns);
      final other = ZxIndex()
        ..blocks = [...idx.blocks.skip(1), idx.blocks.first]
        ..other.add(rec);
      final back =
          ZxIndex.decode(other.encode(multiVolume: false), multiVolume: false);
      expect(back.chunkRuns, isNotNull);
      expect(back.chunkRunsValid, isNull);
      final same = ZxIndex.decode(raw, multiVolume: false);
      expect(same.chunkRunsValid!.chunks, idx.chunkRunsValid!.chunks);
      // the same for a chunk table of zx 0.5.0
      final t = ZxIndex()
        ..blocks = idx.blocks
        ..chunkTable = _chunksOf(_reader(g), idx);
      final traw = t.encode(multiVolume: false);
      final trec =
          zxRecords(traw).firstWhere((r) => r.type == ZxRec.chunkTable);
      final t2 = ZxIndex()
        ..blocks = [...idx.blocks.skip(1), idx.blocks.first]
        ..other.add(trec);
      final tb =
          ZxIndex.decode(t2.encode(multiVolume: false), multiVolume: false);
      expect(tb.chunksValid, isNull);
      expect(ZxIndex.decode(traw, multiVolume: false).chunksValid, isNotNull);
    });

    test('the Index does not grow with the chunks', () {
      // 20 appends of new data: the chunk runs record stays small and the
      // runs stay few (size tiers), every chunk stays findable
      var (g, _) = _create({'f0': lcgBytes(60000, 100)}, dd());
      var stored = 0;
      final sizes = <int>[];
      for (var i = 1; i <= 20; i++) {
        final (g2, r2) =
            _append(g, dd(), add: {'f$i': lcgBytes(60000, 100 + i)});
        g = g2;
        stored += r2.storedChunks;
        final r = _reader(g);
        final raw = r.lastIndex.encode(multiVolume: false);
        final rec = zxRecords(raw).firstWhere((x) => x.type == ZxRec.chunkRuns);
        sizes.add(rec.payload.length);
        expect(r.lastIndex.chunkRunsValid!.runs.length, lessThanOrEqualTo(6));
      }
      expect(sizes.last, lessThan(64));
      final r = _reader(g);
      final all = _chunksOf(r, r.lastIndex);
      final (_, first) = _create({'f0': lcgBytes(60000, 100)}, dd());
      expect(all.length, stored + first.storedChunks);
      // everything is deduplicated against: the same files again store
      // nothing new
      final again = {
        for (var i = 0; i <= 20; i++) 'copy$i': lcgBytes(60000, 100 + i)
      };
      final (g3, r3) = _append(g, dd(), add: again);
      expect(r3.storedChunks, 0);
      expect(r3.dedupBytes, 21 * 60000);
      final want = {
        for (var i = 0; i <= 20; i++) 'f$i': lcgBytes(60000, 100 + i),
        ...again
      };
      _expectFiles(g3, want);
    });

    test('a chunk table of zx 0.5.0 is migrated into a run', () {
      final (g1, r1) = _create({'a': a, 'b': b}, dd());
      final legacy = _toLegacy(g1);
      final lr = _reader(legacy);
      expect(lr.lastIndex.chunkRuns, isNull);
      expect(lr.lastIndex.chunksValid!.length, r1.storedChunks);
      _expectFiles(legacy, {'a': a, 'b': b});
      final (g2, r2) = _append(legacy, dd(), add: {
        'c': _cat([x, a, y])
      });
      expect(r2.dedupBytes, greaterThan(a.length * 9 ~/ 10));
      final r = _reader(g2);
      expect(r.lastIndex.chunkTable, isNull);
      expect(
          _chunksOf(r, r.lastIndex).length, r1.storedChunks + r2.storedChunks);
      _expectFiles(g2, {
        'a': a,
        'b': b,
        'c': _cat([x, a, y])
      });
      // compaction of a legacy archive writes runs too
      final c = _compact(legacy, 1);
      final rc = _reader(c);
      expect(_chunksOf(rc, rc.lastIndex).length, r1.storedChunks);
    });

    test('a damaged run: its page is not used, the update goes on', () {
      // about 100 chunks: two pages
      final (g1, r1) = _create({'a': a, 'm': m}, dd());
      expect(r1.storedChunks, greaterThan(zxRunPageRecords));
      final r = _reader(g1);
      final ref = r.lastIndex.chunkRunsValid!.runs.single;
      // a byte of the first page of records
      final bad = Uint8List.fromList(g1);
      final h = ZxBlockHeader.tryParse(bad, ref.offset, bad.length)!;
      bad[ref.offset + h.headerSize + zxRunHeaderSize + 40] ^= 1;
      final (g2, r2) = _append(bad, dd(), add: {'copy': a});
      // the whole-file check still finds the copy
      expect(r2.reusedFiles, 1);
      _expectFiles(g2, {'a': a, 'm': m, 'copy': a});
      // the chunks of the damaged page are stored again, the others not
      final (g3, r3) = _append(bad, dd(), add: {
        'part': _cat([x, a, m])
      });
      expect(r3.storedChunks, greaterThan(0));
      expect(r3.dedupBytes, lessThan(a.length + m.length));
      expect(r3.dedupBytes, greaterThan((a.length + m.length) ~/ 4));
      _expectFiles(g3, {
        'a': a,
        'm': m,
        'part': _cat([x, a, m])
      });
      // a damaged trailer: the run is not opened, with a warning
      final bad2 = Uint8List.fromList(g1);
      bad2[ref.offset + ref.size - 2] ^= 1;
      final o = dd();
      final (g4, r4) = _append(bad2, o, add: {
        'part': _cat([x, a])
      });
      expect(o.warnings.join(), contains('chunk run'));
      expect(r4.dedupBytes, 0);
      _expectFiles(g4, {
        'a': a,
        'm': m,
        'part': _cat([x, a])
      });
      expect(r1.storedChunks, greaterThan(0));
    });

    test('whole-file check: streamed, spilled to disk, never held', () {
      // gen 1 without dedup: no chunks known, only the file hashes
      final big = lcgBytes(700000, 21); // several 256 KiB blocks
      final (g1, _) = _create({'big': big, 'b': b}, dd(dedup: false));
      final before = _spillDirs();
      // the copy (its size is that of a stored file): its new chunks wait
      // in the spill file, then are dropped
      final src = _CountingIn(big);
      final r = _reader(g1);
      final out = MemoryOutStream()..write(g1, 0, r.validEnd);
      final w = ZxWriter.append(r, dd(), ZxStreamSink(out, r.validEnd));
      for (final e in r.lastIndex.entries) {
        w.addKept(e);
      }
      w.addNew(ZxEntry('copy', ZxKind.file), src, knownSize: big.length);
      // same size, other content: its spilled chunks are stored
      final other = lcgBytes(700000, 22);
      w.addNew(ZxEntry('other', ZxKind.file), MemoryInStream(other),
          knownSize: other.length);
      // a copy of unknown size, small: dropped from the block being filled
      w.addNew(ZxEntry('b2', ZxKind.file), MemoryInStream(b));
      final res = w.finish();
      expect(res.reusedFiles, 2);
      expect(src.largestRead, lessThanOrEqualTo(1 << 16));
      expect(res.packedBytes, greaterThan(other.length));
      expect(res.packedBytes, lessThan(other.length + 60000));
      final g2 = Uint8List.fromList(out.toBytes());
      _expectFiles(
          g2, {'big': big, 'b': b, 'copy': big, 'other': other, 'b2': b});
      final r2 = _reader(g2);
      final e = {for (final e in r2.lastIndex.entries) e.path: e};
      expect(e['copy']!.extents, e['big']!.extents);
      expect(e['b2']!.extents, e['b']!.extents);
      expect(_spillDirs(), before);
    });
    test('the output does not depend on the number of threads', () {
      final files = {
        'a': a,
        'f': _cat([x, m, y]),
        'g': _cat([m, a])
      };
      final (one, _) = _create(files, dd());
      final (three, r3) = _create(files, dd(threads: 3));
      expect(r3.workers, 3);
      expect(three, one);
    });
  });

  group('chunk runs', () {
    // sorted random hashes and locations
    (Uint8List, Int64List) records(int n, int seed) {
      final sha = Uint8List(32 * n);
      final locs = Int64List(3 * n);
      final raw = lcgBytes(32 * n, seed);
      for (var i = 0; i < n; i++) {
        sha.setRange(32 * i, 32 * i + 32, raw, 32 * i);
        locs[3 * i] = i % 7;
        locs[3 * i + 1] = i * 11;
        locs[3 * i + 2] = 100 + i % 50;
      }
      return (sha, locs);
    }

    (ZxChunkRun, Uint8List) write(ZxMemChunks m, ZxKeys? keys) {
      final out = MemoryOutStream();
      final base = 100;
      out.write(Uint8List(base), 0, base);
      late ZxRunWriter w;
      final counts = zxMergeRuns(() => [m.cursor()], (count) {
        return w = ZxRunWriter((b) => out.write(b, 0, b.length), count, keys);
      });
      expect(counts, [m.length]);
      final bytes = Uint8List.fromList(out.toBytes());
      expect(bytes.length - base, w.blockSize);
      expect(zxRunBlockSize(m.length, keys != null), w.blockSize);
      final ref = ZxChunkRunRef(0, base, w.blockSize, m.length);
      final vols = ZxVolumes.single(MemoryInStream(bytes), Uint8List(16));
      return (ZxChunkRun.open(vols, ref, keys), bytes);
    }

    for (final enc in [false, true]) {
      test('write, open, find, scan${enc ? ' (encrypted)' : ''}', () {
        final keys = enc ? ZxKeys(lcgBytes(32, 1), lcgBytes(32, 2)) : null;
        const n = 5000;
        final (sha, locs) = records(n, 3);
        final m = ZxMemChunks.sort(sha, locs, n);
        final (run, bytes) = write(m, keys);
        expect(run.count, n);
        // the memory of a run: about 1.5 bytes a chunk
        expect(run.memoryBytes, lessThan(n * 2));
        for (var i = 0; i < n; i += 7) {
          final h = run.find(sha, 32 * i)!;
          expect(h.block, locs[3 * i]);
          expect(h.offset, locs[3 * i + 1]);
          expect(h.length, locs[3 * i + 2]);
        }
        // misses: the filter answers most without a read
        final miss = lcgBytes(32 * 2000, 9);
        final read0 = run.pagesRead;
        for (var i = 0; i < 2000; i++) {
          expect(run.find(miss, 32 * i), isNull);
        }
        expect(run.pagesRead - read0, lessThan(80));
        // a scan gives every record in order
        final c = run.cursor();
        var k = 0;
        Uint8List? prev;
        while (c.next()) {
          final cur = Uint8List.fromList(
              Uint8List.sublistView(c.sha, c.shaOff, c.shaOff + 32));
          if (prev != null) expect(zxCompareHash(prev, 0, cur, 0), lessThan(0));
          prev = cur;
          k++;
        }
        expect(k, n);
        // encrypted: no hash in the clear
        if (enc) {
          final h0 = Uint8List.sublistView(sha, 0, 8);
          var found = false;
          for (var i = 0; i + 8 <= bytes.length && !found; i++) {
            var same = true;
            for (var j = 0; j < 8 && same; j++) {
              same = bytes[i + j] == h0[j];
            }
            found = same;
          }
          expect(found, false);
        }
      });
    }

    test('a changed page is detected (keyed in an encrypted run)', () {
      for (final keys in [null, ZxKeys(lcgBytes(32, 1), lcgBytes(32, 2))]) {
        const n = 300;
        final (sha, locs) = records(n, 4);
        final m = ZxMemChunks.sort(sha, locs, n);
        final (run, bytes) = write(m, keys);
        final first = m.order[0];
        expect(run.find(sha, 32 * first), isNotNull);
        final hdr = ZxBlockHeader.tryParse(bytes, 100, bytes.length)!;
        final bad = Uint8List.fromList(bytes);
        final p0 = 100 + hdr.headerSize + (keys != null ? 16 : 0) + 16;
        bad[p0 + 33] ^= 4; // the block of the first record
        final vols = ZxVolumes.single(MemoryInStream(bad), Uint8List(16));
        final r2 = ZxChunkRun.open(vols, run.ref, keys);
        expect(r2.find(sha, 32 * first), isNull);
        expect(r2.damagedPages, 1);
        // the other pages are fine
        final last = m.order[n - 1];
        expect(r2.find(sha, 32 * last), isNotNull);
      }
    });

    test('merging: tiers, duplicates, the map, pieces', () {
      expect(zxRunsToMerge([], 10, 100), 0);
      expect(zxRunsToMerge([10], 10, 100), 1);
      expect(zxRunsToMerge([50, 10], 10, 100), 2);
      expect(zxRunsToMerge([100, 10], 10, 100), 1); // a full run stays
      expect(zxRunsToMerge([90], 10, 100), 0); // 90 > 4 * 10
      expect(zxRunsToMerge([10], 0, 100), 0);
      // pieces of at most 64 records, the second source loses ties, the
      // map drops the records of block 3
      final (s1, l1) = records(150, 5);
      final (s2, l2) = records(40, 6);
      // record 11 of s1 (block 4) again in s2 at block 5: the first
      // source wins; record 10 of s1 (block 3, dropped by the map) again in
      // s2 at block 6: the record the map keeps is taken
      s2.setRange(0, 32, s1, 32 * 11);
      l2[0] = 5;
      l2[1] = 999999;
      s2.setRange(32, 64, s1, 32 * 10);
      l2[3] = 6;
      l2[4] = 888888;
      final m1 = ZxMemChunks.sort(s1, l1, 150),
          m2 = ZxMemChunks.sort(s2, l2, 40);
      final got = <(int, int)>{};
      final counts = zxMergeRuns(() => [m1.cursor(), m2.cursor()],
          (count) => ZxRunWriter((b) {}, count, null), map: (b, off, len) {
        if (b == 3) return null;
        got.add((b, off));
        return (b, off);
      }, maxRecords: 64);
      var total = 1; // record 10, from s2
      for (var i = 0; i < 150; i++) {
        if (l1[3 * i] != 3) total++;
      }
      for (var i = 2; i < 40; i++) {
        if (l2[3 * i] != 3) total++;
      }
      expect(counts.fold<int>(0, (a, b) => a + b), total);
      expect(counts.length, (total + 63) ~/ 64);
      expect(counts.every((c) => c <= 64), true);
      expect(got.contains((5, 999999)), false);
      expect(got.contains((l1[33], l1[34])), true);
      expect(got.contains((6, 888888)), true);
    });
  });

  group('compaction', () {
    test('keeps only the chunks still used and repacks their blocks', () {
      final (g1, _) = _create({
        'a': a,
        'b': b,
        'c': _cat([x, m])
      }, dd());
      final (g2, _) = _append(g1, dd(), delete: {'b'});
      final r = _reader(g2);
      expect(r.wastedBytes(), greaterThan(b.length * 9 ~/ 10));
      final before = _chunksOf(r, r.lastIndex).length;
      final c = _compact(g2, 1);
      expect(c.length, lessThan(g2.length - b.length * 9 ~/ 10));
      _expectFiles(c, {
        'a': a,
        'c': _cat([x, m])
      });
      final rc = _reader(c);
      expect(rc.wastedBytes(), 0);
      final t = _chunksOf(rc, rc.lastIndex);
      expect(t.length, lessThan(before));
      _expectChunksUsed(rc, rc.lastIndex);
      // dedup goes on against the compacted file, and b is new again
      final (g3, r3) = _append(c, dd(), add: {'a2': a, 'b': b});
      expect(r3.dedupBytes, a.length);
      expect(r3.packedBytes, greaterThan(b.length));
      _expectFiles(g3, {
        'a': a,
        'c': _cat([x, m]),
        'a2': a,
        'b': b
      });
    });

    test('keeps the chunks of the kept generations', () {
      final (g1, _) = _create({'a': a, 'b': b}, dd());
      final (g2, _) = _append(g1, dd(), delete: {'b'}, add: {'m': m});
      final (g3, _) = _append(g2, dd(), delete: {'a'});
      final c = _compact(g3, 2);
      _expectFiles(c, {'a': a, 'm': m}, version: '2');
      _expectFiles(c, {'m': m});
      final rc = _reader(c);
      // the runs of the last generation keep the chunks both kept
      // generations use; the earlier generation has none
      _expectChunksUsed(rc, rc.lastIndex,
          users: [rc.indexOf(rc.generations.first)]);
      expect(rc.indexOf(rc.generations.first).chunkRuns, isNull);
      final firstUses = <int>{
        for (final e in rc.indexOf(rc.generations.first).entries)
          if (e.path == 'a') e.extents[0]
      };
      final t = _chunksOf(rc, rc.lastIndex);
      expect(
          [for (var i = 0; i < t.length; i++) t.locs[3 * i]]
              .any(firstUses.contains),
          true);
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
      expect(
          cr.lastIndex.blocks.fold<int>(0, (s, x) => s + x.unpackedSize),
          lessThan(whole.lastIndex.blocks
              .fold<int>(0, (s, x) => s + x.unpackedSize)));
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
            for (final ch in _reader(z).lastIndex.chains.values) zxChainName(ch)
          };
      expect(names(c), names(g1));
      expect(names(c).single, startsWith('PPMd:o4:'));
    });

    test('zpaq blocks are repacked with their method', () {
      final o = dd()
        ..coders = const [
          ZxCoderSpec(ZxCodecId.zpaq, ZxCoderConfig(level: 5, params: 'm=1'))
        ];
      final t1 = textBytes(120000, 5), t2 = textBytes(120000, 6);
      final (g1, _) =
          _create({'t1': t1, 't2': t2}, dd(dedup: false)..coders = o.coders);
      final (g2, _) =
          _append(g1, dd(dedup: false)..coders = o.coders, delete: {'t2'});
      Set<String> names(Uint8List z) => {
            for (final ch in _reader(z).lastIndex.chains.values) zxChainName(ch)
          };
      expect(names(g1), {'zpaq:1'});
      // level 9 alone would map zpaq to method 5
      final c = _compact(g2, 1, o: dd(dedup: false)..level = 9);
      _expectFiles(c, {'t1': t1});
      expect(names(c), {'zpaq:1'});
      expect(_reader(c).wastedBytes(), 0);
      expect(c.length, lessThan(g2.length));
      // blocks of zx 0.5.0 (no method in the props) are copied whole
      zxZpaqMethodInProps = false;
      try {
        final (h1, _) =
            _create({'t1': t1, 't2': t2}, dd(dedup: false)..coders = o.coders);
        final (h2, _) =
            _append(h1, dd(dedup: false)..coders = o.coders, delete: {'t2'});
        expect(names(h1), {'zpaq'});
        final r2 = _reader(h2);
        final c2 = _compact(h2, 1, o: dd(dedup: false)..level = 9);
        _expectFiles(c2, {'t1': t1});
        final rc2 = _reader(c2);
        expect(names(c2), {'zpaq'});
        expect(rc2.lastIndex.blocks.length,
            r2.lastIndex.entries.expand((e) => [e.extents[0]]).toSet().length);
        expect(rc2.wastedBytes(), greaterThan(0));
        // -m0 given: repacked with it
        final c3 = _compact(h2, 1,
            o: dd(dedup: false)
              ..coders = o.coders
              ..codersSet = true);
        expect(_reader(c3).wastedBytes(), 0);
      } finally {
        zxZpaqMethodInProps = true;
      }
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
        ZxCoder(
            ZxCodecId.ppmd7, Uint8List.fromList([6, 0, 0, 0, 12])) // 192 MiB
      ]);
      expect(zxDecodeMemory(ch, 1 << 20), greaterThan(192 << 20));
      expect(zxDefaultMemoryLimit(), greaterThanOrEqualTo(64 << 20));
    });

    test('extraction under a tiny limit decodes one block at a time', () {
      final files = {
        'a': a,
        'b': b,
        'f': _cat([x, m, y])
      };
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

/// The spill folders of the dedup writer in the temporary folder.
Set<String> _spillDirs() => {
      for (final e in Directory.systemTemp.listSync())
        if (e.path.split(Platform.pathSeparator).last.startsWith('zx-dedup-'))
          e.path
    };

/// An input that remembers its largest read.
class _CountingIn implements InStream {
  final MemoryInStream _s;
  int largestRead = 0;
  _CountingIn(Uint8List d) : _s = MemoryInStream(d);
  @override
  int read(Uint8List buf, int off, int len) {
    if (len > largestRead) largestRead = len;
    return _s.read(buf, off, len);
  }
}

/// [a] as zx 0.5.0 wrote it: its last Index with a chunk table (record
/// 0x34) instead of chunk runs, rewritten in place of the last one.
Uint8List _toLegacy(Uint8List a) {
  final r = _reader(a);
  final idx = r.lastIndex;
  final table = zxAllChunks(r.volumes, idx, null);
  idx
    ..chunkRuns = null
    ..chunkTable = table;
  final content = idx.encode(multiVolume: false);
  final enc = zxEncodeBlock(ZxEncodeArg(
      content,
      const [ZxCoderSpec(ZxCodecId.lzma2, ZxCoderConfig(level: 5))],
      ZxCheck.crc32c));
  final hdr = ZxBlockHeader.encode(
      ZxBlockType.index,
      enc.coders.isEmpty ? 0 : 1,
      enc.unpackedSize,
      enc.payload.length,
      enc.checkType,
      enc.check);
  final start = r.lastIndexLoc.offset;
  final out = BytesBuilder()
    ..add(a.sublist(0, start))
    ..add(hdr)
    ..add(enc.payload);
  final size = out.length - start;
  out.add(ZxFooter(start, size, idx.blocks.length).encode());
  return out.toBytes();
}
