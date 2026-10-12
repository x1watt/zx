// zxsfx decoder: the libc declarations the vendored C code includes, for
// the freestanding wasm build (zc_core.c defines the functions).
#ifndef ZXSFX_STRING_H
#define ZXSFX_STRING_H
#include <stddef.h>
void *memcpy(void *d, const void *s, size_t n);
void *memmove(void *d, const void *s, size_t n);
void *memset(void *d, int c, size_t n);
int memcmp(const void *a, const void *b, size_t n);
size_t strlen(const char *s);
#endif
