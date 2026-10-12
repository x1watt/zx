// zxsfx decoder: a zcm stream (port of the decoding side of zcm.dart).

#ifndef ZC_ZCM_H
#define ZC_ZCM_H

#include "zc.h"

// A bit predictor of a zcm stream (zcm_predictor.dart ZcmBitPredictor):
// level 1 is the fast predictor, levels 2 to 9 ZcmPredictor.
typedef struct ZPredictor ZPredictor;
ZPredictor *zpredictor_new(i64 level, i64 budgetBytes, i64 lstmCells,
                           i64 lstmLayers, i64 lstmHorizon);
i64 zpredictor_p(ZPredictor *p);
void zpredictor_update(ZPredictor *p, i64 bit);
void zpredictor_setSegment(ZPredictor *p, i64 type, i64 info);

// CRC-32 (zip, the Crc32 of the Dart code).
u32 crc32_update(u32 crc, const u8 *p, i64 n);

// Decodes the zcm stream in[0..inLen) into out[0..outLen) (exactly outLen
// bytes). Returns NULL, or an error message.
const char *zcm_decode(const u8 *in, i64 inLen, u8 *out, i64 outLen);

// The memory a stream needs is decided by its header (the model budget):
// returns the budget in bytes, or -1 when the header is bad.
i64 zcm_budget(const u8 *in, i64 inLen);

#endif
