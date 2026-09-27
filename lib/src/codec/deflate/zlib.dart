// The zlib wrapper of RFC 1950 around the raw inflate of this package
// (InflateDecoderStream): a two byte header (CMF, FLG), the deflate stream
// and the big endian Adler-32 of the uncompressed data. Preset dictionaries
// (FDICT) are rejected. Used by the filesystem handlers (UBIFS, JFFS2,
// cramfs, squashfs gzip), whose blocks are zlib streams.

import 'dart:typed_data';

import '../../io/streams.dart';
import '../../util/adler32.dart';
import 'deflate_coder.dart';

/// Decompresses the zlib stream [src] (RFC 1950). Throws
/// [SevenZipException] for a bad header, a preset dictionary, invalid or
/// truncated deflate data or an Adler-32 mismatch. Bytes after the
/// trailer are ignored.
Uint8List zlibInflateBytes(Uint8List src) =>
    readAll(ZlibDecoderStream(MemoryInStream(src)));

/// Pull decoder of one zlib stream read from [input].
InStream zlibDecoderStream(InStream input) => ZlibDecoderStream(input);

/// Pull decoder of one zlib stream (header, raw deflate, Adler-32).
class ZlibDecoderStream implements InStream {
  final InStream _input;
  InflateDecoderStream? _inflate;
  int _adler = 1;
  bool _done = false;

  ZlibDecoderStream(this._input);

  /// True once the trailer was read and checked.
  bool get isFinished => _done;

  void _readHeader() {
    final h = Uint8List(2);
    if (readFully(_input, h, 0, 2) != 2) {
      throw const SevenZipException(
          'Unexpected end of zlib data', SevenZipError.unexpectedEnd);
    }
    final cmf = h[0], flg = h[1];
    if ((cmf & 0x0F) != 8 || (cmf >> 4) > 7 || ((cmf << 8) | flg) % 31 != 0) {
      throw const SevenZipException('Invalid zlib header');
    }
    if ((flg & 0x20) != 0) {
      throw const SevenZipException('zlib preset dictionary is not supported',
          SevenZipError.unsupportedMethod);
    }
    _inflate = InflateDecoderStream(_input);
  }

  void _readTrailer(InflateDecoderStream z) {
    final t = Uint8List(4);
    final unused = z.unusedInput;
    var n = unused.length < 4 ? unused.length : 4;
    t.setRange(0, n, unused);
    if (n < 4) n += readFully(_input, t, n, 4 - n);
    if (n < 4) {
      throw const SevenZipException(
          'Unexpected end of zlib data', SevenZipError.unexpectedEnd);
    }
    final want = (t[0] << 24) | (t[1] << 16) | (t[2] << 8) | t[3];
    if (want != _adler) {
      throw const SevenZipException(
          'zlib Adler-32 mismatch', SevenZipError.crc);
    }
    _done = true;
  }

  @override
  int read(Uint8List buf, int off, int len) {
    if (_done || len <= 0) return 0;
    if (_inflate == null) _readHeader();
    final z = _inflate!;
    final n = z.read(buf, off, len);
    if (n > 0) {
      _adler = adler32(_adler, buf, off, off + n);
      return n;
    }
    _readTrailer(z);
    return 0;
  }
}
