// Adler-32 (RFC 1950 section 8.2, zlib's adler32()), the checksum of zlib
// streams.

import 'dart:typed_data';

const int _base = 65521; // largest prime smaller than 65536
const int _nmax = 5552; // largest n with 255n(n+1)/2 + (n+1)(BASE-1) < 2^32

/// Updates the running Adler-32 [adler] with b[off, end) and returns the
/// new value. Start with 1 (the Adler-32 of no data).
// adler32_z
int adler32(int adler, Uint8List b, [int off = 0, int? end]) {
  var a = adler & 0xFFFF;
  var s = (adler >> 16) & 0xFFFF;
  var p = off;
  final e = end ?? b.length;
  while (p < e) {
    var n = e - p;
    if (n > _nmax) n = _nmax;
    final stop = p + n;
    while (p < stop) {
      a += b[p++];
      s += a;
    }
    a %= _base;
    s %= _base;
  }
  return (s << 16) | a;
}
