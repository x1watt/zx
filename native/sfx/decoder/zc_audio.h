// zxsfx decoder: port of zcm_audio.dart, the audio model of levels 3 to 6
// (8 and 16 bit PCM, mono or stereo).
//
// After the Audio8BitModel and Audio16BitModel of paq8px (Marcio Pais,
// after Florin Ghido's 'An asymptotically optimal predictor for stereo
// lossless audio compression'; tuned by Zoltan Gotthardt), with paq8px's
// OLS and LMS by Sebastian Lehmann and the residual maps of paq8px
// (SmallStationaryContextMap).

#ifndef ZC_AUDIO_H
#define ZC_AUDIO_H

#include "zc.h"
#include "zc_maps.h"

// Predictor configurations (counts of the full and the light model).
#define AUDIO_MAX_OLS 4
#define AUDIO_MAX_LMS 1
#define AUDIO_MAX_RMS 2
#define AUDIO_MAX_PRED (AUDIO_MAX_OLS + AUDIO_MAX_LMS + AUDIO_MAX_RMS + 3)

// Normalized LMS filter (_Nlms).
typedef struct {
  i64 nOwn, nOther;
  double mu;
  double *x, *w;
  double pred;
} AudioNlms;

// paq8px LMS with RMSprop steps (_RmsLms).
typedef struct {
  i64 nOwn, nOther;
  double rateOwn, rateOther;
  double *x, *w, *eg;
  double pred;
} AudioRmsLms;

// One residual map (_Sscm).
typedef struct {
  u16 *t;
  i64 mask, rate, cx;
} AudioSscm;

typedef struct {
  ZModel base;
  int full;
  i64 hist;
  i64 nPred, nOls, nLms, nRms;
  double *h[2];
  i32 hp[2];
  Ols ols[AUDIO_MAX_OLS][2];
  AudioNlms lms[AUDIO_MAX_LMS][2];
  AudioRmsLms rms[AUDIO_MAX_RMS][2];
  i32 *prd0, *prd1, *res;
  AudioSscm *maps;
  i64 info, bits, channels, ch, lsb, mask, errLog;
} AudioModel;

// [allowance]: bytes for the tables; [full]: the larger fits and filters
// (Dart default true; the predictor passes audio >= 2).
void audiomodel_init(AudioModel *m, i64 allowance, int full);
// Context bits of the residual maps for [allowance] bytes (Dart default
// nPred: 15).
i64 audiomodel_mapBits(i64 allowance, i64 nPred);
// Table bytes of a model with [allowance] (at most that).
i64 audiomodel_tableBytes(i64 allowance);

#endif
