// Date and time functions (SQLite date.c semantics): date(), time(),
// datetime(), julianday(), unixepoch(), strftime(), timediff() is not
// provided.
//
// Times are held as milliseconds since the Julian epoch (iJD, like
// SQLite), in UTC.

import 'value.dart';

class _DT {
  int iJD = 0; // ms since julian epoch
  int y = 2000, m = 1, d = 1;
  int h = 0, mi = 0;
  double s = 0;
  int tz = 0; // minutes
  bool validJD = false, validYMD = false, validHMS = false, validTZ = false;
  bool rawS = false; // raw number not yet interpreted
  double rawValue = 0;
  bool isError = false;
  bool useSubsec = false;

  void computeJD() {
    if (validJD) return;
    int yy, mm, dd;
    if (validYMD) {
      yy = y;
      mm = m;
      dd = d;
    } else {
      yy = 2000;
      mm = 1;
      dd = 1;
    }
    if (yy < -4713 || yy > 9999 || rawS) {
      isError = true;
      return;
    }
    if (mm <= 2) {
      yy--;
      mm += 12;
    }
    final a = (yy + 4800) ~/ 100;
    final b = 38 - a + (a ~/ 4);
    final x1 = (36525 * (yy + 4716)) ~/ 100;
    final x2 = (306001 * (mm + 1)) ~/ 10000;
    iJD = ((x1 + x2 + dd + b - 1524.5) * 86400000).round();
    validJD = true;
    if (validHMS) {
      iJD += h * 3600000 + mi * 60000 + (s * 1000).round();
      if (validTZ) {
        iJD -= tz * 60000;
        validYMD = false;
        validHMS = false;
        validTZ = false;
      }
    }
  }

  void computeYMD() {
    if (validYMD) return;
    if (!validJD) {
      y = 2000;
      m = 1;
      d = 1;
    } else if (!_validJulian(iJD)) {
      isError = true;
      return;
    } else {
      final z = (iJD + 43200000) ~/ 86400000;
      var alpha = ((z + 32044.75) / 36524.25).floor() - 52;
      final a = z + 1 + alpha - ((alpha + 100) ~/ 4) + 25;
      final b = a + 1524;
      final c = ((b - 122.1) / 365.25).floor();
      final dd = (36525 * (c & 32767)) ~/ 100;
      final e = ((b - dd) / 30.6001).floor();
      final x1 = (30.6001 * e).floor();
      d = b - dd - x1;
      m = e < 14 ? e - 1 : e - 13;
      y = m > 2 ? c - 4716 : c - 4715;
    }
    validYMD = true;
  }

  void computeHMS() {
    if (validHMS) return;
    computeJD();
    var dayMs = (iJD + 43200000) % 86400000;
    s = (dayMs % 60000) / 1000.0;
    dayMs ~/= 60000;
    mi = dayMs % 60;
    h = dayMs ~/ 60;
    rawS = false;
    validHMS = true;
  }

  void computeYMDHMS() {
    computeYMD();
    computeHMS();
  }

  void clearYMDHMS() {
    validYMD = false;
    validHMS = false;
    validTZ = false;
  }
}

bool _validJulian(int iJD) => iJD >= 0 && iJD <= 464269060799999;

/// Parses "HH:MM[:SS[.SSS]]" with optional timezone at [i].
bool _parseHms(String z, _DT p) {
  final m = RegExp(r'^(\d{2}):(\d{2})(?::(\d{2})(\.\d+)?)?\s*(.*)$')
      .firstMatch(z);
  if (m == null) return false;
  final h = int.parse(m.group(1)!), mi = int.parse(m.group(2)!);
  if (h > 24 || mi > 59) return false;
  var s = 0.0;
  if (m.group(3) != null) {
    s = int.parse(m.group(3)!).toDouble();
    if (s > 59) return false;
    if (m.group(4) != null) s += double.parse('0${m.group(4)}');
  }
  final rest = m.group(5)!;
  p.h = h;
  p.mi = mi;
  p.s = s;
  p.validJD = false;
  p.rawS = false;
  p.validHMS = true;
  if (rest.isNotEmpty) {
    if (rest == 'Z' || rest == 'z') {
      p.tz = 0;
      p.validTZ = true;
    } else {
      final tm = RegExp(r'^([+-])(\d{2}):?(\d{2})$').firstMatch(rest);
      if (tm == null) return false;
      final v = int.parse(tm.group(2)!) * 60 + int.parse(tm.group(3)!);
      p.tz = tm.group(1) == '-' ? -v : v;
      p.validTZ = true;
    }
  }
  return true;
}

bool _parseDate(String z, _DT p) {
  final m = RegExp(r'^(-?)(\d{4})-(\d{2})-(\d{2})(?:[ T]+(.*)|\s*)$')
      .firstMatch(z);
  if (m == null) return false;
  final y = int.parse(m.group(2)!) * (m.group(1) == '-' ? -1 : 1);
  final mo = int.parse(m.group(3)!), d = int.parse(m.group(4)!);
  if (mo < 1 || mo > 12 || d < 1 || d > 31) return false;
  final rest = m.group(5);
  if (rest != null && rest.isNotEmpty) {
    if (!_parseHms(rest, p)) return false;
  } else {
    p.validHMS = false;
  }
  p.validJD = false;
  p.validYMD = true;
  p.y = y;
  p.m = mo;
  p.d = d;
  if (p.validTZ) p.computeJD();
  return true;
}

void _setRawNumber(_DT p, double r) {
  p.s = r;
  p.rawS = true;
  p.rawValue = r;
  if (r >= 0.0 && r < 5373484.5) {
    p.iJD = (r * 86400000.0 + 0.5).floor();
    p.validJD = true;
  }
}

/// Parses a time value (text or number) into [p].
bool _parseTimeValue(Object? v, _DT p, int nowMs) {
  if (v == null) return false;
  if (v is num) {
    _setRawNumber(p, v.toDouble());
    return true;
  }
  final z = (toText(v) ?? '').trim();
  if (_parseDate(z, p)) return true;
  if (_parseHms(z, p)) return true;
  if (z.toLowerCase() == 'now') {
    p.iJD = nowMs;
    p.validJD = true;
    return true;
  }
  final np = parseNumPrefix(z);
  if (np.end > 0 && np.whole) {
    _setRawNumber(p, np.value.toDouble());
    return true;
  }
  return false;
}

const int _unixEpochJDms = 210866760000000; // 1970-01-01 as iJD

int _localOffsetMs(int iJD) {
  final unixMs = iJD - _unixEpochJDms;
  if (unixMs.abs() > 8640000000000000) return 0;
  final dt = DateTime.fromMillisecondsSinceEpoch(unixMs, isUtc: false);
  return dt.timeZoneOffset.inMilliseconds;
}

bool _applyModifier(String z0, _DT p, int idx) {
  final z = z0.toLowerCase().trim();
  switch (z) {
    case 'auto':
      if (idx > 0) return false;
      if (p.rawS) {
        final r = p.rawValue;
        if (r >= 0.0 && r < 5373484.5) {
          // julian day
        } else if (r >= -210866760000.0 && r <= 253402300799.0) {
          p.iJD = ((r * 1000.0) + _unixEpochJDms).round();
          p.validJD = true;
          p.rawS = false;
        } else {
          return false;
        }
        p.clearYMDHMS();
        p.rawS = false;
      }
      return true;
    case 'julianday':
      if (idx > 0 || !p.rawS) return false;
      p.rawS = false;
      return p.validJD;
    case 'unixepoch':
      if (idx > 0 || !p.rawS) return false;
      final r = p.rawValue;
      if (!(r >= -210866760000.0 && r <= 253402300799.0)) return false;
      p.iJD = ((r * 1000.0) + _unixEpochJDms).round();
      p.validJD = true;
      p.rawS = false;
      p.clearYMDHMS();
      return true;
    case 'localtime':
      p.computeJD();
      p.iJD += _localOffsetMs(p.iJD);
      p.clearYMDHMS();
      return true;
    case 'utc':
      p.computeJD();
      final off = _localOffsetMs(p.iJD);
      p.iJD -= off;
      p.clearYMDHMS();
      return true;
    case 'subsec':
    case 'subsecond':
      p.useSubsec = true;
      return true;
  }
  if (z.startsWith('weekday ')) {
    final np = parseNumPrefix(z.substring(8));
    if (np.end == 0 || !np.whole) return false;
    final n = np.value.toDouble();
    if (n < 0 || n >= 7 || n != n.truncateToDouble()) return false;
    p.computeYMDHMS();
    p.validTZ = false;
    p.validJD = false;
    p.computeJD();
    var x = ((p.iJD + 129600000) ~/ 86400000) % 7;
    final target = n.toInt();
    if (x > target) x -= 7;
    p.iJD += (target - x) * 86400000;
    p.clearYMDHMS();
    return true;
  }
  if (z.startsWith('start of ')) {
    final what = z.substring(9).trim();
    p.computeYMD();
    p.validHMS = true;
    p.h = 0;
    p.mi = 0;
    p.s = 0;
    p.rawS = false;
    p.validTZ = false;
    p.validJD = false;
    if (what == 'month') {
      p.d = 1;
    } else if (what == 'year') {
      p.m = 1;
      p.d = 1;
    } else if (what != 'day') {
      return false;
    }
    return true;
  }
  // +/-YYYY-MM-DD[ HH:MM[:SS]] shifts.
  final shift =
      RegExp(r'^([+-])(\d{4})-(\d{2})-(\d{2})(?: (\d{2}):(\d{2})(?::(\d{2}(?:\.\d+)?))?)?$')
          .firstMatch(z);
  if (shift != null) {
    final sign = shift.group(1) == '-' ? -1 : 1;
    p.computeYMDHMS();
    p.validJD = false;
    p.y += sign * int.parse(shift.group(2)!);
    p.m += sign * int.parse(shift.group(3)!);
    _normalizeMonth(p);
    p.computeJD();
    p.validHMS = false;
    p.validYMD = false;
    var ms = int.parse(shift.group(4)!) * 86400000;
    if (shift.group(5) != null) {
      ms += int.parse(shift.group(5)!) * 3600000 +
          int.parse(shift.group(6)!) * 60000;
      if (shift.group(7) != null) {
        ms += (double.parse(shift.group(7)!) * 1000).round();
      }
    }
    p.iJD += sign * ms;
    return true;
  }
  final m = RegExp(r'^([+-]?\d+(?:\.\d*)?|[+-]?\.\d+)\s*([a-z]+)$').firstMatch(z);
  if (m != null) {
    final r = double.parse(m.group(1)!.replaceFirst(RegExp(r'\.$'), ''));
    var unit = m.group(2)!;
    if (unit.endsWith('s')) unit = unit.substring(0, unit.length - 1);
    const unitMs = {
      'second': 1000.0,
      'minute': 60000.0,
      'hour': 3600000.0,
      'day': 86400000.0,
    };
    if (unitMs.containsKey(unit)) {
      p.computeJD();
      p.iJD += (r * unitMs[unit]!).round();
      p.clearYMDHMS();
      return true;
    }
    if (unit == 'month' || unit == 'year') {
      p.computeYMDHMS();
      p.validJD = false;
      final n = r.truncate();
      if (unit == 'month') {
        p.m += n;
      } else {
        p.y += n;
      }
      _normalizeMonth(p);
      p.validTZ = false;
      p.computeJD();
      final frac = r - n;
      if (frac != 0) {
        p.iJD += (frac * (unit == 'month' ? 30.0 : 365.0) * 86400000).round();
      }
      p.clearYMDHMS();
      return true;
    }
    return false;
  }
  // HH:MM[:SS] offset.
  final hm = RegExp(r'^([+-])?(\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?)$').firstMatch(z);
  if (hm != null) {
    final t = _DT();
    if (!_parseHms(hm.group(2)!, t)) return false;
    final ms =
        t.h * 3600000 + t.mi * 60000 + (t.s * 1000).round();
    p.computeJD();
    p.iJD += hm.group(1) == '-' ? -ms : ms;
    p.clearYMDHMS();
    return true;
  }
  return false;
}

void _normalizeMonth(_DT p) {
  final x = p.m > 0 ? (p.m - 1) ~/ 12 : (p.m - 12) ~/ 12;
  p.y += x;
  p.m -= x * 12;
}

_DT? _parseArgs(List<Object?> args, int nowMs) {
  final p = _DT();
  if (args.isEmpty) {
    p.iJD = nowMs;
    p.validJD = true;
  } else {
    if (!_parseTimeValue(args[0], p, nowMs)) return null;
    for (var i = 1; i < args.length; i++) {
      final z = toText(args[i]);
      if (z == null) return null;
      if (!_applyModifier(z, p, i - 1)) return null;
    }
  }
  p.computeJD();
  if (p.isError || !_validJulian(p.iJD)) return null;
  if (p.rawS && !p.validJD) return null;
  // Normalise (2024-02-30 is 2024-03-01) by recomputing from the JD.
  final sub = p.useSubsec;
  p.clearYMDHMS();
  p.useSubsec = sub;
  return p;
}

String _two(int x) => x.toString().padLeft(2, '0');

String _year(int y) {
  if (y < 0) return '-${(-y).toString().padLeft(4, '0')}';
  return y.toString().padLeft(4, '0');
}

String _secs(_DT p) {
  if (p.useSubsec) {
    final ms = (p.s * 1000).round();
    return '${_two(ms ~/ 1000)}.${(ms % 1000).toString().padLeft(3, '0')}';
  }
  return _two(p.s.floor());
}

Object? sqlDate(List<Object?> a, int nowMs) {
  final p = _parseArgs(a, nowMs);
  if (p == null) return null;
  p.computeYMD();
  return '${_year(p.y)}-${_two(p.m)}-${_two(p.d)}';
}

Object? sqlTime(List<Object?> a, int nowMs) {
  final p = _parseArgs(a, nowMs);
  if (p == null) return null;
  p.computeHMS();
  return '${_two(p.h)}:${_two(p.mi)}:${_secs(p)}';
}

Object? sqlDatetime(List<Object?> a, int nowMs) {
  final p = _parseArgs(a, nowMs);
  if (p == null) return null;
  p.computeYMDHMS();
  return '${_year(p.y)}-${_two(p.m)}-${_two(p.d)} '
      '${_two(p.h)}:${_two(p.mi)}:${_secs(p)}';
}

Object? sqlJulianday(List<Object?> a, int nowMs) {
  final p = _parseArgs(a, nowMs);
  if (p == null) return null;
  return p.iJD / 86400000.0;
}

Object? sqlUnixepoch(List<Object?> a, int nowMs) {
  final p = _parseArgs(a, nowMs);
  if (p == null) return null;
  if (p.useSubsec) return (p.iJD - _unixEpochJDms) / 1000.0;
  return p.iJD ~/ 1000 - 210866760000;
}

/// Unix time in nanoseconds of a time value (zx DATETIME columns), or
/// null when [v] is not a recognisable date/time text.
int? parseDateTimeToNs(String v) {
  final p = _DT();
  if (!_parseTimeValue(v, p, 0) || p.rawS) return null;
  p.computeJD();
  if (p.isError) return null;
  // Keep sub-millisecond digits of the seconds field.
  var ns = (p.iJD - _unixEpochJDms) * 1000000;
  final frac = RegExp(r':\d{2}\.(\d{4,9})').firstMatch(v);
  if (frac != null) {
    final digits = frac.group(1)!.padRight(9, '0');
    final extra = int.parse(digits.substring(3));
    ns += extra;
  }
  return ns;
}

Object? sqlStrftime(List<Object?> a, int nowMs) {
  if (a.isEmpty) return null;
  final fmt = toText(a[0]);
  if (fmt == null) return null;
  final p = _parseArgs(a.sublist(1), nowMs);
  if (p == null) return null;
  p.computeYMDHMS();
  final b = StringBuffer();
  for (var i = 0; i < fmt.length; i++) {
    final c = fmt[i];
    if (c != '%') {
      b.write(c);
      continue;
    }
    i++;
    if (i >= fmt.length) return null;
    switch (fmt[i]) {
      case 'd':
        b.write(_two(p.d));
      case 'e':
        b.write(p.d.toString().padLeft(2, ' '));
      case 'f':
        var s = p.s;
        if (s > 59.999) s = 59.999;
        b.write(s.toStringAsFixed(3).padLeft(6, '0'));
      case 'F':
        b.write('${_year(p.y)}-${_two(p.m)}-${_two(p.d)}');
      case 'H':
        b.write(_two(p.h));
      case 'k':
        b.write(p.h.toString().padLeft(2, ' '));
      case 'I':
      case 'l':
        var h = p.h % 12;
        if (h == 0) h = 12;
        b.write(fmt[i] == 'I' ? _two(h) : h.toString().padLeft(2, ' '));
      case 'j':
        b.write((_dayOfYear(p) + 1).toString().padLeft(3, '0'));
      case 'J':
        b.write(formatG(p.iJD / 86400000.0, 16));
      case 'm':
        b.write(_two(p.m));
      case 'M':
        b.write(_two(p.mi));
      case 'p':
        b.write(p.h >= 12 ? 'PM' : 'AM');
      case 'P':
        b.write(p.h >= 12 ? 'pm' : 'am');
      case 'R':
        b.write('${_two(p.h)}:${_two(p.mi)}');
      case 's':
        if (p.useSubsec) {
          b.write(formatG((p.iJD - _unixEpochJDms) / 1000.0, 15));
        } else {
          b.write(p.iJD ~/ 1000 - 210866760000);
        }
      case 'S':
        b.write(_two(p.s.floor()));
      case 'T':
        b.write('${_two(p.h)}:${_two(p.mi)}:${_two(p.s.floor())}');
      case 'u':
        final w = _dayOfWeek(p);
        b.write(w == 0 ? 7 : w);
      case 'w':
        b.write(_dayOfWeek(p));
      case 'U':
        b.write(_two((_dayOfYear(p) + 7 - _dayOfWeek(p)) ~/ 7));
      case 'W':
        b.write(_two((_dayOfYear(p) + 7 - ((_dayOfWeek(p) + 6) % 7)) ~/ 7));
      case 'Y':
        b.write(_year(p.y));
      case 'G':
      case 'g':
      case 'V':
        final iso = _isoWeek(p);
        if (fmt[i] == 'G') {
          b.write(_year(iso.$1));
        } else if (fmt[i] == 'g') {
          b.write(_two(iso.$1 % 100));
        } else {
          b.write(_two(iso.$2));
        }
      case '%':
        b.write('%');
      default:
        return null;
    }
  }
  return b.toString();
}

int _dayOfWeek(_DT p) => ((p.iJD + 129600000) ~/ 86400000) % 7;

int _dayOfYear(_DT p) {
  final jan1 = _DT()
    ..y = p.y
    ..m = 1
    ..d = 1
    ..validYMD = true;
  jan1.computeJD();
  final start = (jan1.iJD + 43200000) ~/ 86400000;
  final cur = (p.iJD + 43200000) ~/ 86400000;
  return cur - start;
}

(int, int) _isoWeek(_DT p) {
  // Thursday of this week decides the ISO year.
  final dow = (_dayOfWeek(p) + 6) % 7; // Monday = 0
  final thu = _DT()
    ..iJD = p.iJD + (3 - dow) * 86400000
    ..validJD = true;
  thu.computeYMD();
  final doy = _dayOfYear(thu);
  return (thu.y, doy ~/ 7 + 1);
}

/// Current time as iJD milliseconds.
int nowJulianMs(int unixNs) => unixNs ~/ 1000000 + _unixEpochJDms;
