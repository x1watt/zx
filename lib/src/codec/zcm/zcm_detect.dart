// zcm: splits a chunk into segments of one data type each.
//
// Images (BMP with 8, 24 or 32 bits per pixel, PGM, PPM) and PCM audio
// (WAV, AIFF) are found by their headers, anywhere in the chunk, the way
// paq8px's block detection (Filters, Block detection) finds them; their
// pixels or samples become a segment of their own type with the row
// stride or the sample layout as info. The bytes around them are split
// in blocks of 64 KiB, each classified as text, x86 code or other binary
// (adjacent blocks of the same type are merged).
//
// The segment list is coded in the stream (zcm.dart), so the decoder does
// not run the detector.

import 'dart:typed_data';

/// Segment types (4 bits in the stream).
abstract final class ZcmBlockType {
  static const binary = 0;
  static const text = 1;
  static const exe = 2;

  /// 8-bit gray or palette pixels; info: [zcmImageInfo].
  static const image8 = 3;

  /// 24-bit pixels (BGR or RGB); info: [zcmImageInfo].
  static const image24 = 4;

  /// 32-bit pixels; info: [zcmImageInfo].
  static const image32 = 5;

  /// PCM audio; info: [zcmAudioInfo].
  static const audio = 6;

  static const count = 7;

  /// Whether segments of [type] carry an info field.
  static bool hasInfo(int type) => type >= image8 && type <= audio;

  static bool isImage(int type) => type >= image8 && type <= image32;
}

/// Largest row of an image segment (bytes).
const int zcmMaxImageStride = 1 << 20;

/// Image info: bytes per row (24 bits, at most [zcmMaxImageStride]) and
/// padding bytes at the end of each row (2 bits).
int zcmImageInfo(int stride, int padding) => stride | padding << 24;

/// Audio info: bits per sample (bit 0: 16 bits), channels (bit 1:
/// stereo), big endian (bit 2); bit 3 is always set.
int zcmAudioInfo(int bits, int channels, bool bigEndian) =>
    8 |
    (bits == 16 ? 1 : 0) |
    (channels == 2 ? 2 : 0) |
    (bigEndian ? 4 : 0);

/// A run of bytes of one type.
final class ZcmSegment {
  final int type;
  final int off;
  final int len;
  final int info;
  const ZcmSegment(this.type, this.off, this.len, [this.info = 0]);

  @override
  String toString() => 'ZcmSegment($type, $off, $len, $info)';
}

/// Bytes per detection block of the generic types.
const int zcmDetectBlockSize = 1 << 16;

/// Smallest image or audio segment worth a model of its own.
const int _minMedia = 1024;

/// Detects the type of [len] bytes at [off] of [b] (text, exe, binary).
int zcmDetectBlockType(Uint8List b, int off, int len) {
  if (len < 64) return ZcmBlockType.binary;
  var text = 0;
  var e8 = 0;
  var zeros = 0;
  final end = off + len;
  for (var i = off; i < end; i++) {
    final c = b[i];
    if ((c >= 32 && c < 127) || c == 9 || c == 10 || c == 13 || c >= 0xC2) {
      text++;
    } else if (c == 0) {
      zeros++;
    }
    if ((c == 0xE8 || c == 0xE9) && i + 4 < end) {
      final hi = b[i + 4];
      if (hi == 0 || hi == 0xFF) e8++;
    }
  }
  if (text * 100 >= len * 95) return ZcmBlockType.text;
  // Calls and jumps with small displacements, and not mostly zeros.
  if (e8 * 1000 >= len * 3 && zeros * 2 < len) return ZcmBlockType.exe;
  return ZcmBlockType.binary;
}

int _u16le(Uint8List b, int i) => b[i] | b[i + 1] << 8;
int _u32le(Uint8List b, int i) =>
    b[i] | b[i + 1] << 8 | b[i + 2] << 16 | b[i + 3] << 24;
int _u16be(Uint8List b, int i) => b[i] << 8 | b[i + 1];
int _u32be(Uint8List b, int i) =>
    b[i] << 24 | b[i + 1] << 16 | b[i + 2] << 8 | b[i + 3];

// A media segment found at a header: where its data is.
final class _Media {
  final int type, start, len, info;
  const _Media(this.type, this.start, this.len, this.info);
}

// BMP (paq8px detect, BMP): BITMAPINFOHEADER and later, uncompressed 8,
// 24 or 32 bits per pixel.
_Media? _bmp(Uint8List b, int i, int end) {
  if (i + 54 > end) return null;
  final hdr = _u32le(b, i + 14);
  if (hdr != 40 && hdr != 52 && hdr != 56 && hdr != 108 && hdr != 124) {
    return null;
  }
  final dataOff = _u32le(b, i + 10);
  final width = _u32le(b, i + 18);
  var height = _u32le(b, i + 22);
  if (height >= 0x80000000) height = 0x100000000 - height;
  final planes = _u16le(b, i + 26);
  final bpp = _u16le(b, i + 28);
  final comp = _u32le(b, i + 30);
  if (planes != 1 || (bpp != 8 && bpp != 24 && bpp != 32)) return null;
  if (comp != 0 && !(comp == 3 && bpp == 32)) return null;
  if (width < 1 || width > 0x8000 || height < 1 || height > 0x10000) {
    return null;
  }
  if (dataOff < 14 + hdr || dataOff > 14 + hdr + 1024 + 256) return null;
  final stride = ((width * (bpp >> 3)) + 3) & ~3;
  final start = i + dataOff;
  var len = stride * height;
  if (start >= end) return null;
  if (start + len > end) len = (end - start) ~/ stride * stride;
  if (len < _minMedia || len < stride * 4) return null;
  final type = bpp == 8
      ? ZcmBlockType.image8
      : (bpp == 24 ? ZcmBlockType.image24 : ZcmBlockType.image32);
  return _Media(type, start, len,
      zcmImageInfo(stride, stride - width * (bpp >> 3)));
}

// Netpbm P5 (gray) and P6 (RGB) with a maximum value below 256.
_Media? _pnm(Uint8List b, int i, int end) {
  final kind = b[i + 1];
  var p = i + 2;
  final vals = <int>[];
  while (vals.length < 3) {
    // Whitespace and comments.
    while (p < end) {
      final c = b[p];
      if (c == 0x23) {
        while (p < end && b[p] != 10 && b[p] != 13) {
          p++;
        }
      } else if (c == 32 || c == 9 || c == 10 || c == 13) {
        p++;
      } else {
        break;
      }
    }
    if (p >= end || p - i > 256) return null;
    var v = 0;
    var digits = 0;
    while (p < end && b[p] >= 0x30 && b[p] <= 0x39 && digits < 6) {
      v = v * 10 + b[p] - 0x30;
      p++;
      digits++;
    }
    if (digits == 0) return null;
    vals.add(v);
  }
  if (p >= end) return null;
  final ws = b[p];
  if (ws != 32 && ws != 9 && ws != 10 && ws != 13) return null;
  p++;
  final width = vals[0], height = vals[1], maxval = vals[2];
  if (width < 1 || height < 1 || maxval < 1 || maxval > 255) return null;
  final bpp = kind == 0x35 ? 1 : 3;
  final stride = width * bpp;
  if (stride > zcmMaxImageStride) return null;
  var len = stride * height;
  if (p + len > end) len = (end - p) ~/ stride * stride;
  if (len < _minMedia || len < stride * 4) return null;
  return _Media(bpp == 1 ? ZcmBlockType.image8 : ZcmBlockType.image24, p,
      len, zcmImageInfo(stride, 0));
}

// RIFF WAVE with PCM samples of 8 or 16 bits, 1 or 2 channels.
_Media? _wav(Uint8List b, int i, int end) {
  if (i + 44 > end) return null;
  if (_u32be(b, i + 8) != 0x57415645) return null; // WAVE
  var p = i + 12;
  var bits = 0, channels = 0;
  var fmt = false;
  while (p + 8 <= end && p < i + 4096) {
    final id = _u32be(b, p);
    final size = _u32le(b, p + 4);
    if (id == 0x666D7420 && p + 24 <= end) {
      // 'fmt '
      final format = _u16le(b, p + 8);
      channels = _u16le(b, p + 10);
      bits = _u16le(b, p + 22);
      fmt = (format == 1 || format == 0xFFFE) &&
          (channels == 1 || channels == 2) &&
          (bits == 8 || bits == 16);
    } else if (id == 0x64617461) {
      // 'data'
      if (!fmt) return null;
      final start = p + 8;
      var len = size;
      if (start + len > end) len = end - start;
      final unit = channels * (bits >> 3);
      len = len ~/ unit * unit;
      if (len < _minMedia) return null;
      return _Media(ZcmBlockType.audio, start, len,
          zcmAudioInfo(bits, channels, false));
    }
    if (size > 0x7FFFFFFF) return null;
    p += 8 + size + (size & 1);
  }
  return null;
}

// AIFF with 8 or 16 bit samples (big endian), 1 or 2 channels.
_Media? _aiff(Uint8List b, int i, int end) {
  if (i + 12 > end) return null;
  if (_u32be(b, i + 8) != 0x41494646) return null; // AIFF
  var p = i + 12;
  var bits = 0, channels = 0;
  var comm = false;
  while (p + 8 <= end && p < i + 4096) {
    final id = _u32be(b, p);
    final size = _u32be(b, p + 4);
    if (id == 0x434F4D4D && p + 16 <= end) {
      // 'COMM'
      channels = _u16be(b, p + 8);
      bits = _u16be(b, p + 14);
      comm = (channels == 1 || channels == 2) && (bits == 8 || bits == 16);
    } else if (id == 0x53534E44) {
      // 'SSND': offset and block size, then the samples.
      if (!comm || p + 16 > end) return null;
      final start = p + 16 + _u32be(b, p + 8);
      var len = size - 8;
      if (start >= end || len <= 0) return null;
      if (start + len > end) len = end - start;
      final unit = channels * (bits >> 3);
      len = len ~/ unit * unit;
      if (len < _minMedia) return null;
      return _Media(ZcmBlockType.audio, start, len,
          zcmAudioInfo(bits, channels, true));
    }
    if (size > 0x7FFFFFFF) return null;
    p += 8 + size + (size & 1);
  }
  return null;
}

/// Splits [len] bytes at [off] of [b] into segments (offsets relative to
/// [off]). With [media] false only the generic types are used.
List<ZcmSegment> zcmDetectSegments(Uint8List b, int off, int len,
    {bool media = true}) {
  final end = off + len;
  final found = <_Media>[];
  if (media) {
    var i = off;
    while (i + 16 < end) {
      final c = b[i];
      _Media? m;
      if (c == 0x42 && b[i + 1] == 0x4D) {
        m = _bmp(b, i, end);
      } else if (c == 0x50 && (b[i + 1] == 0x35 || b[i + 1] == 0x36)) {
        final n = b[i + 2];
        if (n == 32 || n == 9 || n == 10 || n == 13) m = _pnm(b, i, end);
      } else if (c == 0x52 && _u32be(b, i) == 0x52494646) {
        m = _wav(b, i, end);
      } else if (c == 0x46 && _u32be(b, i) == 0x464F524D) {
        m = _aiff(b, i, end);
      }
      if (m != null) {
        found.add(m);
        i = m.start + m.len;
      } else {
        i++;
      }
    }
  }
  final out = <ZcmSegment>[];
  void generic(int from, int to) {
    for (var p = from; p < to; p += zcmDetectBlockSize) {
      final n = to - p < zcmDetectBlockSize ? to - p : zcmDetectBlockSize;
      final t = zcmDetectBlockType(b, p, n);
      if (out.isNotEmpty &&
          out.last.type == t &&
          !ZcmBlockType.hasInfo(t) &&
          out.last.off + out.last.len == p - off) {
        final l = out.removeLast();
        out.add(ZcmSegment(t, l.off, l.len + n));
      } else {
        out.add(ZcmSegment(t, p - off, n));
      }
    }
  }

  var p = off;
  for (final m in found) {
    if (m.start > p) generic(p, m.start);
    out.add(ZcmSegment(m.type, m.start - off, m.len, m.info));
    p = m.start + m.len;
  }
  if (p < end) generic(p, end);
  return out;
}
