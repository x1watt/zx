// zcm: image models (8-bit gray or palette, 24-bit and 32-bit pixels).
//
// After the Image8BitModel and Image24BitModel of paq8px (Marcio Pais,
// from his Emma; Zoltan Gotthardt, Sebastian Lehmann and the paq8px
// authors; earlier im8/im24 models of paq8 by Matt Mahoney): the pixels around the one being coded (W, N, NW,
// NE and further), on the same color plane and on the planes already coded
// of the same pixel, give numeric predictions whose residuals are modeled
// by histograms (paq8px ResidualMap), hashed contexts of the neighborhood
// (ContextMap), bit contexts of quantized neighbors (paq8px
// LargeStationaryMap) and mixer weight set selectors from the local
// gradients, and least squares fits (paq8px OLS by Sebastian Lehmann). A
// reduced set of paq8px's predictors and contexts (paq8px has about 120
// predictors and six fits). Integers, except the fits (doubles, see
// zcm_ols.dart).

import 'dart:typed_data';

import 'zcm_components.dart';
import 'zcm_models.dart';
import 'zcm_ols.dart';
import 'zcm_tables.dart';

/// paq8px ResidualMap: per context and histogram, the counts of
/// (actual - predicted) byte values as prefix sums; the next bit's
/// probability is the share of the residuals that agree with the bits
/// seen so far and have that bit set.
final class ResidualMap {
  static const int _bins = 256;
  final int n;
  final int histograms;
  final Uint16List _sums;
  final Int32List _pred;
  final Int32List _base;
  int _k = 0;
  final Int32List _dt = kDt;

  ResidualMap(this.n, this.histograms)
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

  /// Learns [byte] in every context set for it, then clears the list.
  @pragma('vm:unsafe:no-bounds-checks')
  void update(int byte) {
    final s = _sums;
    for (var i = 0; i < _k; i++) {
      final base = _base[i];
      final bin = (192 + byte - _pred[i]) & 255;
      if (s[base + _bins - 1] >= 65535) {
        // Halve: rebuild the prefix sums from halved counts.
        var prev = 0, acc = 0;
        for (var j = 0; j < _bins; j++) {
          final v = s[base + j];
          final c = (v - prev) >> 1;
          prev = v;
          acc += c;
          s[base + j] = acc;
        }
      }
      for (var j = base + bin; j < base + _bins; j++) {
        s[j]++;
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
    for (var i = 0; i < _k; i++) {
      final base = _base[i];
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
      // p1 = 4096 * (n1 + 1) / (n0 + n1 + 2)
      var sum = n0 + n1;
      var sh = 0;
      while ((sum >> sh) > 1023) {
        sh++;
      }
      final p1 = (((n1 >> sh) + 1) << 12) * (dt[sum >> sh] >> 1) >> 30;
      final pp = p1 < 1 ? 1 : (p1 > 4095 ? 4095 : p1);
      tx[k] = str[pp];
      tx[k + 1] = (pp - 2048) >> 1;
      k += 2;
    }
    m.nx = k;
  }
}

/// paq8px LargeStationaryMap (simplified): per hashed (context, partial
/// byte) a 16 bit probability with a count, two inputs.
final class _BitHashMap {
  final Uint32List _t;
  final int _mask;
  final Int32List _idx;
  final int n;
  int _k = 0;
  final Int32List _ctx;

  _BitHashMap(this.n, int bits)
      : _t = Uint32List(1 << bits)..fillRange(0, 1 << bits, 2048 << 20),
        _mask = (1 << bits) - 1,
        _idx = Int32List(n),
        _ctx = Int32List(n);

  void set(int h) {
    _ctx[_k++] = h & 0xFFFFFFFF;
  }

  /// Starts the contexts of a new byte.
  void reset() {
    _k = 0;
  }

  /// Learns the last bit and adds zeros (no contexts for this byte).
  @pragma('vm:unsafe:no-bounds-checks')
  void skipMix(Mixer m, int y) {
    final t = _t;
    final tx = m.tx;
    var k = m.nx;
    final target = y << 22;
    for (var i = 0; i < n; i++) {
      final li = _idx[i];
      final e = t[li];
      final en = e & 1023;
      final ep = e >> 10;
      t[li] = ((ep + (((target - ep) * kDt[en]) >> 31)) << 10) |
          (en < 255 ? en + 1 : en);
      _idx[i] = 0;
      tx[k] = 0;
      tx[k + 1] = 0;
      k += 2;
    }
    m.nx = k;
  }

  @pragma('vm:unsafe:no-bounds-checks')
  void mix(Mixer m, int y, int c0) {
    final t = _t;
    final tx = m.tx;
    var k = m.nx;
    final target = y << 22;
    final dt = kDt;
    final str = kStretch;
    for (var i = 0; i < n; i++) {
      final li = _idx[i];
      final e = t[li];
      final en = e & 1023;
      final ep = e >> 10;
      t[li] = ((ep + (((target - ep) * dt[en]) >> 31)) << 10) |
          (en < 255 ? en + 1 : en);
      final ni = hash2(_ctx[i], c0) & _mask;
      _idx[i] = ni;
      final e2 = t[ni];
      final p = e2 >> 20;
      final conf = e2 & 1023;
      tx[k] = conf == 0 ? 0 : str[p] >> 1;
      tx[k + 1] = conf == 0 ? 0 : (p - 2048) >> 3;
      k += 2;
    }
    m.nx = k;
  }
}

/// Residual contexts with direct probabilities (the light image model):
/// per prediction, the difference between it and the bits of the byte
/// known so far, at two resolutions, each a 16 bit probability.
final class _ResidualBits {
  final int n;
  final Uint16List _t;
  final Int32List _pred;
  final Int32List _idx;

  _ResidualBits(this.n)
      : _t = Uint16List(n * 2 * 4096)..fillRange(0, n * 2 * 4096, 32768),
        _pred = Int32List(n),
        _idx = Int32List(n * 2);

  int get inputs => n * 2;

  void set(int i, int prediction) {
    _pred[i] = prediction;
  }

  @pragma('vm:unsafe:no-bounds-checks')
  void mix(Mixer m, int y, int bpos, int c0) {
    final t = _t;
    final tx = m.tx;
    var k = m.nx;
    final str = kStretch;
    final b = (c0 << (8 - bpos)) & 255;
    final ys = y << 16;
    final coarse = 3 - bpos < 0 ? 0 : 3 - bpos;
    for (var i = 0; i < n; i++) {
      final j = i * 2;
      var li = _idx[j];
      t[li] += (ys - t[li]) >> 5;
      li = _idx[j + 1];
      t[li] += (ys - t[li]) >> 6;
      var r = _pred[i] - b;
      if (r < -255) r = -255;
      if (r > 255) r = 255;
      var rc = r >> coarse;
      if (rc < -32) rc = -32;
      if (rc > 31) rc = 31;
      final a = (i * 2) * 4096 + ((rc + 32) << 3 | bpos);
      final bb = (i * 2 + 1) * 4096 + ((r + 256) << 3 | bpos);
      _idx[j] = a;
      _idx[j + 1] = bb & 0xFFFFFFFF;
      tx[k] = str[t[a] >> 4] >> 1;
      tx[k + 1] = str[t[bb] >> 4] >> 1;
      k += 2;
    }
    m.nx = k;
  }
}

@pragma('vm:prefer-inline')
int _abs(int x) => x < 0 ? -x : x;

@pragma('vm:prefer-inline')
int _clip(int x) => x < 0 ? 0 : (x > 255 ? 255 : x);

// paq8px DiffQt: the signed, quantized difference of two bytes (4 bits).
int _diffQt(int a, int b) {
  var d = _abs(a - b);
  if (d <= 2) {
  } else if (d <= 5) {
    d = 3;
  } else if (d <= 9) {
    d = 4;
  } else if (d <= 14) {
    d = 5;
  } else if (d <= 23) {
    d = 6;
  } else {
    d = 7;
  }
  return (a > b ? 8 : 0) | d;
}

int _paeth(int w, int n, int nw) {
  final p = w + n - nw;
  final pw = _abs(p - w), pn = _abs(p - n), pnw = _abs(p - nw);
  if (pw <= pn && pw <= pnw) return w;
  if (pn <= pnw) return n;
  return nw;
}

/// The image model of image8, image24 and image32 segments.
final class ImageModel implements ZcmModel, ZcmMixerContexts {
  static const int _nPred = 42; // 40 fixed and 2 least squares fits
  static const int _nLight = 12;
  static const int _nCm = 20;
  static const int _nBh = 12;

  final int _np, _ncm;
  final bool _useBh, _smallHist;
  final ContextMap _cm;
  final ResidualMap? _r1;
  final ResidualMap? _r2;
  final _ResidualBits? _rb;
  final _BitHashMap _bh;
  final Int32List _p = Int32List(_nPred);
  // Least squares fits per color plane: features as (dx, dy, planes
  // back) triples of [_px], for color and for gray images, the solve
  // interval and the forgetting factor. paq8px Image24BitModel's six
  // fits (32, 12, 15, 10, 14 and 8 pixels, forgetting 0.7 to 0.98,
  // solved every byte) were tried instead of and beside these: 0.2 to
  // 0.7% larger on photo.bmp, neutral on gray.pgm.
  static const List<List<int>> _olsColor = [
    [1, 0, 0, 0, 1, 0, 1, 1, 0, -1, 1, 0, 2, 0, 0, 0, 2, 0, 2, 1, 0, //
      1, 2, 0, -1, 2, 0, -2, 1, 0, 3, 0, 0, 0, 3, 0, 0, 0, 1, 1, 0, 1, //
      0, 1, 1, 1, 1, 1, -1, 1, 1, 0, 0, 2, 1, 0, 2, 0, 1, 2],
    [1, 0, 0, 0, 1, 0, 1, 1, 0, -1, 1, 0, 2, 0, 0, 0, 2, 0, 2, 1, 0, //
      1, 2, 0, 0, 0, 1, 1, 0, 1, 0, 1, 1, 0, 0, 2],
  ];
  static const List<List<int>> _olsGray = [
    [1, 0, 0, 0, 1, 0, 1, 1, 0, -1, 1, 0, 2, 0, 0, 0, 2, 0, 2, 1, 0, //
      1, 2, 0, -1, 2, 0, -2, 1, 0, 3, 0, 0, 0, 3, 0, -2, 2, 0, 2, 2, 0, //
      -3, 1, 0, 3, 1, 0, -1, 3, 0, 1, 3, 0, 4, 0, 0, 0, 4, 0],
    [1, 0, 0, 0, 1, 0, 1, 1, 0, -1, 1, 0, 2, 0, 0, 0, 2, 0, 2, 1, 0, //
      1, 2, 0, -1, 2, 0, -2, 1, 0, 1, 2, 0, 2, 1, 0],
  ];
  static const List<int> _olsN = [20, 12];
  static const List<int> _olsInterval = [4, 2];
  static const List<double> _olsLambda = [0.996, 0.95];
  final List<List<ZcmOls>> _ols = [
    for (var i = 0; i < 2; i++)
      [
        for (var c = 0; c < 4; c++)
          ZcmOls(_olsN[i], _olsInterval[i], _olsLambda[i])
      ]
  ];
  int _olsPlane = -1;
  Uint8List _err = Uint8List(0);
  int _errMask = 0;
  final Int32List _spread = Int32List(_nPred);

  // Layout of the current segment.
  int _stride = 1, _bpp = 1, _width = 1;
  int _info = -1, _type = -1;
  bool _palette = false;
  // Position of the byte being predicted.
  int _col = 0, _line = 0, _k = -1;
  int _color = 0; // plane, or 4 in the row padding
  // Neighbors of this byte.
  int _w = 0, _n = 0, _nw = 0, _ww = 0, _nn = 0;
  int _p1 = 0, _p2 = 0;
  int _ctx0 = 0, _ctx1 = 0, _act = 0;

  /// [allowance]: bytes for all the tables of the model. [full]: all
  /// predictors, contexts and the bit context map; otherwise about half
  /// of them (faster).
  ImageModel(int allowance, {bool full = true})
      : _np = full ? _nPred : _nLight,
        _ncm = full ? _nCm : 6,
        _useBh = full,
        _cm = ContextMap(_cmBytes(allowance), full ? _nCm : 6, rich: false),
        _r1 = full
            ? ResidualMap(_nPred, _small(allowance) ? 8 * 4 : 32 * 4)
            : null,
        _r2 = full
            ? ResidualMap(_nPred, _small(allowance) ? 4 * 4 : 16 * 4)
            : null,
        _rb = full ? null : _ResidualBits(_nLight),
        _smallHist = _small(allowance),
        _bh = _BitHashMap(full ? _nBh : 0, _bhBits(allowance));

  static bool _small(int allowance) => allowance < (6 << 20);

  static int _residualBytes(int allowance) =>
      _nPred * (_small(allowance) ? 12 : 48) * 4 * 512;

  static int _cmBytes(int allowance) {
    final b = allowance - _residualBytes(allowance) - (4 << _bhBits(allowance));
    return floorPow2(b < (64 << 10) ? 64 << 10 : b);
  }

  static int _bhBits(int allowance) {
    var b = 12;
    while (b < 22 && (4 << (b + 1)) <= allowance ~/ 8) {
      b++;
    }
    return b;
  }

  /// Bytes of the tables of a model with [allowance] (at most that).
  static int tableBytes(int allowance) =>
      _cmBytes(allowance) + (4 << _bhBits(allowance)) + _residualBytes(allowance);

  @override
  int get inputs => _cm.nCtx * _cm.inputsPerContext + _residualInputs +
      _bh.n * 2 + 1;

  int get _residualInputs =>
      _rb != null ? _rb.inputs : _r1!.inputs + _r2!.inputs;

  /// Color plane of the byte being coded (4: row padding).
  int get plane => _color;

  /// Pixels around the byte being coded, for the SSE stage.
  int get pxW => _w;
  int get pxN => _n;
  int get pxWW => _ww;
  int get pxNN => _nn;

  /// 8 bits of neighborhood shape (paq8px Image.ctx).
  int get shapeCtx => ((_color & 3) << 9 | _ctx0) >> 3;

  @override
  List<int> get mixerContextSizes => _useBh
      ? const [4 * 8 + 8, 512 * 4, 256 * 4, 64 * 4 * 4, 16 * 8 * 4, 8 * 8 * 4]
      : const [4 * 8 + 8, 512 * 4];

  void _setup(ZcmState s) {
    _type = s.blockType;
    _info = s.blockInfo;
    _stride = _info & 0xFFFFFF;
    final pad = (_info >> 24) & 3;
    _palette = _type == ZcmBlockType.image8pal;
    _bpp = _type == ZcmBlockType.image8 || _palette
        ? 1
        : (_type == ZcmBlockType.image24 ? 3 : 4);
    _width = _stride - pad;
    if (_width < _bpp) _width = _stride;
    // Errors of every predictor at the last 3 rows (and a few bytes).
    final need = (3 * _stride + 16) * _nPred;
    var size = 1024;
    while (size < need && size < (1 << 23)) {
      size <<= 1;
    }
    if (_err.length != size) {
      _err = Uint8List(size);
    } else {
      _err.fillRange(0, size, 0);
    }
    _errMask = size - 1;
  }

  // Average error of predictor [i] at W, N, NW, NE, WW and NN (paq8px
  // GetPredErrAvg).
  @pragma('vm:prefer-inline')
  int _errAvg(int i) {
    final e = _err;
    final m = _errMask;
    final np = _nPred;
    final k = _k;
    final bpp = _bpp;
    final st = _stride;
    int at(int back) => back > k ? 255 : e[((k - back) * np + i) & m];
    return (2 * at(bpp) +
            2 * at(st) +
            at(st - bpp) +
            at(st + bpp) +
            at(2 * bpp) +
            at(2 * st)) >>
        3;
  }

  // The byte [b] positions before the one [dx] pixels to the left and
  // [dy] rows up (negative dx: to the right), kept on the same plane
  // inside the row; 0 outside the segment.
  int _px(ZcmState s, int dx, int dy, int b) {
    final bpp = _bpp;
    var x = _col - b - dx * bpp;
    while (x < 0) {
      x += bpp;
    }
    while (x >= _width) {
      x -= bpp;
    }
    var y = _line - dy;
    if (y < 0) y = 0;
    final off = _k - (y * _stride + x);
    if (off < 1 || off > _k) return 0;
    return s.back(off);
  }

  static int _round(double v) {
    if (!v.isFinite) return 128;
    if (v > 1e6) return 1000000;
    if (v < -1e6) return -1000000;
    return (v + (v < 0 ? -0.5 : 0.5)).toInt();
  }

  void _pred(int i, int p, int spread) {
    _p[i] = p;
    _spread[i] = spread;
  }

  void _byte(ZcmState s) {
    if (s.blockType != _type || s.blockInfo != _info || s.blockPos == 0) {
      _setup(s);
    }
    final k = s.blockPos;
    if (_k >= 0) {
      final c1 = s.c4 & 255;
      _r1?.update(c1);
      _r2?.update(c1);
      // Remember how far off every prediction of that byte was.
      final base = _k * _nPred;
      for (var i = 0; i < _np; i++) {
        var d = c1 - _p[i];
        if (d < 0) d = -d;
        _err[(base + i) & _errMask] = d > 255 ? 255 : d;
      }
      if (_olsPlane >= 0) {
        final v = c1.toDouble();
        for (final o in _ols) {
          o[_olsPlane].update(v);
        }
        _olsPlane = -1;
      }
    }
    _k = k;
    _col = k % _stride;
    _line = k ~/ _stride;
    if (_col >= _width) {
      _color = 4;
      _k = -1;
      for (var i = 0; i < _ncm; i++) {
        _cm.skip(i);
      }
      return;
    }
    _color = _col % _bpp;
    final c = _color;
    int px(int dx, int dy) => _px(s, dx, dy, 0);
    final w = px(1, 0), n = px(0, 1), nw = px(1, 1), ne = px(-1, 1);
    final ww = px(2, 0), nn = px(0, 2), nnw = px(1, 2), nne = px(-1, 2);
    final nww = px(2, 1), nee = px(-2, 1), www = px(3, 0), nnn = px(0, 3);
    final nnee = px(-2, 2), nnww = px(2, 2), neee = px(-3, 1);
    _w = w;
    _n = n;
    _nw = nw;
    _ww = ww;
    _nn = nn;
    final multi = _bpp > 1;
    final p1 = multi ? s.back(1) : w;
    final p2 = multi ? s.back(2) : ww;
    _p1 = p1;
    _p2 = p2;
    // Planes of the neighbors one and two back (p1, p2 at W, N, NE, NW).
    var wp1 = 0, np1 = 0, nep1 = 0, nwp1 = 0, wp2 = 0, np2 = 0;
    if (multi) {
      wp1 = _px(s, 1, 0, 1);
      np1 = _px(s, 0, 1, 1);
      nep1 = _px(s, -1, 1, 1);
      nwp1 = _px(s, 1, 1, 1);
      wp2 = _px(s, 1, 0, 2);
      np2 = _px(s, 0, 1, 2);
    }
    // Numeric predictions (paq8px MakePrediction*), with a spread.
    var i = 0;
    _pred(i++, w, _abs(w - nw));
    _pred(i++, n, _abs(n - nw));
    _pred(i++, w + n - nw, _abs(n - nw) + _abs(w - nw));
    _pred(i++, w + ne - n, _abs(ne - n));
    _pred(i++, n + ne - nne, _abs(ne - nne));
    _pred(i++, n + nw - nnw, _abs(nw - nnw));
    _pred(i++, n * 2 - nn, _abs(n - nn));
    _pred(i++, w * 2 - ww, _abs(w - ww));
    _pred(i++, (w + n + 1) >> 1, _abs(w - n));
    _pred(i++, (w + ne + 1) >> 1, _abs(w - ne));
    _pred(i++, (n + ne + 1) >> 1, _abs(n - ne));
    _pred(i++, (w + nee + 1) >> 1, _abs(w - nee));
    _pred(i++, _paeth(w, n, nw), _abs(n - nw));
    _pred(i++, nw + w - nww, _abs(nw - nww));
    _pred(i++, w + nee - ne, _abs(nee - ne));
    _pred(i++, ne * 2 - nnee, _abs(ne - nnee));
    _pred(i++, nw * 2 - nnww, _abs(nw - nnww));
    _pred(i++, n * 3 - nn * 3 + nnn, _abs(n - nn));
    _pred(i++, w * 3 - ww * 3 + www, _abs(w - ww));
    _pred(i++, (n * 3 + w * 3 - nn - ww + 2) >> 2, _abs(n - w));
    _pred(i++, (w * 2 - ww) + (n * 2 - nn) - (nw * 2 - nnww), _abs(w - n));
    _pred(i++, (8 * w - 3 * ww + (3 * nee - 3 * px(-2, 2) + px(-2, 3))) ~/ 6,
        _abs(w - nee));
    _pred(i++, (w + neee + 1) >> 1, _abs(w - neee));
    _pred(i++, ne + nw - nn, _abs(ne - nw));
    _pred(i++, nn + w - nnw, _abs(nn - nnw));
    _pred(i++, (w + n + ne + nw + 2) >> 2, _abs(w - ne));
    if (_np <= _nLight) {
      if (multi) {
        // The strongest color predictors instead of three plane ones.
        final wwp1 = _px(s, 2, 0, 1);
        _pred(9, w * 2 - ww + p1 - (wp1 * 2 - wwp1), _abs(p1 - wp1));
        _pred(10, w + p1 - wp1, _abs(p1 - wp1));
        _pred(11, n + p1 - np1, _abs(p1 - np1));
      }
    } else if (multi) {
      _pred(i++, p1, 0);
      _pred(i++, n + p1 - np1, _abs(p1 - np1));
      _pred(i++, w + p1 - wp1, _abs(p1 - wp1));
      _pred(i++, ne + p1 - nep1, _abs(p1 - nep1));
      _pred(i++, nw + p1 - nwp1, _abs(p1 - nwp1));
      _pred(i++, (n + p1 - np1 + w + p1 - wp1 + 1) >> 1, _abs(np1 - wp1));
      _pred(i++, w + n - nw + p1 - (wp1 + np1 - nwp1), _abs(p1 - wp1));
      _pred(i++, (w + (p1 - wp1) + w + 1) >> 1, _abs(p1 - wp1));
      _pred(i++, (n + (p1 - np1) + n + 1) >> 1, _abs(p1 - np1));
      _pred(i++, p2, 0);
      _pred(i++, n + p2 - np2, _abs(p2 - np2));
      _pred(i++, w + p2 - wp2, _abs(p2 - wp2));
      _pred(i++, (p1 + p2 + 1) >> 1, _abs(p1 - p2));
      _pred(i++, w + ((p1 - wp1) + (p2 - wp2)) ~/ 2, _abs(p1 - wp1));
    } else {
      _pred(i++, (n + nn + 1) >> 1, _abs(n - nn));
      _pred(i++, (w + ww + 1) >> 1, _abs(w - ww));
      _pred(i++, (ne + nne + 1) >> 1, _abs(ne - nne));
      _pred(i++, (nw + nnw + 1) >> 1, _abs(nw - nnw));
      _pred(i++, _clip(w + n - nw) + (w - ww) ~/ 2, _abs(w - ww));
      _pred(i++, n + (n - nn) ~/ 2, _abs(n - nn));
      _pred(i++, w + (w - ww) ~/ 2, _abs(w - ww));
      _pred(i++, (nn + ww + 1) >> 1, _abs(nn - ww));
      _pred(i++, (ne * 2 + w * 2 - nne - ww + 1) >> 1, _abs(ne - w));
      _pred(i++, nee, _abs(nee - ne));
      _pred(i++, (w + nee + ne + n + 2) >> 2, _abs(w - n));
      _pred(i++, www, _abs(www - ww));
      _pred(i++, nnn, _abs(nnn - nn));
      _pred(i++, (nne + nnw + 1) >> 1, _abs(nne - nnw));
    }
    if (_np > 40) {
      // Least squares fits over the neighborhood (paq8px OLS).
      _olsPlane = c;
      for (var q = 0; q < 2; q++) {
        final o = _ols[q][c];
        final offs = multi ? _olsColor[q] : _olsGray[q];
        for (var f = 0; f < offs.length; f += 3) {
          o.add(_px(s, offs[f], offs[f + 1], offs[f + 2]).toDouble());
        }
        _pred(i++, _round(o.predict()), _abs(w - n));
      }
    }
    // Activity: local gradients, quantized.
    var act = _abs(w - nw) + _abs(n - nw) + _abs(n - ne) + _abs(w - ww);
    act = act < 2 ? act : (act < 64 ? 2 + (kIlog[act] >> 4) - 1 : 7);
    if (act > 7) act = 7;
    _act = act;
    final rb = _rb;
    if (rb != null) {
      for (var j = 0; j < _np; j++) {
        rb.set(j, _p[j]);
      }
    }
    final r1 = _r1, r2 = _r2;
    final small = _smallHist;
    for (var j = 0; j < (r1 == null ? 0 : _np); j++) {
      var sp = _spread[j];
      if (small) {
        sp = sp < 2 ? sp : (sp < 64 ? 2 + (kIlog[sp] >> 4) - 1 : 7);
        if (sp > 7) sp = 7;
        r1!.set(_p[j], sp << 2 | c);
        r2!.set(_p[j], (act >> 1) << 2 | c);
      } else {
        final ea = _errAvg(j);
        r1!.set(_p[j], (ea > 31 ? 31 : ea) << 2 | c);
        final sq = sp >> 1;
        r2!.set(_p[j], (sq > 15 ? 15 : sq) << 2 | c);
      }
    }
    if (_palette) {
      _paletteContexts(w, n, nw, ne, ww, nn, nne, nnw, nww, nee);
      _mixCtx(s, w, n, nw, ne, ww, nn, nne, nnw, p1, np1, nep1);
      return;
    }
    if (!multi) {
      _grayContexts(s, w, n, nw, ne, ww, nn, nnn, nnw, nww, nee, www, nnee,
          nnww);
      _mixCtx(s, w, n, nw, ne, ww, nn, nne, nnw, p1, np1, nep1);
      return;
    }
    // Hashed contexts (paq8px Image24BitModel cm).
    var h = c * 64;
    final cm = _cm;
    final nc = _ncm;
    var j = 0;
    void put(int x) {
      if (j < nc) cm.set(j, x);
      j++;
    }

    put(hash3(++h, w, p1));
    put(hash3(++h, w, p2));
    put(hash3(++h, n, p1));
    put(hash3(++h, n, p2));
    put(hash3(++h, p1, p2));
    put(hash4(++h, n, nn, p1));
    put(hash4(++h, w, ww, p1));
    put(hash4(++h, w, (p1 - wp1) & 511, (p2 - wp2) & 511));
    put(hash4(++h, n, (p1 - np1) & 511, (p2 - np2) & 511));
    put(hash4(++h, nw, (p1 - nwp1) & 511, ne));
    put(hash4(++h, w, ww, n << 8 | nn));
    put(hash4(++h, w, n, ne << 8 | nw));
    if (_ncm > j) {
      _cmRest(s, j, h, w, n, nw, ne, ww, nn, nnn, nne, nee, www, p1, p2, wp1,
          np1, wp2, np2);
    }
    if (_useBh) {
      _bhSet(c, w, n, nw, ne, nne, p1, p2, np1, np2);
    }
    _mixCtx(s, w, n, nw, ne, ww, nn, nne, nnw, p1, np1, nep1);
  }

  // The contexts of palette images (paq8px Image8BitModel, !isGray): the
  // indexes are not intensities, so only their combinations are hashed.
  void _paletteContexts(int w, int n, int nw, int ne, int ww, int nn,
      int nne, int nnw, int nww, int nee) {
    final cm = _cm;
    final nc = _ncm;
    var h = 2048;
    var j = 0;
    void put(int x) {
      if (j < nc) cm.set(j, hash2(++h, x));
      j++;
    }

    put(w);
    put(n);
    put(w | n << 8);
    put(w | ne << 8);
    put(n | nn << 8);
    put(w | ww << 8);
    put(hash4(w, n, nw, ne));
    put(hash4(w, ww, n, nn));
    put(hash4(n, nw, ne, nne));
    put(hash4(w, nw, nww, ww));
    put(hash3(n, ne, nee));
    put(hash3(w, n, nnw));
    put(nw | ne << 8);
    put(hash4(w, n, ne, nn << 8 | ww));
    put(hash2(_width, _col));
    put(hash3(w, n, _col));
    put(nw);
    put(ne);
    put(hash3(ww, nn, nw));
    put(hash4(w, ww, nw, n << 8 | ne));
  }

  // The contexts of gray images (paq8px Image8BitModel, gray).
  void _grayContexts(ZcmState s, int w, int n, int nw, int ne, int ww,
      int nn, int nnn, int nnw, int nww, int nee, int www, int nnee,
      int nnww) {
    final cm = _cm;
    final nc = _ncm;
    var h = 1024;
    var j = 0;
    void put(int x) {
      if (j < nc) cm.set(j, hash2(++h, x));
      j++;
    }

    put(n);
    put(nw);
    put(ne);
    put(n | nn << 8);
    put(ne | nnee << 8);
    put(nw | nnww << 8);
    put(w | nee << 8);
    put(n | nn << 8 | nnn << 16);
    put(hash4(w, ww, n, nn));
    put(hash4(w, n, ne, nw));
    put(((nnn + n + 4) >> 3) | (_clip(n * 3 - nn * 3 + nnn) >> 1) << 8);
    put((_clip(n * 2 - nn) >> 1) | _diffQt(n, _clip(nn * 2 - nnn)) << 8);
    put((_clip(w * 2 - ww) >> 1) | _diffQt(w, _clip(ww * 2 - www)) << 8);
    put(_clip(n * 2 - nn) | _diffQt(w, _clip(nw * 2 - nnw)) << 8);
    put(_clip(w * 2 - ww) | _diffQt(n, _clip(nw * 2 - nww)) << 8);
    put(((w + nee + 1) >> 1) | _diffQt(w, (ww + ne + 1) >> 1) << 8);
    put(_clip(w + nee - ne) | _diffQt(w, _clip(ww + ne - n)) << 8);
    final x = _col;
    final d7 = (x >> 10) > 7 ? x >> 10 : 7;
    final d17 = (x >> 9) > 17 ? x >> 9 : 17;
    final d29 = (x >> 8) > 29 ? x >> 8 : 29;
    put(hash2(_width, x ~/ d7));
    put(hash3(_width, x ~/ d17, _line ~/ 17));
    put(hash3(_width, x ~/ d29, (_clip(w + n - nw) >> 1) | (w >> 2) << 8));
  }

  void _cmRest(ZcmState s, int j, int h, int w, int n, int nw, int ne, int ww,
      int nn, int nnn, int nne, int nee, int www, int p1, int p2, int wp1,
      int np1, int wp2, int np2) {
    final cm = _cm;
    cm.set(j++,
        hash3(++h, (nnn + n + 4) >> 3, _clip(n * 3 - nn * 3 + nnn) >> 1));
    cm.set(j++, hash4(++h, _clip(w + n - nw) >> 1, _clip(w + p1 - wp1) >> 3,
        _clip(n + p1 - np1) >> 3));
    cm.set(j++, hash4(++h, w >> 2, _diffQt(w, p1), _diffQt(w, p2)));
    cm.set(j++, hash4(++h, n >> 2, _diffQt(n, p1), _diffQt(n, p2)));
    cm.set(j++, hash4(++h, (w + n + 4) >> 3, p1 >> 4, p2 >> 4));
    cm.set(j++,
        hash3(++h, _clip(n * 2 - nn) >> 1, _diffQt(n, _clip(nn * 2 - nnn))));
    cm.set(j++,
        hash3(++h, _clip(w * 2 - ww) >> 1, _diffQt(w, _clip(ww * 2 - www))));
    cm.set(j, hash3(++h, (w + nee + 1) >> 1, _diffQt(w, (ww + ne + 1) >> 1)));
  }

  void _bhSet(int c, int w, int n, int nw, int ne, int nne, int p1, int p2,
      int np1, int np2) {
    // Bit contexts of the neighborhood (paq8px mapL).
    final bh = _bh;
    bh.reset();
    var g = c * 32;
    bh.set(hash2(++g, p2));
    bh.set(hash3(++g, p1, p2));
    bh.set(hash3(++g, w, p2));
    bh.set(hash4(++g, w, p1, p2));
    bh.set(hash4(++g, n, np1, np2));
    bh.set(hash4(++g, w, p1, p2 << 8 | n));
    bh.set(hash4(++g, n, ne, p1));
    bh.set(hash4(++g, nw, ne, p1));
    bh.set(hash3(++g, _clip(w + n - nw) >> 1, p1));
    bh.set(hash4(++g, _clip(w + n - nw) >> 1, p1, p2));
    bh.set(hash3(++g, _clip(n + ne - nne) >> 1, p1));
    bh.set(hash4(++g, _paeth(w, n, nw) >> 1, p1, p2));
  }

  void _mixCtx(ZcmState s, int w, int n, int nw, int ne, int ww, int nn,
      int nne, int nnw, int p1, int np1, int nep1) {
    // Mixer contexts.
    _ctx0 = (_abs(w - nw) > 3 ? 256 : 0) |
        (_abs(nw - n) > 3 ? 128 : 0) |
        (_abs(n - ne) > 3 ? 64 : 0) |
        (n > nw ? 32 : 0) |
        (n > ne ? 16 : 0) |
        (n > nn ? 8 : 0) |
        (w > n ? 4 : 0) |
        (w > nw ? 2 : 0) |
        (w > ww ? 1 : 0);
    _ctx1 = _diffQt(p1, _clip(np1 + nep1 - _px(s, -1, 2, 0))) << 4 |
        _diffQt(_clip(n + ne - nne), _clip(n + nw - nnw));
  }

  @override
  void mix(ZcmState s, Mixer m) {
    final bpos = s.bpos;
    if (bpos == 0) _byte(s);
    _cm.mix(m, s.y, bpos, s.c0, s.c4 & 255);
    if (_color == 4) {
      // Row padding: no residual inputs.
      final tx = m.tx;
      var k = m.nx;
      final n = _residualInputs;
      for (var i = 0; i < n; i++) {
        tx[k++] = 0;
      }
      m.nx = k;
      _bh.skipMix(m, s.y);
      m.add(-2047);
      return;
    }
    final rb = _rb;
    if (rb != null) {
      rb.mix(m, s.y, bpos, s.c0);
    } else {
      _r1!.mix(m, bpos, s.c0);
      _r2!.mix(m, bpos, s.c0);
    }
    _bh.mix(m, s.y, s.c0);
    m.add(0);
  }

  @override
  void setMixerContexts(ZcmState s, Mixer m) {
    final bpos = s.bpos;
    final c = _color;
    if (c == 4) {
      m.set(32 + bpos);
      m.set(0);
      if (!_useBh) return;
      m.set(0);
      m.set(0);
      m.set(0);
      m.set(0);
      return;
    }
    final cc = c & 3;
    m.set(cc << 3 | bpos);
    m.set(_ctx0 << 2 | cc);
    if (!_useBh) return;
    m.set(_ctx1 << 2 | cc);
    m.set((_act << 3 | bpos) << 2 | cc);
    final c0 = s.c0;
    final pr1 = 0x100 | ((_n + _w + 1) >> 1);
    final pr2 = 0x100 | (_clip(_n + _w - _nw));
    final pr3 = 0x100 | (_clip(2 * _n - _nn));
    final pr4 = 0x100 | (_clip(2 * _w - _ww));
    final sh = 8 - bpos;
    m.set(((c0 == (pr1 >> sh) ? 8 : 0) |
                (c0 == (pr2 >> sh) ? 4 : 0) |
                (c0 == (pr3 >> sh) ? 2 : 0) |
                (c0 == (pr4 >> sh) ? 1 : 0)) <<
            5 |
        bpos << 2 |
        cc);
    m.set((_p1 >> 5) << 5 | (_p2 >> 5) << 2 | (bpos >> 1));
  }
}


/// Images with 1 or 4 bits per pixel (after paq8px Image1BitModel and
/// Image4BitModel): the pixels around the one being coded, read from the
/// rows above and the bits of the current row, select adaptive
/// probabilities (22 bits and a count, like paq8px's StateMap) in hashed
/// tables, one that keeps adapting fast and one that settles.
final class ZcmBitImageModel implements ZcmModel, ZcmMixerContexts {
  static const int _nCtx = 8;
  final int _bits;
  final Uint32List _t;
  final Int32List _idx = Int32List(_nCtx);
  final Int32List _ctx = Int32List(_nCtx);
  int _info = -1, _type = -1;
  int _stride = 1, _width = 1;
  int _mctx = 0;

  /// [allowance]: bytes for the tables.
  ZcmBitImageModel(int allowance)
      : _bits = _bitsFor(allowance),
        _t = Uint32List(_nCtx * 2 << _bitsFor(allowance))
          ..fillRange(0, _nCtx * 2 << _bitsFor(allowance), 1 << 31);

  static int _bitsFor(int allowance) {
    var b = 12;
    while (b < 20 && (_nCtx * 8 << (b + 1)) <= allowance) {
      b++;
    }
    return b;
  }

  /// Bytes of the tables of a model with [allowance].
  static int tableBytes(int allowance) => _nCtx * 8 << _bitsFor(allowance);

  @pragma('vm:prefer-inline')
  static int _learn(int e, int y, int limit) {
    final n = e & 1023;
    final p = e >> 10;
    return ((p + ((((y << 22) - p) * kDt[n]) >> 30)) << 10) |
        (n < limit ? n + 1 : n);
  }

  @override
  int get inputs => _nCtx * 2 + 1;

  @override
  List<int> get mixerContextSizes => const [2048, 64];

  // The byte of the image at row [row] and byte column [col] (absolute,
  // already coded); 0 outside
  // (s.blockPos is the byte being coded).
  @pragma('vm:prefer-inline')
  int _byteAt(ZcmState s, int row, int col) {
    if (row < 0 || col < 0 || col >= _width) return 0;
    final k = s.blockPos;
    final off = k - (row * _stride + col);
    if (off < 1 || off > k) return 0;
    return s.back(off);
  }

  // Pixel [x] of row [row] (1 bit or a nibble), 0 outside.
  int _pix(ZcmState s, int row, int x, int line, int col, int c0, int bpos) {
    if (x < 0) return 0;
    if (_type == ZcmBlockType.image1) {
      final bc = x >> 3;
      int v;
      if (row == line && bc == col) {
        final sh = bpos - 1 - (x & 7);
        if (sh < 0) return 0;
        v = c0 >> sh;
      } else {
        v = _byteAt(s, row, bc) >> (7 - (x & 7));
      }
      return v & 1;
    }
    final bc = x >> 1;
    if (row == line && bc == col) {
      // Only the high nibble of the current byte can be complete.
      if ((x & 1) != 0 || bpos < 4) return 0;
      return (c0 >> (bpos - 4)) & 15;
    }
    final v = _byteAt(s, row, bc);
    return (x & 1) == 0 ? v >> 4 : v & 15;
  }

  @override
  @pragma('vm:unsafe:no-bounds-checks')
  void mix(ZcmState s, Mixer m) {
    final bpos = s.bpos;
    final c0 = s.c0;
    final y = s.y;
    final t = _t;
    // Learn the last bit.
    for (var i = 0; i < _nCtx; i++) {
      final a = _idx[i];
      t[a] = _learn(t[a], y, 20);
      final b = a + (1 << _bits);
      t[b] = _learn(t[b], y, 255);
    }
    if (bpos == 0 && (s.blockType != _type || s.blockInfo != _info)) {
      _type = s.blockType;
      _info = s.blockInfo;
      _stride = _info & 0xFFFFFF;
      _width = _stride - ((_info >> 24) & 3);
      if (_width < 1) _width = _stride;
    }
    final k = s.blockPos;
    final col = k % _stride;
    final line = k ~/ _stride;
    final mask = (1 << _bits) - 1;
    final ctx = _ctx;
    if (col >= _width) {
      // Row padding.
      for (var i = 0; i < _nCtx; i++) {
        ctx[i] = hash2(i, bpos);
      }
      _mctx = 1024 + bpos;
    } else if (_type == ZcmBlockType.image1) {
      final x = col * 8 + bpos;
      int row(int r, int from, int n) {
        var v = 0;
        for (var d = from; d < from + n; d++) {
          v = v << 1 | _pix(s, line - r, x + d, line, col, c0, bpos);
        }
        return v;
      }

      final r0 = row(0, -12, 12); // the bits to the left
      final r1 = row(1, -5, 11); // row above, x-5 .. x+5
      final r2 = row(2, -3, 7);
      final r3 = row(3, -2, 5);
      ctx[0] = (r0 & 0xFF) | (r1 >> 3 & 0x1F) << 8;
      ctx[1] = (r0 & 0xF) | (r1 >> 2 & 0x7F) << 4 | (r2 >> 1 & 0x1F) << 11;
      ctx[2] = (r0 & 3) | (r1 >> 4 & 7) << 2 | (r2 >> 2 & 7) << 5 |
          (r3 >> 1 & 7) << 8;
      ctx[3] = r0 & 0xFFF;
      ctx[4] = r1 | (r0 & 3) << 11;
      ctx[5] = (r0 & 0x3F) | (r1 >> 3 & 0x1F) << 6 | (r2 >> 2 & 7) << 11 |
          (r3 >> 2 & 1) << 14;
      ctx[6] = hash3(r0 & 0x3FF, r1, r2);
      ctx[7] = hash4(r0 & 0xFFF, r1, r2, r3);
      for (var i = 0; i < _nCtx; i++) {
        ctx[i] = hash2(ctx[i], i);
      }
      _mctx = (r0 & 0xF) | (r1 >> 4 & 7) << 4 | (r2 >> 3 & 1) << 7 |
          (bpos & 3) << 8;
    } else {
      final x = col * 2 + (bpos >> 2);
      final part = bpos < 4 ? c0 : (c0 & ((1 << (bpos - 4)) - 1)) |
          (1 << (bpos - 4));
      int px(int dx, int dy) =>
          _pix(s, line - dy, x - dx, line, col, c0, bpos);
      final w = px(1, 0), n = px(0, 1), nw = px(1, 1), ne = px(-1, 1);
      final ww = px(2, 0), nn = px(0, 2), nne = px(-1, 2), nee = px(-2, 1);
      ctx[0] = w | n << 4 | nw << 8 | ne << 12;
      ctx[1] = w | ww << 4 | n << 8 | nn << 12;
      ctx[2] = n | nn << 4 | ne << 8 | nne << 12;
      ctx[3] = w | n << 4;
      ctx[4] = w;
      ctx[5] = n | ne << 4 | nee << 8;
      ctx[6] = hash4(w, n, nw, ne << 4 | ww << 8 | nn << 12);
      ctx[7] = hash3(w, x, line & 7);
      for (var i = 0; i < _nCtx; i++) {
        ctx[i] = hash3(ctx[i], i, part);
      }
      _mctx = 512 | (w == n ? 1 : 0) << 8 | (n == ne ? 1 : 0) << 7 |
          (w == nw ? 1 : 0) << 6 | (bpos & 3) << 4 | part & 15;
    }
    final tx = m.tx;
    var kk = m.nx;
    final str = kStretch;
    for (var i = 0; i < _nCtx; i++) {
      final a = (i * 2 << _bits) + (ctx[i] & mask);
      _idx[i] = a;
      tx[kk] = str[t[a] >> 20];
      tx[kk + 1] = str[t[a + (1 << _bits)] >> 20];
      kk += 2;
    }
    m.nx = kk;
    m.add(256);
  }

  @override
  void setMixerContexts(ZcmState s, Mixer m) {
    m.set(_mctx & 2047);
    m.set(s.bpos << 3 | (_type == ZcmBlockType.image1 ? 0 : 1));
  }
}
