// Port of C/LzFind.c and C/LzHash.h (LZMA SDK 26.01): the single threaded
// match finders used by the LZMA encoder (bt2, bt3, bt4, bt5, hc4, hc5).
//
// Pointers of the C code become indexes: `buffer` is the index of the
// current position inside `bufBase`, and `son` / `hash` references are
// indexes into their typed lists. UInt32 positions are kept as Dart ints
// below 2^32 (the C code wraps at 2^32 where we mask explicitly).
//
// LzFindMt.c and LzFindOpt.c (multithreaded finder) are not ported: they are
// only used by the multithreaded LZMA encoder.

import 'dart:typed_data';

import '../../io/streams.dart';

// LzHash.h
const int kHash2Size = 1 << 10;
const int kHash3Size = 1 << 16;
const int kFix3HashSize = kHash2Size;
const int kFix4HashSize = kHash2Size + kHash3Size;
const int kFix5HashSize = kFix4HashSize;
const int kLzHashCrcShift1 = 5;
const int kLzHashCrcShift2 = 10;

const int _kBlockMoveAlign = 1 << 7;
const int _kBlockSizeAlign = 1 << 16;
const int _kBlockSizeReserveMin = 1 << 24;
const int _kEmptyHashValue = 0;

const int _mask32 = 0xFFFFFFFF;

// Which GetMatches / Skip pair MatchFinder_CreateVTable selected.
const int _mfHc4 = 0;
const int _mfHc5 = 1;
const int _mfBt2 = 2;
const int _mfBt3 = 3;
const int _mfBt4 = 4;
const int _mfBt5 = 5;

final Uint32List _crcTable = _makeCrcTable();

// MatchFinder_Construct (crc table part)
Uint32List _makeCrcTable() {
  final t = Uint32List(256);
  for (var i = 0; i < 256; i++) {
    var r = i;
    for (var j = 0; j < 8; j++) {
      r = (r >> 1) ^ (0xEDB88320 & -(r & 1));
    }
    t[i] = r & _mask32;
  }
  return t;
}

/// CMatchFinder with the IMatchFinder2 functions as methods.
class CMatchFinder {
  /// The window (stream mode) or the caller's buffer (direct input mode).
  Uint8List bufBase = Uint8List(0);

  /// The window allocated by [create] (C: bufBase in stream mode).
  Uint8List _window = Uint8List(0);

  /// Index of the current position in [bufBase] (C: p.buffer).
  int buffer = 0;
  int pos = 0;
  int posLimit = 0;
  int streamPos = 0;
  int lenLimit = 0;

  int cyclicBufferPos = 0;
  int cyclicBufferSize = 0;

  bool streamEndWasReached = false;
  int btMode = 1;
  int bigHash = 0;
  bool directInput = false;

  int matchMaxLen = 0;
  Uint32List hash = Uint32List(0);
  Uint32List son = Uint32List(0);
  int hashMask = 0;
  int cutValue = 32;

  InStream? stream;

  int blockSize = 0;
  int keepSizeBefore = 0;
  int keepSizeAfter = 0;

  int numHashBytes = 4;
  int directInputRem = 0;
  int historySize = 0;
  int fixedHashSize = 0;
  int numHashBytesMin = 2;
  int numHashOutBits = 0;
  final Uint32List crc = _crcTable;
  int numRefs = 0;

  /// UInt64 in C, -1 here means unknown ((UInt64)(Int64)-1).
  int expectedDataSize = -1;

  int _mfType = _mfBt4;

  // MatchFinder_Construct
  CMatchFinder() {
    _setDefaultSettings();
  }

  // MatchFinder_SetDefaultSettings
  void _setDefaultSettings() {
    cutValue = 32;
    btMode = 1;
    numHashBytes = 4;
    numHashBytesMin = 2;
    numHashOutBits = 0;
    bigHash = 0;
  }

  // MatchFinder_SET_DIRECT_INPUT_BUF
  void setDirectInputBuf(Uint8List src, int off, int len) {
    stream = null;
    directInput = true;
    bufBase = src;
    buffer = off;
    directInputRem = len;
  }

  // MatchFinder_SET_STREAM
  void setStream(InStream s) {
    stream = s;
    directInput = false;
  }

  // Inline_MatchFinder_GetNumAvailableBytes
  int get numAvailableBytes => (streamPos - pos) & _mask32;

  // MatchFinder_ReadBlock
  void _readBlock() {
    if (streamEndWasReached) return;

    if (directInput) {
      var curSize = _mask32 - numAvailableBytes;
      if (curSize > directInputRem) curSize = directInputRem;
      streamPos += curSize;
      directInputRem -= curSize;
      if (directInputRem == 0) streamEndWasReached = true;
      return;
    }

    final s = stream!;
    for (;;) {
      final dest = buffer + numAvailableBytes;
      final size = blockSize - dest;
      if (size == 0) {
        // Not reached in the normal flow (see the C comment).
        return;
      }
      final n = s.read(bufBase, dest, size);
      if (n == 0) {
        streamEndWasReached = true;
        return;
      }
      streamPos += n;
      if (numAvailableBytes > keepSizeAfter) return;
    }
  }

  // MatchFinder_MoveBlock
  void moveBlock() {
    final offset = buffer - keepSizeBefore;
    final keepBefore = (offset & (_kBlockMoveAlign - 1)) + keepSizeBefore;
    final from = offset & ~(_kBlockMoveAlign - 1);
    final n = keepBefore + numAvailableBytes;
    bufBase.setRange(0, n, bufBase, from);
    buffer = keepBefore;
  }

  // MatchFinder_NeedMove
  bool needMove() {
    if (directInput) return false;
    if (streamEndWasReached) return false;
    return blockSize - buffer <= keepSizeAfter;
  }

  // MatchFinder_ReadIfRequired
  void readIfRequired() {
    if (keepSizeAfter >= numAvailableBytes) _readBlock();
  }

  // GetBlockSize
  int _getBlockSize(int historySize) {
    var blockSize = (keepSizeBefore + keepSizeAfter) & _mask32;
    if (keepSizeBefore < historySize || blockSize < keepSizeBefore) return 0;
    const kBlockSizeMax = (0 - _kBlockSizeAlign) & _mask32;
    final rem = (kBlockSizeMax - blockSize) & _mask32;
    final reserve = (blockSize >> (blockSize < (1 << 30) ? 1 : 2)) +
        (1 << 12) +
        _kBlockMoveAlign +
        _kBlockSizeAlign;
    if (blockSize >= kBlockSizeMax || rem < _kBlockSizeReserveMin) return 0;
    if (reserve >= rem) {
      blockSize = kBlockSizeMax;
    } else {
      blockSize += reserve;
      blockSize &= ~(_kBlockSizeAlign - 1);
    }
    return blockSize;
  }

  // MatchFinder_GetHashMask2
  int _getHashMask2(int hs) {
    if (numHashBytes == 2) return (1 << 16) - 1;
    if (hs != 0) hs--;
    hs |= (hs >> 1);
    hs |= (hs >> 2);
    hs |= (hs >> 4);
    hs |= (hs >> 8);
    if (hs >= (1 << 24)) {
      if (numHashBytes == 3) hs = (1 << 24) - 1;
    }
    hs |= (1 << 16) - 1;
    if (numHashBytes >= 5) hs |= (256 << kLzHashCrcShift2) - 1;
    return hs;
  }

  // MatchFinder_GetHashMask
  int _getHashMask(int hs) {
    if (numHashBytes == 2) return (1 << 16) - 1;
    if (hs != 0) hs--;
    hs |= (hs >> 1);
    hs |= (hs >> 2);
    hs |= (hs >> 4);
    hs |= (hs >> 8);
    hs >>= 1;
    if (hs >= (1 << 24)) {
      if (numHashBytes == 3) {
        hs = (1 << 24) - 1;
      } else {
        hs >>= 1;
      }
    }
    hs |= (1 << 16) - 1;
    if (numHashBytes >= 5) hs |= (256 << kLzHashCrcShift2) - 1;
    return hs;
  }

  /// MatchFinder_Create. Returns false when the settings are rejected.
  bool create(int historySize, int keepAddBufferBefore, int matchMaxLen,
      int keepAddBufferAfter) {
    keepSizeBefore = historySize + keepAddBufferBefore + 1;

    keepAddBufferAfter += matchMaxLen;
    if (keepAddBufferAfter < numHashBytes) keepAddBufferAfter = numHashBytes;
    keepSizeAfter = keepAddBufferAfter;

    if (directInput) blockSize = 0;
    if (!directInput) {
      // LzInWindow_Create2
      final bs = _getBlockSize(historySize);
      if (bs == 0) return false;
      if (_window.length != bs || blockSize != bs) {
        blockSize = bs;
        _window = Uint8List(bs);
      }
      bufBase = _window;
    }

    int hs;
    int hsCur;
    if (numHashOutBits != 0) {
      var numBits = numHashOutBits;
      final nbMax = numHashBytes == 2 ? 16 : (numHashBytes == 3 ? 24 : 32);
      if (numBits >= nbMax) numBits = nbMax;
      if (numBits >= 32) {
        hs = _mask32;
      } else {
        hs = (1 << numBits) - 1;
      }
      hs |= (1 << 16) - 1;
      if (numHashBytes >= 5) hs |= (256 << kLzHashCrcShift2) - 1;
      {
        final hs2 = _getHashMask2(historySize);
        if (hs >= hs2) hs = hs2;
      }
      hsCur = hs;
      if (expectedDataSize >= 0 && expectedDataSize < historySize) {
        final hs2 = _getHashMask2(expectedDataSize);
        if (hsCur >= hs2) hsCur = hs2;
      }
    } else {
      hs = _getHashMask(historySize);
      hsCur = hs;
      if (expectedDataSize >= 0 && expectedDataSize < historySize) {
        hsCur = _getHashMask(expectedDataSize);
        if (hsCur >= hs) hsCur = hs;
      }
    }

    hashMask = hsCur;

    var fixed = 0;
    if (numHashBytes > 2 && numHashBytesMin <= 2) fixed += kHash2Size;
    if (numHashBytes > 3 && numHashBytesMin <= 3) fixed += kHash3Size;
    fixedHashSize = fixed;

    this.matchMaxLen = matchMaxLen;
    this.historySize = historySize;
    cyclicBufferSize = historySize + 1;

    // The C code allocates (hs + 1 + fixedHashSize) hash refs but only uses
    // (hashMask + 1 + fixedHashSize) of them; we allocate what is used.
    final hashSize = fixed + hsCur + 1;
    var numSons = cyclicBufferSize;
    if (btMode != 0) numSons <<= 1;
    if (hash.length < hashSize) hash = Uint32List(hashSize);
    if (son.length < numSons) son = Uint32List(numSons);
    numRefs = hashSize + numSons;

    // MatchFinder_CreateVTable
    if (btMode == 0) {
      _mfType = numHashBytes <= 4 ? _mfHc4 : _mfHc5;
    } else if (numHashBytes == 2) {
      _mfType = _mfBt2;
    } else if (numHashBytes == 3) {
      _mfType = _mfBt3;
    } else if (numHashBytes == 4) {
      _mfType = _mfBt4;
    } else {
      _mfType = _mfBt5;
    }
    return true;
  }

  // MatchFinder_Free
  void free() {
    hash = Uint32List(0);
    son = Uint32List(0);
    _window = Uint8List(0);
    bufBase = _window;
    blockSize = 0;
    stream = null;
  }

  // MatchFinder_SetLimits
  void _setLimits() {
    var n = (0 - pos) & _mask32;
    if (n == 0) n = _mask32;

    var k = cyclicBufferSize - cyclicBufferPos;
    if (k < n) n = k;

    k = numAvailableBytes;
    {
      final ksa = keepSizeAfter;
      var mm = matchMaxLen;
      if (k > ksa) {
        k -= ksa;
      } else if (k >= mm) {
        k -= mm;
        k++;
      } else {
        mm = k;
        if (k != 0) k = 1;
      }
      lenLimit = mm;
    }
    if (k < n) n = k;

    posLimit = pos + n;
  }

  // MatchFinder_Init_LowHash
  void _initLowHash() {
    hash.fillRange(0, fixedHashSize, _kEmptyHashValue);
  }

  // MatchFinder_Init_HighHash
  void _initHighHash() {
    hash.fillRange(
        fixedHashSize, fixedHashSize + hashMask + 1, _kEmptyHashValue);
  }

  // MatchFinder_Init_4
  void _init4() {
    if (!directInput) buffer = 0;
    pos = 1;
    streamPos = 1;
    streamEndWasReached = false;
  }

  /// MatchFinder_Init
  void init() {
    _initHighHash();
    _initLowHash();
    _init4();
    _readBlock();
    cyclicBufferPos = pos;
    _setLimits();
  }

  // MatchFinder_Normalize3 (LzFind_SaturSub_32)
  static void _normalize3(int subValue, Uint32List items, int numItems) {
    for (var i = 0; i < numItems; i++) {
      var v = items[i];
      if (v < subValue) v = subValue;
      items[i] = v - subValue;
    }
  }

  // MatchFinder_CheckLimits
  void _checkLimits() {
    if (keepSizeAfter == numAvailableBytes) {
      if (needMove()) moveBlock();
      _readBlock();
    }

    // kMaxValForNormalize == 0: (pos) reached 2^32.
    if ((pos & _mask32) == 0) {
      if (numAvailableBytes >= numHashBytes) {
        final subValue = (pos - historySize - 1) & _mask32;
        pos -= subValue;
        streamPos -= subValue;
        _normalize3(subValue, hash, hashMask + 1 + fixedHashSize);
        var numSonRefs = cyclicBufferSize;
        if (btMode != 0) numSonRefs <<= 1;
        _normalize3(subValue, son, numSonRefs);
      } else {
        // The C code lets (pos) wrap over zero here.
        final avail = numAvailableBytes;
        pos &= _mask32;
        streamPos = pos + avail;
      }
    }

    if (cyclicBufferPos == cyclicBufferSize) cyclicBufferPos = 0;

    _setLimits();
  }

  // MatchFinder_MovePos
  void _movePos() {
    cyclicBufferPos++;
    buffer++;
    final pos1 = pos + 1;
    pos = pos1;
    if (pos1 == posLimit) _checkLimits();
  }

  // MOVE_POS (inlined in the C GetMatches functions)
  @pragma('vm:prefer-inline')
  void _movePosInline() {
    cyclicBufferPos++;
    buffer++;
    final pos1 = pos + 1;
    pos = pos1;
    if (pos1 == posLimit) _checkLimits();
  }

  /// IMatchFinder2::GetMatches. Writes (len, dist) pairs to [distances]
  /// from index 0 and returns the number of values written.
  int getMatches(Uint32List distances) {
    switch (_mfType) {
      case _mfBt4:
        return _bt4GetMatches(distances);
      case _mfHc4:
        return _hc4GetMatches(distances);
      case _mfBt3:
        return _bt3GetMatches(distances);
      case _mfBt5:
        return _bt5GetMatches(distances);
      case _mfHc5:
        return _hc5GetMatches(distances);
      default:
        return _bt2GetMatches(distances);
    }
  }

  /// IMatchFinder2::Skip
  void skip(int num) {
    switch (_mfType) {
      case _mfBt4:
        _bt4Skip(num);
      case _mfHc4:
        _hc4Skip(num);
      case _mfBt3:
        _bt3Skip(num);
      case _mfBt5:
        _bt5Skip(num);
      case _mfHc5:
        _hc5Skip(num);
      default:
        _bt2Skip(num);
    }
  }

  // Hc_GetMatchesSpec
  static int _hcGetMatchesSpec(
      int lenLimit,
      int curMatch,
      int pos,
      Uint8List buf,
      int cur,
      Uint32List son,
      int cyclicBufferPos,
      int cyclicBufferSize,
      int cutValue,
      Uint32List d,
      int dPos,
      int maxLen) {
    final lim = cur + lenLimit;
    son[cyclicBufferPos] = curMatch;

    do {
      if (curMatch == 0) break;
      final delta = pos - curMatch;
      if (delta >= cyclicBufferSize) break;
      curMatch = son[cyclicBufferPos -
          delta +
          (cyclicBufferPos < delta ? cyclicBufferSize : 0)];
      final diff = -delta;
      if (buf[cur + maxLen] == buf[cur + maxLen + diff]) {
        var c = cur;
        var full = false;
        while (buf[c] == buf[c + diff]) {
          if (++c == lim) {
            full = true;
            break;
          }
        }
        if (full) {
          d[dPos] = lim - cur;
          d[dPos + 1] = delta - 1;
          return dPos + 2;
        }
        final len = c - cur;
        if (maxLen < len) {
          maxLen = len;
          d[dPos] = len;
          d[dPos + 1] = delta - 1;
          dPos += 2;
        }
      }
    } while (--cutValue != 0);

    return dPos;
  }

  // GetMatchesSpec1
  static int _getMatchesSpec1(
      int lenLimit,
      int curMatch,
      int pos,
      Uint8List buf,
      int cur,
      Uint32List son,
      int cyclicBufferPos,
      int cyclicBufferSize,
      int cutValue,
      Uint32List d,
      int dPos,
      int maxLen) {
    var ptr0 = (cyclicBufferPos << 1) + 1;
    var ptr1 = cyclicBufferPos << 1;
    var len0 = 0;
    var len1 = 0;

    var cmCheck = pos - cyclicBufferSize;
    if (pos < cyclicBufferSize) cmCheck = 0;

    if (cmCheck < curMatch) {
      do {
        final delta = pos - curMatch;
        final pair = (cyclicBufferPos -
                delta +
                (cyclicBufferPos < delta ? cyclicBufferSize : 0)) <<
            1;
        final pb = cur - delta;
        var len = len0 < len1 ? len0 : len1;
        final pair0 = son[pair];
        if (buf[pb + len] == buf[cur + len]) {
          if (++len != lenLimit && buf[pb + len] == buf[cur + len]) {
            while (++len != lenLimit) {
              if (buf[pb + len] != buf[cur + len]) break;
            }
          }
          if (maxLen < len) {
            maxLen = len;
            d[dPos++] = len;
            d[dPos++] = delta - 1;
            if (len == lenLimit) {
              son[ptr1] = pair0;
              son[ptr0] = son[pair + 1];
              return dPos;
            }
          }
        }
        if (buf[pb + len] < buf[cur + len]) {
          son[ptr1] = curMatch;
          curMatch = son[pair + 1];
          ptr1 = pair + 1;
          len1 = len;
        } else {
          son[ptr0] = curMatch;
          curMatch = son[pair];
          ptr0 = pair;
          len0 = len;
        }
      } while (--cutValue != 0 && cmCheck < curMatch);
    }

    son[ptr0] = _kEmptyHashValue;
    son[ptr1] = _kEmptyHashValue;
    return dPos;
  }

  // SkipMatchesSpec
  static void _skipMatchesSpec(
      int lenLimit,
      int curMatch,
      int pos,
      Uint8List buf,
      int cur,
      Uint32List son,
      int cyclicBufferPos,
      int cyclicBufferSize,
      int cutValue) {
    var ptr0 = (cyclicBufferPos << 1) + 1;
    var ptr1 = cyclicBufferPos << 1;
    var len0 = 0;
    var len1 = 0;

    var cmCheck = pos - cyclicBufferSize;
    if (pos < cyclicBufferSize) cmCheck = 0;

    if (cmCheck < curMatch) {
      do {
        final delta = pos - curMatch;
        final pair = (cyclicBufferPos -
                delta +
                (cyclicBufferPos < delta ? cyclicBufferSize : 0)) <<
            1;
        final pb = cur - delta;
        var len = len0 < len1 ? len0 : len1;
        if (buf[pb + len] == buf[cur + len]) {
          while (++len != lenLimit) {
            if (buf[pb + len] != buf[cur + len]) break;
          }
          if (len == lenLimit) {
            son[ptr1] = son[pair];
            son[ptr0] = son[pair + 1];
            return;
          }
        }
        if (buf[pb + len] < buf[cur + len]) {
          son[ptr1] = curMatch;
          curMatch = son[pair + 1];
          ptr1 = pair + 1;
          len1 = len;
        } else {
          son[ptr0] = curMatch;
          curMatch = son[pair];
          ptr0 = pair;
          len0 = len;
        }
      } while (--cutValue != 0 && cmCheck < curMatch);
    }

    son[ptr0] = _kEmptyHashValue;
    son[ptr1] = _kEmptyHashValue;
  }

  // UPDATE_maxLen
  @pragma('vm:prefer-inline')
  static int _updateMaxLen(
      Uint8List buf, int cur, int d2, int maxLen, int lenLimit) {
    var c = cur + maxLen;
    final lim = cur + lenLimit;
    for (; c != lim; c++) {
      if (buf[c - d2] != buf[c]) break;
    }
    return c - cur;
  }

  // Bt2_MatchFinder_GetMatches
  int _bt2GetMatches(Uint32List distances) {
    final lenLimit = this.lenLimit;
    if (lenLimit < 2) {
      _movePos();
      return 0;
    }
    final cur = buffer;
    final buf = bufBase;
    final hv = buf[cur] | (buf[cur + 1] << 8);
    final curMatch = hash[hv];
    hash[hv] = pos;
    final n = _getMatchesSpec1(lenLimit, curMatch, pos, buf, cur, son,
        cyclicBufferPos, cyclicBufferSize, cutValue, distances, 0, 1);
    _movePosInline();
    return n;
  }

  // Bt3_MatchFinder_GetMatches
  int _bt3GetMatches(Uint32List distances) {
    final lenLimit = this.lenLimit;
    if (lenLimit < 3) {
      _movePos();
      return 0;
    }
    final cur = buffer;
    final buf = bufBase;
    final crc = this.crc;
    final temp = crc[buf[cur]] ^ buf[cur + 1];
    final h2 = temp & (kHash2Size - 1);
    final hv = (temp ^ (buf[cur + 2] << 8)) & hashMask;

    final hash = this.hash;
    final pos = this.pos;

    final d2 = (pos - hash[h2]) & _mask32;
    final curMatch = hash[kFix3HashSize + hv];

    hash[h2] = pos;
    hash[kFix3HashSize + hv] = pos;

    var mmm = cyclicBufferSize;
    if (pos < mmm) mmm = pos;

    var maxLen = 2;
    var dPos = 0;

    if (d2 < mmm && buf[cur - d2] == buf[cur]) {
      maxLen = _updateMaxLen(buf, cur, d2, maxLen, lenLimit);
      distances[0] = maxLen;
      distances[1] = d2 - 1;
      dPos = 2;
      if (maxLen == lenLimit) {
        _skipMatchesSpec(lenLimit, curMatch, pos, buf, cur, son,
            cyclicBufferPos, cyclicBufferSize, cutValue);
        _movePosInline();
        return dPos;
      }
    }

    dPos = _getMatchesSpec1(lenLimit, curMatch, pos, buf, cur, son,
        cyclicBufferPos, cyclicBufferSize, cutValue, distances, dPos, maxLen);
    _movePosInline();
    return dPos;
  }

  // Bt4_MatchFinder_GetMatches
  int _bt4GetMatches(Uint32List distances) {
    final lenLimit = this.lenLimit;
    if (lenLimit < 4) {
      _movePos();
      return 0;
    }
    final cur = buffer;
    final buf = bufBase;
    final crc = this.crc;
    var temp = crc[buf[cur]] ^ buf[cur + 1];
    final h2 = temp & (kHash2Size - 1);
    temp ^= buf[cur + 2] << 8;
    final h3 = temp & (kHash3Size - 1);
    final hv = (temp ^ (crc[buf[cur + 3]] << kLzHashCrcShift1)) & hashMask;

    final hash = this.hash;
    final pos = this.pos;

    var d2 = (pos - hash[h2]) & _mask32;
    final d3 = (pos - hash[kFix3HashSize + h3]) & _mask32;
    final curMatch = hash[kFix4HashSize + hv];

    hash[h2] = pos;
    hash[kFix3HashSize + h3] = pos;
    hash[kFix4HashSize + hv] = pos;

    var mmm = cyclicBufferSize;
    if (pos < mmm) mmm = pos;

    var maxLen = 3;
    var dPos = 0;

    for (;;) {
      if (d2 < mmm && buf[cur - d2] == buf[cur]) {
        distances[0] = 2;
        distances[1] = d2 - 1;
        dPos = 2;
        if (buf[cur - d2 + 2] == buf[cur + 2]) {
          // distances[-2] = 3;
        } else if (d3 < mmm && buf[cur - d3] == buf[cur]) {
          d2 = d3;
          distances[3] = d3 - 1;
          dPos = 4;
        } else {
          break;
        }
      } else if (d3 < mmm && buf[cur - d3] == buf[cur]) {
        d2 = d3;
        distances[1] = d3 - 1;
        dPos = 2;
      } else {
        break;
      }

      maxLen = _updateMaxLen(buf, cur, d2, maxLen, lenLimit);
      distances[dPos - 2] = maxLen;
      if (maxLen == lenLimit) {
        _skipMatchesSpec(lenLimit, curMatch, pos, buf, cur, son,
            cyclicBufferPos, cyclicBufferSize, cutValue);
        _movePosInline();
        return dPos;
      }
      break;
    }

    dPos = _getMatchesSpec1(lenLimit, curMatch, pos, buf, cur, son,
        cyclicBufferPos, cyclicBufferSize, cutValue, distances, dPos, maxLen);
    _movePosInline();
    return dPos;
  }

  // Bt5_MatchFinder_GetMatches
  int _bt5GetMatches(Uint32List distances) {
    final lenLimit = this.lenLimit;
    if (lenLimit < 5) {
      _movePos();
      return 0;
    }
    final cur = buffer;
    final buf = bufBase;
    final crc = this.crc;
    var temp = crc[buf[cur]] ^ buf[cur + 1];
    final h2 = temp & (kHash2Size - 1);
    temp ^= buf[cur + 2] << 8;
    final h3 = temp & (kHash3Size - 1);
    temp ^= crc[buf[cur + 3]] << kLzHashCrcShift1;
    final hv = (temp ^ (crc[buf[cur + 4]] << kLzHashCrcShift2)) & hashMask;

    final hash = this.hash;
    final pos = this.pos;

    var d2 = (pos - hash[h2]) & _mask32;
    final d3 = (pos - hash[kFix3HashSize + h3]) & _mask32;
    final curMatch = hash[kFix5HashSize + hv];

    hash[h2] = pos;
    hash[kFix3HashSize + h3] = pos;
    hash[kFix5HashSize + hv] = pos;

    var mmm = cyclicBufferSize;
    if (pos < mmm) mmm = pos;

    var maxLen = 4;
    var dPos = 0;

    for (;;) {
      if (d2 < mmm && buf[cur - d2] == buf[cur]) {
        distances[0] = 2;
        distances[1] = d2 - 1;
        dPos = 2;
        if (buf[cur - d2 + 2] == buf[cur + 2]) {
        } else if (d3 < mmm && buf[cur - d3] == buf[cur]) {
          distances[3] = d3 - 1;
          dPos = 4;
          d2 = d3;
        } else {
          break;
        }
      } else if (d3 < mmm && buf[cur - d3] == buf[cur]) {
        distances[1] = d3 - 1;
        dPos = 2;
        d2 = d3;
      } else {
        break;
      }

      distances[dPos - 2] = 3;
      if (buf[cur - d2 + 3] != buf[cur + 3]) break;
      maxLen = _updateMaxLen(buf, cur, d2, maxLen, lenLimit);
      distances[dPos - 2] = maxLen;
      if (maxLen == lenLimit) {
        _skipMatchesSpec(lenLimit, curMatch, pos, buf, cur, son,
            cyclicBufferPos, cyclicBufferSize, cutValue);
        _movePosInline();
        return dPos;
      }
      break;
    }

    dPos = _getMatchesSpec1(lenLimit, curMatch, pos, buf, cur, son,
        cyclicBufferPos, cyclicBufferSize, cutValue, distances, dPos, maxLen);
    _movePosInline();
    return dPos;
  }

  // Hc4_MatchFinder_GetMatches
  int _hc4GetMatches(Uint32List distances) {
    final lenLimit = this.lenLimit;
    if (lenLimit < 4) {
      _movePos();
      return 0;
    }
    final cur = buffer;
    final buf = bufBase;
    final crc = this.crc;
    var temp = crc[buf[cur]] ^ buf[cur + 1];
    final h2 = temp & (kHash2Size - 1);
    temp ^= buf[cur + 2] << 8;
    final h3 = temp & (kHash3Size - 1);
    final hv = (temp ^ (crc[buf[cur + 3]] << kLzHashCrcShift1)) & hashMask;

    final hash = this.hash;
    final pos = this.pos;

    var d2 = (pos - hash[h2]) & _mask32;
    final d3 = (pos - hash[kFix3HashSize + h3]) & _mask32;
    final curMatch = hash[kFix4HashSize + hv];

    hash[h2] = pos;
    hash[kFix3HashSize + h3] = pos;
    hash[kFix4HashSize + hv] = pos;

    var mmm = cyclicBufferSize;
    if (pos < mmm) mmm = pos;

    var maxLen = 3;
    var dPos = 0;

    for (;;) {
      if (d2 < mmm && buf[cur - d2] == buf[cur]) {
        distances[0] = 2;
        distances[1] = d2 - 1;
        dPos = 2;
        if (buf[cur - d2 + 2] == buf[cur + 2]) {
          // distances[-2] = 3;
        } else if (d3 < mmm && buf[cur - d3] == buf[cur]) {
          d2 = d3;
          distances[3] = d3 - 1;
          dPos = 4;
        } else {
          break;
        }
      } else if (d3 < mmm && buf[cur - d3] == buf[cur]) {
        d2 = d3;
        distances[1] = d3 - 1;
        dPos = 2;
      } else {
        break;
      }

      maxLen = _updateMaxLen(buf, cur, d2, maxLen, lenLimit);
      distances[dPos - 2] = maxLen;
      if (maxLen == lenLimit) {
        son[cyclicBufferPos] = curMatch;
        _movePosInline();
        return dPos;
      }
      break;
    }

    dPos = _hcGetMatchesSpec(lenLimit, curMatch, pos, buf, cur, son,
        cyclicBufferPos, cyclicBufferSize, cutValue, distances, dPos, maxLen);
    _movePosInline();
    return dPos;
  }

  // Hc5_MatchFinder_GetMatches
  int _hc5GetMatches(Uint32List distances) {
    final lenLimit = this.lenLimit;
    if (lenLimit < 5) {
      _movePos();
      return 0;
    }
    final cur = buffer;
    final buf = bufBase;
    final crc = this.crc;
    var temp = crc[buf[cur]] ^ buf[cur + 1];
    final h2 = temp & (kHash2Size - 1);
    temp ^= buf[cur + 2] << 8;
    final h3 = temp & (kHash3Size - 1);
    temp ^= crc[buf[cur + 3]] << kLzHashCrcShift1;
    final hv = (temp ^ (crc[buf[cur + 4]] << kLzHashCrcShift2)) & hashMask;

    final hash = this.hash;
    final pos = this.pos;

    var d2 = (pos - hash[h2]) & _mask32;
    final d3 = (pos - hash[kFix3HashSize + h3]) & _mask32;
    final curMatch = hash[kFix5HashSize + hv];

    hash[h2] = pos;
    hash[kFix3HashSize + h3] = pos;
    hash[kFix5HashSize + hv] = pos;

    var mmm = cyclicBufferSize;
    if (pos < mmm) mmm = pos;

    var maxLen = 4;
    var dPos = 0;

    for (;;) {
      if (d2 < mmm && buf[cur - d2] == buf[cur]) {
        distances[0] = 2;
        distances[1] = d2 - 1;
        dPos = 2;
        if (buf[cur - d2 + 2] == buf[cur + 2]) {
        } else if (d3 < mmm && buf[cur - d3] == buf[cur]) {
          distances[3] = d3 - 1;
          dPos = 4;
          d2 = d3;
        } else {
          break;
        }
      } else if (d3 < mmm && buf[cur - d3] == buf[cur]) {
        distances[1] = d3 - 1;
        dPos = 2;
        d2 = d3;
      } else {
        break;
      }

      distances[dPos - 2] = 3;
      if (buf[cur - d2 + 3] != buf[cur + 3]) break;
      maxLen = _updateMaxLen(buf, cur, d2, maxLen, lenLimit);
      distances[dPos - 2] = maxLen;
      if (maxLen == lenLimit) {
        son[cyclicBufferPos] = curMatch;
        _movePosInline();
        return dPos;
      }
      break;
    }

    dPos = _hcGetMatchesSpec(lenLimit, curMatch, pos, buf, cur, son,
        cyclicBufferPos, cyclicBufferSize, cutValue, distances, dPos, maxLen);
    _movePosInline();
    return dPos;
  }

  // Bt2_MatchFinder_Skip
  void _bt2Skip(int num) {
    do {
      final lenLimit = this.lenLimit;
      if (lenLimit < 2) {
        _movePos();
        continue;
      }
      final cur = buffer;
      final buf = bufBase;
      final hv = buf[cur] | (buf[cur + 1] << 8);
      final curMatch = hash[hv];
      hash[hv] = pos;
      _skipMatchesSpec(lenLimit, curMatch, pos, buf, cur, son, cyclicBufferPos,
          cyclicBufferSize, cutValue);
      _movePosInline();
    } while (--num != 0);
  }

  // Bt3_MatchFinder_Skip
  void _bt3Skip(int num) {
    do {
      final lenLimit = this.lenLimit;
      if (lenLimit < 3) {
        _movePos();
        continue;
      }
      final cur = buffer;
      final buf = bufBase;
      final temp = crc[buf[cur]] ^ buf[cur + 1];
      final h2 = temp & (kHash2Size - 1);
      final hv = (temp ^ (buf[cur + 2] << 8)) & hashMask;
      final hash = this.hash;
      final curMatch = hash[kFix3HashSize + hv];
      hash[h2] = pos;
      hash[kFix3HashSize + hv] = pos;
      _skipMatchesSpec(lenLimit, curMatch, pos, buf, cur, son, cyclicBufferPos,
          cyclicBufferSize, cutValue);
      _movePosInline();
    } while (--num != 0);
  }

  // Bt4_MatchFinder_Skip
  void _bt4Skip(int num) {
    do {
      final lenLimit = this.lenLimit;
      if (lenLimit < 4) {
        _movePos();
        continue;
      }
      final cur = buffer;
      final buf = bufBase;
      final crc = this.crc;
      var temp = crc[buf[cur]] ^ buf[cur + 1];
      final h2 = temp & (kHash2Size - 1);
      temp ^= buf[cur + 2] << 8;
      final h3 = temp & (kHash3Size - 1);
      final hv = (temp ^ (crc[buf[cur + 3]] << kLzHashCrcShift1)) & hashMask;
      final hash = this.hash;
      final curMatch = hash[kFix4HashSize + hv];
      final pos = this.pos;
      hash[h2] = pos;
      hash[kFix3HashSize + h3] = pos;
      hash[kFix4HashSize + hv] = pos;
      _skipMatchesSpec(lenLimit, curMatch, pos, buf, cur, son, cyclicBufferPos,
          cyclicBufferSize, cutValue);
      _movePosInline();
    } while (--num != 0);
  }

  // Bt5_MatchFinder_Skip
  void _bt5Skip(int num) {
    do {
      final lenLimit = this.lenLimit;
      if (lenLimit < 5) {
        _movePos();
        continue;
      }
      final cur = buffer;
      final buf = bufBase;
      final crc = this.crc;
      var temp = crc[buf[cur]] ^ buf[cur + 1];
      final h2 = temp & (kHash2Size - 1);
      temp ^= buf[cur + 2] << 8;
      final h3 = temp & (kHash3Size - 1);
      temp ^= crc[buf[cur + 3]] << kLzHashCrcShift1;
      final hv = (temp ^ (crc[buf[cur + 4]] << kLzHashCrcShift2)) & hashMask;
      final hash = this.hash;
      final curMatch = hash[kFix5HashSize + hv];
      final pos = this.pos;
      hash[h2] = pos;
      hash[kFix3HashSize + h3] = pos;
      hash[kFix5HashSize + hv] = pos;
      _skipMatchesSpec(lenLimit, curMatch, pos, buf, cur, son, cyclicBufferPos,
          cyclicBufferSize, cutValue);
      _movePosInline();
    } while (--num != 0);
  }

  // Hc4_MatchFinder_Skip (HC_SKIP_HEADER / HC_SKIP_FOOTER)
  void _hc4Skip(int num) {
    do {
      if (lenLimit < 4) {
        _movePos();
        num--;
        continue;
      }
      var pos = this.pos;
      var num2 = num;
      {
        final rem = posLimit - pos;
        if (num2 >= rem) num2 = rem;
      }
      num -= num2;
      var sonPos = cyclicBufferPos;
      cyclicBufferPos = sonPos + num2;
      var cur = buffer;
      final buf = bufBase;
      final hash = this.hash;
      final son = this.son;
      final crc = this.crc;
      final hashMask = this.hashMask;
      do {
        var temp = crc[buf[cur]] ^ buf[cur + 1];
        final h2 = temp & (kHash2Size - 1);
        temp ^= buf[cur + 2] << 8;
        final h3 = temp & (kHash3Size - 1);
        final hv = (temp ^ (crc[buf[cur + 3]] << kLzHashCrcShift1)) & hashMask;
        final curMatch = hash[kFix4HashSize + hv];
        hash[h2] = pos;
        hash[kFix3HashSize + h3] = pos;
        hash[kFix4HashSize + hv] = pos;
        cur++;
        pos++;
        son[sonPos++] = curMatch;
      } while (--num2 != 0);
      buffer = cur;
      this.pos = pos;
      if (pos == posLimit) _checkLimits();
    } while (num != 0);
  }

  // Hc5_MatchFinder_Skip
  void _hc5Skip(int num) {
    do {
      if (lenLimit < 5) {
        _movePos();
        num--;
        continue;
      }
      var pos = this.pos;
      var num2 = num;
      {
        final rem = posLimit - pos;
        if (num2 >= rem) num2 = rem;
      }
      num -= num2;
      var sonPos = cyclicBufferPos;
      cyclicBufferPos = sonPos + num2;
      var cur = buffer;
      final buf = bufBase;
      final hash = this.hash;
      final son = this.son;
      final crc = this.crc;
      final hashMask = this.hashMask;
      do {
        var temp = crc[buf[cur]] ^ buf[cur + 1];
        final h2 = temp & (kHash2Size - 1);
        temp ^= buf[cur + 2] << 8;
        final h3 = temp & (kHash3Size - 1);
        temp ^= crc[buf[cur + 3]] << kLzHashCrcShift1;
        final hv = (temp ^ (crc[buf[cur + 4]] << kLzHashCrcShift2)) & hashMask;
        final curMatch = hash[kFix5HashSize + hv];
        hash[h2] = pos;
        hash[kFix3HashSize + h3] = pos;
        hash[kFix5HashSize + hv] = pos;
        cur++;
        pos++;
        son[sonPos++] = curMatch;
      } while (--num2 != 0);
      buffer = cur;
      this.pos = pos;
      if (pos == posLimit) _checkLimits();
    } while (num != 0);
  }
}
