// CRC-32 (7zCrc.c) and CRC-64 (XzCrc64.c), slicing-by-8.

import 'dart:typed_data';

final Uint32List _crc32Table = _makeCrc32Table();

Uint32List _makeCrc32Table() {
  final t = Uint32List(256 * 8);
  for (var i = 0; i < 256; i++) {
    var r = i;
    for (var j = 0; j < 8; j++) {
      r = (r >> 1) ^ (0xEDB88320 & -(r & 1));
    }
    t[i] = r & 0xFFFFFFFF;
  }
  for (var i = 256; i < 256 * 8; i++) {
    final r = t[i - 256];
    t[i] = t[r & 0xFF] ^ (r >> 8);
  }
  return t;
}

/// Running CRC-32 as 7-Zip computes it (initial value and final xor 0xFFFFFFFF).
class Crc32 {
  int _v = 0xFFFFFFFF;

  void update(Uint8List b, [int off = 0, int? end]) {
    _v = crc32Update(_v, b, off, end ?? b.length);
  }

  int get value => _v ^ 0xFFFFFFFF;

  void reset() => _v = 0xFFFFFFFF;

  static int of(Uint8List b, [int off = 0, int? end]) =>
      crc32Update(0xFFFFFFFF, b, off, end ?? b.length) ^ 0xFFFFFFFF;
}

/// Updates a raw (not inverted) CRC-32 state with b[off, end).
int crc32Update(int v, Uint8List b, int off, int end) {
  final t = _crc32Table;
  var i = off;
  while (end - i >= 8) {
    final lo = v ^ (b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24));
    v = t[0x700 + (lo & 0xFF)] ^
        t[0x600 + ((lo >> 8) & 0xFF)] ^
        t[0x500 + ((lo >> 16) & 0xFF)] ^
        t[0x400 + ((lo >> 24) & 0xFF)] ^
        t[0x300 + b[i + 4]] ^
        t[0x200 + b[i + 5]] ^
        t[0x100 + b[i + 6]] ^
        t[b[i + 7]];
    i += 8;
  }
  while (i < end) {
    v = t[(v ^ b[i++]) & 0xFF] ^ (v >> 8);
  }
  return v;
}

// CRC-64 ECMA-182 reflected (poly 0xC96C5795D7870F42), stored as two
// 32-bit halves to stay fast and exact on every platform.
final Uint32List _c64lo = Uint32List(256);
final Uint32List _c64hi = Uint32List(256);
bool _c64init = false;

void _initCrc64() {
  if (_c64init) return;
  const polyLo = 0xD7870F42, polyHi = 0xC96C5795;
  for (var i = 0; i < 256; i++) {
    var lo = i, hi = 0;
    for (var j = 0; j < 8; j++) {
      final bit = lo & 1;
      lo = ((lo >> 1) | ((hi & 1) << 31)) & 0xFFFFFFFF;
      hi = hi >> 1;
      if (bit != 0) {
        lo ^= polyLo;
        hi ^= polyHi;
      }
    }
    _c64lo[i] = lo;
    _c64hi[i] = hi;
  }
  _c64init = true;
}

/// Running CRC-64 as used by xz.
class Crc64 {
  int _lo = 0xFFFFFFFF, _hi = 0xFFFFFFFF;
  Crc64() {
    _initCrc64();
  }

  void update(Uint8List b, [int off = 0, int? end]) {
    end ??= b.length;
    var lo = _lo, hi = _hi;
    final tl = _c64lo, th = _c64hi;
    for (var i = off; i < end; i++) {
      final idx = (lo ^ b[i]) & 0xFF;
      lo = ((lo >> 8) | ((hi & 0xFF) << 24)) ^ tl[idx];
      hi = (hi >> 8) ^ th[idx];
    }
    _lo = lo;
    _hi = hi;
  }

  /// A CRC whose register starts at zero instead of all ones; read it with
  /// [register] (no final inversion). The RAR5 recovery record checksums
  /// its data chunks this way.
  Crc64.zero() {
    _initCrc64();
    _lo = 0;
    _hi = 0;
  }

  /// The CRC as an unsigned 64-bit value in a Dart int (may be negative when
  /// the top bit is set; compare with [bytes] for storage).
  int get value => ((_hi ^ 0xFFFFFFFF) << 32) | (_lo ^ 0xFFFFFFFF);

  /// The register without the final inversion.
  int get register => (_hi << 32) | _lo;

  /// Little endian 8 bytes, as stored in xz.
  Uint8List get bytes {
    final r = Uint8List(8);
    final lo = _lo ^ 0xFFFFFFFF, hi = _hi ^ 0xFFFFFFFF;
    for (var i = 0; i < 4; i++) {
      r[i] = (lo >> (8 * i)) & 0xFF;
      r[4 + i] = (hi >> (8 * i)) & 0xFF;
    }
    return r;
  }
}
