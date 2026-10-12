// zxsfx decoder: checks and encryption of .zx archives (docs/zx-format.md,
// sections 1, 4 and 7): CRC-32C, xxHash64, SHA-256, HMAC-SHA-256, scrypt
// (RFC 7914), AES-256 (FIPS 197) in CTR mode.

#ifndef ZX_CRYPTO_H
#define ZX_CRYPTO_H

#include "zc.h"

u32 crc32c_update(u32 crc, const u8 *p, i64 n); // crc 0 to start
u64 xxh64(const u8 *p, i64 n, u64 seed);

typedef struct {
  u32 h[8];
  u8 buf[64];
  u64 len;
} Sha256;
void sha256_init(Sha256 *s);
void sha256_update(Sha256 *s, const u8 *p, i64 n);
void sha256_final(Sha256 *s, u8 out[32]);
void sha256(const u8 *p, i64 n, u8 out[32]);

typedef struct {
  Sha256 s;
  u8 opad[64];
} Hmac;
void hmac_init(Hmac *h, const u8 *key, i64 keyLen);
ZINLINE void hmac_update(Hmac *h, const u8 *p, i64 n) {
  sha256_update(&h->s, p, n);
}
void hmac_final(Hmac *h, u8 out[32]);

// scrypt(P, S, N, r, p, dkLen); returns 0 when the memory is not there.
int scrypt(const u8 *pw, i64 pwLen, const u8 *salt, i64 saltLen, i64 n,
           i64 r, i64 p, u8 *out, i64 outLen);

typedef struct {
  u32 rk[60];
} Aes256;
void aes256_init(Aes256 *a, const u8 key[32]);
void aes256_encrypt(const Aes256 *a, const u8 in[16], u8 out[16]);
// XORs b[0..n) with the CTR key stream of the counter block [nonce]
// (incremented as a 128 bit big endian number).
void aes256_ctr(const Aes256 *a, const u8 nonce[16], u8 *b, i64 n);

#endif
