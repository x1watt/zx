// The RAR 1.5 decompressor (unpack version 15, the method of RAR 1.5x
// archives; RAR 1.3 used the same coder). An independent implementation,
// written from format descriptions (the decoding tables and the update
// rules of the adaptive coder, as the prose of the rar-research documents
// states them) and checked black box against archives written by RAR 1.55
// for DOS and extracted by unrar. No unRAR derived code was read.
//
// The coder has three kinds of tokens, chosen by flag bits that are
// themselves coded: literals (a byte ranked by frequency), short matches
// (small distances from a move to front list, or one of the last four
// distances) and long matches (distances from a second ranked list plus
// seven raw bits). Every ranked list adapts to the symbols seen. After
// long runs of literals the coder turns to a "static" mode, where only
// literals and escapes are coded.

import 'dart:typed_data';

import '../../io/streams.dart';

// The window: distances are below 64 KiB and a match is at most a few
// hundred bytes, so 256 KiB keeps the history while the output of 64 KiB
// steps is written.
const int _winSize = 1 << 18;
const int _winMask = _winSize - 1;
const int _flushStep = 1 << 16;

// The number decoders: for a start width s, each limit of the table that
// the 16 bit window reaches adds one bit to the code, and the value is the
// offset in that code length plus the base of the length.
const int _startL1 = 2;
const List<int> _decL1 = [
  0x8000, 0xA000, 0xC000, 0xD000, 0xE000, 0xEA00, //
  0xEE00, 0xF000, 0xF200, 0xF200, 0xFFFF,
];
const List<int> _posL1 = [0, 0, 0, 2, 3, 5, 7, 11, 16, 20, 24, 32, 32];

const int _startL2 = 3;
const List<int> _decL2 = [
  0xA000, 0xC000, 0xD000, 0xE000, 0xEA00, 0xEE00, //
  0xF000, 0xF200, 0xF240, 0xFFFF,
];
const List<int> _posL2 = [0, 0, 0, 0, 5, 7, 9, 13, 18, 22, 26, 34, 36];

const int _startHf0 = 4;
const List<int> _decHf0 = [
  0x8000, 0xC000, 0xE000, 0xF200, 0xF200, 0xF200, //
  0xF200, 0xF200, 0xFFFF,
];
const List<int> _posHf0 = [0, 0, 0, 0, 0, 8, 16, 24, 33, 33, 33, 33, 33];

const int _startHf1 = 5;
const List<int> _decHf1 = [
  0x2000, 0xC000, 0xE000, 0xF000, 0xF200, 0xF200, //
  0xF7E0, 0xFFFF,
];
const List<int> _posHf1 = [0, 0, 0, 0, 0, 0, 4, 44, 60, 76, 80, 80, 127];

const int _startHf2 = 5;
const List<int> _decHf2 = [
  0x1000, 0x2400, 0x8000, 0xC000, 0xFA00, 0xFFFF, //
  0xFFFF, 0xFFFF,
];
const List<int> _posHf2 = [0, 0, 0, 0, 0, 0, 2, 7, 53, 117, 233, 0, 0];

const int _startHf3 = 6;
const List<int> _decHf3 = [
  0x0800, 0x2400, 0xEE00, 0xFE80, 0xFFFF, 0xFFFF, 0xFFFF, //
];
const List<int> _posHf3 = [0, 0, 0, 0, 0, 0, 0, 2, 16, 218, 251, 0, 0];

const int _startHf4 = 8;
const List<int> _decHf4 = [0xFF00, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF];
const List<int> _posHf4 = [0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 0, 0, 0];

// The prefix codes of the short matches: code i has _shortLen bits and
// the prefix _shortXor (the lengths of codes 1 of the first set and 3 of
// the second set are 3 or 4, switched by an escape).
const List<int> _shortLen1 = [1, 3, 4, 4, 5, 6, 7, 8, 8, 4, 4, 5, 6, 6, 4, 0];
const List<int> _shortXor1 = [
  0x00, 0xA0, 0xD0, 0xE0, 0xF0, 0xF8, 0xFC, 0xFE, //
  0xFF, 0xC0, 0x80, 0x90, 0x98, 0x9C, 0xB0,
];
const List<int> _shortLen2 = [2, 3, 3, 3, 4, 4, 5, 6, 6, 4, 4, 5, 6, 6, 4, 0];
const List<int> _shortXor2 = [
  0x00, 0x40, 0x60, 0xA0, 0xD0, 0xE0, 0xF0, 0xF8, //
  0xFC, 0xC0, 0x80, 0x90, 0x98, 0x9C, 0xB0,
];

/// The RAR 1.5 decoder; its state lives across the files of a solid
/// archive.
final class Rar15Decoder {
  final Uint8List _win = Uint8List(_winSize);
  // absolute output position (the window index is _pos & _winMask)
  int _pos = 0;
  bool _started = false;

  // the ranked lists: symbol in the high byte, rank in the low byte
  final Uint16List _chSet = Uint16List(256);
  final Uint16List _chSetA = Uint16List(256);
  final Uint16List _chSetB = Uint16List(256);
  final Uint16List _chSetC = Uint16List(256);
  // the next place of each rank
  final Uint16List _nToPl = Uint16List(256);
  final Uint16List _nToPlB = Uint16List(256);
  final Uint16List _nToPlC = Uint16List(256);

  // the adaptive statistics
  int _avrPlc = 0;
  int _avrPlcB = 0;
  int _avrLn1 = 0;
  int _avrLn2 = 0;
  int _avrLn3 = 0;
  int _maxDist3 = 0;
  int _nhfb = 0;
  int _nlzb = 0;
  int _numHuf = 0;
  int _buf60 = 0;

  // the distances
  final Int64List _oldDist = Int64List(4);
  int _oldDistPtr = 0;
  int _lastDist = 0;
  int _lastLength = 0;

  // per file state
  int _stMode = 0;
  int _lCount = 0;
  int _flagBuf = 0;
  int _flagsCnt = 0;

  // the bit reader
  InStream? _src;
  final Uint8List _inBuf = Uint8List(1 << 16);
  int _inPos = 0;
  int _inLen = 0;
  bool _inEof = false;
  int _overrun = 0;
  int _bitBuf = 0;
  int _bitCount = 0;

  /// Decodes one file of [unpSize] bytes from [src] into [out]; [solid]
  /// continues the state of the previous file.
  void decodeFile(InStream src, OutStream out, int unpSize, bool solid) {
    if (!solid || !_started) _reset();
    _started = true;
    _stMode = 0;
    _lCount = 0;
    _flagBuf = 0;
    _flagsCnt = 0;
    _src = src;
    _inPos = 0;
    _inLen = 0;
    _inEof = false;
    _overrun = 0;
    _bitBuf = 0;
    _bitCount = 0;
    try {
      _run(out, unpSize);
    } finally {
      _src = null;
    }
  }

  void _reset() {
    _win.fillRange(0, _winSize, 0);
    _pos = 0;
    for (var i = 0; i < 256; i++) {
      _chSet[i] = i << 8;
      _chSetB[i] = i << 8;
      _chSetA[i] = i;
      _chSetC[i] = ((256 - i) & 0xFF) << 8;
    }
    _nToPl.fillRange(0, 256, 0);
    _nToPlB.fillRange(0, 256, 0);
    _nToPlC.fillRange(0, 256, 0);
    _rerank(_chSetB, _nToPlB);
    _avrPlc = 0x3500;
    _avrPlcB = 0;
    _avrLn1 = 0;
    _avrLn2 = 0;
    _avrLn3 = 0;
    _maxDist3 = 0x2001;
    _nhfb = 0x80;
    _nlzb = 0x80;
    _numHuf = 0;
    _buf60 = 0;
    // an unused distance points before the start: it copies zeros
    _oldDist.fillRange(0, 4, 0x7FFFFFFF);
    _oldDistPtr = 0;
    _lastDist = 0x7FFFFFFF;
    _lastLength = 0;
  }

  // Gives every entry a rank again when a counter runs over: the table is
  // cut into 8 groups of 32 entries, ranks 7 down to 0, and the next
  // places start at the groups.
  static void _rerank(Uint16List set, Uint16List place) {
    var k = 0;
    for (var rank = 7; rank >= 0; rank--) {
      for (var j = 0; j < 32; j++, k++) {
        set[k] = (set[k] & 0xFF00) | rank;
      }
    }
    place.fillRange(0, 256, 0);
    for (var rank = 6; rank >= 0; rank--) {
      place[rank] = (7 - rank) * 32;
    }
  }

  // The bit reader: a 16 bit window over the bytes, zeros after the end.

  int _readByte() {
    if (_inPos == _inLen) {
      if (!_inEof) {
        _inLen = readFully(_src!, _inBuf, 0, _inBuf.length);
        _inPos = 0;
        if (_inLen < _inBuf.length) _inEof = true;
      }
      if (_inPos == _inLen) {
        if (++_overrun > 64) {
          throw const SevenZipException(
              'RAR: truncated file data', SevenZipError.unexpectedEnd);
        }
        return 0;
      }
    }
    return _inBuf[_inPos++];
  }

  // the next 16 bits
  @pragma('vm:prefer-inline')
  int _get16() {
    while (_bitCount < 16) {
      _bitBuf = ((_bitBuf << 8) | _readByte()) & 0xFFFFFFFF;
      _bitCount += 8;
    }
    return (_bitBuf >> (_bitCount - 16)) & 0xFFFF;
  }

  @pragma('vm:prefer-inline')
  void _skip(int n) {
    _bitCount -= n;
  }

  // Decodes a number with a limit table: the code grows one bit per limit
  // at or below the (16 bit) window [v].
  int _number(int v, int start, List<int> dec, List<int> pos) {
    v &= 0xFFF0;
    var i = 0;
    var bits = start;
    while (dec[i] <= v) {
      i++;
      bits++;
    }
    _skip(bits);
    final base = i > 0 ? dec[i - 1] : 0;
    return ((v - base) >> (16 - bits)) + pos[bits];
  }

  void _run(OutStream out, int size) {
    final end = _pos + size;
    var written = _pos;
    if (size > 0) {
      _readFlags();
      _flagsCnt = 8;
    }
    while (_pos < end) {
      if (_stMode != 0) {
        _literal();
      } else {
        if (--_flagsCnt < 0) {
          _readFlags();
          _flagsCnt = 7;
        }
        if ((_flagBuf & 0x80) != 0) {
          _flagBuf = (_flagBuf << 1) & 0xFF;
          if (_nlzb > _nhfb) {
            _longMatch();
          } else {
            _literal();
          }
        } else {
          _flagBuf = (_flagBuf << 1) & 0xFF;
          if (--_flagsCnt < 0) {
            _readFlags();
            _flagsCnt = 7;
          }
          if ((_flagBuf & 0x80) != 0) {
            _flagBuf = (_flagBuf << 1) & 0xFF;
            if (_nlzb > _nhfb) {
              _literal();
            } else {
              _longMatch();
            }
          } else {
            _flagBuf = (_flagBuf << 1) & 0xFF;
            _shortMatch();
          }
        }
      }
      if (_pos - written >= _flushStep) {
        _write(out, written, _pos < end ? _pos : end);
        written = _pos < end ? _pos : end;
      }
    }
    _write(out, written, end);
  }

  void _write(OutStream out, int from, int to) {
    if (to <= from) return;
    final a = from & _winMask;
    final n = to - from;
    if (a + n <= _winSize) {
      out.write(_win, a, n);
    } else {
      final n1 = _winSize - a;
      out.write(_win, a, n1);
      out.write(_win, 0, n - n1);
    }
  }

  // The flag byte: a symbol of the flag list (ranked like the literals).
  void _readFlags() {
    final place = _number(_get16(), _startHf2, _decHf2, _posHf2) & 0xFF;
    final set = _chSetC;
    final ranks = _nToPlC;
    int e;
    int newPlace;
    while (true) {
      e = set[place];
      _flagBuf = e >> 8;
      newPlace = ranks[e & 0xFF]++;
      e++;
      if ((e & 0xFF) != 0) break;
      _rerank(set, ranks);
    }
    set[place] = set[newPlace];
    set[newPlace] = e;
  }

  // A literal (or, in static mode, an escape).
  void _literal() {
    final v = _get16();
    final a = _avrPlc;
    int place;
    if (a > 0x75FF) {
      place = _number(v, _startHf4, _decHf4, _posHf4);
    } else if (a > 0x5DFF) {
      place = _number(v, _startHf3, _decHf3, _posHf3);
    } else if (a > 0x35FF) {
      place = _number(v, _startHf2, _decHf2, _posHf2);
    } else if (a > 0x0DFF) {
      place = _number(v, _startHf1, _decHf1, _posHf1);
    } else {
      place = _number(v, _startHf0, _decHf0, _posHf0);
    }
    place &= 0xFF;
    if (_stMode != 0) {
      if (place == 0 && v > 0xFFF) place = 0x100;
      place--;
      if (place < 0) {
        // the escape of static mode
        final b = _get16();
        _skip(1);
        if ((b & 0x8000) != 0) {
          _numHuf = 0;
          _stMode = 0;
          return;
        }
        final length = (b & 0x4000) != 0 ? 4 : 3;
        _skip(1);
        var dist = _number(_get16(), _startHf2, _decHf2, _posHf2);
        dist = (dist << 5) | (_get16() >> 11);
        _skip(5);
        _copy(dist, length);
        return;
      }
    } else if (_numHuf++ >= 16 && _flagsCnt == 0) {
      _stMode = 1;
    }
    _avrPlc += place;
    _avrPlc -= _avrPlc >> 8;
    _nhfb += 16;
    if (_nhfb > 0xFF) {
      _nhfb = 0x90;
      _nlzb >>= 1;
    }
    final set = _chSet;
    _win[_pos & _winMask] = set[place] >> 8;
    _pos++;
    final ranks = _nToPl;
    int e;
    int newPlace;
    while (true) {
      e = set[place];
      newPlace = ranks[e & 0xFF]++;
      e++;
      if ((e & 0xFF) <= 0xA1) break;
      _rerank(set, ranks);
    }
    set[place] = set[newPlace];
    set[newPlace] = e;
  }

  // A short match: a new distance from the move to front list, a repeat
  // of the last match, one of the four last distances, or a distance of
  // 15 raw bits.
  void _shortMatch() {
    _numHuf = 0;
    var v = _get16();
    if (_lCount == 2) {
      _skip(1);
      if (v >= 0x8000) {
        _copy(_lastDist, _lastLength);
        return;
      }
      v = (v << 1) & 0xFFFF;
      _lCount = 0;
    }
    v >>= 8;
    var code = 0;
    if (_avrLn1 < 37) {
      while (true) {
        final n = code == 1 ? _buf60 + 3 : _shortLen1[code];
        if (((v ^ _shortXor1[code]) & (~(0xFF >> n) & 0xFF)) == 0) {
          _skip(n);
          break;
        }
        code++;
      }
    } else {
      while (true) {
        final n = code == 3 ? _buf60 + 3 : _shortLen2[code];
        if (((v ^ _shortXor2[code]) & (~(0xFF >> n) & 0xFF)) == 0) {
          _skip(n);
          break;
        }
        code++;
      }
    }
    if (code >= 9) {
      if (code == 9) {
        _lCount++;
        _copy(_lastDist, _lastLength);
        return;
      }
      if (code == 14) {
        _lCount = 0;
        final length = _number(_get16(), _startL2, _decL2, _posL2) + 5;
        final dist = (_get16() >> 1) | 0x8000;
        _skip(15);
        _lastLength = length;
        _lastDist = dist;
        _copy(dist, length);
        return;
      }
      // codes 10 to 13: one of the last four distances
      _lCount = 0;
      final dist = _oldDist[(_oldDistPtr - (code - 9)) & 3];
      var length = _number(_get16(), _startL1, _decL1, _posL1) + 2;
      if (length == 0x101 && code == 10) {
        // an escape: switch the lengths of the short codes
        _buf60 ^= 1;
        return;
      }
      if (dist > 256) length++;
      if (dist >= _maxDist3) length++;
      _pushDist(dist);
      _lastLength = length;
      _lastDist = dist;
      _copy(dist, length);
      return;
    }
    // codes 0 to 8: the match length is code + 2
    _lCount = 0;
    _avrLn1 += code;
    _avrLn1 -= _avrLn1 >> 4;
    final place = _number(_get16(), _startHf2, _decHf2, _posHf2) & 0xFF;
    final list = _chSetA;
    var dist = list[place];
    if (place > 0) {
      // move one step to the front
      list[place] = list[place - 1];
      list[place - 1] = dist;
    }
    final length = code + 2;
    dist++;
    _pushDist(dist);
    _lastLength = length;
    _lastDist = dist;
    _copy(dist, length);
  }

  // A long match: the length by a code chosen from its running average,
  // the high distance bits from the ranked list B, seven raw low bits.
  void _longMatch() {
    _numHuf = 0;
    _nlzb += 16;
    if (_nlzb > 0xFF) {
      _nlzb = 0x90;
      _nhfb >>= 1;
    }
    final oldAvr2 = _avrLn2;
    var v = _get16();
    int length;
    if (_avrLn2 >= 122) {
      length = _number(v, _startL2, _decL2, _posL2);
    } else if (_avrLn2 >= 64) {
      length = _number(v, _startL1, _decL1, _posL1);
    } else if (v < 0x100) {
      length = v;
      _skip(16);
    } else {
      length = 0;
      while (((v << length) & 0x8000) == 0) {
        length++;
      }
      _skip(length + 1);
    }
    _avrLn2 += length;
    _avrLn2 -= _avrLn2 >> 5;

    v = _get16();
    int place;
    if (_avrPlcB > 0x28FF) {
      place = _number(v, _startHf2, _decHf2, _posHf2);
    } else if (_avrPlcB > 0x6FF) {
      place = _number(v, _startHf1, _decHf1, _posHf1);
    } else {
      place = _number(v, _startHf0, _decHf0, _posHf0);
    }
    _avrPlcB += place;
    _avrPlcB -= _avrPlcB >> 8;
    place &= 0xFF;
    final set = _chSetB;
    final ranks = _nToPlB;
    int e;
    int newPlace;
    while (true) {
      e = set[place];
      newPlace = ranks[e & 0xFF]++;
      e++;
      if ((e & 0xFF) != 0) break;
      _rerank(set, ranks);
    }
    set[place] = set[newPlace];
    set[newPlace] = e;

    final dist = ((e & 0xFF00) | (_get16() >> 8)) >> 1;
    _skip(7);

    final oldAvr3 = _avrLn3;
    if (length != 1 && length != 4) {
      if (length == 0 && dist <= _maxDist3) {
        _avrLn3++;
        _avrLn3 -= _avrLn3 >> 8;
      } else if (_avrLn3 > 0) {
        _avrLn3--;
      }
    }
    length += 3;
    if (dist >= _maxDist3) length++;
    if (dist <= 256) length += 8;
    if (oldAvr3 > 0xB0 || (_avrPlc >= 0x2A00 && oldAvr2 < 0x40)) {
      _maxDist3 = 0x7F00;
    } else {
      _maxDist3 = 0x2001;
    }
    _pushDist(dist);
    _lastLength = length;
    _lastDist = dist;
    _copy(dist, length);
  }

  @pragma('vm:prefer-inline')
  void _pushDist(int dist) {
    _oldDist[_oldDistPtr] = dist;
    _oldDistPtr = (_oldDistPtr + 1) & 3;
  }

  // Copies [length] bytes from [dist] back; a distance of zero, or one
  // beyond 64 KiB or before the start of the data, gives zeros.
  void _copy(int dist, int length) {
    final w = _win;
    var p = _pos;
    if (dist == 0 || dist > 0x10000 || dist > p) {
      for (var i = 0; i < length; i++) {
        w[p & _winMask] = 0;
        p++;
      }
    } else {
      for (var i = 0; i < length; i++) {
        w[p & _winMask] = w[(p - dist) & _winMask];
        p++;
      }
    }
    _pos = p;
  }
}
