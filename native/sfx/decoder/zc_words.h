// zxsfx decoder: port of PxWordModel of zcm_words.dart, the word and line
// model of paq8px (WordModel and WordModelInfo by Zoltan Gotthardt and the
// paq8px authors, after the word models of paq8 by Matt Mahoney). The
// chart, nest and XML models of that file are not ported (the codec never
// builds them).

#ifndef ZC_WORDS_H
#define ZC_WORDS_H

#include "zc.h"

// paq8px llog: log2 * 16 of a 32-bit value.
ZINLINE i64 zcmLlog(i64 x) {
  if (x >= 0x1000000) return 256 + kIlog[(x >> 16) & 0xFFFF];
  if (x >= 0x10000) return 128 + kIlog[(x >> 8) & 0xFFFF];
  return kIlog[x & 0xFFFF];
}

#define PXWORD_NCM1 21
#define PXWORD_NCM2 46

// paq8px WordModel: 21 line contexts and 46 word contexts (33 on binary
// data), with run and byte history inputs. One mixer selector of 16 * 8.
typedef struct {
  ZModel base;
  ContextMap cm;
  u32 *iCtx; // _LargeIndirect(20)
  i64 iCtxMask;
  u32 *wordPositions;
  u16 *checksums;
  i64 c4, c, pC, ppC;
  int isNewline, isNewlinePc, isLetter, isLetterPc, isLetterPpC;
  i64 opened, wordLen0, wordLen1, exprLen0;
  i64 line0, line1, firstWord;
  i64 word0, word1, word2, word3, word4;
  i64 expr0, expr1, expr2, expr3, expr4;
  i64 keyword0, gapToken0, gapToken1, currentToken;
  i64 w, chk;
  i64 firstChar, lineMatch;
  i64 nl1, nl2, nl3, nl4;
  i64 groups; // 8 last character classes (64 bits)
  i64 text0;
  i64 lastLetter, lastUpper, wordGap;
  i64 mask, expr0Chars, mask2, f4;
  i64 order;
} PxWordModel;

void pxwordmodel_init(PxWordModel *m, i64 bytes);
// Contexts of the word model with statistics (0 to 31).
ZINLINE i64 pxwordmodel_order(const PxWordModel *m) { return m->order; }

#endif
