// zcm: x86 and x64 code model (level 4 and up, on exe blocks).
//
// A port of the ExeModel of paq8px (Marcio Pais, after the earlier paq
// exe models and DisFilter by Fabian Giesen): it parses the input as x86
// and x64 instructions (prefixes, opcode tables, ModRM, SIB, immediates
// and displacements), keeps the last instructions quantised into 32 bits,
// and uses the parser state, the instruction fields and sparse contexts
// at the positions relevant to parsing as contexts, plus six mixer weight
// set selectors. The opcode tables are copied from paq8px ExeModel.hpp.
// Hashes are zcm's 32-bit ones (paq8px uses 64-bit hashes).

import 'dart:typed_data';

import 'zcm_components.dart';
import 'zcm_models.dart';
import 'zcm_tables.dart';

// Instruction formats.
const int _fAM = 1, _fMR = 2, _fMEXTRA = 3, _fMODE = 3;
const int _fBI = 4, _fWI = 8, _fDI = 12, _fTYPE = 12;
const int _fAD = 0, _fDA = 4, _fBR = 8, _fDR = 12;
const int _fERR = 15;

// Parser states.
const int _sStart = 0, _sPrefOpSize = 1, _sPrefMultiByteOp = 2;
const int _sParseFlags = 3, _sExtraFlags = 4, _sReadModRM = 5;
const int _sReadOp3_38 = 6, _sReadOp3_3A = 7, _sReadSIB = 8;
const int _sRead8 = 9, _sRead16 = 10, _sRead32 = 11, _sRead8ModRm = 12;
const int _sRead16F = 13, _sRead32ModRm = 14, _sError = 15;

const int _opGenBranch = 12;

const int _codeShift = 3;
const int _codeMask = 0xFF << _codeShift;
const int _clearCodeMask = 0xFFFFFFFF ^ _codeMask;
const int _prefixMask = (1 << _codeShift) - 1;
const int _operandSizeOverride = 0x01 << (8 + _codeShift);
const int _multiByteOpcode = 0x02 << (8 + _codeShift);
const int _prefixRex = 0x04 << (8 + _codeShift);
const int _prefix38 = 0x08 << (8 + _codeShift);
const int _prefix3A = 0x10 << (8 + _codeShift);
const int _hasExtraFlags = 0x20 << (8 + _codeShift);
const int _hasModRm = 0x40 << (8 + _codeShift);
const int _modRMShift = 7 + 8 + _codeShift;
const int _sibScaleShift = _modRMShift + 8 - 6;
const int _regDWordDisplacement = 1 << (8 + _sibScaleShift);
const int _addressMode = 2 << (8 + _sibScaleShift);
const int _typeShift = 2 + 8 + _sibScaleShift;
const int _categoryShift = 5;
const int _categoryMask = (1 << _categoryShift) - 1;
const int _modRMmod = 0xC0, _modRMreg = 0x38, _modRMrm = 0x07;
const int _sibScale = 0xC0, _sibBase = 0x07;
const int _rexW = 0x08;
const int _nCM1 = 10;

// Bit 0: invalid in x64, bit 1: a valid x64 prefix.
final Uint8List _x64Flags = () {
  final t = Uint8List(256);
  for (final op in const [
    0x06, 0x07, 0x16, 0x17, 0x1E, 0x1F, 0x27, 0x2F, 0x37, 0x3F, 0x60, //
    0x61, 0x62, 0x82, 0x9A, 0xD4, 0xD5, 0xD6, 0xEA
  ]) {
    t[op] |= 1;
  }
  for (final p in const [0x26, 0x2E, 0x36, 0x3E, 0x9B, 0xF0, 0xF2, 0xF3]) {
    t[p] |= 2;
  }
  for (var p = 0x40; p <= 0x4F; p++) {
    t[p] |= 2;
  }
  for (var p = 0x64; p <= 0x67; p++) {
    t[p] |= 2;
  }
  return t;
}();

/// The paq8px x86/x64 model.
final class X86Model implements ZcmModel, ZcmMixerContexts {
  final ContextMap _cm;
  final Uint8List _im = Uint8List(1 << 20); // IndirectMap states
  final StateMap _imSm = StateMap(256, bitHistory: true);
  int _imIdx = 0;
  final ZcmRandom _rnd = ZcmRandom();
  final Uint32List _cache = Uint32List(32);
  int _cacheIndex = 0;
  final Uint32List _stateBh = Uint32List(256);
  int _pState = _sStart, _state = _sStart;
  int _opMask = 0, _opCategoryMask = 0, _context = 0;
  int _brkCtx = 0;
  // The instruction being parsed.
  int _data = 0, _prefix = 0, _code = 0, _modRM = 0, _sib = 0, _rex = 0;
  int _flags = 0, _bytesRead = 0, _category = 0;
  bool _mustCheckRex = false, _decoding = false, _o16 = false, _imm8 = false;

  /// [full]: byte history inputs and all six mixer selectors (paq8px);
  /// otherwise lighter (no byte history, the three small selectors).
  final bool full;

  X86Model(int bytes, {this.full = true})
      : _cm = ContextMap(bytes, 20, bh: full, rich: full);

  @override
  int get inputs => _cm.nCtx * _cm.inputsPerContext + 2;

  @override
  List<int> get mixerContextSizes =>
      full ? const [1024, 1024, 1024, 8192, 8192, 8192] : const [1024, 1024, 1024];

  void _clearOp() {
    _data = _prefix = _code = _modRM = _sib = _rex = 0;
    _flags = _bytesRead = _category = 0;
    _mustCheckRex = _decoding = _o16 = _imm8 = false;
  }

  static bool _isInvalidX64Op(int op) => (_x64Flags[op] & 1) != 0;

  static bool _isValidX64Prefix(int p) => (_x64Flags[p] & 2) != 0;

  int _opN(int n) => _cache[(_cacheIndex - n) & 31];

  // processMode
  void _processMode() {
    if ((_flags & _fMODE) == _fAM) {
      _data |= _addressMode;
      _bytesRead = 0;
      switch (_flags & _fTYPE) {
        case _fDR:
          _data |= 2 << _typeShift;
          _data |= 1 << _typeShift;
          _state = _sRead32;
        case _fDA:
          _data |= 1 << _typeShift;
          _state = _sRead32;
        case _fAD:
          _state = _sRead32;
        case _fBR:
          _data |= 2 << _typeShift;
          _state = _sRead8;
      }
    } else {
      switch (_flags & _fTYPE) {
        case _fBI:
          _state = _sRead8;
        case _fWI:
          _state = _sRead16;
          _data |= 1 << _typeShift;
          _bytesRead = 0;
        case _fDI:
          _imm8 = (_rex & _rexW) > 0 && (_code & 0xF8) == 0xB8;
          if (!_o16 || _imm8) {
            _state = _sRead32;
            _data |= 2 << _typeShift;
          } else {
            _state = _sRead16;
            _data |= 3 << _typeShift;
          }
          _bytesRead = 0;
        default:
          _state = _sStart;
      }
    }
    _data &= 0xFFFFFFFF;
  }

  // processFlags2
  void _processFlags2() {
    if ((_flags & _fMODE) == _fMR && _state != _sExtraFlags) {
      _state = _sReadModRM;
      return;
    }
    _processMode();
  }

  // processFlags
  void _processFlags() {
    if (_code == 0x9A || _code == 0xEA || _code == 0xC8) {
      _bytesRead = 0;
      _state = _sRead16F;
      return;
    }
    _processFlags2();
  }

  // checkFlags
  void _checkFlags() {
    if (_flags == _fMEXTRA) {
      _state = _sExtraFlags;
    } else if (_flags == _fERR) {
      _clearOp();
      _state = _sError;
    } else {
      _processFlags();
    }
  }

  void _readFlags() {
    _flags = _kTable1[_code];
    _category = _kTypeOp1[_code];
    _checkFlags();
  }

  void _processModRm() {
    if ((_modRM & _modRMmod) == 0x40) {
      _state = _sRead8ModRm;
    } else if ((_modRM & _modRMmod) == 0x80 ||
        (_modRM & (_modRMmod | _modRMrm)) == 0x05 ||
        (_modRM < 0x40 && (_sib & _sibBase) == 0x05)) {
      _state = _sRead32ModRm;
      _bytesRead = 0;
    } else {
      _processMode();
    }
  }

  void _applyCodeAndSetFlag([int flag = 0]) {
    _data &= _clearCodeMask;
    _data = (_data | (_code << _codeShift) | flag) & 0xFFFFFFFF;
  }

  static int _pref(ZcmState s, int i) {
    if (i > s.pos) return 0;
    final b = s.back(i);
    return (b == 0x0F ? 1 : 0) + 2 * (b == 0x66 ? 1 : 0) + 3 * (b == 0x67 ? 1 : 0);
  }

  static int _byte(ZcmState s, int k) => k <= s.pos ? s.back(k) : 0;

  // exeCxt
  static int _exeCxt(ZcmState s, int i, int x) {
    var prefix = 0, opcode = 0, modRm = 0, sib = 0;
    if (i != 0) prefix += 4 * _pref(s, i--);
    if (i != 0) prefix += _pref(s, i--);
    if (i != 0) opcode += _byte(s, i--);
    if (i != 0) modRm += _byte(s, i--) & (_modRMmod | _modRMrm);
    if (i != 0 && (modRm & _modRMrm) == 4 && modRm < _modRMmod) {
      sib = _byte(s, i) & _sibScale;
    }
    return (prefix | opcode << 4 | modRm << 12 | x << 20 | sib << (28 - 6)) &
        0xFFFFFFFF;
  }

  // ExeModel::update (once per byte)
  void _update(ZcmState s) {
    final c1 = s.c4 & 255;
    _pState = _state;
    switch (_state) {
      case _sStart:
      case _sError:
        var skip = false;
        if (_mustCheckRex) {
          _mustCheckRex = false;
          if (!_isInvalidX64Op(c1) && !_isValidX64Prefix(c1)) {
            _rex = _code;
            _code = c1;
            _data = _prefixRex | (_code << _codeShift) | (_data & _prefixMask);
            skip = true;
          }
        }
        _modRM = _sib = _rex = _flags = _bytesRead = 0;
        var done = false;
        if (!skip) {
          _code = c1;
          _mustCheckRex = (_code & 0xF0) == 0x40 &&
              !(_decoding && (_data & _prefixMask) == 1);
          final cd = _code;
          _prefix = ((cd == 0x26 || cd == 0x2E || cd == 0x36 || cd == 0x3E) ? 1 : 0) +
              (cd == 0x64 ? 2 : 0) +
              (cd == 0x65 ? 3 : 0) +
              (cd == 0x67 ? 4 : 0) +
              (cd == 0x9B ? 5 : 0) +
              (cd == 0xF0 ? 6 : 0) +
              ((cd == 0xF2 || cd == 0xF3) ? 7 : 0);
          if (!_decoding) {
            _opMask = ((_opMask << 1) | (_state != _sError ? 1 : 0)) & 0xFFFFFFFF;
            _opCategoryMask =
                ((_opCategoryMask << _categoryShift) | _category) & 0xFFFFFFFF;
            _cache[_cacheIndex & 31] = _data;
            _cacheIndex++;
            if (_prefix == 0) {
              _data = _code << _codeShift;
            } else {
              _data = _prefix;
              _category = _kTypeOp1[_code];
              _decoding = true;
              _brkCtx = hash3(0, _prefix, _opCategoryMask & _categoryMask);
              done = true;
            }
          } else {
            if (_prefix == 0) {
              _data |= _code << _codeShift;
              _decoding = false;
            } else {
              _data = _prefix;
              _category = _kTypeOp1[_code];
              _brkCtx = hash3(1, _prefix, _opCategoryMask & _categoryMask);
              done = true;
            }
          }
        }
        if (done) break;
        _o16 = _code == 0x66;
        if (_o16) {
          _state = _sPrefOpSize;
        } else if (_code == 0x0F) {
          _state = _sPrefMultiByteOp;
        } else {
          _readFlags();
        }
        _brkCtx = hash4(hash2(2, _state), _code, _opCategoryMask & _categoryMask,
            _opN(1) & ((_modRMmod | _modRMreg | _modRMrm) << _modRMShift));
      case _sPrefOpSize:
        _code = c1;
        _applyCodeAndSetFlag(_operandSizeOverride);
        _readFlags();
        _brkCtx = hash2(3, _state);
      case _sPrefMultiByteOp:
        _code = c1;
        _data |= _multiByteOpcode;
        if (_code == 0x38) {
          _state = _sReadOp3_38;
        } else if (_code == 0x3A) {
          _state = _sReadOp3_3A;
        } else {
          _applyCodeAndSetFlag();
          _flags = _kTable2[_code];
          _category = _kTypeOp2[_code];
          _checkFlags();
        }
        _brkCtx = hash2(4, _state);
      case _sParseFlags:
        _processFlags();
        _brkCtx = hash2(5, _state);
      case _sExtraFlags:
      case _sReadModRM:
        _modRM = c1;
        _data = (_data | (_modRM << _modRMShift) | _hasModRm) & 0xFFFFFFFF;
        _sib = 0;
        if (_flags == _fMEXTRA) {
          _data |= _hasExtraFlags;
          final i = ((_modRM >> 3) & 0x07) | ((_code & 0x01) << 3) | ((_code & 0x08) << 1);
          _flags = _kTableX[i];
          _category = _kTypeOpX[i];
          if (_flags == _fERR) {
            _clearOp();
            _state = _sError;
            _brkCtx = hash2(6, _state);
            break;
          }
          _processFlags();
          _brkCtx = hash2(7, _state);
          break;
        }
        if ((_modRM & _modRMrm) == 4 && _modRM < _modRMmod) {
          _state = _sReadSIB;
          _brkCtx = hash2(8, _state);
          break;
        }
        _processModRm();
        _brkCtx = hash3(9, _state, _code);
      case _sReadOp3_38:
      case _sReadOp3_3A:
        _code = c1;
        _applyCodeAndSetFlag(_prefix38 << (_state - _sReadOp3_38));
        if (_state == _sReadOp3_38) {
          _flags = _kTable338[_code];
          _category = _kTypeOp338[_code];
        } else {
          _flags = _kTable33A[_code];
          _category = _kTypeOp33A[_code];
        }
        _checkFlags();
        _brkCtx = hash2(10, _state);
      case _sReadSIB:
        _sib = c1;
        _data = (_data | ((_sib & _sibScale) << _sibScaleShift)) & 0xFFFFFFFF;
        _processModRm();
        _brkCtx = hash3(11, _state, _sib & _sibScale);
      case _sRead8:
      case _sRead16:
      case _sRead32:
        if (++_bytesRead >= ((_state - _sRead8) << ((_imm8 ? 1 : 0) + 1))) {
          _bytesRead = 0;
          _imm8 = false;
          _state = _sStart;
        }
        final br = _bytesRead;
        _brkCtx = hash4(hash2(12, _state), _flags & _fMODE, br,
            ((br > 1 && br <= s.pos) ? (s.back(br) << 8) : 0) | (br != 0 ? c1 : 0));
      case _sRead8ModRm:
        _processMode();
        _brkCtx = hash2(13, _state);
      case _sRead16F:
        if (++_bytesRead == 2) {
          _bytesRead = 0;
          _processFlags2();
        }
        _brkCtx = hash2(14, _state);
      case _sRead32ModRm:
        _data = (_data | _regDWordDisplacement) & 0xFFFFFFFF;
        if (++_bytesRead == 4) {
          _bytesRead = 0;
          _processMode();
        }
        _brkCtx = hash2(15, _state);
    }
    _context = (_state + 16 * _bytesRead + 16 * (_rex & _rexW)) & 255;
    _stateBh[_context] = ((_stateBh[_context] << 8) | c1) & 0xFFFFFFFF;

    // Contexts (the exe block is forced, as in paq8px for EXE blocks).
    var mask = 0, count0 = 0, i = 0;
    while (i < _nCM1) {
      if (i > 1) {
        mask = mask * 2 + ((i - 1 <= s.pos && s.back(i - 1) == 0) ? 1 : 0);
        count0 += mask & 1;
      }
      final j = i < 4 ? i + 1 : 5 + (i - 4) * (2 + (i > 6 ? 1 : 0));
      _cm.set(
          i,
          hash4(
              i,
              _exeCxt(s, j, j > 6 ? c1 : 0),
              ((1 << _nCM1) | mask) * (count0 * _nCM1 ~/ 2 >= i ? 1 : 0),
              (0x08 | (s.pos & 7)) * (i < 4 ? 1 : 0)));
      i++;
    }
    _cm.set(i, _brkCtx);
    final st = _state + 16 * _bytesRead;
    mask = _prefixMask | (0xF8 << _codeShift) | _multiByteOpcode | _prefix38 | _prefix3A;
    _cm.set(++i, hash4(hash2(i, _opN(1) & (mask | _regDWordDisplacement | _addressMode)),
        st, _data & mask, _rex << 8 | _category));
    mask = 0x04 | (0xFE << _codeShift) | _multiByteOpcode | _prefix38 | _prefix3A |
        ((_modRMmod | _modRMreg) << _modRMShift);
    _cm.set(++i, hash4(hash3(i, _opN(1) & mask, _opN(2) & mask), _opN(3) & mask,
        _context + 256 * ((_modRM & _modRMmod) == _modRMmod ? 1 : 0),
        _data & ((mask | _prefixRex) ^ (_modRMmod << _modRMShift))));
    mask = 0x04 | _codeMask;
    _cm.set(++i, hash4(hash3(i, _opN(1) & mask, _opN(2) & mask), _opN(3) & mask,
        _opN(4) & mask, (_data & mask) | (_state << 11) | (_bytesRead << 15)));
    mask = 0x04 | (0xFC << _codeShift) | _multiByteOpcode | _prefix38 | _prefix3A;
    _cm.set(++i, hash4(hash3(i, st, _data & mask), _category * 8 + (_opMask & 0x07),
        _flags,
        ((_sib & _sibBase) == 5 ? 4 : 0) +
            ((_modRM & _modRMreg) == _modRMreg ? 2 : 0) +
            ((_modRM & _modRMmod) == 0 ? 1 : 0)));
    mask = _prefixMask | _codeMask | _operandSizeOverride | _multiByteOpcode |
        _prefixRex | _prefix38 | _prefix3A | _hasExtraFlags | _hasModRm |
        ((_modRMmod | _modRMrm) << _modRMShift);
    _cm.set(++i, hash4(i, _data & mask, st, _flags));
    mask = _prefixMask | _codeMask | _operandSizeOverride | _multiByteOpcode |
        _prefix38 | _prefix3A | _hasExtraFlags | _hasModRm;
    _cm.set(++i, hash4(hash2(i, _opN(1) & mask), _state,
        _bytesRead * 2 + ((_rex & _rexW) > 0 ? 1 : 0),
        _data & ((mask ^ _operandSizeOverride) & 0xFFFF)));
    mask = 0x04 | (0xFE << _codeShift) | _multiByteOpcode | _prefix38 | _prefix3A |
        (_modRMreg << _modRMShift);
    _cm.set(++i, hash4(hash2(i, _opN(1) & mask), _opN(2) & mask, st,
        _data & (mask | _prefixMask | _codeMask)));
    _cm.set(++i, hash2(i, st));
    _cm.set(++i, hash4(i, (0x100 | c1) * (_bytesRead > 0 ? 1 : 0),
        _state + 16 * _pState + 256 * _bytesRead,
        ((_flags & _fMODE) == _fAM ? 16 : 0) +
            (_rex & _rexW) +
            (_o16 ? 4 : 0) +
            ((_code & 0xFE) == 0xE8 ? 2 : 0) +
            (((_data & _multiByteOpcode) != 0 && (_code & 0xF0) == 0x80) ? 1 : 0)));
  }

  @override
  void mix(ZcmState s, Mixer m) {
    final y = s.y;
    // IndirectMap update of the last bit.
    _im[_imIdx] = nextState(_im[_imIdx], y, _rnd);
    if (s.bpos == 0) _update(s);
    _cm.mix(m, y, s.bpos, s.c0, s.c4 & 255);
    // IndirectMap: a bit history per (break context, bit position).
    _imIdx = hash2(_brkCtx, s.bpos) & ((1 << 20) - 1);
    final state = _im[_imIdx];
    final tx = m.tx;
    final k = m.nx;
    final p1 = _imSm.p(y, state);
    if (state == 0) {
      tx[k] = 0;
      tx[k + 1] = 0;
    } else {
      tx[k] = kStretch[p1] >> 1;
      tx[k + 1] = (p1 - 2048) >> 2;
    }
    m.nx = k + 2;
  }

  @override
  void setMixerContexts(ZcmState s, Mixer m) {
    final bpos = s.bpos;
    final c0 = s.c0;
    final bh = _stateBh[_context];
    final sb = ((bh >> (28 - bpos)) & 0x08) |
        ((bh >> (21 - bpos)) & 0x04) |
        ((bh >> (14 - bpos)) & 0x02) |
        ((bh >> (7 - bpos)) & 0x01) |
        (_category == _opGenBranch ? 16 : 0) |
        ((c0 & ((1 << bpos) - 1)) == 0 ? 32 : 0);
    m.set((_context * 4 + (sb >> 4)) & 1023);
    m.set((_state * 64 + bpos * 8 + (_bytesRead > 0 ? 4 : 0) + (sb >> 4)) & 1023);
    m.set((_brkCtx & 0x1FF) | ((sb & 0x20) << 4));
    if (!full) return;
    m.set(hash3(_code, _state, _opN(1) & _codeMask) & 8191);
    m.set(hash4(_state, bpos, _code, _bytesRead) & 8191);
    m.set(hash4(_state, (bpos << 2) | (c0 & 3), _opCategoryMask & _categoryMask,
            (_category == _opGenBranch ? 4 : 0) |
                ((_flags & _fMODE) == _fAM ? 2 : 0) |
                (_bytesRead > 0 ? 1 : 0)) &
        8191);
  }
}

final Uint8List _kTable1 = Uint8List.fromList(const [
  2, 2, 2, 2, 4, 12, 0, 0, 2, 2, 2, 2, 4, 12, 0, 0,
  2, 2, 2, 2, 4, 12, 0, 0, 2, 2, 2, 2, 4, 12, 0, 0,
  2, 2, 2, 2, 4, 12, 0, 0, 2, 2, 2, 2, 4, 12, 0, 0,
  2, 2, 2, 2, 4, 12, 0, 0, 2, 2, 2, 2, 4, 12, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 2, 2, 0, 0, 0, 0, 12, 14, 4, 6, 0, 0, 0, 0,
  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
  6, 14, 6, 6, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 5, 0, 0, 0, 0, 0,
  1, 1, 1, 1, 0, 0, 0, 0, 4, 12, 0, 0, 0, 0, 0, 0,
  4, 4, 4, 4, 4, 4, 4, 4, 12, 12, 12, 12, 12, 12, 12, 12,
  6, 6, 8, 0, 2, 2, 6, 14, 4, 0, 8, 0, 0, 4, 15, 0,
  2, 2, 2, 2, 4, 4, 0, 0, 2, 2, 2, 2, 2, 2, 2, 2,
  9, 9, 9, 9, 4, 4, 4, 4, 13, 13, 1, 9, 0, 0, 0, 0,
  0, 15, 0, 0, 0, 0, 3, 3, 0, 0, 0, 0, 0, 0, 3, 3,
]);

final Uint8List _kTable2 = Uint8List.fromList(const [
  15, 15, 15, 15, 15, 15, 0, 15, 0, 0, 15, 15, 15, 15, 15, 15,
  2, 2, 2, 2, 2, 2, 2, 2, 2, 15, 15, 15, 15, 15, 15, 15,
  2, 2, 2, 2, 15, 15, 15, 15, 2, 2, 2, 2, 2, 2, 2, 2,
  0, 0, 0, 0, 0, 0, 15, 0, 15, 15, 15, 15, 15, 15, 15, 15,
  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
  6, 6, 6, 6, 2, 2, 2, 0, 15, 15, 15, 15, 15, 15, 2, 2,
  13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13,
  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
  0, 0, 0, 2, 6, 2, 2, 2, 15, 15, 15, 2, 6, 2, 15, 2,
  2, 2, 2, 2, 2, 2, 2, 2, 15, 15, 15, 2, 2, 2, 2, 2,
  2, 2, 2, 2, 2, 2, 2, 2, 0, 0, 0, 0, 0, 0, 0, 0,
  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 15,
]);

final Uint8List _kTable338 = Uint8List.fromList(const [
  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 15, 15, 15, 15,
  2, 15, 15, 15, 2, 2, 15, 2, 15, 15, 15, 15, 2, 2, 2, 15,
  2, 2, 2, 2, 2, 2, 15, 15, 2, 2, 2, 2, 15, 15, 15, 15,
  2, 2, 2, 2, 2, 2, 15, 2, 2, 2, 2, 2, 2, 2, 2, 2,
  2, 2, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
  15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
  15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
  15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
  2, 2, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
  15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
  15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
  15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
  15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
  15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
  15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
  2, 2, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
]);

final Uint8List _kTable33A = Uint8List.fromList(const [
  15, 15, 15, 15, 15, 15, 15, 15, 6, 6, 6, 6, 6, 6, 6, 6,
  15, 15, 15, 15, 6, 6, 6, 6, 15, 15, 15, 15, 15, 15, 15, 15,
  6, 6, 6, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
  15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
  6, 6, 6, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
  15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
  6, 6, 6, 6, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
  15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
  15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
  15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
  15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
  15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
  15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
  15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
  15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
  15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
]);

final Uint8List _kTableX = Uint8List.fromList(const [
  6, 15, 2, 2, 2, 2, 2, 2, 14, 15, 2, 2, 2, 2, 2, 2,
  2, 2, 15, 15, 15, 15, 15, 15, 2, 2, 2, 15, 2, 15, 2, 15,
]);

final Uint8List _kTypeOp1 = Uint8List.fromList(const [
  8, 8, 8, 8, 8, 8, 5, 5, 9, 9, 9, 9, 9, 9, 5, 2,
  8, 8, 8, 8, 8, 8, 5, 5, 8, 8, 8, 8, 8, 8, 5, 5,
  9, 9, 9, 9, 9, 9, 1, 7, 8, 8, 8, 8, 8, 8, 1, 7,
  9, 9, 9, 9, 9, 9, 1, 7, 8, 8, 8, 8, 8, 8, 1, 7,
  8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
  5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
  5, 5, 14, 6, 1, 1, 2, 2, 5, 8, 5, 8, 16, 16, 16, 16,
  13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13,
  8, 8, 8, 8, 8, 8, 4, 4, 4, 4, 4, 4, 4, 4, 4, 5,
  4, 4, 4, 4, 4, 4, 4, 4, 6, 6, 12, 3, 5, 5, 4, 4,
  4, 4, 4, 4, 15, 15, 15, 15, 9, 9, 15, 15, 15, 15, 15, 15,
  4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
  10, 10, 12, 12, 4, 4, 4, 4, 5, 5, 12, 12, 14, 14, 14, 14,
  10, 10, 10, 10, 7, 7, 4, 4, 22, 21, 22, 21, 22, 21, 22, 21,
  13, 13, 13, 13, 16, 16, 16, 16, 12, 12, 12, 12, 16, 16, 16, 16,
  2, 14, 2, 2, 20, 17, 8, 8, 17, 17, 17, 17, 17, 17, 8, 12,
]);

final Uint8List _kTypeOp2 = Uint8List.fromList(const [
  20, 20, 20, 20, 0, 20, 20, 20, 20, 20, 0, 19, 0, 19, 0, 0,
  31, 31, 31, 31, 30, 30, 31, 31, 30, 19, 19, 19, 19, 19, 19, 19,
  20, 20, 20, 20, 20, 0, 20, 0, 31, 31, 30, 30, 30, 30, 30, 30,
  20, 20, 20, 20, 20, 20, 0, 0, 2, 0, 2, 0, 0, 0, 0, 0,
  4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
  31, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30,
  29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 0, 0, 29, 29,
  30, 29, 29, 29, 29, 29, 29, 29, 0, 0, 0, 0, 0, 0, 29, 29,
  13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13,
  4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
  5, 5, 19, 11, 10, 10, 0, 0, 5, 5, 20, 11, 10, 10, 28, 8,
  4, 4, 4, 11, 4, 4, 6, 6, 0, 19, 11, 11, 11, 11, 6, 6,
  4, 4, 30, 30, 30, 30, 30, 4, 4, 4, 4, 4, 4, 4, 4, 4,
  0, 29, 29, 29, 30, 29, 0, 30, 29, 29, 30, 29, 29, 29, 30, 29,
  30, 29, 30, 29, 30, 29, 0, 30, 29, 29, 30, 29, 29, 29, 30, 29,
  0, 29, 29, 29, 30, 29, 30, 30, 29, 29, 29, 30, 29, 29, 29, 0,
]);

final Uint8List _kTypeOp338 = Uint8List.fromList(const [
  30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 0, 0, 0, 0,
  30, 0, 0, 0, 30, 30, 0, 30, 0, 0, 0, 0, 30, 30, 30, 0,
  30, 30, 30, 30, 30, 30, 0, 0, 30, 30, 30, 30, 0, 0, 0, 0,
  30, 30, 30, 30, 30, 30, 0, 30, 30, 30, 30, 30, 30, 30, 30, 30,
  30, 30, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  4, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
]);

final Uint8List _kTypeOp33A = Uint8List.fromList(const [
  0, 0, 0, 0, 0, 0, 0, 0, 30, 30, 30, 30, 30, 30, 30, 30,
  0, 0, 0, 0, 30, 30, 30, 30, 0, 0, 0, 0, 0, 0, 0, 0,
  30, 30, 30, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  30, 30, 30, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  30, 30, 30, 30, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
]);

final Uint8List _kTypeOpX = Uint8List.fromList(const [
  9, 9, 9, 8, 8, 8, 8, 8, 9, 9, 9, 8, 8, 8, 8, 8,
  8, 8, 0, 0, 0, 0, 0, 0, 8, 8, 12, 12, 12, 12, 5, 0,
]);
