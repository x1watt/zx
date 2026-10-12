// zxsfx decoder: port of zcm_match.dart, the match model of paq8px.
//
// A port of paq8px's MatchModel and MatchInfo (the paq8px authors, after
// the match model of paq8 by Matt Mahoney).

#ifndef ZC_MATCH_H
#define ZC_MATCH_H

#include "zc.h"
#include "zc_maps.h"

#define PXMATCH_N 4

// The private _Sm of zcm_match.dart: a StateMap that only learns in the
// contexts it predicted in.
typedef struct {
  u32 *t;
  i64 cx;
} PxSm;

// paq8px MatchModel with up to 4 candidates and recovery. A ZMatchModel
// (ZcmMatchInfo) with one mixer selector of 20 contexts.
typedef struct {
  ZMatchModel base;
  u32 *table;
  i64 hashBits;
  PxSm sm0, sm1, sm2;
  ContextMap cm;
  LargeStationaryMap mapL;
  StationaryMap map;
  IndirectContext iCtx;
  i32 len[PXMATCH_N], idx[PXMATCH_N], lenBak[PXMATCH_N], idxBak[PXMATCH_N],
      exp[PXMATCH_N];
  u8 delta[PXMATCH_N];
  i64 active;
  int mapsMixed;
  i64 lensText[3], lensBinary[3], lensExe[3];
  i64 l1, l2, l3;
  // Results of the last mix.
  i64 length, expected, mode5, mode3;
  int isDelta;
} PxMatchModel;

// [bytes]: the position table; [mapBytes]: the context map. The lens
// arrays have 3 entries (Dart default {5, 7, 9}); mapLBits Dart default 20.
void pxmatchmodel_init(PxMatchModel *m, i64 bytes, i64 mapBytes,
                       const i64 *lensText, const i64 *lensBinary,
                       const i64 *lensExe, i64 mapLBits);
// PxMatchModel.tableBytes.
i64 pxmatchmodel_tableBytes(i64 bytes, i64 mapLBits);

ZINLINE i64 pxmatchmodel_length(const PxMatchModel *m) { return m->length; }
ZINLINE i64 pxmatchmodel_expectedByte(const PxMatchModel *m) {
  return m->length > 0 ? m->expected : -1;
}
ZINLINE i64 pxmatchmodel_length2(const PxMatchModel *m) {
  return m->isDelta ? 1 : (m->length == 0 ? 0 : (m->length <= 7 ? 2 : 3));
}
ZINLINE i64 pxmatchmodel_mode3(const PxMatchModel *m) { return m->mode3; }
ZINLINE i64 pxmatchmodel_mode5(const PxMatchModel *m) { return m->mode5; }

#endif
