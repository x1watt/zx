// zcm: the audio model of levels 3 to 6 (8 and 16 bit PCM, mono or stereo;
// levels 7 to 9 use paq8px's models, zcm_audio_px.dart).
//
// After the Audio8BitModel and Audio16BitModel of paq8px (Marcio Pais,
// after Florin Ghido's 'An asymptotically optimal predictor for stereo
// lossless audio compression'; tuned by Zoltan Gotthardt): the next
// sample is predicted by recursive least squares fits (paq8px OLS by
// Sebastian Lehmann: a covariance matrix with exponential forgetting,
// solved by Cholesky factorization every few samples) over the previous
// samples of the same channel and of the other one, by LMS filters
// (paq8px LMS by Sebastian Lehmann, normalized per weight like RMSprop,
// and a plain normalized one) and by polynomial extrapolation; the bits
// of the sample are then coded in contexts of the residual between each
// prediction and the bits already known (paq8px
// SmallStationaryContextMap). 16-bit samples are coded most significant
// byte first (zcm.dart swaps little endian samples, as paq8px's
// EndiannessFilter does).
//
// The fits use doubles with +, -, *, / and the correctly rounded square
// root (zcm_math.dart) in a fixed order, so every machine computes the
// same predictions.

import 'dart:typed_data';

import 'zcm_components.dart';
import 'zcm_math.dart';
import 'zcm_models.dart';
import 'zcm_ols.dart';
import 'zcm_tables.dart';

/// Normalized LMS filter over [nOwn] samples of the channel and [nOther]
/// of the other one.
final class _Nlms {
  final int nOwn, nOther;
  final double mu;
  final Float64List x;
  final Float64List w;
  double _pred = 0.0;

  _Nlms(this.nOwn, this.nOther, this.mu)
      : x = Float64List(nOwn + nOther),
        w = Float64List(nOwn + nOther);

  @pragma('vm:unsafe:no-bounds-checks')
  double predict(Float64List own, int oo, Float64List other, int ot) {
    var s = 0.0;
    for (var i = 0; i < nOwn; i++) {
      final v = own[oo + i];
      x[i] = v;
      s += v * w[i];
    }
    for (var i = 0; i < nOther; i++) {
      final v = other[ot + i];
      x[nOwn + i] = v;
      s += v * w[nOwn + i];
    }
    return _pred = s;
  }

  @pragma('vm:unsafe:no-bounds-checks')
  void update(double y) {
    final n = nOwn + nOther;
    final err = y - _pred;
    var norm = 1.0;
    for (var i = 0; i < n; i++) {
      norm += x[i] * x[i];
    }
    final g = mu * err / norm;
    for (var i = 0; i < n; i++) {
      w[i] += g * x[i];
    }
  }
}

/// paq8px LMS: an LMS filter whose steps are normalized per weight by a
/// running mean of the squared gradient (RMSprop), with its own rates for
/// the samples of the channel and of the other one.
final class _RmsLms {
  final int nOwn, nOther;
  final double rateOwn, rateOther;
  static const double _rho = 0.95;
  static const double _eps = 0.001;
  final Float64List x;
  final Float64List w;
  final Float64List eg;
  double _pred = 0.0;

  _RmsLms(this.nOwn, this.nOther, this.rateOwn, this.rateOther)
      : x = Float64List(nOwn + nOther),
        w = Float64List(nOwn + nOther),
        eg = Float64List(nOwn + nOther);

  @pragma('vm:unsafe:no-bounds-checks')
  double predict(Float64List own, int oo, Float64List other, int ot) {
    var s = 0.0;
    for (var i = 0; i < nOwn; i++) {
      final v = own[oo + i];
      x[i] = v;
      s += v * w[i];
    }
    for (var i = 0; i < nOther; i++) {
      final v = other[ot + i];
      x[nOwn + i] = v;
      s += v * w[nOwn + i];
    }
    return _pred = s;
  }

  @pragma('vm:unsafe:no-bounds-checks')
  void update(double y) {
    final err = y - _pred;
    const c = 1.0 - _rho;
    final n = nOwn + nOther;
    for (var i = 0; i < n; i++) {
      final g = err * x[i];
      final e = _rho * eg[i] + c * (g * g);
      eg[i] = e;
      w[i] += (i < nOwn ? rateOwn : rateOther) * g / zsqrt(e + _eps);
    }
  }
}

/// paq8px SmallStationaryContextMap with one entry per context: a 16 bit
/// probability adapting at a fixed rate.
final class _Sscm {
  final Uint16List _t;
  final int _mask;
  final int rate;
  int _cx = 0;

  _Sscm(int bits, this.rate)
      : _t = Uint16List(1 << bits)..fillRange(0, 1 << bits, 0x7FFF),
        _mask = (1 << bits) - 1;

  @pragma('vm:unsafe:no-bounds-checks')
  int p(int y, int cx) {
    final t = _t;
    final e = t[_cx];
    t[_cx] = e + (((y << 16) - e + (1 << (rate - 1))) >> rate);
    _cx = cx & _mask;
    return t[_cx] >> 4;
  }
}

@pragma('vm:prefer-inline')
int _clampBits(int x, int bits) {
  final half = 1 << (bits - 1);
  if (x < -half) return 0;
  if (x > half - 1) return (1 << bits) - 1;
  return x + half;
}

/// The model of audio segments.
final class AudioModel implements ZcmModel, ZcmMixerContexts {
  // Samples kept per channel (most recent first, in a sliding window).
  final int _hist;
  // Least squares fits: samples of the channel, of the other one (stereo
  // only), solve interval, forgetting factor.
  static const List<List<num>> _olsFull = [
    [48, 16, 16, 0.998],
    [24, 8, 8, 0.998],
    [12, 4, 4, 0.995],
    [6, 2, 2, 0.98],
  ];
  static const List<List<num>> _olsLight = [
    [6, 2, 4, 0.99],
  ];
  // LMS filters: samples of the channel, of the other one, rate.
  static const List<List<num>> _lmsFull = [
    [32, 8, 0.008],
  ];
  // RMSprop LMS filters (paq8px LMS): samples of the channel, of the
  // other one, their rates.
  static const List<List<num>> _rmsFull = [
    [640, 64, 7e-5, 1e-5],
    [256, 32, 2e-4, 5e-5],
  ];
  static const List<List<num>> _lmsLight = [
    [32, 8, 0.008],
  ];

  final bool full;
  final int _nPred;
  final int _nOls, _nLms, _nRms;
  // Per channel: sample history (most recent first).
  final List<Float64List> _h;
  final Int32List _hp;
  final List<List<ZcmOls>> _ols; // [predictor][channel]
  final List<List<_Nlms>> _lms;
  final List<List<_RmsLms>> _rms;
  final Int32List _prd0;
  final Int32List _prd1;
  final Int32List _res;
  final List<_Sscm> _maps = [];
  static const List<int> _widths16 = [8, 13, 4, 5];
  static const List<int> _widths8 = [8, 6, 4, 5];
  static const List<int> _rates = [7, 10, 6, 6];

  int _info = -1;
  int _bits = 16, _channels = 1;
  int _ch = 0, _lsb = 0; // channel and byte of the sample (0: MSB)
  int _mask = 0, _errLog = 0;

  /// [full]: the larger least squares fits and LMS filters (levels 7 to
  /// 9 use paq8px's models, zcm_audio_px.dart). [allowance]: bytes for
  /// the tables.
  factory AudioModel(int allowance, {bool full = true}) {
    final ols = full ? _olsFull : _olsLight;
    final lms = full ? _lmsFull : _lmsLight;
    final rms = full ? _rmsFull : const <List<num>>[];
    return AudioModel._(allowance, full, ols, lms, rms);
  }

  AudioModel._(int allowance, this.full, List<List<num>> ols,
      List<List<num>> lms, List<List<num>> rms)
      : _hist = 720,
        _h = [Float64List(720 * 2), Float64List(720 * 2)],
        _hp = Int32List.fromList([720, 720]),
        _nOls = ols.length,
        _nLms = lms.length,
        _nRms = rms.length,
        _nPred = ols.length + lms.length + rms.length + 3,
        _ols = [
          for (final c in ols)
            [
              for (var ch = 0; ch < 2; ch++)
                ZcmOls((c[0] + c[1]).toInt(), c[2].toInt(), c[3].toDouble())
            ]
        ],
        _lms = [
          for (final c in lms)
            [
              for (var ch = 0; ch < 2; ch++)
                _Nlms(c[0].toInt(), c[1].toInt(), c[2].toDouble())
            ]
        ],
        _rms = [
          for (final c in rms)
            [
              for (var ch = 0; ch < 2; ch++)
                _RmsLms(c[0].toInt(), c[1].toInt(), c[2].toDouble(),
                    c[3].toDouble())
            ]
        ],
        _prd0 = Int32List((ols.length + lms.length + rms.length + 3) * 2),
        _prd1 = Int32List((ols.length + lms.length + rms.length + 3) * 2),
        _res = Int32List((ols.length + lms.length + rms.length + 3) * 2) {
    final bits = mapBits(allowance, _nPred);
    for (var i = 0; i < _nPred; i++) {
      for (var j = 0; j < _nMaps; j++) {
        _maps.add(_Sscm(bits, _rates[j]));
      }
    }
  }

  /// Predictors of a full model (for the table sizes).
  static const int _maxPred = 8 + 1 + 3 + 3;

  // Residual maps per predictor (paq8px).
  int get _nMaps => 4;

  @override
  int get inputs => _nPred * _nMaps * 2;

  @override
  List<int> get mixerContextSizes =>
      full ? const [8192, 4096, 512, 2560, 256] : const [8192, 4096, 512];

  /// Context bits of the residual maps for [allowance] bytes.
  static int mapBits(int allowance, [int nPred = _maxPred]) {
    var b = 17;
    while (b > 10 && nPred * 4 * (2 << b) > allowance) {
      b--;
    }
    return b;
  }

  /// Table bytes of a model with [allowance] (at most that).
  static int tableBytes(int allowance) =>
      _maxPred * 4 * (2 << mapBits(allowance));

  int _sampleAt(ZcmState s, int back) {
    // The sample [back] bytes before the current byte, as a signed value.
    if (_bits == 8) {
      final v = s.back(back);
      return (_info & 4) != 0 ? (v ^ 0x80) - 128 : v - 128;
    }
    final v = s.back(back) << 8 | s.back(back - 1);
    return v >= 0x8000 ? v - 0x10000 : v;
  }

  void _newSample(ZcmState s) {
    final bytesPer = _bits >> 3;
    final k = s.blockPos ~/ bytesPer; // index of the sample to predict
    final stereo = _channels == 2;
    _ch = stereo ? k & 1 : 0;
    if (k > 0) {
      // The previous sample is complete: learn it.
      final pc = stereo ? (k - 1) & 1 : 0;
      final vi = _sampleAt(s, bytesPer);
      final v = vi.toDouble();
      final hist = _h[pc];
      for (var i = 0; i < _nOls; i++) {
        _ols[i][pc].update(v);
      }
      for (var i = 0; i < _nLms; i++) {
        _lms[i][pc].update(v);
      }
      for (var i = 0; i < _nRms; i++) {
        _rms[i][pc].update(v);
      }
      var err = 0;
      for (var i = 0; i < _nPred; i++) {
        final r = vi - _prd0[i * 2 + pc];
        _res[i * 2 + pc] = r;
        final a = r < 0 ? -r : r;
        _mask = ((_mask << 1) | (a > (_bits == 16 ? 128 : 4) ? 1 : 0)) & 0xFFFF;
        final q = a >> (_bits == 16 ? 6 : 1);
        err += q * q;
      }
      var el = 0;
      while ((1 << (el + 1)) <= err && el < 15) {
        el++;
      }
      _errLog = el;
      var hp = _hp[pc] - 1;
      if (hp < 0) {
        // Move the window up (every _hist samples).
        hist.setRange(_hist + 1, _hist * 2, hist, 0);
        hp = _hist;
      }
      hist[hp] = v;
      _hp[pc] = hp;
    }
    // Predictions for the channel of this sample.
    final ch = _ch;
    final own = _h[ch];
    final oo = _hp[ch];
    final other = _h[stereo ? 1 - ch : ch];
    final ot = _hp[stereo ? 1 - ch : ch];
    final lim = _bits == 16 ? 32767 : 127;
    var i = 0;
    for (var j = 0; j < _nOls; j++, i++) {
      final o = _ols[j][ch];
      final cfg = (full ? _olsFull : _olsLight)[j];
      final nOther = stereo ? cfg[1].toInt() : 0;
      final nOwn = o.n - nOther;
      for (var q = 0; q < nOwn; q++) {
        o.add(own[oo + q]);
      }
      for (var q = 0; q < nOther; q++) {
        o.add(other[ot + q]);
      }
      _setPred(i, ch, o.predict(), lim);
    }
    final oth = stereo ? other : own;
    final oto = stereo ? ot : oo;
    for (var j = 0; j < _nLms; j++, i++) {
      _setPred(i, ch, _lms[j][ch].predict(own, oo, oth, oto), lim);
    }
    for (var j = 0; j < _nRms; j++, i++) {
      _setPred(i, ch, _rms[j][ch].predict(own, oo, oth, oto), lim);
    }
    final x1 = own[oo].toInt(), x2 = own[oo + 1].toInt();
    final x3 = own[oo + 2].toInt();
    _setPredInt(i++, ch, x1 * 2 - x2, lim);
    _setPredInt(i++, ch, x1 * 3 - x2 * 3 + x3, lim);
    _setPredInt(i++, ch, stereo && ch == 1 ? other[ot].toInt() : x1, lim);
  }

  void _setPred(int i, int ch, double p, int lim) {
    var v = 0;
    if (p.isFinite) {
      final r = p + (p < 0 ? -0.5 : 0.5);
      v = r > 1e9 ? lim : (r < -1e9 ? -lim : r.toInt());
    }
    _setPredInt(i, ch, v, lim);
  }

  void _setPredInt(int i, int ch, int v, int lim) {
    if (v > lim) v = lim;
    if (v < -lim - 1) v = -lim - 1;
    _prd0[i * 2 + ch] = v;
    var v1 = v + _res[i * 2 + ch];
    if (v1 > lim) v1 = lim;
    if (v1 < -lim - 1) v1 = -lim - 1;
    _prd1[i * 2 + ch] = v1;
  }

  @override
  void mix(ZcmState s, Mixer m) {
    final bpos = s.bpos;
    if (bpos == 0) {
      if (s.blockInfo != _info || s.blockPos == 0) {
        _info = s.blockInfo;
        _bits = (_info & 1) != 0 ? 16 : 8;
        _channels = (_info & 2) != 0 ? 2 : 1;
      }
      if (_bits == 8 || (s.blockPos & 1) == 0) {
        _newSample(s);
        _lsb = 0;
      } else {
        _lsb = 1;
      }
    }
    final c0 = s.c0;
    final y = s.y;
    int b;
    int pos;
    int top;
    if (_bits == 16) {
      pos = _lsb * 8 + bpos;
      final v = _lsb != 0
          ? ((s.c4 & 255) << 8) | ((c0 << (8 - bpos)) & 255)
          : (c0 << (16 - bpos)) & 0xFFFF;
      b = v >= 0x8000 ? v - 0x10000 : v;
      top = 17;
    } else {
      pos = bpos;
      final raw = (c0 << (8 - bpos)) & 255;
      b = (_info & 4) != 0 ? (raw ^ 0x80) - 128 : raw - 128;
      top = 9;
    }
    final widths = _bits == 16 ? _widths16 : _widths8;
    final tx = m.tx;
    var k = m.nx;
    final str = kStretch;
    final ch = _ch;
    var mi = 0;
    final nm = _nMaps;
    for (var i = 0; i < _nPred; i++) {
      final r0 = _prd0[i * 2 + ch] - b;
      final r1 = _prd1[i * 2 + ch] - b;
      for (var j = 0; j < nm; j++) {
        final nb = widths[j];
        var sh = top - nb - pos;
        if (sh < 0) sh = 0;
        final r = j == 3 ? r1 : r0;
        final cx = _clampBits(r >> sh, nb) << 4 | pos;
        final p = _maps[mi++].p(y, cx);
        tx[k] = str[p];
        tx[k + 1] = (p - 2048) >> 2;
        k += 2;
      }
    }
    m.nx = k;
  }

  @override
  void setMixerContexts(ZcmState s, Mixer m) {
    final bpos = s.bpos;
    final c0 = s.c0;
    var bc = 0;
    var mm = _mask & 0xFF;
    while (mm != 0) {
      bc += mm & 1;
      mm >>= 1;
    }
    m.set((_errLog << 9 | _lsb << 8 | c0) & 8191);
    m.set(((_mask & 0xFF) << 4 | _ch << 3 | _lsb << 2 | bpos >> 1) & 4095);
    m.set(bc << 5 | _ch << 4 | _lsb << 3 | bpos);
    if (!full) return;
    // paq8px mxCtx: log2 of the recent large residuals, channel, byte.
    var lg = 0;
    while ((2 << lg) <= bc) {
      lg++;
    }
    final mx = lg * 4 + _ch * 2 + _lsb;
    m.set(mx << 7 | ((s.c4 & 255) >> 1));
    m.set(_errLog << 4 | _ch << 3 | _lsb << 2 | bpos >> 1);
  }
}

/// Swaps the bytes of the 16-bit samples of [len] bytes at [off] (little
/// endian to big endian and back).
void zcmSwap16(Uint8List b, int off, int len) {
  final end = off + (len & ~1);
  for (var i = off; i < end; i += 2) {
    final t = b[i];
    b[i] = b[i + 1];
    b[i + 1] = t;
  }
}
