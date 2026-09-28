// SQL values and their semantics (SQLite rules): storage classes, type
// affinity, comparison, conversion between numbers and text, CAST, and
// LIKE / GLOB.
//
// A SQL value is a plain Dart object: null (NULL), int (INTEGER, 64-bit),
// double (REAL), String (TEXT) or Uint8List (BLOB). The zx types BOOLEAN,
// DATETIME, JSON and ARRAY are stored with these classes too (see
// docs/zxdb-sql.md, "Types").

import 'dart:convert';
import 'dart:typed_data';

import '../storage_api.dart';

/// Column / expression affinity. [none] is the "no affinity" of
/// expressions (literals, function results); [blob] is the affinity of
/// columns declared BLOB or without a type. Neither converts values.
enum Affinity { none, blob, text, numeric, integer, real }

bool isNumericAffinity(Affinity a) =>
    a == Affinity.numeric || a == Affinity.integer || a == Affinity.real;

/// Affinity applied to both operands of a comparison (SQLite
/// sqlite3CompareAffinity).
Affinity comparisonAffinity(Affinity a, Affinity b) {
  if (a != Affinity.none && b != Affinity.none) {
    if (isNumericAffinity(a) || isNumericAffinity(b)) return Affinity.numeric;
    return Affinity.blob;
  }
  if (a == Affinity.none) return b;
  return a;
}

/// Applies a comparison affinity to one operand (only numeric and text
/// conversions happen; see SQLite section 4.2).
Object? applyCompareAffinity(Object? v, Affinity a) {
  if (v == null) return null;
  if (isNumericAffinity(a)) {
    if (v is String) return textToNumeric(v, integer: false);
    return v;
  }
  if (a == Affinity.text && v is num) return numToText(v);
  return v;
}

/// The zx type of a column beyond its affinity.
enum ZxColumnKind { plain, boolean, datetime, json, array }

/// Affinity of a declared column type (SQLite section 3.1 rules), with the
/// zx types JSON and ARRAY mapped to TEXT (a deviation: SQLite gives them
/// NUMERIC).
Affinity affinityOfType(String? declType) {
  if (declType == null || declType.isEmpty) return Affinity.blob;
  final t = declType.toUpperCase();
  if (t == 'JSON' || t == 'ARRAY' || t.startsWith('ARRAY') ||
      t.startsWith('JSON')) {
    return Affinity.text;
  }
  if (t.contains('INT')) return Affinity.integer;
  if (t.contains('CHAR') || t.contains('CLOB') || t.contains('TEXT')) {
    return Affinity.text;
  }
  if (t.contains('BLOB')) return Affinity.blob;
  if (t.contains('REAL') || t.contains('FLOA') || t.contains('DOUB')) {
    return Affinity.real;
  }
  return Affinity.numeric;
}

ZxColumnKind kindOfType(String? declType) {
  if (declType == null) return ZxColumnKind.plain;
  final t = declType.toUpperCase();
  if (t == 'BOOLEAN' || t == 'BOOL') return ZxColumnKind.boolean;
  if (t == 'DATETIME' || t == 'TIMESTAMP') return ZxColumnKind.datetime;
  if (t.startsWith('JSON')) return ZxColumnKind.json;
  if (t.startsWith('ARRAY')) return ZxColumnKind.array;
  return ZxColumnKind.plain;
}

ZxDbException sqlError(String msg, [ZxDbError kind = ZxDbError.generic]) =>
    ZxDbException(msg, kind);

// ---------------------------------------------------------------- typeof

String typeName(Object? v) {
  if (v == null) return 'null';
  if (v is int) return 'integer';
  if (v is double) return 'real';
  if (v is String) return 'text';
  return 'blob';
}

/// Storage class rank for comparisons: NULL < numbers < TEXT < BLOB.
int classRank(Object? v) {
  if (v == null) return 0;
  if (v is num) return 1;
  if (v is String) return 2;
  return 3;
}

// ---------------------------------------------------------------- numbers

const double _two63 = 9223372036854775808.0;

/// Compares an int and a double exactly.
int compareIntDouble(int i, double d) {
  if (d.isNaN) return 1;
  final di = i.toDouble();
  if (di < d) return -1;
  if (di > d) return 1;
  // Equal after rounding: d is integral and within [-2^63, 2^63].
  if (d >= _two63) return -1;
  final dd = d.toInt();
  return i < dd ? -1 : (i > dd ? 1 : 0);
}

int compareNum(num a, num b) {
  if (a is int) {
    if (b is int) return a < b ? -1 : (a > b ? 1 : 0);
    return compareIntDouble(a, b as double);
  }
  final ad = a as double;
  if (b is int) return -compareIntDouble(b, ad);
  final bd = b as double;
  return ad < bd ? -1 : (ad > bd ? 1 : 0);
}

int compareBytes(Uint8List a, Uint8List b) {
  final n = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    final d = a[i] - b[i];
    if (d != 0) return d < 0 ? -1 : 1;
  }
  return a.length < b.length ? -1 : (a.length > b.length ? 1 : 0);
}

/// Binary (memcmp of UTF-8) text order. Comparing UTF-16 code units gives
/// the same order except for surrogate pairs against U+E000..U+FFFF, which
/// we handle by comparing code points.
int compareText(String a, String b) {
  final n = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    final x = a.codeUnitAt(i), y = b.codeUnitAt(i);
    if (x != y) {
      final xs = x >= 0xD800 && x < 0xE000, ys = y >= 0xD800 && y < 0xE000;
      if (xs != ys) return xs ? 1 : -1;
      return x < y ? -1 : 1;
    }
  }
  return a.length < b.length ? -1 : (a.length > b.length ? 1 : 0);
}

/// Collation function: compares two strings.
typedef Collation = int Function(String a, String b);

int nocaseCompare(String a, String b) =>
    compareText(asciiLower(a), asciiLower(b));

int rtrimCompare(String a, String b) =>
    compareText(_rtrimSpaces(a), _rtrimSpaces(b));

String _rtrimSpaces(String s) {
  var e = s.length;
  while (e > 0 && s.codeUnitAt(e - 1) == 32) {
    e--;
  }
  return s.substring(0, e);
}

String asciiLower(String s) {
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (c >= 65 && c <= 90) {
      final b = StringBuffer(s.substring(0, i));
      for (var j = i; j < s.length; j++) {
        final d = s.codeUnitAt(j);
        b.writeCharCode(d >= 65 && d <= 90 ? d + 32 : d);
      }
      return b.toString();
    }
  }
  return s;
}

String asciiUpper(String s) {
  final b = StringBuffer();
  for (var j = 0; j < s.length; j++) {
    final d = s.codeUnitAt(j);
    b.writeCharCode(d >= 97 && d <= 122 ? d - 32 : d);
  }
  return b.toString();
}

Collation? collationByName(String name) {
  switch (name.toUpperCase()) {
    case 'BINARY':
      return null;
    case 'NOCASE':
      return nocaseCompare;
    case 'RTRIM':
      return rtrimCompare;
  }
  throw sqlError('no such collation sequence: $name');
}

/// Total order of SQL values (for ORDER BY, min/max, index keys).
int compareValues(Object? a, Object? b, [Collation? coll]) {
  final ra = classRank(a), rb = classRank(b);
  if (ra != rb) return ra < rb ? -1 : 1;
  switch (ra) {
    case 0:
      return 0;
    case 1:
      return compareNum(a as num, b as num);
    case 2:
      return coll == null
          ? compareText(a as String, b as String)
          : coll(a as String, b as String);
    default:
      return compareBytes(a as Uint8List, b as Uint8List);
  }
}

bool valuesEqual(Object? a, Object? b) => compareValues(a, b) == 0;

// ------------------------------------------------------ text <-> numbers

/// Result of parsing a number prefix of a string.
class NumPrefix {
  final num value;

  /// Number of code units consumed (0 when there is no number).
  final int end;

  /// True when the whole string (after trailing spaces) was consumed.
  final bool whole;

  /// True when the text had integer syntax (no '.', no exponent).
  final bool intSyntax;
  const NumPrefix(this.value, this.end, this.whole, this.intSyntax);
}

bool _isSpace(int c) => c == 32 || (c >= 9 && c <= 13);

/// Parses the longest numeric prefix (SQLite's sqlite3AtoF): optional
/// leading spaces, sign, digits, fraction, exponent.
NumPrefix parseNumPrefix(String s) {
  var i = 0;
  final n = s.length;
  while (i < n && _isSpace(s.codeUnitAt(i))) {
    i++;
  }
  final start = i;
  var neg = false;
  if (i < n && (s.codeUnitAt(i) == 43 || s.codeUnitAt(i) == 45)) {
    neg = s.codeUnitAt(i) == 45;
    i++;
  }
  final digStart = i;
  while (i < n && _isDigit(s.codeUnitAt(i))) {
    i++;
  }
  var nDig = i - digStart;
  var intSyntax = true;
  var fracDigits = 0;
  if (i < n && s.codeUnitAt(i) == 46) {
    var j = i + 1;
    while (j < n && _isDigit(s.codeUnitAt(j))) {
      j++;
    }
    fracDigits = j - i - 1;
    if (nDig > 0 || fracDigits > 0) {
      intSyntax = false;
      i = j;
    }
  }
  if (nDig == 0 && fracDigits == 0) {
    return NumPrefix(0, 0, false, true);
  }
  if (i < n && (s.codeUnitAt(i) == 101 || s.codeUnitAt(i) == 69)) {
    var j = i + 1;
    if (j < n && (s.codeUnitAt(j) == 43 || s.codeUnitAt(j) == 45)) j++;
    final es = j;
    while (j < n && _isDigit(s.codeUnitAt(j))) {
      j++;
    }
    if (j > es) {
      intSyntax = false;
      i = j;
    }
  }
  final end = i;
  var k = i;
  while (k < n && _isSpace(s.codeUnitAt(k))) {
    k++;
  }
  final whole = k == n;
  final text = s.substring(start, end);
  if (intSyntax) {
    final v = int.tryParse(text);
    if (v != null) return NumPrefix(v, end, whole, true);
    // Too large for int64: a real.
    return NumPrefix(
        double.parse(text.startsWith('+') ? text.substring(1) : text),
        end,
        whole,
        false);
  }
  var t = text;
  if (t.startsWith('+') || t.startsWith('-')) t = t.substring(1);
  if (t.startsWith('.')) t = '0$t';
  // Dart's double.parse does not accept '5.' or '5.e3'.
  t = t.replaceFirst(RegExp(r'\.(?=[eE]|$)'), '');
  var d = double.parse(t);
  if (neg) d = -d;
  return NumPrefix(d, end, whole, false);
}

bool _isDigit(int c) => c >= 48 && c <= 57;

/// Real that is exactly an integer in the range SQLite converts back to
/// INTEGER for NUMERIC affinity (sqlite3RealSameAsInt: |x| < 2^51).
bool realIsSmallInt(double d) =>
    d == d.truncateToDouble() &&
    d > -2251799813685248.0 &&
    d < 2251799813685248.0;

/// Applies NUMERIC affinity to a text value; returns the text unchanged
/// when it is not a well formed number.
Object? textToNumeric(String s, {bool integer = true}) {
  final p = parseNumPrefix(s);
  if (p.end == 0 || !p.whole) return s;
  final v = p.value;
  if (v is double) {
    if (v.isNaN) return s;
    if (integer && realIsSmallInt(v)) return v.toInt();
  }
  return v;
}

/// Converts [v] for storage in a column of affinity [a] (SQLite 3.x
/// storage rules).
Object? applyAffinity(Object? v, Affinity a) {
  if (v == null) return null;
  switch (a) {
    case Affinity.none:
    case Affinity.blob:
      return v;
    case Affinity.text:
      if (v is num) return numToText(v);
      return v;
    case Affinity.numeric:
    case Affinity.integer:
      if (v is String) return textToNumeric(v);
      if (v is double && realIsSmallInt(v)) return v.toInt();
      return v;
    case Affinity.real:
      if (v is String) {
        final r = textToNumeric(v, integer: false);
        if (r is int) return r.toDouble();
        return r;
      }
      if (v is int) return v.toDouble();
      return v;
  }
}

/// Converts any value to a number in arithmetic context (prefix parse of
/// text, as SQLite does for '3abc' + 1).
num? toNumber(Object? v) {
  if (v == null) return null;
  if (v is num) return v;
  final s = v is String ? v : utf8.decode(v as Uint8List, allowMalformed: true);
  final p = parseNumPrefix(s);
  if (p.end == 0) return 0;
  return p.value;
}

/// Converts to a double (REAL).
double toDouble(Object? v) {
  final n = toNumber(v);
  if (n == null) return 0.0;
  return n.toDouble();
}

/// CAST(x AS INTEGER) semantics for numbers: truncation, saturation.
int doubleToInt(double d) {
  if (d.isNaN) return 0;
  if (d >= _two63) return 0x7FFFFFFFFFFFFFFF;
  if (d <= -_two63) return -0x8000000000000000;
  return d.toInt();
}

/// Integer prefix parse used by CAST(text AS INTEGER).
int textToIntPrefix(String s) {
  var i = 0;
  final n = s.length;
  while (i < n && _isSpace(s.codeUnitAt(i))) {
    i++;
  }
  var neg = false;
  if (i < n && (s.codeUnitAt(i) == 43 || s.codeUnitAt(i) == 45)) {
    neg = s.codeUnitAt(i) == 45;
    i++;
  }
  final st = i;
  while (i < n && _isDigit(s.codeUnitAt(i))) {
    i++;
  }
  if (i == st) return 0;
  final digits = s.substring(st, i);
  final v = int.tryParse(neg ? '-$digits' : digits);
  if (v != null) return v;
  return neg ? -0x8000000000000000 : 0x7FFFFFFFFFFFFFFF;
}

/// Converts to an integer (CAST AS INTEGER).
int toInt(Object? v) {
  if (v == null) return 0;
  if (v is int) return v;
  if (v is double) return doubleToInt(v);
  final s = v is String ? v : utf8.decode(v as Uint8List, allowMalformed: true);
  return textToIntPrefix(s);
}

/// Text form of a value (TEXT conversion; blobs are decoded as UTF-8).
String? toText(Object? v) {
  if (v == null) return null;
  if (v is String) return v;
  if (v is num) return numToText(v);
  return utf8.decode(v as Uint8List, allowMalformed: true);
}

String numToText(num v) => v is int ? v.toString() : realToText(v as double);

/// SQLite's "%!.15g" rendering of a REAL.
String realToText(double d) {
  if (d.isNaN) return 'NaN';
  if (d.isInfinite) return d > 0 ? 'Inf' : '-Inf';
  return formatG(d, 15, bang: true);
}

/// C printf %g with [prec] significant digits. [bang] is SQLite's '!'
/// flag: keep a '.0' on integral values. [alt] keeps trailing zeros.
String formatG(double d, int prec, {bool bang = false, bool alt = false}) {
  if (prec == 0) prec = 1;
  if (d == 0) {
    if (alt) return '0.${'0' * (prec - 1)}';
    return bang ? '0.0' : '0';
  }
  final neg = d < 0;
  final a = neg ? -d : d;
  final e = a.toStringAsExponential(prec - 1); // d.ddde+X
  final ei = e.indexOf('e');
  var mant = e.substring(0, ei).replaceFirst('.', '');
  final exp = int.parse(e.substring(ei + 1));
  String out;
  if (exp < -4 || exp >= prec) {
    var frac = mant.substring(1);
    if (!alt) frac = frac.replaceFirst(RegExp(r'0+$'), '');
    if (frac.isEmpty && bang) frac = '0';
    final es = exp.abs() < 10 ? '0${exp.abs()}' : '${exp.abs()}';
    out = '${mant[0]}${frac.isEmpty ? '' : '.$frac'}e${exp < 0 ? '-' : '+'}$es';
  } else {
    String ip, fp;
    if (exp >= 0) {
      if (mant.length <= exp + 1) mant = mant.padRight(exp + 1, '0');
      ip = mant.substring(0, exp + 1);
      fp = mant.substring(exp + 1);
    } else {
      ip = '0';
      fp = '${'0' * (-exp - 1)}$mant';
    }
    if (!alt) fp = fp.replaceFirst(RegExp(r'0+$'), '');
    if (fp.isEmpty && bang) fp = '0';
    out = fp.isEmpty ? ip : '$ip.$fp';
  }
  return neg ? '-$out' : out;
}

Uint8List toBlob(Object? v) {
  if (v is Uint8List) return v;
  return Uint8List.fromList(utf8.encode(toText(v) ?? ''));
}

/// CAST(v AS type).
Object? castValue(Object? v, String typeName) {
  if (v == null) return null;
  final a = affinityOfType(typeName);
  switch (a) {
    case Affinity.none:
    case Affinity.blob:
      return toBlob(v);
    case Affinity.text:
      return toText(v);
    case Affinity.integer:
      return toInt(v);
    case Affinity.real:
      if (v is num) return v.toDouble();
      final n = toNumber(v);
      return n!.toDouble();
    case Affinity.numeric:
      if (v is num) {
        return v;
      }
      final s = toText(v)!;
      final p = parseNumPrefix(s);
      if (p.end == 0) return 0;
      final n = p.value;
      if (n is double && realIsSmallInt(n)) return n.toInt();
      return n;
  }
}

// ---------------------------------------------------------------- logic

/// SQL truth value: null, true or false (numeric context).
bool? truth(Object? v) {
  if (v == null) return null;
  if (v is int) return v != 0;
  if (v is double) return v != 0.0;
  final n = toNumber(v);
  return n != 0;
}

// ---------------------------------------------------------------- LIKE

/// SQL LIKE (case-insensitive for ASCII, as SQLite's default).
bool likeMatch(String pattern, String text, {int? escape, bool nocase = true}) {
  return _like(pattern, 0, text, 0, escape, nocase);
}

bool _like(String p, int pi, String t, int ti, int? esc, bool nocase) {
  while (pi < p.length) {
    var c = p.codeUnitAt(pi);
    if (esc != null && c == esc) {
      pi++;
      if (pi >= p.length) return false;
      c = p.codeUnitAt(pi);
      if (ti >= t.length || !_likeEq(c, t.codeUnitAt(ti), nocase)) {
        return false;
      }
      pi++;
      ti++;
      continue;
    }
    if (c == 37) {
      // %
      while (pi < p.length && p.codeUnitAt(pi) == 37) {
        pi++;
      }
      if (pi == p.length) return true;
      for (var k = ti; k <= t.length; k++) {
        if (_like(p, pi, t, k, esc, nocase)) return true;
      }
      return false;
    }
    if (ti >= t.length) return false;
    if (c == 95) {
      // _
      pi++;
      ti++;
      continue;
    }
    if (!_likeEq(c, t.codeUnitAt(ti), nocase)) return false;
    pi++;
    ti++;
  }
  return ti == t.length;
}

bool _likeEq(int a, int b, bool nocase) {
  if (a == b) return true;
  if (!nocase) return false;
  if (a >= 65 && a <= 90) a += 32;
  if (b >= 65 && b <= 90) b += 32;
  return a == b;
}

/// SQL GLOB (case sensitive, *, ?, [...]).
bool globMatch(String p, String t) => _glob(p, 0, t, 0);

bool _glob(String p, int pi, String t, int ti) {
  while (pi < p.length) {
    final c = p.codeUnitAt(pi);
    if (c == 42) {
      while (pi < p.length && p.codeUnitAt(pi) == 42) {
        pi++;
      }
      if (pi == p.length) return true;
      for (var k = ti; k <= t.length; k++) {
        if (_glob(p, pi, t, k)) return true;
      }
      return false;
    }
    if (ti >= t.length) return false;
    if (c == 63) {
      pi++;
      ti++;
      continue;
    }
    if (c == 91) {
      // [...]
      var j = pi + 1;
      var invert = false;
      if (j < p.length && p.codeUnitAt(j) == 94) {
        invert = true;
        j++;
      }
      var matched = false;
      final tc = t.codeUnitAt(ti);
      var first = true;
      while (j < p.length && (first || p.codeUnitAt(j) != 93)) {
        first = false;
        var lo = p.codeUnitAt(j);
        var hi = lo;
        if (j + 2 < p.length &&
            p.codeUnitAt(j + 1) == 45 &&
            p.codeUnitAt(j + 2) != 93) {
          hi = p.codeUnitAt(j + 2);
          j += 2;
        }
        if (tc >= lo && tc <= hi) matched = true;
        j++;
      }
      if (j >= p.length) return false; // unterminated
      if (matched == invert) return false;
      pi = j + 1;
      ti++;
      continue;
    }
    if (c != t.codeUnitAt(ti)) return false;
    pi++;
    ti++;
  }
  return ti == t.length;
}

// ---------------------------------------------------------------- misc

String hexOf(Uint8List b) {
  const d = '0123456789ABCDEF';
  final sb = StringBuffer();
  for (final x in b) {
    sb.writeCharCode(d.codeUnitAt(x >> 4));
    sb.writeCharCode(d.codeUnitAt(x & 15));
  }
  return sb.toString();
}

/// SQL literal of a value (quote()).
String quoteValue(Object? v) {
  if (v == null) return 'NULL';
  if (v is int) return v.toString();
  if (v is double) {
    final s = formatG(v, 17, bang: true);
    // Prefer the shortest round trip form.
    final r = realToText(v);
    return double.tryParse(r) == v ? r : s;
  }
  if (v is String) return "'${v.replaceAll("'", "''")}'";
  return "X'${hexOf(v as Uint8List)}'";
}

/// Converts a Dart value from the API (params) to a SQL value.
Object? fromDart(Object? v) {
  if (v == null || v is int || v is double || v is String) return v;
  if (v is Uint8List) return v;
  if (v is bool) return v ? 1 : 0;
  if (v is List<int>) return Uint8List.fromList(v);
  if (v is DateTime) return v.microsecondsSinceEpoch * 1000;
  if (v is List || v is Map) return jsonEncode(v);
  if (v is BigInt) return v.isValidInt ? v.toInt() : v.toDouble();
  if (v is num) return v.toDouble();
  return v.toString();
}
