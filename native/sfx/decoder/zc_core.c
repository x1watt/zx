// zxsfx decoder: the runtime (memory, the few libc functions), and the
// port of zcm_tables.dart, zcm_state_table.dart, zcm_math.dart,
// zcm_components.dart and the decoder of zcm_coder.dart. The designs and
// credits are in those files (paq8, lpaq1 by Matt Mahoney; paq8px by
// Zoltan Gotthardt, Marcio Pais and others).

#include "host.h"
#include "zc.h"

// ---------------------------------------------------------------- libc

#ifdef __wasm__
void *memcpy(void *d, const void *s, size_t n) {
  return __builtin_memcpy(d, s, n);
}
void *memmove(void *d, const void *s, size_t n) {
  return __builtin_memmove(d, s, n);
}
void *memset(void *d, int c, size_t n) { return __builtin_memset(d, c, n); }
int memcmp(const void *a, const void *b, size_t n) {
  const u8 *x = a, *y = b;
  for (size_t i = 0; i < n; i++) {
    if (x[i] != y[i]) return x[i] < y[i] ? -1 : 1;
  }
  return 0;
}
size_t strlen(const char *s) {
  size_t n = 0;
  while (s[n]) n++;
  return n;
}
#endif

void zfatal(const char *msg) {
  host_write(2, "zx sfx: ", 8);
  host_write(2, msg, (int)strlen(msg));
  host_write(2, "\n", 1);
  host_exit(2);
}

// ---------------------------------------------------------------- arena

#ifdef __wasm__
extern unsigned char __heap_base;
static size_t g_top;   // next free byte
static size_t g_fresh; // bytes from here on were never handed out (zero)
static size_t g_end;   // end of the linear memory

void *zalloc(size_t n) {
  if (g_top == 0) {
    g_top = g_fresh = ((size_t)&__heap_base + 15) & ~(size_t)15;
    g_end = __builtin_wasm_memory_size(0) * 65536;
  }
  size_t a = g_top;
  n = (n + 15) & ~(size_t)15;
  if (n > (size_t)0xFFFFFFF0 - a) zfatal("out of memory");
  size_t e = a + n;
  if (e > g_end) {
    size_t pages = (e - g_end + 65535) / 65536;
    if (__builtin_wasm_memory_grow(0, pages) == (size_t)-1) {
      zfatal("out of memory");
    }
    g_end += pages * 65536;
  }
  if (a < g_fresh) memset((void *)a, 0, (e < g_fresh ? e : g_fresh) - a);
  if (e > g_fresh) g_fresh = e;
  g_top = e;
  return (void *)a;
}
size_t zmark(void) {
  if (g_top == 0) zalloc(0);
  return g_top;
}
void zrelease(size_t mark) { g_top = mark; }
#else
#include <sys/mman.h>
static unsigned char *g_base;
static size_t g_top, g_fresh;
static const size_t g_cap = (size_t)6 << 30;

void *zalloc(size_t n) {
  if (!g_base) {
    g_base = mmap(0, g_cap, PROT_READ | PROT_WRITE,
                  MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    if (g_base == MAP_FAILED) zfatal("out of memory");
  }
  n = (n + 15) & ~(size_t)15;
  size_t a = g_top, e = a + n;
  if (e > g_cap) zfatal("out of memory");
  if (a < g_fresh) memset(g_base + a, 0, (e < g_fresh ? e : g_fresh) - a);
  if (e > g_fresh) g_fresh = e;
  g_top = e;
  return g_base + a;
}
size_t zmark(void) { return g_top; }
void zrelease(size_t mark) { g_top = mark; }
#endif

// ---------------------------------------------------------------- math

static const double ln2Hi = 6.93147180369123816490e-01;
static const double ln2Lo = 1.90821492927058770002e-10;
static const double invLn2 = 1.44269504088896338700e+00;
static double g_pow2[2046];
static int g_pow2Ready;

static void pow2Init(void) {
  double v = 1.0;
  for (int k = 0; k <= 1023; k++) {
    g_pow2[k + 1022] = v;
    v = v * 2.0;
  }
  v = 1.0;
  for (int k = 0; k >= -1022; k--) {
    g_pow2[k + 1022] = v;
    v = v * 0.5;
  }
  g_pow2Ready = 1;
}

double zexp(double x) {
  if (x > 700.0) return 1e300;
  if (x < -700.0) return 0.0;
  if (!g_pow2Ready) pow2Init();
  double kf = (x * invLn2 + (x >= 0 ? 0.5 : -0.5));
  i64 k = (i64)kf;
  double r = (x - (double)k * ln2Hi) - (double)k * ln2Lo;
  double s = 1.0 / 6227020800.0;
  s = s * r + 1.0 / 479001600.0;
  s = s * r + 1.0 / 39916800.0;
  s = s * r + 1.0 / 3628800.0;
  s = s * r + 1.0 / 362880.0;
  s = s * r + 1.0 / 40320.0;
  s = s * r + 1.0 / 5040.0;
  s = s * r + 1.0 / 720.0;
  s = s * r + 1.0 / 120.0;
  s = s * r + 1.0 / 24.0;
  s = s * r + 1.0 / 6.0;
  s = s * r + 0.5;
  s = s * r + 1.0;
  s = s * r + 1.0;
  return s * g_pow2[k + 1022];
}

double zsigmoid(double x) { return 1.0 / (1.0 + zexp(-x)); }

double ztanh(double x) {
  if (x > 20.0) return 1.0;
  if (x < -20.0) return -1.0;
  if (x > -0.0001 && x < 0.0001) return x;
  double e = zexp(2.0 * x);
  return (e - 1.0) / (e + 1.0);
}

double zsqrt(double x) {
  if (x <= 0.0) return 0.0;
  double m = x, scale = 1.0;
  while (m >= 4.0) {
    m *= 0.25;
    scale *= 2.0;
  }
  while (m < 1.0) {
    m *= 4.0;
    scale *= 0.5;
  }
  double r = 1.5;
  for (int i = 0; i < 6; i++) r = 0.5 * (r + m / r);
  return r * scale;
}

double dabs(double x) { return x < 0 ? -x : x; }

i64 dfloor(double x) {
  i64 t = (i64)x;
  return ((double)t > x) ? t - 1 : t;
}

// Dart's round(): to the nearest integer, halves away from zero.
i64 dround(double x) {
  if (x >= 0) {
    i64 t = (i64)x;
    return (x - (double)t >= 0.5) ? t + 1 : t;
  }
  i64 t = (i64)x;
  return ((double)t - x >= 0.5) ? t - 1 : t;
}

// ---------------------------------------------------------------- tables

i16 kSquash[4096];
i16 kStretch[4096];
i32 kDt[1024];
u8 kIlog[65536];

static i64 squashCalc(i64 d) {
  static const int t[33] = {1,    2,    3,    6,    10,   16,   27,
                            45,   73,   120,  194,  310,  488,  747,
                            1101, 1546, 2047, 2549, 2994, 3348, 3607,
                            3785, 3901, 3975, 4024, 4050, 4068, 4079,
                            4085, 4089, 4092, 4093, 4094};
  if (d > 2047) return 4095;
  if (d < -2047) return 0;
  i64 w = d & 127;
  i64 i = (d >> 7) + 16;
  return (t[i] * (128 - w) + t[i + 1] * w + 64) >> 7;
}

void zc_tables_init(void) {
  static int ready;
  if (ready) return;
  ready = 1;
  for (int i = 0; i < 4096; i++) kSquash[i] = (i16)squashCalc(i - 2048);
  i64 pi = 0;
  for (i64 x = -2047; x <= 2047; x++) {
    i64 v = squashCalc(x);
    for (i64 i = pi; i <= v; i++) kStretch[i] = (i16)x;
    pi = v + 1;
  }
  for (i64 i = pi; i < 4096; i++) kStretch[i] = 2047;
  for (i64 n = 0; n < 1024; n++) kDt[n] = (i32)(((i64)1 << 31) / (2 * n + 3));
  i64 x = 14155776;
  for (i64 i = 2; i < 65536; i++) {
    x += 774541002 / (i * 2 - 1);
    kIlog[i] = (u8)(x >> 24);
  }
}

i64 floorPow2(i64 x) {
  i64 p = 1;
  while (p * 2 <= x) p *= 2;
  return p;
}

i64 log2Exact(i64 x) {
  i64 n = 0;
  while (((i64)1 << n) < x) n++;
  return n;
}

i64 zcmHashBitsFor(i64 bytes, i64 entryBytes) {
  i64 b = 10;
  while (b < 22 && (entryBytes << (b + 1)) <= bytes) b++;
  return b;
}

const u8 kNex[512] = {
    1,   3,   4,   7,   8,   9,   11,  15,  16,  17,  18,  20,  21,  22,  26,
    31,  32,  32,  32,  32,  34,  34,  34,  34,  34,  34,  36,  36,  36,  36,
    38,  41,  42,  42,  44,  44,  46,  46,  48,  48,  50,  53,  54,  54,  56,
    56,  58,  58,  60,  60,  62,  62,  50,  67,  68,  68,  70,  70,  72,  72,
    74,  74,  76,  76,  62,  62,  64,  83,  84,  84,  86,  86,  44,  44,  58,
    58,  60,  60,  76,  76,  78,  78,  80,  93,  94,  94,  96,  96,  48,  48,
    88,  88,  80,  103, 104, 104, 106, 106, 62,  62,  88,  88,  80,  113, 114,
    114, 116, 116, 62,  62,  88,  88,  90,  123, 124, 124, 126, 126, 62,  62,
    98,  98,  90,  133, 134, 134, 136, 136, 62,  62,  98,  98,  90,  143, 144,
    144, 68,  68,  62,  62,  98,  98,  100, 149, 150, 150, 108, 108, 100, 153,
    154, 80,  100, 157, 158, 80,  100, 161, 162, 80,  100, 165, 166, 80,  100,
    169, 170, 80,  100, 173, 174, 80,  100, 177, 178, 80,  100, 181, 182, 80,
    100, 185, 186, 80,  100, 189, 190, 80,  100, 193, 194, 80,  100, 197, 198,
    80,  100, 201, 202, 80,  100, 205, 206, 80,  100, 209, 210, 80,  100, 213,
    214, 80,  100, 217, 218, 80,  100, 221, 222, 80,  100, 225, 226, 80,  100,
    229, 230, 80,  100, 233, 234, 80,  100, 237, 238, 80,  100, 241, 242, 80,
    100, 245, 246, 80,  100, 249, 250, 80,  100, 249, 250, 80,  100, 1,   1,
    1,   2,   5,   6,   10,  12,  13,  14,  19,  23,  24,  25,  27,  28,  29,
    30,  33,  35,  35,  35,  35,  37,  37,  37,  37,  37,  37,  39,  39,  39,
    39,  40,  43,  45,  45,  47,  47,  49,  49,  51,  51,  52,  43,  57,  57,
    59,  59,  61,  61,  63,  63,  65,  65,  66,  55,  57,  57,  73,  73,  75,
    75,  77,  77,  79,  79,  81,  81,  82,  69,  71,  71,  73,  73,  59,  59,
    61,  61,  49,  49,  89,  89,  91,  91,  92,  69,  87,  87,  45,  45,  99,
    99,  101, 101, 102, 69,  87,  87,  57,  57,  109, 109, 111, 111, 112, 85,
    87,  87,  57,  57,  119, 119, 121, 121, 122, 85,  97,  97,  57,  57,  129,
    129, 131, 131, 132, 85,  97,  97,  57,  57,  139, 139, 141, 141, 142, 95,
    97,  97,  57,  57,  81,  81,  147, 147, 148, 95,  107, 107, 151, 151, 152,
    95,  69,  155, 156, 95,  69,  159, 160, 95,  69,  163, 164, 95,  69,  167,
    168, 95,  69,  171, 172, 95,  69,  175, 176, 95,  69,  179, 180, 95,  69,
    183, 184, 95,  69,  187, 188, 95,  69,  191, 192, 95,  69,  195, 196, 95,
    69,  199, 200, 95,  69,  203, 204, 95,  69,  207, 208, 95,  69,  211, 212,
    95,  69,  215, 216, 95,  69,  219, 220, 95,  69,  223, 224, 95,  69,  227,
    228, 95,  69,  231, 232, 95,  69,  235, 236, 95,  69,  239, 240, 95,  69,
    243, 244, 95,  69,  247, 248, 95,  69,  251, 252, 95,  69,  251, 252, 2,
    2,   2,
};

const u8 kStateN0[256] = {
    0,  1,  0,  2,  1,  1,  0,  3,  2,  2,  2,  1,  1,  1,  0,  4,  3,  3,
    3,  3,  2,  2,  2,  2,  2,  2,  1,  1,  1,  1,  0,  5,  4,  4,  3,  3,
    2,  2,  1,  1,  0,  6,  5,  5,  4,  4,  3,  3,  2,  2,  1,  1,  0,  7,
    6,  6,  5,  5,  4,  4,  3,  3,  2,  2,  1,  1,  0,  8,  7,  7,  6,  6,
    5,  5,  4,  4,  3,  3,  2,  2,  1,  1,  0,  9,  8,  8,  7,  7,  2,  2,
    1,  1,  0,  10, 9,  9,  8,  8,  2,  2,  1,  1,  0,  11, 10, 10, 9,  9,
    2,  2,  1,  1,  0,  12, 11, 11, 10, 10, 2,  2,  1,  1,  0,  13, 12, 12,
    11, 11, 2,  2,  1,  1,  0,  14, 13, 13, 12, 12, 2,  2,  1,  1,  0,  15,
    14, 14, 1,  1,  0,  16, 15, 1,  0,  17, 16, 1,  0,  18, 17, 1,  0,  19,
    18, 1,  0,  20, 19, 1,  0,  21, 20, 1,  0,  22, 21, 1,  0,  23, 22, 1,
    0,  24, 23, 1,  0,  25, 24, 1,  0,  26, 25, 1,  0,  27, 26, 1,  0,  28,
    27, 1,  0,  29, 28, 1,  0,  30, 29, 1,  0,  31, 30, 1,  0,  32, 31, 1,
    0,  33, 32, 1,  0,  34, 33, 1,  0,  35, 34, 1,  0,  36, 35, 1,  0,  37,
    36, 1,  0,  38, 37, 1,  0,  39, 38, 1,  0,  40, 39, 1,  0,  41, 40, 1,
    0,  0,  0,  0,
};

const u8 kStateN1[256] = {
    0,  0,  1,  0,  1,  1,  2,  0,  1,  1,  1,  2,  2,  2,  3,  0,  1,  1,
    1,  1,  2,  2,  2,  2,  2,  2,  3,  3,  3,  3,  4,  0,  1,  1,  2,  2,
    3,  3,  4,  4,  5,  0,  1,  1,  2,  2,  3,  3,  4,  4,  5,  5,  6,  0,
    1,  1,  2,  2,  3,  3,  4,  4,  5,  5,  6,  6,  7,  0,  1,  1,  2,  2,
    3,  3,  4,  4,  5,  5,  6,  6,  7,  7,  8,  0,  1,  1,  2,  2,  7,  7,
    8,  8,  9,  0,  1,  1,  2,  2,  8,  8,  9,  9,  10, 0,  1,  1,  2,  2,
    9,  9,  10, 10, 11, 0,  1,  1,  2,  2,  10, 10, 11, 11, 12, 0,  1,  1,
    2,  2,  11, 11, 12, 12, 13, 0,  1,  1,  2,  2,  12, 12, 13, 13, 14, 0,
    1,  1,  14, 14, 15, 0,  1,  15, 16, 0,  1,  16, 17, 0,  1,  17, 18, 0,
    1,  18, 19, 0,  1,  19, 20, 0,  1,  20, 21, 0,  1,  21, 22, 0,  1,  22,
    23, 0,  1,  23, 24, 0,  1,  24, 25, 0,  1,  25, 26, 0,  1,  26, 27, 0,
    1,  27, 28, 0,  1,  28, 29, 0,  1,  29, 30, 0,  1,  30, 31, 0,  1,  31,
    32, 0,  1,  32, 33, 0,  1,  33, 34, 0,  1,  34, 35, 0,  1,  35, 36, 0,
    1,  36, 37, 0,  1,  37, 38, 0,  1,  38, 39, 0,  1,  39, 40, 0,  1,  40,
    41, 0,  0,  0,
};

const u8 kStatePrio[256] = {
    0,  1,  1,  2,  2,  2,  2,  5,  3,  3,  3,  3,  3,  3,  5,  6,  4,  4,
    4,  4,  4,  4,  4,  4,  4,  4,  4,  4,  4,  4,  6,  9,  7,  7,  7,  7,
    7,  7,  7,  7,  9,  11, 8,  8,  8,  8,  8,  8,  8,  8,  8,  8,  11, 13,
    10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 13, 15, 12, 12, 12, 12,
    12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 15, 17, 14, 14, 14, 14, 14, 14,
    14, 14, 17, 19, 16, 16, 16, 16, 16, 16, 16, 16, 19, 21, 18, 18, 18, 18,
    18, 18, 18, 18, 21, 23, 20, 20, 20, 20, 20, 20, 20, 20, 23, 25, 22, 22,
    22, 22, 22, 22, 22, 22, 25, 27, 24, 24, 24, 24, 24, 24, 24, 24, 27, 29,
    26, 0,  0,  26, 29, 31, 28, 28, 31, 33, 30, 30, 33, 35, 32, 32, 35, 37,
    34, 34, 37, 39, 36, 36, 39, 41, 38, 38, 41, 43, 40, 40, 43, 45, 42, 42,
    45, 47, 44, 44, 47, 49, 46, 46, 49, 51, 48, 48, 51, 53, 50, 50, 53, 55,
    52, 52, 55, 57, 54, 54, 57, 59, 56, 56, 59, 61, 58, 58, 61, 63, 60, 60,
    63, 65, 62, 62, 65, 67, 64, 64, 67, 69, 66, 66, 69, 71, 68, 68, 71, 73,
    70, 70, 73, 75, 72, 72, 75, 77, 74, 74, 77, 79, 76, 76, 79, 81, 78, 78,
    81, 0,  0,  0,
};

const u8 kStateGroup[256] = {
    0,  1,  2,  3,  4,  5,  6,  7,  8,  9,  10, 11, 12, 13, 14, 18, 23, 24,
    24, 26, 25, 27, 26, 26, 25, 27, 26, 28, 28, 29, 15, 18, 23, 25, 25, 26,
    26, 27, 27, 29, 15, 18, 23, 25, 24, 25, 26, 26, 27, 28, 27, 29, 15, 18,
    23, 24, 24, 24, 25, 25, 27, 27, 28, 28, 28, 29, 15, 19, 22, 24, 23, 24,
    25, 25, 26, 26, 27, 27, 28, 29, 28, 30, 16, 19, 22, 24, 23, 24, 28, 29,
    28, 30, 16, 19, 22, 24, 23, 24, 28, 29, 28, 30, 16, 19, 22, 24, 23, 24,
    28, 29, 28, 30, 16, 19, 22, 24, 23, 24, 28, 29, 28, 30, 16, 19, 22, 24,
    22, 23, 29, 30, 28, 30, 16, 19, 22, 23, 22, 23, 29, 30, 29, 30, 16, 19,
    22, 0,  0,  30, 16, 19, 22, 30, 16, 19, 22, 30, 16, 19, 22, 30, 16, 19,
    22, 30, 16, 19, 22, 30, 16, 19, 21, 31, 16, 19, 21, 31, 16, 19, 21, 31,
    16, 19, 21, 31, 16, 19, 21, 31, 16, 19, 21, 31, 16, 19, 21, 31, 16, 19,
    21, 31, 16, 19, 21, 31, 16, 19, 21, 31, 17, 20, 21, 31, 17, 20, 21, 31,
    17, 20, 21, 31, 17, 20, 21, 31, 17, 20, 21, 31, 17, 20, 21, 31, 17, 20,
    21, 31, 17, 20, 21, 31, 17, 20, 21, 31, 17, 20, 21, 31, 17, 20, 21, 31,
    17, 0,  0,  0,
};

int zt_hasInfo(int type) { return type >= ZT_IMAGE8 && type <= ZT_IMAGE8PAL; }
int zt_isImage(int type) {
  return (type >= ZT_IMAGE8 && type <= ZT_IMAGE32) || type == ZT_IMAGE8PAL;
}
int zt_isBitImage(int type) { return type == ZT_IMAGE1 || type == ZT_IMAGE4; }

// ---------------------------------------------------------------- components

i64 stateInitEntry(i64 state) {
  i64 n0 = kStateN0[state];
  i64 n1 = kStateN1[state];
  if (state < 205) {
    n0 = n0 * 3 + 1;
    n1 = n1 * 3 + 1;
    return (((n1 << 20) / (n0 + n1)) << 12) & 0xFFFFFFFF;
  } else if (state < 253) {
    i64 inc = (state - 205) >> 2;
    if (((state - 205) & 3) <= 1) {
      n0 = 29 + ((i64)1 << inc);
    } else {
      n1 = 29 + ((i64)1 << inc);
    }
    n0 = n0 * 3 + 1;
    n1 = n1 * 3 + 1;
    i64 c = (n0 + n1) >> 3;
    if (c > 1023) c = 1023;
    return ((((n1 << 18) / (n0 + n1)) << 14) | c) & 0xFFFFFFFF;
  }
  return (i64)2048 << 20;
}

void statemap_init(StateMap *m, i64 n, i64 limit, int bitHistory) {
  m->t = ZNEW(u32, n);
  m->n = n;
  m->limit = limit;
  m->cx = 0;
  for (i64 i = 0; i < n; i++) {
    m->t[i] = (u32)(bitHistory ? stateInitEntry(i & 255) : ((i64)2048 << 20));
  }
}

void apm_init(Apm *a, i64 n, i64 rate) {
  a->t = ZNEW(u16, n * 24);
  a->rate = rate;
  a->index = 0;
  for (i64 i = 0; i < n * 24; i++) {
    a->t[i] = (u16)(squash((i % 24 * 2 + 1) * 4096 / 48 - 2048) * 16);
  }
}

i64 apm_pp16(Apm *a, i64 y, i64 pr, i64 cx) {
  u16 *tt = a->t;
  i64 rate = a->rate;
  i64 g = (y << 16) + (y << rate) - y - y;
  tt[a->index] = (u16)(tt[a->index] + ((g - tt[a->index]) >> rate));
  i64 s = (kStretch[pr] + 2048) * 23;
  i64 wt = s & 0xFFF;
  i64 base = cx * 24 + (s >> 12);
  a->index = base + (wt >> 11);
  return ((i64)tt[base] * (4096 - wt) + (i64)tt[base + 1] * wt) >> 12;
}

void apmpx_init(ApmPx *a, i64 n, i64 steps, i64 limit) {
  a->n = n * steps;
  a->t = ZNEW(u32, a->n);
  a->steps = steps;
  a->limit = limit;
  a->cxt = 0;
  for (i64 i = 0; i < a->n; i++) {
    i64 p = ((i % steps * 2 + 1) * 4096) / (steps * 2) - 2048;
    a->t[i] = (u32)((squash(p) << 20) + 6);
  }
}

i64 apmpx_pp(ApmPx *a, i64 y, i64 pr, i64 cx) {
  u32 *tt = a->t;
  i64 e = tt[a->cxt];
  i64 n = e & 1023;
  i64 p = e >> 10;
  tt[a->cxt] = (u32)(((p + ((((y << 22) - p) * kDt[n]) >> 31)) << 10) |
                     (n < a->limit ? n + 1 : n));
  i64 s = (kStretch[pr] + 2048) * (a->steps - 1);
  i64 wt = s & 0xFFF;
  i64 base = cx * a->steps + (s >> 12);
  a->cxt = base + (wt >> 11);
  return (((i64)(tt[base] >> 13)) * (4096 - wt) +
          ((i64)(tt[base + 1] >> 13)) * wt) >> 15;
}

void apm1_init(Apm1 *a, i64 n, i64 rate) {
  a->t = ZNEW(u16, n * 33);
  a->rate = rate;
  a->index = 0;
  for (i64 i = 0; i < n; i++) {
    for (i64 j = 0; j < 33; j++) {
      a->t[i * 33 + j] = (u16)(squash((j - 16) * 128) * 16);
    }
  }
}

i64 apm1_pp(Apm1 *a, i64 y, i64 pr, i64 cx) {
  u16 *tt = a->t;
  i64 rate = a->rate;
  i64 g = (y << 16) + (y << rate) - y - y;
  i64 i = a->index;
  tt[i] = (u16)(tt[i] + ((g - tt[i]) >> rate));
  tt[i + 1] = (u16)(tt[i + 1] + ((g - tt[i + 1]) >> rate));
  i64 s = kStretch[pr];
  i64 w = s & 127;
  a->index = ((s + 2048) >> 7) + cx * 33;
  return ((i64)tt[a->index] * (128 - w) + (i64)tt[a->index + 1] * w) >> 7;
}

void apmpost_init(ApmPost *a, i64 n) {
  a->n0 = ZNEW(u32, n * 4096);
  a->n1 = ZNEW(u32, n * 4096);
  a->index = 0;
  for (i64 i = 0; i < n; i++) {
    for (i64 j = 0; j < 4096; j++) {
      a->n0[i * 4096 + j] = (u32)((4096 - j) >> 1);
      a->n1[i * 4096 + j] = (u32)(j >> 1);
    }
  }
}

i64 apmpost_pp(ApmPost *a, i64 y, i64 pr, i64 cx) {
  i64 i = a->index;
  i64 n0 = (i64)a->n0[i] + 1 - y;
  i64 n1 = (i64)a->n1[i] + y;
  if (n0 >= 0xFFFFFFFF || n1 >= 0xFFFFFFFF) {
    n0 >>= 1;
    n1 >>= 1;
  }
  a->n0[i] = (u32)n0;
  a->n1[i] = (u32)n1;
  i64 j = cx * 4096 + pr;
  a->index = j;
  i64 x = (i64)a->n0[j] * 2 + 1;
  i64 b = (i64)a->n1[j] * 2 + 1;
  return (b << 16) / (x + b);
}

MixerOpts mixer_defaults(void) {
  MixerOpts o;
  o.finalContexts = 1;
  o.rateMax = 56 << 16;
  o.rateMin = 14 << 16;
  o.finalRate = 56 << 16;
  o.finalRateMin = 14 << 16;
  o.shift = 16;
  o.initWeight = 1 << 14;
  return o;
}

void mixer_init(Mixer *m, i64 n, const i64 *sizes, i64 nsizes, MixerOpts o) {
  m->n = n;
  m->tx = ZNEW(i32, n + 4);
  m->nx = 0;
  m->nzi = ZNEW(i32, n + 4);
  m->nSel = nsizes;
  m->base = ZNEW(i32, nsizes);
  m->sizes = ZNEW(i32, nsizes);
  m->sel = ZNEW(i32, nsizes);
  m->st = ZNEW(i32, nsizes);
  m->pr = ZNEW(i32, nsizes);
  m->stride = (n + 3) & ~(i64)3;
  i64 total = 0;
  for (i64 i = 0; i < nsizes; i++) {
    m->sizes[i] = (i32)sizes[i];
    total += sizes[i];
  }
  i64 nw = m->stride * total;
  m->wx = ZNEW(i32, nw);
  m->finalContexts = o.finalContexts;
  m->fw = ZNEW(i32, nsizes * o.finalContexts);
  m->fsel = 0;
  m->fpr = 2048;
  m->rate = o.rateMax;
  m->rateMin = o.rateMin;
  m->frate = o.finalRate;
  m->frateMin = o.finalRateMin;
  m->shift = o.shift;
  m->errLim = 4;
  m->k = 0;
  m->nz = 0;
  i64 b = 0;
  for (i64 i = 0; i < nsizes; i++) {
    m->base[i] = (i32)b;
    b += sizes[i] * m->stride;
  }
  for (i64 i = 0; i < nw; i++) m->wx[i] = (i32)o.initWeight;
  for (i64 i = 0; i < nsizes * o.finalContexts; i++) {
    m->fw[i] = (i32)(65536 / nsizes);
  }
}

i64 mixer_p(Mixer *m) {
  i64 k = m->k;
  const i32 *t = m->tx;
  i64 nxl = m->nx;
  i32 *nzi = m->nzi;
  i64 nz = 0;
  for (i64 i = 0; i < nxl; i++) {
    nzi[nz] = (i32)i;
    nz += t[i] != 0 ? 1 : 0;
  }
  m->nz = nz;
  const i32 *w = m->wx;
  i64 shift = m->shift;
  for (i64 s = 0; s < k; s++) {
    i64 o = m->sel[s];
    i64 d0 = 0;
    for (i64 j = 0; j < nz; j++) {
      i64 i = nzi[j];
      d0 += (i64)t[i] * w[o + i];
    }
    i64 dot = d0 >> shift;
    if (dot > 2047) dot = 2047;
    if (dot < -2047) dot = -2047;
    m->st[s] = (i32)dot;
    m->pr[s] = kSquash[dot + 2048];
  }
  if (k == 1) return m->pr[0];
  i64 dot = 0;
  i64 fo = m->fsel;
  for (i64 s = 0; s < k; s++) dot += (i64)m->st[s] * m->fw[fo + s];
  dot >>= 16;
  if (dot > 2047) dot = 2047;
  if (dot < -2047) dot = -2047;
  return m->fpr = kSquash[dot + 2048];
}

void mixer_update(Mixer *m, i64 y) {
  i64 k = m->k;
  const i32 *t = m->tx;
  i32 *w = m->wx;
  i64 target = y << 12;
  i64 rate = m->rate;
  i64 lim = m->errLim;
  const i32 *nzi = m->nzi;
  i64 nz = m->nz;
  for (i64 s = 0; s < k; s++) {
    i64 err0 = target - m->pr[s];
    if (err0 > -lim && err0 < lim) continue;
    i64 err = (err0 * rate) >> 16;
    i64 o = m->sel[s];
    for (i64 j = 0; j < nz; j++) {
      i64 i = nzi[j];
      w[o + i] = (i32)(w[o + i] + (((i64)t[i] * err) >> 16));
    }
  }
  if (rate > m->rateMin) m->rate = rate - 1;
  if (k > 1) {
    i64 err0 = target - m->fpr;
    if (err0 <= -lim || err0 >= lim) {
      i64 err = (err0 * m->frate) >> 16;
      i64 fo = m->fsel;
      for (i64 s = 0; s < k; s++) {
        m->fw[fo + s] = (i32)(m->fw[fo + s] + (((i64)m->st[s] * err) >> 16));
      }
    }
    if (m->frate > m->frateMin) m->frate--;
  }
  m->nx = 0;
  m->k = 0;
}

static u8 g_zeroCounts[256];

void contextmap_init(ContextMap *c, i64 bytes, i64 nCtx, int rich, int bh) {
  static int zcReady;
  if (!zcReady) {
    for (int i = 0; i < 256; i++) {
      g_zeroCounts[i] = (kStateN0[i] == 0 ? 1 : 0) | (kStateN1[i] == 0 ? 2 : 0);
    }
    zcReady = 1;
  }
  i64 size = bytes < 64 ? 64 : floorPow2(bytes);
  c->nCtx = nCtx;
  c->rich = rich;
  c->bh = bh;
  c->runSm = ZNEW(u32, bh ? nCtx * 4096 : 0);
  c->runIdx = ZNEW(i32, nCtx);
  for (i64 i = 0; i < nCtx; i++) c->runIdx[i] = -1;
  i64 n8 = bh ? nCtx * 256 + 1 : 0, n12 = bh ? nCtx * 4096 + 1 : 0;
  c->bh8 = ZNEW(u32, n8);
  for (i64 i = 0; i < n8; i++) c->bh8[i] = (u32)2048 << 20;
  c->bh12 = ZNEW(u32, n12);
  for (i64 i = 0; i < n12; i++) c->bh12[i] = (u32)2048 << 20;
  c->bh8Idx = ZNEW(i32, nCtx);
  c->bh12Idx = ZNEW(i32, nCtx);
  c->t = ZNEW(u8, size + 64);
  c->mask = size / 64 - 1;
  c->dummy = size;
  c->cxt = ZNEW(i32, nCtx);
  c->skip = ZNEW(u8, nCtx);
  c->cp = ZNEW(i32, nCtx);
  for (i64 i = 0; i < nCtx; i++) c->cp[i] = -1;
  c->cp0 = ZNEW(i32, nCtx);
  c->runp = ZNEW(i32, nCtx);
  c->sm = ZNEW(u32, nCtx * 256 + 1);
  c->smIdx = ZNEW(i32, nCtx);
  c->stv = ZNEW(i32, nCtx);
  zrandom_init(&c->rnd);
  c->hits = 0;
  for (i64 i = 0; i < nCtx * 256 + 1; i++) {
    c->sm[i] = (u32)stateInitEntry(i & 255);
  }
  if (bh) {
    for (i64 i = 0; i < nCtx * 4096; i++) {
      i64 cx = i & 4095;
      i64 bit = cx & 1;
      i64 unc = (cx >> 1) & 1;
      i64 rc = cx >> 4;
      i64 n0 = unc + 1;
      i64 n1 = (rc + 1) * 12;
      if (bit == 0) {
        i64 x = n0;
        n0 = n1;
        n1 = x;
      }
      c->runSm[i] = (u32)(((((n1 << 20) / (n0 + n1)) << 12) | 127) & 0xFFFFFFFF);
    }
  }
  for (i64 i = 0; i < nCtx; i++) {
    c->bh8Idx[i] = (i32)(i * 256);
    c->bh12Idx[i] = (i32)(i * 4096);
    c->smIdx[i] = (i32)(i * 256);
    c->runp[i] = (i32)(c->dummy + 3);
  }
}

static i64 cm_get(ContextMap *c, i64 b, i64 chk) {
  u8 *tt = c->t;
  i64 last = tt[b + 14];
  i64 li = last & 15;
  if (li < 7 && (tt[b + li * 2] | (tt[b + li * 2 + 1] << 8)) == chk) {
    return b + 15 + li * 7;
  }
  i64 best = 0x7FFFFFFF;
  i64 bi = 0;
  for (i64 i = 0; i < 7; i++) {
    if ((tt[b + i * 2] | (tt[b + i * 2 + 1] << 8)) == chk) {
      tt[b + 14] = (u8)(((last << 4) | i) & 0xFF);
      return b + 15 + i * 7;
    }
    i64 pri = kStatePrio[tt[b + 15 + i * 7]];
    if (pri < best && li != i && (last >> 4) != i) {
      best = pri;
      bi = i;
    }
  }
  tt[b + 14] = (u8)(0xF0 | bi);
  tt[b + bi * 2] = (u8)(chk & 255);
  tt[b + bi * 2 + 1] = (u8)(chk >> 8);
  i64 s = b + 15 + bi * 7;
  for (i64 j = 0; j < 7; j++) tt[s + j] = 0;
  return s;
}

static void cm_updateBh(ContextMap *c, i64 i, i64 target) {
  i64 ri = c->runIdx[i];
  if (ri >= 0) {
    i64 e = c->runSm[ri];
    i64 en = e & 1023;
    i64 ep = e >> 10;
    c->runSm[ri] = (u32)(((ep + (((target - ep) * kDt[en]) >> 31)) << 10) |
                         (en < 127 ? en + 1 : en));
  }
  i64 i8 = c->bh8Idx[i];
  i64 e = c->bh8[i8];
  i64 en = e & 1023;
  i64 ep = e >> 10;
  c->bh8[i8] = (u32)(((ep + (((target - ep) * kDt[en]) >> 31)) << 10) |
                     (en < 1023 ? en + 1 : en));
  i64 i12 = c->bh12Idx[i];
  e = c->bh12[i12];
  en = e & 1023;
  ep = e >> 10;
  c->bh12[i12] = (u32)(((ep + (((target - ep) * kDt[en]) >> 31)) << 10) |
                       (en < 1023 ? en + 1 : en));
}

static i64 cm_mixBh(ContextMap *c, i32 *tx, i64 k, i64 i, i64 rp, i64 rc,
                    i64 rb, i64 st, i64 bpos, i64 c0) {
  u8 *tt = c->t;
  i64 b2 = tt[rp + 2];
  i64 b3 = tt[rp + 3];
  i64 unc = (st != 0 && g_zeroCounts[st] == 0) ? 1 : 0;
  i64 nri = -1;
  i64 sh = 0;
  if (rc != 0) {
    i64 sft = 8 - bpos;
    if (((rb + 256) >> sft) == c0) {
      i64 bit = (rb >> (7 - bpos)) & 1;
      i64 u1 = b2 != rb ? 1 : 0;
      i64 bp = (0x33322210 >> (bpos << 2)) & 15;
      i64 r = rc >> 1;
      nri = i * 4096 + ((r > 255 ? 255 : r) << 4 | bp << 2 | u1 << 1 | bit);
      sh = 1 + u1;
    } else if (((b2 + 256) >> sft) == c0) {
      i64 bit = (b2 >> (7 - bpos)) & 1;
      i64 u2 = b3 != b2 ? 1 : 0;
      nri = i * 4096 + (unc << 1 | bit);
      sh = 2 + u2;
    }
  }
  c->runIdx[i] = (i32)nri;
  tx[k++] = (i32)(nri >= 0 ? kStretch[c->runSm[nri] >> 20] >> sh : 0);
  i64 sb = 7 - bpos;
  i64 bits = ((rb >> sb) & 1) | ((b2 >> sb) & 1) << 1 | ((b3 >> sb) & 1) << 2;
  i64 bhs = rc == 0 ? 0 : (8 | bits);
  i64 i8 = i * 256 + (unc << 7 | bhs << 3 | bpos);
  i64 i12 = i * 4096 + ((i64)kStateGroup[st] << 7 | bhs << 3 | bpos);
  c->bh8Idx[i] = (i32)i8;
  c->bh12Idx[i] = (i32)i12;
  tx[k] = kStretch[c->bh8[i8] >> 20] >> 2;
  tx[k + 1] = kStretch[c->bh12[i12] >> 20] >> 2;
  return k + 2;
}

static void cm_advance(ContextMap *c, i64 y, i64 bpos, i64 c0, i64 c1) {
  u8 *tt = c->t;
  u32 *sm = c->sm;
  i64 n = c->nCtx;
  i64 yy = y << 8;
  i64 target = y << 22;
  i64 mode = (bpos == 1 || bpos == 3 || bpos == 6)
                 ? 1
                 : ((bpos == 4 || bpos == 7) ? 2 : 0);
  for (i64 i = 0; i < n; i++) {
    i64 cp = c->cp[i];
    if (cp >= 0) {
      i64 s0 = tt[cp];
      i64 ns = kNex[yy | s0];
      tt[cp] = (u8)((ns >= 205 && ns >= s0 + 4 &&
                     (zrandom_next(&c->rnd) & 1) != 0)
                        ? s0
                        : ns);
    }
    i64 si = c->smIdx[i];
    i64 e = sm[si];
    i64 en = e & 1023;
    i64 ep = e >> 10;
    sm[si] = (u32)(((ep + (((target - ep) * kDt[en]) >> 31)) << 10) |
                   (en < 1023 ? en + 1 : en));
    if (c->bh) cm_updateBh(c, i, target);
    if (bpos == 0) {
      i64 rp = c->runp[i];
      i64 rc = tt[rp];
      if (rc == 0) {
        tt[rp] = 2;
        tt[rp + 1] = (u8)c1;
        tt[rp + 2] = (u8)c1;
        tt[rp + 3] = (u8)c1;
      } else if (tt[rp + 1] != c1) {
        tt[rp] = 1;
        tt[rp + 3] = tt[rp + 2];
        tt[rp + 2] = tt[rp + 1];
        tt[rp + 1] = (u8)c1;
      } else if (rc < 254) {
        tt[rp] = (u8)(rc + 2);
      } else if (rc == 255) {
        tt[rp] = 128;
      }
      if (c->skip[i] != 0) {
        c->smIdx[i] = (i32)(n << 8);
        if (c->bh) {
          c->runIdx[i] = -1;
          c->bh8Idx[i] = (i32)(n << 8);
          c->bh12Idx[i] = (i32)(n << 12);
        }
        c->cp[i] = -1;
        c->runp[i] = (i32)(c->dummy + 3);
        tt[c->dummy + 3] = 0;
        c->stv[i] = -1;
        continue;
      }
    } else if (c->stv[i] < 0) {
      continue;
    }
    if (mode == 1) {
      cp = c->cp0[i] + 1 + (c0 & 1);
    } else if (mode == 2) {
      cp = c->cp0[i] + 3 + (c0 & 3);
    } else {
      i64 cx = (u32)c->cxt[i];
      i64 chk = (cx >> 16) & 0xFFFF;
      i64 s = cm_get(c, ((cx + c0) & c->mask) << 6, chk);
      c->cp0[i] = (i32)s;
      cp = s;
      if (bpos == 0) {
        if (tt[s + 3] == 2) {
          i64 cc = tt[s + 4] + 256;
          i64 p = cm_get(c, ((cx + (cc >> 6)) & c->mask) << 6, chk);
          tt[p] = (u8)(1 + ((cc >> 5) & 1));
          tt[p + 1 + ((cc >> 5) & 1)] = (u8)(1 + ((cc >> 4) & 1));
          tt[p + 3 + ((cc >> 4) & 3)] = (u8)(1 + ((cc >> 3) & 1));
          p = cm_get(c, ((cx + (cc >> 3)) & c->mask) << 6, chk);
          tt[p] = (u8)(1 + ((cc >> 2) & 1));
          tt[p + 1 + ((cc >> 2) & 1)] = (u8)(1 + ((cc >> 1) & 1));
          tt[p + 3 + ((cc >> 1) & 3)] = (u8)(1 + (cc & 1));
        }
        c->runp[i] = (i32)(s + 3);
      }
    }
    if (bpos > 1 && tt[c->runp[i]] == 0) cp = -1;
    c->cp[i] = (i32)cp;
    i64 st = cp >= 0 ? tt[cp] : 0;
    c->stv[i] = (i32)st;
    c->smIdx[i] = (i32)((i << 8) | st);
  }
}

static void cm_inputs(ContextMap *c, Mixer *m, i64 bpos, i64 c0) {
  u8 *tt = c->t;
  i32 *tx = m->tx;
  i64 k = m->nx;
  i64 n = c->nCtx;
  int isRich = c->rich;
  i64 per = isRich ? 6 : 4;
  i64 sh = 8 - bpos;
  i64 bsh = 7 - bpos;
  i64 hit = 0;
  for (i64 i = 0; i < n; i++) {
    i64 st = c->stv[i];
    if (st < 0) {
      for (i64 j = 0; j < per; j++) tx[k + j] = 0;
      k += per;
      continue;
    }
    i64 rp = c->runp[i];
    i64 rb = tt[rp + 1];
    if (((rb + 256) >> sh) == c0) {
      i64 rc = tt[rp];
      i64 cc = (i64)kIlog[rc + 1] << (2 + (~rc & 1));
      tx[k] = (i32)(((rb >> bsh) & 1) != 0 ? cc : -cc);
    } else {
      tx[k] = 0;
    }
    if (st == 0) {
      tx[k + 1] = 0;
      tx[k + 2] = 0;
      tx[k + 3] = 0;
      if (isRich) {
        tx[k + 4] = 0;
        tx[k + 5] = 0;
      }
    } else {
      hit++;
      i64 p1 = c->sm[(i << 8) | st] >> 20;
      i64 s1 = kStretch[p1] >> 2;
      i64 z = g_zeroCounts[st];
      tx[k + 1] = (i32)(st <= 2 ? s1 >> 1 : s1);
      tx[k + 2] = (i32)((p1 - 2048) >> 3);
      tx[k + 3] = (i32)(z != 0 ? s1 : 0);
      if (isRich) {
        i64 z0 = -(z & 1);
        i64 z1 = -(z >> 1);
        tx[k + 4] = (i32)(((p1 & z0) - ((4095 - p1) & z1)) >> 4);
        tx[k + 5] = (i32)(z == 0 ? s1 : 0);
      }
    }
    k += per;
  }
  m->nx = k;
  c->hits = hit;
}

static void cm_inputsBh(ContextMap *c, Mixer *m, i64 bpos, i64 c0) {
  i32 *tx = m->tx;
  i64 k = m->nx;
  i64 n = c->nCtx;
  int isRich = c->rich;
  i64 per = contextmap_inputsPerContext(c);
  i64 hit = 0;
  for (i64 i = 0; i < n; i++) {
    i64 st = c->stv[i];
    if (st < 0) {
      for (i64 j = 0; j < per; j++) tx[k + j] = 0;
      k += per;
      continue;
    }
    i64 rp = c->runp[i];
    k = cm_mixBh(c, tx, k, i, rp, c->t[rp], c->t[rp + 1], st, bpos, c0);
    if (st == 0) {
      tx[k] = 0;
      tx[k + 1] = 0;
      tx[k + 2] = 0;
      k += 3;
      if (isRich) {
        tx[k] = 0;
        tx[k + 1] = 0;
        k += 2;
      }
    } else {
      hit++;
      i64 p1 = c->sm[(i << 8) | st] >> 20;
      i64 s1 = kStretch[p1] >> 2;
      i64 z = g_zeroCounts[st];
      tx[k] = (i32)(st <= 2 ? s1 >> 1 : s1);
      tx[k + 1] = (i32)((p1 - 2048) >> 3);
      tx[k + 2] = (i32)(z != 0 ? s1 : 0);
      k += 3;
      if (isRich) {
        i64 z0 = -(z & 1);
        i64 z1 = -(z >> 1);
        tx[k] = (i32)(((p1 & z0) - ((4095 - p1) & z1)) >> 4);
        tx[k + 1] = (i32)(z == 0 ? s1 : 0);
        k += 2;
      }
    }
  }
  m->nx = k;
  c->hits = hit;
}

void contextmap_mix(ContextMap *c, Mixer *m, i64 y, i64 bpos, i64 c0,
                    i64 c1) {
  cm_advance(c, y, bpos, c0, c1);
  if (c->bh) {
    cm_inputsBh(c, m, bpos, c0);
  } else {
    cm_inputs(c, m, bpos, c0);
  }
}

void directmap_init(DirectMap *d, i64 bits) {
  d->t = ZNEW(u8, ((i64)1 << bits) * 256);
  d->mask = ((i64)1 << bits) - 1;
  d->sm = ZNEW(u32, 256 * 256);
  d->smi = d->cp = d->base = 0;
  zrandom_init(&d->rnd);
  for (i64 i = 0; i < 256 * 256; i++) d->sm[i] = (u32)stateInitEntry(i & 255);
}

void directmap_mix(DirectMap *d, Mixer *m, i64 y, i64 c0) {
  u8 *tt = d->t;
  tt[d->cp] = (u8)nextState(tt[d->cp], y, &d->rnd);
  i64 cp = d->base | c0;
  d->cp = cp;
  i64 st = tt[cp];
  u32 *sm = d->sm;
  sm[d->smi] = (u32)adaptEntry(sm[d->smi], y, 1023);
  d->smi = (c0 << 8) | st;
  i64 p1 = sm[d->smi] >> 20;
  i64 s1 = kStretch[p1];
  mixer_add(m, s1 >> 2);
  mixer_add(m, st == 0 ? 0 : (p1 - 2048) >> 3);
}

void directprobmap_init(DirectProbMap *d, i64 bits, i64 limit) {
  d->t = ZNEW(u32, (i64)1 << bits);
  for (i64 i = 0; i < ((i64)1 << bits); i++) d->t[i] = (u32)2048 << 20;
  d->mask = ((i64)1 << bits) - 1;
  d->limit = limit;
  d->cx = 0;
}

// ---------------------------------------------------------------- state

void zstate_init(ZState *s, i64 bufBytes) {
  i64 n = floorPow2(bufBytes < 4096 ? 4096 : bufBytes);
  s->buf = ZNEW(u8, n);
  s->bufMask = n - 1;
  s->y = 0;
  s->c0 = 1;
  s->bpos = 0;
  s->c4 = s->c8 = s->pos = 0;
  s->blockType = ZT_BINARY;
  s->blockInfo = 0;
  s->blockPos = 0;
}

// ---------------------------------------------------------------- coder

void zdecoder_init(ZDecoder *d, const u8 *data, i64 start, i64 end) {
  d->x1 = 0;
  d->x2 = 0xFFFFFFFF;
  d->x = 0;
  d->data = data;
  d->pos = start;
  d->end = end;
  for (int i = 0; i < 4; i++) d->x = (d->x << 8) | zdecoder_next(d);
}

i64 zdecoder_decodeDirect(ZDecoder *d, int n) {
  i64 v = 0;
  for (int i = 0; i < n; i++) v = (v << 1) | zdecoder_decode(d, 32768);
  return v;
}
