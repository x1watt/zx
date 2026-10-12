// zxsfx decoder: port of zcm_fast.dart, the predictor of level 1.
//
// lpaq1 style (Matt Mahoney): orders 1, 2, 3, 4 and 6 in hashed tables
// with one 64 byte line of 16 entries per context and nibble (the layout
// of lpaq's nibble tables and zpaq's CM component), an order 1 table
// indexed directly, a match model on the last 6 bytes, one mixer weight
// set per partial byte and one APM.

#ifndef ZC_FAST_H
#define ZC_FAST_H

#include "zc.h"

#define ZFAST_NORD 5
#define ZFAST_NIN (ZFAST_NORD + 1 + 2 + 1) // orders, order 1, match, bias
#define ZFAST_STRIDE 12                    // ZFAST_NIN padded

// ZcmFastPredictor
typedef struct {
  ZState s; // the shared history
  u32 *t;
  i64 mask;
  i32 ctx[ZFAST_NORD];
  i32 base[ZFAST_NORD];
  i32 idx[ZFAST_NORD];
  u32 *o1; // 1 << 16
  i64 o1i;
  // Match model.
  i32 *ht;
  i64 htMask;
  i64 ptr, len, exp;
  u32 msm[64 * 2];
  i64 msi;
  // Mixer.
  i32 *w; // 256 * ZFAST_STRIDE
  i32 x[ZFAST_STRIDE];
  i64 wo, pr12, rate;
  // APM.
  Apm apm;
  i64 misses;
  i64 pr;
  i64 tableBytes;
} ZcmFast;

// ZcmFastPredictor(budgetBytes)
void zfast_init(ZcmFast *f, i64 budgetBytes);
// Probability (16 bits) that the next bit is 1.
i64 zfast_p(ZcmFast *f);
// Records the coded bit.
ZINLINE void zfast_update(ZcmFast *f, i64 bit) { zstate_update(&f->s, bit); }
// Starts a segment of [type] with [info].
ZINLINE void zfast_setSegment(ZcmFast *f, i64 type, i64 info) {
  f->s.blockType = type;
  f->s.blockInfo = info;
  f->s.blockPos = 0;
}

#endif
