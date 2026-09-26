// xz decoding: port of C/XzDec.c (the single threaded parts: the filter
// state coders, CMixCoder, CXzUnpacker, XzDecMt_Decode_ST and
// XzStatInfo_SetStat) and of CPP/7zip/Compress/XzDecoder.cpp of the LZMA
// SDK 26.01.
//
// The "output buffer" mode of the C unpacker (XzUnpacker_SetOutBuf, used for
// the random block access of XzHandler's GetStream and by the multithreaded
// decoder) is not ported: the unpacker always decodes into the caller's
// buffer, as XzDecMt_Decode_ST does.

import 'dart:typed_data';

import '../../codec/codec.dart';
import '../../codec/filters/bra.dart';
import '../../codec/filters/delta.dart';
import '../../codec/lzma/lzma2_dec.dart';
import '../../crypto/sha256.dart';
import '../../io/streams.dart';
import '../../util/crc.dart';
import 'xz.dart';

// ECoderStatus (same values as ELzmaStatus)
const int coderStatusNotSpecified = 0;
const int coderStatusFinishedWithMark = 1;
const int coderStatusNotFinished = 2;
const int coderStatusNeedsMoreInput = 3;

// ECoderFinishMode (same values as ELzmaFinishMode)
const int coderFinishAny = 0;
const int coderFinishEnd = 1;

// CODER_BUF_SIZE
const int _coderBufSize = 1 << 17;

// MIXCODER_NUM_FILTERS_MAX
const int _mixCoderNumFiltersMax = 4;

// BRA_BUF_SIZE
const int _braBufSize = 1 << 14;

const int _m32 = 0xFFFFFFFF;

// ---------------------------------------------------------------------------
// IStateCoder

/// IStateCoder: one coder of the xz filter chain. [code2] sets
/// [destProcessed], [srcProcessed] and [status].
abstract class XzStateCoder {
  int destProcessed = 0;
  int srcProcessed = 0;
  int status = coderStatusNotSpecified;

  int setProps(Uint8List props, int propSize);
  void init();
  int code2(Uint8List dest, int destPos, int destLen, Uint8List src, int srcPos,
      int srcLen, bool srcWasFinished, int finishMode);
  int filter(Uint8List data, int off, int size);
}

// ---------------------------------------------------------------------------
// XzBcFilterState

/// CXzBcFilterStateBase
class XzBcFilterStateBase {
  int methodId = 0;
  int delta = 0;
  int ip = 0;
  final Uint32List x86State = Uint32List(1);
  final Uint8List deltaState = Uint8List(kDeltaStateSize);
}

/// Xz_Func_BcFilterStateBase_Filter
typedef XzBcFilterFunc = int Function(
    XzBcFilterStateBase p, Uint8List data, int off, int size);

// g_Funcs_BranchConv_RISC_Dec
const List<BranchConvFunc> _funcsBranchConvRiscDec = [
  z7BranchConvPpcDec,
  z7BranchConvIa64Dec,
  z7BranchConvArmDec,
  z7BranchConvArmtDec,
  z7BranchConvSparcDec,
  z7BranchConvArm64Dec,
  z7BranchConvRiscvDec,
];

// XzBcFilterStateBase_Filter_Dec
int _xzBcFilterStateBaseFilterDec(
    XzBcFilterStateBase p, Uint8List data, int off, int size) {
  switch (p.methodId) {
    case xzIdDelta:
      deltaDecode(p.deltaState, p.delta, data, off, size);
    case xzIdX86:
      size = z7BranchConvStX86Dec(data, off, size, p.ip, p.x86State) - off;
    default:
      if (p.methodId >= xzIdPpc) {
        final i = p.methodId - xzIdPpc;
        if (i < _funcsBranchConvRiscDec.length) {
          size = _funcsBranchConvRiscDec[i](data, off, size, p.ip) - off;
        }
      }
  }
  p.ip = (p.ip + size) & _m32;
  return size;
}

/// CXzBcFilterState
class XzBcFilterState extends XzStateCoder {
  int _bufPos = 0;
  int _bufConv = 0;
  int _bufTotal = 0;
  final Uint8List _buf = Uint8List(_braBufSize);
  final XzBcFilterFunc filterFunc;
  final XzBcFilterStateBase base = XzBcFilterStateBase();

  XzBcFilterState(this.filterFunc);

  // XzBcFilterState_SetProps
  @override
  int setProps(Uint8List props, int propSize) {
    final p = base;
    p.ip = 0;
    if (p.methodId == xzIdDelta) {
      if (propSize != 1) return szErrorUnsupported;
      p.delta = props[0] + 1;
    } else {
      if (propSize == 4) {
        final v = getUint32LE(props, 0);
        switch (p.methodId) {
          case xzIdPpc:
          case xzIdArm:
          case xzIdSparc:
          case xzIdArm64:
            if ((v & 3) != 0) return szErrorUnsupported;
          case xzIdArmt:
          case xzIdRiscv:
            if ((v & 1) != 0) return szErrorUnsupported;
          case xzIdIa64:
            if ((v & 0xf) != 0) return szErrorUnsupported;
        }
        p.ip = v;
      } else if (propSize != 0) {
        return szErrorUnsupported;
      }
    }
    return szOk;
  }

  // XzBcFilterState_Init
  @override
  void init() {
    _bufPos = _bufConv = _bufTotal = 0;
    base.x86State[0] = kBranchConvStX86StateInitVal;
    if (base.methodId == xzIdDelta) deltaInit(base.deltaState);
  }

  // XzBcFilterState_Filter
  @override
  int filter(Uint8List data, int off, int size) =>
      filterFunc(base, data, off, size);

  // XzBcFilterState_Code2
  @override
  int code2(Uint8List dest, int destPos, int destLen, Uint8List src, int srcPos,
      int srcLen, bool srcWasFinished, int finishMode) {
    var destRem = destLen;
    var srcRem = srcLen;
    final buf = _buf;

    destProcessed = 0;
    srcProcessed = 0;
    status = coderStatusNotFinished;

    while (destRem != 0) {
      {
        var size = _bufConv - _bufPos;
        if (size != 0) {
          if (size > destRem) size = destRem;
          dest.setRange(destPos, destPos + size, buf, _bufPos);
          _bufPos += size;
          destProcessed += size;
          destPos += size;
          destRem -= size;
          continue;
        }
      }

      _bufTotal -= _bufPos;
      buf.setRange(0, _bufTotal, buf, _bufPos);
      _bufPos = 0;
      _bufConv = 0;
      {
        var size = _braBufSize - _bufTotal;
        if (size > srcRem) size = srcRem;
        buf.setRange(_bufTotal, _bufTotal + size, src, srcPos);
        srcProcessed += size;
        srcPos += size;
        srcRem -= size;
        _bufTotal += size;
      }
      if (_bufTotal == 0) break;

      _bufConv = filterFunc(base, buf, 0, _bufTotal);

      if (_bufConv == 0) {
        if (!srcWasFinished) break;
        _bufConv = _bufTotal;
      }
    }

    if (_bufTotal == _bufPos && srcRem == 0 && srcWasFinished) {
      status = coderStatusFinishedWithMark;
    }
    return szOk;
  }
}

/// Xz_StateCoder_Bc_SetFromMethod_Func: returns the coder to use (the
/// existing [p] when it is a filter coder already) or null for an
/// unsupported id.
XzBcFilterState? xzStateCoderBcSetFromMethodFunc(
    XzStateCoder? p, int id, XzBcFilterFunc func) {
  if (!xzIsSupportedFilterId(id)) return null;
  final decoder = p is XzBcFilterState ? p : XzBcFilterState(func);
  decoder.base.methodId = id;
  return decoder;
}

// ---------------------------------------------------------------------------
// Lzma2State

/// CLzma2Dec_Spec (without the output buffer mode).
class _Lzma2State extends XzStateCoder {
  final Lzma2Dec decoder = Lzma2Dec();

  // Lzma2State_SetProps
  @override
  int setProps(Uint8List props, int propSize) {
    if (propSize != 1) return szErrorUnsupported;
    return decoder.allocate(props[0]);
  }

  // Lzma2State_Init
  @override
  void init() => decoder.init();

  // Lzma2State_Code2
  @override
  int code2(Uint8List dest, int destPos, int destLen, Uint8List src, int srcPos,
      int srcLen, bool srcWasFinished, int finishMode) {
    final res = decoder.decodeToBuf(
        dest, destPos, destLen, src, srcPos, srcLen, finishMode);
    destProcessed = decoder.destProcessed;
    srcProcessed = decoder.srcProcessed;
    // ECoderStatus values are identical to ELzmaStatus values of LZMA2
    // decoder
    status = decoder.status;
    return res;
  }

  @override
  int filter(Uint8List data, int off, int size) => size;
}

// ---------------------------------------------------------------------------
// CMixCoder

/// CMixCoder
class MixCoder {
  Uint8List? _buf;
  int numCoders = 0;

  bool wasFinished = false;
  int res = szOk;
  int status = coderStatusNotSpecified;

  final List<bool> _finished = List.filled(_mixCoderNumFiltersMax - 1, false);
  final Int64List _pos = Int64List(_mixCoderNumFiltersMax - 1);
  final Int64List _size = Int64List(_mixCoderNumFiltersMax - 1);
  final Int64List ids = Int64List(_mixCoderNumFiltersMax);
  final Int32List _results = Int32List(_mixCoderNumFiltersMax);
  final List<XzStateCoder?> coders = List.filled(_mixCoderNumFiltersMax, null);

  /// Output of [code].
  int destProcessed = 0;
  int srcProcessed = 0;

  // MixCoder_Free
  void free() {
    numCoders = 0;
    for (var i = 0; i < _mixCoderNumFiltersMax; i++) {
      coders[i] = null;
    }
    _buf = null;
  }

  // MixCoder_Init
  void init() {
    for (var i = 0; i < _mixCoderNumFiltersMax - 1; i++) {
      _size[i] = 0;
      _pos[i] = 0;
      _finished[i] = false;
    }
    for (var i = 0; i < numCoders; i++) {
      coders[i]!.init();
      _results[i] = szOk;
    }
    wasFinished = false;
    res = szOk;
    status = coderStatusNotSpecified;
  }

  // MixCoder_SetFromMethod
  int _setFromMethod(int coderIndex, int methodId) {
    ids[coderIndex] = methodId;
    if (methodId == xzIdLzma2) {
      final c = coders[coderIndex];
      coders[coderIndex] = c is _Lzma2State ? c : _Lzma2State();
      return szOk;
    }
    if (coderIndex == 0) return szErrorUnsupported;
    final c = xzStateCoderBcSetFromMethodFunc(
        coders[coderIndex], methodId, _xzBcFilterStateBaseFilterDec);
    if (c == null) return szErrorUnsupported;
    coders[coderIndex] = c;
    return szOk;
  }

  // XzDecMix_Init (without the output buffer mode)
  int initForBlock(XzBlock block) {
    var needReInit = true;
    final numFilters = block.numFilters;

    if (numFilters == numCoders) {
      needReInit = false;
      for (var i = 0; i < numFilters; i++) {
        if (ids[i] != block.filters[numFilters - 1 - i].id) {
          needReInit = true;
          break;
        }
      }
    }

    if (needReInit) {
      free();
      for (var i = 0; i < numFilters; i++) {
        final r = _setFromMethod(i, block.filters[numFilters - 1 - i].id);
        if (r != szOk) return r;
      }
      numCoders = numFilters;
    }
    // else: MixCoder_ResetFromMethod is only needed in output buffer mode

    for (var i = 0; i < numFilters; i++) {
      final f = block.filters[numFilters - 1 - i];
      final r = coders[i]!.setProps(f.props, f.propsSize);
      if (r != szOk) return r;
    }

    init();
    return szOk;
  }

  // MixCoder_Code (the standard mix, without the output buffer mode).
  // Sets [destProcessed] and [srcProcessed].
  int code(
      Uint8List dest,
      int destPos,
      int destLenOrig,
      bool destFinish,
      Uint8List src,
      int srcPos,
      int srcLenOrig,
      bool srcWasFinished,
      int finishMode) {
    var destLen = 0;
    var srcLen = 0;
    destProcessed = 0;
    srcProcessed = 0;

    if (wasFinished) return res;

    status = coderStatusNotFinished;

    Uint8List buf;
    if (numCoders != 1) {
      buf = _buf ??= Uint8List(_coderBufSize * (_mixCoderNumFiltersMax - 1));
      finishMode = coderFinishAny;
    } else {
      buf = src; // not used
    }

    for (;;) {
      var processed = false;
      var allFinished = true;
      var resMain = szOk;

      status = coderStatusNotFinished;

      for (var i = 0; i < numCoders; i++) {
        final coder = coders[i]!;
        Uint8List dest2;
        int dest2Pos;
        int destLen2;
        Uint8List src2;
        int src2Pos;
        int srcLen2;
        bool srcFinished2;

        if (i == 0) {
          src2 = src;
          src2Pos = srcPos;
          srcLen2 = srcLenOrig - srcLen;
          srcFinished2 = srcWasFinished;
        } else {
          final k = i - 1;
          src2 = buf;
          src2Pos = _coderBufSize * k + _pos[k];
          srcLen2 = _size[k] - _pos[k];
          srcFinished2 = _finished[k];
        }

        if (i == numCoders - 1) {
          dest2 = dest;
          dest2Pos = destPos;
          destLen2 = destLenOrig - destLen;
        } else {
          if (_pos[i] != _size[i]) continue;
          dest2 = buf;
          dest2Pos = _coderBufSize * i;
          destLen2 = _coderBufSize;
        }

        if (_results[i] != szOk) {
          if (resMain == szOk) resMain = _results[i];
          continue;
        }

        final r = coder.code2(dest2, dest2Pos, destLen2, src2, src2Pos, srcLen2,
            srcFinished2, finishMode);
        destLen2 = coder.destProcessed;
        srcLen2 = coder.srcProcessed;
        final status2 = coder.status;

        if (r != szOk) {
          _results[i] = r;
          if (resMain == szOk) resMain = r;
        }

        final encodingWasFinished = status2 == coderStatusFinishedWithMark;

        if (!encodingWasFinished) {
          allFinished = false;
          if (numCoders == 1 && r == szOk) status = status2;
        }

        if (i == 0) {
          srcLen += srcLen2;
          srcPos += srcLen2;
        } else {
          _pos[i - 1] += srcLen2;
        }

        if (i == numCoders - 1) {
          destLen += destLen2;
          destPos += destLen2;
        } else {
          _size[i] = destLen2;
          _pos[i] = 0;
          _finished[i] = encodingWasFinished;
        }

        if (destLen2 != 0 || srcLen2 != 0) processed = true;
      }

      if (!processed) {
        if (allFinished) status = coderStatusFinishedWithMark;
        destProcessed = destLen;
        srcProcessed = srcLen;
        return resMain;
      }
    }
  }
}

// ---------------------------------------------------------------------------
// CXzUnpacker

// EXzState
const int _stateStreamHeader = 0;
const int _stateStreamIndex = 1;
const int _stateStreamIndexCrc = 2;
const int _stateStreamFooter = 3;
const int _stateStreamPadding = 4;
const int _stateBlockHeader = 5;
const int _stateBlock = 6;
const int _stateBlockFooter = 7;

/// CXzUnpacker
class XzUnpacker {
  int state = _stateStreamHeader;
  int pos = 0;
  int alignPos = 0;
  int indexPreSize = 0;

  int streamFlags = 0;

  int blockHeaderSize = 0;
  int packSize = 0;
  int unpackSize = 0;

  int numBlocks = 0; // number of finished blocks in current stream
  int indexSize = 0;
  int indexPos = 0;
  int padSize = 0;

  int numStartedStreams = 0;
  int numFinishedStreams = 0;
  int numTotalBlocks = 0;

  int crc = 0;
  final MixCoder decoder = MixCoder();
  final XzBlock block = XzBlock();
  final XzCheck check = XzCheck();
  final Sha256 sha = Sha256();

  bool parseMode = false;
  bool headerParsedOk = false;
  bool decodeToStreamSignature = false;
  bool decodeOnlyOneBlock = false;

  final Uint8List shaDigest = Uint8List(kSha256DigestSize);
  final Uint8List buf = Uint8List(xzBlockHeaderSizeMax);

  /// Outputs of [code].
  int destProcessed = 0;
  int srcProcessed = 0;
  int status = coderStatusNotSpecified;

  // XzUnpacker_Construct
  XzUnpacker() {
    init();
  }

  // XzUnpacker_Init
  void init() {
    state = _stateStreamHeader;
    pos = 0;
    numStartedStreams = 0;
    numFinishedStreams = 0;
    numTotalBlocks = 0;
    padSize = 0;
    decodeOnlyOneBlock = false;

    parseMode = false;
    decodeToStreamSignature = false;
  }

  // XzUnpacker_Free
  void free() => decoder.free();

  // XzUnpacker_PrepareToRandomBlockDecoding
  void prepareToRandomBlockDecoding() {
    indexSize = 0;
    numBlocks = 0;
    sha.init();
    state = _stateBlockHeader;
    pos = 0;
    decodeOnlyOneBlock = true;
  }

  // XzUnpacker_UpdateIndex
  void _updateIndex(int packSize, int unpackSize) {
    final temp = Uint8List(32);
    var num = xzWriteVarInt(temp, 0, packSize);
    num += xzWriteVarInt(temp, num, unpackSize);
    sha.update(temp, 0, num);
    indexSize += num;
    numBlocks++;
  }

  // XzUnpacker_GetPackSizeForIndex
  int get packSizeForIndex =>
      packSize + blockHeaderSize + xzFlagsGetCheckSize(streamFlags);

  /// XzUnpacker_Code: decodes src[srcPos, srcPos + srcLenOrig) into
  /// dest[destPos, destPos + destLenOrig). Sets [destProcessed],
  /// [srcProcessed] and [status]; returns an SRes code.
  int code(Uint8List dest, int destPos, int destLenOrig, Uint8List src,
      int srcPos, int srcLenOrig, bool srcFinished, int finishMode) {
    var destLen = 0;
    var srcLen = 0;
    destProcessed = 0;
    srcProcessed = 0;
    status = coderStatusNotSpecified;

    for (;;) {
      if (state == _stateBlock) {
        var destLen2 = destLenOrig - destLen;
        var srcLen2 = srcLenOrig - srcLen;

        var finishMode2 = finishMode;
        var srcFinished2 = srcFinished;
        var destFinish = false;

        if (block.packSize != -1) {
          final rem = block.packSize - packSize;
          if (srcLen2 >= rem) {
            srcFinished2 = true;
            srcLen2 = rem;
          }
          if (rem == 0 && block.unpackSize == unpackSize) {
            destProcessed = destLen;
            srcProcessed = srcLen;
            return szErrorData;
          }
        }

        if (block.unpackSize != -1) {
          final rem = block.unpackSize - unpackSize;
          if (destLen2 >= rem) {
            destFinish = true;
            finishMode2 = coderFinishEnd;
            destLen2 = rem;
          }
        }

        final res = decoder.code(dest, destPos, destLen2, destFinish, src,
            srcPos, srcLen2, srcFinished2, finishMode2);
        destLen2 = decoder.destProcessed;
        srcLen2 = decoder.srcProcessed;
        status = decoder.status;
        check.update(dest, destPos, destLen2);
        destPos += destLen2;

        srcLen += srcLen2;
        srcPos += srcLen2;
        packSize += srcLen2;
        destLen += destLen2;
        unpackSize += destLen2;
        destProcessed = destLen;
        srcProcessed = srcLen;

        if (res != szOk) return res;

        if (status != coderStatusFinishedWithMark) {
          if (block.packSize == packSize &&
              status == coderStatusNeedsMoreInput) {
            status = coderStatusNotSpecified;
            return szErrorData;
          }
          return szOk;
        }
        {
          _updateIndex(packSizeForIndex, unpackSize);
          state = _stateBlockFooter;
          pos = 0;
          alignPos = 0;
          status = coderStatusNotSpecified;

          if ((block.packSize != -1 && block.packSize != packSize) ||
              (block.unpackSize != -1 && block.unpackSize != unpackSize)) {
            return szErrorData;
          }
        }
      }

      var srcRem = srcLenOrig - srcLen;

      // XZ_STATE_BLOCK_FOOTER can transit to XZ_STATE_BLOCK_HEADER without
      // input bytes
      if (srcRem == 0 && state != _stateBlockFooter) {
        status = coderStatusNeedsMoreInput;
        destProcessed = destLen;
        srcProcessed = srcLen;
        return szOk;
      }

      final r = _codeState(src, srcPos, srcRem);
      srcLen += _stateSrcUsed;
      srcPos += _stateSrcUsed;
      destProcessed = destLen;
      srcProcessed = srcLen;
      if (r != _continue) return r;
    }
  }

  static const int _continue = -1;
  int _stateSrcUsed = 0;

  // The switch (p->state) part of XzUnpacker_Code. Consumes from
  // src[srcPos, srcPos + srcRem), stores the count in [_stateSrcUsed] and
  // returns [_continue] to go on, or the SRes code to return.
  int _codeState(Uint8List src, int srcPos, int srcRem) {
    final start = srcPos;
    _stateSrcUsed = 0;
    switch (state) {
      case _stateStreamHeader:
        if (pos < xzStreamHeaderSize) {
          if (pos < xzSigSize && src[srcPos] != xzSig[pos]) {
            return szErrorNoArchive;
          }
          if (decodeToStreamSignature) return szOk;
          buf[pos++] = src[srcPos++];
        } else {
          final (r, flags) = xzParseHeader(buf, 0);
          streamFlags = flags;
          if (r != szOk) return r;
          numStartedStreams++;
          indexSize = 0;
          numBlocks = 0;
          sha.init();
          state = _stateBlockHeader;
          pos = 0;
        }

      case _stateBlockHeader:
        if (pos == 0) {
          buf[pos++] = src[srcPos++];
          if (buf[0] == 0) {
            if (decodeOnlyOneBlock) {
              _stateSrcUsed = srcPos - start;
              return szErrorData;
            }
            indexPreSize = 1 + xzWriteVarInt(buf, 1, numBlocks);
            indexPos = indexPreSize;
            indexSize += indexPreSize;
            sha.finalTo(shaDigest, 0);
            sha.init();
            crc = crc32Update(0xFFFFFFFF, buf, 0, indexPreSize);
            state = _stateStreamIndex;
            break;
          }
          blockHeaderSize = (buf[0] << 2) + 4;
          break;
        }

        if (pos != blockHeaderSize) {
          var cur = blockHeaderSize - pos;
          if (cur > srcRem) cur = srcRem;
          buf.setRange(pos, pos + cur, src, srcPos);
          pos += cur;
          srcPos += cur;
        } else {
          var r = xzBlockParse(block, buf);
          if (r != szOk) return r;
          if (!xzBlockAreSupportedFilters(block)) return szErrorUnsupported;
          numTotalBlocks++;
          state = _stateBlock;
          packSize = 0;
          unpackSize = 0;
          check.init(xzFlagsGetCheckType(streamFlags));
          if (parseMode) {
            headerParsedOk = true;
            return szOk;
          }
          r = decoder.initForBlock(block);
          if (r != szOk) return r;
        }

      case _stateBlockFooter:
        if (((packSize + alignPos) & 3) != 0) {
          if (srcRem == 0) {
            status = coderStatusNeedsMoreInput;
            return szOk;
          }
          alignPos++;
          if (src[srcPos++] != 0) {
            _stateSrcUsed = srcPos - start;
            return szErrorCrc;
          }
        } else {
          final checkSize = xzFlagsGetCheckSize(streamFlags);
          var cur = checkSize - pos;
          if (cur != 0) {
            if (srcRem == 0) {
              status = coderStatusNeedsMoreInput;
              return szOk;
            }
            if (cur > srcRem) cur = srcRem;
            buf.setRange(pos, pos + cur, src, srcPos);
            pos += cur;
            srcPos += cur;
            if (checkSize != pos) break;
          }
          {
            final digest = Uint8List(xzCheckSizeMax);
            state = _stateBlockHeader;
            pos = 0;
            if (check.finalTo(digest, 0)) {
              for (var i = 0; i < checkSize; i++) {
                if (digest[i] != buf[i]) {
                  _stateSrcUsed = srcPos - start;
                  return szErrorCrc;
                }
              }
            }
            if (decodeOnlyOneBlock) {
              status = coderStatusFinishedWithMark;
              _stateSrcUsed = srcPos - start;
              return szOk;
            }
          }
        }

      case _stateStreamIndex:
        if (pos < indexPreSize) {
          if (src[srcPos++] != buf[pos++]) {
            _stateSrcUsed = srcPos - start;
            return szErrorCrc;
          }
        } else {
          if (indexPos < indexSize) {
            final cur = indexSize - indexPos;
            if (srcRem > cur) srcRem = cur;
            crc = crc32Update(crc, src, srcPos, srcPos + srcRem);
            sha.update(src, srcPos, srcRem);
            srcPos += srcRem;
            indexPos += srcRem;
          } else if ((indexPos & 3) != 0) {
            final b = src[srcPos++];
            crc = crc32Update(crc, src, srcPos - 1, srcPos); // CRC_UPDATE_BYTE
            indexPos++;
            indexSize++;
            if (b != 0) {
              _stateSrcUsed = srcPos - start;
              return szErrorCrc;
            }
          } else {
            final digest = Uint8List(kSha256DigestSize);
            state = _stateStreamIndexCrc;
            indexSize += 4;
            pos = 0;
            sha.finalTo(digest, 0);
            for (var i = 0; i < kSha256DigestSize; i++) {
              if (digest[i] != shaDigest[i]) return szErrorCrc;
            }
          }
        }

      case _stateStreamIndexCrc:
        if (pos < 4) {
          buf[pos++] = src[srcPos++];
        } else {
          state = _stateStreamFooter;
          pos = 0;
          if ((crc ^ 0xFFFFFFFF) != getUint32LE(buf, 0)) return szErrorCrc;
        }

      case _stateStreamFooter:
        {
          var cur = xzStreamFooterSize - pos;
          if (cur > srcRem) cur = srcRem;
          buf.setRange(pos, pos + cur, src, srcPos);
          pos += cur;
          srcPos += cur;
          if (pos == xzStreamFooterSize) {
            state = _stateStreamPadding;
            numFinishedStreams++;
            padSize = 0;
            if (!xzCheckFooter(streamFlags, indexSize, buf, 0)) {
              _stateSrcUsed = srcPos - start;
              return szErrorCrc;
            }
          }
        }

      case _stateStreamPadding:
        if (src[srcPos] != 0) {
          if ((padSize & 3) != 0) return szErrorNoArchive;
          pos = 0;
          state = _stateStreamHeader;
        } else {
          srcPos++;
          padSize++;
        }

      default:
        return szErrorFail;
    }
    _stateSrcUsed = srcPos - start;
    return _continue;
  }

  // XzUnpacker_IsBlockFinished
  bool get isBlockFinished => state == _stateBlockHeader && pos == 0;

  // XzUnpacker_IsStreamWasFinished
  bool get isStreamWasFinished =>
      state == _stateStreamPadding && (padSize & 3) == 0;

  // XzUnpacker_GetExtraSize
  int get extraSize {
    var num = 0;
    if (state == _stateStreamPadding) {
      num = padSize;
    } else if (state == _stateStreamHeader) {
      num = padSize + pos;
    }
    return num;
  }
}

// ---------------------------------------------------------------------------
// XzDecMt (single thread)

/// CXzDecMtProps (the single thread fields).
class XzDecMtProps {
  int inBufSizeSt = 1 << 18;
  int outStepSt = 1 << 20;
  bool ignoreErrors = false;

  /// Number of threads. Only the single threaded decoder is ported; this
  /// is where a multithreaded block decoder would plug in.
  int numThreads = 1;
}

/// CXzStatInfo
class XzStatInfo {
  bool unpackSizeDefined = false;
  bool numStreamsDefined = false;
  bool numBlocksDefined = false;

  bool dataAfterEnd = false;
  bool decodingTruncated = false;

  int inSize = 0;
  int outSize = 0;

  int numStreams = 0;
  int numBlocks = 0;

  int decodeRes = szOk;
  int readRes = szOk;
  int progressRes = szOk;

  int combinedRes = szOk;
  int combinedResType = szOk;

  // XzStatInfo_Clear
  void clear() {
    inSize = 0;
    outSize = 0;
    numStreams = 0;
    numBlocks = 0;
    unpackSizeDefined = false;
    numStreamsDefined = false;
    numBlocksDefined = false;
    dataAfterEnd = false;
    decodingTruncated = false;
    decodeRes = szOk;
    readRes = szOk;
    progressRes = szOk;
    combinedRes = szOk;
    combinedResType = szOk;
  }

  void copyFrom(XzStatInfo o) {
    unpackSizeDefined = o.unpackSizeDefined;
    numStreamsDefined = o.numStreamsDefined;
    numBlocksDefined = o.numBlocksDefined;
    dataAfterEnd = o.dataAfterEnd;
    decodingTruncated = o.decodingTruncated;
    inSize = o.inSize;
    outSize = o.outSize;
    numStreams = o.numStreams;
    numBlocks = o.numBlocks;
    decodeRes = o.decodeRes;
    readRes = o.readRes;
    progressRes = o.progressRes;
    combinedRes = o.combinedRes;
    combinedResType = o.combinedResType;
  }
}

// XzStatInfo_SetStat
void _xzStatInfoSetStat(XzUnpacker dec, bool finishMode, int inProcessed,
    int res, int status, bool decodingTruncated, XzStatInfo stat) {
  stat.decodingTruncated = decodingTruncated;
  stat.inSize = inProcessed;
  stat.numStreams = dec.numStartedStreams;
  stat.numBlocks = dec.numTotalBlocks;

  stat.unpackSizeDefined = true;
  stat.numStreamsDefined = true;
  stat.numBlocksDefined = true;

  var extraSize = dec.extraSize;

  if (res == szOk) {
    if (status == coderStatusNeedsMoreInput) {
      // CODER_STATUS_NEEDS_MORE_INPUT is expected status for correct xz
      // streams, any extra data is part of correct data
      extraSize = 0;
      // if xz stream was not finished, then we need more data
      if (!dec.isStreamWasFinished) res = szErrorInputEof;
    } else {
      // CODER_STATUS_FINISHED_WITH_MARK is not possible for multi stream
      // xz decoding, so here we have (status == CODER_STATUS_NOT_FINISHED)
      if (!decodingTruncated || finishMode) res = szErrorData;
    }
  } else if (res == szErrorNoArchive) {
    // SZ_ERROR_NO_ARCHIVE is possible for 2 states:
    //   XZ_STATE_STREAM_HEADER  - if bad signature or bad CRC
    //   XZ_STATE_STREAM_PADDING - if non-zero padding data
    // extraSize and inProcessed don't include "bad" byte.
    // If (inProcessed == extraSize), there was no good xz stream header,
    // and we keep the error.
    if (inProcessed != extraSize) {
      // here we suppose that all xz streams were finished OK, and we have
      // some extra data after all streams
      stat.dataAfterEnd = true;
      res = szOk;
    }
  }

  if (stat.decodeRes == szOk) stat.decodeRes = res;

  stat.inSize -= extraSize;
}

/// CXzDecMt, single threaded: XzDecMt_Create / XzDecMt_Decode.
class XzDecMt {
  XzDecMtProps props = XzDecMtProps();

  bool _finishMode = false;
  bool _outSizeDefined = false;
  int _outSize = 0;

  int outProcessed = 0;
  int inProcessed = 0;
  int readProcessed = 0;
  bool _readWasFinished = false;
  int readRes = szOk;

  Uint8List? _outBuf;
  Uint8List? _inBuf;

  final XzUnpacker dec = XzUnpacker();

  int _status = coderStatusNotSpecified;
  int _codeRes = szOk;

  // XzDecMt_Decode_ST
  int _decodeSt(InStream inStream, OutStream outStream,
      ProgressCallback? progress, XzStatInfo stat) {
    var outBuf = _outBuf;
    if (outBuf == null || outBuf.length != props.outStepSt) {
      outBuf = _outBuf = Uint8List(props.outStepSt);
    }
    var inBuf = _inBuf;
    if (inBuf == null || inBuf.length != props.inBufSizeSt) {
      inBuf = _inBuf = Uint8List(props.inBufSizeSt);
    }

    final dec = this.dec;
    dec.decodeToStreamSignature = false;

    var inPrev = inProcessed;
    var outPrev = outProcessed;

    var inPos = 0;
    var inLim = 0;
    var outPos = 0;

    for (;;) {
      if (inPos == inLim) {
        if (!_readWasFinished) {
          inPos = 0;
          inLim = inStream.read(inBuf, 0, inBuf.length);
          readProcessed += inLim;
          if (inLim == 0) _readWasFinished = true;
        }
      }

      var outSize = props.outStepSt - outPos;

      var finishMode = coderFinishAny;
      if (_outSizeDefined) {
        final rem = _outSize - outProcessed;
        if (outSize >= rem) {
          outSize = rem;
          if (_finishMode) finishMode = coderFinishEnd;
        }
      }

      final res = dec.code(outBuf, outPos, outSize, inBuf, inPos, inLim - inPos,
          inPos == inLim, finishMode);
      final inProcessedCur = dec.srcProcessed;
      final outProcessedCur = dec.destProcessed;
      final status = dec.status;

      _codeRes = res;
      _status = status;

      inPos += inProcessedCur;
      outPos += outProcessedCur;
      inProcessed += inProcessedCur;
      outProcessed += outProcessedCur;

      final finished =
          (inProcessedCur == 0 && outProcessedCur == 0) || res != szOk;

      if (finished || outProcessedCur >= outSize) {
        if (outPos != 0) {
          outStream.write(outBuf, 0, outPos);
          outPos = 0;
        }
      }

      if (progress != null && res == szOk) {
        if (inProcessed - inPrev >= (1 << 22) ||
            outProcessed - outPrev >= (1 << 22)) {
          progress(inProcessed, outProcessed);
          inPrev = inProcessed;
          outPrev = outProcessed;
        }
      }

      if (finished) {
        // _codeRes is preliminary error from XzUnpacker_Code, and it can be
        // corrected later as final result, so we return SZ_OK here.
        return szOk;
      }
    }
  }

  /// XzDecMt_Decode. [outDataSize] null means undefined; [finishMode]:
  /// false, partial unpacking is allowed; true, xz stream(s) must be
  /// finished. Fills [stat] and returns the combined SRes. Exceptions of
  /// the streams and of [progress] propagate.
  int decode(int? outDataSize, bool finishMode, OutStream outStream,
      InStream inStream, XzStatInfo stat,
      {ProgressCallback? progress}) {
    stat.clear();

    _outSize = 0;
    _outSizeDefined = false;
    if (outDataSize != null) {
      _outSizeDefined = true;
      _outSize = outDataSize;
    }

    _finishMode = finishMode;

    outProcessed = 0;
    inProcessed = 0;
    readProcessed = 0;
    _readWasFinished = false;
    readRes = szOk;

    _codeRes = szOk;
    _status = coderStatusNotSpecified;

    dec.init();

    // Seam for multithreaded decoding: XzDecMt_Decode runs MtDec_Code here
    // when props.numThreads > 1 (blocks with sizes in their headers are
    // decoded in parallel). This port always takes the single thread path.

    var res = _decodeSt(inStream, outStream, progress, stat);

    _xzStatInfoSetStat(
        dec, _finishMode, inProcessed, _codeRes, _status, false, stat);

    stat.readRes = readRes;
    // Not set by XzDecMt_Decode_ST in the C code (only the multithreaded
    // path sets it); XzHandler shows it as the unpacked size.
    stat.outSize = outProcessed;

    if (res == szOk) {
      if (readRes != szOk && stat.decodeRes == szErrorInputEof) {
        res = readRes;
        stat.combinedResType = szErrorRead;
      } else if (stat.decodeRes != szOk) {
        res = stat.decodeRes;
      }
    }

    stat.combinedRes = res;
    if (stat.combinedResType == szOk) stat.combinedResType = res;
    return res;
  }
}

// ---------------------------------------------------------------------------
// XzDecoder.cpp

/// Result of [XzDecoder.decode] (the HRESULT of CDecoder::Decode).
enum XzDecodeResult {
  /// S_OK
  ok,

  /// S_FALSE: a data error; see [XzDecoder.mainDecodeSRes].
  dataError,

  /// E_NOTIMPL: unsupported method or properties.
  notImplemented,

  /// E_OUTOFMEMORY
  outOfMemory,
}

// SResToHRESULT_Code
XzDecodeResult _sResToHresultCode(int res) {
  switch (res) {
    case szOk:
      return XzDecodeResult.ok;
    case szErrorMem:
      return XzDecodeResult.outOfMemory;
    case szErrorUnsupported:
      return XzDecodeResult.notImplemented;
  }
  return XzDecodeResult.dataError;
}

/// NCompress::NXz::CDecoder: decodes xz data from a stream to a stream.
class XzDecoder {
  XzDecMt? _xz;

  /// The SRes of the last [decode].
  int mainDecodeSRes = szOk;
  bool mainDecodeSResWasUsed = false;

  /// Statistics of the last [decode].
  final XzStatInfo stat = XzStatInfo();

  /// Number of threads (only the single thread decoder is ported).
  int numThreads = 1;
  int memUsage = 0;

  /// CDecoder::Decode
  XzDecodeResult decode(InStream seqInStream, OutStream outStream,
      {int? outSizeLimit,
      bool finishStream = true,
      ProgressCallback? progress}) {
    mainDecodeSRes = szOk;
    mainDecodeSResWasUsed = false;
    stat.clear();

    final xz = _xz ??= XzDecMt();

    final props = XzDecMtProps()..numThreads = numThreads;
    xz.props = props;

    final outWrap = CountingOutStream(outStream);

    var res = xz.decode(outSizeLimit, finishStream, outWrap, seqInStream, stat,
        progress: progress);

    mainDecodeSRes = res;
    mainDecodeSResWasUsed = true;

    if (res == szOk && finishStream) {
      if (outSizeLimit != null && outSizeLimit != outWrap.count) {
        res = szErrorData;
      }
    }

    return _sResToHresultCode(res);
  }
}
