// HMAC-SHA1 (RFC 2104) and PBKDF2 with HMAC-SHA1 (RFC 2898, section 5.2),
// written from the RFCs. The WinZip AES key derivation of zip archives
// (AE-1 / AE-2) uses them with 1000 iterations.

import 'dart:typed_data';

import 'sha1.dart';

/// HMAC-SHA1 with a fixed key: the inner and outer hash states after the
/// padded key block are computed once, so every message costs two hashes
/// of the message blocks only.
class HmacSha1 {
  final Uint32List _innerState = Uint32List(5);
  final Uint32List _outerState = Uint32List(5);
  final Sha1 _sha = Sha1();
  final Uint8List _tmp = Uint8List(kSha1DigestSize);

  HmacSha1(Uint8List key) {
    var k = key;
    if (k.length > kSha1BlockSize) k = Sha1.hash(k);
    final block = Uint8List(kSha1BlockSize);
    block.setRange(0, k.length, k);
    // K XOR ipad
    for (var i = 0; i < kSha1BlockSize; i++) {
      block[i] ^= 0x36;
    }
    final s = Sha1();
    sha1UpdateBlocks(s.state, block, 0, 1);
    _innerState.setAll(0, s.state);
    // K XOR opad (0x36 ^ 0x5C == 0x6A)
    for (var i = 0; i < kSha1BlockSize; i++) {
      block[i] ^= 0x6A;
    }
    s.init();
    sha1UpdateBlocks(s.state, block, 0, 1);
    _outerState.setAll(0, s.state);
    init();
  }

  /// Starts a new message.
  void init() {
    _sha.state.setAll(0, _innerState);
    _sha.count = kSha1BlockSize;
  }

  void update(Uint8List data, [int off = 0, int? size]) =>
      _sha.update(data, off, size);

  /// Writes the 20 byte MAC to [mac] at [off] and starts a new message.
  void finalTo(Uint8List mac, [int off = 0]) {
    _sha.finalTo(_tmp);
    _sha.state.setAll(0, _outerState);
    _sha.count = kSha1BlockSize;
    _sha.update(_tmp);
    _sha.finalTo(mac, off);
    init();
  }

  /// The MAC of the message so far, in a new list.
  Uint8List digest() {
    final r = Uint8List(kSha1DigestSize);
    finalTo(r);
    return r;
  }

  /// HMAC-SHA1 of [data] with [key].
  static Uint8List mac(Uint8List key, Uint8List data) =>
      (HmacSha1(key)..update(data)).digest();
}

/// PBKDF2 (RFC 2898, 5.2) with HMAC-SHA1 as the pseudo random function:
/// [dkLen] bytes derived from [password] and [salt] with [iterations].
Uint8List pbkdf2HmacSha1(
    Uint8List password, Uint8List salt, int iterations, int dkLen) {
  final prf = HmacSha1(password);
  final out = Uint8List(dkLen);
  final u = Uint8List(kSha1DigestSize);
  final t = Uint8List(kSha1DigestSize);
  final be = Uint8List(4);
  var pos = 0;
  for (var block = 1; pos < dkLen; block++) {
    // U_1 = PRF(P, S || INT(i))
    be[0] = block >> 24;
    be[1] = block >> 16;
    be[2] = block >> 8;
    be[3] = block;
    prf.update(salt);
    prf.update(be);
    prf.finalTo(u);
    t.setAll(0, u);
    // U_j = PRF(P, U_{j-1}), T = U_1 ^ ... ^ U_c
    for (var j = 1; j < iterations; j++) {
      prf.update(u);
      prf.finalTo(u);
      for (var k = 0; k < kSha1DigestSize; k++) {
        t[k] ^= u[k];
      }
    }
    var n = dkLen - pos;
    if (n > kSha1DigestSize) n = kSha1DigestSize;
    out.setRange(pos, pos + n, t);
    pos += n;
  }
  return out;
}
