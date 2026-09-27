// The payload decoders of U-Boot legacy images (the ih_comp field):
// gzip, bzip2, lzma (the .lzma "alone" container), lzo (the lzop file
// container), lz4 (the lz4 frame and the legacy lz4 container) and zstd.
//
// The lzop container is parsed here from its file layout (the header
// fields, then blocks of u32 dst_len, u32 src_len, optional checksums and
// the LZO1X data, ended by dst_len 0); the zstd frame header for the
// content size from RFC 8878. The decoders are the codecs of
// lib/src/codec (lzo1x, lz4 frames and legacy frames, zstd).

import 'dart:typed_data';

import '../../codec/bzip2/decompress.dart';
import '../../codec/lz4/lz4.dart';
import '../../codec/lzma/lzma_coder.dart';
import '../../codec/lzo/lzo1x.dart';
import '../../codec/zstd/zstd.dart';
import '../../io/streams.dart';
import '../../util/adler32.dart';
import '../gzip/gzip_handler.dart';
import '../item_streams.dart';

/// ih_comp values (image.h, IH_COMP_*).
abstract final class UImageComp {
  static const none = 0;
  static const gzip = 1;
  static const bzip2 = 2;
  static const lzma = 3;
  static const lzo = 4;
  static const lz4 = 5;
  static const zstd = 6;
}

/// The 7-Zip style method name of a compression code.
String uimageMethodName(int comp) {
  switch (comp) {
    case UImageComp.none:
      return 'Copy';
    case UImageComp.gzip:
      return 'gzip';
    case UImageComp.bzip2:
      return 'BZip2';
    case UImageComp.lzma:
      return 'LZMA';
    case UImageComp.lzo:
      return 'LZO';
    case UImageComp.lz4:
      return 'LZ4';
    case UImageComp.zstd:
      return 'zstd';
  }
  return 'comp$comp';
}

/// True when [p] (the first bytes of a payload) starts like data of [comp].
bool uimagePayloadMatches(int comp, Uint8List p) {
  bool at(List<int> sig) {
    if (p.length < sig.length) return false;
    for (var i = 0; i < sig.length; i++) {
      if (p[i] != sig[i]) return false;
    }
    return true;
  }

  switch (comp) {
    case UImageComp.gzip:
      return at(const [0x1F, 0x8B]);
    case UImageComp.bzip2:
      return at(const [0x42, 0x5A, 0x68]);
    case UImageComp.lzma:
      return p.length >= 13 && p[0] < 225;
    case UImageComp.lzo:
      return at(_lzopMagic);
    case UImageComp.lz4:
      return at(const [0x04, 0x22, 0x4D, 0x18]) ||
          at(const [0x02, 0x21, 0x4C, 0x18]);
    case UImageComp.zstd:
      return at(const [0x28, 0xB5, 0x2F, 0xFD]);
  }
  return true;
}

/// The decoded payload [raw] (exactly the compressed bytes) of [comp].
/// Throws [SevenZipException] for unsupported or bad data.
InStream uimageDecoder(int comp, SeekableInStream raw) {
  raw.position = 0;
  switch (comp) {
    case UImageComp.none:
      return raw;
    case UImageComp.gzip:
      return GzipDecoderInStream(raw);
    case UImageComp.bzip2:
      return Bzip2DecoderStream(raw);
    case UImageComp.lzma:
      final h = Uint8List(13);
      readExactly(raw, h, 0, 13);
      final size = getUint64LE(h, 5);
      return LzmaDecoderStream(Uint8List.sublistView(h, 0, 5), raw,
          outSize: size == -1 ? null : size, finishStream: size != -1);
    case UImageComp.lzo:
      return LzopDecoderStream(raw);
    case UImageComp.lz4:
      return Lz4FrameDecoderStream(raw);
    case UImageComp.zstd:
      return ZstdDecoderStream(raw);
  }
  throw SevenZipException(
      'Unknown compression $comp', SevenZipError.unsupportedMethod);
}

/// The unpacked size when the container stores it (gzip ISIZE, lzma
/// header, lzop block headers, lz4 frame content size, zstd frame
/// content size); null otherwise.
int? uimageUnpackedSize(int comp, SeekableInStream raw) {
  final len = raw.length;
  switch (comp) {
    case UImageComp.none:
      return len;
    case UImageComp.gzip:
      if (len < 18) return null;
      final t = readAt(raw, len - 4, 4);
      return getUint32LE(t, 0);
    case UImageComp.lzma:
      if (len < 13) return null;
      final h = readAt(raw, 0, 13);
      final size = getUint64LE(h, 5);
      return size < 0 ? null : size;
    case UImageComp.lzo:
      return _lzopUnpackedSize(raw);
    case UImageComp.lz4:
      final h = readAt(raw, 0, 14);
      if (h.length < 14 || getUint32LE(h, 0) != 0x184D2204) return null;
      if ((h[4] & 0x08) == 0) return null;
      return getUint64LE(h, 6);
    case UImageComp.zstd:
      return _zstdFrameContentSize(readAt(raw, 0, 18));
  }
  return null;
}

// ---------------------------------------------------------------------
// zstd frame header (RFC 8878, 3.1.1.1)

int? _zstdFrameContentSize(Uint8List h) {
  if (h.length < 6 || getUint32LE(h, 0) != 0xFD2FB528) return null;
  final fhd = h[4];
  final fcsFlag = fhd >> 6;
  final single = (fhd & 0x20) != 0;
  final dictFlag = fhd & 3;
  var o = 5;
  if (!single) o++;
  o += const [0, 1, 2, 4][dictFlag];
  final fcsSize = fcsFlag == 0 ? (single ? 1 : 0) : const [0, 2, 4, 8][fcsFlag];
  if (fcsSize == 0 || o + fcsSize > h.length) return null;
  switch (fcsSize) {
    case 1:
      return h[o];
    case 2:
      return (h[o] | (h[o + 1] << 8)) + 256;
    case 4:
      return getUint32LE(h, o);
  }
  return getUint64LE(h, o);
}

// ---------------------------------------------------------------------
// lzop container

const List<int> _lzopMagic = [
  0x89, 0x4C, 0x5A, 0x4F, 0x00, 0x0D, 0x0A, 0x1A, 0x0A //
];

const int _fAdler32D = 0x1;
const int _fAdler32C = 0x2;
const int _fHExtraField = 0x40;
const int _fCrc32D = 0x100;
const int _fCrc32C = 0x200;
const int _fHFilter = 0x800;

class _LzopHeader {
  int flags = 0;
  int method = 0;
  int dataStart = 0;
}

// Reads the lzop file header; the stream is left at the first block.
_LzopHeader _readLzopHeader(InStream s) {
  final h = _LzopHeader();
  var pos = 0;
  final b = Uint8List(16);
  void need(int n) {
    readExactly(s, b, 0, n);
    pos += n;
  }

  need(9);
  for (var i = 0; i < 9; i++) {
    if (b[i] != _lzopMagic[i]) {
      throw const SevenZipException('Not an lzop stream');
    }
  }
  need(4);
  final version = getUint16BE(b, 0);
  if (version >= 0x0940) need(2);
  need(1);
  h.method = b[0];
  if (version >= 0x0940) need(1);
  need(4);
  h.flags = getUint32BE(b, 0);
  if ((h.flags & _fHFilter) != 0) need(4);
  need(8); // mode, mtime low
  if (version >= 0x0940) need(4);
  need(1);
  final nameLen = b[0];
  var left = nameLen;
  while (left > 0) {
    final n = left > 16 ? 16 : left;
    need(n);
    left -= n;
  }
  need(4); // header checksum
  if ((h.flags & _fHExtraField) != 0) {
    need(4);
    var extra = getUint32BE(b, 0);
    while (extra > 0) {
      final n = extra > 16 ? 16 : extra;
      need(n);
      extra -= n;
    }
    need(4);
  }
  if (h.method < 1 || h.method > 3) {
    throw SevenZipException(
        'lzop method ${h.method}', SevenZipError.unsupportedMethod);
  }
  h.dataStart = pos;
  return h;
}

int? _lzopUnpackedSize(SeekableInStream raw) {
  try {
    raw.position = 0;
    final h = _readLzopHeader(raw);
    var pos = h.dataStart;
    var total = 0;
    final len = raw.length;
    for (;;) {
      final b = readAt(raw, pos, 8);
      if (b.length < 4) return null;
      final dst = getUint32BE(b, 0);
      if (dst == 0) return total;
      if (b.length < 8) return null;
      final src = getUint32BE(b, 4);
      pos += 8;
      if ((h.flags & _fAdler32D) != 0) pos += 4;
      if ((h.flags & _fCrc32D) != 0) pos += 4;
      if (src < dst) {
        if ((h.flags & _fAdler32C) != 0) pos += 4;
        if ((h.flags & _fCrc32C) != 0) pos += 4;
      }
      pos += src;
      total += dst;
      if (pos > len) return null;
    }
  } on SevenZipException {
    return null;
  }
}

/// The data of an lzop file, block by block (LZO1X blocks, stored blocks
/// when src_len == dst_len). The Adler-32 of the decoded data is checked
/// when the file has it.
class LzopDecoderStream implements InStream {
  final InStream _in;
  late final _LzopHeader _h;
  Uint8List _out = Uint8List(0);
  int _outPos = 0;
  bool _end = false;
  bool _started = false;

  LzopDecoderStream(this._in);

  bool _nextBlock() {
    if (!_started) {
      _h = _readLzopHeader(_in);
      _started = true;
    }
    final b = Uint8List(4);
    readExactly(_in, b, 0, 4);
    final dst = getUint32BE(b, 0);
    if (dst == 0) return false;
    readExactly(_in, b, 0, 4);
    final src = getUint32BE(b, 0);
    if (src > dst || dst > 64 << 20) {
      throw const SevenZipException('Bad lzop block');
    }
    int? adler;
    if ((_h.flags & _fAdler32D) != 0) {
      readExactly(_in, b, 0, 4);
      adler = getUint32BE(b, 0);
    }
    if ((_h.flags & _fCrc32D) != 0) readExactly(_in, b, 0, 4);
    if (src < dst) {
      if ((_h.flags & _fAdler32C) != 0) readExactly(_in, b, 0, 4);
      if ((_h.flags & _fCrc32C) != 0) readExactly(_in, b, 0, 4);
    }
    final data = Uint8List(src);
    readExactly(_in, data, 0, src);
    final out = src == dst ? data : lzo1xDecompress(data, outSize: dst);
    if (out.length != dst) throw const SevenZipException('Bad lzop block');
    if (adler != null && adler32(1, out, 0, dst) != adler) {
      throw const SevenZipException('lzop checksum error', SevenZipError.crc);
    }
    _out = out;
    _outPos = 0;
    return true;
  }

  @override
  int read(Uint8List buf, int off, int len) {
    if (len <= 0) return 0;
    while (_outPos >= _out.length) {
      if (_end) return 0;
      if (!_nextBlock()) {
        _end = true;
        return 0;
      }
    }
    var n = _out.length - _outPos;
    if (n > len) n = len;
    buf.setRange(off, off + n, _out, _outPos);
    _outPos += n;
    return n;
  }
}
