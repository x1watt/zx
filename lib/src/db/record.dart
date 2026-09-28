// Compact row encoding for table values (zxdb).
//
// A record is a sequence of values, each a one byte tag followed by its
// payload:
//
//   0x00           NULL
//   0x01 varint    INTEGER, zigzag encoded (small magnitudes take 1 byte)
//   0x02 8 bytes   REAL, IEEE 754 big endian
//   0x03 varint n  TEXT, n bytes of UTF-8
//   0x04 varint n  BLOB, n bytes
//   0x05           INTEGER 0
//   0x06           INTEGER 1
//
// Varints are unsigned LEB128 (7 bits per byte, low group first). There is
// no header or column count: the number of values is the number of tagged
// items, and rows written before ALTER TABLE ADD COLUMN are shorter than
// the current column list (readers fill the missing trailing columns with
// the column defaults, as SQLite does).

import 'dart:convert';
import 'dart:typed_data';

class RecordWriter {
  Uint8List _b = Uint8List(64);
  int _n = 0;

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

  void _varint(int x) {
    _ensure(10);
    // Unsigned 64-bit LEB128.
    while (true) {
      final low = x & 0x7F;
      x = (x >> 7) & 0x01FFFFFFFFFFFFFF;
      if (x == 0) {
        _b[_n++] = low;
        return;
      }
      _b[_n++] = low | 0x80;
    }
  }

  void add(Object? v) {
    if (v == null) {
      _ensure(1);
      _b[_n++] = 0;
    } else if (v is int) {
      if (v == 0 || v == 1) {
        _ensure(1);
        _b[_n++] = v == 0 ? 5 : 6;
        return;
      }
      _ensure(1);
      _b[_n++] = 1;
      _varint((v << 1) ^ (v >> 63));
    } else if (v is double) {
      _ensure(9);
      _b[_n++] = 2;
      final bd = ByteData.sublistView(_b, _n, _n + 8);
      bd.setFloat64(0, v);
      _n += 8;
    } else if (v is String) {
      final u = utf8.encode(v);
      _ensure(1);
      _b[_n++] = 3;
      _varint(u.length);
      _ensure(u.length);
      _b.setRange(_n, _n + u.length, u);
      _n += u.length;
    } else if (v is Uint8List) {
      _ensure(1);
      _b[_n++] = 4;
      _varint(v.length);
      _ensure(v.length);
      _b.setRange(_n, _n + v.length, v);
      _n += v.length;
    } else {
      throw ArgumentError('not a SQL value: ${v.runtimeType}');
    }
  }

  Uint8List take() => Uint8List.fromList(Uint8List.sublistView(_b, 0, _n));
}

Uint8List encodeRecord(List<Object?> values) {
  final w = RecordWriter();
  for (final v in values) {
    w.add(v);
  }
  return w.take();
}

/// Decodes a record into [out] (appending); returns [out].
List<Object?> decodeRecord(Uint8List b, [List<Object?>? out]) {
  out ??= <Object?>[];
  var p = 0;
  final n = b.length;
  while (p < n) {
    final tag = b[p++];
    switch (tag) {
      case 0:
        out.add(null);
      case 5:
        out.add(0);
      case 6:
        out.add(1);
      case 1:
        var x = 0, s = 0;
        while (true) {
          final c = b[p++];
          x |= (c & 0x7F) << s;
          if (c < 0x80) break;
          s += 7;
        }
        out.add(((x >> 1) & 0x7FFFFFFFFFFFFFFF) ^ -(x & 1));
      case 2:
        out.add(ByteData.sublistView(b, p, p + 8).getFloat64(0));
        p += 8;
      case 3:
      case 4:
        var len = 0, s = 0;
        while (true) {
          final c = b[p++];
          len |= (c & 0x7F) << s;
          if (c < 0x80) break;
          s += 7;
        }
        if (tag == 3) {
          out.add(utf8.decode(Uint8List.sublistView(b, p, p + len),
              allowMalformed: true));
        } else {
          out.add(Uint8List.fromList(Uint8List.sublistView(b, p, p + len)));
        }
        p += len;
      default:
        throw FormatException('bad record tag $tag');
    }
  }
  return out;
}
