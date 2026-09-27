// Vendored from zpaq-flutter by tool/sync_zpaq.sh: do not edit here, change
// zpaq-flutter and sync again. Pure Dart port of libzpaq and zpaq 7.15 (Matt
// Mahoney, public domain) with the zpaqfranz attribute format (Franco
// Corbelli, MIT). Copyright (c) 2026 Max Brito, BSD 3-clause; see LICENSE
// for the license and the third party notices.

import 'dart:typed_data';

final Uint32List _t0 = () {
  final t = Uint32List(256);
  for (var i = 0; i < 256; ++i) {
    var c = i;
    for (var k = 0; k < 8; ++k) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    t[i] = c;
  }
  return t;
}();

// Slicing by 8: _tN[i] folds N bytes into the state.
final Uint32List _t1 = _slice(_t0, 1);
final Uint32List _t2 = _slice(_t1, 2);
final Uint32List _t3 = _slice(_t2, 3);
final Uint32List _t4 = _slice(_t3, 4);
final Uint32List _t5 = _slice(_t4, 5);
final Uint32List _t6 = _slice(_t5, 6);
final Uint32List _t7 = _slice(_t6, 7);

Uint32List _slice(Uint32List prev, int n) {
  final t = Uint32List(256);
  final base = _t0;
  for (var i = 0; i < 256; ++i) {
    final c = prev[i];
    t[i] = (c >> 8) ^ base[c & 255];
  }
  return t;
}

/// Incremental CRC-32 (IEEE 802.3), as zpaqfranz stores per file.
class Crc32 {
  int _c = 0xFFFFFFFF;

  @pragma('vm:unsafe:no-bounds-checks')
  void add(Uint8List data, [int start = 0, int? end]) {
    end ??= data.length;
    var c = _c;
    final t0 = _t0, t1 = _t1, t2 = _t2, t3 = _t3;
    final t4 = _t4, t5 = _t5, t6 = _t6, t7 = _t7;
    var i = start;
    for (; i + 8 <= end; i += 8) {
      final w =
          data[i] | data[i + 1] << 8 | data[i + 2] << 16 | data[i + 3] << 24;
      c ^= w;
      c = t7[c & 255] ^
          t6[(c >> 8) & 255] ^
          t5[(c >> 16) & 255] ^
          t4[(c >> 24) & 255] ^
          t3[data[i + 4]] ^
          t2[data[i + 5]] ^
          t1[data[i + 6]] ^
          t0[data[i + 7]];
    }
    final t = t0;
    for (; i < end; ++i) {
      c = t[(c ^ data[i]) & 255] ^ (c >> 8);
    }
    _c = c;
  }

  int get value => _c ^ 0xFFFFFFFF;

  void reset() => _c = 0xFFFFFFFF;
}
