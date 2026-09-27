// The block layer of the Zstandard decoder: literals (raw, RLE, Huffman
// with 1 or 4 streams, repeated tables), FSE table descriptions, sequences
// and their execution.
//
// Written from RFC 8878 and the zstd format document
// (doc/zstd_compression_format.md), following the structure of the zstd
// educational decoder (doc/educational_decoder/zstd_decompress.c, used
// under its BSD license, Copyright (c) Meta Platforms, Inc. and
// affiliates). The C function names are kept in the comments. The
// backward bit reader is the 64-bit container of the reference library
// (BIT_initDStream / BIT_reloadDStream), with all positions checked.

import 'dart:typed_data';

import '../../io/streams.dart';

/// Largest block content and block output of zstd (ZSTD_BLOCKSIZE_MAX).
const int zstdBlockSizeMax = 1 << 17;

Never zstdCorrupt(String what) =>
    throw SevenZipException('zstd data error: $what');

// ---- tables of RFC 8878 section 3.1.1.3.2.1 ----

const List<int> _llBase = [
  0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 18, 20, 22, 24, //
  28, 32, 40, 48, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768,
  65536,
];
const List<int> _llBits = [
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 3, 3, //
  4, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
];
const List<int> _mlBase = [
  3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, //
  23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 37, 39, 41, 43, 47, 51,
  59, 67, 83, 99, 131, 259, 515, 1027, 2051, 4099, 8195, 16387, 32771, 65539,
];
const List<int> _mlBits = [
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, //
  0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 7, 8, 9, 10, 11,
  12, 13, 14, 15, 16,
];

// default distributions (RFC 8878 section 3.1.1.3.2.2)
const List<int> _llDefault = [
  4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, //
  2, 3, 2, 1, 1, 1, 1, 1, -1, -1, -1, -1,
];
const List<int> _ofDefault = [
  1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, //
  -1, -1, -1, -1, -1,
];
const List<int> _mlDefault = [
  1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, //
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1,
  -1, -1, -1, -1, -1,
];

const int _kindLL = 0;
const int _kindOF = 1;
const int _kindML = 2;
const List<int> _maxSymbol = [35, 31, 52];
const List<int> _maxLog = [9, 8, 9];

int _highBit(int v) {
  // index of the highest set bit of v > 0
  var n = 0;
  while (v > 1) {
    v >>= 1;
    n++;
  }
  return n;
}

// n <= 16 bits at bit position bitPos of src, bytes from end on read as 0
int _bitsAt(Uint8List src, int end, int bitPos, int n) {
  final p = bitPos >> 3;
  var v = 0;
  for (var i = 0; i < 4; i++) {
    if (p + i < end) v |= src[p + i] << (8 * i);
  }
  return (v >> (bitPos & 7)) & ((1 << n) - 1);
}

/// A sequence decoding table (ZSTD_seqSymbol): for each state the base
/// value and extra bits of its code, and the FSE transition.
class _SeqTable {
  final Int32List base = Int32List(512);
  final Uint8List addBits = Uint8List(512);
  final Uint8List nbBits = Uint8List(512);
  final Uint16List nextBase = Uint16List(512);
  int log = 0;
}

/// An FSE decoding table for the Huffman weights.
class _FseTable {
  final Uint8List symbol = Uint8List(64);
  final Uint8List nbBits = Uint8List(64);
  final Uint16List nextBase = Uint16List(64);
  int log = 0;
}

final _SeqTable _llPredef = _predefined(_kindLL, _llDefault, 6);
final _SeqTable _ofPredef = _predefined(_kindOF, _ofDefault, 5);
final _SeqTable _mlPredef = _predefined(_kindML, _mlDefault, 6);

_SeqTable _predefined(int kind, List<int> dist, int log) {
  final t = _SeqTable();
  final norm = Int16List(64);
  for (var i = 0; i < dist.length; i++) {
    norm[i] = dist[i];
  }
  final sym = Uint8List(512);
  final nb = Uint8List(512);
  final nx = Uint16List(512);
  _buildFse(norm, dist.length, log, sym, nb, nx);
  _fillSeq(t, kind, log, sym, nb, nx);
  return t;
}

// FSE_init_dtable: spreads the symbols of the normalized counts
// norm[0, count) over 1 << log states.
void _buildFse(Int16List norm, int count, int log, Uint8List sym,
    Uint8List nbBits, Uint16List nextBase) {
  final size = 1 << log;
  final next = Int32List(256);
  var high = size - 1;
  for (var s = 0; s < count; s++) {
    if (norm[s] == -1) {
      sym[high--] = s;
      next[s] = 1;
    } else {
      next[s] = norm[s];
    }
  }
  final step = (size >> 1) + (size >> 3) + 3;
  final mask = size - 1;
  var pos = 0;
  for (var s = 0; s < count; s++) {
    final n = norm[s];
    for (var i = 0; i < n; i++) {
      sym[pos] = s;
      do {
        pos = (pos + step) & mask;
      } while (pos > high);
    }
  }
  if (pos != 0) zstdCorrupt('invalid FSE distribution');
  for (var u = 0; u < size; u++) {
    final s = sym[u];
    final ns = next[s]++;
    final b = log - _highBit(ns);
    nbBits[u] = b;
    nextBase[u] = (ns << b) - size;
  }
}

void _fillSeq(_SeqTable t, int kind, int log, Uint8List sym, Uint8List nb,
    Uint16List nx) {
  final size = 1 << log;
  final maxSym = _maxSymbol[kind];
  for (var u = 0; u < size; u++) {
    final s = sym[u];
    if (s > maxSym) zstdCorrupt('invalid sequence code');
    t.nbBits[u] = nb[u];
    t.nextBase[u] = nx[u];
    if (kind == _kindLL) {
      t.base[u] = _llBase[s];
      t.addBits[u] = _llBits[s];
    } else if (kind == _kindML) {
      t.base[u] = _mlBase[s];
      t.addBits[u] = _mlBits[s];
    } else {
      t.base[u] = 1 << s;
      t.addBits[u] = s;
    }
  }
  t.log = log;
}

/// Decoder of the blocks of one frame; [reset] starts a new frame.
class ZstdBlockDecoder {
  // literals
  final Uint8List _lit = Uint8List(zstdBlockSizeMax + 32);
  // Huffman table: symbol | nbBits << 8, 1 << _hufLog entries
  final Uint16List _huf = Uint16List(1 << 11);
  int _hufLog = 0; // 0: no table yet
  final Uint8List _weights = Uint8List(256);
  final Uint8List _hufBits = Uint8List(256);
  final _FseTable _wTable = _FseTable();

  // sequence tables in use (predefined ones or the own buffers)
  _SeqTable? _ll, _of, _ml;
  final _SeqTable _llOwn = _SeqTable();
  final _SeqTable _ofOwn = _SeqTable();
  final _SeqTable _mlOwn = _SeqTable();

  // scratch for FSE table building
  final Int16List _norm = Int16List(64);
  final Uint8List _sym = Uint8List(512);
  final Uint8List _nb = Uint8List(512);
  final Uint16List _nx = Uint16List(512);

  int _rep0 = 1, _rep1 = 4, _rep2 = 8;

  // result of _readFseHeader
  int _fseLog = 0;
  int _fseCount = 0;

  // backward bit reader state (BIT_DStream_t)
  int _bPtr = 0;
  int _bStart = 0;
  int _bBits = 0;
  int _bC = 0;

  /// Starts a new frame: no repeated tables, default repeat offsets.
  void reset() {
    _hufLog = 0;
    _ll = _of = _ml = null;
    _rep0 = 1;
    _rep1 = 4;
    _rep2 = 8;
  }

  // BIT_initDStream over src[start, end): sets _bPtr, _bBits, _bC.
  void _initBits(Uint8List src, ByteData bd, int start, int end) {
    if (end <= start) zstdCorrupt('empty bitstream');
    final last = src[end - 1];
    if (last == 0) zstdCorrupt('bitstream without end mark');
    _bStart = start;
    final len = end - start;
    if (len >= 8) {
      _bPtr = end - 8;
      _bC = bd.getUint64(_bPtr, Endian.little);
      _bBits = 8 - _highBit(last);
    } else {
      _bPtr = start;
      var c = 0;
      for (var i = 0; i < len; i++) {
        c |= src[start + i] << (8 * i);
      }
      _bC = c;
      _bBits = 8 - _highBit(last) + (8 - len) * 8;
    }
  }

  /// Decodes the compressed block src[ip, ipEnd) to out[op, opEnd), with
  /// out[histStart, op) as the history of the frame. Returns the new
  /// output position.
  // ZSTD_decompressBlock_internal
  int decodeCompressed(Uint8List src, int ip, int ipEnd, Uint8List out,
      int histStart, int op, int opEnd) {
    try {
      return _decodeCompressed(src, ip, ipEnd, out, histStart, op, opEnd);
    } on RangeError {
      zstdCorrupt('corrupt block');
    }
  }

  int _decodeCompressed(Uint8List src, int ip, int ipEnd, Uint8List out,
      int histStart, int op, int opEnd) {
    final bd = ByteData.sublistView(src);
    if (ipEnd - ip < 1) zstdCorrupt('block too small');

    // ---- literals section (decode_literals) ----
    final b0 = src[ip];
    final litType = b0 & 3;
    final sf = (b0 >> 2) & 3;
    Uint8List litBuf;
    int litPos, litEnd;
    if (litType <= 1) {
      int size;
      if ((sf & 1) == 0) {
        size = b0 >> 3;
        ip += 1;
      } else if (sf == 1) {
        if (ipEnd - ip < 2) zstdCorrupt('truncated literals header');
        size = (b0 >> 4) | (src[ip + 1] << 4);
        ip += 2;
      } else {
        if (ipEnd - ip < 3) zstdCorrupt('truncated literals header');
        size = (b0 >> 4) | (src[ip + 1] << 4) | (src[ip + 2] << 12);
        ip += 3;
      }
      if (size > zstdBlockSizeMax) zstdCorrupt('literals too large');
      if (litType == 0) {
        if (ipEnd - ip < size) zstdCorrupt('truncated literals');
        litBuf = src;
        litPos = ip;
        litEnd = ip + size;
        ip += size;
      } else {
        if (ipEnd - ip < 1) zstdCorrupt('truncated literals');
        _lit.fillRange(0, size, src[ip]);
        ip += 1;
        litBuf = _lit;
        litPos = 0;
        litEnd = size;
      }
    } else {
      int regen, csize, hlen;
      var streams = 4;
      if (sf <= 1) {
        if (ipEnd - ip < 3) zstdCorrupt('truncated literals header');
        final h = b0 | (src[ip + 1] << 8) | (src[ip + 2] << 16);
        regen = (h >> 4) & 0x3FF;
        csize = (h >> 14) & 0x3FF;
        hlen = 3;
        if (sf == 0) streams = 1;
      } else if (sf == 2) {
        if (ipEnd - ip < 4) zstdCorrupt('truncated literals header');
        final h =
            b0 | (src[ip + 1] << 8) | (src[ip + 2] << 16) | (src[ip + 3] << 24);
        regen = (h >> 4) & 0x3FFF;
        csize = (h >> 18) & 0x3FFF;
        hlen = 4;
      } else {
        if (ipEnd - ip < 5) zstdCorrupt('truncated literals header');
        final h = b0 |
            (src[ip + 1] << 8) |
            (src[ip + 2] << 16) |
            (src[ip + 3] << 24) |
            (src[ip + 4] << 32);
        regen = (h >> 4) & 0x3FFFF;
        csize = (h >> 22) & 0x3FFFF;
        hlen = 5;
      }
      ip += hlen;
      if (regen > zstdBlockSizeMax) zstdCorrupt('literals too large');
      if (ipEnd - ip < csize) zstdCorrupt('truncated literals');
      var hp = ip;
      final hEnd = ip + csize;
      if (litType == 2) {
        hp = _readHuffmanTable(src, bd, hp, hEnd);
      } else if (_hufLog == 0) {
        zstdCorrupt('repeated Huffman table without a previous one');
      }
      if (streams == 1) {
        _hufStream(src, bd, hp, hEnd, 0, regen);
      } else {
        if (hEnd - hp < 10) zstdCorrupt('truncated jump table');
        final s1 = src[hp] | (src[hp + 1] << 8);
        final s2 = src[hp + 2] | (src[hp + 3] << 8);
        final s3 = src[hp + 4] | (src[hp + 5] << 8);
        hp += 6;
        if (s1 + s2 + s3 + 1 > hEnd - hp) zstdCorrupt('invalid jump table');
        final seg = (regen + 3) >> 2;
        if (seg * 3 > regen) zstdCorrupt('invalid literals size');
        _hufStream(src, bd, hp, hp + s1, 0, seg);
        _hufStream(src, bd, hp + s1, hp + s1 + s2, seg, 2 * seg);
        _hufStream(src, bd, hp + s1 + s2, hp + s1 + s2 + s3, 2 * seg, 3 * seg);
        _hufStream(src, bd, hp + s1 + s2 + s3, hEnd, 3 * seg, regen);
      }
      ip = hEnd;
      litBuf = _lit;
      litPos = 0;
      litEnd = regen;
    }

    // ---- sequences section (decode_sequences) ----
    if (ipEnd - ip < 1) zstdCorrupt('missing sequences section');
    var nbSeq = src[ip++];
    if (nbSeq >= 128) {
      if (nbSeq == 255) {
        if (ipEnd - ip < 2) zstdCorrupt('truncated sequences header');
        nbSeq = src[ip] + (src[ip + 1] << 8) + 0x7F00;
        ip += 2;
      } else {
        if (ipEnd - ip < 1) zstdCorrupt('truncated sequences header');
        nbSeq = ((nbSeq - 128) << 8) + src[ip++];
      }
    }
    if (nbSeq == 0) {
      final n = litEnd - litPos;
      if (n > opEnd - op) zstdCorrupt('block output too large');
      out.setRange(op, op + n, litBuf, litPos);
      return op + n;
    }
    if (ipEnd - ip < 1) zstdCorrupt('truncated sequences header');
    final modes = src[ip++];
    if ((modes & 3) != 0) zstdCorrupt('reserved bits set');
    ip = _seqTable(_kindLL, (modes >> 6) & 3, src, ip, ipEnd);
    ip = _seqTable(_kindOF, (modes >> 4) & 3, src, ip, ipEnd);
    ip = _seqTable(_kindML, (modes >> 2) & 3, src, ip, ipEnd);

    return _sequences(src, bd, ip, ipEnd, nbSeq, litBuf, litPos, litEnd, out,
        histStart, op, opEnd);
  }

  // decode_seq_table: sets the table of [kind] for [mode]. Returns the
  // new input position.
  int _seqTable(int kind, int mode, Uint8List src, int ip, int ipEnd) {
    final own = kind == _kindLL
        ? _llOwn
        : kind == _kindOF
            ? _ofOwn
            : _mlOwn;
    _SeqTable? t;
    switch (mode) {
      case 0:
        t = kind == _kindLL
            ? _llPredef
            : kind == _kindOF
                ? _ofPredef
                : _mlPredef;
      case 1:
        if (ipEnd - ip < 1) zstdCorrupt('truncated RLE table');
        final s = src[ip++];
        _sym[0] = s;
        _nb[0] = 0;
        _nx[0] = 0;
        _fillSeq(own, kind, 0, _sym, _nb, _nx);
        t = own;
      case 2:
        ip = _readFseHeader(src, ip, ipEnd, _maxLog[kind], _maxSymbol[kind]);
        _buildFse(_norm, _fseCount, _fseLog, _sym, _nb, _nx);
        _fillSeq(own, kind, _fseLog, _sym, _nb, _nx);
        t = own;
      default:
        t = kind == _kindLL
            ? _ll
            : kind == _kindOF
                ? _of
                : _ml;
        if (t == null) zstdCorrupt('repeated table without a previous one');
    }
    if (kind == _kindLL) {
      _ll = t;
    } else if (kind == _kindOF) {
      _of = t;
    } else {
      _ml = t;
    }
    return ip;
  }

  // FSE_decode_header: reads a normalized distribution into _norm,
  // _fseCount and _fseLog. Returns the position after it.
  int _readFseHeader(
      Uint8List src, int ip, int ipEnd, int maxLog, int maxSymbol) {
    var bitPos = ip * 8;
    final endBits = ipEnd * 8;
    final log = 5 + _bitsAt(src, ipEnd, bitPos, 4);
    bitPos += 4;
    if (log > maxLog) zstdCorrupt('FSE accuracy log too large');
    var remaining = 1 << log;
    var sym = 0;
    final norm = _norm;
    while (remaining > 0) {
      if (sym > maxSymbol) zstdCorrupt('too many FSE symbols');
      final bits = _highBit(remaining + 1) + 1;
      var val = _bitsAt(src, ipEnd, bitPos, bits);
      final lowerMask = (1 << (bits - 1)) - 1;
      final threshold = (1 << bits) - 1 - (remaining + 1);
      if ((val & lowerMask) < threshold) {
        val &= lowerMask;
        bitPos += bits - 1;
      } else {
        if (val > lowerMask) val -= threshold;
        bitPos += bits;
      }
      final proba = val - 1;
      remaining -= proba < 0 ? -proba : proba;
      norm[sym++] = proba;
      if (proba == 0) {
        for (;;) {
          final rep = _bitsAt(src, ipEnd, bitPos, 2);
          bitPos += 2;
          for (var i = 0; i < rep; i++) {
            if (sym > maxSymbol) zstdCorrupt('too many FSE symbols');
            norm[sym++] = 0;
          }
          if (rep != 3) break;
          if (bitPos > endBits) zstdCorrupt('truncated FSE table');
        }
      }
      if (bitPos > endBits) zstdCorrupt('truncated FSE table');
    }
    if (remaining != 0) zstdCorrupt('invalid FSE distribution');
    _fseLog = log;
    _fseCount = sym;
    return (bitPos + 7) >> 3;
  }

  // decode_huf_table + HUF_init_dtable_usingweights. Returns the input
  // position after the table description.
  int _readHuffmanTable(Uint8List src, ByteData bd, int ip, int ipEnd) {
    if (ipEnd - ip < 1) zstdCorrupt('truncated Huffman table');
    final header = src[ip++];
    final w = _weights;
    int n;
    if (header >= 128) {
      n = header - 127;
      final bytes = (n + 1) >> 1;
      if (ipEnd - ip < bytes) zstdCorrupt('truncated Huffman table');
      for (var i = 0; i < n; i++) {
        final b = src[ip + (i >> 1)];
        w[i] = (i & 1) == 0 ? b >> 4 : b & 15;
      }
      ip += bytes;
    } else {
      if (ipEnd - ip < header || header == 0) {
        zstdCorrupt('truncated Huffman table');
      }
      n = _fseWeights(src, bd, ip, ip + header);
      ip += header;
    }
    // weights to code lengths
    var sum = 0;
    for (var i = 0; i < n; i++) {
      final x = w[i];
      if (x > 11) zstdCorrupt('invalid Huffman weight');
      if (x > 0) sum += 1 << (x - 1);
    }
    if (sum == 0) zstdCorrupt('invalid Huffman weights');
    final maxBits = _highBit(sum) + 1;
    if (maxBits > 11) zstdCorrupt('Huffman table too deep');
    final left = (1 << maxBits) - sum;
    if ((left & (left - 1)) != 0) zstdCorrupt('invalid Huffman weights');
    if (n + 1 > 256) zstdCorrupt('too many Huffman symbols');
    w[n] = _highBit(left) + 1;
    n++;
    final bits = _hufBits;
    final rankCount = Int32List(13);
    for (var i = 0; i < n; i++) {
      bits[i] = w[i] > 0 ? maxBits + 1 - w[i] : 0;
      rankCount[bits[i]]++;
    }
    // HUF_init_dtable: canonical codes, from the longest to the shortest
    final rankIdx = Int32List(13);
    rankIdx[maxBits] = 0;
    final t = _huf;
    for (var i = maxBits; i >= 1; i--) {
      rankIdx[i - 1] = rankIdx[i] + rankCount[i] * (1 << (maxBits - i));
    }
    if (rankIdx[0] != (1 << maxBits)) zstdCorrupt('invalid Huffman table');
    for (var i = 0; i < n; i++) {
      final b = bits[i];
      if (b == 0) continue;
      final code = rankIdx[b];
      final len = 1 << (maxBits - b);
      t.fillRange(code, code + len, i | (b << 8));
      rankIdx[b] = code + len;
    }
    _hufLog = maxBits;
    return ip;
  }

  // fse_decode_hufweights + FSE_decompress_interleaved2: decodes the
  // FSE compressed Huffman weights of src[ip, end) into _weights and
  // returns their number.
  int _fseWeights(Uint8List src, ByteData bd, int ip, int end) {
    final p = _readFseHeader(src, ip, end, 6, 15);
    final t = _wTable;
    _buildFse(_norm, _fseCount, _fseLog, t.symbol, t.nbBits, t.nextBase);
    t.log = _fseLog;
    _initBits(src, bd, p, end);
    var ptr = _bPtr, bits = _bBits, c = _bC;
    final start = _bStart;
    final log = t.log;
    final sym = t.symbol, nb = t.nbBits, nx = t.nextBase;
    final w = _weights;
    var s1 = (c << bits) >>> (64 - log);
    bits += log;
    var s2 = (c << bits) >>> (64 - log);
    bits += log;
    var n = 0;
    for (;;) {
      // reload
      if (ptr - start >= 8) {
        ptr -= bits >> 3;
        bits &= 7;
        c = bd.getUint64(ptr, Endian.little);
      } else if (ptr > start) {
        var k = bits >> 3;
        if (k > ptr - start) k = ptr - start;
        ptr -= k;
        bits -= k << 3;
        c = bd.getUint64(ptr, Endian.little);
      }
      if (n > 252) zstdCorrupt('too many Huffman weights');
      w[n++] = sym[s1];
      var b = nb[s1];
      s1 = nx[s1] + ((c << bits) >>> (64 - b));
      bits += b;
      if ((ptr - start) * 8 + 64 - bits < 0) {
        w[n++] = sym[s2];
        break;
      }
      w[n++] = sym[s2];
      b = nb[s2];
      s2 = nx[s2] + ((c << bits) >>> (64 - b));
      bits += b;
      if ((ptr - start) * 8 + 64 - bits < 0) {
        w[n++] = sym[s1];
        break;
      }
    }
    return n;
  }

  // HUF_decompress_1stream: decodes the Huffman stream src[start, end)
  // to _lit[op, opEnd); the stream must be consumed exactly.
  void _hufStream(
      Uint8List src, ByteData bd, int start, int end, int op, int opEnd) {
    _initBits(src, bd, start, end);
    var ptr = _bPtr, bits = _bBits, c = _bC;
    final log = _hufLog;
    final shift = 64 - log;
    final t = _huf;
    final lit = _lit;
    final limit = start + 8;
    // four symbols (at most 44 bits) per reload
    while (opEnd - op >= 4) {
      if (ptr >= limit) {
        ptr -= bits >> 3;
        bits &= 7;
        c = bd.getUint64(ptr, Endian.little);
      } else if (ptr > start) {
        var k = bits >> 3;
        if (k > ptr - start) k = ptr - start;
        ptr -= k;
        bits -= k << 3;
        c = bd.getUint64(ptr, Endian.little);
      }
      var e = t[(c << bits) >>> shift];
      lit[op] = e;
      bits += e >> 8;
      e = t[(c << bits) >>> shift];
      lit[op + 1] = e;
      bits += e >> 8;
      e = t[(c << bits) >>> shift];
      lit[op + 2] = e;
      bits += e >> 8;
      e = t[(c << bits) >>> shift];
      lit[op + 3] = e;
      bits += e >> 8;
      op += 4;
      if (bits > 64) break;
    }
    while (op < opEnd && bits <= 64) {
      if (ptr >= limit) {
        ptr -= bits >> 3;
        bits &= 7;
        c = bd.getUint64(ptr, Endian.little);
      } else if (ptr > start) {
        var k = bits >> 3;
        if (k > ptr - start) k = ptr - start;
        ptr -= k;
        bits -= k << 3;
        c = bd.getUint64(ptr, Endian.little);
      }
      final e = t[(c << bits) >>> shift];
      lit[op++] = e;
      bits += e >> 8;
    }
    if (op != opEnd || ptr != start || bits != 64) {
      zstdCorrupt('Huffman stream not consumed exactly');
    }
  }

  // decompress_sequences + execute_sequences, one sequence at a time.
  int _sequences(
      Uint8List src,
      ByteData bd,
      int ip,
      int ipEnd,
      int nbSeq,
      Uint8List lit,
      int litPos,
      int litEnd,
      Uint8List out,
      int histStart,
      int op,
      int opEnd) {
    final llT = _ll!, ofT = _of!, mlT = _ml!;
    final llBase = llT.base, llAdd = llT.addBits, llNb = llT.nbBits;
    final llNx = llT.nextBase;
    final ofBase = ofT.base, ofAdd = ofT.addBits, ofNb = ofT.nbBits;
    final ofNx = ofT.nextBase;
    final mlBase = mlT.base, mlAdd = mlT.addBits, mlNb = mlT.nbBits;
    final mlNx = mlT.nextBase;

    _initBits(src, bd, ip, ipEnd);
    var ptr = _bPtr, bits = _bBits, c = _bC;
    final start = _bStart;
    final limit = start + 8;
    var rep0 = _rep0, rep1 = _rep1, rep2 = _rep2;

    // initial states: LL, OF, ML
    var n = llT.log;
    var llS = n == 0 ? 0 : (c << bits) >>> (64 - n);
    bits += n;
    n = ofT.log;
    var ofS = n == 0 ? 0 : (c << bits) >>> (64 - n);
    bits += n;
    n = mlT.log;
    var mlS = n == 0 ? 0 : (c << bits) >>> (64 - n);
    bits += n;

    for (var i = nbSeq; i > 0; i--) {
      if (ptr >= limit) {
        ptr -= bits >> 3;
        bits &= 7;
        c = bd.getUint64(ptr, Endian.little);
      } else if (ptr > start) {
        var k = bits >> 3;
        if (k > ptr - start) k = ptr - start;
        ptr -= k;
        bits -= k << 3;
        c = bd.getUint64(ptr, Endian.little);
      }
      // offset, then match length (at most 31 + 16 bits)
      var ofv = ofBase[ofS];
      n = ofAdd[ofS];
      if (n != 0) {
        ofv += (c << bits) >>> (64 - n);
        bits += n;
      }
      var ml = mlBase[mlS];
      n = mlAdd[mlS];
      if (n != 0) {
        ml += (c << bits) >>> (64 - n);
        bits += n;
      }
      if (ptr >= limit) {
        ptr -= bits >> 3;
        bits &= 7;
        c = bd.getUint64(ptr, Endian.little);
      } else if (ptr > start) {
        var k = bits >> 3;
        if (k > ptr - start) k = ptr - start;
        ptr -= k;
        bits -= k << 3;
        c = bd.getUint64(ptr, Endian.little);
      }
      // literals length, then the state updates (at most 16 + 26 bits)
      var ll = llBase[llS];
      n = llAdd[llS];
      if (n != 0) {
        ll += (c << bits) >>> (64 - n);
        bits += n;
      }
      if (i > 1) {
        n = llNb[llS];
        llS = llNx[llS] + (n == 0 ? 0 : (c << bits) >>> (64 - n));
        bits += n;
        n = mlNb[mlS];
        mlS = mlNx[mlS] + (n == 0 ? 0 : (c << bits) >>> (64 - n));
        bits += n;
        n = ofNb[ofS];
        ofS = ofNx[ofS] + (n == 0 ? 0 : (c << bits) >>> (64 - n));
        bits += n;
      }

      // compute_offset
      int offset;
      if (ofv > 3) {
        offset = ofv - 3;
        rep2 = rep1;
        rep1 = rep0;
        rep0 = offset;
      } else {
        final idx = ll == 0 ? ofv : ofv - 1;
        if (idx == 0) {
          offset = rep0;
        } else {
          offset = idx == 1
              ? rep1
              : idx == 2
                  ? rep2
                  : rep0 - 1;
          if (offset == 0) zstdCorrupt('zero repeat offset');
          if (idx > 1) rep2 = rep1;
          rep1 = rep0;
          rep0 = offset;
        }
      }

      // execute: literals, then the match
      if (ll > litEnd - litPos) zstdCorrupt('literals length too large');
      if (ll + ml > opEnd - op) zstdCorrupt('block output too large');
      if (ll < 16) {
        for (var j = 0; j < ll; j++) {
          out[op + j] = lit[litPos + j];
        }
      } else {
        out.setRange(op, op + ll, lit, litPos);
      }
      op += ll;
      litPos += ll;
      if (offset > op - histStart) zstdCorrupt('match offset too far back');
      var from = op - offset;
      if (ml < 16) {
        for (var j = 0; j < ml; j++) {
          out[op + j] = out[from + j];
        }
        op += ml;
      } else if (offset >= ml) {
        out.setRange(op, op + ml, out, from);
        op += ml;
      } else {
        final end = op + ml;
        if (offset < 8) {
          while (op < end) {
            out[op++] = out[from++];
          }
        } else {
          while (op < end) {
            var k = op - from;
            if (k > end - op) k = end - op;
            out.setRange(op, op + k, out, from);
            op += k;
          }
        }
      }
    }
    // the bitstream must be consumed exactly
    if (ptr >= limit) {
      ptr -= bits >> 3;
      bits &= 7;
    } else if (ptr > start) {
      var k = bits >> 3;
      if (k > ptr - start) k = ptr - start;
      ptr -= k;
      bits -= k << 3;
    }
    if (ptr != start || bits != 64) {
      zstdCorrupt('sequences bitstream not consumed exactly');
    }
    _rep0 = rep0;
    _rep1 = rep1;
    _rep2 = rep2;
    // last literals
    final rest = litEnd - litPos;
    if (rest > opEnd - op) zstdCorrupt('block output too large');
    out.setRange(op, op + rest, lit, litPos);
    return op + rest;
  }
}
