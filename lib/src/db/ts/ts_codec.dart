// Column encodings of the zxdb time series (docs/zxdb-design.md 2.3 and
// section 12): the byte writer and reader, zigzag varints, delta-of-delta
// timestamps, delta integers, XOR floats (Gorilla style, byte aligned),
// dictionary and plain strings, a generic tagged value stream, a null
// bitmap and a Bloom filter for tag columns.
//
// A column of a sealed segment is one blob:
//
//   kind u8, rows varint, nulls u8 (1: a bitmap of ceil(rows/8) bytes
//   follows, bit set = value present), then the sections of the kind,
//   each: mode u8 (0 raw, 1 coded), raw length varint, when coded the
//   coders (count u8, then per coder: codec id varint, props length
//   varint, props), payload length varint, payload.
//
// Kinds and their sections (values of present rows only):
//   0 all NULL          none
//   1 timestamps        delta of delta, zigzag varints (fast chain)
//   2 integers          first value then deltas, zigzag varints (fast)
//   3 floats            XOR with the previous value's bits: a control
//                       byte (0: same value; else 1 + 8 * leading zero
//                       bytes + trailing zero bytes) then the meaningful
//                       bytes, big endian (fast)
//   4 dictionary text   the dictionary as text (text chain), the indexes
//                       as varints (fast)
//   5 plain text        the strings as text (text chain)
//   6 generic           tagged values (text chain): 0 NULL, 1 int
//                       (zigzag varint), 2 double (8 bytes), 3 text
//                       (varint length, UTF-8), 4 blob (varint length)
//
// A text section starts with a flag byte: 0 the strings are joined with
// '\n' (none holds one, the form context models like best), 1 each is a
// varint length and its bytes.

import 'dart:convert';
import 'dart:typed_data';

import '../../format/zx/zx_codecs.dart';
import '../../format/zx/zx_format.dart' show ZxCoder, ZxChain;
import '../storage_api.dart';

/// A growable byte buffer.
class TsWriter {
  Uint8List _b;
  int n = 0;
  TsWriter([int capacity = 256]) : _b = Uint8List(capacity);

  void _grow(int extra) {
    var c = _b.length * 2;
    while (c < n + extra) {
      c *= 2;
    }
    final nb = Uint8List(c);
    nb.setRange(0, n, _b);
    _b = nb;
  }

  void byte(int v) {
    if (n + 1 > _b.length) _grow(1);
    _b[n++] = v;
  }

  /// Unsigned LEB128 of the 64 bit pattern of [v].
  void varint(int v) {
    if (n + 10 > _b.length) _grow(10);
    final b = _b;
    var p = n;
    var x = v;
    while (x & ~0x7F != 0) {
      b[p++] = (x & 0x7F) | 0x80;
      x = x >>> 7;
    }
    b[p++] = x;
    n = p;
  }

  void zigzag(int v) => varint((v << 1) ^ (v >> 63));

  void bytes(List<int> src, [int start = 0, int? end]) {
    final e = end ?? src.length;
    final len = e - start;
    if (n + len > _b.length) _grow(len);
    _b.setRange(n, n + len, src, start);
    n += len;
  }

  /// A varint length and the UTF-8 bytes of [s] (ASCII without a copy).
  void string(String s) {
    final len = s.length;
    var ascii = true;
    for (var i = 0; i < len; i++) {
      if (s.codeUnitAt(i) >= 0x80) {
        ascii = false;
        break;
      }
    }
    if (!ascii) {
      final u = utf8.encode(s);
      varint(u.length);
      bytes(u);
      return;
    }
    varint(len);
    if (n + len > _b.length) _grow(len);
    final b = _b;
    var p = n;
    for (var i = 0; i < len; i++) {
      b[p++] = s.codeUnitAt(i);
    }
    n = p;
  }

  void int64(int v) {
    if (n + 8 > _b.length) _grow(8);
    final b = _b;
    for (var i = 7; i >= 0; i--) {
      b[n + i] = v & 0xFF;
      v = v >> 8;
    }
    n += 8;
  }

  Uint8List take() => Uint8List.sublistView(_b, 0, n);
  Uint8List copy() => Uint8List.fromList(Uint8List.sublistView(_b, 0, n));
}

/// A reader over bytes.
class TsReader {
  final Uint8List b;
  int p;
  TsReader(this.b, [this.p = 0]);

  bool get atEnd => p >= b.length;

  int byte() {
    if (p >= b.length) throw _corrupt();
    return b[p++];
  }

  int varint() {
    var x = 0;
    var s = 0;
    final bb = b;
    var q = p;
    while (true) {
      if (q >= bb.length) throw _corrupt();
      final c = bb[q++];
      x |= (c & 0x7F) << s;
      if (c < 0x80) break;
      s += 7;
      if (s > 63) throw _corrupt();
    }
    p = q;
    return x;
  }

  int zigzag() {
    final u = varint();
    return (u >>> 1) ^ -(u & 1);
  }

  Uint8List bytes(int len) {
    if (len < 0 || p + len > b.length) throw _corrupt();
    final r = Uint8List.sublistView(b, p, p + len);
    p += len;
    return r;
  }

  int int64() {
    if (p + 8 > b.length) throw _corrupt();
    var v = 0;
    for (var i = 0; i < 8; i++) {
      v = (v << 8) | b[p + i];
    }
    p += 8;
    return v;
  }
}

ZxDbException _corrupt() =>
    const ZxDbException('time series: corrupt data', ZxDbError.corrupt);

// ------------------------------------------------------------ keys

/// 8 bytes big endian with the sign bit flipped (signed order as bytes).
void tsPutKeyInt(Uint8List k, int off, int v) {
  final u = v ^ (1 << 63);
  for (var i = 7; i >= 0; i--) {
    k[off + i] = (u >>> ((7 - i) * 8)) & 0xFF;
  }
}

int tsGetKeyInt(Uint8List k, int off) {
  var v = 0;
  for (var i = 0; i < 8; i++) {
    v = (v << 8) | k[off + i];
  }
  return v ^ (1 << 63);
}

// ------------------------------------------------------------ values

/// Writes one tagged value (the generic kind and the write buffer).
void tsWriteValue(TsWriter w, Object? v) {
  if (v == null) {
    w.byte(0);
  } else if (v is int) {
    w.byte(1);
    w.zigzag(v);
  } else if (v is double) {
    w.byte(2);
    final bd = ByteData(8)..setFloat64(0, v);
    w.int64(bd.getInt64(0));
  } else if (v is String) {
    w.byte(3);
    w.string(v);
  } else if (v is Uint8List) {
    w.byte(4);
    w.varint(v.length);
    w.bytes(v);
  } else {
    throw ZxDbException(
        'time series: unsupported value ${v.runtimeType}', ZxDbError.constraint);
  }
}

final ByteData _bd8 = ByteData(8);

Object? tsReadValue(TsReader r) {
  switch (r.byte()) {
    case 0:
      return null;
    case 1:
      return r.zigzag();
    case 2:
      _bd8.setInt64(0, r.int64());
      return _bd8.getFloat64(0);
    case 3:
      final n = r.varint();
      return utf8.decode(r.bytes(n));
    case 4:
      final n = r.varint();
      return Uint8List.fromList(r.bytes(n));
  }
  throw _corrupt();
}

// ------------------------------------------------------------ sections

/// A section to be written: raw bytes and whether the text chain (else
/// the fast chain) codes it.
class TsSection {
  final Uint8List raw;
  final bool text;
  Uint8List? payload; // coded bytes (null: raw)
  List<ZxCoder>? coders;
  TsSection(this.raw, this.text);
}

/// A column being written: its header bytes and its sections.
class TsColumnDraft {
  final Uint8List head;
  final List<TsSection> sections;
  TsColumnDraft(this.head, this.sections);

  Uint8List build() {
    final w = TsWriter(head.length + 64);
    w.bytes(head);
    w.byte(sections.length);
    for (final s in sections) {
      final p = s.payload;
      final cs = s.coders;
      if (p == null || cs == null) {
        w.byte(0);
        w.varint(s.raw.length);
        w.varint(s.raw.length);
        w.bytes(s.raw);
      } else {
        w.byte(1);
        w.varint(s.raw.length);
        w.byte(cs.length);
        for (final c in cs) {
          w.varint(c.codecId);
          w.varint(c.props.length);
          w.bytes(c.props);
        }
        w.varint(p.length);
        w.bytes(p);
      }
    }
    return w.copy();
  }
}

/// Codes [raw] with [specs]; returns null when that does not save bytes.
(Uint8List, List<ZxCoder>)? tsCode(Uint8List raw, List<ZxCoderSpec> specs) {
  if (specs.isEmpty || raw.length < 64) return null;
  final (d, cs) = zxEncodeChain(Uint8List.fromList(raw), specs);
  if (d.length + 8 >= raw.length) return null;
  return (d, cs);
}

/// Reads the sections of a column blob after its header; returns their
/// raw bytes.
List<Uint8List> tsReadSections(TsReader r) {
  final n = r.byte();
  final out = <Uint8List>[];
  for (var i = 0; i < n; i++) {
    final mode = r.byte();
    final rawLen = r.varint();
    if (mode == 0) {
      final len = r.varint();
      out.add(r.bytes(len));
      continue;
    }
    final nc = r.byte();
    final coders = <ZxCoder>[];
    for (var j = 0; j < nc; j++) {
      final id = r.varint();
      final pl = r.varint();
      coders.add(ZxCoder(id, Uint8List.fromList(r.bytes(pl))));
    }
    final len = r.varint();
    final payload = Uint8List.fromList(r.bytes(len));
    out.add(zxDecodeChain(payload, ZxChain(0, coders), rawLen));
  }
  return out;
}

// ------------------------------------------------------------ kinds

const int tsKindNull = 0;
const int tsKindTs = 1;
const int tsKindInt = 2;
const int tsKindFloat = 3;
const int tsKindDict = 4;
const int tsKindText = 5;
const int tsKindAny = 6;

/// Encodes timestamps (never NULL) as delta of delta.
Uint8List tsEncodeTimestamps(Int64List v) {
  final w = TsWriter(v.length + 16);
  final n = v.length;
  if (n == 0) return w.copy();
  w.zigzag(v[0]);
  if (n == 1) return w.copy();
  var prevDelta = v[1] - v[0];
  w.zigzag(prevDelta);
  for (var i = 2; i < n; i++) {
    final d = v[i] - v[i - 1];
    w.zigzag(d - prevDelta);
    prevDelta = d;
  }
  return w.copy();
}

Int64List tsDecodeTimestamps(Uint8List b, int n) {
  final out = Int64List(n);
  if (n == 0) return out;
  final r = TsReader(b);
  var prev = r.zigzag();
  out[0] = prev;
  if (n == 1) return out;
  var delta = r.zigzag();
  prev += delta;
  out[1] = prev;
  for (var i = 2; i < n; i++) {
    delta += r.zigzag();
    prev += delta;
    out[i] = prev;
  }
  return out;
}

Uint8List tsEncodeInts(Int64List v, int n) {
  final w = TsWriter(n + 16);
  var prev = 0;
  for (var i = 0; i < n; i++) {
    final x = v[i];
    w.zigzag(x - prev);
    prev = x;
  }
  return w.copy();
}

Int64List tsDecodeInts(Uint8List b, int n) {
  final out = Int64List(n);
  final r = TsReader(b);
  var prev = 0;
  for (var i = 0; i < n; i++) {
    prev += r.zigzag();
    out[i] = prev;
  }
  return out;
}

Uint8List tsEncodeFloats(Float64List v, int n) {
  final bits = Int64List.view(v.buffer, v.offsetInBytes, n);
  final w = TsWriter(n * 3 + 16);
  var prev = 0;
  for (var i = 0; i < n; i++) {
    final x = bits[i] ^ prev;
    prev = bits[i];
    if (x == 0) {
      w.byte(0);
      continue;
    }
    var lz = 0;
    while (lz < 7 && (x >>> (56 - lz * 8)) & 0xFF == 0) {
      lz++;
    }
    var tz = 0;
    while (tz < 7 - lz && (x >>> (tz * 8)) & 0xFF == 0) {
      tz++;
    }
    w.byte(1 + lz * 8 + tz);
    for (var k = 7 - lz; k >= tz; k--) {
      w.byte((x >>> (k * 8)) & 0xFF);
    }
  }
  return w.copy();
}

Float64List tsDecodeFloats(Uint8List b, int n) {
  final out = Float64List(n);
  final bits = Int64List.view(out.buffer);
  var p = 0;
  var prev = 0;
  for (var i = 0; i < n; i++) {
    if (p >= b.length) throw _corrupt();
    final c = b[p++];
    if (c != 0) {
      final lz = (c - 1) >> 3;
      final tz = (c - 1) & 7;
      var x = 0;
      final m = 8 - lz - tz;
      if (m <= 0 || p + m > b.length) throw _corrupt();
      for (var k = 0; k < m; k++) {
        x = (x << 8) | b[p++];
      }
      prev ^= x << (tz * 8);
    }
    bits[i] = prev;
  }
  return out;
}

/// Strings as one text section (see the file comment).
Uint8List tsEncodeStrings(List<String> v) {
  var nl = false;
  for (final s in v) {
    if (s.contains('\n')) {
      nl = true;
      break;
    }
  }
  final w = TsWriter(v.length * 16 + 16);
  if (!nl) {
    w.byte(0);
    for (var i = 0; i < v.length; i++) {
      if (i > 0) w.byte(10);
      w.bytes(utf8.encode(v[i]));
    }
  } else {
    w.byte(1);
    for (final s in v) {
      final u = utf8.encode(s);
      w.varint(u.length);
      w.bytes(u);
    }
  }
  return w.copy();
}

/// The strings of a text section as UTF-8 slices (start, end) of [b].
Int32List tsStringOffsets(Uint8List b, int n) {
  final off = Int32List(n * 2);
  if (n == 0) return off;
  if (b.isEmpty) throw _corrupt();
  if (b[0] == 0) {
    var s = 1;
    var i = 0;
    final len = b.length;
    for (var p = 1; p < len; p++) {
      if (b[p] == 10) {
        if (i >= n) throw _corrupt();
        off[2 * i] = s;
        off[2 * i + 1] = p;
        i++;
        s = p + 1;
      }
    }
    if (i != n - 1) throw _corrupt();
    off[2 * i] = s;
    off[2 * i + 1] = len;
    return off;
  }
  final r = TsReader(b, 1);
  for (var i = 0; i < n; i++) {
    final l = r.varint();
    off[2 * i] = r.p;
    r.p += l;
    if (r.p > b.length) throw _corrupt();
    off[2 * i + 1] = r.p;
  }
  return off;
}

// ------------------------------------------------------------ bloom

/// FNV-1a 64 of the bytes of a tag value (its text; numbers in decimal).
int tsHashValue(Object? v) {
  final s = v is String ? v : '$v';
  var h = 0xcbf29ce484222325;
  for (var i = 0; i < s.length; i++) {
    h ^= s.codeUnitAt(i);
    h *= 0x100000001b3;
  }
  return h;
}

/// A Bloom filter: 10 bits per value, 4 probes (double hashing).
Uint8List tsBloomBuild(Iterable<int> hashes, int count) {
  var bits = count * 10;
  if (bits < 64) bits = 64;
  final nb = (bits + 7) >> 3;
  final f = Uint8List(nb);
  final m = nb * 8;
  for (final h in hashes) {
    final h1 = h & 0x7FFFFFFF;
    final h2 = ((h >>> 32) & 0x7FFFFFFF) | 1;
    for (var k = 0; k < 4; k++) {
      final bit = (h1 + k * h2) % m;
      f[bit >> 3] |= 1 << (bit & 7);
    }
  }
  return f;
}

bool tsBloomMay(Uint8List f, int h) {
  if (f.isEmpty) return true;
  final m = f.length * 8;
  final h1 = h & 0x7FFFFFFF;
  final h2 = ((h >>> 32) & 0x7FFFFFFF) | 1;
  for (var k = 0; k < 4; k++) {
    final bit = (h1 + k * h2) % m;
    if (f[bit >> 3] & (1 << (bit & 7)) == 0) return false;
  }
  return true;
}

// ------------------------------------------------------------ columns

/// Builds the draft of a column of [values] (the rows of a segment).
/// [isTs]: the time column (Int64List of ns, no NULLs).
TsColumnDraft tsEncodeColumn(List<Object?> values) {
  final n = values.length;
  var nulls = 0;
  var ints = 0, doubles = 0, strings = 0;
  for (var i = 0; i < n; i++) {
    final v = values[i];
    if (v == null) {
      nulls++;
    } else if (v is int) {
      ints++;
    } else if (v is double) {
      doubles++;
    } else if (v is String) {
      strings++;
    }
  }
  final present = n - nulls;
  final head = TsWriter(16 + (nulls > 0 ? (n + 7) >> 3 : 0));
  int kind;
  if (present == 0) {
    kind = tsKindNull;
  } else if (ints == present) {
    kind = tsKindInt;
  } else if (doubles == present) {
    kind = tsKindFloat;
  } else if (strings == present) {
    kind = tsKindText; // or dictionary, decided below
  } else {
    kind = tsKindAny;
  }
  // present values (NULLs go to the bitmap), except the generic kind
  // which tags NULLs itself
  final useBitmap = nulls > 0 && kind != tsKindNull && kind != tsKindAny;
  final sections = <TsSection>[];
  List<Object?> pv = values;
  if (useBitmap) {
    pv = [
      for (var i = 0; i < n; i++)
        if (values[i] != null) values[i]
    ];
  }
  switch (kind) {
    case tsKindInt:
      final a = Int64List(present);
      for (var i = 0; i < present; i++) {
        a[i] = pv[i] as int;
      }
      sections.add(TsSection(tsEncodeInts(a, present), false));
    case tsKindFloat:
      final a = Float64List(present);
      for (var i = 0; i < present; i++) {
        a[i] = pv[i] as double;
      }
      sections.add(TsSection(tsEncodeFloats(a, present), false));
    case tsKindText:
      final dict = <String, int>{};
      final idx = Int32List(present);
      for (var i = 0; i < present; i++) {
        final v = pv[i] as String;
        final e = dict[v];
        if (e != null) {
          idx[i] = e;
        } else {
          final k = dict.length;
          dict[v] = k;
          idx[i] = k;
        }
      }
      if (dict.length * 4 <= present || dict.length <= 16 && present > 64) {
        kind = tsKindDict;
        sections.add(TsSection(tsEncodeStrings(dict.keys.toList()), true));
        final w = TsWriter(present + 16);
        w.varint(dict.length);
        for (var i = 0; i < present; i++) {
          w.varint(idx[i]);
        }
        sections.add(TsSection(w.copy(), false));
      } else {
        sections.add(TsSection(tsEncodeStrings(pv.cast<String>()), true));
      }
    case tsKindAny:
      final w = TsWriter(n * 8 + 16);
      for (var i = 0; i < n; i++) {
        tsWriteValue(w, values[i]);
      }
      sections.add(TsSection(w.copy(), true));
  }
  head.byte(kind);
  head.varint(n);
  if (useBitmap) {
    head.byte(1);
    final bm = Uint8List((n + 7) >> 3);
    for (var i = 0; i < n; i++) {
      if (values[i] != null) bm[i >> 3] |= 1 << (i & 7);
    }
    head.bytes(bm);
  } else {
    head.byte(0);
  }
  return TsColumnDraft(head.copy(), sections);
}

/// The time column's draft.
TsColumnDraft tsEncodeTsColumn(Int64List ts) {
  final head = TsWriter(16);
  head.byte(tsKindTs);
  head.varint(ts.length);
  head.byte(0);
  return TsColumnDraft(head.copy(), [TsSection(tsEncodeTimestamps(ts), false)]);
}

/// A decoded column: values by row, decoded lazily for text.
class TsColumn {
  final int kind;
  final int rows;
  final Uint8List? bitmap;

  // the present-value index of each row (with a bitmap)
  Int32List? _rank;
  Int64List? ints;
  Float64List? floats;
  List<String?>? dict;
  Int32List? dictIndex;
  Uint8List? text;
  Int32List? textOff;
  List<String?>? _textCache;
  List<Object?>? any;

  TsColumn._(this.kind, this.rows, this.bitmap);

  static TsColumn decode(Uint8List blob) {
    final r = TsReader(blob);
    final kind = r.byte();
    final n = r.varint();
    final hasBm = r.byte() == 1;
    Uint8List? bm;
    if (hasBm) bm = Uint8List.fromList(r.bytes((n + 7) >> 3));
    final c = TsColumn._(kind, n, bm);
    var present = n;
    if (bm != null) {
      final rank = Int32List(n);
      var k = 0;
      for (var i = 0; i < n; i++) {
        if (bm[i >> 3] & (1 << (i & 7)) != 0) {
          rank[i] = k++;
        } else {
          rank[i] = -1;
        }
      }
      c._rank = rank;
      present = k;
    }
    if (kind == tsKindNull) return c;
    final s = tsReadSections(r);
    switch (kind) {
      case tsKindTs:
        c.ints = tsDecodeTimestamps(s[0], present);
      case tsKindInt:
        c.ints = tsDecodeInts(s[0], present);
      case tsKindFloat:
        c.floats = tsDecodeFloats(s[0], present);
      case tsKindDict:
        final ir = TsReader(s[1]);
        final dn = ir.varint();
        final off = tsStringOffsets(s[0], dn);
        final d = List<String?>.filled(dn, null);
        for (var i = 0; i < dn; i++) {
          d[i] = utf8.decode(Uint8List.sublistView(s[0], off[2 * i], off[2 * i + 1]));
        }
        c.dict = d;
        final idx = Int32List(present);
        for (var i = 0; i < present; i++) {
          idx[i] = ir.varint();
        }
        c.dictIndex = idx;
      case tsKindText:
        c.text = s[0];
        c.textOff = tsStringOffsets(s[0], present);
        c._textCache = List<String?>.filled(present, null);
      case tsKindAny:
        final ar = TsReader(s[0]);
        c.any = [for (var i = 0; i < n; i++) tsReadValue(ar)];
      default:
        throw _corrupt();
    }
    return c;
  }

  /// Approximate memory (for the cache).
  int get bytes =>
      64 +
      (ints?.lengthInBytes ?? 0) +
      (floats?.lengthInBytes ?? 0) +
      (dictIndex?.lengthInBytes ?? 0) +
      (text?.length ?? 0) * 3 +
      (textOff?.lengthInBytes ?? 0) +
      (dict?.length ?? 0) * 48 +
      (any?.length ?? 0) * 32 +
      (_rank?.lengthInBytes ?? 0);

  Object? value(int row) {
    var i = row;
    final rk = _rank;
    if (rk != null) {
      i = rk[row];
      if (i < 0) return null;
    }
    switch (kind) {
      case tsKindTs:
      case tsKindInt:
        return ints![i];
      case tsKindFloat:
        return floats![i];
      case tsKindDict:
        return dict![dictIndex![i]];
      case tsKindText:
        final c = _textCache!;
        final s = c[i];
        if (s != null) return s;
        final off = textOff!;
        return c[i] = utf8.decode(
            Uint8List.sublistView(text!, off[2 * i], off[2 * i + 1]));
      case tsKindAny:
        return any![i];
    }
    return null;
  }
}
