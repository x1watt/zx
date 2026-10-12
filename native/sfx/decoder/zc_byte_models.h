// zxsfx decoder: port of zcm_byte_models.dart, byte predictors turned into
// bit predictions (level 9).
//
// cmix (Byron Knoll) uses byte models: a model gives a probability for
// each of the 256 next bytes, and the bit predictions follow from the sums
// over the bytes that agree with the bits coded so far (ByteModel in
// cmix). The models here: PPMd var.H (Dmitry Shkarin; zc_ppmd.c, used as
// a predictor the way cmix's models/ppmd.cpp uses PPMd var.J), the LSTM of
// zc_lstm.c and cmix's ByteMixer.

#ifndef ZC_BYTE_MODELS_H
#define ZC_BYTE_MODELS_H

#include "zc.h"
#include "zc_lstm.h"
#include "zc_ppmd.h"

// _BitsFromBytes
typedef struct {
  double cum[257];
  i64 lo, hi;
} ZBitsFromBytes;

// _ByteModelBase: inputs 3 (constant), no mixer selectors.
typedef struct ZByteModel ZByteModel;
struct ZByteModel {
  ZModel base;
  ZBitsFromBytes bits;
  StateMap sm;
  int started;
  // The quick gain check (PPMd at level 9), NULL for none.
  GainGate *gate;
  // Learns [byte] (the byte just coded) and sets the next distribution.
  void (*byteUpdate)(ZByteModel *self, i64 byte);
  // The distribution of the next byte (256 doubles, fixed storage).
  double *distribution;
};

// PpmdByteModel
typedef struct {
  ZByteModel b;
  Ppmd7 *p;
  double probs[256];
  u8 mask[256];
} PpmdByteModel;
void ppmdbytemodel_init(PpmdByteModel *m, i64 order, i64 memBytes);

// LstmByteModel
typedef struct {
  ZByteModel b;
  ZcmLstm lstm;
  double probs[256];
} LstmByteModel;
void lstmbytemodel_init(LstmByteModel *m, i64 cells, i64 layers,
                        i64 horizon);

// ByteMixerModel: [source] must come before it in the model list.
typedef struct {
  ZByteModel b;
  ZcmLstm lstm;
  PpmdByteModel *source;
  double in[256];
  double probs[256];
} ByteMixerModel;
void bytemixermodel_init(ByteMixerModel *m, PpmdByteModel *source,
                         i64 cells, i64 layers, i64 horizon);

// ppmdUpdateSymbol: updates the PPMd model with [symbol].
void ppmdUpdateSymbol(Ppmd7 *p, i64 symbol);

#endif
