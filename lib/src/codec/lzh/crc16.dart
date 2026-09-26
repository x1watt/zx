// CRC-16 (polynomial 0xA001, reflected, initial value 0) of LHA archives:
// crc16.c of lhasa (ISC license, see LICENSE).

import 'dart:typed_data';

final Uint16List _crc16Table = _makeTable();

// crc16_table: the same values, computed instead of listed
Uint16List _makeTable() {
  final t = Uint16List(256);
  for (var i = 0; i < 256; i++) {
    var r = i;
    for (var j = 0; j < 8; j++) {
      r = (r & 1) != 0 ? (r >> 1) ^ 0xA001 : r >> 1;
    }
    t[i] = r;
  }
  return t;
}

// lha_crc16_buf
/// Updates [crc] with b[off, end) and returns the new value.
int lhaCrc16(int crc, Uint8List b, int off, int end) {
  final t = _crc16Table;
  var v = crc & 0xFFFF;
  for (var i = off; i < end; i++) {
    v = (v >> 8) ^ t[(v ^ b[i]) & 0xFF];
  }
  return v;
}
