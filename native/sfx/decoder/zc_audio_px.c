// zxsfx decoder: port of zcm_audio_px.dart, paq8px's audio models
// (Audio8BitModel and Audio16BitModel), the audio model of levels 7 to 9.
//
// A port of paq8px's model/Audio16BitModel.cpp, model/Audio8BitModel.cpp,
// model/AudioModel.cpp, OLS and LMS, with the audio SSE stage of SSE.cpp.
// Credits: Marcio Pais (the audio models, after Florin Ghido's 'An
// asymptotically optimal predictor for stereo lossless audio
// compression'), Sebastian Lehmann (OLS and LMS), Zoltan Gotthardt and
// the other paq8px authors (tuning, the residual maps).
//
// Doubles with +, -, *, / only; the reciprocal square roots are a bit
// pattern start and Newton steps, as in the Dart code.

#include "zc_audio_px.h"

#define NOLS AUDIOPX_NOLS
#define NLMS AUDIOPX_NLMS
#define NSSM AUDIOPX_NSSM
#define HIST 4096 // samples kept per channel (the taps reach 2,663)

typedef union {
  double d;
  i64 i;
} DBits;

// 1 / sqrt(x) for x > 0: a bit pattern start and three Newton steps.
static double rsqrt3(double x) {
  DBits u;
  u.d = x;
  u.i = 0x5FE6EB50C7B537A9 - (u.i >> 1);
  double y = u.d;
  double h = 0.5 * x;
  y = y * (1.5 - h * y * y);
  y = y * (1.5 - h * y * y);
  y = y * (1.5 - h * y * y);
  return y;
}

// 1 / sqrt(x) for x > 0 with two Newton steps, for the LMS steps.
ZINLINE double rsqrtLms(double x) {
  DBits u;
  u.d = x;
  u.i = 0x5FE6EB50C7B537A9 - (u.i >> 1);
  double y = u.d;
  double h = 0.5 * x;
  y = y * (1.5 - h * y * y);
  return y * (1.5 - h * y * y);
}

ZINLINE i64 ilog2(i64 x) { return x <= 0 ? 0 : bitLength(x) - 1; }

static i64 bitCount(i64 v) {
  i64 c = 0;
  while (v != 0) {
    v &= v - 1;
    c++;
  }
  return c;
}

ZINLINE i64 clampBits(i64 x, i64 bits) {
  i64 half = (i64)1 << (bits - 1);
  if (x < -half) return 0;
  if (x > half - 1) return ((i64)1 << bits) - 1;
  return x + half;
}

ZINLINE i64 roundClip(double p, i64 lo, i64 hi) {
  if (!(p > (double)lo)) return p != p ? 0 : lo;
  if (!(p < (double)hi)) return hi;
  double r = p < 0 ? p - 0.5 : p + 0.5;
  return (i64)r;
}

ZINLINE i64 clip(i64 v, i64 lo, i64 hi) {
  return v < lo ? lo : (v > hi ? hi : v);
}

// ---------------------------------------------------------------- _Ols

#define OLS_NU 0.001

static void pxols_init(PxOls *o, i64 n, i64 interval, double lambda) {
  i64 np = (n + 1) & ~(i64)1;
  o->n = n;
  o->np = np;
  o->interval = interval;
  o->lambda = lambda;
  o->x = ZNEW(double, np);
  o->c = ZNEW(double, n * np);
  o->l = ZNEW(double, n * np);
  o->w = ZNEW(double, n);
  o->b = ZNEW(double, n);
  o->since = 0;
}

static double pxols_predict(PxOls *o) {
  double s = 0.0;
  for (i64 i = 0; i < o->n; i++) s += o->w[i] * o->x[i];
  return s;
}

// Float64x2 lanes: the even and the odd elements, each its own sum.
static int pxols_factor(PxOls *o) {
  const double *cc = o->c;
  double *ll = o->l;
  i64 n = o->n, np = o->np;
  for (i64 i = 0; i < n; i++) {
    i64 r = i * np;
    for (i64 j = 0; j < i; j++) {
      i64 rj = j * np;
      i64 e = j >> 1;
      double vx = 0.0, vy = 0.0;
      for (i64 k = 0; k < e; k++) {
        vx = vx + ll[r + 2 * k] * ll[rj + 2 * k];
        vy = vy + ll[r + 2 * k + 1] * ll[rj + 2 * k + 1];
      }
      double s = cc[r + j] - (vx + vy);
      if ((j & 1) != 0) s -= ll[r + j - 1] * ll[rj + j - 1];
      ll[r + j] = s / ll[rj + j];
    }
    i64 e = i >> 1;
    double vx = 0.0, vy = 0.0;
    for (i64 k = 0; k < e; k++) {
      double qx = ll[r + 2 * k], qy = ll[r + 2 * k + 1];
      vx = vx + qx * qx;
      vy = vy + qy * qy;
    }
    double s = cc[r + i] + OLS_NU - (vx + vy);
    if ((i & 1) != 0) {
      double q = ll[r + i - 1];
      s -= q * q;
    }
    if (!(s > 1e-8)) return 0;
    ll[r + i] = s * rsqrt3(s);
  }
  return 1;
}

static void pxols_solve(PxOls *o) {
  const double *ll = o->l;
  double *ww = o->w;
  i64 n = o->n, np = o->np;
  for (i64 i = 0; i < n; i++) {
    i64 r = i * np;
    double s = o->b[i];
    for (i64 j = 0; j < i; j++) s -= ll[r + j] * ww[j];
    ww[i] = s / ll[r + i];
  }
  for (i64 i = n - 1; i >= 0; i--) {
    double s = ww[i];
    for (i64 j = i + 1; j < n; j++) s -= ll[j * np + i] * ww[j];
    ww[i] = s / ll[i * np + i];
  }
}

static void pxols_update(PxOls *o, double y) {
  double a = o->lambda;
  double be = 1.0 - o->lambda;
  const double *xx = o->x;
  double *c = o->c;
  i64 np = o->np;
  for (i64 i = 0; i < o->n; i++) {
    double xb = be * xx[i];
    i64 r = i * np;
    i64 e = i >> 1;
    for (i64 j = 0; j <= e; j++) {
      i64 q = r + 2 * j;
      c[q] = c[q] * a + xx[2 * j] * xb;
      c[q + 1] = c[q + 1] * a + xx[2 * j + 1] * xb;
    }
    o->b[i] = a * o->b[i] + be * y * xx[i];
  }
  if (++o->since >= o->interval) {
    o->since = 0;
    if (pxols_factor(o)) pxols_solve(o);
  }
}

// ---------------------------------------------------------------- _Window

static void window_init(PxWindow *w, i64 len) {
  w->len = len;
  w->data = ZNEW(double, len * 2 + 1);
  w->p = len;
}

ZINLINE void window_push(PxWindow *w, double v) {
  i64 q = w->p - 1;
  if (q < 0) {
    memmove(w->data + w->len + 1, w->data,
            sizeof(double) * (size_t)(w->len - 1));
    q = w->len;
  }
  w->data[q] = v;
  w->p = q;
}

static void window_clear(PxWindow *w) {
  memset(w->data, 0, sizeof(double) * (size_t)(w->len * 2 + 1));
  w->p = w->len;
}

// ---------------------------------------------------------------- _Lms

#define LMS_RHO (1.0 - 1.0 / 20.0)
#define LMS_EPS 0.001

static void lms_init(PxLms *l, i64 s, i64 d, double rateS, double rateD) {
  l->s = s;
  l->d = d;
  l->rateS = rateS;
  l->rateD = rateD;
  l->w = ZNEW(double, s + d);
  l->eg = ZNEW(double, s + d);
  window_init(&l->own, s);
  window_init(&l->other, d);
  l->pred = 0.0;
}

static void lms_reset(PxLms *l) {
  memset(l->w, 0, sizeof(double) * (size_t)(l->s + l->d));
  memset(l->eg, 0, sizeof(double) * (size_t)(l->s + l->d));
  window_clear(&l->own);
  window_clear(&l->other);
  l->pred = 0.0;
}

// Takes [sample] of the other channel (in mono the channel's own last
// sample) and predicts the next one.
static double lms_predict(PxLms *l, i64 sample) {
  window_push(&l->other, (double)sample);
  const double *ww = l->w;
  const double *a = l->own.data + l->own.p;
  double sum = 0.0;
  for (i64 i = 0; i < l->s; i++) sum += ww[i] * a[i];
  const double *o = l->other.data + l->other.p;
  for (i64 i = 0; i < l->d; i++) sum += ww[l->s + i] * o[i];
  return l->pred = sum;
}

// Learns [sample] of this channel.
static void lms_update(PxLms *l, i64 sample) {
  double err = (double)sample - l->pred;
  const double c = 1.0 - LMS_RHO;
  double *ww = l->w, *e = l->eg;
  const double *a = l->own.data + l->own.p;
  for (i64 i = 0; i < l->s; i++) {
    double g = err * a[i];
    double v = LMS_RHO * e[i] + c * (g * g);
    e[i] = v;
    ww[i] += l->rateS * g * rsqrtLms(v + LMS_EPS);
  }
  const double *o = l->other.data + l->other.p;
  for (i64 i = 0; i < l->d; i++) {
    double g = err * o[i];
    i64 k = l->s + i;
    double v = LMS_RHO * e[k] + c * (g * g);
    e[k] = v;
    ww[k] += l->rateD * g * rsqrtLms(v + LMS_EPS);
  }
  window_push(&l->own, (double)sample);
}

// ---------------------------------------------------------------- _Sscm

static void pxsscm_init(PxSscm *m, i64 bits, i64 rate, i64 scale) {
  i64 n = (i64)1 << bits;
  m->t = ZNEW(u16, n);
  for (i64 i = 0; i < n; i++) m->t[i] = 0x7FFF;
  m->mask = n - 1;
  m->rate = rate;
  m->scale = scale;
  m->cx = 0;
}

ZINLINE void pxsscm_mix(PxSscm *m, i64 y, i64 cx, i32 *tx, i64 k) {
  u16 *t = m->t;
  i64 e = t[m->cx];
  t[m->cx] =
      (u16)(e + (((y << 16) - e + ((i64)1 << (m->rate - 1))) >> m->rate));
  m->cx = cx & m->mask;
  i64 p = t[m->cx] >> 4;
  tx[k] = (i32)((kStretch[p] * m->scale) >> 8);
  tx[k + 1] = (i32)(((p - 2048) * m->scale) >> 9);
}

// ---------------------------------------------------------------- taps

// The taps of the fits as offsets: i - 1 for x1(i) (the channel's own
// i-th previous sample), -i for x2(i) (the other channel's), in paq8px's
// order. [bits16]: Audio16BitModel's patterns, else Audio8BitModel's.
#define TAPS_MAX 256
static void buildTaps(PxPredictors *pr, int stereo) {
  i32 **t = pr->taps[stereo];
  i64 *nt = pr->ntaps[stereo];
  for (int o = 0; o < NOLS; o++) {
    t[o] = ZNEW(i32, TAPS_MAX);
    nt[o] = 0;
  }
#define X1(o, i) (t[o][nt[o]++] = (i32)((i) - 1))
#define X2(o, i) (t[o][nt[o]++] = (i32)(-(i)))
#define B(c) ((c) ? 1 : 0)
  int bits16 = pr->bits16;
  i64 st = stereo ? 1 : 0;
  if (bits16) {
    if (stereo) {
      for (i64 i = 1; i <= 24; i++) X2(0, i);
      for (i64 i = 1; i <= 104; i++) X1(0, i);
    } else {
      for (i64 i = 1; i <= 128; i++) X1(0, i);
    }
  }
  i64 k1 = 90;
  i64 k2 = k1 - 12 * st;
  for (i64 j = 1, i = 1; j <= k1; j++) {
    X1(1, i);
    i += bits16 ? ((i64)1 << (B(j > 16) + B(j > 32) + B(j > 64)))
                : ((i64)1 << (B(j > 8) + B(j > 16) + B(j > 64)));
  }
  for (i64 j = 1, i = 1; j <= k2; j++) {
    X1(2, i);
    i += (i64)1 << (B(j > 5) + B(j > 10) + B(j > 17) + B(j > 26) + B(j > 37));
  }
  for (i64 j = 1, i = 1; j <= k2; j++) {
    X1(3, i);
    i += (i64)1 << (B(j > 3) + B(j > 7) + B(j > 14) + B(j > 20) + B(j > 33) +
                    B(j > 49));
  }
  for (i64 j = 1, i = 1; j <= k2; j++) {
    X1(4, i);
    i += 1 + B(j > 4) + B(j > 8);
  }
  for (i64 j = 1, i = 1; j <= k1; j++) {
    X1(5, i);
    i += 2 + B(j > 3) + B(j > 9) + B(j > 19) + B(j > 36) + B(j > 61);
  }
  if (stereo) {
    for (i64 i = 1; i <= k1 - k2; i++) {
      X2(2, i);
      X2(3, i);
      X2(4, i);
    }
  }
  if (bits16) {
    k1 = 28;
    k2 = k1 - 6 * st;
    for (i64 i = 1; i <= k2; i++) X1(6, i);
    for (i64 i = 1; i <= k1 - k2; i++) X2(6, i);
    k1 = 32;
    k2 = k1 - 8 * st;
    for (i64 i = 1; i <= k2; i++) X1(7, i);
    for (i64 i = 1; i <= k1 - k2; i++) X2(7, i);
  } else {
    k1 = 28;
    k2 = k1 - 6 * st;
    i64 i = 1;
    for (; i <= k2; i++) {
      X1(0, i);
      X1(6, i);
      X1(7, i);
    }
    for (; i <= 96; i++) X1(0, i);
    if (stereo) {
      for (i = 1; i <= k1 - k2; i++) {
        X2(0, i);
        X2(6, i);
        X2(7, i);
      }
      for (; i <= 32; i++) X2(0, i);
    } else {
      for (; i <= 128; i++) X1(0, i);
    }
  }
#undef X1
#undef X2
#undef B
  pr->tapsBuilt[stereo] = 1;
}

// ---------------------------------------------------------------- _Predictors

typedef struct {
  i64 s, d;
  double rateS, rateD;
} LmsCfg;

static PxPredictors *predictors_new(int bits16, const i64 *num,
                                    const i64 *interval, const double *lambda,
                                    const LmsCfg *lmsCfg) {
  PxPredictors *p = ZNEW(PxPredictors, 1);
  p->bits16 = bits16;
  for (int i = 0; i < NOLS; i++) {
    for (int ch = 0; ch < 2; ch++) {
      pxols_init(&p->ols[i][ch], num[i], interval[i], lambda[i]);
    }
  }
  for (int j = 0; j < NLMS; j++) {
    for (int ch = 0; ch < 2; ch++) {
      lms_init(&p->lms[j][ch], lmsCfg[j].s, lmsCfg[j].d, lmsCfg[j].rateS,
               lmsCfg[j].rateD);
    }
  }
  window_init(&p->hist[0], HIST);
  window_init(&p->hist[1], HIST);
  return p;
}

static void predictors_resetLms(PxPredictors *p) {
  for (int j = 0; j < NLMS; j++) {
    lms_reset(&p->lms[j][0]);
    lms_reset(&p->lms[j][1]);
  }
}

// Learns [sample] of channel [pCh], then predicts channel [ch].
static void predictors_step(PxPredictors *p, i64 sample, i64 pCh, i64 ch,
                            int stereo, i64 lo, i64 hi) {
  double v = (double)sample;
  for (int i = 0; i < NOLS; i++) pxols_update(&p->ols[i][pCh], v);
  for (int j = 0; j < NLMS; j++) lms_update(&p->lms[j][pCh], sample);
  i32 *prd = p->prd;
  for (i64 i = 0; i < NSSM; i++) {
    p->res[i * 2 + pCh] = (i32)(sample - prd[(i * 2 + pCh) * 2]);
  }
  window_push(&p->hist[pCh], v);
  const PxWindow *own = &p->hist[ch];
  const PxWindow *other = &p->hist[stereo ? 1 - ch : ch];
  const double *od = own->data;
  i64 op = own->p;
  const double *xd = other->data;
  i64 xp = other->p;
  int si = stereo ? 1 : 0;
  if (!p->tapsBuilt[si]) buildTaps(p, si);
  for (i64 i = 0; i < NOLS; i++) {
    PxOls *o = &p->ols[i][ch];
    const i32 *t = p->taps[si][i];
    i64 nt = p->ntaps[si][i];
    double *x = o->x;
    for (i64 q = 0; q < nt; q++) {
      i64 a = t[q];
      x[q] = a >= 0 ? od[op + a] : xd[xp - a - 1];
    }
    prd[(i * 2 + ch) * 2] = (i32)roundClip(pxols_predict(o), lo, hi);
  }
  for (i64 j = 0; j < NLMS; j++) {
    prd[((NOLS + j) * 2 + ch) * 2] =
        (i32)roundClip(lms_predict(&p->lms[j][ch], sample), lo, hi);
  }
  i64 x1 = (i64)od[op], x2 = (i64)od[op + 1];
  i64 x3 = (i64)od[op + 2], x4 = (i64)od[op + 3];
  i64 i = NOLS + NLMS;
  prd[(i * 2 + ch) * 2] = (i32)clip(x1 * 2 - x2, lo, hi);
  i++;
  prd[(i * 2 + ch) * 2] = (i32)clip(x1 * 3 - x2 * 3 + x3, lo, hi);
  i++;
  prd[(i * 2 + ch) * 2] = (i32)clip(x1 * 4 - x2 * 6 + x3 * 4 - x4, lo, hi);
  for (i = 0; i < NSSM; i++) {
    i64 k = (i * 2 + ch) * 2;
    prd[k + 1] = (i32)clip((i64)prd[k] + p->res[i * 2 + pCh], lo, hi);
  }
}

// ---------------------------------------------------------------- AudioPxModel

static const i64 kWidths[4] = {8, 13, 4, 5};
static const i64 kRates16[4] = {7, 10, 6, 6};
static const i64 kScaleOls[4] = {128, 128, 86, 128};
static const i64 kScaleOther[4] = {86, 86, 64, 86};
static const i64 kSizesExtra[6] = {8192, 4096, 2560, 256, 20, 1024};

static void apx_mix(ZModel *self, ZState *s, Mixer *m);
static void apx_setCtx(ZModel *self, ZState *s, Mixer *m);

void audiopxmodel_init(AudioPxModel *m, int extra) {
  memset(m, 0, sizeof(*m));
  m->extra = extra;
  m->info = -1;
  m->b16 = 1;
  m->lastP = 32768;
  m->base.inputs = NSSM * 4 * 2;
  m->base.mix = apx_mix;
  m->base.nsel = extra ? 6 : 5;
  m->base.selSizes = kSizesExtra;
  m->base.setCtx = apx_setCtx;
}

i64 audiopxmodel_tableBytes(void) {
  i64 b = 0;
  for (int i = 0; i < 4; i++) b += NSSM * ((i64)2 << (kWidths[i] + 4));
  b += (i64)4 * NSSM * 64 * 256 * 2;
  // Fits: n * n doubles twice, per channel, per width.
  static const i64 num16[8] = {128, 90, 90, 90, 90, 90, 28, 32};
  for (int i = 0; i < 8; i++) b += (i64)2 * 2 * 2 * num16[i] * num16[i] * 8;
  b += (i64)2 * 2 * (1920 + 704 + 2464) * 8 * 4;
  return b;
}

static void chooseBest(AudioPxModel *m, const i32 *res, i64 pCh, i64 ch) {
  i32 *e = m->errE;
  for (i64 i = 0; i < NSSM; i++) {
    i64 r = res[i * 2 + pCh];
    i64 a = r < 0 ? -r : r;
    i64 k = i * 2 + pCh;
    e[k] = (i32)((i64)e[k] - (e[k] >> 4) + (a > 65535 ? 65535 : a));
  }
  i64 best = 0;
  i64 be = e[ch];
  for (i64 i = 1; i < NSSM; i++) {
    i64 v = e[i * 2 + ch];
    if (v < be) {
      be = v;
      best = i;
    }
  }
  m->best = best;
}

static PxPredictors *build16(AudioPxModel *m) {
  m->maps16 = ZNEW(PxSscm, NSSM * 4);
  i64 mi = 0;
  for (i64 i = 0; i < NSSM; i++) {
    const i64 *sc = i < NOLS ? kScaleOls : kScaleOther;
    for (int j = 0; j < 4; j++) {
      pxsscm_init(&m->maps16[mi++], kWidths[j] + 4, kRates16[j], sc[j]);
    }
  }
  static const i64 num[8] = {128, 90, 90, 90, 90, 90, 28, 32};
  static const i64 interval[8] = {24, 30, 31, 32, 33, 34, 4, 3};
  static const double lambda[8] = {0.998, 0.998, 0.998, 0.998,
                                   0.995, 0.998, 0.999, 0.991};
  static const LmsCfg lms[3] = {
      {1280, 640, 5e-5, 5e-5},
      {640, 64, 7e-5, 1e-5},
      {2456, 8, 2e-5, 2e-6},
  };
  return predictors_new(1, num, interval, lambda, lms);
}

static PxPredictors *build8(AudioPxModel *m) {
  m->maps8 = ZNEW(ResidualMap, 4);
  residualmap_init(&m->maps8[0], NSSM, 64, 64);
  residualmap_init(&m->maps8[1], NSSM, 64, 64);
  residualmap_init(&m->maps8[2], NSSM, 64, 96);
  residualmap_init(&m->maps8[3], NSSM, 64, 96);
  static const i64 num[8] = {128, 90, 90, 90, 90, 90, 28, 28};
  static const i64 interval[8] = {24, 30, 31, 32, 33, 34, 4, 3};
  static const double lambda[8] = {0.9975, 0.9965, 0.996, 0.995,
                                   0.995,  0.9985, 0.98,  0.992};
  static const LmsCfg lms[3] = {
      {1280, 640, 3e-5, 2e-5},
      {640, 64, 8e-5, 1e-5},
      {2456, 8, 1.6e-5, 1e-6},
  };
  return predictors_new(0, num, interval, lambda, lms);
}

static void start(AudioPxModel *m, ZState *s) {
  m->info = s->blockInfo;
  m->b16 = (m->info & 1) != 0;
  m->stereo = (m->info & 2) != 0;
  m->signed8 = (m->info & 4) != 0;
  m->mask = 0;
  m->ch = 0;
  m->lsb = 0;
  PxPredictors *p;
  if (m->b16) {
    if (m->p16 == NULL) m->p16 = build16(m);
    p = m->p16;
  } else {
    if (m->p8 == NULL) m->p8 = build8(m);
    p = m->p8;
  }
  predictors_resetLms(p);
}

static void mix16(AudioPxModel *m, ZState *s, Mixer *mx, i64 bpos) {
  PxPredictors *p = m->p16;
  i64 st = m->stereo ? 1 : 0;
  i64 blockPos = s->blockPos;
  if (bpos == 0 && blockPos != 0) {
    m->ch = m->stereo ? (blockPos & 2) >> 1 : 0;
    m->lsb = blockPos & 1;
    if (m->lsb == 0) {
      i64 v = (zstate_back(s, 2) << 8) | zstate_back(s, 1);
      i64 sample = v >= 0x8000 ? v - 0x10000 : v;
      i64 ch = m->ch;
      i64 pCh = ch ^ st;
      i64 mask = m->mask;
      i64 err = 0;
      const i32 *prd = p->prd;
      for (i64 i = 0; i < NOLS; i++) {
        i64 r = sample - prd[(i * 2 + pCh) * 2];
        i64 a = r < 0 ? -r : r;
        mask = ((mask << 1) | (a > 128 ? 1 : 0)) & 0xFFFFFFFF;
        i64 q = a >> 6;
        err += q * q;
      }
      m->mask = mask;
      i64 el = ilog2(err & 0xFFFFFFFF);
      m->errLog = el > 15 ? 15 : el;
      predictors_step(p, sample, pCh, ch, m->stereo, -32768, 32767);
      if (m->extra) chooseBest(m, p->res, pCh, ch);
    }
    i64 bc = bitCount(m->mask);
    if (bc > 31) bc = 31;
    m->mxCtx = ilog2(bc) * 4 + m->ch * 2 + m->lsb;
    m->sseContext = 0x80 | m->mxCtx;
  }
  i64 c0 = s->c0;
  i64 c1 = s->c4 & 255;
  i64 v;
  if (m->lsb != 0) {
    v = (c1 << 8) | ((c0 << (8 - bpos)) & 255);
  } else {
    v = (c0 << (16 - bpos)) & 0xFFFF;
  }
  i64 b = v >= 0x8000 ? v - 0x10000 : v;
  i64 pos = m->lsb * 8 + bpos;
  i64 y = s->y;
  i32 *tx = mx->tx;
  i64 k = mx->nx;
  i64 ch = m->ch;
  const i32 *prd = p->prd;
  PxSscm *maps = m->maps16;
  if (m->extra) {
    i64 r = prd[(m->best * 2 + ch) * 2] - b;
    i64 s6 = 11 - pos, s10 = 7 - pos;
    m->bestCtx = (clampBits(r >> (s6 < 0 ? 0 : s6), 6) << 4) | pos;
    m->apmContext = (clampBits(r >> (s10 < 0 ? 0 : s10), 10) << 4) | pos;
  }
  i64 sh0 = 9 - pos, sh1 = 4 - pos, sh2 = 13 - pos, sh3 = 12 - pos;
  if (sh0 < 0) sh0 = 0;
  if (sh1 < 0) sh1 = 0;
  if (sh2 < 0) sh2 = 0;
  if (sh3 < 0) sh3 = 0;
  i64 mi = 0;
  for (i64 i = 0; i < NSSM; i++) {
    i64 q = (i * 2 + ch) * 2;
    i64 r0 = prd[q] - b;
    i64 r1 = prd[q + 1] - b;
    pxsscm_mix(&maps[mi++], y, (clampBits(r0 >> sh0, 8) << 4) | pos, tx, k);
    pxsscm_mix(&maps[mi++], y, (clampBits(r0 >> sh1, 13) << 4) | pos, tx,
               k + 2);
    pxsscm_mix(&maps[mi++], y, (clampBits(r0 >> sh2, 4) << 4) | pos, tx,
               k + 4);
    pxsscm_mix(&maps[mi++], y, (clampBits(r1 >> sh3, 5) << 4) | pos, tx,
               k + 6);
    k += 8;
  }
  mx->nx = k;
}

static void mix8(AudioPxModel *m, ZState *s, Mixer *mx, i64 bpos) {
  PxPredictors *p = m->p8;
  i64 st = m->stereo ? 1 : 0;
  // The coding loss of the last bit: 0 to 63 (paq8px State.loss).
  i64 lp = m->lastP;
  m->loss += (s->y == 0 ? lp : 65535 - lp) >> 10;
  if (bpos == 0) {
    i64 blockPos = s->blockPos;
    i64 c1 = s->c4 & 255;
    ResidualMap *maps = m->maps8;
    for (int i = 0; i < 4; i++) residualmap_update(&maps[i], c1);
    m->ch = m->stereo ? (blockPos & 1) : 0;
    i64 ch = m->ch;
    i64 sample = m->signed8 ? (c1 ^ 128) - 128 : c1 - 128;
    i64 pCh = ch ^ st;
    const i32 *prd = p->prd;
    for (i64 i = 0; i < NSSM; i++) {
      i64 q = (i * 2 + pCh) * 2;
      i64 e0 = sample - prd[q];
      if (e0 < 0) e0 = -e0;
      i64 e1 = sample - prd[q + 1];
      if (e1 < 0) e1 = -e1;
      m->errBuf0[i] = (i32)((((i64)m->errBuf0[i] * 15) >> 4) + (e0 & 255));
      m->errBuf1[i] = (i32)((((i64)m->errBuf1[i] * 15) >> 4) + (e1 & 255));
    }
    m->lossQ = ((m->lossQ * 15) >> 4) + m->loss;
    m->loss = 0;
    if (blockPos != 0) {
      i64 mask = m->mask;
      i64 err = 0;
      for (i64 i = 0; i < NOLS; i++) {
        i64 r = sample - prd[(i * 2 + pCh) * 2];
        i64 a = r < 0 ? -r : r;
        mask = ((mask << 1) | (a > 4 ? 1 : 0)) & 0xFFFFFFFF;
        err += a * a;
      }
      m->mask = mask;
      i64 el = ilog2(err & 0xFFFFFFFF);
      m->errLog = el > 15 ? 15 : el;
      predictors_step(p, sample, pCh, ch, m->stereo, -128, 127);
      if (m->extra) chooseBest(m, p->res, pCh, ch);
    }
    i64 bc = bitCount(m->mask);
    if (bc > 31) bc = 31;
    m->mxCtx = ilog2(bc) * 2 + ch;
    m->sseContext = m->mxCtx;
    i64 lq = m->lossQ / 384;
    if (lq > 31) lq = 31;
    ResidualMap *r1 = &maps[0], *r2 = &maps[1], *r3 = &maps[2],
                *r4 = &maps[3];
    for (i64 i = 0; i < NSSM; i++) {
      i64 q = (i * 2 + ch) * 2;
      i64 p0 = (i64)prd[q] + 128, p1 = (i64)prd[q + 1] + 128;
      residualmap_set(r1, p0, (lq << 1) | ch);
      residualmap_set(r2, p1, (lq << 1) | ch);
      i64 e0 = m->errBuf0[i] >> 4, e1 = m->errBuf1[i] >> 4;
      residualmap_set(r3, p0, ((e0 > 31 ? 31 : e0) << 1) | ch);
      residualmap_set(r4, p1, ((e1 > 31 ? 31 : e1) << 1) | ch);
    }
  }
  i64 c0 = s->c0;
  if (m->extra) {
    i64 raw = (c0 << (8 - bpos)) & 255;
    i64 b = m->signed8 ? (raw ^ 0x80) - 128 : raw - 128;
    i64 r = p->prd[(m->best * 2 + m->ch) * 2] - b;
    i64 s6 = 3 - bpos;
    m->bestCtx = (clampBits(r >> (s6 < 0 ? 0 : s6), 6) << 4) | bpos;
    m->apmContext = (clampBits(r, 10) << 4) | bpos;
  }
  for (int i = 0; i < 4; i++) residualmap_mix(&m->maps8[i], mx, bpos, c0);
}

static void apx_mix(ZModel *self, ZState *s, Mixer *mx) {
  AudioPxModel *m = (AudioPxModel *)self;
  i64 bpos = s->bpos;
  m->bpos = bpos;
  if (bpos == 0 && (s->blockPos == 0 || s->blockInfo != m->info)) start(m, s);
  if (m->b16) {
    mix16(m, s, mx, bpos);
  } else {
    mix8(m, s, mx, bpos);
  }
}

static void apx_setCtx(ZModel *self, ZState *s, Mixer *mx) {
  AudioPxModel *m = (AudioPxModel *)self;
  i64 bpos = s->bpos;
  i64 c0 = s->c0;
  i64 c1 = s->c4 & 255;
  if (m->b16) {
    mixer_set(mx, (m->errLog << 9) | (m->lsb << 8) | c0);
    mixer_set(mx, ((m->mask & 255) << 4) | (m->ch << 3) | (m->lsb << 2) |
                      (bpos >> 1));
    mixer_set(mx, (m->mxCtx << 7) | (c1 >> 1));
    mixer_set(mx, (m->errLog << 4) | (m->ch << 3) | (m->lsb << 2) |
                      (bpos >> 1));
    mixer_set(mx, m->mxCtx);
    if (m->extra) mixer_set(mx, m->bestCtx);
  } else {
    mixer_set(mx, (m->errLog << 8) | c0);
    mixer_set(mx, ((m->mask & 255) << 3) | (m->ch << 2) | (bpos >> 1));
    mixer_set(mx, (m->mxCtx << 7) | (c1 >> 1));
    mixer_set(mx, (m->errLog << 4) | (m->ch << 3) | bpos);
    mixer_set(mx, m->mxCtx);
    if (m->extra) mixer_set(mx, m->bestCtx);
  }
}

// ---------------------------------------------------------------- AudioSse

void audiosse_init(AudioSse *a) {
  apmpx_init(&a->a0, 1 << 14, 24, 1023);
  apmpost_init(&a->postA, 8);
  apmpost_init(&a->postB, 8);
  apmpx_init(&a->a1, 1 << 14, 24, 1023);
}

i64 audiosse_p(AudioSse *a, i64 y, i64 pr, i64 bpos, i64 m3, i64 ctx,
               i64 actx) {
  i64 q0 = apmpx_pp(&a->a0, y, pr, ((ctx << 6) | (bpos << 3) | m3) & 0x3FFF);
  i64 q1 = apmpx_pp(&a->a1, y, pr, actx & 0x3FFF);
  i64 p0 = (q0 + q1 + 1) >> 1;
  // zcm: the APM side weighs 7/8 (paq8px: 1/2).
  i64 pa = apmpost_pp(&a->postA, y, pr, bpos);
  i64 pb = apmpost_pp(&a->postB, y, p0 >> 4, bpos);
  i64 p = (pa + pb * 7 + 4) >> 3;
  if (p < 1) p = 1;
  if (p > 65535) p = 65535;
  return p;
}
