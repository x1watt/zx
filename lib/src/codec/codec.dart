// Coder interfaces and the method registry (7-Zip's ICompressCoder,
// ICompressFilter, CreateCoder.cpp and the *Register.cpp files).
//
// Decoders are pull streams: a decoder wraps its packed input stream(s) and
// is itself an InStream producing unpacked bytes, so any 7z coder graph is
// decoded by wrapping streams recursively.
//
// Encoders come in three shapes, because 7-Zip's LZMA encoder pulls its
// input while AES pushes its output:
//   * [FilterCoder]: a byte transform (BCJ, ARM, Delta, SWAP...). Encoding is
//     a pull wrapper too, so a filter can feed a compressor.
//   * [Compressor]: consumes an InStream to the end, writes to an OutStream
//     (LZMA, LZMA2, PPMd, Copy).
//   * [PushEncoder]: wraps an OutStream (AES), used after a compressor.
// BCJ2 (one input, four outputs) has its own entry point.

import 'dart:typed_data';

import '../io/streams.dart';

/// 7z method ids (7zHeader.h).
abstract final class MethodId {
  static const copy = 0x00;
  static const delta = 0x03;
  static const arm64 = 0x0A;
  static const riscv = 0x0B;
  static const lzma2 = 0x21;
  static const swap2 = 0x020302;
  static const swap4 = 0x020304;
  static const lzma = 0x030101;
  static const ppmd = 0x030401;
  static const bcj = 0x03030103;
  static const bcj2 = 0x0303011B;
  static const ppc = 0x03030205;
  static const ia64 = 0x03030401;
  static const arm = 0x03030501;
  static const armt = 0x03030701;
  static const sparc = 0x03030805;
  static const aes = 0x06F10701;
  // Known to 7-Zip but not part of the LZMA SDK (not supported here).
  static const deflate = 0x040108;
  static const deflate64 = 0x040109;
  static const bzip2 = 0x040202;
}

/// Receives progress from long running coders. [inSize] and [outSize] are
/// totals so far for the current operation. Throw from here to cancel
/// (the port rethrows it unchanged).
typedef ProgressCallback = void Function(int inSize, int outSize);

/// Supplies the password for AES. Returns null when none is available,
/// which makes decoding fail with [SevenZipError.wrongPassword].
typedef PasswordProvider = String? Function();

/// Shared options passed to coder factories.
class CoderContext {
  final PasswordProvider? password;
  final ProgressCallback? progress;

  /// Number of worker threads the caller allows (-mmt). Coders that are
  /// single threaded ignore it.
  final int threads;
  const CoderContext({this.password, this.progress, this.threads = 1});
}

/// A byte transform whose encode and decode directions are both pull
/// wrappers. [props] are the 7z coder properties.
abstract class FilterCoder {
  InStream encoder(InStream input);
  InStream decoder(InStream input);

  /// Properties to store in the 7z header for this filter (may be empty).
  Uint8List get props;
}

/// A compressor. [encode] reads [input] to its end and writes the packed
/// stream to [output]. Returns the number of bytes read.
abstract class Compressor {
  /// Coder properties (for LZMA: the 5 byte lc/lp/pb + dictionary header).
  Uint8List get props;

  int encode(InStream input, OutStream output, {ProgressCallback? progress});
}

/// An encoder that wraps an output stream (AES). [close] must be called to
/// write the final block; it does not close [output].
abstract class PushEncoder implements OutStream {
  Uint8List get props;
  void close();
}

/// Builds a pull decoder for one 7z coder. [inputs] has one stream per
/// packed input of the coder (4 for BCJ2). [outSize] is the unpacked size
/// the header declares, or null when unknown.
typedef DecoderFactory = InStream Function(Uint8List props,
    List<InStream> inputs, int? outSize, CoderContext ctx);

/// Registry of decoders by method id. Codec files register themselves from
/// lib/src/codec/registry.dart.
final Map<int, DecoderFactory> decoderRegistry = {};

/// Method names as 7-Zip prints them (list -slt "Method" column, -m switch).
const Map<int, String> methodNames = {
  MethodId.copy: 'Copy',
  MethodId.delta: 'Delta',
  MethodId.arm64: 'ARM64',
  MethodId.riscv: 'RISCV',
  MethodId.lzma2: 'LZMA2',
  MethodId.swap2: 'SWAP2',
  MethodId.swap4: 'SWAP4',
  MethodId.lzma: 'LZMA',
  MethodId.ppmd: 'PPMD',
  MethodId.bcj: 'BCJ',
  MethodId.bcj2: 'BCJ2',
  MethodId.ppc: 'PPC',
  MethodId.ia64: 'IA64',
  MethodId.arm: 'ARM',
  MethodId.armt: 'ARMT',
  MethodId.sparc: 'SPARC',
  MethodId.aes: '7zAES',
  MethodId.deflate: 'Deflate',
  MethodId.deflate64: 'Deflate64',
  MethodId.bzip2: 'BZip2',
};
