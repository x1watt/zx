// RAR5 key derivation and checksums: HMAC-SHA256 (RFC 2104), PBKDF2 with
// HMAC-SHA256 (RFC 8018) and the values RAR5 derives from the same PBKDF2
// chain.
//
// The RAR5 technote (https://www.rarlab.com/technote.htm) documents the
// AES-256 encryption, the 2^KDF count PBKDF2 iterations, the salt, the IV
// and the 12 byte check value (8 bytes from additional PBKDF2 rounds and a
// 4 byte checksum), and the "tweaked checksums" flag. The exact use of the
// additional rounds (the hash key after 16 more iterations, the password
// check after 32 more, folded to 8 bytes, its checksum as the first 4 bytes
// of its SHA-256) and of the tweak (an HMAC-SHA256 of the plain checksum
// with the hash key, folded for CRC32) are not spelled out there: they were
// confirmed against archives written by the rar 7.00 tool (see
// test/rar_test.dart), no RAR source code was used.

import 'dart:convert';
import 'dart:typed_data';

import 'sha256.dart';

/// RAR5 limits the KDF count (binary logarithm of the iterations).
const int rar5MaxKdfCount = 24;

/// HMAC-SHA256 with the key blocks prepared once.
final class HmacSha256 {
  final Uint32List _inner = Uint32List(8);
  final Uint32List _outer = Uint32List(8);
  final Uint8List _block = Uint8List(64);

  HmacSha256(Uint8List key) {
    var k = key;
    if (k.length > 64) k = Sha256.hash(k);
    final pad = Uint8List(64);
    pad.setRange(0, k.length, k);
    for (var i = 0; i < 64; i++) {
      _block[i] = pad[i] ^ 0x36;
    }
    _initState(_inner);
    sha256UpdateBlocks(_inner, _block, 0, 1);
    for (var i = 0; i < 64; i++) {
      _block[i] = pad[i] ^ 0x5C;
    }
    _initState(_outer);
    sha256UpdateBlocks(_outer, _block, 0, 1);
  }

  static void _initState(Uint32List st) {
    st[0] = 0x6a09e667;
    st[1] = 0xbb67ae85;
    st[2] = 0x3c6ef372;
    st[3] = 0xa54ff53a;
    st[4] = 0x510e527f;
    st[5] = 0x9b05688c;
    st[6] = 0x1f83d9ab;
    st[7] = 0x5be0cd19;
  }

  /// HMAC of any message.
  Uint8List mac(Uint8List msg) {
    final s = Sha256();
    s.state.setAll(0, _inner);
    s.count = 64;
    s.update(msg);
    final ih = s.digest();
    s.state.setAll(0, _outer);
    s.count = 64;
    s.update(ih);
    return s.digest();
  }

  // HMAC of a 32 byte message into [out]: two compressions, used by the
  // PBKDF2 loop.
  final Uint32List _st = Uint32List(8);
  void _mac32(Uint8List msg, Uint8List out) {
    final b = _block;
    b.setRange(0, 32, msg);
    b[32] = 0x80;
    b.fillRange(33, 62, 0);
    // length (64 + 32) * 8 = 768 bits
    b[62] = 0x03;
    b[63] = 0x00;
    final st = _st;
    st.setAll(0, _inner);
    sha256UpdateBlocks(st, b, 0, 1);
    for (var i = 0; i < 8; i++) {
      final v = st[i];
      b[i * 4] = v >> 24;
      b[i * 4 + 1] = v >> 16;
      b[i * 4 + 2] = v >> 8;
      b[i * 4 + 3] = v;
    }
    b[32] = 0x80;
    b.fillRange(33, 62, 0);
    b[62] = 0x03;
    b[63] = 0x00;
    st.setAll(0, _outer);
    sha256UpdateBlocks(st, b, 0, 1);
    for (var i = 0; i < 8; i++) {
      final v = st[i];
      out[i * 4] = v >> 24;
      out[i * 4 + 1] = v >> 16;
      out[i * 4 + 2] = v >> 8;
      out[i * 4 + 3] = v;
    }
  }
}

/// The three values of the RAR5 PBKDF2 chain for one password and salt.
final class Rar5Keys {
  /// The AES-256 key (PBKDF2-HMAC-SHA256, 2^count iterations).
  final Uint8List key;

  /// The key of the tweaked checksums (16 more iterations).
  final Uint8List hashKey;

  /// The 8 byte password check value (16 more iterations, folded).
  final Uint8List pswCheck;

  Rar5Keys(this.key, this.hashKey, this.pswCheck);

  /// Derives the values for [password] (UTF-8), [salt] (16 bytes) and
  /// [kdfCount].
  factory Rar5Keys.derive(String password, Uint8List salt, int kdfCount) {
    final pw = Uint8List.fromList(utf8.encode(password));
    final h = HmacSha256(pw);
    final msg = Uint8List(salt.length + 4);
    msg.setRange(0, salt.length, salt);
    msg[salt.length + 3] = 1; // block index 1, big endian
    final u = h.mac(msg);
    final f = Uint8List.fromList(u);
    final results = <Uint8List>[];
    final counts = [1 << kdfCount, 16, 16];
    var first = true;
    for (final n in counts) {
      for (var i = first ? 1 : 0; i < n; i++) {
        h._mac32(u, u);
        for (var j = 0; j < 32; j++) {
          f[j] ^= u[j];
        }
      }
      first = false;
      results.add(Uint8List.fromList(f));
    }
    final check = Uint8List(8);
    for (var i = 0; i < 32; i++) {
      check[i & 7] ^= results[2][i];
    }
    return Rar5Keys(results[0], results[1], check);
  }

  /// The 4 byte checksum stored after the password check value.
  static Uint8List checkSum(Uint8List pswCheck) =>
      Uint8List.sublistView(Sha256.hash(pswCheck), 0, 4);

  /// The tweaked CRC32 of an encrypted file.
  int tweakCrc(int crc) {
    final b = Uint8List(4);
    b[0] = crc & 0xFF;
    b[1] = (crc >> 8) & 0xFF;
    b[2] = (crc >> 16) & 0xFF;
    b[3] = (crc >> 24) & 0xFF;
    final d = HmacSha256(hashKey).mac(b);
    var r = 0;
    for (var i = 0; i < 32; i++) {
      r ^= d[i] << ((i & 3) * 8);
    }
    return r & 0xFFFFFFFF;
  }

  /// The tweaked BLAKE2sp digest of an encrypted file.
  Uint8List tweakHash(Uint8List digest) => HmacSha256(hashKey).mac(digest);
}
