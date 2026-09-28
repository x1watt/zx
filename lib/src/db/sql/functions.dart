// Function registry (scalar, aggregate) and the built-in functions.
//
// Extension point for other modules: register scalar functions with
// [ZxFunctionRegistry.scalar] and aggregates with
// [ZxFunctionRegistry.aggregate]; table-valued functions are virtual
// tables (see vtab.dart).

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import '../storage_api.dart';
import 'datetime.dart';
import 'json.dart';
import 'value.dart';

/// What a function sees of the running statement.
abstract class ZxFunctionContext {
  /// Statement start time (ns since the Unix epoch, UTC); 'now' in date
  /// functions and CURRENT_TIMESTAMP are this value for the whole
  /// statement.
  int get nowNs;

  /// The snapshot (or write transaction) the statement reads.
  ZxSnapshot get snapshot;

  /// The write transaction when the statement writes, else null.
  ZxWriteTxn? get txn;

  /// True when argument [i] carries the JSON subtype (it comes from a
  /// JSON function or a JSON column), so JSON functions embed it as JSON
  /// instead of as a string.
  bool argIsJson(int i);

  int get lastInsertRowid;
  int get changes;
  int get totalChanges;
}

typedef ZxScalarImpl = Object? Function(
    List<Object?> args, ZxFunctionContext ctx);

class ZxScalarFunction {
  final String name;
  final int minArgs, maxArgs; // maxArgs -1: unlimited
  final ZxScalarImpl impl;

  /// False for random(), changes()...: never constant folded.
  final bool deterministic;

  /// The result has the JSON subtype (json(), json_array()...).
  final bool resultIsJson;
  const ZxScalarFunction(this.name, this.minArgs, this.maxArgs, this.impl,
      {this.deterministic = true, this.resultIsJson = false});
}

/// Per-group state of an aggregate function.
abstract class ZxAggregateState {
  void step(List<Object?> args);
  Object? finish();
}

class ZxAggregateFunction {
  final String name;
  final int minArgs, maxArgs;
  final ZxAggregateState Function() create;
  final bool resultIsJson;
  const ZxAggregateFunction(this.name, this.minArgs, this.maxArgs, this.create,
      {this.resultIsJson = false});
}

class ZxFunctionRegistry {
  final Map<String, List<ZxScalarFunction>> _scalars = {};
  final Map<String, List<ZxAggregateFunction>> _aggs = {};

  ZxFunctionRegistry({bool builtins = true}) {
    if (builtins) registerBuiltins(this);
  }

  void scalar(ZxScalarFunction f) {
    final l = _scalars.putIfAbsent(f.name.toLowerCase(), () => []);
    l.removeWhere((x) => x.minArgs == f.minArgs && x.maxArgs == f.maxArgs);
    l.insert(0, f);
  }

  /// Shorthand for [scalar].
  void addScalar(String name, int nArgs, ZxScalarImpl impl,
          {bool deterministic = true}) =>
      scalar(ZxScalarFunction(name, nArgs < 0 ? 0 : nArgs, nArgs, impl,
          deterministic: deterministic));

  void aggregate(ZxAggregateFunction f) {
    final l = _aggs.putIfAbsent(f.name.toLowerCase(), () => []);
    l.removeWhere((x) => x.minArgs == f.minArgs && x.maxArgs == f.maxArgs);
    l.insert(0, f);
  }

  static bool _fits(int n, int min, int max) =>
      n >= min && (max < 0 || n <= max);

  ZxScalarFunction? findScalar(String name, int nArgs) {
    final l = _scalars[name];
    if (l == null) return null;
    for (final f in l) {
      if (_fits(nArgs, f.minArgs, f.maxArgs)) return f;
    }
    return null;
  }

  ZxAggregateFunction? findAggregate(String name, int nArgs) {
    final l = _aggs[name];
    if (l == null) return null;
    for (final f in l) {
      if (_fits(nArgs, f.minArgs, f.maxArgs)) return f;
    }
    return null;
  }

  bool hasName(String name) =>
      _scalars.containsKey(name) || _aggs.containsKey(name);

  Iterable<String> get scalarNames => _scalars.keys;
  Iterable<String> get aggregateNames => _aggs.keys;
}

// ------------------------------------------------------------ builtins

final _rand = math.Random.secure();

int _randomInt() {
  final hi = _rand.nextInt(1 << 32);
  final lo = _rand.nextInt(1 << 32);
  return (hi << 32) | lo;
}

String? _text(Object? v) => toText(v);

Object? _substr(List<Object?> a) {
  final x = a[0];
  if (x == null || a[1] == null || (a.length > 2 && a[2] == null)) return null;
  var p1 = toInt(a[1]);
  final isBlob = x is Uint8List;
  if (isBlob && x.isEmpty) return null;
  final List<int> units;
  if (isBlob) {
    units = x;
  } else {
    units = _text(x)!.runes.toList();
  }
  final len = units.length;
  int p2;
  var negP2 = false;
  if (a.length > 2) {
    p2 = toInt(a[2]);
    if (p2 < 0) {
      p2 = -p2;
      negP2 = true;
    }
  } else {
    p2 = 0x7FFFFFFF;
  }
  if (p1 < 0) {
    p1 += len;
    if (p1 < 0) {
      p2 += p1;
      if (p2 < 0) p2 = 0;
      p1 = 0;
    }
  } else if (p1 > 0) {
    p1--;
  } else if (p2 > 0) {
    p2--;
  }
  if (negP2) {
    p1 -= p2;
    if (p1 < 0) {
      p2 += p1;
      p1 = 0;
    }
  }
  if (p1 > len) p1 = len;
  var end = p1 + p2;
  if (end > len) end = len;
  if (end < p1) end = p1;
  final part = units.sublist(p1, end);
  if (isBlob) return Uint8List.fromList(part);
  return String.fromCharCodes(part);
}

String _trim(String s, String chars, bool left, bool right) {
  final set = chars.runes.toSet();
  final r = s.runes.toList();
  var a = 0, b = r.length;
  if (left) {
    while (a < b && set.contains(r[a])) {
      a++;
    }
  }
  if (right) {
    while (b > a && set.contains(r[b - 1])) {
      b--;
    }
  }
  return String.fromCharCodes(r.sublist(a, b));
}

Object? _round(List<Object?> a) {
  if (a[0] == null) return null;
  var n = 0;
  if (a.length > 1) {
    if (a[1] == null) return null;
    n = toInt(a[1]);
    if (n > 30) n = 30;
    if (n < 0) n = 0;
  }
  final x = toDouble(a[0]);
  if (x.isNaN || x.isInfinite) return x;
  if (x.abs() >= 4503599627370496.0) return x; // already integral
  if (n == 0) {
    final r = x < 0 ? -((-x) + 0.5).floorToDouble() : (x + 0.5).floorToDouble();
    return r;
  }
  // SQLite formats with %.*f and parses back.
  if (n > 17) return x;
  final s = x.toStringAsFixed(n);
  return double.parse(s);
}

Object? _abs(Object? v) {
  if (v == null) return null;
  if (v is int) {
    if (v == -0x8000000000000000) {
      throw const ZxDbException('integer overflow');
    }
    return v.abs();
  }
  if (v is double) return v.abs();
  final n = toNumber(v)!;
  return n is int ? n.abs().toDouble() : n.abs();
}

Object? _instr(Object? h, Object? n) {
  if (h == null || n == null) return null;
  if (h is Uint8List && n is Uint8List) {
    if (n.isEmpty) return 1;
    outer:
    for (var i = 0; i + n.length <= h.length; i++) {
      for (var j = 0; j < n.length; j++) {
        if (h[i + j] != n[j]) continue outer;
      }
      return i + 1;
    }
    return 0;
  }
  final hs = _text(h)!, ns = _text(n)!;
  final i = hs.indexOf(ns);
  if (i < 0) return 0;
  return hs.substring(0, i).runes.length + 1;
}

Object? _length(Object? v) {
  if (v == null) return null;
  if (v is Uint8List) return v.length;
  if (v is String) {
    // characters up to the first NUL, a surrogate pair counting once (one
    // pass over the code units; String.runes was 0.4 us a row)
    final n = v.length;
    var count = 0;
    for (var i = 0; i < n; i++) {
      final c = v.codeUnitAt(i);
      if (c == 0) break;
      if (c >= 0xD800 &&
          c <= 0xDBFF &&
          i + 1 < n &&
          (v.codeUnitAt(i + 1) & 0xFC00) == 0xDC00) {
        i++;
      }
      count++;
    }
    return count;
  }
  return _text(v)!.length;
}

Object? _hex(Object? v) {
  if (v == null) return '';
  return hexOf(toBlob(v));
}

Object? _unhex(List<Object?> a) {
  if (a[0] == null) return null;
  final s = _text(a[0])!;
  final ignore = a.length > 1 ? (_text(a[1]) ?? '') : '';
  final out = <int>[];
  int? hi;
  for (final c in s.runes) {
    final ch = String.fromCharCode(c);
    final d = int.tryParse(ch, radix: 16);
    if (d == null) {
      if (hi == null && ignore.contains(ch)) continue;
      return null;
    }
    if (hi == null) {
      hi = d;
    } else {
      out.add(hi * 16 + d);
      hi = null;
    }
  }
  if (hi != null) return null;
  return Uint8List.fromList(out);
}

Object? _replace(Object? s, Object? f, Object? r) {
  if (s == null || f == null) return null;
  final fs = _text(f)!;
  if (fs.isEmpty || fs.codeUnitAt(0) == 0) return s is Uint8List ? _text(s) : s;
  if (r == null) return null;
  return _text(s)!.replaceAll(fs, _text(r)!);
}

Object? _minMaxScalar(List<Object?> a, bool isMax) {
  // SQLite: on ties min() keeps the later argument, max() the earlier.
  Object? best;
  for (var i = 0; i < a.length; i++) {
    final v = a[i];
    if (v == null) return null;
    if (i == 0) {
      best = v;
    } else {
      final c = compareValues(v, best);
      if (isMax ? c > 0 : c <= 0) best = v;
    }
  }
  return best;
}

Object? _char(List<Object?> a) {
  final b = StringBuffer();
  for (final v in a) {
    final c = toInt(v);
    b.writeCharCode(c < 0 || c > 0x10FFFF ? 0xFFFD : c);
  }
  return b.toString();
}

Object? _unicode(Object? v) {
  if (v == null) return null;
  final s = _text(v)!;
  if (s.isEmpty || s.codeUnitAt(0) == 0) return null;
  return s.runes.first;
}

Object? _sign(Object? v) {
  if (v == null) return null;
  num? n;
  if (v is num) {
    n = v;
  } else if (v is String) {
    final p = parseNumPrefix(v);
    if (p.end == 0 || !p.whole) return null;
    n = p.value;
  } else {
    return null;
  }
  return n > 0 ? 1 : (n < 0 ? -1 : 0);
}

double? _mathArg(Object? v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  if (v is String) {
    final p = parseNumPrefix(v);
    if (p.end == 0 || !p.whole) return null;
    return p.value.toDouble();
  }
  return null;
}

Object? _math1(Object? v, double Function(double) f) {
  final x = _mathArg(v);
  if (x == null) return null;
  final r = f(x);
  if (r.isNaN) return null;
  return r;
}

Object? _ceilFloor(Object? v, bool ceil) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is String) {
    final p = parseNumPrefix(v);
    if (p.end == 0 || !p.whole) return null;
    if (p.value is int) return p.value;
  }
  final x = _mathArg(v);
  if (x == null) return null;
  return ceil ? x.ceilToDouble() : x.floorToDouble();
}

// printf ----------------------------------------------------------------

String sqlPrintf(String fmt, List<Object?> args) {
  final b = StringBuffer();
  var ai = 0;
  Object? next() => ai < args.length ? args[ai++] : null;
  var i = 0;
  while (i < fmt.length) {
    final c = fmt[i];
    if (c != '%') {
      b.write(c);
      i++;
      continue;
    }
    i++;
    if (i >= fmt.length) break;
    var minus = false, plus = false, space = false, zero = false;
    var alt = false, comma = false, bang = false;
    while (i < fmt.length) {
      final f = fmt[i];
      if (f == '-') {
        minus = true;
      } else if (f == '+') {
        plus = true;
      } else if (f == ' ') {
        space = true;
      } else if (f == '0') {
        zero = true;
      } else if (f == '#') {
        alt = true;
      } else if (f == ',') {
        comma = true;
      } else if (f == '!') {
        bang = true;
      } else {
        break;
      }
      i++;
    }
    var width = 0;
    if (i < fmt.length && fmt[i] == '*') {
      width = toInt(next());
      if (width < 0) {
        minus = true;
        width = -width;
      }
      i++;
    } else {
      while (i < fmt.length && fmt.codeUnitAt(i) >= 48 && fmt.codeUnitAt(i) <= 57) {
        width = width * 10 + fmt.codeUnitAt(i) - 48;
        i++;
      }
    }
    int? prec;
    if (i < fmt.length && fmt[i] == '.') {
      i++;
      if (i < fmt.length && fmt[i] == '*') {
        prec = toInt(next());
        if (prec < 0) prec = null;
        i++;
      } else {
        prec = 0;
        while (i < fmt.length &&
            fmt.codeUnitAt(i) >= 48 &&
            fmt.codeUnitAt(i) <= 57) {
          prec = prec! * 10 + fmt.codeUnitAt(i) - 48;
          i++;
        }
      }
    }
    // Length modifiers are accepted and ignored.
    while (i < fmt.length && (fmt[i] == 'l' || fmt[i] == 'h')) {
      i++;
    }
    if (i >= fmt.length) break;
    final conv = fmt[i++];
    String body;
    var numeric = false;
    var negative = false;
    switch (conv) {
      case '%':
        b.write('%');
        continue;
      case 'd':
      case 'i':
      case 'u':
        numeric = true;
        final v = next();
        var n = v == null ? 0 : (v is double ? doubleToInt(v) : toInt(v));
        if (v is String) {
          final p = toNumber(v)!;
          n = p is int ? p : doubleToInt(p.toDouble());
        }
        if (conv == 'u' && n < 0) n = -n;
        negative = n < 0;
        body = (negative ? -n : n).toString();
        if (n == -0x8000000000000000) body = body.replaceFirst('-', '');
        if (prec != null && body.length < prec) body = body.padLeft(prec, '0');
        if (comma) {
          final sb = StringBuffer();
          for (var k = 0; k < body.length; k++) {
            if (k > 0 && (body.length - k) % 3 == 0) sb.write(',');
            sb.write(body[k]);
          }
          body = sb.toString();
        }
      case 'x':
      case 'X':
      case 'o':
        numeric = true;
        final n = toInt(next());
        final big = BigInt.from(n).toUnsigned(64);
        body = big.toRadixString(conv == 'o' ? 8 : 16);
        if (conv == 'X') body = body.toUpperCase();
        if (prec != null && body.length < prec) body = body.padLeft(prec, '0');
        if (alt && n != 0) body = (conv == 'o' ? '0' : (conv == 'x' ? '0x' : '0X')) + body;
      case 'f':
      case 'F':
      case 'e':
      case 'E':
      case 'g':
      case 'G':
        numeric = true;
        final v = next();
        var x = v == null ? 0.0 : toDouble(v);
        final p = prec ?? 6;
        negative = x < 0;
        if (negative) x = -x;
        if (x == 0) x = 0.0; // no '-0'
        if (x.isInfinite) {
          body = 'Inf';
        } else if (x.isNaN) {
          body = 'NaN';
        } else if (conv == 'f' || conv == 'F') {
          body = _fixed(x, p > 350 ? 350 : p);
          if (alt && p == 0) body = '$body.';
          if (comma) {
            final dot = body.indexOf('.');
            final ip = dot < 0 ? body : body.substring(0, dot);
            final sb = StringBuffer();
            for (var k = 0; k < ip.length; k++) {
              if (k > 0 && (ip.length - k) % 3 == 0) sb.write(',');
              sb.write(ip[k]);
            }
            body = sb.toString() + (dot < 0 ? '' : body.substring(dot));
          }
        } else if (conv == 'e' || conv == 'E') {
          body = p > 15
              ? _padExp(x.toStringAsExponential(15), p)
              : x.toStringAsExponential(p);
          final ei = body.indexOf('e');
          var exp = body.substring(ei + 1);
          final sgn = exp.startsWith('-') ? '-' : '+';
          exp = exp.replaceFirst(RegExp(r'^[+-]'), '');
          if (exp.length < 2) exp = '0$exp';
          body = '${body.substring(0, ei)}e$sgn$exp';
          if (conv == 'E') body = body.toUpperCase();
        } else {
          body = formatG(x, p == 0 ? 1 : (p > 16 ? 16 : p), bang: bang, alt: alt);
          if (conv == 'G') body = body.toUpperCase();
        }
      case 's':
      case 'z':
        final v = next();
        body = v == null ? '' : (_text(v) ?? '');
        if (prec != null && body.length > prec) body = body.substring(0, prec);
      case 'q':
      case 'Q':
      case 'w':
        final v = next();
        if (v == null) {
          body = conv == 'Q' ? 'NULL' : '(NULL)';
        } else {
          final s = _text(v)!;
          if (conv == 'w') {
            body = s.replaceAll('"', '""');
          } else {
            body = s.replaceAll("'", "''");
            if (conv == 'Q') body = "'$body'";
          }
        }
        if (conv == 'q' && prec != null && body.length > prec) {
          body = body.substring(0, prec);
        }
      case 'c':
        final v = next();
        final s = v == null ? '' : (_text(v) ?? '');
        body = s.isEmpty ? '' : String.fromCharCode(s.runes.first);
        if (prec != null && prec > 1) body = body * prec;
      default:
        return b.toString();
    }
    var sign = '';
    if (numeric) {
      if (negative) {
        sign = '-';
      } else if (plus && conv != 'x' && conv != 'X' && conv != 'o') {
        sign = '+';
      } else if (space && conv != 'x' && conv != 'X' && conv != 'o') {
        sign = ' ';
      }
    }
    final total = sign.length + body.length;
    if (total >= width) {
      b.write(sign);
      b.write(body);
    } else if (minus) {
      b.write(sign);
      b.write(body);
      b.write(' ' * (width - total));
    } else if (zero && numeric) {
      b.write(sign);
      b.write('0' * (width - total));
      b.write(body);
    } else {
      b.write(' ' * (width - total));
      b.write(sign);
      b.write(body);
    }
  }
  return b.toString();
}

/// %.<p>f as SQLite prints it: at most 16 significant digits (the rest
/// are zeros), and precision 0 truncates.
String _fixed(double x, int p) {
  if (p == 0) x = x.truncateToDouble();
  final e = x.toStringAsExponential(15);
  final ei = e.indexOf('e');
  final digits = e.substring(0, ei).replaceFirst('.', '');
  final exp = int.parse(e.substring(ei + 1));
  if (x < 1e21 && exp + 1 + p <= 16) return x.toStringAsFixed(p);
  if (x == 0) return p == 0 ? '0' : '0.${'0' * p}';
  final all = StringBuffer();
  String ip, fp;
  if (exp >= 0) {
    final need = exp + 1 + p;
    final d = digits.padRight(need, '0').substring(0, need);
    ip = d.substring(0, exp + 1);
    fp = d.substring(exp + 1);
  } else {
    ip = '0';
    fp = ('0' * (-exp - 1) + digits).padRight(p, '0').substring(0, p);
  }
  all.write(ip);
  if (p > 0) all.write('.$fp');
  return all.toString();
}

String _padExp(String e, int p) {
  final ei = e.indexOf('e');
  return '${e.substring(0, ei).padRight(p + 2, '0')}${e.substring(ei)}';
}

// aggregates -----------------------------------------------------------

class _Count extends ZxAggregateState {
  int n = 0;
  final bool star;
  _Count(this.star);
  @override
  void step(List<Object?> a) {
    if (star || a[0] != null) n++;
  }

  @override
  Object? finish() => n;
}

class _Sum extends ZxAggregateState {
  final int mode; // 0 sum, 1 total, 2 avg
  _Sum(this.mode);
  int isum = 0;
  double rsum = 0;
  double comp = 0; // Kahan-Babushka-Neumaier compensation
  bool approx = false, overflow = false;
  int cnt = 0;

  void _addReal(double x) {
    final t = rsum + x;
    if (rsum.abs() >= x.abs()) {
      comp += (rsum - t) + x;
    } else {
      comp += (x - t) + rsum;
    }
    rsum = t;
  }

  @override
  void step(List<Object?> a) {
    final v = a[0];
    if (v == null) return;
    cnt++;
    if (v is int && !approx) {
      final r = isum + v;
      if ((isum >= 0) == (v >= 0) && (r >= 0) != (isum >= 0)) {
        overflow = true;
        approx = true;
        _addReal(isum.toDouble());
        _addReal(v.toDouble());
        return;
      }
      isum = r;
      return;
    }
    if (!approx) {
      approx = true;
      _addReal(isum.toDouble());
    }
    if (v is int) {
      _addReal(v.toDouble());
    } else if (v is double) {
      _addReal(v);
    } else {
      final n = toNumber(v)!;
      _addReal(n.toDouble());
    }
  }

  @override
  Object? finish() {
    switch (mode) {
      case 0:
        if (cnt == 0) return null;
        if (overflow) throw const ZxDbException('integer overflow');
        return approx ? rsum + comp : isum;
      case 1:
        return approx ? rsum + comp : isum.toDouble();
      default:
        if (cnt == 0) return null;
        final s = approx ? rsum + comp : isum.toDouble();
        return s / cnt;
    }
  }
}

class _MinMax extends ZxAggregateState {
  final bool isMax;
  Object? best;
  bool any = false;

  /// Set by the executor for columns with a collation.
  Collation? coll;
  _MinMax(this.isMax);

  /// True when the last step changed the result (bare column rule).
  bool changed = false;
  @override
  void step(List<Object?> a) {
    changed = false;
    final v = a[0];
    if (v == null) return;
    if (!any) {
      best = v;
      any = true;
      changed = true;
      return;
    }
    final c = compareValues(v, best, coll);
    if (isMax ? c > 0 : c < 0) {
      best = v;
      changed = true;
    }
  }

  @override
  Object? finish() => best;
}

/// min/max aggregate state (exported for the executor's bare column rule).
typedef MinMaxState = _MinMax;

bool isMinMaxState(ZxAggregateState s) => s is _MinMax;
bool minMaxChanged(ZxAggregateState s) => (s as _MinMax).changed;
void setMinMaxCollation(ZxAggregateState s, Collation? c) =>
    (s as _MinMax).coll = c;

class _GroupConcat extends ZxAggregateState {
  final StringBuffer b = StringBuffer();
  bool any = false;
  @override
  void step(List<Object?> a) {
    final v = a[0];
    if (v == null) return;
    if (any) {
      final sep = a.length > 1 ? (a[1] == null ? '' : toText(a[1])!) : ',';
      b.write(sep);
    }
    any = true;
    b.write(toText(v));
  }

  @override
  Object? finish() => any ? b.toString() : null;
}

class _JsonGroupArray extends ZxAggregateState {
  final List<Object?> items = [];
  final bool Function() isJson;
  _JsonGroupArray(this.isJson);
  @override
  void step(List<Object?> a) => items.add(sqlToJson(a[0], isJson()));
  @override
  Object? finish() => renderJson(items);
}

class _JsonGroupObject extends ZxAggregateState {
  final Map<String, Object?> m = {};
  final bool Function() isJson;
  _JsonGroupObject(this.isJson);
  @override
  void step(List<Object?> a) {
    if (a[0] == null) return;
    m[toText(a[0])!] = sqlToJson(a[1], isJson());
  }

  @override
  Object? finish() => renderJson(m);
}

/// Aggregates whose argument JSON subtype matters get it through this
/// hook, set by the executor per aggregate call.
class JsonArgFlag {
  bool value = false;
}

// ------------------------------------------------------------ json fns

Object? _jsonDoc(Object? v, ZxFunctionContext c, int i) {
  if (v == null) return missing;
  return docArg(v);
}

Object? _jsonExtract(List<Object?> a, ZxFunctionContext c) {
  final doc = _jsonDoc(a[0], c, 0);
  if (identical(doc, missing)) return null;
  if (a.length == 2) {
    if (a[1] == null) return null;
    final v = lookupPath(doc, parsePath(toText(a[1])!));
    if (identical(v, missing)) return null;
    return jsonToSql(v);
  }
  final out = <Object?>[];
  for (var i = 1; i < a.length; i++) {
    if (a[i] == null) return null;
    final v = lookupPath(doc, parsePath(toText(a[i])!));
    out.add(identical(v, missing) ? null : v);
  }
  return renderJson(out);
}

Object? _jsonEdit(List<Object?> a, ZxFunctionContext c, int mode) {
  if (a.length.isEven) {
    throw const ZxDbException(
        'json_insert/json_replace/json_set need an odd number of arguments');
  }
  if (a[0] == null) return null;
  var doc = jsonCopy(docArg(a[0]));
  for (var i = 1; i < a.length; i += 2) {
    if (a[i] == null) return null;
    final steps = parsePath(toText(a[i])!);
    final v = sqlToJson(a[i + 1], c.argIsJson(i + 1));
    doc = editPath(doc, steps, v, mode);
  }
  return renderJson(doc);
}

Object? jsonArrow(Object? l, Object? r, bool text) {
  if (l == null || r == null) return null;
  Object? doc;
  try {
    doc = docArg(l);
  } on ZxDbException {
    if (text) return null;
    rethrow;
  }
  final v = lookupPath(doc, arrowPath(r));
  if (identical(v, missing)) return null;
  return text ? jsonToSql(v) : renderJson(v);
}

void registerBuiltins(ZxFunctionRegistry r) {
  void s(String name, int min, int max, ZxScalarImpl f,
      {bool det = true, bool json = false}) {
    r.scalar(ZxScalarFunction(name, min, max, f,
        deterministic: det, resultIsJson: json));
  }

  s('length', 1, 1, (a, c) => _length(a[0]));
  s('octet_length', 1, 1, (a, c) {
    if (a[0] == null) return null;
    return toBlob(a[0]).length;
  });
  s('lower', 1, 1, (a, c) => a[0] == null ? null : asciiLower(_text(a[0])!));
  s('upper', 1, 1, (a, c) => a[0] == null ? null : asciiUpper(_text(a[0])!));
  s('substr', 2, 3, (a, c) => _substr(a));
  s('substring', 2, 3, (a, c) => _substr(a));
  s('instr', 2, 2, (a, c) => _instr(a[0], a[1]));
  s('replace', 3, 3, (a, c) => _replace(a[0], a[1], a[2]));
  for (final (name, l, rt) in [
    ('trim', true, true),
    ('ltrim', true, false),
    ('rtrim', false, true)
  ]) {
    s(name, 1, 2, (a, c) {
      if (a[0] == null) return null;
      if (a.length > 1 && a[1] == null) return null;
      return _trim(_text(a[0])!, a.length > 1 ? _text(a[1])! : ' ', l, rt);
    });
  }
  s('abs', 1, 1, (a, c) => _abs(a[0]));
  s('round', 1, 2, (a, c) => _round(a));
  s('coalesce', 2, -1, (a, c) {
    for (final v in a) {
      if (v != null) return v;
    }
    return null;
  });
  s('ifnull', 2, 2, (a, c) => a[0] ?? a[1]);
  s('nullif', 2, 2, (a, c) => compareValues(a[0], a[1]) == 0 && a[0] != null ? null : a[0]);
  s('iif', 3, 3, (a, c) => truth(a[0]) == true ? a[1] : a[2]);
  s('typeof', 1, 1, (a, c) => typeName(a[0]));
  s('hex', 1, 1, (a, c) => _hex(a[0]));
  s('unhex', 1, 2, (a, c) => _unhex(a));
  s('quote', 1, 1, (a, c) => quoteValue(a[0]));
  // SQLite returns NULL for an empty result.
  Object? pf(List<Object?> a) {
    if (a[0] == null) return null;
    final r = sqlPrintf(_text(a[0])!, a.sublist(1));
    return r.isEmpty ? null : r;
  }

  s('printf', 1, -1, (a, c) => pf(a));
  s('format', 1, -1, (a, c) => pf(a));
  s('random', 0, 0, (a, c) => _randomInt(), det: false);
  s('randomblob', 1, 1, (a, c) {
    var n = toInt(a[0]);
    if (n < 1) n = 1;
    final b = Uint8List(n);
    for (var i = 0; i < n; i++) {
      b[i] = _rand.nextInt(256);
    }
    return b;
  }, det: false);
  s('zeroblob', 1, 1, (a, c) {
    final n = toInt(a[0]);
    return Uint8List(n < 0 ? 0 : n);
  });
  s('char', 0, -1, (a, c) => _char(a));
  s('unicode', 1, 1, (a, c) => _unicode(a[0]));
  s('sign', 1, 1, (a, c) => _sign(a[0]));
  s('max', 2, -1, (a, c) => _minMaxScalar(a, true));
  s('min', 2, -1, (a, c) => _minMaxScalar(a, false));
  s('like', 2, 3, (a, c) {
    if (a[0] is Uint8List || a[1] is Uint8List) return 0;
    if (a[0] == null || a[1] == null) return null;
    int? esc;
    if (a.length > 2) {
      if (a[2] == null) return null;
      final e = _text(a[2])!;
      if (e.runes.length != 1) {
        throw const ZxDbException(
            'ESCAPE expression must be a single character');
      }
      esc = e.codeUnitAt(0);
    }
    return likeMatch(_text(a[0])!, _text(a[1])!, escape: esc) ? 1 : 0;
  });
  s('glob', 2, 2, (a, c) {
    if (a[0] is Uint8List || a[1] is Uint8List) return 0;
    if (a[0] == null || a[1] == null) return null;
    return globMatch(_text(a[0])!, _text(a[1])!) ? 1 : 0;
  });
  s('likely', 1, 1, (a, c) => a[0]);
  s('unlikely', 1, 1, (a, c) => a[0]);
  s('likelihood', 2, 2, (a, c) => a[0]);
  s('concat', 1, -1, (a, c) {
    final b = StringBuffer();
    for (final v in a) {
      if (v != null) b.write(_text(v));
    }
    return b.toString();
  });
  s('concat_ws', 2, -1, (a, c) {
    if (a[0] == null) return null;
    final sep = _text(a[0])!;
    return a.sublist(1).where((v) => v != null).map(_text).join(sep);
  });
  s('last_insert_rowid', 0, 0, (a, c) => c.lastInsertRowid, det: false);
  s('changes', 0, 0, (a, c) => c.changes, det: false);
  s('total_changes', 0, 0, (a, c) => c.totalChanges, det: false);
  s('sqlite_version', 0, 0, (a, c) => '3.45.1');
  s('zx_version', 0, 0, (a, c) => 'zxdb 1');

  // math
  s('ceil', 1, 1, (a, c) => _ceilFloor(a[0], true));
  s('ceiling', 1, 1, (a, c) => _ceilFloor(a[0], true));
  s('floor', 1, 1, (a, c) => _ceilFloor(a[0], false));
  s('trunc', 1, 1, (a, c) {
    if (a[0] is int) return a[0];
    return _math1(a[0], (x) => x.truncateToDouble());
  });
  s('sqrt', 1, 1, (a, c) => _math1(a[0], math.sqrt));
  s('exp', 1, 1, (a, c) => _math1(a[0], math.exp));
  s('ln', 1, 1, (a, c) => _math1(a[0], (x) => x > 0 ? math.log(x) : double.nan));
  s('log10', 1, 1, (a, c) => _math1(a[0], (x) => x > 0 ? math.log(x) / math.ln10 : double.nan));
  s('log2', 1, 1, (a, c) => _math1(a[0], (x) => x > 0 ? math.log(x) / math.ln2 : double.nan));
  s('log', 1, 1, (a, c) => _math1(a[0], (x) => x > 0 ? math.log(x) / math.ln10 : double.nan));
  s('log', 2, 2, (a, c) {
    final b = _mathArg(a[0]), x = _mathArg(a[1]);
    if (b == null || x == null || b <= 0 || b == 1 || x <= 0) return null;
    return math.log(x) / math.log(b);
  });
  s('pow', 2, 2, (a, c) {
    final x = _mathArg(a[0]), y = _mathArg(a[1]);
    if (x == null || y == null) return null;
    final r = math.pow(x, y).toDouble();
    return r.isNaN ? null : r;
  });
  s('power', 2, 2, (a, c) {
    final x = _mathArg(a[0]), y = _mathArg(a[1]);
    if (x == null || y == null) return null;
    final r = math.pow(x, y).toDouble();
    return r.isNaN ? null : r;
  });
  s('mod', 2, 2, (a, c) {
    final x = _mathArg(a[0]), y = _mathArg(a[1]);
    if (x == null || y == null || y == 0) return null;
    return x.remainder(y);
  });
  s('pi', 0, 0, (a, c) => math.pi);
  for (final (n, f) in <(String, double Function(double))>[
    ('sin', math.sin), ('cos', math.cos), ('tan', math.tan),
    ('asin', math.asin), ('acos', math.acos), ('atan', math.atan),
    ('sinh', (x) => (math.exp(x) - math.exp(-x)) / 2),
    ('cosh', (x) => (math.exp(x) + math.exp(-x)) / 2),
    ('tanh', (x) {
      final e = math.exp(2 * x);
      return (e - 1) / (e + 1);
    }),
    ('degrees', (x) => x * 180 / math.pi),
    ('radians', (x) => x * math.pi / 180),
  ]) {
    s(n, 1, 1, (a, c) => _math1(a[0], f));
  }
  s('atan2', 2, 2, (a, c) {
    final y = _mathArg(a[0]), x = _mathArg(a[1]);
    if (x == null || y == null) return null;
    return math.atan2(y, x);
  });

  // date and time
  int nowMs(ZxFunctionContext c) => nowJulianMs(c.nowNs);
  s('date', 0, -1, (a, c) => sqlDate(a, nowMs(c)), det: false);
  s('time', 0, -1, (a, c) => sqlTime(a, nowMs(c)), det: false);
  s('datetime', 0, -1, (a, c) => sqlDatetime(a, nowMs(c)), det: false);
  s('julianday', 0, -1, (a, c) => sqlJulianday(a, nowMs(c)), det: false);
  s('unixepoch', 0, -1, (a, c) => sqlUnixepoch(a, nowMs(c)), det: false);
  s('strftime', 1, -1, (a, c) => sqlStrftime(a, nowMs(c)), det: false);
  // zx: DATETIME values are ns since the epoch.
  s('zx_datetime', 1, 1, (a, c) {
    if (a[0] == null) return null;
    final ns = toInt(a[0]);
    final ms = ns ~/ 1000000;
    final d = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
    String two(int x) => x.toString().padLeft(2, '0');
    final frac = (ns % 1000000000).toString().padLeft(9, '0');
    return '${d.year.toString().padLeft(4, '0')}-${two(d.month)}-${two(d.day)} '
        '${two(d.hour)}:${two(d.minute)}:${two(d.second)}.$frac';
  });
  s('zx_ns', 1, -1, (a, c) {
    if (a[0] is int && a.length == 1) return a[0];
    if (a.length == 1 && a[0] is String) {
      final v = parseDateTimeToNs(a[0] as String);
      if (v != null) return v;
    }
    final t = sqlJulianday(a, nowMs(c));
    if (t == null) return null;
    return (((t as double) * 86400000.0).round() - 210866760000000) * 1000000;
  }, det: false);

  // json
  s('json', 1, 1, (a, c) {
    if (a[0] == null) return null;
    return renderJson(docArg(a[0]));
  }, json: true);
  s('json_valid', 1, 2, (a, c) {
    if (a[0] == null) return null;
    if (a[0] is num) return 1;
    if (a[0] is Uint8List) return 0;
    return isValidJson(toText(a[0])!) ? 1 : 0;
  });
  s('json_extract', 2, -1, _jsonExtract);
  s('json_type', 1, 2, (a, c) {
    if (a[0] == null) return null;
    var v = docArg(a[0]);
    if (a.length > 1) {
      if (a[1] == null) return null;
      v = lookupPath(v, parsePath(toText(a[1])!));
      if (identical(v, missing)) return null;
    }
    return jsonTypeName(v);
  });
  s('json_array_length', 1, 2, (a, c) {
    if (a[0] == null) return null;
    var v = docArg(a[0]);
    if (a.length > 1) {
      if (a[1] == null) return null;
      v = lookupPath(v, parsePath(toText(a[1])!));
      if (identical(v, missing)) return null;
    }
    return v is List ? v.length : 0;
  });
  s('json_array', 0, -1, (a, c) {
    return renderJson([
      for (var i = 0; i < a.length; i++) sqlToJson(a[i], c.argIsJson(i))
    ]);
  }, json: true);
  s('json_object', 0, -1, (a, c) {
    if (a.length.isOdd) {
      throw const ZxDbException(
          'json_object() requires an even number of arguments');
    }
    final m = <String, Object?>{};
    for (var i = 0; i < a.length; i += 2) {
      final k = a[i];
      if (k is! String) {
        throw const ZxDbException('json_object() labels must be TEXT');
      }
      m[k] = sqlToJson(a[i + 1], c.argIsJson(i + 1));
    }
    return renderJson(m);
  }, json: true);
  s('json_quote', 1, 1, (a, c) => renderJson(sqlToJson(a[0], c.argIsJson(0))),
      json: true);
  s('json_set', 1, -1, (a, c) => _jsonEdit(a, c, 0), json: true);
  s('json_insert', 1, -1, (a, c) => _jsonEdit(a, c, 1), json: true);
  s('json_replace', 1, -1, (a, c) => _jsonEdit(a, c, 2), json: true);
  s('json_remove', 1, -1, (a, c) {
    if (a[0] == null) return null;
    Object? doc = jsonCopy(docArg(a[0]));
    for (var i = 1; i < a.length; i++) {
      if (a[i] == null) return null;
      doc = removePath(doc, parsePath(toText(a[i])!));
      if (identical(doc, missing)) return null;
    }
    return renderJson(doc);
  }, json: true);
  s('json_patch', 2, 2, (a, c) {
    if (a[0] == null || a[1] == null) return null;
    return renderJson(mergePatch(jsonCopy(docArg(a[0])), docArg(a[1])));
  }, json: true);
  s('json_pretty', 1, 2, (a, c) {
    if (a[0] == null) return null;
    final ind = a.length > 1 && a[1] != null ? toText(a[1])! : '    ';
    return JsonEncoder.withIndent(ind).convert(docArg(a[0]));
  });

  // aggregates
  void ag(String name, int min, int max, ZxAggregateState Function() f,
      {bool json = false}) {
    r.aggregate(ZxAggregateFunction(name, min, max, f, resultIsJson: json));
  }

  ag('count', 0, 1, () => _Count(false));
  ag('sum', 1, 1, () => _Sum(0));
  ag('total', 1, 1, () => _Sum(1));
  ag('avg', 1, 1, () => _Sum(2));
  ag('min', 1, 1, () => _MinMax(false));
  ag('max', 1, 1, () => _MinMax(true));
  ag('group_concat', 1, 2, () => _GroupConcat());
  ag('string_agg', 2, 2, () => _GroupConcat());
}

/// count(*) state.
ZxAggregateState countStar() => _Count(true);

/// JSON aggregates need the argument subtype; created by the executor.
ZxAggregateState jsonGroupArray(bool Function() isJson) =>
    _JsonGroupArray(isJson);
ZxAggregateState jsonGroupObject(bool Function() isJson) =>
    _JsonGroupObject(isJson);
