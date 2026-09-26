// SHA-1: port of C/Sha1.c of 7-Zip (public domain; the portable
// Sha1_UpdateBlocks with a 16 word message schedule ring, kNumW 16).

import 'dart:typed_data';

/// SHA1_BLOCK_SIZE
const int kSha1BlockSize = 64;

/// SHA1_DIGEST_SIZE
const int kSha1DigestSize = 20;

// Message schedule ring, reused by every call (the code is synchronous).
final Uint32List _w = Uint32List(16);

int _rotl(int x, int n) => ((x << n) | (x >> (32 - n))) & 0xFFFFFFFF;

// Sha1_UpdateBlocks
void sha1UpdateBlocks(
    Uint32List state, Uint8List data, int off, int numBlocks) {
  if (numBlocks == 0) return;
  final w = _w;
  var a = state[0];
  var b = state[1];
  var c = state[2];
  var d = state[3];
  var e = state[4];
  do {
    for (var i = 0; i < 80; i++) {
      int wi;
      if (i < 16) {
        final p = off + i * 4;
        wi = (data[p] << 24) |
            (data[p + 1] << 16) |
            (data[p + 2] << 8) |
            data[p + 3];
        w[i] = wi;
      } else {
        // w1: rotlFixed(w(i-3) ^ w(i-8) ^ w(i-14) ^ w(i-16), 1)
        final x =
            w[(i - 3) & 15] ^ w[(i - 8) & 15] ^ w[(i - 14) & 15] ^ w[i & 15];
        wi = ((x << 1) | (x >> 31)) & 0xFFFFFFFF;
        w[i & 15] = wi;
      }
      int f;
      if (i < 20) {
        f = 0x5a827999 + (d ^ (b & (c ^ d))); // f0
      } else if (i < 40) {
        f = 0x6ed9eba1 + (b ^ c ^ d); // f1
      } else if (i < 60) {
        f = 0x8f1bbcdc + ((b & c) | (d & (b | c))); // f2
      } else {
        f = 0xca62c1d6 + (b ^ c ^ d); // f3
      }
      final tmp = (e + f + wi + _rotl(a, 5)) & 0xFFFFFFFF;
      e = d;
      d = c;
      c = _rotl(b, 30);
      b = a;
      a = tmp;
    }
    a = (a + state[0]) & 0xFFFFFFFF;
    b = (b + state[1]) & 0xFFFFFFFF;
    c = (c + state[2]) & 0xFFFFFFFF;
    d = (d + state[3]) & 0xFFFFFFFF;
    e = (e + state[4]) & 0xFFFFFFFF;
    state[0] = a;
    state[1] = b;
    state[2] = c;
    state[3] = d;
    state[4] = e;
    off += kSha1BlockSize;
  } while (--numBlocks != 0);
}

/// CSha1
class Sha1 {
  final Uint32List state = Uint32List(5);
  int count = 0;
  final Uint8List buffer = Uint8List(kSha1BlockSize);

  Sha1() {
    init();
  }

  // Sha1_InitState / Sha1_Init
  void init() {
    count = 0;
    state[0] = 0x67452301;
    state[1] = 0xEFCDAB89;
    state[2] = 0x98BADCFE;
    state[3] = 0x10325476;
    state[4] = 0xC3D2E1F0;
  }

  // Sha1_Update
  void update(Uint8List data, [int off = 0, int? size]) {
    var len = size ?? data.length - off;
    if (len == 0) return;
    {
      final pos = count & (kSha1BlockSize - 1);
      final num = kSha1BlockSize - pos;
      count += len;
      if (num > len) {
        buffer.setRange(pos, pos + len, data, off);
        return;
      }
      if (pos != 0) {
        len -= num;
        buffer.setRange(pos, pos + num, data, off);
        off += num;
        sha1UpdateBlocks(state, buffer, 0, 1);
      }
    }
    final numBlocks = len >> 6;
    sha1UpdateBlocks(state, data, off, numBlocks);
    len &= kSha1BlockSize - 1;
    if (len == 0) return;
    off += numBlocks << 6;
    buffer.setRange(0, len, data, off);
  }

  // Sha1_Final. Writes the digest to [digest] at [off] and resets the
  // state for a new hash.
  void finalTo(Uint8List digest, [int off = 0]) {
    var pos = count & (kSha1BlockSize - 1);
    buffer[pos++] = 0x80;
    if (pos > kSha1BlockSize - 4 * 2) {
      while (pos != kSha1BlockSize) {
        buffer[pos++] = 0;
      }
      sha1UpdateBlocks(state, buffer, 0, 1);
      pos = 0;
    }
    buffer.fillRange(pos, kSha1BlockSize - 4 * 2, 0);
    final numBits = count << 3;
    _setBe32(buffer, kSha1BlockSize - 8, (numBits >> 32) & 0xFFFFFFFF);
    _setBe32(buffer, kSha1BlockSize - 4, numBits & 0xFFFFFFFF);
    sha1UpdateBlocks(state, buffer, 0, 1);
    for (var i = 0; i < 5; i++) {
      _setBe32(digest, off + i * 4, state[i]);
    }
    init();
  }

  /// Sha1_Final into a new 20 byte list.
  Uint8List digest() {
    final out = Uint8List(kSha1DigestSize);
    finalTo(out);
    return out;
  }

  /// SHA-1 of [data].
  static Uint8List hash(Uint8List data) => (Sha1()..update(data)).digest();
}

void _setBe32(Uint8List b, int o, int v) {
  b[o] = v >> 24;
  b[o + 1] = v >> 16;
  b[o + 2] = v >> 8;
  b[o + 3] = v;
}
