// Zip methods 2 to 5 (Reduce with compression factor 1 to 4) decoder,
// written from the PKWARE APPNOTE, section 5.2 (Expanding). No code of
// 7-Zip's or Info-ZIP's decoders is used.
//
// Two stages, both done byte by byte in one loop here:
//
// 1. Follower sets. The packed data starts with 256 sets, S(255) first and
//    S(0) last, each a 6 bit count N (at most 32) and N bytes. Then, for
//    every byte, with L the previous byte of this stage (0 at the start):
//    if S(L) is empty the byte follows as 8 bits; otherwise one bit comes
//    first, 1 for a plain 8 bit byte, 0 for an index into S(L) of B(N)
//    bits, where B(N) is the number of bits needed for N - 1 but at least
//    one (a set of one byte still spends one bit on its index). All bit
//    fields are packed starting with the least significant bit.
//
// 2. DLE expansion of the bytes of stage 1. A byte other than 0x90 (DLE)
//    is output as is. DLE 0 is a literal 0x90. DLE V (V not 0) is a match:
//    its length is the low (8 - factor) bits of V, and when they are all
//    ones one more byte is added to it; the next byte C gives the distance
//    (high factor bits of V) * 256 + C + 1. Length + 3 bytes are copied
//    from that distance back, the copy may overlap its own output, and
//    bytes before the start of the output read as zeros.

import 'dart:typed_data';

import '../../io/streams.dart';

const int _kDle = 0x90;
const int _kWinSize = 4096; // the largest distance, (1 << 4) * 256
const int _kWinMask = _kWinSize - 1;

/// Decodes a Reduce stream (zip methods 2 to 5, [factor] = method - 1) of
/// [outSize] bytes.
class ReduceDecoder implements InStream {
  final InStream _in;
  int _remaining;
  final int _factor;

  final Uint8List _inBuf = Uint8List(1 << 16);
  int _inPos = 0;
  int _inLim = 0;
  int _padBytes = 0;
  int _bitBuf = 0;
  int _bitCnt = 0;

  bool _headerDone = false;
  final Uint8List _setLen = Uint8List(256);
  final Uint8List _setBits = Uint8List(256);
  final Uint8List _sets = Uint8List(256 * 32);
  int _last = 0;

  final Uint8List _win = Uint8List(_kWinSize);
  int _winPos = 0;
  int _state = 0;
  int _v = 0;
  int _len = 0;
  int _matchLen = 0;
  int _matchDist = 0;

  ReduceDecoder(InStream packed, int outSize, int factor)
      : _in = packed,
        _remaining = outSize,
        _factor = factor {
    if (factor < 1 || factor > 4) {
      throw SevenZipException(
          'Bad Reduce factor $factor', SevenZipError.unsupportedMethod);
    }
  }

  // Reads the next chunk of packed data, or zero padding past its end.
  int _fill() {
    final n = _in.read(_inBuf, 0, _inBuf.length);
    if (n > 0) return n;
    _padBytes += 4;
    if (_padBytes > 64) throw _endError();
    _inBuf.fillRange(0, 4, 0);
    return 4;
  }

  static SevenZipException _endError() => const SevenZipException(
      'Unexpected end of Reduce data', SevenZipError.unexpectedEnd);

  // A corrupt stream error, or an end error when it came from reading past
  // the end of the input (unread bits fewer than the padding).
  SevenZipException _corrupt(String msg, int unreadBits) =>
      unreadBits < _padBytes * 8 ? _endError() : SevenZipException(msg);

  int _bits(int n) {
    while (_bitCnt < n) {
      if (_inPos == _inLim) {
        _inLim = _fill();
        _inPos = 0;
      }
      _bitBuf |= _inBuf[_inPos++] << _bitCnt;
      _bitCnt += 8;
    }
    final v = _bitBuf & ((1 << n) - 1);
    _bitBuf >>= n;
    _bitCnt -= n;
    return v;
  }

  void _readSets() {
    for (var j = 255; j >= 0; j--) {
      final n = _bits(6);
      if (n > 32) {
        throw _corrupt(
            'Bad Reduce follower set', _bitCnt + (_inLim - _inPos) * 8);
      }
      _setLen[j] = n;
      var b = 1;
      while (n > (1 << b)) {
        b++;
      }
      _setBits[j] = b;
      for (var k = 0; k < n; k++) {
        _sets[j * 32 + k] = _bits(8);
      }
    }
    _headerDone = true;
  }

  @override
  int read(Uint8List buf, int off, int len) {
    if (len > _remaining) len = _remaining;
    if (len <= 0) return 0;
    if (!_headerDone) _readSets();
    final end = off + len;
    var pos = off;
    final win = _win;
    final setLen = _setLen;
    final setBits = _setBits;
    final sets = _sets;
    final inBuf = _inBuf;
    final lenMask = (1 << (8 - _factor)) - 1;
    final distShift = 8 - _factor;
    var inPos = _inPos;
    var inLim = _inLim;
    var bitBuf = _bitBuf;
    var bitCnt = _bitCnt;
    var wp = _winPos;
    var last = _last;
    var state = _state;
    var v = _v;
    var mlen = _len;
    var matchLen = _matchLen;
    var dist = _matchDist;

    while (pos < end) {
      if (matchLen > 0) {
        var n = matchLen;
        if (n > end - pos) n = end - pos;
        matchLen -= n;
        var src = (wp - dist) & _kWinMask;
        while (n-- > 0) {
          final b = win[src];
          win[wp] = b;
          buf[pos++] = b;
          wp = (wp + 1) & _kWinMask;
          src = (src + 1) & _kWinMask;
        }
        continue;
      }

      // Stage 1: the next byte from the follower sets.
      while (bitCnt < 9) {
        if (inPos == inLim) {
          inLim = _fill();
          inPos = 0;
        }
        bitBuf |= inBuf[inPos++] << bitCnt;
        bitCnt += 8;
      }
      int c;
      final n = setLen[last];
      if (n == 0) {
        c = bitBuf & 0xFF;
        bitBuf >>= 8;
        bitCnt -= 8;
      } else if ((bitBuf & 1) != 0) {
        c = (bitBuf >> 1) & 0xFF;
        bitBuf >>= 9;
        bitCnt -= 9;
      } else {
        final nb = setBits[last];
        final i = (bitBuf >> 1) & ((1 << nb) - 1);
        bitBuf >>= nb + 1;
        bitCnt -= nb + 1;
        if (i >= n) {
          throw _corrupt(
              'Bad Reduce follower index', bitCnt + (inLim - inPos) * 8);
        }
        c = sets[last * 32 + i];
      }
      last = c;

      // Stage 2: DLE expansion.
      switch (state) {
        case 0:
          if (c != _kDle) {
            win[wp] = c;
            wp = (wp + 1) & _kWinMask;
            buf[pos++] = c;
          } else {
            state = 1;
          }
        case 1:
          if (c != 0) {
            v = c;
            mlen = c & lenMask;
            state = mlen == lenMask ? 2 : 3;
          } else {
            win[wp] = _kDle;
            wp = (wp + 1) & _kWinMask;
            buf[pos++] = _kDle;
            state = 0;
          }
        case 2:
          mlen += c;
          state = 3;
        default:
          dist = ((v >> distShift) << 8) + c + 1;
          matchLen = mlen + 3;
          state = 0;
      }
    }

    _inPos = inPos;
    _inLim = inLim;
    _bitBuf = bitBuf;
    _bitCnt = bitCnt;
    _winPos = wp;
    _last = last;
    _state = state;
    _v = v;
    _len = mlen;
    _matchLen = matchLen;
    _matchDist = dist;
    if (bitCnt + (inLim - inPos) * 8 < _padBytes * 8) throw _endError();
    _remaining -= len;
    return len;
  }
}
