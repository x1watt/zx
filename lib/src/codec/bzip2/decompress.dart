// Decompression: port of decompress.c (BZ2_decompress) and of the
// decompression half of bzlib.c (BZ2_bzDecompress,
// unRLE_obuf_to_output_FAST) of bzip2 1.0.8, as a pull stream.
// bzip2/libbzip2 is Copyright (C) 1996-2019 Julian Seward, under the bzip2
// license (BSD style, see LICENSE).
//
// BZ2_decompress is a resumable state machine because libbzip2 is pushed
// its input; this decoder pulls its input from an InStream, so the same
// sequence of reads and checks runs straight through and a missing byte is
// an unexpected end. Only the fast (tt) output path of libbzip2 is ported,
// not the "small" (ll16/ll4) one, which gives the same bytes with less
// memory. The concatenation of streams follows bzip2.c (uncompressStream):
// after the end of a stream another stream may follow; anything else is
// data after the end.

import 'dart:typed_data';

import '../../io/streams.dart';
import '../codec.dart';
import 'bzip2_tables.dart';
import 'huffman.dart';

const int _mtfaSize = 4096;
const int _mtflSize = 16;

const int _sStreamHeader = 0;
const int _sBlockHeader = 1;
const int _sOutput = 2;
const int _sDone = 3;

const int _progressStep = 1 << 20;

/// A pull bzip2 decoder over [input]: one stream, or (with
/// [multiStream]) the concatenated streams bzip2 accepts. Every block CRC
/// and every combined stream CRC is checked. Errors are
/// [SevenZipException]s: isNotArc when the input does not start with a
/// bzip2 stream header, unexpectedEnd, crc, or data.
class Bzip2DecoderStream implements InStream {
  final InStream _input;

  /// The unpacked size, when known. Decoding stops at the end of the
  /// stream that reaches it (the following streams are not looked for).
  final int? outSize;

  /// Whether more streams may follow the first one.
  final bool multiStream;
  final ProgressCallback? progress;

  final Uint8List _inBuf;
  int _inPos = 0;
  int _inLim = 0;
  bool _inEof = false;
  int _inTotal = 0;

  // the buffer for bit stream reading
  int _bsBuff = 0;
  int _bsLive = 0;

  int _state = _sStreamHeader;
  SevenZipException? _error;

  /// Block size of the current stream (1..9).
  int blockSize100k = 0;

  /// Number of complete streams decoded.
  int numStreams = 0;

  /// Number of blocks decoded (all streams).
  int numBlocks = 0;

  /// Bytes produced.
  int outProcessed = 0;

  /// Set when data that is not a bzip2 stream follows the last stream.
  bool dataAfterEnd = false;

  int _nextProgress = _progressStep;

  // for undoing the Burrows-Wheeler transform
  Uint32List? _tt;
  int _origPtr = 0;
  int _tPos = 0;
  int _k0 = 0;
  int _nblockUsed = 0;
  int _saveNblock = 0;
  final Int32List _unzftab = Int32List(256);
  final Int32List _cftab = Int32List(257);

  // for doing the final run-length decoding
  int _stateOutCh = 0;
  int _stateOutLen = 0;
  bool _blockRandomised = false;
  int _rNToGo = 0;
  int _rTPos = 0;

  // stored and calculated CRCs
  int _storedBlockCRC = 0;
  int _storedCombinedCRC = 0;
  int _calculatedBlockCRC = 0;
  int _calculatedCombinedCRC = 0;

  // map of bytes used in block
  int _nInUse = 0;
  final Uint8List _inUse = Uint8List(256);
  final Uint8List _inUse16 = Uint8List(16);
  final Uint8List _seqToUnseq = Uint8List(256);

  // for decoding the MTF values
  final Uint8List _mtfa = Uint8List(_mtfaSize);
  final Int32List _mtfbase = Int32List(256 ~/ _mtflSize);
  final Uint8List _selector = Uint8List(bzMaxSelectors);
  final Uint8List _selectorMtf = Uint8List(bzMaxSelectors);
  final Uint8List _len = Uint8List(bzNGroups * bzMaxAlphaSize);

  final Int32List _limit = Int32List(bzNGroups * bzMaxAlphaSize);
  final Int32List _base = Int32List(bzNGroups * bzMaxAlphaSize);
  final Int32List _perm = Int32List(bzNGroups * bzMaxAlphaSize);
  final Int32List _minLens = Int32List(bzNGroups);

  Bzip2DecoderStream(this._input,
      {this.outSize,
      this.multiStream = true,
      this.progress,
      int inBufSize = 1 << 16})
      : _inBuf = Uint8List(inBufSize < 16 ? 16 : inBufSize);

  /// Bytes of the input used by the streams decoded so far (the packed
  /// size): read from the input minus [unusedInput].
  int get inProcessed => _inTotal - (_inLim - _inPos);

  /// Bytes read from the input but not used by the decoder. After the end
  /// they are the start of whatever follows the last stream.
  Uint8List get unusedInput => Uint8List.sublistView(_inBuf, _inPos, _inLim);

  /// Whether the last stream was decoded to its end.
  bool get isFinished => _state == _sDone;

  static SevenZipException _dataError() =>
      const SevenZipException('bzip2: data error');

  static SevenZipException _unexpectedEnd() => const SevenZipException(
      'bzip2: unexpected end of data', SevenZipError.unexpectedEnd);

  // Refills the input buffer. Returns false at the end of the input.
  bool _fill() {
    if (_inEof) return false;
    _inPos = 0;
    _inLim = 0;
    final n = _input.read(_inBuf, 0, _inBuf.length);
    if (n <= 0) {
      _inEof = true;
      return false;
    }
    _inLim = n;
    _inTotal += n;
    return true;
  }

  // Makes at least [n] unread bytes available when the input has them.
  // Returns the number available.
  int _lookahead(int n) {
    for (;;) {
      final avail = _inLim - _inPos;
      if (avail >= n || _inEof) return avail;
      if (_inPos > 0) {
        _inBuf.setRange(0, avail, _inBuf, _inPos);
        _inPos = 0;
        _inLim = avail;
      }
      final r = _input.read(_inBuf, _inLim, _inBuf.length - _inLim);
      if (r <= 0) {
        _inEof = true;
      } else {
        _inLim += r;
        _inTotal += r;
      }
    }
  }

  // GET_BITS
  int _getBits(int n) {
    while (_bsLive < n) {
      if (_inPos == _inLim && !_fill()) throw _unexpectedEnd();
      _bsBuff = ((_bsBuff << 8) | _inBuf[_inPos++]) & 0xFFFFFFFF;
      _bsLive += 8;
    }
    final v = (_bsBuff >> (_bsLive - n)) & ((1 << n) - 1);
    _bsLive -= n;
    return v;
  }

  @override
  int read(Uint8List buf, int off, int len) {
    if (len <= 0) return 0;
    final e = _error;
    if (e != null) throw e;
    try {
      for (;;) {
        switch (_state) {
          case _sOutput:
            final n = _blockRandomised
                ? _unRLERandomised(buf, off, len)
                : _unRLEFast(buf, off, len);
            if (_nblockUsed == _saveNblock + 1 && _stateOutLen == 0) {
              _finishBlock();
            }
            if (n > 0) {
              outProcessed += n;
              final p = progress;
              if (p != null && outProcessed >= _nextProgress) {
                _nextProgress = outProcessed + _progressStep;
                p(inProcessed, outProcessed);
              }
              return n;
            }
          case _sStreamHeader:
            _readStreamHeader();
          case _sBlockHeader:
            _decodeBlock();
          default:
            return 0;
        }
      }
    } on SevenZipException catch (e) {
      _error = e;
      rethrow;
    }
  }

  // The block end part of BZ2_bzDecompress: the block CRC check and the
  // combined CRC.
  void _finishBlock() {
    _calculatedBlockCRC = (~_calculatedBlockCRC) & 0xFFFFFFFF;
    if (_calculatedBlockCRC != _storedBlockCRC) {
      throw const SevenZipException(
          'bzip2: block CRC error', SevenZipError.crc);
    }
    _calculatedCombinedCRC = (((_calculatedCombinedCRC << 1) & 0xFFFFFFFF) |
            (_calculatedCombinedCRC >> 31)) ^
        _calculatedBlockCRC;
    _state = _sBlockHeader;
  }

  // BZ_X_MAGIC_1 .. BZ_X_MAGIC_4 of BZ2_decompress
  void _readStreamHeader() {
    final first = numStreams == 0;
    try {
      if (_getBits(8) != bzHdrB) throw _magicError(first);
      if (_getBits(8) != bzHdrZ) throw _magicError(first);
      if (_getBits(8) != bzHdrH) throw _magicError(first);
      var bs = _getBits(8);
      if (bs < bzHdr0 + 1 || bs > bzHdr0 + 9) throw _magicError(first);
      bs -= bzHdr0;
      blockSize100k = bs;
    } on SevenZipException catch (e) {
      if (first && e.kind == SevenZipError.unexpectedEnd && inProcessed < 4) {
        throw const SevenZipException(
            'bzip2: not a bzip2 stream', SevenZipError.isNotArc);
      }
      rethrow;
    }
    final n = blockSize100k * 100000;
    final tt = _tt;
    if (tt == null || tt.length < n) {
      _tt = null;
      _tt = Uint32List(n);
    }
    _calculatedCombinedCRC = 0;
    _state = _sBlockHeader;
  }

  static SevenZipException _magicError(bool first) => first
      ? const SevenZipException(
          'bzip2: not a bzip2 stream', SevenZipError.isNotArc)
      : _dataError();

  // makeMaps_d
  void _makeMaps() {
    _nInUse = 0;
    for (var i = 0; i < 256; i++) {
      if (_inUse[i] != 0) {
        _seqToUnseq[_nInUse] = i;
        _nInUse++;
      }
    }
  }

  // The end of stream part of BZ2_decompress (BZ_X_ENDHDR_2 ..
  // BZ_X_CCRC_4), the combined CRC check of BZ2_bzDecompress, and the
  // search for a following stream of uncompressStream (bzip2.c).
  void _endOfStream() {
    if (_getBits(8) != 0x72) throw _dataError();
    if (_getBits(8) != 0x45) throw _dataError();
    if (_getBits(8) != 0x38) throw _dataError();
    if (_getBits(8) != 0x50) throw _dataError();
    if (_getBits(8) != 0x90) throw _dataError();

    _storedCombinedCRC = _getBits(16) << 16;
    _storedCombinedCRC |= _getBits(16);

    if (_calculatedCombinedCRC != _storedCombinedCRC) {
      throw const SevenZipException(
          'bzip2: stream CRC error', SevenZipError.crc);
    }

    numStreams++;
    // the rest of the last byte is padding
    _bsLive = 0;
    _bsBuff = 0;

    _state = _sDone;
    if (!multiStream) return;
    final outSize = this.outSize;
    if (outSize != null && outProcessed >= outSize) return;

    final avail = _lookahead(4);
    if (avail == 0) return;
    final b = _inBuf;
    final p = _inPos;
    if (avail >= 4 &&
        b[p] == bzHdrB &&
        b[p + 1] == bzHdrZ &&
        b[p + 2] == bzHdrH &&
        b[p + 3] >= bzHdr0 + 1 &&
        b[p + 3] <= bzHdr0 + 9) {
      _state = _sStreamHeader;
      return;
    }
    dataAfterEnd = true;
  }

  // BZ2_decompress from BZ_X_BLKHDR_1: one block up to the set up of the
  // output (or the end of stream marker).
  void _decodeBlock() {
    var uc = _getBits(8);

    if (uc == 0x17) {
      _endOfStream();
      return;
    }
    if (uc != 0x31) throw _dataError();
    if (_getBits(8) != 0x41) throw _dataError();
    if (_getBits(8) != 0x59) throw _dataError();
    if (_getBits(8) != 0x26) throw _dataError();
    if (_getBits(8) != 0x53) throw _dataError();
    if (_getBits(8) != 0x59) throw _dataError();

    numBlocks++;

    _storedBlockCRC = _getBits(16) << 16;
    _storedBlockCRC |= _getBits(16);

    _blockRandomised = _getBits(1) != 0;

    _origPtr = _getBits(24);
    if (_origPtr > 10 + 100000 * blockSize100k) throw _dataError();

    // Receive the mapping table
    for (var i = 0; i < 16; i++) {
      _inUse16[i] = _getBits(1);
    }

    for (var i = 0; i < 256; i++) {
      _inUse[i] = 0;
    }

    for (var i = 0; i < 16; i++) {
      if (_inUse16[i] != 0) {
        for (var j = 0; j < 16; j++) {
          if (_getBits(1) == 1) _inUse[i * 16 + j] = 1;
        }
      }
    }
    _makeMaps();
    if (_nInUse == 0) throw _dataError();
    final alphaSize = _nInUse + 2;

    // Now the selectors
    final nGroups = _getBits(3);
    if (nGroups < 2 || nGroups > bzNGroups) throw _dataError();
    var nSelectors = _getBits(15);
    if (nSelectors < 1) throw _dataError();
    for (var i = 0; i < nSelectors; i++) {
      var j = 0;
      for (;;) {
        if (_getBits(1) == 0) break;
        j++;
        if (j >= nGroups) throw _dataError();
      }
      // Having more than BZ_MAX_SELECTORS doesn't make much sense since
      // they will never be used, but some implementations might "round up"
      // the number of selectors, so just ignore those.
      if (i < bzMaxSelectors) _selectorMtf[i] = j;
    }
    if (nSelectors > bzMaxSelectors) nSelectors = bzMaxSelectors;

    // Undo the MTF values for the selectors.
    {
      final pos = Uint8List(bzNGroups);
      for (var v = 0; v < nGroups; v++) {
        pos[v] = v;
      }
      for (var i = 0; i < nSelectors; i++) {
        var v = _selectorMtf[i];
        final tmp = pos[v];
        while (v > 0) {
          pos[v] = pos[v - 1];
          v--;
        }
        pos[0] = tmp;
        _selector[i] = tmp;
      }
    }

    // Now the coding tables
    const kA = bzMaxAlphaSize;
    for (var t = 0; t < nGroups; t++) {
      var curr = _getBits(5);
      for (var i = 0; i < alphaSize; i++) {
        for (;;) {
          if (curr < 1 || curr > 20) throw _dataError();
          if (_getBits(1) == 0) break;
          if (_getBits(1) == 0) {
            curr++;
          } else {
            curr--;
          }
        }
        _len[t * kA + i] = curr;
      }
    }

    // Create the Huffman decoding tables
    for (var t = 0; t < nGroups; t++) {
      var minLen = 32;
      var maxLen = 0;
      for (var i = 0; i < alphaSize; i++) {
        final l = _len[t * kA + i];
        if (l > maxLen) maxLen = l;
        if (l < minLen) minLen = l;
      }
      bz2HbCreateDecodeTables(_limit, _base, _perm, t * kA, _len, t * kA,
          minLen, maxLen, alphaSize);
      _minLens[t] = minLen;
    }

    // Now the MTF values
    final nblock = _decodeMtfValues(nSelectors);

    // Now we know what nblock is, we can do a better sanity check on
    // origPtr.
    if (_origPtr < 0 || _origPtr >= nblock) throw _dataError();

    // Set up cftab to facilitate generation of T^(-1)
    final unzftab = _unzftab;
    final cftab = _cftab;
    // Check: unzftab entries in range.
    for (var i = 0; i <= 255; i++) {
      if (unzftab[i] < 0 || unzftab[i] > nblock) throw _dataError();
    }
    // Actually generate cftab.
    cftab[0] = 0;
    for (var i = 1; i <= 256; i++) {
      cftab[i] = unzftab[i - 1];
    }
    for (var i = 1; i <= 256; i++) {
      cftab[i] += cftab[i - 1];
    }
    // Check: cftab entries in range.
    for (var i = 0; i <= 256; i++) {
      if (cftab[i] < 0 || cftab[i] > nblock) throw _dataError();
    }
    // Check: cftab entries non-descending.
    for (var i = 1; i <= 256; i++) {
      if (cftab[i - 1] > cftab[i]) throw _dataError();
    }

    _stateOutLen = 0;
    _stateOutCh = 0;
    _calculatedBlockCRC = 0xFFFFFFFF;
    _state = _sOutput;

    // compute the T^(-1) vector
    final tt = _tt!;
    for (var i = 0; i < nblock; i++) {
      uc = tt[i] & 0xff;
      tt[cftab[uc]] |= (i << 8);
      cftab[uc]++;
    }

    _saveNblock = nblock;
    _tPos = tt[_origPtr] >> 8;
    _nblockUsed = 0;
    final tLimit = 100000 * blockSize100k;
    // BZ_GET_FAST(s->k0)
    if (_tPos >= tLimit) throw _dataError();
    _tPos = tt[_tPos];
    _k0 = _tPos & 0xff;
    _tPos >>= 8;
    _nblockUsed++;
    if (_blockRandomised) {
      _rNToGo = 0;
      _rTPos = 0;
      _k0 ^= _randUpdMask();
    }
  }

  // BZ_RAND_UPD_MASK, then BZ_RAND_MASK
  int _randUpdMask() {
    if (_rNToGo == 0) {
      _rNToGo = bz2RNums[_rTPos];
      _rTPos++;
      if (_rTPos == 512) _rTPos = 0;
    }
    _rNToGo--;
    return _rNToGo == 1 ? 1 : 0;
  }

  // The MTF value loop of BZ2_decompress (GET_MTF_VAL and the MTF
  // decoding), with the bit reader in locals. Returns nblock.
  int _decodeMtfValues(int nSelectors) {
    final eob = _nInUse + 1;
    final nblockMAX = 100000 * blockSize100k;
    final tt = _tt!;
    final unzftab = _unzftab;
    final mtfa = _mtfa;
    final mtfbase = _mtfbase;
    final seqToUnseq = _seqToUnseq;
    final selector = _selector;
    final minLens = _minLens;
    final limit = _limit;
    final base = _base;
    final perm = _perm;
    final inBuf = _inBuf;

    var inPos = _inPos;
    var inLim = _inLim;
    var bsBuff = _bsBuff;
    var bsLive = _bsLive;

    var groupNo = -1;
    var groupPos = 0;
    var gMinlen = 0;
    var gOff = 0;

    for (var i = 0; i <= 255; i++) {
      unzftab[i] = 0;
    }

    // MTF init
    {
      var kk = _mtfaSize - 1;
      for (var ii = 256 ~/ _mtflSize - 1; ii >= 0; ii--) {
        for (var jj = _mtflSize - 1; jj >= 0; jj--) {
          mtfa[kk] = ii * _mtflSize + jj;
          kk--;
        }
        mtfbase[ii] = kk + 1;
      }
    }

    var nblock = 0;
    var inRun = false;
    var es = 0;
    var n = 0;

    for (;;) {
      // GET_MTF_VAL
      if (groupPos == 0) {
        groupNo++;
        if (groupNo >= nSelectors) throw _dataError();
        groupPos = bzGSize;
        final gSel = selector[groupNo];
        gMinlen = minLens[gSel];
        gOff = gSel * bzMaxAlphaSize;
      }
      groupPos--;
      var zn = gMinlen;
      while (bsLive < zn) {
        if (inPos == inLim) {
          _inPos = inPos;
          if (!_fill()) throw _unexpectedEnd();
          inPos = _inPos;
          inLim = _inLim;
        }
        bsBuff = ((bsBuff << 8) | inBuf[inPos++]) & 0xFFFFFFFF;
        bsLive += 8;
      }
      var zvec = (bsBuff >> (bsLive - zn)) & ((1 << zn) - 1);
      bsLive -= zn;
      for (;;) {
        if (zn > 20) throw _dataError(); // the longest code
        if (zvec <= limit[gOff + zn]) break;
        zn++;
        if (bsLive < 1) {
          if (inPos == inLim) {
            _inPos = inPos;
            if (!_fill()) throw _unexpectedEnd();
            inPos = _inPos;
            inLim = _inLim;
          }
          bsBuff = ((bsBuff << 8) | inBuf[inPos++]) & 0xFFFFFFFF;
          bsLive += 8;
        }
        bsLive--;
        zvec = (zvec << 1) | ((bsBuff >> bsLive) & 1);
      }
      final idx = zvec - base[gOff + zn];
      if (idx < 0 || idx >= bzMaxAlphaSize) throw _dataError();
      final nextSym = perm[gOff + idx];

      if (nextSym == bzRunA || nextSym == bzRunB) {
        if (!inRun) {
          inRun = true;
          es = -1;
          n = 1;
        }
        // Check that N doesn't get too big, so that es doesn't go
        // negative.
        if (n >= 2 * 1024 * 1024) throw _dataError();
        if (nextSym == bzRunA) {
          es = es + (0 + 1) * n;
        } else {
          es = es + (1 + 1) * n;
        }
        n = n * 2;
        continue;
      }

      if (inRun) {
        inRun = false;
        es++;
        final c = seqToUnseq[mtfa[mtfbase[0]]];
        unzftab[c] += es;
        if (nblock + es > nblockMAX) throw _dataError();
        tt.fillRange(nblock, nblock + es, c);
        nblock += es;
      }

      if (nextSym == eob) break;

      if (nblock >= nblockMAX) throw _dataError();

      // uc = MTF ( nextSym-1 )
      int uc;
      {
        var nn = nextSym - 1;

        if (nn < _mtflSize) {
          // avoid general-case expense
          final pp = mtfbase[0];
          uc = mtfa[pp + nn];
          while (nn > 3) {
            final z = pp + nn;
            mtfa[z] = mtfa[z - 1];
            mtfa[z - 1] = mtfa[z - 2];
            mtfa[z - 2] = mtfa[z - 3];
            mtfa[z - 3] = mtfa[z - 4];
            nn -= 4;
          }
          while (nn > 0) {
            mtfa[pp + nn] = mtfa[pp + nn - 1];
            nn--;
          }
          mtfa[pp] = uc;
        } else {
          // general case
          var lno = nn ~/ _mtflSize;
          final off = nn % _mtflSize;
          var pp = mtfbase[lno] + off;
          uc = mtfa[pp];
          while (pp > mtfbase[lno]) {
            mtfa[pp] = mtfa[pp - 1];
            pp--;
          }
          mtfbase[lno]++;
          while (lno > 0) {
            mtfbase[lno]--;
            mtfa[mtfbase[lno]] = mtfa[mtfbase[lno - 1] + _mtflSize - 1];
            lno--;
          }
          mtfbase[0]--;
          mtfa[mtfbase[0]] = uc;
          if (mtfbase[0] == 0) {
            var kk = _mtfaSize - 1;
            for (var ii = 256 ~/ _mtflSize - 1; ii >= 0; ii--) {
              for (var jj = _mtflSize - 1; jj >= 0; jj--) {
                mtfa[kk] = mtfa[mtfbase[ii] + jj];
                kk--;
              }
              mtfbase[ii] = kk + 1;
            }
          }
        }
      }

      final c = seqToUnseq[uc];
      unzftab[c]++;
      tt[nblock] = c;
      nblock++;
    }

    _inPos = inPos;
    _inLim = inLim;
    _bsBuff = bsBuff;
    _bsLive = bsLive;
    return nblock;
  }

  // unRLE_obuf_to_output_FAST (not randomised). Returns the number of
  // bytes written to out[off..]; throws on corrupt data. The block CRC is
  // computed over the written bytes after the loop (same value as the per
  // byte BZ_UPDATE_CRC of the C code).
  int _unRLEFast(Uint8List out, int off, int len) {
    final tt = _tt!;
    var ch = _stateOutCh;
    var outLen = _stateOutLen;
    var used = _nblockUsed;
    var k0 = _k0;
    var tPos = _tPos;
    final saveNblockPP = _saveNblock + 1;
    final tLimit = 100000 * blockSize100k;
    var p = off;
    final end = off + len;
    var eqOne = false;
    var corrupt = false;

    outer:
    for (;;) {
      // try to finish existing run
      if (!eqOne) {
        if (outLen > 0) {
          for (;;) {
            if (p == end) break outer;
            if (outLen == 1) break;
            out[p++] = ch;
            outLen--;
          }
          eqOne = true;
        }
      }
      if (eqOne) {
        // s_state_out_len_eq_one
        eqOne = false;
        if (p == end) {
          outLen = 1;
          break outer;
        }
        out[p++] = ch;
      }
      // Only caused by corrupt data stream?
      if (used > saveNblockPP) {
        corrupt = true;
        break outer;
      }

      // can a new run be started?
      if (used == saveNblockPP) {
        outLen = 0;
        break outer;
      }
      ch = k0;
      // BZ_GET_FAST_C(k1)
      if (tPos >= tLimit) {
        corrupt = true;
        break outer;
      }
      tPos = tt[tPos];
      var k1 = tPos & 0xff;
      tPos >>= 8;
      used++;
      if (k1 != k0) {
        k0 = k1;
        eqOne = true;
        continue;
      }
      if (used == saveNblockPP) {
        eqOne = true;
        continue;
      }

      outLen = 2;
      if (tPos >= tLimit) {
        corrupt = true;
        break outer;
      }
      tPos = tt[tPos];
      k1 = tPos & 0xff;
      tPos >>= 8;
      used++;
      if (used == saveNblockPP) continue;
      if (k1 != k0) {
        k0 = k1;
        continue;
      }

      outLen = 3;
      if (tPos >= tLimit) {
        corrupt = true;
        break outer;
      }
      tPos = tt[tPos];
      k1 = tPos & 0xff;
      tPos >>= 8;
      used++;
      if (used == saveNblockPP) continue;
      if (k1 != k0) {
        k0 = k1;
        continue;
      }

      if (tPos >= tLimit) {
        corrupt = true;
        break outer;
      }
      tPos = tt[tPos];
      k1 = tPos & 0xff;
      tPos >>= 8;
      used++;
      outLen = k1 + 4;
      if (tPos >= tLimit) {
        corrupt = true;
        break outer;
      }
      tPos = tt[tPos];
      k0 = tPos & 0xff;
      tPos >>= 8;
      used++;
    }

    if (corrupt) throw _dataError();

    _stateOutCh = ch;
    _stateOutLen = outLen;
    _nblockUsed = used;
    _k0 = k0;
    _tPos = tPos;

    // BZ_UPDATE_CRC over the bytes written
    final table = bz2Crc32Table;
    var crc = _calculatedBlockCRC;
    for (var i = off; i < p; i++) {
      crc = ((crc << 8) & 0xFFFFFFFF) ^ table[(crc >> 24) ^ out[i]];
    }
    _calculatedBlockCRC = crc;
    return p - off;
  }

  // BZ_GET_FAST for the randomised path
  int _getFast() {
    if (_tPos >= 100000 * blockSize100k) throw _dataError();
    _tPos = _tt![_tPos];
    final c = _tPos & 0xff;
    _tPos >>= 8;
    return c;
  }

  // unRLE_obuf_to_output_FAST, randomised blocks (written by bzip2 0.9.0
  // and older).
  int _unRLERandomised(Uint8List out, int off, int len) {
    final saveNblockPP = _saveNblock + 1;
    var p = off;
    final end = off + len;
    final table = bz2Crc32Table;

    for (;;) {
      // try to finish existing run
      for (;;) {
        if (p == end) return p - off;
        if (_stateOutLen == 0) break;
        out[p++] = _stateOutCh;
        _calculatedBlockCRC = ((_calculatedBlockCRC << 8) & 0xFFFFFFFF) ^
            table[(_calculatedBlockCRC >> 24) ^ _stateOutCh];
        _stateOutLen--;
      }

      // can a new run be started?
      if (_nblockUsed == saveNblockPP) return p - off;

      // Only caused by corrupt data stream?
      if (_nblockUsed > saveNblockPP) throw _dataError();

      _stateOutLen = 1;
      _stateOutCh = _k0;
      var k1 = _getFast() ^ _randUpdMask();
      _nblockUsed++;
      if (_nblockUsed == saveNblockPP) continue;
      if (k1 != _k0) {
        _k0 = k1;
        continue;
      }

      _stateOutLen = 2;
      k1 = _getFast() ^ _randUpdMask();
      _nblockUsed++;
      if (_nblockUsed == saveNblockPP) continue;
      if (k1 != _k0) {
        _k0 = k1;
        continue;
      }

      _stateOutLen = 3;
      k1 = _getFast() ^ _randUpdMask();
      _nblockUsed++;
      if (_nblockUsed == saveNblockPP) continue;
      if (k1 != _k0) {
        _k0 = k1;
        continue;
      }

      k1 = _getFast() ^ _randUpdMask();
      _nblockUsed++;
      _stateOutLen = k1 + 4;
      _k0 = _getFast() ^ _randUpdMask();
      _nblockUsed++;
    }
  }
}

/// [DecoderFactory] for MethodId.bzip2: a bzip2 stream (or concatenated
/// streams) as 7-Zip stores it in 7z and zip archives; [props] are empty.
InStream bzip2Decoder(Uint8List props, List<InStream> inputs, int? outSize,
        CoderContext ctx) =>
    Bzip2DecoderStream(inputs[0], outSize: outSize, progress: ctx.progress);
