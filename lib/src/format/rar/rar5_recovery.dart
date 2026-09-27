// The RAR5 recovery record (the "RR" service header of rar -rr).
//
// The technote names the service header but does not describe its data;
// the layout below was found by black box study of the archives that
// rar 7.00 writes and repairs (docs/architecture.md, section 10: no unRAR
// or other rar source was read):
//
// The protected data is the archive (or the volume) from its first byte
// to the recovery record header. It is cut into G chunks of E bytes, the
// last one shorter (zeros for the code):
//   G = min(ceil(size / 1024), 200), E = ceil(size / G) rounded up to even.
// The record is H blocks, H = max(1, floor(G * percent / 100)), each one
//   0   4  "{RB}"
//   4   8  CRC-64 (xz) of the block from offset 12 to its end
//   12  4  block size: 64 + 8 * G + 8 + E
//   16  4  offset of the parity in the block: 64 + 8 * G + 8
//   20  2  1, 1
//   22  8  0
//   30  4  size of the last chunk
//   34  8  size of the protected data
//   42  8  E
//   50  8  block size
//   58  2  G
//   60  2  H
//   62  2  index of the block
//   64  8G the CRC-64 of each chunk, register started at zero and not
//          inverted at the end (the last chunk without its zeros)
//   ..  8  a 64-bit value that rar changes with the time; rar does not
//          check it (a test changed it and rar still tested and repaired);
//          this port writes the CRC-64 of the chunk checksums
//   ..  E  the parity of the block
// The parity is a Reed-Solomon (Cauchy) code over GF(2^16) with the
// polynomial x^16 + x^12 + x^3 + x + 1 (0x1100B), on little endian 16-bit
// symbols: symbol j of block r is the sum over the chunks k of
// symbol j of chunk k times 1 / (k xor (G + r)). Any H damaged chunks,
// found by their CRC-64, can be rebuilt from H blocks.

import 'dart:typed_data';

import '../../io/streams.dart';
import '../../util/crc.dart';

/// GF(2^16) with the polynomial 0x1100B: exponent and logarithm tables.
final class _Gf16 {
  static final _Gf16 instance = _Gf16._();
  final Uint16List exp = Uint16List(2 * 65536);
  final Int32List log = Int32List(65536);
  _Gf16._() {
    var x = 1;
    for (var i = 0; i < 65535; i++) {
      exp[i] = x;
      log[x] = i;
      x <<= 1;
      if ((x & 0x10000) != 0) x ^= 0x1100B;
    }
    for (var i = 65535; i < exp.length; i++) {
      exp[i] = exp[i - 65535];
    }
    log[0] = -1;
  }

  int mul(int a, int b) =>
      a == 0 || b == 0 ? 0 : exp[log[a] + log[b]];

  int inv(int a) => exp[65535 - log[a]];

  /// log(1 / a)
  int logInv(int a) => (65535 - log[a]) % 65535;
}

/// The shape of a recovery record for [dataSize] protected bytes.
final class Rar5RecoveryLayout {
  final int dataSize;
  final int percent;

  /// G: the number of data chunks.
  final int chunks;

  /// E: the chunk size (even).
  final int chunkSize;

  /// H: the number of recovery blocks.
  final int blocks;

  Rar5RecoveryLayout._(
      this.dataSize, this.percent, this.chunks, this.chunkSize, this.blocks);

  factory Rar5RecoveryLayout(int dataSize, int percent) {
    var g = (dataSize + 1023) ~/ 1024;
    if (g > 200) g = 200;
    if (g < 1) g = 1;
    var e = (dataSize + g - 1) ~/ g;
    if (e < 2) e = 2;
    if ((e & 1) != 0) e++;
    var h = g * percent ~/ 100;
    if (h < 1) h = 1;
    return Rar5RecoveryLayout._(dataSize, percent, g, e, h);
  }

  int get parityOffset => 72 + 8 * chunks;
  int get blockSize => parityOffset + chunkSize;
  int get size => blocks * blockSize;

  /// The largest record for any protected size up to [dataSize] (the
  /// size is not monotonic where the chunk count changes).
  static int maxSize(int dataSize, int percent) {
    var m = Rar5RecoveryLayout(dataSize, percent).size;
    for (var g = 1; g < 200 && g * 1024 < dataSize; g++) {
      final s = Rar5RecoveryLayout(g * 1024, percent).size;
      if (s > m) m = s;
    }
    return m;
  }
}

/// Reads [len] bytes of the protected data at [pos] into [buf] at [off].
typedef Rar5ReadAt = void Function(int pos, Uint8List buf, int off, int len);

/// Builds the recovery record data for [l], reading the protected data
/// with [read]. [id] is the 64-bit value stored in every block (by default
/// the CRC-64 of the chunk checksums).
Uint8List rar5BuildRecovery(Rar5RecoveryLayout l, Rar5ReadAt read,
    [int? id]) {
  final gf = _Gf16.instance;
  final exp = gf.exp;
  final log = gf.log;
  final g = l.chunks, e = l.chunkSize, h = l.blocks;
  final ns = e >> 1;
  final parity = [for (var r = 0; r < h; r++) Uint16List(ns)];
  final crcs = List<int>.filled(g, 0);
  final chunk = Uint8List(e);
  final lg = Int32List(ns);
  for (var k = 0; k < g; k++) {
    final start = k * e;
    var n = l.dataSize - start;
    if (n > e) n = e;
    if (n < 0) n = 0;
    if (n > 0) read(start, chunk, 0, n);
    chunk.fillRange(n, e, 0);
    crcs[k] = (Crc64.zero()..update(chunk, 0, n)).register;
    var any = false;
    for (var j = 0; j < ns; j++) {
      final v = chunk[2 * j] | (chunk[2 * j + 1] << 8);
      lg[j] = log[v];
      if (v != 0) any = true;
    }
    if (!any) continue;
    for (var r = 0; r < h; r++) {
      final lc = gf.logInv(k ^ (g + r));
      final p = parity[r];
      for (var j = 0; j < ns; j++) {
        final lv = lg[j];
        if (lv >= 0) p[j] ^= exp[lv + lc];
      }
    }
  }
  final bs = l.blockSize;
  final out = Uint8List(h * bs);
  if (id == null) {
    final t = Uint8List(8 * g);
    for (var k = 0; k < g; k++) {
      setUint64LE(t, 8 * k, crcs[k]);
    }
    final c = (Crc64()..update(t)).bytes;
    id = getUint64LE(c, 0);
  }
  for (var r = 0; r < h; r++) {
    final o = r * bs;
    out[o] = 0x7B; // {RB}
    out[o + 1] = 0x52;
    out[o + 2] = 0x42;
    out[o + 3] = 0x7D;
    setUint32LE(out, o + 12, bs);
    setUint32LE(out, o + 16, l.parityOffset);
    out[o + 20] = 1;
    out[o + 21] = 1;
    setUint32LE(out, o + 30, l.dataSize - (g - 1) * e);
    setUint64LE(out, o + 34, l.dataSize);
    setUint64LE(out, o + 42, e);
    setUint64LE(out, o + 50, bs);
    _setU16(out, o + 58, g);
    _setU16(out, o + 60, h);
    _setU16(out, o + 62, r);
    for (var k = 0; k < g; k++) {
      setUint64LE(out, o + 64 + 8 * k, crcs[k]);
    }
    setUint64LE(out, o + 64 + 8 * g, id);
    final p = parity[r];
    var q = o + l.parityOffset;
    for (var j = 0; j < ns; j++) {
      out[q++] = p[j] & 0xFF;
      out[q++] = p[j] >> 8;
    }
    final c = Crc64()..update(out, o + 12, o + bs);
    out.setRange(o + 4, o + 12, c.bytes);
  }
  return out;
}

void _setU16(Uint8List b, int o, int v) {
  b[o] = v & 0xFF;
  b[o + 1] = (v >> 8) & 0xFF;
}

int _u16(Uint8List b, int o) => b[o] | (b[o + 1] << 8);

/// The result of [rar5RepairWithRecovery].
final class Rar5RepairResult {
  /// Chunks that were damaged and rebuilt.
  final int repaired;

  /// Chunks that were damaged and could not be rebuilt (too many, or the
  /// recovery blocks themselves are damaged).
  final int unrecoverable;
  const Rar5RepairResult(this.repaired, this.unrecoverable);
}

/// Checks the protected data [data] (the archive up to the recovery
/// record) against the recovery record [rr] (the data of the RR service
/// header) and rebuilds damaged chunks in place. Blocks whose CRC-64 is
/// wrong are not used.
Rar5RepairResult rar5RepairWithRecovery(Uint8List data, Uint8List rr) {
  // the valid blocks
  final valid = <int>[];
  int? g, e, h, size;
  var p = 0;
  Uint8List? crcTable;
  while (p + 64 <= rr.length) {
    if (rr[p] != 0x7B || rr[p + 1] != 0x52 || rr[p + 2] != 0x42 ||
        rr[p + 3] != 0x7D) {
      p++;
      continue;
    }
    final bs = getUint32LE(rr, p + 12);
    if (bs < 72 || p + bs > rr.length) {
      p++;
      continue;
    }
    final c = Crc64()..update(rr, p + 12, p + bs);
    final want = rr.sublist(p + 4, p + 12);
    final got = c.bytes;
    var ok = true;
    for (var i = 0; i < 8; i++) {
      if (want[i] != got[i]) ok = false;
    }
    if (!ok) {
      p++;
      continue;
    }
    g = _u16(rr, p + 58);
    h = _u16(rr, p + 60);
    e = getUint64LE(rr, p + 42);
    size = getUint64LE(rr, p + 34);
    crcTable ??= Uint8List.sublistView(rr, p + 64, p + 64 + 8 * g);
    valid.add(p);
    p += bs;
  }
  if (valid.isEmpty || g == null || e == null || h == null || size == null) {
    throw const SevenZipException(
        'RAR5: the recovery record is damaged', SevenZipError.data);
  }
  if (size != data.length) {
    throw const SevenZipException(
        'RAR5: the recovery record does not match the archive size',
        SevenZipError.data);
  }
  final gg = g, ee = e;
  // the damaged chunks
  final bad = <int>[];
  for (var k = 0; k < gg; k++) {
    final start = k * ee;
    var n = size - start;
    if (n > ee) n = ee;
    final c = Crc64.zero()..update(data, start, start + n);
    if (c.register != getUint64LE(crcTable!, 8 * k)) bad.add(k);
  }
  if (bad.isEmpty) return const Rar5RepairResult(0, 0);
  if (bad.length > valid.length) return Rar5RepairResult(0, bad.length);
  final gf = _Gf16.instance;
  final m = bad.length;
  final use = valid.sublist(0, m);
  // A x = s: A[i][t] = 1 / (bad[t] xor (G + r_i)), s = parity of block
  // r_i minus the contribution of the good chunks
  final ns = ee >> 1;
  final rows = [for (final bp in use) _u16(rr, bp + 62)];
  final a = [
    for (final r in rows)
      Int32List.fromList([for (final k in bad) gf.inv(k ^ (gg + r))])
  ];
  final s = [
    for (final bp in use) () {
      final v = Uint16List(ns);
      final po = bp + getUint32LE(rr, bp + 16);
      for (var j = 0; j < ns; j++) {
        v[j] = _u16(rr, po + 2 * j);
      }
      return v;
    }()
  ];
  final chunk = Uint8List(ee);
  final badSet = bad.toSet();
  for (var k = 0; k < gg; k++) {
    if (badSet.contains(k)) continue;
    final start = k * ee;
    var n = size - start;
    if (n > ee) n = ee;
    chunk.setRange(0, n, data, start);
    chunk.fillRange(n, ee, 0);
    for (var i = 0; i < m; i++) {
      final coef = gf.inv(k ^ (gg + rows[i]));
      final v = s[i];
      for (var j = 0; j < ns; j++) {
        v[j] ^= gf.mul(coef, chunk[2 * j] | (chunk[2 * j + 1] << 8));
      }
    }
  }
  // Gauss-Jordan elimination (a Cauchy matrix is invertible)
  for (var col = 0; col < m; col++) {
    var piv = col;
    while (a[piv][col] == 0) {
      piv++;
    }
    if (piv != col) {
      final t = a[piv];
      a[piv] = a[col];
      a[col] = t;
      final u = s[piv];
      s[piv] = s[col];
      s[col] = u;
    }
    final f = gf.inv(a[col][col]);
    for (var t = 0; t < m; t++) {
      a[col][t] = gf.mul(a[col][t], f);
    }
    for (var j = 0; j < ns; j++) {
      s[col][j] = gf.mul(s[col][j], f);
    }
    for (var i = 0; i < m; i++) {
      if (i == col || a[i][col] == 0) continue;
      final c = a[i][col];
      for (var t = 0; t < m; t++) {
        a[i][t] ^= gf.mul(c, a[col][t]);
      }
      for (var j = 0; j < ns; j++) {
        s[i][j] ^= gf.mul(c, s[col][j]);
      }
    }
  }
  for (var i = 0; i < m; i++) {
    final start = bad[i] * ee;
    var n = size - start;
    if (n > ee) n = ee;
    for (var j = 0; j < n; j++) {
      final v = s[i][j >> 1];
      data[start + j] = (j & 1) == 0 ? v & 0xFF : v >> 8;
    }
  }
  return Rar5RepairResult(m, 0);
}

/// Repairs a RAR5 archive or volume held in [archive] in place with its
/// recovery record, like `rar r`: the record is found by the signature
/// and CRC-64 of its blocks (not through the headers, which may be
/// damaged), and gives the size of the protected data. Throws when there
/// is no usable record.
Rar5RepairResult rar5Repair(Uint8List archive) {
  for (var p = archive.length - 64; p >= 0; p--) {
    if (archive[p] != 0x7B || archive[p + 1] != 0x52 ||
        archive[p + 2] != 0x42 || archive[p + 3] != 0x7D) {
      continue;
    }
    final bs = getUint32LE(archive, p + 12);
    if (bs < 72 || p + bs > archive.length) continue;
    final got = (Crc64()..update(archive, p + 12, p + bs)).bytes;
    var ok = true;
    for (var i = 0; i < 8; i++) {
      if (got[i] != archive[p + 4 + i]) ok = false;
    }
    if (!ok) continue;
    final size = getUint64LE(archive, p + 34);
    if (size <= 0 || size > p) continue;
    return rar5RepairWithRecovery(Uint8List.sublistView(archive, 0, size),
        Uint8List.sublistView(archive, size));
  }
  throw const SevenZipException(
      'RAR5: no recovery record found', SevenZipError.data);
}
