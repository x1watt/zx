// zxsfx decoder: port of zcm_x86.dart, the x86 and x64 code model (level
// 4 and up, on exe blocks).
//
// A port of the ExeModel of paq8px (Marcio Pais, after the earlier paq
// exe models and DisFilter by Fabian Giesen). The opcode tables are
// copied from paq8px ExeModel.hpp.

#ifndef ZC_X86_H
#define ZC_X86_H

#include "zc.h"

typedef struct {
  ZModel base;
  ContextMap cm;
  u8 *im; // IndirectMap states (1 << 20)
  StateMap imSm;
  i64 imIdx;
  ZRandom rnd;
  u32 cache[32];
  i64 cacheIndex;
  u32 stateBh[256];
  i64 pState, state;
  i64 opMask, opCategoryMask, context;
  i64 brkCtx;
  // The instruction being parsed.
  i64 data, prefix, code, modRM, sib, rex;
  i64 flags, bytesRead, category;
  int mustCheckRex, decoding, o16, imm8;
  // full: byte history inputs and all six mixer selectors (paq8px).
  int full;
} X86Model;

// Dart default full: true (the predictor passes exe >= 3).
void x86model_init(X86Model *m, i64 bytes, int full);

#endif
