// zxsfx decoder: port of the decoding direction of zcm_dict.dart, the
// English dictionary transform of text segments (the word replacement
// preprocessor of cmix by Byron Knoll, src/preprocess/dictionary.cpp,
// with its dictionary english.dic).

#ifndef ZC_DICT_H
#define ZC_DICT_H

#include "zc.h"

// Unpacks the dictionary (zc_dict_words.c, a raw LZMA stream) into the
// arena, once (about 600 KB kept for the rest of the run). zdict_decode
// calls it
// when needed; call it before a zmark() whose zrelease() would otherwise
// free the dictionary.
void zdict_load(void);

// zcmDictDecode: writes the text of the transform [t] ([tl] bytes) to
// [out]; returns 0 when it does not give exactly [len] bytes or [t] is
// not a valid transform, 1 otherwise.
int zdict_decode(const u8 *t, i64 tl, u8 *out, i64 len);

// The packed word list (zc_dict_words.c, generated).
extern const i64 zdictWordsRawLen;
extern const u8 zdictWordsProps[5];
extern const i64 zdictWordsLen;
extern const u8 zdictWords[];

#endif
