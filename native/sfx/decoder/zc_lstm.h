// zxsfx decoder: port of zcm_lstm.dart, the LSTM byte model of level 9.
//
// After the LSTM of cmix (Byron Knoll; lstm-compress and cmix v21:
// mixer/lstm.cpp, mixer/lstm-layer.cpp). See zcm_lstm.dart for the
// design; this is a literal translation with doubles in the same order.

#ifndef ZC_LSTM_H
#define ZC_LSTM_H

#include "zc.h"

// _Gate
typedef struct {
  i64 n;      // cells
  i64 rowLen; // 256 symbol columns + inputs
  i64 wlen;   // n * rowLen
  double *w;
  double *u; // accumulated gradient
  double *m;
  double *v;
  double *gamma, *beta;
  double *gammaU, *gammaM, *gammaV;
  double *betaU, *betaM, *betaV;
  double *error;
  double *norm;      // horizon * n
  double *ivar;      // horizon
  double *state;     // horizon * n (after the nonlinearity)
  double *transpose; // inputs * n
} ZLstmGate;

// _Layer
typedef struct {
  i64 n;
  i64 inputs; // own hidden + lower hidden + aux + bias
  i64 horizon;
  ZLstmGate forget, node, output;
  double *cell;
  double *stateError;
  double *storedError;
  double *tanhState; // horizon * n
  double *inputGate; // horizon * n
  double *lastState; // horizon * n
  double *x;         // horizon * inputs
  i64 updateSteps;
} ZLstmLayer;

// ZcmLstm
typedef struct {
  i64 cells, layers, horizon, aux;
  double *auxv;
  double learningRate, gradientClip;
  ZLstmLayer *lay;
  double *hidden; // layers * cells + 1 (bias)
  i64 hl;         // hidden length
  double *hiddenError;
  double *wOut; // 256 * hl
  double *out;  // horizon * 256
  i32 *inputHist;
  i64 epoch;
  i64 updateLimit;
  double *beta1Pow, *beta2Pow; // 3001 each
  i64 seed;
} ZcmLstm;

// ZcmLstm(cells:, layers:, horizon:, aux:) with learningRate 0.03 and
// gradientClip 10.0 (the defaults, the only values zcm uses).
void zlstm_init(ZcmLstm *l, i64 cells, i64 layers, i64 horizon, i64 aux);
// setAux: [aux] values.
void zlstm_setAux(ZcmLstm *l, const double *v);
// probabilities: 256 doubles (a view into the output).
const double *zlstm_probabilities(const ZcmLstm *l);
void zlstm_perceive(ZcmLstm *l, i64 symbol);

#endif
