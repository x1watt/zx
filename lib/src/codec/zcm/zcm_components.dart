// zcm: the building blocks of the models (all integer arithmetic).
//
// Designs from paq8 (Matt Mahoney: StateMap, APM, the hashed ContextMap
// with 64 byte buckets, checksums and run statistics, the two layer
// Mixer), lpaq1 (Matt Mahoney: APM interpolation) and paq8px (Zoltan
// Gotthardt, Marcio Pais and others: a-priori StateMap initialisation,
// the probabilistic state increment, mixer learning rate decay). Rewritten
// in Dart for this codec; the numbers are the same kind of fixed point.

import 'dart:typed_data';

import 'zcm_state_table.dart';
import 'zcm_tables.dart';

/// Deterministic pseudo random bits (a 32-bit xorshift).
final class ZcmRandom {
  int _s = 0x2545F491;

  @pragma('vm:prefer-inline')
  int next() {
    var s = _s;
    s ^= (s << 13) & 0xFFFFFFFF;
    s ^= s >> 17;
    s ^= (s << 5) & 0xFFFFFFFF;
    _s = s;
    return s;
  }
}

/// Next bit history state after bit [y], with the probabilistic increment
/// of paq8px for the long runs (states from 205 advance with p = 1/2).
@pragma('vm:prefer-inline')
int nextState(int s, int y, ZcmRandom rnd) {
  final ns = kNex[(y << 8) | s];
  if (ns >= 205 && ns >= s + 4 && (rnd.next() & 1) != 0) return s;
  return ns;
}

/// A-priori probability (22 bits, in the high bits of a StateMap entry) of
/// a bit history state, from its counts (paq8px StateMap, BitHistory).
int stateInitEntry(int state) {
  var n0 = kStateN0[state];
  var n1 = kStateN1[state];
  if (state < 205) {
    n0 = n0 * 3 + 1;
    n1 = n1 * 3 + 1;
    return (((n1 << 20) ~/ (n0 + n1)) << 12) & 0xFFFFFFFF;
  } else if (state < 253) {
    final inc = (state - 205) >> 2;
    if (((state - 205) & 3) <= 1) {
      n0 = 29 + (1 << inc);
    } else {
      n1 = 29 + (1 << inc);
    }
    n0 = n0 * 3 + 1;
    n1 = n1 * 3 + 1;
    var c = (n0 + n1) >> 3;
    if (c > 1023) c = 1023;
    return ((((n1 << 18) ~/ (n0 + n1)) << 14) | c) & 0xFFFFFFFF;
  }
  return 2048 << 20;
}

/// Updates a StateMap entry (22 bit probability, 10 bit count) with bit
/// [y] (paq8px AdaptiveMap::update).
@pragma('vm:prefer-inline')
int adaptEntry(int e, int y, int limit) {
  final n = e & 1023;
  final p = e >> 10;
  final np = p + ((((y << 22) - p) * kDt[n]) >> 31);
  return (np << 10) | (n < limit ? n + 1 : n);
}

/// Maps a context to a probability, adapting to the bits seen in it.
/// [p] updates the entry of the previous call with the bit then returns
/// the 12 bit prediction for context [cx].
final class StateMap {
  final Uint32List t;
  final int limit;
  int _cx = 0;

  /// [n] contexts. With [bitHistory], context & 255 is a bit history
  /// state and the entries start from the state's counts.
  StateMap(int n, {this.limit = 1023, bool bitHistory = false})
      : t = Uint32List(n) {
    for (var i = 0; i < n; i++) {
      t[i] = bitHistory ? stateInitEntry(i & 255) : (2048 << 20);
    }
  }

  @pragma('vm:prefer-inline')
  int p(int y, int cx) {
    final tt = t;
    tt[_cx] = adaptEntry(tt[_cx], y, limit);
    _cx = cx;
    return tt[cx] >> 20;
  }
}

/// Adaptive probability map (lpaq1 APM): refines a probability in a
/// context by interpolating between 24 buckets of its stretched value.
final class Apm {
  final Uint16List t;
  final int rate;
  int _index = 0;

  Apm(int n, {this.rate = 7}) : t = Uint16List(n * 24) {
    for (var i = 0; i < n * 24; i++) {
      t[i] = squash((i % 24 * 2 + 1) * 4096 ~/ 48 - 2048) * 16;
    }
  }

  /// Updates with bit [y], then refines [pr] in context [cx] (12 bits).
  @pragma('vm:prefer-inline')
  int pp(int y, int pr, int cx) => pp16(y, pr, cx) >> 4;

  /// As [pp] with a 16 bit result.
  @pragma('vm:prefer-inline')
  int pp16(int y, int pr, int cx) {
    final tt = t;
    final g = (y << 16) + (y << rate) - y - y;
    tt[_index] += (g - tt[_index]) >> rate;
    final s = (kStretch[pr] + 2048) * 23;
    final wt = s & 0xFFF;
    final base = cx * 24 + (s >> 12);
    _index = base + (wt >> 11);
    return (tt[base] * (4096 - wt) + tt[base + 1] * wt) >> 12;
  }
}

/// paq8px APM: [n] contexts of [steps] buckets over the stretched
/// probability, each a 22 bit probability with a count (AdaptiveMap), the
/// nearer bucket updated with a rate that slows down to 1/[limit].
final class ApmPx {
  final Uint32List t;
  final int steps;
  final int limit;
  final int _n;
  int _cxt = 0;

  ApmPx(int n, this.steps, {this.limit = 1023})
      : t = Uint32List(n * steps),
        _n = n * steps {
    for (var i = 0; i < _n; i++) {
      final p = ((i % steps * 2 + 1) * 4096) ~/ (steps * 2) - 2048;
      t[i] = (squash(p) << 20) + 6;
    }
  }

  /// Updates with bit [y], then refines [pr] (12 bits) in context [cx];
  /// the result has 16 bits.
  @pragma('vm:unsafe:no-bounds-checks')
  int pp(int y, int pr, int cx) {
    final tt = t;
    final e = tt[_cxt];
    final n = e & 1023;
    final p = e >> 10;
    tt[_cxt] = ((p + ((((y << 22) - p) * kDt[n]) >> 31)) << 10) |
        (n < limit ? n + 1 : n);
    final s = (kStretch[pr] + 2048) * (steps - 1);
    final wt = s & 0xFFF;
    final base = cx * steps + (s >> 12);
    _cxt = base + (wt >> 11);
    return ((tt[base] >> 13) * (4096 - wt) + (tt[base + 1] >> 13) * wt) >> 15;
  }
}

/// paq8px APM1: [n] contexts of 33 buckets over the stretched
/// probability, both neighbours updated at a fixed [rate].
final class Apm1 {
  final Uint16List t;
  final int rate;
  int _index = 0;

  Apm1(int n, this.rate) : t = Uint16List(n * 33) {
    for (var i = 0; i < n; i++) {
      for (var j = 0; j < 33; j++) {
        t[i * 33 + j] = squash((j - 16) * 128) * 16;
      }
    }
  }

  /// Updates with bit [y], then refines [pr] (12 bits) in context [cx];
  /// the result has 16 bits.
  @pragma('vm:unsafe:no-bounds-checks')
  int pp(int y, int pr, int cx) {
    final tt = t;
    final g = (y << 16) + (y << rate) - y - y;
    final i = _index;
    tt[i] += (g - tt[i]) >> rate;
    tt[i + 1] += (g - tt[i + 1]) >> rate;
    final s = kStretch[pr];
    final w = s & 127;
    _index = ((s + 2048) >> 7) + cx * 33;
    return (tt[_index] * (128 - w) + tt[_index + 1] * w) >> 7;
  }
}

/// paq8px APMPost: bit counts per ([n] contexts, 12 bit probability),
/// starting from the identity; gives a 16 bit probability.
final class ApmPost {
  final Uint32List _n0;
  final Uint32List _n1;
  int _index = 0;

  ApmPost(int n)
      : _n0 = Uint32List(n * 4096),
        _n1 = Uint32List(n * 4096) {
    for (var i = 0; i < n; i++) {
      for (var j = 0; j < 4096; j++) {
        _n0[i * 4096 + j] = (4096 - j) >> 1;
        _n1[i * 4096 + j] = j >> 1;
      }
    }
  }

  /// Updates with bit [y], then maps [pr] (12 bits) in context [cx].
  @pragma('vm:unsafe:no-bounds-checks')
  int pp(int y, int pr, int cx) {
    final i = _index;
    var n0 = _n0[i] + 1 - y;
    var n1 = _n1[i] + y;
    if (n0 >= 0xFFFFFFFF || n1 >= 0xFFFFFFFF) {
      n0 >>= 1;
      n1 >>= 1;
    }
    _n0[i] = n0;
    _n1[i] = n1;
    final j = cx * 4096 + pr;
    _index = j;
    final a = _n0[j] * 2 + 1;
    final b = _n1[j] * 2 + 1;
    return (b << 16) ~/ (a + b);
  }
}

/// Neural network mixer (paq8 Mixer): [n] inputs in the stretched domain,
/// several weight sets selected by contexts, and when more than one set is
/// selected, a second layer that mixes their outputs.
///
/// Weights are 16.16 fixed point; the learning rate decays from [rateMax]
/// to [rateMin] (16.16) as in paq8px.
final class Mixer {
  final int n;
  final Int32List tx;
  int nx = 0;
  final Int32List wx;
  final Int32List _base; // first weight index of each selector's range
  final Int32List _sizes; // contexts of each selector
  final Int32List _sel; // selected weight offset per selector
  final Int32List _st; // stretched output per selector
  final Int32List _pr; // squashed output per selector
  final int nSel;
  int _k = 0; // selectors set so far
  final Int32List _nzi; // indices of the nonzero inputs
  int _nz = 0;
  // Second layer.
  final Int32List _fw;
  int _fsel = 0;
  final int finalContexts;
  int _fpr = 2048;
  int _rate;
  final int rateMin;
  int _frate;
  final int _frateMin;
  final int shift;
  final Int16List _sq = kSquash;
  late final int _stride = (n + 3) & ~3;
  final int _errLim = 4;

  /// [sizes] gives the number of contexts of each selector.
  Mixer(this.n, List<int> sizes,
      {this.finalContexts = 1,
      int rateMax = 56 << 16,
      this.rateMin = 14 << 16,
      int finalRate = 56 << 16,
      int finalRateMin = 14 << 16,
      this.shift = 16,
      int initWeight = 1 << 14})
      : tx = Int32List(n + 4),
        _nzi = Int32List(n + 4),
        nSel = sizes.length,
        _base = Int32List(sizes.length),
        _sizes = Int32List.fromList(sizes),
        _sel = Int32List(sizes.length),
        _st = Int32List(sizes.length),
        _pr = Int32List(sizes.length),
        wx = Int32List(((n + 3) & ~3) * sizes.fold<int>(0, (a, b) => a + b)),
        _fw = Int32List(sizes.length * finalContexts),
        _rate = rateMax,
        _frate = finalRate,
        _frateMin = finalRateMin {
    var b = 0;
    for (var i = 0; i < sizes.length; i++) {
      _base[i] = b;
      b += sizes[i] * _stride;
    }
    wx.fillRange(0, wx.length, initWeight);
    _fw.fillRange(0, _fw.length, 65536 ~/ sizes.length);
  }

  @pragma('vm:prefer-inline')
  void add(int x) {
    assert(nx < n, 'mixer inputs');
    tx[nx++] = x;
  }

  /// Selects context [cx] of the next selector.
  @pragma('vm:prefer-inline')
  void set(int cx) {
    assert(_k < nSel && cx >= 0 && cx < _sizes[_k], 'selector $_k: $cx');
    _sel[_k] = _base[_k] + cx * _stride;
    _k++;
  }

  /// Selects the weight set of the second layer.
  void setFinal(int cx) {
    _fsel = cx * nSel;
  }

  /// Output of the mixer (12 bits).
  @pragma('vm:unsafe:no-bounds-checks')
  int p() {
    final k = _k;
    final t = tx;
    final nxl = nx;
    // The nonzero inputs (many are zero: contexts not seen yet, no
    // match): the dot products and the training skip the others.
    final nzi = _nzi;
    var nz = 0;
    for (var i = 0; i < nxl; i++) {
      nzi[nz] = i;
      nz += t[i] != 0 ? 1 : 0;
    }
    _nz = nz;
    final w = wx;
    final sq = _sq;
    // Two weight sets per pass (integer sums, so the order of the
    // additions does not change the result).
    var s = 0;
    for (; s + 1 < k; s += 2) {
      final o0 = _sel[s];
      final o1 = _sel[s + 1];
      var a0 = 0, b0 = 0;
      for (var j = 0; j < nz; j++) {
        final i = nzi[j];
        final x = t[i];
        a0 += x * w[o0 + i];
        b0 += x * w[o1 + i];
      }
      var dot = a0 >> shift;
      if (dot > 2047) dot = 2047;
      if (dot < -2047) dot = -2047;
      _st[s] = dot;
      _pr[s] = sq[dot + 2048];
      dot = b0 >> shift;
      if (dot > 2047) dot = 2047;
      if (dot < -2047) dot = -2047;
      _st[s + 1] = dot;
      _pr[s + 1] = sq[dot + 2048];
    }
    if (s < k) {
      final o = _sel[s];
      var d0 = 0;
      for (var j = 0; j < nz; j++) {
        final i = nzi[j];
        d0 += t[i] * w[o + i];
      }
      var dot = d0 >> shift;
      if (dot > 2047) dot = 2047;
      if (dot < -2047) dot = -2047;
      _st[s] = dot;
      _pr[s] = sq[dot + 2048];
    }
    if (k == 1) return _pr[0];
    var dot = 0;
    final fo = _fsel;
    for (var s = 0; s < k; s++) {
      dot += _st[s] * _fw[fo + s];
    }
    dot >>= 16;
    if (dot > 2047) dot = 2047;
    if (dot < -2047) dot = -2047;
    return _fpr = sq[dot + 2048];
  }

  /// Trains the weights used by the last [p] with bit [y] and clears the
  /// inputs for the next bit. Weights are stored in 32 bits (a weight that
  /// would overflow wraps the same way everywhere, so the output stays
  /// deterministic).
  @pragma('vm:unsafe:no-bounds-checks')
  void update(int y) {
    final k = _k;
    final t = tx;
    final w = wx;
    final target = y << 12;
    final rate = _rate;
    final lim = _errLim;
    final nzi = _nzi;
    final nz = _nz;
    for (var s = 0; s < k; s++) {
      final err0 = target - _pr[s];
      if (err0 > -lim && err0 < lim) continue;
      final err = (err0 * rate) >> 16;
      final o = _sel[s];
      for (var j = 0; j < nz; j++) {
        final i = nzi[j];
        w[o + i] += (t[i] * err) >> 16;
      }
    }
    if (rate > rateMin) _rate = rate - 1;
    if (k > 1) {
      final err0 = target - _fpr;
      if (err0 <= -lim || err0 >= lim) {
        final err = (err0 * _frate) >> 16;
        final fo = _fsel;
        for (var s = 0; s < k; s++) {
          _fw[fo + s] += (_st[s] * err) >> 16;
        }
      }
      if (_frate > _frateMin) _frate--;
    }
    nx = 0;
    _k = 0;
  }
}

// Bit 0: the state has no zeros, bit 1: no ones.
final Uint8List _zeroCounts = () {
  final t = Uint8List(256);
  for (var i = 0; i < 256; i++) {
    t[i] = (kStateN0[i] == 0 ? 1 : 0) | (kStateN1[i] == 0 ? 2 : 0);
  }
  return t;
}();

/// Hashed context map (paq8 ContextMap): for each of [nCtx] contexts set
/// per byte, a bit history state for every bit of the next byte, kept in
/// 64 byte buckets (7 slots of 7 states with 16 bit checksums), and the
/// run statistics (last byte seen in the context and how often in a row).
///
/// Mixer inputs per context: 5 with [rich], else 3, plus 1 run input.
/// With [bh] (paq8px ContextMap2 style), the slot also keeps the last 3
/// distinct bytes of the context: the run input comes from an adaptive
/// run map and 2 inputs predict from the byte history. A context can be
/// skipped for a byte ([skip], paq8px ContextMap2::skip): its inputs are
/// zero and nothing is learned from it.
final class ContextMap {
  final Uint8List t;
  final int _mask; // bucket index mask
  final int _dummy; // 64 spare bytes after the table
  final int nCtx;
  final bool rich;
  final bool bh;
  final Uint32List _runSm;
  final Int32List _runIdx;
  final Uint32List _bh8;
  final Uint32List _bh12;
  final Int32List _bh8Idx;
  final Int32List _bh12Idx;
  final Uint8List _group = kStateGroup;
  final Int32List _cxt; // context hashes of this byte
  final Uint8List _skip; // 1: skipped for this byte
  final Int32List _cp; // offset of the current state byte, -1 when none
  final Int32List _cp0; // offset of the current slot
  final Int32List _runp; // offset of the run bytes (count, byte)
  final Uint32List _sm; // StateMaps, 256 entries per context
  final Int32List _smIdx;
  final Int32List _stv; // state of the next bit per context, -1: skipped
  final ZcmRandom _rnd = ZcmRandom();
  final Uint8List _nex = kNex;
  final Int32List _dt = kDt;
  final Int16List _str = kStretch;
  final Uint8List _ilog = kIlog;
  final Uint8List _zz = _zeroCounts;

  /// Inputs added to the mixer per context.
  int get inputsPerContext => (rich ? 6 : 4) + (bh ? 2 : 0);

  /// Contexts that had a bit history for the last predicted bit.
  int hits = 0;

  ContextMap(int bytes, this.nCtx, {this.rich = true, this.bh = false})
      : _runSm = Uint32List(bh ? nCtx * 4096 : 0),
        _runIdx = Int32List(nCtx)..fillRange(0, nCtx, -1),
        _bh8 = Uint32List(bh ? nCtx * 256 + 1 : 0)
          ..fillRange(0, bh ? nCtx * 256 + 1 : 0, 2048 << 20),
        _bh12 = Uint32List(bh ? nCtx * 4096 + 1 : 0)
          ..fillRange(0, bh ? nCtx * 4096 + 1 : 0, 2048 << 20),
        _bh8Idx = Int32List(nCtx),
        _bh12Idx = Int32List(nCtx),
        t = Uint8List((bytes < 64 ? 64 : floorPow2(bytes)) + 64),
        _mask = (bytes < 64 ? 64 : floorPow2(bytes)) ~/ 64 - 1,
        _dummy = bytes < 64 ? 64 : floorPow2(bytes),
        _cxt = Int32List(nCtx),
        _skip = Uint8List(nCtx),
        _cp = Int32List(nCtx)..fillRange(0, nCtx, -1),
        _cp0 = Int32List(nCtx),
        _runp = Int32List(nCtx),
        _sm = Uint32List(nCtx * 256 + 1),
        _smIdx = Int32List(nCtx),
        _stv = Int32List(nCtx) {
    for (var i = 0; i < _sm.length; i++) {
      _sm[i] = stateInitEntry(i & 255);
    }
    // Run map a-priori (paq8px StateMap, Run).
    for (var i = 0; i < _runSm.length; i++) {
      final cx = i & 4095;
      final bit = cx & 1;
      final unc = (cx >> 1) & 1;
      final rc = cx >> 4;
      var n0 = unc + 1;
      var n1 = (rc + 1) * 12;
      if (bit == 0) {
        final x = n0;
        n0 = n1;
        n1 = x;
      }
      _runSm[i] = ((((n1 << 20) ~/ (n0 + n1)) << 12) | 127) & 0xFFFFFFFF;
    }
    for (var i = 0; i < nCtx; i++) {
      _bh8Idx[i] = i * 256;
      _bh12Idx[i] = i * 4096;
      _smIdx[i] = i * 256;
      // Point the run bytes at a harmless location until the first set.
      _runp[i] = _dummy + 3;
    }
  }

  /// Sets context [i] for the next byte (call at the start of a byte,
  /// before [mix]).
  @pragma('vm:prefer-inline')
  void set(int i, int cx) {
    _cxt[i] = hash2(cx, i) & 0xFFFFFFFF;
    _skip[i] = 0;
  }

  /// Skips context [i] for the next byte.
  @pragma('vm:prefer-inline')
  void skip(int i) {
    _skip[i] = 1;
  }

  // ContextMap::E::get: the slot of checksum [chk] in bucket [b] (an
  // offset), replacing the least valuable slot when absent.
  @pragma('vm:unsafe:no-bounds-checks')
  int _get(int b, int chk) {
    final tt = t;
    final last = tt[b + 14];
    final li = last & 15;
    if (li < 7 && (tt[b + li * 2] | (tt[b + li * 2 + 1] << 8)) == chk) {
      return b + 15 + li * 7;
    }
    var best = 0x7FFFFFFF;
    var bi = 0;
    for (var i = 0; i < 7; i++) {
      if ((tt[b + i * 2] | (tt[b + i * 2 + 1] << 8)) == chk) {
        tt[b + 14] = ((last << 4) | i) & 0xFF;
        return b + 15 + i * 7;
      }
      final pri = kStatePrio[tt[b + 15 + i * 7]];
      if (pri < best && li != i && (last >> 4) != i) {
        best = pri;
        bi = i;
      }
    }
    tt[b + 14] = 0xF0 | bi;
    tt[b + bi * 2] = chk & 255;
    tt[b + bi * 2 + 1] = chk >> 8;
    final s = b + 15 + bi * 7;
    for (var j = 0; j < 7; j++) {
      tt[s + j] = 0;
    }
    return s;
  }

  // Updates the run and byte history maps of context [i] with the last
  // bit (bh mode).
  @pragma('vm:unsafe:no-bounds-checks')
  void _updateBh(int i, int target) {
    final dt = _dt;
    final ri = _runIdx[i];
    if (ri >= 0) {
      final e = _runSm[ri];
      final en = e & 1023;
      final ep = e >> 10;
      _runSm[ri] = ((ep + (((target - ep) * dt[en]) >> 31)) << 10) |
          (en < 127 ? en + 1 : en);
    }
    final i8 = _bh8Idx[i];
    var e = _bh8[i8];
    var en = e & 1023;
    var ep = e >> 10;
    _bh8[i8] = ((ep + (((target - ep) * dt[en]) >> 31)) << 10) |
        (en < 1023 ? en + 1 : en);
    final i12 = _bh12Idx[i];
    e = _bh12[i12];
    en = e & 1023;
    ep = e >> 10;
    _bh12[i12] = ((ep + (((target - ep) * dt[en]) >> 31)) << 10) |
        (en < 1023 ? en + 1 : en);
  }

  // The run and byte history inputs of the bh mode (paq8px ContextMap2).
  @pragma('vm:unsafe:no-bounds-checks')
  int _mixBh(Int32List tx, int k, int i, int rp, int rc, int rb, int st,
      int bpos, int c0) {
    final tt = t;
    final str = _str;
    final b2 = tt[rp + 2];
    final b3 = tt[rp + 3];
    final unc = (st != 0 && _zz[st] == 0) ? 1 : 0;
    // Run input.
    var nri = -1;
    var sh = 0;
    if (rc != 0) {
      final sft = 8 - bpos;
      if (((rb + 256) >> sft) == c0) {
        final bit = (rb >> (7 - bpos)) & 1;
        final u1 = b2 != rb ? 1 : 0;
        final bp = (0x33322210 >> (bpos << 2)) & 15;
        final r = rc >> 1;
        nri = i * 4096 + ((r > 255 ? 255 : r) << 4 | bp << 2 | u1 << 1 | bit);
        sh = 1 + u1;
      } else if (((b2 + 256) >> sft) == c0) {
        final bit = (b2 >> (7 - bpos)) & 1;
        final u2 = b3 != b2 ? 1 : 0;
        nri = i * 4096 + (unc << 1 | bit);
        sh = 2 + u2;
      }
    }
    _runIdx[i] = nri;
    tx[k++] = nri >= 0 ? str[_runSm[nri] >> 20] >> sh : 0;
    // Byte history inputs.
    final sb = 7 - bpos;
    final bits =
        ((rb >> sb) & 1) | ((b2 >> sb) & 1) << 1 | ((b3 >> sb) & 1) << 2;
    final bhs = rc == 0 ? 0 : (8 | bits);
    final i8 = i * 256 + (unc << 7 | bhs << 3 | bpos);
    final i12 = i * 4096 + (_group[st] << 7 | bhs << 3 | bpos);
    _bh8Idx[i] = i8;
    _bh12Idx[i] = i12;
    tx[k] = str[_bh8[i8] >> 20] >> 2;
    tx[k + 1] = str[_bh12[i12] >> 20] >> 2;
    return k + 2;
  }

  /// Updates with the last bit ([y]) and adds the predictions for the next
  /// bit. [bpos] is the position of the next bit (0 = first bit of a
  /// byte), [c0] the bits of the byte so far with a leading 1, [c1] the
  /// last whole byte.
  void mix(Mixer m, int y, int bpos, int c0, int c1) {
    _advance(y, bpos, c0, c1);
    if (bh) {
      _inputsBh(m, bpos, c0);
    } else {
      _inputs(m, bpos, c0);
    }
  }

  // Learns the last bit and finds the state of the next one in each
  // context (the state goes to _stv, -1 for a skipped context).
  @pragma('vm:unsafe:no-bounds-checks')
  void _advance(int y, int bpos, int c0, int c1) {
    final tt = t;
    final sm = _sm;
    final cpL = _cp;
    final cp0L = _cp0;
    final runpL = _runp;
    final smIdx = _smIdx;
    final stv = _stv;
    final nex = _nex;
    final dt = _dt;
    final n = nCtx;
    final yy = y << 8;
    final target = y << 22;
    // 0: new slot, 1: states 1-2 of the slot, 2: states 3-6.
    final mode = (bpos == 1 || bpos == 3 || bpos == 6)
        ? 1
        : ((bpos == 4 || bpos == 7) ? 2 : 0);
    for (var i = 0; i < n; i++) {
      // Update the bit history and its StateMap entry with the last bit.
      var cp = cpL[i];
      if (cp >= 0) {
        final s0 = tt[cp];
        final ns = nex[yy | s0];
        tt[cp] = (ns >= 205 && ns >= s0 + 4 && (_rnd.next() & 1) != 0)
            ? s0
            : ns;
      }
      final si = smIdx[i];
      final e = sm[si];
      final en = e & 1023;
      final ep = e >> 10;
      sm[si] = ((ep + (((target - ep) * dt[en]) >> 31)) << 10) |
          (en < 1023 ? en + 1 : en);
      if (bh) _updateBh(i, target);
      if (bpos == 0) {
        // Run count of the previous byte's context.
        final rp = runpL[i];
        final rc = tt[rp];
        if (rc == 0) {
          tt[rp] = 2;
          tt[rp + 1] = c1;
          tt[rp + 2] = c1;
          tt[rp + 3] = c1;
        } else if (tt[rp + 1] != c1) {
          tt[rp] = 1;
          tt[rp + 3] = tt[rp + 2];
          tt[rp + 2] = tt[rp + 1];
          tt[rp + 1] = c1;
        } else if (rc < 254) {
          tt[rp] = rc + 2;
        } else if (rc == 255) {
          tt[rp] = 128;
        }
        if (_skip[i] != 0) {
          // Nothing for this byte.
          smIdx[i] = n << 8;
          if (bh) {
            _runIdx[i] = -1;
            _bh8Idx[i] = n << 8;
            _bh12Idx[i] = n << 12;
          }
          cpL[i] = -1;
          runpL[i] = _dummy + 3;
          tt[_dummy + 3] = 0;
          stv[i] = -1;
          continue;
        }
      } else if (stv[i] < 0) {
        continue;
      }
      // Find the state of the next bit.
      if (mode == 1) {
        cp = cp0L[i] + 1 + (c0 & 1);
      } else if (mode == 2) {
        cp = cp0L[i] + 3 + (c0 & 3);
      } else {
        final cx = _cxt[i];
        final chk = (cx >> 16) & 0xFFFF;
        final s = _get(((cx + c0) & _mask) << 6, chk);
        cp0L[i] = cp = s;
        if (bpos == 0) {
          // Complete the pending bit histories of the second occurrence.
          if (tt[s + 3] == 2) {
            final c = tt[s + 4] + 256;
            var p = _get(((cx + (c >> 6)) & _mask) << 6, chk);
            tt[p] = 1 + ((c >> 5) & 1);
            tt[p + 1 + ((c >> 5) & 1)] = 1 + ((c >> 4) & 1);
            tt[p + 3 + ((c >> 4) & 3)] = 1 + ((c >> 3) & 1);
            p = _get(((cx + (c >> 3)) & _mask) << 6, chk);
            tt[p] = 1 + ((c >> 2) & 1);
            tt[p + 1 + ((c >> 2) & 1)] = 1 + ((c >> 1) & 1);
            tt[p + 3 + ((c >> 1) & 3)] = 1 + (c & 1);
          }
          runpL[i] = s + 3;
        }
      }
      if (bpos > 1 && tt[runpL[i]] == 0) cp = -1;
      cpL[i] = cp;
      final st = cp >= 0 ? tt[cp] : 0;
      stv[i] = st;
      smIdx[i] = (i << 8) | st;
    }
  }

  // The inputs of the plain mode: a run input and 3 or 5 from the state.
  @pragma('vm:unsafe:no-bounds-checks')
  void _inputs(Mixer m, int bpos, int c0) {
    final tt = t;
    final sm = _sm;
    final runpL = _runp;
    final stv = _stv;
    final str = _str;
    final ilog = _ilog;
    final zz = _zz;
    final tx = m.tx;
    var k = m.nx;
    final n = nCtx;
    final isRich = rich;
    final per = isRich ? 6 : 4;
    final sh = 8 - bpos;
    final bsh = 7 - bpos;
    var hit = 0;
    for (var i = 0; i < n; i++) {
      final st = stv[i];
      if (st <= 0) {
        if (st < 0) {
          for (var j = 0; j < per; j++) {
            tx[k + j] = 0;
          }
          k += per;
          continue;
        }
      }
      // Predict from the last byte in the context.
      final rp = runpL[i];
      final rb = tt[rp + 1];
      if (((rb + 256) >> sh) == c0) {
        final rc = tt[rp];
        final c = ilog[rc + 1] << (2 + (~rc & 1));
        tx[k] = ((rb >> bsh) & 1) != 0 ? c : -c;
      } else {
        tx[k] = 0;
      }
      if (st == 0) {
        tx[k + 1] = 0;
        tx[k + 2] = 0;
        tx[k + 3] = 0;
        if (isRich) {
          tx[k + 4] = 0;
          tx[k + 5] = 0;
        }
      } else {
        hit++;
        final p1 = sm[(i << 8) | st] >> 20;
        final s1 = str[p1] >> 2;
        final z = zz[st];
        // paq8px ContextMap2 inputs: the stretched probability (halved
        // for the youngest states), the linear one, the stretched one
        // again when only one bit value was seen, and that case as a
        // linear confidence.
        tx[k + 1] = st <= 2 ? s1 >> 1 : s1;
        tx[k + 2] = (p1 - 2048) >> 3;
        tx[k + 3] = z != 0 ? s1 : 0;
        if (isRich) {
          final z0 = -(z & 1);
          final z1 = -(z >> 1);
          tx[k + 4] = ((p1 & z0) - ((4095 - p1) & z1)) >> 4;
          tx[k + 5] = z == 0 ? s1 : 0;
        }
      }
      k += per;
    }
    m.nx = k;
    hits = hit;
  }

  // The inputs of the bh mode: run, byte history and 3 or 5 from the state.
  @pragma('vm:unsafe:no-bounds-checks')
  void _inputsBh(Mixer m, int bpos, int c0) {
    final sm = _sm;
    final runpL = _runp;
    final stv = _stv;
    final str = _str;
    final zz = _zz;
    final tx = m.tx;
    var k = m.nx;
    final n = nCtx;
    final isRich = rich;
    final per = inputsPerContext;
    var hit = 0;
    for (var i = 0; i < n; i++) {
      final st = stv[i];
      if (st < 0) {
        for (var j = 0; j < per; j++) {
          tx[k + j] = 0;
        }
        k += per;
        continue;
      }
      final rp = runpL[i];
      k = _mixBh(tx, k, i, rp, t[rp], t[rp + 1], st, bpos, c0);
      if (st == 0) {
        tx[k] = 0;
        tx[k + 1] = 0;
        tx[k + 2] = 0;
        k += 3;
        if (isRich) {
          tx[k] = 0;
          tx[k + 1] = 0;
          k += 2;
        }
      } else {
        hit++;
        final p1 = sm[(i << 8) | st] >> 20;
        final s1 = str[p1] >> 2;
        final z = zz[st];
        tx[k] = st <= 2 ? s1 >> 1 : s1;
        tx[k + 1] = (p1 - 2048) >> 3;
        tx[k + 2] = z != 0 ? s1 : 0;
        k += 3;
        if (isRich) {
          final z0 = -(z & 1);
          final z1 = -(z >> 1);
          tx[k] = ((p1 & z0) - ((4095 - p1) & z1)) >> 4;
          tx[k + 1] = z == 0 ? s1 : 0;
          k += 2;
        }
      }
    }
    m.nx = k;
    hits = hit;
  }
}

/// Direct context to bit history map for small contexts (order 0 to 2):
/// one state per (context, partial byte), and a StateMap per map.
final class DirectMap {
  final Uint8List t;
  final int _mask;
  final Uint32List _sm;
  int _smi = 0;
  int _cp = 0;
  int _base = 0;
  final ZcmRandom _rnd = ZcmRandom();

  /// [bits] of context (the table has 2^bits * 256 states).
  DirectMap(int bits)
      : t = Uint8List((1 << bits) * 256),
        _mask = (1 << bits) - 1,
        _sm = Uint32List(256 * 256) {
    for (var i = 0; i < _sm.length; i++) {
      _sm[i] = stateInitEntry(i & 255);
    }
  }

  /// Sets the context for the next byte.
  void set(int cx) {
    _base = (cx & _mask) << 8;
  }

  /// Updates with [y] and adds 2 inputs for the bit after [c0].
  @pragma('vm:prefer-inline')
  void mix(Mixer m, int y, int c0) {
    final tt = t;
    tt[_cp] = nextState(tt[_cp], y, _rnd);
    final cp = _base | c0;
    _cp = cp;
    final st = tt[cp];
    final sm = _sm;
    sm[_smi] = adaptEntry(sm[_smi], y, 1023);
    // The StateMap context: the state and the bit position group.
    _smi = (c0 << 8) | st;
    final p1 = sm[_smi] >> 20;
    final s1 = kStretch[p1];
    m.add(s1 >> 2);
    m.add(st == 0 ? 0 : (p1 - 2048) >> 3);
  }
}

/// A direct adaptive probability per context (no bit history), for small
/// contexts where the counts themselves are the best model.
final class DirectProbMap {
  final Uint32List t;
  final int _mask;
  final int limit;
  int _cx = 0;

  DirectProbMap(int bits, {this.limit = 255})
      : t = Uint32List(1 << bits)..fillRange(0, 1 << bits, 2048 << 20),
        _mask = (1 << bits) - 1;

  @pragma('vm:prefer-inline')
  int p(int y, int cx) {
    final tt = t;
    tt[_cx] = adaptEntry(tt[_cx], y, limit);
    _cx = cx & _mask;
    return tt[_cx] >> 20;
  }
}
