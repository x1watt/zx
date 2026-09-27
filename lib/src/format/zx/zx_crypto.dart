// Encryption of .zx blocks (docs/zx-format.md, section 7): scrypt keys
// (the scrypt of the vendored zpaq engine, RFC 7914), AES-256 in CTR mode
// (the block cipher of aes.dart, the counter incremented as a 128 bit big
// endian number, NIST SP 800-38A) and HMAC-SHA-256 (RFC 2104), encrypt
// then MAC.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../../crypto/aes.dart';
import '../../crypto/sha256.dart';
import '../../io/streams.dart';
import '../../zpaq/crypto/aes_ctr.dart' show scrypt;
import 'zx_format.dart';

/// Bytes of the nonce before an encrypted payload.
const int zxNonceSize = 16;

/// Bytes of the MAC after an encrypted payload.
const int zxMacSize = 32;

/// The default scrypt cost: N = 2^15, r = 8, p = 1 (32 MiB, well under a
/// second).
const int zxDefaultScryptLog2N = 15;

final Random _rng = Random.secure();

/// [n] random bytes.
Uint8List zxRandomBytes(int n) {
  final b = Uint8List(n);
  for (var i = 0; i < n; i++) {
    b[i] = _rng.nextInt(256);
  }
  return b;
}

/// HMAC-SHA-256 over several parts.
class ZxHmac {
  final Sha256 _s = Sha256();
  final Uint8List _ipad = Uint8List(64);
  final Uint8List _opad = Uint8List(64);

  ZxHmac(Uint8List key) {
    var k = key;
    if (k.length > 64) k = Sha256.hash(k);
    for (var i = 0; i < 64; i++) {
      final c = i < k.length ? k[i] : 0;
      _ipad[i] = c ^ 0x36;
      _opad[i] = c ^ 0x5C;
    }
    _s.update(_ipad);
  }

  void update(Uint8List b, [int off = 0, int? end]) =>
      _s.update(b, off, (end ?? b.length) - off);

  /// The MAC; the object is reset for a new message with the same key.
  Uint8List finish() {
    final inner = _s.digest();
    _s.update(_opad);
    _s.update(inner);
    final out = _s.digest();
    _s.update(_ipad);
    return out;
  }
}

/// The keys of an encrypted archive.
class ZxKeys {
  final Uint8List aesKey;
  final Uint8List macKey;
  final Uint32List _aes = Uint32List(kAesNumIvMrkWords);
  ZxKeys(this.aesKey, this.macKey) {
    aesSetKeyEnc(_aes, 4, aesKey, 32);
  }

  /// The keys for [password] and [params]; throws [SevenZipException]
  /// (unsupported) for an unknown KDF or cipher.
  factory ZxKeys.derive(String password, ZxKdfParams params) {
    if (params.kdfId != 1) {
      throw SevenZipException('zx: unsupported key derivation ${params.kdfId}',
          SevenZipError.unsupportedMethod);
    }
    if (params.cipherId != 1) {
      throw SevenZipException('zx: unsupported cipher ${params.cipherId}',
          SevenZipError.unsupportedMethod);
    }
    if (params.log2N < 1 ||
        params.log2N > 24 ||
        params.r < 1 ||
        params.r > 64 ||
        params.p < 1 ||
        params.p > 64) {
      throw const SevenZipException(
          'zx: unsupported scrypt parameters', SevenZipError.unsupportedMethod);
    }
    final pw = Sha256.hash(Uint8List.fromList(utf8.encode(password)));
    final dk =
        scrypt(pw, params.salt, 1 << params.log2N, params.r, params.p, 64);
    return ZxKeys(Uint8List.fromList(Uint8List.sublistView(dk, 0, 32)),
        Uint8List.fromList(Uint8List.sublistView(dk, 32, 64)));
  }

  /// The password check value of these keys.
  Uint8List passwordCheck() {
    final h = ZxHmac(macKey)
      ..update(Uint8List.fromList(utf8.encode('zx password check')));
    return Uint8List.sublistView(h.finish(), 0, 16);
  }

  /// XORs b[off, off + len) with the AES-256-CTR key stream starting at
  /// the counter block [nonce].
  void ctr(Uint8List nonce, Uint8List b, [int off = 0, int? len]) {
    final n = len ?? b.length - off;
    final counter = Uint8List.fromList(nonce);
    final ks = Uint8List(16);
    final p = _aes;
    for (var i = 0; i < n; i += 16) {
      ks.setRange(0, 16, counter);
      p[0] = 0;
      p[1] = 0;
      p[2] = 0;
      p[3] = 0;
      aesCbcEncode(p, ks, 0, 1);
      final k = n - i < 16 ? n - i : 16;
      final o = off + i;
      for (var j = 0; j < k; j++) {
        b[o + j] ^= ks[j];
      }
      // counter + 1, 128 bit big endian
      for (var j = 15; j >= 0; j--) {
        final v = (counter[j] + 1) & 0xFF;
        counter[j] = v;
        if (v != 0) break;
      }
    }
  }

  /// The encrypted payload of a block: nonce, ciphertext of [plain] (which
  /// is changed), MAC over [headerMacPart], the nonce and the ciphertext.
  /// [headerMacPart] is filled in by the caller after the sizes are known,
  /// so the MAC is computed by [mac].
  Uint8List seal(Uint8List plain) {
    final nonce = zxRandomBytes(zxNonceSize);
    ctr(nonce, plain);
    final out = Uint8List(zxNonceSize + plain.length + zxMacSize);
    out.setRange(0, zxNonceSize, nonce);
    out.setRange(zxNonceSize, zxNonceSize + plain.length, plain);
    return out;
  }

  /// The MAC of an encrypted payload [sealed] (nonce, ciphertext, room for
  /// the MAC) for the block header bytes [headerMacPart]; written into the
  /// last 32 bytes of [sealed].
  void mac(Uint8List headerMacPart, Uint8List sealed) {
    final h = ZxHmac(macKey)
      ..update(headerMacPart)
      ..update(sealed, 0, sealed.length - zxMacSize);
    sealed.setRange(sealed.length - zxMacSize, sealed.length, h.finish());
  }

  /// Checks and decrypts an encrypted payload; returns the plaintext (a
  /// view into [sealed], decrypted in place). Throws [SevenZipException]
  /// when the MAC does not match.
  Uint8List open(Uint8List headerMacPart, Uint8List sealed) {
    if (sealed.length < zxNonceSize + zxMacSize) {
      throw const SevenZipException('zx: encrypted block too short');
    }
    final h = ZxHmac(macKey)
      ..update(headerMacPart)
      ..update(sealed, 0, sealed.length - zxMacSize);
    final m = h.finish();
    var diff = 0;
    for (var i = 0; i < zxMacSize; i++) {
      diff |= m[i] ^ sealed[sealed.length - zxMacSize + i];
    }
    if (diff != 0) {
      throw const SevenZipException(
          'zx: an encrypted block is damaged or the password is wrong '
          '(MAC mismatch)',
          SevenZipError.crc);
    }
    final nonce = Uint8List.sublistView(sealed, 0, zxNonceSize);
    final body =
        Uint8List.sublistView(sealed, zxNonceSize, sealed.length - zxMacSize);
    ctr(Uint8List.fromList(nonce), body);
    return body;
  }
}

/// New KDF parameters for [password] (random salt), with its keys.
(ZxKdfParams, ZxKeys) zxNewKdf(String password,
    {int log2N = zxDefaultScryptLog2N, int r = 8, int p = 1}) {
  final salt = zxRandomBytes(32);
  final tmp = ZxKdfParams(1, log2N, r, p, salt, 1, Uint8List(16));
  final keys = ZxKeys.derive(password, tmp);
  return (
    ZxKdfParams(
        1, log2N, r, p, salt, 1, Uint8List.fromList(keys.passwordCheck())),
    keys
  );
}

/// The keys for [password], or null when the password check fails.
ZxKeys? zxCheckPassword(String password, ZxKdfParams params) {
  final keys = ZxKeys.derive(password, params);
  final c = keys.passwordCheck();
  var diff = 0;
  for (var i = 0; i < 16; i++) {
    diff |= c[i] ^ params.passwordCheck[i];
  }
  return diff == 0 ? keys : null;
}
