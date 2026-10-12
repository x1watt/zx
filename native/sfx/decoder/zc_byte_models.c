// zxsfx decoder: port of zcm_byte_models.dart, byte predictors turned into
// bit predictions (level 9).
//
// cmix (Byron Knoll) uses byte models: a model gives a probability for
// each of the 256 next bytes, and the bit predictions follow from the sums
// over the bytes that agree with the bits coded so far (ByteModel in
// cmix). Two such models are here: PPMd var.H (Dmitry Shkarin; the port
// of the LZMA SDK's Ppmd7.c, used as a predictor the way cmix's
// models/ppmd.cpp uses PPMd var.J) and the LSTM of zc_lstm.c.
//
// The PPMd distribution is computed with doubles (+, -, *, / only, fixed
// order), the PPMd model itself stays integer; both are deterministic.

#include "zc_byte_models.h"

// ---------------------------------------------------------------- bits

// Sets the distribution of the next byte ([p] need not be normalised).
static void bits_setBytes(ZBitsFromBytes *b, const double *p) {
  double s = 0.0;
  b->cum[0] = 0.0;
  for (i64 i = 0; i < 256; i++) {
    s += p[i];
    b->cum[i + 1] = s;
  }
  b->lo = 0;
  b->hi = 256;
}

// 12 bit probability that the next bit is 1, given the bits so far.
static i64 bits_p(const ZBitsFromBytes *b) {
  i64 mid = (b->lo + b->hi) >> 1;
  double all = b->cum[b->hi] - b->cum[b->lo];
  if (!(all > 0.0)) return 2048;
  double one = b->cum[b->hi] - b->cum[mid];
  i64 q = dfloor(one / all * 4096.0);
  if (q < 1) q = 1;
  if (q > 4095) q = 4095;
  return q;
}

static void bits_bit(ZBitsFromBytes *b, i64 y) {
  i64 mid = (b->lo + b->hi) >> 1;
  if (y != 0) {
    b->lo = mid;
  } else {
    b->hi = mid;
  }
}

// ---------------------------------------------------------------- base

static void bytemodel_mix(ZModel *self, ZState *s, Mixer *m) {
  ZByteModel *b = (ZByteModel *)self;
  if (s->bpos == 0) {
    if (b->started) b->byteUpdate(b, s->c4 & 255);
    b->started = 1;
    bits_setBytes(&b->bits, b->distribution);
  } else {
    bits_bit(&b->bits, s->y);
  }
  i64 p = bits_p(&b->bits);
  i64 st = kStretch[p];
  i64 p2 = statemap_p(&b->sm, s->y, ((p >> 4) << 3) | s->bpos);
  i32 *tx = m->tx;
  i64 k = m->nx;
  GainGate *g = b->gate;
  if (g != NULL) {
    gaingate_update(g, s->y);
    gaingate_record(g, p);
    if (!gaingate_open(g)) {
      tx[k] = 0;
      tx[k + 1] = 0;
      tx[k + 2] = 0;
      m->nx = k + 3;
      return;
    }
  }
  tx[k] = (i32)st;
  tx[k + 1] = (i32)((p - 2048) >> 2);
  tx[k + 2] = kStretch[p2];
  m->nx = k + 3;
}

static void bytemodel_init(ZByteModel *b, double *distribution,
                           void (*byteUpdate)(ZByteModel *, i64)) {
  b->base.inputs = 3;
  b->base.mix = bytemodel_mix;
  b->base.nsel = 0;
  b->base.selSizes = NULL;
  b->base.setCtx = NULL;
  b->bits.lo = 0;
  b->bits.hi = 256;
  statemap_init(&b->sm, 4096 * 8, 1023, 0);
  b->started = 0;
  b->gate = NULL;
  b->byteUpdate = byteUpdate;
  b->distribution = distribution;
}

// ---------------------------------------------------------------- PPMd

// The probability of every symbol in the current context chain, with the
// escapes and exclusions of PPMd (read only: nothing of the model changes
// here).
static void ppmd_computeDistribution(PpmdByteModel *pm) {
  Ppmd7 *p = pm->p;
  const u8 *m8 = p->mem;
  const u16a *m16 = p->mem16;
  const u32a *m32 = p->mem32;
  double *probs = pm->probs;
  u8 *mask = pm->mask;
  for (i64 i = 0; i < 256; i++) {
    probs[i] = 0.0;
    mask[i] = 0;
  }
  double mass = 1.0;
  i64 mc = p->minContext;
  i64 numMasked = 0;
  i64 hiBits;
  i64 ns = m16[mc >> 1];
  if (ns != 1) {
    i64 summ = m16[(mc >> 1) + 1];
    i64 s = m32[(mc >> 2) + 1];
    i64 sum = 0;
    for (i64 i = 0; i < ns; i++, s += 6) {
      i64 f = m8[s + 1];
      sum += f;
      probs[m8[s]] += mass * (double)f / (double)summ;
      mask[m8[s]] = 1;
    }
    i64 esc = summ - sum;
    mass = mass * (double)(esc > 0 ? esc : 1) / (double)summ;
    hiBits = ppmd7HiBitsFlag3(m8[p->foundState]);
    numMasked = ns;
  } else {
    // Binary context: the probability of its only symbol.
    i64 suffix = m32[(mc >> 2) + 2];
    hiBits = ((m8[p->foundState] + 0xC0) >> (8 - 3)) & (1 << 3);
    i64 idx = ((i64)m8[mc + 3] - 1) * 64 + p->prevSuccess +
              ((p->runLength >> 26) & 0x20) +
              p->ns2BSIndx[m16[suffix >> 1] - 1] +
              (((m8[mc + 2] + 0xC0) >> (8 - 4)) & (1 << 4)) + hiBits;
    double pr = (double)p->binSumm[idx] / (double)PPMD_BIN_SCALE;
    probs[m8[mc + 2]] += mass * pr;
    mask[m8[mc + 2]] = 1;
    mass = mass * (1.0 - pr);
    numMasked = 1;
  }
  // Escape to the shorter contexts.
  while (mass > 1e-12) {
    i64 suffix = m32[(mc >> 2) + 2];
    if (suffix == 0) break;
    mc = suffix;
    i64 n = m16[mc >> 1];
    if (n == numMasked) continue;
    i64 esc;
    if (n != 256) {
      i64 nonMasked = n - numMasked;
      i64 suf2 = m32[(mc >> 2) + 2];
      i64 see = (i64)p->ns2Indx[nonMasked - 1] * 16 + hiBits +
                (nonMasked < (((i64)m16[suf2 >> 1] - n) & 0xFFFFFFFF) ? 1
                                                                       : 0) +
                2 * (m16[(mc >> 1) + 1] < 11 * n ? 1 : 0) +
                4 * (numMasked > nonMasked ? 1 : 0);
      i64 r = (i64)p->seeSumm[see] >> p->seeShift[see];
      esc = r == 0 ? 1 : r;
    } else {
      esc = 1;
    }
    i64 s = m32[(mc >> 2) + 1];
    i64 sum = 0;
    for (i64 i = 0; i < n; i++, s += 6) {
      if (mask[m8[s]] == 0) sum += m8[s + 1];
    }
    i64 total = sum + esc;
    s = m32[(mc >> 2) + 1];
    for (i64 i = 0; i < n; i++, s += 6) {
      i64 sym = m8[s];
      if (mask[sym] == 0) {
        probs[sym] += mass * (double)m8[s + 1] / (double)total;
        mask[sym] = 1;
      }
    }
    mass = mass * (double)esc / (double)total;
    numMasked = n;
  }
  // Whatever is left goes to the symbols never seen.
  i64 unseen = 0;
  for (i64 i = 0; i < 256; i++) {
    if (mask[i] == 0) unseen++;
  }
  if (unseen > 0) {
    double each = mass / (double)unseen;
    for (i64 i = 0; i < 256; i++) {
      if (mask[i] == 0) probs[i] = each;
    }
  }
  // A floor so that no byte is impossible.
  for (i64 i = 0; i < 256; i++) probs[i] += 1e-7;
}

static void ppmd_byteUpdate(ZByteModel *self, i64 byte) {
  PpmdByteModel *m = (PpmdByteModel *)self;
  ppmdUpdateSymbol(m->p, byte);
  ppmd_computeDistribution(m);
}

void ppmdbytemodel_init(PpmdByteModel *m, i64 order, i64 memBytes) {
  bytemodel_init(&m->b, m->probs, ppmd_byteUpdate);
  m->p = ZNEW(Ppmd7, 1);
  ppmd7_construct(m->p);
  i64 mem = memBytes;
  if (mem < PPMD7_MIN_MEM_SIZE) mem = PPMD7_MIN_MEM_SIZE;
  if (mem > ((i64)1 << 31)) mem = (i64)1 << 31;
  ppmd7_alloc(m->p, mem);
  ppmd7_init(m->p, order < 2 ? 2 : (order > 64 ? 64 : order));
  ppmd_computeDistribution(m);
}

// ---------------------------------------------------------------- LSTM

static void lstm_byteUpdate(ZByteModel *self, i64 byte) {
  LstmByteModel *m = (LstmByteModel *)self;
  zlstm_perceive(&m->lstm, byte);
  const double *o = zlstm_probabilities(&m->lstm);
  for (i64 i = 0; i < 256; i++) m->probs[i] = o[i] + 1e-7;
}

void lstmbytemodel_init(LstmByteModel *m, i64 cells, i64 layers,
                        i64 horizon) {
  bytemodel_init(&m->b, m->probs, lstm_byteUpdate);
  for (i64 i = 0; i < 256; i++) m->probs[i] = 1.0 / 256.0;
  zlstm_init(&m->lstm, cells, layers, horizon, 0);
}

// ---------------------------------------------------------------- mixer

static void mixer_byteUpdate(ZByteModel *self, i64 byte) {
  ByteMixerModel *m = (ByteMixerModel *)self;
  // cmix scales the sum of the distributions by 2 / (number of models);
  // 16 was better here.
  const double *d = m->source->b.distribution;
  for (i64 i = 0; i < 256; i++) m->in[i] = d[i] * 16.0;
  zlstm_setAux(&m->lstm, m->in);
  zlstm_perceive(&m->lstm, byte);
  const double *o = zlstm_probabilities(&m->lstm);
  for (i64 i = 0; i < 256; i++) m->probs[i] = o[i] + 1e-7;
}

void bytemixermodel_init(ByteMixerModel *m, PpmdByteModel *source,
                         i64 cells, i64 layers, i64 horizon) {
  bytemodel_init(&m->b, m->probs, mixer_byteUpdate);
  m->source = source;
  for (i64 i = 0; i < 256; i++) m->probs[i] = 1.0 / 256.0;
  zlstm_init(&m->lstm, cells, layers, horizon, 256);
}

// ---------------------------------------------------------------- update

// Updates the PPMd model with [symbol] (Ppmd7z_EncodeSymbol without the
// range coder: the same model changes, in the same order).
void ppmdUpdateSymbol(Ppmd7 *p, i64 symbol) {
  u8 *m8 = p->mem;
  u16a *m16 = p->mem16;
  u32a *m32 = p->mem32;
  u8 *charMask = p->charMask;
  i64 mc = p->minContext;
  if (m16[mc >> 1] != 1) {
    i64 s = m32[(mc >> 2) + 1];
    if (m8[s] == symbol) {
      p->foundState = s;
      ppmd7_update1_0(p);
      return;
    }
    p->prevSuccess = 0;
    i64 i = (i64)m16[mc >> 1] - 1;
    do {
      s += 6;
      if (m8[s] == symbol) {
        p->foundState = s;
        ppmd7_update1(p);
        return;
      }
    } while (--i != 0);
    p->hiBitsFlag = ppmd7HiBitsFlag3(m8[p->foundState]);
    ppmd7_setAllBitsInCharMask(p);
    {
      i64 s2 = m32[(mc >> 2) + 1];
      charMask[m8[s]] = 0;
      do {
        i64 sym0 = m8[s2];
        i64 sym1 = m8[s2 + 6];
        s2 += 12;
        charMask[sym0] = 0;
        charMask[sym1] = 0;
      } while (s2 < s);
    }
  } else {
    i64 prob = ppmd7_getBinSumm(p);
    i64 s = mc + 2;
    i64 pr = p->binSumm[prob];
    pr = pr - ((pr + (1 << (PPMD_PERIOD_BITS - 2))) >> PPMD_PERIOD_BITS);
    if (m8[s] == symbol) {
      p->binSumm[prob] = (u16)(pr + (1 << PPMD_INT_BITS));
      ppmd7_updateBin(p, s);
      return;
    }
    p->binSumm[prob] = (u16)pr;
    p->initEsc = p->expEscape[pr >> 10];
    ppmd7_setAllBitsInCharMask(p);
    charMask[m8[s]] = 0;
    p->prevSuccess = 0;
  }
  for (;;) {
    i64 see;
    i64 escFreq;
    i64 i;
    mc = p->minContext;
    i64 numMasked = m16[mc >> 1];
    do {
      p->orderFall++;
      i64 suffix = m32[(mc >> 2) + 2];
      if (suffix == 0) {
        // Not reachable for bytes (the root context has all 256), but a
        // model restart keeps the state valid if it ever happens.
        ppmd7_init(p, p->maxOrder);
        return;
      }
      mc = suffix;
      i = m16[mc >> 1];
    } while (i == numMasked);
    p->minContext = mc;
    if (i != 256) {
      i64 nonMasked = i - numMasked;
      i64 suffix = m32[(mc >> 2) + 2];
      see = (i64)p->ns2Indx[nonMasked - 1] * 16 + p->hiBitsFlag +
            (nonMasked < (((i64)m16[suffix >> 1] - i) & 0xFFFFFFFF) ? 1 : 0) +
            2 * (m16[(mc >> 1) + 1] < 11 * i ? 1 : 0) +
            4 * (numMasked > nonMasked ? 1 : 0);
      i64 summ = p->seeSumm[see];
      i64 r = summ >> p->seeShift[see];
      p->seeSumm[see] = (u16)(summ - r);
      escFreq = r + (r == 0 ? 1 : 0);
    } else {
      see = PPMD_DUMMY_SEE;
      escFreq = 1;
    }
    i64 s = m32[(mc >> 2) + 1];
    i64 sum = 0;
    do {
      i64 cur = m8[s];
      if (cur == symbol) {
        ppmd7_seeUpdate(p, see);
        p->foundState = s;
        ppmd7_update2(p);
        return;
      }
      sum += (m8[s + 1] & charMask[cur]);
      s += 6;
    } while (--i != 0);
    // Ppmd7z_EncodeSymbol adds the coded total back to the See.
    p->seeSumm[see] = (u16)(p->seeSumm[see] + sum + escFreq);
    {
      i64 s2 = m32[(p->minContext >> 2) + 1];
      s -= 6;
      charMask[m8[s]] = 0;
      do {
        i64 sym0 = m8[s2];
        i64 sym1 = m8[s2 + 6];
        s2 += 12;
        charMask[sym0] = 0;
        charMask[sym1] = 0;
      } while (s2 < s);
    }
  }
}
