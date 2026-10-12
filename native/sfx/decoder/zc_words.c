// zxsfx decoder: port of PxWordModel of zcm_words.dart.
//
// A port of paq8px's WordModel and WordModelInfo (Zoltan Gotthardt and
// the paq8px authors, after the word models of paq8 by Matt Mahoney):
// words, numbers and the gaps between them as tokens, expressions of
// words separated by single spaces, the recent words in many combinations,
// word morphology, character classes, the token before the current one
// (an indirect context), and the line model. Hashes are zcm's 32-bit ones.

#include "zc_words.h"

#define SPACE 0x20
#define NEWLINE 0x0A
#define QUOTE 0x22
#define APOSTROPHE 0x27

#define MAX_WORD_LEN 45
#define MAX_LINE_MATCH 16
#define MAX_LAST_UPPER 63
#define MAX_LAST_LETTER 16
#define WPOS_BITS 16

// C isalpha, ispunct and isspace in the C locale.
static int isAlpha(i64 c) {
  return (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);
}
static int isPunct(i64 c) {
  return (c >= 0x21 && c <= 0x2F) || (c >= 0x3A && c <= 0x40) ||
         (c >= 0x5B && c <= 0x60) || (c >= 0x7B && c <= 0x7E);
}
static int isSpace(i64 c) { return c == 0x20 || (c >= 0x09 && c <= 0x0D); }

ZINLINE i64 combine(i64 seed, i64 x) { return hash2(seed + 0x3C6EF372, x); }

// _LargeIndirect: token histories by context hash (16 bit values, a 16 bit
// checksum).
static void li_set(PxWordModel *m, i64 h, i64 c) {
  i64 i = h & m->iCtxMask;
  i64 chk = (h >> 16) & 0xFFFF;
  i64 e = m->iCtx[i];
  i64 v = (e >> 16) == chk ? (e & 0xFFFF) : 0;
  m->iCtx[i] = (u32)((chk << 16) | (((v << 8) | c) & 0xFFFF));
}
static i64 li_get(PxWordModel *m, i64 h) {
  i64 e = m->iCtx[h & m->iCtxMask];
  return (e >> 16) == ((h >> 16) & 0xFFFF) ? (e & 0xFFFF) : 0;
}

static void shiftWords(PxWordModel *m) {
  m->word4 = m->word3;
  m->word3 = m->word2;
  m->word2 = m->word1;
  m->word1 = m->word0;
  m->wordLen1 = m->wordLen0;
}

static void killWords(PxWordModel *m) {
  m->word4 = m->word3 = m->word2 = m->word1 = 0;
  m->gapToken1 = 0;
}

// WordModelInfo::processChar
static void processChar(PxWordModel *m, ZState *s, int isText,
                        int isExtendedChar) {
  m->ppC = m->pC;
  m->pC = m->c;
  m->isLetterPpC = m->isLetterPc;
  m->isLetterPc = m->isLetter;
  i64 c1 = s->c4 & 255;
  m->c4 = ((m->c4 << 8) | c1) & 0xFFFFFFFF;
  m->c = c1;
  if (m->c >= 0x41 && m->c <= 0x5A) {
    m->c += 0x20;
    m->lastUpper = 0;
  }
  i64 c = m->c;
  i64 pC = m->pC;
  m->isLetter = (c >= 0x61 && c <= 0x7A) || isExtendedChar;
  int isNumber =
      (c >= 0x30 && c <= 0x39) || (pC >= 0x30 && pC <= 0x39 && c == 0x2E);
  m->isNewlinePc = m->isNewline;
  m->isNewline = isText ? (c == NEWLINE || c == 0) : c == 0;
  m->lastUpper =
      m->lastUpper + 1 < MAX_LAST_UPPER ? m->lastUpper + 1 : MAX_LAST_UPPER;
  m->lastLetter = m->lastLetter + 1 < MAX_LAST_LETTER ? m->lastLetter + 1
                                                      : MAX_LAST_LETTER;
  m->mask2 = (m->mask2 << 8) & 0xFFFFFFFF;
  if (isText) li_set(m, m->currentToken, c);

  if (m->isLetter || isNumber) {
    if (m->wordLen0 == 0) {
      // The beginning of a new word.
      if (pC == NEWLINE && m->lastLetter == 3 && m->ppC == 0x2B) {
        m->word0 = m->word1;
        m->word1 = m->word2;
        m->word2 = m->word3;
        m->word3 = m->word4 = 0;
        m->wordLen0 = m->wordLen1;
      } else {
        m->wordGap = m->lastLetter;
        m->gapToken1 = m->gapToken0;
        if (pC == QUOTE || (pC == APOSTROPHE && !m->isLetterPpC)) {
          m->opened = pC;
        }
      }
      m->gapToken0 = 0;
      m->mask2 = 0;
    }
    m->lastLetter = 0;
    m->word0 = combine(m->word0, c);
    m->currentToken = m->word0;
    m->w = m->word0 & (((i64)1 << WPOS_BITS) - 1);
    m->chk = (m->word0 >> 16) & 0xFFFF;
    m->text0 = ((m->text0 << 8) | c) & 0xFFFFFFFFFF;
    m->wordLen0 = m->wordLen0 + 1 < MAX_WORD_LEN ? m->wordLen0 + 1
                                                 : MAX_WORD_LEN;
    if (m->isLetter) {
      if (c == 0x65) {
        m->mask2 |= c;
      } else if (c == 0x61 || c == 0x69 || c == 0x6F || c == 0x75) {
        m->mask2 |= 0x61;
      } else if (c >= 0x62 && c <= 0x7A) {
        if (c == 0x79) {
          m->mask2 |= 0x79;
        } else if (pC == 0x74 && c == 0x68) {
          m->mask2 = ((m->mask2 >> 8) & 0x00FFFF00) | 0x74;
        } else {
          m->mask2 |= 0x62;
        }
      } else {
        m->mask2 |= 128;
      }
    } else if (c == 0x2E) {
      m->mask2 |= 0x2E;
    } else {
      m->mask2 |= c == 0x30 ? 0x30 : 0x31;
    }
  } else {
    m->gapToken0 = combine(m->gapToken0, m->isNewline ? SPACE : c1);
    m->currentToken = m->gapToken0;
    if (m->isNewline && pC == 0x2B && m->isLetterPpC) {
    } else if (c == 0x3F || pC == 0x21 || pC == 0x2E) {
      killWords(m);
    } else if (c == pC) {
    } else if ((c == SPACE || m->isNewline) &&
               (pC == SPACE || m->isNewlinePc)) {
    } else {
      shiftWords(m);
    }
    if (m->wordLen0 != 0) {
      m->wordPositions[m->w] = (u32)s->pos;
      m->checksums[m->w] = (u16)m->chk;
      m->w = 0;
      m->chk = 0;
      if (c == 0x3A || c == 0x3D) m->keyword0 = m->word0;
      if (m->firstWord == 0) m->firstWord = m->word0;
      m->word0 = 0;
      m->wordLen0 = 0;
      m->mask2 = 0;
    }
    if (c1 == 0x2E || c1 == 0x21 || c1 == 0x3F) {
      m->mask2 |= 0x21;
    } else if (c1 == 0x2C || c1 == 0x3B || c1 == 0x3A) {
      m->mask2 |= 0x2C;
    } else if (c1 == 0x28 || c1 == 0x7B || c1 == 0x5B || c1 == 0x3C) {
      m->mask2 |= 0x28;
      m->opened = c1;
    } else if (c1 == 0x29 || c1 == 0x7D || c1 == 0x5D || c1 == 0x3E) {
      m->mask2 |= 0x29;
      m->opened = 0;
    } else if (c1 == QUOTE || c1 == APOSTROPHE) {
      m->mask2 |= c1;
      m->opened = 0;
    } else {
      m->mask2 |= c1;
    }
  }

  i64 g = c1;
  if (g >= 128) {
    if ((g & 0xF8) == 0xF0) {
      g = 1;
    } else if ((g & 0xF0) == 0xE0) {
      g = 2;
    } else if ((g & 0xE0) == 0xC0) {
      g = 3;
    } else if ((g & 0xC0) == 0x80) {
      g = 4;
    } else if (g == 0xFF) {
      g = 5;
    } else {
      g = c1 & 0xF0;
    }
  } else if (g >= 0x30 && g <= 0x39) {
    g = 0x30;
  } else if (g >= 0x61 && g <= 0x7A) {
    g = 0x61;
  } else if (g >= 0x41 && g <= 0x5A) {
    g = 0x41;
  } else if (g < 32 && !m->isNewline) {
    g = 6;
  }
  m->groups = shl(m->groups, 8) | g;

  // Expressions (pure words separated by single spaces).
  if (m->isLetter) {
    m->expr0Chars = ((m->expr0Chars << 8) | c) & 0xFFFFFFFF;
    m->expr0 = combine(m->expr0, c);
    m->exprLen0 = m->exprLen0 + 1 < MAX_WORD_LEN ? m->exprLen0 + 1
                                                 : MAX_WORD_LEN;
  } else {
    m->expr0Chars = 0;
    m->exprLen0 = 0;
    if ((c == SPACE || m->isNewline) &&
        (m->isLetterPc || pC == APOSTROPHE || pC == QUOTE)) {
      m->expr4 = m->expr3;
      m->expr3 = m->expr2;
      m->expr2 = m->expr1;
      m->expr1 = m->expr0;
      m->expr0 = 0;
    } else if (c == APOSTROPHE || c == QUOTE ||
               (m->isNewline && pC == SPACE) ||
               (c == SPACE && m->isNewlinePc)) {
      // ignore
    } else {
      m->expr4 = m->expr3 = m->expr2 = m->expr1 = m->expr0 = 0;
    }
  }
}

// WordModelInfo::lineModelPredict
static void lineModel(PxWordModel *m, ZState *s, int isText, i64 k) {
  ContextMap *cm = &m->cm;
  i64 i = 1024 * (1 + (((isText ? 1 : 0) << 1) | 1));
  i64 pos = s->pos;
  if (m->isNewline) {
    m->nl4 = m->nl3;
    m->nl3 = m->nl2;
    m->nl2 = m->nl1;
    m->nl1 = pos;
    m->firstChar = -1;
    m->firstWord = 0;
    m->line1 = m->line0;
    m->line0 = 0;
  }
  i64 c1 = s->c4 & 255;
  m->line0 = combine(m->line0, c1);
  contextmap_set(cm, k++, hash2(++i, m->line0));
  i64 col = pos - m->nl1;
  if (col == 1) m->firstChar = m->groups & 0xFF;
  const u8 *buf = s->buf;
  i64 bm = s->bufMask;
  i64 cAbove = buf[(m->nl2 + col) & bm];
  i64 pCAbove = buf[(m->nl2 + col - 1) & bm];
  int isNewLineStart = col == 0 && m->nl2 > 0;
  int isPrevCharMatchAbove = c1 == pCAbove && col != 0 && m->nl2 != 0;
  i64 aboveCtx = (cAbove << 1) | (isPrevCharMatchAbove ? 1 : 0);
  if (isNewLineStart) {
    m->lineMatch = 0;
  } else if (m->lineMatch >= 0 && isPrevCharMatchAbove) {
    m->lineMatch = m->lineMatch + 1 < MAX_LINE_MATCH ? m->lineMatch + 1
                                                     : MAX_LINE_MATCH;
  } else {
    m->lineMatch = -1;
  }
  if (m->lineMatch >= 0) {
    contextmap_set(cm, k++, hash3(++i, cAbove, m->lineMatch));
  } else {
    contextmap_skip(cm, k++);
    i++;
  }
  i64 lineLength = m->nl1 - m->nl2;
  if (col < lineLength) {
    contextmap_set(cm, k++, hash2(++i, (aboveCtx << 8) | c1));
    contextmap_set(cm, k++, hash3(++i, (aboveCtx << 8) | c1, col));
  } else {
    contextmap_skip(cm, k++);
    contextmap_skip(cm, k++);
    i += 2;
  }
  contextmap_set(cm, k++,
                 hash4(++i, lineLength, col, (aboveCtx << 8) | (m->groups & 0xFF)));
  contextmap_set(cm, k++, hash4(++i, lineLength, col, (aboveCtx << 8) | c1));
  i64 cAbove2 = buf[(m->nl3 + col) & bm];
  i64 cAbove3 = buf[(m->nl4 + col) & bm];
  i64 lineLength2 = m->nl2 - m->nl3;
  i64 lineLength3 = m->nl3 - m->nl4;
  i64 gBefore = m->groups & 0xFFFF;
  if (cAbove == cAbove2 && lineLength == lineLength2) {
    contextmap_set(cm, k++, hash3(++i, gBefore, cAbove));
  } else {
    contextmap_skip(cm, k++);
    i++;
  }
  if (col < lineLength && col < lineLength2 && col < lineLength3) {
    contextmap_set(cm, k++, hash4(++i, gBefore, cAbove, (cAbove2 << 8) | cAbove3));
  } else {
    contextmap_skip(cm, k++);
    i++;
  }
  if (lineLength > 1) {
    i64 cx = isText ? (m->groups & 0xFF) : c1;
    contextmap_set(cm, k++, hash3(++i, m->line1, (col << 8) | cx));
    contextmap_set(cm, k++, hash3(++i, m->line1, m->line0));
  } else {
    contextmap_skip(cm, k++);
    contextmap_skip(cm, k++);
    i += 2;
  }
  contextmap_set(cm, k++, hash2(++i, (col << 1) | (c1 == SPACE ? 1 : 0)));
  contextmap_set(cm, k++, hash2(++i, (col << 8) | c1));
  contextmap_set(cm, k++, hash3(++i, col, m->mask & 0x1FF));
  contextmap_set(cm, k++, hash3(++i, col, lineLength));
  contextmap_set(cm, k++,
                 hash3(++i, (col << 8) | (m->firstChar & 0xFFFF),
                       ((i64)(m->lastUpper < col ? 1 : 0) << 8) |
                           (m->groups & 0xFF)));
  contextmap_set(cm, k++, hash2(++i, m->nl1));
  contextmap_set(cm, k++, hash3(++i, m->nl1, m->c));
  contextmap_set(cm, k++, hash2(++i, m->firstChar & 0xFFFF));
  contextmap_set(cm, k++, hash3(++i, m->firstChar & 0xFFFF, m->c));
  contextmap_set(cm, k++, hash2(++i, m->firstWord));
  contextmap_set(cm, k, hash3(++i, m->firstWord, m->c));
}

// WordModelInfo::predict
static void predict(PxWordModel *m, ZState *s, int isText) {
  ContextMap *cm = &m->cm;
  i64 pos = s->pos;
  i64 lastPos = m->checksums[m->w] != m->chk ? 0 : (i64)m->wordPositions[m->w];
  i64 dist = 0;
  if (lastPos != 0) {
    dist = zcmLlog(pos - lastPos + 120) >> 4;
    if (dist > 20) dist = 20;
  }
  int word0MayEndNow = lastPos != 0;
  i64 b1 = (m->c4 >> 8) & 0xFF, b0 = m->c4 & 0xFF;
  int mayBeCaps = b1 >= 0x41 && b1 <= 0x5A && b0 >= 0x41 && b0 <= 0x5A;
  i64 k = 0;
  i64 i = 0;
  contextmap_set(cm, k++, hash3(++i, m->text0 & 0xFFFFFFFF, m->text0 >> 32));
  if (isText) {
    contextmap_set(cm, k++, hash4(++i, m->expr0, m->expr1,
                                  hash3(m->expr2, m->expr3, m->expr4)));
    contextmap_set(cm, k++, hash4(++i, m->expr0, m->expr1, m->expr2));
  } else {
    contextmap_skip(cm, k++);
    contextmap_skip(cm, k++);
    i += 2;
  }
  contextmap_set(cm, k++, hash3(++i, m->gapToken0, m->keyword0));
  contextmap_set(cm, k++, hash4(++i, m->word0, m->c, m->keyword0));
  contextmap_set(cm, k++, hash3(++i, m->word0, dist));
  contextmap_set(cm, k++, hash4(++i, m->word1, m->gapToken0, dist));
  contextmap_set(cm, k++, hash3(++i, pos >> 10, m->word0));
  i64 wmeMbc = (word0MayEndNow ? 2 : 0) | (mayBeCaps ? 1 : 0);
  i64 wl = m->wordLen0 < 6 ? m->wordLen0 : 6;
  i64 wlWmeMbc = (wl << 2) | wmeMbc;
  contextmap_set(cm, k++, hash3(++i, wlWmeMbc, m->mask2));
  for (i64 n = 1; n <= 4; n++) {
    if (m->exprLen0 >= n) {
      i64 el = m->exprLen0 < n + 3 ? m->exprLen0 : n + 3;
      i64 ch = n == 4 ? m->expr0Chars
                      : (m->expr0Chars & (((i64)1 << (8 * n)) - 1));
      contextmap_set(cm, k++, hash3(++i, (el << 2) | wmeMbc, n == 1 ? m->c : ch));
    } else {
      contextmap_skip(cm, k++);
      i++;
    }
  }
  contextmap_set(cm, k++, hash3(++i, m->word0, 0));
  contextmap_set(cm, k++, hash3(++i, m->word0, m->gapToken0));
  contextmap_set(cm, k++, hash4(++i, m->c, m->word0, m->gapToken1));
  contextmap_set(cm, k++, hash4(++i, m->c, m->gapToken0, m->word1));
  contextmap_set(cm, k++, hash3(++i, m->word0, m->word1));
  contextmap_set(cm, k++, hash4(++i, m->word0, m->word1, m->word2));
  contextmap_set(cm, k++, hash4(++i, m->gapToken0, m->word1,
                                hash2(m->gapToken1, m->word2)));
  contextmap_set(cm, k++, hash4(++i, m->word0, m->word1,
                                hash2(m->gapToken1, m->word2)));
  contextmap_set(cm, k++, hash4(++i, m->word0, m->word1, m->gapToken1));
  i64 c1 = m->c4 & 0xFF;
  if (isText) {
    contextmap_set(cm, k++, hash4(++i, m->word0, c1, m->word2));
    contextmap_set(cm, k++, hash4(++i, m->word0, c1, m->word3));
    contextmap_set(cm, k++, hash4(++i, m->word0, c1, m->word4));
    contextmap_set(cm, k++, hash4(++i, m->word0, c1, hash2(m->word1, m->word4)));
    contextmap_set(cm, k++, hash4(++i, m->word0, c1, hash2(m->word1, m->word3)));
    contextmap_set(cm, k++, hash4(++i, m->word0, c1, hash2(m->word2, m->word3)));
  } else {
    for (i64 n = 0; n < 6; n++) contextmap_skip(cm, k++);
    i += 6;
  }
  i64 g = m->groups & 0xFF;
  contextmap_set(cm, k++, hash4(++i, m->opened, wlWmeMbc, g));
  contextmap_set(cm, k++, hash4(++i, m->opened, m->c, dist != 0 ? 1 : 0));
  contextmap_set(cm, k++, hash3(++i, m->opened, m->word0));
  i64 gl = m->groups & 0xFFFFFFFF, gh = (m->groups >> 32) & 0xFFFFFFFF;
  contextmap_set(cm, k++, hash3(++i, gl, gh));
  contextmap_set(cm, k++, hash4(++i, gl, gh, m->c));
  contextmap_set(cm, k++, hash4(++i, gl, gh, m->c4 & 0xFFFF));
  m->f4 = ((m->f4 << 4) | (c1 == 0x20 ? 0 : c1 >> 4)) & 0xFFFFFFFF;
  contextmap_set(cm, k++, hash2(++i, m->f4 & 0x0FFF));
  contextmap_set(cm, k++, hash2(++i, m->f4));
  i64 fl = 0;
  if (c1 != 0) {
    if (isAlpha(c1)) {
      fl = 1;
    } else if (isPunct(c1)) {
      fl = 2;
    } else if (isSpace(c1)) {
      fl = 3;
    } else if (c1 == 0xFF) {
      fl = 4;
    } else if (c1 < 16) {
      fl = 5;
    } else if (c1 < 64) {
      fl = 6;
    } else {
      fl = 7;
    }
  }
  m->mask = ((m->mask << 3) | fl) & 0xFFFFFFFF;
  contextmap_set(cm, k++, hash2(++i, m->mask));
  contextmap_set(cm, k++, hash3(++i, m->mask, c1));
  contextmap_set(cm, k++, hash3(++i, m->mask, m->c4 & 0x00FFFF00));
  contextmap_set(cm, k++, hash3(++i, m->mask & 0x1FF, m->f4 & 0x00FFF0));
  if (isText) {
    i64 bits = ((m->mask & 0x1FF) << 3) | (m->wordLen1 > 3 ? 4 : 0) |
               (m->lastUpper < m->lastLetter + m->wordLen1 ? 2 : 0) |
               (m->lastUpper < m->wordLen0 + m->wordLen1 + m->wordGap ? 1 : 0);
    contextmap_set(cm, k++, hash4(++i, hash2(m->word0, c1),
                                  zcmLlog(m->wordGap), bits));
    i64 htoken = li_get(m, m->currentToken);
    contextmap_set(cm, k++, hash2(++i, (wlWmeMbc << 16) | htoken));
    contextmap_set(cm, k++, hash3(++i, (wlWmeMbc << 8) | (htoken & 0xFF), m->c));
    contextmap_set(cm, k++, hash3(++i, (wlWmeMbc << 8) | (htoken & 0xFF),
                                  m->c4 & 0xFFFF));
    contextmap_set(cm, k++, hash4(++i, htoken & 0xFF, gl, gh));
    contextmap_set(cm, k++, hash3(++i, htoken, gl));
  } else {
    for (i64 n = 0; n < 6; n++) contextmap_skip(cm, k++);
    i += 6;
  }
}

static void pxword_mix(ZModel *self, ZState *s, Mixer *mx) {
  PxWordModel *m = (PxWordModel *)self;
  if (s->bpos == 0) {
    int isText = s->blockType == ZT_TEXT;
    i64 c1 = s->c4 & 255;
    processChar(m, s, isText, isText && c1 >= 128);
    predict(m, s, isText);
    lineModel(m, s, isText, PXWORD_NCM2);
  }
  contextmap_mix(&m->cm, mx, s->y, s->bpos, s->c0, s->c4 & 255);
  i64 o = m->cm.hits - (PXWORD_NCM1 + PXWORD_NCM2 - 31);
  if (o < 0) o = 0;
  m->order = o;
}

static void pxword_setCtx(ZModel *self, ZState *s, Mixer *mx) {
  PxWordModel *m = (PxWordModel *)self;
  mixer_set(mx, ((m->order >> 1) << 3) | s->bpos);
}

static const i64 kPxWordSel[1] = {16 * 8};

void pxwordmodel_init(PxWordModel *m, i64 bytes) {
  memset(m, 0, sizeof(*m));
  contextmap_init(&m->cm, bytes, PXWORD_NCM1 + PXWORD_NCM2, 0, 1);
  m->iCtx = ZNEW(u32, (i64)1 << 20);
  m->iCtxMask = ((i64)1 << 20) - 1;
  m->wordPositions = ZNEW(u32, (i64)1 << WPOS_BITS);
  m->checksums = ZNEW(u16, (i64)1 << WPOS_BITS);
  m->firstChar = -1;
  m->lineMatch = -1;
  m->lastLetter = MAX_LAST_LETTER;
  m->lastUpper = MAX_LAST_UPPER;
  m->wordGap = MAX_LAST_LETTER;
  m->base.inputs = m->cm.nCtx * contextmap_inputsPerContext(&m->cm);
  m->base.mix = pxword_mix;
  m->base.nsel = 1;
  m->base.selSizes = kPxWordSel;
  m->base.setCtx = pxword_setCtx;
}
