// PPMd encode/decode driver for byte comparisons with the C reference and
// speed measurements.
//
//   dart run tool/ppmd_bench.dart e <order> <mem> <in> <out>
//   dart run tool/ppmd_bench.dart d <order> <mem> <in> <out> <outSize>

import 'dart:io';
import 'dart:typed_data';

import 'package:zx/src/codec/codec.dart';
import 'package:zx/src/codec/ppmd/ppmd7.dart';
import 'package:zx/src/codec/ppmd/ppmd7_enc.dart';
import 'package:zx/src/codec/ppmd/ppmd_coder.dart';
import 'package:zx/src/io/streams.dart';

void main(List<String> args) {
  if (args.length < 5) {
    stderr.writeln('usage: e|d order mem in out [outSize]');
    exit(1);
  }
  final order = int.parse(args[1]);
  final mem = int.parse(args[2]);
  final input = File(args[3]).readAsBytesSync();
  final sw = Stopwatch()..start();
  if (args[0] == 'e') {
    final out = MemoryOutStream();
    if (order <= 32 && mem >= (1 << 16) && (mem & 3) == 0) {
      PpmdCompressor(order: order, memSize: mem)
          .encode(MemoryInStream(input), out);
    } else {
      // CEncoder rejects orders above 32; drive the C level API directly.
      final p = Ppmd7()..alloc(mem);
      final bo = PpmdByteOut(out);
      p.rcOut = bo;
      ppmd7zInitRangeEnc(p);
      p.init(order);
      ppmd7zEncodeSymbols(p, input, 0, input.length);
      ppmd7zFlushRangeEnc(p);
      bo.flushBuf();
    }
    sw.stop();
    File(args[4]).writeAsBytesSync(out.toBytes());
    final s = sw.elapsedMicroseconds / 1e6;
    stderr.writeln('enc ${input.length} to ${out.length}  '
        '${s.toStringAsFixed(3)} s  '
        '${(input.length / s / 1e6).toStringAsFixed(1)} MB/s');
  } else {
    final outSize = int.parse(args[5]);
    final props = Uint8List(5);
    props[0] = order;
    setUint32LE(props, 1, mem);
    final dec = ppmdDecoder(
        props, [MemoryInStream(input)], outSize, const CoderContext());
    final out = readAll(dec);
    sw.stop();
    File(args[4]).writeAsBytesSync(out);
    final s = sw.elapsedMicroseconds / 1e6;
    stderr.writeln('dec ${input.length} to ${out.length}  '
        '${s.toStringAsFixed(3)} s  '
        '${(out.length / s / 1e6).toStringAsFixed(1)} MB/s');
  }
}
