// zxsfx decoder: port of zcm_predictor.dart: the predictor of each level
// (which models run, how the memory budget is split between them, the
// mixers and the final probability refinement), and the ZPredictor
// interface of zc_zcm.h (level 1 is zc_fast.c). Designs and credits are
// in zcm_predictor.dart and zcm.dart (paq8, lpaq1, paq8px, cmix).
//
// zcmExperiment is always empty in a stream the codec wrote, so the
// models it gates (SparseMatch, SparseBit, LinearPrediction, Chart, Nest,
// Xml) are never built and are not ported.

#include "zc.h"
#include "zc_audio.h"
#include "zc_audio_px.h"
#include "zc_byte_models.h"
#include "zc_fast.h"
#include "zc_image.h"
#include "zc_image_px.h"
#include "zc_maps.h"
#include "zc_match.h"
#include "zc_models.h"
#include "zc_sparse.h"
#include "zc_text.h"
#include "zc_words.h"
#include "zc_x86.h"
#include "zc_zcm.h"

// ---------------------------------------------------------------- spec

typedef struct {
  i64 level;
  const i64 *orders;
  i64 norders;
  int rich;
  i64 matchMinS, matchMinL;
  i64 wordContexts;
  int wordAlways, sparse, sparseLight, indirect, fullIndirect, record;
  i64 exe, selectors, apms;
  int bh;
  i64 ppmdOrder;
  int charGroup, dmc;
  i64 image, audio;
  i64 finalRate, finalRateMin;
  i64 text, textSets;
  i64 similarity;
  int pxMatch, gainGate;
} Spec;

static const i64 kOrders4[] = {2, 3, 4, 6};
static const i64 kOrders8[] = {2, 3, 4, 5, 6, 7, 8, 12};

static Spec spec_of(i64 level) {
  Spec s;
  memset(&s, 0, sizeof s);
  s.level = level;
  s.rich = 1;
  s.matchMinS = 6;
  s.selectors = 1;
  s.apms = 1;
  s.finalRate = 8 << 16;
  s.finalRateMin = 2 << 16;
  s.textSets = 10;
  s.orders = kOrders4;
  s.norders = 4;
  switch (level) {
    case 2:
      s.rich = 0;
      s.selectors = 2;
      s.apms = 2;
      s.finalRate = 16 << 16;
      break;
    case 3:
      s.rich = 0;
      s.wordContexts = 5;
      s.exe = 1;
      s.image = 1;
      s.audio = 1;
      s.selectors = 3;
      s.apms = 2;
      s.finalRate = 16 << 16;
      break;
    case 4:
      s.rich = 0;
      s.matchMinL = 16;
      s.wordContexts = 10;
      s.sparse = 1;
      s.sparseLight = 1;
      s.exe = 2;
      s.image = 1;
      s.audio = 1;
      s.selectors = 3;
      s.apms = 2;
      s.finalRate = 16 << 16;
      break;
    case 5:
      s.rich = 0;
      s.matchMinL = 16;
      s.wordContexts = 16;
      s.sparse = 1;
      s.sparseLight = 1;
      s.exe = 2;
      s.image = 1;
      s.audio = 1;
      s.selectors = 3;
      s.apms = 4;
      s.finalRate = 24 << 16;
      s.finalRateMin = 3 << 16;
      break;
    case 6:
      s.orders = kOrders8;
      s.norders = 8;
      s.matchMinL = 20;
      s.wordContexts = 16;
      s.sparse = 1;
      s.indirect = 1;
      s.record = 1;
      s.exe = 3;
      s.charGroup = 1;
      s.image = 2;
      s.audio = 2;
      s.selectors = 6;
      s.apms = 4;
      break;
    default:
      s.orders = kOrders8;
      s.norders = 8;
      s.matchMinL = level >= 8 ? 24 : 20;
      s.wordContexts = 67;
      s.wordAlways = level >= 8;
      s.sparse = 1;
      s.indirect = 1;
      s.fullIndirect = 1;
      s.record = 1;
      s.exe = 3;
      s.bh = 1;
      s.charGroup = 1;
      s.image = 2;
      s.audio = 3;
      s.selectors = 7;
      s.apms = 5;
      s.dmc = level >= 9;
      s.ppmdOrder = level >= 9 ? 16 : 0;
      s.text = level >= 8 ? 1 : 0;
      s.similarity = level >= 9 ? 2048 : 0;
      s.gainGate = 1;
      s.pxMatch = 1;
      break;
  }
  return s;
}

i64 zcmBufferBytesP(i64 budgetBytes) {
  i64 b = floorPow2(budgetBytes / 8);
  if (b > ((i64)64 << 20)) b = (i64)64 << 20;
  if (b < ((i64)1 << 16)) b = (i64)1 << 16;
  return b;
}

// ---------------------------------------------------------------- SSE

static u8 g_charClass[256];

typedef struct {
  ApmPx a0, a1, a2, a3;
  Apm1 b1, b2, b3;
  ApmPost postA, postB;
  i64 mask, b1Mask;
} SsePx;

static i64 sse_b1Contexts(i64 bits) {
  return bits >= 16 ? 256 * 257 : (i64)1 << bits;
}

static i64 sse_bytesFor(i64 bits) {
  return (2048 * 24 + 3 * ((i64)1 << bits) * 24) * 4 +
         (sse_b1Contexts(bits) + 2 * ((i64)1 << bits)) * 33 * 2 +
         2 * 8 * 4096 * 8;
}

static i64 sse_bitsFor(i64 budgetBytes) {
  i64 b = 16;
  while (b > 8 && sse_bytesFor(b) * 12 > budgetBytes) b--;
  return b;
}

static SsePx *sse_new(i64 bits, i64 a0n) {
  SsePx *x = ZNEW(SsePx, 1);
  apmpx_init(&x->a0, a0n, 24, 1023);
  apmpx_init(&x->a1, (i64)1 << bits, 24, 1023);
  apmpx_init(&x->a2, (i64)1 << bits, 24, 1023);
  apmpx_init(&x->a3, (i64)1 << bits, 24, 1023);
  apm1_init(&x->b1, sse_b1Contexts(bits), 7);
  x->b1Mask = bits >= 16 ? -1 : ((i64)1 << bits) - 1;
  apm1_init(&x->b2, (i64)1 << bits, 6);
  apm1_init(&x->b3, (i64)1 << bits, 6);
  apmpost_init(&x->postA, 8);
  apmpost_init(&x->postB, 8);
  x->mask = ((i64)1 << bits) - 1;
  return x;
}

ZINLINE i64 sse_b1cx(const SsePx *x, i64 cx) {
  return x->b1Mask < 0 ? cx : (hash2(cx, 1) & x->b1Mask);
}
ZINLINE i64 avg4(i64 a, i64 b, i64 c, i64 d) { return (a + b + c + d + 2) >> 2; }
ZINLINE i64 clamp16(i64 p) { return p < 1 ? 1 : (p > 65535 ? 65535 : p); }

static i64 sse_text(SsePx *x, i64 y, i64 pr, i64 c0, i64 bpos, i64 c4, i64 m3,
                    i64 e, i64 len2, i64 no, i64 wo) {
  i64 cls = g_charClass[c4 & 255];
  i64 p0 = apmpx_pp(&x->a0, y, pr, ((c0 << 3) | cls) & 2047);
  i64 p1 = apmpx_pp(&x->a1, y, pr, hash4(bpos, m3 & 3, c4 & 0xFFFF, cls) & x->mask);
  i64 p2 = apmpx_pp(&x->a2, y, pr, hash2(c0, (e << 2) | len2) & x->mask);
  i64 p3 = apmpx_pp(&x->a3, y, pr, hash3(c0, c4 & 0xFFFF, wo) & x->mask);
  i64 pA = avg4(pr << 4, p1, p2, p3);
  i64 p4 = apm1_pp(&x->b1, y, pA >> 4,
                   sse_b1cx(x, e + (((wo >> 2) << 5) | (len2 << 3) | (no >> 1)) * 257));
  i64 p5 = apm1_pp(&x->b2, y, p0 >> 4, hash2(c0, c4 & 0xFFFFFF) & x->mask);
  i64 p6 = apm1_pp(&x->b3, y, p0 >> 4, hash2(c0, c4) & x->mask);
  i64 pB = avg4(p0, p4, p5, p6);
  return clamp16((apmpost_pp(&x->postA, y, pA >> 4, bpos) +
                  apmpost_pp(&x->postB, y, pB >> 4, bpos) + 1) >> 1);
}

static i64 sse_textPx(SsePx *x, i64 y, i64 pr, i64 c0, i64 bpos, i64 c4,
                      i64 m3, i64 e, i64 len2, i64 no, i64 wo, i64 tmask,
                      i64 tfirst, i64 torder) {
  (void)no;
  i64 p0 = apmpx_pp(&x->a0, y, pr, ((c0 << 7) | (tmask & 0x0F) | (m3 << 4)) & 0x7FFF);
  i64 p1 = apmpx_pp(&x->a1, y, pr, hash4(bpos, m3 & 3, c4 & 0xFFFF, tmask >> 4) & x->mask);
  i64 p2 = apmpx_pp(&x->a2, y, pr, hash2(c0, (e << 2) | len2) & x->mask);
  i64 p3 = apmpx_pp(&x->a3, y, pr, hash3(c0, c4 & 0xFFFF, tfirst) & x->mask);
  i64 pA = avg4(pr << 4, p1, p2, p3);
  i64 p4 = apm1_pp(&x->b1, y, pA >> 4,
                   sse_b1cx(x, e + (((wo >> 2) << 5) | (len2 << 3) | (torder >> 1)) * 257));
  i64 p5 = apm1_pp(&x->b2, y, p0 >> 4, hash2(c0, c4 & 0xFFFFFF) & x->mask);
  i64 p6 = apm1_pp(&x->b3, y, p0 >> 4, hash2(c0, c4) & x->mask);
  i64 pB = avg4(p0, p4, p5, p6);
  return clamp16((apmpost_pp(&x->postA, y, pA >> 4, bpos) +
                  apmpost_pp(&x->postB, y, pB >> 4, bpos) + 1) >> 1);
}

static i64 sse_image(SsePx *x, i64 y, i64 pr, i64 c0, i64 bpos, i64 m3,
                     i64 plane, i64 w, i64 n, i64 ww, i64 nn, i64 ctx) {
  i64 pl = plane & 3;
  i64 p0 = apmpx_pp(&x->a0, y, pr, (pl << 5) | (bpos << 2) | (bpos == 0 ? 0 : (m3 & 3)));
  i64 p1 = apmpx_pp(&x->a1, y, pr, hash3(c0, w, ww) & x->mask);
  i64 p2 = apmpx_pp(&x->a2, y, pr, hash3(c0, n, nn) & x->mask);
  i64 p3 = apmpx_pp(&x->a3, y, pr, hash2((c0 << 8) | ctx, pl) & x->mask);
  i64 pA = avg4(pr << 4, p1, p2, p3);
  i64 p4 = apm1_pp(&x->b1, y, p0 >> 4, sse_b1cx(x, ((pl << 3) | bpos) + 257 * (ctx & 0xF8)));
  i64 p5 = apm1_pp(&x->b2, y, p0 >> 4, hash3(c0, (w + n) >> 1, pl) & x->mask);
  i64 pB = (p0 * 2 + p4 * 3 + p5 * 3 + 4) >> 3;
  return clamp16((apmpost_pp(&x->postA, y, pA >> 4, bpos) +
                  apmpost_pp(&x->postB, y, pB >> 4, bpos) + 1) >> 1);
}

static i64 sse_generic(SsePx *x, i64 y, i64 pr, i64 c0, i64 bpos, i64 c4,
                       i64 m3, i64 e, i64 len2, i64 no, i64 wo) {
  i64 p0 = apmpx_pp(&x->a0, y, pr, (len2 << 6) | (bpos << 3) | m3);
  i64 p1 = apmpx_pp(&x->a1, y, pr, ((no << 5) | (len2 << 3) | bpos) & x->mask);
  i64 p2 = apmpx_pp(&x->a2, y, pr, (c0 | ((c4 & 0xFF) << 8)) & x->mask);
  i64 p3 = apmpx_pp(&x->a3, y, pr, hash2(c0, c4 & 0xFFFF) & x->mask);
  i64 pA = avg4(pr << 4, p1, p2, p3);
  i64 p4 = apm1_pp(&x->b1, y, pA >> 4, sse_b1cx(x, e + ((m3 << 5) | (no << 2) | len2) * 257));
  i64 p5 = apm1_pp(&x->b2, y, p0 >> 4,
                   ((m3 << 13) | (len2 << 11) | ((wo >> 2) << 8) | c0) & x->mask);
  i64 p6 = apm1_pp(&x->b3, y, p0 >> 4,
                   (((m3 & 3) << 14) | ((bpos >> 1) << 12) | ((c4 & 0xFF) << 4) |
                    (wo >> 1)) & x->mask);
  i64 pB = avg4(p0, p4, p5, p6);
  return clamp16((apmpost_pp(&x->postA, y, pA >> 4, no) +
                  apmpost_pp(&x->postB, y, pB >> 4, len2) + 1) >> 1);
}

// ---------------------------------------------------------------- predictor

#define MAX_MODELS 32

typedef struct {
  ZModel *m[MAX_MODELS];
  i64 n;
} ModelList;

struct ZPredictor {
  int fast;
  ZcmFast *f;
  Spec spec;
  ZState s;
  // models
  OrderModel *orders;
  ZModel *match; // a ZMatchModel
  ZModel *word;
  PxWordModel *pxWord;
  TextModel *text;
  SimilarityModel *sim;
  SparseModel *sparse;
  IndirectModel *indirect;
  RecordModel *record;
  ZModel *exe;
  CharGroupModel *charGroup;
  DmcModel *dmc;
  PpmdByteModel *ppmd;
  LstmByteModel *lstm;
  ByteMixerModel *byteMixer;
  i64 lstmCells, lstmLayers, lstmHorizon;
  i64 imageBytes, audioBytes, sseBits;
  ImageModel *image;
  ZcmBitImageModel *bitImage;
  AudioModel *audio;
  AudioPxModel *audioPx;
  AudioSse *sseAudio;
  Mixer *mixers[ZT_COUNT];
  ModelList *active[ZT_COUNT];
  ModelList *extra[ZT_COUNT]; // the models with mixer contexts
  Mixer *last;
  Apm *a1, *a2, *a3, *a4;
  SsePx *sseText, *sseGeneric, *sseImage;
  i64 pr, misses;
  // paq8px image models (levels 7 to 9)
  PxImage24Model *pxImg24;
  PxImage8Model *pxImg8;
  Mixer *pxMixers[4];
  ModelList *pxModels24, *pxModels8;
  ZcmImageSse *pxSse24, *pxSse8;
};

static void add(ModelList *l, void *m) {
  if (l->n == MAX_MODELS) zfatal("zcm: too many models");
  l->m[l->n++] = (ZModel *)m;
}

static void remove_model(ModelList *l, void *m) {
  for (i64 i = 0; i < l->n; i++) {
    if (l->m[i] == (ZModel *)m) {
      for (i64 j = i + 1; j < l->n; j++) l->m[j - 1] = l->m[j];
      l->n--;
      return;
    }
  }
}

static i64 match_length(ZPredictor *p) {
  ZMatchModel *mm = (ZMatchModel *)p->match;
  return mm->length(p->match);
}
static i64 match_expected(ZPredictor *p) {
  ZMatchModel *mm = (ZMatchModel *)p->match;
  return mm->expectedByte(p->match);
}

static LstmByteModel *plain_lstm(ZPredictor *p) {
  if (!p->lstm) {
    p->lstm = ZNEW(LstmByteModel, 1);
    lstmbytemodel_init(p->lstm, p->lstmCells, p->lstmLayers, p->lstmHorizon);
  }
  return p->lstm;
}

static ModelList *models_for(ZPredictor *p, i64 type) {
  ModelList *l = ZNEW(ModelList, 1);
  add(l, p->orders);
  add(l, p->match);
  if (type == ZT_AUDIO && p->audioBytes > 0) {
    if (p->spec.audio >= 3) {
      if (!p->audioPx) {
        p->audioPx = ZNEW(AudioPxModel, 1);
        audiopxmodel_init(p->audioPx, 1);
      }
      add(l, p->audioPx);
    } else {
      if (!p->audio) {
        p->audio = ZNEW(AudioModel, 1);
        audiomodel_init(p->audio, p->audioBytes, p->spec.audio >= 2);
      }
      add(l, p->audio);
    }
    if (p->record) add(l, p->record);
    if (p->spec.audio >= 3) remove_model(l, p->orders);
    if (p->lstmCells > 0) add(l, plain_lstm(p));
    return l;
  }
  if (zt_isBitImage((int)type) && p->imageBytes > 0) {
    if (!p->bitImage) {
      p->bitImage = ZNEW(ZcmBitImageModel, 1);
      zcmbitimagemodel_init(p->bitImage, p->imageBytes / 4);
    }
    add(l, p->bitImage);
    return l;
  }
  if (zt_isImage((int)type) && p->imageBytes > 0) {
    if (!p->image) {
      p->image = ZNEW(ImageModel, 1);
      imagemodel_init(p->image, p->imageBytes, p->spec.image >= 2);
    }
    add(l, p->image);
    if (p->lstmCells > 0) add(l, plain_lstm(p));
    return l;
  }
  if (p->word && (type == ZT_TEXT || p->spec.wordAlways)) add(l, p->word);
  if (p->text && (type == ZT_TEXT || (p->spec.text >= 2 && type == ZT_BINARY))) {
    add(l, p->text);
  }
  if (p->sparse) add(l, p->sparse);
  int isText = type == ZT_TEXT;
  if (p->sim && !isText) add(l, p->sim);
  if (p->indirect) add(l, p->indirect);
  if (p->record) add(l, p->record);
  if (p->exe && type == ZT_EXE) add(l, p->exe);
  if (p->charGroup) add(l, p->charGroup);
  if (p->dmc) add(l, p->dmc);
  if (p->ppmd) add(l, p->ppmd);
  if (p->lstmCells > 0) {
    if (p->ppmd) {
      if (!p->byteMixer) {
        p->byteMixer = ZNEW(ByteMixerModel, 1);
        bytemixermodel_init(p->byteMixer, p->ppmd, p->lstmCells, p->lstmLayers,
                            p->lstmHorizon);
      }
      add(l, p->byteMixer);
    } else {
      add(l, plain_lstm(p));
    }
  }
  return l;
}

static i64 selectors_for(ZPredictor *p, i64 type) {
  return type == ZT_AUDIO && p->spec.audio >= 3 ? 1 : p->spec.selectors;
}

static Mixer *mixer_for(ZPredictor *p, i64 type, ModelList *models) {
  i64 n = 1;
  for (i64 i = 0; i < models->n; i++) n += models->m[i]->inputs;
  i64 sizes[64];
  i64 ns = 0;
  sizes[ns++] = 256;
  i64 sel = selectors_for(p, type);
  if (sel >= 2) sizes[ns++] = 64 * 8;
  if (sel >= 3) sizes[ns++] = 256;
  if (sel >= 4) sizes[ns++] = 16 * 4 * 8;
  if (sel >= 5) sizes[ns++] = 256;
  if (sel >= 6) sizes[ns++] = 1024;
  if (sel >= 7) {
    sizes[ns++] = 1024;
    sizes[ns++] = 256;
    sizes[ns++] = 1536;
  }
  ModelList *extra = ZNEW(ModelList, 1);
  for (i64 i = 0; i < models->n; i++) {
    ZModel *m = models->m[i];
    if (m->nsel > 0) {
      for (i64 j = 0; j < m->nsel; j++) {
        if (ns == 64) zfatal("zcm: too many selectors");
        sizes[ns++] = m->selSizes[j];
      }
      add(extra, m);
    }
  }
  p->extra[type] = extra;
  i64 w0 = (65536 * 12) / n;
  if (w0 > 16384) w0 = 16384;
  MixerOpts o = mixer_defaults();
  o.finalContexts = type == ZT_AUDIO ? 16 : 8;
  o.initWeight = w0;
  o.finalRate = p->spec.finalRate;
  o.finalRateMin = p->spec.finalRateMin;
  Mixer *m = ZNEW(Mixer, 1);
  mixer_init(m, n, sizes, ns, o);
  return m;
}

static ZPredictor *full_new(i64 level, i64 budgetBytes, i64 lstmCells,
                            i64 lstmLayers, i64 lstmHorizon) {
  ZPredictor *p = ZNEW(ZPredictor, 1);
  Spec spec = spec_of(level);
  p->spec = spec;
  i64 bufBytes = zcmBufferBytesP(budgetBytes);
  i64 matchEntries = floorPow2(budgetBytes / 64);
  i64 sseBits = spec.apms >= 5 ? sse_bitsFor(budgetBytes) : 0;
  i64 sseBytes = spec.apms >= 5 ? sse_bytesFor(sseBits) * 2 : 0;
  i64 mediaBytes = budgetBytes / 4;
  i64 imageBytes = spec.image > 0 ? mediaBytes : 0;
  i64 audioBytes = spec.audio > 0 ? mediaBytes : 0;
  i64 matchBytes =
      spec.pxMatch
          ? pxmatchmodel_tableBytes(matchEntries * 8,
                                    zcmHashBitsFor(matchEntries * 4, 42)) +
                floorPow2(matchEntries * 4) + 64
          : floorPow2(matchEntries) * 8;
  i64 rest = budgetBytes - bufBytes - matchBytes - ((i64)1 << 20) - sseBytes;
  if (rest < (256 << 10)) rest = 256 << 10;
  i64 ppmdBytes = 0;
  if (spec.ppmdOrder > 0 && budgetBytes >= (16 << 20)) {
    ppmdBytes = floorPow2(budgetBytes / 4);
    if (ppmdBytes > ((i64)1 << 31)) ppmdBytes = (i64)1 << 31;
  }
  i64 wo = spec.norders * 2;
  i64 ww = spec.wordContexts == 0 ? 0 : (spec.wordContexts > 16 ? 24 : 12);
  i64 ws = spec.sparse ? 4 : 0;
  i64 wi = spec.indirect ? 3 : 0;
  i64 wr = spec.record ? 3 : 0;
  i64 we = spec.exe > 0 ? 4 : 0;
  i64 wg = spec.charGroup ? 3 : 0;
  int dmc = spec.dmc && budgetBytes >= (16 << 20);
  i64 wd = dmc ? 2 : 0;
  i64 wt = spec.text > 0 ? 10 : 0;
  i64 wsi = spec.similarity > 0 ? 3 : 0;
  i64 total = wo + ww + ws + wi + wr + we + wg + wd + wt + wsi;
#define SHARE(w) ((w) == 0 ? 0 : floorPow2((rest * (w)) / total))
  i64 bo = SHARE(wo), bw = SHARE(ww), bs = SHARE(ws), bi = SHARE(wi);
  i64 br = SHARE(wr), be = SHARE(we), bg = SHARE(wg);
  i64 bd = wd == 0 ? 0 : (rest * wd) / total;
  i64 bt = SHARE(wt), bsi = SHARE(wsi);
#undef SHARE

  // The fields in the order of the Dart initializer list (the order of the
  // allocations does not change the output, the values do).
  zstate_init(&p->s, bufBytes);
  if (ppmdBytes > 0) {
    p->ppmd = ZNEW(PpmdByteModel, 1);
    ppmdbytemodel_init(p->ppmd, spec.ppmdOrder, ppmdBytes);
    if (spec.gainGate) {
      p->ppmd->b.gate = ZNEW(GainGate, 1);
      gaingate_init(p->ppmd->b.gate);
    }
  }
  p->lstmCells = lstmCells;
  p->lstmLayers = lstmLayers;
  p->lstmHorizon = lstmHorizon;
  p->orders = ZNEW(OrderModel, 1);
  ordermodel_init(p->orders, spec.orders, spec.norders, bo, spec.rich, spec.bh,
                  spec.bh);
  if (spec.pxMatch) {
    static const i64 l468[] = {4, 6, 8}, l358[] = {3, 5, 8};
    PxMatchModel *m = ZNEW(PxMatchModel, 1);
    pxmatchmodel_init(m, matchEntries * 8, matchEntries * 4, l468, l468, l358,
                      zcmHashBitsFor(matchEntries * 4, 42));
    p->match = (ZModel *)m;
  } else {
    MatchModel *m = ZNEW(MatchModel, 1);
    matchmodel_init(m, matchEntries, bufBytes, spec.matchMinS,
                    spec.matchMinL > 0 ? spec.matchMinL : (i64)1 << 30);
    p->match = (ZModel *)m;
  }
  if (spec.wordContexts != 0) {
    if (spec.wordContexts > 16) {
      p->pxWord = ZNEW(PxWordModel, 1);
      pxwordmodel_init(p->pxWord, bw);
      p->word = (ZModel *)p->pxWord;
    } else {
      WordModel *w = ZNEW(WordModel, 1);
      wordmodel_init(w, bw, spec.wordContexts);
      p->word = (ZModel *)w;
    }
  }
  if (spec.sparse) {
    p->sparse = ZNEW(SparseModel, 1);
    sparsemodel_init(p->sparse, bs, spec.sparseLight);
  }
  if (spec.indirect) {
    p->indirect = ZNEW(IndirectModel, 1);
    indirectmodel_init(p->indirect, bi, spec.fullIndirect);
  }
  if (spec.charGroup) {
    p->charGroup = ZNEW(CharGroupModel, 1);
    chargroupmodel_init(p->charGroup, bg);
  }
  if (bd > 0) {
    p->dmc = ZNEW(DmcModel, 1);
    dmcmodel_init(p->dmc, bd, 256);
    if (spec.gainGate) {
      p->dmc->gate = ZNEW(GainGate, 1);
      gaingate_init(p->dmc->gate);
    }
  }
  if (bsi > 0) {
    p->sim = ZNEW(SimilarityModel, 1);
    similaritymodel_init(p->sim, bsi, spec.similarity);
  }
  if (bt > 0) {
    p->text = ZNEW(TextModel, 1);
    textmodel_init(p->text, bt, spec.textSets, 0, 0);
  }
  if (spec.record) {
    p->record = ZNEW(RecordModel, 1);
    recordmodel_init(p->record, br);
  }
  if (spec.exe != 0) {
    if (spec.exe == 1) {
      ExeModel *x = ZNEW(ExeModel, 1);
      exemodel_init(x, be, 5);
      p->exe = (ZModel *)x;
    } else {
      X86Model *x = ZNEW(X86Model, 1);
      x86model_init(x, be, spec.exe >= 3);
      p->exe = (ZModel *)x;
    }
  }
  if (spec.apms >= 1 && spec.apms <= 4) {
    p->a1 = ZNEW(Apm, 1);
    apm_init(p->a1, 256 * 8, 7);
  }
  if (spec.apms >= 2 && spec.apms <= 4) {
    p->a2 = ZNEW(Apm, 1);
    apm_init(p->a2, 65536, 7);
  }
  if (spec.apms >= 3 && spec.apms <= 4) {
    p->a3 = ZNEW(Apm, 1);
    apm_init(p->a3, 65536, 7);
  }
  if (spec.apms == 4) {
    p->a4 = ZNEW(Apm, 1);
    apm_init(p->a4, 65536, 7);
  }
  p->sseBits = sseBits;
  p->imageBytes = imageBytes;
  p->audioBytes = audioBytes;
  p->pr = 2048;
  return p;
}

static int is_px_image(ZPredictor *p, i64 type) {
  return p->spec.level >= 7 && p->imageBytes > 0 &&
         (type == ZT_IMAGE24 || type == ZT_IMAGE32 || type == ZT_IMAGE8);
}

static i64 miss_bits(ZPredictor *p, i64 y) {
  i64 miss = (p->pr >= 2048) != (y == 1) ? 1 : 0;
  p->misses = ((p->misses << 1) | miss) & 0xFFFF;
  return (p->misses & 1) | ((p->misses & 0xFE) != 0 ? 2 : 0) |
         ((p->misses & 0xFF00) != 0 ? 4 : 0);
}

static i64 px_image_p(ZPredictor *p, i64 type) {
  ZState *st = &p->s;
  i64 y = st->y;
  int gray = type == ZT_IMAGE8;
  PxImageModel *img;
  ModelList *models;
  if (gray) {
    if (!p->pxImg8) {
      p->pxImg8 = ZNEW(PxImage8Model, 1);
      pximage8model_init(p->pxImg8, p->imageBytes);
    }
    img = &p->pxImg8->px;
    if (!p->pxModels8) {
      p->pxModels8 = ZNEW(ModelList, 1);
      add(p->pxModels8, p->orders);
      add(p->pxModels8, p->match);
      add(p->pxModels8, img);
    }
    models = p->pxModels8;
  } else {
    if (!p->pxImg24) {
      p->pxImg24 = ZNEW(PxImage24Model, 1);
      pximage24model_init(p->pxImg24, p->imageBytes);
    }
    img = &p->pxImg24->px;
    if (!p->pxModels24) {
      p->pxModels24 = ZNEW(ModelList, 1);
      add(p->pxModels24, p->orders);
      add(p->pxModels24, p->match);
      add(p->pxModels24, img);
    }
    models = p->pxModels24;
  }
  pximage_prepare(img, st);
  i64 plane = pximage_plane(img);
  i64 mi = gray ? 3 : (plane == 0 ? 0 : (plane == 1 ? 1 : 2));
  Mixer *m = p->pxMixers[mi];
  if (!m) {
    i64 n = 1;
    for (i64 i = 0; i < models->n; i++) n += models->m[i]->inputs;
    i64 w0 = (65536 * 12) / n;
    if (w0 > 16384) w0 = 16384;
    i64 sizes[64];
    i64 ns = 0;
    sizes[ns++] = 64;
    sizes[ns++] = 64;
    for (i64 j = 0; j < img->base.nsel; j++) sizes[ns++] = img->base.selSizes[j];
    MixerOpts o = mixer_defaults();
    o.finalContexts = 8;
    o.initWeight = w0;
    o.finalRate = p->spec.finalRate;
    o.finalRateMin = p->spec.finalRateMin;
    m = ZNEW(Mixer, 1);
    mixer_init(m, n, sizes, ns, o);
    p->pxMixers[mi] = m;
  }
  p->last = m;
  for (i64 i = 0; i < models->n; i++) models->m[i]->mix(models->m[i], st, m);
  mixer_add(m, 256);
  i64 c0 = st->c0;
  i64 bpos = st->bpos;
  i64 m3 = miss_bits(p, y);
  i64 hits = ordermodel_hits(p->orders);
  i64 ml = match_length(p);
  i64 mq = ml == 0 ? 0 : (ml < 16 ? 1 + (ml >> 2) : (ml < 32 ? 5 : (ml < 64 ? 6 : 7)));
  mixer_set(m, ((hits > 7 ? 7 : hits) << 3) | bpos);
  mixer_set(m, (mq << 3) | bpos);
  img->base.setCtx(&img->base, st, m);
  mixer_setFinal(m, bpos);
  i64 pr = mixer_p(m);
  i64 pf = pr << 4;
  if (p->spec.apms >= 5) {
    i64 e = match_expected(p);
    ZcmImageSse *sse;
    if (gray) {
      if (!p->pxSse8) {
        p->pxSse8 = ZNEW(ZcmImageSse, 1);
        zcmimagesse_init(p->pxSse8, p->sseBits, 1);
      }
      sse = p->pxSse8;
    } else {
      if (!p->pxSse24) {
        p->pxSse24 = ZNEW(ZcmImageSse, 1);
        zcmimagesse_init(p->pxSse24, p->sseBits, 0);
      }
      sse = p->pxSse24;
    }
    pf = zcmimagesse_p(sse, y, pr, c0, bpos, m3, img, e < 0 ? 0 : e);
  }
  pf = clamp16(pf);
  img->finalP = pf;
  p->pr = pf >> 4;
  return pf;
}

static i64 full_p(ZPredictor *p) {
  ZState *st = &p->s;
  i64 y = st->y;
  i64 type = st->blockType;
  if (p->last) mixer_update(p->last, y);
  if (is_px_image(p, type)) return px_image_p(p, type);
  ModelList *models = p->active[type];
  if (!models) {
    models = p->active[type] = models_for(p, type);
    p->mixers[type] = mixer_for(p, type, models);
  }
  Mixer *m = p->mixers[type];
  p->last = m;
  for (i64 i = 0; i < models->n; i++) models->m[i]->mix(models->m[i], st, m);
  mixer_add(m, 256);
  i64 c0 = st->c0;
  i64 bpos = st->bpos;
  i64 c4 = st->c4;
  i64 m3 = miss_bits(p, y);
  mixer_set(m, c0);
  i64 ml = match_length(p);
  i64 mq = ml == 0 ? 0 : (ml < 16 ? 1 + (ml >> 2) : (ml < 32 ? 5 : (ml < 64 ? 6 : 7)));
  i64 sel = selectors_for(p, type);
  i64 hits = ordermodel_hits(p->orders);
  if (sel >= 2) mixer_set(m, (mq << 3) | bpos);
  if (sel >= 3) mixer_set(m, c4 & 255);
  if (sel >= 4) {
    i64 h = hits > 15 ? 15 : hits;
    mixer_set(m, (((h << 2) | (m3 & 3)) << 3) | bpos);
  }
  if (sel >= 5) mixer_set(m, (c4 >> 8) & 255);
  if (sel >= 6) {
    i64 low = c0 & (((i64)1 << bpos) - 1);
    i64 flag = (low == 0 || c0 == ((i64)2 << bpos) - 1) ? 1 : 0;
    mixer_set(m, (c4 & 255) | (bpos > 5 ? 256 : 0) | (flag << 9));
  }
  if (sel >= 7) {
    i64 c1 = c4 & 255, c2 = (c4 >> 8) & 255, c3 = (c4 >> 16) & 255;
    i64 o = hits > 7 ? 7 : hits;
    i64 bt = type == ZT_BINARY ? 0 : (type == ZT_TEXT ? 1 : (type == ZT_EXE ? 2 : 3));
    mixer_set(m, o | ((c1 >> 6) << 3) | (bpos == 0 ? 32 : 0) | (c1 == c2 ? 64 : 0) |
                     (bt << 7));
    mixer_set(m, c3);
    i64 c;
    if (bpos != 0) {
      c = (c0 << (8 - bpos)) & 255;
      if (bpos == 1) c |= c3 >> 1;
      c = ((bpos < 5 ? bpos : 5) << 8) | (c1 >> 5) | ((c2 >> 5) << 3) | (c & 192);
    } else {
      c = (c3 >> 7) | ((c4 >> 31) << 1) | ((c2 >> 6) << 2) | (c1 & 240);
    }
    mixer_set(m, c);
  }
  ModelList *extra = p->extra[type];
  for (i64 i = 0; i < extra->n; i++) extra->m[i]->setCtx(extra->m[i], st, m);
  AudioPxModel *ap = p->audioPx;
  int isAudioPx = ap != 0 && type == ZT_AUDIO;
  mixer_setFinal(m, isAudioPx ? audiopxmodel_finalContext(ap) : bpos);
  i64 pr = mixer_p(m);
  if (isAudioPx) {
    i64 pf = pr << 4;
    if (p->spec.apms >= 5) {
      if (!p->sseAudio) {
        p->sseAudio = ZNEW(AudioSse, 1);
        audiosse_init(p->sseAudio);
      }
      pf = audiosse_p(p->sseAudio, y, pr, bpos, m3, audiopxmodel_sseContext(ap),
                      audiopxmodel_apmContext(ap));
    }
    audiopxmodel_setLastP(ap, pf);
    p->pr = pf >> 4;
    return pf;
  }
  ImageModel *img = p->image;
  if (p->spec.apms >= 5 && img && zt_isImage((int)type)) {
    if (!p->sseImage) p->sseImage = sse_new(p->sseBits, 2048);
    i64 pf = sse_image(p->sseImage, y, pr, c0, bpos, m3, imagemodel_plane(img),
                       imagemodel_pxW(img), imagemodel_pxN(img),
                       imagemodel_pxWW(img), imagemodel_pxNN(img),
                       imagemodel_shapeCtx(img));
    p->pr = pf >> 4;
    return pf;
  }
  if (p->spec.apms >= 5) {
    int isText = type == ZT_TEXT;
    SsePx *sse;
    if (isText) {
      if (!p->sseText) p->sseText = sse_new(p->sseBits, p->text ? 32768 : 2048);
      sse = p->sseText;
    } else {
      if (!p->sseGeneric) p->sseGeneric = sse_new(p->sseBits, 2048);
      sse = p->sseGeneric;
    }
    i64 e = match_expected(p);
    i64 no = hits > 7 ? 7 : hits;
    i64 wo = p->pxWord ? pxwordmodel_order(p->pxWord) : 0;
    i64 len2 = ml == 0 ? 0 : (ml < 16 ? 1 : (ml < 32 ? 2 : 3));
    TextModel *tm = p->text;
    i64 pf;
    if (isText) {
      if (tm) {
        pf = sse_textPx(sse, y, pr, c0, bpos, c4, m3, e < 0 ? 0 : e, len2, no, wo,
                        textmodel_mask(tm), textmodel_firstLetter(tm),
                        textmodel_order(tm));
      } else {
        pf = sse_text(sse, y, pr, c0, bpos, c4, m3, e < 0 ? 0 : e, len2, no, wo);
      }
    } else {
      pf = sse_generic(sse, y, pr, c0, bpos, c4, m3, e < 0 ? 0 : e, len2, no, wo);
    }
    p->pr = pf >> 4;
    return pf;
  }
  i64 pf = pr << 4;
  if (p->a1) {
    i64 p1 = apm_pp16(p->a1, y, pr, c0 | (m3 << 8));
    if (!p->a2) {
      pf = (pf * 3 + p1 + 2) >> 2;
    } else {
      i64 p2 = apm_pp16(p->a2, y, pr, hash2(c4 & 0xFFFF, c0) & 0xFFFF);
      if (!p->a3) {
        pf = (pf * 2 + p1 + p2 + 2) >> 2;
      } else {
        i64 p3 = apm_pp16(p->a3, y, pr, hash2(c4 & 0xFFFFFF, c0 + 256) & 0xFFFF);
        i64 pa;
        if (!p->a4) {
          pa = (pf + p2 + p3 * 2 + 2) >> 2;
        } else {
          i64 e = match_expected(p);
          i64 p4 = apm_pp16(p->a4, y, pr, e < 0 ? c0 : (hash3(e, mq, c0) & 0xFFFF));
          pa = (pf + p2 + p3 + p4 + 2) >> 2;
        }
        pf = (pa * 3 + p1 + 2) >> 2;
      }
    }
  }
  pf = clamp16(pf);
  p->pr = pf >> 4;
  return pf;
}

// ---------------------------------------------------------------- interface

ZPredictor *zpredictor_new(i64 level, i64 budgetBytes, i64 lstmCells,
                           i64 lstmLayers, i64 lstmHorizon) {
  static int ready;
  if (!ready) {
    zc_tables_init();
    zc_maps_init();
    for (int c = 0; c < 256; c++) {
      int k;
      if (c >= 0x61 && c <= 0x7A) k = 0;
      else if (c >= 0x41 && c <= 0x5A) k = 1;
      else if (c >= 0x30 && c <= 0x39) k = 2;
      else if (c == 0x20) k = 3;
      else if (c == 0x0A || c == 0x0D) k = 4;
      else if (c >= 0x80) k = 7;
      else if (c < 0x20) k = 6;
      else k = 5;
      g_charClass[c] = (u8)k;
    }
    ready = 1;
  }
  if (level == 1) {
    ZPredictor *p = ZNEW(ZPredictor, 1);
    p->fast = 1;
    p->f = ZNEW(ZcmFast, 1);
    zfast_init(p->f, budgetBytes);
    return p;
  }
  return full_new(level, budgetBytes, lstmCells, lstmLayers, lstmHorizon);
}

i64 zpredictor_p(ZPredictor *p) { return p->fast ? zfast_p(p->f) : full_p(p); }

void zpredictor_update(ZPredictor *p, i64 bit) {
  if (p->fast) {
    zfast_update(p->f, bit);
  } else {
    zstate_update(&p->s, bit);
  }
}

void zpredictor_setSegment(ZPredictor *p, i64 type, i64 info) {
  if (p->fast) {
    zfast_setSegment(p->f, type, info);
    return;
  }
  p->s.blockType = type;
  p->s.blockInfo = info;
  p->s.blockPos = 0;
}
