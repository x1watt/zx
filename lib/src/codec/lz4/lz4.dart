// LZ4 block and frame decoders, written from the LZ4 format documents of the
// reference implementation (github.com/lz4/lz4, doc/lz4_Block_format.md and
// doc/lz4_Frame_format.md, BSD 2-clause, Copyright (c) Yann Collet).
//
// Frame support: the LZ4 frame (magic 0x184D2204) with linked or
// independent blocks, block and content checksums (xxHash-32), content
// size, skippable frames (0x184D2A50..0x184D2A5F), concatenated frames, and
// the legacy frame (magic 0x184C2102, `lz4 -l`, the format of Linux kernel
// images). Frames with a dictionary ID are rejected (no dictionaries).
//
// All reads and writes are bounds checked: corrupt or truncated input
// throws [SevenZipException].

import 'dart:typed_data';

import '../../io/streams.dart';
import '../../util/xxhash.dart';

/// Magic number of an LZ4 frame.
const int lz4FrameMagic = 0x184D2204;

/// Magic number of a legacy LZ4 frame (lz4 -l, Linux kernel images).
const int lz4LegacyMagic = 0x184C2102;

const int _legacyBlockSize = 8 << 20;
const int _window = 1 << 16;

Never _corrupt(String what) => throw SevenZipException('LZ4 data error: $what');

Never _truncated() => throw const SevenZipException(
    'Unexpected end of LZ4 data', SevenZipError.unexpectedEnd);

Never _overrun() =>
    throw const SevenZipException('LZ4 data error: output overrun');

/// Decompresses the LZ4 block src[srcOff, srcOff + srcLen) (the rest of
/// [src] when [srcLen] is null) into a new buffer of [outSize] bytes.
/// When the block decodes to fewer bytes, a view of the decoded part is
/// returned; when it needs more, [SevenZipException] is thrown.
Uint8List lz4BlockDecompress(Uint8List src,
    {int srcOff = 0, int? srcLen, required int outSize}) {
  final len = srcLen ?? src.length - srcOff;
  final out = Uint8List(outSize);
  final n = lz4BlockDecompressInto(src, srcOff, len, out, 0, outSize);
  return n == outSize ? out : Uint8List.sublistView(out, 0, n);
}

/// Decompresses the LZ4 block src[srcOff, srcOff + srcLen) into
/// dst[dstOff, dstOff + dstCap) and returns the number of bytes written.
/// Matches may not reach before [dstOff].
int lz4BlockDecompressInto(Uint8List src, int srcOff, int srcLen, Uint8List dst,
    int dstOff, int dstCap) {
  if (srcOff < 0 || srcLen < 0 || srcOff + srcLen > src.length) {
    throw ArgumentError('lz4: source range out of bounds');
  }
  if (dstOff < 0 || dstCap < 0 || dstOff + dstCap > dst.length) {
    throw ArgumentError('lz4: destination range out of bounds');
  }
  return _decodeBlock(
          src, srcOff, srcOff + srcLen, dst, dstOff, dstOff, dstOff + dstCap) -
      dstOff;
}

// LZ4_decompress_generic (safe variant, as described in
// lz4_Block_format.md). Decodes src[ip, ipEnd) to dst[op, ...), with
// dst[histStart, op) usable as history. Returns the new output position.
int _decodeBlock(Uint8List src, int ip, int ipEnd, Uint8List dst, int histStart,
    int op, int opEnd) {
  if (ip >= ipEnd) _truncated();
  for (;;) {
    if (ip >= ipEnd) _truncated();
    final token = src[ip++];

    // literals
    var lit = token >> 4;
    if (lit == 15) {
      int b;
      do {
        if (ip >= ipEnd) _truncated();
        b = src[ip++];
        lit += b;
      } while (b == 255);
    }
    if (lit > ipEnd - ip) _truncated();
    if (lit > opEnd - op) _overrun();
    if (lit < 16) {
      for (var i = 0; i < lit; i++) {
        dst[op + i] = src[ip + i];
      }
    } else {
      dst.setRange(op, op + lit, src, ip);
    }
    ip += lit;
    op += lit;
    if (ip == ipEnd) break; // the last sequence has only literals

    // match
    if (ip + 2 > ipEnd) _truncated();
    final offset = src[ip] | (src[ip + 1] << 8);
    ip += 2;
    if (offset == 0 || offset > op - histStart) {
      _corrupt('invalid match offset');
    }
    var len = token & 15;
    if (len == 15) {
      int b;
      do {
        if (ip >= ipEnd) _truncated();
        b = src[ip++];
        len += b;
      } while (b == 255);
    }
    len += 4;
    if (len > opEnd - op) _overrun();
    var from = op - offset;
    if (offset >= len && len >= 32) {
      dst.setRange(op, op + len, dst, from);
      op += len;
    } else if (len >= 64) {
      // overlapping: copy the growing periodic pattern in chunks
      final end = op + len;
      while (op < end) {
        var n = op - from;
        if (n > end - op) n = end - op;
        dst.setRange(op, op + n, dst, from);
        op += n;
      }
    } else {
      final end = op + len;
      while (op < end) {
        dst[op++] = dst[from++];
      }
    }
  }
  return op;
}

/// Pull decoder of LZ4 frames (and legacy frames) read from [input]:
/// concatenated frames are decoded in order, skippable frames are skipped.
/// With [verifyChecksums] (the default) block and content checksums are
/// checked when present.
class Lz4FrameDecoderStream implements InStream {
  final InStream _input;
  final bool verifyChecksums;

  // 0: before a frame magic, 1: in a frame, 2: in a legacy frame, 3: done
  int _state = 0;
  final Uint8List _hdr = Uint8List(16);

  // current frame
  bool _linked = false;
  bool _blockSum = false;
  bool _contentSum = false;
  int _contentSize = -1;
  int _blockMax = 0;
  int _frameOut = 0;
  Xxh32? _xxh;

  Uint8List _in = Uint8List(0);
  Uint8List _out = Uint8List(0);
  int _histStart = 0; // start of the usable history in _out
  int _outPos = 0; // next byte handed out
  int _outEnd = 0; // end of the decoded data in _out

  Lz4FrameDecoderStream(this._input, {this.verifyChecksums = true});

  int _readLe32(bool allowEof) {
    final n = readFully(_input, _hdr, 0, 4);
    if (n == 0 && allowEof) return -1;
    if (n != 4) _truncated();
    return _hdr[0] | (_hdr[1] << 8) | (_hdr[2] << 16) | (_hdr[3] << 24);
  }

  void _readExact(Uint8List b, int off, int len) {
    if (readFully(_input, b, off, len) != len) _truncated();
  }

  void _skip(int n) {
    final tmp = Uint8List(n < 65536 ? n : 65536);
    while (n > 0) {
      final k = n < tmp.length ? n : tmp.length;
      _readExact(tmp, 0, k);
      n -= k;
    }
  }

  // Starts the frame whose magic is [magic]. Returns false at the end.
  bool _startFrame(int magic) {
    for (;;) {
      if (magic < 0) return false;
      if ((magic & 0xFFFFFFF0) == 0x184D2A50) {
        _skip(_readLe32(false));
        magic = _readLe32(true);
        continue;
      }
      if (magic == lz4LegacyMagic) {
        _state = 2;
        _linked = false;
        _blockMax = _legacyBlockSize;
        if (_out.length < _blockMax) _out = Uint8List(_blockMax);
        _histStart = _outPos = _outEnd = 0;
        return true;
      }
      if (magic != lz4FrameMagic) {
        throw const SevenZipException(
            'Unknown LZ4 frame magic', SevenZipError.headers);
      }
      _readFrameHeader();
      _state = 1;
      return true;
    }
  }

  void _readFrameHeader() {
    final h = _hdr;
    _readExact(h, 0, 2);
    final flg = h[0], bd = h[1];
    if ((flg >> 6) != 1) {
      throw const SevenZipException(
          'Unsupported LZ4 frame version', SevenZipError.unsupported);
    }
    if ((flg & 2) != 0 || (bd & 0x8F) != 0) {
      _corrupt('reserved bits set in the frame descriptor');
    }
    final bs = (bd >> 4) & 7;
    if (bs < 4) _corrupt('invalid block maximum size');
    var n = 2;
    if ((flg & 8) != 0) n += 8;
    if ((flg & 1) != 0) n += 4;
    _readExact(h, 2, n - 2 + 1);
    final hc = (xxh32(h, 0, n) >> 8) & 0xFF;
    if (hc != h[n]) _corrupt('frame header checksum mismatch');
    if ((flg & 1) != 0) {
      throw const SevenZipException(
          'LZ4 frames with a dictionary are not supported',
          SevenZipError.unsupported);
    }
    _linked = (flg & 0x20) == 0;
    _blockSum = (flg & 0x10) != 0;
    _contentSum = (flg & 4) != 0;
    if ((flg & 8) != 0) {
      final bdv = ByteData.sublistView(h);
      _contentSize = bdv.getUint64(2, Endian.little);
    } else {
      _contentSize = -1;
    }
    _blockMax = 1 << (8 + 2 * bs);
    _frameOut = 0;
    _xxh = _contentSum && verifyChecksums ? Xxh32() : null;
    final need = _linked ? _window + _blockMax : _blockMax;
    if (_out.length < need) _out = Uint8List(need);
    if (_in.length < _blockMax) _in = Uint8List(_blockMax);
    _histStart = _outPos = _outEnd = 0;
  }

  // Decodes the next block into _out. Returns false at the end of all
  // frames.
  bool _nextBlock() {
    for (;;) {
      if (_state == 3) return false;
      if (_state == 0) {
        if (!_startFrame(_readLe32(true))) {
          _state = 3;
          return false;
        }
        continue;
      }
      if (_state == 2) {
        if (_legacyBlock()) return true;
        continue;
      }
      if (_frameBlock()) return true;
    }
  }

  bool _legacyBlock() {
    final size = _readLe32(true);
    if (size <= 0) {
      // end of input, or four zero bytes (the Linux kernel's end mark)
      _state = size < 0 ? 3 : 0;
      return false;
    }
    if (size == lz4FrameMagic ||
        size == lz4LegacyMagic ||
        (size & 0xFFFFFFF0) == 0x184D2A50) {
      _state = 0;
      if (!_startFrame(size)) _state = 3;
      return false;
    }
    // LZ4_compressBound(8 MiB)
    const maxC = _legacyBlockSize + _legacyBlockSize ~/ 255 + 16;
    if (size > maxC) _corrupt('invalid legacy block size');
    if (_in.length < size) _in = Uint8List(size);
    final got = readFully(_input, _in, 0, size);
    if (got == 0) {
      // the Linux kernel build appends the 4 byte uncompressed size
      // after the legacy frame: a size field followed by the end of input
      _state = 3;
      return false;
    }
    if (got != size) _truncated();
    _outPos = 0;
    _outEnd = _decodeBlock(_in, 0, size, _out, 0, 0, _legacyBlockSize);
    return true;
  }

  bool _frameBlock() {
    final raw = _readLe32(false);
    if (raw == 0) {
      // end mark
      if (_contentSize >= 0 && _contentSize != _frameOut) {
        _corrupt('frame content size mismatch');
      }
      if (_contentSum) {
        final sum = _readLe32(false);
        final x = _xxh;
        if (x != null && x.digest != sum) {
          throw const SevenZipException(
              'LZ4 content checksum mismatch', SevenZipError.crc);
        }
      }
      _state = 0;
      return false;
    }
    final stored = (raw & 0x80000000) != 0;
    final size = raw & 0x7FFFFFFF;
    if (size > _blockMax) _corrupt('block larger than the maximum size');
    _readExact(_in, 0, size);
    if (_blockSum) {
      final sum = _readLe32(false);
      if (verifyChecksums && xxh32(_in, 0, size) != sum) {
        throw const SevenZipException(
            'LZ4 block checksum mismatch', SevenZipError.crc);
      }
    }
    // position of this block in _out
    int start;
    if (_linked) {
      start = _outEnd;
      if (start + _blockMax > _out.length) {
        // keep the last 64 KiB as history
        final keep =
            start - _histStart < _window ? start - _histStart : _window;
        _out.setRange(0, keep, _out, start - keep);
        _histStart = 0;
        start = keep;
      }
    } else {
      start = 0;
      _histStart = 0;
    }
    int end;
    if (stored) {
      _out.setRange(start, start + size, _in, 0);
      end = start + size;
    } else {
      end = _decodeBlock(
          _in, 0, size, _out, _histStart, start, start + _blockMax);
    }
    _outPos = start;
    _outEnd = end;
    _frameOut += end - start;
    _xxh?.update(_out, start, end);
    return true;
  }

  @override
  int read(Uint8List buf, int off, int len) {
    if (len <= 0) return 0;
    while (_outPos >= _outEnd) {
      if (!_nextBlock()) return 0;
    }
    var n = _outEnd - _outPos;
    if (n > len) n = len;
    buf.setRange(off, off + n, _out, _outPos);
    _outPos += n;
    return n;
  }
}
