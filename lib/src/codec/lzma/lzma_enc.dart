// Port of C/LzmaEnc.c (LZMA SDK 26.01), single threaded: props
// normalization, price tables, optimal (normal) and fast parsing, the range
// encoder, end marker, LzmaEnc_Encode streaming and the internal interface
// used by the LZMA2 encoder (LzmaEnc_PrepareForLzma2, LzmaEnc_CodeOneMemBlock,
// LzmaEnc_SaveState / RestoreState).
//
// The output is byte identical to the SDK built without multithreading
// (Z7_ST, or numThreads = 1) for the same properties.
//
// The C code is compiled on x86/x64 without LZMA_LOG_BSR, so the slot of a
// distance comes from the g_FastPos table (kNumLogBits = 14); the result is
// the same either way.

import 'dart:typed_data';

import '../../io/streams.dart';
import '../codec.dart';
import 'lz_find.dart';
import 'lzma_dec.dart'
    show
        lzmaPropsSize,
        szErrorOutputEof,
        szErrorParam,
        szErrorWrite,
        szErrorFail,
        szOk;

/// CLzmaEncProps. Integer fields use -1 (or 0 where the C code does) for
/// "default", and [reduceSize] uses -1 for (UInt64)(Int64)-1.
class LzmaEncProps {
  /// 0 <= level <= 9
  int level = 5;

  /// (1 << 12) <= dictSize <= (3 << 29); 0 = default for the level.
  int dictSize = 0;

  /// 0 <= lc <= 8, default = 3
  int lc = -1;

  /// 0 <= lp <= 4, default = 0
  int lp = -1;

  /// 0 <= pb <= 4, default = 2
  int pb = -1;

  /// 0 - fast, 1 - normal, default = 1
  int algo = -1;

  /// 5 <= fb <= 273, default = 32
  int fb = -1;

  /// 0 - hashChain Mode, 1 - binTree mode - normal, default = 1
  int btMode = -1;

  /// 2, 3, 4 or 5 (default = 4 for bt, 5 for hc)
  int numHashBytes = -1;
  int numHashOutBits = 0;

  /// 1 <= mc <= (1 << 30), 0 = default
  int mc = 0;

  /// Write the end of stream marker (EOPM).
  bool writeEndMark = false;

  /// Number of match finder threads of the C encoder. This port always
  /// encodes on one thread (the output is the same); the value is kept
  /// because the LZMA2 thread and block size logic depends on it.
  int numThreads = -1;

  /// Estimated size of the data (reduces the dictionary). -1 = unknown.
  int reduceSize = -1;

  // LzmaEncProps_Init
  LzmaEncProps();

  LzmaEncProps copy() => LzmaEncProps()
    ..level = level
    ..dictSize = dictSize
    ..lc = lc
    ..lp = lp
    ..pb = pb
    ..algo = algo
    ..fb = fb
    ..btMode = btMode
    ..numHashBytes = numHashBytes
    ..numHashOutBits = numHashOutBits
    ..mc = mc
    ..writeEndMark = writeEndMark
    ..numThreads = numThreads
    ..reduceSize = reduceSize;

  // LzmaEncProps_Normalize
  void normalize() {
    var level = this.level;
    if (level < 0) level = 5;
    this.level = level;

    if (dictSize == 0) {
      // sizeof(size_t) == 8
      dictSize = level <= 4
          ? 1 << (level * 2 + 16)
          : level <= 8
              ? 1 << (level + 20)
              : 1 << 28;
    }

    if (reduceSize >= 0 && dictSize > reduceSize) {
      var v = reduceSize & 0xFFFFFFFF;
      const kReduceMin = 1 << 12;
      if (v < kReduceMin) v = kReduceMin;
      if (dictSize > v) dictSize = v;
    }

    if (lc < 0) lc = 3;
    if (lp < 0) lp = 0;
    if (pb < 0) pb = 2;

    if (algo < 0) algo = level < 5 ? 0 : 1;
    if (fb < 0) fb = level < 7 ? 32 : 64;
    if (btMode < 0) btMode = algo == 0 ? 0 : 1;
    if (numHashBytes < 0) numHashBytes = btMode != 0 ? 4 : 5;
    if (mc == 0) mc = (16 + (fb >> 1)) >> (btMode != 0 ? 0 : 1);

    // As in the multithreaded build of the SDK (7-Zip), not Z7_ST.
    if (numThreads < 0) numThreads = (btMode != 0 && algo != 0) ? 2 : 1;
  }

  // LzmaEncProps_GetDictSize
  int getDictSize() => (copy()..normalize()).dictSize;
}

const int _mask32 = 0xFFFFFFFF;

// for good normalization speed we still reserve 256 MB before 4 GB range
const int _kLzmaMaxHistorySize = 15 << 28;

const int _kTopValue = 1 << 24;
const int _kNumBitModelTotalBits = 11;
const int _kBitModelTotal = 1 << _kNumBitModelTotalBits;
const int _kNumMoveBits = 5;
const int _kProbInitValue = _kBitModelTotal >> 1;
const int _kNumMoveReducingBits = 4;
const int _kNumBitPriceShiftBits = 4;

const int _repLenCount = 64;

const int _kNumLogBits = 14; // 11 + sizeof(size_t) / 8 * 3
const int _kDicLogSizeMaxCompress = (_kNumLogBits - 1) * 2 + 7;

const int _lzmaNumReps = 4;

const int _kNumOpts = 1 << 11;
const int _kPackReserve = _kNumOpts * 8;

const int _kNumLenToPosStates = 4;
const int _kNumPosSlotBits = 6;
const int _kDicLogSizeMax = 32;
const int _kDistTableSizeMax = _kDicLogSizeMax * 2;

const int _kNumAlignBits = 4;
const int _kAlignTableSize = 1 << _kNumAlignBits;
const int _kAlignMask = _kAlignTableSize - 1;

const int _kStartPosModelIndex = 4;
const int _kEndPosModelIndex = 14;
const int _kNumFullDistances = 1 << (_kEndPosModelIndex >> 1);

const int _lzmaPbMax = 4;
const int _lzmaLcMax = 8;
const int _lzmaLpMax = 4;
const int _lzmaNumPbStatesMax = 1 << _lzmaPbMax;

const int _kLenNumLowBits = 3;
const int _kLenNumLowSymbols = 1 << _kLenNumLowBits;
const int _kLenNumHighBits = 8;
const int _kLenNumHighSymbols = 1 << _kLenNumHighBits;
const int _kLenNumSymbolsTotal = _kLenNumLowSymbols * 2 + _kLenNumHighSymbols;

const int _lzmaMatchLenMin = 2;
const int _lzmaMatchLenMax = _lzmaMatchLenMin + _kLenNumSymbolsTotal - 1;

const int _kNumStates = 12;

// CLenEnc: low[LZMA_NUM_PB_STATES_MAX << (kLenNumLowBits + 1)] then
// high[kLenNumHighSymbols] in one list.
const int _lenLowSize = _lzmaNumPbStatesMax << (_kLenNumLowBits + 1);
const int _lenHigh = _lenLowSize;
const int _lenEncSize = _lenLowSize + _kLenNumHighSymbols;

const int _kStateStart = 0;
const int _kStateLitAfterMatch = 4;
const int _kStateLitAfterRep = 5;
const int _kStateMatchAfterLit = 7;
const int _kStateRepAfterLit = 8;

const List<int> _kLiteralNextStates = [0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 4, 5];
const List<int> _kMatchNextStates = [7, 7, 7, 7, 7, 7, 7, 10, 10, 10, 10, 10];
const List<int> _kRepNextStates = [8, 8, 8, 8, 8, 8, 8, 11, 11, 11, 11, 11];
const List<int> _kShortRepNextStates = [
  9, 9, 9, 9, 9, 9, 9, 11, 11, 11, 11, 11 //
];

const int _kInfinityPrice = 1 << 30;

const int _rcBufSize = 1 << 16;

const int _markLit = 0xFFFFFFFF;

final Uint8List _gFastPos = _fastPosInit();
final Uint32List _probPricesTable = _initPriceTables();

// LzmaEnc_FastPosInit
Uint8List _fastPosInit() {
  final g = Uint8List(1 << _kNumLogBits);
  g[0] = 0;
  g[1] = 1;
  var o = 2;
  for (var slot = 2; slot < _kNumLogBits * 2; slot++) {
    final k = 1 << ((slot >> 1) - 1);
    for (var j = 0; j < k; j++) {
      g[o + j] = slot;
    }
    o += k;
  }
  return g;
}

// LzmaEnc_InitPriceTables
Uint32List _initPriceTables() {
  final probPrices = Uint32List(_kBitModelTotal >> _kNumMoveReducingBits);
  for (var i = 0; i < (_kBitModelTotal >> _kNumMoveReducingBits); i++) {
    const kCyclesBits = _kNumBitPriceShiftBits;
    var w = (i << _kNumMoveReducingBits) + (1 << (_kNumMoveReducingBits - 1));
    var bitCount = 0;
    for (var j = 0; j < kCyclesBits; j++) {
      w = w * w;
      bitCount <<= 1;
      while (w >= (1 << 16)) {
        w >>= 1;
        bitCount++;
      }
    }
    probPrices[i] = ((_kNumBitModelTotalBits << kCyclesBits) - 15 - bitCount);
  }
  return probPrices;
}

/// Where the range encoder writes: ISeqOutStream. Returns the number of
/// bytes accepted (less than [len] is a write error / overflow).
abstract class _SeqOutStream {
  int write(Uint8List buf, int off, int len);
}

class _OutStreamWrap implements _SeqOutStream {
  final OutStream out;
  _OutStreamWrap(this.out);
  @override
  int write(Uint8List buf, int off, int len) {
    out.write(buf, off, len);
    return len;
  }
}

// CLzmaEnc_SeqOutStreamBuf
class _SeqOutStreamBuf implements _SeqOutStream {
  Uint8List data;
  int pos;
  int rem;
  bool overflow = false;
  _SeqOutStreamBuf(this.data, this.pos, this.rem);

  // SeqOutStreamBuf_Write
  @override
  int write(Uint8List buf, int off, int size) {
    if (rem < size) {
      size = rem;
      overflow = true;
    }
    if (size != 0) {
      data.setRange(pos, pos + size, buf, off);
      rem -= size;
      pos += size;
    }
    return size;
  }
}

/// CRangeEnc
class _RangeEnc {
  int range = 0xFFFFFFFF;
  int cache = 0;
  int low = 0;
  int cacheSize = 0;
  final Uint8List bufBase = Uint8List(_rcBufSize);
  int buf = 0;
  _SeqOutStream? outStream;
  int processed = 0;
  int res = szOk;

  // RangeEnc_Init
  void init() {
    range = 0xFFFFFFFF;
    cache = 0;
    low = 0;
    cacheSize = 0;
    buf = 0;
    processed = 0;
    res = szOk;
  }

  // RangeEnc_GetProcessed
  int get processedTotal => processed + buf + cacheSize;

  // RangeEnc_FlushStream
  void flushStream() {
    final num = buf;
    if (res == szOk) {
      if (num != outStream!.write(bufBase, 0, num)) res = szErrorWrite;
    }
    processed += num;
    buf = 0;
  }

  // RangeEnc_ShiftLow
  void shiftLow() {
    final low32 = low & _mask32;
    var high = low >> 32;
    low = (low32 << 8) & _mask32;
    if (low32 < 0xFF000000 || high != 0) {
      bufBase[buf++] = cache + high;
      cache = low32 >> 24;
      if (buf == _rcBufSize) flushStream();
      if (cacheSize == 0) return;
      high += 0xFF;
      for (;;) {
        bufBase[buf++] = high;
        if (buf == _rcBufSize) flushStream();
        if (--cacheSize == 0) return;
      }
    }
    cacheSize++;
  }

  // RangeEnc_FlushData
  void flushData() {
    for (var i = 0; i < 5; i++) {
      shiftLow();
    }
  }

  // RC_BIT (same result as the branchless macro)
  @pragma('vm:prefer-inline')
  void encodeBit(Uint16List probs, int i, int bit) {
    final ttt = probs[i];
    final newBound = (range >> _kNumBitModelTotalBits) * ttt;
    if (bit == 0) {
      range = newBound;
      probs[i] = ttt + ((_kBitModelTotal - ttt) >> _kNumMoveBits);
    } else {
      low += newBound;
      range -= newBound;
      probs[i] = ttt - (ttt >> _kNumMoveBits);
    }
    if (range < _kTopValue) {
      range = (range << 8) & _mask32;
      shiftLow();
    }
  }

  // RC_BIT_0
  @pragma('vm:prefer-inline')
  void encodeBit0(Uint16List probs, int i) {
    final ttt = probs[i];
    range = (range >> _kNumBitModelTotalBits) * ttt;
    probs[i] = ttt + ((_kBitModelTotal - ttt) >> _kNumMoveBits);
    if (range < _kTopValue) {
      range = (range << 8) & _mask32;
      shiftLow();
    }
  }

  // RC_BIT_1
  @pragma('vm:prefer-inline')
  void encodeBit1(Uint16List probs, int i) {
    final ttt = probs[i];
    final newBound = (range >> _kNumBitModelTotalBits) * ttt;
    low += newBound;
    range -= newBound;
    probs[i] = ttt - (ttt >> _kNumMoveBits);
    if (range < _kTopValue) {
      range = (range << 8) & _mask32;
      shiftLow();
    }
  }

  // RangeEnc_EncodeDirectBits: encodes the low [numBits] bits of [value],
  // most significant first. LzmaEnc_CodeOneBlock inlines the same loop with
  // a shifted (pos2) variable; the output is the same.
  void encodeDirectBits(int value, int numBits) {
    do {
      range >>= 1;
      low += range & (0 - ((value >> --numBits) & 1));
      if (range < _kTopValue) {
        range = (range << 8) & _mask32;
        shiftLow();
      }
    } while (numBits != 0);
  }

  // LitEnc_Encode
  void litEncode(Uint16List probs, int off, int sym) {
    sym |= 0x100;
    do {
      encodeBit(probs, off + (sym >> 8), (sym >> 7) & 1);
      sym <<= 1;
    } while (sym < 0x10000);
  }

  // LitEnc_EncodeMatched
  void litEncodeMatched(Uint16List probs, int off, int sym, int matchByte) {
    var offs = 0x100;
    sym |= 0x100;
    do {
      matchByte <<= 1;
      final i = off + offs + (matchByte & offs) + (sym >> 8);
      final bit = (sym >> 7) & 1;
      sym <<= 1;
      offs &= ~(matchByte ^ sym);
      encodeBit(probs, i, bit);
    } while (sym < 0x10000);
  }

  // RcTree_ReverseEncode
  void treeReverseEncode(Uint16List probs, int off, int numBits, int sym) {
    var m = 1;
    do {
      final bit = sym & 1;
      sym >>= 1;
      encodeBit(probs, off + m, bit);
      m = (m << 1) | bit;
    } while (--numBits != 0);
  }

  // LenEnc_Encode
  void lenEncode(Uint16List p, int sym, int posState) {
    var probs = 0;
    if (sym >= _kLenNumLowSymbols) {
      encodeBit1(p, probs);
      probs += _kLenNumLowSymbols;
      if (sym >= _kLenNumLowSymbols * 2) {
        encodeBit1(p, probs);
        litEncode(p, _lenHigh, sym - _kLenNumLowSymbols * 2);
        return;
      }
      sym -= _kLenNumLowSymbols;
    }
    encodeBit0(p, probs);
    probs += posState << (1 + _kLenNumLowBits);
    var bit = sym >> 2;
    encodeBit(p, probs + 1, bit);
    var m = (1 << 1) + bit;
    bit = (sym >> 1) & 1;
    encodeBit(p, probs + m, bit);
    m = (m << 1) + bit;
    bit = sym & 1;
    encodeBit(p, probs + m, bit);
  }
}

/// CLenPriceEnc
class _LenPriceEnc {
  int tableSize = 0;

  /// prices[LZMA_NUM_PB_STATES_MAX][kLenNumSymbolsTotal]
  final Uint32List prices =
      Uint32List(_lzmaNumPbStatesMax * _kLenNumSymbolsTotal);
}

/// CSaveState
class _SaveState {
  Uint16List litProbs = Uint16List(0);
  int state = 0;
  final Uint32List reps = Uint32List(_lzmaNumReps);
  final Uint16List posAlignEncoder = Uint16List(1 << _kNumAlignBits);
  final Uint16List isRep = Uint16List(_kNumStates);
  final Uint16List isRepG0 = Uint16List(_kNumStates);
  final Uint16List isRepG1 = Uint16List(_kNumStates);
  final Uint16List isRepG2 = Uint16List(_kNumStates);
  final Uint16List isMatch = Uint16List(_kNumStates * _lzmaNumPbStatesMax);
  final Uint16List isRep0Long = Uint16List(_kNumStates * _lzmaNumPbStatesMax);
  final Uint16List posSlotEncoder =
      Uint16List(_kNumLenToPosStates << _kNumPosSlotBits);
  final Uint16List posEncoders = Uint16List(_kNumFullDistances);
  final Uint16List lenProbs = Uint16List(_lenEncSize);
  final Uint16List repLenProbs = Uint16List(_lenEncSize);
}

/// CLzmaEnc: the LZMA encoder object (LzmaEnc_Create / LzmaEnc_Destroy).
class LzmaEnc {
  final CMatchFinder _mf = CMatchFinder();

  int _optCur = 0;
  int _optEnd = 0;

  int _longestMatchLen = 0;
  int _numPairs = 0;
  int _numAvail = 0;

  int _state = 0;
  int _numFastBytes = 0;
  int _additionalOffset = 0;
  final Uint32List _reps = Uint32List(_lzmaNumReps);
  int _lpMask = 0;
  int _pbMask = 0;
  Uint16List _litProbs = Uint16List(0);
  final _RangeEnc _rc = _RangeEnc();

  int _backRes = 0;

  int _lc = 0;
  int _lp = 0;
  int _pb = 0;
  int _lclp = -1;

  bool _fastMode = false;
  bool _writeEndMark = false;
  bool _finished = false;
  bool _needInit = false;

  int _nowPos64 = 0;

  int _matchPriceCount = 0;
  int _repLenEncCounter = 0;

  int _distTableSize = 0;

  int _dictSize = 0;
  int _result = szOk;

  final Uint32List _probPrices = _probPricesTable;

  final Uint32List _matches = Uint32List(_lzmaMatchLenMax * 2 + 2);

  final Uint32List _alignPrices = Uint32List(_kAlignTableSize);
  final Uint32List _posSlotPrices =
      Uint32List(_kNumLenToPosStates * _kDistTableSizeMax);
  final Uint32List _distancesPrices =
      Uint32List(_kNumLenToPosStates * _kNumFullDistances);

  final Uint16List _posAlignEncoder = Uint16List(1 << _kNumAlignBits);
  final Uint16List _isRep = Uint16List(_kNumStates);
  final Uint16List _isRepG0 = Uint16List(_kNumStates);
  final Uint16List _isRepG1 = Uint16List(_kNumStates);
  final Uint16List _isRepG2 = Uint16List(_kNumStates);
  final Uint16List _isMatch = Uint16List(_kNumStates * _lzmaNumPbStatesMax);
  final Uint16List _isRep0Long = Uint16List(_kNumStates * _lzmaNumPbStatesMax);
  final Uint16List _posSlotEncoder =
      Uint16List(_kNumLenToPosStates << _kNumPosSlotBits);
  final Uint16List _posEncoders = Uint16List(_kNumFullDistances);

  final Uint16List _lenProbs = Uint16List(_lenEncSize);
  final Uint16List _repLenProbs = Uint16List(_lenEncSize);

  final Uint8List _gFastPosT = _gFastPos;

  final _LenPriceEnc _lenEnc = _LenPriceEnc();
  final _LenPriceEnc _repLenEnc = _LenPriceEnc();

  // COptimal opt[kNumOpts] as parallel lists.
  final Uint32List _optPrice = Uint32List(_kNumOpts);
  final Uint16List _optState = Uint16List(_kNumOpts);
  final Uint16List _optExtra = Uint16List(_kNumOpts);
  final Uint32List _optLen = Uint32List(_kNumOpts);
  final Uint32List _optDist = Uint32List(_kNumOpts);
  final Uint32List _optReps = Uint32List(_kNumOpts * _lzmaNumReps);

  final _SaveState _saveState = _SaveState();

  // Locals of GetOptimum.
  final Uint32List _goReps = Uint32List(_lzmaNumReps);
  final Uint32List _goRepLens = Uint32List(_lzmaNumReps);

  // LzmaEnc_Construct
  LzmaEnc() {
    setProps(LzmaEncProps());
  }

  // ---------------------------------------------------------------------
  // Props

  /// LzmaEnc_SetProps. Throws [SevenZipException] for bad parameters
  /// (SZ_ERROR_PARAM).
  void setProps(LzmaEncProps props2) {
    final props = props2.copy()..normalize();

    if (props.lc > _lzmaLcMax ||
        props.lp > _lzmaLpMax ||
        props.pb > _lzmaPbMax ||
        props.lc < 0 ||
        props.lp < 0 ||
        props.pb < 0) {
      throw const SevenZipException(
          'LZMA: unsupported lc/lp/pb', SevenZipError.unsupported);
    }

    if (props.dictSize > _kLzmaMaxHistorySize) {
      props.dictSize = _kLzmaMaxHistorySize;
    }

    if (props.dictSize > (1 << _kDicLogSizeMaxCompress)) {
      throw const SevenZipException(
          'LZMA: dictionary too large', SevenZipError.unsupported);
    }

    _dictSize = props.dictSize;
    {
      var fb = props.fb;
      if (fb < 5) fb = 5;
      if (fb > _lzmaMatchLenMax) fb = _lzmaMatchLenMax;
      _numFastBytes = fb;
    }
    _lc = props.lc;
    _lp = props.lp;
    _pb = props.pb;
    _fastMode = props.algo == 0;
    _mf.btMode = props.btMode != 0 ? 1 : 0;
    {
      var numHashBytes = 4;
      if (props.btMode != 0) {
        if (props.numHashBytes < 2) {
          numHashBytes = 2;
        } else if (props.numHashBytes < 4) {
          numHashBytes = props.numHashBytes;
        }
      }
      if (props.numHashBytes >= 5) numHashBytes = 5;

      _mf.numHashBytes = numHashBytes;
      _mf.numHashOutBits = props.numHashOutBits & 0xFF;
    }

    _mf.cutValue = props.mc & _mask32;

    _writeEndMark = props.writeEndMark;
  }

  /// LzmaEnc_SetDataSize. -1 = unknown.
  void setDataSize(int expectedDataSize) {
    _mf.expectedDataSize = expectedDataSize;
  }

  /// LzmaEnc_WriteProperties: the 5 byte LZMA properties.
  Uint8List writeProperties() {
    final props = Uint8List(lzmaPropsSize);
    final dictSize = _dictSize;
    int v;
    props[0] = (_pb * 5 + _lp) * 9 + _lc;

    if (dictSize >= (1 << 21)) {
      const kDictMask = (1 << 20) - 1;
      v = (dictSize + kDictMask) & ~kDictMask & _mask32;
      if (v < dictSize) v = dictSize;
    } else {
      var i = 11 * 2;
      do {
        v = (2 + (i & 1)) << (i >> 1);
        i++;
      } while (v < dictSize);
    }

    setUint32LE(props, 1, v);
    return props;
  }

  /// LzmaEnc_IsWriteEndMark
  bool get isWriteEndMark => _writeEndMark;

  /// The dictionary size after normalization.
  int get dictSize => _dictSize;

  // ---------------------------------------------------------------------
  // State save / restore (LZMA2)

  /// LzmaEnc_SaveState
  void saveState() {
    final v = _saveState;
    v.state = _state;
    v.reps.setAll(0, _reps);
    v.posAlignEncoder.setAll(0, _posAlignEncoder);
    v.isRep.setAll(0, _isRep);
    v.isRepG0.setAll(0, _isRepG0);
    v.isRepG1.setAll(0, _isRepG1);
    v.isRepG2.setAll(0, _isRepG2);
    v.isMatch.setAll(0, _isMatch);
    v.isRep0Long.setAll(0, _isRep0Long);
    v.posSlotEncoder.setAll(0, _posSlotEncoder);
    v.posEncoders.setAll(0, _posEncoders);
    v.lenProbs.setAll(0, _lenProbs);
    v.repLenProbs.setAll(0, _repLenProbs);
    v.litProbs.setRange(0, 0x300 << _lclp, _litProbs);
  }

  /// LzmaEnc_RestoreState
  void restoreState() {
    final v = _saveState;
    _state = v.state;
    _reps.setAll(0, v.reps);
    _posAlignEncoder.setAll(0, v.posAlignEncoder);
    _isRep.setAll(0, v.isRep);
    _isRepG0.setAll(0, v.isRepG0);
    _isRepG1.setAll(0, v.isRepG1);
    _isRepG2.setAll(0, v.isRepG2);
    _isMatch.setAll(0, v.isMatch);
    _isRep0Long.setAll(0, v.isRep0Long);
    _posSlotEncoder.setAll(0, v.posSlotEncoder);
    _posEncoders.setAll(0, v.posEncoders);
    _lenProbs.setAll(0, v.lenProbs);
    _repLenProbs.setAll(0, v.repLenProbs);
    _litProbs.setRange(0, 0x300 << _lclp, v.litProbs);
  }

  // ---------------------------------------------------------------------
  // Prices

  // GET_PRICE
  @pragma('vm:prefer-inline')
  int _getPrice(int prob, int bit) => _probPrices[
      (prob ^ ((-bit) & (_kBitModelTotal - 1))) >> _kNumMoveReducingBits];

  // GET_PRICE_0
  @pragma('vm:prefer-inline')
  int _getPrice0(int prob) => _probPrices[prob >> _kNumMoveReducingBits];

  // GET_PRICE_1
  @pragma('vm:prefer-inline')
  int _getPrice1(int prob) =>
      _probPrices[(prob ^ (_kBitModelTotal - 1)) >> _kNumMoveReducingBits];

  // LitEnc_GetPrice
  int _litGetPrice(Uint16List probs, int off, int sym) {
    final probPrices = _probPrices;
    var price = 0;
    sym |= 0x100;
    do {
      final bit = sym & 1;
      sym >>= 1;
      price += probPrices[
          (probs[off + sym] ^ ((-bit) & (_kBitModelTotal - 1))) >>
              _kNumMoveReducingBits];
    } while (sym >= 2);
    return price;
  }

  // LitEnc_Matched_GetPrice
  int _litMatchedGetPrice(Uint16List probs, int off, int sym, int matchByte) {
    final probPrices = _probPrices;
    var price = 0;
    var offs = 0x100;
    sym |= 0x100;
    do {
      matchByte <<= 1;
      final bit = (sym >> 7) & 1;
      price += probPrices[(probs[off + offs + (matchByte & offs) + (sym >> 8)] ^
              ((-bit) & (_kBitModelTotal - 1))) >>
          _kNumMoveReducingBits];
      sym <<= 1;
      offs &= ~(matchByte ^ sym);
    } while (sym < 0x10000);
    return price;
  }

  // SetPrices_3
  void _setPrices3(
      Uint16List probs, int off, int startPrice, Uint32List prices, int poff) {
    for (var i = 0; i < 8; i += 2) {
      var price = startPrice;
      price += _getPrice(probs[off + 1], i >> 2);
      price += _getPrice(probs[off + 2 + (i >> 2)], (i >> 1) & 1);
      final prob = probs[off + 4 + (i >> 1)];
      prices[poff + i] = price + _getPrice0(prob);
      prices[poff + i + 1] = price + _getPrice1(prob);
    }
  }

  // LenPriceEnc_UpdateTables
  void _lenPriceEncUpdateTables(
      _LenPriceEnc p, int numPosStates, Uint16List enc) {
    final pr = p.prices;
    int b;
    {
      final prob = enc[0];
      b = _getPrice1(prob);
      final a = _getPrice0(prob);
      final c = b + _getPrice0(enc[_kLenNumLowSymbols]);
      for (var posState = 0; posState < numPosStates; posState++) {
        final prices = posState * _kLenNumSymbolsTotal;
        final probs = posState << (1 + _kLenNumLowBits);
        _setPrices3(enc, probs, a, pr, prices);
        _setPrices3(enc, probs + _kLenNumLowSymbols, c, pr,
            prices + _kLenNumLowSymbols);
      }
    }

    {
      var i = p.tableSize;

      if (i > _kLenNumLowSymbols * 2) {
        const probs = _lenHigh;
        const prices = _kLenNumLowSymbols * 2;
        i -= _kLenNumLowSymbols * 2 - 1;
        i >>= 1;
        b += _getPrice1(enc[_kLenNumLowSymbols]);
        do {
          var sym = --i + (1 << (_kLenNumHighBits - 1));
          var price = b;
          do {
            final bit = sym & 1;
            sym >>= 1;
            price += _getPrice(enc[probs + sym], bit);
          } while (sym >= 2);

          {
            final prob = enc[probs + i + (1 << (_kLenNumHighBits - 1))];
            pr[prices + i * 2] = price + _getPrice0(prob);
            pr[prices + i * 2 + 1] = price + _getPrice1(prob);
          }
        } while (i != 0);

        final num = p.tableSize - _kLenNumLowSymbols * 2;
        for (var posState = 1; posState < numPosStates; posState++) {
          final dst = posState * _kLenNumSymbolsTotal + _kLenNumLowSymbols * 2;
          pr.setRange(dst, dst + num, pr, _kLenNumLowSymbols * 2);
        }
      }
    }
  }

  // FillAlignPrices
  void _fillAlignPrices() {
    final probs = _posAlignEncoder;
    for (var i = 0; i < _kAlignTableSize ~/ 2; i++) {
      var price = 0;
      var sym = i;
      var m = 1;
      int bit;
      bit = sym & 1;
      sym >>= 1;
      price += _getPrice(probs[m], bit);
      m = (m << 1) + bit;
      bit = sym & 1;
      sym >>= 1;
      price += _getPrice(probs[m], bit);
      m = (m << 1) + bit;
      bit = sym & 1;
      sym >>= 1;
      price += _getPrice(probs[m], bit);
      m = (m << 1) + bit;
      final prob = probs[m];
      _alignPrices[i] = price + _getPrice0(prob);
      _alignPrices[i + 8] = price + _getPrice1(prob);
    }
  }

  final Uint32List _tempPrices = Uint32List(_kNumFullDistances);

  // FillDistancesPrices
  void _fillDistancesPrices() {
    final tempPrices = _tempPrices;
    final g = _gFastPosT;
    _matchPriceCount = 0;

    for (var i = _kStartPosModelIndex ~/ 2; i < _kNumFullDistances ~/ 2; i++) {
      final posSlot = g[i];
      var footerBits = (posSlot >> 1) - 1;
      var base = (2 | (posSlot & 1)) << footerBits;
      final probs = base * 2;
      var price = 0;
      var m = 1;
      var sym = i;
      final offset = 1 << footerBits;
      base += i;

      if (footerBits != 0) {
        do {
          final bit = sym & 1;
          sym >>= 1;
          price += _getPrice(_posEncoders[probs + m], bit);
          m = (m << 1) + bit;
        } while (--footerBits != 0);
      }

      {
        final prob = _posEncoders[probs + m];
        tempPrices[base] = price + _getPrice0(prob);
        tempPrices[base + offset] = price + _getPrice1(prob);
      }
    }

    for (var lps = 0; lps < _kNumLenToPosStates; lps++) {
      final distTableSize2 = (_distTableSize + 1) >> 1;
      final posSlotPrices = lps * _kDistTableSizeMax;
      final probs = lps << _kNumPosSlotBits;
      final psp = _posSlotPrices;
      final enc = _posSlotEncoder;

      for (var slot = 0; slot < distTableSize2; slot++) {
        int price;
        int bit;
        var sym = slot + (1 << (_kNumPosSlotBits - 1));
        bit = sym & 1;
        sym >>= 1;
        price = _getPrice(enc[probs + sym], bit);
        bit = sym & 1;
        sym >>= 1;
        price += _getPrice(enc[probs + sym], bit);
        bit = sym & 1;
        sym >>= 1;
        price += _getPrice(enc[probs + sym], bit);
        bit = sym & 1;
        sym >>= 1;
        price += _getPrice(enc[probs + sym], bit);
        bit = sym & 1;
        sym >>= 1;
        price += _getPrice(enc[probs + sym], bit);
        final prob = enc[probs + slot + (1 << (_kNumPosSlotBits - 1))];
        psp[posSlotPrices + slot * 2] = price + _getPrice0(prob);
        psp[posSlotPrices + slot * 2 + 1] = price + _getPrice1(prob);
      }

      {
        var delta = ((_kEndPosModelIndex ~/ 2 - 1) - _kNumAlignBits) <<
            _kNumBitPriceShiftBits;
        for (var slot = _kEndPosModelIndex ~/ 2;
            slot < distTableSize2;
            slot++) {
          psp[posSlotPrices + slot * 2] += delta;
          psp[posSlotPrices + slot * 2 + 1] += delta;
          delta += 1 << _kNumBitPriceShiftBits;
        }
      }

      {
        final dp = lps * _kNumFullDistances;
        final dPrices = _distancesPrices;
        dPrices[dp + 0] = psp[posSlotPrices + 0];
        dPrices[dp + 1] = psp[posSlotPrices + 1];
        dPrices[dp + 2] = psp[posSlotPrices + 2];
        dPrices[dp + 3] = psp[posSlotPrices + 3];

        for (var i = 4; i < _kNumFullDistances; i += 2) {
          final slotPrice = psp[posSlotPrices + g[i]];
          dPrices[dp + i] = slotPrice + tempPrices[i];
          dPrices[dp + i + 1] = slotPrice + tempPrices[i + 1];
        }
      }
    }
  }

  // ---------------------------------------------------------------------
  // Match finder helpers

  // MOVE_POS
  @pragma('vm:prefer-inline')
  void _movePos(int num) {
    _additionalOffset += num;
    _mf.skip(num);
  }

  // Output of _readMatchDistances (the C *numPairsRes).
  int _numPairsRes = 0;

  // ReadMatchDistances
  int _readMatchDistances() {
    _additionalOffset++;
    _numAvail = _mf.numAvailableBytes;
    final numPairs = _mf.getMatches(_matches);
    _numPairsRes = numPairs;

    if (numPairs == 0) return 0;
    {
      final len = _matches[numPairs - 2];
      if (len != _numFastBytes) return len;
      {
        var numAvail = _numAvail;
        if (numAvail > _lzmaMatchLenMax) numAvail = _lzmaMatchLenMax;
        {
          final buf = _mf.bufBase;
          final p1 = _mf.buffer - 1;
          var p2 = p1 + len;
          final dif = -1 - _matches[numPairs - 1];
          final lim = p1 + numAvail;
          for (; p2 != lim && buf[p2] == buf[p2 + dif]; p2++) {}
          return p2 - p1;
        }
      }
    }
  }

  // GetPosSlot1 / BSR2_RET
  @pragma('vm:prefer-inline')
  int _getPosSlot2(int pos) {
    final zz = (pos < (1 << (_kNumLogBits + 6))) ? 6 : 6 + _kNumLogBits - 1;
    return _gFastPosT[pos >> zz] + (zz * 2);
  }

  // GetPosSlot
  @pragma('vm:prefer-inline')
  int _getPosSlot(int pos) {
    if (pos < _kNumFullDistances) {
      return _gFastPosT[pos & (_kNumFullDistances - 1)];
    }
    return _getPosSlot2(pos);
  }

  // GetPrice_ShortRep
  @pragma('vm:prefer-inline')
  int _getPriceShortRep(int state, int posState) =>
      _getPrice0(_isRepG0[state]) +
      _getPrice0(_isRep0Long[state * _lzmaNumPbStatesMax + posState]);

  // GetPrice_Rep_0
  @pragma('vm:prefer-inline')
  int _getPriceRep0(int state, int posState) =>
      _getPrice1(_isMatch[state * _lzmaNumPbStatesMax + posState]) +
      _getPrice1(_isRep0Long[state * _lzmaNumPbStatesMax + posState]) +
      _getPrice1(_isRep[state]) +
      _getPrice0(_isRepG0[state]);

  // GetPrice_PureRep
  int _getPricePureRep(int repIndex, int state, int posState) {
    int price;
    var prob = _isRepG0[state];
    if (repIndex == 0) {
      price = _getPrice0(prob);
      price += _getPrice1(_isRep0Long[state * _lzmaNumPbStatesMax + posState]);
    } else {
      price = _getPrice1(prob);
      prob = _isRepG1[state];
      if (repIndex == 1) {
        price += _getPrice0(prob);
      } else {
        price += _getPrice1(prob);
        price += _getPrice(_isRepG2[state], repIndex - 2);
      }
    }
    return price;
  }

  // Backward
  int _backward(int cur) {
    var wr = cur + 1;
    _optEnd = wr;

    for (;;) {
      var dist = _optDist[cur];
      var len = _optLen[cur];
      final extra = _optExtra[cur];
      cur -= len;

      if (extra != 0) {
        wr--;
        _optLen[wr] = len;
        cur -= extra;
        len = extra;
        if (extra == 1) {
          _optDist[wr] = dist;
          dist = _markLit;
        } else {
          _optDist[wr] = 0;
          len--;
          wr--;
          _optDist[wr] = _markLit;
          _optLen[wr] = 1;
        }
      }

      if (cur == 0) {
        _backRes = dist;
        _optCur = wr;
        return len;
      }

      wr--;
      _optDist[wr] = dist;
      _optLen[wr] = len;
    }
  }

  // LIT_PROBS
  @pragma('vm:prefer-inline')
  int _litProbsOff(int pos, int prevByte) =>
      3 * ((((pos << 8) + prevByte) & _lpMask) << _lc);

  // GetOptimum
  int _getOptimum(int position) {
    int last;
    int cur;
    final reps = _goReps;
    final repLens = _goRepLens;
    final matches = _matches;
    final optPrice = _optPrice;
    final optLen = _optLen;
    final optDist = _optDist;
    final optExtra = _optExtra;
    final optState = _optState;
    final optReps = _optReps;
    final isMatch = _isMatch;
    final isRep = _isRep;
    final probPrices = _probPrices;
    final pbMask = _pbMask;
    final numFastBytes = _numFastBytes;
    final lenPrices = _lenEnc.prices;
    final repLenPrices = _repLenEnc.prices;

    {
      int numPairs;
      int mainLen;
      int repMaxIndex;
      int posState;
      int matchPrice;
      int repMatchPrice;

      _optCur = _optEnd = 0;

      if (_additionalOffset == 0) {
        mainLen = _readMatchDistances();
        numPairs = _numPairsRes;
      } else {
        mainLen = _longestMatchLen;
        numPairs = _numPairs;
      }

      var numAvail = _numAvail;
      if (numAvail < 2) {
        _backRes = _markLit;
        return 1;
      }
      if (numAvail > _lzmaMatchLenMax) numAvail = _lzmaMatchLenMax;

      final buf = _mf.bufBase;
      final data = _mf.buffer - 1;
      repMaxIndex = 0;

      for (var i = 0; i < _lzmaNumReps; i++) {
        reps[i] = _reps[i];
        final data2 = data - reps[i];
        if (buf[data] != buf[data2] || buf[data + 1] != buf[data2 + 1]) {
          repLens[i] = 0;
          continue;
        }
        var len = 2;
        for (; len < numAvail && buf[data + len] == buf[data2 + len]; len++) {}
        repLens[i] = len;
        if (len > repLens[repMaxIndex]) repMaxIndex = i;
        if (len == _lzmaMatchLenMax) break;
      }

      if (repLens[repMaxIndex] >= numFastBytes) {
        _backRes = repMaxIndex;
        final len = repLens[repMaxIndex];
        _movePos(len - 1);
        return len;
      }

      if (mainLen >= numFastBytes) {
        _backRes = matches[numPairs - 1] + _lzmaNumReps;
        _movePos(mainLen - 1);
        return mainLen;
      }

      final curByte = buf[data];
      final matchByte = buf[data - reps[0]];

      last = repLens[repMaxIndex];
      if (last <= mainLen) last = mainLen;

      if (last < 2 && curByte != matchByte) {
        _backRes = _markLit;
        return 1;
      }

      optState[0] = _state;

      posState = position & pbMask;

      {
        final probs = _litProbsOff(position, buf[data - 1]);
        optPrice[1] =
            _getPrice0(isMatch[_state * _lzmaNumPbStatesMax + posState]) +
                (_state >= 7
                    ? _litMatchedGetPrice(_litProbs, probs, curByte, matchByte)
                    : _litGetPrice(_litProbs, probs, curByte));
      }

      optDist[1] = _markLit;
      optExtra[1] = 0;

      matchPrice = _getPrice1(isMatch[_state * _lzmaNumPbStatesMax + posState]);
      repMatchPrice = matchPrice + _getPrice1(isRep[_state]);

      if (matchByte == curByte && repLens[0] == 0) {
        final shortRepPrice =
            repMatchPrice + _getPriceShortRep(_state, posState);
        if (shortRepPrice < optPrice[1]) {
          optPrice[1] = shortRepPrice;
          optDist[1] = 0;
          optExtra[1] = 0;
        }
        if (last < 2) {
          _backRes = optDist[1];
          return 1;
        }
      }

      optLen[1] = 1;

      optReps[0] = reps[0];
      optReps[1] = reps[1];
      optReps[2] = reps[2];
      optReps[3] = reps[3];

      // ---------- REP ----------

      for (var i = 0; i < _lzmaNumReps; i++) {
        var repLen = repLens[i];
        if (repLen < 2) continue;
        final price = repMatchPrice + _getPricePureRep(i, _state, posState);
        do {
          final price2 = price +
              repLenPrices[
                  posState * _kLenNumSymbolsTotal + repLen - _lzmaMatchLenMin];
          if (price2 < optPrice[repLen]) {
            optPrice[repLen] = price2;
            optLen[repLen] = repLen;
            optDist[repLen] = i;
            optExtra[repLen] = 0;
          }
        } while (--repLen >= 2);
      }

      // ---------- MATCH ----------
      {
        var len = repLens[0] + 1;
        if (len <= mainLen) {
          var offs = 0;
          final normalMatchPrice = matchPrice + _getPrice0(isRep[_state]);

          if (len < 2) {
            len = 2;
          } else {
            while (len > matches[offs]) {
              offs += 2;
            }
          }

          for (;; len++) {
            final dist = matches[offs + 1];
            var price = normalMatchPrice +
                lenPrices[
                    posState * _kLenNumSymbolsTotal + len - _lzmaMatchLenMin];
            final lenToPosState = (len < _kNumLenToPosStates + 1)
                ? len - 2
                : _kNumLenToPosStates - 1;

            if (dist < _kNumFullDistances) {
              price += _distancesPrices[lenToPosState * _kNumFullDistances +
                  (dist & (_kNumFullDistances - 1))];
            } else {
              final slot = _getPosSlot2(dist);
              price += _alignPrices[dist & _kAlignMask];
              price +=
                  _posSlotPrices[lenToPosState * _kDistTableSizeMax + slot];
            }

            if (price < optPrice[len]) {
              optPrice[len] = price;
              optLen[len] = len;
              optDist[len] = dist + _lzmaNumReps;
              optExtra[len] = 0;
            }

            if (len == matches[offs]) {
              offs += 2;
              if (offs == numPairs) break;
            }
          }
        }
      }

      cur = 0;
    }

    // ---------- Optimal Parsing ----------

    for (;;) {
      int numAvail;
      int numAvailFull;
      int newLen;
      int numPairs;
      int prev;
      int state;
      int posState;
      int startLen;
      int litPrice;
      int matchPrice;
      int repMatchPrice;
      bool nextIsLit;

      if (++cur == last) break;

      if (cur >= _kNumOpts - 64) {
        var price = optPrice[cur];
        var best = cur;
        for (var j = cur + 1; j <= last; j++) {
          final price2 = optPrice[j];
          if (price >= price2) {
            price = price2;
            best = j;
          }
        }
        {
          final delta = best - cur;
          if (delta != 0) _movePos(delta);
        }
        cur = best;
        break;
      }

      newLen = _readMatchDistances();
      numPairs = _numPairsRes;

      if (newLen >= numFastBytes) {
        _numPairs = numPairs;
        _longestMatchLen = newLen;
        break;
      }

      final curOpt = cur;

      position++;

      prev = cur - optLen[curOpt];

      if (optLen[curOpt] == 1) {
        state = optState[prev];
        if (optDist[curOpt] == 0) {
          state = _kShortRepNextStates[state];
        } else {
          state = _kLiteralNextStates[state];
        }
      } else {
        final dist = optDist[curOpt];

        if (optExtra[curOpt] != 0) {
          prev -= optExtra[curOpt];
          state = _kStateRepAfterLit;
          if (optExtra[curOpt] == 1) {
            state =
                dist < _lzmaNumReps ? _kStateRepAfterLit : _kStateMatchAfterLit;
          }
        } else {
          state = optState[prev];
          if (dist < _lzmaNumReps) {
            state = _kRepNextStates[state];
          } else {
            state = _kMatchNextStates[state];
          }
        }

        final prevOpt = prev * _lzmaNumReps;
        var b0 = optReps[prevOpt];

        if (dist < _lzmaNumReps) {
          if (dist == 0) {
            reps[0] = b0;
            reps[1] = optReps[prevOpt + 1];
            reps[2] = optReps[prevOpt + 2];
            reps[3] = optReps[prevOpt + 3];
          } else {
            reps[1] = b0;
            b0 = optReps[prevOpt + 1];
            if (dist == 1) {
              reps[0] = b0;
              reps[2] = optReps[prevOpt + 2];
              reps[3] = optReps[prevOpt + 3];
            } else {
              reps[2] = b0;
              reps[0] = optReps[prevOpt + dist];
              reps[3] = optReps[prevOpt + (dist ^ 1)];
            }
          }
        } else {
          reps[0] = dist - _lzmaNumReps + 1;
          reps[1] = b0;
          reps[2] = optReps[prevOpt + 1];
          reps[3] = optReps[prevOpt + 2];
        }
      }

      optState[curOpt] = state;
      final curReps = curOpt * _lzmaNumReps;
      optReps[curReps] = reps[0];
      optReps[curReps + 1] = reps[1];
      optReps[curReps + 2] = reps[2];
      optReps[curReps + 3] = reps[3];

      final buf = _mf.bufBase;
      final data = _mf.buffer - 1;
      final curByte = buf[data];
      final matchByte = buf[data - reps[0]];

      posState = position & pbMask;

      {
        final curPrice = optPrice[curOpt];
        final prob = isMatch[state * _lzmaNumPbStatesMax + posState];
        matchPrice = curPrice +
            probPrices[(prob ^ (_kBitModelTotal - 1)) >> _kNumMoveReducingBits];
        litPrice = curPrice + probPrices[prob >> _kNumMoveReducingBits];
      }

      final nextOpt = cur + 1;
      nextIsLit = false;

      if ((optPrice[nextOpt] < _kInfinityPrice && matchByte == curByte) ||
          litPrice > optPrice[nextOpt]) {
        litPrice = 0;
      } else {
        final probs = _litProbsOff(position, buf[data - 1]);
        litPrice += (state >= 7
            ? _litMatchedGetPrice(_litProbs, probs, curByte, matchByte)
            : _litGetPrice(_litProbs, probs, curByte));

        if (litPrice < optPrice[nextOpt]) {
          optPrice[nextOpt] = litPrice;
          optLen[nextOpt] = 1;
          optDist[nextOpt] = _markLit;
          optExtra[nextOpt] = 0;
          nextIsLit = true;
        }
      }

      repMatchPrice = matchPrice + _getPrice1(isRep[state]);

      numAvailFull = _numAvail;
      {
        final temp = _kNumOpts - 1 - cur;
        if (numAvailFull > temp) numAvailFull = temp;
      }

      // ---------- SHORT_REP ----------
      if (state < 7 &&
          matchByte == curByte &&
          repMatchPrice < optPrice[nextOpt]) {
        if (optLen[nextOpt] < 2 || optDist[nextOpt] != 0) {
          final shortRepPrice =
              repMatchPrice + _getPriceShortRep(state, posState);
          if (shortRepPrice < optPrice[nextOpt]) {
            optPrice[nextOpt] = shortRepPrice;
            optLen[nextOpt] = 1;
            optDist[nextOpt] = 0;
            optExtra[nextOpt] = 0;
            nextIsLit = false;
          }
        }
      }

      if (numAvailFull < 2) continue;
      numAvail = numAvailFull <= numFastBytes ? numAvailFull : numFastBytes;

      // ---------- LIT : REP_0 ----------

      if (!nextIsLit &&
          litPrice != 0 &&
          matchByte != curByte &&
          numAvailFull > 2) {
        final data2 = data - reps[0];
        if (buf[data + 1] == buf[data2 + 1] &&
            buf[data + 2] == buf[data2 + 2]) {
          var len = 3;
          var limit = numFastBytes + 1;
          if (limit > numAvailFull) limit = numAvailFull;
          for (; len < limit && buf[data + len] == buf[data2 + len]; len++) {}

          {
            final state2 = _kLiteralNextStates[state];
            final posState2 = (position + 1) & pbMask;
            final price = litPrice + _getPriceRep0(state2, posState2);
            {
              final offset = cur + len;

              if (last < offset) last = offset;

              len--;
              final price2 = price +
                  repLenPrices[posState2 * _kLenNumSymbolsTotal +
                      len -
                      _lzmaMatchLenMin];

              if (price2 < optPrice[offset]) {
                optPrice[offset] = price2;
                optLen[offset] = len;
                optDist[offset] = 0;
                optExtra[offset] = 1;
              }
            }
          }
        }
      }

      startLen = 2; /* speed optimization */

      {
        // ---------- REP ----------
        for (var repIndex = 0; repIndex < _lzmaNumReps; repIndex++) {
          final data2 = data - reps[repIndex];
          if (buf[data] != buf[data2] || buf[data + 1] != buf[data2 + 1]) {
            continue;
          }

          var len = 2;
          for (;
              len < numAvail && buf[data + len] == buf[data2 + len];
              len++) {}

          {
            final offset = cur + len;
            if (last < offset) last = offset;
          }
          int price;
          {
            var len2 = len;
            price = repMatchPrice + _getPricePureRep(repIndex, state, posState);
            do {
              final price2 = price +
                  repLenPrices[posState * _kLenNumSymbolsTotal +
                      len2 -
                      _lzmaMatchLenMin];
              final opt = cur + len2;
              if (price2 < optPrice[opt]) {
                optPrice[opt] = price2;
                optLen[opt] = len2;
                optDist[opt] = repIndex;
                optExtra[opt] = 0;
              }
            } while (--len2 >= 2);
          }

          if (repIndex == 0) startLen = len + 1;

          {
            // ---------- REP : LIT : REP_0 ----------
            var len2 = len + 1;
            var limit = len2 + numFastBytes;
            if (limit > numAvailFull) limit = numAvailFull;

            len2 += 2;
            if (len2 <= limit &&
                buf[data + len2 - 2] == buf[data2 + len2 - 2] &&
                buf[data + len2 - 1] == buf[data2 + len2 - 1]) {
              var state2 = _kRepNextStates[state];
              var posState2 = (position + len) & pbMask;
              price += repLenPrices[posState * _kLenNumSymbolsTotal +
                      len -
                      _lzmaMatchLenMin] +
                  _getPrice0(
                      isMatch[state2 * _lzmaNumPbStatesMax + posState2]) +
                  _litMatchedGetPrice(
                      _litProbs,
                      _litProbsOff(position + len, buf[data + len - 1]),
                      buf[data + len],
                      buf[data2 + len]);

              state2 = _kStateLitAfterRep;
              posState2 = (posState2 + 1) & pbMask;

              price += _getPriceRep0(state2, posState2);

              for (;
                  len2 < limit && buf[data + len2] == buf[data2 + len2];
                  len2++) {}

              len2 -= len;
              {
                final offset = cur + len + len2;

                if (last < offset) last = offset;
                len2--;
                final price2 = price +
                    repLenPrices[posState2 * _kLenNumSymbolsTotal +
                        len2 -
                        _lzmaMatchLenMin];

                if (price2 < optPrice[offset]) {
                  optPrice[offset] = price2;
                  optLen[offset] = len2;
                  optExtra[offset] = len + 1;
                  optDist[offset] = repIndex;
                }
              }
            }
          }
        }
      }

      // ---------- MATCH ----------
      if (newLen > numAvail) {
        newLen = numAvail;
        for (numPairs = 0; newLen > matches[numPairs]; numPairs += 2) {}
        matches[numPairs] = newLen;
        numPairs += 2;
      }

      if (newLen >= startLen) {
        final normalMatchPrice = matchPrice + _getPrice0(isRep[state]);

        {
          final offset = cur + newLen;
          if (last < offset) last = offset;
        }

        var offs = 0;
        while (startLen > matches[offs]) {
          offs += 2;
        }
        var dist = matches[offs + 1];

        var posSlot = _getPosSlot2(dist);

        for (var len = startLen;; len++) {
          var price = normalMatchPrice +
              lenPrices[
                  posState * _kLenNumSymbolsTotal + len - _lzmaMatchLenMin];
          {
            var lenNorm = len - 2;
            lenNorm = lenNorm < _kNumLenToPosStates - 1
                ? lenNorm
                : _kNumLenToPosStates - 1;
            if (dist < _kNumFullDistances) {
              price += _distancesPrices[lenNorm * _kNumFullDistances +
                  (dist & (_kNumFullDistances - 1))];
            } else {
              price += _posSlotPrices[lenNorm * _kDistTableSizeMax + posSlot] +
                  _alignPrices[dist & _kAlignMask];
            }

            final opt = cur + len;
            if (price < optPrice[opt]) {
              optPrice[opt] = price;
              optLen[opt] = len;
              optDist[opt] = dist + _lzmaNumReps;
              optExtra[opt] = 0;
            }
          }

          if (len == matches[offs]) {
            // MATCH : LIT : REP_0

            final data2 = data - dist - 1;
            var len2 = len + 1;
            var limit = len2 + numFastBytes;
            if (limit > numAvailFull) limit = numAvailFull;

            len2 += 2;
            if (len2 <= limit &&
                buf[data + len2 - 2] == buf[data2 + len2 - 2] &&
                buf[data + len2 - 1] == buf[data2 + len2 - 1]) {
              for (;
                  len2 < limit && buf[data + len2] == buf[data2 + len2];
                  len2++) {}

              len2 -= len;

              {
                var state2 = _kMatchNextStates[state];
                var posState2 = (position + len) & pbMask;
                price += _getPrice0(
                    isMatch[state2 * _lzmaNumPbStatesMax + posState2]);
                price += _litMatchedGetPrice(
                    _litProbs,
                    _litProbsOff(position + len, buf[data + len - 1]),
                    buf[data + len],
                    buf[data2 + len]);

                state2 = _kStateLitAfterMatch;

                posState2 = (posState2 + 1) & pbMask;
                price += _getPriceRep0(state2, posState2);

                final offset = cur + len + len2;

                if (last < offset) last = offset;
                len2--;
                final price2 = price +
                    repLenPrices[posState2 * _kLenNumSymbolsTotal +
                        len2 -
                        _lzmaMatchLenMin];
                if (price2 < optPrice[offset]) {
                  optPrice[offset] = price2;
                  optLen[offset] = len2;
                  optExtra[offset] = len + 1;
                  optDist[offset] = dist + _lzmaNumReps;
                }
              }
            }

            offs += 2;
            if (offs == numPairs) break;
            dist = matches[offs + 1];
            posSlot = _getPosSlot2(dist);
          }
        }
      }
    }

    do {
      optPrice[last] = _kInfinityPrice;
    } while (--last != 0);

    return _backward(cur);
  }

  // ChangePair
  @pragma('vm:prefer-inline')
  static bool _changePair(int smallDist, int bigDist) =>
      (bigDist >> 7) > smallDist;

  // GetOptimumFast
  int _getOptimumFast() {
    int mainDist;
    int mainLen;
    int numPairs;
    var repIndex = 0;
    var repLen = 0;

    if (_additionalOffset == 0) {
      mainLen = _readMatchDistances();
      numPairs = _numPairsRes;
    } else {
      mainLen = _longestMatchLen;
      numPairs = _numPairs;
    }

    var numAvail = _numAvail;
    _backRes = _markLit;
    if (numAvail < 2) return 1;
    if (numAvail > _lzmaMatchLenMax) numAvail = _lzmaMatchLenMax;
    var buf = _mf.bufBase;
    var data = _mf.buffer - 1;

    for (var i = 0; i < _lzmaNumReps; i++) {
      final data2 = data - _reps[i];
      if (buf[data] != buf[data2] || buf[data + 1] != buf[data2 + 1]) continue;
      var len = 2;
      for (; len < numAvail && buf[data + len] == buf[data2 + len]; len++) {}
      if (len >= _numFastBytes) {
        _backRes = i;
        _movePos(len - 1);
        return len;
      }
      if (len > repLen) {
        repIndex = i;
        repLen = len;
      }
    }

    final matches = _matches;
    if (mainLen >= _numFastBytes) {
      _backRes = matches[numPairs - 1] + _lzmaNumReps;
      _movePos(mainLen - 1);
      return mainLen;
    }

    mainDist = 0;

    if (mainLen >= 2) {
      mainDist = matches[numPairs - 1];
      while (numPairs > 2) {
        if (mainLen != matches[numPairs - 4] + 1) break;
        final dist2 = matches[numPairs - 3];
        if (!_changePair(dist2, mainDist)) break;
        numPairs -= 2;
        mainLen--;
        mainDist = dist2;
      }
      if (mainLen == 2 && mainDist >= 0x80) mainLen = 1;
    }

    if (repLen >= 2) {
      if (repLen + 1 >= mainLen ||
          (repLen + 2 >= mainLen && mainDist >= (1 << 9)) ||
          (repLen + 3 >= mainLen && mainDist >= (1 << 15))) {
        _backRes = repIndex;
        _movePos(repLen - 1);
        return repLen;
      }
    }

    if (mainLen < 2 || numAvail <= 2) return 1;

    {
      final len1 = _readMatchDistances();
      _numPairs = _numPairsRes;
      _longestMatchLen = len1;

      if (len1 >= 2) {
        final newDist = matches[_numPairs - 1];
        if ((len1 >= mainLen && newDist < mainDist) ||
            (len1 == mainLen + 1 && !_changePair(mainDist, newDist)) ||
            (len1 > mainLen + 1) ||
            (len1 + 1 >= mainLen &&
                mainLen >= 3 &&
                _changePair(newDist, mainDist))) {
          return 1;
        }
      }
    }

    buf = _mf.bufBase;
    data = _mf.buffer - 1;

    for (var i = 0; i < _lzmaNumReps; i++) {
      final data2 = data - _reps[i];
      if (buf[data] != buf[data2] || buf[data + 1] != buf[data2 + 1]) continue;
      final limit = mainLen - 1;
      for (var len = 2;; len++) {
        if (len >= limit) return 1;
        if (buf[data + len] != buf[data2 + len]) break;
      }
    }

    _backRes = mainDist + _lzmaNumReps;
    if (mainLen != 2) _movePos(mainLen - 2);
    return mainLen;
  }

  // WriteEndMarker
  void _writeEndMarker(int posState) {
    final rc = _rc;
    rc.encodeBit1(_isMatch, _state * _lzmaNumPbStatesMax + posState);
    rc.encodeBit0(_isRep, _state);
    _state = _kMatchNextStates[_state];

    rc.lenEncode(_lenProbs, 0, posState);

    {
      // RcTree_Encode_PosSlot(rc, posSlotEncoder[0], 63)
      var m = 1;
      do {
        rc.encodeBit1(_posSlotEncoder, m);
        m = (m << 1) + 1;
      } while (m < (1 << _kNumPosSlotBits));
    }
    {
      // RangeEnc_EncodeDirectBits(rc, (1 << 26) - 1, 26)
      rc.encodeDirectBits(
          (1 << (30 - _kNumAlignBits)) - 1, 30 - _kNumAlignBits);
    }
    {
      // RcTree_ReverseEncode(rc, posAlignEncoder, 4, kAlignMask)
      var m = 1;
      do {
        rc.encodeBit1(_posAlignEncoder, m);
        m = (m << 1) + 1;
      } while (m < _kAlignTableSize);
    }
  }

  // CheckErrors
  int _checkErrors() {
    if (_result != szOk) return _result;
    if (_rc.res != szOk) _result = szErrorWrite;
    if (_result != szOk) _finished = true;
    return _result;
  }

  // Flush
  int _flush(int nowPos) {
    _finished = true;
    if (_writeEndMark) _writeEndMarker(nowPos & _pbMask);
    _rc.flushData();
    _rc.flushStream();
    return _checkErrors();
  }

  // LzmaEnc_CodeOneBlock
  int _codeOneBlock(int maxPackSize, int maxUnpackSize) {
    if (_needInit) {
      _mf.init();
      _needInit = false;
    }

    if (_finished) return _result;
    {
      final r = _checkErrors();
      if (r != szOk) return r;
    }

    var nowPos32 = _nowPos64 & _mask32;
    final startPos32 = nowPos32;
    final rc = _rc;

    if (_nowPos64 == 0) {
      if (_mf.numAvailableBytes == 0) return _flush(nowPos32);
      _readMatchDistances();
      rc.encodeBit0(_isMatch, _kStateStart * _lzmaNumPbStatesMax + 0);
      final curByte = _mf.bufBase[_mf.buffer - _additionalOffset];
      rc.litEncode(_litProbs, 0, curByte);
      _additionalOffset--;
      nowPos32++;
    }

    if (_mf.numAvailableBytes != 0) {
      for (;;) {
        int dist;
        int len;

        if (_fastMode) {
          len = _getOptimumFast();
        } else {
          final oci = _optCur;
          if (_optEnd == oci) {
            len = _getOptimum(nowPos32);
          } else {
            len = _optLen[oci];
            _backRes = _optDist[oci];
            _optCur = oci + 1;
          }
        }

        final posState = nowPos32 & _pbMask;
        final isMatchIdx = _state * _lzmaNumPbStatesMax + posState;

        dist = _backRes;

        if (dist == _markLit) {
          rc.encodeBit0(_isMatch, isMatchIdx);
          final buf = _mf.bufBase;
          final data = _mf.buffer - _additionalOffset;
          final probs = _litProbsOff(nowPos32, buf[data - 1]);
          final curByte = buf[data];
          final state = _state;
          _state = _kLiteralNextStates[state];
          if (state < 7) {
            rc.litEncode(_litProbs, probs, curByte);
          } else {
            rc.litEncodeMatched(
                _litProbs, probs, curByte, buf[data - _reps[0]]);
          }
        } else {
          rc.encodeBit1(_isMatch, isMatchIdx);

          if (dist < _lzmaNumReps) {
            rc.encodeBit1(_isRep, _state);
            if (dist == 0) {
              rc.encodeBit0(_isRepG0, _state);
              if (len != 1) {
                rc.encodeBit1(_isRep0Long, isMatchIdx);
              } else {
                rc.encodeBit0(_isRep0Long, isMatchIdx);
                _state = _kShortRepNextStates[_state];
              }
            } else {
              rc.encodeBit1(_isRepG0, _state);
              if (dist == 1) {
                rc.encodeBit0(_isRepG1, _state);
                dist = _reps[1];
              } else {
                rc.encodeBit1(_isRepG1, _state);
                if (dist == 2) {
                  rc.encodeBit0(_isRepG2, _state);
                  dist = _reps[2];
                } else {
                  rc.encodeBit1(_isRepG2, _state);
                  dist = _reps[3];
                  _reps[3] = _reps[2];
                }
                _reps[2] = _reps[1];
              }
              _reps[1] = _reps[0];
              _reps[0] = dist;
            }

            if (len != 1) {
              rc.lenEncode(_repLenProbs, len - _lzmaMatchLenMin, posState);
              --_repLenEncCounter;
              _state = _kRepNextStates[_state];
            }
          } else {
            rc.encodeBit0(_isRep, _state);
            _state = _kMatchNextStates[_state];

            rc.lenEncode(_lenProbs, len - _lzmaMatchLenMin, posState);

            dist -= _lzmaNumReps;
            _reps[3] = _reps[2];
            _reps[2] = _reps[1];
            _reps[1] = _reps[0];
            _reps[0] = dist + 1;

            _matchPriceCount++;
            final posSlot = _getPosSlot(dist);
            {
              var sym = posSlot + (1 << _kNumPosSlotBits);
              final lenToPosState = (len < _kNumLenToPosStates + 1)
                  ? len - 2
                  : _kNumLenToPosStates - 1;
              final probs = lenToPosState << _kNumPosSlotBits;
              do {
                final prob = probs + (sym >> _kNumPosSlotBits);
                final bit = (sym >> (_kNumPosSlotBits - 1)) & 1;
                sym <<= 1;
                rc.encodeBit(_posSlotEncoder, prob, bit);
              } while (sym < (1 << (_kNumPosSlotBits * 2)));
            }

            if (dist >= _kStartPosModelIndex) {
              final footerBits = (posSlot >> 1) - 1;

              if (dist < _kNumFullDistances) {
                final base = (2 | (posSlot & 1)) << footerBits;
                rc.treeReverseEncode(_posEncoders, base, footerBits, dist);
              } else {
                rc.encodeDirectBits(
                    dist >> _kNumAlignBits, footerBits - _kNumAlignBits);
                var m = 1;
                int bit;
                bit = dist & 1;
                dist >>= 1;
                rc.encodeBit(_posAlignEncoder, m, bit);
                m = (m << 1) + bit;
                bit = dist & 1;
                dist >>= 1;
                rc.encodeBit(_posAlignEncoder, m, bit);
                m = (m << 1) + bit;
                bit = dist & 1;
                dist >>= 1;
                rc.encodeBit(_posAlignEncoder, m, bit);
                m = (m << 1) + bit;
                bit = dist & 1;
                rc.encodeBit(_posAlignEncoder, m, bit);
              }
            }
          }
        }

        nowPos32 = (nowPos32 + len) & _mask32;
        _additionalOffset -= len;

        if (_additionalOffset == 0) {
          if (!_fastMode) {
            if (_matchPriceCount >= 64) {
              _fillAlignPrices();
              _fillDistancesPrices();
              _lenPriceEncUpdateTables(_lenEnc, 1 << _pb, _lenProbs);
            }
            if (_repLenEncCounter <= 0) {
              _repLenEncCounter = _repLenCount;
              _lenPriceEncUpdateTables(_repLenEnc, 1 << _pb, _repLenProbs);
            }
          }

          if (_mf.numAvailableBytes == 0) break;
          final processed = (nowPos32 - startPos32) & _mask32;

          if (maxPackSize != 0) {
            if (processed + _kNumOpts + 300 >= maxUnpackSize ||
                rc.processedTotal + _kPackReserve >= maxPackSize) {
              break;
            }
          } else if (processed >= (1 << 17)) {
            _nowPos64 += (nowPos32 - startPos32) & _mask32;
            return _checkErrors();
          }
        }
      }
    }

    _nowPos64 += (nowPos32 - startPos32) & _mask32;
    return _flush(nowPos32);
  }

  // kBigHashDicLimit
  static const int _kBigHashDicLimit = 1 << 24;

  // LzmaEnc_Alloc
  int _alloc(int keepWindowSize) {
    var beforeSize = _kNumOpts;

    {
      final lclp = _lc + _lp;
      if (_litProbs.isEmpty || _lclp != lclp) {
        _litProbs = Uint16List(0x300 << lclp);
        _saveState.litProbs = Uint16List(0x300 << lclp);
        _lclp = lclp;
      }
    }

    _mf.bigHash = _dictSize > _kBigHashDicLimit ? 1 : 0;

    var dictSize = _dictSize;
    if (dictSize == (2 << 30) || dictSize == (3 << 30)) dictSize -= 1;

    if (beforeSize + dictSize < keepWindowSize) {
      beforeSize = keepWindowSize - dictSize;
    }

    if (!_mf.create(
        dictSize, beforeSize, _numFastBytes, _lzmaMatchLenMax + 1)) {
      return szErrorParam;
    }
    return szOk;
  }

  // LzmaEnc_Init
  void _init() {
    _state = 0;
    _reps[0] = _reps[1] = _reps[2] = _reps[3] = 1;

    _rc.init();

    _posAlignEncoder.fillRange(0, _posAlignEncoder.length, _kProbInitValue);
    _isMatch.fillRange(0, _isMatch.length, _kProbInitValue);
    _isRep0Long.fillRange(0, _isRep0Long.length, _kProbInitValue);
    _isRep.fillRange(0, _kNumStates, _kProbInitValue);
    _isRepG0.fillRange(0, _kNumStates, _kProbInitValue);
    _isRepG1.fillRange(0, _kNumStates, _kProbInitValue);
    _isRepG2.fillRange(0, _kNumStates, _kProbInitValue);
    _posSlotEncoder.fillRange(0, _posSlotEncoder.length, _kProbInitValue);
    _posEncoders.fillRange(0, _kNumFullDistances, _kProbInitValue);
    _litProbs.fillRange(0, 0x300 << (_lp + _lc), _kProbInitValue);

    // LenEnc_Init
    _lenProbs.fillRange(0, _lenEncSize, _kProbInitValue);
    _repLenProbs.fillRange(0, _lenEncSize, _kProbInitValue);

    _optEnd = 0;
    _optCur = 0;

    _optPrice.fillRange(0, _kNumOpts, _kInfinityPrice);

    _additionalOffset = 0;

    _pbMask = (1 << _pb) - 1;
    _lpMask = (0x100 << _lp) - (0x100 >> _lc);
  }

  // LzmaEnc_InitPrices
  void _initPrices() {
    if (!_fastMode) {
      _fillDistancesPrices();
      _fillAlignPrices();
    }

    _lenEnc.tableSize =
        _repLenEnc.tableSize = _numFastBytes + 1 - _lzmaMatchLenMin;

    _repLenEncCounter = _repLenCount;

    _lenPriceEncUpdateTables(_lenEnc, 1 << _pb, _lenProbs);
    _lenPriceEncUpdateTables(_repLenEnc, 1 << _pb, _repLenProbs);
  }

  // LzmaEnc_AllocAndInit
  int _allocAndInit(int keepWindowSize) {
    var i = _kEndPosModelIndex ~/ 2;
    for (; i < _kDicLogSizeMax; i++) {
      if (_dictSize <= (1 << i)) break;
    }
    _distTableSize = i * 2;

    _finished = false;
    _result = szOk;
    _nowPos64 = 0;
    _needInit = true;
    final r = _alloc(keepWindowSize);
    if (r != szOk) return r;
    _init();
    _initPrices();
    return szOk;
  }

  // LzmaEnc_Prepare
  int _prepare(_SeqOutStream outStream, InStream inStream) {
    _mf.setStream(inStream);
    _rc.outStream = outStream;
    return _allocAndInit(0);
  }

  /// LzmaEnc_PrepareForLzma2
  int prepareForLzma2(InStream inStream, int keepWindowSize) {
    _mf.setStream(inStream);
    return _allocAndInit(keepWindowSize);
  }

  /// LzmaEnc_MemPrepare
  int memPrepare(Uint8List src, int srcOff, int srcLen, int keepWindowSize) {
    _mf.setDirectInputBuf(src, srcOff, srcLen);
    setDataSize(srcLen);
    return _allocAndInit(keepWindowSize);
  }

  /// LzmaEnc_Finish (nothing to do in the single threaded version).
  void finish() {}

  /// LzmaEnc_GetCurBuf: the window and the index of the first byte not
  /// yet encoded.
  Uint8List get curBufArray => _mf.bufBase;
  int get curBufPos => _mf.buffer - _additionalOffset;

  /// Output of [codeOneMemBlock]: the C *destLen and *unpackSize.
  int memBlockDestLen = 0;
  int memBlockUnpackSize = 0;

  /// LzmaEnc_CodeOneMemBlock. (desiredPackSize == 0) is not allowed.
  int codeOneMemBlock(bool reInit, Uint8List dest, int destPos, int destLen,
      int desiredPackSize, int unpackSize) {
    final outStream = _SeqOutStreamBuf(dest, destPos, destLen);

    _writeEndMark = false;
    _finished = false;
    _result = szOk;

    if (reInit) _init();
    _initPrices();
    _rc.init();
    _rc.outStream = outStream;
    final nowPos64 = _nowPos64;

    final res = _codeOneBlock(desiredPackSize, unpackSize);

    memBlockUnpackSize = (_nowPos64 - nowPos64) & _mask32;
    memBlockDestLen = destLen - outStream.rem;
    if (outStream.overflow) return szErrorOutputEof;

    return res;
  }

  // LzmaEnc_Encode2
  int _encode2(ProgressCallback? progress) {
    int res;
    for (;;) {
      res = _codeOneBlock(0, 0);
      if (res != szOk || _finished) break;
      if (progress != null) progress(_nowPos64, _rc.processedTotal);
    }
    finish();
    return res;
  }

  /// LzmaEnc_Encode: reads [inStream] to its end and writes the LZMA
  /// stream (without the 5 byte properties) to [outStream].
  void encode(OutStream outStream, InStream inStream,
      {ProgressCallback? progress}) {
    var res = _prepare(_OutStreamWrap(outStream), inStream);
    if (res == szOk) res = _encode2(progress);
    _throwIfError(res);
  }

  /// LzmaEnc_MemEncode: encodes src[srcOff, srcOff + srcLen) with the
  /// match finder reading the buffer directly (no window copy).
  void memEncode(OutStream outStream, Uint8List src,
      {int srcOff = 0,
      int? srcLen,
      bool? writeEndMark,
      ProgressCallback? progress}) {
    final len = srcLen ?? src.length - srcOff;
    if (writeEndMark != null) _writeEndMark = writeEndMark;
    _rc.outStream = _OutStreamWrap(outStream);
    var res = memPrepare(src, srcOff, len, 0);
    if (res == szOk) {
      res = _encode2(progress);
      if (res == szOk && _nowPos64 != len) res = szErrorFail;
    }
    _throwIfError(res);
  }

  /// Number of input bytes encoded so far.
  int get nowPos64 => _nowPos64;

  static void _throwIfError(int res) {
    if (res == szOk) return;
    if (res == szErrorParam) {
      throw const SevenZipException(
          'LZMA encoder: unsupported parameters', SevenZipError.unsupported);
    }
    if (res == szErrorWrite) {
      throw const SevenZipException(
          'LZMA encoder: write error', SevenZipError.io);
    }
    throw SevenZipException('LZMA encoder error $res');
  }

  /// LzmaEnc_Destroy: releases the big buffers.
  void destroy() {
    _mf.free();
    _litProbs = Uint16List(0);
    _saveState.litProbs = Uint16List(0);
    _lclp = -1;
  }
}

/// LzmaEncode (one call interface): returns the 5 property bytes and the
/// packed data.
({Uint8List props, Uint8List data}) lzmaEncode(
    Uint8List src, LzmaEncProps props,
    {bool writeEndMark = false, ProgressCallback? progress}) {
  final p = LzmaEnc();
  p.setProps(props);
  final propsEncoded = p.writeProperties();
  final out = MemoryOutStream(src.length ~/ 2 + 1024);
  p.memEncode(out, src, writeEndMark: writeEndMark, progress: progress);
  p.destroy();
  return (props: propsEncoded, data: out.toBytes());
}
