// CRC-32C (Castagnoli, RFC 3720 appendix B.4): the reflected polynomial
// 0x82F63B78, initial value and final xor 0xFFFFFFFF, slicing-by-8 as in
// crc.dart. Used by the .zx format for its headers.

import 'dart:typed_data';

final Uint32List _table = _makeTable();

Uint32List _makeTable() {
  final t = Uint32List(256 * 8);
  for (var i = 0; i < 256; i++) {
    var r = i;
    for (var j = 0; j < 8; j++) {
      r = (r >> 1) ^ (0x82F63B78 & -(r & 1));
    }
    t[i] = r & 0xFFFFFFFF;
  }
  for (var i = 256; i < 256 * 8; i++) {
    final r = t[i - 256];
    t[i] = t[r & 0xFF] ^ (r >> 8);
  }
  return t;
}

/// Running CRC-32C.
class Crc32c {
  int _v = 0xFFFFFFFF;

  void update(Uint8List b, [int off = 0, int? end]) {
    _v = crc32cUpdate(_v, b, off, end ?? b.length);
  }

  int get value => _v ^ 0xFFFFFFFF;

  void reset() => _v = 0xFFFFFFFF;

  /// CRC-32C of b[off, end).
  static int of(Uint8List b, [int off = 0, int? end]) =>
      crc32cUpdate(0xFFFFFFFF, b, off, end ?? b.length) ^ 0xFFFFFFFF;
}

/// Updates a raw (not inverted) CRC-32C state with b[off, end).
int crc32cUpdate(int v, Uint8List b, int off, int end) {
  final t = _table;
  var i = off;
  while (end - i >= 8) {
    final lo =
        v ^ (b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24));
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
