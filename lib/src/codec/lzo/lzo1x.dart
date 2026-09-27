// LZO1X decompressor, written from the description of the bitstream in the
// Linux kernel document Documentation/staging/lzo.rst ("LZO stream format
// as understood by Linux's LZO decompressor", format facts only; no code
// of LZO, miniLZO or the kernel was read or translated).
//
// It decodes the output of every LZO1X compressor (lzo1x_1, lzo1x_1_15,
// lzo1x_999; UBIFS, JFFS2, squashfs, lzop and the kernel images use them)
// and the version 1 stream of the kernel's lzo-rle (first byte 17, then the
// version byte, then zero runs coded in the 0001HLLL instruction).
//
// Every read and write is bounds checked: corrupt or truncated input
// throws [SevenZipException], never reads outside [src] or writes outside
// the given output range.

import 'dart:typed_data';

import '../../io/streams.dart';

Never _corrupt(String what) => throw SevenZipException('LZO data error: $what');

Never _truncated() => throw const SevenZipException(
    'Unexpected end of LZO data', SevenZipError.unexpectedEnd);

Never _overrun() =>
    throw const SevenZipException('LZO data error: output overrun');

/// Decompresses the LZO1X block src[srcOff, srcOff + srcLen) (the whole
/// rest of [src] when [srcLen] is null) into a new buffer of [outSize]
/// bytes. When the block decodes to fewer bytes, a view of the decoded
/// part is returned; when it would need more, [SevenZipException] is
/// thrown. Bytes after the end marker are ignored.
Uint8List lzo1xDecompress(Uint8List src,
    {int srcOff = 0, int? srcLen, required int outSize}) {
  final len = srcLen ?? src.length - srcOff;
  final out = Uint8List(outSize);
  final n = lzo1xDecompressInto(src, srcOff, len, out, 0, outSize);
  return n == outSize ? out : Uint8List.sublistView(out, 0, n);
}

/// Decompresses the LZO1X block src[srcOff, srcOff + srcLen) into
/// dst[dstOff, dstOff + dstCap) and returns the number of bytes written.
/// Throws [SevenZipException] for corrupt or truncated input and when the
/// output does not fit in [dstCap] bytes.
// lzo1x_decompress_safe (behavior as described in lzo.rst)
int lzo1xDecompressInto(Uint8List src, int srcOff, int srcLen, Uint8List dst,
    int dstOff, int dstCap) {
  if (srcOff < 0 || srcLen < 0 || srcOff + srcLen > src.length) {
    throw ArgumentError('lzo1x: source range out of bounds');
  }
  if (dstOff < 0 || dstCap < 0 || dstOff + dstCap > dst.length) {
    throw ArgumentError('lzo1x: destination range out of bounds');
  }
  var ip = srcOff;
  final ipEnd = srcOff + srcLen;
  var op = dstOff;
  final opEnd = dstOff + dstCap;
  if (srcLen < 3) _truncated();

  // bitstream version: first byte 17 and at least 5 bytes (lzo-rle)
  var version = 0;
  if (srcLen >= 5 && src[ip] == 17) {
    version = src[ip + 1];
    ip += 2;
    if (version > 1) {
      throw SevenZipException('Unsupported LZO bitstream version $version',
          SevenZipError.unsupportedMethod);
    }
  }

  // state: literals copied by the last instruction (0..3, or 4 for 4 and
  // more), which selects the meaning of instructions 0..15
  var state = 0;
  var t = src[ip];
  if (t > 17) {
    ip++;
    t -= 17;
    if (ip + t > ipEnd) _truncated();
    if (op + t > opEnd) _overrun();
    for (var i = 0; i < t; i++) {
      dst[op + i] = src[ip + i];
    }
    ip += t;
    op += t;
    state = t < 4 ? t : 4;
  }

  for (;;) {
    if (ip >= ipEnd) _truncated();
    t = src[ip++];
    int len; // match length
    int dist; // match distance
    int s; // literals after the match
    if (t < 16) {
      if (state == 0) {
        // 0000LLLL: literal run of 4 or more bytes
        len = t;
        if (len == 0) {
          len = 15;
          for (;;) {
            if (ip >= ipEnd) _truncated();
            final b = src[ip++];
            if (b != 0) {
              len += b;
              break;
            }
            len += 255;
            if (len > dstCap) _overrun();
          }
        }
        len += 3;
        if (ip + len > ipEnd) _truncated();
        if (op + len > opEnd) _overrun();
        if (len < 32) {
          for (var i = 0; i < len; i++) {
            dst[op + i] = src[ip + i];
          }
        } else {
          dst.setRange(op, op + len, src, ip);
        }
        ip += len;
        op += len;
        state = 4;
        continue;
      }
      // 0000DDSS HHHHHHHH: 2 bytes within 1 KiB after 1..3 literals,
      // 3 bytes at 2049..3072 after 4 or more literals
      if (ip >= ipEnd) _truncated();
      final h = src[ip++];
      if (state == 4) {
        len = 3;
        dist = (h << 2) + ((t >> 2) & 3) + 2049;
      } else {
        len = 2;
        dist = (h << 2) + ((t >> 2) & 3) + 1;
      }
      s = t & 3;
    } else if (t < 32) {
      // 0001HLLL (+ext) LE16: distance 16384..49151, or the end marker
      if (version == 1 &&
          (t & 8) != 0 &&
          ip + 1 < ipEnd &&
          (src[ip] & 0xFC) == 0xFC &&
          src[ip + 1] == 0xFF) {
        // lzo-rle: distance 0xBFFF means a run of zeros
        if (ip + 2 >= ipEnd) _truncated();
        s = src[ip] & 3;
        final run = ((src[ip + 2] << 3) | (t & 7)) + 4;
        ip += 3;
        if (op + run > opEnd) _overrun();
        dst.fillRange(op, op + run, 0);
        op += run;
        if (s != 0) {
          if (ip + s > ipEnd) _truncated();
          if (op + s > opEnd) _overrun();
          for (var i = 0; i < s; i++) {
            dst[op + i] = src[ip + i];
          }
          ip += s;
          op += s;
        }
        state = s;
        continue;
      }
      len = t & 7;
      if (len == 0) {
        len = 7;
        for (;;) {
          if (ip >= ipEnd) _truncated();
          final b = src[ip++];
          if (b != 0) {
            len += b;
            break;
          }
          len += 255;
          if (len > dstCap) _overrun();
        }
      }
      len += 2;
      if (ip + 2 > ipEnd) _truncated();
      final v = src[ip] | (src[ip + 1] << 8);
      ip += 2;
      dist = 16384 + ((t & 8) << 11) + (v >> 2);
      s = v & 3;
      if (dist == 16384) break; // end of stream
    } else if (t < 64) {
      // 001LLLLL (+ext) LE16: distance 1..16384
      len = t & 31;
      if (len == 0) {
        len = 31;
        for (;;) {
          if (ip >= ipEnd) _truncated();
          final b = src[ip++];
          if (b != 0) {
            len += b;
            break;
          }
          len += 255;
          if (len > dstCap) _overrun();
        }
      }
      len += 2;
      if (ip + 2 > ipEnd) _truncated();
      final v = src[ip] | (src[ip + 1] << 8);
      ip += 2;
      dist = (v >> 2) + 1;
      s = v & 3;
    } else {
      // 01LDDDSS / 1LLDDDSS HHHHHHHH: 3..8 bytes within 2 KiB
      if (ip >= ipEnd) _truncated();
      final h = src[ip++];
      len = t < 128 ? 3 + ((t >> 5) & 1) : 5 + ((t >> 5) & 3);
      dist = (h << 3) + ((t >> 2) & 7) + 1;
      s = t & 3;
    }

    // match copy
    if (dist > op - dstOff) _corrupt('match distance too far back');
    if (op + len > opEnd) _overrun();
    var from = op - dist;
    if (dist >= len && len >= 32) {
      dst.setRange(op, op + len, dst, from);
      op += len;
    } else {
      final end = op + len;
      while (op < end) {
        dst[op++] = dst[from++];
      }
    }

    // 0..3 literals after the match
    if (s != 0) {
      if (ip + s > ipEnd) _truncated();
      if (op + s > opEnd) _overrun();
      for (var i = 0; i < s; i++) {
        dst[op + i] = src[ip + i];
      }
      ip += s;
      op += s;
    }
    state = s;
  }
  return op - dstOff;
}
