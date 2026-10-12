// zxsfx decoder: port of zcm_image_px.dart (the image models of paq8px as
// whole models, levels 7 to 9).
//
// Ports of paq8px's Image24BitModel and Image8BitModel (grayscale part),
// with their mixer weight set selectors and their SSE stages (SSE.cpp,
// IMAGE24 and IMAGE8GRAY). paq8px image models: Marcio Pais (from his
// Emma), Zoltan Gotthardt, Sebastian Lehmann (the least squares fits) and
// the paq8px authors, after the im8/im24 models of paq8 by Matt Mahoney.
// The owner decided that zcm may port paq8px code freely (credits in the
// file headers, the README and LICENSE).

#include "zc_image_px.h"

// ---------------------------------------------------------------- helpers

ZINLINE i64 rabs(i64 a, i64 b) { return a > b ? a - b : b - a; }
ZINLINE i64 iabs(i64 x) { return x < 0 ? -x : x; }
ZINLINE i64 clip8(i64 x) { return x < 0 ? 0 : (x > 255 ? 255 : x); }
ZINLINE i64 avg2(i64 x, i64 y) { return (x + y + 1) >> 1; }
ZINLINE i64 pmin(i64 a, i64 b) { return a < b ? a : b; }
ZINLINE i64 pmax(i64 a, i64 b) { return a > b ? a : b; }
// Dart toSigned(16) and toSigned(8).
ZINLINE i64 sx16(i64 v) { return (i64)(i16)(u16)v; }
ZINLINE i64 sx8(i64 v) { return (i64)(i8)(u8)v; }

// paq8px DiffQt (its arguments are bytes).
static i64 diffQt(i64 a, i64 b) {
  a &= 255;
  b &= 255;
  i64 d = a > b ? a - b : b - a;
  if (d <= 2) {
  } else if (d <= 5) {
    d = 3;
  } else if (d <= 9) {
    d = 4;
  } else if (d <= 14) {
    d = 5;
  } else if (d <= 23) {
    d = 6;
  } else {
    d = 7;
  }
  return (a > b ? 8 : 0) | d;
}

static i64 paeth(i64 w, i64 n, i64 nw) {
  i64 p = w + n - nw;
  i64 pw = iabs(p - w), pn = iabs(p - n), pnw = iabs(p - nw);
  if (pw <= pn && pw <= pnw) return w;
  if (pn <= pnw) return n;
  return nw;
}

static i64 gap(i64 w, i64 n, i64 nw, i64 ne, i64 ww, i64 nne, i64 nn) {
  i64 dh = iabs(w - ww) + iabs(n - nw) + iabs(ne - n);
  i64 dv = iabs(w - nw) + iabs(n - nn) + iabs(ne - nne);
  if (dh > dv) return n;
  if (dv > dh) return w;
  return n + w - nw;
}

// paq8px clamp4: [px] limited to the range of four bytes.
static i64 clamp4(i64 px, i64 a, i64 b, i64 c, i64 d) {
  i64 hi = a, lo = a;
  if (b > hi) hi = b;
  if (c > hi) hi = c;
  if (d > hi) hi = d;
  if (b < lo) lo = b;
  if (c < lo) lo = c;
  if (d < lo) lo = d;
  return px < lo ? lo : (px > hi ? hi : px);
}

ZINLINE i64 ilog2(i64 x) { return x <= 0 ? 0 : bitLength(x) - 1; }

// roundf, then the conversion to short.
static i64 roundShort(double v) {
  if (!__builtin_isfinite(v)) return 0;
  if (v > 32767) return 32767;
  if (v < -32768) return -32768;
  return (i64)(v + (v < 0 ? -0.5 : 0.5));
}

ZINLINE i64 h5(i64 a, i64 b, i64 c, i64 d, i64 e) {
  return hash2(hash4(a, b, c, d), e);
}
ZINLINE i64 h6(i64 a, i64 b, i64 c, i64 d, i64 e, i64 f) {
  return hash2(h5(a, b, c, d, e), f);
}
ZINLINE i64 h7(i64 a, i64 b, i64 c, i64 d, i64 e, i64 f, i64 g) {
  return hash2(h6(a, b, c, d, e, f), g);
}

ZINLINE void mp(i32 *pr, i64 i, i64 r1, i64 r2, i64 p) {
  pr[i] = (i32)((rabs(r1 & 255, r2 & 255) << 16) | (p & 65535));
}
ZINLINE void mc(i32 *pr, i64 i, i64 p) { pr[i] = (i32)(p & 65535); }
ZINLINE void mavg(i32 *pr, i64 i, i64 a, i64 b) {
  pr[i] = (i32)(((rabs(a, b) & 65535) << 16) | (avg2(a, b) & 65535));
}
ZINLINE void mt(i32 *pr, i64 i, i64 px, i64 far, i64 origin) {
  pr[i] = (i32)(((rabs(px, far) & 65535) << 16) |
                ((origin + px - far) & 65535));
}
ZINLINE void ms(i32 *pr, i64 i, i64 px, i64 far, i64 origin) {
  pr[i] = (i32)(((rabs(px, far) & 65535) << 16) |
                (avg2(origin, origin + px - far) & 65535));
}

// The features of paq8px's least squares fits (olsCtx1 to olsCtx6) as
// indexes of the neighborhood list (nb: olsCtx1's 32 pixels, p1, p2).
static const u8 kOlsIdx0[] = {0,  1,  2,  3,  4,  5,  6,  7,  8,  9,  10,
                              11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21,
                              22, 23, 24, 25, 26, 27, 28, 29, 30, 31};
static const u8 kOlsIdx1[] = {3, 4, 5, 8, 9, 10, 11, 12, 17, 18, 19, 24};
static const u8 kOlsIdx2[] = {10, 11, 12, 13, 14, 18, 19, 20,
                              21, 24, 25, 26, 28, 29, 30};
static const u8 kOlsIdx3[] = {10, 11, 12, 13, 18, 19, 20, 24, 25, 28};
static const u8 kOlsIdx4[] = {2, 3, 4, 5, 7, 8, 9, 10, 16, 17, 18, 23, 24, 28};
static const u8 kOlsIdx5[] = {3, 4, 5, 24, 18, 10, 32, 33};
static const u8 *const kOlsIdx[6] = {kOlsIdx0, kOlsIdx1, kOlsIdx2,
                                     kOlsIdx3, kOlsIdx4, kOlsIdx5};
static const i64 kOlsIdxLen[6] = {sizeof(kOlsIdx0), sizeof(kOlsIdx1),
                                  sizeof(kOlsIdx2), sizeof(kOlsIdx3),
                                  sizeof(kOlsIdx4), sizeof(kOlsIdx5)};

// ---------------------------------------------------------------- _Ring

static void ring_init(PxRing *r) {
  r->b = ZNEW(u8, 1);
  r->cap = 1;
  r->mask = 0;
  r->pos = 0;
}

static void ring_setSize(PxRing *r, i64 n, i64 fill) {
  i64 size = 1;
  while (size < n) size <<= 1;
  if (size > r->cap) {
    r->b = ZNEW(u8, size);
    r->cap = size;
  }
  memset(r->b, (int)fill, (size_t)size);
  r->mask = size - 1;
  r->pos = 0;
}

ZINLINE void ring_add(PxRing *r, i64 v) {
  r->b[r->pos & r->mask] = (u8)v;
  r->pos++;
}

ZINLINE i64 ring_back(const PxRing *r, i64 i) {
  return r->b[(r->pos - i) & r->mask];
}

// ---------------------------------------------------------------- ZcmImageSse

void zcmimagesse_init(ZcmImageSse *x, i64 bits, int gray) {
  x->gray = gray;
  apmpx_init(&x->a0, gray ? 1 << 11 : 1 << 7, 24, 1023);
  apmpx_init(&x->a1, (i64)1 << bits, 24, 1023);
  apmpx_init(&x->a2, gray ? 256 * 257 : (i64)1 << bits, 24, 1023);
  apmpx_init(&x->a3, gray ? 1 : (i64)1 << bits, 24, 1023);
  apm1_init(&x->b1, gray ? 1 : 1 << 15, 7);
  apm1_init(&x->b2, gray ? 1 : (i64)1 << bits, 7);
  apmpost_init(&x->postA, 8);
  apmpost_init(&x->postB, 8);
  x->mask = ((i64)1 << bits) - 1;
}

i64 zcmimagesse_bytesFor(i64 bits, int gray) {
  return gray ? (((i64)1 << 11) + ((i64)1 << bits) + 256 * 257) * 24 * 4 +
                    2 * 8 * 4096 * 8
              : (((i64)1 << 7) + 3 * ((i64)1 << bits)) * 24 * 4 +
                    (((i64)1 << 15) + ((i64)1 << bits)) * 33 * 2 +
                    2 * 8 * 4096 * 8;
}

i64 zcmimagesse_p(ZcmImageSse *x, i64 y, i64 pr, i64 c0, i64 bpos, i64 m3,
                  const PxImageModel *img, i64 e) {
  i64 r = 0;
  if (x->gray) {
    i64 ctx = pximage_sseCtx(img);
    i64 p0 = apmpx_pp(&x->a0, y, pr, (c0 << 3) | (bpos == 0 ? 0 : (m3 & 3)));
    i64 p1 = apmpx_pp(&x->a1, y, p0 >> 4, ((c0 << 8) | ctx) & x->mask);
    i64 p2 = apmpx_pp(&x->a2, y, pr, (bpos | (ctx & 0xF8)) * 257 + e);
    i64 pa = (2 * (pr << 4) + p1 + p2 + 2) >> 2;
    i64 qa = apmpost_pp(&x->postA, y, p0 >> 4, bpos);
    i64 qb = apmpost_pp(&x->postB, y, pa >> 4, bpos);
    r = (qa + qb + 1) >> 1;
  } else {
    i64 plane = pximage_plane(img) & 3;
    i64 lossQ = pximage_lossQ(img);
    i64 p0 = apmpx_pp(&x->a0, y, pr,
                      (plane << 5) | (bpos << 2) | (bpos == 0 ? 0 : (m3 & 3)));
    i64 p1 = apmpx_pp(&x->a1, y, pr,
                      hash3(c0, pximage_pxW(img), pximage_pxWW(img)) & x->mask);
    i64 p2 = apmpx_pp(&x->a2, y, pr,
                      hash3(c0, pximage_pxN(img), pximage_pxNN(img)) & x->mask);
    i64 p3 = apmpx_pp(&x->a3, y, pr, ((c0 << 8) | pximage_sseCtx(img)) & x->mask);
    i64 pa = ((pr << 4) + p1 + p2 + p3 + 2) >> 2;
    i64 p4 = apm1_pp(&x->b1, y, p0 >> 4, ((lossQ >> 2) << 5) | (plane << 3) | bpos);
    i64 p5 = apm1_pp(&x->b2, y, p0 >> 4,
                     hash3(c0, lossQ > 255 ? 255 : lossQ, plane) & x->mask);
    i64 pb = (p0 * 2 + p4 * 3 + p5 * 3 + 4) >> 3;
    i64 qa = apmpost_pp(&x->postA, y, pa >> 4, bpos);
    i64 qb = apmpost_pp(&x->postB, y, pb >> 4, bpos);
    r = (qa + qb + 1) >> 1;
  }
  return r < 1 ? 1 : (r > 65535 ? 65535 : r);
}

// ---------------------------------------------------------------- predictors

// The neighborhood that the plane predictors read (paq8px names).
typedef struct {
  i64 wwwwww, wwwww, wwww, www, ww, w, nwwww, nwww, nww, nw, n, ne, nee,
      neee, neeee, nnnwww, nnwww, nnww, nnw, nn, nne, nnee, nneee, nnnww,
      nnnw, nnn, nnne, nnnee, nnneee, nnnnw, nnnn, nnnne, nnnnn, nnnnnn,
      nnnnww, nnwwww, nnnnee, nneeee, nnnnnnee, nnnnwwww, nnnneeee, neeeeee,
      nnnwwww, nnneeee, neeeee, neeeeeee;
} PxNb;

// The predictors of the current plane (shared by paq8px's 24 and 8 bit
// models, from "(N * 3 + W * 3 - NN - WW + 2) >> 2" to the constant 0).
static i64 planePredictors(i32 *pr, i64 i, const PxNb *b) {
  const i64 wwwwww = b->wwwwww, wwwww = b->wwwww, wwww = b->wwww,
            www = b->www, ww = b->ww, w = b->w, nwwww = b->nwwww,
            nwww = b->nwww, nww = b->nww, nw = b->nw, n = b->n, ne = b->ne,
            nee = b->nee, neee = b->neee, neeee = b->neeee,
            nnnwww = b->nnnwww, nnwww = b->nnwww, nnww = b->nnww,
            nnw = b->nnw, nn = b->nn, nne = b->nne, nnee = b->nnee,
            nneee = b->nneee, nnnww = b->nnnww, nnnw = b->nnnw,
            nnn = b->nnn, nnne = b->nnne, nnnee = b->nnnee,
            nnneee = b->nnneee, nnnnw = b->nnnnw, nnnn = b->nnnn,
            nnnne = b->nnnne, nnnnn = b->nnnnn, nnnnnn = b->nnnnnn,
            nnnnww = b->nnnnww, nnwwww = b->nnwwww, nnnnee = b->nnnnee,
            nneeee = b->nneeee, nnnnnnee = b->nnnnnnee,
            nnnnwwww = b->nnnnwwww, nnnneeee = b->nnnneeee,
            neeeeee = b->neeeeee, nnnwwww = b->nnnwwww, neeeee = b->neeeee,
            neeeeeee = b->neeeeeee;
  mc(pr, i++, (n * 3 + w * 3 - nn - ww + 2) >> 2);
  mavg(pr, i++, w, nee);
  mt(pr, i++, w, nw, n);
  mt(pr, i++, ww, nnww, nn);
  mt(pr, i++, www, nnnwww, nnn);
  mt(pr, i++, w, n, ne);
  mt(pr, i++, n, nnw, nw);
  mt(pr, i++, n, nne, ne);
  mt(pr, i++, nn, nnnnee, nnee);
  mt(pr, i++, n, nnn, nn);
  mt(pr, i++, nn, nnnnnn, nnnn);
  mt(pr, i++, w, www, ww);
  mt(pr, i++, ww, wwwwww, wwww);
  mt(pr, i++, w, ne, nee);
  mt(pr, i++, ww, nnee, nneeee);
  mt(pr, i++, nw, nww, w);
  mt(pr, i++, nnww, nnwwww, ww);
  mt(pr, i++, nn, nnw, w);
  mt(pr, i++, nnnn, nnnnnnee, nnee);
  mt(pr, i++, ne, nn, nw);
  ms(pr, i++, w, nne, ne);
  mt(pr, i++, nne, nnne, ne);
  mt(pr, i++, nee, nneee, nee);
  mt(pr, i++, neee, nnneee, neee);
  mt(pr, i++, nne, nn, w);
  mt(pr, i++, nnw, nnww, w);
  mc(pr, i++, n * 3 - nn * 3 + nnn);
  mc(pr, i++, w * 3 - ww * 3 + www);
  mc(pr, i++, clamp4(n * 3 - nn * 3 + nnn, n, w, ne, nw));
  mc(pr, i++, clamp4(w * 3 - ww * 3 + www, n, w, ne, nw));
  mc(pr, i++,
     (15 * n - 20 * nn + 15 * nnn - 6 * nnnn + nnnnn +
      clamp4(4 * w - 6 * nww + 4 * nnwww - nnnwwww, w, nw, n, nn)) /
         6);
  mc(pr, i++, (6 * ne - 4 * nnee + nnneee + (4 * w - 6 * nw + 4 * nnw - nnnw)) / 4);
  mc(pr, i++,
     ((n + 3 * nw) / 4) * 3 - avg2(nnw, nnww) * 3 + (nnnww * 3 + nnnwww) / 4);
  mc(pr, i++, (w * 2 + nw) - (ww + 2 * nww) + nwww);
  mavg(pr, i++, neeee, neeeeee);
  mavg(pr, i++, wwww, wwwwww);
  mavg(pr, i++, nnnn, nnnnnn);
  mavg(pr, i++, nnnnww, nnww);
  mavg(pr, i++, nnnnee, nnee);
  mavg(pr, i++, www, wwwwww);
  mc(pr, i++, w);
  mc(pr, i++, n);
  mc(pr, i++, nn);
  mt(pr, i++, w, ww, w);
  mt(pr, i++, ww, wwww, ww);
  mt(pr, i++, n, nn, n);
  mt(pr, i++, nn, nnnn, nn);
  mt(pr, i++, nw, nnww, nw);
  mt(pr, i++, nnww, nnnnwwww, nnww);
  mt(pr, i++, ne, nnee, ne);
  mt(pr, i++, nneee, nnnneeee, nneee);
  mt(pr, i++, w, nee, neee);
  mt(pr, i++, nww, nwwww, ww);
  mc(pr, i++, (w + n + neeeee + neeeeeee) / 4);
  mt(pr, i++, ww, n, nee);
  mt(pr, i++, n, nnww, nww);
  mavg(pr, i++, 2 * n - nn, 2 * w - ww);
  mavg(pr, i++, 2 * w - ww, 2 * nw - nnww);
  mc(pr, i++, paeth(w, n, nw));
  mc(pr, i++, gap(w, n, nw, ne, ww, nne, nn));
  mc(pr, i++, (6 * w - 4 * ww + www + 4 * ne - 6 * nne + 4 * nnne - nnnne) / 4);
  mc(pr, i++,
     (10 * w - 10 * ww + 5 * www - wwww + 4 * ne - 6 * nne + 4 * nnne - nnnne) /
         5);
  mc(pr, i++,
     (15 * w - 4 * ww + 10 * (3 * ne - 3 * nne + nnne) -
      (3 * neee - 3 * nneee + nnneee)) /
         20);
  mc(pr, i++, (8 * w - 3 * ww + (3 * nee - 3 * nnee + nnnee)) / 6);
  mc(pr, i++, (2 * w - ww) + (2 * n - nn) - (2 * nw - nnww));
  mc(pr, i++, (6 * n - 4 * nn + nnn + 4 * ne - 6 * nne + 4 * nnne - nnnne) / 4);
  mc(pr, i++,
     ((10 * n - 10 * nn + 5 * nnn - nnnn) + (4 * ne - 6 * nne + 4 * nnne - nnnne)) /
         5);
  mc(pr, i++, (6 * n - 4 * nn + nnn + 4 * nw - 6 * nnw + 4 * nnnw - nnnnw) / 4);
  mc(pr, i++,
     ((10 * n - 10 * nn + 5 * nnn - nnnn) + (4 * nw - 6 * nnw + 4 * nnnw - nnnnw)) /
         5);
  mc(pr, i++, (6 * ne - 4 * nnee + nnneee) / 3);
  mc(pr, i++,
     ((6 * w - 4 * ww + www) + (6 * n - 4 * nn + nnn) -
      (6 * nw - 4 * nnww + nnnwww)) /
         3);
  mc(pr, i++, (15 * w - 20 * ww + 15 * www - 6 * wwww + wwwww) / 5);
  mc(pr, i++, (2 * ne - nnee) + (2 * nw - nnww) - (2 * n - nn));
  mc(pr, i++, 0);
  return i;
}

// ---------------------------------------------------------------- PxImage24Model

#define NRM24 PXIMAGE24_NRM
#define NOLS24 PXIMAGE24_NOLS
#define NLSM24 PXIMAGE24_NLSM
#define NCM24 PXIMAGE24_NCM
#define NP24 PXIMAGE24_NP

static const double kLambda24[NOLS24] = {0.98, 0.87, 0.9, 0.8, 0.9, 0.7};
static const i64 kNum24[NOLS24] = {32, 12, 15, 10, 14, 8};
static const i64 kSel24[20] = {9,   8,   64,   64,   16, 512, 256,
                               128, 32,  1024, 32,   256, NP24, NP24,
                               1024, 1024, 8, 512, 256, 256};

static i64 px24_fixedBytes(void) {
  return ((i64)NRM24 * ((1 << 7) * 2 + (1 << 5)) +
          (i64)NOLS24 * ((1 << 7) + (1 << 5))) *
         512;
}

static i64 px24_cmBytes(i64 allowance) {
  i64 b = (allowance - px24_fixedBytes()) * 3 / 8;
  return floorPow2(b < (1 << 20) ? 1 << 20 : b);
}

static i64 px24_lsmBits(i64 allowance) {
  i64 left = allowance - px24_fixedBytes() - px24_cmBytes(allowance);
  i64 b = 12;
  while (b < 23 && ((i64)42 << (b + 1)) <= left) b++;
  return b;
}

i64 pximage24model_tableBytes(i64 allowance) {
  return px24_fixedBytes() + px24_cmBytes(allowance) +
         ((i64)42 << px24_lsmBits(allowance));
}

static i64 px24_plane(const PxImageModel *s) {
  return ((const PxImage24Model *)s)->color;
}
static i64 px24_lossQ(const PxImageModel *s) {
  return ((const PxImage24Model *)s)->lossQ;
}
static i64 px24_sseCtx(const PxImageModel *s) {
  const PxImage24Model *m = (const PxImage24Model *)s;
  return ((m->color << 9) | m->ctx0) >> 3;
}
static i64 px24_pxW(const PxImageModel *s) {
  return ((const PxImage24Model *)s)->w1;
}
static i64 px24_pxN(const PxImageModel *s) {
  return ((const PxImage24Model *)s)->n;
}
static i64 px24_pxWW(const PxImageModel *s) {
  return ((const PxImage24Model *)s)->ww;
}
static i64 px24_pxNN(const PxImageModel *s) {
  return ((const PxImage24Model *)s)->nn;
}

static void px24_prepare(PxImageModel *self, ZState *s);
static void px24_mix(ZModel *self, ZState *s, Mixer *m);
static void px24_setCtx(ZModel *self, ZState *s, Mixer *m);

void pximage24model_init(PxImage24Model *m, i64 allowance) {
  memset(m, 0, sizeof *m);
  contextmap_init(&m->cm, px24_cmBytes(allowance), NCM24, 1, 0);
  residualmap_init(&m->r1, NRM24, 1 << 7, 74);
  residualmap_init(&m->r2, NRM24, 1 << 5, 74);
  residualmap_init(&m->r3, NRM24, 1 << 7, 74);
  residualmap_init(&m->o1, NOLS24, 1 << 7, 74);
  residualmap_init(&m->o2, NOLS24, 1 << 5, 74);
  largestationarymap_init(&m->mapL, NLSM24, px24_lsmBits(allowance), 74);
  for (int i = 0; i < NOLS24; i++) {
    for (int c = 0; c < 4; c++) ols_init(&m->ols[i][c], kNum24[i], 1, kLambda24[i]);
  }
  ring_init(&m->errBuf);
  ring_init(&m->lossBuf);
  ring_init(&m->bestBuf);
  m->info = m->type = -1;
  m->stride = 3;
  m->w = 1;
  m->lastBpos = m->lastPos = -1;
  m->px.finalP = 32768;
  m->px.prepare = px24_prepare;
  m->px.plane = px24_plane;
  m->px.lossQ = px24_lossQ;
  m->px.sseCtx = px24_sseCtx;
  m->px.pxW = px24_pxW;
  m->px.pxN = px24_pxN;
  m->px.pxWW = px24_pxWW;
  m->px.pxNN = px24_pxNN;
  m->px.base.inputs = NCM24 * contextmap_inputsPerContext(&m->cm) +
                      (NRM24 * 3 + NOLS24 * 2) * 2 +
                      NLSM24 * LARGESTATIONARYMAP_INPUTS_PER_CONTEXT + 1;
  m->px.base.mix = px24_mix;
  m->px.base.nsel = 20;
  m->px.base.selSizes = kSel24;
  m->px.base.setCtx = px24_setCtx;
}

static void px24_initSegment(PxImage24Model *m) {
  m->stride = m->type == ZT_IMAGE32 ? 4 : 3;
  m->w = m->info & 0xFFFFFF;
  if (m->w < 1) m->w = 1;
  m->padding = m->w % m->stride;
  m->x = 0;
  m->line = 0;
  m->color = 0;
  ring_setSize(&m->lossBuf, 3 * m->w, 255);
  ring_setSize(&m->errBuf, 3 * m->w * NP24, 255);
  ring_setSize(&m->bestBuf, 3 * m->w, 0);
}

// Px: the pixel relX to the left and relY up on the plane colorShift bytes
// back, kept inside the rows; 127 when there is none.
static i64 px24_px(const PxImage24Model *m, const ZState *s, i64 relX,
                   i64 relY, i64 colorShift) {
  i64 st = m->stride;
  relX = relX * st + colorShift;
  i64 x0 = m->x - relX;
  while (x0 < 0) {
    relX -= st;
    x0 += st;
  }
  while (x0 >= m->w) {
    relX += st;
    x0 -= st;
  }
  if (m->line - relY < 0) relY = m->line;
  i64 offset = relY * m->w + relX;
  if (offset <= 0) {
    if (relY < m->line) {
      offset += m->w;
    } else {
      return 127;
    }
  }
  return zstate_back(s, offset);
}

ZINLINE i64 px24_ls(const PxImage24Model *m, i64 relX, i64 relY) {
  if (m->line - relY < 0) return 255;
  relX *= m->stride;
  if (m->x - relX < 0 || m->x - relX >= m->w) return 255;
  return ring_back(&m->lossBuf, relY * m->w + relX);
}

ZINLINE i64 px24_predErr(const PxImage24Model *m, i64 i, i64 relX, i64 relY) {
  if (m->line - relY < 0) return 255;
  relX *= m->stride;
  if (m->x - relX < 0 || m->x - relX >= m->w) return 255;
  return ring_back(&m->errBuf, (relY * m->w + relX - 1) * NP24 + i + 1);
}

static i64 px24_predErrAvg(const PxImage24Model *m, i64 i) {
  return (2 * px24_predErr(m, i, 1, 0) + 2 * px24_predErr(m, i, 0, 1) +
          px24_predErr(m, i, -1, 1) + px24_predErr(m, i, 1, 1) +
          px24_predErr(m, i, 2, 0) + px24_predErr(m, i, 0, 2)) >>
         3;
}

static void px24_byte(PxImage24Model *m, ZState *s, i64 c1);

static void px24_prepare(PxImageModel *self, ZState *s) {
  PxImage24Model *m = (PxImage24Model *)self;
  i64 bpos = s->bpos;
  i64 pos = s->pos;
  if (bpos == m->lastBpos && pos == m->lastPos) return;
  m->lastBpos = bpos;
  m->lastPos = pos;
  if (m->color < 4) {
    i64 p = m->px.finalP;
    m->loss += (s->y == 0 ? p : 65535 - p) >> 10;
  }
  if (bpos != 0) return;
  i64 c1 = s->c4 & 255;
  // Learn the byte just coded.
  residualmap_update(&m->r1, c1);
  residualmap_update(&m->r2, c1);
  residualmap_update(&m->r3, c1);
  residualmap_update(&m->o1, c1);
  residualmap_update(&m->o2, c1);
  if (s->blockType != m->type || s->blockInfo != m->info || s->blockPos == 0) {
    m->type = s->blockType;
    m->info = s->blockInfo;
    px24_initSegment(m);
    i64 k = s->blockPos;
    m->x = k % m->w;
    m->line = k / m->w;
  } else {
    m->x++;
    if (m->x >= m->w) {
      m->x = 0;
      m->line++;
    }
  }
  if (m->x == 0) {
    m->color = 0;
  } else if (m->x < m->w - m->padding) {
    m->color = m->x % m->stride;
  } else {
    m->color = 4;
  }
  if (m->color < 4) px24_byte(m, s, c1);
}

static void px24_byte(PxImage24Model *m, ZState *s, i64 c1) {
  ring_add(&m->lossBuf, m->loss >> 2 > 255 ? 255 : m->loss >> 2);
  m->loss = 0;
#define PX(x, y, c) px24_px(m, s, x, y, c)
  PxNb b;
  b.wwwwww = PX(6, 0, 0);
  b.wwwww = PX(5, 0, 0);
  b.wwww = PX(4, 0, 0);
  const i64 www = PX(3, 0, 0), ww = PX(2, 0, 0), w = PX(1, 0, 0);
  b.nwwww = PX(4, 1, 0);
  b.nwww = PX(3, 1, 0);
  const i64 nww = PX(2, 1, 0), nw = PX(1, 1, 0);
  const i64 n = PX(0, 1, 0), ne = PX(-1, 1, 0), nee = PX(-2, 1, 0),
            neee = PX(-3, 1, 0);
  b.neeee = PX(-4, 1, 0);
  const i64 nnnwww = PX(3, 3, 0), nnwww = PX(3, 2, 0), nnww = PX(2, 2, 0),
            nnw = PX(1, 2, 0);
  const i64 nn = PX(0, 2, 0), nne = PX(-1, 2, 0), nnee = PX(-2, 2, 0),
            nneee = PX(-3, 2, 0);
  const i64 nnnww = PX(2, 3, 0), nnnw = PX(1, 3, 0), nnn = PX(0, 3, 0),
            nnne = PX(-1, 3, 0);
  const i64 nnnee = PX(-2, 3, 0), nnneee = PX(-3, 3, 0);
  b.nnnnw = PX(1, 4, 0);
  b.nnnn = PX(0, 4, 0);
  b.nnnne = PX(-1, 4, 0);
  b.nnnnn = PX(0, 5, 0);
  b.nnnnnn = PX(0, 6, 0);
  const i64 wwp1 = PX(2, 0, 1), wp1 = PX(1, 0, 1), p1 = PX(0, 0, 1);
  const i64 nwp1 = PX(1, 1, 1), np1 = PX(0, 1, 1);
  const i64 nep1 = PX(-1, 1, 1), nnp1 = PX(0, 2, 1);
  const i64 nnnp1 = PX(0, 3, 1), wwwp1 = PX(3, 0, 1);
  const i64 nnwp1 = PX(1, 2, 1), nnep1 = PX(-1, 2, 1);
  const i64 nwwp1 = PX(2, 1, 1), neep1 = PX(-2, 1, 1);
  const i64 nneep1 = PX(-2, 2, 1);
  const i64 wwp2 = PX(2, 0, 2), wp2 = PX(1, 0, 2), p2 = PX(0, 0, 2);
  const i64 nwp2 = PX(1, 1, 2), np2 = PX(0, 1, 2);
  const i64 nep2 = PX(-1, 1, 2), nnp2 = PX(0, 2, 2);
  const i64 wwwp2 = PX(3, 0, 2);
  const i64 nnwp2 = PX(1, 2, 2), nnep2 = PX(-1, 2, 2);
  const i64 nnwwp2 = PX(2, 2, 2), nneep2 = PX(-2, 2, 2);
  b.nnnnww = PX(2, 4, 0);
  b.nnwwww = PX(4, 2, 0);
  b.nnnnee = PX(-2, 4, 0);
  b.nneeee = PX(-4, 2, 0);
  b.nnnnnnee = PX(-2, 6, 0);
  b.nnnnwwww = PX(4, 4, 0);
  b.nnnneeee = PX(-4, 4, 0);
  b.neeeeee = PX(-6, 1, 0);
  b.nnnwwww = PX(4, 3, 0);
  const i64 nnneeee = PX(-4, 3, 0);
  b.neeeee = PX(-5, 1, 0);
  b.neeeeeee = PX(-7, 1, 0);
#undef PX
  b.www = www;
  b.ww = ww;
  b.w = w;
  b.nww = nww;
  b.nw = nw;
  b.n = n;
  b.ne = ne;
  b.nee = nee;
  b.neee = neee;
  b.nnnwww = nnnwww;
  b.nnwww = nnwww;
  b.nnww = nnww;
  b.nnw = nnw;
  b.nn = nn;
  b.nne = nne;
  b.nnee = nnee;
  b.nneee = nneee;
  b.nnnww = nnnww;
  b.nnnw = nnnw;
  b.nnn = nnn;
  b.nnne = nnne;
  b.nnnee = nnnee;
  b.nnneee = nnneee;
  b.nnneeee = nnneeee;
  m->ww = ww;
  m->w1 = w;
  m->nw = nw;
  m->n = n;
  m->ne = ne;
  m->nn = nn;
  m->nne = nne;
  m->nnee = nnee;
  m->nee = nee;
  m->nnw = nnw;
  m->nnww = nnww;
  m->nnn = nnn;
  m->www = www;
  m->nww = nww;
  m->p1 = p1;
  m->p2 = p2;
  m->np1 = np1;
  m->np2 = np2;
  m->wp1 = wp1;
  m->wp2 = wp2;
  m->nep1 = nep1;
  m->nep2 = nep2;
  m->nwp1 = nwp1;
  m->nwp2 = nwp2;
  m->nnp1 = nnp1;
  m->nnp2 = nnp2;
  m->wwp1 = wwp1;
  m->wwp2 = wwp2;

  // Mixer context: edge direction.
  i64 scoreVert = (2 * rabs(n, nn * 2 - nnn) + rabs(w, nw * 2 - nnw) +
                   rabs(ne, nne * 2 - nnne)) /
                  4;
  i64 scoreHoriz = (2 * rabs(w, ww * 2 - www) + rabs(n, nw * 2 - nww)) / 3;
  i64 scoreDiag1 = (2 * rabs(nw, nnww * 2 - nnnwww) +
                    rabs(n, nnw * 2 - nnnww) + rabs(w, nww * 2 - nnwww)) /
                   4;
  i64 scoreDiag2 = (2 * rabs(ne, nnee * 2 - nnneee) +
                    rabs(n, nne * 2 - nnnee) + rabs(nee, nneee * 2 - nnneeee)) /
                   4;
  i64 best = scoreVert;
  m->bestDir = 0;
  if (scoreHoriz < best) {
    best = scoreHoriz;
    m->bestDir = 1;
  }
  if (scoreDiag1 < best) {
    best = scoreDiag1;
    m->bestDir = 2;
  }
  if (scoreDiag2 < best) {
    best = scoreDiag2;
    m->bestDir = 3;
  }
  m->bestRes = diffQt(0, best);

  i64 lq = px24_ls(m, 1, 0) + px24_ls(m, 0, 1) + px24_ls(m, 2, 0) +
           px24_ls(m, 0, 2) + px24_ls(m, 1, 1) + px24_ls(m, -1, 1);
  if (lq > 639) lq = 639;
  m->lossQ = lq;

  // Errors of the predictions of the last byte.
  i64 lowest = 255, bestIdx = 0;
  i32 *pr = m->pred;
  for (i64 i = NP24 - 1; i >= 0; i--) {
    i64 p = sx16(pr[i]);
    i64 d = iabs(c1 - p);
    ring_add(&m->errBuf, d & 255);
    if (d < lowest) {
      lowest = d;
      bestIdx = i;
    }
  }
  ring_add(&m->bestBuf, bestIdx);

  i64 i = 0;
  // p1-based predictors.
  mc(pr, i++, p1);
  mt(pr, i++, p1, np1, n);
  ms(pr, i++, p1, np1, n);
  mp(pr, i++, p1, np1, n);
  mt(pr, i++, p1, wp1, w);
  ms(pr, i++, p1, wp1, w);
  mp(pr, i++, p1, wp1, w);
  mt(pr, i++, p1, nep1, ne);
  mp(pr, i++, p1, nep1, ne);
  mt(pr, i++, p1, nnp1, nn);
  mp(pr, i++, p1, nnp1, nn);
  mt(pr, i++, p1, nwp1, nw);
  ms(pr, i++, p1, nwp1, nw);
  mp(pr, i++, p1, nwp1, nw);
  mt(pr, i++, p1, wwp1, ww);
  mp(pr, i++, p1, wwp1, ww);
  ms(pr, i++, p1, nneep1, ne);
  mt(pr, i++, p1, (-3 * wwp1 + 8 * wp1 + (neep1 * 2 - nneep1)) / 6,
     (-3 * ww + 8 * w + (nee * 2 - nnee)) / 6);
  mt(pr, i++, p1, avg2(wwp1, neep1 * 2 - nneep1), avg2(ww, nee * 2 - nnee));
  mt(pr, i++, p1, wp1 + np1 - nwp1, w + n - nw);
  mt(pr, i++, p1, np1 + nwp1 - nnwp1, n + nw - nnw);
  mt(pr, i++, p1, np1 + nep1 - nnep1, n + ne - nne);
  mt(pr, i++, p1, np1 + nnp1 - nnnp1, n + nn - nnn);
  mt(pr, i++, p1, wp1 + wwp1 - wwwp1, w + ww - www);
  mt(pr, i++, p1, wp1 + neep1 - nep1, w + nee - ne);
  mt(pr, i++, p1, np1 * 2 - nnp1, n * 2 - nn);
  mt(pr, i++, p1, wp1 * 2 - wwp1, w * 2 - ww);
  mt(pr, i++, p1, wp1 + nep1 - np1, w + ne - n);
  mt(pr, i++, p1, nep1 + nwp1 - nnp1, ne + nw - nn);
  mt(pr, i++, p1, nwp1 + wp1 - nwwp1, nw + w - nww);
  // p2-based predictors.
  mc(pr, i++, p2);
  mt(pr, i++, p2, np2, n);
  ms(pr, i++, p2, np2, n);
  mt(pr, i++, p2, wp2, w);
  ms(pr, i++, p2, wp2, w);
  mt(pr, i++, p2, nep2, ne);
  mt(pr, i++, p2, nnp2, nn);
  ms(pr, i++, p2, nwp2, nw);
  mt(pr, i++, p2, wwp2, ww);
  ms(pr, i++, p2, nneep2, ne);
  mt(pr, i++, p2, wp2 + np2 - nwp2, w + n - nw);
  mt(pr, i++, p2, np2 + nwp2 - nnwp2, n + nw - nnw);
  mt(pr, i++, p2, np2 + nep2 - nnep2, n + ne - nne);
  mt(pr, i++, p2, wp2 + wwp2 - wwwp2, w + ww - www);
  mt(pr, i++, p2, np2 * 2 - nnp2, n * 2 - nn);
  mt(pr, i++, p2, wp2 * 2 - wwp2, w * 2 - ww);
  mt(pr, i++, p2, nwp2 * 2 - nnwwp2, nw * 2 - nnww);
  mt(pr, i++, p2, nep2 * 2 - nneep2, ne * 2 - nnee);
  // The current color plane only.
  i = planePredictors(pr, i, &b);

  i64 c = m->color;
  m->lossQ4 = c == 2 ? (lq < 1 ? lq : pmin(1 + (lq - 1) / 40, 7))
                     : (c == 1 ? (lq < 8 ? lq >> 2 : pmin(2 + (lq - 8) / 40, 7))
                               : pmin(lq / 40, 7));
  for (i64 j = 0; j < NRM24; j++) {
    i64 v = pr[j];
    i64 spread = v >> 16;
    i64 p = sx16(v);
    i64 ea = px24_predErrAvg(m, j);
    residualmap_set(&m->r1, p, (pmin(ea, 31) << 2) | c);
    residualmap_set(&m->r2, p, (m->lossQ4 << 2) | c);
    residualmap_set(&m->r3, p, (pmin(spread, 31) << 2) | c);
  }
  // Least squares fits per plane.
  i32 *nb = m->nb;
  nb[0] = (i32)b.wwwwww;
  nb[1] = (i32)b.wwwww;
  nb[2] = (i32)b.wwww;
  nb[3] = (i32)www;
  nb[4] = (i32)ww;
  nb[5] = (i32)w;
  nb[6] = (i32)b.nwwww;
  nb[7] = (i32)b.nwww;
  nb[8] = (i32)nww;
  nb[9] = (i32)nw;
  nb[10] = (i32)n;
  nb[11] = (i32)ne;
  nb[12] = (i32)nee;
  nb[13] = (i32)neee;
  nb[14] = (i32)b.neeee;
  nb[15] = (i32)nnwww;
  nb[16] = (i32)nnww;
  nb[17] = (i32)nnw;
  nb[18] = (i32)nn;
  nb[19] = (i32)nne;
  nb[20] = (i32)nnee;
  nb[21] = (i32)nneee;
  nb[22] = (i32)nnnww;
  nb[23] = (i32)nnnw;
  nb[24] = (i32)nnn;
  nb[25] = (i32)nnne;
  nb[26] = (i32)nnnee;
  nb[27] = (i32)b.nnnnw;
  nb[28] = (i32)b.nnnn;
  nb[29] = (i32)b.nnnne;
  nb[30] = (i32)b.nnnnn;
  nb[31] = (i32)b.nnnnnn;
  nb[32] = (i32)p1;
  nb[33] = (i32)p2;
  i64 k = c > 0 ? c - 1 : m->stride - 1;
  double p1d = (double)p1;
  for (i64 j = 0; j < NOLS24; j++) {
    ols_update(&m->ols[j][k], p1d);
    Ols *o = &m->ols[j][c];
    const u8 *t = kOlsIdx[j];
    for (i64 q = 0; q < kOlsIdxLen[j]; q++) ols_add(o, (double)nb[t[q]]);
    i64 p = roundShort(ols_predict(o));
    mc(pr, NRM24 + j, p);
    i64 ea = px24_predErrAvg(m, NRM24 + j);
    residualmap_set(&m->o1, p, (pmin(ea, 31) << 2) | c);
    residualmap_set(&m->o2, p, (m->lossQ4 << 2) | c);
  }

  // Hashed contexts (non-photographic images).
  i64 h = c * 1024;
  ContextMap *cm = &m->cm;
  i64 j = 0;
#define SET(x)                     \
  do {                             \
    h++;                           \
    contextmap_set(cm, j, (x));    \
    j++;                           \
  } while (0)
  SET(hash3(h, w, p1));
  SET(hash3(h, w, p2));
  SET(hash3(h, n, p1));
  SET(hash3(h, n, p2));
  SET(hash3(h, p1, p2));
  SET(hash4(h, n, nn, p1));
  SET(hash4(h, n, nn, p2));
  SET(hash4(h, w, ww, p1));
  SET(hash4(h, w, ww, p2));
  SET(h5(h, n, w, p1, p2));
  SET(hash4(h, w, p1 - wp1, p2 - wp2));
  SET(hash4(h, n, p1 - np1, p2 - np2));
  SET(hash4(h, nw, p1 - nwp1, p2 - nwp2));
  SET(hash4(h, ne, p1 - nep1, p2 - nep2));
  SET(h5(h, w, ww, n, nn));
  SET(h5(h, w, n, ne, nw));
  SET(hash3(h, (nnn + n + 4) >> 3, (n * 3 - nn * 3 + nnn) >> 1));
  SET(h6(h, (w + n - nw) >> 1, (w + p1 - wp1) >> 3, (w + p2 - wp2) >> 3,
         (n + p1 - np1) >> 3, (n + p2 - np2) >> 3));
  SET(hash4(h, w >> 2, diffQt(w, p1), diffQt(w, p2)));
  SET(hash4(h, n >> 2, diffQt(n, p1), diffQt(n, p2)));
  SET(hash4(h, (w + n + 4) >> 3, p1 >> 4, p2 >> 4));
  SET(hash3(h, (n * 2 - nn) >> 1, diffQt(n, nn * 2 - nnn)));
  SET(hash3(h, (w * 2 - ww) >> 1, diffQt(w, ww * 2 - www)));
  SET(hash3(h, n * 2 - nn, diffQt(w, nw * 2 - nnw)));
  SET(hash3(h, w * 2 - ww, diffQt(n, nw * 2 - nww)));
  SET(hash3(h, (w + nee + 1) >> 1, diffQt(w, (ww + ne + 1) >> 1)));
  SET(hash3(h, w + nee - ne, diffQt(w, ww + ne - n)));
  i64 xs = m->x / m->stride;
  i64 div7 = pmax(xs >> 10, 7);
  i64 div17 = pmax(xs >> 9, 17);
  i64 div29 = pmax(xs >> 8, 29);
  SET(hash3(h, m->w, xs / div7));
  SET(hash4(h, m->w, xs / div17, m->line / 17));
  SET(hash4(h, m->w, xs / div29, (w + n - nw) >> 1));
  SET(h5(h, m->w, xs / div29, w >> 2, ne >> 2));
#undef SET

  // paq8px keeps the (N > NN) >> 3 of its source: always 0.
  m->ctx0 = (rabs(w, nw) > 3 ? 256 : 0) | (rabs(nw, n) > 3 ? 128 : 0) |
            (rabs(n, ne) > 3 ? 64 : 0) | (n > nw ? 32 : 0) |
            (n > ne ? 16 : 0) | (w > n ? 4 : 0) | (w > nw ? 2 : 0) |
            (w > ww ? 1 : 0);
  m->ctx1 = (diffQt(p1, np1 + nep1 - nnep1) << 4) |
            diffQt(n + ne - nne, n + nw - nnw);
}

static void px24_mix(ZModel *self, ZState *s, Mixer *mx) {
  PxImage24Model *m = (PxImage24Model *)self;
  px24_prepare(&m->px, s);
  i64 bpos = s->bpos;
  i64 c0 = s->c0;
  i64 y = s->y;
  contextmap_mix(&m->cm, mx, y, bpos, c0, s->c4 & 255);
  largestationarymap_update(&m->mapL, y);
  i32 *tx = mx->tx;
  if (m->color == 4) {
    i64 k = mx->nx;
    i64 n = (NRM24 * 3 + NOLS24 * 2) * 2 +
            NLSM24 * LARGESTATIONARYMAP_INPUTS_PER_CONTEXT;
    for (i64 i = 0; i < n; i++) tx[k++] = 0;
    mx->nx = k;
    mixer_add(mx, -2047);
    return;
  }
  residualmap_mix(&m->r1, mx, bpos, c0);
  residualmap_mix(&m->r2, mx, bpos, c0);
  residualmap_mix(&m->r3, mx, bpos, c0);
  residualmap_mix(&m->o1, mx, bpos, c0);
  residualmap_mix(&m->o2, mx, bpos, c0);
  // Bit contexts of the pixel neighborhood.
  const i64 w = m->w1, n = m->n, nw = m->nw, ne = m->ne, nn = m->nn,
            ww = m->ww;
  const i64 p1 = m->p1, p2 = m->p2;
  const i64 np1 = m->np1, np2 = m->np2, nep1 = m->nep1, nep2 = m->nep2;
  LargeStationaryMap *mapL = &m->mapL;
  i64 i = ((c0 << 2) | m->color) * 256;
#define L(x)                              \
  do {                                    \
    i++;                                  \
    largestationarymap_set(mapL, (x));    \
  } while (0)
  L(hash2(i, p2));
  L(hash3(i, p1, p2));
  L(hash3(i, w, p2));
  L(hash4(i, w, p1, p2));
  L(hash4(i, n, np1, np2));
  L(h6(i, w, p1, p2, n, np1));
  L(h7(i, w, p1, p2, n, np1, np2));
  L(h5(i, w, p1, p2, ne));
  L(h6(i, w, p1, p2, ne, nep1));
  L(h7(i, w, p1, p2, ne, nep1, nep2));
  L(hash4(i, n, ne, p1));
  L(hash4(i, nw, ne, p1));
  L(hash4(i, nw, ne, p2));
  L(hash4(i, nw, nn, p1));
  L(h5(i, w, n, ne, p1));
  L(h5(i, w, n, nw, p1));
  L(h6(i, n, np1, ne, nw, p1));
  L(hash4(i, ne, m->nee, p1));
  L(hash4(i, ne, m->nee, p2));
  L(h5(i, ne, nep1, nep2, m->nee));
  L(hash4(i, nn, m->nnn, p1));
  L(hash4(i, nn, m->nnn, p2));
  L(h5(i, nn, m->nnp1, m->nnp2, m->nnn));
  L(h5(i, ww, m->wwp1, m->wwp2, m->www));
  L(h5(i, np1, np2, m->wp1, m->wp2));
  L(h5(i, m->nwp1, m->nwp2, nep1, nep2));
  L(hash3(i, (w + n - nw) >> 1, p1));
  L(hash4(i, (w + n - nw) >> 1, p1, p2));
  L(hash3(i, (n + ne - m->nne) >> 1, p1));
  L(hash4(i, (n + ne - m->nne) >> 1, p1, p2));
  L(hash3(i, (w * 2 - ww) >> 1, p1));
  L(hash3(i, (n * 2 - nn) >> 1, p1));
  L(hash4(i, (w * 2 - ww) >> 1, p1, p2));
  L(hash4(i, (n * 2 - nn) >> 1, p1, p2));
  L(hash3(i, (nw + w - m->nww) >> 1, p1));
  L(hash4(i, (nw + w - m->nww) >> 1, p1, p2));
  L(hash3(i, (nw + n - m->nnw) >> 1, p1));
  L(hash4(i, (nw + n - m->nnw) >> 1, p1, p2));
  L(hash3(i, paeth(w, n, nw) >> 1, p1));
  L(hash4(i, paeth(w, n, nw) >> 1, p1, p2));
#undef L
  largestationarymap_mix(mapL, mx);
  mixer_add(mx, 0);
}

static void px24_setCtx(ZModel *self, ZState *s, Mixer *mx) {
  PxImage24Model *m = (PxImage24Model *)self;
  if (m->color == 4) {
    for (int i = 0; i < 20; i++) mixer_set(mx, 0);
    return;
  }
  i64 bpos = s->bpos;
  i64 c0 = s->c0;
  i64 bp = (0x33322210 >> (bpos << 2)) & 0xF;
  i64 xs = m->x / m->stride;
  i64 line = m->line;
  mixer_set(mx, 1 + bpos);
  mixer_set(mx, m->lossQ4);
  mixer_set(mx, ((line & 7) << 3) | bpos);
  mixer_set(mx, ((xs & 7) << 3) | (line & 7));
  mixer_set(mx, xs & 15);
  mixer_set(mx, (xs / pmax(xs >> 9, 3)) & 511);
  mixer_set(mx, (xs / pmax(xs >> 8, 19)) & 255);
  i64 n = m->n, w = m->w1;
  i64 pred1 = 0x100 | ((n + w + 1) >> 1);
  i64 pred2 = 0x100 | sx8(n + w - m->nw);
  i64 pred3 = 0x100 | sx8(2 * n - m->nn);
  i64 pred4 = 0x100 | sx8(2 * w - m->ww);
  i64 sh = 8 - bpos;
  mixer_set(mx, ((c0 == (pred1 >> sh)) ? 64 : 0) |
                    ((c0 == (pred2 >> sh)) ? 32 : 0) |
                    ((c0 == (pred3 >> sh)) ? 16 : 0) |
                    ((c0 == (pred4 >> sh)) ? 8 : 0) | bpos);
  mixer_set(mx, (m->lossQ4 << 2) | bp);
  mixer_set(mx, (m->ctx1 << 2) | bp);
  mixer_set(mx, (m->bestDir << 3) | m->bestRes);
  mixer_set(mx, ((xs + line) >> 5) & 255);
  const PxRing *bb = &m->bestBuf;
  i64 bw = m->color == 0 ? ring_back(bb, m->stride) : ring_back(bb, 1);
  i64 bn = ring_back(bb, m->w);
  mixer_set(mx, bw);
  mixer_set(mx, bn);
  mixer_set(mx, (pmin(31, px24_predErrAvg(m, bw)) << 5) |
                    pmin(31, px24_predErrAvg(m, bn)));
  i64 bne = ring_back(bb, m->w + m->stride);
  i64 bnw = ring_back(bb, m->w - m->stride);
  mixer_set(mx, (pmin(31, px24_predErrAvg(m, bne)) << 5) |
                    pmin(31, px24_predErrAvg(m, bnw)));
  mixer_set(mx, m->ctx0 >> 6);
  mixer_set(mx, ((m->ctx0 & 0x3F) << 3) | m->lossQ4);
  i64 tn = 2 * n - m->nn, tw = 2 * w - m->ww;
  i64 tne = 2 * m->ne - m->nnee, tnw = 2 * m->nw - m->nnww;
  i64 tmin = pmin(pmin(pmin(tn, tw), tne), tnw);
  i64 tmax = pmax(pmax(pmax(tn, tw), tne), tnw);
  mixer_set(mx, ((pmin(tmax - tmin, 255) >> 2) << 2) | (bpos >> 1));
  mixer_set(mx, ((m->p1 >> 5) << 5) | ((m->p2 >> 5) << 2) | (bpos >> 1));
}

// ---------------------------------------------------------------- PxImage8Model

#define NRM8 PXIMAGE8_NRM
#define NOLS8 PXIMAGE8_NOLS
#define NCM8 PXIMAGE8_NCM
#define NP8 PXIMAGE8_NP

static const double kLambda8[NOLS8] = {0.996, 0.87, 0.93, 0.8, 0.9};
static const i64 kNum8[NOLS8] = {32, 12, 15, 10, 14};
static const i64 kSel8[8] = {512, 16, 32, 255, 1024, 64, 128, 256};

static i64 px8_fixedBytes(void) {
  return ((i64)NRM8 * ((1 << 5) * 2 + (1 << 3)) +
          (i64)NOLS8 * ((1 << 5) + (1 << 3))) *
             512 +
         (1 << 15) * 4;
}

static i64 px8_cmBytes(i64 allowance) {
  i64 b = allowance - px8_fixedBytes();
  return floorPow2(b < (1 << 20) ? 1 << 20 : b);
}

i64 pximage8model_tableBytes(i64 allowance) {
  return px8_fixedBytes() + px8_cmBytes(allowance);
}

static i64 px8_plane(const PxImageModel *s) {
  (void)s;
  return 0;
}
static i64 px8_lossQ(const PxImageModel *s) {
  return ((const PxImage8Model *)s)->lossQ;
}
static i64 px8_sseCtx(const PxImageModel *s) {
  return ((const PxImage8Model *)s)->ctx >> 1;
}
static i64 px8_pxW(const PxImageModel *s) {
  return ((const PxImage8Model *)s)->pw;
}
static i64 px8_pxN(const PxImageModel *s) {
  return ((const PxImage8Model *)s)->pn;
}
static i64 px8_pxWW(const PxImageModel *s) {
  return ((const PxImage8Model *)s)->pww;
}
static i64 px8_pxNN(const PxImageModel *s) {
  return ((const PxImage8Model *)s)->pnn;
}

static void px8_prepare(PxImageModel *self, ZState *s);
static void px8_mix(ZModel *self, ZState *s, Mixer *m);
static void px8_setCtx(ZModel *self, ZState *s, Mixer *m);

void pximage8model_init(PxImage8Model *m, i64 allowance) {
  memset(m, 0, sizeof *m);
  contextmap_init(&m->cm, px8_cmBytes(allowance), NCM8, 1, 0);
  stationarymap_init(&m->map0, 0, 8, 64);
  stationarymap_init(&m->map1, 15, 1, 64);
  residualmap_init(&m->r1, NRM8, 1 << 5, 74);
  residualmap_init(&m->r2, NRM8, 1 << 3, 74);
  residualmap_init(&m->r3, NRM8, 1 << 5, 74);
  residualmap_init(&m->o1, NOLS8, 1 << 5, 74);
  residualmap_init(&m->o2, NOLS8, 1 << 3, 74);
  for (int i = 0; i < NOLS8; i++) ols_init(&m->ols[i], kNum8[i], 1, kLambda8[i]);
  ring_init(&m->errBuf);
  ring_init(&m->lossBuf);
  m->info = m->type = -1;
  m->w = 1;
  m->columns0 = m->columns1 = 1;
  m->lastBpos = m->lastPos = -1;
  m->px.finalP = 32768;
  m->px.prepare = px8_prepare;
  m->px.plane = px8_plane;
  m->px.lossQ = px8_lossQ;
  m->px.sseCtx = px8_sseCtx;
  m->px.pxW = px8_pxW;
  m->px.pxN = px8_pxN;
  m->px.pxWW = px8_pxWW;
  m->px.pxNN = px8_pxNN;
  m->px.base.inputs = NCM8 * contextmap_inputsPerContext(&m->cm) + 2 * 3 +
                      (NRM8 * 3 + NOLS8 * 2) * 2 + 1;
  m->px.base.mix = px8_mix;
  m->px.base.nsel = 8;
  m->px.base.selSizes = kSel8;
  m->px.base.setCtx = px8_setCtx;
}

static void px8_initSegment(PxImage8Model *m) {
  m->w = m->info & 0xFFFFFF;
  if (m->w < 1) m->w = 1;
  i64 l0 = ilog2(m->w) * 2;
  m->columns0 = pmax(1, m->w / pmax(1, l0));
  m->columns1 = pmax(1, m->columns0 / pmax(1, ilog2(m->columns0)));
  ring_setSize(&m->lossBuf, 3 * m->w, 255);
  ring_setSize(&m->errBuf, 3 * m->w * NP8, 255);
}

ZINLINE i64 px8_ls(const PxImage8Model *m, i64 relX, i64 relY) {
  if (m->line - relY < 0) return 255;
  if (m->x - relX < 0 || m->x - relX >= m->w) return 255;
  return ring_back(&m->lossBuf, relY * m->w + relX);
}

ZINLINE i64 px8_predErr(const PxImage8Model *m, i64 i, i64 relX, i64 relY) {
  if (m->line - relY < 0) return 255;
  if (m->x - relX < 0 || m->x - relX >= m->w) return 255;
  return ring_back(&m->errBuf, (relY * m->w + relX - 1) * NP8 + i + 1);
}

static i64 px8_predErrAvg(const PxImage8Model *m, i64 i) {
  return (2 * px8_predErr(m, i, 1, 0) + 2 * px8_predErr(m, i, 0, 1) +
          px8_predErr(m, i, -1, 1) + px8_predErr(m, i, 1, 1) +
          px8_predErr(m, i, 2, 0) + px8_predErr(m, i, 0, 2)) >>
         3;
}

static void px8_byte(PxImage8Model *m, ZState *s, i64 c1);

static void px8_prepare(PxImageModel *self, ZState *s) {
  PxImage8Model *m = (PxImage8Model *)self;
  i64 bpos = s->bpos;
  i64 pos = s->pos;
  if (bpos == m->lastBpos && pos == m->lastPos) return;
  m->lastBpos = bpos;
  m->lastPos = pos;
  i64 p = m->px.finalP;
  m->loss += (s->y == 0 ? p : 65535 - p) >> 10;
  if (bpos != 0) return;
  i64 c1 = s->c4 & 255;
  residualmap_update(&m->r1, c1);
  residualmap_update(&m->r2, c1);
  residualmap_update(&m->r3, c1);
  residualmap_update(&m->o1, c1);
  residualmap_update(&m->o2, c1);
  if (s->blockType != m->type || s->blockInfo != m->info || s->blockPos == 0) {
    m->type = s->blockType;
    m->info = s->blockInfo;
    px8_initSegment(m);
    i64 k = s->blockPos;
    m->x = k % m->w;
    m->line = k / m->w;
  } else {
    m->x++;
    if (m->x >= m->w) {
      m->x = 0;
      m->line++;
    }
  }
  px8_byte(m, s, c1);
}

static void px8_byte(PxImage8Model *m, ZState *s, i64 c1) {
  const i64 wd = m->w;
#define B(i) zstate_back(s, (i))
  PxNb b;
  b.wwwww = B(5);
  b.wwww = B(4);
  const i64 www = B(3), ww = B(2), w = B(1);
  b.nwwww = B(wd + 4);
  b.nwww = B(wd + 3);
  const i64 nww = B(wd + 2);
  const i64 nw = B(wd + 1), n = B(wd), ne = B(wd - 1), nee = B(wd - 2);
  b.neee = B(wd - 3);
  b.neeee = B(wd - 4);
  b.nnwww = B(wd * 2 + 3);
  const i64 nnww = B(wd * 2 + 2), nnw = B(wd * 2 + 1);
  const i64 nn = B(wd * 2), nne = B(wd * 2 - 1), nnee = B(wd * 2 - 2);
  b.nneee = B(wd * 2 - 3);
  b.nnnww = B(wd * 3 + 2);
  b.nnnw = B(wd * 3 + 1);
  const i64 nnn = B(wd * 3);
  b.nnne = B(wd * 3 - 1);
  b.nnnee = B(wd * 3 - 2);
  b.nnnnw = B(wd * 4 + 1);
  b.nnnn = B(wd * 4);
  b.nnnne = B(wd * 4 - 1);
  b.nnnnn = B(wd * 5);
  b.nnnnnn = B(wd * 6);
  b.wwwwww = B(6);
  b.nnwwww = B(2 * wd + 4);
  b.nnnwww = B(3 * wd + 3);
  b.nnnwwww = B(3 * wd + 4);
  b.nnnnww = B(4 * wd + 2);
  b.nnnnwwww = B(4 * wd + 4);
  b.neeeee = B(wd - 5);
  b.neeeeee = B(wd - 6);
  b.nneeee = B(2 * wd - 4);
  b.nnneee = B(3 * wd - 3);
  b.nnnnee = B(4 * wd - 2);
  b.nnnneeee = B(4 * wd - 4);
  b.nnnnnnee = B(6 * wd - 2);
  b.neeeeeee = B(wd - 7);
#undef B
  b.www = www;
  b.ww = ww;
  b.w = w;
  b.nww = nww;
  b.nw = nw;
  b.n = n;
  b.ne = ne;
  b.nee = nee;
  b.nnww = nnww;
  b.nnw = nnw;
  b.nn = nn;
  b.nne = nne;
  b.nnee = nnee;
  b.nnn = nnn;
  b.nnneeee = 0;
  m->pw = w;
  m->pn = n;
  m->pnw = nw;
  m->pne = ne;
  m->pww = ww;
  m->pnn = nn;
  m->pnnw = nnw;
  m->pnne = nne;
  m->pnnee = nnee;
  m->pnnww = nnww;

  ContextMap *cm = &m->cm;
  i64 h = 1024;
  i64 j = 0;
#define SET(x)                     \
  do {                             \
    h++;                           \
    contextmap_set(cm, j, (x));    \
    j++;                           \
  } while (0)
  SET(hash3(h, n, m->line & 3));

  ring_add(&m->lossBuf, m->loss >> 2 > 255 ? 255 : m->loss >> 2);
  m->loss = 0;
  i64 lq = px8_ls(m, 1, 0) + px8_ls(m, 0, 1) + px8_ls(m, 2, 0) +
           px8_ls(m, 0, 2) + px8_ls(m, 1, 1) + px8_ls(m, -1, 1);
  if (lq > 639) lq = 639;
  m->lossQ = lq;
  i32 *pr = m->pred;
  for (i64 i = NP8 - 1; i >= 0; i--) {
    ring_add(&m->errBuf, iabs(c1 - sx16(pr[i])) & 255);
  }
  // The predictors of paq8px's gray model are those of the planes.
  planePredictors(pr, 0, &b);
  i64 lq4 = pmin(lq / 40, 7);
  for (i64 i = 0; i < NRM8; i++) {
    i64 v = pr[i];
    i64 p = sx16(v);
    residualmap_set(&m->r1, p, pmin(px8_predErrAvg(m, i), 31));
    residualmap_set(&m->r2, p, lq4);
    residualmap_set(&m->r3, p, pmin(v >> 16, 31));
  }
  i32 *nb = m->nb;
  nb[0] = (i32)b.wwwwww;
  nb[1] = (i32)b.wwwww;
  nb[2] = (i32)b.wwww;
  nb[3] = (i32)www;
  nb[4] = (i32)ww;
  nb[5] = (i32)w;
  nb[6] = (i32)b.nwwww;
  nb[7] = (i32)b.nwww;
  nb[8] = (i32)nww;
  nb[9] = (i32)nw;
  nb[10] = (i32)n;
  nb[11] = (i32)ne;
  nb[12] = (i32)nee;
  nb[13] = (i32)b.neee;
  nb[14] = (i32)b.neeee;
  nb[15] = (i32)b.nnwww;
  nb[16] = (i32)nnww;
  nb[17] = (i32)nnw;
  nb[18] = (i32)nn;
  nb[19] = (i32)nne;
  nb[20] = (i32)nnee;
  nb[21] = (i32)b.nneee;
  nb[22] = (i32)b.nnnww;
  nb[23] = (i32)b.nnnw;
  nb[24] = (i32)nnn;
  nb[25] = (i32)b.nnne;
  nb[26] = (i32)b.nnnee;
  nb[27] = (i32)b.nnnnw;
  nb[28] = (i32)b.nnnn;
  nb[29] = (i32)b.nnnne;
  nb[30] = (i32)b.nnnnn;
  nb[31] = (i32)b.nnnnnn;
  double wd0 = (double)w;
  for (i64 k = 0; k < NOLS8; k++) {
    Ols *o = &m->ols[k];
    ols_update(o, wd0);
    const u8 *t = kOlsIdx[k];
    for (i64 q = 0; q < kOlsIdxLen[k]; q++) ols_add(o, (double)nb[t[q]]);
    i64 p = roundShort(ols_predict(o));
    pr[NRM8 + k] = (i32)clip8(p);
    residualmap_set(&m->o1, p, pmin(px8_predErrAvg(m, NRM8 + k), 31));
    residualmap_set(&m->o2, p, lq4);
  }

  SET(hash2(h, n));
  SET(hash2(h, nw));
  SET(hash2(h, ne));
  SET(hash3(h, n, nn));
  SET(hash3(h, ne, nnee));
  SET(hash3(h, nw, nnww));
  SET(hash3(h, w, nee));
  SET(hash4(h, n, nn, nnn));
  SET(h5(h, w, ww, n, nn));
  SET(h5(h, w, n, ne, nw));
  SET(hash3(h, (nnn + n + 4) >> 3, (n * 3 - nn * 3 + nnn) >> 1));
  SET(hash3(h, (n * 2 - nn) >> 1, diffQt(n, nn * 2 - nnn)));
  SET(hash3(h, (w * 2 - ww) >> 1, diffQt(w, ww * 2 - www)));
  SET(hash3(h, n * 2 - nn, diffQt(w, nw * 2 - nnw)));
  SET(hash3(h, w * 2 - ww, diffQt(n, nw * 2 - nww)));
  SET(hash3(h, (w + nee + 1) >> 1, diffQt(w, (ww + ne + 1) >> 1)));
  SET(hash3(h, w + nee - ne, diffQt(w, ww + ne - n)));
  i64 x = m->x;
  i64 div7 = pmax(x >> 10, 7);
  i64 div17 = pmax(x >> 9, 17);
  i64 div29 = pmax(x >> 8, 29);
  SET(hash3(h, wd, x / div7));
  SET(hash4(h, wd, x / div17, m->line / 17));
  SET(hash4(h, wd, x / div29, ((w + n - nw) & 255) >> 1));
  SET(h5(h, wd, w >> 2, ne >> 2, x / div29));
#undef SET

  m->ctx = pmin(0x1F, x / pmax(1, wd / pmin(32, m->columns0))) |
           ((((iabs(w - n) * 16 > w + n) ? 2 : 0) |
             (iabs(n - nw) > 8 ? 1 : 0))
            << 5) |
           ((w + n) & 0x180);
  m->res = clamp4(w + n - nw, w, nw, n, ne);
}

static void px8_mix(ZModel *self, ZState *s, Mixer *mx) {
  PxImage8Model *m = (PxImage8Model *)self;
  px8_prepare(&m->px, s);
  i64 bpos = s->bpos;
  i64 c0 = s->c0;
  i64 y = s->y;
  contextmap_mix(&m->cm, mx, y, bpos, c0, s->c4 & 255);
  stationarymap_update(&m->map0, y);
  stationarymap_update(&m->map1, y);
  i64 b = (c0 << (8 - bpos)) & 255;
  stationarymap_set(&m->map0, 0);
  stationarymap_set(&m->map1,
                    (((clip8(m->pw + m->pn - m->pnw) - b) & 255) * 8 + bpos) |
                        (diffQt(clip8(m->pn + m->pne - m->pnne),
                                clip8(m->pn + m->pnw - m->pnnw))
                         << 11));
  stationarymap_mix(&m->map0, mx);
  stationarymap_mix(&m->map1, mx);
  residualmap_mix(&m->r1, mx, bpos, c0);
  residualmap_mix(&m->r2, mx, bpos, c0);
  residualmap_mix(&m->r3, mx, bpos, c0);
  residualmap_mix(&m->o1, mx, bpos, c0);
  residualmap_mix(&m->o2, mx, bpos, c0);
  mixer_add(mx, 0);
}

static void px8_setCtx(ZModel *self, ZState *s, Mixer *mx) {
  PxImage8Model *m = (PxImage8Model *)self;
  i64 bpos = s->bpos;
  i64 c0 = s->c0;
  i64 w = m->pw, n = m->pn;
  m->col = (m->col + 1) & 7;
  mixer_set(mx, m->ctx);
  mixer_set(mx, (m->col << 1) | ((c0 == ((0x100 | m->res) >> (8 - bpos))) ? 1 : 0));
  mixer_set(mx, (n + w) >> 4);
  mixer_set(mx, c0 - 1);
  mixer_set(mx, (iabs(w - n) > 4 ? 512 : 0) | (iabs(n - m->pne) > 4 ? 256 : 0) |
                    (iabs(w - m->pnw) > 4 ? 128 : 0) | (w > n ? 64 : 0) |
                    (n > m->pne ? 32 : 0) | (w > m->pnw ? 16 : 0) |
                    (w > m->pww ? 8 : 0) | (n > m->pnn ? 4 : 0) |
                    (m->pnw > m->pnnww ? 2 : 0) | (m->pne > m->pnnee ? 1 : 0));
  mixer_set(mx, pmin(63, m->x / m->columns0));
  mixer_set(mx, pmin(127, m->x / m->columns1));
  mixer_set(mx, pmin(255, (m->x + m->line) / 32));
}
