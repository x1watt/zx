// zxsfx decoder: port of zcm_maps.dart and zcm_ols.dart (designs of
// paq8px: Zoltan Gotthardt, Marcio Pais, Sebastian Lehmann and the paq8px
// authors; see those files).

#include "zc_maps.h"

i32 zcmDt2[1024];

void zc_maps_init(void) {
  for (i64 n = 0; n < 1024; n++) zcmDt2[n] = (i32)(((i64)1 << 30) / (n + 2));
}

void stationarymap_init(StationaryMap *m, i64 bitsOfContext, i64 inputBits,
                        i64 scale) {
  m->t = ZNEW(u32, ((i64)1 << bitsOfContext) * (((i64)1 << inputBits) - 1));
  m->mask = ((i64)1 << bitsOfContext) - 1;
  m->stride = ((i64)1 << inputBits) - 1;
  m->scale = scale;
  m->context = 0;
  m->b = 0;
  m->cp = -1;
}

void stationarymap_update(StationaryMap *m, i64 y) {
  i64 cp = m->cp;
  if (cp < 0) return;
  i64 c = m->t[cp];
  i64 n0 = (c >> 16) + 1 - y;
  i64 n1 = (c & 0xFFFF) + y;
  i64 shift = (n0 | n1) >> 16;
  n0 >>= shift;
  n1 >>= shift;
  m->t[cp] = (u32)(n0 << 16 | n1);
  m->b += (y != 0 && m->b > 0) ? 1 : 0;
  m->cp = -1;
}

void stationarymap_mix(StationaryMap *m, Mixer *mx) {
  i64 cp = m->context + m->b;
  m->cp = cp;
  i64 c = m->t[cp];
  i64 n0 = c >> 16, n1 = c & 0xFFFF;
  i64 sum = n0 + n1;
  i64 p1 = ((n1 * 2 + 1) << 12) / (sum * 2 + 2);
  i64 st = (kStretch[p1] * m->scale) >> 8;
  i32 *tx = mx->tx;
  i64 k = mx->nx;
  tx[k] = (i32)st;
  tx[k + 1] = (i32)(((p1 - 2048) * m->scale) >> 9);
  tx[k + 2] = (i32)((sum <= 1 || (n0 != 0 && n1 != 0)) ? 0 : st);
  mx->nx = k + 3;
  m->b += m->b + 1;
}

void stationarymap_skip(StationaryMap *m, Mixer *mx) {
  m->cp = -1;
  i32 *tx = mx->tx;
  i64 k = mx->nx;
  tx[k] = tx[k + 1] = tx[k + 2] = 0;
  mx->nx = k + 3;
}

void smallstationarymap_init(SmallStationaryMap *m, i64 bitsOfContext,
                             i64 inputBits, i64 rate, i64 scale) {
  i64 n = ((i64)1 << bitsOfContext) * (((i64)1 << inputBits) - 1);
  m->t = ZNEW(u16, n);
  for (i64 i = 0; i < n; i++) m->t[i] = 0x7FFF;
  m->mask = ((i64)1 << bitsOfContext) - 1;
  m->stride = ((i64)1 << inputBits) - 1;
  m->rate = rate;
  m->scale = scale;
  m->context = 0;
  m->b = 0;
  m->cp = -1;
}

void smallstationarymap_update(SmallStationaryMap *m, i64 y) {
  i64 cp = m->cp;
  if (cp < 0) return;
  i64 v = m->t[cp];
  m->t[cp] = (u16)(v + (((y << 16) - v + ((i64)1 << (m->rate - 1))) >> m->rate));
  m->b += (y != 0 && m->b > 0) ? 1 : 0;
  m->cp = -1;
}

void smallstationarymap_mix(SmallStationaryMap *m, Mixer *mx) {
  i64 cp = m->context + m->b;
  m->cp = cp;
  i64 p = m->t[cp] >> 4;
  i32 *tx = mx->tx;
  i64 k = mx->nx;
  tx[k] = (i32)((kStretch[p] * m->scale) >> 8);
  tx[k + 1] = (i32)(((p - 2048) * m->scale) >> 9);
  mx->nx = k + 2;
  m->b += m->b + 1;
}

void largestationarymap_init(LargeStationaryMap *m, i64 n, i64 hashBits,
                             i64 scale) {
  m->n = n;
  m->hashBits = hashBits;
  m->scale = scale;
  m->chk = ZNEW(u16, (i64)7 << hashBits);
  m->val = ZNEW(u32, (i64)7 << hashBits);
  m->cp = ZNEW(i32, n);
  m->k = 0;
  zrandom_init(&m->rnd);
}

static void lsm_shift(u16 *chk, u32 *val, i64 b, i64 from) {
  for (i64 j = from; j > 0; j--) {
    chk[b + j] = chk[b + j - 1];
    val[b + j] = val[b + j - 1];
  }
}

static i64 lsm_find(LargeStationaryMap *m, i64 bucket, i64 checksum) {
  u16 *chk = m->chk;
  u32 *val = m->val;
  i64 b = bucket * 7;
  if (checksum == 0) checksum = 1;
  if (chk[b] == checksum) return b;
  for (i64 i = 1; i < 7; i++) {
    i64 c = chk[b + i];
    if (c == checksum) {
      u32 v = val[b + i];
      lsm_shift(chk, val, b, i);
      chk[b] = (u16)checksum;
      val[b] = v;
      return b;
    }
    if (c == 0) {
      lsm_shift(chk, val, b, i);
      chk[b] = (u16)checksum;
      val[b] = 0;
      return b;
    }
  }
  i64 minIdx = 6;
  i64 rnd = zrandom_next(&m->rnd);
  if ((rnd & 63) >= 1) {
    i64 minPrio = val[b + 6] & 1023;
    i64 p = val[b + 5] & 1023;
    if (p < minPrio) {
      minPrio = p;
      minIdx = 5;
    }
    rnd >>= 6;
    if ((rnd & 63) >= 4) {
      p = val[b + 4] & 1023;
      if (p < minPrio) {
        minPrio = p;
        minIdx = 4;
      }
      rnd >>= 6;
      if ((rnd & 63) >= 8) {
        p = val[b + 3] & 1023;
        if (p < minPrio) {
          minPrio = p;
          minIdx = 3;
        }
        rnd >>= 6;
        if ((rnd & 63) >= 16) {
          p = val[b + 2] & 1023;
          if (p < minPrio) minIdx = 2;
        }
      }
    }
  }
  lsm_shift(chk, val, b, minIdx);
  chk[b] = (u16)checksum;
  val[b] = 0;
  return b;
}

void largestationarymap_set(LargeStationaryMap *m, i64 h) {
  h &= 0xFFFFFFFF;
  i64 bucket = h >> (32 - m->hashBits);
  i64 chk = (h * 0x2F0F3A55 >> 8) & 0xFFFF;
  m->cp[m->k++] = (i32)lsm_find(m, bucket, chk);
}

void largestationarymap_update(LargeStationaryMap *m, i64 y) {
  u32 *val = m->val;
  for (i64 i = 0; i < m->k; i++) {
    i64 cp = m->cp[i];
    if (cp < 0) continue;
    i64 cell = val[cp] ^ 0x80000000;
    i64 sum = cell & 1023;
    i64 p1 = cell >> 10;
    i64 np = p1 + ((((y << 22) - p1) * zcmDt2[sum]) >> 30);
    val[cp] = (u32)(0x80000000 ^ ((np << 10) | (sum < 1023 ? sum + 1 : sum)));
  }
  m->k = 0;
}

void largestationarymap_mix(LargeStationaryMap *m, Mixer *mx) {
  u32 *val = m->val;
  i32 *tx = mx->tx;
  i64 k = mx->nx;
  for (i64 i = 0; i < m->k; i++) {
    i64 cp = m->cp[i];
    if (cp < 0) {
      tx[k] = tx[k + 1] = tx[k + 2] = 0;
      k += 3;
      continue;
    }
    i64 cell = val[cp] ^ 0x80000000;
    i64 p1 = cell >> 20;
    i64 st = (kStretch[p1] * m->scale) >> 8;
    tx[k] = (i32)st;
    tx[k + 1] = (i32)(((p1 - 2048) * m->scale) >> 9);
    i64 p22 = cell >> 10;
    i64 sum = cell & 1023;
    i64 n1 = ((sum + 1) * p22) >> 22;
    int uncertain = sum <= 1 || (n1 < sum - 1 && n1 != 0);
    tx[k + 2] = (i32)(uncertain ? 0 : st);
    k += 3;
  }
  mx->nx = k;
}

void indirectcontext_init(IndirectContext *c, i64 bitsPerContext,
                          i64 inputBits, i64 valueBits, i64 contextBits) {
  i64 n = (i64)1 << bitsPerContext;
  c->t = ZNEW(u32, n);
  c->ctxMask = n - 1;
  c->inputBits = inputBits;
  c->valueBits = valueBits;
  c->contextBits = contextBits < 0 ? valueBits : contextBits;
  c->ctx = 0;
  if (c->contextBits < valueBits) {
    for (i64 i = 0; i < n; i++) c->t[i] = 1;
  }
}

void mtflist_init(MtfList *l, i64 n) {
  l->prev = ZNEW(i32, n);
  l->next = ZNEW(i32, n);
  for (i64 i = 0; i < n; i++) {
    l->prev[i] = (i32)(i - 1);
    l->next[i] = (i32)(i + 1);
  }
  l->next[n - 1] = -1;
  l->root = 0;
  l->index = 0;
}

void mtflist_moveToFront(MtfList *l, i64 i) {
  l->index = i;
  if (i == l->root) return;
  i64 p = l->prev[i];
  i64 n = l->next[i];
  if (p >= 0) l->next[p] = l->next[i];
  if (n >= 0) l->prev[n] = l->prev[i];
  l->prev[l->root] = (i32)i;
  l->next[i] = (i32)l->root;
  l->root = i;
  l->prev[l->root] = -1;
}

void residualmap_init(ResidualMap *m, i64 n, i64 histograms, i64 scale) {
  m->n = n;
  m->histograms = histograms;
  m->scale = scale;
  m->sums = ZNEW(u16, n * histograms * 256);
  m->pred = ZNEW(i32, n);
  m->base = ZNEW(i32, n);
  m->k = 0;
}

void residualmap_update(ResidualMap *m, i64 byte) {
  u16 *s = m->sums;
  for (i64 i = 0; i < m->k; i++) {
    i64 base = m->base[i];
    if (base < 0) continue;
    i64 bin = (192 + byte - m->pred[i]) & 255;
    for (i64 j = base + bin; j < base + 256; j++) s[j]++;
    if (s[base + 255] == 65535) {
      for (i64 j = base; j < base + 256; j++) s[j] >>= 1;
    }
  }
  m->k = 0;
}

void residualmap_mix(ResidualMap *m, Mixer *mx, i64 bpos, i64 c0) {
  const u16 *s = m->sums;
  i32 *tx = mx->tx;
  i64 k = mx->nx;
  i64 c1 = (c0 << (8 - bpos)) & 255;
  i64 range = (i64)1 << (7 - bpos);
  i64 sc = m->scale;
  for (i64 i = 0; i < m->k; i++) {
    i64 base = m->base[i];
    if (base < 0) {
      tx[k] = tx[k + 1] = 0;
      k += 2;
      continue;
    }
    i64 o0 = (192 + c1 - m->pred[i]) & 255;
    i64 o1 = (o0 + range) & 255;
    i64 n0, n1;
    if (o0 + range <= 256) {
      n0 = (i64)s[base + o0 + range - 1] - (o0 == 0 ? 0 : s[base + o0 - 1]);
    } else {
      n0 = (i64)s[base + 255] - s[base + o0 - 1] + s[base + o0 + range - 257];
    }
    if (o1 + range <= 256) {
      n1 = (i64)s[base + o1 + range - 1] - (o1 == 0 ? 0 : s[base + o1 - 1]);
    } else {
      n1 = (i64)s[base + 255] - s[base + o1 - 1] + s[base + o1 + range - 257];
    }
    i64 sum = n0 + n1;
    i64 sh = bitLength(sum | 1) - 10;
    if (sh < 0) sh = 0;
    i64 p1 = (((((n1 >> sh) + 1) << 12) * zcmDt2[sum >> sh]) >> 30);
    i64 pp = p1 < 1 ? 1 : (p1 > 4095 ? 4095 : p1);
    tx[k] = (i32)((kStretch[pp] * sc) >> 8);
    tx[k + 1] = (i32)(((pp - 2048) * sc) >> 9);
    k += 2;
  }
  mx->nx = k;
}

void ols_init(Ols *o, i64 n, i64 interval, double lambda) {
  o->n = n;
  o->interval = interval;
  o->lambda = lambda;
  o->nu = 0.001;
  o->x = ZNEW(double, n);
  o->w = ZNEW(double, n);
  o->c = ZNEW(double, n * n);
  o->b = ZNEW(double, n);
  o->l = ZNEW(double, n * n);
  o->t = ZNEW(double, n);
  o->k = 0;
  o->since = 0;
}

double ols_predict(Ols *o) {
  while (o->k < o->n) o->x[o->k++] = 0.0;
  o->k = 0;
  double s = 0.0;
  for (i64 i = 0; i < o->n; i++) s += o->x[i] * o->w[i];
  return s;
}

static int ols_factor(Ols *o) {
  i64 n = o->n;
  double *c = o->c, *l = o->l;
  for (i64 i = 0; i < n; i++) {
    i64 r = i * n;
    for (i64 j = 0; j <= i; j++) {
      double s = c[r + j];
      if (i == j) s += o->nu;
      i64 rj = j * n;
      for (i64 k = 0; k < j; k++) s -= l[r + k] * l[rj + k];
      if (i == j) {
        if (s <= 1e-10) return 0;
        l[r + i] = zsqrt(s);
      } else {
        l[r + j] = s / l[rj + j];
      }
    }
  }
  return 1;
}

static void ols_solve(Ols *o) {
  i64 n = o->n;
  double *l = o->l, *t = o->t, *w = o->w, *b = o->b;
  for (i64 i = 0; i < n; i++) {
    double s = b[i];
    i64 r = i * n;
    for (i64 k = 0; k < i; k++) s -= l[r + k] * t[k];
    t[i] = s / l[r + i];
  }
  for (i64 i = n - 1; i >= 0; i--) {
    double s = t[i];
    for (i64 k = i + 1; k < n; k++) s -= l[k * n + i] * w[k];
    w[i] = s / l[i * n + i];
  }
}

void ols_update(Ols *o, double y) {
  i64 n = o->n;
  double a = o->lambda;
  double be = 1.0 - o->lambda;
  for (i64 i = 0; i < n; i++) {
    double xb = o->x[i] * be;
    i64 r = i * n;
    for (i64 j = 0; j <= i; j++) o->c[r + j] = a * o->c[r + j] + o->x[j] * xb;
  }
  for (i64 i = 0; i < n; i++) o->b[i] = a * o->b[i] + y * o->x[i] * be;
  if (++o->since >= o->interval) {
    o->since = 0;
    if (ols_factor(o)) ols_solve(o);
  }
}
