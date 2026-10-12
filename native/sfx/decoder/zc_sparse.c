// zxsfx decoder: port of the similarity model of zcm_sparse.dart.
//
// Port of paq8px's SimilarityModel / SimilarityModelPair (the paq8px
// authors): for every distance up to a window, a running mean of how far
// the byte at that distance was from the actual byte; the closest
// distances give predictions (like a match that tolerates small
// differences), and the best record length gives row predictions
// (undetected images and tables).

#include "zc_sparse.h"

#define NRM1 16
#define NRM2 2
#define NCM 8

// |int8(a - b)| (paq8px rabs).
ZINLINE i64 rabs(i64 a, i64 b) {
  i64 d = (i8)(a - b);
  return d < 0 ? -d : d;
}

// Dart x.toSigned(16).
ZINLINE i64 sx16(i64 x) { return (i16)x; }

ZINLINE i64 imin2(i64 a, i64 b) { return a < b ? a : b; }

static void similarity_init(Similarity *sm, i64 bytes, i64 maxDistance,
                            i64 maxRecord) {
  sm->maxDistance = maxDistance;
  sm->maxRecord = maxRecord;
  residualmap_init(&sm->mapR1, NRM1, 32, 64);
  residualmap_init(&sm->mapR2, NRM2, 64 * 16, 64);
  contextmap_init(&sm->cm, bytes, NCM, 0, 1);
  sm->ema = ZNEW(u16, maxDistance);
  for (i64 i = 0; i < maxDistance; i++) sm->ema[i] = 64 << 8;
  sm->recordLen = 1;
  sm->recordScore = 0;
  sm->mctx1 = sm->mctx2 = 0;
}

#define SIMILARITY_INPUTS ((NRM1 + NRM2) * 2 + NCM * 6)

// SimilarityModel::update: the best record length.
static void similarity_findRecord(Similarity *sm, i64 warmup) {
  i64 count = warmup < sm->maxRecord ? warmup : sm->maxRecord;
  i64 best = 0x7FFFFFFF;
  const u16 *e = sm->ema;
  i64 md = sm->maxDistance;
  for (i64 i = 0; i < count; i++) {
    i64 rl = count - i;
    i64 r = (i64)e[md - rl] + e[md - rl * 2] + e[md - rl * 3] + e[md - rl * 4];
    if (r <= best) {
      sm->recordLen = rl;
      best = r;
    }
  }
  sm->recordScore = best == 0x7FFFFFFF ? 0 : best;
}

// SimilarityModel::mix at a byte boundary.
static void similarity_byteContexts(Similarity *sm, ZState *s) {
  const u8 *buf = s->buf;
  i64 bm = s->bufMask;
  i64 pos = s->pos;
  i64 md = sm->maxDistance;
  const u16 *ema = sm->ema;
  ResidualMap *r1m = &sm->mapR1, *r2m = &sm->mapR2;
  i64 d0 = md - sm->matchIndex[0], d1 = md - sm->matchIndex[1];
  i64 e0 = buf[(pos - d0) & bm];
  i64 e1 = buf[(pos - d1) & bm];
  i64 ms0 = sm->matchScore[0], ms1 = sm->matchScore[1];
  residualmap_set(r1m, e0, (ms0 >> 8) < 31 ? ms0 >> 8 : 31);
  residualmap_set(r1m, e1, (ms1 >> 8) < 31 ? ms1 >> 8 : 31);
  i64 r = rabs(e0, e1) >> 1;
  residualmap_set(r2m, e0,
                  ((r < 63 ? r : 63) << 4) | ((ms0 >> 9) < 15 ? ms0 >> 9 : 15));
  i64 w = buf[(pos - 1) & bm], ww = buf[(pos - 2) & bm];
  i64 wwww = buf[(pos - 4) & bm];
  i64 he0, he1, he2;
  {
    i64 n0 = buf[(pos - d0) & bm], nw0 = buf[(pos - d0 - 1) & bm];
    i64 nww0 = buf[(pos - d0 - 2) & bm], nwwww0 = buf[(pos - d0 - 4) & bm];
    he0 = sx16(w + n0 - nw0);
    residualmap_set(r1m, he0, imin2(rabs(w, ww + nw0 - nww0), 31));
    he1 = sx16(ww + n0 - nww0);
    residualmap_set(r1m, he1, imin2(rabs(ww, wwww + nww0 - nwwww0), 31));
  }
  {
    i64 n0 = buf[(pos - d1) & bm], nw0 = buf[(pos - d1 - 1) & bm];
    i64 nww0 = buf[(pos - d1 - 2) & bm], nwwww0 = buf[(pos - d1 - 4) & bm];
    he2 = sx16(w + n0 - nw0);
    residualmap_set(r1m, he2, imin2(rabs(w, ww + nw0 - nww0), 31));
    residualmap_set(r1m, sx16(ww + n0 - nww0),
                    imin2(rabs(ww, wwww + nww0 - nwwww0), 31));
  }
  // Record model.
  i64 rl = sm->recordLen;
  i64 n = buf[(pos - rl) & bm], nn = buf[(pos - 2 * rl) & bm],
      nnn = buf[(pos - 3 * rl) & bm], nnnn = buf[(pos - 4 * rl) & bm];
  i64 bestN = n, bestNW = buf[(pos - (rl + 1)) & bm],
      bestNWW = buf[(pos - (rl + 2)) & bm];
  i64 bestNWWWW = buf[(pos - (rl + 4)) & bm];
  i64 scoreN = ema[md - rl], scoreNN = ema[md - rl * 2];
  i64 scoreNNN = ema[md - rl * 3], scoreNNNN = ema[md - rl * 4];
  i64 bestScore = scoreN;
  if (scoreNN < bestScore) {
    bestN = nn;
    bestNW = buf[(pos - (rl * 2 + 1)) & bm];
    bestNWW = buf[(pos - (rl * 2 + 2)) & bm];
    bestNWWWW = buf[(pos - (rl * 2 + 4)) & bm];
    bestScore = scoreNN;
  }
  if (scoreNNN < bestScore) {
    bestN = nnn;
    bestNW = buf[(pos - (rl * 3 + 1)) & bm];
    bestNWW = buf[(pos - (rl * 3 + 2)) & bm];
    bestNWWWW = buf[(pos - (rl * 3 + 4)) & bm];
    bestScore = scoreNNN;
  }
  if (scoreNNNN < bestScore) {
    bestN = nnnn;
    bestNW = buf[(pos - (rl * 4 + 1)) & bm];
    bestNWW = buf[(pos - (rl * 4 + 2)) & bm];
    bestNWWWW = buf[(pos - (rl * 4 + 4)) & bm];
    bestScore = scoreNNNN;
  }
  bestScore >>= 8;
  scoreN >>= 8;
  scoreNN >>= 8;
  scoreNNN >>= 8;
  scoreNNNN >>= 8;
  i64 columnScore =
      rabs(bestN, n) + rabs(bestN, nn) + rabs(bestN, nnn) + rabs(bestN, nnnn);
  residualmap_set(r2m, bestN,
                  (imin2(bestScore >> 1, 31) << 5) |
                      imin2(columnScore >> 2, 31));
  residualmap_set(r1m, sx16(w + bestN - bestNW),
                  imin2(rabs(w, ww + bestNW - bestNWW), 31));
  residualmap_set(r1m, sx16(ww + bestN - bestNWW),
                  imin2(rabs(ww, wwww + bestNWW - bestNWWWW), 31));
  residualmap_set(r1m, n, imin2(scoreN >> 1, 31));
  residualmap_set(r1m, nn, imin2(scoreNN >> 1, 31));
  residualmap_set(r1m, nnn, imin2(scoreNNN >> 1, 31));
  residualmap_set(r1m, nnnn, imin2(scoreNNNN >> 1, 31));
  i64 nw = buf[(pos - (rl + 1)) & bm], nnw = buf[(pos - (2 * rl + 1)) & bm];
  i64 o2 = sx16(2 * n - nn);
  residualmap_set(r1m, o2, imin2(rabs(w, 2 * nw - nnw), 31));
  i64 nnnw = buf[(pos - (3 * rl + 1)) & bm],
      nnnnw = buf[(pos - (4 * rl + 1)) & bm],
      nnnnn = buf[(pos - (5 * rl)) & bm];
  i64 o3 = sx16(3 * n - 3 * nn + nnn);
  residualmap_set(r1m, o3,
                  imin2(rabs(n, 3 * nn - 3 * nnn + nnnn) +
                            rabs(w, 3 * nw - 3 * nnw + nnnw),
                        63) >>
                      1);
  i64 o4 = sx16(4 * n - 6 * nn + 4 * nnn - nnnn);
  residualmap_set(r1m, o4,
                  imin2(rabs(n, 4 * nn - 6 * nnn + 4 * nnnn - nnnnn) +
                            rabs(w, 4 * nw - 6 * nnw + 4 * nnnw - nnnnw),
                        63) >>
                      1);
  i64 lo = n, hi = n;
  if (nn < lo) lo = nn;
  if (nnn < lo) lo = nnn;
  if (nnnn < lo) lo = nnnn;
  if (nn > hi) hi = nn;
  if (nnn > hi) hi = nnn;
  if (nnnn > hi) hi = nnnn;
  residualmap_set(r1m, (n + nn + nnn + nnnn + 2) >> 2,
                  imin2((hi - lo) >> 1, 31));
  // Hashed contexts.
  ContextMap *cm = &sm->cm;
  contextmap_set(cm, 0, hash4(n, nn, nnn, nnnn));
  contextmap_set(cm, 1, hash2(1, e0));
  contextmap_set(cm, 2, hash2(2, e1));
  contextmap_set(cm, 3, hash2(3, he0 + 256));
  contextmap_set(cm, 4, hash2(4, he1 + 256));
  contextmap_set(cm, 5, hash2(5, he2 + 256));
  contextmap_set(cm, 6, hash2(6, o2 + 256));
  contextmap_set(cm, 7, hash2(7, bestN));
  i64 columnCtx = columnScore <= 1
                      ? 0
                      : (columnScore < (sm->recordScore >> 10) * 3 ? 1 : 2);
  i64 matchCtx = ms0 == 0 ? 0 : 1 + imin2((ms0 >> 8) >> 2, 30);
  sm->mctx1 = (columnCtx << 5) | matchCtx;
  sm->mctx2 = (columnCtx << 1) | (sm->recordScore == 0 ? 1 : 0);
}

static const i64 kSizes[4] = {3 * 32, 3 * 2, 3 * 32, 3 * 2};

static void sim_mix(ZModel *self, ZState *s, Mixer *m);
static void sim_setCtx(ZModel *self, ZState *s, Mixer *m);

void similaritymodel_init(SimilarityModel *m, i64 bytes, i64 maxDistance) {
  memset(m, 0, sizeof(*m));
  i64 rec = maxDistance / 4 < 1024 ? maxDistance / 4 : 1024;
  similarity_init(&m->slow, bytes / 2, maxDistance, rec);
  similarity_init(&m->fast, bytes / 4, maxDistance,
                  rec / 2 < 512 ? rec / 2 : 512);
  m->maxDistance = maxDistance;
  m->warmup = 0;
  m->started = 0;
  m->base.inputs = SIMILARITY_INPUTS * 2;
  m->base.mix = sim_mix;
  m->base.nsel = 4;
  m->base.selSizes = kSizes;
  m->base.setCtx = sim_setCtx;
}

// SimilarityModelPair::update: the running means of |int8(x - c1)| for
// every distance, and the two closest distances of each model.
static void updateEma(SimilarityModel *m, ZState *s) {
  const u8 *buf = s->buf;
  i64 bm = s->bufMask;
  i64 pos = s->pos;
  i64 c1 = s->c4 & 255;
  i64 md = m->maxDistance;
  i64 count = m->warmup < md ? m->warmup : md;
  m->warmup++;
  u16 *e1 = m->slow.ema, *e2 = m->fast.ema;
  i64 i1a = 0, i1b = 0, s1a = 0xFFFF, s1b = 0xFFFF;
  i64 i2a = 0, i2b = 0, s2a = 0xFFFF, s2b = 0xFFFF;
  i64 base = pos - 1 - count;
  i64 eb = md - count;
  for (i64 i = 0; i < count; i++) {
    i64 d = (buf[(base + i) & bm] - c1) & 255;
    if (d >= 128) d = 256 - d;
    i64 cur = d << 8;
    i64 idx = eb + i;
    i64 r1 = ((i64)e1[idx] * 63 + cur) >> 6;
    e1[idx] = (u16)r1;
    i64 r2 = ((i64)e2[idx] * 57 + cur * 7) >> 6;
    e2[idx] = (u16)r2;
    if (r1 < s1b) {
      if (r1 < s1a) {
        i1b = i1a;
        s1b = s1a;
        i1a = idx;
        s1a = r1;
      } else {
        i1b = idx;
        s1b = r1;
      }
    }
    if (r2 < s2b) {
      if (r2 < s2a) {
        i2b = i2a;
        s2b = s2a;
        i2a = idx;
        s2a = r2;
      } else {
        i2b = idx;
        s2b = r2;
      }
    }
  }
  m->slow.matchIndex[0] = (i32)i1a;
  m->slow.matchIndex[1] = (i32)i1b;
  m->slow.matchScore[0] = (i32)s1a;
  m->slow.matchScore[1] = (i32)s1b;
  m->fast.matchIndex[0] = (i32)i2a;
  m->fast.matchIndex[1] = (i32)i2b;
  m->fast.matchScore[0] = (i32)s2a;
  m->fast.matchScore[1] = (i32)s2b;
}

static void sim_mix(ZModel *self, ZState *s, Mixer *mx) {
  SimilarityModel *m = (SimilarityModel *)self;
  i64 bpos = s->bpos;
  if (bpos == 0) {
    i64 c1 = s->c4 & 255;
    if (m->started) {
      residualmap_update(&m->slow.mapR1, c1);
      residualmap_update(&m->slow.mapR2, c1);
      residualmap_update(&m->fast.mapR1, c1);
      residualmap_update(&m->fast.mapR2, c1);
    }
    m->started = 1;
    updateEma(m, s);
    similarity_findRecord(&m->slow, m->warmup);
    similarity_findRecord(&m->fast, m->warmup);
    similarity_byteContexts(&m->slow, s);
    similarity_byteContexts(&m->fast, s);
  }
  i64 c0 = s->c0;
  i64 y = s->y;
  i64 c1 = s->c4 & 255;
  for (int k = 0; k < 2; k++) {
    Similarity *sm = k == 0 ? &m->slow : &m->fast;
    residualmap_mix(&sm->mapR1, mx, bpos, c0);
    residualmap_mix(&sm->mapR2, mx, bpos, c0);
    contextmap_mix(&sm->cm, mx, y, bpos, c0, c1);
  }
}

static void sim_setCtx(ZModel *self, ZState *s, Mixer *mx) {
  SimilarityModel *m = (SimilarityModel *)self;
  mixer_set(mx, m->slow.mctx1);
  mixer_set(mx, m->slow.mctx2);
  mixer_set(mx, m->fast.mctx1);
  mixer_set(mx, m->fast.mctx2);
}
