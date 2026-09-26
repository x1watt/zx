// BCJ2 converter for x86 code (branch CALL/JUMP variant 2): port of
// C/Bcj2.c (decoder), C/Bcj2Enc.c (encoder) and
// CPP/7zip/Compress/Bcj2Coder.cpp (the stream drivers).
//
// BCJ2 has one unpacked stream and four packed streams: MAIN (the bytes that
// are not branch targets), CALL and JUMP (big endian absolute targets of
// e8 and e9/0f8x instructions) and RC (a range coded bit per marker telling
// whether it was converted).

import 'dart:typed_data';

import '../../io/streams.dart';
import '../codec.dart';

const int _m32 = 0xFFFFFFFF;

final Uint8List _empty = Uint8List(0);

/// BCJ2_NUM_STREAMS
const int bcj2NumStreams = 4;

const int bcj2StreamMain = 0;
const int bcj2StreamCall = 1;
const int bcj2StreamJump = 2;
const int bcj2StreamRc = 3;

const int _bcj2DecStateOrig0 = bcj2NumStreams;
const int _bcj2DecStateOrig3 = bcj2NumStreams + 3;
const int _bcj2DecStateOrig = bcj2NumStreams + 4;
const int _bcj2DecStateError = bcj2NumStreams + 5;

const int _bcj2EncStateOrig = bcj2NumStreams;
const int _bcj2EncStateFinished = bcj2NumStreams + 1;

// BCJ2_IS_32BIT_STREAM
bool _bcj2Is32BitStream(int s) => s == bcj2StreamCall || s == bcj2StreamJump;

const int _kTopValue = 1 << 24;
const int _kNumBitModelTotalBits = 11;
const int _kBitModelTotal = 1 << _kNumBitModelTotalBits;
const int _kNumMoveBits = 5;

/// BCJ2_ENC_RELAT_LIMIT_DEFAULT: the limit 7-Zip uses (no BCJ2 properties
/// are set by 7zUpdate.cpp).
const int bcj2EncRelatLimitDefault = 0x0f << 24;

/// BCJ2_ENC_RELAT_LIMIT_MAX
const int bcj2EncRelatLimitMax = 1 << 31;

// ---------------------------------------------------------------------------
// Decoder (Bcj2.c)

/// CBcj2Dec. The C pointers bufs[i]/lims[i] are indices into [inBufs][i],
/// dest/destLim are indices into [dest].
class Bcj2Dec {
  final List<Uint8List> inBufs;
  final Int64List bufs = Int64List(bcj2NumStreams);
  final Int64List lims = Int64List(bcj2NumStreams);
  Uint8List dest = _empty;
  int destPos = 0;
  int destLim = 0;

  int state = bcj2StreamRc;
  int ip = 0;
  int temp = 0;
  int range = 0;
  int code = 0;
  final Uint16List probs = Uint16List(2 + 256);

  Bcj2Dec(this.inBufs);

  // Bcj2Dec_Init
  void init() {
    state = bcj2StreamRc;
    ip = 0;
    temp = 0;
    range = 0;
    code = 0;
    for (var i = 0; i < probs.length; i++) {
      probs[i] = _kBitModelTotal >> 1;
    }
  }

  // Bcj2Dec_IsMaybeFinished_code
  bool get isMaybeFinishedCode => code == 0;

  // Bcj2Dec_Decode. Returns false on SZ_ERROR_DATA.
  bool decode() {
    var v = temp;
    final rcBuf = inBufs[bcj2StreamRc];
    if (range <= 5) {
      var code = this.code;
      state = _bcj2DecStateError; // for the case we return SZ_ERROR_DATA
      for (; range != 5; range++) {
        if (range == 1 && code != 0) return false;
        if (bufs[bcj2StreamRc] == lims[bcj2StreamRc]) {
          state = bcj2StreamRc;
          return true;
        }
        code = ((code << 8) | rcBuf[bufs[bcj2StreamRc]++]) & _m32;
        this.code = code;
      }
      if (code == 0xffffffff) return false;
      range = 0xffffffff;
    }
    {
      var st = state;
      if (_bcj2Is32BitStream(st)) {
        final cur = bufs[st];
        if (cur == lims[st]) return true;
        bufs[st] = cur + 4;
        final b = inBufs[st];
        final ip = (this.ip + 4) & _m32;
        v = (((b[cur] << 24) |
                    (b[cur + 1] << 16) |
                    (b[cur + 2] << 8) |
                    b[cur + 3]) -
                ip) &
            _m32;
        this.ip = ip;
        st = _bcj2DecStateOrig0;
      }
      if (st >= _bcj2DecStateOrig0 && st <= _bcj2DecStateOrig3) {
        final dest = this.dest;
        var d = destPos;
        for (;;) {
          if (d == destLim) {
            state = st;
            temp = v;
            return true;
          }
          dest[d++] = v;
          destPos = d;
          if (++st == _bcj2DecStateOrig3 + 1) break;
          v >>= 8;
        }
      }
    }

    final mainBuf = inBufs[bcj2StreamMain];
    final dest = this.dest;
    for (;;) {
      if (range < _kTopValue) {
        if (bufs[bcj2StreamRc] == lims[bcj2StreamRc]) {
          state = bcj2StreamRc;
          temp = v;
          return true;
        }
        range = (range << 8) & _m32;
        code = ((code << 8) | rcBuf[bufs[bcj2StreamRc]++]) & _m32;
      }
      {
        var src = bufs[bcj2StreamMain];
        var d = destPos;
        final srcLimMain = lims[bcj2StreamMain];
        var num = destLim - d;
        final rem = srcLimMain - src;
        if (num >= rem) num = rem;
        num &= ~3; // NUM_ITERS = 4
        final srcLim = src + num;
        var found = false;

        // ONE_ITER: copy a byte, stop after e8/e9 or 0f 8x.
        if (src != srcLim) {
          for (;;) {
            var b = mainBuf[src];
            dest[d++] = b;
            v = ((v & 0xff) << 24) | b;
            if (((b + (0x100 - 0xe8)) & 0xfe) == 0 ||
                ((v - 0x0f000080) & 0xFFFFFFF0) == 0) {
              found = true;
              break;
            }
            b = mainBuf[src + 1];
            dest[d++] = b;
            v = ((v & 0xff) << 24) | b;
            if (((b + (0x100 - 0xe8)) & 0xfe) == 0 ||
                ((v - 0x0f000080) & 0xFFFFFFF0) == 0) {
              found = true;
              break;
            }
            b = mainBuf[src + 2];
            dest[d++] = b;
            v = ((v & 0xff) << 24) | b;
            if (((b + (0x100 - 0xe8)) & 0xfe) == 0 ||
                ((v - 0x0f000080) & 0xFFFFFFF0) == 0) {
              found = true;
              break;
            }
            b = mainBuf[src + 3];
            dest[d++] = b;
            v = ((v & 0xff) << 24) | b;
            if (((b + (0x100 - 0xe8)) & 0xfe) == 0 ||
                ((v - 0x0f000080) & 0xFFFFFFF0) == 0) {
              found = true;
              break;
            }
            src += 4;
            if (src == srcLim) break;
          }
        }

        if (!found) {
          // (src == srcLim)
          for (;;) {
            if (src == srcLimMain || d == destLim) {
              final num = src - bufs[bcj2StreamMain];
              bufs[bcj2StreamMain] = src;
              destPos = d;
              ip = (ip + num) & _m32;
              // state BCJ2_STREAM_MAIN has more priority than BCJ2_STATE_ORIG
              state = src == srcLimMain ? bcj2StreamMain : _bcj2DecStateOrig;
              temp = v;
              return true;
            }
            final b = mainBuf[src];
            dest[d++] = b;
            v = ((v & 0xff) << 24) | b;
            if (((b + (0x100 - 0xe8)) & 0xfe) == 0 ||
                ((v - 0x0f000080) & 0xFFFFFFF0) == 0) {
              break;
            }
            src++;
          }
        }

        {
          final num = d - destPos;
          destPos = d;
          bufs[bcj2StreamMain] += num;
          ip = (ip + num) & _m32;
        }
        {
          final c = ((v + 0x17) >> 6) & 1;
          final index = ((-c) & ((v >> 24) & 0xff)) + c + ((v >> 5) & 1);
          final ttt = probs[index];
          final bound = (range >> _kNumBitModelTotalBits) * ttt;
          if (code < bound) {
            range = bound;
            probs[index] = ttt + ((_kBitModelTotal - ttt) >> _kNumMoveBits);
            continue;
          }
          range -= bound;
          code -= bound;
          probs[index] = ttt - (ttt >> _kNumMoveBits);
        }
      }
      {
        // cj = (Byte)v == 0xe8 ? BCJ2_STREAM_CALL : BCJ2_STREAM_JUMP
        final cj = (((v + 0x57) >> 6) & 1) + bcj2StreamCall;
        final cur = bufs[cj];
        if (cur == lims[cj]) {
          state = cj;
          break;
        }
        final b = inBufs[cj];
        v = (b[cur] << 24) |
            (b[cur + 1] << 16) |
            (b[cur + 2] << 8) |
            b[cur + 3];
        bufs[cj] = cur + 4;
        final ip = (this.ip + 4) & _m32;
        v = (v - ip) & _m32;
        this.ip = ip;
        final d = destPos;
        final rem = destLim - d;
        if (rem < 4) {
          if (rem > 0) {
            dest[d] = v;
            v >>= 8;
            if (rem > 1) {
              dest[d + 1] = v;
              v >>= 8;
              if (rem > 2) {
                dest[d + 2] = v;
                v >>= 8;
              }
            }
          }
          temp = v;
          destPos = d + rem;
          state = _bcj2DecStateOrig0 + rem;
          break;
        }
        dest[d] = v;
        dest[d + 1] = v >> 8;
        dest[d + 2] = v >> 16;
        dest[d + 3] = v >> 24;
        v >>= 24;
        destPos = d + 4;
      }
    }

    if (range < _kTopValue && bufs[bcj2StreamRc] != lims[bcj2StreamRc]) {
      range = (range << 8) & _m32;
      code = ((code << 8) | rcBuf[bufs[bcj2StreamRc]++]) & _m32;
    }
    return true;
  }
}

/// NCompress::NBcj2::CDecoder in its read mode (SetInStream2,
/// SetOutStreamSize, Read), with the finish mode that 7zDecode.cpp enables
/// for full extraction.
class Bcj2Decoder implements InStream {
  final List<InStream> _inStreams;
  final int? _outSize;
  int _outSizeProcessed = 0;
  final bool _finishMode;

  final List<Uint8List> _bufs;
  final Int32List _bufsSizes = Int32List(bcj2NumStreams);
  // CBaseDecoder
  final List<bool> _readEnded = List<bool>.filled(bcj2NumStreams, false);
  final List<bool> _readError = List<bool>.filled(bcj2NumStreams, false);
  final Int32List _extraSizes = Int32List(bcj2NumStreams);
  final Int64List _readSizes = Int64List(bcj2NumStreams);
  late final Bcj2Dec _dec;

  /// [inStreams]: MAIN, CALL, JUMP, RC. [bufSize] is the buffer of each
  /// input (1 << 18 in 7-Zip).
  Bcj2Decoder(this._inStreams,
      {int? outSize, bool finishMode = true, int bufSize = 1 << 18})
      : _outSize = outSize,
        _finishMode = finishMode,
        _bufs = List<Uint8List>.generate(bcj2NumStreams, (_) {
          // CBaseCoder::Alloc: sizes aligned for 4, at least 4.
          var size = bufSize & ~3;
          if (size < 4) size = 4;
          return Uint8List(size);
        }) {
    if (_inStreams.length != bcj2NumStreams) {
      throw const SevenZipException(
          'BCJ2 needs 4 input streams', SevenZipError.unsupportedMethod);
    }
    for (var i = 0; i < bcj2NumStreams; i++) {
      _bufsSizes[i] = _bufs[i].length;
    }
    _dec = Bcj2Dec(_bufs);
    _initCommon();
  }

  // CBaseDecoder::InitCommon
  void _initCommon() {
    for (var i = 0; i < bcj2NumStreams; i++) {
      _dec.lims[i] = _dec.bufs[i] = 0;
      _readEnded[i] = false;
      _readError[i] = false;
      _extraSizes[i] = 0;
      _readSizes[i] = 0;
    }
    _dec.init();
  }

  // CBaseDecoder::GetProcessedSize_ForInStream
  int processedSizeForInStream(int i) =>
      _readSizes[i] - ((_dec.lims[i] - _dec.bufs[i]) + _extraSizes[i]);

  // CBaseDecoder::ReadInStream. The stream index is dec.state.
  void _readInStream(InStream inStream) {
    final state = _dec.state;
    var total = 0;
    {
      final buf = _bufs[state];
      final cur = _dec.bufs[state];
      _dec.lims[state] = _dec.bufs[state] = 0;
      total = _extraSizes[state];
      for (var i = 0; i < total; i++) {
        buf[i] = buf[cur + i];
      }
    }
    if (_readEnded[state] || _readError[state]) return;
    do {
      final curSize =
          inStream.read(_bufs[state], total, _bufsSizes[state] - total);
      if (curSize == 0) {
        _readEnded[state] = true;
        break;
      }
      _readSizes[state] += curSize;
      total += curSize;
    } while (total < 4 && _bcj2Is32BitStream(state));

    if (total == 0) return;

    if (_bcj2Is32BitStream(state)) {
      final extra = total & 3;
      _extraSizes[state] = extra;
      if (total < 4) {
        // A CALL/JUMP stream that ends inside a 32-bit value (S_FALSE).
        _readError[state] = true;
        return;
      }
      total -= extra;
    }
    _dec.lims[state] += total;
  }

  // CDecoder::Read
  @override
  int read(Uint8List data, int off, int size) {
    var totalProcessed = 0;
    final outSize = _outSize;
    if (outSize != null) {
      final rem = outSize - _outSizeProcessed;
      if (size > rem) size = rem;
    }
    final requested = size;
    final dec = _dec;
    dec.dest = data;
    dec.destPos = off;
    dec.destLim = off + size;

    var error = false;
    for (;;) {
      if (!dec.decode()) {
        // this error can be only at the start of the stream
        throw const SevenZipException('BCJ2 data error');
      }
      final curSize = dec.destPos - off;
      if (curSize != 0) {
        off += curSize;
        size -= curSize;
        _outSizeProcessed += curSize;
        totalProcessed += curSize;
      }
      if (dec.state >= bcj2NumStreams) break;
      _readInStream(_inStreams[dec.state]);
      if (dec.lims[dec.state] == 0) {
        // No new data in the input stream: we stop decoding. The error is
        // ignored when some data was written to the output buffer.
        if (totalProcessed == 0) error = _readError[dec.state];
        break;
      }
    }
    dec.dest = _empty; // do not keep the caller's buffer

    if (error) {
      throw const SevenZipException('BCJ2: truncated CALL/JUMP stream');
    }
    if (_finishMode && outSize != null && outSize == _outSizeProcessed) {
      if (!dec.isMaybeFinishedCode ||
          (dec.state != bcj2StreamMain && dec.state != _bcj2DecStateOrig)) {
        throw const SevenZipException('BCJ2 stream is not finished correctly');
      }
    }
    if (totalProcessed == 0 &&
        requested != 0 &&
        outSize != null &&
        _outSizeProcessed < outSize) {
      throw const SevenZipException(
          'Unexpected end of BCJ2 data', SevenZipError.unexpectedEnd);
    }
    return totalProcessed;
  }
}

/// DecoderFactory for MethodId.bcj2 (no properties).
InStream bcj2DecoderFactory(
    Uint8List props, List<InStream> inputs, int? outSize, CoderContext ctx) {
  if (props.isNotEmpty) {
    throw const SevenZipException(
        'BCJ2 has no properties', SevenZipError.unsupportedMethod);
  }
  return Bcj2Decoder(inputs, outSize: outSize);
}

// ---------------------------------------------------------------------------
// Encoder (Bcj2Enc.c)

/// EBcj2Enc_FinishMode
const int bcj2EncFinishModeContinue = 0;
const int bcj2EncFinishModeEndBlock = 1;
const int bcj2EncFinishModeEndStream = 2;

/// BCJ2_ENC_FileSizeField_UNLIMITED ((UInt64)0 - 1, as a signed int).
const int bcj2EncFileSizeFieldUnlimited = -1;

/// BCJ2_ENC_FileSize_MAX ((UInt64)0 - 2, as a signed int).
const int _bcj2EncFileSizeMax = -2;

const int _minInt64 = -0x8000000000000000;

// Unsigned 64-bit comparisons (CBcj2Enc_ip_unsigned is UInt64).
bool _ugt(int a, int b) => (a ^ _minInt64) > (b ^ _minInt64);
bool _ule(int a, int b) => (a ^ _minInt64) <= (b ^ _minInt64);

const int _convFlag = 1 << 16; // CONV_FLAG
const int _numShiftBits = 24; // NUM_SHIFT_BITS

/// CBcj2Enc. Pointers are indices: bufs[i]/lims[i] into [outBufs][i],
/// src/srcLim into [srcBuf] (the input buffer or [temp]).
class Bcj2Enc {
  final List<Uint8List> outBufs;
  final Int64List bufs = Int64List(bcj2NumStreams);
  final Int64List lims = Int64List(bcj2NumStreams);
  Uint8List srcBuf = Uint8List(0);
  int src = 0;
  int srcLim = 0;

  int state = _bcj2EncStateOrig;
  int finishMode = bcj2EncFinishModeContinue;

  int context = 0;
  int flushRem = 5;
  int isFlushState = 0;

  int cache = 0;
  int range = 0xffffffff;
  int low = 0;
  int cacheSize = 1;

  int ip64 = 0;
  int fileIp64 = 0;
  int fileSize64Minus1 = bcj2EncFileSizeFieldUnlimited;
  int relatLimit = bcj2EncRelatLimitDefault;

  int tempTarget = 0;
  int tempPos = 0;
  final Uint8List temp = Uint8List(8);
  final Uint16List probs = Uint16List(2 + 256);

  Bcj2Enc(this.outBufs);

  // Bcj2Enc_Init
  void init() {
    state = _bcj2EncStateOrig;
    finishMode = bcj2EncFinishModeContinue;
    context = 0;
    flushRem = 5;
    isFlushState = 0;
    cache = 0;
    range = 0xffffffff;
    low = 0;
    cacheSize = 1;
    ip64 = 0;
    fileIp64 = 0;
    fileSize64Minus1 = bcj2EncFileSizeFieldUnlimited;
    relatLimit = bcj2EncRelatLimitDefault;
    tempPos = 0;
    for (var i = 0; i < probs.length; i++) {
      probs[i] = _kBitModelTotal >> 1;
    }
  }

  // Bcj2Enc_IsFinished
  bool get isFinished => flushRem == 0;

  // Bcj2_RangeEnc_ShiftLow. Returns true when the RC buffer is full.
  bool _shiftLow() {
    final low32 = low & _m32;
    final high = low >> 32;
    if (low32 < 0xff000000 || high != 0) {
      final rc = outBufs[bcj2StreamRc];
      var buf = bufs[bcj2StreamRc];
      final lim = lims[bcj2StreamRc];
      do {
        if (buf == lim) {
          state = bcj2StreamRc;
          bufs[bcj2StreamRc] = buf;
          return true;
        }
        rc[buf++] = cache + high;
        cache = 0xff;
      } while (--cacheSize != 0);
      bufs[bcj2StreamRc] = buf;
      cache = (low32 >> 24) & 0xff;
    }
    cacheSize++;
    low = (low32 << 8) & _m32;
    return false;
  }

  // Bcj2Enc_Encode_2
  void _encode2() {
    if (isFlushState == 0) {
      {
        final st = state;
        if (_bcj2Is32BitStream(st)) {
          final cur = bufs[st];
          if (cur == lims[st]) return;
          final b = outBufs[st];
          final t = tempTarget;
          b[cur] = t >> 24;
          b[cur + 1] = t >> 16;
          b[cur + 2] = t >> 8;
          b[cur + 3] = t;
          bufs[st] = cur + 4;
        }
      }
      state = _bcj2EncStateOrig; // for the main reason of exit
      var src = this.src;
      var v = context;
      final sBuf = srcBuf;
      final mainBuf = outBufs[bcj2StreamMain];

      for (;;) {
        int ip;
        if (range < _kTopValue) {
          // WRITE_CONTEXT_AND_SRC
          this.src = src;
          context = v & 0xff;
          if (_shiftLow()) return;
          range = (range << 8) & _m32;
          src = this.src;
          v = context;
        }
        {
          var dest = bufs[bcj2StreamMain];
          final remSrc = srcLim - src;
          var rem = lims[bcj2StreamMain] - dest;
          if (rem >= remSrc) rem = remSrc;
          final lim = src + rem;
          // ONE_ITER, twice per loop in C
          if (src != lim) {
            for (;;) {
              final b = sBuf[src];
              mainBuf[dest++] = b;
              v = ((v & 0xff) << _numShiftBits) | b;
              if (((b + (0x100 - 0xe8)) & 0xfe) == 0) break;
              if (((v - 0x0f000080) & 0xFFFFFFF0) == 0) break;
              src++;
              if (src == lim) break;
            }
          }

          ip = ip64 + (dest - bufs[bcj2StreamMain]);
          bufs[bcj2StreamMain] = dest;
          ip64 = ip;

          if (src == lim) {
            this.src = src;
            context = v & 0xff;
            if (src != srcLim) {
              state = bcj2StreamMain;
              return;
            }
            if (finishMode != bcj2EncFinishModeEndStream) return;
            isFlushState = 1;
            break;
          }
          src++;
        }
        // A marker was found. (v) bits [24..31]: src[-2], bits [0..7]:
        // src[-1] (e8/e9/8x).
        if (srcLim - src >= 4) {
          final relat = sBuf[src] |
              (sBuf[src + 1] << 8) |
              (sBuf[src + 2] << 16) |
              (sBuf[src + 3] << 24);
          ip -= fileIp64;
          if (_ugt(ip, ((v + 0x20) >> 5) & 1)) {
            if (_ule(ip + 4 + relat.toSigned(32), fileSize64Minus1)) {
              if ((((relat + relatLimit) & _m32) >> 1) < relatLimit) {
                v |= _convFlag;
              }
            }
          }
        } else if (finishMode == bcj2EncFinishModeContinue) {
          // (srcLim - src < 4): wait for more data, the marker byte is
          // processed again in the next call.
          ip64--;
          bufs[bcj2StreamMain]--;
          src--;
          v >>= _numShiftBits;
          this.src = src;
          context = v & 0xff;
          return;
        }
        {
          final c = ((v + 0x17) >> 6) & 1;
          final index =
              ((-c) & ((v >> _numShiftBits) & 0xff)) + c + ((v >> 5) & 1);
          final ttt = probs[index];
          final bound = (range >> _kNumBitModelTotalBits) * ttt;
          if ((v & _convFlag) == 0) {
            range = bound;
            probs[index] = ttt + ((_kBitModelTotal - ttt) >> _kNumMoveBits);
            continue;
          }
          low += bound;
          range -= bound;
          probs[index] = ttt - (ttt >> _kNumMoveBits);
        }
        {
          final cj = (((v + 0x57) >> 6) & 1) + bcj2StreamCall;
          var ip2 = ip64;
          v = sBuf[src] |
              (sBuf[src + 1] << 8) |
              (sBuf[src + 2] << 16) |
              (sBuf[src + 3] << 24);
          ip2 += 4;
          ip64 = ip2;
          src += 4;
          final absol = (ip2 + v) & _m32;
          final cur = bufs[cj];
          v >>= 24;
          if (cur == lims[cj]) {
            state = cj;
            tempTarget = absol;
            this.src = src;
            context = v & 0xff;
            return;
          }
          final b = outBufs[cj];
          b[cur] = absol >> 24;
          b[cur + 1] = absol >> 16;
          b[cur + 2] = absol >> 8;
          b[cur + 3] = absol;
          bufs[cj] = cur + 4;
        }
      }
    }

    for (; flushRem != 0; flushRem--) {
      if (_shiftLow()) return;
    }
    state = _bcj2EncStateFinished;
  }

  // Bcj2Enc_Encode
  void encode() {
    if (tempPos != 0) {
      // extra: number of bytes copied from (src) to (temp) in this call
      var extra = 0;
      for (;;) {
        final sBuf = srcBuf;
        final s = src;
        final sLim = srcLim;
        final fm = finishMode;
        if (s != sLim) {
          // There is src data after the data copied to temp[]: we use
          // MODE_CONTINUE for the temp data.
          finishMode = bcj2EncFinishModeContinue;
        }
        srcBuf = temp;
        src = 0;
        srcLim = tempPos;
        _encode2();
        {
          final num = src;
          final tPos = tempPos - num;
          tempPos = tPos;
          for (var i = 0; i < tPos; i++) {
            temp[i] = temp[i + num];
          }
          srcBuf = sBuf;
          src = s;
          srcLim = sLim;
          finishMode = fm;
          if (state != _bcj2EncStateOrig) {
            // Roll back (src) and tempPos, if it is possible.
            if (extra >= tPos) extra = tPos;
            src = s - extra;
            tempPos = tPos - extra;
            return;
          }
          if (s == sLim) return;
          if (extra >= tPos) {
            // temp[] holds only data of this call's src: encode without it.
            src = s - tPos;
            tempPos = 0;
            break;
          }
          temp[tPos] = sBuf[s];
          tempPos = tPos + 1;
          src = s + 1;
          extra++;
        }
      }
    }

    _encode2();

    if (state == _bcj2EncStateOrig) {
      final rem = srcLim - src;
      if (rem != 0) {
        for (var i = 0; i < rem; i++) {
          temp[i] = srcBuf[src + i];
        }
        src = srcLim;
        tempPos = rem;
      }
    }
  }
}

/// Returns the size of sub stream [index] of the input (a file of a solid
/// 7z folder), or null when it is not known (S_FALSE). This mirrors
/// ICompressGetSubStreamSize::GetSubStreamSize of 7-Zip's CFolderInStream,
/// which the BCJ2 encoder uses to limit conversions to each file.
typedef Bcj2SubStreamSize = int? Function(int index);

/// NCompress::NBcj2::CEncoder::CodeReal. Reads [input] to its end and writes
/// the four BCJ2 streams. Returns the number of bytes read.
///
/// [inSize] is the input size when known (7-Zip's 7z encoder does not pass
/// it). [subStreamSize] gives the sizes of the files in the input, as 7-Zip
/// does from its folder input stream; without it the whole input is one
/// block. [relatLimit] is 7-Zip's "d" property of BCJ2, 0xF000000 unless
/// set. [bufSize] is the size of the input and of each output buffer.
int bcj2Encode(InStream input, OutStream main, OutStream call, OutStream jump,
    OutStream rc,
    {int? inSize,
    Bcj2SubStreamSize? subStreamSize,
    int relatLimit = bcj2EncRelatLimitDefault,
    ProgressCallback? progress,
    int bufSize = 1 << 18}) {
  if (relatLimit < 0 || relatLimit > bcj2EncRelatLimitMax) {
    throw const SevenZipException(
        'Invalid BCJ2 relat limit', SevenZipError.unsupportedMethod);
  }
  final outStreams = [main, call, jump, rc];
  // CBaseCoder::Alloc
  var size = bufSize & ~3;
  if (size < 4) size = 4;
  final bufs = List<Uint8List>.generate(bcj2NumStreams, (_) => Uint8List(size));
  final inBuf = Uint8List(size);

  var fileSizeMinus1 = bcj2EncFileSizeFieldUnlimited;
  if (inSize != null) {
    if (_ule(inSize, _bcj2EncFileSizeMax)) fileSizeMinus1 = inSize - 1;
  }

  var getSubStreamSize = subStreamSize;

  final enc = Bcj2Enc(bufs);
  enc.srcBuf = inBuf;
  enc.src = 0;
  enc.srcLim = 0;
  for (var i = 0; i < bcj2NumStreams; i++) {
    enc.bufs[i] = 0;
    enc.lims[i] = size;
  }
  enc.init();
  enc.fileIp64 = 0;
  enc.fileSize64Minus1 = fileSizeMinus1;
  enc.relatLimit = relatLimit;
  enc.finishMode = bcj2EncFinishModeContinue;

  // Variables that correspond to processed data in the input stream:
  var inPosWithoutTemp = 0; // does not include data in enc.temp[]
  var inPosWithTemp = 0; // includes data in enc.temp[]

  var prevProgress = 0;
  var totalRead = 0; // size read from the input stream
  var outSizeRc = 0;
  var subStreamIndex = 0;
  var subStreamStartPos = 0; // global start offset of subStreams[index]
  var subStreamSizeCur = 0;
  var srcLimRead = 0;
  var readWasFinished = false;
  var isAccurate = false;
  var wasUnknownSize = false;

  for (;;) {
    if (readWasFinished && enc.srcLim == srcLimRead) {
      enc.finishMode = bcj2EncFinishModeEndStream;
    }

    enc.encode();

    inPosWithTemp = totalRead - (srcLimRead - enc.src);
    inPosWithoutTemp = inPosWithTemp - enc.tempPos;

    if (enc.isFinished) break;

    if (enc.state < bcj2NumStreams) {
      final st = enc.state;
      if (enc.bufs[st] != enc.lims[st]) {
        throw const SevenZipException('BCJ2 encoder error (E_FAIL)');
      }
      final curSize = enc.bufs[st];
      outStreams[st].write(bufs[st], 0, curSize);
      if (st == bcj2StreamRc) outSizeRc += curSize;
      enc.bufs[st] = 0;
      enc.lims[st] = size;
    } else {
      if (enc.state != _bcj2EncStateOrig ||
          enc.src != enc.srcLim ||
          (enc.finishMode != bcj2EncFinishModeContinue && enc.tempPos != 0)) {
        throw const SevenZipException('BCJ2 encoder error (E_FAIL)');
      }

      if (enc.src == srcLimRead) {
        if (readWasFinished) {
          throw const SevenZipException('BCJ2 encoder error (E_FAIL)');
        }
        final curSize = input.read(inBuf, 0, size);
        if (curSize == 0) readWasFinished = true;
        totalRead += curSize;
        enc.src = 0;
        srcLimRead = curSize;
      }
      enc.srcLim = srcLimRead;

      if (getSubStreamSize != null) {
        // Default conversion options, used if the sub stream related
        // options are not OK.
        enc.fileIp64 = 0;
        enc.fileSize64Minus1 = fileSizeMinus1;
        for (;;) {
          int nextPos;
          if (isAccurate) {
            nextPos = subStreamStartPos + subStreamSizeCur;
          } else {
            final s = getSubStreamSize!(subStreamIndex);
            if (s == null) {
              // S_FALSE: the sub stream size is unknown, default settings.
              enc.finishMode = bcj2EncFinishModeContinue;
              wasUnknownSize = true;
              break;
            }
            subStreamSizeCur = s;
            nextPos = subStreamStartPos + subStreamSizeCur;
            if (subStreamSizeCur == -1) {
              enc.finishMode = bcj2EncFinishModeContinue;
              wasUnknownSize = true;
              break;
            }
            if (nextPos < subStreamStartPos) {
              throw const SevenZipException('BCJ2 encoder error (E_FAIL)');
            }
            isAccurate = nextPos < totalRead ||
                (nextPos <= totalRead && readWasFinished);
          }

          if (nextPos < inPosWithTemp) {
            if (wasUnknownSize) {
              enc.finishMode = bcj2EncFinishModeContinue;
              getSubStreamSize = null;
              break;
            }
            throw const SevenZipException('BCJ2 encoder error (E_FAIL)');
          }

          if (nextPos <= inPosWithTemp) {
            if (enc.finishMode != bcj2EncFinishModeContinue) {
              subStreamStartPos = nextPos;
              subStreamSizeCur = 0;
              wasUnknownSize = false;
              subStreamIndex++;
              isAccurate = false;
              continue;
            }
          }

          enc.finishMode = bcj2EncFinishModeContinue;

          if (!wasUnknownSize && _ule(subStreamSizeCur, _bcj2EncFileSizeMax)) {
            enc.fileIp64 = enc.ip64 + (subStreamStartPos - inPosWithoutTemp);
            enc.fileSize64Minus1 = subStreamSizeCur - 1;
          }

          if (isAccurate) {
            final rem = totalRead - nextPos;
            if (enc.srcLim - enc.src < rem) {
              throw const SevenZipException('BCJ2 encoder error (E_FAIL)');
            }
            enc.srcLim -= rem;
            enc.finishMode = bcj2EncFinishModeEndBlock;
          }
          break;
        }
      }
    }

    if (progress != null && inPosWithoutTemp - prevProgress >= (1 << 22)) {
      prevProgress = inPosWithoutTemp;
      final outSize2 = inPosWithoutTemp + outSizeRc + enc.bufs[bcj2StreamRc];
      progress(inPosWithoutTemp, outSize2);
    }
  }

  for (var i = 0; i < bcj2NumStreams; i++) {
    outStreams[i].write(bufs[i], 0, enc.bufs[i]);
  }
  for (var i = 0; i < bcj2NumStreams; i++) {
    outStreams[i].flush();
  }
  return totalRead;
}
