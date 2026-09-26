// The decoding side of zip items: the decryption (ZipCrypto, WinZip AES)
// and the decompression by method, over the codecs of the package. The
// method data layouts come from the PKWARE APPNOTE: LZMA (5.8.8: a 2 byte
// version, a 2 byte property size and the LZMA properties before the raw
// stream, general purpose bit 1 when an end marker is present), xz (a
// complete .xz stream), bzip2 (a complete .bz2 stream), PPMd (5.10: PPMd
// var.I rev 1 with a 2 byte parameter header).

import 'dart:typed_data';

import '../../codec/bzip2/bzip2_coder.dart';
import '../../codec/deflate/deflate_coder.dart';
import '../../codec/lzma/lzma_coder.dart';
import '../../codec/ppmd8/ppmd8_coder.dart';
import '../../io/streams.dart';
import '../../util/crc.dart';
import '../xz/xz.dart' show szErrorInputEof;
import '../xz/xz_dec.dart';
import 'zip_header.dart';
import 'zip_implode.dart';
import 'zip_reduce.dart';
import 'zip_shrink.dart';

/// Whether method [m] (under the encryption) can be decoded.
bool zipMethodIsSupported(int m) {
  switch (m) {
    case ZipMethod.store:
    case ZipMethod.shrink:
    case 2:
    case 3:
    case 4:
    case 5:
    case ZipMethod.implode:
    case ZipMethod.deflate:
    case ZipMethod.deflate64:
    case ZipMethod.bzip2:
    case ZipMethod.lzma:
    case ZipMethod.xz:
    case ZipMethod.ppmd:
      return true;
  }
  return false;
}

/// Counts and checksums the unpacked data on its way to [base] (null in
/// test mode).
class ZipCrcOutStream implements OutStream {
  final OutStream? base;
  int _crc = 0xFFFFFFFF;
  int count = 0;
  final void Function(int)? progress;
  int _nextProgress = 1 << 20;

  ZipCrcOutStream(this.base, {this.progress});

  int get crc => _crc ^ 0xFFFFFFFF;

  @override
  void write(Uint8List buf, int off, int len) {
    _crc = crc32Update(_crc, buf, off, off + len);
    base?.write(buf, off, len);
    count += len;
    final p = progress;
    if (p != null && count >= _nextProgress) {
      _nextProgress = count + (1 << 20);
      p(count);
    }
  }

  @override
  void flush() => base?.flush();
}

/// A decoder that read ahead of the end of its data: the bytes it did not
/// use (null when there is no such decoder).
Uint8List? decoderUnusedInput(Object d) {
  if (d is InflateDecoderStream) return d.unusedInput;
  if (d is Deflate64DecoderStream) return d.unusedInput;
  if (d is Bzip2DecoderStream) return d.unusedInput;
  if (d is LzmaDecoderStream) return d.unusedInput;
  return null;
}

/// Reads the LZMA header of zip method 14 from [packed]: the 2 byte
/// version, the 2 byte property size, the properties. Returns the 5 LZMA
/// property bytes.
Uint8List readZipLzmaHeader(InStream packed) {
  final h = Uint8List(4);
  readExactly(packed, h, 0, 4);
  final propsSize = h[2] | (h[3] << 8);
  if (propsSize != 5) {
    throw const SevenZipException(
        'Unsupported LZMA properties', SevenZipError.unsupportedMethod);
  }
  final props = Uint8List(5);
  readExactly(packed, props, 0, 5);
  return props;
}

/// A pull decoder of [method] over [packed] (already decrypted). [outSize]
/// is the unpacked size when known. [lzmaEos] is general purpose bit 1 of
/// LZMA items. Returns null for methods that decode by pushing (xz), see
/// [decodeZipItem].
InStream? zipPullDecoder(int method, InStream packed, int? outSize,
    {bool lzmaEos = false,
    bool implodeBigWindow = false,
    bool implodeLiteralTree = false}) {
  switch (method) {
    case ZipMethod.store:
      return outSize == null ? packed : LimitedInStream(packed, outSize);
    case ZipMethod.deflate:
      return InflateDecoderStream(packed, outSize: outSize);
    case ZipMethod.deflate64:
      return Deflate64DecoderStream(packed, outSize: outSize);
    case ZipMethod.bzip2:
      return Bzip2DecoderStream(packed, outSize: outSize, multiStream: false);
    case ZipMethod.shrink:
      if (outSize == null) return null;
      return ShrinkDecoder(packed, outSize);
    case 2:
    case 3:
    case 4:
    case 5:
      if (outSize == null) return null;
      return ReduceDecoder(packed, outSize, method - 1);
    case ZipMethod.implode:
      if (outSize == null) return null;
      return ImplodeDecoder(packed, outSize,
          bigWindow: implodeBigWindow, literalTree: implodeLiteralTree);
    case ZipMethod.ppmd:
      return Ppmd8ZipDecoder(packed, outSize: outSize);
    case ZipMethod.lzma:
      final props = readZipLzmaHeader(packed);
      return LzmaDecoderStream(props, packed,
          outSize: outSize, finishStream: true);
  }
  return null;
}

/// Decodes [method] from [packed] to [out]. Returns the pull decoder used
/// (for its unused input), or null for push decoders. Throws
/// [SevenZipException] for data errors and unsupported methods.
Object? decodeZipItem(int method, InStream packed, int? outSize,
    ZipCrcOutStream out, Uint8List buf,
    {int flags = 0}) {
  if (method == ZipMethod.xz) {
    final dec = XzDecoder();
    final r = dec.decode(packed, out, outSizeLimit: outSize);
    switch (r) {
      case XzDecodeResult.ok:
        return null;
      case XzDecodeResult.notImplemented:
        throw const SevenZipException(
            'Unsupported xz filter', SevenZipError.unsupportedMethod);
      default:
        // szErrorInputEof: the data ended early
        if (dec.mainDecodeSRes == szErrorInputEof) {
          throw const SevenZipException(
              'Unexpected end of xz data', SevenZipError.unexpectedEnd);
        }
        throw const SevenZipException('xz data error');
    }
  }
  final d = zipPullDecoder(method, packed, outSize,
      lzmaEos: (flags & ZipFlags.bit1) != 0,
      implodeBigWindow: (flags & ZipFlags.bit1) != 0,
      implodeLiteralTree: (flags & ZipFlags.bit2) != 0);
  if (d == null) {
    throw SevenZipException('Unsupported method ${zipMethodName(method)}',
        SevenZipError.unsupportedMethod);
  }
  for (;;) {
    var want = buf.length;
    if (outSize != null) {
      final rem = outSize - out.count;
      if (rem <= 0) break;
      if (rem < want) want = rem;
    }
    final n = d.read(buf, 0, want);
    if (n == 0) break;
    out.write(buf, 0, n);
  }
  return d;
}
