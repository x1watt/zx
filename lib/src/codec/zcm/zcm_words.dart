// zcm: the word and line model of paq8px (level 7 and up), and paq8px's
// chart, nest and XML models.
//
// A port of paq8px's WordModel and WordModelInfo (Zoltan Gotthardt and
// the paq8px authors, after the word models of paq8 by Matt Mahoney):
// words, numbers and the gaps between them as tokens, expressions of
// words separated by single spaces, the recent words in many combinations,
// word morphology (the last letters by class), character classes, the
// token before the current one (an indirect context), and the line model:
// the column, the bytes above in the previous lines, how well the current
// line matches the previous one, and the first character and word of the
// line or paragraph. The PDF text extraction of paq8px is left out.
// Hashes are zcm's 32-bit ones (paq8px uses 64-bit hashes).

import 'dart:typed_data';

import 'zcm_components.dart';
import 'zcm_models.dart';
import 'zcm_tables.dart';

const int _space = 0x20, _newLine = 0x0A, _quote = 0x22, _apostrophe = 0x27;

/// paq8px llog: log2 * 16 of a 32-bit value.
int zcmLlog(int x) {
  if (x >= 0x1000000) return 256 + kIlog[(x >> 16) & 0xFFFF];
  if (x >= 0x10000) return 128 + kIlog[(x >> 8) & 0xFFFF];
  return kIlog[x & 0xFFFF];
}

// C isalpha, ispunct and isspace in the C locale.
bool _isAlpha(int c) => (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);
bool _isPunct(int c) =>
    (c >= 0x21 && c <= 0x2F) ||
    (c >= 0x3A && c <= 0x40) ||
    (c >= 0x5B && c <= 0x60) ||
    (c >= 0x7B && c <= 0x7E);
bool _isSpace(int c) => c == 0x20 || (c >= 0x09 && c <= 0x0D);

@pragma('vm:prefer-inline')
int _combine(int seed, int x) => hash2(seed + 0x3C6EF372, x);

/// Token histories by context hash (paq8px LargeIndirectContext with 16
/// bit values: 2 bytes of history per token, a 16 bit checksum).
final class _LargeIndirect {
  final Uint32List _t;
  final int _mask;
  _LargeIndirect(int bits)
      : _t = Uint32List(1 << bits),
        _mask = (1 << bits) - 1;

  void set(int h, int c) {
    final i = h & _mask;
    final chk = (h >> 16) & 0xFFFF;
    final e = _t[i];
    final v = (e >> 16) == chk ? e & 0xFFFF : 0;
    _t[i] = chk << 16 | ((v << 8 | c) & 0xFFFF);
  }

  int get(int h) {
    final e = _t[h & _mask];
    return (e >> 16) == ((h >> 16) & 0xFFFF) ? e & 0xFFFF : 0;
  }
}

/// paq8px WordModel: 21 line contexts and 46 word contexts (33 on
/// binary data), with run and byte history inputs.
final class PxWordModel implements ZcmModel, ZcmMixerContexts {
  static const int nCM1 = 21;
  static const int nCM2 = 46;
  static const int _maxWordLen = 45;
  static const int _maxLineMatch = 16;
  static const int _maxLastUpper = 63;
  static const int _maxLastLetter = 16;
  static const int _wPosBits = 16;

  final ContextMap _cm;
  final _LargeIndirect _iCtx = _LargeIndirect(20);
  final Uint32List _wordPositions = Uint32List(1 << _wPosBits);
  final Uint16List _checksums = Uint16List(1 << _wPosBits);

  int _c4 = 0, _c = 0, _pC = 0, _ppC = 0;
  bool _isNewline = false, _isNewlinePc = false;
  bool _isLetter = false, _isLetterPc = false, _isLetterPpC = false;
  int _opened = 0, _wordLen0 = 0, _wordLen1 = 0, _exprLen0 = 0;
  int _line0 = 0, _line1 = 0, _firstWord = 0;
  int _word0 = 0, _word1 = 0, _word2 = 0, _word3 = 0, _word4 = 0;
  int _expr0 = 0, _expr1 = 0, _expr2 = 0, _expr3 = 0, _expr4 = 0;
  int _keyword0 = 0, _gapToken0 = 0, _gapToken1 = 0, _currentToken = 0;
  int _w = 0, _chk = 0;
  int _firstChar = -1, _lineMatch = -1;
  int _nl1 = 0, _nl2 = 0, _nl3 = 0, _nl4 = 0;
  int _groups = 0; // 8 last character classes (64 bits)
  int _text0 = 0;
  int _lastLetter = _maxLastLetter, _lastUpper = _maxLastUpper;
  int _wordGap = _maxLastLetter;
  int _mask = 0, _expr0Chars = 0, _mask2 = 0, _f4 = 0;
  int _order = 0;

  PxWordModel(int bytes)
      : _cm = ContextMap(bytes, nCM1 + nCM2, rich: false, bh: true);

  @override
  int get inputs => _cm.nCtx * _cm.inputsPerContext;

  @override
  List<int> get mixerContextSizes => const [16 * 8];

  /// Contexts of the word model with statistics (0 to 31).
  int get order => _order;

  void _shiftWords() {
    _word4 = _word3;
    _word3 = _word2;
    _word2 = _word1;
    _word1 = _word0;
    _wordLen1 = _wordLen0;
  }

  void _killWords() {
    _word4 = _word3 = _word2 = _word1 = 0;
    _gapToken1 = 0;
  }

  // WordModelInfo::processChar
  void _processChar(ZcmState s, bool isText, bool isExtendedChar) {
    _ppC = _pC;
    _pC = _c;
    _isLetterPpC = _isLetterPc;
    _isLetterPc = _isLetter;
    final c1 = s.c4 & 255;
    _c4 = ((_c4 << 8) | c1) & 0xFFFFFFFF;
    _c = c1;
    if (_c >= 0x41 && _c <= 0x5A) {
      _c += 0x20;
      _lastUpper = 0;
    }
    final c = _c;
    final pC = _pC;
    _isLetter = (c >= 0x61 && c <= 0x7A) || isExtendedChar;
    final isNumber =
        (c >= 0x30 && c <= 0x39) || (pC >= 0x30 && pC <= 0x39 && c == 0x2E);
    _isNewlinePc = _isNewline;
    _isNewline = isText ? (c == _newLine || c == 0) : c == 0;
    _lastUpper =
        _lastUpper + 1 < _maxLastUpper ? _lastUpper + 1 : _maxLastUpper;
    _lastLetter =
        _lastLetter + 1 < _maxLastLetter ? _lastLetter + 1 : _maxLastLetter;
    _mask2 = (_mask2 << 8) & 0xFFFFFFFF;
    if (isText) _iCtx.set(_currentToken, c);

    if (_isLetter || isNumber) {
      if (_wordLen0 == 0) {
        // The beginning of a new word.
        if (pC == _newLine && _lastLetter == 3 && _ppC == 0x2B) {
          _word0 = _word1;
          _word1 = _word2;
          _word2 = _word3;
          _word3 = _word4 = 0;
          _wordLen0 = _wordLen1;
        } else {
          _wordGap = _lastLetter;
          _gapToken1 = _gapToken0;
          if (pC == _quote || (pC == _apostrophe && !_isLetterPpC)) {
            _opened = pC;
          }
        }
        _gapToken0 = 0;
        _mask2 = 0;
      }
      _lastLetter = 0;
      _word0 = _combine(_word0, c);
      _currentToken = _word0;
      _w = _word0 & ((1 << _wPosBits) - 1);
      _chk = (_word0 >> 16) & 0xFFFF;
      _text0 = ((_text0 << 8) | c) & 0xFFFFFFFFFF;
      _wordLen0 = _wordLen0 + 1 < _maxWordLen ? _wordLen0 + 1 : _maxWordLen;
      if (_isLetter) {
        if (c == 0x65) {
          _mask2 |= c;
        } else if (c == 0x61 || c == 0x69 || c == 0x6F || c == 0x75) {
          _mask2 |= 0x61;
        } else if (c >= 0x62 && c <= 0x7A) {
          if (c == 0x79) {
            _mask2 |= 0x79;
          } else if (pC == 0x74 && c == 0x68) {
            _mask2 = ((_mask2 >> 8) & 0x00FFFF00) | 0x74;
          } else {
            _mask2 |= 0x62;
          }
        } else {
          _mask2 |= 128;
        }
      } else if (c == 0x2E) {
        _mask2 |= 0x2E;
      } else {
        _mask2 |= c == 0x30 ? 0x30 : 0x31;
      }
    } else {
      _gapToken0 = _combine(_gapToken0, _isNewline ? _space : c1);
      _currentToken = _gapToken0;
      if (_isNewline && pC == 0x2B && _isLetterPpC) {
      } else if (c == 0x3F || pC == 0x21 || pC == 0x2E) {
        _killWords();
      } else if (c == pC) {
      } else if ((c == _space || _isNewline) &&
          (pC == _space || _isNewlinePc)) {
      } else {
        _shiftWords();
      }
      if (_wordLen0 != 0) {
        _wordPositions[_w] = s.pos;
        _checksums[_w] = _chk;
        _w = 0;
        _chk = 0;
        if (c == 0x3A || c == 0x3D) _keyword0 = _word0;
        if (_firstWord == 0) _firstWord = _word0;
        _word0 = 0;
        _wordLen0 = 0;
        _mask2 = 0;
      }
      if (c1 == 0x2E || c1 == 0x21 || c1 == 0x3F) {
        _mask2 |= 0x21;
      } else if (c1 == 0x2C || c1 == 0x3B || c1 == 0x3A) {
        _mask2 |= 0x2C;
      } else if (c1 == 0x28 || c1 == 0x7B || c1 == 0x5B || c1 == 0x3C) {
        _mask2 |= 0x28;
        _opened = c1;
      } else if (c1 == 0x29 || c1 == 0x7D || c1 == 0x5D || c1 == 0x3E) {
        _mask2 |= 0x29;
        _opened = 0;
      } else if (c1 == _quote || c1 == _apostrophe) {
        _mask2 |= c1;
        _opened = 0;
      } else {
        _mask2 |= c1;
      }
    }

    var g = c1;
    if (g >= 128) {
      if ((g & 0xF8) == 0xF0) {
        g = 1;
      } else if ((g & 0xF0) == 0xE0) {
        g = 2;
      } else if ((g & 0xE0) == 0xC0) {
        g = 3;
      } else if ((g & 0xC0) == 0x80) {
        g = 4;
      } else if (g == 0xFF) {
        g = 5;
      } else {
        g = c1 & 0xF0;
      }
    } else if (g >= 0x30 && g <= 0x39) {
      g = 0x30;
    } else if (g >= 0x61 && g <= 0x7A) {
      g = 0x61;
    } else if (g >= 0x41 && g <= 0x5A) {
      g = 0x41;
    } else if (g < 32 && !_isNewline) {
      g = 6;
    }
    _groups = (_groups << 8) | g;

    // Expressions (pure words separated by single spaces).
    if (_isLetter) {
      _expr0Chars = ((_expr0Chars << 8) | c) & 0xFFFFFFFF;
      _expr0 = _combine(_expr0, c);
      _exprLen0 = _exprLen0 + 1 < _maxWordLen ? _exprLen0 + 1 : _maxWordLen;
    } else {
      _expr0Chars = 0;
      _exprLen0 = 0;
      if ((c == _space || _isNewline) &&
          (_isLetterPc || pC == _apostrophe || pC == _quote)) {
        _expr4 = _expr3;
        _expr3 = _expr2;
        _expr2 = _expr1;
        _expr1 = _expr0;
        _expr0 = 0;
      } else if (c == _apostrophe ||
          c == _quote ||
          (_isNewline && pC == _space) ||
          (c == _space && _isNewlinePc)) {
        // ignore
      } else {
        _expr4 = _expr3 = _expr2 = _expr1 = _expr0 = 0;
      }
    }
  }

  // WordModelInfo::lineModelPredict
  void _lineModel(ZcmState s, bool isText, int k) {
    final cm = _cm;
    var i = 1024 * (1 + ((isText ? 1 : 0) << 1 | 1));
    final pos = s.pos;
    if (_isNewline) {
      _nl4 = _nl3;
      _nl3 = _nl2;
      _nl2 = _nl1;
      _nl1 = pos;
      _firstChar = -1;
      _firstWord = 0;
      _line1 = _line0;
      _line0 = 0;
    }
    final c1 = s.c4 & 255;
    _line0 = _combine(_line0, c1);
    cm.set(k++, hash2(++i, _line0));
    final col = pos - _nl1;
    if (col == 1) _firstChar = _groups & 0xFF;
    final buf = s.buf;
    final bm = s.bufMask;
    final cAbove = buf[(_nl2 + col) & bm];
    final pCAbove = buf[(_nl2 + col - 1) & bm];
    final isNewLineStart = col == 0 && _nl2 > 0;
    final isPrevCharMatchAbove = c1 == pCAbove && col != 0 && _nl2 != 0;
    final aboveCtx = cAbove << 1 | (isPrevCharMatchAbove ? 1 : 0);
    if (isNewLineStart) {
      _lineMatch = 0;
    } else if (_lineMatch >= 0 && isPrevCharMatchAbove) {
      _lineMatch =
          _lineMatch + 1 < _maxLineMatch ? _lineMatch + 1 : _maxLineMatch;
    } else {
      _lineMatch = -1;
    }
    if (_lineMatch >= 0) {
      cm.set(k++, hash3(++i, cAbove, _lineMatch));
    } else {
      cm.skip(k++);
      i++;
    }
    final lineLength = _nl1 - _nl2;
    if (col < lineLength) {
      cm.set(k++, hash2(++i, aboveCtx << 8 | c1));
      cm.set(k++, hash3(++i, aboveCtx << 8 | c1, col));
    } else {
      cm.skip(k++);
      cm.skip(k++);
      i += 2;
    }
    cm.set(k++, hash4(++i, lineLength, col, aboveCtx << 8 | (_groups & 0xFF)));
    cm.set(k++, hash4(++i, lineLength, col, aboveCtx << 8 | c1));
    final cAbove2 = buf[(_nl3 + col) & bm];
    final cAbove3 = buf[(_nl4 + col) & bm];
    final lineLength2 = _nl2 - _nl3;
    final lineLength3 = _nl3 - _nl4;
    final gBefore = _groups & 0xFFFF;
    if (cAbove == cAbove2 && lineLength == lineLength2) {
      cm.set(k++, hash3(++i, gBefore, cAbove));
    } else {
      cm.skip(k++);
      i++;
    }
    if (col < lineLength && col < lineLength2 && col < lineLength3) {
      cm.set(k++, hash4(++i, gBefore, cAbove, cAbove2 << 8 | cAbove3));
    } else {
      cm.skip(k++);
      i++;
    }
    if (lineLength > 1) {
      final cx = isText ? _groups & 0xFF : c1;
      cm.set(k++, hash3(++i, _line1, col << 8 | cx));
      cm.set(k++, hash3(++i, _line1, _line0));
    } else {
      cm.skip(k++);
      cm.skip(k++);
      i += 2;
    }
    cm.set(k++, hash2(++i, col << 1 | (c1 == _space ? 1 : 0)));
    cm.set(k++, hash2(++i, col << 8 | c1));
    cm.set(k++, hash3(++i, col, _mask & 0x1FF));
    cm.set(k++, hash3(++i, col, lineLength));
    cm.set(
        k++,
        hash3(++i, col << 8 | (_firstChar & 0xFFFF),
            (_lastUpper < col ? 1 : 0) << 8 | (_groups & 0xFF)));
    cm.set(k++, hash2(++i, _nl1));
    cm.set(k++, hash3(++i, _nl1, _c));
    cm.set(k++, hash2(++i, _firstChar & 0xFFFF));
    cm.set(k++, hash3(++i, _firstChar & 0xFFFF, _c));
    cm.set(k++, hash2(++i, _firstWord));
    cm.set(k, hash3(++i, _firstWord, _c));
  }

  // WordModelInfo::predict
  void _predict(ZcmState s, bool isText) {
    final cm = _cm;
    final pos = s.pos;
    final lastPos = _checksums[_w] != _chk ? 0 : _wordPositions[_w];
    var dist = 0;
    if (lastPos != 0) {
      dist = zcmLlog(pos - lastPos + 120) >> 4;
      if (dist > 20) dist = 20;
    }
    final word0MayEndNow = lastPos != 0;
    final b1 = (_c4 >> 8) & 0xFF, b0 = _c4 & 0xFF;
    final mayBeCaps = b1 >= 0x41 && b1 <= 0x5A && b0 >= 0x41 && b0 <= 0x5A;
    var k = 0;
    var i = 0;
    cm.set(k++, hash3(++i, _text0 & 0xFFFFFFFF, _text0 >> 32));
    if (isText) {
      cm.set(k++, hash4(++i, _expr0, _expr1, hash3(_expr2, _expr3, _expr4)));
      cm.set(k++, hash4(++i, _expr0, _expr1, _expr2));
    } else {
      cm.skip(k++);
      cm.skip(k++);
      i += 2;
    }
    cm.set(k++, hash3(++i, _gapToken0, _keyword0));
    cm.set(k++, hash4(++i, _word0, _c, _keyword0));
    cm.set(k++, hash3(++i, _word0, dist));
    cm.set(k++, hash4(++i, _word1, _gapToken0, dist));
    cm.set(k++, hash3(++i, pos >> 10, _word0));
    final wmeMbc = (word0MayEndNow ? 2 : 0) | (mayBeCaps ? 1 : 0);
    final wl = _wordLen0 < 6 ? _wordLen0 : 6;
    final wlWmeMbc = wl << 2 | wmeMbc;
    cm.set(k++, hash3(++i, wlWmeMbc, _mask2));
    for (var n = 1; n <= 4; n++) {
      if (_exprLen0 >= n) {
        final el = _exprLen0 < n + 3 ? _exprLen0 : n + 3;
        final ch = n == 4 ? _expr0Chars : _expr0Chars & ((1 << (8 * n)) - 1);
        cm.set(k++, hash3(++i, el << 2 | wmeMbc, n == 1 ? _c : ch));
      } else {
        cm.skip(k++);
        i++;
      }
    }
    cm.set(k++, hash3(++i, _word0, 0));
    cm.set(k++, hash3(++i, _word0, _gapToken0));
    cm.set(k++, hash4(++i, _c, _word0, _gapToken1));
    cm.set(k++, hash4(++i, _c, _gapToken0, _word1));
    cm.set(k++, hash3(++i, _word0, _word1));
    cm.set(k++, hash4(++i, _word0, _word1, _word2));
    cm.set(k++, hash4(++i, _gapToken0, _word1, hash2(_gapToken1, _word2)));
    cm.set(k++, hash4(++i, _word0, _word1, hash2(_gapToken1, _word2)));
    cm.set(k++, hash4(++i, _word0, _word1, _gapToken1));
    final c1 = _c4 & 0xFF;
    if (isText) {
      cm.set(k++, hash4(++i, _word0, c1, _word2));
      cm.set(k++, hash4(++i, _word0, c1, _word3));
      cm.set(k++, hash4(++i, _word0, c1, _word4));
      cm.set(k++, hash4(++i, _word0, c1, hash2(_word1, _word4)));
      cm.set(k++, hash4(++i, _word0, c1, hash2(_word1, _word3)));
      cm.set(k++, hash4(++i, _word0, c1, hash2(_word2, _word3)));
    } else {
      for (var n = 0; n < 6; n++) {
        cm.skip(k++);
      }
      i += 6;
    }
    final g = _groups & 0xFF;
    cm.set(k++, hash4(++i, _opened, wlWmeMbc, g));
    cm.set(k++, hash4(++i, _opened, _c, dist != 0 ? 1 : 0));
    cm.set(k++, hash3(++i, _opened, _word0));
    final gl = _groups & 0xFFFFFFFF, gh = (_groups >> 32) & 0xFFFFFFFF;
    cm.set(k++, hash3(++i, gl, gh));
    cm.set(k++, hash4(++i, gl, gh, _c));
    cm.set(k++, hash4(++i, gl, gh, _c4 & 0xFFFF));
    _f4 = ((_f4 << 4) | (c1 == 0x20 ? 0 : c1 >> 4)) & 0xFFFFFFFF;
    cm.set(k++, hash2(++i, _f4 & 0x0FFF));
    cm.set(k++, hash2(++i, _f4));
    var fl = 0;
    if (c1 != 0) {
      if (_isAlpha(c1)) {
        fl = 1;
      } else if (_isPunct(c1)) {
        fl = 2;
      } else if (_isSpace(c1)) {
        fl = 3;
      } else if (c1 == 0xFF) {
        fl = 4;
      } else if (c1 < 16) {
        fl = 5;
      } else if (c1 < 64) {
        fl = 6;
      } else {
        fl = 7;
      }
    }
    _mask = ((_mask << 3) | fl) & 0xFFFFFFFF;
    cm.set(k++, hash2(++i, _mask));
    cm.set(k++, hash3(++i, _mask, c1));
    cm.set(k++, hash3(++i, _mask, _c4 & 0x00FFFF00));
    cm.set(k++, hash3(++i, _mask & 0x1FF, _f4 & 0x00FFF0));
    if (isText) {
      cm.set(
          k++,
          hash4(
              ++i,
              hash2(_word0, c1),
              zcmLlog(_wordGap),
              (_mask & 0x1FF) << 3 |
                  (_wordLen1 > 3 ? 4 : 0) |
                  (_lastUpper < _lastLetter + _wordLen1 ? 2 : 0) |
                  (_lastUpper < _wordLen0 + _wordLen1 + _wordGap ? 1 : 0)));
      final htoken = _iCtx.get(_currentToken);
      cm.set(k++, hash2(++i, wlWmeMbc << 16 | htoken));
      cm.set(k++, hash3(++i, wlWmeMbc << 8 | (htoken & 0xFF), _c));
      cm.set(k++, hash3(++i, wlWmeMbc << 8 | (htoken & 0xFF), _c4 & 0xFFFF));
      cm.set(k++, hash4(++i, htoken & 0xFF, gl, gh));
      cm.set(k++, hash3(++i, htoken, gl));
    } else {
      for (var n = 0; n < 6; n++) {
        cm.skip(k++);
      }
      i += 6;
    }
    assert(k == nCM2);
  }

  @override
  void mix(ZcmState s, Mixer m) {
    if (s.bpos == 0) {
      final isText = s.blockType == ZcmBlockType.text;
      final c1 = s.c4 & 255;
      _processChar(s, isText, isText && c1 >= 128);
      _predict(s, isText);
      _lineModel(s, isText, nCM2);
    }
    _cm.mix(m, s.y, s.bpos, s.c0, s.c4 & 255);
    var o = _cm.hits - (nCM1 + nCM2 - 31);
    if (o < 0) o = 0;
    _order = o;
  }

  @override
  void setMixerContexts(ZcmState s, Mixer m) {
    m.set((_order >> 1) << 3 | s.bpos);
  }
}

/// paq8px ChartModel (from paq8kx7, with enhancements by Zoltan
/// Gotthardt): the second to last byte picks a slot of a chart of recent
/// contexts (3 selected bits of the last 3 bytes, or character classes in
/// text), plus sparse indirect contexts.
final class ChartModel implements ZcmModel {
  static const int _nCm = 87;
  final ContextMap _cm;
  final Uint32List _chart = Uint32List(24);
  int _charGroup = 0;
  final Uint8List _ind1 = Uint8List(1024 + 64);
  final Uint8List _ind2 = Uint8List(256);
  final Uint8List _ind3 = Uint8List(65536);

  ChartModel(int bytes) : _cm = ContextMap(bytes, _nCm, rich: false);

  @override
  int get inputs => _cm.nCtx * _cm.inputsPerContext;

  void _byte(ZcmState s) {
    final c4 = s.c4;
    final c1 = c4 & 0xFF;
    final w0 = c4 & 0x00FFFFFF;
    var w4 = (w0 << 8) & 0xFFFFFFFF;
    final w2 = w4 & 0x0000FF00;
    var w3 = 0;
    final isText = s.blockType == ZcmBlockType.text;
    if (!isText) {
      w3 = w4 & 0x00FF0000;
      w4 = w4 & 0xFF000000;
    }
    int a0;
    if (isText) {
      var g = c1;
      if (g >= 0x61 && g <= 0x7A) {
        g = 0;
      } else if (g >= 0x41 && g <= 0x5A) {
        g = 1;
      } else if (g >= 0x30 && g <= 0x39) {
        g = 2;
      } else if (g == 0 || g == 0x20) {
        g = 3;
      } else if (g <= 31) {
        g = 4;
      } else if (g <= 63) {
        g = 5;
      } else if (g <= 127) {
        g = 6;
      } else {
        g = 7;
      }
      _charGroup = ((_charGroup << 8) | g) & 0xFFFFFFFF;
      a0 = _charGroup;
    } else {
      a0 = (c4 >> 5) & 0x00070707;
    }
    final cm = _cm;
    var h = 0;
    var k = 0;
    if (!isText) {
      final b0 = (c4 >> 23) & 0x1C0 | (c4 >> 18) & 0x38 | (c4 >> 13) & 0x07;
      final b1 = (c4 >> 20) & 0x1C0 | (c4 >> 15) & 0x38 | (c4 >> 10) & 0x07;
      final b2 = (c4 >> 18) & 0x30 | (c4 >> 12) & 0x0C | (c4 >> 8) & 3;
      final d0 = (c4 >> 15) & 0x1C0 | (c4 >> 10) & 0x38 | (c4 >> 5) & 0x07;
      final d1 = (c4 >> 12) & 0x1C0 | (c4 >> 7) & 0x38 | (c4 >> 2) & 0x07;
      final d2 = (c4 >> 10) & 0x30 | (c4 >> 4) & 0x0C | c4 & 3;
      for (var i = 0; i < 3; i++) {
        final b = i == 0 ? b0 : (i == 1 ? b1 : b2);
        final d = i == 0 ? d0 : (i == 1 ? d1 : d2);
        final g = _ind1[i << 9 | d];
        _ind1[i << 9 | b] = c1;
        cm.set(k++, hash2(++h, g));
        cm.set(k++, hash2(++h, w2 | g));
        cm.set(k++, hash2(++h, w3 | g));
        cm.set(k++, hash2(++h, w4 | g));
      }
    } else {
      h += 12;
    }
    final buf2 = (c4 >> 8) & 0xFF;
    final buf3 = (c4 >> 16) & 0xFF;
    var g = _ind2[c1];
    _ind2[buf2] = c1;
    cm.set(k++, hash2(++h, w4 | g));
    g = _ind3[buf2 << 8 | c1];
    _ind3[buf3 << 8 | buf2] = c1;
    cm.set(k++, hash2(++h, w4 | g));
    if (!isText) {
      cm.set(k++, hash2(++h, w3 | g));
    } else {
      h++;
    }
    final cnt = isText ? 1 : 3;
    for (var i = 0; i < cnt; i++) {
      final e =
          i == 0 ? a0 : (i == 1 ? (c4 >> 2) & 0x00070707 : c4 & 0x00070707);
      _chart[i << 3 | ((e >> 8) & 7)] = w0;
    }
    for (var i = 0; i < cnt * 8; i++) {
      final sel = i >> 3;
      final e =
          sel == 0 ? a0 : (sel == 1 ? (c4 >> 2) & 0x00070707 : c4 & 0x00070707);
      final kk = _chart[i];
      cm.set(k++, hash2(++h, kk));
      cm.set(k++, hash3(++h, e, kk & 0xFFFF));
      cm.set(k++, hash2(++h, (e & 7) << 8 | (kk & 0xFF00FF)));
    }
    while (k < _nCm) {
      cm.skip(k++);
    }
  }

  @override
  void mix(ZcmState s, Mixer m) {
    if (s.bpos == 0) _byte(s);
    _cm.mix(m, s.y, s.bpos, s.c0, s.c4 & 255);
  }
}

/// paq8px NestModel: nesting of brackets, quotes and markup, and the
/// vowel and consonant pattern of the text.
final class NestModel implements ZcmModel {
  final ContextMap _cm;
  int _ic = 0, _bc = 0, _pc = 0, _vc = 0, _qc = 0, _lvc = 0, _wc = 0;
  int _ac = 0, _ec = 0, _uc = 0, _sense1 = 0, _sense2 = 0, _w = 0;

  NestModel(int bytes) : _cm = ContextMap(bytes, 12, rich: false);

  @override
  int get inputs => _cm.nCtx * _cm.inputsPerContext;

  void _byte(ZcmState s) {
    final c4 = s.c4;
    final c = c4 & 0xFF;
    var matched = 1;
    var vv = 0;
    if (!((_vc & 7) > 0 && (_vc & 7) < 3)) _w = 0;
    if ((c & 0x80) != 0) _w = (_w * 11 * 32 + c) & 0xFFFFFFFF;
    final lc = c >= 0x41 && c <= 0x5A ? c + 32 : c;
    if (lc == 0x61 || lc == 0x65 || lc == 0x69 || lc == 0x6F || lc == 0x75) {
      vv = 1;
      _w = (_w * 997 * 8 + (lc ~/ 4 - 22)) & 0xFFFFFFFF;
    } else if (lc >= 0x61 && lc <= 0x7A) {
      vv = 2;
      _w = (_w * 271 * 32 + lc - 97) & 0xFFFFFFFF;
    } else if (lc == 0x20 || lc == 0x2E || lc == 0x2C || lc == 0x0A) {
      vv = 3;
    } else if (lc >= 0x30 && lc <= 0x39) {
      vv = 4;
    } else if (lc == 0x79) {
      vv = 5;
    } else if (lc == 0x27) {
      vv = 6;
    } else {
      vv = (c & 32) != 0 ? 7 : 0;
    }
    _vc = ((_vc << 3) | vv) & 0xFFFFFFFF;
    if (vv != _lvc) {
      _wc = ((_wc << 3) | vv) & 0xFFFFFFFF;
      _lvc = vv;
    }
    switch (c) {
      case 0x20:
        _qc = 0;
      case 0x28:
        _ic += 31;
      case 0x29:
        _ic -= 31;
      case 0x5B:
        _ic += 11;
      case 0x5D:
        _ic -= 11;
      case 0x3C:
        _ic += 23;
        _qc += 34;
      case 0x3E:
        _ic -= 23;
        _qc = _qc ~/ 5;
      case 0x3A:
        _pc = 20;
      case 0x7B:
        _ic += 17;
      case 0x7D:
        _ic -= 17;
      case 0x7C:
        _pc += 223;
      case 0x22:
        _pc += 0x40;
      case 0x27:
        _pc += 0x42;
        if (c != ((c4 >> 8) & 0xFF)) {
          _sense2 ^= 1;
        } else {
          _ac += 2 * _sense2 - 1;
        }
      case 0x0A:
        _pc = _qc = 0;
      case 0x2E:
      case 0x21:
      case 0x3F:
        _pc = 0;
      case 0x23:
        _pc += 0x08;
      case 0x25:
        _pc += 0x76;
      case 0x24:
        _pc += 0x45;
      case 0x2A:
        _pc += 0x35;
      case 0x2D:
        _pc += 0x3;
      case 0x40:
        _pc += 0x72;
      case 0x26:
        _qc += 0x12;
      case 0x3B:
        _qc = _qc ~/ 3;
      case 0x5C:
        _pc += 0x29;
      case 0x2F:
        _pc += 0x11;
        if (c == 0x3C) _qc += 74;
      case 0x3D:
        _pc += 87;
        if (c != ((c4 >> 8) & 0xFF)) {
          _sense1 ^= 1;
        } else {
          _ec += 2 * _sense1 - 1;
        }
      default:
        matched = 0;
    }
    if (c4 == 0x266C743B) {
      _uc = _uc + 1 < 7 ? _uc + 1 : 7;
    } else if (c4 == 0x2667743B) {
      if (_uc > 0) _uc--;
    }
    if (matched != 0) {
      _bc = 0;
    } else {
      _bc++;
    }
    if (_bc > 300) _bc = _ic = _pc = _qc = _uc = 0;
    _ic &= 0xFFFFFFFF;
    _pc &= 0xFFFFFFFF;
    _qc &= 0xFFFFFFFF;
    final cm = _cm;
    var i = 0;
    var lb = 0;
    while ((1 << (lb + 1)) <= _bc + 1) {
      lb++;
    }
    cm.set(
        i,
        hash4(++i, (vv > 0 && vv < 3) ? 0 : (lc | 0x100), _ic & 0x3FF,
            (_ec & 7) << 8 | (_ac & 7) << 4 | _uc));
    cm.set(i, hash4(++i, _ic, _w, lb));
    cm.set(i, hash2(++i, (3 * _vc + 77 * _pc + 373 * _ic + _qc) & 0xFFFF));
    cm.set(i, hash2(++i, (31 * _vc + 27 * _pc + 281 * _qc) & 0xFFFF));
    cm.set(i, hash2(++i, (13 * _vc + 271 * _ic + _qc + _bc) & 0xFFFF));
    cm.set(i, hash2(++i, (17 * _pc + 7 * _ic) & 0xFFFF));
    cm.set(i, hash2(++i, (13 * _vc + _ic) & 0xFFFF));
    cm.set(i, hash2(++i, (_vc ~/ 3 + _pc) & 0xFFFF));
    cm.set(i, hash2(++i, (7 * _wc + _qc) & 0xFFFF));
    cm.set(i, hash3(++i, _vc & 0xFFFF, c));
    cm.set(i, hash3(++i, (3 * _pc) & 0xFFFF, c));
    cm.set(i, hash3(++i, _ic & 0xFFFF, c));
  }

  @override
  void mix(ZcmState s, Mixer m) {
    if (s.bpos == 0) _byte(s);
    _cm.mix(m, s.y, s.bpos, s.c0, s.c4 & 255);
  }
}

final class _XmlAttr {
  int name = 0, value = 0, length = 0;
  void clear() => name = value = length = 0;
}

final class _XmlTag {
  int name = 0, length = 0, level = 0;
  bool endTag = false, empty = false;
  int cData = 0, cLength = 0, cType = 0; // content
  final List<_XmlAttr> attrs = List.generate(4, (_) => _XmlAttr());
  int attrIndex = 0;

  void clear() {
    name = length = level = 0;
    endTag = empty = false;
    cData = cLength = cType = 0;
    for (final a in attrs) {
      a.clear();
    }
    attrIndex = 0;
  }
}

/// paq8px XMLModel (Marcio Pais): the state of a small XML/HTML parser (tag names,
/// nesting level, attributes, content types such as dates, numbers and
/// URLs) and the indentation as contexts.
final class XmlModel implements ZcmModel {
  static const int _cache = 32;
  // Parser states.
  static const int _none = 0, _tagName = 1, _tag = 2, _attrName = 3;
  static const int _attrValue = 4, _content = 5, _cdata = 6, _comment = 7;
  // Content flags.
  static const int _text = 0x001, _number = 0x002, _date = 0x004;
  static const int _time = 0x008, _url = 0x010, _link = 0x020;
  static const int _coords = 0x040, _temp = 0x080, _isbn = 0x100;

  final ContextMap _cm;
  final List<_XmlTag> _tags = List.generate(_cache, (_) => _XmlTag());
  int _index = 0;
  int _state = _none, _pState = _none;
  int _wsRun = 0, _pWsRun = 0, _indentTab = 0, _indentStep = 2;
  int _lineEnding = 2;

  XmlModel(int bytes) : _cm = ContextMap(bytes, 4, rich: false);

  @override
  int get inputs => _cm.nCtx * _cm.inputsPerContext;

  _XmlTag _at(int i) => _tags[i & (_cache - 1)];

  static bool _digit(int c) => c >= 0x30 && c <= 0x39;

  void _detect(ZcmState s, _XmlTag t) {
    final c4 = s.c4, c8 = s.c8;
    int b(int i) => s.back(i);
    if ((c4 & 0xF0F0F0F0) == 0x30303030) {
      var i = 0;
      while (i < 4 && _digit((c4 >> (8 * i)) & 0xFF)) {
        i++;
      }
      if (i == 4 &&
          (((c8 & 0xFDF0F0FD) == 0x2D30302D && _digit(b(9))) ||
              (c8 & 0xF0FDF0FD) == 0x302D302D)) {
        t.cType |= _date;
      }
    } else if (((c8 & 0xF0F0FDF0) == 0x30302D30 ||
            (c8 & 0xF0F0F0FD) == 0x3030302D) &&
        _digit(b(9))) {
      var i = 2;
      while (i < 4 && _digit((c8 >> (8 * i)) & 0xFF)) {
        i++;
      }
      if (i == 4 && (c4 & 0xF0FDF0F0) == 0x302D3030) t.cType |= _date;
    }
    if ((c4 & 0xF0FFF0F0) == 0x303A3030 &&
        _digit(b(5)) &&
        (!_digit(b(6)) || ((c8 & 0xF0F0FF00) == 0x30303A00 && !_digit(b(9))))) {
      t.cType |= _time;
    }
    if (t.cLength >= 8 && (c8 & 0x80808080) == 0 && (c4 & 0x80808080) == 0) {
      t.cType |= _text;
    }
    if ((c8 & 0xF0F0FF) == 0x3030C2 && (c4 & 0xFFF0F0FF) == 0xB0303027) {
      var i = 2;
      while (i < 7 && _digit(b(i))) {
        i += (i & 1) * 2 + 1;
      }
      if (i == 10) t.cType |= _coords;
    }
    if ((c4 & 0xFFFFFA) == 0xC2B042 &&
        (c4 & 0xFF) != 0x47 &&
        (_digit(c4 >> 24) || ((c4 >> 24) == 0x20 && _digit(b(5))))) {
      t.cType |= _temp;
    }
    if (_digit(c4 & 0xFF)) t.cType |= _number;
    if (c4 == 0x4953424E && (c8 & 0xFF) == 0x20) t.cType |= _isbn;
  }

  void _byte(ZcmState s) {
    var pTag = _at(_index - 1);
    final tag = _at(_index);
    final attr = tag.attrs[tag.attrIndex & 3];
    _pState = _state;
    final c4 = s.c4, c8 = s.c8;
    final c1 = c4 & 0xFF;
    if ((c1 == 9 || c1 == 32) && (c1 == ((c4 >> 8) & 0xFF) || _wsRun == 0)) {
      _wsRun++;
      _indentTab = c1 == 9 ? 1 : 0;
    } else {
      if ((_state == _none ||
              (_state == _content && tag.cLength <= _lineEnding + _wsRun)) &&
          _wsRun > 1 + _indentTab &&
          _wsRun != _pWsRun) {
        _indentStep = (_wsRun - _pWsRun).abs();
        _pWsRun = _wsRun;
      }
      _wsRun = 0;
    }
    if (c1 == 10) _lineEnding = 1 + (((c4 >> 8) & 0xFF) == 13 ? 1 : 0);
    final cm = _cm;
    switch (_state) {
      case _none:
        if (c1 == 0x3C) {
          _state = _tagName;
          tag.clear();
          tag.level = (pTag.endTag || pTag.empty) ? pTag.level : pTag.level + 1;
        }
        if (tag.level > 1) _detect(s, tag);
        cm.set(
            0,
            hash3(_pState, _state,
                ((pTag.level + 1) * _indentStep - _wsRun) & 0xFFFFFFFF));
      case _tagName:
        if (tag.length > 0 && (c1 == 9 || c1 == 10 || c1 == 13 || c1 == 32)) {
          _state = _tag;
        } else if ((c1 == 0x3A ||
                (c1 >= 0x41 && c1 <= 0x5A) ||
                c1 == 0x5F ||
                (c1 >= 0x61 && c1 <= 0x7A)) ||
            (tag.length > 0 && (c1 == 0x2D || c1 == 0x2E || _digit(c1)))) {
          tag.length++;
          tag.name = (tag.name * 263 * 32 + (c1 & 0xDF)) & 0xFFFFFFFF;
        } else if (c1 == 0x3E) {
          if (tag.endTag) {
            _state = _none;
            _index++;
          } else {
            _state = _content;
          }
        } else if (c1 != 0x21 && c1 != 0x2D && c1 != 0x2F && c1 != 0x5B) {
          _state = _none;
          _index++;
        } else if (tag.length == 0) {
          if (c1 == 0x2F) {
            tag.endTag = true;
            tag.level = tag.level > 0 ? tag.level - 1 : 0;
          } else if (c4 == 0x3C212D2D) {
            _state = _comment;
            tag.level = tag.level > 0 ? tag.level - 1 : 0;
          }
        }
        if (tag.length == 1 && (c4 & 0xFFFF00) == 0x3C2100) {
          tag.clear();
          _state = _none;
        } else if (tag.length == 5 && c8 == 0x215B4344 && c4 == 0x4154415B) {
          _state = _cdata;
          tag.level = tag.level > 0 ? tag.level - 1 : 0;
        }
        var i = 1;
        do {
          pTag = _at(_index - i);
          i += 1 +
              ((pTag.endTag && _at(_index - i - 1).name == pTag.name) ? 1 : 0);
        } while (i < _cache && (pTag.endTag || pTag.empty));
        cm.set(
            0,
            hash4(_pState << 4 | _state, tag.name, tag.level,
                hash2(pTag.name, pTag.level != tag.level ? 1 : 0)));
      case _tag:
        if (c1 == 0x2F) {
          tag.empty = true;
        } else if (c1 == 0x3E) {
          if (tag.empty) {
            _state = _none;
            _index++;
          } else {
            _state = _content;
          }
        } else if (c1 != 9 && c1 != 10 && c1 != 13 && c1 != 32) {
          _state = _attrName;
          attr.name = c1 & 0xDF;
        }
        cm.set(0, hash4(_pState << 4 | _state, tag.name, c1, tag.attrIndex));
      case _attrName:
        if ((c4 & 0xFFF0) == 0x3D20 && (c1 == 0x22 || c1 == 0x27)) {
          _state = _attrValue;
          if ((c8 & 0xDFDF) == 0x4852 && (c4 & 0xDFDF0000) == 0x45460000) {
            tag.cType |= _link;
          }
        } else if (c1 != 0x22 && c1 != 0x27 && c1 != 0x3D) {
          attr.name = (attr.name * 263 * 32 + (c1 & 0xDF)) & 0xFFFFFFFF;
        }
        cm.set(
            0,
            hash4(_pState << 4 | _state, attr.name, tag.attrIndex,
                hash2(tag.name, tag.cType)));
      case _attrValue:
        if (c1 == 0x22 || c1 == 0x27) {
          tag.attrIndex++;
          _state = _tag;
        } else {
          attr.value = (attr.value * 263 * 32 + (c1 & 0xDF)) & 0xFFFFFFFF;
          attr.length++;
          if ((c8 & 0xDFDFDFDF) == 0x48545450 &&
              ((c4 >> 8) == 0x3A2F2F || c4 == 0x733A2F2F)) {
            tag.cType |= _url;
          }
        }
        cm.set(0, hash3(_pState << 4 | _state, attr.name, tag.cType));
      case _content:
        if (c1 == 0x3C) {
          _state = _tagName;
          _index++;
          final nt = _at(_index);
          nt.clear();
          nt.level = tag.level + 1;
        } else {
          tag.cLength++;
          tag.cData = (tag.cData * 997 * 16 + (c1 & 0xDF)) & 0xFFFFFFFF;
          _detect(s, tag);
        }
        cm.set(0, hash3(_pState << 4 | _state, tag.name, c4 & 0xC0FF));
      case _cdata:
        if ((c4 & 0xFFFFFF) == 0x5D5D3E) {
          _state = _none;
          _index++;
        }
        cm.set(0, hash2(_pState, _state));
      case _comment:
        if ((c4 & 0xFFFFFF) == 0x2D2D3E) {
          _state = _none;
          _index++;
        }
        cm.set(0, hash2(_pState, _state));
    }
    pTag = _at(_index - 1);
    final ct = _at(_index);
    var i = 64;
    cm.set(
        1,
        hash4(++i, _state, ct.level,
            hash2(_pState * 2 + (ct.endTag ? 1 : 0), ct.name)));
    cm.set(
        2,
        hash4(++i, pTag.name, _state * 2 + (pTag.endTag ? 1 : 0),
            hash2(pTag.cType, ct.cType)));
    cm.set(
        3,
        hash4(++i, _state * 2 + (ct.endTag ? 1 : 0), ct.name,
            hash2(ct.cType, c4 & 0xE0FF)));
  }

  @override
  void mix(ZcmState s, Mixer m) {
    if (s.bpos == 0) _byte(s);
    _cm.mix(m, s.y, s.bpos, s.c0, s.c4 & 255);
  }
}
