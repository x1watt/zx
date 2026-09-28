// zcm: paq8px's audio models (Audio8BitModel and Audio16BitModel), the
// audio model of levels 7 to 9.
//
// A port of paq8px's model/Audio16BitModel.cpp, model/Audio8BitModel.cpp,
// model/AudioModel.cpp, OLS and LMS, with the audio SSE stage of SSE.cpp
// in zcm_predictor.dart. Credits: Marcio Pais (the audio models, after
// Florin Ghido's 'An asymptotically optimal predictor for stereo lossless
// audio compression'), Sebastian Lehmann (OLS and LMS), Zoltan Gotthardt
// and the other paq8px authors (tuning, the residual maps).
//
// Per sample and channel: eight least squares fits over sparse taps of
// the previous samples of the channel and of the other one (the exact
// tap patterns of paq8px), three LMS filters with RMSprop steps and three
// polynomial extrapolations. Every predictor gives two predictions: its
// own and its own plus its last residual on the other channel (the stereo
// decorrelation of paq8px). 16-bit samples: four stationary maps per
// predictor in contexts of the residual between the prediction and the
// bits known so far; 8-bit samples: four residual histograms per
// predictor (paq8px ResidualMap) selected by the recent coding loss and
// the recent errors of the predictor.
//
// Differences from paq8px: doubles instead of floats (OLS of the 8-bit
// model, LMS), and the reciprocal square root of the LMS steps is a
// deterministic Newton iteration from a bit pattern, so every machine
// computes the same predictions (doubles with +, -, *, / only).

import 'dart:typed_data';

import 'zcm_components.dart';
import 'zcm_maps.dart';
import 'zcm_models.dart';
import 'zcm_tables.dart';

final Float64List _rf = Float64List(1);
final Int64List _ri = Int64List.view(_rf.buffer);

/// 1 / sqrt(x) for x > 0: a bit pattern start and three Newton steps
/// (relative error below 1e-12), deterministic.
@pragma('vm:prefer-inline')
double _rsqrt(double x) {
  _rf[0] = x;
  _ri[0] = 0x5FE6EB50C7B537A9 - (_ri[0] >> 1);
  var y = _rf[0];
  final h = 0.5 * x;
  y = y * (1.5 - h * y * y);
  y = y * (1.5 - h * y * y);
  y = y * (1.5 - h * y * y);
  return y;
}

/// 1 / sqrt(x) for x > 0 with two Newton steps (relative error below
/// 1e-5), for the LMS steps.
@pragma('vm:prefer-inline')
double _rsqrtLms(double x) {
  _rf[0] = x;
  _ri[0] = 0x5FE6EB50C7B537A9 - (_ri[0] >> 1);
  var y = _rf[0];
  final h = 0.5 * x;
  y = y * (1.5 - h * y * y);
  return y * (1.5 - h * y * y);
}

@pragma('vm:prefer-inline')
int _ilog2(int x) => x <= 0 ? 0 : x.bitLength - 1;

int _bitCount(int v) {
  var c = 0;
  while (v != 0) {
    v &= v - 1;
    c++;
  }
  return c;
}

/// paq8px OLS: exponentially forgetting least squares over [n] features,
/// solved by Cholesky factorization every [interval] updates. Rows are
/// padded to an even length and processed two doubles at a time
/// (Float64x2: the same IEEE operations per lane on every machine).
final class _Ols {
  final int n;
  final int np; // n rounded up to even
  final int interval;
  final double lambda;
  static const double _nu = 0.001;
  final Float64List x; // np, the padding stays 0
  final Float64List w;
  final Float64List c; // lower triangle, rows of np
  final Float64List b;
  final Float64List l;
  final Float64x2List _x2, _c2, _l2;
  int _since = 0;

  factory _Ols(int n, int interval, double lambda) {
    final np = (n + 1) & ~1;
    return _Ols._(n, np, interval, lambda, Float64List(np), Float64List(n * np),
        Float64List(n * np));
  }

  _Ols._(this.n, this.np, this.interval, this.lambda, this.x, this.c, this.l)
      : w = Float64List(n),
        b = Float64List(n),
        _x2 = Float64x2List.view(x.buffer),
        _c2 = Float64x2List.view(c.buffer),
        _l2 = Float64x2List.view(l.buffer);

  @pragma('vm:unsafe:no-bounds-checks')
  double predict() {
    var s = 0.0;
    for (var i = 0; i < n; i++) {
      s += w[i] * x[i];
    }
    return s;
  }

  @pragma('vm:unsafe:no-bounds-checks')
  void update(double y) {
    final a = lambda;
    final be = 1.0 - lambda;
    final a2 = Float64x2.splat(a);
    final xx = x, x2 = _x2, c2 = _c2;
    final h = np >> 1;
    for (var i = 0; i < n; i++) {
      final xb = Float64x2.splat(be * xx[i]);
      final r = i * h;
      final e = i >> 1;
      for (var j = 0; j <= e; j++) {
        c2[r + j] = c2[r + j] * a2 + x2[j] * xb;
      }
      b[i] = a * b[i] + be * y * xx[i];
    }
    if (++_since >= interval) {
      _since = 0;
      if (_factor()) _solve();
    }
  }

  @pragma('vm:unsafe:no-bounds-checks')
  bool _factor() {
    final cc = c, ll = l, l2 = _l2;
    final h = np >> 1;
    for (var i = 0; i < n; i++) {
      final r = i * np;
      final r2 = i * h;
      for (var j = 0; j < i; j++) {
        final rj = j * np;
        final rj2 = j * h;
        final e = j >> 1;
        var v = Float64x2.zero();
        for (var k = 0; k < e; k++) {
          v += l2[r2 + k] * l2[rj2 + k];
        }
        var s = cc[r + j] - (v.x + v.y);
        if ((j & 1) != 0) s -= ll[r + j - 1] * ll[rj + j - 1];
        ll[r + j] = s / ll[rj + j];
      }
      final e = i >> 1;
      var v = Float64x2.zero();
      for (var k = 0; k < e; k++) {
        final q = l2[r2 + k];
        v += q * q;
      }
      var s = cc[r + i] + _nu - (v.x + v.y);
      if ((i & 1) != 0) {
        final q = ll[r + i - 1];
        s -= q * q;
      }
      if (!(s > 1e-8)) return false;
      ll[r + i] = s * _rsqrt(s);
    }
    return true;
  }

  @pragma('vm:unsafe:no-bounds-checks')
  void _solve() {
    final ll = l, ww = w;
    for (var i = 0; i < n; i++) {
      final r = i * np;
      var s = b[i];
      for (var j = 0; j < i; j++) {
        s -= ll[r + j] * ww[j];
      }
      ww[i] = s / ll[r + i];
    }
    for (var i = n - 1; i >= 0; i--) {
      var s = ww[i];
      for (var j = i + 1; j < n; j++) {
        s -= ll[j * np + i] * ww[j];
      }
      ww[i] = s / ll[i * np + i];
    }
  }
}

/// A history of the most recent values first, in a sliding window: the
/// window is `data[p .. p + len)`.
final class _Window {
  final int len;
  final Float64List data;
  int p;

  _Window(this.len)
      : data = Float64List(len * 2 + 1),
        p = len;

  @pragma('vm:prefer-inline')
  void push(double v) {
    var q = p - 1;
    if (q < 0) {
      data.setRange(len + 1, len * 2, data, 0);
      q = len;
    }
    data[q] = v;
    p = q;
  }

  void clear() {
    data.fillRange(0, data.length, 0.0);
    p = len;
  }
}

/// paq8px LMS: [s] weights on the channel's own samples and [d] on the
/// other channel's, steps normalized per weight by a running mean of the
/// squared gradient (RMSprop).
final class _Lms {
  final int s, d;
  final double rateS, rateD;
  static const double _rho = 1.0 - 1.0 / 20.0;
  static const double _eps = 0.001;
  final Float64List w;
  final Float64List eg;
  final _Window own;
  final _Window other;
  double _pred = 0.0;

  _Lms(this.s, this.d, this.rateS, this.rateD)
      : w = Float64List(s + d),
        eg = Float64List(s + d),
        own = _Window(s),
        other = _Window(d);

  void reset() {
    w.fillRange(0, w.length, 0.0);
    eg.fillRange(0, eg.length, 0.0);
    own.clear();
    other.clear();
    _pred = 0.0;
  }

  /// Takes [sample] of the other channel (in mono the channel's own last
  /// sample) and predicts the next one.
  @pragma('vm:unsafe:no-bounds-checks')
  double predict(int sample) {
    other.push(sample.toDouble());
    final ww = w;
    final a = own.data, ap = own.p;
    var sum = 0.0;
    for (var i = 0; i < s; i++) {
      sum += ww[i] * a[ap + i];
    }
    final o = other.data, op = other.p;
    for (var i = 0; i < d; i++) {
      sum += ww[s + i] * o[op + i];
    }
    return _pred = sum;
  }

  /// Learns [sample] of this channel.
  @pragma('vm:unsafe:no-bounds-checks')
  void update(int sample) {
    final err = sample - _pred;
    const c = 1.0 - _rho;
    final ww = w, e = eg;
    final a = own.data, ap = own.p;
    for (var i = 0; i < s; i++) {
      final g = err * a[ap + i];
      final v = _rho * e[i] + c * (g * g);
      e[i] = v;
      ww[i] += rateS * g * _rsqrtLms(v + _eps);
    }
    final o = other.data, op = other.p;
    for (var i = 0; i < d; i++) {
      final g = err * o[op + i];
      final k = s + i;
      final v = _rho * e[k] + c * (g * g);
      e[k] = v;
      ww[k] += rateD * g * _rsqrtLms(v + _eps);
    }
    own.push(sample.toDouble());
  }
}

/// paq8px SmallStationaryContextMap with one input bit: a 16 bit
/// probability per context at a fixed rate, two inputs scaled by [scale].
final class _Sscm {
  final Uint16List _t;
  final int _mask;
  final int rate;
  final int scale;
  int _cx = 0;

  _Sscm(int bits, this.rate, this.scale)
      : _t = Uint16List(1 << bits)..fillRange(0, 1 << bits, 0x7FFF),
        _mask = (1 << bits) - 1;

  int get bytes => _t.length * 2;

  @pragma('vm:prefer-inline')
  void mix(Mixer m, int y, int cx, Int32List tx, int k) {
    final t = _t;
    final e = t[_cx];
    t[_cx] = e + (((y << 16) - e + (1 << (rate - 1))) >> rate);
    _cx = cx & _mask;
    final p = t[_cx] >> 4;
    tx[k] = (kStretch[p] * scale) >> 8;
    tx[k + 1] = ((p - 2048) * scale) >> 9;
  }
}

@pragma('vm:prefer-inline')
int _clampBits(int x, int bits) {
  final half = 1 << (bits - 1);
  if (x < -half) return 0;
  if (x > half - 1) return (1 << bits) - 1;
  return x + half;
}

@pragma('vm:prefer-inline')
int _roundClip(double p, int lo, int hi) {
  if (!(p > lo)) return p.isNaN ? 0 : lo;
  if (!(p < hi)) return hi;
  final r = p < 0 ? p - 0.5 : p + 0.5;
  return r.truncate();
}

@pragma('vm:prefer-inline')
int _clip(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);

const int _nOls = 8;
const int _nLms = 3;
const int _nSsm = _nOls + _nLms + 3;
const int _hist = 4096; // samples kept per channel (the taps reach 2,663)

/// The taps of the fits as offsets: `i - 1` for x1(i) (the channel's own
/// i-th previous sample), `-i` for x2(i) (the other channel's), in
/// paq8px's order. [bits16]: Audio16BitModel's patterns, else
/// Audio8BitModel's.
List<Int32List> _taps(bool bits16, bool stereo) {
  final t = List.generate(_nOls, (_) => <int>[]);
  final st = stereo ? 1 : 0;
  void x1(int o, int i) => t[o].add(i - 1);
  void x2(int o, int i) => t[o].add(-i);
  int b(bool c) => c ? 1 : 0;
  if (bits16) {
    if (stereo) {
      for (var i = 1; i <= 24; i++) {
        x2(0, i);
      }
      for (var i = 1; i <= 104; i++) {
        x1(0, i);
      }
    } else {
      for (var i = 1; i <= 128; i++) {
        x1(0, i);
      }
    }
  }
  var k1 = 90;
  var k2 = k1 - 12 * st;
  for (var j = 1, i = 1; j <= k1; j++) {
    x1(1, i);
    i += bits16
        ? 1 << (b(j > 16) + b(j > 32) + b(j > 64))
        : 1 << (b(j > 8) + b(j > 16) + b(j > 64));
  }
  for (var j = 1, i = 1; j <= k2; j++) {
    x1(2, i);
    i += 1 << (b(j > 5) + b(j > 10) + b(j > 17) + b(j > 26) + b(j > 37));
  }
  for (var j = 1, i = 1; j <= k2; j++) {
    x1(3, i);
    i += 1 <<
        (b(j > 3) + b(j > 7) + b(j > 14) + b(j > 20) + b(j > 33) + b(j > 49));
  }
  for (var j = 1, i = 1; j <= k2; j++) {
    x1(4, i);
    i += 1 + b(j > 4) + b(j > 8);
  }
  for (var j = 1, i = 1; j <= k1; j++) {
    x1(5, i);
    i += 2 + b(j > 3) + b(j > 9) + b(j > 19) + b(j > 36) + b(j > 61);
  }
  if (stereo) {
    for (var i = 1; i <= k1 - k2; i++) {
      x2(2, i);
      x2(3, i);
      x2(4, i);
    }
  }
  if (bits16) {
    k1 = 28;
    k2 = k1 - 6 * st;
    for (var i = 1; i <= k2; i++) {
      x1(6, i);
    }
    for (var i = 1; i <= k1 - k2; i++) {
      x2(6, i);
    }
    k1 = 32;
    k2 = k1 - 8 * st;
    for (var i = 1; i <= k2; i++) {
      x1(7, i);
    }
    for (var i = 1; i <= k1 - k2; i++) {
      x2(7, i);
    }
  } else {
    k1 = 28;
    k2 = k1 - 6 * st;
    var i = 1;
    for (; i <= k2; i++) {
      x1(0, i);
      x1(6, i);
      x1(7, i);
    }
    for (; i <= 96; i++) {
      x1(0, i);
    }
    if (stereo) {
      for (i = 1; i <= k1 - k2; i++) {
        x2(0, i);
        x2(6, i);
        x2(7, i);
      }
      for (; i <= 32; i++) {
        x2(0, i);
      }
    } else {
      for (; i <= 128; i++) {
        x1(0, i);
      }
    }
  }
  return [for (final l in t) Int32List.fromList(l)];
}

/// The predictors of one sample width: fits, LMS filters and the sample
/// histories per channel.
final class _Predictors {
  final bool bits16;
  final List<List<_Ols>> ols; // [predictor][channel]
  final List<List<_Lms>> lms;
  final List<_Window> hist = [_Window(_hist), _Window(_hist)];
  final List<List<Int32List>?> _tapsBy = [null, null];
  // prd[(i * 2 + ch) * 2 + k]: prediction k (0: own, 1: plus the last
  // residual of the other channel) of predictor i for channel ch.
  final Int32List prd = Int32List(_nSsm * 4);
  final Int32List res = Int32List(_nSsm * 2);

  _Predictors(this.bits16, List<int> num, List<int> interval,
      List<double> lambda, List<List<double>> lmsCfg)
      : ols = [
          for (var i = 0; i < _nOls; i++)
            [
              for (var ch = 0; ch < 2; ch++)
                _Ols(num[i], interval[i], lambda[i])
            ]
        ],
        lms = [
          for (final c in lmsCfg)
            [
              for (var ch = 0; ch < 2; ch++)
                _Lms(c[0].toInt(), c[1].toInt(), c[2], c[3])
            ]
        ];

  void resetLms() {
    for (final l in lms) {
      l[0].reset();
      l[1].reset();
    }
  }

  /// Learns [sample] of channel [pCh], then predicts channel [ch]; returns
  /// the sum of squares for errLog and shifts the mask (via [mask]).
  @pragma('vm:unsafe:no-bounds-checks')
  void step(int sample, int pCh, int ch, bool stereo, int lo, int hi) {
    final v = sample.toDouble();
    for (var i = 0; i < _nOls; i++) {
      ols[i][pCh].update(v);
    }
    for (var j = 0; j < _nLms; j++) {
      lms[j][pCh].update(sample);
    }
    for (var i = 0; i < _nSsm; i++) {
      res[i * 2 + pCh] = sample - prd[(i * 2 + pCh) * 2];
    }
    hist[pCh].push(v);
    final own = hist[ch];
    final other = hist[stereo ? 1 - ch : ch];
    final od = own.data, op = own.p;
    final xd = other.data, xp = other.p;
    final taps = _tapsBy[stereo ? 1 : 0] ??= _taps(bits16, stereo);
    for (var i = 0; i < _nOls; i++) {
      final o = ols[i][ch];
      final t = taps[i];
      final x = o.x;
      for (var q = 0; q < t.length; q++) {
        final a = t[q];
        x[q] = a >= 0 ? od[op + a] : xd[xp - a - 1];
      }
      prd[(i * 2 + ch) * 2] = _roundClip(o.predict(), lo, hi);
    }
    for (var j = 0; j < _nLms; j++) {
      prd[((_nOls + j) * 2 + ch) * 2] =
          _roundClip(lms[j][ch].predict(sample), lo, hi);
    }
    final x1 = od[op].toInt(), x2 = od[op + 1].toInt();
    final x3 = od[op + 2].toInt(), x4 = od[op + 3].toInt();
    var i = _nOls + _nLms;
    prd[(i++ * 2 + ch) * 2] = _clip(x1 * 2 - x2, lo, hi);
    prd[(i++ * 2 + ch) * 2] = _clip(x1 * 3 - x2 * 3 + x3, lo, hi);
    prd[(i * 2 + ch) * 2] = _clip(x1 * 4 - x2 * 6 + x3 * 4 - x4, lo, hi);
    for (i = 0; i < _nSsm; i++) {
      final k = (i * 2 + ch) * 2;
      prd[k + 1] = _clip(prd[k] + res[i * 2 + pCh], lo, hi);
    }
  }
}

/// paq8px's audio model for 8 and 16 bit PCM, mono or stereo. The
/// predictor feeds it the final probability of each bit ([lastP]) for
/// the coding loss contexts of 8-bit audio and reads [sseContext].
final class AudioPxModel implements ZcmModel, ZcmMixerContexts {
  _Predictors? _p16, _p8;
  final List<_Sscm> _maps16 = [];
  final List<ResidualMap> _maps8 = [];

  static const List<int> _widths = [8, 13, 4, 5];
  static const List<int> _rates16 = [7, 10, 6, 6];
  static const List<int> _scaleOls = [128, 128, 86, 128];
  static const List<int> _scaleOther = [86, 86, 64, 86];

  int _info = -1;
  bool _b16 = true, _stereo = false, _signed8 = false;
  int _ch = 0, _lsb = 0;
  int _mask = 0, _errLog = 0, _mxCtx = 0;

  // 8 bits: coding loss and predictor errors.
  int _loss = 0, _lossQ = 0;
  final Int32List _errBuf0 = Int32List(_nSsm);
  final Int32List _errBuf1 = Int32List(_nSsm);

  /// The final 16 bit probability of the last bit (set by the predictor).
  int lastP = 32768;

  /// The weight set of the final mixer layer: the bit of the sample.
  int get finalContext => _b16 ? _lsb << 3 | _bpos : _bpos;
  int _bpos = 0;

  /// State.Audio of paq8px (the context of the audio SSE stage).
  int sseContext = 0;

  /// [extra]: a mixer weight set and an SSE context selected by the
  /// residual of the predictor with the smallest recent errors (zcm).
  final bool extra;

  // zcm: the predictor with the smallest recent errors per channel, and
  // the contexts of its residual for the current bit.
  final Int32List _errE = Int32List(_nSsm * 2);
  int _best = 0;
  int _bestCtx = 0;

  /// The residual context of the best predictor for the SSE stage (14
  /// bits).
  int apmContext = 0;

  AudioPxModel({this.extra = true});

  void _chooseBest(Int32List res, int pCh, int ch) {
    final e = _errE;
    for (var i = 0; i < _nSsm; i++) {
      final r = res[i * 2 + pCh];
      final a = r < 0 ? -r : r;
      final k = i * 2 + pCh;
      e[k] = e[k] - (e[k] >> 4) + (a > 65535 ? 65535 : a);
    }
    var best = 0;
    var be = e[ch];
    for (var i = 1; i < _nSsm; i++) {
      final v = e[i * 2 + ch];
      if (v < be) {
        be = v;
        best = i;
      }
    }
    _best = best;
  }

  /// Bytes of the tables (both sample widths).
  static int get tableBytes {
    var b = 0;
    for (final w in _widths) {
      b += _nSsm * (2 << (w + 4));
    }
    b += 4 * _nSsm * 64 * 256 * 2;
    // Fits: n * n doubles twice, per channel, per width.
    const num16 = [128, 90, 90, 90, 90, 90, 28, 32];
    for (final n in num16) {
      b += 2 * 2 * 2 * n * n * 8;
    }
    b += 2 * 2 * (1920 + 704 + 2464) * 8 * 4;
    return b;
  }

  @override
  int get inputs => _nSsm * 4 * 2;

  @override
  List<int> get mixerContextSizes => extra
      ? const [8192, 4096, 2560, 256, 20, 1024]
      : const [8192, 4096, 2560, 256, 20];

  _Predictors _build16() {
    for (var i = 0; i < _nSsm; i++) {
      final sc = i < _nOls ? _scaleOls : _scaleOther;
      for (var j = 0; j < 4; j++) {
        _maps16.add(_Sscm(_widths[j] + 4, _rates16[j], sc[j]));
      }
    }
    return _Predictors(true, const [
      128,
      90,
      90,
      90,
      90,
      90,
      28,
      32
    ], const [
      24,
      30,
      31,
      32,
      33,
      34,
      4,
      3
    ], const [
      0.998,
      0.998,
      0.998,
      0.998,
      0.995,
      0.998,
      0.999,
      0.991
    ], const [
      [1280, 640, 5e-5, 5e-5],
      [640, 64, 7e-5, 1e-5],
      [2456, 8, 2e-5, 2e-6],
    ]);
  }

  _Predictors _build8() {
    _maps8.addAll([
      ResidualMap(_nSsm, 64, scale: 64),
      ResidualMap(_nSsm, 64, scale: 64),
      ResidualMap(_nSsm, 64, scale: 96),
      ResidualMap(_nSsm, 64, scale: 96),
    ]);
    return _Predictors(false, const [
      128,
      90,
      90,
      90,
      90,
      90,
      28,
      28
    ], const [
      24,
      30,
      31,
      32,
      33,
      34,
      4,
      3
    ], const [
      0.9975,
      0.9965,
      0.996,
      0.995,
      0.995,
      0.9985,
      0.98,
      0.992
    ], const [
      [1280, 640, 3e-5, 2e-5],
      [640, 64, 8e-5, 1e-5],
      [2456, 8, 1.6e-5, 1e-6],
    ]);
  }

  void _start(ZcmState s) {
    _info = s.blockInfo;
    _b16 = (_info & 1) != 0;
    _stereo = (_info & 2) != 0;
    _signed8 = (_info & 4) != 0;
    _mask = 0;
    _ch = 0;
    _lsb = 0;
    final p = _b16 ? (_p16 ??= _build16()) : (_p8 ??= _build8());
    p.resetLms();
  }

  @override
  void mix(ZcmState s, Mixer m) {
    final bpos = s.bpos;
    _bpos = bpos;
    if (bpos == 0 && (s.blockPos == 0 || s.blockInfo != _info)) _start(s);
    if (_b16) {
      _mix16(s, m, bpos);
    } else {
      _mix8(s, m, bpos);
    }
  }

  @pragma('vm:unsafe:no-bounds-checks')
  void _mix16(ZcmState s, Mixer m, int bpos) {
    final p = _p16!;
    final st = _stereo ? 1 : 0;
    final blockPos = s.blockPos;
    if (bpos == 0 && blockPos != 0) {
      _ch = _stereo ? (blockPos & 2) >> 1 : 0;
      _lsb = blockPos & 1;
      if (_lsb == 0) {
        final v = s.back(2) << 8 | s.back(1);
        final sample = v >= 0x8000 ? v - 0x10000 : v;
        final ch = _ch;
        final pCh = ch ^ st;
        var mask = _mask;
        var err = 0;
        final prd = p.prd;
        for (var i = 0; i < _nOls; i++) {
          final r = sample - prd[(i * 2 + pCh) * 2];
          final a = r < 0 ? -r : r;
          mask = ((mask << 1) | (a > 128 ? 1 : 0)) & 0xFFFFFFFF;
          final q = a >> 6;
          err += q * q;
        }
        _mask = mask;
        final el = _ilog2(err & 0xFFFFFFFF);
        _errLog = el > 15 ? 15 : el;
        p.step(sample, pCh, ch, _stereo, -32768, 32767);
        if (extra) _chooseBest(p.res, pCh, ch);
      }
      var bc = _bitCount(_mask);
      if (bc > 31) bc = 31;
      _mxCtx = _ilog2(bc) * 4 + _ch * 2 + _lsb;
      sseContext = 0x80 | _mxCtx;
    }
    final c0 = s.c0;
    final c1 = s.c4 & 255;
    final int v;
    if (_lsb != 0) {
      v = (c1 << 8) | ((c0 << (8 - bpos)) & 255);
    } else {
      v = (c0 << (16 - bpos)) & 0xFFFF;
    }
    final b = v >= 0x8000 ? v - 0x10000 : v;
    final pos = _lsb * 8 + bpos;
    final y = s.y;
    final tx = m.tx;
    var k = m.nx;
    final ch = _ch;
    final prd = p.prd;
    final maps = _maps16;
    if (extra) {
      final r = prd[(_best * 2 + ch) * 2] - b;
      final s6 = 11 - pos, s10 = 7 - pos;
      _bestCtx = _clampBits(r >> (s6 < 0 ? 0 : s6), 6) << 4 | pos;
      apmContext = _clampBits(r >> (s10 < 0 ? 0 : s10), 10) << 4 | pos;
    }
    var sh0 = 9 - pos, sh1 = 4 - pos, sh2 = 13 - pos, sh3 = 12 - pos;
    if (sh0 < 0) sh0 = 0;
    if (sh1 < 0) sh1 = 0;
    if (sh2 < 0) sh2 = 0;
    if (sh3 < 0) sh3 = 0;
    var mi = 0;
    for (var i = 0; i < _nSsm; i++) {
      final q = (i * 2 + ch) * 2;
      final r0 = prd[q] - b;
      final r1 = prd[q + 1] - b;
      maps[mi++].mix(m, y, _clampBits(r0 >> sh0, 8) << 4 | pos, tx, k);
      maps[mi++].mix(m, y, _clampBits(r0 >> sh1, 13) << 4 | pos, tx, k + 2);
      maps[mi++].mix(m, y, _clampBits(r0 >> sh2, 4) << 4 | pos, tx, k + 4);
      maps[mi++].mix(m, y, _clampBits(r1 >> sh3, 5) << 4 | pos, tx, k + 6);
      k += 8;
    }
    m.nx = k;
  }

  @pragma('vm:unsafe:no-bounds-checks')
  void _mix8(ZcmState s, Mixer m, int bpos) {
    final p = _p8!;
    final st = _stereo ? 1 : 0;
    // The coding loss of the last bit: 0 to 63 (paq8px State.loss).
    final lp = lastP;
    _loss += (s.y == 0 ? lp : 65535 - lp) >> 10;
    if (bpos == 0) {
      final blockPos = s.blockPos;
      final c1 = s.c4 & 255;
      final maps = _maps8;
      for (var i = 0; i < maps.length; i++) {
        maps[i].update(c1);
      }
      _ch = _stereo ? blockPos & 1 : 0;
      final ch = _ch;
      final sample = _signed8 ? (c1 ^ 128) - 128 : c1 - 128;
      final pCh = ch ^ st;
      final prd = p.prd;
      for (var i = 0; i < _nSsm; i++) {
        final q = (i * 2 + pCh) * 2;
        var e0 = sample - prd[q];
        if (e0 < 0) e0 = -e0;
        var e1 = sample - prd[q + 1];
        if (e1 < 0) e1 = -e1;
        _errBuf0[i] = ((_errBuf0[i] * 15) >> 4) + (e0 & 255);
        _errBuf1[i] = ((_errBuf1[i] * 15) >> 4) + (e1 & 255);
      }
      _lossQ = ((_lossQ * 15) >> 4) + _loss;
      _loss = 0;
      if (blockPos != 0) {
        var mask = _mask;
        var err = 0;
        for (var i = 0; i < _nOls; i++) {
          final r = sample - prd[(i * 2 + pCh) * 2];
          final a = r < 0 ? -r : r;
          mask = ((mask << 1) | (a > 4 ? 1 : 0)) & 0xFFFFFFFF;
          err += a * a;
        }
        _mask = mask;
        final el = _ilog2(err & 0xFFFFFFFF);
        _errLog = el > 15 ? 15 : el;
        p.step(sample, pCh, ch, _stereo, -128, 127);
        if (extra) _chooseBest(p.res, pCh, ch);
      }
      var bc = _bitCount(_mask);
      if (bc > 31) bc = 31;
      _mxCtx = _ilog2(bc) * 2 + ch;
      sseContext = _mxCtx;
      var lq = _lossQ ~/ 384;
      if (lq > 31) lq = 31;
      final r1 = _maps8[0], r2 = _maps8[1], r3 = _maps8[2], r4 = _maps8[3];
      for (var i = 0; i < _nSsm; i++) {
        final q = (i * 2 + ch) * 2;
        final p0 = prd[q] + 128, p1 = prd[q + 1] + 128;
        r1.set(p0, lq << 1 | ch);
        r2.set(p1, lq << 1 | ch);
        final e0 = _errBuf0[i] >> 4, e1 = _errBuf1[i] >> 4;
        r3.set(p0, (e0 > 31 ? 31 : e0) << 1 | ch);
        r4.set(p1, (e1 > 31 ? 31 : e1) << 1 | ch);
      }
    }
    final c0 = s.c0;
    if (extra) {
      final raw = (c0 << (8 - bpos)) & 255;
      final b = _signed8 ? (raw ^ 0x80) - 128 : raw - 128;
      final r = p.prd[(_best * 2 + _ch) * 2] - b;
      final s6 = 3 - bpos;
      _bestCtx = _clampBits(r >> (s6 < 0 ? 0 : s6), 6) << 4 | bpos;
      apmContext = _clampBits(r, 10) << 4 | bpos;
    }
    final maps = _maps8;
    for (var i = 0; i < maps.length; i++) {
      maps[i].mix(m, bpos, c0);
    }
  }

  @override
  void setMixerContexts(ZcmState s, Mixer m) {
    final bpos = s.bpos;
    final c0 = s.c0;
    final c1 = s.c4 & 255;
    if (_b16) {
      m.set((_errLog << 9) | (_lsb << 8) | c0);
      m.set(((_mask & 255) << 4) | (_ch << 3) | (_lsb << 2) | (bpos >> 1));
      m.set((_mxCtx << 7) | (c1 >> 1));
      m.set((_errLog << 4) | (_ch << 3) | (_lsb << 2) | (bpos >> 1));
      m.set(_mxCtx);
      if (extra) m.set(_bestCtx);
    } else {
      m.set((_errLog << 8) | c0);
      m.set(((_mask & 255) << 3) | (_ch << 2) | (bpos >> 1));
      m.set((_mxCtx << 7) | (c1 >> 1));
      m.set((_errLog << 4) | (_ch << 3) | bpos);
      m.set(_mxCtx);
      if (extra) m.set(_bestCtx);
    }
  }
}

/// paq8px's SSE stage of audio (SSE.cpp, AUDIO): one APM in the context
/// of the audio model's state, the bit position and the recent misses,
/// and two APMPosts by bit position.
final class AudioSse {
  final ApmPx _a0 = ApmPx(1 << 14, 24);
  final ApmPost _postA = ApmPost(8);
  final ApmPost _postB = ApmPost(8);
  // zcm: a second APM in the residual context of the best predictor
  // ([AudioPxModel.apmContext]), averaged with the first.
  final ApmPx _a1 = ApmPx(1 << 14, 24);

  /// Bytes of the tables.
  static const int tableBytes = 2 * (1 << 14) * 24 * 4 + 2 * 8 * 4096 * 8;

  /// Refines the mixer output [pr] (12 bits) after bit [y]; the result
  /// has 16 bits. [m3]: misses3 of paq8px; [ctx]: [AudioPxModel.sseContext].
  int p(int y, int pr, int bpos, int m3, int ctx, int actx) {
    final p0 = (_a0.pp(y, pr, (ctx << 6 | bpos << 3 | m3) & 0x3FFF) +
            _a1.pp(y, pr, actx & 0x3FFF) +
            1) >>
        1;
    // zcm: the APM side weighs 7/8 (paq8px: 1/2).
    var p = (_postA.pp(y, pr, bpos) + _postB.pp(y, p0 >> 4, bpos) * 7 + 4) >> 3;
    if (p < 1) p = 1;
    if (p > 65535) p = 65535;
    return p;
  }
}
