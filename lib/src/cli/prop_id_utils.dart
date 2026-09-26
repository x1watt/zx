// Property value printing: UI/Common/PropIDUtils.cpp
// (ConvertPropertyToString2, ConvertWinAttribToString, the POSIX mode
// string) and Windows/PropVariantConv.cpp (ConvertUtcFileTimeToString2,
// ConvertPropVariantToShortString) of the LZMA SDK, with the POSIX
// FileTimeToLocalFileTime of Common/MyWindows.cpp.

import '../format/archive_types.dart';
import 'common.dart';

/// g_Timestamp_Show_UTC (the -slmu switch).
bool gTimestampShowUtc = false;

const int kTimestampPrintLevelDay = -3;
const int kTimestampPrintLevelMin = -1;
const int kTimestampPrintLevelSec = 0;
const int kTimestampPrintLevelNtfs = 7;
const int kTimestampPrintLevelNs = 9;

const int kTimestampPrintFlagsForceUtc = 1 << 0;
const int kTimestampPrintFlagsForceLocal = 1 << 1;
const int kTimestampPrintFlagsDisableZ = 1 << 4;

// TIME_GetBias: the current offset of local time, applied to all times.
int? _biasTicks;
int _localOffsetTicks() =>
    _biasTicks ??= DateTime.now().timeZoneOffset.inSeconds * 10000000;

String _two(int v) => v < 10 ? '0$v' : '$v';

/// ConvertUtcFileTimeToString2: null when the time can not be converted.
String? convertUtcFileTimeToString2(int utc, int ns100,
    [int level = kTimestampPrintLevelSec, int flags = 0]) {
  final showUtc = (flags & kTimestampPrintFlagsForceUtc) != 0
      ? true
      : (flags & kTimestampPrintFlagsForceLocal) != 0
          ? false
          : gTimestampShowUtc;
  var ft = utc;
  if (!showUtc) ft = utc + _localOffsetTicks();
  if (ft < 0) return null; // FileTimeToSystemTime fails for bit 63
  final dt = DateTime.fromMicrosecondsSinceEpoch(
      (ft - kFileTimeUnixEpoch) ~/ 10 -
          (((ft - kFileTimeUnixEpoch) % 10 != 0 && ft < kFileTimeUnixEpoch)
              ? 1
              : 0),
      isUtc: true);
  final sb = StringBuffer();
  var year = dt.year;
  if (year >= 10000) {
    sb.write(year ~/ 10000);
    year %= 10000;
  }
  sb.write(year.toString().padLeft(4, '0'));
  sb.write('-${_two(dt.month)}-${_two(dt.day)}');
  if (level > kTimestampPrintLevelDay) {
    sb.write(' ${_two(dt.hour)}:${_two(dt.minute)}');
    if (level >= kTimestampPrintLevelSec) {
      sb.write(':${_two(dt.second)}');
      if (level > kTimestampPrintLevelSec) {
        sb.write('.');
        var numDigits = 7;
        final frac = (ft % 10000000).toString().padLeft(7, '0');
        if (numDigits > level) numDigits = level;
        sb.write(frac.substring(0, numDigits));
        if (level >= kTimestampPrintLevelNtfs + 1) {
          sb.write(ns100 ~/ 10);
          if (level >= kTimestampPrintLevelNtfs + 2) sb.write(ns100 % 10);
        }
      }
    }
  }
  if (showUtc) {
    if ((flags & kTimestampPrintFlagsDisableZ) == 0) sb.write('Z');
  }
  return sb.toString();
}

/// ConvertUtcFileTimeToString (level SEC by default).
String? convertUtcFileTimeToString(int ft,
        [int level = kTimestampPrintLevelSec]) =>
    convertUtcFileTimeToString2(ft, 0, level);

const String _gWinAttribChars = 'RHS8DAdNTsLCOIEVvX.PU.M......B';
const String _kPosixTypes = '0pc3d5b7-9lBsDEF';

String _attrChar(int a, int n, String c) => (a & (1 << n)) != 0 ? c : '-';

// ConvertPosixAttribToString
String convertPosixAttribToString(int a) {
  final s = List<String>.filled(10, '-');
  s[0] = _kPosixTypes[(a >> 12) & 0xF];
  for (var i = 6; i >= 0; i -= 3) {
    s[7 - i] = _attrChar(a, i + 2, 'r');
    s[8 - i] = _attrChar(a, i + 1, 'w');
    s[9 - i] = _attrChar(a, i + 0, 'x');
  }
  if ((a & 0x800) != 0) s[3] = (a & (1 << 6)) != 0 ? 's' : 'S';
  if ((a & 0x400) != 0) s[6] = (a & (1 << 3)) != 0 ? 's' : 'S';
  if ((a & 0x200) != 0) s[9] = (a & (1 << 0)) != 0 ? 't' : 'T';
  var r = s.join();
  a &= ~0xFFFF;
  a &= 0xFFFFFFFF;
  if (a != 0) r += ' ${hex8Upper(a)}';
  return r;
}

/// ConvertWinAttribToString.
String convertWinAttribToString(int wa) {
  wa &= 0xFFFFFFFF;
  final isPosix = (wa & 0x8000) != 0;
  var posix = 0;
  if (isPosix) {
    posix = wa >> 16;
    if ((wa & 0xF0000000) != 0) wa &= 0x3FFF;
  }
  final sb = StringBuffer();
  for (var i = 0; i < 30; i++) {
    final flag = 1 << i;
    if ((wa & flag) != 0) {
      final c = _gWinAttribChars[i];
      if (c != '.') {
        wa &= ~flag;
        sb.write(c);
      }
    }
  }
  if (wa != 0) sb.write(' ${hex8Upper(wa)}');
  if (isPosix) sb.write(' ${convertPosixAttribToString(posix)}');
  return sb.toString();
}

/// True when the property is a FILETIME value.
bool isFileTimeProp(int propId) =>
    propId == Kpid.cTime ||
    propId == Kpid.aTime ||
    propId == Kpid.mTime ||
    propId == Kpid.changeTime;

/// ConvertPropertyToShortString2 for the values of the handlers: [timePrec]
/// is the precision of FILETIME values (0 when not given).
String convertPropertyToShortString2(Object? prop, int propId,
    {int level = 0, int timePrec = 0}) {
  if (prop == null) return '';
  if (prop is int && isFileTimeProp(propId)) {
    var numDigits = kTimestampPrintLevelNtfs;
    final prec = timePrec;
    if (prec != 0 && prec <= 16 + 9) {
      if (prec == 1 || prec == 2) {
        numDigits = 0;
      } else if (prec == 3) {
        numDigits = 9;
      } else {
        numDigits = prec - 16;
        if (numDigits < kTimestampPrintLevelSec) {
          numDigits = kTimestampPrintLevelNtfs;
        }
      }
    }
    if (prop == 0) return '';
    if (level > numDigits) level = numDigits;
    return convertUtcFileTimeToString2(prop, 0, level) ?? '';
  }
  switch (propId) {
    case Kpid.crc:
      if (prop is int) return hex8Upper(prop);
    case Kpid.attrib:
      if (prop is int) return convertWinAttribToString(prop);
    case Kpid.posixAttrib:
      if (prop is int) return convertPosixAttribToString(prop);
    case Kpid.iNode:
      if (prop is int) {
        return '${(prop >> 48) & 0xFFFF}-${prop & ((1 << 48) - 1)}';
      }
    case Kpid.va:
      if (prop is int) return '0x${hexUpper(prop)}';
  }
  return convertPropVariantToShortString(prop);
}

/// ConvertPropVariantToShortString.
String convertPropVariantToShortString(Object? prop) {
  if (prop == null) return '';
  if (prop is String) return '?';
  if (prop is bool) return prop ? '+' : '-';
  if (prop is int) return u64ToString(prop);
  return '?';
}

/// ConvertPropertyToString2.
String convertPropertyToString2(Object? prop, int propId,
    {int level = 0, int timePrec = 0}) {
  if (prop is String) return prop;
  return convertPropertyToShortString2(prop, propId,
      level: level, timePrec: timePrec);
}
