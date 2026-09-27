// xxHash32 and xxHash64, written from the xxHash specification
// (github.com/Cyan4973/xxHash doc/xxhash_spec.md, BSD 2-clause). XXH32 is
// the block and content checksum of the LZ4 frame format, XXH64 (low 32
// bits) the content checksum of zstd frames.
//
// Dart ints are 64-bit and wrap on multiplication, which is the arithmetic
// XXH64 needs. XXH32 masks with 0xFFFFFFFF after every step.

import 'dart:typed_data';

const int _p32a = 0x9E3779B1;
const int _p32b = 0x85EBCA77;
const int _p32c = 0xC2B2AE3D;
const int _p32d = 0x27D4EB2F;
const int _p32e = 0x165667B1;

const int _p64a = 0x9E3779B185EBCA87;
const int _p64b = 0xC2B2AE3D27D4EB4F;
const int _p64c = 0x165667B19E3779F9;
const int _p64d = 0x85EBCA77C2B2AE63;
const int _p64e = 0x27D4EB2F165667C5;

const int _m32 = 0xFFFFFFFF;

int _rotl32(int x, int r) => ((x << r) | (x >> (32 - r))) & _m32;

int _rotl64(int x, int r) => (x << r) | (x >>> (64 - r));

int _le32(Uint8List b, int i) =>
    b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24);

int _le64(Uint8List b, int i) => _le32(b, i) | (_le32(b, i + 4) << 32);

/// XXH32 of b[off, end) with [seed].
int xxh32(Uint8List b, [int off = 0, int? end, int seed = 0]) {
  final h = Xxh32(seed);
  h.update(b, off, end ?? b.length);
  return h.digest;
}

/// XXH64 of b[off, end) with [seed], as an unsigned value in a 64-bit int
/// (values of 2^63 and more are negative).
int xxh64(Uint8List b, [int off = 0, int? end, int seed = 0]) {
  final h = Xxh64(seed);
  h.update(b, off, end ?? b.length);
  return h.digest;
}

/// Streaming XXH32 (XXH32_update / XXH32_digest).
class Xxh32 {
  final int _seed;
  int _v1, _v2, _v3, _v4;
  int _total = 0;
  final Uint8List _mem = Uint8List(16);
  int _memSize = 0;

  Xxh32([int seed = 0])
      : _seed = seed & _m32,
        _v1 = (seed + _p32a + _p32b) & _m32,
        _v2 = (seed + _p32b) & _m32,
        _v3 = seed & _m32,
        _v4 = (seed - _p32a) & _m32;

  // XXH32_update
  void update(Uint8List b, [int off = 0, int? end]) {
    var p = off;
    final e = end ?? b.length;
    if (e <= p) return;
    _total += e - p;
    if (_memSize + (e - p) < 16) {
      _mem.setRange(_memSize, _memSize + e - p, b, p);
      _memSize += e - p;
      return;
    }
    var v1 = _v1, v2 = _v2, v3 = _v3, v4 = _v4;
    if (_memSize > 0) {
      final n = 16 - _memSize;
      _mem.setRange(_memSize, 16, b, p);
      p += n;
      final m = _mem;
      v1 = (_rotl32((v1 + _le32(m, 0) * _p32b) & _m32, 13) * _p32a) & _m32;
      v2 = (_rotl32((v2 + _le32(m, 4) * _p32b) & _m32, 13) * _p32a) & _m32;
      v3 = (_rotl32((v3 + _le32(m, 8) * _p32b) & _m32, 13) * _p32a) & _m32;
      v4 = (_rotl32((v4 + _le32(m, 12) * _p32b) & _m32, 13) * _p32a) & _m32;
      _memSize = 0;
    }
    final limit = e - 16;
    while (p <= limit) {
      var x = (v1 + _le32(b, p) * _p32b) & _m32;
      v1 = ((((x << 13) | (x >> 19)) & _m32) * _p32a) & _m32;
      x = (v2 + _le32(b, p + 4) * _p32b) & _m32;
      v2 = ((((x << 13) | (x >> 19)) & _m32) * _p32a) & _m32;
      x = (v3 + _le32(b, p + 8) * _p32b) & _m32;
      v3 = ((((x << 13) | (x >> 19)) & _m32) * _p32a) & _m32;
      x = (v4 + _le32(b, p + 12) * _p32b) & _m32;
      v4 = ((((x << 13) | (x >> 19)) & _m32) * _p32a) & _m32;
      p += 16;
    }
    _v1 = v1;
    _v2 = v2;
    _v3 = v3;
    _v4 = v4;
    if (p < e) {
      _mem.setRange(0, e - p, b, p);
      _memSize = e - p;
    }
  }

  // XXH32_digest
  int get digest {
    int h;
    if (_total >= 16) {
      h = (_rotl32(_v1, 1) +
              _rotl32(_v2, 7) +
              _rotl32(_v3, 12) +
              _rotl32(_v4, 18)) &
          _m32;
    } else {
      h = (_seed + _p32e) & _m32;
    }
    h = (h + _total) & _m32;
    final m = _mem;
    var p = 0;
    while (p + 4 <= _memSize) {
      h = (_rotl32((h + _le32(m, p) * _p32c) & _m32, 17) * _p32d) & _m32;
      p += 4;
    }
    while (p < _memSize) {
      h = (_rotl32((h + m[p] * _p32e) & _m32, 11) * _p32a) & _m32;
      p++;
    }
    h ^= h >> 15;
    h = (h * _p32b) & _m32;
    h ^= h >> 13;
    h = (h * _p32c) & _m32;
    h ^= h >> 16;
    return h;
  }
}

// XXH64_round
int _round64(int acc, int lane) => _rotl64(acc + lane * _p64b, 31) * _p64a;

// XXH64_mergeRound
int _merge64(int acc, int v) => (acc ^ _round64(0, v)) * _p64a + _p64d;

/// Streaming XXH64 (XXH64_update / XXH64_digest).
class Xxh64 {
  final int _seed;
  int _v1, _v2, _v3, _v4;
  int _total = 0;
  final Uint8List _mem = Uint8List(32);
  int _memSize = 0;

  Xxh64([int seed = 0])
      : _seed = seed,
        _v1 = seed + _p64a + _p64b,
        _v2 = seed + _p64b,
        _v3 = seed,
        _v4 = seed - _p64a;

  // XXH64_update
  void update(Uint8List b, [int off = 0, int? end]) {
    var p = off;
    final e = end ?? b.length;
    if (e <= p) return;
    _total += e - p;
    if (_memSize + (e - p) < 32) {
      _mem.setRange(_memSize, _memSize + e - p, b, p);
      _memSize += e - p;
      return;
    }
    var v1 = _v1, v2 = _v2, v3 = _v3, v4 = _v4;
    if (_memSize > 0) {
      final n = 32 - _memSize;
      _mem.setRange(_memSize, 32, b, p);
      p += n;
      final m = _mem;
      v1 = _round64(v1, _le64(m, 0));
      v2 = _round64(v2, _le64(m, 8));
      v3 = _round64(v3, _le64(m, 16));
      v4 = _round64(v4, _le64(m, 24));
      _memSize = 0;
    }
    final limit = e - 32;
    if (p <= limit) {
      final bd = ByteData.sublistView(b);
      while (p <= limit) {
        var x = v1 + bd.getUint64(p, Endian.little) * _p64b;
        v1 = ((x << 31) | (x >>> 33)) * _p64a;
        x = v2 + bd.getUint64(p + 8, Endian.little) * _p64b;
        v2 = ((x << 31) | (x >>> 33)) * _p64a;
        x = v3 + bd.getUint64(p + 16, Endian.little) * _p64b;
        v3 = ((x << 31) | (x >>> 33)) * _p64a;
        x = v4 + bd.getUint64(p + 24, Endian.little) * _p64b;
        v4 = ((x << 31) | (x >>> 33)) * _p64a;
        p += 32;
      }
    }
    _v1 = v1;
    _v2 = v2;
    _v3 = v3;
    _v4 = v4;
    if (p < e) {
      _mem.setRange(0, e - p, b, p);
      _memSize = e - p;
    }
  }

  // XXH64_digest
  int get digest {
    int h;
    if (_total >= 32) {
      h = _rotl64(_v1, 1) +
          _rotl64(_v2, 7) +
          _rotl64(_v3, 12) +
          _rotl64(_v4, 18);
      h = _merge64(h, _v1);
      h = _merge64(h, _v2);
      h = _merge64(h, _v3);
      h = _merge64(h, _v4);
    } else {
      h = _seed + _p64e;
    }
    h += _total;
    final m = _mem;
    var p = 0;
    while (p + 8 <= _memSize) {
      h ^= _round64(0, _le64(m, p));
      h = _rotl64(h, 27) * _p64a + _p64d;
      p += 8;
    }
    if (p + 4 <= _memSize) {
      h ^= _le32(m, p) * _p64a;
      h = _rotl64(h, 23) * _p64b + _p64c;
      p += 4;
    }
    while (p < _memSize) {
      h ^= m[p] * _p64e;
      h = _rotl64(h, 11) * _p64a;
      p++;
    }
    h ^= h >>> 33;
    h *= _p64b;
    h ^= h >>> 29;
    h *= _p64c;
    h ^= h >>> 32;
    return h;
  }
}
