// Port of C/LzmaDec.c (LZMA SDK 26.01): the streaming LZMA decoder
// (LzmaDec_DecodeToDic / LzmaDec_DecodeToBuf with finish modes and status),
// plus the SRes codes of 7zTypes.h shared by the LZMA and LZMA2 coders.
//
// The C decoder reads its input through a pointer that points either into
// the caller's buffer or into p.tempBuf. Here the pair (_buf, _bufPos)
// plays that role.

import 'dart:typed_data';

// SRes codes (7zTypes.h).
const int szOk = 0; // SZ_OK
const int szErrorData = 1; // SZ_ERROR_DATA
const int szErrorMem = 2; // SZ_ERROR_MEM
const int szErrorUnsupported = 4; // SZ_ERROR_UNSUPPORTED
const int szErrorParam = 5; // SZ_ERROR_PARAM
const int szErrorInputEof = 6; // SZ_ERROR_INPUT_EOF
const int szErrorOutputEof = 7; // SZ_ERROR_OUTPUT_EOF
const int szErrorRead = 8; // SZ_ERROR_READ
const int szErrorWrite = 9; // SZ_ERROR_WRITE
const int szErrorProgress = 10; // SZ_ERROR_PROGRESS
const int szErrorFail = 11; // SZ_ERROR_FAIL

// ELzmaFinishMode
const int lzmaFinishAny = 0; // LZMA_FINISH_ANY
const int lzmaFinishEnd = 1; // LZMA_FINISH_END

// ELzmaStatus
const int lzmaStatusNotSpecified = 0; // LZMA_STATUS_NOT_SPECIFIED
const int lzmaStatusFinishedWithMark = 1; // LZMA_STATUS_FINISHED_WITH_MARK
const int lzmaStatusNotFinished = 2; // LZMA_STATUS_NOT_FINISHED
const int lzmaStatusNeedsMoreInput = 3; // LZMA_STATUS_NEEDS_MORE_INPUT
// LZMA_STATUS_MAYBE_FINISHED_WITHOUT_MARK
const int lzmaStatusMaybeFinishedWithoutMark = 4;

const int lzmaPropsSize = 5; // LZMA_PROPS_SIZE
const int lzmaRequiredInputMax = 20; // LZMA_REQUIRED_INPUT_MAX

const int _kTopValue = 1 << 24;
const int _kNumBitModelTotalBits = 11;
const int _kBitModelTotal = 1 << _kNumBitModelTotalBits;
const int _kNumMoveBits = 5;
const int _rcInitSize = 5;

const int _kNumPosBitsMax = 4;
const int _kNumPosStatesMax = 1 << _kNumPosBitsMax;
const int _kLenNumLowBits = 3;
const int _kLenNumLowSymbols = 1 << _kLenNumLowBits;
const int _kLenNumHighBits = 8;
const int _kLenNumHighSymbols = 1 << _kLenNumHighBits;

const int _lenLow = 0;
const int _lenHigh = _lenLow + 2 * (_kNumPosStatesMax << _kLenNumLowBits);
const int _kNumLenProbs = _lenHigh + _kLenNumHighSymbols;
const int _lenChoice = _lenLow;
const int _lenChoice2 = _lenLow + (1 << _kLenNumLowBits);

const int _kNumStates = 12;
const int _kNumStates2 = 16;
const int _kNumLitStates = 7;

const int _kStartPosModelIndex = 4;
const int _kEndPosModelIndex = 14;
const int _kNumFullDistances = 1 << (_kEndPosModelIndex >> 1);

const int _kNumPosSlotBits = 6;
const int _kNumLenToPosStates = 4;

const int _kNumAlignBits = 4;
const int _kAlignTableSize = 1 << _kNumAlignBits;

const int _kMatchMinLen = 2;
const int _kMatchSpecLenStart =
    _kMatchMinLen + _kLenNumLowSymbols * 2 + _kLenNumHighSymbols;

const int _kMatchSpecLenErrorData = 1 << 9;
const int _kMatchSpecLenErrorFail = _kMatchSpecLenErrorData - 1;

// Probability array layout. The C code addresses it from probs_1664
// (kStartOffset = 1664, so Align is at 0 there); here the offsets are
// absolute indexes into probs.
const int _specPos = 0;
const int _isRep0Long = _specPos + _kNumFullDistances;
const int _repLenCoder = _isRep0Long + (_kNumStates2 << _kNumPosBitsMax);
const int _lenCoder = _repLenCoder + _kNumLenProbs;
const int _isMatch = _lenCoder + _kNumLenProbs;
const int _align = _isMatch + (_kNumStates2 << _kNumPosBitsMax);
const int _isRep = _align + _kAlignTableSize;
const int _isRepG0 = _isRep + _kNumStates;
const int _isRepG1 = _isRepG0 + _kNumStates;
const int _isRepG2 = _isRepG1 + _kNumStates;
const int _posSlot = _isRepG2 + _kNumStates;
const int _literal = _posSlot + (_kNumLenToPosStates << _kNumPosSlotBits);
const int _numBaseProbs = _literal;

const int _lzmaLitSize = 0x300;
const int _lzmaDicMin = 1 << 12;

// kBadRepCode
const int _kBadRepCode = 0xC0000000 - 0x400;

// ELzmaDummy
const int _dummyInputEof = 0;
const int _dummyLit = 1;
const int _dummyMatch = 2;
const int _dummyRep = 3;

/// CLzmaProps
class LzmaProps {
  final int lc;
  final int lp;
  final int pb;
  final int dicSize;
  const LzmaProps(this.lc, this.lp, this.pb, this.dicSize);

  /// LzmaProps_Decode. Returns null for unsupported properties.
  static LzmaProps? decode(Uint8List data, [int off = 0, int? size]) {
    size ??= data.length - off;
    if (size < lzmaPropsSize) return null;
    var dicSize = data[off + 1] |
        (data[off + 2] << 8) |
        (data[off + 3] << 16) |
        (data[off + 4] << 24);
    if (dicSize < _lzmaDicMin) dicSize = _lzmaDicMin;
    var d = data[off];
    if (d >= 9 * 5 * 5) return null;
    final lc = d % 9;
    d ~/= 9;
    return LzmaProps(lc, d % 5, d ~/ 5, dicSize);
  }

  // LzmaProps_GetNumProbs
  int get numProbs => _numBaseProbs + (_lzmaLitSize << (lc + lp));
}

/// CLzmaDec
class LzmaDec {
  int lc = 0;
  int lp = 0;
  int pb = 0;
  int dicSize = 0;

  Uint16List probs = Uint16List(0);
  Uint8List dic = Uint8List(0);
  int dicBufSize = 0;
  int dicPos = 0;

  Uint8List _buf = Uint8List(0);
  int _bufPos = 0;

  int range = 0;
  int code = 0;
  int processedPos = 0;
  int checkDicSize = 0;
  int rep0 = 1;
  int rep1 = 1;
  int rep2 = 1;
  int rep3 = 1;
  int state = 0;
  int remainLen = 0;

  int numProbs = 0;
  int tempBufSize = 0;
  final Uint8List tempBuf = Uint8List(lzmaRequiredInputMax);

  /// Output of [decodeToDic] / [decodeToBuf]: ELzmaStatus.
  int status = lzmaStatusNotSpecified;

  /// Output of [decodeToDic] / [decodeToBuf]: input bytes consumed
  /// (the C *srcLen after the call).
  int srcProcessed = 0;

  /// Output of [decodeToBuf]: bytes written (the C *destLen).
  int destProcessed = 0;

  // LzmaDec_DecodeReal_3
  int _decodeReal(int limit, int bufLimit) {
    final probs = this.probs;
    var state = this.state;
    var rep0 = this.rep0, rep1 = this.rep1, rep2 = this.rep2;
    var rep3 = this.rep3;
    final pbMask = (1 << pb) - 1;
    final lc = this.lc;
    final lpMask = (0x100 << lp) - (0x100 >> lc);

    final dic = this.dic;
    final dicBufSize = this.dicBufSize;
    var dicPos = this.dicPos;

    var processedPos = this.processedPos;
    final checkDicSize = this.checkDicSize;
    var len = 0;

    final buf = _buf;
    var bufPos = _bufPos;
    var range = this.range;
    var code = this.code;

    // The range coder keeps (code <= range), so (code << 8) and
    // (range << 8) never exceed 32 bits after a normalization.
    do {
      int bound;
      int ttt;
      final posState = (processedPos & pbMask) << 4;

      var prob = _isMatch + posState + state;
      ttt = probs[prob];
      if (range < _kTopValue) {
        range <<= 8;
        code = (code << 8) | buf[bufPos++];
      }
      bound = (range >> _kNumBitModelTotalBits) * ttt;
      if (code < bound) {
        range = bound;
        probs[prob] = ttt + ((_kBitModelTotal - ttt) >> _kNumMoveBits);
        prob = _literal;
        if (processedPos != 0 || checkDicSize != 0) {
          prob += 3 *
              ((((processedPos << 8) +
                          dic[(dicPos == 0 ? dicBufSize : dicPos) - 1]) &
                      lpMask) <<
                  lc);
        }
        processedPos++;

        var symbol = 1;
        if (state < _kNumLitStates) {
          state -= (state < 4) ? state : 3;
          do {
            ttt = probs[prob + symbol];
            if (range < _kTopValue) {
              range <<= 8;
              code = (code << 8) | buf[bufPos++];
            }
            bound = (range >> _kNumBitModelTotalBits) * ttt;
            if (code < bound) {
              range = bound;
              probs[prob + symbol] =
                  ttt + ((_kBitModelTotal - ttt) >> _kNumMoveBits);
              symbol += symbol;
            } else {
              range -= bound;
              code -= bound;
              probs[prob + symbol] = ttt - (ttt >> _kNumMoveBits);
              symbol += symbol + 1;
            }
          } while (symbol < 0x100);
        } else {
          var matchByte = dic[dicPos - rep0 + (dicPos < rep0 ? dicBufSize : 0)];
          var offs = 0x100;
          state -= (state < 10) ? 3 : 6;
          do {
            matchByte += matchByte;
            final bit = offs;
            offs &= matchByte;
            final probLit = prob + offs + bit + symbol;
            ttt = probs[probLit];
            if (range < _kTopValue) {
              range <<= 8;
              code = (code << 8) | buf[bufPos++];
            }
            bound = (range >> _kNumBitModelTotalBits) * ttt;
            if (code < bound) {
              range = bound;
              probs[probLit] = ttt + ((_kBitModelTotal - ttt) >> _kNumMoveBits);
              symbol += symbol;
              offs ^= bit;
            } else {
              range -= bound;
              code -= bound;
              probs[probLit] = ttt - (ttt >> _kNumMoveBits);
              symbol += symbol + 1;
            }
          } while (symbol < 0x100);
        }

        dic[dicPos++] = symbol;
        continue;
      }

      range -= bound;
      code -= bound;
      probs[prob] = ttt - (ttt >> _kNumMoveBits);
      prob = _isRep + state;
      ttt = probs[prob];
      if (range < _kTopValue) {
        range <<= 8;
        code = (code << 8) | buf[bufPos++];
      }
      bound = (range >> _kNumBitModelTotalBits) * ttt;
      if (code < bound) {
        range = bound;
        probs[prob] = ttt + ((_kBitModelTotal - ttt) >> _kNumMoveBits);
        state += _kNumStates;
        prob = _lenCoder;
      } else {
        range -= bound;
        code -= bound;
        probs[prob] = ttt - (ttt >> _kNumMoveBits);
        prob = _isRepG0 + state;
        ttt = probs[prob];
        if (range < _kTopValue) {
          range <<= 8;
          code = (code << 8) | buf[bufPos++];
        }
        bound = (range >> _kNumBitModelTotalBits) * ttt;
        if (code < bound) {
          range = bound;
          probs[prob] = ttt + ((_kBitModelTotal - ttt) >> _kNumMoveBits);
          prob = _isRep0Long + posState + state;
          ttt = probs[prob];
          if (range < _kTopValue) {
            range <<= 8;
            code = (code << 8) | buf[bufPos++];
          }
          bound = (range >> _kNumBitModelTotalBits) * ttt;
          if (code < bound) {
            range = bound;
            probs[prob] = ttt + ((_kBitModelTotal - ttt) >> _kNumMoveBits);
            dic[dicPos] = dic[dicPos - rep0 + (dicPos < rep0 ? dicBufSize : 0)];
            dicPos++;
            processedPos++;
            state = state < _kNumLitStates ? 9 : 11;
            continue;
          }
          range -= bound;
          code -= bound;
          probs[prob] = ttt - (ttt >> _kNumMoveBits);
        } else {
          int distance;
          range -= bound;
          code -= bound;
          probs[prob] = ttt - (ttt >> _kNumMoveBits);
          prob = _isRepG1 + state;
          ttt = probs[prob];
          if (range < _kTopValue) {
            range <<= 8;
            code = (code << 8) | buf[bufPos++];
          }
          bound = (range >> _kNumBitModelTotalBits) * ttt;
          if (code < bound) {
            range = bound;
            probs[prob] = ttt + ((_kBitModelTotal - ttt) >> _kNumMoveBits);
            distance = rep1;
          } else {
            range -= bound;
            code -= bound;
            probs[prob] = ttt - (ttt >> _kNumMoveBits);
            prob = _isRepG2 + state;
            ttt = probs[prob];
            if (range < _kTopValue) {
              range <<= 8;
              code = (code << 8) | buf[bufPos++];
            }
            bound = (range >> _kNumBitModelTotalBits) * ttt;
            if (code < bound) {
              range = bound;
              probs[prob] = ttt + ((_kBitModelTotal - ttt) >> _kNumMoveBits);
              distance = rep2;
            } else {
              range -= bound;
              code -= bound;
              probs[prob] = ttt - (ttt >> _kNumMoveBits);
              distance = rep3;
              rep3 = rep2;
            }
            rep2 = rep1;
          }
          rep1 = rep0;
          rep0 = distance;
        }
        state = state < _kNumLitStates ? 8 : 11;
        prob = _repLenCoder;
      }

      // Length decoder (the non Z7_LZMA_SIZE_OPT variant).
      {
        var probLen = prob + _lenChoice;
        ttt = probs[probLen];
        if (range < _kTopValue) {
          range <<= 8;
          code = (code << 8) | buf[bufPos++];
        }
        bound = (range >> _kNumBitModelTotalBits) * ttt;
        int limitBits;
        int offset;
        if (code < bound) {
          range = bound;
          probs[probLen] = ttt + ((_kBitModelTotal - ttt) >> _kNumMoveBits);
          probLen = prob + _lenLow + posState;
          limitBits = 1 << _kLenNumLowBits;
          offset = 0;
        } else {
          range -= bound;
          code -= bound;
          probs[probLen] = ttt - (ttt >> _kNumMoveBits);
          probLen = prob + _lenChoice2;
          ttt = probs[probLen];
          if (range < _kTopValue) {
            range <<= 8;
            code = (code << 8) | buf[bufPos++];
          }
          bound = (range >> _kNumBitModelTotalBits) * ttt;
          if (code < bound) {
            range = bound;
            probs[probLen] = ttt + ((_kBitModelTotal - ttt) >> _kNumMoveBits);
            probLen = prob + _lenLow + posState + (1 << _kLenNumLowBits);
            limitBits = 1 << _kLenNumLowBits;
            offset = _kLenNumLowSymbols;
          } else {
            range -= bound;
            code -= bound;
            probs[probLen] = ttt - (ttt >> _kNumMoveBits);
            probLen = prob + _lenHigh;
            limitBits = 1 << _kLenNumHighBits;
            offset = _kLenNumLowSymbols * 2;
          }
        }
        // TREE_DECODE
        len = 1;
        do {
          ttt = probs[probLen + len];
          if (range < _kTopValue) {
            range <<= 8;
            code = (code << 8) | buf[bufPos++];
          }
          bound = (range >> _kNumBitModelTotalBits) * ttt;
          if (code < bound) {
            range = bound;
            probs[probLen + len] =
                ttt + ((_kBitModelTotal - ttt) >> _kNumMoveBits);
            len += len;
          } else {
            range -= bound;
            code -= bound;
            probs[probLen + len] = ttt - (ttt >> _kNumMoveBits);
            len += len + 1;
          }
        } while (len < limitBits);
        len = len - limitBits + offset;
      }

      if (state >= _kNumStates) {
        int distance;
        prob = _posSlot +
            ((len < _kNumLenToPosStates ? len : _kNumLenToPosStates - 1) <<
                _kNumPosSlotBits);
        // TREE_6_DECODE
        distance = 1;
        do {
          ttt = probs[prob + distance];
          if (range < _kTopValue) {
            range <<= 8;
            code = (code << 8) | buf[bufPos++];
          }
          bound = (range >> _kNumBitModelTotalBits) * ttt;
          if (code < bound) {
            range = bound;
            probs[prob + distance] =
                ttt + ((_kBitModelTotal - ttt) >> _kNumMoveBits);
            distance += distance;
          } else {
            range -= bound;
            code -= bound;
            probs[prob + distance] = ttt - (ttt >> _kNumMoveBits);
            distance += distance + 1;
          }
        } while (distance < 0x40);
        distance -= 0x40;

        if (distance >= _kStartPosModelIndex) {
          final posSlot = distance;
          var numDirectBits = (distance >> 1) - 1;
          distance = 2 | (distance & 1);
          if (posSlot < _kEndPosModelIndex) {
            distance <<= numDirectBits;
            prob = _specPos;
            var m = 1;
            distance++;
            do {
              // REV_BIT_VAR
              final p2 = prob + distance;
              ttt = probs[p2];
              if (range < _kTopValue) {
                range <<= 8;
                code = (code << 8) | buf[bufPos++];
              }
              bound = (range >> _kNumBitModelTotalBits) * ttt;
              if (code < bound) {
                range = bound;
                probs[p2] = ttt + ((_kBitModelTotal - ttt) >> _kNumMoveBits);
                distance += m;
                m += m;
              } else {
                range -= bound;
                code -= bound;
                probs[p2] = ttt - (ttt >> _kNumMoveBits);
                m += m;
                distance += m;
              }
            } while (--numDirectBits != 0);
            distance -= m;
          } else {
            numDirectBits -= _kNumAlignBits;
            do {
              if (range < _kTopValue) {
                range <<= 8;
                code = (code << 8) | buf[bufPos++];
              }
              range >>= 1;
              code -= range;
              final t = code >> 63; // 0 or -1: (0 - ((UInt32)code >> 31))
              distance = (distance << 1) + (t + 1);
              code += range & t;
            } while (--numDirectBits != 0);
            prob = _align;
            distance <<= _kNumAlignBits;
            var i = 1;
            // REV_BIT_CONST(prob, i, 1), (2), (4), REV_BIT_LAST(8)
            for (var m = 1; m <= 8; m += m) {
              ttt = probs[prob + i];
              if (range < _kTopValue) {
                range <<= 8;
                code = (code << 8) | buf[bufPos++];
              }
              bound = (range >> _kNumBitModelTotalBits) * ttt;
              if (code < bound) {
                range = bound;
                probs[prob + i] =
                    ttt + ((_kBitModelTotal - ttt) >> _kNumMoveBits);
                if (m == 8) {
                  i -= m;
                } else {
                  i += m;
                }
              } else {
                range -= bound;
                code -= bound;
                probs[prob + i] = ttt - (ttt >> _kNumMoveBits);
                if (m != 8) i += m * 2;
              }
            }
            distance |= i;
            if (distance == 0xFFFFFFFF) {
              len = _kMatchSpecLenStart;
              state -= _kNumStates;
              break;
            }
          }
        }

        rep3 = rep2;
        rep2 = rep1;
        rep1 = rep0;
        rep0 = distance + 1;
        state = (state < _kNumStates + _kNumLitStates)
            ? _kNumLitStates
            : _kNumLitStates + 3;
        if (distance >= (checkDicSize == 0 ? processedPos : checkDicSize)) {
          len += _kMatchSpecLenErrorData + _kMatchMinLen;
          break;
        }
      }

      len += _kMatchMinLen;

      {
        final rem = limit - dicPos;
        if (rem == 0) break;

        var curLen = rem < len ? rem : len;
        var pos = dicPos - rep0 + (dicPos < rep0 ? dicBufSize : 0);

        processedPos += curLen;

        len -= curLen;
        if (curLen <= dicBufSize - pos) {
          if (rep0 >= curLen) {
            dic.setRange(dicPos, dicPos + curLen, dic, pos);
            dicPos += curLen;
          } else {
            final lim = dicPos + curLen;
            final src = pos - dicPos;
            do {
              dic[dicPos] = dic[dicPos + src];
            } while (++dicPos != lim);
          }
        } else {
          do {
            dic[dicPos++] = dic[pos];
            if (++pos == dicBufSize) pos = 0;
          } while (--curLen != 0);
        }
      }
    } while (dicPos < limit && bufPos < bufLimit);

    if (range < _kTopValue) {
      range <<= 8;
      code = (code << 8) | buf[bufPos++];
    }

    _bufPos = bufPos;
    this.range = range;
    this.code = code;
    remainLen = len;
    this.dicPos = dicPos;
    this.processedPos = processedPos & 0xFFFFFFFF;
    this.rep0 = rep0;
    this.rep1 = rep1;
    this.rep2 = rep2;
    this.rep3 = rep3;
    this.state = state;
    if (len >= _kMatchSpecLenErrorData) return szErrorData;
    return szOk;
  }

  // LzmaDec_WriteRem
  void _writeRem(int limit) {
    var len = remainLen;
    if (len == 0) return;
    var dicPos = this.dicPos;
    {
      final rem = limit - dicPos;
      if (rem < len) {
        len = rem;
        if (len == 0) return;
      }
    }

    if (checkDicSize == 0 && dicSize - processedPos <= len) {
      checkDicSize = dicSize;
    }

    processedPos = (processedPos + len) & 0xFFFFFFFF;
    remainLen -= len;
    final dic = this.dic;
    final rep0 = this.rep0;
    final dicBufSize = this.dicBufSize;
    do {
      dic[dicPos] = dic[dicPos - rep0 + (dicPos < rep0 ? dicBufSize : 0)];
      dicPos++;
    } while (--len != 0);
    this.dicPos = dicPos;
  }

  // LzmaDec_DecodeReal2
  int _decodeReal2(int limit, int bufLimit) {
    if (checkDicSize == 0) {
      final rem = dicSize - processedPos;
      if (limit - dicPos > rem) limit = dicPos + rem;
    }
    final res = _decodeReal(limit, bufLimit);
    if (checkDicSize == 0 && processedPos >= dicSize) checkDicSize = dicSize;
    return res;
  }

  // Output of _tryDummy: the C *bufOut.
  int _dummyBufOut = 0;

  // LzmaDec_TryDummy. [bufPos] and [bufLimit] index [buf].
  int _tryDummy(Uint8List buf, int bufPos, int bufLimit) {
    var range = this.range;
    var code = this.code;
    final probs = this.probs;
    var state = this.state;
    int res;

    // NORMALIZE_CHECK, returns false on DUMMY_INPUT_EOF.
    for (;;) {
      int prob;
      int bound;
      int ttt;
      final posState = (processedPos & ((1 << pb) - 1)) << 4;

      prob = _isMatch + posState + state;
      ttt = probs[prob];
      if (range < _kTopValue) {
        if (bufPos >= bufLimit) return _dummyInputEof;
        range <<= 8;
        code = (code << 8) | buf[bufPos++];
      }
      bound = (range >> _kNumBitModelTotalBits) * ttt;
      if (code < bound) {
        range = bound;

        prob = _literal;
        if (checkDicSize != 0 || processedPos != 0) {
          prob += _lzmaLitSize *
              (((processedPos & ((1 << lp) - 1)) << lc) +
                  (dic[(dicPos == 0 ? dicBufSize : dicPos) - 1] >> (8 - lc)));
        }

        if (state < _kNumLitStates) {
          var symbol = 1;
          do {
            ttt = probs[prob + symbol];
            if (range < _kTopValue) {
              if (bufPos >= bufLimit) return _dummyInputEof;
              range <<= 8;
              code = (code << 8) | buf[bufPos++];
            }
            bound = (range >> _kNumBitModelTotalBits) * ttt;
            if (code < bound) {
              range = bound;
              symbol += symbol;
            } else {
              range -= bound;
              code -= bound;
              symbol += symbol + 1;
            }
          } while (symbol < 0x100);
        } else {
          var matchByte = dic[dicPos - rep0 + (dicPos < rep0 ? dicBufSize : 0)];
          var offs = 0x100;
          var symbol = 1;
          do {
            matchByte += matchByte;
            final bit = offs;
            offs &= matchByte;
            final probLit = prob + offs + bit + symbol;
            ttt = probs[probLit];
            if (range < _kTopValue) {
              if (bufPos >= bufLimit) return _dummyInputEof;
              range <<= 8;
              code = (code << 8) | buf[bufPos++];
            }
            bound = (range >> _kNumBitModelTotalBits) * ttt;
            if (code < bound) {
              range = bound;
              symbol += symbol;
              offs ^= bit;
            } else {
              range -= bound;
              code -= bound;
              symbol += symbol + 1;
            }
          } while (symbol < 0x100);
        }
        res = _dummyLit;
      } else {
        int len;
        range -= bound;
        code -= bound;

        prob = _isRep + state;
        ttt = probs[prob];
        if (range < _kTopValue) {
          if (bufPos >= bufLimit) return _dummyInputEof;
          range <<= 8;
          code = (code << 8) | buf[bufPos++];
        }
        bound = (range >> _kNumBitModelTotalBits) * ttt;
        if (code < bound) {
          range = bound;
          state = 0;
          prob = _lenCoder;
          res = _dummyMatch;
        } else {
          range -= bound;
          code -= bound;
          res = _dummyRep;
          prob = _isRepG0 + state;
          ttt = probs[prob];
          if (range < _kTopValue) {
            if (bufPos >= bufLimit) return _dummyInputEof;
            range <<= 8;
            code = (code << 8) | buf[bufPos++];
          }
          bound = (range >> _kNumBitModelTotalBits) * ttt;
          if (code < bound) {
            range = bound;
            prob = _isRep0Long + posState + state;
            ttt = probs[prob];
            if (range < _kTopValue) {
              if (bufPos >= bufLimit) return _dummyInputEof;
              range <<= 8;
              code = (code << 8) | buf[bufPos++];
            }
            bound = (range >> _kNumBitModelTotalBits) * ttt;
            if (code < bound) {
              range = bound;
              break;
            } else {
              range -= bound;
              code -= bound;
            }
          } else {
            range -= bound;
            code -= bound;
            prob = _isRepG1 + state;
            ttt = probs[prob];
            if (range < _kTopValue) {
              if (bufPos >= bufLimit) return _dummyInputEof;
              range <<= 8;
              code = (code << 8) | buf[bufPos++];
            }
            bound = (range >> _kNumBitModelTotalBits) * ttt;
            if (code < bound) {
              range = bound;
            } else {
              range -= bound;
              code -= bound;
              prob = _isRepG2 + state;
              ttt = probs[prob];
              if (range < _kTopValue) {
                if (bufPos >= bufLimit) return _dummyInputEof;
                range <<= 8;
                code = (code << 8) | buf[bufPos++];
              }
              bound = (range >> _kNumBitModelTotalBits) * ttt;
              if (code < bound) {
                range = bound;
              } else {
                range -= bound;
                code -= bound;
              }
            }
          }
          state = _kNumStates;
          prob = _repLenCoder;
        }
        {
          int limit;
          int offset;
          var probLen = prob + _lenChoice;
          ttt = probs[probLen];
          if (range < _kTopValue) {
            if (bufPos >= bufLimit) return _dummyInputEof;
            range <<= 8;
            code = (code << 8) | buf[bufPos++];
          }
          bound = (range >> _kNumBitModelTotalBits) * ttt;
          if (code < bound) {
            range = bound;
            probLen = prob + _lenLow + posState;
            offset = 0;
            limit = 1 << _kLenNumLowBits;
          } else {
            range -= bound;
            code -= bound;
            probLen = prob + _lenChoice2;
            ttt = probs[probLen];
            if (range < _kTopValue) {
              if (bufPos >= bufLimit) return _dummyInputEof;
              range <<= 8;
              code = (code << 8) | buf[bufPos++];
            }
            bound = (range >> _kNumBitModelTotalBits) * ttt;
            if (code < bound) {
              range = bound;
              probLen = prob + _lenLow + posState + (1 << _kLenNumLowBits);
              offset = _kLenNumLowSymbols;
              limit = 1 << _kLenNumLowBits;
            } else {
              range -= bound;
              code -= bound;
              probLen = prob + _lenHigh;
              offset = _kLenNumLowSymbols * 2;
              limit = 1 << _kLenNumHighBits;
            }
          }
          // TREE_DECODE_CHECK
          len = 1;
          do {
            ttt = probs[probLen + len];
            if (range < _kTopValue) {
              if (bufPos >= bufLimit) return _dummyInputEof;
              range <<= 8;
              code = (code << 8) | buf[bufPos++];
            }
            bound = (range >> _kNumBitModelTotalBits) * ttt;
            if (code < bound) {
              range = bound;
              len += len;
            } else {
              range -= bound;
              code -= bound;
              len += len + 1;
            }
          } while (len < limit);
          len -= limit;
          len += offset;
        }

        if (state < 4) {
          prob = _posSlot +
              ((len < _kNumLenToPosStates - 1
                      ? len
                      : _kNumLenToPosStates - 1) <<
                  _kNumPosSlotBits);
          var posSlot = 1;
          do {
            ttt = probs[prob + posSlot];
            if (range < _kTopValue) {
              if (bufPos >= bufLimit) return _dummyInputEof;
              range <<= 8;
              code = (code << 8) | buf[bufPos++];
            }
            bound = (range >> _kNumBitModelTotalBits) * ttt;
            if (code < bound) {
              range = bound;
              posSlot += posSlot;
            } else {
              range -= bound;
              code -= bound;
              posSlot += posSlot + 1;
            }
          } while (posSlot < (1 << _kNumPosSlotBits));
          posSlot -= 1 << _kNumPosSlotBits;
          if (posSlot >= _kStartPosModelIndex) {
            var numDirectBits = (posSlot >> 1) - 1;

            if (posSlot < _kEndPosModelIndex) {
              prob = _specPos + ((2 | (posSlot & 1)) << numDirectBits);
            } else {
              numDirectBits -= _kNumAlignBits;
              do {
                if (range < _kTopValue) {
                  if (bufPos >= bufLimit) return _dummyInputEof;
                  range <<= 8;
                  code = (code << 8) | buf[bufPos++];
                }
                range >>= 1;
                if (code >= range) code -= range;
              } while (--numDirectBits != 0);
              prob = _align;
              numDirectBits = _kNumAlignBits;
            }
            var i = 1;
            var m = 1;
            do {
              // REV_BIT_CHECK
              ttt = probs[prob + i];
              if (range < _kTopValue) {
                if (bufPos >= bufLimit) return _dummyInputEof;
                range <<= 8;
                code = (code << 8) | buf[bufPos++];
              }
              bound = (range >> _kNumBitModelTotalBits) * ttt;
              if (code < bound) {
                range = bound;
                i += m;
                m += m;
              } else {
                range -= bound;
                code -= bound;
                m += m;
                i += m;
              }
            } while (--numDirectBits != 0);
          }
        }
      }
      break;
    }
    if (range < _kTopValue) {
      if (bufPos >= bufLimit) return _dummyInputEof;
      range <<= 8;
      code = (code << 8) | buf[bufPos++];
    }

    _dummyBufOut = bufPos;
    return res;
  }

  /// LzmaDec_InitDicAndState
  void initDicAndState(bool initDic, bool initState) {
    remainLen = _kMatchSpecLenStart + 1;
    tempBufSize = 0;

    if (initDic) {
      processedPos = 0;
      checkDicSize = 0;
      remainLen = _kMatchSpecLenStart + 2;
    }
    if (initState) remainLen = _kMatchSpecLenStart + 2;
  }

  /// LzmaDec_Init
  void init() {
    dicPos = 0;
    initDicAndState(true, true);
  }

  /// LzmaDec_DecodeToDic. Decodes from src[srcPos, srcPos + srcLen) into
  /// [dic] up to [dicLimit]. Returns an SRes code and sets [srcProcessed]
  /// and [status].
  int decodeToDic(
      int dicLimit, Uint8List src, int srcPos, int srcLen, int finishMode) {
    var inSize = srcLen;
    srcProcessed = 0;
    status = lzmaStatusNotSpecified;

    if (remainLen > _kMatchSpecLenStart) {
      if (remainLen > _kMatchSpecLenStart + 2) {
        return remainLen == _kMatchSpecLenErrorFail ? szErrorFail : szErrorData;
      }

      for (;
          inSize > 0 && tempBufSize < _rcInitSize;
          srcProcessed++, inSize--) {
        tempBuf[tempBufSize++] = src[srcPos++];
      }
      if (tempBufSize != 0 && tempBuf[0] != 0) return szErrorData;
      if (tempBufSize < _rcInitSize) {
        status = lzmaStatusNeedsMoreInput;
        return szOk;
      }
      code = (tempBuf[1] << 24) |
          (tempBuf[2] << 16) |
          (tempBuf[3] << 8) |
          tempBuf[4];

      if (checkDicSize == 0 && processedPos == 0 && code >= _kBadRepCode) {
        return szErrorData;
      }

      range = 0xFFFFFFFF;
      tempBufSize = 0;

      if (remainLen > _kMatchSpecLenStart + 1) {
        final n = numProbsFor(lc, lp);
        probs.fillRange(0, n, _kBitModelTotal >> 1);
        rep0 = rep1 = rep2 = rep3 = 1;
        state = 0;
      }

      remainLen = 0;
    }

    for (;;) {
      if (remainLen == _kMatchSpecLenStart) {
        if (code != 0) return szErrorData;
        status = lzmaStatusFinishedWithMark;
        return szOk;
      }

      _writeRem(dicLimit);

      var checkEndMarkNow = false;

      if (dicPos >= dicLimit) {
        if (remainLen == 0 && code == 0) {
          status = lzmaStatusMaybeFinishedWithoutMark;
          return szOk;
        }
        if (finishMode == lzmaFinishAny) {
          status = lzmaStatusNotFinished;
          return szOk;
        }
        if (remainLen != 0) {
          status = lzmaStatusNotFinished;
          return szErrorData;
        }
        checkEndMarkNow = true;
      }

      if (tempBufSize == 0) {
        int bufLimit;
        var dummyProcessed = -1;

        if (inSize < lzmaRequiredInputMax || checkEndMarkNow) {
          final dummyRes = _tryDummy(src, srcPos, srcPos + inSize);

          if (dummyRes == _dummyInputEof) {
            if (inSize >= lzmaRequiredInputMax) break;
            srcProcessed += inSize;
            tempBufSize = inSize;
            for (var i = 0; i < inSize; i++) {
              tempBuf[i] = src[srcPos + i];
            }
            status = lzmaStatusNeedsMoreInput;
            return szOk;
          }

          dummyProcessed = _dummyBufOut - srcPos;
          if (dummyProcessed > lzmaRequiredInputMax) break;

          if (checkEndMarkNow && dummyRes != _dummyMatch) {
            srcProcessed += dummyProcessed;
            tempBufSize = dummyProcessed;
            for (var i = 0; i < dummyProcessed; i++) {
              tempBuf[i] = src[srcPos + i];
            }
            status = lzmaStatusNotFinished;
            return szErrorData;
          }

          bufLimit = srcPos;
        } else {
          bufLimit = srcPos + inSize - lzmaRequiredInputMax;
        }

        _buf = src;
        _bufPos = srcPos;

        final res = _decodeReal2(dicLimit, bufLimit);
        final processed = _bufPos - srcPos;

        if (dummyProcessed < 0) {
          if (processed > inSize) break;
        } else if (dummyProcessed != processed) {
          break;
        }

        srcPos += processed;
        inSize -= processed;
        srcProcessed += processed;

        if (res != szOk) {
          remainLen = _kMatchSpecLenErrorData;
          return szErrorData;
        }
        continue;
      }

      {
        var rem = tempBufSize;
        var ahead = 0;
        var dummyProcessed = -1;

        while (rem < lzmaRequiredInputMax && ahead < inSize) {
          tempBuf[rem++] = src[srcPos + ahead++];
        }

        if (rem < lzmaRequiredInputMax || checkEndMarkNow) {
          final dummyRes = _tryDummy(tempBuf, 0, rem);

          if (dummyRes == _dummyInputEof) {
            if (rem >= lzmaRequiredInputMax) break;
            tempBufSize = rem;
            srcProcessed += ahead;
            status = lzmaStatusNeedsMoreInput;
            return szOk;
          }

          dummyProcessed = _dummyBufOut;

          if (dummyProcessed < tempBufSize) break;

          if (checkEndMarkNow && dummyRes != _dummyMatch) {
            srcProcessed += dummyProcessed - tempBufSize;
            tempBufSize = dummyProcessed;
            status = lzmaStatusNotFinished;
            return szErrorData;
          }
        }

        _buf = tempBuf;
        _bufPos = 0;

        {
          final res = _decodeReal2(dicLimit, 0);
          var processed = _bufPos;
          rem = tempBufSize;

          if (dummyProcessed < 0) {
            if (processed > lzmaRequiredInputMax) break;
            if (processed < rem) break;
          } else if (dummyProcessed != processed) {
            break;
          }

          processed -= rem;

          srcPos += processed;
          inSize -= processed;
          srcProcessed += processed;
          tempBufSize = 0;

          if (res != szOk) {
            remainLen = _kMatchSpecLenErrorData;
            return szErrorData;
          }
        }
      }
    }

    // Some unexpected error: internal error of code.
    remainLen = _kMatchSpecLenErrorFail;
    return szErrorFail;
  }

  /// LzmaDec_DecodeToBuf. Sets [destProcessed], [srcProcessed], [status].
  int decodeToBuf(Uint8List dest, int destPos, int destLen, Uint8List src,
      int srcPos, int srcLen, int finishMode) {
    var outSize = destLen;
    var inSize = srcLen;
    var totalIn = 0;
    var totalOut = 0;
    for (;;) {
      int outSizeCur;
      int curFinishMode;
      if (dicPos == dicBufSize) dicPos = 0;
      final dicPos0 = dicPos;
      if (outSize > dicBufSize - dicPos0) {
        outSizeCur = dicBufSize;
        curFinishMode = lzmaFinishAny;
      } else {
        outSizeCur = dicPos0 + outSize;
        curFinishMode = finishMode;
      }

      final res = decodeToDic(outSizeCur, src, srcPos, inSize, curFinishMode);
      final inSizeCur = srcProcessed;
      srcPos += inSizeCur;
      inSize -= inSizeCur;
      totalIn += inSizeCur;
      outSizeCur = dicPos - dicPos0;
      dest.setRange(destPos, destPos + outSizeCur, dic, dicPos0);
      destPos += outSizeCur;
      outSize -= outSizeCur;
      totalOut += outSizeCur;
      srcProcessed = totalIn;
      destProcessed = totalOut;
      if (res != szOk) return res;
      if (outSizeCur == 0 || outSize == 0) return szOk;
    }
  }

  /// Number of probabilities for lc/lp (LzmaProps_GetNumProbs).
  static int numProbsFor(int lc, int lp) =>
      _numBaseProbs + (_lzmaLitSize << (lc + lp));

  // LzmaDec_AllocateProbs2
  void _allocateProbs2(LzmaProps propNew) {
    final n = propNew.numProbs;
    if (probs.isEmpty || n != numProbs) {
      probs = Uint16List(n);
      numProbs = n;
    }
  }

  /// LzmaDec_AllocateProbs. Returns an SRes code.
  int allocateProbs(Uint8List props, [int off = 0, int? size]) {
    final propNew = LzmaProps.decode(props, off, size);
    if (propNew == null) return szErrorUnsupported;
    _allocateProbs2(propNew);
    _setProps(propNew);
    return szOk;
  }

  /// LzmaDec_Allocate. When [maxOutSize] is given and smaller than the
  /// dictionary, the dictionary buffer is limited to it (the one call
  /// LzmaDecode interface does the same by decoding into the output buffer).
  int allocate(Uint8List props, {int off = 0, int? size, int? maxOutSize}) {
    final propNew = LzmaProps.decode(props, off, size);
    if (propNew == null) return szErrorUnsupported;
    _allocateProbs2(propNew);
    final dictSize = propNew.dicSize;
    var mask = (1 << 12) - 1;
    if (dictSize >= (1 << 30)) {
      mask = (1 << 22) - 1;
    } else if (dictSize >= (1 << 22)) {
      mask = (1 << 20) - 1;
    }
    var bufSize = (dictSize + mask) & ~mask;
    if (bufSize < dictSize) bufSize = dictSize;
    if (maxOutSize != null && maxOutSize < bufSize) {
      bufSize = maxOutSize < 1 ? 1 : maxOutSize;
    }
    if (dic.length != bufSize) dic = Uint8List(bufSize);
    dicBufSize = bufSize;
    _setProps(propNew);
    return szOk;
  }

  void _setProps(LzmaProps p) {
    lc = p.lc;
    lp = p.lp;
    pb = p.pb;
    dicSize = p.dicSize;
  }

  /// LzmaDec_Free
  void free() {
    probs = Uint16List(0);
    dic = Uint8List(0);
    dicBufSize = 0;
  }
}

/// LzmaDecode (one call interface). Decodes [src] into [dest] (whose
/// length is the output limit). Returns an SRes code; see the returned
/// decoder's [LzmaDec.destProcessed], [LzmaDec.srcProcessed] and
/// [LzmaDec.status] for the details.
({int res, int destLen, int srcLen, int status}) lzmaDecode(
    Uint8List dest, Uint8List src, Uint8List propData, int finishMode) {
  final outSize = dest.length;
  final inSize = src.length;
  if (inSize < _rcInitSize) {
    return (
      res: szErrorInputEof,
      destLen: 0,
      srcLen: 0,
      status: lzmaStatusNotSpecified
    );
  }
  final p = LzmaDec();
  final r = p.allocateProbs(propData);
  if (r != szOk) {
    return (res: r, destLen: 0, srcLen: 0, status: lzmaStatusNotSpecified);
  }
  p.dic = dest;
  p.dicBufSize = outSize;
  p.init();
  var res = p.decodeToDic(outSize, src, 0, inSize, finishMode);
  if (res == szOk && p.status == lzmaStatusNeedsMoreInput) {
    res = szErrorInputEof;
  }
  return (
    res: res,
    destLen: p.dicPos,
    srcLen: p.srcProcessed,
    status: p.status
  );
}
