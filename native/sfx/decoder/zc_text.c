// zxsfx decoder: port of zcm_text.dart.
//
// A port of paq8px's TextModel, Word, Segment, Sentence, Paragraph and
// EnglishStemmer (Marcio Pais, the paq8px authors; the stemmer is based
// on the Porter2 stemmer of Martin Porter): the text is parsed into words,
// segments, sentences and paragraphs; each word is stemmed and classified,
// the language (English or unknown) follows from how many of the last 64
// words the stemmer recognized, and 28 hashed contexts combine them. It
// also sets ten mixer weight set selectors. Hashes are zcm's 32-bit ones.

#include "zc_text.h"
#include "zc_words.h" // zcmLlog

#define TAB 0x09
#define NEWLINE 0x0A
#define CR 0x0D
#define SPACE 0x20
#define QUOTE 0x22
#define APOSTROPHE 0x27

#define B(x) ((i64)((x) ? 1 : 0))

ZINLINE i64 lower(i64 c) { return c >= 0x41 && c <= 0x5A ? c + 32 : c; }

// ilog2 of a 32-bit value (0 for 0).
ZINLINE i64 ilog2(i64 x) {
  x &= 0xFFFFFFFF;
  if (x == 0) return 0;
  return 63 - __builtin_clzll((u64)x);
}

ZINLINE i64 comb(i64 h, i64 c) { return hash2(h + 0x6A09E667, c + 0x100); }

// English word types (paq8px Language and English flags).
enum {
  T_VERB = 1 << 0,
  T_NOUN = 1 << 1,
  T_ADJECTIVE = 1 << 2,
  T_PLURAL = 1 << 3,
  T_MALE = 1 << 4,
  T_FEMALE = 1 << 5,
  T_NEGATION = 1 << 6,
  T_PAST_TENSE = (1 << 7) | T_VERB,
  T_PRESENT_PARTICIPLE = (1 << 8) | T_VERB,
  T_ADJECTIVE_SUPERLATIVE = (1 << 9) | T_ADJECTIVE,
  T_ADJECTIVE_WITHOUT = (1 << 10) | T_ADJECTIVE,
  T_ADJECTIVE_FULL = (1 << 11) | T_ADJECTIVE,
  T_ADVERB_OF_MANNER = 1 << 12,
  T_SUFFIX_NESS = 1 << 13,
  T_SUFFIX_ITY = (1 << 14) | T_NOUN,
  T_SUFFIX_CAPABLE = 1 << 15,
  T_SUFFIX_NCE = 1 << 16,
  T_SUFFIX_NT = 1 << 17,
  T_SUFFIX_ION = 1 << 18,
  T_SUFFIX_AL = (1 << 19) | T_ADJECTIVE,
  T_SUFFIX_IC = (1 << 20) | T_ADJECTIVE,
  T_SUFFIX_IVE = 1 << 21,
  T_SUFFIX_OUS = (1 << 22) | T_ADJECTIVE,
  T_PREFIX_OVER = 1 << 23,
  T_PREFIX_UNDER = 1 << 24,
};

#define LANG_UNKNOWN 0
#define LANG_ENGLISH 1
#define LANG_COUNT 2

#define NELEM(a) ((i64)(sizeof(a) / sizeof((a)[0])))

// ---------------------------------------------------------------- ZcmWord

static void zw_reset(ZcmWord *w) { memset(w, 0, sizeof(*w)); }

static void zw_copy(ZcmWord *d, const ZcmWord *s) {
  if (d != s) *d = *s;
}

ZINLINE i64 slen(const char *s) { return (i64)strlen(s); }

// Word::operator==
static int zw_eq(const ZcmWord *w, const char *s) {
  i64 len = slen(s);
  if (w->end - w->start + B(w->letters[w->start] != 0) != len) return 0;
  for (i64 i = 0; i < len; i++) {
    if (w->letters[w->start + i] != (u8)s[i]) return 0;
  }
  return 1;
}

// Word::operator+=
static void zw_add(ZcmWord *w, i64 c) {
  if (w->end < ZCMWORD_MAX - 1) {
    w->end += B(w->letters[w->end] > 0);
    w->letters[w->end] = (u8)lower(c);
  }
}

// Letter [i] from the start / from the end (0 when the word is shorter).
ZINLINE i64 zw_at(const ZcmWord *w, i64 i) {
  return w->end - w->start >= i ? w->letters[w->start + i] : 0;
}
ZINLINE i64 zw_back(const ZcmWord *w, i64 i) {
  return w->end - w->start >= i ? w->letters[w->end - i] : 0;
}
ZINLINE i64 zw_length(const ZcmWord *w) {
  return w->letters[w->start] != 0 ? w->end - w->start + 1 : 0;
}

static i64 zw_hash(const ZcmWord *w) {
  i64 h = 0;
  for (i64 i = w->start; i <= w->end; i++) h = comb(h, w->letters[i]);
  return h;
}
static void zw_calculateWordHash(ZcmWord *w) {
  w->hash0 = w->hash1 = zw_hash(w);
}
static void zw_calculateStemHash(ZcmWord *w) { w->hash1 = zw_hash(w); }

static int zw_matchAt(const ZcmWord *w, i64 off, const char *s) {
  for (i64 i = 0; s[i] != 0; i++) {
    if (w->letters[off + i] != (u8)s[i]) return 0;
  }
  return 1;
}

static int zw_changeSuffix(ZcmWord *w, const char *oldSuffix,
                           const char *newSuffix) {
  i64 len = slen(oldSuffix);
  if (zw_length(w) > len && zw_matchAt(w, w->end - len + 1, oldSuffix)) {
    i64 n = slen(newSuffix);
    if (n > 0) {
      i64 lim = w->end + n < ZCMWORD_MAX - 1 ? w->end + n : ZCMWORD_MAX - 1;
      i64 count = lim - w->end;
      i64 at = w->end - len + 1;
      for (i64 i = 0; i < count; i++) w->letters[at + i] = (u8)newSuffix[i];
      i64 e = w->end - len + n;
      w->end = e < ZCMWORD_MAX - 1 ? e : ZCMWORD_MAX - 1;
    } else {
      w->end -= len;
    }
    return 1;
  }
  return 0;
}

static int zw_matchesAny(const ZcmWord *w, const char *const *a, i64 n) {
  i64 len = zw_length(w);
  for (i64 i = 0; i < n; i++) {
    if (slen(a[i]) == len && zw_matchAt(w, w->start, a[i])) return 1;
  }
  return 0;
}

static int zw_endsWith(const ZcmWord *w, const char *suffix) {
  i64 len = slen(suffix);
  return zw_length(w) > len && zw_matchAt(w, w->end - len + 1, suffix);
}

static int zw_startsWith(const ZcmWord *w, const char *prefix) {
  i64 len = slen(prefix);
  return zw_length(w) > len && zw_matchAt(w, w->start, prefix);
}

// ---------------------------------------------------------------- stemmer

static const char *const kMaleWords[] = {"he",  "him", "his",     "himself",
                                         "man", "men", "boy",     "husband",
                                         "actor"};
static const char *const kFemaleWords[] = {
    "she", "her", "herself", "woman", "women", "girl", "wife", "actress"};
static const char *const kCommonWords[] = {"the",  "be",   "to",   "of",
                                           "and",  "in",   "that", "you",
                                           "have", "with", "from", "but"};
static const char *const kSuffixesStep0[] = {"'s'", "'s", "'"};
static const char *const kSuffixesStep1B[] = {"eedly", "eed", "ed",
                                              "edly",  "ing", "ingly"};
static const i64 kTypesStep1B[] = {
    T_ADVERB_OF_MANNER,
    0,
    T_PAST_TENSE,
    T_ADVERB_OF_MANNER | T_PAST_TENSE,
    T_PRESENT_PARTICIPLE,
    T_ADVERB_OF_MANNER | T_PRESENT_PARTICIPLE};
static const char *const kStep2From[] = {
    "ization", "ational", "ousness", "iveness", "fulness", "tional",
    "lessli",  "biliti",  "entli",   "ation",   "alism",   "aliti",
    "fulli",   "ousli",   "iviti",   "enci",    "anci",    "abli",
    "izer",    "ator",    "alli",    "bli"};
static const char *const kStep2To[] = {
    "ize", "ate", "ous",  "ive",  "ful",  "tion", "less", "ble",
    "ent", "ate", "al",   "al",   "ful",  "ous",  "ive",  "ence",
    "ance", "able", "ize", "ate", "al",   "ble"};
static const i64 kTypesStep2[] = {T_SUFFIX_ION,
                                  T_SUFFIX_ION | T_SUFFIX_AL,
                                  T_SUFFIX_NESS,
                                  T_SUFFIX_NESS,
                                  T_SUFFIX_NESS,
                                  T_SUFFIX_ION | T_SUFFIX_AL,
                                  T_ADVERB_OF_MANNER,
                                  T_ADVERB_OF_MANNER | T_SUFFIX_ITY,
                                  T_ADVERB_OF_MANNER,
                                  T_SUFFIX_ION,
                                  0,
                                  T_SUFFIX_ITY,
                                  T_ADVERB_OF_MANNER,
                                  T_ADVERB_OF_MANNER,
                                  T_SUFFIX_ITY,
                                  0,
                                  0,
                                  T_ADVERB_OF_MANNER,
                                  0,
                                  0,
                                  T_ADVERB_OF_MANNER,
                                  T_ADVERB_OF_MANNER};
static const char *const kStep3From[] = {"ational", "tional", "alize", "icate",
                                         "iciti",   "ical",   "ful",   "ness"};
static const char *const kStep3To[] = {"ate", "tion", "al", "ic",
                                       "ic",  "ic",   "",   ""};
static const i64 kTypesStep3[] = {T_SUFFIX_ION | T_SUFFIX_AL,
                                  T_SUFFIX_ION | T_SUFFIX_AL,
                                  0,
                                  0,
                                  T_SUFFIX_ITY,
                                  T_SUFFIX_AL,
                                  T_ADJECTIVE_FULL,
                                  T_SUFFIX_NESS};
static const char *const kSuffixesStep4[] = {
    "al",   "ance", "ence", "er",  "ic",  "able", "ible",
    "ant",  "ement", "ment", "ent", "ou",  "ism",  "ate",
    "iti",  "ous",  "ive",  "ize", "sion", "tion"};
static const i64 kTypesStep4[] = {
    T_SUFFIX_AL, T_SUFFIX_NCE, T_SUFFIX_NCE,  0,           T_SUFFIX_IC,
    T_SUFFIX_CAPABLE, T_SUFFIX_CAPABLE, T_SUFFIX_NT, 0,     0,
    T_SUFFIX_NT, 0,            0,             0,           T_SUFFIX_ITY,
    T_SUFFIX_OUS, T_SUFFIX_IVE, 0,            T_SUFFIX_ION, T_SUFFIX_ION};
static const char *const kExceptionsRegion1[] = {"gener", "arsen", "commun"};
static const char *const kExceptions1From[] = {
    "skis",  "skies", "dying", "lying",  "tying", "idly",  "gently",
    "ugly",  "early", "only",  "singly", "sky",   "news",  "howe",
    "atlas", "cosmos", "bias", "andes",  "texas"};
static const char *const kExceptions1To[] = {
    "ski",   "sky",    "die",  "lie",   "tie",  "idl",  "gentl",
    "ugli",  "earli",  "onli", "singl", "sky",  "news", "howe",
    "atlas", "cosmos", "bias", "andes", "texas"};
static const i64 kTypesExceptions1[] = {T_NOUN | T_PLURAL,
                                        T_NOUN | T_PLURAL | T_VERB,
                                        T_PRESENT_PARTICIPLE,
                                        T_PRESENT_PARTICIPLE,
                                        T_PRESENT_PARTICIPLE,
                                        T_ADVERB_OF_MANNER,
                                        T_ADVERB_OF_MANNER,
                                        T_ADJECTIVE,
                                        T_ADJECTIVE | T_ADVERB_OF_MANNER,
                                        0,
                                        T_ADVERB_OF_MANNER,
                                        T_NOUN,
                                        T_NOUN,
                                        0,
                                        T_NOUN,
                                        T_NOUN,
                                        T_NOUN,
                                        T_NOUN | T_PLURAL,
                                        T_NOUN};
static const char *const kExceptions2[] = {"inning",  "outing", "canning",
                                           "herring", "earring", "proceed",
                                           "exceed",  "succeed"};
static const i64 kTypesExceptions2[] = {T_NOUN, T_NOUN, T_NOUN, T_NOUN,
                                        T_NOUN, T_VERB, T_VERB, T_VERB};

static int in(i64 c, const char *a) {
  for (i64 i = 0; a[i] != 0; i++) {
    if ((u8)a[i] == c) return 1;
  }
  return 0;
}

ZINLINE int isVowel(i64 c) { return in(c, "aeiouy"); }
ZINLINE int isConsonant(i64 c) { return !isVowel(c); }
ZINLINE int isShortConsonant(i64 c) { return !in(c, "wxY"); }
ZINLINE int isDouble(i64 c) { return in(c, "bdfgmnprt"); }
ZINLINE int isLiEnding(i64 c) { return in(c, "cdeghkmnrt"); }

// Stemmer::getRegion
static i64 getRegion(const ZcmWord *w, i64 from) {
  int hasVowel = 0;
  for (i64 i = w->start + from; i <= w->end; i++) {
    if (isVowel(w->letters[i])) {
      hasVowel = 1;
      continue;
    }
    if (hasVowel) return i - w->start + 1;
  }
  return w->start + zw_length(w);
}

// Stemmer::suffixInRn (the unsigned difference of C++ wraps to a large
// value when the suffix is longer than the word).
static int suffixInRn(const ZcmWord *w, i64 rn, const char *suffix) {
  i64 d = zw_length(w) - slen(suffix);
  return w->start != w->end && (d < 0 || rn <= d);
}

static i64 getRegion1(const ZcmWord *w) {
  for (i64 i = 0; i < NELEM(kExceptionsRegion1); i++) {
    if (zw_startsWith(w, kExceptionsRegion1[i]))
      return slen(kExceptionsRegion1[i]);
  }
  return getRegion(w, 0);
}

static int endsInShortSyllable(const ZcmWord *w) {
  if (w->end == w->start) return 0;
  if (w->end == w->start + 1) {
    return isVowel(zw_back(w, 1)) && isConsonant(zw_back(w, 0));
  }
  return isConsonant(zw_back(w, 2)) && isVowel(zw_back(w, 1)) &&
         isConsonant(zw_back(w, 0)) && isShortConsonant(zw_back(w, 0));
}

static int isShortWord(const ZcmWord *w) {
  return endsInShortSyllable(w) && getRegion1(w) == zw_length(w);
}

static int hasVowels(const ZcmWord *w) {
  for (i64 i = w->start; i <= w->end; i++) {
    if (isVowel(w->letters[i])) return 1;
  }
  return 0;
}

static int trimApostrophes(ZcmWord *w) {
  int result = 0;
  i64 cnt = 0;
  while (w->start != w->end && zw_at(w, 0) == APOSTROPHE) {
    result = 1;
    w->start++;
    cnt++;
  }
  while (w->start != w->end && zw_back(w, 0) == APOSTROPHE) {
    if (cnt == 0) break;
    w->end--;
    cnt--;
  }
  return result;
}

static void markYsAsConsonants(ZcmWord *w) {
  if (zw_at(w, 0) == 0x79) w->letters[w->start] = 0x59;
  for (i64 i = w->start + 1; i <= w->end; i++) {
    if (isVowel(w->letters[i - 1]) && w->letters[i] == 0x79) {
      w->letters[i] = 0x59;
    }
  }
}

static int processPrefixes(ZcmWord *w) {
  if (zw_startsWith(w, "irr") && zw_length(w) > 5 &&
      (zw_at(w, 3) == 0x61 || zw_at(w, 3) == 0x65)) {
    w->start += 2;
    w->type |= T_NEGATION;
  } else if (zw_startsWith(w, "over") && zw_length(w) > 5) {
    w->start += 4;
    w->type |= T_PREFIX_OVER;
  } else if (zw_startsWith(w, "under") && zw_length(w) > 6) {
    w->start += 5;
    w->type |= T_PREFIX_UNDER;
  } else if (zw_startsWith(w, "unn") && zw_length(w) > 5) {
    w->start += 2;
    w->type |= T_NEGATION;
  } else if (zw_startsWith(w, "non") &&
             zw_length(w) > 5 + B(zw_at(w, 3) == 0x2D)) {
    w->start += 2 + B(zw_at(w, 3) == 0x2D);
    w->type |= T_NEGATION;
  } else {
    return 0;
  }
  return 1;
}

static void notSuperlative(ZcmWord *w, i64 i) {
  w->end = i;
  w->type &= ~(i64)T_ADJECTIVE_SUPERLATIVE;
}

static int processSuperlatives(ZcmWord *w) {
  if (zw_endsWith(w, "est") && zw_length(w) > 4) {
    i64 i = w->end;
    w->end -= 3;
    w->type |= T_ADJECTIVE_SUPERLATIVE;
    if (zw_back(w, 0) == zw_back(w, 1) && zw_back(w, 0) != 0x72 &&
        !(zw_length(w) >= 4 && zw_matchAt(w, w->end - 3, "sugg"))) {
      i64 b0 = zw_back(w, 0);
      w->end -= B(((b0 != 0x66 && b0 != 0x6C && b0 != 0x73) ||
                   (zw_length(w) > 4 && zw_back(w, 1) == 0x6C &&
                    (zw_back(w, 2) == 0x75 || zw_back(w, 3) == 0x75 ||
                     zw_back(w, 3) == 0x76))) &&
                  !(zw_length(w) == 3 && zw_back(w, 1) == 0x64 &&
                    zw_back(w, 2) == 0x6F));
      if (zw_length(w) == 2 && (zw_at(w, 0) != 0x69 || zw_at(w, 1) != 0x6E)) {
        notSuperlative(w, i);
      }
    } else {
      switch (zw_back(w, 0)) {
        case 0x64: // d
        case 0x6B: // k
        case 0x6D: // m
        case 0x79: // y
          break;
        case 0x67: // g
          if (!(zw_length(w) > 3 &&
                (zw_back(w, 1) == 0x6E || zw_back(w, 1) == 0x72) &&
                !zw_matchAt(w, w->end - 3, "cong"))) {
            notSuperlative(w, i);
          } else {
            w->end += B(zw_back(w, 2) == 0x61);
          }
          break;
        case 0x69: // i
          w->letters[w->end] = 0x79;
          break;
        case 0x6C: // l
          if (w->end == w->start + 1 || zw_matchAt(w, w->end - 2, "mo")) {
            notSuperlative(w, i);
          } else {
            w->end += B(isConsonant(zw_back(w, 1)));
          }
          break;
        case 0x6E: // n
          if (zw_length(w) < 3 || isConsonant(zw_back(w, 1)) ||
              isConsonant(zw_back(w, 2))) {
            notSuperlative(w, i);
          }
          break;
        case 0x72: // r
          if (zw_length(w) > 3 && isVowel(zw_back(w, 1)) &&
              isVowel(zw_back(w, 2))) {
            w->end += B(zw_back(w, 2) == 0x75 &&
                        (zw_back(w, 1) == 0x61 || zw_back(w, 1) == 0x69));
          } else {
            notSuperlative(w, i);
          }
          break;
        case 0x73: // s
          w->end++;
          break;
        case 0x77: // w
          if (!(zw_length(w) > 2 && isVowel(zw_back(w, 1)))) {
            notSuperlative(w, i);
          }
          break;
        case 0x68: // h
          if (!(zw_length(w) > 2 && isConsonant(zw_back(w, 1)))) {
            notSuperlative(w, i);
          }
          break;
        default:
          w->end += 3;
          w->type &= ~(i64)T_ADJECTIVE_SUPERLATIVE;
      }
    }
  }
  return (w->type & T_ADJECTIVE_SUPERLATIVE) != 0;
}

static int step0(ZcmWord *w) {
  for (i64 i = 0; i < NELEM(kSuffixesStep0); i++) {
    if (zw_endsWith(w, kSuffixesStep0[i])) {
      w->end -= slen(kSuffixesStep0[i]);
      w->type |= T_PLURAL;
      return 1;
    }
  }
  return 0;
}

static int step1A(ZcmWord *w) {
  if (zw_endsWith(w, "sses")) {
    w->end -= 2;
    w->type |= T_PLURAL;
    return 1;
  }
  if (zw_endsWith(w, "ied") || zw_endsWith(w, "ies")) {
    w->type |= zw_back(w, 0) == 0x64 ? T_PAST_TENSE : T_PLURAL;
    w->end -= zw_length(w) > 4 ? 2 : 1;
    return 1;
  }
  if (zw_endsWith(w, "us") || zw_endsWith(w, "ss")) return 0;
  if (zw_back(w, 0) == 0x73 && zw_length(w) > 2) {
    for (i64 i = w->start; i <= w->end - 2; i++) {
      if (isVowel(w->letters[i])) {
        w->end--;
        w->type |= T_PLURAL;
        return 1;
      }
    }
  }
  if (zw_endsWith(w, "n't") && zw_length(w) > 4) {
    switch (zw_back(w, 3)) {
      case 0x61: // a
        if (zw_back(w, 4) == 0x63) {
          w->end -= 2; // can't, to can
        } else {
          zw_changeSuffix(w, "n't", "ll"); // shan't, to shall
        }
        break;
      case 0x69: // i
        zw_changeSuffix(w, "in't", "m"); // ain't, to am
        break;
      case 0x6F: // o
        if (zw_back(w, 4) == 0x77) {
          zw_changeSuffix(w, "on't", "ill"); // won't, to will
        } else {
          w->end -= 3; // don't, to do
        }
        break;
      default:
        w->end -= 3;
    }
    w->type |= T_NEGATION;
    return 1;
  }
  if (zw_endsWith(w, "hood") && zw_length(w) > 7) {
    w->end -= 4;
    return 1;
  }
  return 0;
}

static void step1BPast(ZcmWord *w) {
  switch (zw_back(w, 0)) {
    case 0x63: // c
    case 0x73: // s
    case 0x76: // v
      w->end += B(!(zw_endsWith(w, "ss") || zw_endsWith(w, "ias")));
      break;
    case 0x64: { // d
      i64 b2 = zw_back(w, 2);
      w->end += B(isVowel(zw_back(w, 1)) &&
                  !(b2 == 0x61 || b2 == 0x65 || b2 == 0x69 || b2 == 0x6F));
      break;
    }
    case 0x6B: // k
      w->end += B(zw_endsWith(w, "uak"));
      break;
    case 0x6C: // l
      w->end += B(in(zw_back(w, 1), "bcdfgkptyz") ||
                  (in(zw_back(w, 1), "aiou") && isConsonant(zw_back(w, 2))));
      break;
  }
}

static void step1BIng(ZcmWord *w) {
  switch (zw_back(w, 0)) {
    case 0x64: // d
      if (isVowel(zw_back(w, 1)) && zw_back(w, 2) != 0x61 &&
          zw_back(w, 2) != 0x65 && zw_back(w, 2) != 0x6F) {
        zw_add(w, 0x65);
      }
      break;
    case 0x67: { // g
      i64 b1 = zw_back(w, 1), b2 = zw_back(w, 2), b3 = zw_back(w, 3);
      if (in(b1, "adeilru") ||
          (b1 == 0x6E &&
           (b2 == 0x65 || (b2 == 0x75 && b3 != 0x62 && b3 != 0x64) ||
            (b2 == 0x61 &&
             (b3 == 0x72 || (b3 == 0x68 && zw_back(w, 4) == 0x63))) ||
            (zw_endsWith(w, "ring") &&
             (zw_back(w, 4) == 0x63 || zw_back(w, 4) == 0x66))))) {
        zw_add(w, 0x65);
      }
      break;
    }
    case 0x6C: { // l
      i64 b1 = zw_back(w, 1);
      if (!(b1 == 0x6C || b1 == 0x72 || b1 == 0x77 ||
            (isVowel(b1) && isVowel(zw_back(w, 2))))) {
        zw_add(w, 0x65);
      }
      if (zw_endsWith(w, "uell") && zw_length(w) > 4 &&
          zw_back(w, 4) != 0x71) {
        w->end--;
      }
      break;
    }
    case 0x72: { // r
      i64 b1 = zw_back(w, 1), b2 = zw_back(w, 2), b3 = zw_back(w, 3);
      if (((b1 == 0x69 && b2 != 0x61 && b2 != 0x65 && b2 != 0x6F) ||
           (b1 == 0x61 && !(b2 == 0x65 || b2 == 0x6F ||
                            (b2 == 0x6C && b3 == 0x6C))) ||
           (b1 == 0x6F && !(b2 == 0x6F || (b2 == 0x74 && b3 != 0x73))) ||
           b1 == 0x63 || b1 == 0x74) &&
          !zw_endsWith(w, "str")) {
        zw_add(w, 0x65);
      }
      break;
    }
    case 0x74: { // t
      i64 b2 = zw_back(w, 2);
      if (zw_back(w, 1) == 0x6F && b2 != 0x67 && b2 != 0x6C && b2 != 0x69 &&
          b2 != 0x6F) {
        zw_add(w, 0x65);
      }
      break;
    }
    case 0x75: // u
      if (!(zw_length(w) > 3 && isVowel(zw_back(w, 1)) &&
            isVowel(zw_back(w, 2)))) {
        zw_add(w, 0x65);
      }
      break;
    case 0x7A: // z
      if (zw_endsWith(w, "izz") && zw_length(w) > 3 &&
          (zw_back(w, 3) == 0x68 || zw_back(w, 3) == 0x75)) {
        w->end--;
      } else if (zw_back(w, 1) != 0x74 && zw_back(w, 1) != 0x7A) {
        zw_add(w, 0x65);
      }
      break;
    case 0x6B: // k
      if (zw_endsWith(w, "uak")) zw_add(w, 0x65);
      break;
    case 0x62: // b
    case 0x63: // c
    case 0x73: // s
    case 0x76: // v
      if (!((zw_back(w, 0) == 0x62 &&
             (zw_back(w, 1) == 0x6D || zw_back(w, 1) == 0x72)) ||
            zw_endsWith(w, "ss") || zw_endsWith(w, "ias") ||
            zw_eq(w, "zinc"))) {
        zw_add(w, 0x65);
      }
      break;
  }
}

static int step1B(ZcmWord *w, i64 r1) {
  for (i64 i = 0; i < NELEM(kSuffixesStep1B); i++) {
    const char *suf = kSuffixesStep1B[i];
    if (!zw_endsWith(w, suf)) continue;
    if (i <= 1) {
      if (suffixInRn(w, r1, suf)) w->end -= 1 + i * 2;
    } else {
      i64 j = w->end;
      w->end -= slen(suf);
      if (hasVowels(w)) {
        if (zw_endsWith(w, "at") || zw_endsWith(w, "bl") ||
            zw_endsWith(w, "iz") || isShortWord(w)) {
          zw_add(w, 0x65);
        } else if (zw_length(w) > 2) {
          if (zw_back(w, 0) == zw_back(w, 1) && isDouble(zw_back(w, 0))) {
            w->end--;
          } else if (i == 2 || i == 3) {
            step1BPast(w);
          } else if (i >= 4) {
            step1BIng(w);
          }
        }
      } else {
        w->end = j;
        return 0;
      }
    }
    w->type |= kTypesStep1B[i];
    return 1;
  }
  return 0;
}

static int step1C(ZcmWord *w) {
  i64 b0 = zw_back(w, 0);
  if (zw_length(w) > 2 && (b0 == 0x79 || b0 == 0x59) &&
      !in(zw_back(w, 1), "aeiouy")) {
    w->letters[w->end] = 0x69;
    return 1;
  }
  return 0;
}

static int adverb2(ZcmWord *w) {
  w->end -= 2;
  w->type |= T_ADVERB_OF_MANNER;
  return 1;
}

static int step2(ZcmWord *w, i64 r1) {
  for (i64 i = 0; i < NELEM(kStep2From); i++) {
    const char *s = kStep2From[i];
    if (zw_endsWith(w, s) && suffixInRn(w, r1, s)) {
      zw_changeSuffix(w, s, kStep2To[i]);
      w->type |= kTypesStep2[i];
      return 1;
    }
  }
  if (zw_endsWith(w, "logi") && suffixInRn(w, r1, "ogi")) {
    w->end--;
    return 1;
  }
  if (zw_endsWith(w, "li")) {
    if (suffixInRn(w, r1, "li") && isLiEnding(zw_back(w, 2))) {
      return adverb2(w);
    }
    if (zw_length(w) > 3) {
      switch (zw_back(w, 2)) {
        case 0x62: // b
          w->letters[w->end] = 0x65;
          w->type |= T_ADVERB_OF_MANNER;
          return 1;
        case 0x69: // i
          if (zw_length(w) > 4) return adverb2(w);
          break;
        case 0x6C: // l
          if (zw_length(w) > 5 &&
              (zw_back(w, 3) == 0x61 || zw_back(w, 3) == 0x75)) {
            return adverb2(w);
          }
          break;
        case 0x73: // s
          return adverb2(w);
        case 0x65: // e
        case 0x67: // g
        case 0x6D: // m
        case 0x6E: // n
        case 0x72: // r
        case 0x77: // w
          if (zw_length(w) > 4 + B(zw_back(w, 2) == 0x72)) return adverb2(w);
          break;
      }
    }
  }
  return 0;
}

static int step3(ZcmWord *w, i64 r1, i64 r2) {
  int res = 0;
  for (i64 i = 0; i < NELEM(kStep3From); i++) {
    const char *s = kStep3From[i];
    if (zw_endsWith(w, s) && suffixInRn(w, r1, s)) {
      zw_changeSuffix(w, s, kStep3To[i]);
      w->type |= kTypesStep3[i];
      res = 1;
      break;
    }
  }
  if (zw_endsWith(w, "ative") && suffixInRn(w, r2, "ative")) {
    w->end -= 5;
    w->type |= T_SUFFIX_IVE;
    return 1;
  }
  if (zw_length(w) > 5 && zw_endsWith(w, "less")) {
    w->end -= 4;
    w->type |= T_ADJECTIVE_WITHOUT;
    return 1;
  }
  return res;
}

static int step4(ZcmWord *w, i64 r2) {
  int res = 0;
  for (i64 i = 0; i < NELEM(kSuffixesStep4); i++) {
    const char *s = kSuffixesStep4[i];
    if (zw_endsWith(w, s) && suffixInRn(w, r2, s)) {
      w->end -= slen(s) - B(i > 17);
      if (!(i == 10 && zw_back(w, 0) == 0x6D)) w->type |= kTypesStep4[i];
      if (i == 0 && zw_endsWith(w, "nti")) {
        w->end--;
        res = 1;
        continue;
      }
      return 1;
    }
  }
  return res;
}

static int step5(ZcmWord *w, i64 r1, i64 r2) {
  if (zw_back(w, 0) == 0x65 && !zw_eq(w, "here")) {
    if (suffixInRn(w, r2, "e")) {
      w->end--;
    } else if (suffixInRn(w, r1, "e")) {
      w->end--;
      w->end += B(endsInShortSyllable(w));
    } else {
      return 0;
    }
    return 1;
  }
  if (zw_length(w) > 1 && zw_back(w, 0) == 0x6C && suffixInRn(w, r2, "l") &&
      zw_back(w, 1) == 0x6C) {
    w->end--;
    return 1;
  }
  return 0;
}

int zcmEnglishStem(ZcmWord *w) {
  if (zw_length(w) < 2) {
    zw_calculateStemHash(w);
    return 0;
  }
  int res = trimApostrophes(w);
  res = processPrefixes(w) || res;
  res = processSuperlatives(w) || res;
  for (i64 i = 0; i < NELEM(kExceptions1From); i++) {
    if (zw_eq(w, kExceptions1From[i])) {
      if (i < 11) {
        const char *to = kExceptions1To[i];
        i64 n = slen(to);
        for (i64 k = 0; k < n; k++) w->letters[w->start + k] = (u8)to[k];
        w->end = w->start + n - 1;
      }
      zw_calculateStemHash(w);
      w->type |= kTypesExceptions1[i];
      w->language = LANG_ENGLISH;
      return i < 11;
    }
  }
  markYsAsConsonants(w);
  i64 r1 = getRegion1(w);
  i64 r2 = getRegion(w, r1);
  res = step0(w) || res;
  res = step1A(w) || res;
  for (i64 i = 0; i < NELEM(kExceptions2); i++) {
    if (zw_eq(w, kExceptions2[i])) {
      zw_calculateStemHash(w);
      w->type |= kTypesExceptions2[i];
      w->language = LANG_ENGLISH;
      return res;
    }
  }
  res = step1B(w, r1) || res;
  res = step1C(w) || res;
  res = step2(w, r1) || res;
  res = step3(w, r1, r2) || res;
  res = step4(w, r2) || res;
  res = step5(w, r1, r2) || res;
  for (i64 i = w->start; i <= w->end; i++) {
    if (w->letters[i] == 0x59) w->letters[i] = 0x79;
  }
  if (w->type == 0 || w->type == T_PLURAL) {
    if (zw_matchesAny(w, kMaleWords, NELEM(kMaleWords))) {
      res = 1;
      w->type |= T_MALE;
    } else if (zw_matchesAny(w, kFemaleWords, NELEM(kFemaleWords))) {
      res = 1;
      w->type |= T_FEMALE;
    }
  }
  if (!res) res = zw_matchesAny(w, kCommonWords, NELEM(kCommonWords));
  zw_calculateStemHash(w);
  if (res) w->language = LANG_ENGLISH;
  return res;
}

// ---------------------------------------------------------------- tables

// TextModel::asciiGroup
static const u8 kAsciiGroup[] = {
    0,  5,  5,  5,  5,  5,  5,  5,  5,  5,  4,  5,  5,  4,  5,  5,
    5,  5,  5,  5,  5,  5,  5,  5,  5,  5,  5,  5,  5,  5,  5,  5,
    6,  7,  8,  17, 17, 9,  17, 10, 11, 12, 17, 17, 13, 14, 15, 16,
    1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  18, 19, 20, 23, 21, 22,
    23, 2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,
    2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  24, 27, 25, 27, 26,
    27, 3,  3,  3,  3,  3,  3,  3,  3,  3,  3,  3,  3,  3,  3,  3,
    3,  3,  3,  3,  3,  3,  3,  3,  3,  3,  3,  28, 30, 29, 30, 30};

// Shared::update asciiGroup (the group of a partial byte).
static const u8 kPartialGroup[] = {
    0, 10, 0, 1, 10, 10, 0, 4, 2, 3, 10, 10, 10, 10, 0, 0, 5, 4, 2, 2, 3, 3,
    10, 10, 10, 10, 10, 10, 10, 10, 0, 0, 0, 0, 5, 5, 9, 4, 2, 2, 2, 2, 3, 3,
    3, 3, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 0,
    0, 0, 0, 0, 0, 0, 0, 5, 8, 8, 5, 9, 9, 6, 5, 2, 2, 2, 2, 2, 2, 2, 8, 3, 3,
    3, 3, 3, 3, 3, 8, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10,
    10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 7, 8, 8, 8, 8, 8, 5, 5, 9, 9,
    9, 9, 9, 7, 8, 5, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 8, 8, 3, 3, 3,
    3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 8, 8, 10, 10, 10, 10, 10, 10, 10, 10, 10,
    10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10,
    10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10,
    10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10,
    10, 10};

_Static_assert(sizeof(kAsciiGroup) == 128, "kAsciiGroup");
_Static_assert(sizeof(kPartialGroup) == 255, "kPartialGroup");
_Static_assert(NELEM(kTypesStep1B) == NELEM(kSuffixesStep1B), "step1B");
_Static_assert(NELEM(kStep2To) == NELEM(kStep2From) &&
                   NELEM(kTypesStep2) == NELEM(kStep2From), "step2");
_Static_assert(NELEM(kStep3To) == NELEM(kStep3From) &&
                   NELEM(kTypesStep3) == NELEM(kStep3From), "step3");
_Static_assert(NELEM(kTypesStep4) == NELEM(kSuffixesStep4), "step4");
_Static_assert(NELEM(kExceptions1To) == NELEM(kExceptions1From) &&
                   NELEM(kTypesExceptions1) == NELEM(kExceptions1From),
               "exceptions1");
_Static_assert(NELEM(kTypesExceptions2) == NELEM(kExceptions2), "exceptions2");

i64 zcmCharacterGroup(i64 c0, i64 bpos) {
  return bpos > 0
             ? kPartialGroup[((i64)1 << bpos) - 2 + (c0 & (((i64)1 << bpos) - 1))]
             : 0;
}

// ---------------------------------------------------------------- TextModel

// Parser states (TextModel::Parse).
enum {
  P_UNKNOWN = 0,
  P_READING_WORD = 1,
  P_POSSIBLE_HYPHENATION = 2,
  P_WAS_ABBREVIATION = 3,
  P_AFTER_COMMA = 4,
  P_AFTER_QUOTE = 5,
  P_AFTER_ABBREVIATION = 6,
  P_EXPECT_DIGIT = 7,
};

#define MIN_RECOGNIZED_WORDS 4

static const i64 kSetSizes[10] = {16 * 8, 2048, 2048, 4096, 4096,
                                  2048,   2048, 4096, 8192, 2048};

static const char *const kAbbreviations[] = {"mr", "mrs", "ms",
                                             "dr", "st",  "jr"};

// Ring access (paq8px Cache::operator()).
ZINLINE ZcmWord *wordAt(TextModel *m, i64 lang, i64 i) {
  return &m->words[lang][(m->wordsIndex[lang] - i) & 7];
}
ZINLINE ZcmSegment *segmentAt(TextModel *m, i64 i) {
  return &m->segments[(m->segmentsIndex - i) & 3];
}
ZINLINE ZcmSentence *sentenceAt(TextModel *m, i64 i) {
  return &m->sentences[(m->sentencesIndex - i) & 3];
}
ZINLINE ZcmParagraph *paragraphAt(TextModel *m, i64 i) {
  return &m->paragraphs[(m->paragraphsIndex - i) & 1];
}

static void segment_clear(ZcmSegment *s) {
  zw_reset(&s->firstWord);
  s->wordCount = s->numCount = 0;
}

static void sentence_clear(ZcmSentence *s) {
  segment_clear(&s->seg);
  s->type = s->segmentCount = s->verbIndex = s->nounIndex = s->capitalIndex =
      0;
  zw_reset(&s->lastVerb);
  zw_reset(&s->lastNoun);
  zw_reset(&s->lastCapital);
}

static void paragraph_clear(ZcmParagraph *p) {
  p->sentenceCount = 0;
  p->typeCount[0] = p->typeCount[1] = p->typeCount[2] = 0;
  p->typeMask = 0;
}

static ZcmSegment *nextSegment(TextModel *m) {
  m->segmentsIndex++;
  ZcmSegment *s = segmentAt(m, 0);
  segment_clear(s);
  return s;
}
static ZcmSentence *nextSentence(TextModel *m) {
  m->sentencesIndex++;
  ZcmSentence *s = sentenceAt(m, 0);
  sentence_clear(s);
  return s;
}
static ZcmParagraph *nextParagraph(TextModel *m) {
  m->paragraphsIndex++;
  ZcmParagraph *s = paragraphAt(m, 0);
  paragraph_clear(s);
  return s;
}

// Int32List element updates (stores truncate to 32 bits).
ZINLINE void madd(TextModel *m, int i, i64 v) {
  m->masks[i] = (i32)((i64)m->masks[i] + v);
}
ZINLINE void mshl(TextModel *m, int i, int n) {
  m->masks[i] = (i32)shl(m->masks[i], n);
}

// The end of a word: stemming, language detection, the words of the
// segment and sentence.
static void endWord(TextModel *m, i64 pos) {
  ZcmWord *cWord = m->cWord;
  if (m->langId != LANG_UNKNOWN) zw_copy(wordAt(m, LANG_UNKNOWN, 0), cWord);
  // Only English is detected (paq8px also has French and German).
  m->langCountEn -= (m->langMaskEn >> 63) & 1;
  m->langMaskEn = shl(m->langMaskEn, 1);
  if (m->langId != LANG_ENGLISH) zw_copy(wordAt(m, LANG_ENGLISH, 0), cWord);
  if (zcmEnglishStem(wordAt(m, LANG_ENGLISH, 0))) {
    m->langCountEn++;
    m->langMaskEn |= 1;
  }
  m->langId = LANG_UNKNOWN;
  if (m->langCountEn >= MIN_RECOGNIZED_WORDS) m->langId = LANG_ENGLISH;
  m->wordsIndex[LANG_ENGLISH]++;
  m->wordsIndex[LANG_UNKNOWN]++;
  m->langPId = m->langId;
  m->pWord = wordAt(m, m->langId, 1);
  m->cWord = wordAt(m, m->langId, 0);
  zw_reset(m->cWord);
  ZcmWord *pWord = m->pWord;
  m->wordPos[pWord->hash0 & 0xFFFF] = (u32)pos;
  if (m->cSegment->wordCount == 0) zw_copy(&m->cSegment->firstWord, pWord);
  m->cSegment->wordCount++;
  ZcmSentence *sen = m->cSentence;
  if (sen->seg.wordCount == 0) zw_copy(&sen->seg.firstWord, pWord);
  sen->seg.wordCount++;
  m->wordLength[1] = m->wordLength[0];
  m->wordLength[0] = 0;
  m->quoteLength += B(m->quoteLength > 0);
  if (m->quoteLength > 0x1F) m->quoteLength = 0;
  sen->verbIndex++;
  sen->nounIndex++;
  sen->capitalIndex++;
  if ((pWord->type & T_VERB) != 0) {
    sen->verbIndex = 0;
    zw_copy(&sen->lastVerb, pWord);
  }
  if ((pWord->type & T_NOUN) != 0) {
    sen->nounIndex = 0;
    zw_copy(&sen->lastNoun, pWord);
  }
  if (sen->seg.wordCount > 1 && m->lastUpper < m->wordLength[1]) {
    sen->capitalIndex = 0;
    zw_copy(&sen->lastCapital, pWord);
  }
}

static void punctuation(TextModel *m, ZState *st, i64 c, i64 pC) {
  // The switch of TextModel::update with its fall throughs.
  int sentenceEnd = 0;
  int segmentEnd = 0;
  if (c == 0x2E) {
    if (m->langId != LANG_UNKNOWN && m->lastUpper == m->wordLength[1] &&
        zw_matchesAny(m->pWord, kAbbreviations, NELEM(kAbbreviations))) {
      m->state = P_WAS_ABBREVIATION;
      m->parseCtx = hash2(m->state, m->pWord->hash0);
      return;
    }
    sentenceEnd = 1;
  } else if (c == 0x3F || c == 0x21) {
    sentenceEnd = 1;
  } else if (c == 0x2C || c == 0x3B || c == 0x3A) {
    segmentEnd = 1;
  }
  if (sentenceEnd) {
    ZcmSentence *sen = m->cSentence;
    sen->type = c == 0x2E ? 0 : (c == 0x3F ? 1 : 2);
    sen->segmentCount++;
    ZcmParagraph *par = m->cParagraph;
    par->sentenceCount++;
    par->typeCount[sen->type]++;
    par->typeMask = ((par->typeMask << 2) | sen->type) & 0xFFFFFFFF;
    m->cSentence = nextSentence(m);
    madd(m, 3, 3);
  }
  if (sentenceEnd || segmentEnd) {
    if (c == 0x2C) {
      m->commas++;
      m->state = P_AFTER_COMMA;
      m->parseCtx =
          hash4(m->state, ilog2(m->quoteLength + 1), ilog2(m->lastNewLine),
                B(m->lastUpper < m->lastLetter + m->wordLength[1]));
    } else if (c == 0x3A) {
      zw_copy(&m->topicDescriptor, m->pWord);
    }
    if (!sentenceEnd) {
      m->cSentence->segmentCount++;
      madd(m, 3, 4);
    }
    m->lastPunctuation = 0;
    madd(m, 0, 3);
    madd(m, 1, 2);
    madd(m, 2, 15);
    m->cSegment = nextSegment(m);
    return;
  }
  int space = 0;
  switch (c) {
    case NEWLINE:
      m->prevNewLine = m->lastNewLine;
      m->lastNewLine = 0;
      m->commas = 0;
      if (m->prevNewLine == 1 || (m->prevNewLine == 2 && pC == CR)) {
        m->cParagraph = nextParagraph(m);
      } else if ((m->lastLetter == 2 && pC == 0x2B) ||
                 (m->lastLetter == 3 && pC == CR &&
                  zstate_back(st, 3) == 0x2B)) {
        m->parseCtx = hash2(P_READING_WORD, m->pWord->hash0);
        m->state = P_POSSIBLE_HYPHENATION;
      }
      space = 1;
      break;
    case TAB:
    case CR:
    case SPACE:
      space = 1;
      break;
    case 0x28: // (
      madd(m, 2, 1);
      madd(m, 3, 6);
      m->nestHash += 31;
      m->lastNest = 0;
      break;
    case 0x5B: // [
      madd(m, 2, 2);
      m->nestHash += 11;
      m->lastNest = 0;
      break;
    case 0x7B: // {
      madd(m, 2, 3);
      m->nestHash += 17;
      m->lastNest = 0;
      break;
    case 0x3C: // <
      madd(m, 2, 4);
      m->nestHash += 23;
      m->lastNest = 0;
      break;
    case 0xAB:
      madd(m, 2, 5);
      break;
    case 0x29: // )
      madd(m, 2, 6);
      m->nestHash -= 31;
      m->lastNest = 0;
      break;
    case 0x5D: // ]
      madd(m, 2, 7);
      m->nestHash -= 11;
      m->lastNest = 0;
      break;
    case 0x7D: // }
      madd(m, 2, 8);
      m->nestHash -= 17;
      m->lastNest = 0;
      break;
    case 0x3E: // >
      madd(m, 2, 9);
      m->nestHash -= 23;
      m->lastNest = 0;
      break;
    case 0xBB:
      madd(m, 2, 10);
      break;
    case QUOTE:
      madd(m, 2, 11);
      if (m->quoteLength == 0) {
        m->quoteLength = 1;
      } else {
        m->quoteLength = 0;
        m->state = P_AFTER_QUOTE;
        m->parseCtx = hash2(m->state, 0x100 | pC);
      }
      break;
    case 0x2F:
    case 0x2D:
    case 0x2B:
    case 0x2A:
    case 0x3D:
    case 0x25:
      madd(m, 2, 13);
      break;
    case 0x5C:
    case 0x7C:
    case 0x5F:
    case 0x40:
    case 0x26:
    case 0x5E:
      madd(m, 2, 14);
      break;
  }
  m->nestHash &= 0xFFFFFFFF;
  if (space) {
    m->spaces |= 1;
    madd(m, 1, 3);
    madd(m, 3, 5);
    if (c == SPACE && m->pState == P_WAS_ABBREVIATION) {
      m->state = P_AFTER_ABBREVIATION;
      m->parseCtx = hash2(m->state, m->pWord->hash0);
    }
  }
}

// Unsigned 64-bit comparison.
ZINLINE i64 ucmp(i64 a, i64 b) {
  u64 x = (u64)a, y = (u64)b;
  return x < y ? -1 : (x > y ? 1 : 0);
}

static void digits(TextModel *m, ZState *st, i64 c) {
  i64 *nums = m->numbers;
  i32 *nl = m->numLength;
  if (c >= 0x30 && c <= 0x39) {
    nums[0] = nums[0] * 10 + (c & 0x0F);
    nl[0] = nl[0] + 1 < 19 ? nl[0] + 1 : 19;
    m->numHashes[0] = (i32)comb(m->numHashes[0], c);
    if (nl[0] < nl[1] &&
        (m->pState == P_EXPECT_DIGIT || ((m->numDiff & 3) == 0 && nl[0] <= 1))) {
      i64 expectedNum = nums[1] + (m->numMask & 3) - 2;
      i64 placeDivisor = 1;
      for (i64 i = 0; i < (i64)nl[1] - nl[0]; i++) placeDivisor *= 10;
      // Unsigned 64-bit division (Dart _udiv).
      if ((i64)((u64)expectedNum / (u64)placeDivisor) == nums[0]) {
        m->state = P_EXPECT_DIGIT;
      }
    } else {
      i64 d = zstate_back(st, nl[0] + 2);
      if (nl[0] < 3 && zstate_back(st, nl[0] + 1) == 0x2C && d >= 0x30 &&
          d <= 0x39) {
        m->state = P_EXPECT_DIGIT;
      }
    }
    m->lastDigit = 0;
    madd(m, 3, 7);
  } else if (nums[0] != 0) {
    i64 a = nums[0], b = nums[1];
    int ge = ucmp(a, b) >= 0, gt = ucmp(a, b) > 0;
    m->numMask = ((m->numMask << 2) | (1 + B(ge) + B(gt))) & 0xFFFFFFFF;
    i64 diff = (i64)(i32)(a - b);
    if (diff < 0) diff = -diff;
    i64 ld = ilog2(diff);
    m->numDiff = ((m->numDiff << 2) | (ld < 3 ? ld : 3)) & 0xFFFFFFFF;
    nums[1] = a;
    nums[0] = 0;
    m->numHashes[1] = m->numHashes[0];
    m->numHashes[0] = 0;
    nl[1] = nl[0];
    nl[0] = 0;
    m->cSegment->numCount++;
    m->cSentence->seg.numCount++;
  }
}

// TextModel::update
static void update(TextModel *m, ZState *st) {
  m->lastUpper = m->lastUpper + 1 < 0xFF ? m->lastUpper + 1 : 0xFF;
  m->maskUpper = (m->maskUpper << 1) & 0xFFFFFFFF;
  m->lastLetter = m->lastLetter + 1 < 0x1F ? m->lastLetter + 1 : 0x1F;
  m->lastDigit = m->lastDigit + 1 < 0xFF ? m->lastDigit + 1 : 0xFF;
  m->lastPunctuation =
      m->lastPunctuation + 1 < 0x3F ? m->lastPunctuation + 1 : 0x3F;
  m->lastNewLine = (m->lastNewLine + 1) & 0xFFFFFFFF;
  m->prevNewLine = (m->prevNewLine + 1) & 0xFFFFFFFF;
  m->lastNest = (m->lastNest + 1) & 0xFFFFFFFF;
  m->spaces = (m->spaces << 1) & 0xFFFFFFFF;
  mshl(m, 0, 2);
  mshl(m, 1, 2);
  mshl(m, 2, 4);
  mshl(m, 3, 3);
  m->pState = m->state;

  i64 c = st->c4 & 255;
  i64 lc = lower(c);
  i64 g = c < 0x80 ? kAsciiGroup[c] : 31;
  if (g > 4 || g != (m->masks[4] & 0x1F)) {
    m->masks[4] = (i32)(shl(m->masks[4], 5) | g);
  }
  i64 pos = st->pos;
  m->bytePos[c] = (u32)pos;
  if (c != lc) {
    c = lc;
    m->lastUpper = 0;
    m->maskUpper |= 1;
  }
  i64 pC = zstate_back(st, 2);
  m->state = P_UNKNOWN;
  m->parseCtx = hash4(
      m->state, m->pWord->hash0, c,
      hash2((ilog2(m->lastNewLine) + 1) * B(m->lastNewLine * 3 > m->prevNewLine),
            m->masks[1] & 0xFC));

  if ((c >= 0x61 && c <= 0x7A) || c == APOSTROPHE || c == 0x2D || c > 0x7F) {
    if (m->wordLength[0] == 0) {
      // Hyphenation with "+" (book1 of the Calgary corpus).
      if (pC == NEWLINE &&
          ((m->lastLetter == 3 && zstate_back(st, 3) == 0x2B) ||
           (m->lastLetter == 4 && zstate_back(st, 3) == CR &&
            zstate_back(st, 4) == 0x2B))) {
        m->wordLength[0] = m->wordLength[1];
        for (i64 i = LANG_UNKNOWN; i < LANG_COUNT; i++) m->wordsIndex[i]--;
        m->cWord = m->pWord;
        m->pWord = wordAt(m, m->langPId, 1);
        zw_reset(m->cWord);
        for (i64 i = 0; i < m->wordLength[0]; i++) {
          zw_add(m->cWord, zstate_back(st, m->wordLength[0] - i + m->lastLetter));
        }
        m->wordLength[1] = (i32)zw_length(m->pWord);
        m->cSegment->wordCount--;
        m->cSentence->seg.wordCount--;
      } else {
        m->wordGap = m->lastLetter;
        m->firstLetter = c;
      }
    }
    m->lastLetter = 0;
    m->wordLength[0]++;
    madd(m, 0, m->langId != LANG_UNKNOWN ? 1 + B(isVowel(c)) : 1);
    madd(m, 1, 1);
    madd(m, 3, m->masks[0] & 3);
    if (c == APOSTROPHE) {
      madd(m, 2, 12);
      if (m->wordLength[0] == 1) {
        if (m->quoteLength == 0 && pC == SPACE) {
          m->quoteLength = 1;
        } else if (m->quoteLength > 0 && m->lastPunctuation == 1) {
          m->quoteLength = 0;
          m->state = P_AFTER_QUOTE;
          m->parseCtx = hash2(m->state, pC);
        }
      }
    }
    zw_add(m->cWord, c);
    zw_calculateWordHash(m->cWord);
    m->state = P_READING_WORD;
    m->parseCtx = hash2(m->state, m->cWord->hash0);
  } else {
    if (zw_length(m->cWord) > 0) endWord(m, pos);
    punctuation(m, st, c, pC);
    digits(m, st, c);
  }
  if (m->lastNewLine == 1) {
    m->firstChar = m->langId != LANG_UNKNOWN ? c : (c < 96 ? c : 96);
  }
  if (m->lastNest > 512) m->nestHash = 0;
  i64 leadingBitsSet = 0;
  while (leadingBitsSet < 8 && ((c >> (7 - leadingBitsSet)) & 1) != 0) {
    leadingBitsSet++;
  }
  if (m->utf8Remaining > 0 && leadingBitsSet == 1) {
    m->utf8Remaining--;
  } else {
    m->utf8Remaining =
        leadingBitsSet != 1
            ? ((c != 0xC0 && c != 0xC1 && c < 0xF5)
                   ? leadingBitsSet - B(leadingBitsSet > 0)
                   : -1)
            : 0;
  }
  const u32 *bp = m->bytePos;
  u32 comma = bp[0x2C];
  m->maskPunctuation = B(comma > bp[0x2E]) | (B(comma > bp[0x21]) << 1) |
                       (B(comma > bp[0x3F]) << 2) | (B(comma > bp[0x3A]) << 3) |
                       (B(comma > bp[0x3B]) << 4);
}

ZINLINE void put(TextModel *m, i64 k, i64 h) {
  i64 j = m->slot[k];
  if (j >= 0) contextmap_set(&m->cm, j, h);
}

// TextModel::setContexts
static void setContexts(TextModel *m, ZState *st) {
  i64 c = st->c4 & 255;
  i64 lc = lower(c);
  const i32 *masks = m->masks;
  i64 m2 = masks[2] & 0x0F;
  i64 column = m->lastNewLine < 0xFF ? m->lastNewLine : 0xFF;
  ZcmWord *cWord = m->cWord, *pWord = m->pWord;
  i64 w = m->state == P_READING_WORD ? cWord->hash0 : pWord->hash0;
  i64 cWordHash0 = cWord->hash0;
  i64 pWordHash0 = pWord->hash0;
  i64 pWordHash1 = pWord->hash1;
  i64 wl0 = m->wordLength[0], wl1 = m->wordLength[1];
  i64 lang = m->langPId;
  ZcmSegment *seg = m->cSegment;
  ZcmSentence *sen = m->cSentence;
  i64 lastUpper = m->lastUpper, lastLetter = m->lastLetter;
  i64 lastDigit = m->lastDigit, wordGap = m->wordGap;
  i64 i = m->state * 64;
  i64 k = 0;
  put(m, k++, m->parseCtx);
  put(m, k++,
      hash4(++i, cWordHash0, pWordHash0,
            B(lastUpper < wl0) | (B(lastDigit < wl0 + wordGap) << 1)));
  i64 nl = ilog2(m->numbers[0] & 0xFFFFFFFF);
  put(m, k++,
      hash4(hash2(++i, cWordHash0), wordAt(m, lang, 2)->hash0, nl < 10 ? nl : 10,
            B(lastUpper < lastLetter + wl1) | (B(lastLetter > 3) << 1) |
                (B(lastLetter > 0 && wl1 < 3) << 2)));
  put(m, k++,
      hash4(hash2(++i, cWordHash0), masks[1] & 0x3FF,
            wordAt(m, lang, 3)->hash1,
            B(lastDigit < wl0 + wordGap) |
                (B(lastUpper < lastLetter + wl1) << 1) |
                ((m->spaces & 0x7F) << 2)));
  put(m, k++, hash3(++i, cWordHash0, pWordHash1));
  put(m, k++, hash4(++i, cWordHash0, pWordHash1, wordAt(m, lang, 2)->hash1));
  put(m, k++,
      hash4(++i, w, wordAt(m, lang, 2)->hash0, wordAt(m, lang, 3)->hash0));
  put(m, k++,
      hash4(++i, cWordHash0, c,
            sen->verbIndex < sen->seg.wordCount ? sen->lastVerb.hash0 : 0));
  put(m, k++, hash4(hash2(++i, pWordHash1), masks[1] & 0xFC, lc, wordGap));
  i64 swc = ilog2(seg->wordCount + 1);
  put(m, k++,
      hash4(hash2(++i, lastLetter == 0 ? cWordHash0 : pWordHash0), c,
            seg->firstWord.hash1, swc < 3 ? swc : 3));
  put(m, k++, hash4(++i, cWordHash0, c, segmentAt(m, 1)->firstWord.hash1));
  put(m, k++,
      hash4(hash2(++i, lc > 31 ? lc : 31), masks[1] & 0xFFC,
            (m->spaces & 0xFE) | B(m->lastPunctuation < lastLetter),
            (m->maskUpper & 0xFF) |
                (((0x100 | m->firstLetter) * B(wl0 > 1)) << 8)));
  i64 lu = ilog2(lastUpper + 1);
  put(m, k++,
      hash4(++i, column, lu < 7 ? lu : 7, ilog2(m->lastPunctuation + 1)));
  put(m, k++,
      hash2(++i, (column & 0xF8) | (masks[1] & 3) |
                     (B(m->prevNewLine - m->lastNewLine > 63) << 2) |
                     ((lastLetter < 3 ? lastLetter : 3) << 8) |
                     (m->firstChar << 10) | (B(m->commas > 4) << 18) |
                     (B(m2 >= 1 && m2 <= 5) << 19) |
                     (B(m2 >= 6 && m2 <= 10) << 20) |
                     (B(m2 == 11 || m2 == 12) << 21) |
                     (B(lastUpper < column) << 22) |
                     (B(lastDigit < column) << 23) |
                     (B(column < m->prevNewLine - m->lastNewLine) << 24)));
  i64 lp = m->lastPunctuation;
  put(m, k++,
      hash4(hash2(++i, (2 * column) / 3),
            (lp < 13 ? lp : 13) + B(lp > 16) + B(lp > 32) +
                m->maskPunctuation * 16,
            ilog2(lastUpper + 1),
            hash2(ilog2(m->prevNewLine - m->lastNewLine),
                  B((masks[1] & 3) == 0) | (B(m2 < 6) << 1) |
                      (B(m2 < 11) << 2))));
  put(m, k++, hash3(++i, column >> 1, m->spaces & 0x0F));
  i64 wlq = wl0 < 8 ? ((wl0 > 3 ? wl0 : 3) - 2) : 0;
  put(m, k++,
      hash4(hash2(++i, masks[3] & 0x3F),
            hash2(wlq < 3 ? wlq : 3, m->firstLetter * B(wl0 < 5)), w,
            B(c == zstate_back(st, 2)) | (B(masks[2] != 0) << 1) |
                (B(lp < wl0 + wordGap) << 2) | (B(lastUpper < wl0) << 3) |
                (B(lastDigit < wl0 + wordGap) << 4) |
                (B(lp < 2 + wl0 + wordGap + wl1) << 5)));
  put(m, k++, hash4(++i, w, c, m->numHashes[1]));
  i64 pos = st->pos;
  put(m, k++,
      hash4(++i, w, c,
            zcmLlog((pos - (i64)m->wordPos[w & 0xFFFF]) & 0xFFFFFFFF) >> 1));
  put(m, k++, hash4(++i, w, c, m->topicDescriptor.hash0));
  put(m, k++, hash4(++i, m->numLength[0], c, m->topicDescriptor.hash0));
  put(m, k++,
      hash4(++i, lastLetter > 0 ? c : 0x100, masks[1] & 0xFFC,
            m->nestHash & 0x7FF));
  put(m, k++,
      hash4(hash2(++i, w), c, masks[3] & 0x1FF,
            (B(sen->verbIndex == 0 && zw_length(&sen->lastVerb) > 0) << 6) |
                (B(wl1 > 3) << 5) | (B(seg->wordCount == 0) << 4) |
                (B(sen->segmentCount == 0 && sen->seg.wordCount < 2) << 3) |
                (B(lp >= lastLetter + wl1 + wordGap) << 2) |
                (B(lastUpper < lastLetter + wl1) << 1) |
                B(lastUpper < wl0 + wordGap + wl1)));
  put(m, k++,
      hash4(hash2(++i, c), pWordHash1, m->firstLetter * B(wl0 < 6),
            (B(lp < wl0 + wordGap) << 1) |
                B(lp >= lastLetter + wl1 + wordGap)));
  ZcmWord *ww = wordAt(m, lang, 1 + B(wl0 == 0));
  put(m, k++,
      hash4(hash2(++i, w), c, ww->letters[ww->start],
            m->firstLetter * B(wl0 < 7)));
  put(m, k++, hash4(++i, column, m->spaces & 7, m->nestHash & 0x7FF));
  put(m, k++,
      hash4(++i, cWordHash0, B(lastUpper < column) | (B(lastUpper < wl0) << 1),
            wl0 < 5 ? wl0 : 5));
  put(m, k++,
      hash4(hash2(++i, m->langId), w, 0,
            B(lastUpper < wl0) | (B(seg->wordCount == 0) << 1)));
}

static void text_mix(ZModel *self, ZState *s, Mixer *mx) {
  TextModel *m = (TextModel *)self;
  if (s->bpos == 0) {
    update(m, s);
    setContexts(m, s);
  }
  contextmap_mix(&m->cm, mx, s->y, s->bpos, s->c0, s->c4 & 255);
  i64 o = m->cm.hits - (m->cm.nCtx - 15);
  m->order = o < 0 ? 0 : o;
}

static void text_setCtx(ZModel *self, ZState *s, Mixer *mx) {
  TextModel *m = (TextModel *)self;
  i64 bpos = s->bpos;
  i64 c0 = s->c0;
  i64 c1 = s->c4 & 255;
  const i32 *masks = m->masks;
  i64 wl0 = m->wordLength[0], wl1 = m->wordLength[1];
  i64 lu = m->lastUpper, ll = m->lastLetter, lp = m->lastPunctuation;
  i64 wordGap = m->wordGap;
  i64 g = zcmCharacterGroup(c0, bpos);
  i64 n = m->mixerSets;
  if (n >= 1) mixer_set(mx, (m->order << 3) | bpos);
  if (n >= 2) {
    mixer_set(mx, hash3(m->langId != LANG_UNKNOWN ? 1 + B(isVowel(c1)) : 0,
                        masks[1] & 0xFF, c0) >>
                      21);
  }
  if (n >= 3) {
    i64 il = ilog2(wl0 + 1);
    mixer_set(mx, hash3(il, c0,
                        B(m->lastDigit < wl0 + wordGap) |
                            (B(lu < ll + wl1) << 1) |
                            (B(lp < wl0 + wordGap) << 2) | (B(lu < wl0) << 3)) >>
                      21);
  }
  if (n >= 4) {
    mixer_set(mx,
              hash4(masks[1] & 0x3FF, g, B(lu < wl0), B(lu < ll + wl1)) >> 20);
  }
  if (n >= 5) {
    mixer_set(mx, hash3(m->spaces & 0x1FF, g,
                        B(lu < wl0) | (B(lu < ll + wl1) << 1) |
                            (B(lp < ll) << 2) | (B(lp < wl0 + wordGap) << 3) |
                            (B(lp < ll + wl1 + wordGap) << 4)) >>
                      20);
  }
  if (n >= 6) {
    mixer_set(mx, hash3(m->firstLetter * B(wl0 < 4), wl0 < 6 ? wl0 : 6, c0) >>
                      21);
  }
  if (n >= 7) {
    ZcmWord *p = m->pWord;
    mixer_set(mx, hash4(zw_at(p, 0), zw_back(p, 0), wl0 < 4 ? wl0 : 4,
                        B(lp < ll)) >>
                      21);
  }
  if (n >= 8) {
    mixer_set(mx, hash4(wl0 < 4 ? wl0 : 4, g, B(lu < wl0),
                        m->nestHash > 0
                            ? (m->nestHash & 0xFF)
                            : (0x100 | (m->firstLetter * B(wl0 > 0 && wl0 < 4)))) >>
                      20);
  }
  if (n >= 9) {
    mixer_set(mx, hash3(g, masks[4] & 0x1F, (masks[4] >> 5) & 0x1F) >> 19);
  }
  if (n >= 10) mixer_set(mx, hash4(g, 0, m->langId, m->state) >> 21);
}

void textmodel_init(TextModel *m, i64 bytes, i64 mixerSets,
                    const i64 *contexts, i64 ncontexts) {
  memset(m, 0, sizeof(*m));
  contextmap_init(&m->cm, bytes, contexts == NULL ? TEXT_NCM : ncontexts, 0, 1);
  m->mixerSets = mixerSets;
  if (contexts == NULL) {
    for (i64 i = 0; i < TEXT_NCM; i++) m->slot[i] = (i8)i;
  } else {
    for (i64 i = 0; i < TEXT_NCM; i++) m->slot[i] = -1;
    for (i64 i = 0; i < ncontexts; i++) m->slot[contexts[i]] = (i8)i;
  }
  m->wordPos = ZNEW(u32, 0x10000);
  m->state = m->pState = P_UNKNOWN;
  m->langId = m->langPId = LANG_UNKNOWN;
  m->cWord = wordAt(m, m->langId, 0);
  m->pWord = wordAt(m, m->langId, 1);
  m->cSegment = segmentAt(m, 0);
  m->cSentence = sentenceAt(m, 0);
  m->cParagraph = paragraphAt(m, 0);
  m->base.inputs = m->cm.nCtx * contextmap_inputsPerContext(&m->cm);
  m->base.mix = text_mix;
  m->base.nsel = mixerSets;
  m->base.selSizes = kSetSizes;
  m->base.setCtx = text_setCtx;
}
