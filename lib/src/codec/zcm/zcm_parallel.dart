// zcm: segment parallel coding in worker isolates.
//
// With ZcmOptions.segmentSize > 0 a zcm stream is a series of independent
// segments, each coded with a fresh model. This file codes them in a
// WorkerPool: the output is byte for byte what ZcmCompressor writes with
// the same options (the split does not depend on the number of threads),
// and every stream with independent segments decodes in parallel too.
//
// Ratio cost: each segment starts with empty statistics and without the
// history of the others. On the benchmark corpus a split into 4 segments
// costs about 2 to 4% (docs/performance.md); segments of several MiB lose
// much less.
//
// Memory: every worker holds one model of the stream's memory budget, so
// the peak is about threads * budget (zcm_auto.dart chooses both).

import 'dart:isolate';
import 'dart:typed_data';

import '../../io/streams.dart';
import '../../pool.dart';
import 'zcm.dart';

/// Default segment size for [threads] workers and [length] bytes: the
/// input split evenly, in 64 KiB units, at least 1 MiB.
int zcmDefaultSegmentSize(int length, int threads) {
  var seg = (length + threads - 1) ~/ (threads < 1 ? 1 : threads);
  seg = (seg + zcmBlockSize - 1) ~/ zcmBlockSize * zcmBlockSize;
  if (seg < (1 << 20)) seg = 1 << 20;
  return seg;
}

/// Compresses [data] with independent segments coded on [threads]
/// worker isolates. When [options] has no segment size, one is chosen with
/// [zcmDefaultSegmentSize] (and stored in the stream).
Future<Uint8List> zcmCompressParallel(Uint8List data, ZcmOptions options,
    {int threads = 2, void Function(Isolate isolate)? onSpawn}) async {
  final o = options.segmentSize > 0
      ? options
      : options.copyWith(
          segmentSize: zcmDefaultSegmentSize(data.length, threads));
  final h = ZcmHeader.fromOptions(o, data.length);
  final props = h.props;
  final seg = h.segmentSize;
  final n = (data.length + seg - 1) ~/ seg;
  final out = MemoryOutStream(data.length ~/ 3 + 64);
  final head = zcmHeaderBytes(h);
  out.write(head, 0, head.length);
  if (n <= 1 || threads <= 1) {
    for (var i = 0; i < n; i++) {
      final off = i * seg;
      final len = data.length - off < seg ? data.length - off : seg;
      final r = zcmEncodeSegmentRecord(h, data, off, len);
      out.write(r, 0, r.length);
    }
  } else {
    final pool = await WorkerPool.spawn(threads < n ? threads : n,
        onSpawn: onSpawn);
    try {
      // At most one segment per worker plus one in flight.
      final pending = <Future<TransferableTypedData>>[];
      var next = 0;
      Future<TransferableTypedData> submit(int i) {
        final off = i * seg;
        final len = data.length - off < seg ? data.length - off : seg;
        final input = TransferableTypedData.fromList(
            [Uint8List.sublistView(data, off, off + len)]);
        final orig = data.length;
        return pool.run(_encodeTask(props, orig, input, len));
      }

      while (next < n && pending.length < pool.size + 1) {
        pending.add(submit(next++));
      }
      for (var i = 0; i < n; i++) {
        final r = (await pending[i]).materialize().asUint8List();
        out.write(r, 0, r.length);
        if (next < n) pending.add(submit(next++));
      }
    } finally {
      pool.close();
    }
  }
  final end = zcmEndBytes();
  out.write(end, 0, end.length);
  return Uint8List.fromList(out.toBytes());
}

// The closures sent to the workers are made here, so that they capture
// only their (sendable) arguments.
TransferableTypedData Function() _encodeTask(Uint8List props, int orig,
        TransferableTypedData input, int len) =>
    () => _encodeWorker(props, orig, input, len);

TransferableTypedData Function() _decodeTask(Uint8List props,
        TransferableTypedData input, int rawLen, int crc, int packedLen) =>
    () => _decodeWorker(props, input, rawLen, crc, packedLen);

TransferableTypedData _encodeWorker(
    Uint8List props, int orig, TransferableTypedData input, int len) {
  final h = zcmParseProps(props).withOriginalSize(orig);
  final data = input.materialize().asUint8List();
  return TransferableTypedData.fromList(
      [zcmEncodeSegmentRecord(h, data, 0, len)]);
}

/// Decompresses a zcm stream in memory; the segments of a stream with
/// independent segments are decoded on [threads] worker isolates.
Future<Uint8List> zcmDecompressParallel(Uint8List packed,
    {int threads = 2, void Function(Isolate isolate)? onSpawn}) async {
  final (h, chunks) = zcmParseStream(packed);
  if (!h.independent || chunks.length <= 1 || threads <= 1) {
    return zcmDecompressBytes(packed);
  }
  var total = 0;
  for (final c in chunks) {
    total += c.rawLen;
  }
  final out = Uint8List(total);
  final props = h.props;
  final pool = await WorkerPool.spawn(
      threads < chunks.length ? threads : chunks.length,
      onSpawn: onSpawn);
  try {
    final futures = <Future<TransferableTypedData>>[];
    for (final c in chunks) {
      final input = TransferableTypedData.fromList([
        Uint8List.sublistView(packed, c.packedOff, c.packedOff + c.packedLen)
      ]);
      final rawLen = c.rawLen, crc = c.crc, plen = c.packedLen;
      futures.add(pool.run(_decodeTask(props, input, rawLen, crc, plen)));
    }
    var off = 0;
    for (var i = 0; i < chunks.length; i++) {
      final r = (await futures[i]).materialize().asUint8List();
      out.setRange(off, off + r.length, r);
      off += r.length;
    }
  } finally {
    pool.close();
  }
  return out;
}

TransferableTypedData _decodeWorker(Uint8List props,
    TransferableTypedData input, int rawLen, int crc, int packedLen) {
  final h = zcmParseProps(props);
  final p = input.materialize().asUint8List();
  final out = Uint8List(rawLen);
  zcmDecodeSegment(h, p, ZcmChunkRef(rawLen, crc, 0, packedLen), out, 0);
  return TransferableTypedData.fromList([out]);
}
