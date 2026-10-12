// zxsfx decoder: port of zcm_fast.dart, the predictor of level 1, written
// as one function for speed.
//
// lpaq1 style (Matt Mahoney): orders 1, 2, 3, 4 and 6 in hashed tables
// with one 64 byte line of 16 entries per context and nibble (the layout
// of lpaq's nibble tables and zpaq's CM component), each entry a fast and
// a slow adaptive probability; an order 1 table indexed directly; a match
// model on the last 6 bytes; one mixer weight set per partial byte; and
// one APM.

#include "zc_fast.h"

#define MIN_LEN 6

static i32 dt16[16];

// zcmBufferBytes of zcm_predictor.dart.
static i64 bufferBytes(i64 budgetBytes) {
  i64 b = floorPow2(budgetBytes / 8);
  if (b > (64 << 20)) b = 64 << 20;
  if (b < (1 << 16)) b = 1 << 16;
  return b;
}

void zfast_init(ZcmFast *f, i64 budgetBytes) {
  for (i64 i = 0; i < 16; i++) dt16[i] = (i32)((65536 * 2) / (2 * i + 3));
  i64 buf = bufferBytes(budgetBytes);
  i64 htEntries = floorPow2(budgetBytes / 32);
  i64 tb = budgetBytes - buf - htEntries * 4 - (1 << 20);
  if (tb < (1 << 16)) tb = 1 << 16;
  i64 entries = floorPow2(tb / 4);
  zstate_init(&f->s, buf);
  f->t = ZNEW(u32, entries);
  for (i64 i = 0; i < entries; i++) f->t[i] = (2048u << 20) | (32768u << 4);
  f->mask = entries - 1;
  for (i64 i = 0; i < ZFAST_NORD; i++) f->ctx[i] = f->base[i] = f->idx[i] = 0;
  f->o1 = ZNEW(u32, 1 << 16);
  for (i64 i = 0; i < (1 << 16); i++) f->o1[i] = 2048u << 20;
  f->o1i = 0;
  f->ht = ZNEW(i32, htEntries);
  f->htMask = htEntries - 1;
  f->ptr = f->len = f->exp = 0;
  for (i64 i = 0; i < 128; i++) f->msm[i] = 2048u << 20;
  f->msi = 0;
  f->w = ZNEW(i32, 256 * ZFAST_STRIDE);
  for (i64 i = 0; i < 256 * ZFAST_STRIDE; i++) f->w[i] = 16384;
  for (i64 i = 0; i < ZFAST_STRIDE; i++) f->x[i] = 0;
  f->wo = 0;
  f->pr12 = 2048;
  f->rate = 56 << 16;
  apm_init(&f->apm, 256 * 8, 7);
  f->misses = 0;
  f->pr = 2048;
  f->tableBytes = buf + htEntries * 4 + entries * 4;
}

// Byte boundary: new contexts and the match model.
static void fast_byte(ZcmFast *f) {
  ZState *st = &f->s;
  i64 c4 = st->c4;
  i64 c8 = st->c8;
  i32 *ctx = f->ctx;
  ctx[0] = (i32)hash2(c4 & 0xFF, 1);
  ctx[1] = (i32)hash2(c4 & 0xFFFF, 2);
  ctx[2] = (i32)hash2(c4 & 0xFFFFFF, 3);
  ctx[3] = (i32)hash2(c4, 4);
  ctx[4] = (i32)hash2(hash2(c4, c8 & 0xFFFF), 6);
  // Match model.
  const u8 *buf = st->buf;
  i64 bm = st->bufMask;
  i64 pos = st->pos;
  if (f->len > 0) {
    if (f->exp == (c4 & 255)) {
      f->len++;
      if (f->len > 65535) f->len = 65535;
      f->ptr++;
    } else {
      f->len = 0;
    }
  }
  if (pos >= MIN_LEN) {
    i64 h = hash2(c4, c8 & 0xFFFF) & f->htMask;
    if (f->len == 0) {
      i64 cand = f->ht[h];
      if (cand > 0 && pos - cand < bm - 64) {
        i64 l = 0;
        while (l < 64 && l < cand &&
               buf[(cand - 1 - l) & bm] == buf[(pos - 1 - l) & bm]) {
          l++;
        }
        if (l >= MIN_LEN) {
          f->len = l;
          f->ptr = cand;
        }
      }
    }
    f->ht[h] = (i32)pos;
  }
  if (f->len > 0) f->exp = buf[f->ptr & bm];
}

i64 zfast_p(ZcmFast *f) {
  ZState *st = &f->s;
  i64 y = st->y;
  i64 bpos = st->bpos;
  i64 c0 = st->c0;
  i32 *x = f->x;
  i32 *w = f->w;
  // Train the mixer with the last bit.
  {
    i64 err0 = (y << 12) - f->pr12;
    if (err0 <= -4 || err0 >= 4) {
      i64 err = (err0 * f->rate) >> 16;
      i64 o = f->wo;
      for (i64 i = 0; i < ZFAST_NIN; i++) {
        w[o + i] = (i32)(w[o + i] + (((i64)x[i] * err) >> 16));
      }
    }
    if (f->rate > (14 << 16)) f->rate--;
  }
  if (bpos == 0) fast_byte(f);
  // Order n tables: update the last entry, find the next.
  u32 *t = f->t;
  const i16 *str = kStretch;
  i32 *ctx = f->ctx;
  i32 *base = f->base;
  i32 *idx = f->idx;
  if (bpos == 0 || bpos == 4) {
    i64 nib = bpos == 0 ? 0 : (c0 & 15) + 1;
    i64 mask = f->mask;
    for (i64 i = 0; i < ZFAST_NORD; i++) {
      base[i] = (i32)((hash2(ctx[i], nib) << 4) & mask);
    }
  }
  i64 sub = bpos < 4 ? c0 : ((i64)1 << (bpos - 4)) | (c0 & (((i64)1 << (bpos - 4)) - 1));
  i64 yf = y << 12;
  i64 ys = y << 16;
  for (i64 i = 0; i < ZFAST_NORD; i++) {
    i64 li = idx[i];
    i64 e = t[li];
    i64 pf = e >> 20;
    i64 ps = (e >> 4) & 0xFFFF;
    i64 c = e & 15;
    pf += (yf - pf) >> 2;
    ps += ((ys - ps) * dt16[c]) >> 16;
    t[li] = (u32)((pf << 20) | (ps << 4) | (c < 14 ? c + 1 : c));
    i64 ni = (i64)base[i] + sub;
    idx[i] = (i32)ni;
    i64 e2 = t[ni];
    x[i] = (i32)(((i64)str[e2 >> 20] + str[(e2 >> 8) & 0xFFF]) >> 1);
  }
  // Order 1 direct.
  const i32 *dt = kDt;
  i64 target = y << 22;
  {
    u32 *o1 = f->o1;
    i64 e = o1[f->o1i];
    i64 en = e & 1023;
    i64 ep = e >> 10;
    o1[f->o1i] = (u32)(((ep + (((target - ep) * dt[en]) >> 31)) << 10) |
                       (en < 1023 ? en + 1 : en));
    f->o1i = ((st->c4 & 255) << 8) | c0;
    x[ZFAST_NORD] = str[o1[f->o1i] >> 20];
  }
  // Match model.
  {
    u32 *msm = f->msm;
    i64 e = msm[f->msi];
    i64 en = e & 1023;
    i64 ep = e >> 10;
    msm[f->msi] = (u32)(((ep + (((target - ep) * dt[en]) >> 31)) << 10) |
                        (en < 1023 ? en + 1 : en));
    if (f->len > 0 && ((f->exp + 256) >> (8 - bpos)) != c0) f->len = 0;
    if (f->len > 0) {
      i64 bit = (f->exp >> (7 - bpos)) & 1;
      i64 len = f->len;
      i64 lq = len < 32 ? len : 32 + ((len >> 6) < 31 ? len >> 6 : 31);
      f->msi = ((lq > 63 ? 63 : lq) << 1) | bit;
      i64 st1 = str[msm[f->msi] >> 20];
      x[ZFAST_NORD + 1] = (i32)st1;
      i64 lc = len < 32 ? len : 32;
      x[ZFAST_NORD + 2] = (i32)(bit != 0 ? lc << 6 : -(lc << 6));
    } else {
      f->msi = 0;
      x[ZFAST_NORD + 1] = 0;
      x[ZFAST_NORD + 2] = 0;
    }
  }
  x[ZFAST_NORD + 3] = 256;
  // Mix.
  i64 o = c0 * ZFAST_STRIDE;
  f->wo = o;
  i64 dot = 0;
  for (i64 i = 0; i < ZFAST_NIN; i++) dot += (i64)x[i] * w[o + i];
  dot >>= 16;
  if (dot > 2047) dot = 2047;
  if (dot < -2047) dot = -2047;
  i64 pr = kSquash[dot + 2048];
  f->pr12 = pr;
  // APM on the partial byte and the recent misses.
  i64 miss = ((f->pr >= 2048) != (y == 1)) ? 1 : 0;
  f->misses = ((f->misses << 1) | miss) & 0xFFFF;
  i64 m3 = (f->misses & 1) | ((f->misses & 0xFE) != 0 ? 2 : 0) |
           ((f->misses & 0xFF00) != 0 ? 4 : 0);
  i64 pa = apm_pp16(&f->apm, y, pr, c0 | (m3 << 8));
  i64 pf = ((pr << 4) * 3 + pa + 2) >> 2;
  if (pf < 1) pf = 1;
  if (pf > 65535) pf = 65535;
  f->pr = pf >> 4;
  return pf;
}
