// Zip method 1 (Shrink) decoder, written from the PKWARE APPNOTE, section
// 5.1 (UnShrinking). No code of 7-Zip's or Info-ZIP's decoders is used.
//
// Shrink is LZW with codes of 9 to 13 bits, packed starting with the least
// significant bit of each byte. Codes 0 to 255 stand for single bytes, code
// 256 is a control code and codes 257 to 8191 are strings, each one stored
// as the code of a prefix string plus one final byte.
//
// Control: after code 256 comes a subcode, read at the current size. 1 makes
// every following code one bit wider (the size never grows by itself), 2 is
// a partial clear. Any other subcode is an error.
//
// Strings: every code after the first one adds a string to the table, made
// of the previous code plus the first byte of the string of the new code.
// It goes into the lowest free code. When the new code is the very code
// being added (the "KwKwK" case of LZW: the encoder used a string it had
// only just made), its first byte is the first byte of the previous string.
// When no code is free, nothing is added.
//
// Partial clear: every string that no other string in use has as its prefix
// is freed, in one pass over the table (a string whose only children get
// freed stays). The code size does not change. Freed codes are then handed
// out again from the lowest one up. A freed entry keeps its prefix and byte
// until it is given out again, and strings are always resolved through the
// current table: an encoder may add a string right after a clear whose
// prefix is the code it just wrote, even when the clear freed that code.
// 7-Zip 23.01 reads such streams this way (Info-ZIP unzip 6 rejects the ones
// that later use such a string).

import 'dart:typed_data';

import '../../io/streams.dart';

const int _kNumCodes = 8192;
const int _kFirstFree = 257;
const int _kMaxBits = 13;

/// Decodes a Shrink stream (zip method 1) of [outSize] bytes.
class ShrinkDecoder implements InStream {
  final InStream _in;
  int _remaining;

  final Uint8List _inBuf = Uint8List(1 << 16);
  int _inPos = 0;
  int _inLim = 0;
  int _padBytes = 0;
  int _bitBuf = 0;
  int _bitCnt = 0;

  final Uint16List _prefix = Uint16List(_kNumCodes);
  final Uint8List _suffix = Uint8List(_kNumCodes);
  final Uint8List _inUse = Uint8List(_kNumCodes);
  final Uint8List _isParent = Uint8List(_kNumCodes);

  /// Pending output of the last string: _stack[_sp, _kNumCodes).
  final Uint8List _stack = Uint8List(_kNumCodes);
  int _sp = _kNumCodes;

  int _codeSize = 9;
  int _prev = -1;
  int _prevFirst = 0;
  int _nextFree = _kFirstFree;

  ShrinkDecoder(InStream packed, int outSize)
      : _in = packed,
        _remaining = outSize;

  // Reads the next chunk of packed data, or zero padding past its end.
  int _fill() {
    final n = _in.read(_inBuf, 0, _inBuf.length);
    if (n > 0) return n;
    _padBytes += 4;
    if (_padBytes > 64) {
      throw _endError();
    }
    _inBuf.fillRange(0, 4, 0);
    return 4;
  }

  static SevenZipException _endError() => const SevenZipException(
      'Unexpected end of Shrink data', SevenZipError.unexpectedEnd);

  // A corrupt stream error, or an end error when it came from reading past
  // the end of the input (unread bits fewer than the padding).
  SevenZipException _corrupt(String msg, int unreadBits) =>
      unreadBits < _padBytes * 8 ? _endError() : SevenZipException(msg);

  @override
  int read(Uint8List buf, int off, int len) {
    if (len > _remaining) len = _remaining;
    if (len <= 0) return 0;
    final end = off + len;
    var pos = off;
    final stack = _stack;
    final prefix = _prefix;
    final suffix = _suffix;
    final inUse = _inUse;
    final inBuf = _inBuf;
    var inPos = _inPos;
    var inLim = _inLim;
    var bitBuf = _bitBuf;
    var bitCnt = _bitCnt;
    var codeSize = _codeSize;
    var sp = _sp;

    while (pos < end) {
      if (sp < _kNumCodes) {
        var n = _kNumCodes - sp;
        if (n > end - pos) n = end - pos;
        buf.setRange(pos, pos + n, stack, sp);
        pos += n;
        sp += n;
        continue;
      }
      while (bitCnt < codeSize) {
        if (inPos == inLim) {
          inLim = _fill();
          inPos = 0;
        }
        bitBuf |= inBuf[inPos++] << bitCnt;
        bitCnt += 8;
      }
      final code = bitBuf & ((1 << codeSize) - 1);
      bitBuf >>= codeSize;
      bitCnt -= codeSize;

      if (code == 256) {
        while (bitCnt < codeSize) {
          if (inPos == inLim) {
            inLim = _fill();
            inPos = 0;
          }
          bitBuf |= inBuf[inPos++] << bitCnt;
          bitCnt += 8;
        }
        final sub = bitBuf & ((1 << codeSize) - 1);
        bitBuf >>= codeSize;
        bitCnt -= codeSize;
        if (sub == 1) {
          if (codeSize == _kMaxBits) {
            throw _corrupt(
                'Shrink code size above 13 bits', bitCnt + (inLim - inPos) * 8);
          }
          codeSize++;
        } else if (sub == 2) {
          _partialClear();
        } else {
          throw _corrupt(
              'Bad Shrink control code', bitCnt + (inLim - inPos) * 8);
        }
        continue;
      }

      final prev = _prev;
      if (prev < 0) {
        if (code > 255) {
          throw _corrupt('Bad first Shrink code', bitCnt + (inLim - inPos) * 8);
        }
        buf[pos++] = code;
        _prev = code;
        _prevFirst = code;
        continue;
      }
      if (code < 256) {
        final n = _nextFree;
        if (n < _kNumCodes) {
          prefix[n] = prev;
          suffix[n] = code;
          inUse[n] = 1;
          _advanceFree();
        }
        buf[pos++] = code;
        _prev = code;
        _prevFirst = code;
        continue;
      }

      final n = _nextFree;
      if (inUse[code] == 0 && code != n) {
        throw _corrupt('Bad Shrink code', bitCnt + (inLim - inPos) * 8);
      }
      // Resolve the string of the code into the stack. If its chain goes
      // through the free code n that is about to be added (always so in
      // the KwKwK case), the first byte is the first byte of the previous
      // string, and the chain is walked again once n holds its string.
      var c = code;
      var s = _kNumCodes;
      var hitNew = false;
      while (c >= _kFirstFree) {
        if (c == n) {
          hitNew = true;
          break;
        }
        if (s == 0) {
          throw _corrupt('Bad Shrink string', bitCnt + (inLim - inPos) * 8);
        }
        stack[--s] = suffix[c];
        c = prefix[c];
      }
      int first;
      if (hitNew) {
        first = _prevFirst;
      } else {
        if (c == 256 || s == 0) {
          throw _corrupt('Bad Shrink string', bitCnt + (inLim - inPos) * 8);
        }
        first = c;
        stack[--s] = c;
      }
      if (n < _kNumCodes) {
        prefix[n] = prev;
        suffix[n] = first;
        inUse[n] = 1;
        _advanceFree();
      }
      if (hitNew) {
        c = code;
        s = _kNumCodes;
        while (c >= _kFirstFree) {
          if (s == 0) {
            throw _corrupt('Bad Shrink string', bitCnt + (inLim - inPos) * 8);
          }
          stack[--s] = suffix[c];
          c = prefix[c];
        }
        if (c == 256 || s == 0) {
          throw _corrupt('Bad Shrink string', bitCnt + (inLim - inPos) * 8);
        }
        stack[--s] = c;
      }
      _prev = code;
      _prevFirst = first;
      sp = s;
    }

    _inPos = inPos;
    _inLim = inLim;
    _bitBuf = bitBuf;
    _bitCnt = bitCnt;
    _codeSize = codeSize;
    _sp = sp;
    if (bitCnt + (inLim - inPos) * 8 < _padBytes * 8) {
      throw _endError();
    }
    _remaining -= len;
    return len;
  }

  void _advanceFree() {
    var n = _nextFree + 1;
    final inUse = _inUse;
    while (n < _kNumCodes && inUse[n] != 0) {
      n++;
    }
    _nextFree = n;
  }

  // Frees every string that is not the prefix of another string in use.
  void _partialClear() {
    final prefix = _prefix;
    final inUse = _inUse;
    final isParent = _isParent;
    isParent.fillRange(0, _kNumCodes, 0);
    for (var c = _kFirstFree; c < _kNumCodes; c++) {
      if (inUse[c] != 0) isParent[prefix[c]] = 1;
    }
    for (var c = _kFirstFree; c < _kNumCodes; c++) {
      if (isParent[c] == 0) inUse[c] = 0;
    }
    _nextFree = _kFirstFree - 1;
    _advanceFree();
  }
}
