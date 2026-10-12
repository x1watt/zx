// zxsfx decoder: port of zcm_audio.dart, the audio model of levels 3 to 6
// (levels 7 to 9 use paq8px's models, zc_audio_px.c).
//
// After the Audio8BitModel and Audio16BitModel of paq8px (Marcio Pais,
// after Florin Ghido's 'An asymptotically optimal predictor for stereo
// lossless audio compression'; tuned by Zoltan Gotthardt): the next
// sample is predicted by recursive least squares fits (paq8px OLS by
// Sebastian Lehmann), by LMS filters (paq8px LMS by Sebastian Lehmann,
// normalized per weight like RMSprop, and a plain normalized one) and by
// polynomial extrapolation; the bits of the sample are then coded in
// contexts of the residual between each prediction and the bits already
// known (paq8px SmallStationaryContextMap). 16-bit samples are coded most
// significant byte first (zcm.dart swaps little endian samples).

#include "zc_audio.h"

// Least squares fits: samples of the channel, of the other one (stereo
// only), solve interval, forgetting factor.
typedef struct {
  i64 own, other, interval;
  double lambda;
} OlsCfg;
static const OlsCfg kOlsFull[4] = {
    {48, 16, 16, 0.998},
    {24, 8, 8, 0.998},
    {12, 4, 4, 0.995},
    {6, 2, 2, 0.98},
};
static const OlsCfg kOlsLight[1] = {
    {6, 2, 4, 0.99},
};
// LMS filters: samples of the channel, of the other one, rate.
typedef struct {
  i64 own, other;
  double mu;
} LmsCfg;
static const LmsCfg kLmsFull[1] = {{32, 8, 0.008}};
static const LmsCfg kLmsLight[1] = {{32, 8, 0.008}};
// RMSprop LMS filters: samples of the channel, of the other one, rates.
typedef struct {
  i64 own, other;
  double rateOwn, rateOther;
} RmsCfg;
static const RmsCfg kRmsFull[2] = {
    {640, 64, 7e-5, 1e-5},
    {256, 32, 2e-4, 5e-5},
};

static const i64 kWidths16[4] = {8, 13, 4, 5};
static const i64 kWidths8[4] = {8, 6, 4, 5};
static const i64 kRates[4] = {7, 10, 6, 6};
static const i64 kSizesFull[5] = {8192, 4096, 512, 2560, 256};
static const i64 kSizesLight[3] = {8192, 4096, 512};

// Predictors of a full model (for the table sizes).
#define MAX_PRED (8 + 1 + 3 + 3)
// Residual maps per predictor (paq8px).
#define NMAPS 4

// ---------------------------------------------------------------- _Nlms

static void nlms_init(AudioNlms *f, i64 nOwn, i64 nOther, double mu) {
  f->nOwn = nOwn;
  f->nOther = nOther;
  f->mu = mu;
  f->x = ZNEW(double, nOwn + nOther);
  f->w = ZNEW(double, nOwn + nOther);
  f->pred = 0.0;
}

static double nlms_predict(AudioNlms *f, const double *own, i64 oo,
                           const double *other, i64 ot) {
  double s = 0.0;
  for (i64 i = 0; i < f->nOwn; i++) {
    double v = own[oo + i];
    f->x[i] = v;
    s += v * f->w[i];
  }
  for (i64 i = 0; i < f->nOther; i++) {
    double v = other[ot + i];
    f->x[f->nOwn + i] = v;
    s += v * f->w[f->nOwn + i];
  }
  return f->pred = s;
}

static void nlms_update(AudioNlms *f, double y) {
  i64 n = f->nOwn + f->nOther;
  double err = y - f->pred;
  double norm = 1.0;
  for (i64 i = 0; i < n; i++) norm += f->x[i] * f->x[i];
  double g = f->mu * err / norm;
  for (i64 i = 0; i < n; i++) f->w[i] += g * f->x[i];
}

// ---------------------------------------------------------------- _RmsLms

#define RMS_RHO 0.95
#define RMS_EPS 0.001

static void rmslms_init(AudioRmsLms *f, i64 nOwn, i64 nOther, double rateOwn,
                        double rateOther) {
  f->nOwn = nOwn;
  f->nOther = nOther;
  f->rateOwn = rateOwn;
  f->rateOther = rateOther;
  f->x = ZNEW(double, nOwn + nOther);
  f->w = ZNEW(double, nOwn + nOther);
  f->eg = ZNEW(double, nOwn + nOther);
  f->pred = 0.0;
}

static double rmslms_predict(AudioRmsLms *f, const double *own, i64 oo,
                             const double *other, i64 ot) {
  double s = 0.0;
  for (i64 i = 0; i < f->nOwn; i++) {
    double v = own[oo + i];
    f->x[i] = v;
    s += v * f->w[i];
  }
  for (i64 i = 0; i < f->nOther; i++) {
    double v = other[ot + i];
    f->x[f->nOwn + i] = v;
    s += v * f->w[f->nOwn + i];
  }
  return f->pred = s;
}

static void rmslms_update(AudioRmsLms *f, double y) {
  double err = y - f->pred;
  const double c = 1.0 - RMS_RHO;
  i64 n = f->nOwn + f->nOther;
  for (i64 i = 0; i < n; i++) {
    double g = err * f->x[i];
    double e = RMS_RHO * f->eg[i] + c * (g * g);
    f->eg[i] = e;
    f->w[i] += (i < f->nOwn ? f->rateOwn : f->rateOther) * g /
               zsqrt(e + RMS_EPS);
  }
}

// ---------------------------------------------------------------- _Sscm

static void sscm_init(AudioSscm *m, i64 bits, i64 rate) {
  i64 n = (i64)1 << bits;
  m->t = ZNEW(u16, n);
  for (i64 i = 0; i < n; i++) m->t[i] = 0x7FFF;
  m->mask = n - 1;
  m->rate = rate;
  m->cx = 0;
}

ZINLINE i64 sscm_p(AudioSscm *m, i64 y, i64 cx) {
  u16 *t = m->t;
  i64 e = t[m->cx];
  t[m->cx] =
      (u16)(e + (((y << 16) - e + ((i64)1 << (m->rate - 1))) >> m->rate));
  m->cx = cx & m->mask;
  return t[m->cx] >> 4;
}

ZINLINE i64 clampBits(i64 x, i64 bits) {
  i64 half = (i64)1 << (bits - 1);
  if (x < -half) return 0;
  if (x > half - 1) return ((i64)1 << bits) - 1;
  return x + half;
}

// ---------------------------------------------------------------- AudioModel

i64 audiomodel_mapBits(i64 allowance, i64 nPred) {
  i64 b = 17;
  while (b > 10 && nPred * 4 * ((i64)2 << b) > allowance) b--;
  return b;
}

i64 audiomodel_tableBytes(i64 allowance) {
  return (i64)MAX_PRED * 4 * ((i64)2 << audiomodel_mapBits(allowance, MAX_PRED));
}

static void audio_mix(ZModel *self, ZState *s, Mixer *m);
static void audio_setCtx(ZModel *self, ZState *s, Mixer *m);

void audiomodel_init(AudioModel *m, i64 allowance, int full) {
  const OlsCfg *ols = full ? kOlsFull : kOlsLight;
  const LmsCfg *lms = full ? kLmsFull : kLmsLight;
  const RmsCfg *rms = kRmsFull;
  m->full = full;
  m->nOls = full ? 4 : 1;
  m->nLms = 1;
  m->nRms = full ? 2 : 0;
  m->nPred = m->nOls + m->nLms + m->nRms + 3;
  m->hist = 720;
  m->h[0] = ZNEW(double, 720 * 2);
  m->h[1] = ZNEW(double, 720 * 2);
  m->hp[0] = 720;
  m->hp[1] = 720;
  for (i64 i = 0; i < m->nOls; i++) {
    for (int ch = 0; ch < 2; ch++) {
      ols_init(&m->ols[i][ch], ols[i].own + ols[i].other, ols[i].interval,
               ols[i].lambda);
    }
  }
  for (i64 i = 0; i < m->nLms; i++) {
    for (int ch = 0; ch < 2; ch++) {
      nlms_init(&m->lms[i][ch], lms[i].own, lms[i].other, lms[i].mu);
    }
  }
  for (i64 i = 0; i < m->nRms; i++) {
    for (int ch = 0; ch < 2; ch++) {
      rmslms_init(&m->rms[i][ch], rms[i].own, rms[i].other, rms[i].rateOwn,
                  rms[i].rateOther);
    }
  }
  m->prd0 = ZNEW(i32, m->nPred * 2);
  m->prd1 = ZNEW(i32, m->nPred * 2);
  m->res = ZNEW(i32, m->nPred * 2);
  i64 bits = audiomodel_mapBits(allowance, m->nPred);
  m->maps = ZNEW(AudioSscm, m->nPred * NMAPS);
  i64 mi = 0;
  for (i64 i = 0; i < m->nPred; i++) {
    for (i64 j = 0; j < NMAPS; j++) sscm_init(&m->maps[mi++], bits, kRates[j]);
  }
  m->info = -1;
  m->bits = 16;
  m->channels = 1;
  m->ch = 0;
  m->lsb = 0;
  m->mask = 0;
  m->errLog = 0;
  m->base.inputs = m->nPred * NMAPS * 2;
  m->base.mix = audio_mix;
  m->base.nsel = full ? 5 : 3;
  m->base.selSizes = full ? kSizesFull : kSizesLight;
  m->base.setCtx = audio_setCtx;
}

// The sample [back] bytes before the current byte, as a signed value.
static i64 sampleAt(AudioModel *m, ZState *s, i64 back) {
  if (m->bits == 8) {
    i64 v = zstate_back(s, back);
    return (m->info & 4) != 0 ? (v ^ 0x80) - 128 : v - 128;
  }
  i64 v = (zstate_back(s, back) << 8) | zstate_back(s, back - 1);
  return v >= 0x8000 ? v - 0x10000 : v;
}

static void setPredInt(AudioModel *m, i64 i, i64 ch, i64 v, i64 lim) {
  if (v > lim) v = lim;
  if (v < -lim - 1) v = -lim - 1;
  m->prd0[i * 2 + ch] = (i32)v;
  i64 v1 = v + m->res[i * 2 + ch];
  if (v1 > lim) v1 = lim;
  if (v1 < -lim - 1) v1 = -lim - 1;
  m->prd1[i * 2 + ch] = (i32)v1;
}

static void setPred(AudioModel *m, i64 i, i64 ch, double p, i64 lim) {
  i64 v = 0;
  if (p - p == 0.0) { // p.isFinite
    double r = p + (p < 0 ? -0.5 : 0.5);
    v = r > 1e9 ? lim : (r < -1e9 ? -lim : (i64)r);
  }
  setPredInt(m, i, ch, v, lim);
}

static void newSample(AudioModel *m, ZState *s) {
  i64 bytesPer = m->bits >> 3;
  i64 k = s->blockPos / bytesPer; // index of the sample to predict
  int stereo = m->channels == 2;
  m->ch = stereo ? (k & 1) : 0;
  if (k > 0) {
    // The previous sample is complete: learn it.
    i64 pc = stereo ? ((k - 1) & 1) : 0;
    i64 vi = sampleAt(m, s, bytesPer);
    double v = (double)vi;
    double *hist = m->h[pc];
    for (i64 i = 0; i < m->nOls; i++) ols_update(&m->ols[i][pc], v);
    for (i64 i = 0; i < m->nLms; i++) nlms_update(&m->lms[i][pc], v);
    for (i64 i = 0; i < m->nRms; i++) rmslms_update(&m->rms[i][pc], v);
    i64 err = 0;
    for (i64 i = 0; i < m->nPred; i++) {
      i64 r = vi - m->prd0[i * 2 + pc];
      m->res[i * 2 + pc] = (i32)r;
      i64 a = r < 0 ? -r : r;
      m->mask = ((m->mask << 1) | (a > (m->bits == 16 ? 128 : 4) ? 1 : 0)) &
                0xFFFF;
      i64 q = a >> (m->bits == 16 ? 6 : 1);
      err += q * q;
    }
    i64 el = 0;
    while (((i64)1 << (el + 1)) <= err && el < 15) el++;
    m->errLog = el;
    i64 hp = m->hp[pc] - 1;
    if (hp < 0) {
      // Move the window up (every hist samples).
      memmove(hist + m->hist + 1, hist, sizeof(double) * (size_t)(m->hist - 1));
      hp = m->hist;
    }
    hist[hp] = v;
    m->hp[pc] = (i32)hp;
  }
  // Predictions for the channel of this sample.
  i64 ch = m->ch;
  const double *own = m->h[ch];
  i64 oo = m->hp[ch];
  const double *other = m->h[stereo ? 1 - ch : ch];
  i64 ot = m->hp[stereo ? 1 - ch : ch];
  i64 lim = m->bits == 16 ? 32767 : 127;
  i64 i = 0;
  for (i64 j = 0; j < m->nOls; j++, i++) {
    Ols *o = &m->ols[j][ch];
    const OlsCfg *cfg = &(m->full ? kOlsFull : kOlsLight)[j];
    i64 nOther = stereo ? cfg->other : 0;
    i64 nOwn = o->n - nOther;
    for (i64 q = 0; q < nOwn; q++) ols_add(o, own[oo + q]);
    for (i64 q = 0; q < nOther; q++) ols_add(o, other[ot + q]);
    setPred(m, i, ch, ols_predict(o), lim);
  }
  const double *oth = stereo ? other : own;
  i64 oto = stereo ? ot : oo;
  for (i64 j = 0; j < m->nLms; j++, i++) {
    setPred(m, i, ch, nlms_predict(&m->lms[j][ch], own, oo, oth, oto), lim);
  }
  for (i64 j = 0; j < m->nRms; j++, i++) {
    setPred(m, i, ch, rmslms_predict(&m->rms[j][ch], own, oo, oth, oto), lim);
  }
  i64 x1 = (i64)own[oo], x2 = (i64)own[oo + 1];
  i64 x3 = (i64)own[oo + 2];
  setPredInt(m, i++, ch, x1 * 2 - x2, lim);
  setPredInt(m, i++, ch, x1 * 3 - x2 * 3 + x3, lim);
  setPredInt(m, i++, ch, (stereo && ch == 1) ? (i64)other[ot] : x1, lim);
}

static void audio_mix(ZModel *self, ZState *s, Mixer *mx) {
  AudioModel *m = (AudioModel *)self;
  i64 bpos = s->bpos;
  if (bpos == 0) {
    if (s->blockInfo != m->info || s->blockPos == 0) {
      m->info = s->blockInfo;
      m->bits = (m->info & 1) != 0 ? 16 : 8;
      m->channels = (m->info & 2) != 0 ? 2 : 1;
    }
    if (m->bits == 8 || (s->blockPos & 1) == 0) {
      newSample(m, s);
      m->lsb = 0;
    } else {
      m->lsb = 1;
    }
  }
  i64 c0 = s->c0;
  i64 y = s->y;
  i64 b, pos, top;
  if (m->bits == 16) {
    pos = m->lsb * 8 + bpos;
    i64 v = m->lsb != 0 ? (((s->c4 & 255) << 8) | ((c0 << (8 - bpos)) & 255))
                        : ((c0 << (16 - bpos)) & 0xFFFF);
    b = v >= 0x8000 ? v - 0x10000 : v;
    top = 17;
  } else {
    pos = bpos;
    i64 raw = (c0 << (8 - bpos)) & 255;
    b = (m->info & 4) != 0 ? (raw ^ 0x80) - 128 : raw - 128;
    top = 9;
  }
  const i64 *widths = m->bits == 16 ? kWidths16 : kWidths8;
  i32 *tx = mx->tx;
  i64 k = mx->nx;
  i64 ch = m->ch;
  i64 mi = 0;
  for (i64 i = 0; i < m->nPred; i++) {
    i64 r0 = m->prd0[i * 2 + ch] - b;
    i64 r1 = m->prd1[i * 2 + ch] - b;
    for (i64 j = 0; j < NMAPS; j++) {
      i64 nb = widths[j];
      i64 sh = top - nb - pos;
      if (sh < 0) sh = 0;
      i64 r = j == 3 ? r1 : r0;
      i64 cx = (clampBits(r >> sh, nb) << 4) | pos;
      i64 p = sscm_p(&m->maps[mi++], y, cx);
      tx[k] = kStretch[p];
      tx[k + 1] = (i32)((p - 2048) >> 2);
      k += 2;
    }
  }
  mx->nx = k;
}

static void audio_setCtx(ZModel *self, ZState *s, Mixer *mx) {
  AudioModel *m = (AudioModel *)self;
  i64 bpos = s->bpos;
  i64 c0 = s->c0;
  i64 bc = 0;
  i64 mm = m->mask & 0xFF;
  while (mm != 0) {
    bc += mm & 1;
    mm >>= 1;
  }
  mixer_set(mx, ((m->errLog << 9) | (m->lsb << 8) | c0) & 8191);
  mixer_set(mx, (((m->mask & 0xFF) << 4) | (m->ch << 3) | (m->lsb << 2) |
                 (bpos >> 1)) &
                    4095);
  mixer_set(mx, (bc << 5) | (m->ch << 4) | (m->lsb << 3) | bpos);
  if (!m->full) return;
  // paq8px mxCtx: log2 of the recent large residuals, channel, byte.
  i64 lg = 0;
  while (((i64)2 << lg) <= bc) lg++;
  i64 mxc = lg * 4 + m->ch * 2 + m->lsb;
  mixer_set(mx, (mxc << 7) | ((s->c4 & 255) >> 1));
  mixer_set(mx, (m->errLog << 4) | (m->ch << 3) | (m->lsb << 2) | (bpos >> 1));
}
