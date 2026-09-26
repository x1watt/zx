// AES (table based, software only): port of C/Aes.c (AesGenTables,
// Aes_SetKey_Enc, Aes_SetKey_Dec, Aes_Encode, Aes_Decode, AesCbc_Init,
// AesCbc_Encode, AesCbc_Decode) and the CBC filter of
// CPP/7zip/Crypto/MyAes.cpp (CAesCoder).
//
// The key schedule and CBC state live in one word array like the C ivAes
// buffer: words [0..3] the IV (the CBC chain value), word [4] the number of
// double rounds (keyMode), words [8..] the round keys.

import 'dart:typed_data';

import '../codec/filters/filter_coder.dart';

/// AES_BLOCK_SIZE
const int kAesBlockSize = 16;

/// AES_NUM_IVMRK_WORDS: 1 (IV) + 1 (keyMode) + 15 (AES-256 round keys)
/// blocks of 4 words.
const int kAesNumIvMrkWords = (1 + 1 + 15) * 4;

const List<int> _sbox = [
  0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, //
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
  0xb0, 0x54, 0xbb, 0x16,
];

/// The tables of AesGenTables: T (encryption), D (decryption), Sbox, InvS.
class _AesTables {
  final Uint8List sbox = Uint8List.fromList(_sbox);
  final Uint8List invS = Uint8List(256);
  final Uint32List t0 = Uint32List(256);
  final Uint32List t1 = Uint32List(256);
  final Uint32List t2 = Uint32List(256);
  final Uint32List t3 = Uint32List(256);
  final Uint32List d0 = Uint32List(256);
  final Uint32List d1 = Uint32List(256);
  final Uint32List d2 = Uint32List(256);
  final Uint32List d3 = Uint32List(256);

  // AesGenTables
  _AesTables() {
    for (var i = 0; i < 256; i++) {
      invS[sbox[i]] = i;
    }
    for (var i = 0; i < 256; i++) {
      {
        final a1 = sbox[i];
        final a2 = _xtime(a1);
        final a3 = a2 ^ a1;
        t0[i] = _ui32(a2, a1, a1, a3);
        t1[i] = _ui32(a3, a2, a1, a1);
        t2[i] = _ui32(a1, a3, a2, a1);
        t3[i] = _ui32(a1, a1, a3, a2);
      }
      {
        final a1 = invS[i];
        final a2 = _xtime(a1);
        final a4 = _xtime(a2);
        final a8 = _xtime(a4);
        final a9 = a8 ^ a1;
        final aB = a8 ^ a2 ^ a1;
        final aD = a8 ^ a4 ^ a1;
        final aE = a8 ^ a4 ^ a2;
        d0[i] = _ui32(aE, a9, aD, aB);
        d1[i] = _ui32(aB, aE, a9, aD);
        d2[i] = _ui32(aD, aB, aE, a9);
        d3[i] = _ui32(a9, aD, aB, aE);
      }
    }
  }

  static int _xtime(int x) => ((x << 1) ^ ((x & 0x80) != 0 ? 0x1B : 0)) & 0xFF;
  static int _ui32(int a0, int a1, int a2, int a3) =>
      a0 | (a1 << 8) | (a2 << 16) | (a3 << 24);
}

final _AesTables _tables = _AesTables();

int _getUi32(Uint8List b, int o) =>
    b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);

void _setUi32(Uint8List b, int o, int v) {
  b[o] = v;
  b[o + 1] = v >> 8;
  b[o + 2] = v >> 16;
  b[o + 3] = v >> 24;
}

// Aes_SetKey_Enc. [w] at [wOff] is the keyMode word, followed by 3 unused
// words and the round keys (the C "aes" pointer, ivAes + 4).
void aesSetKeyEnc(Uint32List w, int wOff, Uint8List key, int keySize) {
  final sbox = _tables.sbox;
  var rcon = 1;
  keySize ~/= 4;
  w[wOff] = (keySize ~/ 2) + 3;
  var p = wOff + 4;
  for (var i = 0; i < keySize; i++) {
    w[p + i] = _getUi32(key, i * 4);
  }
  var t = w[p + keySize - 1];
  final wLim = p + keySize * 3 + 28;
  var m = 0;
  do {
    if (m == 0) {
      t = (sbox[(t >> 8) & 0xFF] ^ rcon) |
          (sbox[(t >> 16) & 0xFF] << 8) |
          (sbox[t >> 24] << 16) |
          (sbox[t & 0xFF] << 24);
      rcon <<= 1;
      if ((rcon & 0x100) != 0) rcon = 0x1b;
      m = keySize;
    } else if (m == 4 && keySize > 6) {
      t = sbox[t & 0xFF] |
          (sbox[(t >> 8) & 0xFF] << 8) |
          (sbox[(t >> 16) & 0xFF] << 16) |
          (sbox[t >> 24] << 24);
    }
    m--;
    t ^= w[p];
    w[p + keySize] = t;
  } while (++p != wLim);
}

// Aes_SetKey_Dec
void aesSetKeyDec(Uint32List w, int wOff, Uint8List key, int keySize) {
  aesSetKeyEnc(w, wOff, key, keySize);
  final tb = _tables;
  final sbox = tb.sbox;
  final num = keySize + 20;
  final p = wOff + 8;
  for (var i = 0; i < num; i++) {
    final r = w[p + i];
    w[p + i] = tb.d0[sbox[r & 0xFF]] ^
        tb.d1[sbox[(r >> 8) & 0xFF]] ^
        tb.d2[sbox[(r >> 16) & 0xFF]] ^
        tb.d3[sbox[r >> 24]];
  }
}

// AesCbc_Init
void aesCbcInit(Uint32List p, Uint8List iv) {
  for (var i = 0; i < 4; i++) {
    p[i] = _getUi32(iv, i * 4);
  }
}

// AesCbc_Encode (with Aes_Encode inlined)
void aesCbcEncode(Uint32List p, Uint8List data, int off, int numBlocks) {
  final tb = _tables;
  final t0 = tb.t0, t1 = tb.t1, t2 = tb.t2, t3 = tb.t3;
  final sbox = tb.sbox;
  final w = p;
  final numRounds2Init = w[4];
  var c0 = p[0], c1 = p[1], c2 = p[2], c3 = p[3];
  for (; numBlocks != 0; numBlocks--, off += kAesBlockSize) {
    // p[] ^= data
    var s0 = c0 ^ _getUi32(data, off);
    var s1 = c1 ^ _getUi32(data, off + 4);
    var s2 = c2 ^ _getUi32(data, off + 8);
    var s3 = c3 ^ _getUi32(data, off + 12);

    // Aes_Encode(p + 4, p, p)
    var numRounds2 = numRounds2Init;
    var wi = 8;
    s0 ^= w[wi];
    s1 ^= w[wi + 1];
    s2 ^= w[wi + 2];
    s3 ^= w[wi + 3];
    wi += 4;
    int m0, m1, m2, m3;
    for (;;) {
      // HT16(m, s, 0)
      m0 = t0[s0 & 0xFF] ^
          t1[(s1 >> 8) & 0xFF] ^
          t2[(s2 >> 16) & 0xFF] ^
          t3[s3 >> 24] ^
          w[wi];
      m1 = t0[s1 & 0xFF] ^
          t1[(s2 >> 8) & 0xFF] ^
          t2[(s3 >> 16) & 0xFF] ^
          t3[s0 >> 24] ^
          w[wi + 1];
      m2 = t0[s2 & 0xFF] ^
          t1[(s3 >> 8) & 0xFF] ^
          t2[(s0 >> 16) & 0xFF] ^
          t3[s1 >> 24] ^
          w[wi + 2];
      m3 = t0[s3 & 0xFF] ^
          t1[(s0 >> 8) & 0xFF] ^
          t2[(s1 >> 16) & 0xFF] ^
          t3[s2 >> 24] ^
          w[wi + 3];
      if (--numRounds2 == 0) break;
      // HT16(s, m, 4)
      s0 = t0[m0 & 0xFF] ^
          t1[(m1 >> 8) & 0xFF] ^
          t2[(m2 >> 16) & 0xFF] ^
          t3[m3 >> 24] ^
          w[wi + 4];
      s1 = t0[m1 & 0xFF] ^
          t1[(m2 >> 8) & 0xFF] ^
          t2[(m3 >> 16) & 0xFF] ^
          t3[m0 >> 24] ^
          w[wi + 5];
      s2 = t0[m2 & 0xFF] ^
          t1[(m3 >> 8) & 0xFF] ^
          t2[(m0 >> 16) & 0xFF] ^
          t3[m1 >> 24] ^
          w[wi + 6];
      s3 = t0[m3 & 0xFF] ^
          t1[(m0 >> 8) & 0xFF] ^
          t2[(m1 >> 16) & 0xFF] ^
          t3[m2 >> 24] ^
          w[wi + 7];
      wi += 8;
    }
    wi += 4;
    // FT4(0..3)
    c0 = (sbox[m0 & 0xFF] |
            (sbox[(m1 >> 8) & 0xFF] << 8) |
            (sbox[(m2 >> 16) & 0xFF] << 16) |
            (sbox[m3 >> 24] << 24)) ^
        w[wi];
    c1 = (sbox[m1 & 0xFF] |
            (sbox[(m2 >> 8) & 0xFF] << 8) |
            (sbox[(m3 >> 16) & 0xFF] << 16) |
            (sbox[m0 >> 24] << 24)) ^
        w[wi + 1];
    c2 = (sbox[m2 & 0xFF] |
            (sbox[(m3 >> 8) & 0xFF] << 8) |
            (sbox[(m0 >> 16) & 0xFF] << 16) |
            (sbox[m1 >> 24] << 24)) ^
        w[wi + 2];
    c3 = (sbox[m3 & 0xFF] |
            (sbox[(m0 >> 8) & 0xFF] << 8) |
            (sbox[(m1 >> 16) & 0xFF] << 16) |
            (sbox[m2 >> 24] << 24)) ^
        w[wi + 3];

    _setUi32(data, off, c0);
    _setUi32(data, off + 4, c1);
    _setUi32(data, off + 8, c2);
    _setUi32(data, off + 12, c3);
  }
  p[0] = c0;
  p[1] = c1;
  p[2] = c2;
  p[3] = c3;
}

// AesCbc_Decode (with Aes_Decode inlined)
void aesCbcDecode(Uint32List p, Uint8List data, int off, int numBlocks) {
  final tb = _tables;
  final d0 = tb.d0, d1 = tb.d1, d2 = tb.d2, d3 = tb.d3;
  final invS = tb.invS;
  final w = p;
  final numRounds2Init = w[4];
  var c0 = p[0], c1 = p[1], c2 = p[2], c3 = p[3];
  for (; numBlocks != 0; numBlocks--, off += kAesBlockSize) {
    final in0 = _getUi32(data, off);
    final in1 = _getUi32(data, off + 4);
    final in2 = _getUi32(data, off + 8);
    final in3 = _getUi32(data, off + 12);

    // Aes_Decode(p + 4, out, in)
    var numRounds2 = numRounds2Init;
    var wi = 8 + numRounds2 * 8;
    var s0 = in0 ^ w[wi];
    var s1 = in1 ^ w[wi + 1];
    var s2 = in2 ^ w[wi + 2];
    var s3 = in3 ^ w[wi + 3];
    int m0, m1, m2, m3;
    for (;;) {
      wi -= 8;
      // HD16(m, s, 4)
      m0 = d0[s0 & 0xFF] ^
          d1[(s3 >> 8) & 0xFF] ^
          d2[(s2 >> 16) & 0xFF] ^
          d3[s1 >> 24] ^
          w[wi + 4];
      m1 = d0[s1 & 0xFF] ^
          d1[(s0 >> 8) & 0xFF] ^
          d2[(s3 >> 16) & 0xFF] ^
          d3[s2 >> 24] ^
          w[wi + 5];
      m2 = d0[s2 & 0xFF] ^
          d1[(s1 >> 8) & 0xFF] ^
          d2[(s0 >> 16) & 0xFF] ^
          d3[s3 >> 24] ^
          w[wi + 6];
      m3 = d0[s3 & 0xFF] ^
          d1[(s2 >> 8) & 0xFF] ^
          d2[(s1 >> 16) & 0xFF] ^
          d3[s0 >> 24] ^
          w[wi + 7];
      if (--numRounds2 == 0) break;
      // HD16(s, m, 0)
      s0 = d0[m0 & 0xFF] ^
          d1[(m3 >> 8) & 0xFF] ^
          d2[(m2 >> 16) & 0xFF] ^
          d3[m1 >> 24] ^
          w[wi];
      s1 = d0[m1 & 0xFF] ^
          d1[(m0 >> 8) & 0xFF] ^
          d2[(m3 >> 16) & 0xFF] ^
          d3[m2 >> 24] ^
          w[wi + 1];
      s2 = d0[m2 & 0xFF] ^
          d1[(m1 >> 8) & 0xFF] ^
          d2[(m0 >> 16) & 0xFF] ^
          d3[m3 >> 24] ^
          w[wi + 2];
      s3 = d0[m3 & 0xFF] ^
          d1[(m2 >> 8) & 0xFF] ^
          d2[(m1 >> 16) & 0xFF] ^
          d3[m0 >> 24] ^
          w[wi + 3];
    }
    // FD4(0..3)
    final o0 = (invS[m0 & 0xFF] |
            (invS[(m3 >> 8) & 0xFF] << 8) |
            (invS[(m2 >> 16) & 0xFF] << 16) |
            (invS[m1 >> 24] << 24)) ^
        w[wi];
    final o1 = (invS[m1 & 0xFF] |
            (invS[(m0 >> 8) & 0xFF] << 8) |
            (invS[(m3 >> 16) & 0xFF] << 16) |
            (invS[m2 >> 24] << 24)) ^
        w[wi + 1];
    final o2 = (invS[m2 & 0xFF] |
            (invS[(m1 >> 8) & 0xFF] << 8) |
            (invS[(m0 >> 16) & 0xFF] << 16) |
            (invS[m3 >> 24] << 24)) ^
        w[wi + 2];
    final o3 = (invS[m3 & 0xFF] |
            (invS[(m2 >> 8) & 0xFF] << 8) |
            (invS[(m1 >> 16) & 0xFF] << 16) |
            (invS[m0 >> 24] << 24)) ^
        w[wi + 3];

    _setUi32(data, off, c0 ^ o0);
    _setUi32(data, off + 4, c1 ^ o1);
    _setUi32(data, off + 8, c2 ^ o2);
    _setUi32(data, off + 12, c3 ^ o3);
    c0 = in0;
    c1 = in1;
    c2 = in2;
    c3 = in3;
  }
  p[0] = c0;
  p[1] = c1;
  p[2] = c2;
  p[3] = c3;
}

/// A single block AES encryption (ECB), mainly for test vectors.
/// Encrypts [data] at [off] in place with [key] (16, 24 or 32 bytes).
void aesEncryptBlock(Uint8List key, Uint8List data, [int off = 0]) {
  final p = Uint32List(kAesNumIvMrkWords);
  aesSetKeyEnc(p, 4, key, key.length);
  aesCbcEncode(p, data, off, 1); // zero IV: CBC of one block is ECB
}

/// A single block AES decryption (ECB), mainly for test vectors.
void aesDecryptBlock(Uint8List key, Uint8List data, [int off = 0]) {
  final p = Uint32List(kAesNumIvMrkWords);
  aesSetKeyDec(p, 4, key, key.length);
  aesCbcDecode(p, data, off, 1);
}

/// NCrypto::CAesCoder with CBC (CAesCbcEncoder / CAesCbcDecoder), the
/// ICompressFilter used by 7zAES.
class AesCbcFilter implements CompressFilter {
  final bool _encodeMode;
  final int _keySize;
  bool _keyIsSet = false;
  final Uint32List _aes = Uint32List(kAesNumIvMrkWords);
  final Uint8List _iv = Uint8List(kAesBlockSize);

  /// [keySize] 0 accepts 16, 24 or 32 byte keys.
  AesCbcFilter(this._encodeMode, [this._keySize = 32]);

  // CAesCoder::Init
  @override
  void init() {
    aesCbcInit(_aes, _iv);
    if (!_keyIsSet) throw StateError('AES key is not set');
  }

  // CAesCoder::Filter
  @override
  int filter(Uint8List data, int off, int size) {
    if (!_keyIsSet) return 0;
    if (size < kAesBlockSize) {
      if (size == 0) return 0;
      return kAesBlockSize;
    }
    size >>= 4;
    if (_encodeMode) {
      aesCbcEncode(_aes, data, off, size);
    } else {
      aesCbcDecode(_aes, data, off, size);
    }
    return size << 4;
  }

  // CAesCoder::SetKey
  void setKey(Uint8List data) {
    final size = data.length;
    if ((size & 0x7) != 0 || size < 16 || size > 32) {
      throw ArgumentError('Invalid AES key size: $size');
    }
    if (_keySize != 0 && size != _keySize) {
      throw ArgumentError('Invalid AES key size: $size');
    }
    if (_encodeMode) {
      aesSetKeyEnc(_aes, 4, data, size);
    } else {
      aesSetKeyDec(_aes, 4, data, size);
    }
    _keyIsSet = true;
  }

  // CAesCoder::SetInitVector
  void setInitVector(Uint8List data) {
    if (data.length != kAesBlockSize) {
      throw ArgumentError('Invalid AES IV size: ${data.length}');
    }
    _iv.setRange(0, kAesBlockSize, data);
    aesCbcInit(_aes, _iv);
  }
}
