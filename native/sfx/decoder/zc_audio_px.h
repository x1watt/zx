// zxsfx decoder: port of zcm_audio_px.dart, paq8px's audio models
// (Audio8BitModel and Audio16BitModel), the audio model of levels 7 to 9,
// and AudioSse, paq8px's audio SSE stage.
//
// Credits: Marcio Pais (the audio models, after Florin Ghido's 'An
// asymptotically optimal predictor for stereo lossless audio
// compression'), Sebastian Lehmann (OLS and LMS), Zoltan Gotthardt and
// the other paq8px authors (tuning, the residual maps).

#ifndef ZC_AUDIO_PX_H
#define ZC_AUDIO_PX_H

#include "zc.h"
#include "zc_maps.h"

#define AUDIOPX_NOLS 8
#define AUDIOPX_NLMS 3
#define AUDIOPX_NSSM (AUDIOPX_NOLS + AUDIOPX_NLMS + 3)

// paq8px OLS of this file (_Ols, not zc_maps.h Ols).
typedef struct {
  i64 n, np, interval;
  double lambda;
  double *x, *w, *c, *b, *l;
  i64 since;
} PxOls;

// A history of the most recent values first (_Window).
typedef struct {
  i64 len;
  double *data;
  i64 p;
} PxWindow;

// paq8px LMS (_Lms).
typedef struct {
  i64 s, d;
  double rateS, rateD;
  double *w, *eg;
  PxWindow own, other;
  double pred;
} PxLms;

// paq8px SmallStationaryContextMap with one input bit (_Sscm).
typedef struct {
  u16 *t;
  i64 mask, rate, scale, cx;
} PxSscm;

// The predictors of one sample width (_Predictors).
typedef struct {
  int bits16;
  PxOls ols[AUDIOPX_NOLS][2];
  PxLms lms[AUDIOPX_NLMS][2];
  PxWindow hist[2];
  // Taps per stereo flag and fit: offsets, and their counts.
  i32 *taps[2][AUDIOPX_NOLS];
  i64 ntaps[2][AUDIOPX_NOLS];
  int tapsBuilt[2];
  i32 prd[AUDIOPX_NSSM * 4];
  i32 res[AUDIOPX_NSSM * 2];
} PxPredictors;

typedef struct {
  ZModel base;
  PxPredictors *p16, *p8;
  PxSscm *maps16; // AUDIOPX_NSSM * 4 once built
  ResidualMap *maps8; // 4 once built
  i64 info;
  int b16, stereo, signed8;
  i64 ch, lsb, mask, errLog, mxCtx;
  i64 loss, lossQ;
  i32 errBuf0[AUDIOPX_NSSM], errBuf1[AUDIOPX_NSSM];
  // The final 16 bit probability of the last bit (set by the predictor).
  i64 lastP;
  i64 bpos;
  // State.Audio of paq8px (the context of the audio SSE stage).
  i64 sseContext;
  int extra;
  i32 errE[AUDIOPX_NSSM * 2];
  i64 best, bestCtx;
  // The residual context of the best predictor for the SSE stage.
  i64 apmContext;
} AudioPxModel;

// [extra]: Dart default true (the predictor uses the default).
void audiopxmodel_init(AudioPxModel *m, int extra);
// The weight set of the final mixer layer: the bit of the sample.
ZINLINE i64 audiopxmodel_finalContext(const AudioPxModel *m) {
  return m->b16 ? ((m->lsb << 3) | m->bpos) : m->bpos;
}
ZINLINE i64 audiopxmodel_sseContext(const AudioPxModel *m) {
  return m->sseContext;
}
ZINLINE i64 audiopxmodel_apmContext(const AudioPxModel *m) {
  return m->apmContext;
}
ZINLINE void audiopxmodel_setLastP(AudioPxModel *m, i64 p) { m->lastP = p; }
// Bytes of the tables (both sample widths).
i64 audiopxmodel_tableBytes(void);

// paq8px's SSE stage of audio.
typedef struct {
  ApmPx a0;
  ApmPost postA, postB;
  ApmPx a1;
} AudioSse;
void audiosse_init(AudioSse *a);
// Refines the mixer output [pr] (12 bits) after bit [y]; 16 bit result.
i64 audiosse_p(AudioSse *a, i64 y, i64 pr, i64 bpos, i64 m3, i64 ctx,
               i64 actx);
#define AUDIOSSE_TABLE_BYTES \
  ((i64)2 * (1 << 14) * 24 * 4 + (i64)2 * 8 * 4096 * 8)

#endif
