// Branch converters for executables: port of C/Bra.c, C/Bra86.c (BraIA64.c
// is empty, its code moved to Bra.c) and the filter classes of
// CPP/7zip/Compress/BranchMisc.cpp and BcjCoder.cpp.
//
// Every converter takes (data, off, size, pc) and returns the index after the
// last processed byte (the C functions return a pointer). The processed size
// is (result - off). pc is the virtual program counter of data[off].
//
// C pointer arithmetic for the program counter (BR_PC_INIT: pc -= p,
// BR_PC_GET: pc + p) maps to indices: pcBase = pc - off, pc(p) = pcBase + p.

import 'dart:typed_data';

import 'filter_coder.dart';

const int _m32 = 0xFFFFFFFF;

int _getUi32(Uint8List d, int p) =>
    d[p] | (d[p + 1] << 8) | (d[p + 2] << 16) | (d[p + 3] << 24);

void _setUi32(Uint8List d, int p, int v) {
  d[p] = v;
  d[p + 1] = v >> 8;
  d[p + 2] = v >> 16;
  d[p + 3] = v >> 24;
}

int _getBe32(Uint8List d, int p) =>
    (d[p] << 24) | (d[p + 1] << 16) | (d[p + 2] << 8) | d[p + 3];

void _setBe32(Uint8List d, int p, int v) {
  d[p] = v >> 24;
  d[p + 1] = v >> 16;
  d[p + 2] = v >> 8;
  d[p + 3] = v;
}

/// Signature of the RISC converters (z7_Func_BranchConv).
typedef BranchConvFunc = int Function(
    Uint8List data, int off, int size, int pc);

// ---------------------------------------------------------------------------
// ARM64

// z7_BranchConv_ARM64 (Z7_BRANCH_FUNC_MAIN)
int _branchConvArm64(Uint8List d, int p, int size, int pc, bool encoding) {
  const flag = 1 << (24 - 4);
  const mask = (1 << 24) - (flag << 1);
  size &= ~3;
  final lim = p + size;
  pc = pc - p - 4; // BR_PC_INIT, then (p) points to the next instruction
  for (;;) {
    if (p == lim) return p;
    var v = _getUi32(d, p);
    p += 4;
    if (((v - 0x94000000) & 0xfc000000) == 0) {
      final c = ((pc + p) & _m32) >> 2;
      if (encoding) {
        v += c;
      } else {
        v -= c;
      }
      v &= 0x03ffffff;
      v |= 0x94000000;
      _setUi32(d, p - 4, v);
      continue;
    }
    v = (v - 0x90000000) & _m32;
    if ((v & 0x9f000000) == 0) {
      v = (v + flag) & _m32;
      if ((v & mask) != 0) continue;
      var z = (v & 0xffffffe0) | (v >> 26);
      final c = (((pc + p) & _m32) >> (12 - 3)) & ~7;
      if (encoding) {
        z = (z + c) & _m32;
      } else {
        z = (z - c) & _m32;
      }
      v &= 0x1f;
      v |= 0x90000000;
      v |= (z << 26) & _m32;
      v |= 0x00ffffe0 & ((z & ((flag << 1) - 1)) - flag);
      _setUi32(d, p - 4, v);
    }
  }
}

// z7_BranchConv_ARM64_Dec
int z7BranchConvArm64Dec(Uint8List d, int off, int size, int pc) =>
    _branchConvArm64(d, off, size, pc, false);
// z7_BranchConv_ARM64_Enc
int z7BranchConvArm64Enc(Uint8List d, int off, int size, int pc) =>
    _branchConvArm64(d, off, size, pc, true);

// ---------------------------------------------------------------------------
// ARM

// z7_BranchConv_ARM
int _branchConvArm(Uint8List d, int p, int size, int pc, bool encoding) {
  size &= ~3;
  final lim = p + size;
  // Branch offset is relative to the +2 instructions from the current one;
  // (p) will point to the next instruction.
  pc = pc - p + 8 - 4;
  for (;;) {
    if (p >= lim) return p;
    p += 4;
    if (d[p - 1] != 0xeb) continue;
    var v = _getUi32(d, p - 4);
    final c = ((pc + p) & _m32) >> 2;
    if (encoding) {
      v += c;
    } else {
      v -= c;
    }
    v &= 0x00ffffff;
    v |= 0xeb000000;
    _setUi32(d, p - 4, v);
  }
}

// z7_BranchConv_ARM_Dec
int z7BranchConvArmDec(Uint8List d, int off, int size, int pc) =>
    _branchConvArm(d, off, size, pc, false);
// z7_BranchConv_ARM_Enc
int z7BranchConvArmEnc(Uint8List d, int off, int size, int pc) =>
    _branchConvArm(d, off, size, pc, true);

// ---------------------------------------------------------------------------
// PPC

// z7_BranchConv_PPC
int _branchConvPpc(Uint8List d, int p, int size, int pc, bool encoding) {
  size &= ~3;
  final lim = p + size;
  pc = pc - p - 4;
  for (;;) {
    if (p == lim) return p;
    // (v & 0xfc000003) == 0x48000001, tested on the big endian bytes
    final b0 = d[p];
    final b3 = d[p + 3];
    p += 4;
    if ((b0 & 0xfc) != 0x48 || (b3 & 3) != 1) continue;
    var v = _getBe32(d, p - 4);
    final c = (pc + p) & _m32;
    if (encoding) {
      v += c;
    } else {
      v -= c;
    }
    v &= 0x03ffffff;
    v |= 0x48000000;
    _setBe32(d, p - 4, v);
  }
}

// z7_BranchConv_PPC_Dec
int z7BranchConvPpcDec(Uint8List d, int off, int size, int pc) =>
    _branchConvPpc(d, off, size, pc, false);
// z7_BranchConv_PPC_Enc
int z7BranchConvPpcEnc(Uint8List d, int off, int size, int pc) =>
    _branchConvPpc(d, off, size, pc, true);

// ---------------------------------------------------------------------------
// SPARC (the variant without BR_SPARC_USE_ROTATE)

// z7_BranchConv_SPARC
int _branchConvSparc(Uint8List d, int p, int size, int pc, bool encoding) {
  const flag = 1 << 22;
  size &= ~3;
  final lim = p + size;
  pc = pc - p - 4;
  for (;;) {
    if (p == lim) return p;
    var v = _getBe32(d, p);
    p += 4;
    v = (v + (5 << 29)) & _m32;
    v ^= 7 << 29;
    v = (v + flag) & _m32;
    if ((v & (0x100000000 - (flag << 1))) != 0) continue;
    v = (v << 2) & _m32;
    final c = (pc + p) & _m32;
    if (encoding) {
      v += c;
    } else {
      v -= c;
    }
    v &= (flag << 3) - 1;
    v = (v - (flag << 2)) & _m32;
    v >>= 2;
    v |= 1 << 30;
    _setBe32(d, p - 4, v);
  }
}

// z7_BranchConv_SPARC_Dec
int z7BranchConvSparcDec(Uint8List d, int off, int size, int pc) =>
    _branchConvSparc(d, off, size, pc, false);
// z7_BranchConv_SPARC_Enc
int z7BranchConvSparcEnc(Uint8List d, int off, int size, int pc) =>
    _branchConvSparc(d, off, size, pc, true);

// ---------------------------------------------------------------------------
// ARMT (Thumb)

// z7_BranchConv_ARMT
int _branchConvArmt(Uint8List d, int p, int size, int pc, bool encoding) {
  size &= ~1;
  if (size <= 2) return p;
  size -= 2;
  final lim = p + size;
  pc -= p;
  do {
    var b1 = d[p + 1];
    for (;;) {
      if (p >= lim) return p;
      final b3 = d[p + 3];
      p += 2;
      if ((b3 & (b1 ^ 8)) >= 0xf8) break;
      if (p >= lim) return p;
      b1 = d[p + 3];
      p += 2;
      if ((b1 & (b3 ^ 8)) >= 0xf8) break;
    }
    var v = ((d[p - 2] | (d[p - 1] << 8)) << 11) |
        ((d[p] | (d[p + 1] << 8)) & 0x7FF);
    p += 2;
    final c = ((pc + p) & _m32) >> 1;
    if (encoding) {
      v = (v + c) & _m32;
    } else {
      v = (v - c) & _m32;
    }
    final hi = ((v >> 11) & 0x7ff) | 0xf000;
    final lo = v | 0xf800;
    d[p - 4] = hi;
    d[p - 3] = hi >> 8;
    d[p - 2] = lo;
    d[p - 1] = lo >> 8;
  } while (p < lim);
  return p;
}

// z7_BranchConv_ARMT_Dec
int z7BranchConvArmtDec(Uint8List d, int off, int size, int pc) =>
    _branchConvArmt(d, off, size, pc, false);
// z7_BranchConv_ARMT_Enc
int z7BranchConvArmtEnc(Uint8List d, int off, int size, int pc) =>
    _branchConvArmt(d, off, size, pc, true);

// ---------------------------------------------------------------------------
// IA64

// z7_BranchConv_IA64
int _branchConvIa64(Uint8List d, int p, int size, int pc, bool encoding) {
  size &= ~15;
  final lim = p + size;
  pc = (pc - (1 << 4)) & _m32;
  pc >>= 4 - 1;
  for (;;) {
    int m;
    for (;;) {
      if (p == lim) return p;
      m = 0x334b0000 >> (d[p] & 0x1e);
      p += 16;
      pc = (pc + (1 << 1)) & _m32;
      m &= 3;
      if (m != 0) break;
    }
    p += m * 5 - 20; // a negative value is expected here
    do {
      final t = d[p] | (d[p + 1] << 8);
      var z = _getUi32(d, p + 1) >> m;
      p += 5;
      if (((t >> m) & (0x70 << 1)) == 0 &&
          ((z - (0x5000000 << 1)) & (0xf000000 << 1)) == 0) {
        var v = ((0x8fffff << 1) | 1) & z;
        z ^= v;
        if (encoding) {
          pc &= (0x1fffff << 1) | 1;
          v += pc;
        } else {
          pc |= _m32 ^ ((0x1fffff << 1) | 1);
          v -= pc;
        }
        v &= _m32 ^ (0x600000 << 1);
        v += 0x700000 << 1;
        v &= (0x8fffff << 1) | 1;
        z |= v;
        z = (z << m) & _m32;
        _setUi32(d, p + 1 - 5, z);
      }
      m++;
    } while ((m &= 3) != 0);
  }
}

// z7_BranchConv_IA64_Dec
int z7BranchConvIa64Dec(Uint8List d, int off, int size, int pc) =>
    _branchConvIa64(d, off, size, pc, false);
// z7_BranchConv_IA64_Enc
int z7BranchConvIa64Enc(Uint8List d, int off, int size, int pc) =>
    _branchConvIa64(d, off, size, pc, true);

// ---------------------------------------------------------------------------
// RISCV (the little endian variant with 16-bit loads, RISCV_USE_16BIT_LOAD)

const int _riscvInstrSize = 2;
const int _riscvStep1 = 4 + _riscvInstrSize;
const int _riscvStep2 = 4;
const int _riscvRegVal = 2 << 7;
const int _riscvCmdVal = 3;
const int _riscvDelta7F = 0x7f;

// RISCV_CHECK_1
bool _riscvCheck1(int v, int b) =>
    (((b - _riscvCmdVal) ^ (v << 8)) & (0xf8000 + _riscvCmdVal)) == 0;

// RISCV_CHECK_2
bool _riscvCheck2(int v, int r) =>
    (((v - ((_riscvCmdVal << 12) | _riscvRegVal | 8)) << 18) & _m32) <
    (r & 0x1d);

// z7_BranchConv_RISCV_Enc
int z7BranchConvRiscvEnc(Uint8List d, int p, int size, int pc) {
  // RISCV_SCAN_LOOP
  size &= ~(_riscvInstrSize - 1);
  if (size <= 6) return p;
  size -= 6;
  final lim = p + size;
  pc -= p;
  for (;;) {
    int a, v;
    for (;;) {
      if (p >= lim) return p;
      a = ((d[p] | (d[p + 1] << 8)) ^ 0x10) + 1;
      if ((a & 0x77) == 0) break;
      a = ((d[p + 2] | (d[p + 3] << 8)) ^ 0x10) + 1;
      p += _riscvInstrSize * 2;
      if ((a & 0x77) == 0) {
        p -= _riscvInstrSize;
        if (p >= lim) return p;
        break;
      }
    }
    // end of RISCV_SCAN_LOOP
    v = a;
    a = _getUi32(d, p);

    if ((v & 8) == 0) {
      // JAL
      if (((v - 0x100) & 0xd80) != 0) {
        p += _riscvInstrSize;
        continue;
      }
      v = ((a & 0x80000000) >> 11) |
          ((a & (0x3ff << 21)) >> 20) |
          ((a & (1 << 20)) >> 9) |
          (a & (0xff << 12));
      v = (v + pc + p) & _m32; // BR_CONVERT_VAL_ENC
      d[p + 1] = ((v >> 13) & 0xf0) | ((a >> 8) & 0xf);
      d[p + 2] = v >> 9;
      d[p + 3] = v >> 1;
      p += 4;
      continue;
    }

    // AUIPC
    if ((v & 0xe80) != 0) {
      // (not x0) and (not x2)
      final b = _getUi32(d, p + 4);
      if (_riscvCheck1(v, b)) {
        _setUi32(d, p, ((b << 12) & _m32) | (0x17 + _riscvRegVal));
        a &= 0xfffff000;
        a = (a + (b.toSigned(32) >> 20)) & _m32; // arithmetic shift
        a = (a + pc + p) & _m32; // BR_CONVERT_VAL_ENC
        _setBe32(d, p + 4, a);
        p += 8;
      } else {
        p += _riscvStep1;
      }
    } else {
      var r = a >> 27;
      if (_riscvCheck2(v, r)) {
        v = _getUi32(d, p + 4);
        r = ((r << 7) + 0x17 + (v & 0xfffff000)) & _m32;
        a = (a >> 12) | ((v << 20) & _m32);
        _setUi32(d, p, r);
        _setUi32(d, p + 4, a);
        p += 8;
      } else {
        p += _riscvStep2;
      }
    }
  }
}

// z7_BranchConv_RISCV_Dec
int z7BranchConvRiscvDec(Uint8List d, int p, int size, int pc) {
  // RISCV_SCAN_LOOP
  size &= ~(_riscvInstrSize - 1);
  if (size <= 6) return p;
  size -= 6;
  final lim = p + size;
  pc -= p;
  for (;;) {
    int a, v;
    for (;;) {
      if (p >= lim) return p;
      a = ((d[p] | (d[p + 1] << 8)) ^ 0x10) + 1;
      if ((a & 0x77) == 0) break;
      a = ((d[p + 2] | (d[p + 3] << 8)) ^ 0x10) + 1;
      p += _riscvInstrSize * 2;
      if ((a & 0x77) == 0) {
        p -= _riscvInstrSize;
        if (p >= lim) return p;
        break;
      }
    }
    // end of RISCV_SCAN_LOOP
    if ((a & 8) == 0) {
      // JAL
      a = (a - (0x100 - _riscvDelta7F)) & _m32;
      if ((a & 0xd80) != 0) {
        p += _riscvInstrSize;
        continue;
      }
      final aOld = (a + (0xef - _riscvDelta7F)) & 0xfff;
      v = (d[p + 3] << 1) | (d[p + 2] << 9) | ((a & 0xf000) << 5);
      v = (v - (pc + p)) & _m32; // BR_CONVERT_VAL_DEC
      a = aOld |
          ((v << 11) & 0x80000000) |
          ((v << 20) & (0x3ff << 21)) |
          ((v << 9) & (1 << 20)) |
          (v & (0xff << 12));
      _setUi32(d, p, a);
      p += 4;
      continue;
    }

    // AUIPC
    v = a;
    a = _getUi32(d, p);
    if ((v & 0xe80) == 0) {
      // x0/x2
      final r = a >> 27;
      if (_riscvCheck2(v, r)) {
        var b = _getBe32(d, p + 4);
        v = a >> 12;
        b = (b - (pc + p)) & _m32; // BR_CONVERT_VAL_DEC
        a = (r << 7) + 0x17;
        a = (a + ((b + 0x800) & 0xfffff000)) & _m32;
        v |= (b << 20) & _m32;
        _setUi32(d, p, a);
        _setUi32(d, p + 4, v);
        p += 8;
      } else {
        p += _riscvStep2;
      }
    } else {
      final b = _getUi32(d, p + 4);
      if (!_riscvCheck1(v, b)) {
        p += _riscvStep1;
      } else {
        v = (a & 0xfffff000) | (b >> 20);
        a = ((b << 12) & _m32) | (0x17 + _riscvRegVal);
        _setUi32(d, p, a);
        _setUi32(d, p + 4, v);
        p += 8;
      }
    }
  }
}

// ---------------------------------------------------------------------------
// X86 (BCJ), Bra86.c

/// Z7_BRANCH_CONV_ST_X86_STATE_INIT_VAL
const int kBranchConvStX86StateInitVal = 0;

// BR86_NEED_CONV_FOR_MS_BYTE
bool _br86NeedConvForMsByte(int b) => ((b + 1) & 0xfe) == 0;

// BR86_IS_BCJ_BYTE
bool _br86IsBcjByte(int b) => (b & 0xfe) == 0xe8;

// The goto labels of z7_BranchConvSt_X86 become these states.
const int _x86Start = 0;
const int _x86Main = 1;
const int _x86A3 = 2;

// z7_BranchConvSt_X86 (Z7_BRANCH_CONV_ST(X86)). [state] is a one element
// list holding the UInt32 state variable.
int _branchConvStX86(
    Uint8List d, int p, int size, int pc, Uint32List state, bool encoding) {
  if (size < 5) return p;
  final lim = p + size - 4;
  var mask = state[0];
  // The call/jump offset is relative to the next instruction.
  pc = pc + 4 - p;
  var label = _x86Start;
  for (;;) {
    if (label == _x86Start) {
      // start:
      if (p >= lim) break; // goto fin
      int k;
      if (_br86IsBcjByte(d[p])) {
        k = 0;
      } else {
        mask >>= 1;
        if (_br86IsBcjByte(d[p + 1])) {
          k = 1;
        } else {
          mask >>= 1;
          if (_br86IsBcjByte(d[p + 2])) {
            k = 2;
          } else {
            mask = 0;
            k = _br86IsBcjByte(d[p + 3]) ? 3 : 4;
          }
        }
      }
      if (k == 4) {
        p += 4;
        label = _x86Main;
        continue;
      }
      // m0 / m1 / m2 / a3: (p) points after the e8/e9 byte
      p += k + 1;
      if (k == 3 || mask == 0) {
        label = _x86A3;
        continue;
      }
      if (p > lim) {
        p--; // fin_p
        break;
      }
      if (mask > 4 || mask == 3) {
        mask >>= 1;
        mask |= 4; // continue
        continue;
      }
      mask >>= 1;
      if (_br86NeedConvForMsByte(d[p + mask])) {
        mask |= 4; // continue
        continue;
      }
      var v = (_getUi32(d, p) + (1 << 24)) & _m32;
      if ((v & 0xfe000000) != 0) {
        mask |= 4; // continue
        continue;
      }
      final c = (pc + p) & _m32;
      if (encoding) {
        v = (v + c) & _m32;
      } else {
        v = (v - c) & _m32;
      }
      mask <<= 3;
      if (_br86NeedConvForMsByte(v >> mask)) {
        v ^= ((0x100 << mask) - 1);
        if (encoding) {
          v = (v + c) & _m32;
        } else {
          v = (v - c) & _m32;
        }
      }
      mask = 0;
      v &= (1 << 25) - 1;
      v -= 1 << 24;
      _setUi32(d, p, v);
      p += 4;
      label = _x86Main;
    } else if (label == _x86Main) {
      // main_loop:
      if (p >= lim) break; // goto fin
      var fin = false;
      for (;;) {
        p += 4;
        if (_br86IsBcjByte(d[p - 4])) {
          p -= 3; // a0
          break;
        }
        if (_br86IsBcjByte(d[p - 3])) {
          p -= 2; // a1
          break;
        }
        if (_br86IsBcjByte(d[p - 2])) {
          p -= 1; // a2
          break;
        }
        if (_br86IsBcjByte(d[p - 1])) break; // a3
        if (p >= lim) {
          fin = true;
          break;
        }
      }
      if (fin) break; // goto fin
      label = _x86A3;
    } else {
      // a3:
      if (p > lim) {
        p--; // fin_p
        break;
      }
      var v = (_getUi32(d, p) + (1 << 24)) & _m32;
      if ((v & 0xfe000000) != 0) {
        mask |= 4; // continue
        label = _x86Start;
        continue;
      }
      final c = (pc + p) & _m32;
      if (encoding) {
        v = (v + c) & _m32;
      } else {
        v = (v - c) & _m32;
      }
      v &= (1 << 25) - 1;
      v -= 1 << 24;
      _setUi32(d, p, v);
      p += 4;
      label = _x86Main;
    }
  }
  // fin:
  state[0] = mask;
  return p;
}

// z7_BranchConvSt_X86_Dec
int z7BranchConvStX86Dec(
        Uint8List d, int off, int size, int pc, Uint32List state) =>
    _branchConvStX86(d, off, size, pc, state, false);
// z7_BranchConvSt_X86_Enc
int z7BranchConvStX86Enc(
        Uint8List d, int off, int size, int pc, Uint32List state) =>
    _branchConvStX86(d, off, size, pc, state, true);

// ---------------------------------------------------------------------------
// Filter classes

/// NBranch::CCoder / CEncoder / CDecoder (BranchMisc.cpp): a RISC converter
/// with a start program counter.
class BranchFilter implements CompressFilter {
  final BranchConvFunc _braFunc;
  final int _pcInit;
  int _pc = 0;
  BranchFilter(this._braFunc, [this._pcInit = 0]);

  // CEncoder::Init / CDecoder::Init
  @override
  void init() => _pc = _pcInit;

  // CEncoder::Filter / CDecoder::Filter
  @override
  int filter(Uint8List data, int off, int size) {
    final processed = _braFunc(data, off, size, _pc) - off;
    _pc = (_pc + processed) & _m32;
    return processed;
  }
}

/// NBcj::CCoder2 (BcjCoder.cpp): the x86 converter with its state.
class BcjFilter implements CompressFilter {
  final bool _encoding;
  int _pc = 0;
  final Uint32List _state = Uint32List(1);
  BcjFilter(this._encoding);

  // CCoder2::Init
  @override
  void init() {
    _pc = 0;
    _state[0] = kBranchConvStX86StateInitVal;
  }

  // CCoder2::Filter
  @override
  int filter(Uint8List data, int off, int size) {
    final end = _encoding
        ? z7BranchConvStX86Enc(data, off, size, _pc, _state)
        : z7BranchConvStX86Dec(data, off, size, _pc, _state);
    final processed = end - off;
    _pc = (_pc + processed) & _m32;
    return processed;
  }
}
