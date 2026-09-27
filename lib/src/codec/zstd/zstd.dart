// Zstandard frames (RFC 8878): the frame header, raw, RLE and compressed
// blocks, skippable frames, concatenated frames and the XXH64 content
// checksum, in memory ([zstdDecompress]) and as a pull stream
// ([ZstdDecoderStream]). Dictionaries are not supported (a frame with a
// dictionary ID is rejected). See zstd_block.dart for the sources.

import 'dart:typed_data';

import '../../io/streams.dart';
import '../../util/xxhash.dart';
import 'zstd_block.dart';

/// Magic number of a zstd frame.
const int zstdMagic = 0xFD2FB528;

bool _isSkippable(int magic) => (magic & 0xFFFFFFF0) == 0x184D2A50;

Never _truncated() => throw const SevenZipException(
    'Unexpected end of zstd data', SevenZipError.unexpectedEnd);

int _le32(Uint8List b, int p) =>
    b[p] | (b[p + 1] << 8) | (b[p + 2] << 16) | (b[p + 3] << 24);

/// The parsed frame header (ZSTD_frameHeader).
class _FrameHeader {
  int windowSize = 0;
  int contentSize = -1; // -1: unknown
  bool checksum = false;
  int blockMax = 0;
}

// Size of the frame header after the magic, from its first byte.
int _headerSize(int fhd) {
  final fcsFlag = fhd >> 6;
  final single = (fhd & 0x20) != 0;
  const dictBytes = [0, 1, 2, 4];
  const fcsBytes = [0, 2, 4, 8];
  var n = 1 + (single ? 0 : 1) + dictBytes[fhd & 3];
  n += fcsFlag == 0 ? (single ? 1 : 0) : fcsBytes[fcsFlag];
  return n;
}

// parse_frame_header: h[p, p + _headerSize(h[p]))
void _parseHeader(Uint8List h, int p, _FrameHeader f) {
  final fhd = h[p++];
  final fcsFlag = fhd >> 6;
  final single = (fhd & 0x20) != 0;
  if ((fhd & 0x08) != 0) {
    throw const SevenZipException('zstd data error: reserved bit set');
  }
  f.checksum = (fhd & 0x04) != 0;
  var window = 0;
  if (!single) {
    final wd = h[p++];
    final base = 1 << (10 + (wd >> 3));
    window = base + (base >> 3) * (wd & 7);
  }
  var dictId = 0;
  switch (fhd & 3) {
    case 1:
      dictId = h[p];
      p += 1;
    case 2:
      dictId = h[p] | (h[p + 1] << 8);
      p += 2;
    case 3:
      dictId = _le32(h, p);
      p += 4;
  }
  if (dictId != 0) {
    throw const SevenZipException(
        'zstd frames with a dictionary are not supported',
        SevenZipError.unsupported);
  }
  var fcs = -1;
  switch (fcsFlag) {
    case 0:
      if (single) fcs = h[p];
    case 1:
      fcs = (h[p] | (h[p + 1] << 8)) + 256;
    case 2:
      fcs = _le32(h, p);
    case 3:
      fcs = _le32(h, p) | (_le32(h, p + 4) << 32);
      if (fcs < 0) {
        throw const SevenZipException(
            'zstd frame content size too large', SevenZipError.unsupported);
      }
  }
  f.contentSize = fcs;
  f.windowSize = single ? fcs : window;
  final w = f.windowSize;
  f.blockMax = w < zstdBlockSizeMax ? w : zstdBlockSizeMax;
}

// Returns [out] with room for [need] bytes (the first [used] kept), grown
// by doubling up to [limit].
Uint8List _grow(Uint8List out, int used, int need, int limit) {
  if (need <= out.length) return out;
  var cap = out.length * 2;
  if (cap < need) cap = need;
  if (cap < 1 << 16) cap = 1 << 16;
  if (cap > limit) cap = limit;
  return Uint8List(cap)..setRange(0, used, out);
}

/// Decompresses all zstd frames of [src] (skippable frames are skipped)
/// and returns the concatenated output. Throws [SevenZipException] for
/// corrupt or truncated data, a checksum mismatch, unknown data after the
/// frames, or an output larger than [maxOutput].
Uint8List zstdDecompress(Uint8List src, {int? maxOutput}) {
  final limit = maxOutput ?? (1 << 62);
  var out = Uint8List(0);
  var op = 0;
  var ip = 0;
  final dec = ZstdBlockDecoder();
  final f = _FrameHeader();

  if (src.length < 4) _truncated();
  while (ip < src.length) {
    if (src.length - ip < 4) _truncated();
    final magic = _le32(src, ip);
    ip += 4;
    if (_isSkippable(magic)) {
      if (src.length - ip < 4) _truncated();
      final size = _le32(src, ip);
      ip += 4;
      if (src.length - ip < size) _truncated();
      ip += size;
      continue;
    }
    if (magic != zstdMagic) {
      throw const SevenZipException(
          'Unknown zstd frame magic', SevenZipError.headers);
    }
    if (src.length - ip < 1) _truncated();
    final hs = _headerSize(src[ip]);
    if (src.length - ip < hs) _truncated();
    _parseHeader(src, ip, f);
    ip += hs;
    dec.reset();
    final frameStart = op;
    if (f.contentSize >= 0) {
      if (f.contentSize > limit - op) {
        throw const SevenZipException('zstd output larger than the limit');
      }
      out = _grow(out, op, op + f.contentSize, limit);
    }
    final bmax = f.blockMax;
    for (;;) {
      if (src.length - ip < 3) _truncated();
      final bh = src[ip] | (src[ip + 1] << 8) | (src[ip + 2] << 16);
      ip += 3;
      final last = (bh & 1) != 0;
      final type = (bh >> 1) & 3;
      final size = bh >> 3;
      switch (type) {
        case 0:
          if (size > bmax) zstdCorrupt('block too large');
          if (src.length - ip < size) _truncated();
          if (size > limit - op) {
            throw const SevenZipException('zstd output larger than the limit');
          }
          out = _grow(out, op, op + size, limit);
          out.setRange(op, op + size, src, ip);
          ip += size;
          op += size;
        case 1:
          if (size > bmax) zstdCorrupt('block too large');
          if (src.length - ip < 1) _truncated();
          if (size > limit - op) {
            throw const SevenZipException('zstd output larger than the limit');
          }
          out = _grow(out, op, op + size, limit);
          out.fillRange(op, op + size, src[ip]);
          ip += 1;
          op += size;
        case 2:
          if (size > zstdBlockSizeMax) zstdCorrupt('block too large');
          if (src.length - ip < size) _truncated();
          var end = op + bmax;
          if (end > limit) end = limit;
          final cs = f.contentSize;
          if (cs >= 0 && end > frameStart + cs) end = frameStart + cs;
          out = _grow(out, op, end, limit);
          op = dec.decodeCompressed(
              src, ip, ip + size, out, frameStart, op, end);
          ip += size;
        default:
          zstdCorrupt('reserved block type');
      }
      if (f.contentSize >= 0 && op - frameStart > f.contentSize) {
        zstdCorrupt('frame larger than its content size');
      }
      if (last) break;
    }
    if (f.contentSize >= 0 && op - frameStart != f.contentSize) {
      zstdCorrupt('frame content size mismatch');
    }
    if (f.checksum) {
      if (src.length - ip < 4) _truncated();
      final want = _le32(src, ip);
      ip += 4;
      if ((xxh64(out, frameStart, op) & 0xFFFFFFFF) != want) {
        throw const SevenZipException(
            'zstd content checksum mismatch', SevenZipError.crc);
      }
    }
  }
  if (out.length == op) return out;
  if (out.length - op <= (1 << 16)) return Uint8List.sublistView(out, 0, op);
  return Uint8List.fromList(Uint8List.sublistView(out, 0, op));
}

/// Pull decoder of zstd frames read from [input]: concatenated frames are
/// decoded in order and skippable frames skipped. The window buffer grows
/// with the output up to the window size of the frame (at most
/// [maxWindowSize], larger windows are rejected). With [verifyChecksum]
/// (the default) the content checksum is checked when present.
class ZstdDecoderStream implements InStream {
  final InStream _input;
  final bool verifyChecksum;
  final int maxWindowSize;

  final ZstdBlockDecoder _dec = ZstdBlockDecoder();
  final _FrameHeader _f = _FrameHeader();
  final Uint8List _hdr = Uint8List(16);
  Uint8List? _cbuf;

  // 0: before a frame, 1: in a frame, 2: done
  int _state = 0;
  int _window = 0;
  int _frameOut = 0;
  Xxh64? _xxh;

  Uint8List _buf = Uint8List(0);
  int _histStart = 0;
  int _pos = 0; // end of the decoded data
  int _outPos = 0; // next byte handed out

  ZstdDecoderStream(this._input,
      {this.verifyChecksum = true, this.maxWindowSize = 1 << 31});

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

  // Reads the next frame header. Returns false at the end of the input.
  bool _startFrame() {
    for (;;) {
      final n = readFully(_input, _hdr, 0, 4);
      if (n == 0) return false;
      if (n != 4) _truncated();
      final magic = _le32(_hdr, 0);
      if (_isSkippable(magic)) {
        _readExact(_hdr, 0, 4);
        _skip(_le32(_hdr, 0));
        continue;
      }
      if (magic != zstdMagic) {
        throw const SevenZipException(
            'Unknown zstd frame magic', SevenZipError.headers);
      }
      _readExact(_hdr, 0, 1);
      final hs = _headerSize(_hdr[0]);
      _readExact(_hdr, 1, hs - 1);
      _parseHeader(_hdr, 0, _f);
      var w = _f.windowSize;
      if (_f.contentSize >= 0 && _f.contentSize < w) w = _f.contentSize;
      if (w > maxWindowSize) {
        throw SevenZipException(
            'zstd window of ${_f.windowSize} bytes is larger than the limit',
            SevenZipError.unsupported);
      }
      _window = w;
      _dec.reset();
      _frameOut = 0;
      _xxh = _f.checksum && verifyChecksum ? Xxh64() : null;
      _histStart = _pos;
      return true;
    }
  }

  // Makes room for [room] bytes at _pos. Called when all decoded data was
  // handed out; keeps at most one window of history of the current frame,
  // moved to the start of the buffer.
  void _makeRoom(int room) {
    if (_pos + room <= _buf.length) return;
    var keep = _pos - _histStart;
    if (keep > _window) keep = _window;
    var extra = _window;
    if (extra > 32 << 20) extra = 32 << 20;
    if (extra < 4 * zstdBlockSizeMax) extra = 4 * zstdBlockSizeMax;
    final maxCap = _window + extra;
    if (_buf.length < maxCap || keep + room > _buf.length) {
      var cap = _buf.length * 2;
      if (cap < 1 << 20) cap = 1 << 20;
      if (cap > maxCap) cap = maxCap;
      if (cap < keep + room) cap = keep + room;
      _buf = Uint8List(cap)..setRange(0, keep, _buf, _pos - keep);
    } else {
      _buf.setRange(0, keep, _buf, _pos - keep);
    }
    _histStart = 0;
    _pos = _outPos = keep;
  }

  // Decodes the next block. Returns false at the end of all frames.
  bool _nextBlock() {
    for (;;) {
      if (_state == 2) return false;
      if (_state == 0) {
        if (!_startFrame()) {
          _state = 2;
          return false;
        }
        _state = 1;
        continue;
      }
      _readExact(_hdr, 0, 3);
      final bh = _hdr[0] | (_hdr[1] << 8) | (_hdr[2] << 16);
      final last = (bh & 1) != 0;
      final type = (bh >> 1) & 3;
      final size = bh >> 3;
      final bmax = _f.blockMax;
      if (type == 3) zstdCorrupt('reserved block type');
      if (size > (type == 2 ? zstdBlockSizeMax : bmax)) {
        zstdCorrupt('block too large');
      }
      if (type == 2) {
        final cb = _cbuf ??= Uint8List(zstdBlockSizeMax);
        _readExact(cb, 0, size);
        _makeRoom(bmax);
        _pos = _dec.decodeCompressed(
            cb, 0, size, _buf, _histStart, _pos, _pos + bmax);
      } else {
        _makeRoom(size);
        if (type == 0) {
          _readExact(_buf, _pos, size);
        } else {
          _readExact(_hdr, 0, 1);
          _buf.fillRange(_pos, _pos + size, _hdr[0]);
        }
        _pos += size;
      }
      final blockStart = _outPos;
      final n = _pos - blockStart;
      _frameOut += n;
      _xxh?.update(_buf, blockStart, _pos);
      final cs = _f.contentSize;
      if (cs >= 0 && _frameOut > cs) {
        zstdCorrupt('frame larger than its content size');
      }
      if (last) _endFrame();
      if (n > 0) return true;
    }
  }

  void _endFrame() {
    final cs = _f.contentSize;
    if (cs >= 0 && _frameOut != cs) zstdCorrupt('frame content size mismatch');
    if (_f.checksum) {
      _readExact(_hdr, 0, 4);
      final x = _xxh;
      if (x != null && (x.digest & 0xFFFFFFFF) != _le32(_hdr, 0)) {
        throw const SevenZipException(
            'zstd content checksum mismatch', SevenZipError.crc);
      }
    }
    _state = 0;
  }

  @override
  int read(Uint8List buf, int off, int len) {
    if (len <= 0) return 0;
    while (_outPos >= _pos) {
      if (!_nextBlock()) return 0;
    }
    var n = _pos - _outPos;
    if (n > len) n = len;
    buf.setRange(off, off + n, _buf, _outPos);
    _outPos += n;
    return n;
  }
}
