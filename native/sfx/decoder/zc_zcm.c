// zxsfx decoder: the decoding side of zcm.dart: the stream header, the
// chunks, the segment headers of a chunk, and the inverse transforms
// (E8/E9 of paq8px's ExeFilter, the English dictionary, 16-bit audio byte
// order).

#include "zc_zcm.h"

#include "zc_dict.h"

#ifdef ZC_TRACE
// Tests: called with each segment (kind 0: type, info) and each bit's
// probability (kind 1: p).
void (*zcm_trace_hook)(int kind, i64 a, i64 b);
#define TRACE(k, a, b) \
  if (zcm_trace_hook) zcm_trace_hook(k, a, b)
#else
#define TRACE(k, a, b)
#endif

#define F_INDEPENDENT 1
#define F_LSTM 2
#define F_DETECT 4
#define F_E8E9 8
#define F_DICT 16
#define SOLID_CHUNK (1 << 24)
#define MIN_MIB 4
#define MAX_MIB (64 << 10)

static u32 g_crcTable[256];

u32 crc32_update(u32 crc, const u8 *p, i64 n) {
  if (g_crcTable[1] == 0) {
    for (u32 i = 0; i < 256; i++) {
      u32 c = i;
      for (int k = 0; k < 8; k++) c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1;
      g_crcTable[i] = c;
    }
  }
  crc = ~crc;
  for (i64 i = 0; i < n; i++) crc = g_crcTable[(crc ^ p[i]) & 255] ^ (crc >> 8);
  return ~crc;
}

typedef struct {
  const u8 *p;
  i64 pos, end;
} Rd;

static int rd_byte(Rd *r, i64 *v) {
  if (r->pos >= r->end) return 0;
  *v = r->p[r->pos++];
  return 1;
}

static int rd_vint(Rd *r, i64 *v) {
  i64 x = 0, b;
  for (int shift = 0; shift < 63; shift += 7) {
    if (!rd_byte(r, &b)) return 0;
    x |= (b & 0x7F) << shift;
    if (b < 0x80) {
      *v = x;
      return 1;
    }
  }
  return 0;
}

typedef struct {
  i64 level, flags, mem, seg, cells, layers, horizon, orig;
} Header;

static const char *read_header(Rd *r, Header *h) {
  i64 b0, b1, b2, version;
  if (!rd_byte(r, &b0) || !rd_byte(r, &b1) || !rd_byte(r, &b2)) {
    return "zcm: unexpected end of data";
  }
  if (b0 != 0x7A || b1 != 0x63 || b2 != 0x6D) return "zcm: bad magic";
  if (!rd_byte(r, &version) || !rd_byte(r, &h->level) ||
      !rd_byte(r, &h->flags) || !rd_vint(r, &h->mem) || !rd_vint(r, &h->seg)) {
    return "zcm: unexpected end of data";
  }
  if (version != 1) return "zcm: unsupported version";
  if (h->level < 1 || h->level > 9 || (h->flags & ~31) != 0) {
    return "zcm: data error (bad header)";
  }
  if (h->mem < MIN_MIB || h->mem > MAX_MIB) {
    return "zcm: data error (bad memory budget)";
  }
  int indep = (h->flags & F_INDEPENDENT) != 0;
  if (indep != (h->seg > 0) || h->seg > ((i64)1 << 40)) {
    return "zcm: data error (bad segments)";
  }
  h->cells = h->layers = h->horizon = 0;
  if (h->flags & F_LSTM) {
    if (!rd_vint(r, &h->cells) || !rd_byte(r, &h->layers) ||
        !rd_vint(r, &h->horizon)) {
      return "zcm: unexpected end of data";
    }
    if (h->level != 9 || h->cells < 1 || h->cells > 1024 || h->layers < 1 ||
        h->layers > 8 || h->horizon < 1 || h->horizon > 1000) {
      return "zcm: data error (bad LSTM size)";
    }
  }
  if (!rd_vint(r, &h->orig)) return "zcm: unexpected end of data";
  return 0;
}

i64 zcm_budget(const u8 *in, i64 inLen) {
  Rd r = {in, 0, inLen};
  Header h;
  if (read_header(&r, &h)) return -1;
  return h.mem << 20;
}

static ZPredictor *new_predictor(const Header *h) {
  return zpredictor_new(h->level, h->mem << 20,
                        (h->flags & F_LSTM) ? h->cells : 0, h->layers,
                        h->horizon);
}

static void e8e9_decode(u8 *b, i64 off, i64 len, i64 base) {
  for (i64 i = 5; i < len; i++) {
    i64 p = off + i;
    i64 hi = b[p];
    i64 op = b[p - 4];
    if ((hi == 0 || hi == 0xFF) &&
        (op == 0xE8 || op == 0xE9 || (b[p - 5] == 0x0F && (op & 0xF0) == 0x80))) {
      i64 a = (b[p - 1] ^ 176) | (b[p - 2] ^ 176) << 8 | (b[p - 3] ^ 176) << 16 |
              hi << 24;
      a = (a - base - i - 1) & 0x1FFFFFF;
      if (a >= 0x1000000) a -= 0x2000000;
      b[p] = (u8)((a >> 24) & 255);
      b[p - 1] = (u8)((a >> 16) & 255);
      b[p - 2] = (u8)((a >> 8) & 255);
      b[p - 3] = (u8)(a & 255);
    }
  }
}

static void swap16(u8 *b, i64 off, i64 len) {
  i64 end = off + (len & ~(i64)1);
  for (i64 i = off; i < end; i += 2) {
    u8 t = b[i];
    b[i] = b[i + 1];
    b[i + 1] = t;
  }
}

// Bytes the range decoder read past the end of the chunk.
static i64 overrun(const ZDecoder *d) {
  return d->pos > d->end ? d->pos - d->end : 0;
}

// zcmDecodeChunk: [len] bytes into out[off..], the history of [pred] at
// stream position [base].
static const char *decode_chunk(ZPredictor *pred, const Header *h,
                                const u8 *packed, i64 packedLen, u8 *out,
                                i64 off, i64 len, i64 base, u8 *scratch) {
  ZDecoder dec;
  zdecoder_init(&dec, packed, 0, packedLen);
  i64 done = 0;
  while (done < len) {
    i64 type = ZT_BINARY, bl = len, info = 0, tl = -1;
    if (h->flags & F_DETECT) {
      type = zdecoder_decodeDirect(&dec, 4);
      if (type >= ZT_COUNT) return "zcm: data error (bad segment type)";
      bl = zdecoder_decodeDirect(&dec, 32);
      if (bl < 1 || bl > len - done) return "zcm: data error (bad segment length)";
      if (zt_hasInfo((int)type)) {
        info = zdecoder_decodeDirect(&dec, 32);
        int bad = type == ZT_AUDIO
                      ? info > 15
                      : (info >= (1 << 26) || (info & 0xFFFFFF) == 0 ||
                         (info & 0xFFFFFF) > ZT_MAX_IMAGE_STRIDE);
        if (info < 1 || bad) return "zcm: data error (bad segment info)";
      }
      if (type == ZT_TEXT && (h->flags & F_DICT) &&
          zdecoder_decodeDirect(&dec, 1) != 0) {
        tl = zdecoder_decodeDirect(&dec, 32);
        if (tl < 1 || tl > bl * 2 + 16) return "zcm: data error (bad text length)";
      }
      if (overrun(&dec) > 4) return "zcm: unexpected end of data";
    }
    TRACE(0, type, info);
    zpredictor_setSegment(pred, type, info);
    // The transformed text goes to [scratch] (2 * len + 16 bytes).
    u8 *target = tl >= 0 ? scratch : out;
    i64 start = tl >= 0 ? 0 : off + done;
    i64 end = tl >= 0 ? tl : start + bl;
    for (i64 i = start; i < end; i++) {
      i64 c = 0;
      for (int j = 0; j < 8; j++) {
        i64 pp = zpredictor_p(pred);
        TRACE(1, pp, 0);
        i64 bit = zdecoder_decode(&dec, pp);
        zpredictor_update(pred, bit);
        c = (c << 1) | bit;
      }
      target[i] = (u8)c;
      if (overrun(&dec) > 4) return "zcm: unexpected end of data";
    }
    if (tl >= 0) {
      if (!zdict_decode(target, tl, out + off + done, bl)) {
        return "zcm: data error (bad text transform)";
      }
    }
    if (type == ZT_EXE && (h->flags & F_E8E9)) {
      e8e9_decode(out, off + done, bl, base + done);
    }
    if (type == ZT_AUDIO && (info & 1) != 0 && (info & 4) == 0) {
      swap16(out, off + done, bl);
    }
    done += bl;
  }
  if (overrun(&dec) > 0) return "zcm: unexpected end of data";
  return 0;
}

const char *zcm_decode(const u8 *in, i64 inLen, u8 *out, i64 outLen) {
  Rd r = {in, 0, inLen};
  Header h;
  const char *err = read_header(&r, &h);
  if (err) return err;
  i64 expect = h.orig == 0 ? outLen : h.orig - 1;
  if (expect != outLen) return "zcm: data error (size mismatch)";
  int indep = (h.flags & F_INDEPENDENT) != 0;
  i64 maxChunk = indep ? h.seg : SOLID_CHUNK;
  // Scratch for the dictionary transform of text segments (allocated
  // before the predictors: they are released per independent chunk).
  i64 sc = maxChunk < outLen ? maxChunk : outLen;
  u8 *scratch = 0;
  if (h.flags & F_DICT) {
    zdict_load(); // stays in the arena, before the mark
    scratch = ZNEW(u8, sc * 2 + 16);
  }
  size_t mark = zmark();
  ZPredictor *pred = 0;
  i64 total = 0;
  for (;;) {
    i64 rawLen, packedLen;
    if (!rd_vint(&r, &rawLen)) return "zcm: unexpected end of data";
    if (rawLen == 0) break;
    if (rawLen > maxChunk) return "zcm: data error (chunk too large)";
    if (total + rawLen > outLen) return "zcm: data error (too long)";
    if (r.end - r.pos < 4) return "zcm: unexpected end of data";
    u32 crc = (u32)in[r.pos] | (u32)in[r.pos + 1] << 8 |
              (u32)in[r.pos + 2] << 16 | (u32)in[r.pos + 3] << 24;
    r.pos += 4;
    if (!rd_vint(&r, &packedLen)) return "zcm: unexpected end of data";
    if (packedLen > rawLen + (rawLen >> 3) + 4096) {
      return "zcm: data error (packed size)";
    }
    if (packedLen > r.end - r.pos) return "zcm: unexpected end of data";
    if (pred == 0 || indep) {
      zrelease(mark);
      pred = new_predictor(&h);
    }
    err = decode_chunk(pred, &h, in + r.pos, packedLen, out, total, rawLen,
                       indep ? 0 : total, scratch);
    if (err) return err;
    if (crc32_update(0, out + total, rawLen) != crc) return "zcm: CRC error";
    r.pos += packedLen;
    total += rawLen;
  }
  zrelease(mark);
  if (total != outLen) return "zcm: data error (size mismatch)";
  return 0;
}
