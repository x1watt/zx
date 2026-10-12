// zxsfx decoder: port of zcm_image.dart (image models: 8-bit gray or
// palette, 24-bit and 32-bit pixels; 1 and 4 bit pixels).
//
// After the Image8BitModel and Image24BitModel of paq8px (Marcio Pais,
// from his Emma; Zoltan Gotthardt, Sebastian Lehmann and the paq8px
// authors; earlier im8/im24 models of paq8 by Matt Mahoney): the pixels
// around the one being coded (W, N, NW, NE and further), on the same color
// plane and on the planes already coded of the same pixel, give numeric
// predictions whose residuals are modeled by histograms (paq8px
// ResidualMap), hashed contexts of the neighborhood (ContextMap), bit
// contexts of quantized neighbors (paq8px LargeStationaryMap) and mixer
// weight set selectors from the local gradients, and least squares fits
// (paq8px OLS by Sebastian Lehmann). The 1 and 4 bit model follows paq8px
// Image1BitModel and Image4BitModel.

#include "zc_image.h"

// ---------------------------------------------------------------- ResidualMap

// paq8px ResidualMap: per context and histogram, the counts of
// (actual - predicted) byte values as prefix sums.
void imgresidualmap_init(ImgResidualMap *m, i64 n, i64 histograms) {
  m->n = n;
  m->histograms = histograms;
  m->sums = ZNEW(u16, n * histograms * 256);
  m->pred = ZNEW(i32, n);
  m->base = ZNEW(i32, n);
  m->k = 0;
}

// Learns [byte] in every context set for it, then clears the list.
void imgresidualmap_update(ImgResidualMap *m, i64 byte) {
  u16 *s = m->sums;
  for (i64 i = 0; i < m->k; i++) {
    i64 base = m->base[i];
    i64 bin = (192 + byte - m->pred[i]) & 255;
    if (s[base + 255] >= 65535) {
      // Halve: rebuild the prefix sums from halved counts.
      i64 prev = 0, acc = 0;
      for (i64 j = 0; j < 256; j++) {
        i64 v = s[base + j];
        i64 c = (v - prev) >> 1;
        prev = v;
        acc += c;
        s[base + j] = (u16)acc;
      }
    }
    for (i64 j = base + bin; j < base + 256; j++) {
      s[j] = (u16)(s[j] + 1);
    }
  }
  m->k = 0;
}

// Adds 2 inputs per context for the next bit.
void imgresidualmap_mix(ImgResidualMap *m, Mixer *mx, i64 bpos, i64 c0) {
  const u16 *s = m->sums;
  i32 *tx = mx->tx;
  i64 k = mx->nx;
  i64 c1 = (c0 << (8 - bpos)) & 255;
  i64 range = (i64)1 << (7 - bpos);
  for (i64 i = 0; i < m->k; i++) {
    i64 base = m->base[i];
    i64 o0 = (192 + c1 - m->pred[i]) & 255;
    i64 o1 = (o0 + range) & 255;
    i64 n0, n1;
    if (o0 + range <= 256) {
      n0 = (i64)s[base + o0 + range - 1] - (o0 == 0 ? 0 : (i64)s[base + o0 - 1]);
    } else {
      n0 = (i64)s[base + 255] - (i64)s[base + o0 - 1] +
           (i64)s[base + o0 + range - 256 - 1];
    }
    if (o1 + range <= 256) {
      n1 = (i64)s[base + o1 + range - 1] - (o1 == 0 ? 0 : (i64)s[base + o1 - 1]);
    } else {
      n1 = (i64)s[base + 255] - (i64)s[base + o1 - 1] +
           (i64)s[base + o1 + range - 256 - 1];
    }
    // p1 = 4096 * (n1 + 1) / (n0 + n1 + 2)
    i64 sum = n0 + n1;
    int sh = 0;
    while ((sum >> sh) > 1023) sh++;
    i64 p1 = ((((n1 >> sh) + 1) << 12) * ((i64)kDt[sum >> sh] >> 1)) >> 30;
    i64 pp = p1 < 1 ? 1 : (p1 > 4095 ? 4095 : p1);
    tx[k] = kStretch[pp];
    tx[k + 1] = (i32)((pp - 2048) >> 1);
    k += 2;
  }
  mx->nx = k;
}

// ---------------------------------------------------------------- _BitHashMap

// Per hashed (context, partial byte) a 22 bit probability with a count,
// two inputs.
static void bh_init(ImgBitHashMap *b, i64 n, i64 bits) {
  i64 size = (i64)1 << bits;
  b->t = ZNEW(u32, size);
  for (i64 i = 0; i < size; i++) b->t[i] = (u32)2048 << 20;
  b->mask = size - 1;
  b->idx = ZNEW(i32, n);
  b->ctx = ZNEW(i32, n);
  b->n = n;
  b->k = 0;
}

ZINLINE void bh_set(ImgBitHashMap *b, i64 h) {
  b->ctx[b->k++] = (i32)(h & 0xFFFFFFFF);
}

// Starts the contexts of a new byte.
ZINLINE void bh_reset(ImgBitHashMap *b) { b->k = 0; }

ZINLINE i64 bh_learn(i64 e, i64 target) {
  i64 en = e & 1023;
  i64 ep = e >> 10;
  return shl(ep + (((target - ep) * (i64)kDt[en]) >> 31), 10) |
         (en < 255 ? en + 1 : en);
}

// Learns the last bit and adds zeros (no contexts for this byte).
static void bh_skipMix(ImgBitHashMap *b, Mixer *m, i64 y) {
  u32 *t = b->t;
  i32 *tx = m->tx;
  i64 k = m->nx;
  i64 target = y << 22;
  for (i64 i = 0; i < b->n; i++) {
    i64 li = b->idx[i];
    t[li] = (u32)bh_learn(t[li], target);
    b->idx[i] = 0;
    tx[k] = 0;
    tx[k + 1] = 0;
    k += 2;
  }
  m->nx = k;
}

static void bh_mix(ImgBitHashMap *b, Mixer *m, i64 y, i64 c0) {
  u32 *t = b->t;
  i32 *tx = m->tx;
  i64 k = m->nx;
  i64 target = y << 22;
  for (i64 i = 0; i < b->n; i++) {
    i64 li = b->idx[i];
    t[li] = (u32)bh_learn(t[li], target);
    i64 ni = hash2(b->ctx[i], c0) & b->mask;
    b->idx[i] = (i32)ni;
    i64 e2 = t[ni];
    i64 p = e2 >> 20;
    i64 conf = e2 & 1023;
    tx[k] = conf == 0 ? 0 : (i32)(kStretch[p] >> 1);
    tx[k + 1] = conf == 0 ? 0 : (i32)((p - 2048) >> 3);
    k += 2;
  }
  m->nx = k;
}

// ---------------------------------------------------------------- _ResidualBits

// Residual contexts with direct probabilities (the light image model).
static void rb_init(ImgResidualBits *r, i64 n) {
  r->n = n;
  r->t = ZNEW(u16, n * 2 * 4096);
  for (i64 i = 0; i < n * 2 * 4096; i++) r->t[i] = 32768;
  r->pred = ZNEW(i32, n);
  r->idx = ZNEW(i32, n * 2);
}

static void rb_mix(ImgResidualBits *r, Mixer *m, i64 y, i64 bpos, i64 c0) {
  u16 *t = r->t;
  i32 *tx = m->tx;
  i64 k = m->nx;
  i64 b = (c0 << (8 - bpos)) & 255;
  i64 ys = y << 16;
  i64 coarse = 3 - bpos < 0 ? 0 : 3 - bpos;
  for (i64 i = 0; i < r->n; i++) {
    i64 j = i * 2;
    i64 li = r->idx[j];
    t[li] = (u16)(t[li] + ((ys - t[li]) >> 5));
    li = r->idx[j + 1];
    t[li] = (u16)(t[li] + ((ys - t[li]) >> 6));
    i64 rr = r->pred[i] - b;
    if (rr < -255) rr = -255;
    if (rr > 255) rr = 255;
    i64 rc = rr >> coarse;
    if (rc < -32) rc = -32;
    if (rc > 31) rc = 31;
    i64 a = (i * 2) * 4096 + (((rc + 32) << 3) | bpos);
    i64 bb = (i * 2 + 1) * 4096 + (((rr + 256) << 3) | bpos);
    r->idx[j] = (i32)a;
    r->idx[j + 1] = (i32)(bb & 0xFFFFFFFF);
    tx[k] = (i32)(kStretch[t[a] >> 4] >> 1);
    tx[k + 1] = (i32)(kStretch[t[bb] >> 4] >> 1);
    k += 2;
  }
  m->nx = k;
}

// ---------------------------------------------------------------- helpers

ZINLINE i64 iabs(i64 x) { return x < 0 ? -x : x; }
ZINLINE i64 clip8(i64 x) { return x < 0 ? 0 : (x > 255 ? 255 : x); }

// paq8px DiffQt: the signed, quantized difference of two bytes (4 bits).
static i64 diffQt(i64 a, i64 b) {
  i64 d = iabs(a - b);
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

// ---------------------------------------------------------------- ImageModel

#define NPRED IMAGEMODEL_NPRED // 40 fixed and 2 least squares fits
#define NLIGHT 12
#define NCM 20
#define NBH 12

// Least squares fits per color plane: features as (dx, dy, planes back)
// triples of im_px, for color and for gray images, the solve interval and
// the forgetting factor.
static const i64 kOlsColor0[] = {
    1, 0, 0, 0, 1, 0, 1, 1, 0, -1, 1, 0, 2, 0, 0, 0, 2, 0, 2, 1, 0,
    1, 2, 0, -1, 2, 0, -2, 1, 0, 3, 0, 0, 0, 3, 0, 0, 0, 1, 1, 0, 1,
    0, 1, 1, 1, 1, 1, -1, 1, 1, 0, 0, 2, 1, 0, 2, 0, 1, 2};
static const i64 kOlsColor1[] = {
    1, 0, 0, 0, 1, 0, 1, 1, 0, -1, 1, 0, 2, 0, 0, 0, 2, 0, 2, 1, 0,
    1, 2, 0, 0, 0, 1, 1, 0, 1, 0, 1, 1, 0, 0, 2};
static const i64 kOlsGray0[] = {
    1, 0, 0, 0, 1, 0, 1, 1, 0, -1, 1, 0, 2, 0, 0, 0, 2, 0, 2, 1, 0,
    1, 2, 0, -1, 2, 0, -2, 1, 0, 3, 0, 0, 0, 3, 0, -2, 2, 0, 2, 2, 0,
    -3, 1, 0, 3, 1, 0, -1, 3, 0, 1, 3, 0, 4, 0, 0, 0, 4, 0};
static const i64 kOlsGray1[] = {
    1, 0, 0, 0, 1, 0, 1, 1, 0, -1, 1, 0, 2, 0, 0, 0, 2, 0, 2, 1, 0,
    1, 2, 0, -1, 2, 0, -2, 1, 0, 1, 2, 0, 2, 1, 0};
static const i64 *const kOlsColor[2] = {kOlsColor0, kOlsColor1};
static const i64 *const kOlsGray[2] = {kOlsGray0, kOlsGray1};
static const i64 kOlsColorLen[2] = {sizeof(kOlsColor0) / sizeof(i64),
                                    sizeof(kOlsColor1) / sizeof(i64)};
static const i64 kOlsGrayLen[2] = {sizeof(kOlsGray0) / sizeof(i64),
                                   sizeof(kOlsGray1) / sizeof(i64)};
static const i64 kOlsN[2] = {20, 12};
static const i64 kOlsInterval[2] = {4, 2};
static const double kOlsLambda[2] = {0.996, 0.95};

static const i64 kImgSelFull[6] = {4 * 8 + 8, 512 * 4, 256 * 4,
                                   64 * 4 * 4, 16 * 8 * 4, 8 * 8 * 4};
static const i64 kImgSelLight[2] = {4 * 8 + 8, 512 * 4};

static int im_small(i64 allowance) { return allowance < (6 << 20); }

static i64 im_residualBytes(i64 allowance) {
  return (i64)NPRED * (im_small(allowance) ? 12 : 48) * 4 * 512;
}

static i64 im_bhBits(i64 allowance) {
  i64 b = 12;
  while (b < 22 && ((i64)4 << (b + 1)) <= allowance / 8) b++;
  return b;
}

static i64 im_cmBytes(i64 allowance) {
  i64 b = allowance - im_residualBytes(allowance) -
          ((i64)4 << im_bhBits(allowance));
  return floorPow2(b < (64 << 10) ? 64 << 10 : b);
}

i64 imagemodel_tableBytes(i64 allowance) {
  return im_cmBytes(allowance) + ((i64)4 << im_bhBits(allowance)) +
         im_residualBytes(allowance);
}

static i64 im_residualInputs(const ImageModel *m) {
  return m->full ? imgresidualmap_inputs(&m->r1) + imgresidualmap_inputs(&m->r2)
                 : m->rb.n * 2;
}

static void imagemodel_mix(ZModel *self, ZState *s, Mixer *m);
static void imagemodel_setCtx(ZModel *self, ZState *s, Mixer *m);

void imagemodel_init(ImageModel *m, i64 allowance, int full) {
  m->full = full;
  m->np = full ? NPRED : NLIGHT;
  m->ncm = full ? NCM : 6;
  m->useBh = full;
  contextmap_init(&m->cm, im_cmBytes(allowance), full ? NCM : 6, 0, 0);
  if (full) {
    imgresidualmap_init(&m->r1, NPRED, im_small(allowance) ? 8 * 4 : 32 * 4);
    imgresidualmap_init(&m->r2, NPRED, im_small(allowance) ? 4 * 4 : 16 * 4);
  } else {
    rb_init(&m->rb, NLIGHT);
  }
  m->smallHist = im_small(allowance);
  bh_init(&m->bh, full ? NBH : 0, im_bhBits(allowance));
  for (int i = 0; i < 2; i++) {
    for (int c = 0; c < 4; c++) {
      ols_init(&m->ols[i][c], kOlsN[i], kOlsInterval[i], kOlsLambda[i]);
    }
  }
  m->olsPlane = -1;
  m->err = 0;
  m->errSize = m->errCap = 0;
  m->errMask = 0;
  m->stride = 1;
  m->bpp = 1;
  m->width = 1;
  m->info = -1;
  m->type = -1;
  m->palette = 0;
  m->col = m->line = 0;
  m->k = -1;
  m->color = 0;
  m->w = m->n = m->nw = m->ww = m->nn = 0;
  m->p1 = m->p2 = 0;
  m->ctx0 = m->ctx1 = m->act = 0;
  m->base.inputs = m->cm.nCtx * contextmap_inputsPerContext(&m->cm) +
                   im_residualInputs(m) + m->bh.n * 2 + 1;
  m->base.mix = imagemodel_mix;
  m->base.nsel = full ? 6 : 2;
  m->base.selSizes = full ? kImgSelFull : kImgSelLight;
  m->base.setCtx = imagemodel_setCtx;
}

static void im_setup(ImageModel *m, ZState *s) {
  m->type = s->blockType;
  m->info = s->blockInfo;
  m->stride = m->info & 0xFFFFFF;
  i64 pad = (m->info >> 24) & 3;
  m->palette = m->type == ZT_IMAGE8PAL;
  m->bpp = (m->type == ZT_IMAGE8 || m->palette)
               ? 1
               : (m->type == ZT_IMAGE24 ? 3 : 4);
  m->width = m->stride - pad;
  if (m->width < m->bpp) m->width = m->stride;
  // Errors of every predictor at the last 3 rows (and a few bytes).
  i64 need = (3 * m->stride + 16) * NPRED;
  i64 size = 1024;
  while (size < need && size < (1 << 23)) size <<= 1;
  if (size > m->errCap) {
    m->err = ZNEW(u8, size);
    m->errCap = size;
  } else {
    memset(m->err, 0, (size_t)size);
  }
  m->errSize = size;
  m->errMask = size - 1;
}

// Average error of predictor [i] at W, N, NW, NE, WW and NN (paq8px
// GetPredErrAvg).
ZINLINE i64 im_errAt(const ImageModel *m, i64 back, i64 i) {
  i64 k = m->k;
  return back > k ? 255 : m->err[((k - back) * NPRED + i) & m->errMask];
}
static i64 im_errAvg(const ImageModel *m, i64 i) {
  i64 bpp = m->bpp, st = m->stride;
  return (2 * im_errAt(m, bpp, i) + 2 * im_errAt(m, st, i) +
          im_errAt(m, st - bpp, i) + im_errAt(m, st + bpp, i) +
          im_errAt(m, 2 * bpp, i) + im_errAt(m, 2 * st, i)) >>
         3;
}

// The byte [b] positions before the one [dx] pixels to the left and [dy]
// rows up (negative dx: to the right), kept on the same plane inside the
// row; 0 outside the segment.
static i64 im_px(const ImageModel *m, const ZState *s, i64 dx, i64 dy, i64 b) {
  i64 bpp = m->bpp;
  i64 x = m->col - b - dx * bpp;
  while (x < 0) x += bpp;
  while (x >= m->width) x -= bpp;
  i64 y = m->line - dy;
  if (y < 0) y = 0;
  i64 off = m->k - (y * m->stride + x);
  if (off < 1 || off > m->k) return 0;
  return zstate_back(s, off);
}

static i64 im_round(double v) {
  if (!__builtin_isfinite(v)) return 128;
  if (v > 1e6) return 1000000;
  if (v < -1e6) return -1000000;
  return (i64)(v + (v < 0 ? -0.5 : 0.5));
}

ZINLINE void im_pred(ImageModel *m, i64 i, i64 p, i64 spread) {
  m->p[i] = (i32)p;
  m->spread[i] = (i32)spread;
}

// The contexts of palette images (paq8px Image8BitModel, !isGray): the
// indexes are not intensities, so only their combinations are hashed.
static void im_paletteContexts(ImageModel *m, i64 w, i64 n, i64 nw, i64 ne,
                               i64 ww, i64 nn, i64 nne, i64 nnw, i64 nww,
                               i64 nee) {
  ContextMap *cm = &m->cm;
  i64 nc = m->ncm;
  i64 h = 2048;
  i64 j = 0;
#define PUT(x)                                  \
  do {                                          \
    i64 x_ = (x);                               \
    if (j < nc) contextmap_set(cm, j, hash2(++h, x_)); \
    j++;                                        \
  } while (0)
  PUT(w);
  PUT(n);
  PUT(w | (n << 8));
  PUT(w | (ne << 8));
  PUT(n | (nn << 8));
  PUT(w | (ww << 8));
  PUT(hash4(w, n, nw, ne));
  PUT(hash4(w, ww, n, nn));
  PUT(hash4(n, nw, ne, nne));
  PUT(hash4(w, nw, nww, ww));
  PUT(hash3(n, ne, nee));
  PUT(hash3(w, n, nnw));
  PUT(nw | (ne << 8));
  PUT(hash4(w, n, ne, (nn << 8) | ww));
  PUT(hash2(m->width, m->col));
  PUT(hash3(w, n, m->col));
  PUT(nw);
  PUT(ne);
  PUT(hash3(ww, nn, nw));
  PUT(hash4(w, ww, nw, (n << 8) | ne));
}

// The contexts of gray images (paq8px Image8BitModel, gray).
static void im_grayContexts(ImageModel *m, i64 w, i64 n, i64 nw, i64 ne,
                            i64 ww, i64 nn, i64 nnn, i64 nnw, i64 nww,
                            i64 nee, i64 www, i64 nnee, i64 nnww) {
  ContextMap *cm = &m->cm;
  i64 nc = m->ncm;
  i64 h = 1024;
  i64 j = 0;
  PUT(n);
  PUT(nw);
  PUT(ne);
  PUT(n | (nn << 8));
  PUT(ne | (nnee << 8));
  PUT(nw | (nnww << 8));
  PUT(w | (nee << 8));
  PUT(n | (nn << 8) | (nnn << 16));
  PUT(hash4(w, ww, n, nn));
  PUT(hash4(w, n, ne, nw));
  PUT(((nnn + n + 4) >> 3) | ((clip8(n * 3 - nn * 3 + nnn) >> 1) << 8));
  PUT((clip8(n * 2 - nn) >> 1) | (diffQt(n, clip8(nn * 2 - nnn)) << 8));
  PUT((clip8(w * 2 - ww) >> 1) | (diffQt(w, clip8(ww * 2 - www)) << 8));
  PUT(clip8(n * 2 - nn) | (diffQt(w, clip8(nw * 2 - nnw)) << 8));
  PUT(clip8(w * 2 - ww) | (diffQt(n, clip8(nw * 2 - nww)) << 8));
  PUT(((w + nee + 1) >> 1) | (diffQt(w, (ww + ne + 1) >> 1) << 8));
  PUT(clip8(w + nee - ne) | (diffQt(w, clip8(ww + ne - n)) << 8));
  i64 x = m->col;
  i64 d7 = (x >> 10) > 7 ? x >> 10 : 7;
  i64 d17 = (x >> 9) > 17 ? x >> 9 : 17;
  i64 d29 = (x >> 8) > 29 ? x >> 8 : 29;
  PUT(hash2(m->width, x / d7));
  PUT(hash3(m->width, x / d17, m->line / 17));
  PUT(hash3(m->width, x / d29, (clip8(w + n - nw) >> 1) | ((w >> 2) << 8)));
#undef PUT
}

static void im_cmRest(ImageModel *m, i64 j, i64 h, i64 w, i64 n, i64 nw,
                      i64 ne, i64 ww, i64 nn, i64 nnn, i64 nne, i64 nee,
                      i64 www, i64 p1, i64 p2, i64 wp1, i64 np1, i64 wp2,
                      i64 np2) {
  ContextMap *cm = &m->cm;
  h++;
  contextmap_set(cm, j++,
                 hash3(h, (nnn + n + 4) >> 3, clip8(n * 3 - nn * 3 + nnn) >> 1));
  h++;
  contextmap_set(cm, j++,
                 hash4(h, clip8(w + n - nw) >> 1, clip8(w + p1 - wp1) >> 3,
                       clip8(n + p1 - np1) >> 3));
  h++;
  contextmap_set(cm, j++, hash4(h, w >> 2, diffQt(w, p1), diffQt(w, p2)));
  h++;
  contextmap_set(cm, j++, hash4(h, n >> 2, diffQt(n, p1), diffQt(n, p2)));
  h++;
  contextmap_set(cm, j++, hash4(h, (w + n + 4) >> 3, p1 >> 4, p2 >> 4));
  h++;
  contextmap_set(cm, j++,
                 hash3(h, clip8(n * 2 - nn) >> 1, diffQt(n, clip8(nn * 2 - nnn))));
  h++;
  contextmap_set(cm, j++,
                 hash3(h, clip8(w * 2 - ww) >> 1, diffQt(w, clip8(ww * 2 - www))));
  h++;
  contextmap_set(cm, j,
                 hash3(h, (w + nee + 1) >> 1, diffQt(w, (ww + ne + 1) >> 1)));
  (void)nne;
  (void)wp2;
  (void)np2;
}

static void im_bhSet(ImageModel *m, i64 c, i64 w, i64 n, i64 nw, i64 ne,
                     i64 nne, i64 p1, i64 p2, i64 np1, i64 np2) {
  // Bit contexts of the neighborhood (paq8px mapL).
  ImgBitHashMap *bh = &m->bh;
  bh_reset(bh);
  i64 g = c * 32;
  g++; bh_set(bh, hash2(g, p2));
  g++; bh_set(bh, hash3(g, p1, p2));
  g++; bh_set(bh, hash3(g, w, p2));
  g++; bh_set(bh, hash4(g, w, p1, p2));
  g++; bh_set(bh, hash4(g, n, np1, np2));
  g++; bh_set(bh, hash4(g, w, p1, (p2 << 8) | n));
  g++; bh_set(bh, hash4(g, n, ne, p1));
  g++; bh_set(bh, hash4(g, nw, ne, p1));
  g++; bh_set(bh, hash3(g, clip8(w + n - nw) >> 1, p1));
  g++; bh_set(bh, hash4(g, clip8(w + n - nw) >> 1, p1, p2));
  g++; bh_set(bh, hash3(g, clip8(n + ne - nne) >> 1, p1));
  g++; bh_set(bh, hash4(g, paeth(w, n, nw) >> 1, p1, p2));
}

static void im_mixCtx(ImageModel *m, ZState *s, i64 w, i64 n, i64 nw, i64 ne,
                      i64 ww, i64 nn, i64 nne, i64 nnw, i64 p1, i64 np1,
                      i64 nep1) {
  // Mixer contexts.
  m->ctx0 = (iabs(w - nw) > 3 ? 256 : 0) | (iabs(nw - n) > 3 ? 128 : 0) |
            (iabs(n - ne) > 3 ? 64 : 0) | (n > nw ? 32 : 0) |
            (n > ne ? 16 : 0) | (n > nn ? 8 : 0) | (w > n ? 4 : 0) |
            (w > nw ? 2 : 0) | (w > ww ? 1 : 0);
  m->ctx1 = (diffQt(p1, clip8(np1 + nep1 - im_px(m, s, -1, 2, 0))) << 4) |
            diffQt(clip8(n + ne - nne), clip8(n + nw - nnw));
}

static void im_byte(ImageModel *m, ZState *s) {
  if (s->blockType != m->type || s->blockInfo != m->info || s->blockPos == 0) {
    im_setup(m, s);
  }
  i64 k = s->blockPos;
  if (m->k >= 0) {
    i64 c1 = s->c4 & 255;
    if (m->full) {
      imgresidualmap_update(&m->r1, c1);
      imgresidualmap_update(&m->r2, c1);
    }
    // Remember how far off every prediction of that byte was.
    i64 base = m->k * NPRED;
    for (i64 i = 0; i < m->np; i++) {
      i64 d = c1 - m->p[i];
      if (d < 0) d = -d;
      m->err[(base + i) & m->errMask] = (u8)(d > 255 ? 255 : d);
    }
    if (m->olsPlane >= 0) {
      double v = (double)c1;
      for (int q = 0; q < 2; q++) ols_update(&m->ols[q][m->olsPlane], v);
      m->olsPlane = -1;
    }
  }
  m->k = k;
  m->col = k % m->stride;
  m->line = k / m->stride;
  if (m->col >= m->width) {
    m->color = 4;
    m->k = -1;
    for (i64 i = 0; i < m->ncm; i++) contextmap_skip(&m->cm, i);
    return;
  }
  m->color = m->col % m->bpp;
  i64 c = m->color;
#define PX(dx, dy) im_px(m, s, dx, dy, 0)
  i64 w = PX(1, 0), n = PX(0, 1), nw = PX(1, 1), ne = PX(-1, 1);
  i64 ww = PX(2, 0), nn = PX(0, 2), nnw = PX(1, 2), nne = PX(-1, 2);
  i64 nww = PX(2, 1), nee = PX(-2, 1), www = PX(3, 0), nnn = PX(0, 3);
  i64 nnee = PX(-2, 2), nnww = PX(2, 2), neee = PX(-3, 1);
  m->w = w;
  m->n = n;
  m->nw = nw;
  m->ww = ww;
  m->nn = nn;
  int multi = m->bpp > 1;
  i64 p1 = multi ? zstate_back(s, 1) : w;
  i64 p2 = multi ? zstate_back(s, 2) : ww;
  m->p1 = p1;
  m->p2 = p2;
  // Planes of the neighbors one and two back (p1, p2 at W, N, NE, NW).
  i64 wp1 = 0, np1 = 0, nep1 = 0, nwp1 = 0, wp2 = 0, np2 = 0;
  if (multi) {
    wp1 = im_px(m, s, 1, 0, 1);
    np1 = im_px(m, s, 0, 1, 1);
    nep1 = im_px(m, s, -1, 1, 1);
    nwp1 = im_px(m, s, 1, 1, 1);
    wp2 = im_px(m, s, 1, 0, 2);
    np2 = im_px(m, s, 0, 1, 2);
  }
  // Numeric predictions (paq8px MakePrediction*), with a spread.
  i64 i = 0;
#define P(p, sp)                 \
  do {                           \
    im_pred(m, i, (p), (sp));    \
    i++;                         \
  } while (0)
  P(w, iabs(w - nw));
  P(n, iabs(n - nw));
  P(w + n - nw, iabs(n - nw) + iabs(w - nw));
  P(w + ne - n, iabs(ne - n));
  P(n + ne - nne, iabs(ne - nne));
  P(n + nw - nnw, iabs(nw - nnw));
  P(n * 2 - nn, iabs(n - nn));
  P(w * 2 - ww, iabs(w - ww));
  P((w + n + 1) >> 1, iabs(w - n));
  P((w + ne + 1) >> 1, iabs(w - ne));
  P((n + ne + 1) >> 1, iabs(n - ne));
  P((w + nee + 1) >> 1, iabs(w - nee));
  P(paeth(w, n, nw), iabs(n - nw));
  P(nw + w - nww, iabs(nw - nww));
  P(w + nee - ne, iabs(nee - ne));
  P(ne * 2 - nnee, iabs(ne - nnee));
  P(nw * 2 - nnww, iabs(nw - nnww));
  P(n * 3 - nn * 3 + nnn, iabs(n - nn));
  P(w * 3 - ww * 3 + www, iabs(w - ww));
  P((n * 3 + w * 3 - nn - ww + 2) >> 2, iabs(n - w));
  P((w * 2 - ww) + (n * 2 - nn) - (nw * 2 - nnww), iabs(w - n));
  P((8 * w - 3 * ww + (3 * nee - 3 * PX(-2, 2) + PX(-2, 3))) / 6,
    iabs(w - nee));
  P((w + neee + 1) >> 1, iabs(w - neee));
  P(ne + nw - nn, iabs(ne - nw));
  P(nn + w - nnw, iabs(nn - nnw));
  P((w + n + ne + nw + 2) >> 2, iabs(w - ne));
  if (m->np <= NLIGHT) {
    if (multi) {
      // The strongest color predictors instead of three plane ones.
      i64 wwp1 = im_px(m, s, 2, 0, 1);
      im_pred(m, 9, w * 2 - ww + p1 - (wp1 * 2 - wwp1), iabs(p1 - wp1));
      im_pred(m, 10, w + p1 - wp1, iabs(p1 - wp1));
      im_pred(m, 11, n + p1 - np1, iabs(p1 - np1));
    }
  } else if (multi) {
    P(p1, 0);
    P(n + p1 - np1, iabs(p1 - np1));
    P(w + p1 - wp1, iabs(p1 - wp1));
    P(ne + p1 - nep1, iabs(p1 - nep1));
    P(nw + p1 - nwp1, iabs(p1 - nwp1));
    P((n + p1 - np1 + w + p1 - wp1 + 1) >> 1, iabs(np1 - wp1));
    P(w + n - nw + p1 - (wp1 + np1 - nwp1), iabs(p1 - wp1));
    P((w + (p1 - wp1) + w + 1) >> 1, iabs(p1 - wp1));
    P((n + (p1 - np1) + n + 1) >> 1, iabs(p1 - np1));
    P(p2, 0);
    P(n + p2 - np2, iabs(p2 - np2));
    P(w + p2 - wp2, iabs(p2 - wp2));
    P((p1 + p2 + 1) >> 1, iabs(p1 - p2));
    P(w + ((p1 - wp1) + (p2 - wp2)) / 2, iabs(p1 - wp1));
  } else {
    P((n + nn + 1) >> 1, iabs(n - nn));
    P((w + ww + 1) >> 1, iabs(w - ww));
    P((ne + nne + 1) >> 1, iabs(ne - nne));
    P((nw + nnw + 1) >> 1, iabs(nw - nnw));
    P(clip8(w + n - nw) + (w - ww) / 2, iabs(w - ww));
    P(n + (n - nn) / 2, iabs(n - nn));
    P(w + (w - ww) / 2, iabs(w - ww));
    P((nn + ww + 1) >> 1, iabs(nn - ww));
    P((ne * 2 + w * 2 - nne - ww + 1) >> 1, iabs(ne - w));
    P(nee, iabs(nee - ne));
    P((w + nee + ne + n + 2) >> 2, iabs(w - n));
    P(www, iabs(www - ww));
    P(nnn, iabs(nnn - nn));
    P((nne + nnw + 1) >> 1, iabs(nne - nnw));
  }
#undef PX
  if (m->np > 40) {
    // Least squares fits over the neighborhood (paq8px OLS).
    m->olsPlane = c;
    for (int q = 0; q < 2; q++) {
      Ols *o = &m->ols[q][c];
      const i64 *offs = multi ? kOlsColor[q] : kOlsGray[q];
      i64 len = multi ? kOlsColorLen[q] : kOlsGrayLen[q];
      for (i64 f = 0; f < len; f += 3) {
        ols_add(o, (double)im_px(m, s, offs[f], offs[f + 1], offs[f + 2]));
      }
      P(im_round(ols_predict(o)), iabs(w - n));
    }
  }
#undef P
  // Activity: local gradients, quantized.
  i64 act = iabs(w - nw) + iabs(n - nw) + iabs(n - ne) + iabs(w - ww);
  act = act < 2 ? act : (act < 64 ? 2 + (kIlog[act] >> 4) - 1 : 7);
  if (act > 7) act = 7;
  m->act = act;
  if (!m->full) {
    for (i64 j = 0; j < m->np; j++) m->rb.pred[j] = m->p[j];
  }
  int small = m->smallHist;
  for (i64 j = 0; j < (m->full ? m->np : 0); j++) {
    i64 sp = m->spread[j];
    if (small) {
      sp = sp < 2 ? sp : (sp < 64 ? 2 + (kIlog[sp] >> 4) - 1 : 7);
      if (sp > 7) sp = 7;
      imgresidualmap_set(&m->r1, m->p[j], (sp << 2) | c);
      imgresidualmap_set(&m->r2, m->p[j], ((act >> 1) << 2) | c);
    } else {
      i64 ea = im_errAvg(m, j);
      imgresidualmap_set(&m->r1, m->p[j], ((ea > 31 ? 31 : ea) << 2) | c);
      i64 sq = sp >> 1;
      imgresidualmap_set(&m->r2, m->p[j], ((sq > 15 ? 15 : sq) << 2) | c);
    }
  }
  if (m->palette) {
    im_paletteContexts(m, w, n, nw, ne, ww, nn, nne, nnw, nww, nee);
    im_mixCtx(m, s, w, n, nw, ne, ww, nn, nne, nnw, p1, np1, nep1);
    return;
  }
  if (!multi) {
    im_grayContexts(m, w, n, nw, ne, ww, nn, nnn, nnw, nww, nee, www, nnee,
                    nnww);
    im_mixCtx(m, s, w, n, nw, ne, ww, nn, nne, nnw, p1, np1, nep1);
    return;
  }
  // Hashed contexts (paq8px Image24BitModel cm).
  i64 h = c * 64;
  ContextMap *cm = &m->cm;
  i64 nc = m->ncm;
  i64 j = 0;
#define PUT(x)                                 \
  do {                                         \
    h++;                                       \
    i64 x_ = (x);                              \
    if (j < nc) contextmap_set(cm, j, x_);     \
    j++;                                       \
  } while (0)
  PUT(hash3(h, w, p1));
  PUT(hash3(h, w, p2));
  PUT(hash3(h, n, p1));
  PUT(hash3(h, n, p2));
  PUT(hash3(h, p1, p2));
  PUT(hash4(h, n, nn, p1));
  PUT(hash4(h, w, ww, p1));
  PUT(hash4(h, w, (p1 - wp1) & 511, (p2 - wp2) & 511));
  PUT(hash4(h, n, (p1 - np1) & 511, (p2 - np2) & 511));
  PUT(hash4(h, nw, (p1 - nwp1) & 511, ne));
  PUT(hash4(h, w, ww, (n << 8) | nn));
  PUT(hash4(h, w, n, (ne << 8) | nw));
#undef PUT
  if (m->ncm > j) {
    im_cmRest(m, j, h, w, n, nw, ne, ww, nn, nnn, nne, nee, www, p1, p2, wp1,
              np1, wp2, np2);
  }
  if (m->useBh) im_bhSet(m, c, w, n, nw, ne, nne, p1, p2, np1, np2);
  im_mixCtx(m, s, w, n, nw, ne, ww, nn, nne, nnw, p1, np1, nep1);
}

static void imagemodel_mix(ZModel *self, ZState *s, Mixer *mx) {
  ImageModel *m = (ImageModel *)self;
  i64 bpos = s->bpos;
  if (bpos == 0) im_byte(m, s);
  contextmap_mix(&m->cm, mx, s->y, bpos, s->c0, s->c4 & 255);
  if (m->color == 4) {
    // Row padding: no residual inputs.
    i32 *tx = mx->tx;
    i64 k = mx->nx;
    i64 n = im_residualInputs(m);
    for (i64 i = 0; i < n; i++) tx[k++] = 0;
    mx->nx = k;
    bh_skipMix(&m->bh, mx, s->y);
    mixer_add(mx, -2047);
    return;
  }
  if (!m->full) {
    rb_mix(&m->rb, mx, s->y, bpos, s->c0);
  } else {
    imgresidualmap_mix(&m->r1, mx, bpos, s->c0);
    imgresidualmap_mix(&m->r2, mx, bpos, s->c0);
  }
  bh_mix(&m->bh, mx, s->y, s->c0);
  mixer_add(mx, 0);
}

static void imagemodel_setCtx(ZModel *self, ZState *s, Mixer *mx) {
  ImageModel *m = (ImageModel *)self;
  i64 bpos = s->bpos;
  i64 c = m->color;
  if (c == 4) {
    mixer_set(mx, 32 + bpos);
    mixer_set(mx, 0);
    if (!m->useBh) return;
    mixer_set(mx, 0);
    mixer_set(mx, 0);
    mixer_set(mx, 0);
    mixer_set(mx, 0);
    return;
  }
  i64 cc = c & 3;
  mixer_set(mx, (cc << 3) | bpos);
  mixer_set(mx, (m->ctx0 << 2) | cc);
  if (!m->useBh) return;
  mixer_set(mx, (m->ctx1 << 2) | cc);
  mixer_set(mx, (((m->act << 3) | bpos) << 2) | cc);
  i64 c0 = s->c0;
  i64 pr1 = 0x100 | ((m->n + m->w + 1) >> 1);
  i64 pr2 = 0x100 | clip8(m->n + m->w - m->nw);
  i64 pr3 = 0x100 | clip8(2 * m->n - m->nn);
  i64 pr4 = 0x100 | clip8(2 * m->w - m->ww);
  i64 sh = 8 - bpos;
  mixer_set(mx, ((((c0 == (pr1 >> sh)) ? 8 : 0) | ((c0 == (pr2 >> sh)) ? 4 : 0) |
                  ((c0 == (pr3 >> sh)) ? 2 : 0) | ((c0 == (pr4 >> sh)) ? 1 : 0))
                 << 5) |
                    (bpos << 2) | cc);
  mixer_set(mx, ((m->p1 >> 5) << 5) | ((m->p2 >> 5) << 2) | (bpos >> 1));
}

// ---------------------------------------------------------------- ZcmBitImageModel

// Images with 1 or 4 bits per pixel (after paq8px Image1BitModel and
// Image4BitModel): the pixels around the one being coded select adaptive
// probabilities (22 bits and a count) in hashed tables, one that keeps
// adapting fast and one that settles.

static const i64 kBitImgSel[2] = {2048, 64};

static i64 bi_bitsFor(i64 allowance) {
  i64 b = 12;
  while (b < 20 && (((i64)BITIMAGE_NCTX * 8) << (b + 1)) <= allowance) b++;
  return b;
}

i64 zcmbitimagemodel_tableBytes(i64 allowance) {
  return ((i64)BITIMAGE_NCTX * 8) << bi_bitsFor(allowance);
}

ZINLINE i64 bi_learn(i64 e, i64 y, i64 limit) {
  i64 n = e & 1023;
  i64 p = e >> 10;
  return shl(p + ((((y << 22) - p) * (i64)kDt[n]) >> 30), 10) |
         (n < limit ? n + 1 : n);
}

static void bitimage_mix(ZModel *self, ZState *s, Mixer *mx);
static void bitimage_setCtx(ZModel *self, ZState *s, Mixer *mx);

void zcmbitimagemodel_init(ZcmBitImageModel *m, i64 allowance) {
  m->bits = bi_bitsFor(allowance);
  i64 size = ((i64)BITIMAGE_NCTX * 2) << m->bits;
  m->t = ZNEW(u32, size);
  for (i64 i = 0; i < size; i++) m->t[i] = (u32)1 << 31;
  for (int i = 0; i < BITIMAGE_NCTX; i++) m->idx[i] = m->ctx[i] = 0;
  m->info = m->type = -1;
  m->stride = m->width = 1;
  m->mctx = 0;
  m->base.inputs = BITIMAGE_NCTX * 2 + 1;
  m->base.mix = bitimage_mix;
  m->base.nsel = 2;
  m->base.selSizes = kBitImgSel;
  m->base.setCtx = bitimage_setCtx;
}

// The byte of the image at row [row] and byte column [col] (absolute,
// already coded); 0 outside (s->blockPos is the byte being coded).
ZINLINE i64 bi_byteAt(const ZcmBitImageModel *m, const ZState *s, i64 row,
                      i64 col) {
  if (row < 0 || col < 0 || col >= m->width) return 0;
  i64 k = s->blockPos;
  i64 off = k - (row * m->stride + col);
  if (off < 1 || off > k) return 0;
  return zstate_back(s, off);
}

// Pixel [x] of row [row] (1 bit or a nibble), 0 outside.
static i64 bi_pix(const ZcmBitImageModel *m, const ZState *s, i64 row, i64 x,
                  i64 line, i64 col, i64 c0, i64 bpos) {
  if (x < 0) return 0;
  if (m->type == ZT_IMAGE1) {
    i64 bc = x >> 3;
    i64 v;
    if (row == line && bc == col) {
      i64 sh = bpos - 1 - (x & 7);
      if (sh < 0) return 0;
      v = c0 >> sh;
    } else {
      v = bi_byteAt(m, s, row, bc) >> (7 - (x & 7));
    }
    return v & 1;
  }
  i64 bc = x >> 1;
  if (row == line && bc == col) {
    // Only the high nibble of the current byte can be complete.
    if ((x & 1) != 0 || bpos < 4) return 0;
    return (c0 >> (bpos - 4)) & 15;
  }
  i64 v = bi_byteAt(m, s, row, bc);
  return (x & 1) == 0 ? v >> 4 : v & 15;
}

static i64 bi_row(const ZcmBitImageModel *m, const ZState *s, i64 r, i64 from,
                  i64 n, i64 x, i64 line, i64 col, i64 c0, i64 bpos) {
  i64 v = 0;
  for (i64 d = from; d < from + n; d++) {
    v = (v << 1) | bi_pix(m, s, line - r, x + d, line, col, c0, bpos);
  }
  return v;
}

static void bitimage_mix(ZModel *self, ZState *s, Mixer *mx) {
  ZcmBitImageModel *m = (ZcmBitImageModel *)self;
  i64 bpos = s->bpos;
  i64 c0 = s->c0;
  i64 y = s->y;
  u32 *t = m->t;
  // Learn the last bit.
  for (int i = 0; i < BITIMAGE_NCTX; i++) {
    i64 a = m->idx[i];
    t[a] = (u32)bi_learn(t[a], y, 20);
    i64 b = a + ((i64)1 << m->bits);
    t[b] = (u32)bi_learn(t[b], y, 255);
  }
  if (bpos == 0 && (s->blockType != m->type || s->blockInfo != m->info)) {
    m->type = s->blockType;
    m->info = s->blockInfo;
    m->stride = m->info & 0xFFFFFF;
    m->width = m->stride - ((m->info >> 24) & 3);
    if (m->width < 1) m->width = m->stride;
  }
  i64 k = s->blockPos;
  i64 col = k % m->stride;
  i64 line = k / m->stride;
  i64 mask = ((i64)1 << m->bits) - 1;
  i32 *ctx = m->ctx;
  if (col >= m->width) {
    // Row padding.
    for (int i = 0; i < BITIMAGE_NCTX; i++) ctx[i] = (i32)hash2(i, bpos);
    m->mctx = 1024 + bpos;
  } else if (m->type == ZT_IMAGE1) {
    i64 x = col * 8 + bpos;
    i64 r0 = bi_row(m, s, 0, -12, 12, x, line, col, c0, bpos); // to the left
    i64 r1 = bi_row(m, s, 1, -5, 11, x, line, col, c0, bpos); // x-5 .. x+5
    i64 r2 = bi_row(m, s, 2, -3, 7, x, line, col, c0, bpos);
    i64 r3 = bi_row(m, s, 3, -2, 5, x, line, col, c0, bpos);
    ctx[0] = (i32)((r0 & 0xFF) | (((r1 >> 3) & 0x1F) << 8));
    ctx[1] = (i32)((r0 & 0xF) | (((r1 >> 2) & 0x7F) << 4) |
                   (((r2 >> 1) & 0x1F) << 11));
    ctx[2] = (i32)((r0 & 3) | (((r1 >> 4) & 7) << 2) | (((r2 >> 2) & 7) << 5) |
                   (((r3 >> 1) & 7) << 8));
    ctx[3] = (i32)(r0 & 0xFFF);
    ctx[4] = (i32)(r1 | ((r0 & 3) << 11));
    ctx[5] = (i32)((r0 & 0x3F) | (((r1 >> 3) & 0x1F) << 6) |
                   (((r2 >> 2) & 7) << 11) | (((r3 >> 2) & 1) << 14));
    ctx[6] = (i32)hash3(r0 & 0x3FF, r1, r2);
    ctx[7] = (i32)hash4(r0 & 0xFFF, r1, r2, r3);
    for (int i = 0; i < BITIMAGE_NCTX; i++) ctx[i] = (i32)hash2(ctx[i], i);
    m->mctx = (r0 & 0xF) | (((r1 >> 4) & 7) << 4) | (((r2 >> 3) & 1) << 7) |
              ((bpos & 3) << 8);
  } else {
    i64 x = col * 2 + (bpos >> 2);
    i64 part = bpos < 4 ? c0
                        : ((c0 & (((i64)1 << (bpos - 4)) - 1)) |
                           ((i64)1 << (bpos - 4)));
#define BPX(dx, dy) bi_pix(m, s, line - (dy), x - (dx), line, col, c0, bpos)
    i64 w = BPX(1, 0), n = BPX(0, 1), nw = BPX(1, 1), ne = BPX(-1, 1);
    i64 ww = BPX(2, 0), nn = BPX(0, 2), nne = BPX(-1, 2), nee = BPX(-2, 1);
#undef BPX
    ctx[0] = (i32)(w | (n << 4) | (nw << 8) | (ne << 12));
    ctx[1] = (i32)(w | (ww << 4) | (n << 8) | (nn << 12));
    ctx[2] = (i32)(n | (nn << 4) | (ne << 8) | (nne << 12));
    ctx[3] = (i32)(w | (n << 4));
    ctx[4] = (i32)w;
    ctx[5] = (i32)(n | (ne << 4) | (nee << 8));
    ctx[6] = (i32)hash4(w, n, nw, (ne << 4) | (ww << 8) | (nn << 12));
    ctx[7] = (i32)hash3(w, x, line & 7);
    for (int i = 0; i < BITIMAGE_NCTX; i++) {
      ctx[i] = (i32)hash3(ctx[i], i, part);
    }
    m->mctx = 512 | ((w == n ? 1 : 0) << 8) | ((n == ne ? 1 : 0) << 7) |
              ((w == nw ? 1 : 0) << 6) | ((bpos & 3) << 4) | (part & 15);
  }
  i32 *tx = mx->tx;
  i64 kk = mx->nx;
  for (int i = 0; i < BITIMAGE_NCTX; i++) {
    i64 a = (((i64)i * 2) << m->bits) + (ctx[i] & mask);
    m->idx[i] = (i32)a;
    tx[kk] = kStretch[t[a] >> 20];
    tx[kk + 1] = kStretch[t[a + ((i64)1 << m->bits)] >> 20];
    kk += 2;
  }
  mx->nx = kk;
  mixer_add(mx, 256);
}

static void bitimage_setCtx(ZModel *self, ZState *s, Mixer *mx) {
  ZcmBitImageModel *m = (ZcmBitImageModel *)self;
  mixer_set(mx, m->mctx & 2047);
  mixer_set(mx, (s->bpos << 3) | (m->type == ZT_IMAGE1 ? 0 : 1));
}
