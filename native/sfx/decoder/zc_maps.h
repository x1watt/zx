// zxsfx decoder: port of zcm_maps.dart (paq8px StationaryMap,
// LargeStationaryMap, SmallStationaryContextMap, IndirectContext, MTFList,
// ResidualMap) and of zcm_ols.dart (paq8px OLS).

#ifndef ZC_MAPS_H
#define ZC_MAPS_H

#include "zc.h"

// zcmDt2[n] = 2^30 / (n + 2).
extern i32 zcmDt2[1024];
void zc_maps_init(void);

// Dart int.bitLength of a non negative value.
ZINLINE i64 bitLength(i64 v) {
  return v <= 0 ? 0 : 64 - __builtin_clzll((u64)v);
}

typedef struct {
  u32 *t;
  i64 mask, stride, scale, context, b, cp;
} StationaryMap;
#define STATIONARYMAP_INPUTS 3
void stationarymap_init(StationaryMap *m, i64 bitsOfContext, i64 inputBits,
                        i64 scale); // Dart default scale: 64
ZINLINE void stationarymap_set(StationaryMap *m, i64 ctx) {
  m->context = (ctx & m->mask) * m->stride;
  m->b = 0;
}
void stationarymap_update(StationaryMap *m, i64 y);
void stationarymap_mix(StationaryMap *m, Mixer *mx);
void stationarymap_skip(StationaryMap *m, Mixer *mx);

typedef struct {
  u16 *t;
  i64 mask, stride, rate, scale, context, b, cp;
} SmallStationaryMap;
#define SMALLSTATIONARYMAP_INPUTS 2
void smallstationarymap_init(SmallStationaryMap *m, i64 bitsOfContext,
                             i64 inputBits, i64 rate,
                             i64 scale); // Dart default scale: 64
ZINLINE void smallstationarymap_set(SmallStationaryMap *m, i64 ctx) {
  m->context = (ctx & m->mask) * m->stride;
  m->b = 0;
}
void smallstationarymap_update(SmallStationaryMap *m, i64 y);
void smallstationarymap_mix(SmallStationaryMap *m, Mixer *mx);

typedef struct {
  u16 *chk;
  u32 *val;
  i64 hashBits, n, scale;
  i32 *cp;
  i64 k;
  ZRandom rnd;
} LargeStationaryMap;
#define LARGESTATIONARYMAP_INPUTS_PER_CONTEXT 3
void largestationarymap_init(LargeStationaryMap *m, i64 n, i64 hashBits,
                             i64 scale); // Dart default scale: 64
void largestationarymap_set(LargeStationaryMap *m, i64 h);
ZINLINE void largestationarymap_skipContext(LargeStationaryMap *m) {
  m->cp[m->k++] = -1;
}
void largestationarymap_update(LargeStationaryMap *m, i64 y);
void largestationarymap_mix(LargeStationaryMap *m, Mixer *mx);

typedef struct {
  u32 *t;
  i64 ctxMask, inputBits, contextBits, valueBits, ctx;
} IndirectContext;
// contextBits < 0: the Dart default (valueBits). Dart default valueBits: 8.
void indirectcontext_init(IndirectContext *c, i64 bitsPerContext,
                          i64 inputBits, i64 valueBits, i64 contextBits);
ZINLINE void indirectcontext_add(IndirectContext *c, i64 x) {
  i64 cur = c->t[c->ctx];
  i64 lead = cur & ((i64)1 << c->contextBits);
  i64 v = ((cur << c->inputBits) | x | lead) &
          (((i64)1 << (c->contextBits + 1)) - 1);
  v &= ((i64)1 << c->valueBits) - 1;
  c->t[c->ctx] = (u32)v;
}
ZINLINE void indirectcontext_select(IndirectContext *c, i64 i) {
  c->ctx = i & c->ctxMask;
}
ZINLINE i64 indirectcontext_value(const IndirectContext *c) {
  return c->t[c->ctx];
}

typedef struct {
  i32 *prev, *next;
  i64 root, index;
} MtfList;
void mtflist_init(MtfList *l, i64 n);
ZINLINE i64 mtflist_getFirst(MtfList *l) { return l->index = l->root; }
ZINLINE i64 mtflist_getNext(MtfList *l) {
  if (l->index >= 0) l->index = l->next[l->index];
  return l->index;
}
void mtflist_moveToFront(MtfList *l, i64 i);

// zcm_maps.dart ResidualMap (zcm_image.dart has another one, ImgResidualMap).
typedef struct {
  i64 n, histograms, scale;
  u16 *sums;
  i32 *pred, *base;
  i64 k;
} ResidualMap;
void residualmap_init(ResidualMap *m, i64 n, i64 histograms,
                      i64 scale); // Dart default scale: 64
ZINLINE i64 residualmap_inputs(const ResidualMap *m) { return m->n * 2; }
ZINLINE void residualmap_set(ResidualMap *m, i64 prediction, i64 histogram) {
  i64 k = m->k;
  m->pred[k] = (i32)prediction;
  m->base[k] = (i32)((k * m->histograms + histogram) * 256);
  m->k = k + 1;
}
ZINLINE void residualmap_skip(ResidualMap *m) { m->base[m->k++] = -1; }
void residualmap_update(ResidualMap *m, i64 byte);
void residualmap_mix(ResidualMap *m, Mixer *mx, i64 bpos, i64 c0);

// zcm_ols.dart ZcmOls.
typedef struct {
  i64 n, interval;
  double lambda, nu;
  double *x, *w, *c, *b, *l, *t;
  i64 k, since;
} Ols;
void ols_init(Ols *o, i64 n, i64 interval, double lambda);
ZINLINE void ols_add(Ols *o, double v) {
  if (o->k < o->n) o->x[o->k++] = v;
}
double ols_predict(Ols *o);
void ols_update(Ols *o, double y);

#endif
