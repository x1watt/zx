// zxsfx decoder: port of zcm_models.dart (the models of zcm).
//
// Designs from paq8l and lpaq1 (Matt Mahoney: match, word, sparse,
// record, indirect and the x86 context of execxt, which paq8 credits to
// Alexander Rhatushnyak and Serge Osnach for the exe work) and paq8px
// (Marcio Pais, Zoltan Gotthardt and others: several match lengths, the
// line and column contexts of the text models). Written in Dart for zcm,
// ported literally to C.

#include "zc_models.h"

// ---------------------------------------------------------------- OrderModel

static void ordermodel_mixPairs(OrderModel *om, Mixer *m, i64 y, i64 c0,
                                i64 c1) {
  u32 *slow = om->slow, *fast = om->fast;
  i32 *tx = m->tx;
  i64 k = m->nx;
  for (i64 j = 0; j < 2; j++) {
    i64 li = j == 0 ? om->i0 : om->i1;
    slow[li] = (u32)adaptEntry(slow[li], y, 1023);
    fast[li] = (u32)adaptEntry(fast[li], y, 16);
    i64 ni = j == 0 ? c0 : 256 + ((c1 << 8) | c0);
    if (j == 0) {
      om->i0 = ni;
    } else {
      om->i1 = ni;
    }
    i64 ps = slow[ni] >> 20, pf = fast[ni] >> 20;
    tx[k] = (i32)((ps - 2048) >> 3);
    tx[k + 1] = (i32)(kStretch[ps] >> 2);
    tx[k + 2] = (i32)((pf - 2048) >> 3);
    tx[k + 3] = (i32)(kStretch[pf] >> 2);
    k += 4;
  }
  m->nx = k;
}

static void ordermodel_mix(ZModel *self, ZState *s, Mixer *m) {
  OrderModel *om = (OrderModel *)self;
  if (s->bpos == 0) {
    i64 c4 = s->c4;
    directmap_set(&om->o1, c4 & 255);
    for (i64 i = 0; i < om->norders; i++) {
      i64 o = om->orders[i];
      i64 h;
      if (o <= 4) {
        h = c4 & (((i64)1 << (o * 8)) - 1);
        if (o == 4) h = c4;
        h = hash2(h, o);
      } else if (o <= 8) {
        h = hash3(c4,
                  s->c8 & ((o == 8) ? 0xFFFFFFFF
                                    : (((i64)1 << ((o - 4) * 8)) - 1)),
                  o);
      } else {
        // Long orders: hash the bytes from the buffer.
        i64 hh = hash2(c4, s->c8);
        for (i64 k = 9; k <= o; k++) {
          hh = (hh * 0x2F0F3A55 + zstate_back(s, k) + 1) & 0xFFFFFFFF;
        }
        h = hash2(hh, o);
      }
      contextmap_set(&om->cm, i, h);
    }
  }
  i64 y = s->y;
  i64 c0 = s->c0;
  directmap_mix(&om->o0, m, y, c0);
  directmap_mix(&om->o1, m, y, c0);
  if (om->pairs) ordermodel_mixPairs(om, m, y, c0, s->c4 & 255);
  contextmap_mix(&om->cm, m, y, s->bpos, c0, s->c4 & 255);
}

void ordermodel_init(OrderModel *m, const i64 *orders, i64 norders, i64 bytes,
                     int rich, int bh, int pairs) {
  directmap_init(&m->o0, 0);
  directmap_init(&m->o1, 8);
  contextmap_init(&m->cm, bytes, norders, rich, bh);
  m->orders = ZNEW(i32, norders);
  for (i64 i = 0; i < norders; i++) m->orders[i] = (i32)orders[i];
  m->norders = norders;
  m->pairs = pairs;
  m->slow = ZNEW(u32, 256 + 65536);
  m->fast = ZNEW(u32, 256 + 65536);
  for (i64 i = 0; i < 256 + 65536; i++) {
    m->slow[i] = (u32)((i64)2048 << 20);
    m->fast[i] = (u32)((i64)2048 << 20);
  }
  m->i0 = 0;
  m->i1 = 256;
  m->base.inputs = 4 + (pairs ? 8 : 0) +
                   m->cm.nCtx * contextmap_inputsPerContext(&m->cm);
  m->base.mix = ordermodel_mix;
  m->base.nsel = 0;
  m->base.selSizes = 0;
  m->base.setCtx = 0;
}

// ---------------------------------------------------------------- MatchModel

static i64 matchmodel_lenQ(MatchModel *mm) {
  i64 l = mm->len;
  if (l < 16) return l;
  i64 q = 16 + (((i64)kIlog[l < 65535 ? l : 65535] - 64) >> 2);
  return q > 63 ? 63 : q;
}

// Length of the common history before [cand] and [pos] (capped).
static i64 matchmodel_verify(const u8 *buf, i64 bm, i64 cand, i64 pos) {
  if (pos - cand > bm - 64) return 0;
  i64 l = 0;
  while (l < 400 && l < cand &&
         buf[(cand - 1 - l) & bm] == buf[(pos - 1 - l) & bm]) {
    l++;
  }
  return l;
}

static void matchmodel_mix(ZModel *self, ZState *s, Mixer *m) {
  MatchModel *mm = (MatchModel *)self;
  const u8 *buf = s->buf;
  i64 bm = mm->bufMask;
  if (s->bpos == 0) {
    i64 pos = s->pos;
    if (mm->len > 0 && mm->exp != (s->c4 & 255)) mm->len = 0;
    if (mm->len > 0) {
      mm->len++;
      if (mm->len > 65535) mm->len = 65535;
      mm->ptr++;
    }
    if (pos >= mm->minS) {
      i64 hs = 0;
      for (i64 k = 1; k <= mm->minS; k++) {
        hs = (hs * 0x2F0F3A55 + buf[(pos - k) & bm] + 1) & 0xFFFFFFFF;
      }
      hs = hash2(hs, mm->minS) & mm->mask;
      i64 hl = -1;
      if (pos >= mm->minL) {
        i64 h = 0;
        for (i64 k = 1; k <= mm->minL; k++) {
          h = (h * 0x2F0F3A55 + buf[(pos - k) & bm] + 1) & 0xFFFFFFFF;
        }
        hl = hash2(h, mm->minL) & mm->mask;
      }
      if (mm->len == 0) {
        // Look for a new match, the long hash first.
        if (hl >= 0) {
          i64 cand = mm->htL[hl];
          if (cand > 0) {
            i64 l = matchmodel_verify(buf, bm, cand, pos);
            if (l >= mm->minL) {
              mm->len = l;
              mm->ptr = cand;
            }
          }
        }
        if (mm->len == 0) {
          i64 cand = mm->htS[hs];
          if (cand > 0) {
            i64 l = matchmodel_verify(buf, bm, cand, pos);
            if (l >= mm->minS) {
              mm->len = l;
              mm->ptr = cand;
            }
          }
        }
      }
      mm->htS[hs] = (i32)pos;
      if (hl >= 0) mm->htL[hl] = (i32)pos;
    }
    if (mm->len > 0) mm->exp = buf[mm->ptr & bm];
  } else if (mm->len > 0 && ((mm->exp + 256) >> (8 - s->bpos)) != s->c0) {
    mm->len = 0;
  }
  i64 y = s->y;
  if (mm->len > 0) {
    i64 bit = (mm->exp >> (7 - s->bpos)) & 1;
    i64 lq = matchmodel_lenQ(mm);
    i64 p1 = statemap_p(&mm->sm1, y, (lq << 1) | bit);
    i64 st = kStretch[p1];
    mixer_add(m, st);
    i64 lc = lq < 32 ? lq : 32;
    mixer_add(m, bit != 0 ? lc << 6 : -(lc << 6));
    i64 lb = lq < 16 ? (lq < 8 ? 0 : 1) : (lq < 24 ? 2 : 3);
    i64 p2 = statemap_p(&mm->sm2, y,
                        (((((mm->exp << 3) | s->bpos) << 1) | bit) << 2) | lb);
    mixer_add(m, kStretch[p2]);
  } else {
    statemap_p(&mm->sm1, y, 0);
    statemap_p(&mm->sm2, y, 0);
    mixer_add(m, 0);
    mixer_add(m, 0);
    mixer_add(m, 0);
  }
}

static i64 matchmodel_lengthFn(ZModel *self) {
  return matchmodel_length((MatchModel *)self);
}
static i64 matchmodel_expectedFn(ZModel *self) {
  return matchmodel_expectedByte((MatchModel *)self);
}

void matchmodel_init(MatchModel *m, i64 tableEntries, i64 bufBytes, i64 minS,
                     i64 minL) {
  i64 n = floorPow2(tableEntries);
  m->htS = ZNEW(i32, n);
  m->htL = ZNEW(i32, n);
  m->mask = n - 1;
  m->minS = minS;
  m->minL = minL;
  m->ptr = m->len = m->exp = 0;
  statemap_init(&m->sm1, 64 * 2, 1023, 0);
  statemap_init(&m->sm2, 256 * 8 * 2 * 4, 1023, 0);
  m->bufMask = floorPow2(bufBytes < 4096 ? 4096 : bufBytes) - 1;
  m->base.base.inputs = 3;
  m->base.base.mix = matchmodel_mix;
  m->base.base.nsel = 0;
  m->base.base.selSizes = 0;
  m->base.base.setCtx = 0;
  m->base.length = matchmodel_lengthFn;
  m->base.expectedByte = matchmodel_expectedFn;
}

// ---------------------------------------------------------------- WordModel

static void wordmodel_mix(ZModel *self, ZState *s, Mixer *m) {
  WordModel *w = (WordModel *)self;
  ContextMap *cm = &w->cm;
  if (s->bpos == 0) {
    i64 c = s->c4 & 255;
    i64 pos = s->pos;
    if (c >= 65 && c <= 90) c += 32;
    int letter = (c >= 97 && c <= 122) || c >= 128;
    if (letter) {
      w->w0 = hash2(w->w0 + 0x9E37, c);
      w->text0 = (w->text0 * 997 * 16 + c) & 0xFFFFFFFF;
    } else if (w->w0 != 0) {
      w->w4 = w->w3;
      w->w3 = w->w2;
      w->w2 = w->w1;
      w->w1 = w->w0;
      w->w0 = 0;
    }
    if (c >= 48 && c <= 57) {
      w->num = hash2(w->num + 7, c);
    } else if (!letter) {
      w->num = 0;
    }
    if (!letter && c != 32 && !(c >= 48 && c <= 57)) {
      w->punct = c;
    }
    // Brackets: ( [ { < and their closing forms.
    if (c == 40 || c == 91 || c == 123) {
      if (w->depth < 64) w->brackets[w->depth] = (u8)c;
      w->depth++;
    } else if ((c == 41 || c == 93 || c == 125) && w->depth > 0) {
      w->depth--;
    }
    if (c == 10) {
      w->prevNl = w->lastNl;
      w->lastNl = pos;
      w->indent = 0;
      w->inIndent = 1;
    } else if (w->inIndent != 0) {
      if (c == 32 || c == 9) {
        w->indent++;
      } else {
        w->inIndent = 0;
      }
    }
    i64 col = pos - w->lastNl;
    i64 lineLen = w->lastNl - w->prevNl;
    i64 above = col < lineLen ? zstate_back(s, lineLen) : 0;
    i64 colQ = col < 32 ? col : 32 + (col >> 4) - 2;
    i64 c1 = s->c4 & 255;
    i64 c4 = s->c4;
    i64 h = hash2(w->w0, c1);
    i64 br = w->depth == 0
                 ? 0
                 : ((i64)w->brackets[(w->depth - 1) & 63] |
                    ((w->depth < 8 ? w->depth : 8) << 8));
    contextmap_set(cm, 0, hash2(w->w0, 1));
    contextmap_set(cm, 1, hash3(h, w->w1, 2));
    contextmap_set(cm, 2, hash4(h, w->w1, w->w2, 3));
    contextmap_set(cm, 3, hash3(w->w0, w->punct, 4));
    if (cm->nCtx == 5) {
      contextmap_set(cm, 4, hash3(above, colQ, 7));
      contextmap_mix(cm, m, s->y, s->bpos, s->c0, s->c4 & 255);
      return;
    }
    contextmap_set(cm, 4, hash3(h, w->w2, 5));
    contextmap_set(cm, 5, hash3(h, w->w3, 6));
    contextmap_set(cm, 6, hash3(above, colQ, 7));
    contextmap_set(cm, 7, hash4(above, c1, (c4 >> 8) & 255, 8));
    contextmap_set(cm, 8, hash3(w->num, w->w0 == 0 ? c1 : 256, 9));
    contextmap_set(cm, 9, hash4(h, w->w1, w->w3, 10));
    if (cm->nCtx < 16) {
      contextmap_mix(cm, m, s->y, s->bpos, s->c0, s->c4 & 255);
      return;
    }
    contextmap_set(cm, 10, hash2(w->text0 & 0xFFFFFF, 11));
    contextmap_set(cm, 11, hash2(w->text0 & 0xFFFFF, 12));
    contextmap_set(cm, 12, hash3(c1 | ((c4 >> 8) & 0xFF00), w->w4, 13));
    contextmap_set(cm, 13, hash4(w->indent, w->inIndent, col < 64 ? col : 64,
                                 c1 | (14 << 8)));
    contextmap_set(cm, 14, hash3(br, c1, 15));
    contextmap_set(cm, 15, hash4(br, w->w0, (c4 >> 8) & 255, 16));
  }
  contextmap_mix(cm, m, s->y, s->bpos, s->c0, s->c4 & 255);
}

void wordmodel_init(WordModel *m, i64 bytes, i64 contexts) {
  contextmap_init(&m->cm, bytes,
                  contexts <= 5 ? 5 : (contexts < 16 ? 10 : 16), 1, 0);
  m->w0 = m->w1 = m->w2 = m->w3 = m->w4 = 0;
  m->text0 = 0;
  m->lastNl = m->prevNl = 0;
  m->indent = 0;
  m->inIndent = 1;
  m->punct = 0;
  m->num = 0;
  memset(m->brackets, 0, sizeof m->brackets);
  m->depth = 0;
  m->base.inputs = m->cm.nCtx * contextmap_inputsPerContext(&m->cm);
  m->base.mix = wordmodel_mix;
  m->base.nsel = 0;
  m->base.selSizes = 0;
  m->base.setCtx = 0;
}

// ---------------------------------------------------------------- SparseModel

static void sparsemodel_mix(ZModel *self, ZState *s, Mixer *m) {
  ContextMap *cm = &((SparseModel *)self)->cm;
  if (s->bpos == 0 && cm->nCtx == 5) {
    i64 c4 = s->c4;
    i64 lane = s->pos & 3;
    contextmap_set(cm, 0, c4 & 0xFF00);
    contextmap_set(cm, 1, c4 & 0xFF0000);
    contextmap_set(cm, 2, c4 & 0xFF00FF00);
    contextmap_set(cm, 3, hash2(c4 & 0xFFFF, s->c8 >> 16));
    contextmap_set(cm, 4, hash4(lane, c4 >> 24, s->c8 >> 24, 9));
  } else if (s->bpos == 0) {
    i64 c4 = s->c4;
    contextmap_set(cm, 0, c4 & 0xFF00);
    contextmap_set(cm, 1, c4 & 0xFF0000);
    contextmap_set(cm, 2, c4 & 0xFF000000);
    contextmap_set(cm, 3, c4 & 0xFFFF0000);
    contextmap_set(cm, 4, c4 & 0xFF00FF00);
    contextmap_set(cm, 5, c4 & 0x00FF00FF);
    contextmap_set(cm, 6, hash2(s->c8 & 0xFFFF, 6));
    contextmap_set(cm, 7, hash2(c4 & 0xFFFF, s->c8 >> 16));
    // Lanes of 32-bit words.
    i64 lane = s->pos & 3;
    contextmap_set(cm, 8, hash3(lane, c4 >> 24, 8));
    contextmap_set(cm, 9, hash4(lane, c4 >> 24, s->c8 >> 24, 9));
  }
  contextmap_mix(cm, m, s->y, s->bpos, s->c0, s->c4 & 255);
}

void sparsemodel_init(SparseModel *m, i64 bytes, int light) {
  contextmap_init(&m->cm, bytes, light ? 5 : 10, 0, 0);
  m->base.inputs = m->cm.nCtx * contextmap_inputsPerContext(&m->cm);
  m->base.mix = sparsemodel_mix;
  m->base.nsel = 0;
  m->base.selSizes = 0;
  m->base.setCtx = 0;
}

// ---------------------------------------------------------------- IndirectModel

static void im_put(IndirectModel *im, i64 h) {
  i64 k = im->k++;
  contextmap_set(&im->cm, k, hash2(h, ++im->i));
}

static void im_setLarge(IndirectModel *im, i64 ctx, i64 c1) {
  i64 j = hash2(ctx, im->i) & im->largeMask;
  im->large[j] = (u32)((((i64)im->large[j] << 8) | c1) & 0xFFFFFFFF);
}

static i64 im_getLarge(IndirectModel *im, i64 ctx) {
  return im->large[hash2(ctx, im->i) & im->largeMask];
}

static void im_setFull(IndirectModel *im, ZState *s) {
  u32 *t1 = im->t1;
  u16 *t2 = im->t2, *t3 = im->t3, *t4 = im->t4;
  u32 *t5 = im->t5;
  i64 c4 = s->c4;
  i64 b1 = c4 & 255, b2 = (c4 >> 8) & 255, b3 = (c4 >> 16) & 255;
  i64 b4 = (c4 >> 24) & 255, b5 = s->c8 & 255;
  i64 c1 = b1;
  i64 d2 = c4 & 0xFFFF;
  i64 d3 = (b1 >> 3) | ((b2 >> 3) << 5) | ((b3 >> 3) << 10);
  i64 d4 = (b1 >> 4) | ((b2 >> 4) << 4) | ((b3 >> 4) << 8) | ((b4 >> 4) << 12);
  i64 h1 = (c1 | ((i64)t1[c1] << 8)) & 0xFFFFFFFF;
  i64 h2 = d2 | ((i64)t2[d2] << 16);
  i64 h3 = d3 | ((i64)t3[d3] << 16);
  i64 h4 = d4 | ((i64)t4[d4] << 16);
  t1[d2 >> 8] = (u32)((((i64)t1[d2 >> 8] << 8) | c1) & 0xFFFFFFFF);
  t2[(c4 >> 8) & 0xFFFF] = (u16)(((i64)t2[(c4 >> 8) & 0xFFFF] << 8) | c1);
  i64 i3 = (b2 >> 3) | ((b3 >> 3) << 5) | ((b4 >> 3) << 10);
  t3[i3] = (u16)(((i64)t3[i3] << 8) | c1);
  i64 i4 = (b2 >> 4) | ((b3 >> 4) << 4) | ((b4 >> 4) << 8) | ((b5 >> 4) << 12);
  t4[i4] = (u16)(((i64)t4[i4] << 8) | c1);
  int text = s->blockType == ZT_TEXT;
  im->i = s->blockType * 64;
  im->k = 0;
  im_put(im, h1);
  im_put(im, h1 & 0xFFFFFF00);
  im_put(im, t1[c1]);
  im_put(im, h2);
  im_put(im, h4);
  im_put(im, h1 & 0xFFFF);
  im_put(im, h2 & 0xFF0000);
  im_put(im, h2 & 0xFFFFFF);
  if (!text) {
    im_put(im, h1 & 0xFF00);
    im_put(im, h3);
    im_put(im, h3 & 0xFF0000);
    im_put(im, h3 & 0xFFFFFF);
    im_put(im, h4 & 0xFF0000);
    im_put(im, h4 & 0xFFFFFF);
  }
  // Lowercase text contexts.
  i64 lc = (c1 >= 65 && c1 <= 90) ? c1 + 32 : c1;
  im->chars4 = ((im->chars4 << 8) | lc) & 0xFFFFFFFF;
  i64 h5 = t5[im->chars4 & 0xFFFF];
  i64 i5 = (im->chars4 >> 8) & 0xFFFF;
  t5[i5] = (u32)((((i64)t5[i5] << 8) | lc) & 0xFFFFFFFF);
  im_put(im, (h5 & 0xFF) | (lc << 8));
  im_put(im, h5 & 0xFFFF);
  im_put(im, h5 & 0xFFFFFF);
  im_put(im, h5);
  // Hashed contexts of 3 and 4 bytes and their byte histories.
  im_setLarge(im, c4 >> 8, c1);
  i64 ctx = c4 & 0xFFFFFF;
  i64 h6 = im_getLarge(im, ctx);
  im_put(im, hash2(h6 & 0xFF, ctx & 0xFF));
  im_put(im, hash2(h6 & 0xFF, ctx & 0xFFFF));
  im_put(im, hash2(h6, ctx & 0xFF));
  im_setLarge(im, (im->chars4 >> 8) | 0x1000000, c1);
  ctx = (im->chars4 & 0xFFFFFF) | 0x1000000;
  h6 = im_getLarge(im, ctx);
  im_put(im, hash2(h6 & 0xFF, ctx));
  im_put(im, hash2(h6 & 0xFFFF, ctx));
  im_put(im, h6);
  im_setLarge(im, hash2((b5 << 24) | (c4 >> 8), 7), c1);
  h6 = im_getLarge(im, hash2(c4, 7));
  im_put(im, hash2(h6 & 0xFF, c4 & 0xFFFF));
  im_put(im, hash2(h6 & 0xFFFF, c4 & 0xFF));
  im_put(im, h6);
  // Text blocks use fewer contexts: fill the rest.
  while (im->k < im->cm.nCtx) {
    im_put(im, 0);
  }
}

static void indirectmodel_mix(ZModel *self, ZState *s, Mixer *m) {
  IndirectModel *im = (IndirectModel *)self;
  ContextMap *cm = &im->cm;
  if (s->bpos == 0) {
    if (im->full) {
      im_setFull(im, s);
    } else {
      i64 c4 = s->c4;
      i64 d = c4 & 0xFFFF;
      i64 c = d & 255;
      im->t1[d >> 8] = (u32)((((i64)im->t1[d >> 8] << 8) | c) & 0xFFFFFFFF);
      i64 i2 = (c4 >> 8) & 0xFFFF;
      im->t2[i2] = (u16)((((i64)im->t2[i2] << 8) | c) & 0xFFFF);
      i64 t = (c | ((i64)im->t1[c] << 8)) & 0xFFFFFFFF;
      contextmap_set(cm, 0, t & 0xFFFF);
      contextmap_set(cm, 1, t & 0xFFFFFF);
      contextmap_set(cm, 2, hash2(t, 2));
      contextmap_set(cm, 3, t & 0xFF00);
      t = d | ((i64)im->t2[d] << 16);
      contextmap_set(cm, 4, hash2(t & 0xFFFFFF, 4));
      contextmap_set(cm, 5, hash2(t, 5));
    }
  }
  contextmap_mix(cm, m, s->y, s->bpos, s->c0, s->c4 & 255);
}

void indirectmodel_init(IndirectModel *m, i64 bytes, int full) {
  contextmap_init(&m->cm, full ? bytes * 3 / 4 : bytes, full ? 27 : 6, 0, 0);
  m->full = full;
  m->t1 = ZNEW(u32, 256);
  m->t2 = ZNEW(u16, 65536);
  m->t3 = ZNEW(u16, 32768);
  m->t4 = ZNEW(u16, 65536);
  m->t5 = ZNEW(u32, 65536);
  i64 nl = full ? floorPow2(bytes / 16 < 4096 ? 4096 : bytes / 16) : 1;
  m->large = ZNEW(u32, nl);
  m->largeMask = full ? nl - 1 : 0;
  m->chars4 = 0;
  m->i = m->k = 0;
  m->base.inputs = m->cm.nCtx * contextmap_inputsPerContext(&m->cm);
  m->base.mix = indirectmodel_mix;
  m->base.nsel = 0;
  m->base.selSizes = 0;
  m->base.setCtx = 0;
}

// ---------------------------------------------------------------- CharGroupModel

static void chargroupmodel_mix(ZModel *self, ZState *s, Mixer *m) {
  CharGroupModel *g = (CharGroupModel *)self;
  ContextMap *cm = &g->cm;
  if (s->bpos == 0) {
    i64 c4 = s->c4;
    i64 v = c4 & 255;
    if (v >= 48 && v <= 57) {
      v = 48;
    } else if (v >= 65 && v <= 90) {
      v = 65;
    } else if (v >= 97 && v <= 122) {
      v = 97;
    } else if (v >= 128) {
      v = 128;
    }
    int collapse = (v == 48 || v == 65 || v == 97) && v == (g->g1 & 255);
    if (!collapse) {
      g->g3 = ((g->g3 << 8) | (g->g2 >> 24)) & 0xFFFFFFFF;
      g->g2 = ((g->g2 << 8) | (g->g1 >> 24)) & 0xFFFFFFFF;
      g->g1 = ((g->g1 << 8) | v) & 0xFFFFFFFF;
    }
    i64 i = collapse ? 7 : 0;
    contextmap_set(cm, 0, hash4(++i, g->g3, g->g2, g->g1));
    contextmap_set(cm, 1, hash3(++i, g->g2, g->g1));
    contextmap_set(cm, 2, hash3(++i, g->g2 & 0xFFFF, g->g1));
    contextmap_set(cm, 3, hash2(++i, g->g1));
    contextmap_set(cm, 4, hash2(++i, g->g1 & 0xFFFF));
    contextmap_set(cm, 5, hash4(++i, g->g2 & 0xFFFFFF, g->g1, c4 & 0xFFFF));
    contextmap_set(cm, 6, hash4(++i, g->g2 & 0xFF, g->g1, c4 & 0xFFFFFF));
  }
  contextmap_mix(cm, m, s->y, s->bpos, s->c0, s->c4 & 255);
}

void chargroupmodel_init(CharGroupModel *m, i64 bytes) {
  contextmap_init(&m->cm, bytes, 7, 1, 1);
  m->g1 = m->g2 = m->g3 = 0;
  m->base.inputs = m->cm.nCtx * contextmap_inputsPerContext(&m->cm);
  m->base.mix = chargroupmodel_mix;
  m->base.nsel = 0;
  m->base.selSizes = 0;
  m->base.setCtx = 0;
}

// ---------------------------------------------------------------- RecordModel

static void recordmodel_mix(ZModel *self, ZState *s, Mixer *m) {
  RecordModel *rm = (RecordModel *)self;
  ContextMap *cm = &rm->cm;
  if (s->bpos == 0) {
    i32 *cpos1 = rm->cpos1, *cpos2 = rm->cpos2, *cpos3 = rm->cpos3,
        *cpos4 = rm->cpos4;
    i64 pos = s->pos;
    i64 c4 = s->c4;
    i64 c = c4 & 255;
    i64 w = c4 & 0xFFFF;
    i64 r = pos - cpos1[c];
    if (r > 1 && r == (i64)cpos1[c] - cpos2[c] &&
        r == (i64)cpos2[c] - cpos3[c] && r == (i64)cpos3[c] - cpos4[c] &&
        (r > 15 || (r * 6 + 1 <= pos && c == zstate_back(s, r * 5 + 1) &&
                    c == zstate_back(s, r * 6 + 1)))) {
      if (r == rm->rlen1) {
        rm->rcount1++;
      } else if (r == rm->rlen2) {
        rm->rcount2++;
      } else if (rm->rcount1 > rm->rcount2) {
        rm->rlen2 = r;
        rm->rcount2 = 1;
      } else {
        rm->rlen1 = r;
        rm->rcount1 = 1;
      }
    }
    if (rm->rcount1 > 15 && rm->rlen != rm->rlen1) {
      rm->rlen = rm->rlen1;
      rm->rcount1 = rm->rcount2 = 0;
    }
    if (rm->rcount2 > 15 && rm->rlen != rm->rlen2) {
      rm->rlen = rm->rlen2;
      rm->rcount1 = rm->rcount2 = 0;
    }
    cpos4[c] = cpos3[c];
    cpos3[c] = cpos2[c];
    cpos2[c] = cpos1[c];
    cpos1[c] = (i32)pos;
    i64 dw = pos - rm->wpos1[w];
    rm->wpos1[w] = (i32)pos;
    i64 rl = rm->rlen;
    i64 above = rl <= pos ? zstate_back(s, rl) : 0;
    i64 above2 = rl * 2 <= pos ? zstate_back(s, rl * 2) : 0;
    i64 col = pos % rl;
    i64 dc = pos - cpos2[c];
    contextmap_set(cm, 0, hash2((c << 8) | (dc < 1020 ? dc >> 2 : 255), 0));
    contextmap_set(cm, 1,
                   hash2((w << 9) | ((i64)kIlog[dw < 65535 ? dw : 65535] >> 2),
                         1));
    contextmap_set(cm, 2, hash3(rl, above | (above2 << 8), 2));
    contextmap_set(cm, 3, hash3(rl, above | (col << 8), 3));
    contextmap_set(cm, 4, hash3(rl, c | (col << 8), 4));
    contextmap_set(cm, 5, hash3(rl, w, 5));
  }
  contextmap_mix(cm, m, s->y, s->bpos, s->c0, s->c4 & 255);
}

void recordmodel_init(RecordModel *m, i64 bytes) {
  contextmap_init(&m->cm, bytes, 6, 0, 0);
  m->cpos1 = ZNEW(i32, 256);
  m->cpos2 = ZNEW(i32, 256);
  m->cpos3 = ZNEW(i32, 256);
  m->cpos4 = ZNEW(i32, 256);
  m->wpos1 = ZNEW(i32, 65536);
  m->rlen = 2;
  m->rlen1 = 3;
  m->rlen2 = 4;
  m->rcount1 = m->rcount2 = 0;
  m->base.inputs = m->cm.nCtx * contextmap_inputsPerContext(&m->cm);
  m->base.mix = recordmodel_mix;
  m->base.nsel = 0;
  m->base.selSizes = 0;
  m->base.setCtx = 0;
}

// ---------------------------------------------------------------- ExeModel

static i64 exe_pref(i64 b) {
  return (b == 0x0F ? 1 : 0) + (b == 0x66 ? 2 : 0) + (b == 0x67 ? 3 : 0);
}

// execxt(i, x)
static i64 exe_ctx(ZState *s, i64 i, i64 x) {
  i64 prefix = 0, opcode = 0, modrm = 0, sib = 0;
  i64 pos = s->pos;
  if (i > 0 && i <= pos) prefix += 4 * exe_pref(zstate_back(s, i--));
  if (i > 0 && i <= pos) prefix += exe_pref(zstate_back(s, i--));
  if (i > 0 && i <= pos) opcode += zstate_back(s, i--);
  if (i > 0 && i <= pos) modrm += zstate_back(s, i--) & 0xC7;
  if (i > 0 && i <= pos && (modrm & 7) == 4 && modrm < 0xC0) {
    sib = zstate_back(s, i) & 0xC0;
  }
  return prefix | (opcode << 4) | (modrm << 12) | (x << 20) | (sib << 22);
}

static void exemodel_mix(ZModel *self, ZState *s, Mixer *m) {
  static const i64 kOrder[8] = {0, 1, 2, 5, 4, 6, 3, 7};
  ContextMap *cm = &((ExeModel *)self)->cm;
  if (s->bpos == 0) {
    i64 n = cm->nCtx;
    for (i64 k = 0; k < n; k++) {
      i64 i = n == 8 ? k : kOrder[k];
      i64 j = i < 4 ? i + 1 : 5 + (i - 4) * (2 + (i > 6 ? 1 : 0));
      contextmap_set(cm, k,
                     hash3(i, exe_ctx(s, j, j > 6 ? (s->c4 & 255) : 0),
                           s->pos & 3));
    }
  }
  contextmap_mix(cm, m, s->y, s->bpos, s->c0, s->c4 & 255);
}

void exemodel_init(ExeModel *m, i64 bytes, i64 contexts) {
  contextmap_init(&m->cm, bytes, contexts, 0, 0);
  m->base.inputs = m->cm.nCtx * contextmap_inputsPerContext(&m->cm);
  m->base.mix = exemodel_mix;
  m->base.nsel = 0;
  m->base.selSizes = 0;
  m->base.setCtx = 0;
}

// ---------------------------------------------------------------- DmcModel

i64 dmcmodel_nodesFor(i64 bytes) {
  return bytes / 12 < ((i64)1 << 18) ? ((i64)1 << 18) : bytes / 12;
}

static void dmc_reset(DmcModel *d) {
  for (i64 i = 0; i < 256; i++) {
    for (i64 j = 0; j < 256; j++) {
      i64 k = j * 256 + i;
      if (i < 127) {
        d->nx0[k] = (i32)(j * 256 + i * 2 + 1);
        d->nx1[k] = (i32)(j * 256 + i * 2 + 2);
      } else {
        d->nx0[k] = (i32)((i - 127) * 256);
        d->nx1[k] = (i32)((i + 1) * 256);
      }
      d->c0[k] = 128;
      d->c1[k] = 128;
      d->state[k] = 0;
    }
  }
  d->top = 65536;
  d->curr = 0;
  d->threshold = d->baseThreshold;
}

static void dmcmodel_mix(ZModel *self, ZState *s, Mixer *m) {
  DmcModel *d = (DmcModel *)self;
  i32 *nx0 = d->nx0, *nx1 = d->nx1;
  u16 *c0 = d->c0, *c1 = d->c1;
  i64 y = s->y;
  if (d->top == 0) {
    dmc_reset(d);
  } else {
    // Clone the next state when it is reached often from here.
    i64 curr = d->curr;
    if (d->top < d->size) {
      i64 next = y != 0 ? nx1[curr] : nx0[curr];
      i64 n = y != 0 ? c1[curr] : c0[curr];
      i64 nn = (i64)c0[next] + c1[next];
      if (n >= d->threshold * 2 && nn - n >= d->threshold * 3) {
        i64 r = n * 4096 / nn;
        i64 top = d->top;
        i64 a0 = ((i64)c0[next] * r) >> 12;
        i64 a1 = ((i64)c1[next] * r) >> 12;
        c0[top] = (u16)a0;
        c1[top] = (u16)a1;
        c0[next] = (u16)(c0[next] - a0);
        c1[next] = (u16)(c1[next] - a1);
        nx0[top] = nx0[next];
        nx1[top] = nx1[next];
        d->state[top] = d->state[next];
        if (y != 0) {
          nx1[curr] = (i32)top;
        } else {
          nx0[curr] = (i32)top;
        }
        d->top = top + 1;
        if (d->top == d->size * 2 / 3) d->threshold = d->baseThreshold * 2;
        if (d->top == d->size * 5 / 6) d->threshold = d->baseThreshold * 3;
      }
    }
    // Update the counts and the state.
    if (y != 0) {
      if (c1[curr] < 3800) c1[curr] = (u16)(c1[curr] + 256);
    } else if (c0[curr] < 3800) {
      c0[curr] = (u16)(c0[curr] + 256);
    }
    d->state[curr] = (u8)nextState(d->state[curr], y, &d->rnd);
    d->curr = y != 0 ? nx1[curr] : nx0[curr];
    if (d->top >= d->size && s->bpos == 1) dmc_reset(d);
  }
  i64 c = d->curr;
  i64 p1 = statemap_p(&d->sm, y, d->state[c]);
  i64 n1 = c1[c];
  i64 n0 = c0[c];
  i64 p2 = (n1 + 5) * 4096 / (n0 + n1 + 10);
  if (p2 > 4095) p2 = 4095;
  i32 *tx = m->tx;
  i64 k = m->nx;
  GainGate *g = d->gate;
  if (g) {
    gaingate_update(g, y);
    gaingate_record(g, p1);
    if (!gaingate_open(g)) {
      tx[k] = 0;
      tx[k + 1] = 0;
      m->nx = k + 2;
      return;
    }
  }
  tx[k] = kStretch[p1];
  tx[k + 1] = kStretch[p2];
  m->nx = k + 2;
}

void dmcmodel_init(DmcModel *m, i64 bytes, i64 threshold) {
  m->gate = 0;
  i64 n = dmcmodel_nodesFor(bytes);
  m->size = n;
  m->nx0 = ZNEW(i32, n);
  m->nx1 = ZNEW(i32, n);
  m->state = ZNEW(u8, n);
  m->c0 = ZNEW(u16, n);
  m->c1 = ZNEW(u16, n);
  statemap_init(&m->sm, 256, 1023, 1);
  m->top = 0;
  m->curr = 0;
  m->threshold = 256;
  m->baseThreshold = threshold;
  zrandom_init(&m->rnd);
  m->base.inputs = 2;
  m->base.mix = dmcmodel_mix;
  m->base.nsel = 0;
  m->base.selSizes = 0;
  m->base.setCtx = 0;
}
