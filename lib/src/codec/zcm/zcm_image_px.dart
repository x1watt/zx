// zcm: the image models of paq8px as whole models (levels 7 to 9).
//
// Ports of paq8px's Image24BitModel and Image8BitModel (grayscale part),
// with their mixer weight set selectors and their SSE stages (SSE.cpp,
// IMAGE24 and IMAGE8GRAY). paq8px image models: Marcio Pais (from his
// Emma), Zoltan Gotthardt, Sebastian Lehmann (the least squares fits) and
// the paq8px authors, after the im8/im24 models of paq8 by Matt Mahoney.
// The owner decided that zcm may port paq8px code freely (credits in the
// file headers, the README and LICENSE).
//
// What differs from paq8px: the hashes (zcm's own), the context map
// (zcm's ContextMap in rich mode: the lpaq run input and five state
// inputs instead of paq8px's run map and four), the least squares fits
// in doubles (paq8px uses floats) solved with +, -, *, / and zcm's own
// square root, the table sizes (from zcm's budget), the loss of a bit
// from zcm's 16 bit final probability, and the gray model has no scene
// (previous frame) maps and no repeated-run jumps (single images).

import 'dart:typed_data';

import 'zcm_components.dart';
import 'zcm_maps.dart'
    show ResidualMap, ZcmLargeStationaryMap, ZcmStationaryMap;
import 'zcm_models.dart';
import 'zcm_ols.dart';
import 'zcm_tables.dart';

@pragma('vm:prefer-inline')
int _rabs(int a, int b) => a > b ? a - b : b - a;

@pragma('vm:prefer-inline')
int _clip(int x) => x < 0 ? 0 : (x > 255 ? 255 : x);

@pragma('vm:prefer-inline')
int _avg(int x, int y) => (x + y + 1) >> 1;

// paq8px DiffQt (its arguments are bytes).
int _diffQt(int a, int b) {
  a &= 255;
  b &= 255;
  var d = a > b ? a - b : b - a;
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
  final pw = (p - w).abs(), pn = (p - n).abs(), pnw = (p - nw).abs();
  if (pw <= pn && pw <= pnw) return w;
  if (pn <= pnw) return n;
  return nw;
}

int _gap(int w, int n, int nw, int ne, int ww, int nne, int nn) {
  final dh = (w - ww).abs() + (n - nw).abs() + (ne - n).abs();
  final dv = (w - nw).abs() + (n - nn).abs() + (ne - nne).abs();
  if (dh > dv) return n;
  if (dv > dh) return w;
  return n + w - nw;
}

// paq8px clamp4: [px] limited to the range of four bytes.
int _clamp4(int px, int a, int b, int c, int d) {
  var hi = a, lo = a;
  if (b > hi) hi = b;
  if (c > hi) hi = c;
  if (d > hi) hi = d;
  if (b < lo) lo = b;
  if (c < lo) lo = c;
  if (d < lo) lo = d;
  return px < lo ? lo : (px > hi ? hi : px);
}

int _ilog2(int x) => x <= 0 ? 0 : x.bitLength - 1;

// roundf, then the conversion to short.
int _roundShort(double v) {
  if (!v.isFinite) return 0;
  if (v > 32767) return 32767;
  if (v < -32768) return -32768;
  return (v + (v < 0 ? -0.5 : 0.5)).toInt();
}

int _h5(int a, int b, int c, int d, int e) => hash2(hash4(a, b, c, d), e);
int _h6(int a, int b, int c, int d, int e, int f) =>
    hash2(_h5(a, b, c, d, e), f);
int _h7(int a, int b, int c, int d, int e, int f, int g) =>
    hash2(_h6(a, b, c, d, e, f), g);

@pragma('vm:prefer-inline')
void _mp(Int32List pr, int i, int r1, int r2, int p) {
  pr[i] = _rabs(r1 & 255, r2 & 255) << 16 | (p & 65535);
}

@pragma('vm:prefer-inline')
void _mc(Int32List pr, int i, int p) {
  pr[i] = p & 65535;
}

@pragma('vm:prefer-inline')
void _mavg(Int32List pr, int i, int a, int b) {
  pr[i] = (_rabs(a, b) & 65535) << 16 | (_avg(a, b) & 65535);
}

@pragma('vm:prefer-inline')
void _mt(Int32List pr, int i, int px, int far, int origin) {
  pr[i] = (_rabs(px, far) & 65535) << 16 | ((origin + px - far) & 65535);
}

@pragma('vm:prefer-inline')
void _ms(Int32List pr, int i, int px, int far, int origin) {
  pr[i] = (_rabs(px, far) & 65535) << 16 |
      (_avg(origin, origin + px - far) & 65535);
}

// The features of paq8px's least squares fits (olsCtx1 to olsCtx6) as
// indexes of the neighborhood list (_nb: olsCtx1's 32 pixels, p1, p2).
const List<List<int>> _olsIdx24 = [
  [
    0,
    1,
    2,
    3,
    4,
    5,
    6,
    7,
    8,
    9,
    10,
    11,
    12,
    13,
    14,
    15,
    16,
    17,
    18,
    19,
    20,
    21,
    22,
    23,
    24,
    25,
    26,
    27,
    28,
    29,
    30,
    31
  ],
  [3, 4, 5, 8, 9, 10, 11, 12, 17, 18, 19, 24],
  [10, 11, 12, 13, 14, 18, 19, 20, 21, 24, 25, 26, 28, 29, 30],
  [10, 11, 12, 13, 18, 19, 20, 24, 25, 28],
  [2, 3, 4, 5, 7, 8, 9, 10, 16, 17, 18, 23, 24, 28],
  [3, 4, 5, 24, 18, 10, 32, 33],
];

/// A byte ring buffer (paq8px RingBuffer): [back] 1 is the last added.
final class _Ring {
  Uint8List b = Uint8List(1);
  int _mask = 0;
  int _pos = 0;

  void setSize(int n, int fill) {
    var size = 1;
    while (size < n) {
      size <<= 1;
    }
    if (b.length != size) b = Uint8List(size);
    b.fillRange(0, size, fill);
    _mask = size - 1;
    _pos = 0;
  }

  @pragma('vm:prefer-inline')
  void add(int v) {
    b[_pos & _mask] = v;
    _pos++;
  }

  @pragma('vm:prefer-inline')
  int back(int i) => b[(_pos - i) & _mask];
}

/// The SSE stages of paq8px for images (SSE.cpp, IMAGE24 and IMAGE8GRAY).
/// [bits]: the bits of the hashed contexts (16 in paq8px).
final class ZcmImageSse {
  final ApmPx _a0, _a1, _a2, _a3;
  final Apm1 _b1, _b2;
  final ApmPost _postA, _postB;
  final int _mask;
  final bool _gray;

  ZcmImageSse(int bits, {required bool gray})
      : _gray = gray,
        _a0 = ApmPx(gray ? 1 << 11 : 1 << 7, 24),
        _a1 = ApmPx(1 << bits, 24),
        _a2 = ApmPx(gray ? 256 * 257 : 1 << bits, 24),
        _a3 = ApmPx(gray ? 1 : 1 << bits, 24),
        _b1 = Apm1(gray ? 1 : 1 << 15, 7),
        _b2 = Apm1(gray ? 1 : 1 << bits, 7),
        _postA = ApmPost(8),
        _postB = ApmPost(8),
        _mask = (1 << bits) - 1;

  /// Bytes of the tables.
  static int bytesFor(int bits, bool gray) => gray
      ? ((1 << 11) + (1 << bits) + 256 * 257) * 24 * 4 + 2 * 8 * 4096 * 8
      : ((1 << 7) + 3 * (1 << bits)) * 24 * 4 +
          ((1 << 15) + (1 << bits)) * 33 * 2 +
          2 * 8 * 4096 * 8;

  /// The final probability (16 bits) from the mixer's [pr] (12 bits).
  int p(int y, int pr, int c0, int bpos, int m3, PxImageModel img, int e) {
    var r = 0;
    if (_gray) {
      final ctx = img.sseCtx;
      final p0 = _a0.pp(y, pr, c0 << 3 | (bpos == 0 ? 0 : (m3 & 3)));
      final p1 = _a1.pp(y, p0 >> 4, (c0 << 8 | ctx) & _mask);
      final p2 = _a2.pp(y, pr, (bpos | (ctx & 0xF8)) * 257 + e);
      final pa = (2 * (pr << 4) + p1 + p2 + 2) >> 2;
      r = (_postA.pp(y, p0 >> 4, bpos) + _postB.pp(y, pa >> 4, bpos) + 1) >> 1;
    } else {
      final plane = img.plane & 3;
      final lossQ = img.lossQ;
      final p0 =
          _a0.pp(y, pr, plane << 5 | bpos << 2 | (bpos == 0 ? 0 : (m3 & 3)));
      final p1 = _a1.pp(y, pr, hash3(c0, img.pxW, img.pxWW) & _mask);
      final p2 = _a2.pp(y, pr, hash3(c0, img.pxN, img.pxNN) & _mask);
      final p3 = _a3.pp(y, pr, (c0 << 8 | img.sseCtx) & _mask);
      final pa = ((pr << 4) + p1 + p2 + p3 + 2) >> 2;
      final p4 = _b1.pp(y, p0 >> 4, (lossQ >> 2) << 5 | plane << 3 | bpos);
      final p5 = _b2.pp(
          y, p0 >> 4, hash3(c0, lossQ > 255 ? 255 : lossQ, plane) & _mask);
      final pb = (p0 * 2 + p4 * 3 + p5 * 3 + 4) >> 3;
      r = (_postA.pp(y, pa >> 4, bpos) + _postB.pp(y, pb >> 4, bpos) + 1) >> 1;
    }
    return r < 1 ? 1 : (r > 65535 ? 65535 : r);
  }
}

/// What the predictor needs from a paq8px image model.
abstract class PxImageModel implements ZcmModel, ZcmMixerContexts {
  /// The final probability of the last bit (16 bits), set by the
  /// predictor: the models keep the coding cost of the pixels.
  int finalP = 32768;

  /// Color plane (0 to 3; 4: row padding).
  int get plane;
  int get lossQ;
  int get sseCtx;
  int get pxW;
  int get pxN;
  int get pxWW;
  int get pxNN;

  /// Computes the byte contexts (at bpos 0) before the mixer is chosen.
  void prepare(ZcmState s);
}

/// paq8px Image24BitModel: 24 and 32-bit pixels.
final class PxImage24Model extends PxImageModel {
  static const int nRM = 122;
  static const int nOLS = 6;
  static const int nLSM = 40;
  static const int nCM = 31;
  static const int _nP = nRM + nOLS;

  static const List<double> _lambda = [0.98, 0.87, 0.9, 0.8, 0.9, 0.7];
  static const List<int> _num = [32, 12, 15, 10, 14, 8];

  final ContextMap _cm;
  final ResidualMap _r1 = ResidualMap(nRM, 1 << 7, scale: 74);
  final ResidualMap _r2 = ResidualMap(nRM, 1 << 5, scale: 74);
  final ResidualMap _r3 = ResidualMap(nRM, 1 << 7, scale: 74);
  final ResidualMap _o1 = ResidualMap(nOLS, 1 << 7, scale: 74);
  final ResidualMap _o2 = ResidualMap(nOLS, 1 << 5, scale: 74);
  final ZcmLargeStationaryMap _mapL;
  final List<List<ZcmOls>> _ols = [
    for (var i = 0; i < nOLS; i++)
      [for (var c = 0; c < 4; c++) ZcmOls(_num[i], 1, _lambda[i])]
  ];
  final Int32List _pred = Int32List(_nP); // spread << 16 | prediction
  final Int32List _nb = Int32List(34);
  final _Ring _errBuf = _Ring();
  final _Ring _lossBuf = _Ring();
  final _Ring _bestBuf = _Ring();

  int _info = -1, _type = -1;
  int _stride = 3, _w = 1, _padding = 0;
  int _x = 0, _line = 0, _color = 0;
  int _loss = 0;
  int _lossQ = 0, _lossQ4 = 0;
  int _ctx0 = 0, _ctx1 = 0;
  int _bestDir = 0, _bestRes = 0;
  int _lastBpos = -1, _lastPos = -1;
  // Neighborhood (paq8px names).
  int _ww = 0, _w1 = 0, _nw = 0, _n = 0, _ne = 0, _nn = 0, _nne = 0;
  int _nnee = 0, _nee = 0, _nnw = 0, _nnww = 0, _nnn = 0, _www = 0, _nww = 0;
  int _p1 = 0, _p2 = 0;
  int _np1 = 0, _np2 = 0, _wp1 = 0, _wp2 = 0, _nep1 = 0, _nep2 = 0;
  int _nwp1 = 0, _nwp2 = 0, _nnp1 = 0, _nnp2 = 0, _wwp1 = 0, _wwp2 = 0;

  PxImage24Model._(int cmBytes, int lsmBits)
      : _cm = ContextMap(cmBytes, nCM, rich: true),
        _mapL = ZcmLargeStationaryMap(nLSM, lsmBits, scale: 74);

  factory PxImage24Model(int allowance) =>
      PxImage24Model._(_cmBytes(allowance), _lsmBits(allowance));

  static int _fixedBytes() =>
      (nRM * ((1 << 7) * 2 + (1 << 5)) + nOLS * ((1 << 7) + (1 << 5))) * 512;

  static int _cmBytes(int allowance) {
    final b = (allowance - _fixedBytes()) * 3 ~/ 8;
    return floorPow2(b < (1 << 20) ? 1 << 20 : b);
  }

  static int _lsmBits(int allowance) {
    final left = allowance - _fixedBytes() - _cmBytes(allowance);
    var b = 12;
    while (b < 23 && (42 << (b + 1)) <= left) {
      b++;
    }
    return b;
  }

  /// Bytes of the tables of a model with [allowance].
  static int tableBytes(int allowance) =>
      _fixedBytes() + _cmBytes(allowance) + (42 << _lsmBits(allowance));

  @override
  int get inputs =>
      nCM * _cm.inputsPerContext +
      (nRM * 3 + nOLS * 2) * 2 +
      nLSM * ZcmLargeStationaryMap.inputsPerContext +
      1;

  @override
  int get plane => _color;
  @override
  int get lossQ => _lossQ;
  @override
  int get sseCtx => ((_color << 9) | _ctx0) >> 3;
  @override
  int get pxW => _w1;
  @override
  int get pxN => _n;
  @override
  int get pxWW => _ww;
  @override
  int get pxNN => _nn;

  @override
  List<int> get mixerContextSizes => const [
        9, 8, 64, 64, 16, 512, 256, 128, 32, 1024, //
        32, 256, _nP, _nP, 1024, 1024, 8, 512, 256, 256
      ];

  void _init() {
    _stride = _type == ZcmBlockType.image32 ? 4 : 3;
    _w = _info & 0xFFFFFF;
    if (_w < 1) _w = 1;
    _padding = _w % _stride;
    _x = 0;
    _line = 0;
    _color = 0;
    _lossBuf.setSize(3 * _w, 255);
    _errBuf.setSize(3 * _w * _nP, 255);
    _bestBuf.setSize(3 * _w, 0);
  }

  // Px: the pixel relX to the left and relY up on the plane colorShift
  // bytes back, kept inside the rows; 127 when there is none.
  int _px(ZcmState s, int relX, int relY, int colorShift) {
    final st = _stride;
    relX = relX * st + colorShift;
    var x0 = _x - relX;
    while (x0 < 0) {
      relX -= st;
      x0 += st;
    }
    while (x0 >= _w) {
      relX += st;
      x0 -= st;
    }
    if (_line - relY < 0) relY = _line;
    var offset = relY * _w + relX;
    if (offset <= 0) {
      if (relY < _line) {
        offset += _w;
      } else {
        return 127;
      }
    }
    return s.back(offset);
  }

  @pragma('vm:prefer-inline')
  int _ls(int relX, int relY) {
    if (_line - relY < 0) return 255;
    relX *= _stride;
    if (_x - relX < 0 || _x - relX >= _w) return 255;
    return _lossBuf.back(relY * _w + relX);
  }

  @pragma('vm:prefer-inline')
  int _predErr(int i, int relX, int relY) {
    if (_line - relY < 0) return 255;
    relX *= _stride;
    if (_x - relX < 0 || _x - relX >= _w) return 255;
    return _errBuf.back((relY * _w + relX - 1) * _nP + i + 1);
  }

  int _predErrAvg(int i) =>
      (2 * _predErr(i, 1, 0) +
          2 * _predErr(i, 0, 1) +
          _predErr(i, -1, 1) +
          _predErr(i, 1, 1) +
          _predErr(i, 2, 0) +
          _predErr(i, 0, 2)) >>
      3;

  @override
  void prepare(ZcmState s) {
    final bpos = s.bpos;
    final pos = s.pos;
    if (bpos == _lastBpos && pos == _lastPos) return;
    _lastBpos = bpos;
    _lastPos = pos;
    if (_color < 4) {
      final p = finalP;
      _loss += (s.y == 0 ? p : 65535 - p) >> 10;
    }
    if (bpos != 0) return;
    final c1 = s.c4 & 255;
    // Learn the byte just coded.
    _r1.update(c1);
    _r2.update(c1);
    _r3.update(c1);
    _o1.update(c1);
    _o2.update(c1);
    if (s.blockType != _type || s.blockInfo != _info || s.blockPos == 0) {
      _type = s.blockType;
      _info = s.blockInfo;
      _init();
      final k = s.blockPos;
      _x = k % _w;
      _line = k ~/ _w;
    } else {
      _x++;
      if (_x >= _w) {
        _x = 0;
        _line++;
      }
    }
    if (_x == 0) {
      _color = 0;
    } else if (_x < _w - _padding) {
      _color = _x % _stride;
    } else {
      _color = 4;
    }
    if (_color < 4) _byte(s, c1);
  }

  void _byte(ZcmState s, int c1) {
    _lossBuf.add(_loss >> 2 > 255 ? 255 : _loss >> 2);
    _loss = 0;
    final wwwwww = _px(s, 6, 0, 0),
        wwwww = _px(s, 5, 0, 0),
        wwww = _px(s, 4, 0, 0);
    final www = _px(s, 3, 0, 0), ww = _px(s, 2, 0, 0), w = _px(s, 1, 0, 0);
    final nwwww = _px(s, 4, 1, 0),
        nwww = _px(s, 3, 1, 0),
        nww = _px(s, 2, 1, 0),
        nw = _px(s, 1, 1, 0);
    final n = _px(s, 0, 1, 0),
        ne = _px(s, -1, 1, 0),
        nee = _px(s, -2, 1, 0),
        neee = _px(s, -3, 1, 0);
    final neeee = _px(s, -4, 1, 0);
    final nnnwww = _px(s, 3, 3, 0),
        nnwww = _px(s, 3, 2, 0),
        nnww = _px(s, 2, 2, 0),
        nnw = _px(s, 1, 2, 0);
    final nn = _px(s, 0, 2, 0),
        nne = _px(s, -1, 2, 0),
        nnee = _px(s, -2, 2, 0),
        nneee = _px(s, -3, 2, 0);
    final nnnww = _px(s, 2, 3, 0),
        nnnw = _px(s, 1, 3, 0),
        nnn = _px(s, 0, 3, 0),
        nnne = _px(s, -1, 3, 0);
    final nnnee = _px(s, -2, 3, 0), nnneee = _px(s, -3, 3, 0);
    final nnnnw = _px(s, 1, 4, 0),
        nnnn = _px(s, 0, 4, 0),
        nnnne = _px(s, -1, 4, 0);
    final nnnnn = _px(s, 0, 5, 0), nnnnnn = _px(s, 0, 6, 0);
    final wwp1 = _px(s, 2, 0, 1), wp1 = _px(s, 1, 0, 1), p1 = _px(s, 0, 0, 1);
    final nwp1 = _px(s, 1, 1, 1), np1 = _px(s, 0, 1, 1);
    final nep1 = _px(s, -1, 1, 1), nnp1 = _px(s, 0, 2, 1);
    final nnnp1 = _px(s, 0, 3, 1), wwwp1 = _px(s, 3, 0, 1);
    final nnwp1 = _px(s, 1, 2, 1), nnep1 = _px(s, -1, 2, 1);
    final nwwp1 = _px(s, 2, 1, 1), neep1 = _px(s, -2, 1, 1);
    final nneep1 = _px(s, -2, 2, 1);
    final wwp2 = _px(s, 2, 0, 2), wp2 = _px(s, 1, 0, 2), p2 = _px(s, 0, 0, 2);
    final nwp2 = _px(s, 1, 1, 2), np2 = _px(s, 0, 1, 2);
    final nep2 = _px(s, -1, 1, 2), nnp2 = _px(s, 0, 2, 2);
    final wwwp2 = _px(s, 3, 0, 2);
    final nnwp2 = _px(s, 1, 2, 2), nnep2 = _px(s, -1, 2, 2);
    final nnwwp2 = _px(s, 2, 2, 2), nneep2 = _px(s, -2, 2, 2);
    final nnnnww = _px(s, 2, 4, 0),
        nnwwww = _px(s, 4, 2, 0),
        nnnnee = _px(s, -2, 4, 0);
    final nneeee = _px(s, -4, 2, 0), nnnnnnee = _px(s, -2, 6, 0);
    final nnnnwwww = _px(s, 4, 4, 0),
        nnnneeee = _px(s, -4, 4, 0),
        neeeeee = _px(s, -6, 1, 0);
    final nnnwwww = _px(s, 4, 3, 0),
        nnneeee = _px(s, -4, 3, 0),
        neeeee = _px(s, -5, 1, 0);
    final neeeeeee = _px(s, -7, 1, 0);
    _ww = ww;
    _w1 = w;
    _nw = nw;
    _n = n;
    _ne = ne;
    _nn = nn;
    _nne = nne;
    _nnee = nnee;
    _nee = nee;
    _nnw = nnw;
    _nnww = nnww;
    _nnn = nnn;
    _www = www;
    _nww = nww;
    _p1 = p1;
    _p2 = p2;
    _np1 = np1;
    _np2 = np2;
    _wp1 = wp1;
    _wp2 = wp2;
    _nep1 = nep1;
    _nep2 = nep2;
    _nwp1 = nwp1;
    _nwp2 = nwp2;
    _nnp1 = nnp1;
    _nnp2 = nnp2;
    _wwp1 = wwp1;
    _wwp2 = wwp2;

    // Mixer context: edge direction.
    final scoreVert = (2 * _rabs(n, nn * 2 - nnn) +
            _rabs(w, nw * 2 - nnw) +
            _rabs(ne, nne * 2 - nnne)) ~/
        4;
    final scoreHoriz =
        (2 * _rabs(w, ww * 2 - www) + _rabs(n, nw * 2 - nww)) ~/ 3;
    final scoreDiag1 = (2 * _rabs(nw, nnww * 2 - nnnwww) +
            _rabs(n, nnw * 2 - nnnww) +
            _rabs(w, nww * 2 - nnwww)) ~/
        4;
    final scoreDiag2 = (2 * _rabs(ne, nnee * 2 - nnneee) +
            _rabs(n, nne * 2 - nnnee) +
            _rabs(nee, nneee * 2 - nnneeee)) ~/
        4;
    var best = scoreVert;
    _bestDir = 0;
    if (scoreHoriz < best) {
      best = scoreHoriz;
      _bestDir = 1;
    }
    if (scoreDiag1 < best) {
      best = scoreDiag1;
      _bestDir = 2;
    }
    if (scoreDiag2 < best) {
      best = scoreDiag2;
      _bestDir = 3;
    }
    _bestRes = _diffQt(0, best);

    var lq =
        _ls(1, 0) + _ls(0, 1) + _ls(2, 0) + _ls(0, 2) + _ls(1, 1) + _ls(-1, 1);
    if (lq > 639) lq = 639;
    _lossQ = lq;

    // Errors of the predictions of the last byte.
    var lowest = 255, bestIdx = 0;
    final pr = _pred;
    for (var i = _nP - 1; i >= 0; i--) {
      final p = pr[i].toSigned(16);
      final d = (c1 - p).abs();
      _errBuf.add(d & 255);
      if (d < lowest) {
        lowest = d;
        bestIdx = i;
      }
    }
    _bestBuf.add(bestIdx);

    var i = 0;
    // p1-based predictors.
    _mc(pr, i++, p1);
    _mt(pr, i++, p1, np1, n);
    _ms(pr, i++, p1, np1, n);
    _mp(pr, i++, p1, np1, n);
    _mt(pr, i++, p1, wp1, w);
    _ms(pr, i++, p1, wp1, w);
    _mp(pr, i++, p1, wp1, w);
    _mt(pr, i++, p1, nep1, ne);
    _mp(pr, i++, p1, nep1, ne);
    _mt(pr, i++, p1, nnp1, nn);
    _mp(pr, i++, p1, nnp1, nn);
    _mt(pr, i++, p1, nwp1, nw);
    _ms(pr, i++, p1, nwp1, nw);
    _mp(pr, i++, p1, nwp1, nw);
    _mt(pr, i++, p1, wwp1, ww);
    _mp(pr, i++, p1, wwp1, ww);
    _ms(pr, i++, p1, nneep1, ne);
    _mt(pr, i++, p1, (-3 * wwp1 + 8 * wp1 + (neep1 * 2 - nneep1)) ~/ 6,
        (-3 * ww + 8 * w + (nee * 2 - nnee)) ~/ 6);
    _mt(pr, i++, p1, _avg(wwp1, neep1 * 2 - nneep1), _avg(ww, nee * 2 - nnee));
    _mt(pr, i++, p1, wp1 + np1 - nwp1, w + n - nw);
    _mt(pr, i++, p1, np1 + nwp1 - nnwp1, n + nw - nnw);
    _mt(pr, i++, p1, np1 + nep1 - nnep1, n + ne - nne);
    _mt(pr, i++, p1, np1 + nnp1 - nnnp1, n + nn - nnn);
    _mt(pr, i++, p1, wp1 + wwp1 - wwwp1, w + ww - www);
    _mt(pr, i++, p1, wp1 + neep1 - nep1, w + nee - ne);
    _mt(pr, i++, p1, np1 * 2 - nnp1, n * 2 - nn);
    _mt(pr, i++, p1, wp1 * 2 - wwp1, w * 2 - ww);
    _mt(pr, i++, p1, wp1 + nep1 - np1, w + ne - n);
    _mt(pr, i++, p1, nep1 + nwp1 - nnp1, ne + nw - nn);
    _mt(pr, i++, p1, nwp1 + wp1 - nwwp1, nw + w - nww);
    // p2-based predictors.
    _mc(pr, i++, p2);
    _mt(pr, i++, p2, np2, n);
    _ms(pr, i++, p2, np2, n);
    _mt(pr, i++, p2, wp2, w);
    _ms(pr, i++, p2, wp2, w);
    _mt(pr, i++, p2, nep2, ne);
    _mt(pr, i++, p2, nnp2, nn);
    _ms(pr, i++, p2, nwp2, nw);
    _mt(pr, i++, p2, wwp2, ww);
    _ms(pr, i++, p2, nneep2, ne);
    _mt(pr, i++, p2, wp2 + np2 - nwp2, w + n - nw);
    _mt(pr, i++, p2, np2 + nwp2 - nnwp2, n + nw - nnw);
    _mt(pr, i++, p2, np2 + nep2 - nnep2, n + ne - nne);
    _mt(pr, i++, p2, wp2 + wwp2 - wwwp2, w + ww - www);
    _mt(pr, i++, p2, np2 * 2 - nnp2, n * 2 - nn);
    _mt(pr, i++, p2, wp2 * 2 - wwp2, w * 2 - ww);
    _mt(pr, i++, p2, nwp2 * 2 - nnwwp2, nw * 2 - nnww);
    _mt(pr, i++, p2, nep2 * 2 - nneep2, ne * 2 - nnee);
    // The current color plane only.
    i = _planePredictors(
        pr,
        i,
        wwwwww,
        wwwww,
        wwww,
        www,
        ww,
        w,
        nwwww,
        nwww,
        nww,
        nw,
        n,
        ne,
        nee,
        neee,
        neeee,
        nnnwww,
        nnwww,
        nnww,
        nnw,
        nn,
        nne,
        nnee,
        nneee,
        nnnww,
        nnnw,
        nnn,
        nnne,
        nnnee,
        nnneee,
        nnnnw,
        nnnn,
        nnnne,
        nnnnn,
        nnnnnn,
        nnnnww,
        nnwwww,
        nnnnee,
        nneeee,
        nnnnnnee,
        nnnnwwww,
        nnnneeee,
        neeeeee,
        nnnwwww,
        nnneeee,
        neeeee,
        neeeeeee);
    assert(i == nRM);

    final c = _color;
    _lossQ4 = c == 2
        ? (lq < 1 ? lq : _min(1 + (lq - 1) ~/ 40, 7))
        : (c == 1
            ? (lq < 8 ? lq >> 2 : _min(2 + (lq - 8) ~/ 40, 7))
            : _min(lq ~/ 40, 7));
    for (var j = 0; j < nRM; j++) {
      final v = pr[j];
      final spread = v >> 16;
      final p = v.toSigned(16);
      final ea = _predErrAvg(j);
      _r1.set(p, _min(ea, 31) << 2 | c);
      _r2.set(p, _lossQ4 << 2 | c);
      _r3.set(p, _min(spread, 31) << 2 | c);
    }
    // Least squares fits per plane.
    final nb = _nb;
    nb[0] = wwwwww;
    nb[1] = wwwww;
    nb[2] = wwww;
    nb[3] = www;
    nb[4] = ww;
    nb[5] = w;
    nb[6] = nwwww;
    nb[7] = nwww;
    nb[8] = nww;
    nb[9] = nw;
    nb[10] = n;
    nb[11] = ne;
    nb[12] = nee;
    nb[13] = neee;
    nb[14] = neeee;
    nb[15] = nnwww;
    nb[16] = nnww;
    nb[17] = nnw;
    nb[18] = nn;
    nb[19] = nne;
    nb[20] = nnee;
    nb[21] = nneee;
    nb[22] = nnnww;
    nb[23] = nnnw;
    nb[24] = nnn;
    nb[25] = nnne;
    nb[26] = nnnee;
    nb[27] = nnnnw;
    nb[28] = nnnn;
    nb[29] = nnnne;
    nb[30] = nnnnn;
    nb[31] = nnnnnn;
    nb[32] = p1;
    nb[33] = p2;
    final k = c > 0 ? c - 1 : _stride - 1;
    final p1d = p1.toDouble();
    for (var j = 0; j < nOLS; j++) {
      _ols[j][k].update(p1d);
      final o = _ols[j][c];
      final t = _olsIdx24[j];
      for (var q = 0; q < t.length; q++) {
        o.add(nb[t[q]].toDouble());
      }
      final p = _roundShort(o.predict());
      _mc(pr, nRM + j, p);
      final ea = _predErrAvg(nRM + j);
      _o1.set(p, _min(ea, 31) << 2 | c);
      _o2.set(p, _lossQ4 << 2 | c);
    }

    // Hashed contexts (non-photographic images).
    var h = c * 1024;
    final cm = _cm;
    var j = 0;
    cm.set(j++, hash3(++h, w, p1));
    cm.set(j++, hash3(++h, w, p2));
    cm.set(j++, hash3(++h, n, p1));
    cm.set(j++, hash3(++h, n, p2));
    cm.set(j++, hash3(++h, p1, p2));
    cm.set(j++, hash4(++h, n, nn, p1));
    cm.set(j++, hash4(++h, n, nn, p2));
    cm.set(j++, hash4(++h, w, ww, p1));
    cm.set(j++, hash4(++h, w, ww, p2));
    cm.set(j++, _h5(++h, n, w, p1, p2));
    cm.set(j++, hash4(++h, w, p1 - wp1, p2 - wp2));
    cm.set(j++, hash4(++h, n, p1 - np1, p2 - np2));
    cm.set(j++, hash4(++h, nw, p1 - nwp1, p2 - nwp2));
    cm.set(j++, hash4(++h, ne, p1 - nep1, p2 - nep2));
    cm.set(j++, _h5(++h, w, ww, n, nn));
    cm.set(j++, _h5(++h, w, n, ne, nw));
    cm.set(j++, hash3(++h, (nnn + n + 4) >> 3, (n * 3 - nn * 3 + nnn) >> 1));
    cm.set(
        j++,
        _h6(++h, (w + n - nw) >> 1, (w + p1 - wp1) >> 3, (w + p2 - wp2) >> 3,
            (n + p1 - np1) >> 3, (n + p2 - np2) >> 3));
    cm.set(j++, hash4(++h, w >> 2, _diffQt(w, p1), _diffQt(w, p2)));
    cm.set(j++, hash4(++h, n >> 2, _diffQt(n, p1), _diffQt(n, p2)));
    cm.set(j++, hash4(++h, (w + n + 4) >> 3, p1 >> 4, p2 >> 4));
    cm.set(j++, hash3(++h, (n * 2 - nn) >> 1, _diffQt(n, nn * 2 - nnn)));
    cm.set(j++, hash3(++h, (w * 2 - ww) >> 1, _diffQt(w, ww * 2 - www)));
    cm.set(j++, hash3(++h, n * 2 - nn, _diffQt(w, nw * 2 - nnw)));
    cm.set(j++, hash3(++h, w * 2 - ww, _diffQt(n, nw * 2 - nww)));
    cm.set(j++, hash3(++h, (w + nee + 1) >> 1, _diffQt(w, (ww + ne + 1) >> 1)));
    cm.set(j++, hash3(++h, w + nee - ne, _diffQt(w, ww + ne - n)));
    final xs = _x ~/ _stride;
    final div7 = _max(xs >> 10, 7);
    final div17 = _max(xs >> 9, 17);
    final div29 = _max(xs >> 8, 29);
    cm.set(j++, hash3(++h, _w, xs ~/ div7));
    cm.set(j++, hash4(++h, _w, xs ~/ div17, _line ~/ 17));
    cm.set(j++, hash4(++h, _w, xs ~/ div29, (w + n - nw) >> 1));
    cm.set(j++, _h5(++h, _w, xs ~/ div29, w >> 2, ne >> 2));
    assert(j == nCM);

    // paq8px keeps the (N > NN) >> 3 of its source: always 0.
    _ctx0 = (_rabs(w, nw) > 3 ? 256 : 0) |
        (_rabs(nw, n) > 3 ? 128 : 0) |
        (_rabs(n, ne) > 3 ? 64 : 0) |
        (n > nw ? 32 : 0) |
        (n > ne ? 16 : 0) |
        (w > n ? 4 : 0) |
        (w > nw ? 2 : 0) |
        (w > ww ? 1 : 0);
    _ctx1 = _diffQt(p1, np1 + nep1 - nnep1) << 4 |
        _diffQt(n + ne - nne, n + nw - nnw);
  }

  // The predictors of the current plane (shared by paq8px's 24 and 8 bit
  // models, from "(N * 3 + W * 3 - NN - WW + 2) >> 2" to the constant 0).
  static int _planePredictors(
      Int32List pr,
      int i,
      int wwwwww,
      int wwwww,
      int wwww,
      int www,
      int ww,
      int w,
      int nwwww,
      int nwww,
      int nww,
      int nw,
      int n,
      int ne,
      int nee,
      int neee,
      int neeee,
      int nnnwww,
      int nnwww,
      int nnww,
      int nnw,
      int nn,
      int nne,
      int nnee,
      int nneee,
      int nnnww,
      int nnnw,
      int nnn,
      int nnne,
      int nnnee,
      int nnneee,
      int nnnnw,
      int nnnn,
      int nnnne,
      int nnnnn,
      int nnnnnn,
      int nnnnww,
      int nnwwww,
      int nnnnee,
      int nneeee,
      int nnnnnnee,
      int nnnnwwww,
      int nnnneeee,
      int neeeeee,
      int nnnwwww,
      int nnneeee,
      int neeeee,
      int neeeeeee) {
    _mc(pr, i++, (n * 3 + w * 3 - nn - ww + 2) >> 2);
    _mavg(pr, i++, w, nee);
    _mt(pr, i++, w, nw, n);
    _mt(pr, i++, ww, nnww, nn);
    _mt(pr, i++, www, nnnwww, nnn);
    _mt(pr, i++, w, n, ne);
    _mt(pr, i++, n, nnw, nw);
    _mt(pr, i++, n, nne, ne);
    _mt(pr, i++, nn, nnnnee, nnee);
    _mt(pr, i++, n, nnn, nn);
    _mt(pr, i++, nn, nnnnnn, nnnn);
    _mt(pr, i++, w, www, ww);
    _mt(pr, i++, ww, wwwwww, wwww);
    _mt(pr, i++, w, ne, nee);
    _mt(pr, i++, ww, nnee, nneeee);
    _mt(pr, i++, nw, nww, w);
    _mt(pr, i++, nnww, nnwwww, ww);
    _mt(pr, i++, nn, nnw, w);
    _mt(pr, i++, nnnn, nnnnnnee, nnee);
    _mt(pr, i++, ne, nn, nw);
    _ms(pr, i++, w, nne, ne);
    _mt(pr, i++, nne, nnne, ne);
    _mt(pr, i++, nee, nneee, nee);
    _mt(pr, i++, neee, nnneee, neee);
    _mt(pr, i++, nne, nn, w);
    _mt(pr, i++, nnw, nnww, w);
    _mc(pr, i++, n * 3 - nn * 3 + nnn);
    _mc(pr, i++, w * 3 - ww * 3 + www);
    _mc(pr, i++, _clamp4(n * 3 - nn * 3 + nnn, n, w, ne, nw));
    _mc(pr, i++, _clamp4(w * 3 - ww * 3 + www, n, w, ne, nw));
    _mc(
        pr,
        i++,
        (15 * n -
                20 * nn +
                15 * nnn -
                6 * nnnn +
                nnnnn +
                _clamp4(4 * w - 6 * nww + 4 * nnwww - nnnwwww, w, nw, n, nn)) ~/
            6);
    _mc(pr, i++,
        (6 * ne - 4 * nnee + nnneee + (4 * w - 6 * nw + 4 * nnw - nnnw)) ~/ 4);
    _mc(
        pr,
        i++,
        ((n + 3 * nw) ~/ 4) * 3 -
            _avg(nnw, nnww) * 3 +
            (nnnww * 3 + nnnwww) ~/ 4);
    _mc(pr, i++, (w * 2 + nw) - (ww + 2 * nww) + nwww);
    _mavg(pr, i++, neeee, neeeeee);
    _mavg(pr, i++, wwww, wwwwww);
    _mavg(pr, i++, nnnn, nnnnnn);
    _mavg(pr, i++, nnnnww, nnww);
    _mavg(pr, i++, nnnnee, nnee);
    _mavg(pr, i++, www, wwwwww);
    _mc(pr, i++, w);
    _mc(pr, i++, n);
    _mc(pr, i++, nn);
    _mt(pr, i++, w, ww, w);
    _mt(pr, i++, ww, wwww, ww);
    _mt(pr, i++, n, nn, n);
    _mt(pr, i++, nn, nnnn, nn);
    _mt(pr, i++, nw, nnww, nw);
    _mt(pr, i++, nnww, nnnnwwww, nnww);
    _mt(pr, i++, ne, nnee, ne);
    _mt(pr, i++, nneee, nnnneeee, nneee);
    _mt(pr, i++, w, nee, neee);
    _mt(pr, i++, nww, nwwww, ww);
    _mc(pr, i++, (w + n + neeeee + neeeeeee) ~/ 4);
    _mt(pr, i++, ww, n, nee);
    _mt(pr, i++, n, nnww, nww);
    _mavg(pr, i++, 2 * n - nn, 2 * w - ww);
    _mavg(pr, i++, 2 * w - ww, 2 * nw - nnww);
    _mc(pr, i++, _paeth(w, n, nw));
    _mc(pr, i++, _gap(w, n, nw, ne, ww, nne, nn));
    _mc(pr, i++,
        (6 * w - 4 * ww + www + 4 * ne - 6 * nne + 4 * nnne - nnnne) ~/ 4);
    _mc(
        pr,
        i++,
        (10 * w -
                10 * ww +
                5 * www -
                wwww +
                4 * ne -
                6 * nne +
                4 * nnne -
                nnnne) ~/
            5);
    _mc(
        pr,
        i++,
        (15 * w -
                4 * ww +
                10 * (3 * ne - 3 * nne + nnne) -
                (3 * neee - 3 * nneee + nnneee)) ~/
            20);
    _mc(pr, i++, (8 * w - 3 * ww + (3 * nee - 3 * nnee + nnnee)) ~/ 6);
    _mc(pr, i++, (2 * w - ww) + (2 * n - nn) - (2 * nw - nnww));
    _mc(pr, i++,
        (6 * n - 4 * nn + nnn + 4 * ne - 6 * nne + 4 * nnne - nnnne) ~/ 4);
    _mc(
        pr,
        i++,
        ((10 * n - 10 * nn + 5 * nnn - nnnn) +
                (4 * ne - 6 * nne + 4 * nnne - nnnne)) ~/
            5);
    _mc(pr, i++,
        (6 * n - 4 * nn + nnn + 4 * nw - 6 * nnw + 4 * nnnw - nnnnw) ~/ 4);
    _mc(
        pr,
        i++,
        ((10 * n - 10 * nn + 5 * nnn - nnnn) +
                (4 * nw - 6 * nnw + 4 * nnnw - nnnnw)) ~/
            5);
    _mc(pr, i++, (6 * ne - 4 * nnee + nnneee) ~/ 3);
    _mc(
        pr,
        i++,
        ((6 * w - 4 * ww + www) +
                (6 * n - 4 * nn + nnn) -
                (6 * nw - 4 * nnww + nnnwww)) ~/
            3);
    _mc(pr, i++, (15 * w - 20 * ww + 15 * www - 6 * wwww + wwwww) ~/ 5);
    _mc(pr, i++, (2 * ne - nnee) + (2 * nw - nnww) - (2 * n - nn));
    _mc(pr, i++, 0);
    return i;
  }

  @override
  void mix(ZcmState s, Mixer m) {
    prepare(s);
    final bpos = s.bpos;
    final c0 = s.c0;
    final y = s.y;
    _cm.mix(m, y, bpos, c0, s.c4 & 255);
    _mapL.update(y);
    final tx = m.tx;
    if (_color == 4) {
      var k = m.nx;
      final n = (nRM * 3 + nOLS * 2) * 2 +
          nLSM * ZcmLargeStationaryMap.inputsPerContext;
      for (var i = 0; i < n; i++) {
        tx[k++] = 0;
      }
      m.nx = k;
      m.add(-2047);
      return;
    }
    _r1.mix(m, bpos, c0);
    _r2.mix(m, bpos, c0);
    _r3.mix(m, bpos, c0);
    _o1.mix(m, bpos, c0);
    _o2.mix(m, bpos, c0);
    // Bit contexts of the pixel neighborhood.
    final w = _w1, n = _n, nw = _nw, ne = _ne, nn = _nn, ww = _ww;
    final p1 = _p1, p2 = _p2;
    final np1 = _np1, np2 = _np2, nep1 = _nep1, nep2 = _nep2;
    final mapL = _mapL;
    var i = (c0 << 2 | _color) * 256;
    mapL.set(hash2(++i, p2));
    mapL.set(hash3(++i, p1, p2));
    mapL.set(hash3(++i, w, p2));
    mapL.set(hash4(++i, w, p1, p2));
    mapL.set(hash4(++i, n, np1, np2));
    mapL.set(_h6(++i, w, p1, p2, n, np1));
    mapL.set(_h7(++i, w, p1, p2, n, np1, np2));
    mapL.set(_h5(++i, w, p1, p2, ne));
    mapL.set(_h6(++i, w, p1, p2, ne, nep1));
    mapL.set(_h7(++i, w, p1, p2, ne, nep1, nep2));
    mapL.set(hash4(++i, n, ne, p1));
    mapL.set(hash4(++i, nw, ne, p1));
    mapL.set(hash4(++i, nw, ne, p2));
    mapL.set(hash4(++i, nw, nn, p1));
    mapL.set(_h5(++i, w, n, ne, p1));
    mapL.set(_h5(++i, w, n, nw, p1));
    mapL.set(_h6(++i, n, np1, ne, nw, p1));
    mapL.set(hash4(++i, ne, _nee, p1));
    mapL.set(hash4(++i, ne, _nee, p2));
    mapL.set(_h5(++i, ne, nep1, nep2, _nee));
    mapL.set(hash4(++i, nn, _nnn, p1));
    mapL.set(hash4(++i, nn, _nnn, p2));
    mapL.set(_h5(++i, nn, _nnp1, _nnp2, _nnn));
    mapL.set(_h5(++i, ww, _wwp1, _wwp2, _www));
    mapL.set(_h5(++i, np1, np2, _wp1, _wp2));
    mapL.set(_h5(++i, _nwp1, _nwp2, nep1, nep2));
    mapL.set(hash3(++i, (w + n - nw) >> 1, p1));
    mapL.set(hash4(++i, (w + n - nw) >> 1, p1, p2));
    mapL.set(hash3(++i, (n + ne - _nne) >> 1, p1));
    mapL.set(hash4(++i, (n + ne - _nne) >> 1, p1, p2));
    mapL.set(hash3(++i, (w * 2 - ww) >> 1, p1));
    mapL.set(hash3(++i, (n * 2 - nn) >> 1, p1));
    mapL.set(hash4(++i, (w * 2 - ww) >> 1, p1, p2));
    mapL.set(hash4(++i, (n * 2 - nn) >> 1, p1, p2));
    mapL.set(hash3(++i, (nw + w - _nww) >> 1, p1));
    mapL.set(hash4(++i, (nw + w - _nww) >> 1, p1, p2));
    mapL.set(hash3(++i, (nw + n - _nnw) >> 1, p1));
    mapL.set(hash4(++i, (nw + n - _nnw) >> 1, p1, p2));
    mapL.set(hash3(++i, _paeth(w, n, nw) >> 1, p1));
    mapL.set(hash4(++i, _paeth(w, n, nw) >> 1, p1, p2));
    mapL.mix(m);
    m.add(0);
  }

  @override
  void setMixerContexts(ZcmState s, Mixer m) {
    if (_color == 4) {
      for (var i = 0; i < 20; i++) {
        m.set(0);
      }
      return;
    }
    final bpos = s.bpos;
    final c0 = s.c0;
    final bp = (0x33322210 >> (bpos << 2)) & 0xF;
    final xs = _x ~/ _stride;
    final line = _line;
    m.set(1 + bpos);
    m.set(_lossQ4);
    m.set((line & 7) << 3 | bpos);
    m.set((xs & 7) << 3 | (line & 7));
    m.set(xs & 15);
    m.set((xs ~/ _max(xs >> 9, 3)) & 511);
    m.set((xs ~/ _max(xs >> 8, 19)) & 255);
    final n = _n, w = _w1;
    final pred1 = 0x100 | ((n + w + 1) >> 1);
    final pred2 = 0x100 | (n + w - _nw).toSigned(8);
    final pred3 = 0x100 | (2 * n - _nn).toSigned(8);
    final pred4 = 0x100 | (2 * w - _ww).toSigned(8);
    final sh = 8 - bpos;
    m.set((c0 == (pred1 >> sh) ? 64 : 0) |
        (c0 == (pred2 >> sh) ? 32 : 0) |
        (c0 == (pred3 >> sh) ? 16 : 0) |
        (c0 == (pred4 >> sh) ? 8 : 0) |
        bpos);
    m.set(_lossQ4 << 2 | bp);
    m.set(_ctx1 << 2 | bp);
    m.set(_bestDir << 3 | _bestRes);
    m.set(((xs + line) >> 5) & 255);
    final bb = _bestBuf;
    final bw = _color == 0 ? bb.back(_stride) : bb.back(1);
    final bn = bb.back(_w);
    m.set(bw);
    m.set(bn);
    m.set(_min(31, _predErrAvg(bw)) << 5 | _min(31, _predErrAvg(bn)));
    final bne = bb.back(_w + _stride);
    final bnw = bb.back(_w - _stride);
    m.set(_min(31, _predErrAvg(bne)) << 5 | _min(31, _predErrAvg(bnw)));
    m.set(_ctx0 >> 6);
    m.set((_ctx0 & 0x3F) << 3 | _lossQ4);
    final tn = 2 * n - _nn, tw = 2 * w - _ww;
    final tne = 2 * _ne - _nnee, tnw = 2 * _nw - _nnww;
    final tmin = _min(_min(_min(tn, tw), tne), tnw);
    final tmax = _max(_max(_max(tn, tw), tne), tnw);
    m.set((_min(tmax - tmin, 255) >> 2) << 2 | (bpos >> 1));
    m.set((_p1 >> 5) << 5 | (_p2 >> 5) << 2 | (bpos >> 1));
  }
}

@pragma('vm:prefer-inline')
int _min(int a, int b) => a < b ? a : b;

@pragma('vm:prefer-inline')
int _max(int a, int b) => a > b ? a : b;

/// paq8px Image8BitModel, grayscale part (palette images keep zcm's
/// ImageModel).
final class PxImage8Model extends PxImageModel {
  static const int nRM = 74;
  static const int nOLS = 5;
  static const int nCM = 22;
  static const int _nP = nRM + nOLS;
  static const List<double> _lambda = [0.996, 0.87, 0.93, 0.8, 0.9];
  static const List<int> _num = [32, 12, 15, 10, 14];

  final ContextMap _cm;
  final ZcmStationaryMap _map0 = ZcmStationaryMap(0, 8);
  final ZcmStationaryMap _map1 = ZcmStationaryMap(15, 1);
  final ResidualMap _r1 = ResidualMap(nRM, 1 << 5, scale: 74);
  final ResidualMap _r2 = ResidualMap(nRM, 1 << 3, scale: 74);
  final ResidualMap _r3 = ResidualMap(nRM, 1 << 5, scale: 74);
  final ResidualMap _o1 = ResidualMap(nOLS, 1 << 5, scale: 74);
  final ResidualMap _o2 = ResidualMap(nOLS, 1 << 3, scale: 74);
  final List<ZcmOls> _ols = [
    for (var i = 0; i < nOLS; i++) ZcmOls(_num[i], 1, _lambda[i])
  ];
  final Int32List _pred = Int32List(_nP);
  final Int32List _nb = Int32List(34);
  final _Ring _errBuf = _Ring();
  final _Ring _lossBuf = _Ring();

  int _info = -1, _type = -1;
  int _w = 1, _x = 0, _line = 0;
  int _loss = 0, _lossQ = 0;
  int _ctx = 0, _res = 0, _col = 0;
  int _columns0 = 1, _columns1 = 1;
  int _lastBpos = -1, _lastPos = -1;
  int _pw = 0, _pn = 0, _pnw = 0, _pne = 0, _pww = 0, _pnn = 0;
  int _pnnw = 0, _pnne = 0, _pnnee = 0, _pnnww = 0;

  PxImage8Model(int allowance)
      : _cm = ContextMap(_cmBytes(allowance), nCM, rich: true);

  static int _fixedBytes() =>
      (nRM * ((1 << 5) * 2 + (1 << 3)) + nOLS * ((1 << 5) + (1 << 3))) * 512 +
      (1 << 15) * 4;

  static int _cmBytes(int allowance) {
    final b = allowance - _fixedBytes();
    return floorPow2(b < (1 << 20) ? 1 << 20 : b);
  }

  /// Bytes of the tables of a model with [allowance].
  static int tableBytes(int allowance) => _fixedBytes() + _cmBytes(allowance);

  @override
  int get inputs =>
      nCM * _cm.inputsPerContext + 2 * 3 + (nRM * 3 + nOLS * 2) * 2 + 1;

  @override
  int get plane => 0;
  @override
  int get lossQ => _lossQ;
  @override
  int get sseCtx => _ctx >> 1;
  @override
  int get pxW => _pw;
  @override
  int get pxN => _pn;
  @override
  int get pxWW => _pww;
  @override
  int get pxNN => _pnn;

  @override
  List<int> get mixerContextSizes =>
      const [512, 16, 32, 255, 1024, 64, 128, 256];

  void _init() {
    _w = _info & 0xFFFFFF;
    if (_w < 1) _w = 1;
    final l0 = _ilog2(_w) * 2;
    _columns0 = _max(1, _w ~/ _max(1, l0));
    _columns1 = _max(1, _columns0 ~/ _max(1, _ilog2(_columns0)));
    _lossBuf.setSize(3 * _w, 255);
    _errBuf.setSize(3 * _w * _nP, 255);
  }

  @pragma('vm:prefer-inline')
  int _ls(int relX, int relY) {
    if (_line - relY < 0) return 255;
    if (_x - relX < 0 || _x - relX >= _w) return 255;
    return _lossBuf.back(relY * _w + relX);
  }

  @pragma('vm:prefer-inline')
  int _predErr(int i, int relX, int relY) {
    if (_line - relY < 0) return 255;
    if (_x - relX < 0 || _x - relX >= _w) return 255;
    return _errBuf.back((relY * _w + relX - 1) * _nP + i + 1);
  }

  int _predErrAvg(int i) =>
      (2 * _predErr(i, 1, 0) +
          2 * _predErr(i, 0, 1) +
          _predErr(i, -1, 1) +
          _predErr(i, 1, 1) +
          _predErr(i, 2, 0) +
          _predErr(i, 0, 2)) >>
      3;

  @override
  void prepare(ZcmState s) {
    final bpos = s.bpos;
    final pos = s.pos;
    if (bpos == _lastBpos && pos == _lastPos) return;
    _lastBpos = bpos;
    _lastPos = pos;
    final p = finalP;
    _loss += (s.y == 0 ? p : 65535 - p) >> 10;
    if (bpos != 0) return;
    final c1 = s.c4 & 255;
    _r1.update(c1);
    _r2.update(c1);
    _r3.update(c1);
    _o1.update(c1);
    _o2.update(c1);
    if (s.blockType != _type || s.blockInfo != _info || s.blockPos == 0) {
      _type = s.blockType;
      _info = s.blockInfo;
      _init();
      final k = s.blockPos;
      _x = k % _w;
      _line = k ~/ _w;
    } else {
      _x++;
      if (_x >= _w) {
        _x = 0;
        _line++;
      }
    }
    _byte(s, c1);
  }

  void _byte(ZcmState s, int c1) {
    final wd = _w;
    final wwwww = s.back(5),
        wwww = s.back(4),
        www = s.back(3),
        ww = s.back(2),
        w = s.back(1);
    final nwwww = s.back(wd + 4), nwww = s.back(wd + 3), nww = s.back(wd + 2);
    final nw = s.back(wd + 1),
        n = s.back(wd),
        ne = s.back(wd - 1),
        nee = s.back(wd - 2);
    final neee = s.back(wd - 3), neeee = s.back(wd - 4);
    final nnwww = s.back(wd * 2 + 3),
        nnww = s.back(wd * 2 + 2),
        nnw = s.back(wd * 2 + 1);
    final nn = s.back(wd * 2),
        nne = s.back(wd * 2 - 1),
        nnee = s.back(wd * 2 - 2);
    final nneee = s.back(wd * 2 - 3);
    final nnnww = s.back(wd * 3 + 2),
        nnnw = s.back(wd * 3 + 1),
        nnn = s.back(wd * 3);
    final nnne = s.back(wd * 3 - 1), nnnee = s.back(wd * 3 - 2);
    final nnnnw = s.back(wd * 4 + 1),
        nnnn = s.back(wd * 4),
        nnnne = s.back(wd * 4 - 1);
    final nnnnn = s.back(wd * 5), nnnnnn = s.back(wd * 6);
    final wwwwww = s.back(6),
        nnwwww = s.back(2 * wd + 4),
        nnnwww = s.back(3 * wd + 3);
    final nnnwwww = s.back(3 * wd + 4), nnnnww = s.back(4 * wd + 2);
    final nnnnwwww = s.back(4 * wd + 4),
        neeeee = s.back(wd - 5),
        neeeeee = s.back(wd - 6);
    final nneeee = s.back(2 * wd - 4), nnneee = s.back(3 * wd - 3);
    final nnnnee = s.back(4 * wd - 2), nnnneeee = s.back(4 * wd - 4);
    final nnnnnnee = s.back(6 * wd - 2), neeeeeee = s.back(wd - 7);
    _pw = w;
    _pn = n;
    _pnw = nw;
    _pne = ne;
    _pww = ww;
    _pnn = nn;
    _pnnw = nnw;
    _pnne = nne;
    _pnnee = nnee;
    _pnnww = nnww;

    final cm = _cm;
    var h = 1024;
    var j = 0;
    cm.set(j++, hash3(++h, n, _line & 3));

    _lossBuf.add(_loss >> 2 > 255 ? 255 : _loss >> 2);
    _loss = 0;
    var lq =
        _ls(1, 0) + _ls(0, 1) + _ls(2, 0) + _ls(0, 2) + _ls(1, 1) + _ls(-1, 1);
    if (lq > 639) lq = 639;
    _lossQ = lq;
    final pr = _pred;
    for (var i = _nP - 1; i >= 0; i--) {
      _errBuf.add((c1 - pr[i].toSigned(16)).abs() & 255);
    }
    // The predictors of paq8px's gray model are those of the planes.
    PxImage24Model._planePredictors(
        pr,
        0,
        wwwwww,
        wwwww,
        wwww,
        www,
        ww,
        w,
        nwwww,
        nwww,
        nww,
        nw,
        n,
        ne,
        nee,
        neee,
        neeee,
        nnnwww,
        nnwww,
        nnww,
        nnw,
        nn,
        nne,
        nnee,
        nneee,
        nnnww,
        nnnw,
        nnn,
        nnne,
        nnnee,
        nnneee,
        nnnnw,
        nnnn,
        nnnne,
        nnnnn,
        nnnnnn,
        nnnnww,
        nnwwww,
        nnnnee,
        nneeee,
        nnnnnnee,
        nnnnwwww,
        nnnneeee,
        neeeeee,
        nnnwwww,
        0,
        neeeee,
        neeeeeee);
    final lq4 = _min(lq ~/ 40, 7);
    for (var i = 0; i < nRM; i++) {
      final v = pr[i];
      final p = v.toSigned(16);
      _r1.set(p, _min(_predErrAvg(i), 31));
      _r2.set(p, lq4);
      _r3.set(p, _min(v >> 16, 31));
    }
    final nb = _nb;
    nb[0] = wwwwww;
    nb[1] = wwwww;
    nb[2] = wwww;
    nb[3] = www;
    nb[4] = ww;
    nb[5] = w;
    nb[6] = nwwww;
    nb[7] = nwww;
    nb[8] = nww;
    nb[9] = nw;
    nb[10] = n;
    nb[11] = ne;
    nb[12] = nee;
    nb[13] = neee;
    nb[14] = neeee;
    nb[15] = nnwww;
    nb[16] = nnww;
    nb[17] = nnw;
    nb[18] = nn;
    nb[19] = nne;
    nb[20] = nnee;
    nb[21] = nneee;
    nb[22] = nnnww;
    nb[23] = nnnw;
    nb[24] = nnn;
    nb[25] = nnne;
    nb[26] = nnnee;
    nb[27] = nnnnw;
    nb[28] = nnnn;
    nb[29] = nnnne;
    nb[30] = nnnnn;
    nb[31] = nnnnnn;
    final wd0 = w.toDouble();
    for (var k = 0; k < nOLS; k++) {
      final o = _ols[k];
      o.update(wd0);
      final t = _olsIdx24[k];
      for (var q = 0; q < t.length; q++) {
        o.add(nb[t[q]].toDouble());
      }
      final p = _roundShort(o.predict());
      pr[nRM + k] = _clip(p);
      _o1.set(p, _min(_predErrAvg(nRM + k), 31));
      _o2.set(p, lq4);
    }

    cm.set(j++, hash2(++h, n));
    cm.set(j++, hash2(++h, nw));
    cm.set(j++, hash2(++h, ne));
    cm.set(j++, hash3(++h, n, nn));
    cm.set(j++, hash3(++h, ne, nnee));
    cm.set(j++, hash3(++h, nw, nnww));
    cm.set(j++, hash3(++h, w, nee));
    cm.set(j++, hash4(++h, n, nn, nnn));
    cm.set(j++, _h5(++h, w, ww, n, nn));
    cm.set(j++, _h5(++h, w, n, ne, nw));
    cm.set(j++, hash3(++h, (nnn + n + 4) >> 3, (n * 3 - nn * 3 + nnn) >> 1));
    cm.set(j++, hash3(++h, (n * 2 - nn) >> 1, _diffQt(n, nn * 2 - nnn)));
    cm.set(j++, hash3(++h, (w * 2 - ww) >> 1, _diffQt(w, ww * 2 - www)));
    cm.set(j++, hash3(++h, n * 2 - nn, _diffQt(w, nw * 2 - nnw)));
    cm.set(j++, hash3(++h, w * 2 - ww, _diffQt(n, nw * 2 - nww)));
    cm.set(j++, hash3(++h, (w + nee + 1) >> 1, _diffQt(w, (ww + ne + 1) >> 1)));
    cm.set(j++, hash3(++h, w + nee - ne, _diffQt(w, ww + ne - n)));
    final x = _x;
    final div7 = _max(x >> 10, 7);
    final div17 = _max(x >> 9, 17);
    final div29 = _max(x >> 8, 29);
    cm.set(j++, hash3(++h, wd, x ~/ div7));
    cm.set(j++, hash4(++h, wd, x ~/ div17, _line ~/ 17));
    cm.set(j++, hash4(++h, wd, x ~/ div29, ((w + n - nw) & 255) >> 1));
    cm.set(j++, _h5(++h, wd, w >> 2, ne >> 2, x ~/ div29));
    assert(j == nCM);

    _ctx = _min(0x1F, x ~/ _max(1, wd ~/ _min(32, _columns0))) |
        (((((w - n).abs() * 16 > w + n) ? 2 : 0) |
                ((n - nw).abs() > 8 ? 1 : 0)) <<
            5) |
        ((w + n) & 0x180);
    _res = _clamp4(w + n - nw, w, nw, n, ne);
  }

  @override
  void mix(ZcmState s, Mixer m) {
    prepare(s);
    final bpos = s.bpos;
    final c0 = s.c0;
    final y = s.y;
    _cm.mix(m, y, bpos, c0, s.c4 & 255);
    _map0.update(y);
    _map1.update(y);
    final b = (c0 << (8 - bpos)) & 255;
    _map0.set(0);
    _map1.set(((((_clip(_pw + _pn - _pnw) - b) & 255) * 8 + bpos)) |
        _diffQt(_clip(_pn + _pne - _pnne), _clip(_pn + _pnw - _pnnw)) << 11);
    _map0.mix(m);
    _map1.mix(m);
    _r1.mix(m, bpos, c0);
    _r2.mix(m, bpos, c0);
    _r3.mix(m, bpos, c0);
    _o1.mix(m, bpos, c0);
    _o2.mix(m, bpos, c0);
    m.add(0);
  }

  @override
  void setMixerContexts(ZcmState s, Mixer m) {
    final bpos = s.bpos;
    final c0 = s.c0;
    final w = _pw, n = _pn;
    _col = (_col + 1) & 7;
    m.set(_ctx);
    m.set(_col << 1 | (c0 == ((0x100 | _res) >> (8 - bpos)) ? 1 : 0));
    m.set((n + w) >> 4);
    m.set(c0 - 1);
    m.set(((w - n).abs() > 4 ? 512 : 0) |
        ((n - _pne).abs() > 4 ? 256 : 0) |
        ((w - _pnw).abs() > 4 ? 128 : 0) |
        (w > n ? 64 : 0) |
        (n > _pne ? 32 : 0) |
        (w > _pnw ? 16 : 0) |
        (w > _pww ? 8 : 0) |
        (n > _pnn ? 4 : 0) |
        (_pnw > _pnnww ? 2 : 0) |
        (_pne > _pnnee ? 1 : 0));
    m.set(_min(63, _x ~/ _columns0));
    m.set(_min(127, _x ~/ _columns1));
    m.set(_min(255, (_x + _line) ~/ 32));
  }
}
