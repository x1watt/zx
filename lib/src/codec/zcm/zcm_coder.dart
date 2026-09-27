// zcm: binary arithmetic coder.
//
// The 32-bit carryless coder of paq8 and lpaq1 (Matt Mahoney): the range
// [x1, x2] is split at x1 + range * p / 4096 and leading bytes are shifted
// out as soon as x1 and x2 agree on them. Probabilities are 16 bits (the
// probability that the next bit is 1, 1..65535; stream version 1 used 12
// bits). The split uses a 64-bit product, which is exact.

import 'dart:typed_data';

/// Growable output buffer for the encoder.
final class ZcmByteSink {
  Uint8List _buf;
  int _len = 0;

  ZcmByteSink([int capacity = 1 << 16]) : _buf = Uint8List(capacity);

  int get length => _len;

  @pragma('vm:prefer-inline')
  void add(int b) {
    if (_len == _buf.length) _grow(_len + 1);
    _buf[_len++] = b;
  }

  void addBytes(Uint8List b, [int off = 0, int? len]) {
    final n = len ?? b.length - off;
    if (_len + n > _buf.length) _grow(_len + n);
    _buf.setRange(_len, _len + n, b, off);
    _len += n;
  }

  void _grow(int need) {
    var cap = _buf.length * 2;
    if (cap < need) cap = need;
    final nb = Uint8List(cap);
    nb.setRange(0, _len, _buf);
    _buf = nb;
  }

  void clear() => _len = 0;

  /// A view of the bytes written so far.
  Uint8List view() => Uint8List.sublistView(_buf, 0, _len);
}

/// Arithmetic encoder (paq8 Encoder, compress mode).
final class ZcmEncoder {
  int _x1 = 0;
  int _x2 = 0xFFFFFFFF;
  final ZcmByteSink out;

  ZcmEncoder(this.out);

  /// Codes [bit] with probability [p] (of a 1, 16 bits, 1..65535).
  @pragma('vm:prefer-inline')
  void encode(int bit, int p) {
    final xmid = _x1 + (((_x2 - _x1) * p) >> 16);
    if (bit != 0) {
      _x2 = xmid;
    } else {
      _x1 = xmid + 1;
    }
    while (((_x1 ^ _x2) & 0xFF000000) == 0) {
      out.add(_x2 >> 24);
      _x1 = (_x1 << 8) & 0xFFFFFFFF;
      _x2 = ((_x2 << 8) & 0xFFFFFFFF) | 255;
    }
  }

  /// Codes [n] bits of [v] (high first) with p = 1/2.
  void encodeDirect(int v, int n) {
    for (var i = n - 1; i >= 0; i--) {
      encode((v >> i) & 1, 32768);
    }
  }

  /// Writes the 4 bytes that fix a value inside the final range.
  void flush() {
    out.add(_x1 >> 24);
    out.add((_x1 >> 16) & 255);
    out.add((_x1 >> 8) & 255);
    out.add(_x1 & 255);
  }
}

/// Arithmetic decoder (paq8 Encoder, decompress mode). Reads past the end
/// of [data] as zero bytes; the caller bounds the number of decoded bits,
/// so a truncated or corrupt stream can not make it loop forever.
final class ZcmDecoder {
  int _x1 = 0;
  int _x2 = 0xFFFFFFFF;
  int _x = 0;
  final Uint8List data;
  int _pos;
  final int _end;

  ZcmDecoder(this.data, [int start = 0, int? end])
      : _pos = start,
        _end = end ?? data.length {
    for (var i = 0; i < 4; i++) {
      _x = (_x << 8) | _next();
    }
  }

  @pragma('vm:prefer-inline')
  int _next() => _pos < _end ? data[_pos++] : (_pos++ & 0);

  /// Bytes consumed beyond the end of the input (a sign of truncation).
  int get overrun => _pos > _end ? _pos - _end : 0;

  /// Decodes a bit coded with probability [p] (16 bits).
  @pragma('vm:prefer-inline')
  int decode(int p) {
    final xmid = _x1 + (((_x2 - _x1) * p) >> 16);
    int y;
    if (_x <= xmid) {
      y = 1;
      _x2 = xmid;
    } else {
      y = 0;
      _x1 = xmid + 1;
    }
    while (((_x1 ^ _x2) & 0xFF000000) == 0) {
      _x1 = (_x1 << 8) & 0xFFFFFFFF;
      _x2 = ((_x2 << 8) & 0xFFFFFFFF) | 255;
      _x = ((_x << 8) & 0xFFFFFFFF) | _next();
    }
    return y;
  }

  int decodeDirect(int n) {
    var v = 0;
    for (var i = 0; i < n; i++) {
      v = (v << 1) | decode(32768);
    }
    return v;
  }
}
