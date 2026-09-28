// Pieces of the SQLite database file format shared by the reader and the
// writer (https://www.sqlite.org/fileformat2.html): varints, the record
// format with its serial types, the payload split between a b-tree cell
// and its overflow pages, and the comparison of index keys (BINARY,
// NOCASE and RTRIM collations, NULL < numbers < text < BLOB).

import 'dart:convert';
import 'dart:typed_data';

/// The version number the writer puts in the header (3.45.1).
const int sqliteVersionNumber = 3045001;

/// The 16 byte magic string at the start of every database file.
final Uint8List sqliteMagic =
    Uint8List.fromList(ascii.encode('SQLite format 3\u0000'));

// ---------------------------------------------------------------- varints

/// Reads the varint at [p]: (value, length).
(int, int) readVarint(Uint8List b, int p) {
  var v = 0;
  for (var i = 0; i < 8; i++) {
    final c = b[p + i];
    v = (v << 7) | (c & 0x7f);
    if (c < 0x80) return (v, i + 1);
  }
  v = (v << 8) | b[p + 8];
  return (v, 9);
}

/// Bytes a varint of [v] takes.
int varintLength(int v) {
  if (v < 0 || v > 0x00ffffffffffffff) return 9;
  var n = 1;
  while (v > 0x7f) {
    v >>>= 7;
    n++;
  }
  return n;
}

/// Writes the varint of [v] at [p]; returns its length.
int writeVarint(Uint8List b, int p, int v) {
  if (v < 0 || v > 0x00ffffffffffffff) {
    b[p + 8] = v & 0xff;
    v >>>= 8;
    for (var i = 7; i >= 0; i--) {
      b[p + i] = (v & 0x7f) | 0x80;
      v >>>= 7;
    }
    return 9;
  }
  final n = varintLength(v);
  for (var i = n - 1; i >= 0; i--) {
    b[p + i] = (v & 0x7f) | (i == n - 1 ? 0 : 0x80);
    v >>>= 7;
  }
  return n;
}

// ---------------------------------------------------------- record format

/// Content bytes of serial type [t].
int serialTypeSize(int t) {
  switch (t) {
    case 0:
    case 8:
    case 9:
      return 0;
    case 1:
      return 1;
    case 2:
      return 2;
    case 3:
      return 3;
    case 4:
      return 4;
    case 5:
      return 6;
    case 6:
    case 7:
      return 8;
    case 10:
    case 11:
      throw const FormatException('reserved serial type');
  }
  return (t - 12) >> 1;
}

/// Text encodings of a database (header offset 56).
enum SqliteTextEncoding { utf8, utf16le, utf16be }

String _decodeText(Uint8List b, int p, int n, SqliteTextEncoding enc) {
  switch (enc) {
    case SqliteTextEncoding.utf8:
      return utf8.decode(Uint8List.sublistView(b, p, p + n),
          allowMalformed: true);
    case SqliteTextEncoding.utf16le:
    case SqliteTextEncoding.utf16be:
      final le = enc == SqliteTextEncoding.utf16le;
      final units = List<int>.filled(n >> 1, 0);
      for (var i = 0; i < units.length; i++) {
        final a = b[p + 2 * i], c = b[p + 2 * i + 1];
        units[i] = le ? a | (c << 8) : (a << 8) | c;
      }
      return String.fromCharCodes(units);
  }
}

/// Decodes a record: a list of null, int, double, String and Uint8List.
List<Object?> decodeSqliteRecord(Uint8List b,
    [SqliteTextEncoding enc = SqliteTextEncoding.utf8]) {
  final (hdr, l0) = readVarint(b, 0);
  var hp = l0;
  var dp = hdr;
  final out = <Object?>[];
  while (hp < hdr) {
    final (t, l) = readVarint(b, hp);
    hp += l;
    final n = serialTypeSize(t);
    if (dp + n > b.length) throw const FormatException('record overflows');
    switch (t) {
      case 0:
        out.add(null);
      case 8:
        out.add(0);
      case 9:
        out.add(1);
      case 7:
        out.add(ByteData.sublistView(b, dp, dp + 8).getFloat64(0));
      case >= 1 && <= 6:
        var v = b[dp] >= 0x80 ? -1 : 0;
        for (var i = 0; i < n; i++) {
          v = (v << 8) | b[dp + i];
        }
        out.add(v);
      default:
        if (t.isEven) {
          out.add(Uint8List.fromList(Uint8List.sublistView(b, dp, dp + n)));
        } else {
          out.add(_decodeText(b, dp, n, enc));
        }
    }
    dp += n;
  }
  return out;
}

int _intSerialType(int v) {
  if (v == 0) return 8;
  if (v == 1) return 9;
  if (v >= -128 && v <= 127) return 1;
  if (v >= -32768 && v <= 32767) return 2;
  if (v >= -8388608 && v <= 8388607) return 3;
  if (v >= -2147483648 && v <= 2147483647) return 4;
  if (v >= -140737488355328 && v <= 140737488355327) return 5;
  return 6;
}

/// Encodes a record (UTF-8 text). Doubles that are NaN become NULL, as
/// in SQLite; bools become 0 or 1.
Uint8List encodeSqliteRecord(List<Object?> values) {
  final types = <int>[];
  final bodies = <Object?>[];
  var body = 0;
  for (var v in values) {
    if (v is bool) v = v ? 1 : 0;
    if (v is double && v.isNaN) v = null;
    if (v == null) {
      types.add(0);
      bodies.add(null);
    } else if (v is int) {
      final t = _intSerialType(v);
      types.add(t);
      bodies.add(v);
      body += serialTypeSize(t);
    } else if (v is double) {
      types.add(7);
      bodies.add(v);
      body += 8;
    } else if (v is String) {
      final u = utf8.encode(v);
      types.add(13 + 2 * u.length);
      bodies.add(u);
      body += u.length;
    } else if (v is List<int>) {
      types.add(12 + 2 * v.length);
      bodies.add(v);
      body += v.length;
    } else {
      final u = utf8.encode(v.toString());
      types.add(13 + 2 * u.length);
      bodies.add(u);
      body += u.length;
    }
  }
  var hdr = 0;
  for (final t in types) {
    hdr += varintLength(t);
  }
  // the header size counts its own varint
  var hsize = hdr + 1;
  while (varintLength(hsize) + hdr != hsize) {
    hsize = hdr + varintLength(hsize);
  }
  final out = Uint8List(hsize + body);
  var p = writeVarint(out, 0, hsize);
  for (final t in types) {
    p += writeVarint(out, p, t);
  }
  final bd = ByteData.sublistView(out);
  for (var i = 0; i < types.length; i++) {
    final t = types[i];
    final v = bodies[i];
    switch (t) {
      case 0:
      case 8:
      case 9:
        break;
      case 7:
        bd.setFloat64(p, v as double);
        p += 8;
      case >= 1 && <= 6:
        final n = serialTypeSize(t);
        var x = v as int;
        for (var k = n - 1; k >= 0; k--) {
          out[p + k] = x & 0xff;
          x >>= 8;
        }
        p += n;
      default:
        final l = v as List<int>;
        out.setRange(p, p + l.length, l);
        p += l.length;
    }
  }
  return out;
}

// ------------------------------------------------------ payload splitting

/// Bytes of a payload of [p] bytes kept in the cell (the rest goes to
/// overflow pages), for usable page size [u].
int localPayload(int p, int u, {required bool tableLeaf}) {
  final x = tableLeaf ? u - 35 : ((u - 12) * 64 ~/ 255) - 23;
  if (p <= x) return p;
  final m = ((u - 12) * 32 ~/ 255) - 23;
  final k = m + ((p - m) % (u - 4));
  return k <= x ? k : m;
}

// ------------------------------------------------------------ comparison

/// Collating sequences SQLite has built in.
enum SqliteCollation { binary, nocase, rtrim }

SqliteCollation collationOf(String? name) {
  switch (name?.toUpperCase()) {
    case 'NOCASE':
      return SqliteCollation.nocase;
    case 'RTRIM':
      return SqliteCollation.rtrim;
  }
  return SqliteCollation.binary;
}

int _rank(Object? v) {
  if (v == null) return 0;
  if (v is num) return 1;
  if (v is String) return 2;
  return 3;
}

int _memcmp(List<int> a, List<int> b) {
  final n = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    final d = a[i] - b[i];
    if (d != 0) return d;
  }
  return a.length - b.length;
}

int _cmpIntReal(int i, double r) {
  if (r.isNaN) return 1;
  if (r < -9223372036854775808.0) return 1;
  if (r >= 9223372036854775808.0) return -1;
  final t = r.truncate();
  if (i < t) return -1;
  if (i > t) return 1;
  final f = r - t;
  if (f > 0) return -1;
  if (f < 0) return 1;
  return 0;
}

/// Compares two values as SQLite compares index keys.
int compareSqliteValues(Object? a, Object? b,
    [SqliteCollation coll = SqliteCollation.binary]) {
  final ra = _rank(a), rb = _rank(b);
  if (ra != rb) return ra - rb;
  switch (ra) {
    case 0:
      return 0;
    case 1:
      if (a is int && b is int) return a.compareTo(b);
      if (a is int) return _cmpIntReal(a, b as double);
      if (b is int) return -_cmpIntReal(b, a as double);
      return (a as double).compareTo(b as double);
    case 2:
      var x = utf8.encode(a as String);
      var y = utf8.encode(b as String);
      if (coll == SqliteCollation.nocase) {
        x = Uint8List.fromList([for (final c in x) c >= 65 && c <= 90 ? c + 32 : c]);
        y = Uint8List.fromList([for (final c in y) c >= 65 && c <= 90 ? c + 32 : c]);
      } else if (coll == SqliteCollation.rtrim) {
        var n = x.length, m = y.length;
        while (n > 0 && x[n - 1] == 32) {
          n--;
        }
        while (m > 0 && y[m - 1] == 32) {
          m--;
        }
        x = Uint8List.sublistView(x, 0, n);
        y = Uint8List.sublistView(y, 0, m);
      }
      return _memcmp(x, y);
    default:
      return _memcmp(a as List<int>, b as List<int>);
  }
}

/// One field of an index key: its collation and direction.
class SqliteKeyField {
  final SqliteCollation collation;
  final bool desc;
  const SqliteKeyField(this.collation, this.desc);
}

/// Compares index keys field by field ([fields] may be shorter than the
/// keys: the rest compares with BINARY, ascending).
int compareSqliteKeys(
    List<Object?> a, List<Object?> b, List<SqliteKeyField> fields) {
  final n = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    final f = i < fields.length ? fields[i] : null;
    var c = compareSqliteValues(
        a[i], b[i], f?.collation ?? SqliteCollation.binary);
    if (c != 0) {
      if (f != null && f.desc) c = -c;
      return c;
    }
  }
  return a.length - b.length;
}
