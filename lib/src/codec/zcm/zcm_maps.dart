// zcm: the direct and hashed probability maps of paq8px.
//
// Ports of paq8px's StationaryMap, LargeStationaryMap (with the Bucket16
// hash buckets), SmallStationaryContextMap, IndirectContext, MTFList and
// ResidualMap (Zoltan Gotthardt, Marcio Pais, Sebastian Lehmann and the
// paq8px authors). In paq8px the maps are updated through an update
// broadcaster after each bit; here the owning model calls [update] with
// the coded bit before it mixes the next one. All integer arithmetic.

import 'dart:typed_data';

import 'zcm_components.dart';
import 'zcm_tables.dart';

/// paq8px DivisionTable: 2^30 / (n + 2).
final Int32List zcmDt2 = () {
  final t = Int32List(1024);
  for (var n = 0; n < 1024; n++) {
    t[n] = (1 << 30) ~/ (n + 2);
  }
  return t;
}();

/// paq8px StationaryMap: a direct context with exact bit counts (two 16
/// bit counts per bit of a partial byte of [inputBits] bits), 3 inputs.
final class ZcmStationaryMap {
  final Uint32List _t;
  final int _mask, _stride;
  final int scale;
  int _context = 0;
  int _b = 0;
  int _cp = -1;

  ZcmStationaryMap(int bitsOfContext, int inputBits, {this.scale = 64})
      : _t = Uint32List((1 << bitsOfContext) * ((1 << inputBits) - 1)),
        _mask = (1 << bitsOfContext) - 1,
        _stride = (1 << inputBits) - 1;

  static const int inputs = 3;

  /// Sets the context (a direct value, the high bits are dropped).
  @pragma('vm:prefer-inline')
  void set(int ctx) {
    _context = (ctx & _mask) * _stride;
    _b = 0;
  }

  /// Learns bit [y] in the slot of the last [mix].
  @pragma('vm:prefer-inline')
  void update(int y) {
    final cp = _cp;
    if (cp < 0) return;
    final c = _t[cp];
    var n0 = (c >> 16) + 1 - y;
    var n1 = (c & 0xFFFF) + y;
    final shift = (n0 | n1) >> 16;
    n0 >>= shift;
    n1 >>= shift;
    _t[cp] = n0 << 16 | n1;
    _b += (y != 0 && _b > 0) ? 1 : 0;
    _cp = -1;
  }

  @pragma('vm:unsafe:no-bounds-checks')
  void mix(Mixer m) {
    final cp = _context + _b;
    _cp = cp;
    final c = _t[cp];
    final n0 = c >> 16, n1 = c & 0xFFFF;
    final sum = n0 + n1;
    final p1 = ((n1 * 2 + 1) << 12) ~/ (sum * 2 + 2);
    final st = (kStretch[p1] * scale) >> 8;
    final tx = m.tx;
    final k = m.nx;
    tx[k] = st;
    tx[k + 1] = ((p1 - 2048) * scale) >> 9;
    tx[k + 2] = (sum <= 1 || (n0 != 0 && n1 != 0)) ? 0 : st;
    m.nx = k + 3;
    _b += _b + 1;
  }

  /// Adds zero inputs (no context for this bit).
  void skip(Mixer m) {
    _cp = -1;
    final tx = m.tx;
    final k = m.nx;
    tx[k] = 0;
    tx[k + 1] = 0;
    tx[k + 2] = 0;
    m.nx = k + 3;
  }
}

/// paq8px SmallStationaryContextMap: a direct context with a 16 bit
/// probability per bit, adapting at a fixed [rate], 2 inputs.
final class ZcmSmallStationaryMap {
  final Uint16List _t;
  final int _mask, _stride;
  final int rate;
  final int scale;
  int _context = 0;
  int _b = 0;
  int _cp = -1;

  ZcmSmallStationaryMap(int bitsOfContext, int inputBits, this.rate,
      {this.scale = 64})
      : _t = Uint16List((1 << bitsOfContext) * ((1 << inputBits) - 1))
          ..fillRange(0, (1 << bitsOfContext) * ((1 << inputBits) - 1), 0x7FFF),
        _mask = (1 << bitsOfContext) - 1,
        _stride = (1 << inputBits) - 1;

  static const int inputs = 2;

  @pragma('vm:prefer-inline')
  void set(int ctx) {
    _context = (ctx & _mask) * _stride;
    _b = 0;
  }

  @pragma('vm:prefer-inline')
  void update(int y) {
    final cp = _cp;
    if (cp < 0) return;
    final v = _t[cp];
    _t[cp] = v + (((y << 16) - v + (1 << (rate - 1))) >> rate);
    _b += (y != 0 && _b > 0) ? 1 : 0;
    _cp = -1;
  }

  @pragma('vm:unsafe:no-bounds-checks')
  void mix(Mixer m) {
    final cp = _context + _b;
    _cp = cp;
    final p = _t[cp] >> 4;
    final tx = m.tx;
    final k = m.nx;
    tx[k] = (kStretch[p] * scale) >> 8;
    tx[k + 1] = ((p - 2048) * scale) >> 9;
    m.nx = k + 2;
    _b += _b + 1;
  }
}

/// paq8px LargeStationaryMap: hashed contexts in buckets of 7 slots with
/// 16 bit checksums (Bucket16, most recently used first), each a 22 bit
/// probability and a 10 bit count; 3 inputs per context.
final class ZcmLargeStationaryMap {
  static const int _slots = 7;
  final Uint16List _chk;
  final Uint32List _val;
  final int _hashBits;
  final int n;
  final int scale;
  final Int32List _cp; // slot index per context, -1: skipped
  int _k = 0;
  final ZcmRandom _rnd = ZcmRandom();

  ZcmLargeStationaryMap(this.n, int hashBits, {this.scale = 64})
      : _hashBits = hashBits,
        _chk = Uint16List(_slots << hashBits),
        _val = Uint32List(_slots << hashBits),
        _cp = Int32List(n);

  static const int inputsPerContext = 3;

  // Bucket16::find
  @pragma('vm:unsafe:no-bounds-checks')
  int _find(int bucket, int checksum) {
    final chk = _chk;
    final val = _val;
    final b = bucket * _slots;
    if (checksum == 0) checksum = 1;
    if (chk[b] == checksum) return b;
    for (var i = 1; i < _slots; i++) {
      final c = chk[b + i];
      if (c == checksum) {
        final v = val[b + i];
        for (var j = i; j > 0; j--) {
          chk[b + j] = chk[b + j - 1];
          val[b + j] = val[b + j - 1];
        }
        chk[b] = checksum;
        val[b] = v;
        return b;
      }
      if (c == 0) {
        for (var j = i; j > 0; j--) {
          chk[b + j] = chk[b + j - 1];
          val[b + j] = val[b + j - 1];
        }
        chk[b] = checksum;
        val[b] = 0;
        return b;
      }
    }
    // Evict one of the least recently used slots with a low count
    // (the two most recently used ones are kept).
    var minIdx = _slots - 1;
    var rnd = _rnd.next();
    if ((rnd & 63) >= 1) {
      var minPrio = val[b + 6] & 1023;
      var p = val[b + 5] & 1023;
      if (p < minPrio) {
        minPrio = p;
        minIdx = 5;
      }
      rnd >>= 6;
      if ((rnd & 63) >= 4) {
        p = val[b + 4] & 1023;
        if (p < minPrio) {
          minPrio = p;
          minIdx = 4;
        }
        rnd >>= 6;
        if ((rnd & 63) >= 8) {
          p = val[b + 3] & 1023;
          if (p < minPrio) {
            minPrio = p;
            minIdx = 3;
          }
          rnd >>= 6;
          if ((rnd & 63) >= 16) {
            p = val[b + 2] & 1023;
            if (p < minPrio) minIdx = 2;
          }
        }
      }
    }
    for (var j = minIdx; j > 0; j--) {
      chk[b + j] = chk[b + j - 1];
      val[b + j] = val[b + j - 1];
    }
    chk[b] = checksum;
    val[b] = 0;
    return b;
  }

  /// Sets the next context (a 32-bit hash).
  @pragma('vm:prefer-inline')
  void set(int h) {
    h &= 0xFFFFFFFF;
    final bucket = h >> (32 - _hashBits);
    final chk = (h * 0x2F0F3A55 >> 8) & 0xFFFF;
    _cp[_k++] = _find(bucket, chk);
  }

  /// Skips the next context.
  @pragma('vm:prefer-inline')
  void skipContext() {
    _cp[_k++] = -1;
  }

  /// Learns bit [y] in the contexts of the last [mix] and clears them.
  @pragma('vm:unsafe:no-bounds-checks')
  void update(int y) {
    final val = _val;
    final dt = zcmDt2;
    for (var i = 0; i < _k; i++) {
      final cp = _cp[i];
      if (cp < 0) continue;
      final cell = val[cp] ^ 0x80000000;
      final sum = cell & 1023;
      final p1 = cell >> 10;
      final np = p1 + ((((y << 22) - p1) * dt[sum]) >> 30);
      val[cp] = 0x80000000 ^ ((np << 10) | (sum < 1023 ? sum + 1 : sum));
    }
    _k = 0;
  }

  @pragma('vm:unsafe:no-bounds-checks')
  void mix(Mixer m) {
    final val = _val;
    final tx = m.tx;
    var k = m.nx;
    final str = kStretch;
    for (var i = 0; i < _k; i++) {
      final cp = _cp[i];
      if (cp < 0) {
        tx[k] = 0;
        tx[k + 1] = 0;
        tx[k + 2] = 0;
        k += 3;
        continue;
      }
      final cell = val[cp] ^ 0x80000000;
      final p1 = cell >> 20;
      final st = (str[p1] * scale) >> 8;
      tx[k] = st;
      tx[k + 1] = ((p1 - 2048) * scale) >> 9;
      final p22 = cell >> 10;
      final sum = cell & 1023;
      final n1 = ((sum + 1) * p22) >> 22;
      final uncertain = sum <= 1 || (n1 < sum - 1 && n1 != 0);
      tx[k + 2] = uncertain ? 0 : st;
      k += 3;
    }
    m.nx = k;
  }
}

/// paq8px IndirectContext: per context slot the last bits or bytes seen
/// (a history of [contextBits] bits with a leading 1 when shorter than
/// the value type), selected by a direct context of [bitsPerContext] bits.
final class ZcmIndirectContext {
  final Uint32List _t;
  final int _ctxMask;
  final int inputBits;
  final int contextBits;
  final int _valueBits;
  int _ctx = 0;

  /// [valueBits]: 8 or 16 (the C++ value type).
  ZcmIndirectContext(int bitsPerContext, this.inputBits,
      {int valueBits = 8, int? contextBits})
      : _t = Uint32List(1 << bitsPerContext),
        _ctxMask = (1 << bitsPerContext) - 1,
        _valueBits = valueBits,
        contextBits = contextBits ?? valueBits {
    if (this.contextBits < _valueBits) {
      _t.fillRange(0, _t.length, 1);
    }
  }

  /// Shifts [x] into the current slot (operator+=).
  @pragma('vm:prefer-inline')
  void add(int x) {
    final cur = _t[_ctx];
    final lead = cur & (1 << contextBits);
    var v = ((cur << inputBits) | x | lead) & ((1 << (contextBits + 1)) - 1);
    v &= (1 << _valueBits) - 1;
    _t[_ctx] = v;
  }

  /// Selects the slot (operator=).
  @pragma('vm:prefer-inline')
  void select(int i) {
    _ctx = i & _ctxMask;
  }

  /// The value of the current slot (operator()).
  @pragma('vm:prefer-inline')
  int get value => _t[_ctx];
}

/// paq8px MTFList: an order of [n] items, most recently used first.
final class ZcmMtfList {
  final Int32List _prev;
  final Int32List _next;
  int _root = 0;
  int _index = 0;

  ZcmMtfList(int n)
      : _prev = Int32List(n),
        _next = Int32List(n) {
    for (var i = 0; i < n; i++) {
      _prev[i] = i - 1;
      _next[i] = i + 1;
    }
    _next[n - 1] = -1;
  }

  int getFirst() => _index = _root;

  int getNext() {
    if (_index >= 0) _index = _next[_index];
    return _index;
  }

  void moveToFront(int i) {
    _index = i;
    if (i == _root) return;
    final p = _prev[i];
    final n = _next[i];
    if (p >= 0) _next[p] = _next[i];
    if (n >= 0) _prev[n] = _prev[i];
    _prev[_root] = i;
    _next[i] = _root;
    _root = i;
    _prev[_root] = -1;
  }
}

/// paq8px ResidualMap: per context and histogram, the counts of
/// (actual - predicted) byte values as prefix sums; the next bit's
/// probability is the share of the residuals that agree with the bits
/// seen so far and have that bit set. 2 inputs per context.
final class ResidualMap {
  static const int _bins = 256;
  final int n;
  final int histograms;
  final int scale;
  final Uint16List _sums;
  final Int32List _pred;
  final Int32List _base; // -1: skipped
  int _k = 0;
  final Int32List _dt = zcmDt2;

  ResidualMap(this.n, this.histograms, {this.scale = 64})
      : _sums = Uint16List(n * histograms * _bins),
        _pred = Int32List(n),
        _base = Int32List(n);

  int get inputs => n * 2;

  /// Sets the next context: [prediction] of the byte (any int, used mod
  /// 256) and the [histogram] of the context.
  @pragma('vm:prefer-inline')
  void set(int prediction, int histogram) {
    final k = _k;
    _pred[k] = prediction;
    _base[k] = (k * histograms + histogram) * _bins;
    _k = k + 1;
  }

  /// Skips the next context.
  @pragma('vm:prefer-inline')
  void skip() {
    _base[_k++] = -1;
  }

  /// Learns [byte] in every context set for it, then clears the list.
  @pragma('vm:unsafe:no-bounds-checks')
  void update(int byte) {
    final s = _sums;
    for (var i = 0; i < _k; i++) {
      final base = _base[i];
      if (base < 0) continue;
      final bin = (192 + byte - _pred[i]) & 255;
      for (var j = base + bin; j < base + _bins; j++) {
        s[j]++;
      }
      if (s[base + _bins - 1] == 65535) {
        for (var j = base; j < base + _bins; j++) {
          s[j] >>= 1;
        }
      }
    }
    _k = 0;
  }

  /// Adds 2 inputs per context for the next bit.
  @pragma('vm:unsafe:no-bounds-checks')
  void mix(Mixer m, int bpos, int c0) {
    final s = _sums;
    final tx = m.tx;
    var k = m.nx;
    final c1 = (c0 << (8 - bpos)) & 255;
    final range = 1 << (7 - bpos);
    final str = kStretch;
    final dt = _dt;
    final sc = scale;
    for (var i = 0; i < _k; i++) {
      final base = _base[i];
      if (base < 0) {
        tx[k] = 0;
        tx[k + 1] = 0;
        k += 2;
        continue;
      }
      final o0 = (192 + c1 - _pred[i]) & 255;
      final o1 = (o0 + range) & 255;
      int n0, n1;
      if (o0 + range <= _bins) {
        n0 = s[base + o0 + range - 1] - (o0 == 0 ? 0 : s[base + o0 - 1]);
      } else {
        n0 = s[base + _bins - 1] -
            s[base + o0 - 1] +
            s[base + o0 + range - _bins - 1];
      }
      if (o1 + range <= _bins) {
        n1 = s[base + o1 + range - 1] - (o1 == 0 ? 0 : s[base + o1 - 1]);
      } else {
        n1 = s[base + _bins - 1] -
            s[base + o1 - 1] +
            s[base + o1 + range - _bins - 1];
      }
      final sum = n0 + n1;
      var sh = (sum | 1).bitLength - 10;
      if (sh < 0) sh = 0;
      final p1 = ((((n1 >> sh) + 1) << 12) * dt[sum >> sh]) >> 30;
      final pp = p1 < 1 ? 1 : (p1 > 4095 ? 4095 : p1);
      tx[k] = (str[pp] * sc) >> 8;
      tx[k + 1] = ((pp - 2048) * sc) >> 9;
      k += 2;
    }
    m.nx = k;
  }
}
