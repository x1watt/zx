// RAR 3.x (RAR 2.9 to 4.x archives) key derivation for AES-128: port of
// calcAes30Params of rardecode (archive15.go, Nicholas Waples, BSD
// 2-clause, see LICENSE). The password as UTF-16LE followed by the 8 byte
// salt is hashed 2^18 times with SHA-1, each round followed by the 3 low
// bytes of the round number; every 2^14 rounds the last byte of the
// fifth word of the intermediate digest is one byte of the IV, and the
// first 16 bytes of the final digest, with the bytes of each 32-bit word
// reversed, are the key. There is no password check value: a wrong
// password gives bad data (or bad encrypted headers).

import 'dart:typed_data';

import 'sha1.dart';

/// hashRounds
const int rar3KdfRounds = 0x40000;

/// saltSize
const int rar3SaltSize = 8;

/// The AES-128 key and IV of a RAR 3.x password and salt.
final class Rar3Keys {
  final Uint8List key;
  final Uint8List iv;
  Rar3Keys._(this.key, this.iv);

  // calcAes30Params
  factory Rar3Keys.derive(String password, Uint8List? salt) {
    final s = salt ?? Uint8List(0);
    final p = Uint8List(password.length * 2 + s.length);
    for (var i = 0; i < password.length; i++) {
      final c = password.codeUnitAt(i);
      p[i * 2] = c & 0xFF;
      p[i * 2 + 1] = c >> 8;
    }
    p.setRange(password.length * 2, p.length, s);
    final hash = Sha1();
    final copy = Sha1();
    final iv = Uint8List(16);
    final b = Uint8List(3);
    final d = Uint8List(kSha1DigestSize);
    const step = rar3KdfRounds ~/ 16;
    for (var i = 0; i < rar3KdfRounds; i++) {
      hash.update(p);
      b[0] = i & 0xFF;
      b[1] = (i >> 8) & 0xFF;
      b[2] = (i >> 16) & 0xFF;
      hash.update(b);
      if (i % step == 0) {
        // hash.Sum: the digest so far, the hash goes on
        copy.state.setAll(0, hash.state);
        copy.count = hash.count;
        copy.buffer.setAll(0, hash.buffer);
        copy.finalTo(d);
        iv[i ~/ step] = d[4 * 4 + 3];
      }
    }
    hash.finalTo(d);
    final key = Uint8List(16);
    for (var k = 0; k < 16; k += 4) {
      key[k] = d[k + 3];
      key[k + 1] = d[k + 2];
      key[k + 2] = d[k + 1];
      key[k + 3] = d[k];
    }
    return Rar3Keys._(key, iv);
  }
}
