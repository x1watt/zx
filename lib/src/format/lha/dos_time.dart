// Time conversions of the LHA and ARJ headers: MS-DOS date and time (local
// time, 2 second steps), Unix seconds and FILETIME (100 ns ticks since
// 1601, the time properties of the handlers).

/// FILETIME of 1970-01-01.
const int kFileTimeUnixEpoch = 116444736000000000;

/// FILETIME of Unix time [seconds].
int unixTimeToFileTime(int seconds) => seconds * 10000000 + kFileTimeUnixEpoch;

/// Unix seconds of [ft], rounded down.
int fileTimeToUnixTime(int ft) {
  final t = ft - kFileTimeUnixEpoch;
  var s = t ~/ 10000000;
  if (t < 0 && s * 10000000 != t) s--;
  return s;
}

/// FILETIME of an MS-DOS date and time (local time); null for 0 or an
/// invalid value.
int? dosTimeToFileTime(int dos) {
  if (dos == 0) return null;
  final sec = (dos << 1) & 0x3E;
  final min = (dos >> 5) & 0x3F;
  final hour = (dos >> 11) & 0x1F;
  final day = (dos >> 16) & 0x1F;
  final mon = (dos >> 21) & 0x0F;
  final year = 1980 + ((dos >> 25) & 0x7F);
  if (mon < 1 || mon > 12 || day < 1 || hour > 23 || min > 59 || sec > 59) {
    return null;
  }
  final t = DateTime(year, mon, day, hour, min, sec);
  return t.microsecondsSinceEpoch * 10 + kFileTimeUnixEpoch;
}

/// The MS-DOS date and time (local time) of [ft], odd seconds rounded up,
/// clamped to 1980..2107.
int fileTimeToDosTime(int ft) {
  var us = (ft - kFileTimeUnixEpoch) ~/ 10;
  var t = DateTime.fromMicrosecondsSinceEpoch(us);
  if (t.second.isOdd || t.millisecond != 0 || t.microsecond != 0) {
    // up to the next even second
    us = us - t.millisecond * 1000 - t.microsecond + 1000000;
    t = DateTime.fromMicrosecondsSinceEpoch(us);
    if (t.second.isOdd) t = t.add(const Duration(seconds: 1));
  }
  if (t.year < 1980) return (1 << 21) | (1 << 16); // 1980-01-01
  if (t.year > 2107) {
    return (127 << 25) | (12 << 21) | (31 << 16) | (23 << 11) | (59 << 5) | 29;
  }
  return ((t.year - 1980) << 25) |
      (t.month << 21) |
      (t.day << 16) |
      (t.hour << 11) |
      (t.minute << 5) |
      (t.second >> 1);
}
