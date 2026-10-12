// zxsfx decoder: port of the decoding direction of zcm_dict.dart.
//
// The word replacement preprocessor of cmix (Byron Knoll,
// src/preprocess/dictionary.cpp), with its dictionary english.dic (44,515
// words ordered by frequency, the first 80 coded in one byte, the next
// 3,840 in two, the rest in three): words of lowercase letters become
// their codes, a capitalized word gets a 0x40 prefix, an all uppercase
// word 0x07 (and 0x06 when lowercase letters follow it directly), and
// bytes that collide with the codes or flags are escaped with 0x0C.
//
// The word list is stored as a raw LZMA stream (zc_dict_words.c)
// and unpacked on first use.

#include "zc_dict.h"
#include "lzma/LzmaDec.h"

#define K_CAPITALIZED 0x40
#define K_UPPERCASE 0x07
#define K_END_UPPER 0x06
#define K_ESCAPE 0x0C
#define K_QUOTE 0x08
static const u8 kQuoteStr[6] = {0x26, 0x71, 0x75, 0x6F, 0x74, 0x3B}; // &quot;

#define B1 80
#define B2 (B1 + 3840)
#define B3 (B2 + 40960)

// _Dict (the decoding part: the words and their offsets).
static struct {
  u8 *raw;
  i64 rawLen;
  i32 *start; // offset of word i in raw; start[n] is the end
  i64 n;
} g_dict;

static int isLower(i64 c) { return c >= 0x61 && c <= 0x7A; }

static void *dict_alloc(ISzAllocPtr p, size_t n) {
  (void)p;
  return zalloc(n);
}
static void dict_free(ISzAllocPtr p, void *a) {
  (void)p;
  (void)a;
}
static const ISzAlloc g_dictAlloc = {dict_alloc, dict_free};

void zdict_load(void) {
  if (g_dict.raw != NULL) return;
  // The words: LZMA decoding of zdictWords.
  i64 rawLen = zdictWordsRawLen;
  u8 *raw = ZNEW(u8, rawLen);
  size_t mark = zmark();
  {
    SizeT dl = (SizeT)rawLen, sl = (SizeT)zdictWordsLen;
    ELzmaStatus st;
    if (LzmaDecode(raw, &dl, zdictWords, &sl, zdictWordsProps, 5,
                   LZMA_FINISH_END, &st, &g_dictAlloc) != SZ_OK ||
        dl != (SizeT)rawLen) {
      zfatal("damaged dictionary");
    }
  }
  zrelease(mark);
  // Count the words, then their offsets.
  i64 count = 0;
  for (i64 i = 0; i < rawLen;) {
    i64 j = i;
    while (j < rawLen && isLower(raw[j])) j++;
    if (j > i) count++;
    i = j + 1;
  }
  i64 n = count;
  if (n > B3) n = B3;
  i32 *start = ZNEW(i32, n + 1);
  i64 k = 0;
  for (i64 i = 0; i < rawLen && k < n;) {
    i64 j = i;
    while (j < rawLen && isLower(raw[j])) j++;
    if (j > i) start[k++] = (i32)i;
    i = j + 1;
  }
  // The end of the last word, for its length.
  i64 e = start[n - 1];
  while (e < rawLen && isLower(raw[e])) e++;
  start[n] = (i32)e;
  g_dict.raw = raw;
  g_dict.rawLen = rawLen;
  g_dict.start = start;
  g_dict.n = n;
}

static i64 dict_length(i64 k) {
  i64 e = g_dict.start[k];
  i64 s = e;
  while (e < g_dict.rawLen && isLower(g_dict.raw[e])) e++;
  return e - s;
}

// The word number of a code, or -1 ([b0] first; [b1], [b2] as read).
static i64 dict_wordOf(i64 b0, i64 b1, i64 b2) {
  i64 k;
  if (b0 < 0xD0) {
    k = b0 - 0x80;
  } else if (b1 < 0xD0) {
    if (b1 < 0x80) return -1;
    k = B1 + (b0 - 0xD0) * 80 + (b1 - 0x80);
  } else {
    if (b0 < 0xF0 || b2 < 0x80 || b2 >= 0xD0) return -1;
    k = B2 + ((b0 - 0xF0) * 32 + (b1 - 0xD0)) * 80 + (b2 - 0x80);
  }
  return k >= 0 && k < g_dict.n ? k : -1;
}

// Inverse of zcmDictTransform (Dictionary::Decode).
int zdict_decode(const u8 *t, i64 tl, u8 *out, i64 len) {
  zdict_load();
  const u8 *raw = g_dict.raw;
  int upper = 0, capital = 0;
  i64 i = 0;
  i64 end = len;
  i64 p = 0;
  while (i < tl) {
    i64 c = t[i++];
    if (c == K_ESCAPE) {
      upper = 0;
      if (i >= tl || p >= end) return 0;
      out[p++] = t[i++];
    } else if (c == K_QUOTE) {
      if (p + 5 > end) return 0;
      for (i64 k = 1; k < 6; k++) out[p++] = kQuoteStr[k];
    } else if (c == K_UPPERCASE) {
      upper = 1;
    } else if (c == K_CAPITALIZED) {
      capital = 1;
    } else if (c == K_END_UPPER) {
      upper = 0;
    } else if (c >= 0x80) {
      i64 b1 = 0, b2 = 0;
      if (c > 0xCF) {
        if (i >= tl) return 0;
        b1 = t[i++];
        if (b1 > 0xCF) {
          if (i >= tl) return 0;
          b2 = t[i++];
        }
      }
      i64 k = dict_wordOf(c, b1, b2);
      if (k < 0) return 0;
      i64 s = g_dict.start[k];
      i64 wl = dict_length(k);
      if (p + wl > end) return 0;
      for (i64 j = 0; j < wl; j++) {
        i64 ch = raw[s + j];
        if (j == 0 && capital) {
          ch -= 32;
          capital = 0;
        }
        if (upper) ch = ch - 0x61 + 0x41;
        out[p++] = (u8)ch;
      }
    } else {
      if (!((c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A))) {
        upper = 0;
      }
      if (capital || upper) c = (c - 0x61 + 0x41) & 0xFF;
      capital = 0;
      if (p >= end) return 0;
      out[p++] = (u8)c;
    }
  }
  return p == len;
}
