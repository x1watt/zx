// Vendored from zpaq-flutter by tool/sync_zpaq.sh: do not edit here, change
// zpaq-flutter and sync again. Pure Dart port of libzpaq and zpaq 7.15 (Matt
// Mahoney, public domain) with the zpaqfranz attribute format (Franco
// Corbelli, MIT). Copyright (c) 2026 Max Brito, BSD 3-clause; see LICENSE
// for the license and the third party notices.

import 'dart:typed_data';

/// Thrown for any malformed archive, bad configuration or ZPAQL runtime error.
class ZpaqException implements Exception {
  final String message;
  ZpaqException(this.message);
  @override
  String toString() => 'ZpaqException: $message';
}

Never zpaqError(String msg) => throw ZpaqException(msg);

/// Byte source. [get] returns 0..255 or -1 at end of input.
abstract class ZReader {
  int get();

  /// Reads up to [n] bytes into [buf] at [off], returns count read (0 at EOF).
  int read(Uint8List buf, int off, int n) {
    var i = 0;
    for (; i < n; ++i) {
      final c = get();
      if (c < 0) break;
      buf[off + i] = c;
    }
    return i;
  }
}

/// Byte sink.
abstract class ZWriter {
  void put(int c);
  void write(Uint8List buf, int off, int n) {
    for (var i = 0; i < n; ++i) {
      put(buf[off + i]);
    }
  }
}

/// Growable in-memory byte buffer that can be written and then read back,
/// the equivalent of libzpaq::StringBuffer.
class ZBuffer extends ZReader implements ZWriter {
  Uint8List _p;
  int _wpos = 0;
  int _rpos = 0;

  /// Maximum size, or -1 for unlimited.
  int limit = -1;

  ZBuffer([int initial = 128]) : _p = Uint8List(initial < 16 ? 16 : initial);

  ZBuffer.of(Uint8List data)
      : _p = data,
        _wpos = data.length;

  /// Uses the first [size] bytes of [data] as content, without copying.
  ZBuffer.wrap(Uint8List data, int size)
      : _p = data,
        _wpos = size;

  int get size => _wpos;

  /// Makes room for [n] more bytes.
  void reserve(int n) => _reserve(n);

  /// Takes [data] as the whole content without copying, if empty so far.
  /// Returns false (and does nothing) if the buffer already has content.
  bool adopt(Uint8List data) {
    if (_wpos != 0) return false;
    _p = data;
    _wpos = data.length;
    _rpos = 0;
    return true;
  }

  int get readPosition => _rpos;
  int get remaining => _wpos - _rpos;

  /// Backing storage; valid bytes are [0, size).
  Uint8List get data => _p;

  /// A view of the written bytes (no copy).
  Uint8List get bytes => Uint8List.sublistView(_p, 0, _wpos);

  void _reserve(int n) {
    final need = _wpos + n;
    if (limit >= 0 && need > limit) zpaqError('buffer overflow');
    if (need <= _p.length) return;
    var a = _p.length * 2;
    if (a < need) a = need + 1024;
    final q = Uint8List(a);
    q.setRange(0, _wpos, _p);
    _p = q;
  }

  @override
  void put(int c) {
    if (_wpos >= _p.length) _reserve(1);
    _p[_wpos++] = c;
  }

  @override
  void write(Uint8List buf, int off, int n) {
    if (n <= 0) return;
    _reserve(n);
    _p.setRange(_wpos, _wpos + n, buf, off);
    _wpos += n;
  }

  void addAll(List<int> buf) {
    _reserve(buf.length);
    _p.setRange(_wpos, _wpos + buf.length, buf);
    _wpos += buf.length;
  }

  /// Little-endian integer of [n] bytes.
  void putLE(int x, int n) {
    for (var i = 0; i < n; ++i) {
      put(x & 255);
      x >>= 8;
    }
  }

  @override
  int get() => _rpos < _wpos ? _p[_rpos++] : -1;

  @override
  int read(Uint8List buf, int off, int n) {
    if (_rpos + n > _wpos) n = _wpos - _rpos;
    if (n > 0) buf.setRange(off, off + n, _p, _rpos);
    _rpos += n;
    return n;
  }

  /// Truncate or extend (with garbage) to [n] bytes.
  void resize(int n) {
    if (n > _p.length) _reserve(n - _wpos);
    _wpos = n;
    if (_rpos > _wpos) _rpos = _wpos;
  }

  void clear() {
    _wpos = 0;
    _rpos = 0;
  }
}

/// Reader over an in-memory byte list.
class MemoryReader extends ZReader {
  final Uint8List _d;
  int pos;
  final int end;
  MemoryReader(this._d, [this.pos = 0, int? end]) : end = end ?? _d.length;
  @override
  int get() => pos < end ? _d[pos++] : -1;
  @override
  int read(Uint8List buf, int off, int n) {
    if (pos + n > end) n = end - pos;
    if (n > 0) buf.setRange(off, off + n, _d, pos);
    pos += n;
    return n;
  }
}

/// Read a little-endian unsigned integer of [n] bytes from [p] at [o].
int readLE(Uint8List p, int o, int n) {
  var x = 0;
  for (var i = n - 1; i >= 0; --i) {
    x = (x << 8) | p[o + i];
  }
  return x;
}

/// floor(log2(x)) + 1, i.e. number of significant bits (0 for x == 0), for
/// 0 <= x < 2^32. A table: int.bitLength is not a fast intrinsic, and the
/// LZ77 match search calls this for every candidate.
@pragma('vm:prefer-inline')
@pragma('vm:unsafe:no-bounds-checks')
int lg(int x) {
  final t = _lgTable;
  if (x < 0x10000) return x <= 0 ? 0 : t[x];
  return 16 + t[x >>> 16];
}

/// [lg] with its table passed in: [lg] reads a lazily initialized global,
/// and the possible initialization call makes the compiler save every live
/// register around it. Hot loops load [lgTable] once and use this.
@pragma('vm:prefer-inline')
@pragma('vm:unsafe:no-bounds-checks')
int lgWith(Uint8List t, int x) {
  if (x < 0x10000) return x <= 0 ? 0 : t[x];
  return 16 + t[x >>> 16];
}

/// The table of [lg] and [lgWith].
Uint8List get lgTable => _lgTable;

final Uint8List _lgTable = () {
  final t = Uint8List(0x10000);
  for (var i = 1; i < 0x10000; ++i) {
    t[i] = i.bitLength;
  }
  return t;
}();

final Uint8List _zeros = Uint8List(1 << 16);

/// Sets [t] to zeros. `fillRange` on typed lists goes element by element
/// through a generic implementation; `setRange` from a zero buffer is a
/// memory move.
void zeroFill(TypedData t) {
  final b = t.buffer.asUint8List(t.offsetInBytes, t.lengthInBytes);
  final z = _zeros;
  for (var i = 0; i < b.length; i += z.length) {
    final e = i + z.length < b.length ? i + z.length : b.length;
    b.setRange(i, e, z);
  }
}

/// Sets all of [t] to [v], doubling the filled part with memory moves.
void fill32(Uint32List t, int v) {
  final n = t.length;
  if (n == 0) return;
  t[0] = v;
  for (var k = 1; k < n; k *= 2) {
    t.setRange(k, k * 2 < n ? k * 2 : n, t);
  }
}

/// Decimal string of at least [n] digits.
String itos(int x, [int n = 1]) => x.toString().padLeft(n, '0');
