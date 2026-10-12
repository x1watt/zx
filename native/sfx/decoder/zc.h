// zxsfx decoder: shared definitions of the C port of zcm and of the zx
// reader. Compiled for wasm32 (the self-extracting archive) and natively
// (tests), with -fwrapv -ffp-contract=off, so it computes exactly what the
// Dart code computes.
//
// Porting rules (Dart -> C), which every file of the port follows:
//   * a Dart `int` is an `i64`; with -fwrapv, +, -, * wrap like Dart's
//     64-bit ints. `<<` goes through shl() when the left side can be
//     negative or the result can overflow (it is undefined in C).
//   * `>>` on an i64 is arithmetic (as Dart); `>>>` is ushr().
//   * `~/` is C `/` (both truncate); Dart `%` is dmod() (never negative)
//     unless both sides are known to be non negative.
//   * Uint8List / Int16List / Uint16List / Int32List / Uint32List /
//     Float64List are u8 / i16 / u16 / i32 / u32 / double arrays: a store
//     truncates the same way as in Dart. Read a u32 element into an i64
//     before arithmetic that could overflow 32 bits.
//   * `double` is C double; never call libm (use zexp, ztanh, zsigmoid,
//     zsqrt of zc_math.c). Dart's `x.truncate()` is (i64)x, `x.round()`
//     is dround(), `x.floor()` is dfloor().
//   * typed lists are zero filled: zalloc() returns zeroed memory.
//   * classes are structs; methods take the struct pointer first. An
//     interface is a struct of function pointers placed first in the
//     struct that implements it (ZModel below).

#ifndef ZC_H
#define ZC_H

#include <stddef.h>
#include <stdint.h>

typedef int64_t i64;
typedef uint64_t u64;
typedef int32_t i32;
typedef uint32_t u32;
typedef int16_t i16;
typedef uint16_t u16;
typedef int8_t i8;
typedef uint8_t u8;

#define ZINLINE static inline __attribute__((always_inline))

ZINLINE i64 shl(i64 a, int n) { return (i64)((u64)a << n); }
ZINLINE i64 ushr(i64 a, int n) { return (i64)((u64)a >> n); }
ZINLINE i64 dmod(i64 a, i64 b) {
  i64 r = a % b;
  return r < 0 ? r + (b < 0 ? -b : b) : r;
}
ZINLINE i64 imin(i64 a, i64 b) { return a < b ? a : b; }
ZINLINE i64 imax(i64 a, i64 b) { return a > b ? a : b; }

// ---------------------------------------------------------------- libc

void *memcpy(void *d, const void *s, size_t n);
void *memmove(void *d, const void *s, size_t n);
void *memset(void *d, int c, size_t n);
int memcmp(const void *a, const void *b, size_t n);
size_t strlen(const char *s);

// Fatal error: prints the message and exits (status 2).
__attribute__((noreturn)) void zfatal(const char *msg);

// Memory: an arena. zalloc returns zeroed, 16 byte aligned memory, or
// calls zfatal when the memory is exhausted. zmark / zrelease free
// everything allocated after the mark.
void *zalloc(size_t n);
size_t zmark(void);
void zrelease(size_t mark);
// Typed helpers.
#define ZNEW(T, n) ((T *)zalloc(sizeof(T) * (size_t)(n)))

// ---------------------------------------------------------------- math

double zexp(double x);
double zsigmoid(double x);
double ztanh(double x);
double zsqrt(double x);
// Dart double.round() (half away from zero) and floor(), to an i64.
i64 dround(double x);
i64 dfloor(double x);
double dabs(double x);

// ---------------------------------------------------------------- tables

extern i16 kSquash[4096];
extern i16 kStretch[4096];
extern i32 kDt[1024];
extern u8 kIlog[65536];
extern const u8 kNex[512];
extern const u8 kStateN0[256];
extern const u8 kStateN1[256];
extern const u8 kStatePrio[256];
extern const u8 kStateGroup[256];
void zc_tables_init(void);

ZINLINE i64 squash(i64 d) {
  if (d > 2047) d = 2047;
  if (d < -2047) d = -2047;
  return kSquash[d + 2048];
}

ZINLINE i64 hash2(i64 a, i64 b) {
  i64 h = ((a & 0xFFFFFFFF) * 0x9E3779B1 + (b & 0xFFFFFFFF) * 0x85EBCA77 +
           1) & 0xFFFFFFFF;
  h ^= h >> 15;
  h = (h * 0x2C1B3C6D) & 0xFFFFFFFF;
  h ^= h >> 13;
  return h;
}
ZINLINE i64 hash3(i64 a, i64 b, i64 c) { return hash2(hash2(a, b), c); }
ZINLINE i64 hash4(i64 a, i64 b, i64 c, i64 d) {
  return hash2(hash2(hash2(a, b), c), d);
}
i64 floorPow2(i64 x);
i64 log2Exact(i64 x);
i64 zcmHashBitsFor(i64 bytes, i64 entryBytes);

// ---------------------------------------------------------------- components

typedef struct { i64 s; } ZRandom;
ZINLINE void zrandom_init(ZRandom *r) { r->s = 0x2545F491; }
ZINLINE i64 zrandom_next(ZRandom *r) {
  i64 s = r->s;
  s ^= (s << 13) & 0xFFFFFFFF;
  s ^= s >> 17;
  s ^= (s << 5) & 0xFFFFFFFF;
  r->s = s;
  return s;
}

ZINLINE i64 nextState(i64 s, i64 y, ZRandom *rnd) {
  i64 ns = kNex[(y << 8) | s];
  if (ns >= 205 && ns >= s + 4 && (zrandom_next(rnd) & 1) != 0) return s;
  return ns;
}

i64 stateInitEntry(i64 state);

ZINLINE i64 adaptEntry(i64 e, i64 y, i64 limit) {
  i64 n = e & 1023;
  i64 p = e >> 10;
  i64 np = p + ((((y << 22) - p) * kDt[n]) >> 31);
  return (np << 10) | (n < limit ? n + 1 : n);
}

typedef struct {
  u32 *t;
  i64 n;
  i64 limit;
  i64 cx;
} StateMap;
void statemap_init(StateMap *m, i64 n, i64 limit, int bitHistory);
ZINLINE i64 statemap_p(StateMap *m, i64 y, i64 cx) {
  m->t[m->cx] = (u32)adaptEntry(m->t[m->cx], y, m->limit);
  m->cx = cx;
  return m->t[cx] >> 20;
}

typedef struct {
  u16 *t;
  i64 rate;
  i64 index;
} Apm;
void apm_init(Apm *a, i64 n, i64 rate);
i64 apm_pp16(Apm *a, i64 y, i64 pr, i64 cx);
ZINLINE i64 apm_pp(Apm *a, i64 y, i64 pr, i64 cx) {
  return apm_pp16(a, y, pr, cx) >> 4;
}

typedef struct {
  u32 *t;
  i64 steps, limit, n, cxt;
} ApmPx;
void apmpx_init(ApmPx *a, i64 n, i64 steps, i64 limit);
i64 apmpx_pp(ApmPx *a, i64 y, i64 pr, i64 cx);

typedef struct {
  u16 *t;
  i64 rate, index;
} Apm1;
void apm1_init(Apm1 *a, i64 n, i64 rate);
i64 apm1_pp(Apm1 *a, i64 y, i64 pr, i64 cx);

typedef struct {
  u32 *n0, *n1;
  i64 index;
} ApmPost;
void apmpost_init(ApmPost *a, i64 n);
i64 apmpost_pp(ApmPost *a, i64 y, i64 pr, i64 cx);

typedef struct {
  i64 n;
  i32 *tx;
  i64 nx;
  i32 *wx;
  i32 *base, *sizes, *sel, *st, *pr;
  i64 nSel;
  i64 k;
  i32 *nzi;
  i64 nz;
  i32 *fw;
  i64 fsel, finalContexts, fpr;
  i64 rate, rateMin, frate, frateMin, shift, stride, errLim;
} Mixer;
// [sizes] are the contexts of each of the [nsizes] selectors. Defaults of
// the Dart constructor: finalContexts 1, rateMax 56 << 16, rateMin
// 14 << 16, finalRate 56 << 16, finalRateMin 14 << 16, shift 16,
// initWeight 1 << 14.
typedef struct {
  i64 finalContexts, rateMax, rateMin, finalRate, finalRateMin, shift,
      initWeight;
} MixerOpts;
MixerOpts mixer_defaults(void);
void mixer_init(Mixer *m, i64 n, const i64 *sizes, i64 nsizes, MixerOpts o);
ZINLINE void mixer_add(Mixer *m, i64 x) { m->tx[m->nx++] = (i32)x; }
ZINLINE void mixer_set(Mixer *m, i64 cx) {
  m->sel[m->k] = (i32)(m->base[m->k] + cx * m->stride);
  m->k++;
}
ZINLINE void mixer_setFinal(Mixer *m, i64 cx) { m->fsel = cx * m->nSel; }
i64 mixer_p(Mixer *m);
void mixer_update(Mixer *m, i64 y);

typedef struct {
  u8 *t;
  i64 mask, dummy, nCtx;
  int rich, bh;
  u32 *runSm;
  i32 *runIdx;
  u32 *bh8, *bh12;
  i32 *bh8Idx, *bh12Idx;
  i32 *cxt;
  u8 *skip;
  i32 *cp, *cp0, *runp;
  u32 *sm;
  i32 *smIdx, *stv;
  ZRandom rnd;
  i64 hits;
} ContextMap;
void contextmap_init(ContextMap *c, i64 bytes, i64 nCtx, int rich, int bh);
ZINLINE i64 contextmap_inputsPerContext(const ContextMap *c) {
  return (c->rich ? 6 : 4) + (c->bh ? 2 : 0);
}
ZINLINE void contextmap_set(ContextMap *c, i64 i, i64 cx) {
  c->cxt[i] = (i32)(hash2(cx, i) & 0xFFFFFFFF);
  c->skip[i] = 0;
}
ZINLINE void contextmap_skip(ContextMap *c, i64 i) { c->skip[i] = 1; }
void contextmap_mix(ContextMap *c, Mixer *m, i64 y, i64 bpos, i64 c0, i64 c1);

typedef struct {
  u8 *t;
  i64 mask;
  u32 *sm;
  i64 smi, cp, base;
  ZRandom rnd;
} DirectMap;
void directmap_init(DirectMap *d, i64 bits);
ZINLINE void directmap_set(DirectMap *d, i64 cx) {
  d->base = (cx & d->mask) << 8;
}
void directmap_mix(DirectMap *d, Mixer *m, i64 y, i64 c0);

typedef struct {
  u32 *t;
  i64 mask, limit, cx;
} DirectProbMap;
void directprobmap_init(DirectProbMap *d, i64 bits, i64 limit);
ZINLINE i64 directprobmap_p(DirectProbMap *d, i64 y, i64 cx) {
  d->t[d->cx] = (u32)adaptEntry(d->t[d->cx], y, d->limit);
  d->cx = cx & d->mask;
  return d->t[d->cx] >> 20;
}

typedef struct {
  i64 acc, pr;
} GainGate;
ZINLINE void gaingate_init(GainGate *g) {
  g->acc = -65536;
  g->pr = -1;
}
ZINLINE int gaingate_open(const GainGate *g) { return g->acc < -2048; }
ZINLINE void gaingate_update(GainGate *g, i64 y) {
  i64 pr = g->pr;
  if (pr < 0) return;
  i64 p = y != 0 ? pr : 4096 - pr;
  i64 d = 192 - kIlog[p < 1 ? 1 : p] - 16;
  g->acc += d - (g->acc >> 12);
}
ZINLINE void gaingate_record(GainGate *g, i64 p12) { g->pr = p12; }

// ---------------------------------------------------------------- models

// Block types (zcm_detect.dart, ZcmBlockType).
enum {
  ZT_BINARY = 0,
  ZT_TEXT = 1,
  ZT_EXE = 2,
  ZT_IMAGE8 = 3,
  ZT_IMAGE24 = 4,
  ZT_IMAGE32 = 5,
  ZT_AUDIO = 6,
  ZT_IMAGE1 = 7,
  ZT_IMAGE4 = 8,
  ZT_IMAGE8PAL = 9,
  ZT_COUNT = 10,
};
#define ZT_MAX_IMAGE_STRIDE (1 << 20)
int zt_hasInfo(int type);
int zt_isImage(int type);
int zt_isBitImage(int type);

typedef struct {
  i64 y, c0, bpos, c4, c8, pos;
  u8 *buf;
  i64 bufMask;
  i64 blockType, blockInfo, blockPos;
} ZState;
void zstate_init(ZState *s, i64 bufBytes);
ZINLINE i64 zstate_back(const ZState *s, i64 i) {
  return s->buf[(s->pos - i) & s->bufMask];
}
ZINLINE void zstate_update(ZState *s, i64 bit) {
  s->y = bit;
  i64 c = (s->c0 << 1) | bit;
  if (c >= 256) {
    i64 b = c & 255;
    s->buf[s->pos & s->bufMask] = (u8)b;
    s->pos++;
    s->blockPos++;
    s->c8 = ((s->c8 << 8) | (s->c4 >> 24)) & 0xFFFFFFFF;
    s->c4 = ((s->c4 << 8) | b) & 0xFFFFFFFF;
    s->c0 = 1;
    s->bpos = 0;
  } else {
    s->c0 = c;
    s->bpos++;
  }
}

// A model (ZcmModel, and ZcmMixerContexts when nsel > 0). The struct of a
// model starts with a ZModel.
typedef struct ZModel ZModel;
struct ZModel {
  i64 inputs;
  void (*mix)(ZModel *self, ZState *s, Mixer *m);
  // ZcmMixerContexts: the sizes of the selectors it sets, and the setter.
  i64 nsel;
  const i64 *selSizes;
  void (*setCtx)(ZModel *self, ZState *s, Mixer *m);
};

// ZcmMatchInfo: a match model.
typedef struct {
  ZModel base;
  i64 (*length)(ZModel *self);
  i64 (*expectedByte)(ZModel *self);
} ZMatchModel;

// ---------------------------------------------------------------- coder

typedef struct {
  i64 x1, x2, x;
  const u8 *data;
  i64 pos, end;
} ZDecoder;
void zdecoder_init(ZDecoder *d, const u8 *data, i64 start, i64 end);
ZINLINE i64 zdecoder_next(ZDecoder *d) {
  return d->pos < d->end ? d->data[d->pos++] : (d->pos++, 0);
}
ZINLINE i64 zdecoder_decode(ZDecoder *d, i64 p) {
  i64 xmid = d->x1 + (((d->x2 - d->x1) * p) >> 16);
  i64 y;
  if (d->x <= xmid) {
    y = 1;
    d->x2 = xmid;
  } else {
    y = 0;
    d->x1 = xmid + 1;
  }
  while (((d->x1 ^ d->x2) & 0xFF000000) == 0) {
    d->x1 = (d->x1 << 8) & 0xFFFFFFFF;
    d->x2 = ((d->x2 << 8) & 0xFFFFFFFF) | 255;
    d->x = ((d->x << 8) & 0xFFFFFFFF) | zdecoder_next(d);
  }
  return y;
}
i64 zdecoder_decodeDirect(ZDecoder *d, int n);

#endif
