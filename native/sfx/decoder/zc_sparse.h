// zxsfx decoder: port of the similarity model of zcm_sparse.dart
// (paq8px's SimilarityModel and SimilarityModelPair, by the paq8px
// authors). The other models of that file (SparseMatchModel,
// SparseBitModel, LinearPredictionModel) are never built by the codec and
// are not ported.

#ifndef ZC_SPARSE_H
#define ZC_SPARSE_H

#include "zc.h"
#include "zc_maps.h"

// One paq8px SimilarityModel (the slow or the fast one of a pair).
typedef struct {
  i64 maxDistance, maxRecord;
  ResidualMap mapR1, mapR2;
  ContextMap cm;
  u16 *ema;
  i32 matchIndex[2], matchScore[2];
  i64 recordLen, recordScore;
  i64 mctx1, mctx2;
} Similarity;

// paq8px SimilarityModelPair over the last [maxDistance] bytes.
typedef struct {
  ZModel base;
  Similarity slow, fast;
  i64 maxDistance;
  i64 warmup;
  int started;
} SimilarityModel;

void similaritymodel_init(SimilarityModel *m, i64 bytes, i64 maxDistance);

#endif
