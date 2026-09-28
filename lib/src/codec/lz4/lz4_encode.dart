// LZ4 block and frame encoder, written from the LZ4 format documents of
// the reference implementation (github.com/lz4/lz4, doc/lz4_Block_format.md
// and doc/lz4_Frame_format.md, BSD 2-clause, Copyright (c) Yann Collet).
// The output is standard LZ4: `lz4 -d` and lz4.dart decode it.
//
// The match finder is a hash of 4 bytes with short chains (a "fast" mode
// with a chain depth: 1 is the classic single probe of LZ4_compress_fast,
// larger depths find longer matches at some cost in speed). Positions
// that find no match are skipped faster and faster (the acceleration of
// LZ4_compress_fast), so incompressible data costs little.
//
// Rules of the block format kept here: the last 5 bytes are literals, the
// last match starts at least 12 bytes before the end, matches are at
// least 4 bytes, offsets are 1..65535.

import 'dart:typed_data';

import '../../util/xxhash.dart';

const int _minMatch = 4;
const int _lastLiterals = 5;
const int _mfLimit = 12;
const int _hashLog = 16;
const int _maxDistance = 65535;

/// The largest output of [lz4CompressBlock] for [n] input bytes.
int lz4CompressBound(int n) => n + n ~/ 255 + 16;

/// A reusable LZ4 block compressor (its tables are kept between calls).
class Lz4Compressor {
  /// Candidates tried per position (1 to 64).
  final int depth;

  // head[hash] = position + 1 of the last occurrence (0: none), relative
  // to the start of the current block; chain[pos & 0xFFFF] = distance to
  // the previous position with the same hash (0: none)
  final Int32List _head = Int32List(1 << _hashLog);
  final Uint16List _chain = Uint16List(1 << 16);

  Lz4Compressor({int depth = 4}) : depth = depth < 1 ? 1 : (depth > 64 ? 64 : depth);

  static final Map<int, Lz4Compressor> _shared = {};

  /// A compressor of this isolate for [depth], reused between calls (its
  /// tables are 384 KiB).
  static Lz4Compressor shared(int depth) =>
      _shared[depth] ??= Lz4Compressor(depth: depth);

  /// Compresses src[srcOff, srcOff + srcLen) as one LZ4 block into [dst]
  /// at [dstOff] (at least [lz4CompressBound] bytes of room). Returns the
  /// number of bytes written.
  int compressBlock(
      Uint8List src, int srcOff, int srcLen, Uint8List dst, int dstOff) {
    final head = _head;
    final chain = _chain;
    // unaligned little endian loads (intrinsics in AOT code)
    final bd = ByteData.sublistView(src);
    head.fillRange(0, head.length, 0);
    final base = srcOff;
    final end = srcOff + srcLen;
    var op = dstOff;
    var anchor = srcOff;
    if (srcLen >= _mfLimit + 1) {
      final mfLimit = end - _mfLimit;
      final matchLimit = end - _lastLiterals;
      final maxDepth = depth;
      var ip = srcOff;
      var misses = 0;
      while (ip < mfLimit) {
        final seq = bd.getUint32(ip, Endian.little);
        final h = ((seq * 2654435761) & 0xFFFFFFFF) >> (32 - _hashLog);
        var cand = head[h] - 1;
        final rel = ip - base;
        // insert ip
        if (cand >= 0) {
          final d = rel - cand;
          chain[rel & 0xFFFF] = d > _maxDistance ? 0 : d;
        } else {
          chain[rel & 0xFFFF] = 0;
        }
        head[h] = rel + 1;
        // the longest match among the candidates
        var bestLen = 0;
        var bestPos = 0;
        var tries = maxDepth;
        while (cand >= 0 && tries > 0) {
          final cp = base + cand;
          if (ip - cp > _maxDistance) break;
          if (bd.getUint32(cp, Endian.little) == seq) {
            var l = _minMatch;
            // 8 bytes at a time, then byte by byte
            while (ip + l + 8 <= matchLimit &&
                bd.getUint64(cp + l, Endian.little) ==
                    bd.getUint64(ip + l, Endian.little)) {
              l += 8;
            }
            while (ip + l < matchLimit && src[cp + l] == src[ip + l]) {
              l++;
            }
            if (l > bestLen) {
              bestLen = l;
              bestPos = cp;
              if (ip + l >= matchLimit) break;
            }
          }
          final d = chain[cand & 0xFFFF];
          if (d == 0) break;
          cand -= d;
          tries--;
        }
        if (bestLen == 0) {
          // skip faster through data without matches
          misses++;
          ip += 1 + (misses >> 6);
          continue;
        }
        misses = 0;
        // extend backwards
        var mp = bestPos;
        while (ip > anchor && mp > base && src[ip - 1] == src[mp - 1]) {
          ip--;
          mp--;
          bestLen++;
        }
        // the sequence: literals, then the match
        final litLen = ip - anchor;
        final ml = bestLen - _minMatch;
        final tokenPos = op++;
        var token = 0;
        if (litLen >= 15) {
          token = 0xF0;
          var r = litLen - 15;
          while (r >= 255) {
            dst[op++] = 255;
            r -= 255;
          }
          dst[op++] = r;
        } else {
          token = litLen << 4;
        }
        dst.setRange(op, op + litLen, src, anchor);
        op += litLen;
        final off = ip - mp;
        dst[op++] = off & 0xFF;
        dst[op++] = off >> 8;
        if (ml >= 15) {
          token |= 15;
          var r = ml - 15;
          while (r >= 255) {
            dst[op++] = 255;
            r -= 255;
          }
          dst[op++] = r;
        } else {
          token |= ml;
        }
        dst[tokenPos] = token;
        final mEnd = ip + bestLen;
        // index a few positions inside the match: with depth 1 only the
        // one two bytes before its end (as LZ4_compress_fast), with
        // deeper chains about 8 of them
        final stop = mEnd < mfLimit ? mEnd : mfLimit;
        var p = maxDepth == 1 ? mEnd - 2 : ip + 1;
        final step = maxDepth == 1
            ? 1
            : bestLen > 16
                ? bestLen >> 3
                : 2;
        while (p < stop) {
          final s = bd.getUint32(p, Endian.little);
          final hh = ((s * 2654435761) & 0xFFFFFFFF) >> (32 - _hashLog);
          final c = head[hh] - 1;
          final r = p - base;
          if (c >= 0) {
            final d = r - c;
            chain[r & 0xFFFF] = d > _maxDistance ? 0 : d;
          } else {
            chain[r & 0xFFFF] = 0;
          }
          head[hh] = r + 1;
          p += step;
        }
        ip = mEnd;
        anchor = ip;
      }
    }
    // the last literals
    final litLen = end - anchor;
    if (litLen >= 15) {
      dst[op++] = 0xF0;
      var r = litLen - 15;
      while (r >= 255) {
        dst[op++] = 255;
        r -= 255;
      }
      dst[op++] = r;
    } else {
      dst[op++] = litLen << 4;
    }
    dst.setRange(op, op + litLen, src, anchor);
    op += litLen;
    return op - dstOff;
  }
}

/// Compresses [src] into one LZ4 block (the raw block format, no frame).
Uint8List lz4CompressBlockBytes(Uint8List src, {int depth = 4}) {
  final out = Uint8List(lz4CompressBound(src.length));
  final n = Lz4Compressor.shared(depth).compressBlock(src, 0, src.length, out, 0);
  return Uint8List.sublistView(out, 0, n);
}

/// Compresses [src] into one LZ4 frame (magic 0x184D2204): independent
/// blocks of at most 4 MiB (64 KiB when [src] is that small), no
/// checksums besides the header checksum; a block that does not shrink
/// is stored uncompressed, as the format allows.
Uint8List lz4CompressFrame(Uint8List src, {int depth = 4}) {
  final n = src.length;
  // block maximum size code: 4 = 64 KiB, 5 = 256 KiB, 6 = 1 MiB, 7 = 4 MiB
  var bs = 4;
  while (bs < 7 && n > (1 << (8 + 2 * bs))) {
    bs++;
  }
  final blockMax = 1 << (8 + 2 * bs);
  final blocks = n == 0 ? 0 : (n + blockMax - 1) ~/ blockMax;
  final out = Uint8List(7 + blocks * (4 + lz4CompressBound(blockMax)) + 4);
  out[0] = 0x04;
  out[1] = 0x22;
  out[2] = 0x4D;
  out[3] = 0x18;
  out[4] = 0x60; // version 01, independent blocks
  out[5] = bs << 4;
  out[6] = (xxh32(out, 4, 6) >> 8) & 0xFF;
  var op = 7;
  final c = Lz4Compressor.shared(depth);
  for (var pos = 0; pos < n; pos += blockMax) {
    final len = n - pos < blockMax ? n - pos : blockMax;
    final k = c.compressBlock(src, pos, len, out, op + 4);
    if (k < len) {
      out[op] = k & 0xFF;
      out[op + 1] = (k >> 8) & 0xFF;
      out[op + 2] = (k >> 16) & 0xFF;
      out[op + 3] = (k >> 24) & 0xFF;
      op += 4 + k;
    } else {
      final v = len | 0x80000000;
      out[op] = v & 0xFF;
      out[op + 1] = (v >> 8) & 0xFF;
      out[op + 2] = (v >> 16) & 0xFF;
      out[op + 3] = (v >> 24) & 0xFF;
      out.setRange(op + 4, op + 4 + len, src, pos);
      op += 4 + len;
    }
  }
  out[op++] = 0;
  out[op++] = 0;
  out[op++] = 0;
  out[op++] = 0;
  return Uint8List.sublistView(out, 0, op);
}
