// zxsfx decoder: port of zcm_image_px.dart (the image models of paq8px as
// whole models, levels 7 to 9, and their SSE stages).
//
// Ports of paq8px's Image24BitModel and Image8BitModel (grayscale part):
// Marcio Pais (from his Emma), Zoltan Gotthardt, Sebastian Lehmann (the
// least squares fits) and the paq8px authors, after the im8/im24 models
// of paq8 by Matt Mahoney.

#ifndef ZC_IMAGE_PX_H
#define ZC_IMAGE_PX_H

#include "zc.h"
#include "zc_maps.h"

// A byte ring buffer (paq8px RingBuffer): back(1) is the last added.
typedef struct {
  u8 *b;
  i64 cap, mask, pos;
} PxRing;

// What the predictor needs from a paq8px image model (Dart PxImageModel).
// The struct of PxImage24Model and PxImage8Model starts with it.
typedef struct PxImageModel PxImageModel;
struct PxImageModel {
  ZModel base;
  // The final probability of the last bit (16 bits), set by the
  // predictor after the SSE: the models keep the coding cost of the
  // pixels. Starts at 32768.
  i64 finalP;
  // Computes the byte contexts (at bpos 0) before the mixer is chosen.
  void (*prepare)(PxImageModel *self, ZState *s);
  i64 (*plane)(const PxImageModel *self); // 0 to 3; 4: row padding
  i64 (*lossQ)(const PxImageModel *self);
  i64 (*sseCtx)(const PxImageModel *self);
  i64 (*pxW)(const PxImageModel *self);
  i64 (*pxN)(const PxImageModel *self);
  i64 (*pxWW)(const PxImageModel *self);
  i64 (*pxNN)(const PxImageModel *self);
};
ZINLINE void pximage_prepare(PxImageModel *m, ZState *s) { m->prepare(m, s); }
ZINLINE i64 pximage_plane(const PxImageModel *m) { return m->plane(m); }
ZINLINE i64 pximage_lossQ(const PxImageModel *m) { return m->lossQ(m); }
ZINLINE i64 pximage_sseCtx(const PxImageModel *m) { return m->sseCtx(m); }
ZINLINE i64 pximage_pxW(const PxImageModel *m) { return m->pxW(m); }
ZINLINE i64 pximage_pxN(const PxImageModel *m) { return m->pxN(m); }
ZINLINE i64 pximage_pxWW(const PxImageModel *m) { return m->pxWW(m); }
ZINLINE i64 pximage_pxNN(const PxImageModel *m) { return m->pxNN(m); }

// The SSE stages of paq8px for images (SSE.cpp, IMAGE24 and IMAGE8GRAY).
typedef struct {
  ApmPx a0, a1, a2, a3;
  Apm1 b1, b2;
  ApmPost postA, postB;
  i64 mask;
  int gray;
} ZcmImageSse;
// [bits]: the bits of the hashed contexts (16 in paq8px).
void zcmimagesse_init(ZcmImageSse *x, i64 bits, int gray);
i64 zcmimagesse_bytesFor(i64 bits, int gray);
// The final probability (16 bits) from the mixer's [pr] (12 bits).
i64 zcmimagesse_p(ZcmImageSse *x, i64 y, i64 pr, i64 c0, i64 bpos, i64 m3,
                  const PxImageModel *img, i64 e);

// paq8px Image24BitModel: 24 and 32-bit pixels.
#define PXIMAGE24_NRM 122
#define PXIMAGE24_NOLS 6
#define PXIMAGE24_NLSM 40
#define PXIMAGE24_NCM 31
#define PXIMAGE24_NP (PXIMAGE24_NRM + PXIMAGE24_NOLS)
typedef struct {
  PxImageModel px;
  ContextMap cm;
  ResidualMap r1, r2, r3, o1, o2;
  LargeStationaryMap mapL;
  Ols ols[PXIMAGE24_NOLS][4];
  i32 pred[PXIMAGE24_NP]; // spread << 16 | prediction
  i32 nb[34];
  PxRing errBuf, lossBuf, bestBuf;
  i64 info, type;
  i64 stride, w, padding;
  i64 x, line, color;
  i64 loss, lossQ, lossQ4;
  i64 ctx0, ctx1;
  i64 bestDir, bestRes;
  i64 lastBpos, lastPos;
  // Neighborhood (paq8px names).
  i64 ww, w1, nw, n, ne, nn, nne;
  i64 nnee, nee, nnw, nnww, nnn, www, nww;
  i64 p1, p2;
  i64 np1, np2, wp1, wp2, nep1, nep2;
  i64 nwp1, nwp2, nnp1, nnp2, wwp1, wwp2;
} PxImage24Model;
void pximage24model_init(PxImage24Model *m, i64 allowance);
i64 pximage24model_tableBytes(i64 allowance);

// paq8px Image8BitModel, grayscale part.
#define PXIMAGE8_NRM 74
#define PXIMAGE8_NOLS 5
#define PXIMAGE8_NCM 22
#define PXIMAGE8_NP (PXIMAGE8_NRM + PXIMAGE8_NOLS)
typedef struct {
  PxImageModel px;
  ContextMap cm;
  StationaryMap map0, map1;
  ResidualMap r1, r2, r3, o1, o2;
  Ols ols[PXIMAGE8_NOLS];
  i32 pred[PXIMAGE8_NP];
  i32 nb[34];
  PxRing errBuf, lossBuf;
  i64 info, type;
  i64 w, x, line;
  i64 loss, lossQ;
  i64 ctx, res, col;
  i64 columns0, columns1;
  i64 lastBpos, lastPos;
  i64 pw, pn, pnw, pne, pww, pnn;
  i64 pnnw, pnne, pnnee, pnnww;
} PxImage8Model;
void pximage8model_init(PxImage8Model *m, i64 allowance);
i64 pximage8model_tableBytes(i64 allowance);

#endif
