// zxsfx decoder: the PPMd var.H model (Dmitry Shkarin), port of the model
// part of lib/src/codec/ppmd/ppmd7.dart (itself a port of the LZMA SDK's
// C/Ppmd7.c by Igor Pavlov), as zcm's PpmdByteModel uses it: no range
// coder, only the model updates.
//
// Every "pointer" is an offset into one arena (mem), viewed as bytes,
// 16-bit and 32-bit words in the host (little endian) byte order, with
// the C layout described in ppmd7.dart.

#ifndef ZC_PPMD_H
#define ZC_PPMD_H

#include "zc.h"

typedef u16 __attribute__((may_alias)) u16a;
typedef u32 __attribute__((may_alias)) u32a;

#define PPMD7_MIN_MEM_SIZE (1 << 11)
#define PPMD_INT_BITS 7
#define PPMD_PERIOD_BITS 7
#define PPMD_BIN_SCALE (1 << (PPMD_INT_BITS + PPMD_PERIOD_BITS))
#define PPMD_NUM_INDEXES 38
#define PPMD_DUMMY_SEE (25 * 16)

typedef struct {
  i64 minContext, maxContext, foundState, orderFall, initEsc, prevSuccess,
      maxOrder, hiBitsFlag, runLength, initRL;
  i64 size, glueCount, alignOffset;
  u8 *mem;
  u16a *mem16;
  u32a *mem32;
  i64 loUnit, hiUnit, text, unitsStart;
  u8 indx2Units[PPMD_NUM_INDEXES + 2];
  u8 units2Indx[128];
  u32 freeList[PPMD_NUM_INDEXES];
  u8 ns2BSIndx[256];
  u8 ns2Indx[256];
  u8 expEscape[16];
  u16 seeSumm[25 * 16 + 1];
  u8 seeShift[25 * 16 + 1];
  u8 seeCount[25 * 16 + 1];
  u16 binSumm[128 * 64];
  u8 charMask[256];
  u32 ps[64];
} Ppmd7;

// Ppmd7_Construct
void ppmd7_construct(Ppmd7 *p);
// Ppmd7_Alloc (from the arena)
void ppmd7_alloc(Ppmd7 *p, i64 size);
// Ppmd7_Init
void ppmd7_init(Ppmd7 *p, i64 maxOrder);
void ppmd7_update1(Ppmd7 *p);
void ppmd7_update1_0(Ppmd7 *p);
void ppmd7_update2(Ppmd7 *p);
void ppmd7_updateBin(Ppmd7 *p, i64 s);
i64 ppmd7_getBinSumm(Ppmd7 *p);
void ppmd7_seeUpdate(Ppmd7 *p, i64 see);
ZINLINE void ppmd7_setAllBitsInCharMask(Ppmd7 *p) {
  memset(p->charMask, 0xFF, 256);
}
// PPMD7_HiBitsFlag_3
ZINLINE i64 ppmd7HiBitsFlag3(i64 sym) {
  return ((sym + 0xC0) >> (8 - 3)) & (1 << 3);
}
// SUCCESSOR of the state at [s].
ZINLINE i64 ppmd7_successor(const Ppmd7 *p, i64 s) {
  i64 i = (s >> 1) + 1;
  return (i64)p->mem16[i] | ((i64)p->mem16[i + 1] << 16);
}

#endif
