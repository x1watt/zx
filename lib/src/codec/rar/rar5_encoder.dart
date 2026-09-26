// The RAR5 compressor, written for this package from the format that the
// RAR5 decoder reads (rar5_decoder.dart, after libarchive's rar5 reader):
// blocks with Huffman tables, literals, LZ matches with the length bonus
// for long distances, the four repeat distances, the "repeat last match"
// code and the filters: E8E9 for x86 executables (ELF and PE files) and
// DELTA for data whose bytes are best predicted by the byte 1 to 4
// positions back (sampled audio, raw images).
//
// Matches come from the LZMA SDK match finder (lz_find.dart, public
// domain): hash chains for the fast levels, binary trees for the others,
// with a greedy parse (level 1) or a lazy parse with one position of look
// ahead (levels 2 to 5).
//
// A solid stream is one match finder over the concatenation of the files;
// each file ends its own block sequence, and matches never cross the end
// of a file.

import 'dart:math' as math;
import 'dart:typed_data';

import '../../io/streams.dart';
import '../lzma/lz_find.dart';
import 'rar_huffman.dart';

const int _huffBC = 20;
const int _huffNC = 306;
const int _huffDC = 64;
const int _huffLDC = 16;
const int _huffRC = 44;

/// The longest match length the format codes (length slot 43 plus its 9
/// extra bits, plus 2).
const int rar5MaxMatchLen = 4097;

// token kinds
const int _tLit = 0;
const int _tMatch = 1;
const int _tRep = 2;
const int _tLast = 3;
const int _tFilter = 4;

// FILTER_TYPE
const int _filterDelta = 0;
const int _filterE8E9 = 2;

/// Settings of one compression level.
final class Rar5EncoderLevel {
  final bool binaryTree;
  final int cutValue;
  final int niceLen;
  final bool lazy;
  const Rar5EncoderLevel(
      this.binaryTree, this.cutValue, this.niceLen, this.lazy);

  /// The settings of methods 1 to 5.
  static Rar5EncoderLevel of(int method) {
    switch (method) {
      case 1:
        return const Rar5EncoderLevel(false, 4, 32, false);
      case 2:
        return const Rar5EncoderLevel(false, 16, 48, true);
      case 3:
        return const Rar5EncoderLevel(true, 24, 64, true);
      case 4:
        return const Rar5EncoderLevel(true, 48, 128, true);
      default:
        return const Rar5EncoderLevel(true, 96, 273, true);
    }
  }
}

/// MSB first bit writer into a growable buffer.
final class _BitWriter {
  Uint8List buf = Uint8List(1 << 16);
  int len = 0;
  int _acc = 0;
  int _n = 0;

  void reset() {
    len = 0;
    _acc = 0;
    _n = 0;
  }

  @pragma('vm:prefer-inline')
  void bits(int value, int count) {
    if (count == 0) return;
    _acc = ((_acc << count) | (value & ((1 << count) - 1))) & 0xFFFFFFFFFF;
    _n += count;
    while (_n >= 8) {
      _n -= 8;
      if (len == buf.length) _grow();
      buf[len++] = (_acc >> _n) & 0xFF;
    }
  }

  void _grow() {
    final nb = Uint8List(buf.length * 2);
    nb.setRange(0, len, buf);
    buf = nb;
  }

  /// Flushes the partial byte; returns the number of bits used in the
  /// last byte (1 to 8), 8 when nothing is partial.
  int finish() {
    if (_n == 0) return 8;
    final used = _n;
    bits(0, 8 - _n);
    return used;
  }
}

/// A RAR5 encoder; one instance per archive (its match finder is reused).
final class Rar5Encoder {
  final int method;
  final int dictSize;
  final Rar5EncoderLevel _lv;
  final CMatchFinder _mf = CMatchFinder();
  final Uint32List _matches = Uint32List(2 * 300);
  bool _mfReady = false;

  // absolute position of the next byte in the current stream
  int _pos = 0;

  // encoder state that the decoder mirrors
  final Int64List _reps = Int64List(4);
  int _lastLen = 0;
  int _lastDist = 0;

  // tokens of the current block
  static const int _maxTokens = 1 << 16;
  final Uint8List _tKind = Uint8List(_maxTokens);
  final Int32List _tA = Int32List(_maxTokens);
  final Int64List _tB = Int64List(_maxTokens);
  int _nTok = 0;
  int _blockBytes = 0;

  final _BitWriter _bw = _BitWriter();
  final Uint32List _freqNC = Uint32List(_huffNC);
  final Uint32List _freqDC = Uint32List(_huffDC);
  final Uint32List _freqLDC = Uint32List(_huffLDC);
  final Uint32List _freqRC = Uint32List(_huffRC);
  final Uint8List _lenNC = Uint8List(_huffNC);
  final Uint8List _lenDC = Uint8List(_huffDC);
  final Uint8List _lenLDC = Uint8List(_huffLDC);
  final Uint8List _lenRC = Uint8List(_huffRC);
  final Uint32List _codeNC = Uint32List(_huffNC);
  final Uint32List _codeDC = Uint32List(_huffDC);
  final Uint32List _codeLDC = Uint32List(_huffLDC);
  final Uint32List _codeRC = Uint32List(_huffRC);

  Rar5Encoder(this.method, this.dictSize) : _lv = Rar5EncoderLevel.of(method);

  /// Starts a new stream (a non solid file, or the first file of a solid
  /// stream) read from [src].
  void start(InStream src,
      {int expectedSize = -1, List<int>? fileSizes, bool filters = true}) {
    _filterStream = null;
    if (filters && fileSizes != null) {
      var limit = dictSize >> 1;
      if (limit > 0x400000) limit = 0x400000;
      final fs = _FilterStream(src, fileSizes, limit);
      _filterStream = fs;
      src = fs;
    }
    final mf = _mf;
    mf.btMode = _lv.binaryTree ? 1 : 0;
    mf.numHashBytes = 4;
    mf.cutValue = _lv.cutValue;
    mf.expectedDataSize = expectedSize;
    if (!mf.create(dictSize, 0, _lv.niceLen, rar5MaxMatchLen + 1)) {
      throw const SevenZipException(
          'RAR5: bad encoder settings', SevenZipError.unsupported);
    }
    mf.setStream(src);
    mf.init();
    _mfReady = true;
    _pos = 0;
    _reps.fillRange(0, 4, 0);
    _lastLen = 0;
    _lastDist = 0;
  }

  _FilterStream? _filterStream;

  // the next filter block at or after [_pos], if any, and emits the
  // filters that start at [_pos]
  int _nextBoundary(int fileEnd) {
    final fs = _filterStream;
    if (fs == null) return fileEnd;
    final q = fs.filters;
    while (q.isNotEmpty && q.first.start < _pos) {
      q.removeAt(0);
    }
    while (q.isNotEmpty && q.first.start == _pos) {
      final f = q.removeAt(0);
      final n = _nTok++;
      _tKind[n] = _tFilter;
      _tA[n] = f.length;
      _tB[n] = f.type | (f.channels << 8);
    }
    if (q.isNotEmpty && q.first.start < fileEnd) return q.first.start;
    return fileEnd;
  }

  /// Releases the match finder memory.
  void free() {
    _mf.free();
    _mfReady = false;
  }

  /// Encodes the next [size] bytes of the stream into [out] as the packed
  /// data of one file.
  void encodeFile(int size, OutStream out) {
    if (!_mfReady) throw StateError('start() not called');
    if (size == 0) return;
    final fileEnd = _pos + size;
    _nTok = 0;
    _blockBytes = 0;
    final mf = _mf;
    final lazy = _lv.lazy;
    final niceLen = _lv.niceLen;

    // the current candidate (for the position _pos)
    var haveCur = false;
    var curLen = 0;
    var curDist = 0;
    var curRep = -1;

    while (_pos < fileEnd) {
      final bound = _nextBoundary(fileEnd);
      if (!haveCur) {
        _find(bound);
        curLen = _fLen;
        curDist = _fDist;
        curRep = _fRep;
      }
      haveCur = false;
      if (curLen < 2) {
        _literal(mf.bufBase[mf.buffer - 1]);
        _pos++;
        _blockCheck(out, false);
        continue;
      }
      if (lazy && curLen < niceLen && _pos + 1 < bound) {
        final litByte = mf.bufBase[mf.buffer - 1];
        _pos++;
        _find(bound);
        _pos--;
        if (_better(_fLen, _fDist, _fRep, curLen, curDist, curRep)) {
          _literal(litByte);
          _pos++;
          curLen = _fLen;
          curDist = _fDist;
          curRep = _fRep;
          haveCur = true;
          _blockCheck(out, false);
          continue;
        }
        _emit(curLen, curDist, curRep);
        if (curLen > 2) mf.skip(curLen - 2);
        _pos += curLen;
      } else {
        _emit(curLen, curDist, curRep);
        if (curLen > 1) mf.skip(curLen - 1);
        _pos += curLen;
      }
      _blockCheck(out, false);
    }
    _flushBlock(out, true);
  }

  // whether the next candidate is worth a literal first
  static bool _better(
      int nLen, int nDist, int nRep, int cLen, int cDist, int cRep) {
    if (nLen < 2) return false;
    if (nRep >= 0 && cRep < 0) return nLen >= cLen;
    if (nLen > cLen + 1) return true;
    if (nLen == cLen + 1) {
      if (nRep >= 0) return true;
      return _distCost(nDist) <= _distCost(cDist) + 4;
    }
    if (nLen == cLen && cRep < 0 && nRep < 0) {
      return _distCost(nDist) + 7 < _distCost(cDist);
    }
    return false;
  }

  // a rough cost in bits of coding a distance
  static int _distCost(int dist) {
    var b = 0;
    var d = dist;
    while (d > 1) {
      d >>= 1;
      b++;
    }
    return b;
  }

  static int _bonus(int dist) =>
      dist > 0x100 ? (dist > 0x2000 ? (dist > 0x40000 ? 3 : 2) : 1) : 0;

  // results of _find
  int _fLen = 0;
  int _fDist = 0;
  int _fRep = -1;

  // gets the matches of the position _pos (advancing the match finder by
  // one) and picks the best candidate
  void _find(int fileEnd) {
    final mf = _mf;
    final avail = mf.numAvailableBytes;
    final numPairs = mf.getMatches(_matches);
    final buf = mf.bufBase;
    final p1 = mf.buffer - 1;
    var maxLen = fileEnd - _pos;
    if (maxLen > avail) maxLen = avail;
    if (maxLen > rar5MaxMatchLen) maxLen = rar5MaxMatchLen;

    var bestLen = 0;
    var bestDist = 0;
    if (numPairs > 0) {
      // the longest match, extended past the match finder limit
      var len = _matches[numPairs - 2];
      final dist = _matches[numPairs - 1] + 1;
      if (len > maxLen) len = maxLen;
      if (len == _lv.niceLen && len < maxLen) {
        while (len < maxLen && buf[p1 + len] == buf[p1 + len - dist]) {
          len++;
        }
      }
      // the longest match that is long enough for its distance bonus
      if (len >= 2 + _bonus(dist)) {
        bestLen = len;
        bestDist = dist;
      } else {
        for (var i = numPairs - 4; i >= 0; i -= 2) {
          var l = _matches[i];
          if (l > maxLen) l = maxLen;
          final d = _matches[i + 1] + 1;
          if (l >= 2 + _bonus(d)) {
            bestLen = l;
            bestDist = d;
            break;
          }
        }
      }
      // a shorter distance with almost the same length is cheaper
      for (var i = numPairs - 4; i >= 0; i -= 2) {
        var l = _matches[i];
        if (l > maxLen) l = maxLen;
        final d = _matches[i + 1] + 1;
        if (l + 1 >= bestLen &&
            l >= 2 + _bonus(d) &&
            _distCost(d) + 6 < _distCost(bestDist)) {
          bestLen = l;
          bestDist = d;
        }
      }
    }
    // the repeat distances
    var repLen = 0;
    var repIdx = -1;
    if (maxLen >= 2) {
      final reps = _reps;
      for (var r = 0; r < 4; r++) {
        final d = reps[r];
        if (d <= 0 || d > _pos || d > dictSize) continue;
        if (buf[p1] != buf[p1 - d] || buf[p1 + 1] != buf[p1 + 1 - d]) {
          continue;
        }
        var l = 2;
        while (l < maxLen && buf[p1 + l] == buf[p1 + l - d]) {
          l++;
        }
        if (l > repLen) {
          repLen = l;
          repIdx = r;
        }
      }
    }
    if (repIdx >= 0 &&
        (repLen + 1 >= bestLen ||
            (repLen + 2 >= bestLen && _distCost(bestDist) > 10) ||
            (repLen + 3 >= bestLen && _distCost(bestDist) > 16))) {
      _fLen = repLen;
      _fDist = _reps[repIdx];
      _fRep = repIdx;
      return;
    }
    _fLen = bestLen;
    _fDist = bestDist;
    _fRep = -1;
  }

  void _literal(int b) {
    final n = _nTok++;
    _tKind[n] = _tLit;
    _tA[n] = b;
    _blockBytes++;
  }

  // records a match and updates the state the decoder keeps
  void _emit(int len, int dist, int rep) {
    final n = _nTok++;
    final reps = _reps;
    if (rep >= 0) {
      if (rep == 0 && len == _lastLen && dist == _lastDist) {
        _tKind[n] = _tLast;
      } else {
        _tKind[n] = _tRep;
        _tA[n] = len;
        _tB[n] = rep;
        // dist_cache_touch
        final d = reps[rep];
        for (var i = rep; i > 0; i--) {
          reps[i] = reps[i - 1];
        }
        reps[0] = d;
        _lastLen = len;
      }
    } else {
      _tKind[n] = _tMatch;
      _tA[n] = len;
      _tB[n] = dist;
      reps[3] = reps[2];
      reps[2] = reps[1];
      reps[1] = reps[0];
      reps[0] = dist;
      _lastLen = len;
    }
    _lastDist = reps[0];
    _blockBytes += len;
  }

  void _blockCheck(OutStream out, bool last) {
    if (_nTok >= _maxTokens - 2 || _blockBytes >= (1 << 20)) {
      _flushBlock(out, last);
    }
  }

  // decode_code_length inverse: (slot, extra bits, extra value)
  static int _lenSlot(int len) {
    final l = len - 2;
    if (l < 8) return l;
    var lbits = 0;
    while ((l >> lbits) >= 8) {
      lbits++;
    }
    return 4 * (lbits + 1) + ((l >> lbits) - 4);
  }

  static int _slotBits(int slot) => slot < 8 ? 0 : slot ~/ 4 - 1;

  static int _distSlot(int dist) {
    final d = dist - 1;
    if (d < 4) return d;
    var dbits = 0;
    while ((d >> dbits) >= 4) {
      dbits++;
    }
    return 2 * (dbits + 1) + ((d >> dbits) & 1);
  }

  static int _distBits(int slot) => slot < 4 ? 0 : slot ~/ 2 - 1;

  void _countTokens() {
    _freqNC.fillRange(0, _huffNC, 0);
    _freqDC.fillRange(0, _huffDC, 0);
    _freqLDC.fillRange(0, _huffLDC, 0);
    _freqRC.fillRange(0, _huffRC, 0);
    for (var i = 0; i < _nTok; i++) {
      switch (_tKind[i]) {
        case _tLit:
          _freqNC[_tA[i]]++;
        case _tLast:
          _freqNC[257]++;
        case _tFilter:
          _freqNC[256]++;
        case _tRep:
          _freqNC[258 + _tB[i]]++;
          _freqRC[_lenSlot(_tA[i])]++;
        default:
          final dist = _tB[i];
          final len = _tA[i] - _bonus(dist);
          _freqNC[262 + _lenSlot(len)]++;
          final ds = _distSlot(dist);
          _freqDC[ds]++;
          if (_distBits(ds) >= 4) _freqLDC[(dist - 1) & 15]++;
      }
    }
  }

  void _flushBlock(OutStream out, bool last) {
    if (_nTok == 0 && !last) return;
    _countTokens();
    rarHuffmanLengths(_freqNC, _lenNC, _huffNC, 15);
    rarHuffmanLengths(_freqDC, _lenDC, _huffDC, 15);
    rarHuffmanLengths(_freqLDC, _lenLDC, _huffLDC, 15);
    rarHuffmanLengths(_freqRC, _lenRC, _huffRC, 15);
    rarHuffmanCodes(_lenNC, _codeNC, _huffNC);
    rarHuffmanCodes(_lenDC, _codeDC, _huffDC);
    rarHuffmanCodes(_lenLDC, _codeLDC, _huffLDC);
    rarHuffmanCodes(_lenRC, _codeRC, _huffRC);

    final bw = _bw..reset();
    _writeTables(bw);
    for (var i = 0; i < _nTok; i++) {
      switch (_tKind[i]) {
        case _tLit:
          final s = _tA[i];
          bw.bits(_codeNC[s], _lenNC[s]);
        case _tLast:
          bw.bits(_codeNC[257], _lenNC[257]);
        case _tFilter:
          bw.bits(_codeNC[256], _lenNC[256]);
          // parse_filter: block start (0: here), block length, type
          _filterData(bw, 0);
          _filterData(bw, _tA[i]);
          final t = _tB[i] & 0xFF;
          bw.bits(t, 3);
          if (t == _filterDelta) bw.bits((_tB[i] >> 8) - 1, 5);
        case _tRep:
          final s = 258 + _tB[i];
          bw.bits(_codeNC[s], _lenNC[s]);
          _writeLen(bw, _tA[i], _codeRC, _lenRC, 0);
        default:
          final dist = _tB[i];
          _writeLen(bw, _tA[i] - _bonus(dist), _codeNC, _lenNC, 262);
          final ds = _distSlot(dist);
          bw.bits(_codeDC[ds], _lenDC[ds]);
          final dbits = _distBits(ds);
          if (dbits > 0) {
            final extra = (dist - 1) & ((1 << dbits) - 1);
            if (dbits >= 4) {
              if (dbits > 4) bw.bits(extra >> 4, dbits - 4);
              final low = extra & 15;
              bw.bits(_codeLDC[low], _lenLDC[low]);
            } else {
              bw.bits(extra, dbits);
            }
          }
      }
    }
    final lastBits = bw.finish();
    final size = bw.len;
    final byteCount = size < 0x100 ? 0 : (size < 0x10000 ? 1 : 2);
    final flags = 0x80 | (last ? 0x40 : 0) | (byteCount << 3) | (lastBits - 1);
    final hdr = Uint8List(2 + byteCount + 1);
    hdr[0] = flags;
    for (var i = 0; i <= byteCount; i++) {
      hdr[2 + i] = (size >> (8 * i)) & 0xFF;
    }
    var cks = 0x5A ^ flags;
    for (var i = 0; i < 3; i++) {
      cks ^= (size >> (8 * i)) & 0xFF;
    }
    hdr[1] = cks & 0xFF;
    out.write(hdr, 0, hdr.length);
    out.write(bw.buf, 0, size);
    _nTok = 0;
    _blockBytes = 0;
  }

  // parse_filter_data inverse: 2 bits of byte count, then the bytes
  static void _filterData(_BitWriter bw, int v) {
    var n = 1;
    while (n < 4 && (v >> (8 * n)) != 0) {
      n++;
    }
    bw.bits(n - 1, 2);
    for (var i = 0; i < n; i++) {
      bw.bits((v >> (8 * i)) & 0xFF, 8);
    }
  }

  static void _writeLen(
      _BitWriter bw, int len, Uint32List codes, Uint8List lens, int base) {
    final slot = _lenSlot(len);
    bw.bits(codes[base + slot], lens[base + slot]);
    final lbits = _slotBits(slot);
    if (lbits > 0) bw.bits((len - 2) & ((1 << lbits) - 1), lbits);
  }

  // the table section of a block (parse_tables inverse)
  void _writeTables(_BitWriter bw) {
    final all = Uint8List(_huffNC + _huffDC + _huffLDC + _huffRC);
    all.setRange(0, _huffNC, _lenNC);
    all.setRange(_huffNC, _huffNC + _huffDC, _lenDC);
    all.setRange(_huffNC + _huffDC, _huffNC + _huffDC + _huffLDC, _lenLDC);
    all.setRange(_huffNC + _huffDC + _huffLDC, all.length, _lenRC);

    // run length coding of the lengths: (symbol, extra bits count, value)
    final sym = <int>[];
    final extraN = <int>[];
    final extraV = <int>[];
    var i = 0;
    while (i < all.length) {
      final v = all[i];
      var run = 1;
      while (i + run < all.length && all[i + run] == v) {
        run++;
      }
      if (v == 0 && run >= 3) {
        var r = run;
        while (r >= 3) {
          if (r >= 11) {
            final n = r > 138 ? 138 : r;
            sym.add(19);
            extraN.add(7);
            extraV.add(n - 11);
            r -= n;
          } else {
            sym.add(18);
            extraN.add(3);
            extraV.add(r - 3);
            r = 0;
          }
        }
        for (var k = 0; k < r; k++) {
          sym.add(0);
          extraN.add(0);
          extraV.add(0);
        }
        i += run;
        continue;
      }
      // the value once, then repeats of the previous one
      sym.add(v);
      extraN.add(0);
      extraV.add(0);
      var r = run - 1;
      while (r >= 3) {
        if (r >= 11) {
          final n = r > 138 ? 138 : r;
          sym.add(17);
          extraN.add(7);
          extraV.add(n - 11);
          r -= n;
        } else {
          final n = r > 10 ? 10 : r;
          sym.add(16);
          extraN.add(3);
          extraV.add(n - 3);
          r -= n;
        }
      }
      for (var k = 0; k < r; k++) {
        sym.add(v);
        extraN.add(0);
        extraV.add(0);
      }
      i += run;
    }
    final freqBC = Uint32List(_huffBC);
    for (final s in sym) {
      freqBC[s]++;
    }
    final lenBC = Uint8List(_huffBC);
    final codeBC = Uint32List(_huffBC);
    rarHuffmanLengths(freqBC, lenBC, _huffBC, 15);
    rarHuffmanCodes(lenBC, codeBC, _huffBC);
    // the 20 bit lengths as nibbles, 15 escaped, zero runs as 15 + count
    var k = 0;
    while (k < _huffBC) {
      final l = lenBC[k];
      if (l == 0) {
        var run = 1;
        while (k + run < _huffBC && lenBC[k + run] == 0) {
          run++;
        }
        if (run >= 3) {
          if (run > 17) run = 17;
          bw.bits(15, 4);
          bw.bits(run - 2, 4);
          k += run;
          continue;
        }
        bw.bits(0, 4);
        k++;
        continue;
      }
      if (l == 15) {
        bw.bits(15, 4);
        bw.bits(0, 4);
      } else {
        bw.bits(l, 4);
      }
      k++;
    }
    for (var j = 0; j < sym.length; j++) {
      final s = sym[j];
      bw.bits(codeBC[s], lenBC[s]);
      if (extraN[j] > 0) bw.bits(extraV[j], extraN[j]);
    }
  }
}

/// A filter block the decoder has to run.
final class _FilterBlock {
  final int start; // absolute position in the stream
  final int length;
  final int type;
  final int channels;
  _FilterBlock(this.start, this.length, this.type, this.channels);
}

/// Applies the forward transform of the filters to the input, file by
/// file, and records the filter blocks for the encoder.
final class _FilterStream implements InStream {
  final InStream base;
  final List<int> fileSizes;
  final int blockLimit;
  final List<_FilterBlock> filters = [];

  int _file = 0;
  int _fileStart = 0;
  int _pos = 0; // absolute position of the next byte read from base
  int _type = -1; // filter of the current file, -1 none
  int _channels = 0;

  Uint8List _buf = Uint8List(0);
  Uint8List _tmp = Uint8List(0);
  int _bufPos = 0;
  int _bufLen = 0;

  _FilterStream(this.base, this.fileSizes, this.blockLimit);

  @override
  int read(Uint8List buf, int off, int len) {
    if (_bufPos == _bufLen && !_fill()) return 0;
    final n = len < _bufLen - _bufPos ? len : _bufLen - _bufPos;
    buf.setRange(off, off + n, _buf, _bufPos);
    _bufPos += n;
    return n;
  }

  // reads and transforms the next block
  bool _fill() {
    while (_file < fileSizes.length && _pos >= _fileStart + fileSizes[_file]) {
      _fileStart += fileSizes[_file];
      _file++;
      _type = -1;
    }
    if (_file >= fileSizes.length) {
      // past the known files: pass the rest through
      if (_buf.length < 1 << 16) _buf = Uint8List(1 << 16);
      final n = base.read(_buf, 0, _buf.length);
      _bufPos = 0;
      _bufLen = n;
      _pos += n;
      return n > 0;
    }
    final fileEnd = _fileStart + fileSizes[_file];
    if (_pos == _fileStart && blockLimit >= 1024) {
      _analyze(fileEnd - _fileStart);
    }
    var want = fileEnd - _pos;
    final limit = _type >= 0 ? blockLimit : 1 << 16;
    if (want > limit) want = limit;
    if (_buf.length < want) _buf = Uint8List(want < 1 << 16 ? 1 << 16 : want);
    final n = _readFully(_buf, 0, want);
    _bufPos = 0;
    _bufLen = n;
    if (n == 0) return false;
    if (_type >= 0 && n >= 16) {
      if (_type == _filterE8E9) {
        _e8e9(_buf, n, _pos - _fileStart);
      } else {
        _delta(_buf, n, _channels);
      }
      filters.add(_FilterBlock(_pos, n, _type, _channels));
    }
    _pos += n;
    return true;
  }

  // chooses the filter of a file from its first bytes
  void _analyze(int fileSize) {
    _type = -1;
    if (fileSize < 1024) return;
    var sample = fileSize < 1 << 16 ? fileSize : 1 << 16;
    if (sample > blockLimit) sample = blockLimit;
    // the sample is read into the block buffer and kept for the first
    // block: peek through a small read ahead
    if (_tmp.length < sample) _tmp = Uint8List(sample);
    final n = _readFully(_tmp, 0, sample);
    _peeked = n;
    if (_isX86Executable(_tmp, n)) {
      _type = _filterE8E9;
      return;
    }
    final ch = _deltaChannels(_tmp, n);
    if (ch > 0) {
      _type = _filterDelta;
      _channels = ch;
    }
  }

  // bytes of the file start already read by _analyze
  int _peeked = 0;

  // reads from [base], first the bytes [_analyze] looked at
  int _readFully(Uint8List b, int off, int len) {
    var done = 0;
    if (_peeked > 0 && identical(b, _buf)) {
      final n = _peeked < len ? _peeked : len;
      b.setRange(off, off + n, _tmp, 0);
      if (n < _peeked) {
        _tmp.setRange(0, _peeked - n, _tmp, n);
      }
      _peeked -= n;
      done = n;
    }
    while (done < len) {
      final n = base.read(b, off + done, len - done);
      if (n == 0) break;
      done += n;
    }
    return done;
  }

  static bool _isX86Executable(Uint8List b, int n) {
    if (n < 64) return false;
    if (b[0] == 0x7F && b[1] == 0x45 && b[2] == 0x4C && b[3] == 0x46) {
      final machine = b[5] == 2 ? (b[18] << 8) | b[19] : b[18] | (b[19] << 8);
      return machine == 3 || machine == 0x3E;
    }
    return b[0] == 0x4D && b[1] == 0x5A;
  }

  // order 0 entropy (bits per byte) of [n] values in [counts]
  static double _entropy(Int32List counts, int n) {
    var h = 0.0;
    for (final c in counts) {
      if (c == 0) continue;
      final p = c / n;
      h -= p * _log2(p);
    }
    return h;
  }

  static double _log2(double x) => math.log(x) / math.ln2;

  // the number of channels (1 to 4) of a delta filter worth using, or 0
  static int _deltaChannels(Uint8List b, int n) {
    final counts = Int32List(256);
    for (var i = 0; i < n; i++) {
      counts[b[i]]++;
    }
    final hRaw = _entropy(counts, n);
    if (hRaw < 5.0) return 0;
    var best = 0;
    var bestH = hRaw - 1.5;
    for (var ch = 1; ch <= 4; ch++) {
      counts.fillRange(0, 256, 0);
      for (var i = ch; i < n; i++) {
        counts[(b[i] - b[i - ch]) & 0xFF]++;
      }
      final h = _entropy(counts, n - ch);
      if (h < bestH) {
        bestH = h;
        best = ch;
      }
    }
    return best;
  }

  // the forward E8E9 transform of run_e8e9_filter ([rel]: the position
  // of the block in its file)
  static void _e8e9(Uint8List b, int len, int rel) {
    const fileSize = 0x1000000;
    for (var i = 0; i < len - 4;) {
      final c = b[i++];
      if (c == 0xE8 || c == 0xE9) {
        final offset = (i + rel) % fileSize;
        var o = b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24);
        if (o >= 0x80000000) o -= 0x100000000;
        int s;
        if (o >= -offset && o < fileSize - offset) {
          s = o + offset;
        } else if (o >= fileSize - offset && o < fileSize) {
          s = o - fileSize;
        } else {
          s = o;
        }
        s &= 0xFFFFFFFF;
        b[i] = s & 0xFF;
        b[i + 1] = (s >> 8) & 0xFF;
        b[i + 2] = (s >> 16) & 0xFF;
        b[i + 3] = (s >> 24) & 0xFF;
        i += 4;
      }
    }
  }

  // the forward DELTA transform of run_delta_filter
  void _delta(Uint8List b, int len, int channels) {
    if (_tmp.length < len) _tmp = Uint8List(len);
    final t = _tmp;
    var dst = 0;
    for (var ch = 0; ch < channels; ch++) {
      var prev = 0;
      for (var i = ch; i < len; i += channels) {
        final v = b[i];
        t[dst++] = (prev - v) & 0xFF;
        prev = v;
      }
    }
    b.setRange(0, len, t);
  }
}
