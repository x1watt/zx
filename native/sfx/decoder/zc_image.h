// zxsfx decoder: port of zcm_image.dart (the image models of levels 3 to
// 6 and of palette images, and the 1 and 4 bit image model).
//
// After the Image8BitModel, Image24BitModel, Image1BitModel and
// Image4BitModel of paq8px (Marcio Pais, from his Emma; Zoltan Gotthardt,
// Sebastian Lehmann and the paq8px authors; earlier im8/im24 models of
// paq8 by Matt Mahoney).

#ifndef ZC_IMAGE_H
#define ZC_IMAGE_H

#include "zc.h"
#include "zc_maps.h"

// zcm_image.dart ResidualMap (zc_maps.h has the other one, ResidualMap).
typedef struct {
  i64 n, histograms;
  u16 *sums;
  i32 *pred, *base;
  i64 k;
} ImgResidualMap;
void imgresidualmap_init(ImgResidualMap *m, i64 n, i64 histograms);
ZINLINE i64 imgresidualmap_inputs(const ImgResidualMap *m) { return m->n * 2; }
ZINLINE void imgresidualmap_set(ImgResidualMap *m, i64 prediction,
                                i64 histogram) {
  i64 k = m->k;
  m->pred[k] = (i32)prediction;
  m->base[k] = (i32)((k * m->histograms + histogram) * 256);
  m->k = k + 1;
}
void imgresidualmap_update(ImgResidualMap *m, i64 byte);
void imgresidualmap_mix(ImgResidualMap *m, Mixer *mx, i64 bpos, i64 c0);

// _BitHashMap (paq8px LargeStationaryMap, simplified).
typedef struct {
  u32 *t;
  i64 mask, n, k;
  i32 *idx, *ctx;
} ImgBitHashMap;

// _ResidualBits (the light model's residual contexts).
typedef struct {
  i64 n;
  u16 *t;
  i32 *pred, *idx;
} ImgResidualBits;

#define IMAGEMODEL_NPRED 42

// ImageModel: image8, image24, image32 and image8pal segments.
typedef struct {
  ZModel base;
  i64 np, ncm;
  int useBh, smallHist, full;
  ContextMap cm;
  ImgResidualMap r1, r2;  // full only
  ImgResidualBits rb;     // light only
  ImgBitHashMap bh;
  i32 p[IMAGEMODEL_NPRED];
  i32 spread[IMAGEMODEL_NPRED];
  Ols ols[2][4];
  i64 olsPlane;
  u8 *err;
  i64 errSize, errCap, errMask;
  // Layout of the current segment.
  i64 stride, bpp, width, info, type;
  int palette;
  // Position of the byte being predicted.
  i64 col, line, k;
  i64 color; // plane, or 4 in the row padding
  i64 w, n, nw, ww, nn;
  i64 p1, p2;
  i64 ctx0, ctx1, act;
} ImageModel;

// [allowance]: bytes for all the tables; [full]: all predictors and
// contexts (Dart default true).
void imagemodel_init(ImageModel *m, i64 allowance, int full);
i64 imagemodel_tableBytes(i64 allowance);
// Getters the predictor reads.
ZINLINE i64 imagemodel_plane(const ImageModel *m) { return m->color; }
ZINLINE i64 imagemodel_pxW(const ImageModel *m) { return m->w; }
ZINLINE i64 imagemodel_pxN(const ImageModel *m) { return m->n; }
ZINLINE i64 imagemodel_pxWW(const ImageModel *m) { return m->ww; }
ZINLINE i64 imagemodel_pxNN(const ImageModel *m) { return m->nn; }
ZINLINE i64 imagemodel_shapeCtx(const ImageModel *m) {
  return (((m->color & 3) << 9) | m->ctx0) >> 3;
}

// ZcmBitImageModel: image1 and image4 segments.
#define BITIMAGE_NCTX 8
typedef struct {
  ZModel base;
  i64 bits;
  u32 *t;
  i32 idx[BITIMAGE_NCTX];
  i32 ctx[BITIMAGE_NCTX];
  i64 info, type, stride, width, mctx;
} ZcmBitImageModel;
void zcmbitimagemodel_init(ZcmBitImageModel *m, i64 allowance);
i64 zcmbitimagemodel_tableBytes(i64 allowance);

#endif
