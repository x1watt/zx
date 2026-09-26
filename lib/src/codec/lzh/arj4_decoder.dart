// Decoder of ARJ method 4 ("compressed fastest"). The ARJ technote names
// the method only; the format decoded here is LZ77 with prefix coded
// lengths and distances, most significant bit first:
//
//   length code: n one bits (n = 0..7, followed by a zero bit when n < 7),
//     then n bits v; c = 2^n - 1 + v. c = 0 is a literal: the next 8 bits.
//     Otherwise the match is c + 2 bytes long (3..256).
//   distance: n one bits (n = 0..4, followed by a zero bit when n < 4),
//     then 9 + n bits v; the distance is 2^(9 + n) - 512 + v + 1
//     (1..15872).
//
// The decoder frame is the one of the LHA methods (lha_decoder.dart).

import 'dart:typed_data';

import 'lha_decoder.dart';
import 'lzh_bits.dart';

/// Method 4 as an [LhaDecoder] (one literal or match per call).
class Arj4Decoder extends LhaDecoder {
  static const int _ringBits = 15; // 32 KiB, more than the 15872 window
  static const int _mask = (1 << _ringBits) - 1;

  final LzhBitReader r;
  final Uint8List ring = Uint8List(1 << _ringBits);
  int pos = 0;

  Arj4Decoder(this.r);

  @override
  int get maxRead => 256;

  // the length code: -1 at the end of the input
  int _decodeLen() {
    var width = 0;
    var plus = 0;
    var pwr = 1;
    for (; width < 7; width++) {
      final b = r.readBit();
      if (b < 0) return -1;
      if (b == 0) break;
      plus += pwr;
      pwr <<= 1;
    }
    if (width == 0) return plus;
    final v = r.readBits(width);
    if (v < 0) return -1;
    return plus + v;
  }

  // the distance - 1: -1 at the end of the input
  int _decodePtr() {
    var width = 9;
    var plus = 0;
    var pwr = 1 << 9;
    for (; width < 13; width++) {
      final b = r.readBit();
      if (b < 0) return -1;
      if (b == 0) break;
      plus += pwr;
      pwr <<= 1;
    }
    final v = r.readBits(width);
    if (v < 0) return -1;
    return plus + v;
  }

  @override
  int read(Uint8List buf, int off) {
    final c = _decodeLen();
    if (c < 0) return 0;
    if (c == 0) {
      final b = r.readBits(8);
      if (b < 0) return 0;
      buf[off] = b;
      ring[pos] = b;
      pos = (pos + 1) & _mask;
      return 1;
    }
    final len = c + 2;
    final d = _decodePtr();
    if (d < 0) return 0;
    var from = (pos - d - 1) & _mask;
    var p = pos;
    for (var i = 0; i < len; i++) {
      final b = ring[from];
      buf[off + i] = b;
      ring[p] = b;
      p = (p + 1) & _mask;
      from = (from + 1) & _mask;
    }
    pos = p;
    return len;
  }
}
