// BIP-340 Schnorr signatures over secp256k1, the keys of NOSTR (NIP-01):
// the seals of signed .zx generations (docs/zx-format.md, signed
// generations). Ported from Arca's arca_core (crypto/schnorr.dart, the same
// author, BSD 3-clause), with zx's own SHA-256 and a precomputed table for
// the generator. BIP-340 is by Pieter Wuille, Jonas Nick and Tim Ruffing.
//
// Pure Dart on BigInt. It is not constant time: secret keys are only
// handled on the machine that signs, never by a reader.

import 'dart:math';
import 'dart:typed_data';

import 'sha256.dart';

final BigInt _p = BigInt.parse(
    'FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F',
    radix: 16);
final BigInt _n = BigInt.parse(
    'FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141',
    radix: 16);
final BigInt _gx = BigInt.parse(
    '79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798',
    radix: 16);
final BigInt _gy = BigInt.parse(
    '483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8',
    radix: 16);
final BigInt _sqrtExp = (_p + BigInt.one) >> 2;
final BigInt _two = BigInt.two;
final BigInt _three = BigInt.from(3);
final BigInt _four = BigInt.from(4);
final BigInt _eight = BigInt.from(8);
final BigInt _seven = BigInt.from(7);

/// A point in Jacobian coordinates; z == 0 is the point at infinity.
class _Jac {
  const _Jac(this.x, this.y, this.z);
  final BigInt x, y, z;
  bool get isInfinity => z == BigInt.zero;
}

final _infinity = _Jac(BigInt.one, BigInt.one, BigInt.zero);
final _g = _Jac(_gx, _gy, BigInt.one);

BigInt _mod(BigInt a) => a % _p;

_Jac _double(_Jac a) {
  if (a.isInfinity || a.y == BigInt.zero) return _infinity;
  final ysq = _mod(a.y * a.y);
  final s = _mod(_four * a.x * ysq);
  final m = _mod(_three * a.x * a.x);
  final nx = _mod(m * m - _two * s);
  final ny = _mod(m * (s - nx) - _eight * ysq * ysq);
  final nz = _mod(_two * a.y * a.z);
  return _Jac(nx, ny, nz);
}

_Jac _add(_Jac a, _Jac b) {
  if (a.isInfinity) return b;
  if (b.isInfinity) return a;
  final z1z1 = _mod(a.z * a.z);
  final z2z2 = _mod(b.z * b.z);
  final u1 = _mod(a.x * z2z2);
  final u2 = _mod(b.x * z1z1);
  final s1 = _mod(a.y * b.z * z2z2);
  final s2 = _mod(b.y * a.z * z1z1);
  if (u1 == u2) {
    return s1 == s2 ? _double(a) : _infinity;
  }
  final h = _mod(u2 - u1);
  final r = _mod(s2 - s1);
  final hh = _mod(h * h);
  final hhh = _mod(h * hh);
  final v = _mod(u1 * hh);
  final nx = _mod(r * r - hhh - _two * v);
  final ny = _mod(r * (v - nx) - s1 * hhh);
  final nz = _mod(a.z * b.z * h);
  return _Jac(nx, ny, nz);
}

/// [k] times [p] (double and add).
_Jac _mul(_Jac p, BigInt k) {
  var result = _infinity;
  var addend = p;
  var e = k;
  while (e > BigInt.zero) {
    if (e.isOdd) result = _add(result, addend);
    addend = _double(addend);
    e = e >> 1;
  }
  return result;
}

// The generator in windows of 4 bits: _gTable[w][d] = d * 16^w * G, so
// k * G is at most 64 additions and no doubling.
List<List<_Jac>>? _gTableCache;

List<List<_Jac>> get _gTable {
  final c = _gTableCache;
  if (c != null) return c;
  final t = <List<_Jac>>[];
  var base = _g;
  for (var w = 0; w < 64; w++) {
    final row = <_Jac>[_infinity];
    var acc = _infinity;
    for (var d = 1; d < 16; d++) {
      acc = _add(acc, base);
      row.add(acc);
    }
    t.add(row);
    for (var i = 0; i < 4; i++) {
      base = _double(base);
    }
  }
  return _gTableCache = t;
}

/// [k] times the generator (0 <= k < 2^256).
_Jac _mulG(BigInt k) {
  final t = _gTable;
  var r = _infinity;
  var e = k;
  for (var w = 0; w < 64 && e > BigInt.zero; w++) {
    final d = (e & BigInt.from(15)).toInt();
    if (d != 0) r = _add(r, t[w][d]);
    e = e >> 4;
  }
  return r;
}

/// Affine (x, y), or null for infinity.
(BigInt, BigInt)? _affine(_Jac a) {
  if (a.isInfinity) return null;
  final zi = a.z.modInverse(_p);
  final zi2 = _mod(zi * zi);
  return (_mod(a.x * zi2), _mod(a.y * zi2 * zi));
}

BigInt _int(List<int> b, [int off = 0, int len = 32]) {
  var r = BigInt.zero;
  for (var i = off; i < off + len; i++) {
    r = (r << 8) | BigInt.from(b[i]);
  }
  return r;
}

Uint8List _bytes32(BigInt v) {
  final out = Uint8List(32);
  var x = v;
  final ff = BigInt.from(0xff);
  for (var i = 31; i >= 0; i--) {
    out[i] = (x & ff).toInt();
    x = x >> 8;
  }
  return out;
}

final Map<String, Uint8List> _tagHashes = {};

/// SHA-256(SHA-256(tag) || SHA-256(tag) || parts...).
Uint8List _taggedHash(String tag, List<List<int>> parts) {
  final t = _tagHashes[tag] ??= Sha256.hash(Uint8List.fromList(tag.codeUnits));
  final h = Sha256()
    ..update(t)
    ..update(t);
  for (final p in parts) {
    h.update(p is Uint8List ? p : Uint8List.fromList(p));
  }
  return h.digest();
}

/// The point with x coordinate [x] and an even y, or null if none exists.
_Jac? _liftX(BigInt x) {
  if (x >= _p) return null;
  final cc = _mod(x * x * x + _seven);
  final y = cc.modPow(_sqrtExp, _p);
  if (_mod(y * y) != cc) return null;
  return _Jac(x, y.isEven ? y : _p - y, BigInt.one);
}

/// Thrown for keys or inputs that BIP-340 rejects.
class SchnorrException implements Exception {
  SchnorrException(this.message);
  final String message;
  @override
  String toString() => 'SchnorrException: $message';
}

/// A new random 32-byte secret key from a secure source.
Uint8List generateSecretKey([Random? random]) {
  final rng = random ?? Random.secure();
  while (true) {
    final k = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      k[i] = rng.nextInt(256);
    }
    final d = _int(k);
    if (d > BigInt.zero && d < _n) return k;
  }
}

/// True for a valid secp256k1 secret key (1 <= d < n).
bool isValidSecretKey(List<int> secret) {
  if (secret.length != 32) return false;
  final d = _int(secret);
  return d > BigInt.zero && d < _n;
}

/// The 32-byte x-only public key of [secret].
Uint8List publicKeyOf(List<int> secret) {
  if (!isValidSecretKey(secret)) throw SchnorrException('invalid secret key');
  final p = _affine(_mulG(_int(secret)))!;
  return _bytes32(p.$1);
}

/// True when [publicKey] is a valid x-only public key.
bool isValidPublicKey(List<int> publicKey) =>
    publicKey.length == 32 && _liftX(_int(publicKey)) != null;

/// Signs the 32-byte [message] with [secret]. [aux] is 32 bytes of fresh
/// randomness; when omitted a secure random value is used.
Uint8List schnorrSign(List<int> secret, List<int> message, {List<int>? aux}) {
  if (!isValidSecretKey(secret)) throw SchnorrException('invalid secret key');
  if (message.length != 32) throw SchnorrException('message must be 32 bytes');
  final a = aux ?? generateSecretKey();
  if (a.length != 32) throw SchnorrException('aux must be 32 bytes');
  final d0 = _int(secret);
  final pAff = _affine(_mulG(d0))!;
  final d = pAff.$2.isEven ? d0 : _n - d0;
  final px = _bytes32(pAff.$1);
  final t = _bytes32(d ^ _int(_taggedHash('BIP0340/aux', [a])));
  final k0 = _int(_taggedHash('BIP0340/nonce', [t, px, message])) % _n;
  if (k0 == BigInt.zero) throw SchnorrException('nonce is zero');
  final rAff = _affine(_mulG(k0))!;
  final k = rAff.$2.isEven ? k0 : _n - k0;
  final rx = _bytes32(rAff.$1);
  final e = _int(_taggedHash('BIP0340/challenge', [rx, px, message])) % _n;
  final s = (k + e * d) % _n;
  final sig = Uint8List(64)
    ..setAll(0, rx)
    ..setAll(32, _bytes32(s));
  if (!schnorrVerify(px, message, sig)) {
    throw SchnorrException('produced an invalid signature');
  }
  return sig;
}

/// Verifies a 64-byte BIP-340 [signature] of the 32-byte [message] by the
/// x-only [publicKey].
bool schnorrVerify(
    List<int> publicKey, List<int> message, List<int> signature) {
  if (publicKey.length != 32 ||
      signature.length != 64 ||
      message.length != 32) {
    return false;
  }
  final p = _liftX(_int(publicKey));
  if (p == null) return false;
  final r = _int(signature, 0);
  final s = _int(signature, 32);
  if (r >= _p || s >= _n) return false;
  final e = _int(_taggedHash('BIP0340/challenge',
          [signature.sublist(0, 32), publicKey, message])) %
      _n;
  final rPoint = _add(_mulG(s), _mul(p, (_n - e) % _n));
  final rAff = _affine(rPoint);
  if (rAff == null) return false;
  return rAff.$2.isEven && rAff.$1 == r;
}
