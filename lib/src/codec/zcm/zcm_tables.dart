// zcm: integer tables and hashes shared by every component.
//
// Everything here is integer arithmetic, so the tables are the same on
// every platform (see zcm.dart for the determinism rules of the codec).
//
// squash and stretch follow lpaq1 by Matt Mahoney (33 point interpolation
// of the logistic function, stretch as its exact inverse); the ilog table
// is the integer recurrence of paq8 (Matt Mahoney). The division table
// follows the AdaptiveMap of paq8px (Zoltan Gotthardt).

import 'dart:typed_data';

/// Logistic function: p = 4096 / (1 + exp(-d / 256)), d in -2047..2047,
/// p in 0..4095. Table of 4096 entries indexed by d + 2048.
final Int16List kSquash = _buildSquash();

/// Inverse of squash: d = ln(p / (1 - p)) * 256, p in 0..4095.
final Int16List kStretch = _buildStretch();

/// kDt[n] = 2^31 / (2n + 3): the reciprocal 1 / (n + 1.5) in 2^30 units,
/// the adaptation rate of a StateMap entry that has seen n updates.
final Int32List kDt = _buildDt();

/// kIlog[x] = round(log2(x) * 16) for x in 0..65535 (paq8 Ilog).
final Uint8List kIlog = _buildIlog();

// squash (lpaq1)
int _squashCalc(int d) {
  if (d > 2047) return 4095;
  if (d < -2047) return 0;
  const t = [
    1, 2, 3, 6, 10, 16, 27, 45, 73, 120, 194, 310, 488, 747, 1101, //
    1546, 2047, 2549, 2994, 3348, 3607, 3785, 3901, 3975, 4024, //
    4050, 4068, 4079, 4085, 4089, 4092, 4093, 4094
  ];
  final w = d & 127;
  final i = (d >> 7) + 16;
  return (t[i] * (128 - w) + t[i + 1] * w + 64) >> 7;
}

Int16List _buildSquash() {
  final t = Int16List(4096);
  for (var i = 0; i < 4096; i++) {
    t[i] = _squashCalc(i - 2048);
  }
  return t;
}

// stretch (lpaq1): the inverse of squash
Int16List _buildStretch() {
  final t = Int16List(4096);
  var pi = 0;
  for (var x = -2047; x <= 2047; x++) {
    final v = _squashCalc(x);
    for (var i = pi; i <= v; i++) {
      t[i] = x;
    }
    pi = v + 1;
  }
  for (var i = pi; i < 4096; i++) {
    t[i] = 2047;
  }
  return t;
}

Int32List _buildDt() {
  final t = Int32List(1024);
  for (var n = 0; n < 1024; n++) {
    t[n] = (1 << 31) ~/ (2 * n + 3);
  }
  return t;
}

// Ilog (paq8)
Uint8List _buildIlog() {
  final t = Uint8List(65536);
  var x = 14155776;
  for (var i = 2; i < 65536; i++) {
    x += 774541002 ~/ (i * 2 - 1); // 2^29 / ln 2
    t[i] = x >> 24;
  }
  return t;
}

/// squash with clamping of the argument.
@pragma('vm:prefer-inline')
int squash(int d) {
  if (d > 2047) d = 2047;
  if (d < -2047) d = -2047;
  return kSquash[d + 2048];
}

/// 32-bit hash of two values (finalized, well mixed).
@pragma('vm:prefer-inline')
int hash2(int a, int b) {
  var h = ((a & 0xFFFFFFFF) * 0x9E3779B1 + (b & 0xFFFFFFFF) * 0x85EBCA77 + 1) &
      0xFFFFFFFF;
  h ^= h >> 15;
  h = (h * 0x2C1B3C6D) & 0xFFFFFFFF;
  h ^= h >> 13;
  return h;
}

/// 32-bit hash of three values.
@pragma('vm:prefer-inline')
int hash3(int a, int b, int c) => hash2(hash2(a, b), c);

/// 32-bit hash of four values.
@pragma('vm:prefer-inline')
int hash4(int a, int b, int c, int d) => hash2(hash2(hash2(a, b), c), d);

/// Largest power of two <= [x] (x >= 1).
int floorPow2(int x) {
  var p = 1;
  while (p * 2 <= x) {
    p *= 2;
  }
  return p;
}

/// log2 of a power of two.
int log2Exact(int x) {
  var n = 0;
  while ((1 << n) < x) {
    n++;
  }
  return n;
}

/// Hash bits of a table of 2^bits entries of [entryBytes] each that fits
/// in [bytes] (10 to 22).
int zcmHashBitsFor(int bytes, int entryBytes) {
  var b = 10;
  while (b < 22 && (entryBytes << (b + 1)) <= bytes) {
    b++;
  }
  return b;
}
