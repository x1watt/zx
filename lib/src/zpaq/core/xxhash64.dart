// Vendored from zpaq-flutter by tool/sync_zpaq.sh: do not edit here, change
// zpaq-flutter and sync again. Pure Dart port of libzpaq and zpaq 7.15 (Matt
// Mahoney, public domain) with the zpaqfranz attribute format (Franco
// Corbelli, MIT). Copyright (c) 2026 Max Brito, BSD 3-clause; see LICENSE
// for the license and the third party notices.

import 'dart:typed_data';

const int _p1 = -7046029288634856825; // 0x9E3779B185EBCA87
const int _p2 = -4417276706812531889; // 0xC2B2AE3D27D4EB4F
const int _p3 = 1609587929392839161; // 0x165667B19E3779F9
const int _p4 = -8796714831421723037; // 0x85EBCA77C2B2AE63
const int _p5 = 2870177450012600261; // 0x27D4EB2F165667C5

// Dart ints are 64 bit and wrap on overflow, which is what XXH64 needs.
int _rotl(int x, int r) => (x << r) | (x >>> (64 - r));

int _round(int acc, int input) {
  acc += input * _p2;
  acc = _rotl(acc, 31);
  return acc * _p1;
}

int _merge(int acc, int v) {
  acc ^= _round(0, v);
  return acc * _p1 + _p4;
}

/// Incremental XXH64 with seed 0, the file hash zpaqfranz stores by default
/// (as XXHASH64). Several times faster than SHA-1.
class XxHash64 {
  int _v1 = 0, _v2 = 0, _v3 = 0, _v4 = 0;
  int _total = 0;
  final Uint8List _mem = Uint8List(32);
  late final ByteData _memView = ByteData.sublistView(_mem);
  int _memSize = 0;

  XxHash64() {
    reset();
  }

  void reset() {
    _v1 = _p1 + _p2;
    _v2 = _p2;
    _v3 = 0;
    _v4 = -_p1;
    _total = 0;
    _memSize = 0;
  }

  @pragma('vm:unsafe:no-bounds-checks')
  void add(Uint8List data, [int start = 0, int? end]) {
    end ??= data.length;
    var i = start;
    _total += end - i;
    if (_memSize + (end - i) < 32) {
      _mem.setRange(_memSize, _memSize + end - i, data, i);
      _memSize += end - i;
      return;
    }
    var v1 = _v1, v2 = _v2, v3 = _v3, v4 = _v4;
    if (_memSize > 0) {
      final k = 32 - _memSize;
      _mem.setRange(_memSize, 32, data, i);
      i += k;
      final m = _memView;
      v1 = _round(v1, m.getUint64(0, Endian.little));
      v2 = _round(v2, m.getUint64(8, Endian.little));
      v3 = _round(v3, m.getUint64(16, Endian.little));
      v4 = _round(v4, m.getUint64(24, Endian.little));
      _memSize = 0;
    }
    final bd = ByteData.sublistView(data);
    final limit = end - 32;
    while (i <= limit) {
      v1 = _round(v1, bd.getUint64(i, Endian.little));
      v2 = _round(v2, bd.getUint64(i + 8, Endian.little));
      v3 = _round(v3, bd.getUint64(i + 16, Endian.little));
      v4 = _round(v4, bd.getUint64(i + 24, Endian.little));
      i += 32;
    }
    _v1 = v1;
    _v2 = v2;
    _v3 = v3;
    _v4 = v4;
    if (i < end) {
      _mem.setRange(0, end - i, data, i);
      _memSize = end - i;
    }
  }

  /// The 64 bit hash (as a Dart int, two's complement). Resets the state.
  int digest() {
    int h;
    if (_total >= 32) {
      h = _rotl(_v1, 1) + _rotl(_v2, 7) + _rotl(_v3, 12) + _rotl(_v4, 18);
      h = _merge(h, _v1);
      h = _merge(h, _v2);
      h = _merge(h, _v3);
      h = _merge(h, _v4);
    } else {
      h = _v3 + _p5;
    }
    h += _total;
    final m = _memView;
    var p = 0;
    while (p + 8 <= _memSize) {
      h ^= _round(0, m.getUint64(p, Endian.little));
      h = _rotl(h, 27) * _p1 + _p4;
      p += 8;
    }
    if (p + 4 <= _memSize) {
      h ^= m.getUint32(p, Endian.little) * _p1;
      h = _rotl(h, 23) * _p2 + _p3;
      p += 4;
    }
    while (p < _memSize) {
      h ^= _mem[p] * _p5;
      h = _rotl(h, 11) * _p1;
      ++p;
    }
    h ^= h >>> 33;
    h *= _p2;
    h ^= h >>> 29;
    h *= _p3;
    h ^= h >>> 32;
    reset();
    return h;
  }

  static int hash(Uint8List data) => (XxHash64()..add(data)).digest();
}
