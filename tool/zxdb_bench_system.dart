// Benchmarks of the zxdb system layer (docs/zxdb-design.md 7):
//   - sha256 lookup in zx_files (target < 50 us), over an archive of many
//     small files, through the virtual table (plan, open, cursor);
//   - TLSH similar-20 over 1M synthetic digests (target < 50 ms) with the
//     in-memory band index (probe levels 0 and 1), the exact scan, and the
//     persisted band index over a smaller set (memory store), with recall
//     against the exact answer.
//
// dart run tool/zxdb_bench_system.dart [digests=1000000] [files=100000]
// (AOT: dart compile exe tool/zxdb_bench_system.dart -o /tmp/b && /tmp/b)

import 'dart:math';
import 'dart:typed_data';

import 'package:zx/src/crypto/sha256.dart';
import 'package:zx/src/db/memory_store.dart';
import 'package:zx/src/db/system/archive_view.dart';
import 'package:zx/src/db/system/sys_vtab.dart';
import 'package:zx/src/db/system/system_tables.dart';
import 'package:zx/src/db/system/tlsh_index.dart';
import 'package:zx/src/format/zx/zx_format.dart';
import 'package:zx/src/format/zx/zx_writer.dart';
import 'package:zx/src/io/streams.dart';

double _us(Stopwatch sw, int n) => sw.elapsedMicroseconds / n;

void benchSha(int files) {
  print('--- sha256 lookup, $files files');
  final sw = Stopwatch()..start();
  final out = MemoryOutStream();
  final o = ZxWriteOptions()
    ..threads = 1
    ..archiveId = Uint8List(16)
    ..time = 1790000000000000000;
  final w = ZxWriter.create(o, (h) => ZxStreamSink(out));
  final shas = <Uint8List>[];
  for (var i = 0; i < files; i++) {
    final d = Uint8List(24);
    ByteData.sublistView(d).setInt64(0, i * 2654435761);
    ByteData.sublistView(d).setInt64(8, i);
    shas.add(Sha256.hash(d));
    w.addNew(ZxEntry('dir${i % 100}/f$i', ZxKind.file), MemoryInStream(d),
        knownSize: d.length);
  }
  w.finish();
  final bytes = Uint8List.fromList(out.toBytes());
  print('archive written: ${bytes.length} bytes in ${sw.elapsedMilliseconds} ms');
  sw.reset();
  final av = ZxArchiveView.memory(bytes)!;
  final t = ZxFilesTable(av);
  sysQuery(t, [('sha256', SysOp.eq, shas[0])]);
  print('open + Index decode + first lookup: ${sw.elapsedMilliseconds} ms');
  final r = Random(1);
  const n = 20000;
  final keys = [for (var i = 0; i < n; i++) shas[r.nextInt(files)]];
  var hits = 0;
  sw
    ..reset()
    ..start();
  for (final k in keys) {
    hits += sysQuery(t, [('sha256', SysOp.eq, k)]).length;
  }
  sw.stop();
  print('zx_files WHERE sha256 = ?: ${_us(sw, n).toStringAsFixed(2)} us '
      '(hits $hits/$n)');
  final v = av.current;
  sw
    ..reset()
    ..start();
  for (final k in keys) {
    hits += v.findBySha256(k).length;
  }
  sw.stop();
  print('binary search alone: ${_us(sw, n).toStringAsFixed(2)} us');
  sw
    ..reset()
    ..start();
  for (var i = 0; i < n; i++) {
    hits += sysQuery(t, [('path', SysOp.eq, 'dir${i % 100}/f$i')]).length;
  }
  sw.stop();
  print('zx_files WHERE path = ?: ${_us(sw, n).toStringAsFixed(2)} us');
  av.close();
}

/// A random digest with plausible header bytes.
Uint8List randomDigest(Random r) {
  final b = Uint8List(tlshBinSize);
  b[0] = r.nextInt(256);
  b[1] = 100 + r.nextInt(60);
  b[2] = r.nextInt(256);
  for (var i = 3; i < tlshBinSize; i++) {
    b[i] = r.nextInt(256);
  }
  return b;
}

/// A near copy of [d]: [k] buckets moved by one step (or two).
Uint8List nearCopy(Uint8List d, int k, Random r) {
  final c = Uint8List.fromList(d);
  for (var i = 0; i < k; i++) {
    final byte = 3 + r.nextInt(32), shift = 2 * r.nextInt(4);
    final v = (c[byte] >> shift) & 3;
    final nv = r.nextBool() ? (v + 1).clamp(0, 3) : (v - 1).clamp(0, 3);
    final step = r.nextInt(8) == 0 ? (v < 2 ? 3 : 0) : nv;
    c[byte] = (c[byte] & ~(3 << shift)) | (step << shift);
  }
  if (r.nextInt(4) == 0) c[1] = (c[1] + 1) & 255;
  return c;
}

void benchTlsh(int count) {
  print('--- TLSH similar-20, $count synthetic digests');
  final r = Random(42);
  // families: 1000 bases with 20 near copies each at 4..40 changed
  // buckets, the rest random
  const families = 1000, perFamily = 20;
  final all = Uint8List(count * tlshBinSize);
  final queries = <Uint8List>[];
  var i = 0;
  for (var f = 0; f < families && i < count; f++) {
    final base = randomDigest(r);
    queries.add(nearCopy(base, 6, r));
    for (var k = 0; k < perFamily && i < count; k++, i++) {
      all.setRange(i * tlshBinSize, (i + 1) * tlshBinSize,
          nearCopy(base, 4 + r.nextInt(37), r));
    }
  }
  for (; i < count; i++) {
    all.setRange(i * tlshBinSize, (i + 1) * tlshBinSize, randomDigest(r));
  }
  final sw = Stopwatch()..start();
  final idx = TlshBandIndex.build(all);
  print('band index build: ${sw.elapsedMilliseconds} ms, '
      '${(idx.memoryBytes / (1 << 20)).toStringAsFixed(1)} MiB');
  const nq = 100;
  final qs = queries.take(nq).toList();
  // warm up
  for (final q in qs.take(5)) {
    idx.query(q, 20);
    idx.exact(q, 20);
  }
  final exact = <List<(int, int)>>[];
  sw
    ..reset()
    ..start();
  for (final q in qs) {
    exact.add(idx.exact(q, 20));
  }
  sw.stop();
  print('exact scan: ${(sw.elapsedMicroseconds / nq / 1000).toStringAsFixed(2)} ms/query');
  for (final level in [0, 1]) {
    var found = 0, wanted = 0;
    sw
      ..reset()
      ..start();
    final res = [for (final q in qs) idx.query(q, 20, probeLevel: level)];
    sw.stop();
    for (var k = 0; k < qs.length; k++) {
      // recall by distance: hits at or under the exact 20th distance
      final truth = exact[k];
      final limit = truth.last.$2;
      wanted += truth.length;
      found += res[k].where((h) => h.$2 <= limit).length.clamp(0, truth.length);
    }
    print('band probe $level: '
        '${(sw.elapsedMicroseconds / nq / 1000).toStringAsFixed(3)} ms/query, '
        'recall ${(100 * found / wanted).toStringAsFixed(1)}%');
  }
}

void benchPersisted(int count) {
  print('--- persisted band index (memory store), $count digests');
  final r = Random(7);
  final store = ZxMemoryStore();
  final txn = store.begin();
  final bands = txn.createTree(ZxTlshStore.bandsTree);
  final digests = txn.createTree(ZxTlshStore.digestsTree);
  final state = txn.createTree(ZxTlshStore.stateTree);
  final qs = <Uint8List>[];
  final sw = Stopwatch()..start();
  for (var i = 0; i < count; i++) {
    final d = (i % 50 == 0) ? randomDigest(r) : nearCopy(randomDigest(r), 3, r);
    if (i % (count ~/ 100) == 0) qs.add(nearCopy(d, 5, r));
    final sha = Uint8List(32);
    ByteData.sublistView(sha).setInt64(0, i);
    ZxTlshStore.addDigest(bands, digests, sha, d);
  }
  state.put(Uint8List.fromList('generation'.codeUnits), Uint8List(8));
  txn.commit();
  print('insert + commit: ${sw.elapsedMilliseconds} ms');
  final s = store.snapshot();
  for (final q in qs.take(3)) {
    ZxTlshStore.query(s, q, limit: 20);
  }
  sw
    ..reset()
    ..start();
  var n = 0;
  for (final q in qs) {
    n += ZxTlshStore.query(s, q, limit: 20).length;
  }
  sw.stop();
  print('query (probe 1, top 20): '
      '${(sw.elapsedMicroseconds / qs.length / 1000).toStringAsFixed(3)} ms/query '
      '($n hits)');
}

void main(List<String> args) {
  final digests = args.isNotEmpty ? int.parse(args[0]) : 1000000;
  final files = args.length > 1 ? int.parse(args[1]) : 100000;
  final persisted = args.length > 2 ? int.parse(args[2]) : 100000;
  benchSha(files);
  benchTlsh(digests);
  benchPersisted(persisted);
}
