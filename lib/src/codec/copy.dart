// The Copy method: CopyCoder.cpp and CopyRegister.cpp of the LZMA SDK.

import 'dart:typed_data';

import '../io/streams.dart';
import 'codec.dart';

/// NCompress::CCopyCoder as a pull decoder: passes [outSize] bytes of the
/// packed stream through (all of it when the size is unknown).
class CopyDecoder implements InStream {
  final InStream _in;
  int? _rem;
  CopyDecoder(this._in, int? outSize) : _rem = outSize;

  @override
  int read(Uint8List buf, int off, int len) {
    final rem = _rem;
    if (rem != null) {
      if (rem <= 0) return 0;
      if (len > rem) len = rem;
    }
    final n = _in.read(buf, off, len);
    if (rem != null) {
      if (n == 0) {
        throw const SevenZipException(
            'Unexpected end of data', SevenZipError.unexpectedEnd);
      }
      _rem = rem - n;
    }
    return n;
  }
}

/// NCompress::CCopyCoder as a [Compressor] (no properties).
class CopyCompressor implements Compressor {
  /// CCopyCoder::TotalSize of the last [encode].
  int totalSize = 0;

  @override
  Uint8List get props => Uint8List(0);

  @override
  int encode(InStream input, OutStream output, {ProgressCallback? progress}) {
    // kBufSize (CopyCoder.cpp) is 1 << 17.
    final buf = Uint8List(1 << 17);
    totalSize = 0;
    for (;;) {
      final n = input.read(buf, 0, buf.length);
      if (n == 0) break;
      output.write(buf, 0, n);
      totalSize += n;
      if (progress != null) progress(totalSize, totalSize);
    }
    output.flush();
    return totalSize;
  }
}

/// REGISTER_CODEC_E(Copy, ...): registers the Copy decoder.
void registerCopyCodec([Map<int, DecoderFactory>? reg]) {
  (reg ?? decoderRegistry)[MethodId.copy] = (props, inputs, outSize, ctx) {
    // 7zDecode.cpp (v23): a decoder without properties support fails
    // when properties are present.
    if (inputs.length != 1 || props.isNotEmpty) {
      throw const SevenZipException(
          'Unsupported Copy coder', SevenZipError.unsupportedMethod);
    }
    return CopyDecoder(inputs[0], outSize);
  };
}
