// Vendored from zpaq-flutter by tool/sync_zpaq.sh: do not edit here, change
// zpaq-flutter and sync again. Pure Dart port of libzpaq and zpaq 7.15 (Matt
// Mahoney, public domain) with the zpaqfranz attribute format (Franco
// Corbelli, MIT). Copyright (c) 2026 Max Brito, BSD 3-clause; see LICENSE
// for the license and the third party notices.

import 'dart:typed_data';

import 'sha256.dart';

final Uint8List _sbox = () {
  // Generate the AES S-box.
  final s = Uint8List(256);
  var p = 1, q = 1;
  do {
    p = p ^ ((p << 1) & 0xFF) ^ ((p & 0x80) != 0 ? 0x1B : 0);
    q ^= q << 1;
    q ^= q << 2;
    q ^= q << 4;
    q &= 0xFF;
    if ((q & 0x80) != 0) q ^= 0x09;
    final x = q ^
        (((q << 1) | (q >> 7)) & 0xFF) ^
        (((q << 2) | (q >> 6)) & 0xFF) ^
        (((q << 3) | (q >> 5)) & 0xFF) ^
        (((q << 4) | (q >> 4)) & 0xFF);
    s[p] = x ^ 0x63;
  } while (p != 1);
  s[0] = 0x63;
  return s;
}();

int _xtime(int x) => ((x << 1) ^ ((x & 0x80) != 0 ? 0x1B : 0)) & 0xFF;

/// AES-256 in CTR mode as used by zpaq: the counter block is the first 8
/// bytes of the IV followed by the big-endian 64 bit block number, where
/// the block number is (file offset / 16).
class AesCtr {
  final Uint32List _rk = Uint32List(60);
  final Uint8List _iv = Uint8List(8);
  final Uint8List _ct = Uint8List(16);
  final Uint8List _state = Uint8List(16);
  final Uint8List _t = Uint8List(16);

  AesCtr(Uint8List key, Uint8List iv) {
    if (key.length != 32) throw ArgumentError('AES-256 key must be 32 bytes');
    _iv.setRange(0, 8, iv);
    _expandKey(key);
  }

  void _expandKey(Uint8List key) {
    const nk = 8;
    for (var i = 0; i < nk; ++i) {
      _rk[i] = key[4 * i] << 24 |
          key[4 * i + 1] << 16 |
          key[4 * i + 2] << 8 |
          key[4 * i + 3];
    }
    var rcon = 1;
    for (var i = nk; i < 60; ++i) {
      var t = _rk[i - 1];
      if (i % nk == 0) {
        t = ((t << 8) | (t >> 24)) & 0xFFFFFFFF;
        t = _sbox[t >> 24] << 24 |
            _sbox[(t >> 16) & 255] << 16 |
            _sbox[(t >> 8) & 255] << 8 |
            _sbox[t & 255];
        t ^= rcon << 24;
        rcon = _xtime(rcon);
      } else if (i % nk == 4) {
        t = _sbox[t >> 24] << 24 |
            _sbox[(t >> 16) & 255] << 16 |
            _sbox[(t >> 8) & 255] << 8 |
            _sbox[t & 255];
      }
      _rk[i] = _rk[i - nk] ^ t;
    }
  }

  void _encryptBlock(Uint8List s, Uint8List out) {
    final st = _state;
    for (var i = 0; i < 16; ++i) {
      st[i] = s[i] ^ ((_rk[i >> 2] >> (24 - 8 * (i & 3))) & 255);
    }
    for (var round = 1; round <= 14; ++round) {
      // SubBytes + ShiftRows
      final t = _t;
      for (var c = 0; c < 4; ++c) {
        for (var r = 0; r < 4; ++r) {
          t[4 * c + r] = _sbox[st[4 * ((c + r) & 3) + r]];
        }
      }
      if (round != 14) {
        for (var c = 0; c < 4; ++c) {
          final a0 = t[4 * c], a1 = t[4 * c + 1];
          final a2 = t[4 * c + 2], a3 = t[4 * c + 3];
          final x = a0 ^ a1 ^ a2 ^ a3;
          t[4 * c] = a0 ^ x ^ _xtime(a0 ^ a1);
          t[4 * c + 1] = a1 ^ x ^ _xtime(a1 ^ a2);
          t[4 * c + 2] = a2 ^ x ^ _xtime(a2 ^ a3);
          t[4 * c + 3] = a3 ^ x ^ _xtime(a3 ^ a0);
        }
      }
      for (var i = 0; i < 16; ++i) {
        st[i] =
            t[i] ^ ((_rk[round * 4 + (i >> 2)] >> (24 - 8 * (i & 3))) & 255);
      }
    }
    out.setRange(0, 16, st);
  }

  /// Encrypts one 16 byte block (exposed for tests).
  Uint8List encryptBlock(Uint8List block) {
    final out = Uint8List(16);
    _encryptBlock(block, out);
    return out;
  }

  final Uint8List _ctr = Uint8List(16);
  int _cachedBlock = -1;

  /// XORs buf[off..off+n) with the key stream for absolute [offset].
  void apply(Uint8List buf, int off, int n, int offset) {
    var i = 0;
    while (i < n) {
      final pos = offset + i;
      final blk = pos >> 4;
      if (blk != _cachedBlock) {
        _ctr.setRange(0, 8, _iv);
        for (var k = 0; k < 8; ++k) {
          _ctr[8 + k] = (blk >> (56 - 8 * k)) & 255;
        }
        _encryptBlock(_ctr, _ct);
        _cachedBlock = blk;
      }
      var j = pos & 15;
      while (j < 16 && i < n) {
        buf[off + i] ^= _ct[j];
        ++i;
        ++j;
      }
    }
  }
}

/// HMAC-SHA256 based PBKDF2 with one iteration (as libzpaq), dkLen multiple
/// of 32, password length <= 64.
Uint8List _pbkdf2(Uint8List pw, Uint8List salt, int dkLen) {
  final out = Uint8List(dkLen);
  final sha = Sha256();
  for (var i = 1; i * 32 <= dkLen; ++i) {
    final ipad = Uint8List(64), opad = Uint8List(64);
    for (var j = 0; j < 64; ++j) {
      final c = j < pw.length ? pw[j] : 0;
      ipad[j] = c ^ 0x36;
      opad[j] = c ^ 0x5c;
    }
    sha.add(ipad);
    sha.add(salt);
    sha.add([(i >> 24) & 255, (i >> 16) & 255, (i >> 8) & 255, i & 255]);
    final b = sha.digest();
    sha.add(opad);
    sha.add(b);
    out.setRange(i * 32 - 32, i * 32, sha.digest());
  }
  return out;
}

int _rotl(int a, int b) => ((a << b) | (a >> (32 - b))) & 0xFFFFFFFF;

void _salsa8(Uint32List b, int o, Uint32List x) {
  for (var i = 0; i < 16; ++i) {
    x[i] = b[o + i];
  }
  for (var i = 0; i < 4; ++i) {
    x[4] ^= _rotl((x[0] + x[12]) & 0xFFFFFFFF, 7);
    x[8] ^= _rotl((x[4] + x[0]) & 0xFFFFFFFF, 9);
    x[12] ^= _rotl((x[8] + x[4]) & 0xFFFFFFFF, 13);
    x[0] ^= _rotl((x[12] + x[8]) & 0xFFFFFFFF, 18);
    x[9] ^= _rotl((x[5] + x[1]) & 0xFFFFFFFF, 7);
    x[13] ^= _rotl((x[9] + x[5]) & 0xFFFFFFFF, 9);
    x[1] ^= _rotl((x[13] + x[9]) & 0xFFFFFFFF, 13);
    x[5] ^= _rotl((x[1] + x[13]) & 0xFFFFFFFF, 18);
    x[14] ^= _rotl((x[10] + x[6]) & 0xFFFFFFFF, 7);
    x[2] ^= _rotl((x[14] + x[10]) & 0xFFFFFFFF, 9);
    x[6] ^= _rotl((x[2] + x[14]) & 0xFFFFFFFF, 13);
    x[10] ^= _rotl((x[6] + x[2]) & 0xFFFFFFFF, 18);
    x[3] ^= _rotl((x[15] + x[11]) & 0xFFFFFFFF, 7);
    x[7] ^= _rotl((x[3] + x[15]) & 0xFFFFFFFF, 9);
    x[11] ^= _rotl((x[7] + x[3]) & 0xFFFFFFFF, 13);
    x[15] ^= _rotl((x[11] + x[7]) & 0xFFFFFFFF, 18);
    x[1] ^= _rotl((x[0] + x[3]) & 0xFFFFFFFF, 7);
    x[2] ^= _rotl((x[1] + x[0]) & 0xFFFFFFFF, 9);
    x[3] ^= _rotl((x[2] + x[1]) & 0xFFFFFFFF, 13);
    x[0] ^= _rotl((x[3] + x[2]) & 0xFFFFFFFF, 18);
    x[6] ^= _rotl((x[5] + x[4]) & 0xFFFFFFFF, 7);
    x[7] ^= _rotl((x[6] + x[5]) & 0xFFFFFFFF, 9);
    x[4] ^= _rotl((x[7] + x[6]) & 0xFFFFFFFF, 13);
    x[5] ^= _rotl((x[4] + x[7]) & 0xFFFFFFFF, 18);
    x[11] ^= _rotl((x[10] + x[9]) & 0xFFFFFFFF, 7);
    x[8] ^= _rotl((x[11] + x[10]) & 0xFFFFFFFF, 9);
    x[9] ^= _rotl((x[8] + x[11]) & 0xFFFFFFFF, 13);
    x[10] ^= _rotl((x[9] + x[8]) & 0xFFFFFFFF, 18);
    x[12] ^= _rotl((x[15] + x[14]) & 0xFFFFFFFF, 7);
    x[13] ^= _rotl((x[12] + x[15]) & 0xFFFFFFFF, 9);
    x[14] ^= _rotl((x[13] + x[12]) & 0xFFFFFFFF, 13);
    x[15] ^= _rotl((x[14] + x[13]) & 0xFFFFFFFF, 18);
  }
  for (var i = 0; i < 16; ++i) {
    b[o + i] += x[i];
  }
}

void _blockmix(Uint32List b, int r, Uint32List y, Uint32List x, Uint32List t) {
  for (var j = 0; j < 16; ++j) {
    x[j] = b[32 * r - 16 + j];
  }
  for (var i = 0; i < 2 * r; ++i) {
    for (var j = 0; j < 16; ++j) {
      x[j] ^= b[i * 16 + j];
    }
    _salsa8(x, 0, t);
    y.setRange(i * 16, i * 16 + 16, x);
  }
  for (var i = 0; i < r; ++i) {
    b.setRange(i * 16, i * 16 + 16, y, i * 32);
  }
  for (var i = 0; i < r; ++i) {
    b.setRange((i + r) * 16, (i + r) * 16 + 16, y, i * 32 + 16);
  }
}

void _smix(Uint8List b, int bo, int r, int n) {
  final x = Uint32List(32 * r), v = Uint32List(32 * r * n);
  final y = Uint32List(32 * r), xx = Uint32List(16), t = Uint32List(16);
  for (var i = 0; i < r * 128; ++i) {
    x[i >> 2] += b[bo + i] << ((i & 3) * 8);
  }
  for (var i = 0; i < n; ++i) {
    v.setRange(i * r * 32, i * r * 32 + r * 32, x);
    _blockmix(x, r, y, xx, t);
  }
  for (var i = 0; i < n; ++i) {
    final j = x[(2 * r - 1) * 16] & (n - 1);
    for (var k = 0; k < r * 32; ++k) {
      x[k] ^= v[j * r * 32 + k];
    }
    _blockmix(x, r, y, xx, t);
  }
  for (var i = 0; i < r * 128; ++i) {
    b[bo + i] = x[i >> 2] >> ((i & 3) * 8);
  }
}

/// scrypt(pw, salt, n, r, p) giving dkLen bytes, as libzpaq::scrypt.
Uint8List scrypt(Uint8List pw, Uint8List salt, int n, int r, int p, int dkLen) {
  final b = _pbkdf2(pw, salt, p * r * 128);
  for (var i = 0; i < p; ++i) {
    _smix(b, i * r * 128, r, n);
  }
  return _pbkdf2(pw, b, dkLen);
}

/// zpaq key derivation: 32 bytes of scrypt(SHA256(password), salt, 16384,
/// 8, 1).
Uint8List zpaqStretchKey(Uint8List passwordHash, Uint8List salt) =>
    scrypt(passwordHash, salt, 1 << 14, 8, 1, 32);
