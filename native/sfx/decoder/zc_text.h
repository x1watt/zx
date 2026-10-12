// zxsfx decoder: port of zcm_text.dart, the text model of paq8px with its
// English stemmer (TextModel, Word, Segment, Sentence, Paragraph and
// EnglishStemmer by Marcio Pais and the paq8px authors; the stemmer is
// based on the Porter2 stemmer of Martin Porter).

#ifndef ZC_TEXT_H
#define ZC_TEXT_H

#include "zc.h"

#define ZCMWORD_MAX 64
#define TEXT_NCM 28

// A word of the text (paq8px Word): up to 63 lowercase letters, the hash
// of the word and of its stem, its type flags and language.
typedef struct {
  u8 letters[ZCMWORD_MAX];
  i64 start, end;
  i64 hash0; // the word
  i64 hash1; // the stem
  i64 type, language;
} ZcmWord;

typedef struct {
  ZcmWord firstWord;
  i64 wordCount, numCount;
} ZcmSegment;

typedef struct {
  ZcmSegment seg;
  i64 type; // 0: declarative, 1: interrogative, 2: exclamative
  i64 segmentCount, verbIndex, nounIndex, capitalIndex;
  ZcmWord lastVerb, lastNoun, lastCapital;
} ZcmSentence;

typedef struct {
  i64 sentenceCount;
  i32 typeCount[3];
  i64 typeMask;
} ZcmParagraph;

// The character group of the partial byte [c0] at [bpos] (paq8px
// State.Text.characterGroup).
i64 zcmCharacterGroup(i64 c0, i64 bpos);

// The English stemmer: stems [w] in place (the stem hash and the type
// flags); 1 when the word looks English.
int zcmEnglishStem(ZcmWord *w);

// paq8px TextModel: 28 contexts with run and byte history inputs and up
// to ten mixer weight set selectors ([mixerSets]).
typedef struct {
  ZModel base;
  ContextMap cm;
  i64 mixerSets;
  // Rings (paq8px Cache): words by language, segments, sentences,
  // paragraphs; each ring has its own index.
  ZcmWord words[2][8];
  i64 wordsIndex[2];
  ZcmSegment segments[4];
  i64 segmentsIndex;
  ZcmSentence sentences[4];
  i64 sentencesIndex;
  ZcmParagraph paragraphs[2];
  i64 paragraphsIndex;
  u32 *wordPos;  // 0x10000
  u32 bytePos[256];
  ZcmWord *cWord, *pWord;
  ZcmSegment *cSegment;
  ZcmSentence *cSentence;
  ZcmParagraph *cParagraph;
  i64 state, pState;
  // Lang
  i64 langCountEn, langMaskEn, langId, langPId;
  // Info
  i64 numbers[2];
  i32 numHashes[2];
  i32 numLength[2];
  i64 numMask, numDiff;
  i64 lastUpper, maskUpper, lastLetter, lastDigit;
  i64 lastPunctuation, lastNewLine, prevNewLine;
  i64 wordGap, spaces, commas;
  i64 quoteLength, maskPunctuation, nestHash, lastNest;
  i32 masks[5];
  i32 wordLength[2];
  i64 utf8Remaining;
  i64 firstLetter, firstChar;
  ZcmWord topicDescriptor;
  i64 parseCtx;
  i64 order;
  i8 slot[TEXT_NCM];
} TextModel;

// [contexts] NULL (the Dart default, null): all 28 contexts; otherwise
// the [ncontexts] context indices to keep. Dart default mixerSets: 10.
void textmodel_init(TextModel *m, i64 bytes, i64 mixerSets,
                    const i64 *contexts, i64 ncontexts);
// Contexts with statistics (0 to 15), for the SSE stage.
ZINLINE i64 textmodel_order(const TextModel *m) { return m->order; }
// The low bits of the word shape mask, for the SSE stage.
ZINLINE i64 textmodel_mask(const TextModel *m) { return m->masks[1] & 0xFF; }
// The first letter of the current word, for the SSE stage.
ZINLINE i64 textmodel_firstLetter(const TextModel *m) {
  return m->firstLetter;
}

#endif
