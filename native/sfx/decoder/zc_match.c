// zxsfx decoder: port of zcm_match.dart, the match model of paq8px.
//
// A port of paq8px's MatchModel and MatchInfo (the paq8px authors, after
// the match model of paq8 by Matt Mahoney): the positions of the last
// three occurrences of the hashes of the last LEN1, LEN2 and LEN3 bytes
// are kept, up to four match candidates are followed at once (the best
// one predicts; the others tell whether the prediction is certain), and
// a candidate that fails on one byte predicts in "delta" mode for the
// rest of that byte and is recovered when the byte after the mismatch
// agrees again.

#include "zc_match.h"

#define PX_N PXMATCH_N // candidates
#define PX_SLOTS 3     // positions per hash element
#define PX_MINLENRM 3
#define PX_MAXLEN 65535

// ---------------------------------------------------------------- _Sm

static void pxsm_init(PxSm *m, i64 n) {
  m->t = ZNEW(u32, n);
  for (i64 i = 0; i < n; i++) m->t[i] = (u32)((i64)2048 << 20);
  m->cx = -1;
}

ZINLINE void pxsm_update(PxSm *m, i64 y) {
  i64 cx = m->cx;
  if (cx >= 0) {
    m->t[cx] = (u32)adaptEntry(m->t[cx], y, 1023);
    m->cx = -1;
  }
}

ZINLINE i64 pxsm_p1(PxSm *m, i64 cx) {
  m->cx = cx;
  return m->t[cx] >> 20;
}

// ---------------------------------------------------------------- PxMatchModel

static const i64 kPxSelSizes[1] = {20};

static i64 px_elements(i64 bytes) {
  return floorPow2(bytes / 12 < 4096 ? 4096 : bytes / 12);
}

i64 pxmatchmodel_tableBytes(i64 bytes, i64 mapLBits) {
  return px_elements(bytes) * 12 + ((i64)6 << mapLBits) * 7 +
         ((i64)1 << 15) * 4 + (28 * 2 * 8 + 256 * 8 * 256 + 256 * 256) * 4;
}

ZINLINE int px_noMatch(const PxMatchModel *m, i64 i) {
  return m->len[i] == 0 && m->delta[i] == 0 && m->lenBak[i] == 0;
}
ZINLINE int px_preRecovery(const PxMatchModel *m, i64 i) {
  return m->len[i] == 0 && m->delta[i] == 0 && m->lenBak[i] != 0;
}
ZINLINE int px_recovery(const PxMatchModel *m, i64 i) {
  return m->len[i] != 0 && m->lenBak[i] != 0;
}

// MatchInfo::update
static void px_updateCandidate(PxMatchModel *m, i64 i, ZState *s, i64 y,
                               i64 bpos) {
  if (m->len[i] != 0) {
    i64 expectedBit = ((i64)m->exp[i] >> ((8 - bpos) & 7)) & 1;
    if (y != expectedBit) {
      if (px_recovery(m, i)) {
        m->lenBak[i] = 0;
        m->idxBak[i] = 0;
      } else {
        m->lenBak[i] = m->len[i];
        m->idxBak[i] = m->idx[i];
        m->delta[i] = 1;
      }
      m->len[i] = 0;
    }
  }
  if (bpos == 0) {
    if (px_preRecovery(m, i)) {
      m->idxBak[i] = (i32)((i64)m->idxBak[i] + 1);
      if (m->lenBak[i] < PX_MAXLEN) m->lenBak[i] = (i32)((i64)m->lenBak[i] + 1);
      if (s->buf[(i64)m->idxBak[i] & s->bufMask] == (s->c4 & 255)) {
        m->len[i] = m->lenBak[i];
        m->idx[i] = m->idxBak[i];
      } else {
        m->lenBak[i] = 0;
        m->idxBak[i] = 0;
      }
    }
    if (m->len[i] != 0) {
      m->idx[i] = (i32)((i64)m->idx[i] + 1);
      if (m->len[i] < PX_MAXLEN) m->len[i] = (i32)((i64)m->len[i] + 1);
      if (px_recovery(m, i) &&
          (i64)m->len[i] - m->lenBak[i] >= PX_MINLENRM) {
        m->lenBak[i] = 0;
        m->idxBak[i] = 0;
      }
    }
    m->delta[i] = 0;
  }
}

static void px_remove(PxMatchModel *m, i64 i) {
  for (i64 j = i; j < m->active; j++) {
    i64 f = j + 1 < PX_N ? j + 1 : j;
    m->len[j] = m->len[f];
    m->idx[j] = m->idx[f];
    m->lenBak[j] = m->lenBak[f];
    m->idxBak[j] = m->idxBak[f];
    m->exp[j] = m->exp[f];
    m->delta[j] = m->delta[f];
  }
}

static int px_isMatch(ZState *s, i64 p, i64 minLen) {
  const u8 *buf = s->buf;
  i64 bm = s->bufMask;
  i64 pos = s->pos;
  if (pos - p > bm - 64) return 0;
  for (i64 l = 1; l <= minLen; l++) {
    if (buf[(pos - l) & bm] != buf[(p - l) & bm]) return 0;
  }
  return 1;
}

static void px_addCandidates(PxMatchModel *m, ZState *s, i64 e, i64 len) {
  i64 i = 0;
  const u32 *t = m->table;
  while (m->active < PX_N && i < PX_SLOTS) {
    i64 p = t[e + i];
    if (p == 0) break;
    if (px_isMatch(s, p, len)) {
      int same = 0;
      for (i64 j = 0; j < m->active; j++) {
        if ((i64)m->idx[j] == p) {
          same = 1;
          break;
        }
      }
      if (!same) {
        i64 a = m->active;
        m->len[a] = (i32)(len - m->l1 + 1);
        m->idx[a] = (i32)p;
        m->lenBak[a] = 0;
        m->idxBak[a] = 0;
        m->exp[a] = 0;
        m->delta[a] = 0;
        m->active = a + 1;
      }
    }
    i++;
  }
}

// Hash of the last [n] bytes.
static i64 px_hashLast(const u8 *buf, i64 bm, i64 pos, i64 n) {
  i64 h = n * 0x2F0F3A55;
  for (i64 k = 1; k <= n; k++) {
    h = (h * 0x2F0F3A55 + buf[(pos - k) & bm] + 1) & 0xFFFFFFFF;
  }
  return hash2(h, n);
}

static void px_addPos(PxMatchModel *m, i64 e, i64 pos) {
  u32 *t = m->table;
  t[e + 2] = t[e + 1];
  t[e + 1] = t[e];
  t[e] = (u32)pos;
}

static void px_update(PxMatchModel *m, ZState *s, i64 y, i64 bpos) {
  i64 n = m->active > 1 ? m->active : 1;
  for (i64 i = 0; i < n; i++) {
    px_updateCandidate(m, i, s, y, bpos);
    if (m->active != 0 && px_noMatch(m, i)) {
      m->active--;
      if (m->active == i) break;
      px_remove(m, i);
      i--;
    }
  }
  if (bpos == 0) {
    i64 type = s->blockType;
    const i64 *lens = type == ZT_TEXT
                          ? m->lensText
                          : (type == ZT_EXE ? m->lensExe : m->lensBinary);
    m->l1 = lens[0];
    m->l2 = lens[1];
    m->l3 = lens[2];
    const u8 *buf = s->buf;
    i64 bm = s->bufMask;
    i64 pos = s->pos;
    int sh = (int)(32 - m->hashBits);
    for (i64 k = 2; k >= 0; k--) {
      i64 len = k == 2 ? m->l3 : (k == 1 ? m->l2 : m->l1);
      if (pos < len) continue;
      i64 e = (px_hashLast(buf, bm, pos, len) >> sh) * PX_SLOTS;
      if (m->active < PX_N) px_addCandidates(m, s, e, len);
      px_addPos(m, e, pos);
    }
    for (i64 i = 0; i < m->active; i++) {
      m->exp[i] = buf[(i64)m->idx[i] & bm];
    }
  }
}

// MatchInfo::prio
ZINLINE i64 px_prio(const PxMatchModel *m, i64 i) {
  return (m->len[i] != 0 ? (i64)1 << 49 : 0) | ((i64)m->delta[i] << 48) |
         ((i64)(m->delta[i] != 0 ? m->lenBak[i] : m->len[i]) << 32) |
         ((i64)m->idx[i] & 0xFFFFFFFF);
}

static void pxmatchmodel_mix(ZModel *self, ZState *s, Mixer *mx) {
  PxMatchModel *m = (PxMatchModel *)self;
  i64 y = s->y;
  i64 bpos = s->bpos;
  pxsm_update(&m->sm0, y);
  pxsm_update(&m->sm1, y);
  pxsm_update(&m->sm2, y);
  if (m->mapsMixed) {
    largestationarymap_update(&m->mapL, y);
    stationarymap_update(&m->map, y);
  }
  px_update(m, s, y, bpos);
  i64 best = 0;
  i64 bestPrio = px_prio(m, 0);
  for (i64 i = 1; i < m->active; i++) {
    i64 p = px_prio(m, i);
    if (p > bestPrio) {
      bestPrio = p;
      best = i;
    }
  }
  i64 length = m->len[best];
  i64 expectedByte = m->exp[best];
  int noMatch = px_noMatch(m, best);
  int isDelta = m->delta[best] != 0;
  int preRec = px_preRecovery(m, best);
  int rec = px_recovery(m, best);
  i64 c0 = s->c0;
  i64 c1 = s->c4 & 255;
  i64 expectedBit = length != 0 ? (expectedByte >> (7 - bpos)) & 1 : 0;
  i64 n0 = 0, n1 = 0;
  for (i64 i = 0; i < m->active; i++) {
    if (m->len[i] == 0) continue;
    i64 b = ((i64)m->exp[i] >> (7 - bpos)) & 1;
    n0 += 1 - b;
    n1 += b;
  }
  i64 uncertain = n0 != 0 && n1 != 0 ? 1 : 0;
  i32 *tx = mx->tx;
  i64 k = mx->nx;
  i64 ctx0 = 0, ctx1 = 0, ctx2 = 0;
  if (length != 0) {
    i64 dl = length <= 16
                 ? length - 1
                 : 12 + ((length - 1 < 63 ? length - 1 : 63) >> 2);
    ctx0 = 1 + ((dl << 4) | (expectedBit << 3) | bpos);
    ctx1 = 1 + ((expectedByte << 11) | (bpos << 8) | c1);
    i64 sign = 2 * expectedBit - 1;
    tx[k] = (i32)(sign * ((length < 32 ? length : 32) << 5));
    tx[k + 1] = (i32)(sign * ((i64)kIlog[length < 65535 ? length : 65535] << 2));
  } else {
    tx[k] = 0;
    tx[k + 1] = 0;
  }
  k += 2;
  if (isDelta) ctx2 = 1 + ((expectedByte << 8) | c0);
  for (i64 i = 0; i < 3; i++) {
    i64 c = i == 0 ? ctx0 : (i == 1 ? ctx1 : ctx2);
    if (c != 0) {
      PxSm *sm = i == 0 ? &m->sm0 : (i == 1 ? &m->sm1 : &m->sm2);
      i64 p1 = pxsm_p1(sm, i == 2 ? (c - 1) & 0xFFFF : c - 1);
      tx[k] = (i32)(kStretch[p1] >> 2);
      tx[k + 1] = (i32)((p1 - 2048) >> 3);
    } else {
      tx[k] = 0;
      tx[k + 1] = 0;
    }
    k += 2;
  }
  mx->nx = k;
  i64 l2 = (length >> 2) < 3 ? length >> 2 : 3;
  i64 mode3 =
      noMatch ? 0 : (isDelta ? 1 : (preRec ? 2 : (rec ? 3 : 4 + l2)));
  i64 mode5 =
      noMatch
          ? 0
          : (isDelta ? 1
                     : (preRec ? 2
                               : (rec ? 3
                                      : 4 + ((l2 << 2) | (expectedBit << 1) |
                                             uncertain))));
  if (bpos == 0) {
    contextmap_set(&m->cm, 0,
                   hash2(((length != 0 ? expectedByte : c1) << 3) | mode3, 1));
    contextmap_set(&m->cm, 1,
                   hash3(length != 0 ? expectedByte : (s->c4 >> 8) & 0xFF,
                         (c1 << 3) | mode3, 2));
  }
  contextmap_mix(&m->cm, mx, y, bpos, c0, c1);
  largestationarymap_set(&m->mapL,
                         hash4(expectedByte, c0, s->c4 & 0xFFFFFF, mode5));
  largestationarymap_mix(&m->mapL, mx);
  indirectcontext_add(&m->iCtx, y);
  indirectcontext_select(&m->iCtx, (mode5 << 3) | bpos);
  stationarymap_set(&m->map, (indirectcontext_value(&m->iCtx) << 8) |
                                 (mode5 << 3) | bpos);
  stationarymap_mix(&m->map, mx);
  m->mapsMixed = 1;
  m->length = length;
  m->expected = expectedByte;
  m->mode3 = mode3;
  m->mode5 = mode5;
  m->isDelta = isDelta;
}

static void pxmatchmodel_setCtx(ZModel *self, ZState *s, Mixer *mx) {
  mixer_set(mx, ((PxMatchModel *)self)->mode5);
}

static i64 pxmatchmodel_lengthFn(ZModel *self) {
  return pxmatchmodel_length((PxMatchModel *)self);
}
static i64 pxmatchmodel_expectedFn(ZModel *self) {
  return pxmatchmodel_expectedByte((PxMatchModel *)self);
}

void pxmatchmodel_init(PxMatchModel *m, i64 bytes, i64 mapBytes,
                       const i64 *lensText, const i64 *lensBinary,
                       const i64 *lensExe, i64 mapLBits) {
  i64 el = px_elements(bytes);
  m->table = ZNEW(u32, el * PX_SLOTS);
  m->hashBits = log2Exact(el);
  pxsm_init(&m->sm0, 28 * 2 * 8);
  pxsm_init(&m->sm1, 256 * 8 * 256);
  pxsm_init(&m->sm2, 256 * 256);
  contextmap_init(&m->cm, mapBytes, 2, 0, 0);
  largestationarymap_init(&m->mapL, 1, mapLBits, 64);
  stationarymap_init(&m->map, 1 + 6 + 5 + 3, 1, 64);
  indirectcontext_init(&m->iCtx, 8, 1, 8, 6);
  for (int i = 0; i < PX_N; i++) {
    m->len[i] = m->idx[i] = m->lenBak[i] = m->idxBak[i] = m->exp[i] = 0;
    m->delta[i] = 0;
  }
  m->active = 0;
  m->mapsMixed = 0;
  for (int i = 0; i < 3; i++) {
    m->lensText[i] = lensText[i];
    m->lensBinary[i] = lensBinary[i];
    m->lensExe[i] = lensExe[i];
  }
  m->l1 = 5;
  m->l2 = 7;
  m->l3 = 9;
  m->length = m->expected = m->mode5 = m->mode3 = 0;
  m->isDelta = 0;
  m->base.base.inputs = 2 + 2 * 4 + 3 * 2 + 3 + 3;
  m->base.base.mix = pxmatchmodel_mix;
  m->base.base.nsel = 1;
  m->base.base.selSizes = kPxSelSizes;
  m->base.base.setCtx = pxmatchmodel_setCtx;
  m->base.length = pxmatchmodel_lengthFn;
  m->base.expectedByte = pxmatchmodel_expectedFn;
}
