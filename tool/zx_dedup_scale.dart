// Measures what the chunk index of the .zx dedup writer costs at the
// scale of a large archive, without writing the data: the chunks of
// 100 GiB of unique data at 64 KiB (1,638,400 chunks, or -chunks=N) are
// simulated (synthetic SHA-256 values and locations).
//
//   dart run tool/zx_dedup_scale.dart old   the in memory index of zx 0.5.0
//                                           (ZxChunkIndex) and its chunk
//                                           table (record 0x34)
//   dart run tool/zx_dedup_scale.dart new   a chunk run (block type 6)
//                                           written to a temporary file,
//                                           opened as a writer opens it,
//                                           then looked up and merged
//
//   dart run tool/zx_dedup_scale.dart prepare old|new DIR
//                                           an archive whose last Index
//                                           knows the chunks (a chunk table
//                                           of zx 0.5.0, or a run)
//   dart run tool/zx_dedup_scale.dart append DIR/x.zx
//                                           appends 64 MiB of new data to
//                                           it and prints the peak resident
//                                           size of the process
//
// Each mode prints the resident size before and after (run them as
// separate processes so that the heaps do not mix).

import 'dart:io';
import 'dart:typed_data';

import 'package:zx/src/format/zx/zx_blocks.dart';
import 'package:zx/src/format/zx/zx_chunkrun.dart';
import 'package:zx/src/format/zx/zx_codecs.dart';
import 'package:zx/src/format/zx/zx_dedup.dart';
import 'package:zx/src/format/zx/zx_format.dart';
import 'package:zx/src/format/zx/zx_reader.dart';
import 'package:zx/src/format/zx/zx_writer.dart';
import 'package:zx/src/io/streams.dart';

int _n = 1638400;

// the hash of chunk i: 8 bytes that grow with i (so the records come
// sorted), then 24 pseudo random bytes
void _hash(int i, Uint8List out, [int o = 0]) {
  // i * 2^64 / n, as two 32 bit halves
  final step = (1 << 62) ~/ _n * 4;
  final v = i * step;
  final hi = (v >> 32) & 0xFFFFFFFF, lo = v & 0xFFFFFFFF;
  out[o] = hi >> 24;
  out[o + 1] = (hi >> 16) & 0xFF;
  out[o + 2] = (hi >> 8) & 0xFF;
  out[o + 3] = hi & 0xFF;
  out[o + 4] = lo >> 24;
  out[o + 5] = (lo >> 16) & 0xFF;
  out[o + 6] = (lo >> 8) & 0xFF;
  out[o + 7] = lo & 0xFF;
  var x = i * 2654435761 + 12345;
  for (var k = 8; k < 32; k++) {
    x = (x * 1103515245 + 12345) & 0x7FFFFFFF;
    out[o + k] = x >> 16;
  }
}

int _mb(int b) => (b / (1 << 20)).round();

String _rss() => '${_mb(ProcessInfo.currentRss)} MB';

void main(List<String> args) {
  for (final a in args) {
    if (a.startsWith('-chunks=')) _n = int.parse(a.substring(8));
  }
  final mode = args.isEmpty ? 'new' : args.first;
  if (mode == 'prepare') return _prepare(args[1] == 'old', args[2]);
  if (mode == 'append') return _append(args[1]);
  print('chunks: $_n (${(_n * 65536 / (1 << 30)).toStringAsFixed(0)} GiB of '
      'unique data at 64 KiB)');
  if (mode == 'old') {
    _old();
  } else {
    _new();
  }
}

void _old() {
  final rss0 = ProcessInfo.currentRss;
  final sw = Stopwatch()..start();
  final ix = ZxChunkIndex();
  final h = Uint8List(32);
  for (var i = 0; i < _n; i++) {
    _hash(i, h);
    ix.add(h, i >> 8, (i & 255) << 16, 65536);
  }
  final rss1 = ProcessInfo.currentRss;
  print('old: in memory index: ${sw.elapsedMilliseconds} ms to fill, '
      'resident +${_mb(rss1 - rss0)} MB '
      '(${((rss1 - rss0) / _n).toStringAsFixed(1)} bytes a chunk), now ${_rss()}');
  // the chunk table every Index held
  final sha = Uint8List(32 * _n);
  final locs = Int64List(3 * _n);
  for (var i = 0; i < _n; i++) {
    _hash(i, sha, 32 * i);
    locs[3 * i] = i >> 8;
    locs[3 * i + 1] = (i & 255) << 16;
    locs[3 * i + 2] = 65536;
  }
  final w = ZxBytes(1 << 20);
  ZxChunkTable(0, locs, sha).write(w, 0);
  print('old: chunk table (record 0x34) in every Index: '
      '${_mb(w.length)} MB (${(w.length / _n).toStringAsFixed(1)} bytes a '
      'chunk, before the LZMA2 of the Index: SHA-256 values do not compress)');
  sw.reset();
  var found = 0;
  for (var i = 0; i < 200000; i++) {
    _hash((i * 7919) % _n, h);
    if (ix.find(h, 65536) >= 0) found++;
  }
  print('old: 200000 lookups (hits $found): ${sw.elapsedMilliseconds} ms');
}

void _new() {
  final tmp = Directory.systemTemp.createTempSync('zx_scale_');
  try {
    final path = '${tmp.path}/runs';
    final f = File(path).openSync(mode: FileMode.write);
    final buf = BytesBuilder(copy: true);
    void write(Uint8List b) {
      buf.add(b);
      if (buf.length >= 1 << 20) f.writeFromSync(buf.takeBytes());
    }

    final sw = Stopwatch()..start();
    // one run of every chunk, as a merge of many generations writes it
    final w = ZxRunWriter(write, _n, null);
    final h = Uint8List(32);
    for (var i = 0; i < _n; i++) {
      _hash(i, h);
      w.add(h, 0, i >> 8, (i & 255) << 16, 65536);
    }
    w.finish();
    f.writeFromSync(buf.takeBytes());
    f.closeSync();
    final size = w.blockSize;
    print('new: run written in ${sw.elapsedMilliseconds} ms: ${_mb(size)} MB '
        '(${(size / _n).toStringAsFixed(1)} bytes a chunk, written once and '
        'again at each merge of its tier)');
    final idx = ZxIndex()
      ..chunkRuns = ZxChunkRuns(0, [ZxChunkRunRef(0, 0, size, _n)]);
    final raw = idx.encode(multiVolume: false);
    final rec = zxRecords(raw).firstWhere((r) => r.type == ZxRec.chunkRuns);
    print('new: chunk runs record (0x36) in every Index: '
        '${rec.payload.length} bytes');

    final rss0 = ProcessInfo.currentRss;
    final s = FileInStream.open(path);
    final vols = ZxVolumes.single(s, Uint8List(16));
    sw.reset();
    final run = ZxChunkRun.open(vols, ZxChunkRunRef(0, 0, size, _n), null);
    final rss1 = ProcessInfo.currentRss;
    print('new: run opened in ${sw.elapsedMilliseconds} ms: '
        '${run.memoryBytes} bytes kept (fences and Bloom filter, '
        '${(run.memoryBytes / _n).toStringAsFixed(2)} bytes a chunk), '
        'resident +${_mb(rss1 - rss0)} MB, now ${_rss()}');

    sw.reset();
    var found = 0;
    for (var i = 0; i < 200000; i++) {
      _hash((i * 7919) % _n, h);
      if (run.find(h, 0) != null) found++;
    }
    final hitMs = sw.elapsedMilliseconds;
    final hitPages = run.pagesRead;
    sw.reset();
    var falsePos = 0;
    for (var i = 0; i < 200000; i++) {
      _hash((i * 7919) % _n, h);
      // same first bytes (the same page), another hash: a new chunk
      for (var k = 8; k < 32; k++) {
        h[k] ^= 0xA5 + k;
      }
      if (run.find(h, 0) != null) falsePos++;
    }
    final missPages = run.pagesRead - hitPages;
    print('new: 200000 lookups of stored chunks (found $found): $hitMs ms, '
        '$hitPages pages read; 200000 of new chunks: '
        '${sw.elapsedMilliseconds} ms, $missPages pages read '
        '(${(100 * missPages / 200000).toStringAsFixed(2)}% let through by '
        'the filter), $falsePos found');
    s.close();

    // a merge of two runs of half the chunks each (the tier merge of a
    // large archive), streamed page by page
    final halves = [for (var k = 0; k < 2; k++) '${tmp.path}/half$k'];
    final refs = <ZxChunkRunRef>[];
    for (var k = 0; k < 2; k++) {
      final g = File(halves[k]).openSync(mode: FileMode.write);
      final b2 = BytesBuilder(copy: true);
      final cnt = (_n + 1 - k) ~/ 2;
      final wr = ZxRunWriter((b) {
        b2.add(b);
        if (b2.length >= 1 << 20) g.writeFromSync(b2.takeBytes());
      }, cnt, null);
      for (var i = k; i < _n; i += 2) {
        _hash(i, h);
        wr.add(h, 0, i >> 8, (i & 255) << 16, 65536);
      }
      wr.finish();
      g.writeFromSync(b2.takeBytes());
      g.closeSync();
      refs.add(ZxChunkRunRef(0, 0, wr.blockSize, cnt));
    }
    final ins = [for (final p in halves) FileInStream.open(p)];
    final runs = [
      for (var k = 0; k < 2; k++)
        ZxChunkRun.open(ZxVolumes.single(ins[k], Uint8List(16)), refs[k], null)
    ];
    final outF = File('${tmp.path}/merged').openSync(mode: FileMode.write);
    final b3 = BytesBuilder(copy: true);
    final rss2 = ProcessInfo.currentRss;
    sw.reset();
    final counts = zxMergeRuns(
        () => [for (final r in runs) r.cursor()],
        (count) => ZxRunWriter((b) {
              b3.add(b);
              if (b3.length >= 1 << 20) outF.writeFromSync(b3.takeBytes());
            }, count, null),
        maxRecords: 1 << 30);
    outF.writeFromSync(b3.takeBytes());
    outF.closeSync();
    print('new: merge of 2 x ${_n ~/ 2} records: ${sw.elapsedMilliseconds} ms '
        '(two passes), ${counts.length} run(s), resident '
        '+${_mb(ProcessInfo.currentRss - rss2)} MB, now ${_rss()}');
    for (final i in ins) {
      i.close();
    }
  } finally {
    tmp.deleteSync(recursive: true);
  }
}

ZxWriteOptions _opts() => ZxWriteOptions()
  ..threads = 1
  ..level = 0
  ..tlsh = false;

// an archive of one 1 MiB file, then a generation whose Index knows every
// chunk: in a chunk table (zx 0.5.0) or in a run written before it
void _prepare(bool old, String dir) {
  final path = '$dir/x.zx';
  final out = FileOutStream.create(path);
  final w = ZxWriter.create(_opts(), (h) => ZxStreamSink(out));
  final data = Uint8List(1 << 20);
  for (var i = 0; i < data.length; i++) {
    data[i] = (i * 2654435761) >> 13;
  }
  w.addNew(ZxEntry('seed', ZxKind.file), MemoryInStream(data),
      knownSize: data.length);
  w.finish();
  out.close();
  final s = FileInStream.open(path);
  final r = ZxArchiveReader.open(s, const ZxOpenParams())!;
  final idx = r.lastIndex;
  final metaChain = r.header.metaChain != null;
  final unpacked = idx.blocks.first.unpackedSize;
  final start = r.lastIndexLoc.offset;
  s.close();
  // the chunks point into block 0 (valid for the block table)
  final raf = File(path).openSync(mode: FileMode.append);
  raf.truncateSync(start);
  raf.setPositionSync(start);
  var pos = start;
  void put(Uint8List b) {
    raf.writeFromSync(b);
    pos += b.length;
  }

  final h = Uint8List(32);
  if (old) {
    final sha = Uint8List(32 * _n);
    final locs = Int64List(3 * _n);
    for (var i = 0; i < _n; i++) {
      _hash(i, sha, 32 * i);
      locs[3 * i + 1] = i % (unpacked - 1);
      locs[3 * i + 2] = 1;
    }
    // sorted by block then offset, as the table requires
    final order = List<int>.generate(_n, (i) => i)
      ..sort((a, b) => locs[3 * a + 1] - locs[3 * b + 1]);
    final s2 = Uint8List(32 * _n), l2 = Int64List(3 * _n);
    for (var i = 0; i < _n; i++) {
      s2.setRange(32 * i, 32 * i + 32, sha, 32 * order[i]);
      l2.setRange(3 * i, 3 * i + 3, locs, 3 * order[i]);
    }
    idx
      ..chunkRuns = null
      ..chunkTable = ZxChunkTable(0, l2, s2);
  } else {
    final buf = BytesBuilder(copy: true);
    final w2 = ZxRunWriter((b) {
      buf.add(b);
      if (buf.length >= 1 << 20) put(buf.takeBytes());
    }, _n, null);
    final at = pos;
    for (var i = 0; i < _n; i++) {
      _hash(i, h);
      w2.add(h, 0, 0, i % (unpacked - 1), 1);
    }
    w2.finish();
    put(buf.takeBytes());
    idx
      ..chunkTable = null
      ..chunkRuns = ZxChunkRuns(0, [ZxChunkRunRef(0, at, w2.blockSize, _n)]);
  }
  // the Index again (metadata blocks of 16 MiB at most), and its Footer
  final content = idx.encode(multiVolume: false);
  final ixStart = pos;
  for (var off = 0; off < content.length; off += 16 << 20) {
    final end =
        off + (16 << 20) < content.length ? off + (16 << 20) : content.length;
    final enc = zxEncodeBlock(ZxEncodeArg(
        Uint8List.fromList(Uint8List.sublistView(content, off, end)),
        metaChain
            ? const [ZxCoderSpec(ZxCodecId.lzma2, ZxCoderConfig(level: 1))]
            : const [],
        ZxCheck.crc32c));
    put(ZxBlockHeader.encode(ZxBlockType.index, enc.coders.isEmpty ? 0 : 1,
        enc.unpackedSize, enc.payload.length, enc.checkType, enc.check));
    put(enc.payload);
  }
  put(ZxFooter(ixStart, pos - ixStart, idx.blocks.length).encode());
  raf.closeSync();
  print('prepared ${old ? 'a chunk table' : 'a run'} of $_n chunks: '
      '${_mb(pos)} MB, Index ${_mb(pos - ixStart)} MB');
}

// 64 MiB of new data appended in place
void _append(String path) {
  final rss0 = ProcessInfo.currentRss;
  final sw = Stopwatch()..start();
  final s = FileInStream.open(path);
  final r = ZxArchiveReader.open(s, const ZxOpenParams())!;
  final f = File(path).openSync(mode: FileMode.append);
  final out = FileOutStream(f)..position = r.validEnd;
  final w = ZxWriter.append(r, _opts(), ZxStreamSink(out, r.validEnd));
  final rssOpen = ProcessInfo.currentRss;
  for (final e in r.lastIndex.entries) {
    w.addKept(e);
  }
  final data = Uint8List(64 << 20);
  var x = 7;
  for (var i = 0; i < data.length; i++) {
    x = (x * 1103515245 + 12345) & 0x7FFFFFFF;
    data[i] = x >> 16;
  }
  w.addNew(ZxEntry('new', ZxKind.file), MemoryInStream(data),
      knownSize: data.length);
  final res = w.finish();
  out.flush();
  out.close();
  s.close();
  print('append: ${sw.elapsedMilliseconds} ms, ${res.storedChunks} chunks '
      'stored; resident at start ${_mb(rss0)} MB, after opening the last '
      'generation ${_mb(rssOpen)} MB, peak ${_mb(ProcessInfo.maxRss)} MB '
      '(64 MiB of it is the input held by this tool)');
  final r2 =
      ZxArchiveReader.open(FileInStream.open(path), const ZxOpenParams())!;
  print('append: the new Index is ${_mb(r2.lastIndexLoc.size)} MB '
      '(${r2.lastIndexLoc.size} bytes)');
}
