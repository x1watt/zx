// Vendored from zpaq-flutter by tool/sync_zpaq.sh: do not edit here, change
// zpaq-flutter and sync again. Pure Dart port of libzpaq and zpaq 7.15 (Matt
// Mahoney, public domain) with the zpaqfranz attribute format (Franco
// Corbelli, MIT). Copyright (c) 2026 Max Brito, BSD 3-clause; see LICENSE
// for the license and the third party notices.

/// zpaq stores dates as decimal numbers YYYYMMDDHHMMSS in UTC.
int dateTimeToDecimal(DateTime t) {
  final u = t.toUtc();
  return u.year * 10000000000 +
      u.month * 100000000 +
      u.day * 1000000 +
      u.hour * 10000 +
      u.minute * 100 +
      u.second;
}

DateTime decimalToDateTime(int d) => DateTime.utc(
      d ~/ 10000000000,
      d ~/ 100000000 % 100,
      d ~/ 1000000 % 100,
      d ~/ 10000 % 100,
      d ~/ 100 % 100,
      d % 100,
    );

/// "YYYY-MM-DD HH:MM:SS" (UTC).
String formatDecimalDate(int d) {
  if (d == 0) return '0000-00-00 00:00:00';
  String p(int x, int n) => x.toString().padLeft(n, '0');
  return '${p(d ~/ 10000000000, 4)}-${p(d ~/ 100000000 % 100, 2)}-'
      '${p(d ~/ 1000000 % 100, 2)} ${p(d ~/ 10000 % 100, 2)}:'
      '${p(d ~/ 100 % 100, 2)}:${p(d % 100, 2)}';
}
