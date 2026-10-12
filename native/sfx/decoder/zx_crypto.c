// zxsfx decoder: CRC-32C, xxHash64 (Yann Collet's algorithm), SHA-256
// (FIPS 180-4), HMAC (RFC 2104), PBKDF2 (RFC 8018), scrypt (RFC 7914, Colin
// Percival) and AES-256 (FIPS 197), written from their specifications.

#include "zx_crypto.h"

// ---------------------------------------------------------------- CRC-32C

static u32 g_crc32c[256];

u32 crc32c_update(u32 crc, const u8 *p, i64 n) {
  if (g_crc32c[1] == 0) {
    for (u32 i = 0; i < 256; i++) {
      u32 c = i;
      for (int k = 0; k < 8; k++) c = (c & 1) ? 0x82F63B78u ^ (c >> 1) : c >> 1;
      g_crc32c[i] = c;
    }
  }
  crc = ~crc;
  for (i64 i = 0; i < n; i++) crc = g_crc32c[(crc ^ p[i]) & 255] ^ (crc >> 8);
  return ~crc;
}

// ---------------------------------------------------------------- xxHash64

#define P1 0x9E3779B185EBCA87ull
#define P2 0xC2B2AE3D27D4EB4Full
#define P3 0x165667B19E3779F9ull
#define P4 0x85EBCA77C2B2AE63ull
#define P5 0x27D4EB2F165667C5ull

ZINLINE u64 rotl64(u64 x, int r) { return (x << r) | (x >> (64 - r)); }
ZINLINE u64 rd64(const u8 *p) {
  u64 v = 0;
  for (int i = 7; i >= 0; i--) v = (v << 8) | p[i];
  return v;
}
ZINLINE u32 rd32(const u8 *p) {
  return (u32)p[0] | (u32)p[1] << 8 | (u32)p[2] << 16 | (u32)p[3] << 24;
}
ZINLINE u64 xxround(u64 acc, u64 in) {
  acc += in * P2;
  acc = rotl64(acc, 31);
  return acc * P1;
}
ZINLINE u64 xxmerge(u64 acc, u64 v) {
  acc ^= xxround(0, v);
  return acc * P1 + P4;
}

u64 xxh64(const u8 *p, i64 n, u64 seed) {
  const u8 *end = p + n;
  u64 h;
  if (n >= 32) {
    u64 v1 = seed + P1 + P2, v2 = seed + P2, v3 = seed, v4 = seed - P1;
    const u8 *limit = end - 32;
    do {
      v1 = xxround(v1, rd64(p));
      v2 = xxround(v2, rd64(p + 8));
      v3 = xxround(v3, rd64(p + 16));
      v4 = xxround(v4, rd64(p + 24));
      p += 32;
    } while (p <= limit);
    h = rotl64(v1, 1) + rotl64(v2, 7) + rotl64(v3, 12) + rotl64(v4, 18);
    h = xxmerge(h, v1);
    h = xxmerge(h, v2);
    h = xxmerge(h, v3);
    h = xxmerge(h, v4);
  } else {
    h = seed + P5;
  }
  h += (u64)n;
  while (p + 8 <= end) {
    h ^= xxround(0, rd64(p));
    h = rotl64(h, 27) * P1 + P4;
    p += 8;
  }
  if (p + 4 <= end) {
    h ^= (u64)rd32(p) * P1;
    h = rotl64(h, 23) * P2 + P3;
    p += 4;
  }
  while (p < end) {
    h ^= (*p) * P5;
    h = rotl64(h, 11) * P1;
    p++;
  }
  h ^= h >> 33;
  h *= P2;
  h ^= h >> 29;
  h *= P3;
  h ^= h >> 32;
  return h;
}

// ---------------------------------------------------------------- SHA-256

static const u32 K256[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
    0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
    0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
    0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
    0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
    0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};

ZINLINE u32 ror32(u32 x, int r) { return (x >> r) | (x << (32 - r)); }

static void sha256_block(u32 h[8], const u8 *p) {
  u32 w[64];
  for (int i = 0; i < 16; i++) {
    w[i] = (u32)p[i * 4] << 24 | (u32)p[i * 4 + 1] << 16 |
           (u32)p[i * 4 + 2] << 8 | p[i * 4 + 3];
  }
  for (int i = 16; i < 64; i++) {
    u32 s0 = ror32(w[i - 15], 7) ^ ror32(w[i - 15], 18) ^ (w[i - 15] >> 3);
    u32 s1 = ror32(w[i - 2], 17) ^ ror32(w[i - 2], 19) ^ (w[i - 2] >> 10);
    w[i] = w[i - 16] + s0 + w[i - 7] + s1;
  }
  u32 a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6],
      hh = h[7];
  for (int i = 0; i < 64; i++) {
    u32 s1 = ror32(e, 6) ^ ror32(e, 11) ^ ror32(e, 25);
    u32 ch = (e & f) ^ (~e & g);
    u32 t1 = hh + s1 + ch + K256[i] + w[i];
    u32 s0 = ror32(a, 2) ^ ror32(a, 13) ^ ror32(a, 22);
    u32 maj = (a & b) ^ (a & c) ^ (b & c);
    u32 t2 = s0 + maj;
    hh = g;
    g = f;
    f = e;
    e = d + t1;
    d = c;
    c = b;
    b = a;
    a = t1 + t2;
  }
  h[0] += a;
  h[1] += b;
  h[2] += c;
  h[3] += d;
  h[4] += e;
  h[5] += f;
  h[6] += g;
  h[7] += hh;
}

void sha256_init(Sha256 *s) {
  static const u32 iv[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
  for (int i = 0; i < 8; i++) s->h[i] = iv[i];
  s->len = 0;
}

void sha256_update(Sha256 *s, const u8 *p, i64 n) {
  i64 fill = (i64)(s->len & 63);
  s->len += (u64)n;
  if (fill) {
    i64 k = 64 - fill < n ? 64 - fill : n;
    memcpy(s->buf + fill, p, (size_t)k);
    p += k;
    n -= k;
    if (fill + k < 64) return;
    sha256_block(s->h, s->buf);
  }
  while (n >= 64) {
    sha256_block(s->h, p);
    p += 64;
    n -= 64;
  }
  if (n) memcpy(s->buf, p, (size_t)n);
}

void sha256_final(Sha256 *s, u8 out[32]) {
  u64 bits = s->len * 8;
  u8 pad[72];
  i64 fill = (i64)(s->len & 63);
  i64 padLen = (fill < 56 ? 56 : 120) - fill;
  memset(pad, 0, sizeof pad);
  pad[0] = 0x80;
  for (int i = 0; i < 8; i++) pad[padLen + i] = (u8)(bits >> (56 - 8 * i));
  sha256_update(s, pad, padLen + 8);
  for (int i = 0; i < 8; i++) {
    out[i * 4] = (u8)(s->h[i] >> 24);
    out[i * 4 + 1] = (u8)(s->h[i] >> 16);
    out[i * 4 + 2] = (u8)(s->h[i] >> 8);
    out[i * 4 + 3] = (u8)s->h[i];
  }
}

void sha256(const u8 *p, i64 n, u8 out[32]) {
  Sha256 s;
  sha256_init(&s);
  sha256_update(&s, p, n);
  sha256_final(&s, out);
}

// ---------------------------------------------------------------- HMAC

void hmac_init(Hmac *h, const u8 *key, i64 keyLen) {
  u8 k[32], ipad[64];
  if (keyLen > 64) {
    sha256(key, keyLen, k);
    key = k;
    keyLen = 32;
  }
  for (int i = 0; i < 64; i++) {
    u8 c = i < keyLen ? key[i] : 0;
    ipad[i] = c ^ 0x36;
    h->opad[i] = c ^ 0x5C;
  }
  sha256_init(&h->s);
  sha256_update(&h->s, ipad, 64);
}

void hmac_final(Hmac *h, u8 out[32]) {
  u8 inner[32];
  sha256_final(&h->s, inner);
  sha256_init(&h->s);
  sha256_update(&h->s, h->opad, 64);
  sha256_update(&h->s, inner, 32);
  sha256_final(&h->s, out);
}

static void pbkdf2_sha256_1(const u8 *pw, i64 pwLen, const u8 *salt,
                            i64 saltLen, u8 *out, i64 outLen) {
  // One iteration (as scrypt uses it).
  for (i64 block = 1; outLen > 0; block++) {
    u8 ctr[4] = {(u8)(block >> 24), (u8)(block >> 16), (u8)(block >> 8),
                 (u8)block};
    u8 t[32];
    Hmac h;
    hmac_init(&h, pw, pwLen);
    hmac_update(&h, salt, saltLen);
    hmac_update(&h, ctr, 4);
    hmac_final(&h, t);
    i64 k = outLen < 32 ? outLen : 32;
    memcpy(out, t, (size_t)k);
    out += k;
    outLen -= k;
  }
}

// ---------------------------------------------------------------- scrypt

ZINLINE u32 rol32(u32 x, int r) { return (x << r) | (x >> (32 - r)); }

static void salsa8(u32 b[16]) {
  u32 x[16];
  for (int i = 0; i < 16; i++) x[i] = b[i];
  for (int i = 0; i < 8; i += 2) {
    x[4] ^= rol32(x[0] + x[12], 7);
    x[8] ^= rol32(x[4] + x[0], 9);
    x[12] ^= rol32(x[8] + x[4], 13);
    x[0] ^= rol32(x[12] + x[8], 18);
    x[9] ^= rol32(x[5] + x[1], 7);
    x[13] ^= rol32(x[9] + x[5], 9);
    x[1] ^= rol32(x[13] + x[9], 13);
    x[5] ^= rol32(x[1] + x[13], 18);
    x[14] ^= rol32(x[10] + x[6], 7);
    x[2] ^= rol32(x[14] + x[10], 9);
    x[6] ^= rol32(x[2] + x[14], 13);
    x[10] ^= rol32(x[6] + x[2], 18);
    x[3] ^= rol32(x[15] + x[11], 7);
    x[7] ^= rol32(x[3] + x[15], 9);
    x[11] ^= rol32(x[7] + x[3], 13);
    x[15] ^= rol32(x[11] + x[7], 18);
    x[1] ^= rol32(x[0] + x[3], 7);
    x[2] ^= rol32(x[1] + x[0], 9);
    x[3] ^= rol32(x[2] + x[1], 13);
    x[0] ^= rol32(x[3] + x[2], 18);
    x[6] ^= rol32(x[5] + x[4], 7);
    x[7] ^= rol32(x[6] + x[5], 9);
    x[4] ^= rol32(x[7] + x[6], 13);
    x[5] ^= rol32(x[4] + x[7], 18);
    x[11] ^= rol32(x[10] + x[9], 7);
    x[8] ^= rol32(x[11] + x[10], 9);
    x[9] ^= rol32(x[8] + x[11], 13);
    x[10] ^= rol32(x[9] + x[8], 18);
    x[12] ^= rol32(x[15] + x[14], 7);
    x[13] ^= rol32(x[12] + x[15], 9);
    x[14] ^= rol32(x[13] + x[12], 13);
    x[15] ^= rol32(x[14] + x[13], 18);
  }
  for (int i = 0; i < 16; i++) b[i] += x[i];
}

// BlockMix of 2r 64 byte blocks: in -> out.
static void blockmix(const u32 *in, u32 *out, i64 r) {
  u32 x[16];
  for (int i = 0; i < 16; i++) x[i] = in[(2 * r - 1) * 16 + i];
  for (i64 i = 0; i < 2 * r; i++) {
    for (int j = 0; j < 16; j++) x[j] ^= in[i * 16 + j];
    salsa8(x);
    u32 *y = out + ((i & 1) ? (r + i / 2) : (i / 2)) * 16;
    for (int j = 0; j < 16; j++) y[j] = x[j];
  }
}

int scrypt(const u8 *pw, i64 pwLen, const u8 *salt, i64 saltLen, i64 n,
           i64 r, i64 p, u8 *out, i64 outLen) {
  i64 words = 32 * r; // u32 words of a block of 128 r bytes
  size_t mark = zmark();
  u8 *b = ZNEW(u8, p * 128 * r);
  pbkdf2_sha256_1(pw, pwLen, salt, saltLen, b, p * 128 * r);
  u32 *v = ZNEW(u32, n * words);
  u32 *x = ZNEW(u32, words);
  u32 *y = ZNEW(u32, words);
  for (i64 k = 0; k < p; k++) {
    u8 *bk = b + k * 128 * r;
    for (i64 i = 0; i < words; i++) x[i] = rd32(bk + i * 4);
    for (i64 i = 0; i < n; i++) {
      memcpy(v + i * words, x, (size_t)words * 4);
      blockmix(x, y, r);
      u32 *t = x;
      x = y;
      y = t;
    }
    for (i64 i = 0; i < n; i++) {
      u64 j = x[(2 * r - 1) * 16] & (u64)(n - 1);
      for (i64 q = 0; q < words; q++) x[q] ^= v[j * words + q];
      blockmix(x, y, r);
      u32 *t = x;
      x = y;
      y = t;
    }
    for (i64 i = 0; i < words; i++) {
      bk[i * 4] = (u8)x[i];
      bk[i * 4 + 1] = (u8)(x[i] >> 8);
      bk[i * 4 + 2] = (u8)(x[i] >> 16);
      bk[i * 4 + 3] = (u8)(x[i] >> 24);
    }
  }
  pbkdf2_sha256_1(pw, pwLen, b, p * 128 * r, out, outLen);
  zrelease(mark);
  return 1;
}

// ---------------------------------------------------------------- AES-256

static const u8 SBOX[256] = {
    0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b,
    0xfe, 0xd7, 0xab, 0x76, 0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0,
    0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0, 0xb7, 0xfd, 0x93, 0x26,
    0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
    0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2,
    0xeb, 0x27, 0xb2, 0x75, 0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0,
    0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84, 0x53, 0xd1, 0x00, 0xed,
    0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
    0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f,
    0x50, 0x3c, 0x9f, 0xa8, 0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5,
    0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2, 0xcd, 0x0c, 0x13, 0xec,
    0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
    0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14,
    0xde, 0x5e, 0x0b, 0xdb, 0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c,
    0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79, 0xe7, 0xc8, 0x37, 0x6d,
    0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
    0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f,
    0x4b, 0xbd, 0x8b, 0x8a, 0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e,
    0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e, 0xe1, 0xf8, 0x98, 0x11,
    0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
    0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f,
    0xb0, 0x54, 0xbb, 0x16};

ZINLINE u32 subword(u32 w) {
  return (u32)SBOX[w >> 24] << 24 | (u32)SBOX[(w >> 16) & 255] << 16 |
         (u32)SBOX[(w >> 8) & 255] << 8 | SBOX[w & 255];
}

void aes256_init(Aes256 *a, const u8 key[32]) {
  u32 rcon = 1;
  for (int i = 0; i < 8; i++) {
    a->rk[i] = (u32)key[i * 4] << 24 | (u32)key[i * 4 + 1] << 16 |
               (u32)key[i * 4 + 2] << 8 | key[i * 4 + 3];
  }
  for (int i = 8; i < 60; i++) {
    u32 t = a->rk[i - 1];
    if (i % 8 == 0) {
      t = subword((t << 8) | (t >> 24)) ^ (rcon << 24);
      rcon = (rcon << 1) ^ ((rcon & 0x80) ? 0x11B : 0);
    } else if (i % 8 == 4) {
      t = subword(t);
    }
    a->rk[i] = a->rk[i - 8] ^ t;
  }
}

ZINLINE u8 xtime(u8 x) { return (u8)((x << 1) ^ ((x & 0x80) ? 0x1B : 0)); }

void aes256_encrypt(const Aes256 *a, const u8 in[16], u8 out[16]) {
  u8 s[16];
  for (int c = 0; c < 4; c++) {
    u32 k = a->rk[c];
    s[c * 4] = in[c * 4] ^ (u8)(k >> 24);
    s[c * 4 + 1] = in[c * 4 + 1] ^ (u8)(k >> 16);
    s[c * 4 + 2] = in[c * 4 + 2] ^ (u8)(k >> 8);
    s[c * 4 + 3] = in[c * 4 + 3] ^ (u8)k;
  }
  for (int round = 1; round <= 14; round++) {
    u8 t[16];
    // SubBytes and ShiftRows
    for (int c = 0; c < 4; c++) {
      for (int r = 0; r < 4; r++) t[c * 4 + r] = SBOX[s[((c + r) & 3) * 4 + r]];
    }
    // MixColumns (not in the last round)
    if (round < 14) {
      for (int c = 0; c < 4; c++) {
        u8 a0 = t[c * 4], a1 = t[c * 4 + 1], a2 = t[c * 4 + 2], a3 = t[c * 4 + 3];
        u8 all = a0 ^ a1 ^ a2 ^ a3;
        t[c * 4] = a0 ^ all ^ xtime(a0 ^ a1);
        t[c * 4 + 1] = a1 ^ all ^ xtime(a1 ^ a2);
        t[c * 4 + 2] = a2 ^ all ^ xtime(a2 ^ a3);
        t[c * 4 + 3] = a3 ^ all ^ xtime(a3 ^ a0);
      }
    }
    for (int c = 0; c < 4; c++) {
      u32 k = a->rk[round * 4 + c];
      s[c * 4] = t[c * 4] ^ (u8)(k >> 24);
      s[c * 4 + 1] = t[c * 4 + 1] ^ (u8)(k >> 16);
      s[c * 4 + 2] = t[c * 4 + 2] ^ (u8)(k >> 8);
      s[c * 4 + 3] = t[c * 4 + 3] ^ (u8)k;
    }
  }
  memcpy(out, s, 16);
}

void aes256_ctr(const Aes256 *a, const u8 nonce[16], u8 *b, i64 n) {
  u8 counter[16], ks[16];
  memcpy(counter, nonce, 16);
  for (i64 i = 0; i < n; i += 16) {
    aes256_encrypt(a, counter, ks);
    i64 k = n - i < 16 ? n - i : 16;
    for (i64 j = 0; j < k; j++) b[i + j] ^= ks[j];
    for (int j = 15; j >= 0; j--) {
      if (++counter[j] != 0) break;
    }
  }
}
