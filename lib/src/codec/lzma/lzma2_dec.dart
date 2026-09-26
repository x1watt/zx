// Port of C/Lzma2Dec.c (LZMA SDK 26.01): the LZMA2 chunk parser on top of
// the LZMA decoder (Lzma2Dec_DecodeToDic / Lzma2Dec_DecodeToBuf /
// Lzma2Dec_Parse).
//
//   00000000  -  End of data
//   00000001 U U  -  Uncompressed, reset dic, need reset state and set new prop
//   00000010 U U  -  Uncompressed, no reset
//   100uuuuu U U P P  -  LZMA, no reset
//   101uuuuu U U P P  -  LZMA, reset state
//   110uuuuu U U P P S  -  LZMA, reset state + set new prop
//   111uuuuu U U P P S  -  LZMA, reset state + set new prop, reset dic
//
//   u, U - Unpack Size
//   P - Pack Size
//   S - Props

import 'dart:typed_data';

import 'lzma_dec.dart';

const int _lzma2ControlCopyResetDic = 1;
const int _lzma2LclpMax = 4;

// ELzma2State
const int _stateControl = 0;
const int _stateUnpack0 = 1;
const int _stateUnpack1 = 2;
const int _statePack0 = 3;
const int _statePack1 = 4;
const int _stateProp = 5;
const int _stateData = 6;
const int _stateDataCont = 7;
const int _stateFinished = 8;
const int _stateError = 9;

// ELzma2ParseStatus
const int lzma2ParseStatusNewBlock = lzmaStatusMaybeFinishedWithoutMark + 1;
const int lzma2ParseStatusNewChunk = lzmaStatusMaybeFinishedWithoutMark + 2;

/// LZMA2_DIC_SIZE_FROM_PROP, with 40 meaning 0xFFFFFFFF.
int lzma2DictSizeFromProp(int prop) {
  if (prop > 40) {
    throw ArgumentError.value(prop, 'prop', 'LZMA2 property must be <= 40');
  }
  return prop == 40 ? 0xFFFFFFFF : (2 | (prop & 1)) << (prop ~/ 2 + 11);
}

// Lzma2Dec_GetOldProps
Uint8List? _getOldProps(int prop) {
  if (prop > 40) return null;
  final dicSize = lzma2DictSizeFromProp(prop);
  final props = Uint8List(lzmaPropsSize);
  props[0] = _lzma2LclpMax;
  props[1] = dicSize;
  props[2] = dicSize >> 8;
  props[3] = dicSize >> 16;
  props[4] = dicSize >> 24;
  return props;
}

/// CLzma2Dec
class Lzma2Dec {
  int state = _stateControl;
  int control = 0;
  int needInitLevel = 0;
  bool isExtraMode = false;
  int packSize = 0;
  int unpackSize = 0;
  final LzmaDec decoder = LzmaDec();

  /// Output of [decodeToDic] / [decodeToBuf]: ELzmaStatus.
  int status = lzmaStatusNotSpecified;

  /// Output of [decodeToDic] / [decodeToBuf] / [parse]: input consumed.
  int srcProcessed = 0;

  /// Output of [decodeToBuf]: bytes written.
  int destProcessed = 0;

  /// Lzma2Dec_AllocateProbs. Returns an SRes code.
  int allocateProbs(int prop) {
    final props = _getOldProps(prop);
    if (props == null) return szErrorUnsupported;
    return decoder.allocateProbs(props);
  }

  /// Lzma2Dec_Allocate. See [LzmaDec.allocate] for [maxOutSize].
  int allocate(int prop, {int? maxOutSize}) {
    final props = _getOldProps(prop);
    if (props == null) return szErrorUnsupported;
    return decoder.allocate(props, maxOutSize: maxOutSize);
  }

  /// Like [allocate], for a dictionary size given in bytes (as the xz
  /// format and raw LZMA2 users may do).
  int allocateForDictSize(int dictSize, {int? maxOutSize}) {
    final props = Uint8List(lzmaPropsSize);
    props[0] = _lzma2LclpMax;
    props[1] = dictSize;
    props[2] = dictSize >> 8;
    props[3] = dictSize >> 16;
    props[4] = dictSize >> 24;
    return decoder.allocate(props, maxOutSize: maxOutSize);
  }

  /// Lzma2Dec_Init
  void init() {
    state = _stateControl;
    needInitLevel = 0xE0;
    isExtraMode = false;
    unpackSize = 0;
    decoder.init();
  }

  bool get _isUncompressedState => (control & (1 << 7)) == 0;

  // Lzma2Dec_UpdateState
  int _updateState(int b) {
    switch (state) {
      case _stateControl:
        isExtraMode = false;
        control = b;
        if (b == 0) return _stateFinished;
        if (_isUncompressedState) {
          if (b == _lzma2ControlCopyResetDic) {
            needInitLevel = 0xC0;
          } else if (b > 2 || needInitLevel == 0xE0) {
            return _stateError;
          }
        } else {
          if (b < needInitLevel) return _stateError;
          needInitLevel = 0;
          unpackSize = (b & 0x1F) << 16;
        }
        return _stateUnpack0;

      case _stateUnpack0:
        unpackSize |= b << 8;
        return _stateUnpack1;

      case _stateUnpack1:
        unpackSize |= b;
        unpackSize++;
        return _isUncompressedState ? _stateData : _statePack0;

      case _statePack0:
        packSize = b << 8;
        return _statePack1;

      case _statePack1:
        packSize |= b;
        packSize++;
        return (control & 0x40) != 0 ? _stateProp : _stateData;

      case _stateProp:
        {
          if (b >= 9 * 5 * 5) return _stateError;
          final lc = b % 9;
          b ~/= 9;
          decoder.pb = b ~/ 5;
          final lp = b % 5;
          if (lc + lp > _lzma2LclpMax) return _stateError;
          decoder.lc = lc;
          decoder.lp = lp;
          return _stateData;
        }

      default:
        return _stateError;
    }
  }

  // LzmaDec_UpdateWithUncompressed
  static void _updateWithUncompressed(
      LzmaDec p, Uint8List src, int srcPos, int size) {
    p.dic.setRange(p.dicPos, p.dicPos + size, src, srcPos);
    p.dicPos += size;
    if (p.checkDicSize == 0 && p.dicSize - p.processedPos <= size) {
      p.checkDicSize = p.dicSize;
    }
    p.processedPos = (p.processedPos + size) & 0xFFFFFFFF;
  }

  /// Lzma2Dec_DecodeToDic. Returns an SRes code and sets [srcProcessed]
  /// and [status].
  int decodeToDic(
      int dicLimit, Uint8List src, int srcPos, int srcLen, int finishMode) {
    final inSize = srcLen;
    srcProcessed = 0;
    status = lzmaStatusNotSpecified;

    while (state != _stateError) {
      if (state == _stateFinished) {
        status = lzmaStatusFinishedWithMark;
        return szOk;
      }

      final dicPos = decoder.dicPos;

      if (dicPos == dicLimit && finishMode == lzmaFinishAny) {
        status = lzmaStatusNotFinished;
        return szOk;
      }

      if (state != _stateData && state != _stateDataCont) {
        if (srcProcessed == inSize) {
          status = lzmaStatusNeedsMoreInput;
          return szOk;
        }
        srcProcessed++;
        state = _updateState(src[srcPos++]);
        if (dicPos == dicLimit && state != _stateFinished) break;
        continue;
      }

      {
        var inCur = inSize - srcProcessed;
        var outCur = dicLimit - dicPos;
        var curFinishMode = lzmaFinishAny;

        if (outCur >= unpackSize) {
          outCur = unpackSize;
          curFinishMode = lzmaFinishEnd;
        }

        if (_isUncompressedState) {
          if (inCur == 0) {
            status = lzmaStatusNeedsMoreInput;
            return szOk;
          }

          if (state == _stateData) {
            final initDic = control == _lzma2ControlCopyResetDic;
            decoder.initDicAndState(initDic, false);
          }

          if (inCur > outCur) inCur = outCur;
          if (inCur == 0) break;

          _updateWithUncompressed(decoder, src, srcPos, inCur);

          srcPos += inCur;
          srcProcessed += inCur;
          unpackSize -= inCur;
          state = unpackSize == 0 ? _stateControl : _stateDataCont;
        } else {
          if (state == _stateData) {
            final initDic = control >= 0xE0;
            final initState = control >= 0xA0;
            decoder.initDicAndState(initDic, initState);
            state = _stateDataCont;
          }

          if (inCur > packSize) inCur = packSize;

          final res = decoder.decodeToDic(
              dicPos + outCur, src, srcPos, inCur, curFinishMode);
          inCur = decoder.srcProcessed;
          status = decoder.status;

          srcPos += inCur;
          srcProcessed += inCur;
          packSize -= inCur;
          outCur = decoder.dicPos - dicPos;
          unpackSize -= outCur;

          if (res != szOk) break;

          if (status == lzmaStatusNeedsMoreInput) {
            if (packSize == 0) break;
            return szOk;
          }

          if (inCur == 0 && outCur == 0) {
            if (status != lzmaStatusMaybeFinishedWithoutMark ||
                unpackSize != 0 ||
                packSize != 0) {
              break;
            }
            state = _stateControl;
          }

          status = lzmaStatusNotSpecified;
        }
      }
    }

    status = lzmaStatusNotSpecified;
    state = _stateError;
    return szErrorData;
  }

  /// Lzma2Dec_Parse. Returns an ELzma2ParseStatus / ELzmaStatus value and
  /// sets [srcProcessed].
  int parse(int outSize, Uint8List src, int srcPos, int srcLen,
      bool checkFinishBlock) {
    final inSize = srcLen;
    srcProcessed = 0;

    while (state != _stateError) {
      if (state == _stateFinished) return lzmaStatusFinishedWithMark;

      if (outSize == 0 && !checkFinishBlock) return lzmaStatusNotFinished;

      if (state != _stateData && state != _stateDataCont) {
        if (srcProcessed == inSize) return lzmaStatusNeedsMoreInput;
        srcProcessed++;

        state = _updateState(src[srcPos++]);

        if (state == _stateUnpack0) {
          if (control == _lzma2ControlCopyResetDic || control >= 0xE0) {
            return lzma2ParseStatusNewBlock;
          }
        }

        if (outSize == 0 && state != _stateFinished) {
          return lzmaStatusNotFinished;
        }

        if (state == _stateData) return lzma2ParseStatusNewChunk;

        continue;
      }

      if (outSize == 0) return lzmaStatusNotFinished;

      {
        var inCur = inSize - srcProcessed;

        if (_isUncompressedState) {
          if (inCur == 0) return lzmaStatusNeedsMoreInput;
          if (inCur > unpackSize) inCur = unpackSize;
          if (inCur > outSize) inCur = outSize;
          decoder.dicPos += inCur;
          srcPos += inCur;
          srcProcessed += inCur;
          outSize -= inCur;
          unpackSize -= inCur;
          state = unpackSize == 0 ? _stateControl : _stateDataCont;
        } else {
          isExtraMode = true;

          if (inCur == 0) {
            if (packSize != 0) return lzmaStatusNeedsMoreInput;
          } else if (state == _stateData) {
            state = _stateDataCont;
            if (src[srcPos] != 0) {
              // first byte of lzma chunk must be Zero
              srcProcessed += 1;
              packSize--;
              break;
            }
          }

          if (inCur > packSize) inCur = packSize;

          srcPos += inCur;
          srcProcessed += inCur;
          packSize -= inCur;

          if (packSize == 0) {
            var rem = outSize;
            if (rem > unpackSize) rem = unpackSize;
            decoder.dicPos += rem;
            unpackSize -= rem;
            outSize -= rem;
            if (unpackSize == 0) state = _stateControl;
          }
        }
      }
    }

    state = _stateError;
    return lzmaStatusNotSpecified;
  }

  /// Lzma2Dec_GetUnpackExtra
  int get unpackExtra => isExtraMode ? unpackSize : 0;

  /// Lzma2Dec_DecodeToBuf. Sets [destProcessed], [srcProcessed], [status].
  int decodeToBuf(Uint8List dest, int destPos, int destLen, Uint8List src,
      int srcPos, int srcLen, int finishMode) {
    var outSize = destLen;
    var inSize = srcLen;
    var totalIn = 0;
    var totalOut = 0;

    for (;;) {
      final d = decoder;
      if (d.dicPos == d.dicBufSize) d.dicPos = 0;
      final dicPos = d.dicPos;
      var curFinishMode = lzmaFinishAny;
      var outCur = d.dicBufSize - dicPos;

      if (outCur >= outSize) {
        outCur = outSize;
        curFinishMode = finishMode;
      }

      final res =
          decodeToDic(dicPos + outCur, src, srcPos, inSize, curFinishMode);
      final inCur = srcProcessed;

      srcPos += inCur;
      inSize -= inCur;
      totalIn += inCur;
      outCur = d.dicPos - dicPos;
      dest.setRange(destPos, destPos + outCur, d.dic, dicPos);
      destPos += outCur;
      outSize -= outCur;
      totalOut += outCur;
      srcProcessed = totalIn;
      destProcessed = totalOut;
      if (res != szOk) return res;
      if (outCur == 0 || outSize == 0) return szOk;
    }
  }
}

/// Lzma2Decode (one call interface).
({int res, int destLen, int srcLen, int status}) lzma2Decode(
    Uint8List dest, Uint8List src, int prop, int finishMode) {
  final p = Lzma2Dec();
  final r = p.allocateProbs(prop);
  if (r != szOk) {
    return (res: r, destLen: 0, srcLen: 0, status: lzmaStatusNotSpecified);
  }
  p.decoder.dic = dest;
  p.decoder.dicBufSize = dest.length;
  p.init();
  var res = p.decodeToDic(dest.length, src, 0, src.length, finishMode);
  if (res == szOk && p.status == lzmaStatusNeedsMoreInput) {
    res = szErrorInputEof;
  }
  return (
    res: res,
    destLen: p.decoder.dicPos,
    srcLen: p.srcProcessed,
    status: p.status
  );
}
