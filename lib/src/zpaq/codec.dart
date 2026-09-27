// Vendored from zpaq-flutter by tool/sync_zpaq.sh: do not edit here, change
// zpaq-flutter and sync again. Pure Dart port of libzpaq and zpaq 7.15 (Matt
// Mahoney, public domain) with the zpaqfranz attribute format (Franco
// Corbelli, MIT). Copyright (c) 2026 Max Brito, BSD 3-clause; see LICENSE
// for the license and the third party notices.

import 'dart:typed_data';

import 'core/decompresser.dart';
import 'core/io.dart';
import 'core/method.dart';

/// Compresses [data] into a standalone ZPAQ stream (no archive index),
/// splitting it into independent blocks of at most [blockSize] bytes.
///
/// [method] is a zpaq level "0".."5" or an explicit method string. This
/// runs on the calling isolate: use `Isolate.run` for large inputs.
Uint8List zpaqCompress(Uint8List data,
    {String method = '1', int blockSize = (1 << 24) - 4096}) {
  final out = ZBuffer(data.length ~/ 2 + 256);
  var off = 0;
  do {
    var n = data.length - off;
    if (n > blockSize) n = blockSize;
    final block = ZBuffer.of(
        Uint8List.fromList(Uint8List.sublistView(data, off, off + n)));
    compressBlock(block, out, method);
    off += n;
  } while (off < data.length);
  return Uint8List.fromList(Uint8List.sublistView(out.data, 0, out.size));
}

/// Decompresses a ZPAQ stream (every block and segment, concatenated).
///
/// Accepts the output of [zpaqCompress] and of zpaq/libzpaq streaming
/// compression. Runs on the calling isolate.
Uint8List zpaqDecompress(Uint8List stream) {
  final out = ZBuffer(stream.length * 3 + 256);
  decompressAll(MemoryReader(stream), out);
  return Uint8List.fromList(Uint8List.sublistView(out.data, 0, out.size));
}
