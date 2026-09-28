// Order-preserving encodings of typed SQL values into byte keys, used for
// index keys, rowid keys and grouping / distinct hashing.
//
// Keys compare as unsigned bytes (memcmp, shorter first on a common
// prefix), and the encodings below make that byte order equal to SQLite's
// value order: NULL < numbers (INTEGER and REAL compared numerically) <
// TEXT (binary, UTF-8 memcmp) < BLOB (memcmp). Every component encoding is
// prefix free, so a tuple of values encodes to the concatenation of its
// components and tuples compare component by component. A descending
// component is the bitwise complement of its ascending encoding.
//
// Component layouts:
//   NULL                 0x05
//   number < -2^63       0x10, complement of the IEEE bits of the double
//   number in int64 range 0x11, floor(x) as 8 bytes (sign bit flipped,
//                        big endian), then 0x00 when x is integral, or
//                        0x01 and the 8 IEEE bits of the fraction (0 < f < 1)
//   number >= 2^63       0x12, the IEEE bits of the double
//   TEXT                 0x20, UTF-8 bytes with 0x00 escaped as 0x00 0xFF,
//                        terminated by 0x00 0x00
//   BLOB                 0x30, bytes escaped the same way, 0x00 0x00
//
// Equal numbers encode identically whatever their storage class (1 and
// 1.0 give the same bytes), as SQLite compares them equal. Decoding gives
// an int for integral numbers in range and a double otherwise; callers
// that know the column holds REAL values convert back (see [decodeKey]).
//
// Rowids in table trees are encoded by [encodeRowid]: 8 bytes, sign bit
// flipped, big endian.

import 'dart:convert';
import 'dart:typed_data';

const int kTagNull = 0x05;
const int kTagNumLow = 0x10;
const int kTagNum = 0x11;
const int kTagNumHigh = 0x12;
const int kTagText = 0x20;
const int kTagBlob = 0x30;

const double _two63 = 9223372036854775808.0;

/// Growable byte buffer for building keys.
class KeyWriter {
  Uint8List _b = Uint8List(32);
  int _n = 0;

  int get length => _n;

  void _ensure(int extra) {
    if (_n + extra <= _b.length) return;
    var c = _b.length * 2;
    while (c < _n + extra) {
      c *= 2;
    }
    final nb = Uint8List(c);
    nb.setRange(0, _n, _b);
    _b = nb;
  }

  void byte(int x) {
    _ensure(1);
    _b[_n++] = x;
  }

  void u64(int x) {
    _ensure(8);
    for (var i = 7; i >= 0; i--) {
      _b[_n + i] = x & 0xFF;
      x >>= 8;
    }
    _n += 8;
  }

  void bytes(List<int> src) {
    _ensure(src.length);
    _b.setRange(_n, _n + src.length, src);
    _n += src.length;
  }

  /// Complements bytes [from, length) (descending component).
  void invertFrom(int from) {
    for (var i = from; i < _n; i++) {
      _b[i] = ~_b[i] & 0xFF;
    }
  }

  void reset() => _n = 0;

  Uint8List take() => Uint8List.fromList(Uint8List.sublistView(_b, 0, _n));
}

int _doubleBits(double d) {
  final bd = ByteData(8)..setFloat64(0, d);
  return bd.getInt64(0);
}

double _bitsDouble(int bits) {
  final bd = ByteData(8)..setInt64(0, bits);
  return bd.getFloat64(0);
}

/// Appends one value (ascending, or descending when [desc]).
void encodeKeyValue(KeyWriter w, Object? v, {bool desc = false}) {
  final start = w.length;
  if (v == null) {
    w.byte(kTagNull);
  } else if (v is int) {
    w.byte(kTagNum);
    w.u64(v ^ (-0x8000000000000000));
    w.byte(0);
  } else if (v is double) {
    _encodeDouble(w, v);
  } else if (v is String) {
    w.byte(kTagText);
    _escaped(w, utf8.encode(v));
  } else if (v is Uint8List) {
    w.byte(kTagBlob);
    _escaped(w, v);
  } else {
    throw ArgumentError('not a SQL value: ${v.runtimeType}');
  }
  if (desc) w.invertFrom(start);
}

void _encodeDouble(KeyWriter w, double d) {
  if (d.isNaN) {
    w.byte(kTagNull);
    return;
  }
  if (d < -_two63) {
    w.byte(kTagNumLow);
    w.u64(~_doubleBits(-d));
    return;
  }
  if (d >= _two63) {
    w.byte(kTagNumHigh);
    w.u64(_doubleBits(d));
    return;
  }
  final f = d.floorToDouble();
  final fi = f.toInt();
  w.byte(kTagNum);
  w.u64(fi ^ (-0x8000000000000000));
  final frac = d - f;
  if (frac == 0) {
    w.byte(0);
  } else {
    w.byte(1);
    w.u64(_doubleBits(frac));
  }
}

void _escaped(KeyWriter w, List<int> b) {
  for (final x in b) {
    if (x == 0) {
      w.byte(0);
      w.byte(0xFF);
    } else {
      w.byte(x);
    }
  }
  w.byte(0);
  w.byte(0);
}

/// Encodes a tuple. [desc] marks descending components.
Uint8List encodeKey(List<Object?> values, [List<bool>? desc]) {
  final w = KeyWriter();
  for (var i = 0; i < values.length; i++) {
    encodeKeyValue(w, values[i], desc: desc != null && desc[i]);
  }
  return w.take();
}

/// Decodes [count] components (all when null) starting at [offset].
/// Returns the values; [endOut], when given, receives the end offset.
List<Object?> decodeKey(Uint8List key,
    {int offset = 0, int? count, List<bool>? desc, List<int>? endOut}) {
  final out = <Object?>[];
  var p = offset;
  while (p < key.length && (count == null || out.length < count)) {
    final d = desc != null && out.length < desc.length && desc[out.length];
    final r = _decodeOne(key, p, d);
    out.add(r.$1);
    p = r.$2;
  }
  if (endOut != null && endOut.isNotEmpty) endOut[0] = p;
  return out;
}

(Object?, int) _decodeOne(Uint8List k, int p, bool desc) {
  int b(int i) => desc ? (~k[i] & 0xFF) : k[i];
  int u64(int i) {
    var x = 0;
    for (var j = 0; j < 8; j++) {
      x = (x << 8) | b(i + j);
    }
    return x;
  }

  final tag = b(p);
  switch (tag) {
    case kTagNull:
      return (null, p + 1);
    case kTagNumLow:
      return (-_bitsDouble(~u64(p + 1)), p + 9);
    case kTagNumHigh:
      return (_bitsDouble(u64(p + 1)), p + 9);
    case kTagNum:
      final fi = u64(p + 1) ^ (-0x8000000000000000);
      if (b(p + 9) == 0) return (fi, p + 10);
      final frac = _bitsDouble(u64(p + 10));
      return (fi.toDouble() + frac, p + 18);
    case kTagText:
    case kTagBlob:
      final bytes = <int>[];
      var i = p + 1;
      while (true) {
        final x = b(i);
        if (x == 0) {
          if (b(i + 1) == 0) {
            i += 2;
            break;
          }
          bytes.add(0);
          i += 2;
        } else {
          bytes.add(x);
          i++;
        }
      }
      if (tag == kTagText) {
        return (utf8.decode(bytes, allowMalformed: true), i);
      }
      return (Uint8List.fromList(bytes), i);
  }
  throw FormatException('bad key tag $tag at $p');
}

/// Offset just past component starting at [p] (ascending or descending).
int skipKeyValue(Uint8List k, int p, {bool desc = false}) =>
    _decodeOne(k, p, desc).$2;

/// Rowid key of a table tree.
Uint8List encodeRowid(int rowid) {
  final b = Uint8List(8);
  var x = rowid ^ (-0x8000000000000000);
  for (var i = 7; i >= 0; i--) {
    b[i] = x & 0xFF;
    x >>= 8;
  }
  return b;
}

int decodeRowid(Uint8List k, [int offset = 0]) {
  var x = 0;
  for (var j = 0; j < 8; j++) {
    x = (x << 8) | k[offset + j];
  }
  return x ^ (-0x8000000000000000);
}

/// Smallest key greater than every key starting with [prefix] (exclusive
/// upper bound of a prefix scan); null when there is none (all 0xFF).
Uint8List? prefixEnd(Uint8List prefix) {
  var n = prefix.length;
  while (n > 0 && prefix[n - 1] == 0xFF) {
    n--;
  }
  if (n == 0) return null;
  final r = Uint8List.fromList(Uint8List.sublistView(prefix, 0, n));
  r[n - 1]++;
  return r;
}

/// Key suitable as a hash map key for grouping (equal SQL values, e.g. 1
/// and 1.0, give equal strings).
String groupKey(List<Object?> values) {
  final k = encodeKey(values);
  return String.fromCharCodes(k);
}
