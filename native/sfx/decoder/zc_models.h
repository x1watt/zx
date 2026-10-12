// zxsfx decoder: port of zcm_models.dart (the models of zcm).
//
// Designs from paq8l and lpaq1 (Matt Mahoney: match, word, sparse,
// record, indirect and the x86 context of execxt, which paq8 credits to
// Alexander Rhatushnyak and Serge Osnach for the exe work) and paq8px
// (Marcio Pais, Zoltan Gotthardt and others: several match lengths, the
// line and column contexts of the text models). Dmc after Cormack and
// Horspool.

#ifndef ZC_MODELS_H
#define ZC_MODELS_H

#include "zc.h"

// Orders 0 to N (ZcmOrders: see ordermodel_hits).
typedef struct {
  ZModel base;
  DirectMap o0, o1;
  ContextMap cm;
  i32 *orders;
  i64 norders;
  int pairs;
  u32 *slow, *fast;
  i64 i0, i1;
} OrderModel;
// Dart defaults: rich true, bh false, pairs false.
void ordermodel_init(OrderModel *m, const i64 *orders, i64 norders, i64 bytes,
                     int rich, int bh, int pairs);
ZINLINE i64 ordermodel_hits(const OrderModel *m) { return m->cm.hits; }

// Match model (two hash lengths).
typedef struct {
  ZMatchModel base;
  i32 *htS, *htL;
  i64 mask, minS, minL;
  i64 ptr, len, exp;
  StateMap sm1, sm2;
  i64 bufMask;
} MatchModel;
// Dart defaults: minS 5, minL 12.
void matchmodel_init(MatchModel *m, i64 tableEntries, i64 bufBytes, i64 minS,
                     i64 minL);
ZINLINE i64 matchmodel_length(const MatchModel *m) { return m->len; }
ZINLINE i64 matchmodel_expectedByte(const MatchModel *m) {
  return m->len > 0 ? m->exp : -1;
}

// Word and text model.
typedef struct {
  ZModel base;
  ContextMap cm;
  i64 w0, w1, w2, w3, w4;
  i64 text0;
  i64 lastNl, prevNl;
  i64 indent, inIndent;
  i64 punct;
  i64 num;
  u8 brackets[64];
  i64 depth;
} WordModel;
// contexts: 5, 10 or 16 (Dart default 16).
void wordmodel_init(WordModel *m, i64 bytes, i64 contexts);

// Sparse contexts.
typedef struct {
  ZModel base;
  ContextMap cm;
} SparseModel;
void sparsemodel_init(SparseModel *m, i64 bytes, int light);

// Indirect contexts.
typedef struct {
  ZModel base;
  ContextMap cm;
  int full;
  u32 *t1;
  u16 *t2, *t3, *t4;
  u32 *t5;
  u32 *large;
  i64 largeMask;
  i64 chars4;
  i64 i, k;
} IndirectModel;
void indirectmodel_init(IndirectModel *m, i64 bytes, int full);

// Character group contexts.
typedef struct {
  ZModel base;
  ContextMap cm;
  i64 g1, g2, g3;
} CharGroupModel;
void chargroupmodel_init(CharGroupModel *m, i64 bytes);

// Record model.
typedef struct {
  ZModel base;
  ContextMap cm;
  i32 *cpos1, *cpos2, *cpos3, *cpos4;
  i32 *wpos1;
  i64 rlen, rlen1, rlen2, rcount1, rcount2;
} RecordModel;
void recordmodel_init(RecordModel *m, i64 bytes);
ZINLINE i64 recordmodel_recordLength(const RecordModel *m) { return m->rlen; }

// x86 contexts.
typedef struct {
  ZModel base;
  ContextMap cm;
} ExeModel;
// contexts: 8 (Dart default) or fewer.
void exemodel_init(ExeModel *m, i64 bytes, i64 contexts);

// Dynamic Markov coding. [gate] may be NULL (Dart: null).
typedef struct {
  ZModel base;
  GainGate *gate;
  i32 *nx0, *nx1;
  u8 *state;
  u16 *c0, *c1;
  i64 size;
  StateMap sm;
  i64 top, curr, threshold, baseThreshold;
  ZRandom rnd;
} DmcModel;
// threshold: Dart default 256.
void dmcmodel_init(DmcModel *m, i64 bytes, i64 threshold);
i64 dmcmodel_nodesFor(i64 bytes);

#endif
