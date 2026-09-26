// Encode/decode speed of the LZMA and LZMA2 ports.
//
//   dart compile exe tool/lzma_bench.dart -o /tmp/lzma_bench
//   /tmp/lzma_bench <file> [method props ...]
//
// Each method props argument is a 7-Zip style string, e.g. "x1" or
// "x5:d=16m"; prefix it with "2:" for LZMA2. Default: x1, x5.

import 'dart:io';
import 'dart:typed_data';

import 'package:zx/src/codec/codec.dart';
import 'package:zx/src/codec/lzma/lzma_coder.dart';
import 'package:zx/src/io/streams.dart';

double _mbs(int bytes, Duration d) =>
    bytes / (1 << 20) / (d.inMicroseconds / 1e6);

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: lzma_bench <file> [props ...]');
    exit(2);
  }
  final data = File(args[0]).readAsBytesSync();
  final methods = args.length > 1 ? args.sublist(1) : ['x1', 'x5'];
  for (final m in methods) {
    final lzma2 = m.startsWith('2:');
    final ms = lzma2 ? m.substring(2) : m;
    final Compressor c =
        lzma2 ? Lzma2Compressor.fromString(ms) : LzmaCompressor.fromString(ms);
    final out = MemoryOutStream(data.length + 1024);
    final sw = Stopwatch()..start();
    c.encode(MemoryInStream(data), out);
    final encTime = sw.elapsed;
    final packed = Uint8List.fromList(out.toBytes());

    // Decode a few times, keep the best.
    var best = const Duration(days: 1);
    for (var i = 0; i < 3; i++) {
      sw
        ..reset()
        ..start();
      final dec = lzma2
          ? lzma2Decoder(c.props, [MemoryInStream(packed)], data.length,
              const CoderContext())
          : lzmaDecoder(c.props, [MemoryInStream(packed)], data.length,
              const CoderContext());
      final sink = NullOutStream();
      copyStream(dec, sink, bufSize: 1 << 16);
      final t = sw.elapsed;
      if (sink.count != data.length) throw StateError('size mismatch');
      if (t < best) best = t;
    }
    final check = lzma2
        ? readAll(lzma2Decoder(c.props, [MemoryInStream(packed)], data.length,
            const CoderContext()))
        : readAll(lzmaDecoder(c.props, [MemoryInStream(packed)], data.length,
            const CoderContext()));
    for (var i = 0; i < data.length; i++) {
      if (check[i] != data[i]) throw StateError('round trip mismatch at $i');
    }
    print('${lzma2 ? 'LZMA2' : 'LZMA '} $ms: ${data.length} -> ${packed.length}'
        '  encode ${_mbs(data.length, encTime).toStringAsFixed(2)} MB/s'
        '  decode ${_mbs(data.length, best).toStringAsFixed(1)} MB/s');
  }
}
