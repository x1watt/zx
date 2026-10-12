// zxsfx decoder: the extractor of a self-extracting zx archive
// (x.zx.sfx). It reads the .zx archive that starts at a given offset of a
// file (docs/zx-format.md: the Header, the last Footer, the Index, the
// blocks) and extracts, lists or tests it.
//
//   zxsfx <file> <archive offset> [-o DIR] [-l] [-t] [-y] [-h] [paths...]
//
// Codecs: store, LZMA, LZMA2, the branch filters, Delta and zcm (the
// writer of a .zx.sfx only uses these). Archives may be encrypted (scrypt,
// AES-256-CTR, HMAC-SHA-256), solid and deduplicated. Not supported (the
// writer refuses them): volume sets, databases, streamed archives.

#include "host.h"
#include "lzma/Bra.h"
#include "lzma/Delta.h"
#include "lzma/Lzma2Dec.h"
#include "lzma/LzmaDec.h"
#include "zc.h"
#include "zc_zcm.h"
#include "zx_crypto.h"

#define ZCM_CODEC 0x10000

// ---------------------------------------------------------------- output

static void out_str(int fd, const char *s) { host_write(fd, s, (int)strlen(s)); }

static void out_num(int fd, i64 v) {
  char b[24];
  int n = 0;
  if (v < 0) {
    out_str(fd, "-");
    v = -v;
  }
  do {
    b[n++] = (char)('0' + v % 10);
    v /= 10;
  } while (v);
  char r[24];
  for (int i = 0; i < n; i++) r[i] = b[n - 1 - i];
  host_write(fd, r, n);
}

static void out_pad_num(int fd, i64 v, int width) {
  i64 t = v;
  int n = 1;
  while (t >= 10) {
    t /= 10;
    n++;
  }
  for (int i = n; i < width; i++) out_str(fd, " ");
  out_num(fd, v);
}

__attribute__((noreturn)) static void fail2(const char *a, const char *b) {
  out_str(2, "zx sfx: ");
  out_str(2, a);
  if (b) {
    out_str(2, ": ");
    out_str(2, b);
  }
  out_str(2, "\n");
  host_exit(2);
}

// ---------------------------------------------------------------- strings

static char *str_dup(const char *s, i64 n) {
  char *r = ZNEW(char, n + 1);
  memcpy(r, s, (size_t)n);
  r[n] = 0;
  return r;
}

static char *str_cat3(const char *a, const char *b, const char *c) {
  i64 la = (i64)strlen(a), lb = (i64)strlen(b), lc = (i64)strlen(c);
  char *r = ZNEW(char, la + lb + lc + 1);
  memcpy(r, a, (size_t)la);
  memcpy(r + la, b, (size_t)lb);
  memcpy(r + la + lb, c, (size_t)lc);
  r[la + lb + lc] = 0;
  return r;
}

static int str_eq(const char *a, const char *b) {
  while (*a && *a == *b) {
    a++;
    b++;
  }
  return *a == *b;
}

// ---------------------------------------------------------------- reading

static int g_fd;
static i64 g_base; // offset of the archive in the file
static i64 g_len;  // bytes of the archive

static void read_at(i64 off, void *buf, i64 n) {
  if (off < 0 || n < 0 || off + n > g_len) fail2("damaged archive", "read past the end");
  u8 *p = buf;
  while (n > 0) {
    int k = n > (1 << 30) ? (1 << 30) : (int)n;
    int r = host_pread(g_fd, p, k, g_base + off);
    if (r <= 0) fail2("read error", 0);
    p += r;
    off += r;
    n -= r;
  }
}

typedef struct {
  const u8 *p;
  i64 pos, end;
} R;

static void r_need(R *r, i64 n) {
  if (n < 0 || r->end - r->pos < n) fail2("damaged archive", "truncated record");
}
static i64 r_u8(R *r) {
  r_need(r, 1);
  return r->p[r->pos++];
}
static i64 r_vint(R *r) {
  u64 v = 0;
  for (int shift = 0; shift < 70; shift += 7) {
    i64 b = r_u8(r);
    if (shift == 63 && b > 1) break;
    v |= (u64)(b & 0x7F) << shift;
    if (b < 0x80) {
      if (v >= ((u64)1 << 63)) break;
      return (i64)v;
    }
  }
  fail2("damaged archive", "bad vint");
}
static const u8 *r_bytes(R *r, i64 n) {
  r_need(r, n);
  const u8 *p = r->p + r->pos;
  r->pos += n;
  return p;
}
static u32 le32(const u8 *p) {
  return (u32)p[0] | (u32)p[1] << 8 | (u32)p[2] << 16 | (u32)p[3] << 24;
}
static i64 le64(const u8 *p) {
  u64 v = 0;
  for (int i = 7; i >= 0; i--) v = (v << 8) | p[i];
  return (i64)v;
}

// ---------------------------------------------------------------- archive

typedef struct {
  i64 id, props;
  const u8 *propData;
} Coder;

typedef struct {
  i64 id, n;
  Coder c[8];
} Chain;

typedef struct {
  i64 offset, headerSize, packed, unpacked, chain;
} BlockRef;

typedef struct {
  i64 block, off, len;
} Extent;

enum { K_FILE = 0, K_DIR = 1, K_SYMLINK = 2, K_HARDLINK = 3 };

typedef struct {
  char *path;
  i64 kind, size, mode, mtime, nExt, nSparse;
  int hasMode, hasTime, hasSha, selected;
  Extent *ext;
  i64 *sparse; // pairs (offset, length)
  char *link;
  u8 sha[32];
} Entry;

static Chain g_chains[64];
static i64 g_nChains;
static BlockRef *g_blocks;
static i64 g_nBlocks;
static Entry *g_entries;
static i64 g_nEntries;
static int g_encrypted, g_encMeta;
static Aes256 g_aes;
static u8 g_macKey[32];

static Chain *find_chain(i64 id) {
  static Chain store;
  if (id == 0) return &store;
  for (i64 i = 0; i < g_nChains; i++) {
    if (g_chains[i].id == id) return &g_chains[i];
  }
  fail2("damaged archive", "unknown chain");
}

static void parse_chain(R *r) {
  if (g_nChains == 64) fail2("unsupported archive", "too many chains");
  Chain *c = &g_chains[g_nChains++];
  c->id = r_vint(r);
  c->n = r_vint(r);
  if (c->n > 8) fail2("unsupported archive", "chain too long");
  for (i64 i = 0; i < c->n; i++) {
    c->c[i].id = r_vint(r);
    c->c[i].props = r_vint(r);
    c->c[i].propData = r_bytes(r, c->c[i].props);
  }
}

// ---------------------------------------------------------------- blocks

static void *sz_alloc(ISzAllocPtr p, size_t n) {
  (void)p;
  return zalloc(n);
}
static void sz_free(ISzAllocPtr p, void *a) {
  (void)p;
  (void)a;
}
static const ISzAlloc g_szAlloc = {sz_alloc, sz_free};

static int is_filter(i64 id) { return id >= 0x40 && id <= 0x48; }

static const char *decode_coder(const Coder *c, u8 *in, i64 inLen, u8 *out,
                                i64 outLen) {
  size_t mark = zmark();
  const char *err = 0;
  if (c->id == 1 || c->id == 2) {
    SizeT dl = (SizeT)outLen, sl = (SizeT)inLen;
    ELzmaStatus st;
    SRes res;
    if (c->id == 1) {
      if (c->props != 1) return "bad LZMA2 props";
      res = Lzma2Decode(out, &dl, in, &sl, c->propData[0], LZMA_FINISH_END,
                        &st, &g_szAlloc);
    } else {
      if (c->props != 5) return "bad LZMA props";
      res = LzmaDecode(out, &dl, in, &sl, c->propData, 5, LZMA_FINISH_END,
                       &st, &g_szAlloc);
    }
    if (res != SZ_OK || dl != (SizeT)outLen) err = "damaged block data (LZMA)";
  } else if (c->id == ZCM_CODEC) {
    err = zcm_decode(in, inLen, out, outLen);
  } else {
    err = "unsupported codec";
  }
  zrelease(mark);
  return err;
}

static void filter_decode(const Coder *c, u8 *d, i64 n) {
  UInt32 pc = 0;
  if (c->id != 0x48) {
    if (c->props == 4) pc = le32(c->propData);
    else if (c->props != 0) fail2("damaged archive", "bad filter props");
  }
  switch (c->id) {
    case 0x40: {
      UInt32 st = Z7_BRANCH_CONV_ST_X86_STATE_INIT_VAL;
      z7_BranchConvSt_X86_Dec(d, (SizeT)n, pc, &st);
      break;
    }
    case 0x41: z7_BranchConv_ARM_Dec(d, (SizeT)n, pc); break;
    case 0x42: z7_BranchConv_ARMT_Dec(d, (SizeT)n, pc); break;
    case 0x43: z7_BranchConv_ARM64_Dec(d, (SizeT)n, pc); break;
    case 0x44: z7_BranchConv_PPC_Dec(d, (SizeT)n, pc); break;
    case 0x45: z7_BranchConv_SPARC_Dec(d, (SizeT)n, pc); break;
    case 0x46: z7_BranchConv_IA64_Dec(d, (SizeT)n, pc); break;
    case 0x47: z7_BranchConv_RISCV_Dec(d, (SizeT)n, pc); break;
    case 0x48: {
      if (c->props != 1) fail2("damaged archive", "bad Delta props");
      Byte state[DELTA_STATE_SIZE];
      Delta_Init(state);
      Delta_Decode(state, (unsigned)c->propData[0] + 1, d, (SizeT)n);
      break;
    }
  }
}

static u8 *g_cache;     // the decoded block
static i64 g_cacheIdx = -1;
static u8 *g_packed;    // the raw block (header and payload)
static u8 *g_work;      // scratch for a chain
static i64 g_maxUnpacked, g_maxRaw;

// Decodes the block at [off] of [size] bytes (header included) with chain
// [chainId] into [out] (unpackedSize bytes). [raw] holds size bytes.
static void decode_block(i64 off, i64 size, u8 *raw, u8 *out, u8 *work,
                         int encrypted, i64 *outSize) {
  read_at(off, raw, size);
  if (size < 10 || le32(raw) != 0x01425A58) fail2("damaged archive", "no block marker");
  R r = {raw, 4, size};
  i64 hs = r_vint(&r);
  if (hs > 256) fail2("damaged archive", "bad block header");
  i64 start = r.pos;
  i64 crcPos = start + hs;
  if (crcPos + 4 > size || crc32c_update(0, raw, crcPos) != le32(raw + crcPos)) {
    fail2("damaged archive", "block header CRC");
  }
  R f = {raw, start, crcPos};
  r_vint(&f); // type
  i64 chainId = r_vint(&f);
  i64 unpacked = r_vint(&f);
  i64 packed = r_vint(&f);
  i64 ct = r_u8(&f);
  static const int checkSize[] = {0, 4, 8, 32, 32};
  if (ct > 4) fail2("unsupported archive", "check type");
  if (ct == 4) fail2("unsupported archive", "BLAKE2sp block checks");
  const u8 *check = r_bytes(&f, checkSize[ct]);
  i64 headerSize = crcPos + 4;
  if (headerSize + packed != size) fail2("damaged archive", "block size");
  if (unpacked > g_maxUnpacked) fail2("damaged archive", "block too large");
  u8 *payload = raw + headerSize;
  i64 plen = packed;
  if (encrypted) {
    if (plen < 48) fail2("damaged archive", "encrypted block too short");
    Hmac h;
    u8 mac[32];
    hmac_init(&h, g_macKey, 32);
    hmac_update(&h, raw, crcPos);
    hmac_update(&h, payload, plen - 32);
    hmac_final(&h, mac);
    u8 diff = 0;
    for (int i = 0; i < 32; i++) diff |= mac[i] ^ payload[plen - 32 + i];
    if (diff) fail2("an encrypted block is damaged or the password is wrong", 0);
    aes256_ctr(&g_aes, payload, payload + 16, plen - 48);
    payload += 16;
    plen -= 48;
  }
  Chain *chain = find_chain(chainId);
  // Undo the coders, last first. A filter works in place; a compressor
  // writes to [out] or [work] (whichever is not its input).
  u8 *cur = payload;
  i64 curLen = plen;
  for (i64 i = chain->n - 1; i >= 0; i--) {
    const Coder *c = &chain->c[i];
    if (is_filter(c->id)) {
      filter_decode(c, cur, curLen);
      continue;
    }
    for (i64 j = 0; j < i; j++) {
      if (!is_filter(chain->c[j].id)) {
        fail2("unsupported archive", "a chain with two compressors");
      }
    }
    u8 *dst = cur == out ? work : out;
    const char *err = decode_coder(c, cur, curLen, dst, unpacked);
    if (err) fail2(err, 0);
    cur = dst;
    curLen = unpacked;
  }
  if (curLen != unpacked) fail2("damaged archive", "block size mismatch");
  if (cur != out) memmove(out, cur, (size_t)curLen);
  if (ct == 1) {
    if (crc32c_update(0, out, unpacked) != le32(check)) fail2("block check mismatch (damaged data)", 0);
  } else if (ct == 2) {
    if ((u64)xxh64(out, unpacked, 0) != (u64)le64(check)) fail2("block check mismatch (damaged data)", 0);
  } else if (ct == 3) {
    u8 d[32];
    sha256(out, unpacked, d);
    if (memcmp(d, check, 32) != 0) fail2("block check mismatch (damaged data)", 0);
  }
  *outSize = unpacked;
}

static const u8 *get_block(i64 idx) {
  if (idx == g_cacheIdx) return g_cache;
  if (idx < 0 || idx >= g_nBlocks) fail2("damaged archive", "bad block number");
  BlockRef *b = &g_blocks[idx];
  i64 n;
  g_cacheIdx = -1;
  decode_block(b->offset, b->headerSize + b->packed, g_packed, g_cache, g_work,
               g_encrypted, &n);
  if (n != b->unpacked) fail2("damaged archive", "block size mismatch");
  g_cacheIdx = idx;
  return g_cache;
}

// ---------------------------------------------------------------- index

static int path_ok(const char *p) {
  if (!*p || *p == '/') return 0;
  const char *s = p;
  for (;;) {
    const char *e = s;
    while (*e && *e != '/') e++;
    i64 n = e - s;
    if (n == 0 || (n == 1 && s[0] == '.') || (n == 2 && s[0] == '.' && s[1] == '.')) {
      return 0;
    }
    if (!*e) return 1;
    s = e + 1;
  }
}

static void parse_entry(R *r, Entry *e) {
  memset(e, 0, sizeof *e);
  e->kind = -1;
  int hasPath = 0;
  while (r->pos < r->end) {
    i64 type = r_vint(r);
    i64 len = r_vint(r);
    R f = {r_bytes(r, len), 0, len};
    switch (type) {
      case 0x51: {
        i64 n = r_vint(&f);
        e->path = str_dup((const char *)r_bytes(&f, n), n);
        if ((i64)strlen(e->path) != n) fail2("damaged archive", "bad path");
        hasPath = 1;
        break;
      }
      case 0x53: e->kind = r_vint(&f); break;
      case 0x55: e->size = r_vint(&f); break;
      case 0x57: {
        e->nExt = r_vint(&f);
        if (e->nExt > len) fail2("damaged archive", "extents");
        e->ext = ZNEW(Extent, e->nExt);
        for (i64 i = 0; i < e->nExt; i++) {
          e->ext[i].block = r_vint(&f);
          e->ext[i].off = r_vint(&f);
          e->ext[i].len = r_vint(&f);
        }
        break;
      }
      case 0x59: {
        i64 n = r_vint(&f);
        e->link = str_dup((const char *)r_bytes(&f, n), n);
        break;
      }
      case 0x5C:
        e->mode = r_vint(&f);
        e->hasMode = 1;
        break;
      case 0x62: {
        u64 z = (u64)r_vint(&f);
        e->mtime = (i64)(z >> 1) ^ -(i64)(z & 1);
        e->hasTime = 1;
        break;
      }
      case 0x6A:
        if (len != 32) fail2("damaged archive", "SHA-256");
        memcpy(e->sha, f.p, 32);
        e->hasSha = 1;
        break;
      case 0x72: {
        e->nSparse = r_vint(&f);
        if (e->nSparse > len) fail2("damaged archive", "sparse map");
        e->sparse = ZNEW(i64, e->nSparse * 2);
        for (i64 i = 0; i < e->nSparse * 2; i++) e->sparse[i] = r_vint(&f);
        break;
      }
      default:
        if (type & 1) fail2("unsupported archive", "unknown critical entry record");
    }
  }
  if (!hasPath || e->kind < 0) fail2("damaged archive", "entry without path or kind");
  if (!path_ok(e->path)) fail2("unsafe path in the archive", e->path);
  if (e->kind == K_HARDLINK && (!e->link || !path_ok(e->link))) {
    fail2("unsafe hard link in the archive", e->path);
  }
}

static void parse_index(const u8 *p, i64 n) {
  R r = {p, 0, n};
  i64 cap = 64;
  g_entries = ZNEW(Entry, cap);
  while (r.pos < r.end) {
    i64 type = r_vint(&r);
    i64 len = r_vint(&r);
    R f = {r_bytes(&r, len), 0, len};
    switch (type) {
      case 0x10: parse_chain(&f); break;
      case 0x12: {
        g_nBlocks = r_vint(&f);
        if (g_nBlocks > len) fail2("damaged archive", "block table");
        g_blocks = ZNEW(BlockRef, g_nBlocks);
        for (i64 i = 0; i < g_nBlocks; i++) {
          BlockRef *b = &g_blocks[i];
          b->offset = r_vint(&f);
          b->headerSize = r_vint(&f);
          b->packed = r_vint(&f);
          b->unpacked = r_vint(&f);
          b->chain = r_vint(&f);
        }
        break;
      }
      case 0x21: {
        if (g_nEntries == cap) {
          Entry *ne = ZNEW(Entry, cap * 2);
          memcpy(ne, g_entries, sizeof(Entry) * (size_t)cap);
          g_entries = ne;
          cap *= 2;
        }
        parse_entry(&f, &g_entries[g_nEntries++]);
        break;
      }
      case 0x46: {
        f.pos += 6;
        u64 req = (u64)le64(r_bytes(&f, 8));
        if (req & ~(u64)0xF) fail2("unsupported archive", "required features of the generation");
        break;
      }
      default:
        if (type & 1) fail2("unsupported archive", "unknown critical index record");
    }
  }
}

// ---------------------------------------------------------------- open

static char g_pw[1024];
static int g_pwGiven;

static void open_archive(void) {
  u8 h[64];
  if (g_len < 64 + 40) fail2("not a zx archive", 0);
  read_at(0, h, 64);
  static const u8 magic[8] = {0x89, 0x5A, 0x58, 0x0D, 0x0A, 0x1A, 0x0A, 0x00};
  if (memcmp(h, magic, 8) != 0) fail2("not a zx archive", 0);
  i64 recSize = le32(h + 56);
  if (64 + recSize > g_len) fail2("damaged archive", "header");
  u8 *rec = ZNEW(u8, recSize);
  read_at(64, rec, recSize);
  // CRC-32C of bytes 0..59 and the records, as one stream.
  u8 *all = ZNEW(u8, 60 + recSize);
  memcpy(all, h, 60);
  memcpy(all + 60, rec, (size_t)recSize);
  if (crc32c_update(0, all, 60 + recSize) != le32(h + 60)) fail2("damaged archive", "header CRC");
  if ((h[8] | h[9] << 8) != 1) fail2("unsupported archive", "format version");
  i64 flags = h[22] | h[23] << 8;
  u64 req = (u64)le64(h + 24);
  if (flags & 1) fail2("unsupported archive", "streamed archives");
  if (flags & 4) fail2("unsupported archive", "volume sets");
  if (req & ~(u64)0xF) fail2("unsupported archive", "required features");
  g_encrypted = (req & 2) != 0;
  g_encMeta = (flags & 2) != 0;
  const u8 *kdf = 0;
  i64 kdfLen = 0;
  R r = {rec, 0, recSize};
  while (r.pos < r.end) {
    i64 type = r_vint(&r);
    i64 len = r_vint(&r);
    const u8 *p = r_bytes(&r, len);
    if (type == 0x05) {
      kdf = p;
      kdfLen = len;
    } else if (type == 0x0B) {
      R f = {p, 0, len};
      parse_chain(&f);
    } else if (type & 1) {
      fail2("unsupported archive", "unknown critical header record");
    }
  }
  if (g_encrypted) {
    if (!kdf) fail2("damaged archive", "no key derivation record");
    R f = {kdf, 0, kdfLen};
    i64 kdfId = r_vint(&f);
    i64 ps = r_vint(&f);
    R pr = {r_bytes(&f, ps), 0, ps};
    i64 cipher = r_vint(&f);
    const u8 *check = r_bytes(&f, 16);
    if (kdfId != 1 || cipher != 1) fail2("unsupported encryption", 0);
    i64 log2N = r_vint(&pr), rr = r_vint(&pr), pp = r_vint(&pr);
    const u8 *salt = r_bytes(&pr, 32);
    if (log2N < 1 || log2N > 24 || rr < 1 || rr > 64 || pp < 1 || pp > 64) {
      fail2("unsupported encryption", "scrypt parameters");
    }
    int n = g_pwGiven ? (int)strlen(g_pw)
                      : host_password("Password: ", g_pw, sizeof g_pw - 1);
    if (n < 0) n = 0;
    g_pw[n] = 0;
    u8 pwh[32], dk[64];
    sha256((const u8 *)g_pw, n, pwh);
    out_str(2, "Checking the password...\n");
    scrypt(pwh, 32, salt, 32, (i64)1 << log2N, rr, pp, dk, 64);
    aes256_init(&g_aes, dk);
    memcpy(g_macKey, dk + 32, 32);
    Hmac hm;
    u8 mac[32];
    hmac_init(&hm, g_macKey, 32);
    hmac_update(&hm, (const u8 *)"zx password check", 17);
    hmac_final(&hm, mac);
    if (memcmp(mac, check, 16) != 0) fail2("wrong password", 0);
  }
  // The last Footer.
  u8 ft[40];
  read_at(g_len - 40, ft, 40);
  if (le32(ft + 36) != 0x1A455A58 || crc32c_update(0, ft, 32) != le32(ft + 32)) {
    fail2("damaged archive", "footer");
  }
  i64 indexOff = le64(ft), indexSize = le64(ft + 8);
  i64 sealSize = le32(ft + 24);
  if (indexOff < 64 || indexSize < 0 || indexOff + indexSize + sealSize != g_len - 40) {
    fail2("damaged archive", "footer offsets");
  }
  // The Index blocks, one after the other.
  u8 *index = 0;
  i64 indexLen = 0;
  i64 pos = indexOff;
  while (pos < indexOff + indexSize) {
    u8 hb[300];
    i64 k = indexOff + indexSize - pos < 300 ? indexOff + indexSize - pos : 300;
    read_at(pos, hb, k);
    R br = {hb, 4, k};
    if (k < 10 || le32(hb) != 0x01425A58) fail2("damaged archive", "index block");
    i64 hs = r_vint(&br);
    i64 crcPos = br.pos + hs;
    R f = {hb, br.pos, crcPos < k ? crcPos : k};
    i64 type = r_vint(&f);
    r_vint(&f);
    i64 unpacked = r_vint(&f);
    i64 packed = r_vint(&f);
    if (type != 5 || unpacked > ((i64)1 << 31) || packed > ((i64)1 << 31)) {
      fail2("damaged archive", "index block");
    }
    i64 size = crcPos + 4 + packed;
    u8 *raw = ZNEW(u8, size);
    u8 *work = ZNEW(u8, unpacked + 16);
    u8 *ni = ZNEW(u8, indexLen + unpacked);
    if (indexLen) memcpy(ni, index, (size_t)indexLen);
    i64 got;
    i64 saveMax = g_maxUnpacked;
    g_maxUnpacked = (i64)1 << 31;
    decode_block(pos, size, raw, ni + indexLen, work, g_encMeta, &got);
    g_maxUnpacked = saveMax;
    index = ni;
    indexLen += got;
    pos += size;
  }
  parse_index(index, indexLen);
  // Buffers for the data blocks.
  g_maxUnpacked = 0;
  g_maxRaw = 0;
  for (i64 i = 0; i < g_nBlocks; i++) {
    BlockRef *b = &g_blocks[i];
    if (b->unpacked > g_maxUnpacked) g_maxUnpacked = b->unpacked;
    if (b->headerSize + b->packed > g_maxRaw) g_maxRaw = b->headerSize + b->packed;
    if (b->offset < 64 || b->offset + b->headerSize + b->packed > indexOff) {
      fail2("damaged archive", "block table");
    }
  }
  if (g_maxUnpacked > ((i64)1 << 30)) fail2("unsupported archive", "blocks larger than 1 GiB");
  g_cache = ZNEW(u8, g_maxUnpacked + 16);
  g_work = ZNEW(u8, g_maxUnpacked + 16);
  g_packed = ZNEW(u8, g_maxRaw + 16);
}

// ---------------------------------------------------------------- extract

static const char *g_outDir = ".";
static int g_overwrite, g_list, g_test, g_quiet;

static char *out_path(const char *rel) {
  if (str_eq(g_outDir, ".")) return str_dup(rel, (i64)strlen(rel));
  return str_cat3(g_outDir, "/", rel);
}

// Creates the parent directories of rel (inside the output folder),
// refusing to go through a symlink.
static void make_parents(const char *rel) {
  i64 n = (i64)strlen(rel);
  for (i64 i = 0; i < n; i++) {
    if (rel[i] != '/') continue;
    size_t mark = zmark();
    char *d = out_path(str_dup(rel, i));
    int k = host_kind(d);
    if (k == 2) fail2("refusing to write through a symlink", d);
    if (k < 0) {
      int r = host_mkdir(d, 0755);
      if (r < 0 && host_kind(d) != 1) fail2("can not create the folder", d);
    } else if (k != 1) {
      fail2("not a folder", d);
    }
    zrelease(mark);
  }
}

// Writes the content of a file entry to [fd] (fd < 0: only checks it).
static void write_content(Entry *e, int fd) {
  Sha256 sh;
  sha256_init(&sh);
  i64 written = 0;
  static u8 zeros[65536];
  i64 ext = 0, extOff = 0; // position in the extents
  // The data ranges: the whole file, or the sparse map.
  i64 nRanges = e->nSparse ? e->nSparse : 1;
  for (i64 ri = 0; ri < nRanges; ri++) {
    i64 rOff = e->nSparse ? e->sparse[ri * 2] : 0;
    i64 rLen = e->nSparse ? e->sparse[ri * 2 + 1] : e->size;
    if (rOff < written || rOff + rLen > e->size) fail2("damaged archive", "sparse map");
    while (written < rOff) {
      i64 k = rOff - written < 65536 ? rOff - written : 65536;
      sha256_update(&sh, zeros, k);
      if (fd >= 0 && host_write(fd, zeros, (int)k) != k) fail2("write error", e->path);
      written += k;
    }
    i64 left = rLen;
    while (left > 0) {
      if (ext >= e->nExt) fail2("damaged archive", "extents shorter than the file");
      Extent *x = &e->ext[ext];
      const u8 *b = get_block(x->block);
      if (x->off < 0 || x->off + x->len > g_blocks[x->block].unpacked) {
        fail2("damaged archive", "extent outside its block");
      }
      i64 k = x->len - extOff < left ? x->len - extOff : left;
      const u8 *p = b + x->off + extOff;
      sha256_update(&sh, p, k);
      if (fd >= 0) {
        for (i64 d = 0; d < k;) {
          int c = k - d > (1 << 30) ? (1 << 30) : (int)(k - d);
          if (host_write(fd, p + d, c) != c) fail2("write error", e->path);
          d += c;
        }
      }
      written += k;
      left -= k;
      extOff += k;
      if (extOff == x->len) {
        ext++;
        extOff = 0;
      }
    }
  }
  while (written < e->size) {
    i64 k = e->size - written < 65536 ? e->size - written : 65536;
    sha256_update(&sh, zeros, k);
    if (fd >= 0 && host_write(fd, zeros, (int)k) != k) fail2("write error", e->path);
    written += k;
  }
  if (ext != e->nExt) fail2("damaged archive", "extents longer than the file");
  if (e->hasSha) {
    u8 d[32];
    sha256_final(&sh, d);
    if (memcmp(d, e->sha, 32) != 0) fail2("SHA-256 mismatch (damaged data)", e->path);
  }
}

static void remove_existing(const char *p) {
  int k = host_kind(p);
  if (k < 0) return;
  if (!g_overwrite) fail2("already exists (use -y to overwrite)", p);
  if (k == 1) return;
  if (host_unlink(p) < 0) fail2("can not replace", p);
}

static i64 find_entry(const char *path) {
  for (i64 i = 0; i < g_nEntries; i++) {
    if (str_eq(g_entries[i].path, path)) return i;
  }
  return -1;
}

static void extract_all(void) {
  // Files, folders and hard links first; symlinks last, so that no file
  // is written through a symlink of the archive.
  for (i64 i = 0; i < g_nEntries; i++) {
    Entry *e = &g_entries[i];
    if (!e->selected) continue;
    size_t mark = zmark();
    if (g_test) {
      if (e->kind == K_FILE) write_content(e, -1);
      if (!g_quiet) {
        out_str(1, "OK  ");
        out_str(1, e->path);
        out_str(1, "\n");
      }
      zrelease(mark);
      continue;
    }
    make_parents(e->path);
    char *p = out_path(e->path);
    if (!g_quiet) {
      out_str(1, e->path);
      out_str(1, "\n");
    }
    if (e->kind == K_DIR) {
      int k = host_kind(p);
      if (k == 2) fail2("refusing to write through a symlink", p);
      if (k < 0 && host_mkdir(p, 0700) < 0) fail2("can not create the folder", p);
    } else if (e->kind == K_FILE) {
      remove_existing(p);
      int fd = host_open(p, 2);
      if (fd < 0) fail2("can not create", p);
      write_content(e, fd);
      host_close(fd);
      if (e->hasMode) host_chmod(p, (int)(e->mode & 07777));
      if (e->hasTime) host_utime(p, e->mtime);
    } else if (e->kind == K_HARDLINK) {
      i64 t = find_entry(e->link);
      if (t < 0 || t >= i) fail2("damaged archive", "hard link target");
      remove_existing(p);
      if (host_link(out_path(e->link), p) < 0) fail2("can not create the link", p);
    } else if (e->kind != K_SYMLINK) {
      out_str(2, "zx sfx: skipped (special file): ");
      out_str(2, e->path);
      out_str(2, "\n");
    }
    zrelease(mark);
  }
  if (g_test) return;
  for (i64 i = 0; i < g_nEntries; i++) {
    Entry *e = &g_entries[i];
    if (!e->selected || e->kind != K_SYMLINK) continue;
    size_t mark = zmark();
    make_parents(e->path);
    char *p = out_path(e->path);
    remove_existing(p);
    if (!e->link || host_symlink(e->link, p) < 0) fail2("can not create the symlink", p);
    if (e->hasTime) host_utime(p, e->mtime);
    zrelease(mark);
  }
  // Folder modes and times last (deepest first), as writing changes them.
  for (i64 i = g_nEntries - 1; i >= 0; i--) {
    Entry *e = &g_entries[i];
    if (!e->selected || e->kind != K_DIR) continue;
    size_t mark = zmark();
    char *p = out_path(e->path);
    if (host_kind(p) == 1) {
      host_chmod(p, e->hasMode ? (int)(e->mode & 07777) : 0755);
      if (e->hasTime) host_utime(p, e->mtime);
    }
    zrelease(mark);
  }
}

static void list_all(void) {
  i64 total = 0, files = 0;
  for (i64 i = 0; i < g_nEntries; i++) {
    Entry *e = &g_entries[i];
    if (!e->selected) continue;
    const char *k = e->kind == K_DIR ? "D" : e->kind == K_SYMLINK ? "L" : e->kind == K_HARDLINK ? "H" : " ";
    out_str(1, k);
    out_pad_num(1, e->kind == K_FILE ? e->size : 0, 14);
    out_str(1, "  ");
    out_str(1, e->path);
    if (e->link) {
      out_str(1, e->kind == K_SYMLINK ? " -> " : " => ");
      out_str(1, e->link);
    }
    out_str(1, "\n");
    if (e->kind == K_FILE) {
      total += e->size;
      files++;
    }
  }
  out_pad_num(1, total, 15);
  out_str(1, "  ");
  out_num(1, files);
  out_str(1, " files\n");
}

// ---------------------------------------------------------------- main

static char *arg(int i) {
  int n = host_argv(i, 0, 0);
  if (n < 0) return 0;
  char *s = ZNEW(char, n + 1);
  host_argv(i, s, n + 1);
  return s;
}

static void usage(void) {
  out_str(1,
          "A self-extracting zx archive. Usage:\n"
          "  sh ARCHIVE.zx.sfx [-o DIR] [-y] [FILE...]   extract (to DIR)\n"
          "  sh ARCHIVE.zx.sfx -l                        list the files\n"
          "  sh ARCHIVE.zx.sfx -t                        test the files\n"
          "Options: -o DIR  output folder (created when missing)\n"
          "         -pPASS  the password (asked when not given)\n"
          "         -y      overwrite existing files\n"
          "         -q      quiet\n"
          "zx can read the archive too: zx x ARCHIVE.zx.sfx\n");
}

int zxsfx_main(void) {
  zc_tables_init();
  int argc = host_argc();
  if (argc < 2) {
    usage();
    return 2;
  }
  char *file = arg(0);
  char *offs = arg(1);
  i64 base = 0;
  for (char *c = offs; *c; c++) {
    if (*c < '0' || *c > '9') fail2("bad archive offset", offs);
    base = base * 10 + (*c - '0');
  }
  char **sel = ZNEW(char *, argc);
  int nSel = 0;
  for (int i = 2; i < argc; i++) {
    char *a = arg(i);
    if (str_eq(a, "-h") || str_eq(a, "--help")) {
      usage();
      return 0;
    } else if (str_eq(a, "-l")) {
      g_list = 1;
    } else if (str_eq(a, "-t")) {
      g_test = 1;
    } else if (str_eq(a, "-y")) {
      g_overwrite = 1;
    } else if (str_eq(a, "-q")) {
      g_quiet = 1;
    } else if (a[0] == '-' && a[1] == 'p') {
      i64 n = (i64)strlen(a + 2);
      if (n >= (i64)sizeof g_pw) fail2("password too long", 0);
      memcpy(g_pw, a + 2, (size_t)n + 1);
      g_pwGiven = 1;
    } else if (str_eq(a, "-o")) {
      if (i + 1 >= argc) fail2("-o needs a folder", 0);
      g_outDir = arg(++i);
    } else if (a[0] == '-' && a[1] == 'o' && a[2]) {
      g_outDir = a + 2;
    } else if (str_eq(a, "--")) {
      for (i++; i < argc; i++) sel[nSel++] = arg(i);
    } else if (a[0] == '-') {
      fail2("unknown option (-h for help)", a);
    } else {
      sel[nSel++] = a;
    }
  }
  g_fd = host_open(file, 0);
  if (g_fd < 0) fail2("can not open", file);
  i64 size = host_fsize(g_fd);
  if (size < 0 || base > size) fail2("can not read", file);
  g_base = base;
  g_len = size - base;
  open_archive();
  for (i64 i = 0; i < g_nEntries; i++) {
    Entry *e = &g_entries[i];
    e->selected = nSel == 0;
    for (int j = 0; j < nSel && !e->selected; j++) {
      i64 n = (i64)strlen(sel[j]);
      while (n > 1 && sel[j][n - 1] == '/') n--;
      if ((i64)strlen(e->path) >= n && memcmp(e->path, sel[j], (size_t)n) == 0 &&
          (e->path[n] == 0 || e->path[n] == '/')) {
        e->selected = 1;
      }
    }
  }
  // A hard link needs its target extracted too.
  for (i64 i = 0; i < g_nEntries; i++) {
    Entry *e = &g_entries[i];
    if (e->selected && e->kind == K_HARDLINK) {
      i64 t = find_entry(e->link);
      if (t >= 0) g_entries[t].selected = 1;
    }
  }
  if (g_list) {
    list_all();
    return 0;
  }
  if (!g_test && !str_eq(g_outDir, ".")) {
    int k = host_kind(g_outDir);
    if (k < 0) {
      // create the output folder and its parents
      i64 n = (i64)strlen(g_outDir);
      for (i64 i = 1; i <= n; i++) {
        if (i == n || g_outDir[i] == '/') {
          char *d = str_dup(g_outDir, i);
          if (host_kind(d) < 0 && host_mkdir(d, 0755) < 0) fail2("can not create the folder", d);
        }
      }
    } else if (k != 1 && k != 2) {
      fail2("not a folder", g_outDir);
    }
  }
  extract_all();
  if (g_test) out_str(1, "Everything is OK\n");
  return 0;
}

#ifdef __wasm__
int _start(void) { return zxsfx_main(); }
#endif
