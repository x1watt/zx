// zcm: paq8px's sparse match, sparse bit, linear prediction and
// similarity models.
//
// Ports of paq8px's SparseMatchModel (Marcio Pais), SparseBitModel,
// LinearPredictionModel (Marcio Pais, with Sebastian Lehmann's OLS) and
// SimilarityModel / SimilarityModelPair (the paq8px authors):
//   * sparse match: matches of the recent bytes with some bits masked
//     off or with a gap (every second byte, one byte skipped), predicting
//     the byte that followed;
//   * sparse bits: contexts of the last four bytes with bit masks;
//   * linear prediction: least squares fits over the last 32 bytes (at
//     strides 1, 2 and 3) and simple extrapolations, their residuals
//     modeled by histograms, for numeric data that no detector found;
//   * similarity: for every distance up to a window, a running mean of
//     how far the byte at that distance was from the actual byte; the
//     closest distances give predictions (like a match that tolerates
//     small differences), and the best record length gives row
//     predictions (undetected images and tables).
// Integers, except the fits (doubles, see zcm_ols.dart).

import 'dart:typed_data';

import 'zcm_components.dart';
import 'zcm_maps.dart';
import 'zcm_models.dart';
import 'zcm_ols.dart';
import 'zcm_tables.dart';

@pragma('vm:prefer-inline')
int _ilog2(int x) => x <= 0 ? 0 : x.bitLength - 1;

/// |int8(a - b)| (paq8px rabs).
@pragma('vm:prefer-inline')
int _rabs(int a, int b) {
  final d = (a - b).toSigned(8);
  return d < 0 ? -d : d;
}

/// paq8px SparseMatchModel.
final class SparseMatchModel implements ZcmModel, ZcmMixerContexts {
  static const int _numHashes = 4;
  // offset, stride, deletions, minLen, bitMask
  static const List<int> _offset = [0, 1, 0, 0];
  static const List<int> _stride = [1, 1, 2, 1];
  static const List<int> _minLen = [5, 4, 4, 5];
  static const List<int> _bitMask = [0xDF, 0xFF, 0xDF, 0x0F];
  static const int _maxLen = 0xFFFF;

  final Uint32List _table;
  final int _mask;
  final int _hashBits;
  final ZcmLargeStationaryMap _mapL;
  final ZcmStationaryMap _map0 = ZcmStationaryMap(17, 4);
  final ZcmStationaryMap _map1 = ZcmStationaryMap(8, 1);
  final ZcmStationaryMap _map2 = ZcmStationaryMap(19, 1);
  final ZcmIndirectContext _iCtx8 = ZcmIndirectContext(19, 1);
  final ZcmIndirectContext _iCtx16 = ZcmIndirectContext(16, 8, valueBits: 16);
  final ZcmMtfList _list = ZcmMtfList(_numHashes);
  final Int32List _hashes = Int32List(_numHashes);
  int _hashIndex = 0;
  int _length = 0;
  int _index = 0;
  int _expectedByte = 0;
  bool _valid = false;
  bool _mixed = false;

  /// [bytes]: the hash table of positions (4 bytes each).
  SparseMatchModel(int bytes, {int mapBits = 17})
      : _table = Uint32List(floorPow2(bytes ~/ 4 < 4096 ? 4096 : bytes ~/ 4)),
        _mask = floorPow2(bytes ~/ 4 < 4096 ? 4096 : bytes ~/ 4) - 1,
        _hashBits = log2Exact(floorPow2(bytes ~/ 4 < 4096 ? 4096 : bytes ~/ 4)),
        _mapL = ZcmLargeStationaryMap(1, mapBits);

  /// Table bytes for [bytes] of hash table and [mapBits].
  static int tableBytes(int bytes, int mapBits) =>
      floorPow2(bytes ~/ 4 < 4096 ? 4096 : bytes ~/ 4) * 4 +
      (6 << mapBits) * 7 +
      (1 << 17) * 15 * 4 +
      (1 << 8) * 4 +
      (1 << 19) * 4 +
      (1 << 19) * 4 +
      (1 << 16) * 4;

  @override
  int get inputs => 3 + 3 + 3 * 3;

  @override
  List<int> get mixerContextSizes => const [_numHashes * 64, _numHashes * 2048];

  void _update(ZcmState s) {
    final buf = s.buf;
    final bm = s.bufMask;
    final pos = s.pos;
    for (var i = 0; i < _numHashes; i++) {
      var h = 0;
      var k = _offset[i] + 1;
      final bmk = _bitMask[i];
      for (var j = 0; j < _minLen[i]; j++, k += _stride[i]) {
        h = hash2(h, buf[(pos - k) & bm] & bmk);
      }
      _hashes[i] = (h >> (32 - _hashBits)) & _mask;
    }
    if (_length != 0) {
      _index++;
      if (_length < _maxLen) _length++;
    } else {
      for (var i = _list.getFirst(); i >= 0; i = _list.getNext()) {
        _index = _table[_hashes[i]];
        if (_index > 0) {
          var offset = _offset[i] + 1;
          final ml = _minLen[i], bmk = _bitMask[i];
          while (_length < ml &&
              ((buf[(pos - offset) & bm] ^ buf[(_index - offset) & bm]) &
                      bmk) ==
                  0) {
            _length++;
            offset += _stride[i];
          }
          if (_length >= ml) {
            _length -= ml - 1;
            _hashIndex = i;
            _list.moveToFront(i);
            break;
          }
        }
        _length = _index = 0;
      }
    }
    for (var i = 0; i < _numHashes; i++) {
      _table[_hashes[i]] = pos;
    }
    final c1 = s.c4 & 255;
    _expectedByte = _length != 0 ? buf[_index & bm] : 0;
    if (_valid) {
      _iCtx8.add(s.y);
      _iCtx16.add(c1);
    }
    _valid = _length > 1;
    if (_valid) {
      _mapL.set(hash4(_expectedByte, s.c0, c1 | ((s.c4 >> 8) & 0xFF) << 8,
          _ilog2(_length + 1) * _numHashes + _hashIndex));
      final c1e = c1 << 8 | _expectedByte;
      _map0.set(c1e);
      _iCtx8.select(c1e);
      _iCtx16.select(c1e);
      _map1.set(_iCtx8.value);
      _map2.set(_iCtx16.value);
    }
  }

  @override
  void mix(ZcmState s, Mixer m) {
    final y = s.y;
    if (_mixed) {
      _mapL.update(y);
      _map0.update(y);
      _map1.update(y);
      _map2.update(y);
      _mixed = false;
    }
    final bpos = s.bpos;
    final c0 = s.c0;
    final b = (c0 << (8 - bpos)) & 255;
    if (bpos == 0) {
      _update(s);
    } else if (_valid) {
      final c1 = s.c4 & 255;
      _mapL.set(hash4(_expectedByte, c0, c1 | ((s.c4 >> 8) & 0xFF) << 8,
          _ilog2(_length + 1) * _numHashes + _hashIndex));
      if (bpos == 4) {
        _map0.set(0x10000 | ((_expectedByte ^ ((c0 << 4) & 255)) << 8) | c1);
      }
      _iCtx8.add(y);
      _iCtx8.select((bpos << 16) | (c1 << 8) | (_expectedByte ^ b));
      _map1.set(_iCtx8.value);
      _map2.set((bpos << 16) | (_iCtx16.value ^ (b | (b << 8))));
    }
    final bmk = _bitMask[_hashIndex];
    if (_length > 0 && (((_expectedByte ^ b) & bmk) >> (8 - bpos)) != 0) {
      _length = 0;
    }
    final tx = m.tx;
    if (_valid) {
      var k = m.nx;
      if (_length > 1 && ((bmk >> (7 - bpos)) & 1) != 0) {
        final expectedBit = (_expectedByte >> (7 - bpos)) & 1;
        final sign = 2 * expectedBit - 1;
        final l1 = _length - 1;
        tx[k] = sign * ((l1 < 64 ? l1 : 64) << 4);
        final l2 = _length - 2 < 3 ? _length - 2 : 3;
        tx[k + 1] = (sign * (1 << l2) * (l1 < 8 ? l1 : 8)) << 4;
        tx[k + 2] = sign * 512;
      } else {
        tx[k] = 0;
        tx[k + 1] = 0;
        tx[k + 2] = 0;
      }
      m.nx = k + 3;
      _mapL.mix(m);
      _map0.mix(m);
      _map1.mix(m);
      _map2.mix(m);
      _mixed = true;
    } else {
      var k = m.nx;
      for (var i = 0; i < 15; i++) {
        tx[k++] = 0;
      }
      m.nx = k;
    }
  }

  @override
  void setMixerContexts(ZcmState s, Mixer m) {
    final bpos = s.bpos;
    final l = _length;
    m.set((_hashIndex << 6) | (bpos << 3) | (l < 7 ? l : 7));
    final il = _ilog2(l + 1);
    m.set((_hashIndex << 11) |
        ((il < 7 ? il : 7) << 8) |
        ((s.c0 ^ (_expectedByte >> (8 - bpos))) & 255));
  }
}

/// paq8px SparseBitModel: contexts of the last 4 bytes under bit masks
/// (6 on text, 10 on other data).
final class SparseBitModel implements ZcmModel {
  final ContextMap _cm;

  SparseBitModel(int bytes) : _cm = ContextMap(bytes, 10, rich: false);

  @override
  int get inputs => _cm.nCtx * _cm.inputsPerContext;

  @override
  void mix(ZcmState s, Mixer m) {
    if (s.bpos == 0) {
      final c4 = s.c4;
      final cm = _cm;
      cm.set(0, hash2(1, c4 & 0x00F0F0FF));
      cm.set(1, hash2(2, c4 & 0xDFDFDFE0));
      cm.set(2, hash2(3, c4 & 0xFFC0FFC0));
      cm.set(3, hash2(4, c4 & 0xE0FFFFE0));
      cm.set(4, hash2(5, c4 & 0x00E0E0E0));
      cm.set(5, hash2(6, c4 & 0xE0E0E0E0));
      if (s.blockType != ZcmBlockType.text) {
        cm.set(6, hash2(7, c4 & 0x0000F8F8));
        cm.set(7, hash2(8, c4 & 0x00F8F8F8));
        cm.set(8, hash2(9, c4 & 0xF8F8F8F8));
        cm.set(9, hash2(10, c4 & 0x0F0F0F0F));
      } else {
        cm.skip(6);
        cm.skip(7);
        cm.skip(8);
        cm.skip(9);
      }
    }
    _cm.mix(m, s.y, s.bpos, s.c0, s.c4 & 255);
  }
}

/// paq8px LinearPredictionModel: three least squares fits over the last
/// 32 bytes at strides 1, 2 and 3 and four extrapolations, 7 residual
/// histograms selected by each prediction's recent error.
final class LinearPredictionModel implements ZcmModel {
  static const int _nOls = 3;
  static const int _nRm = _nOls + 4;
  final List<ZcmOls> _ols = [
    for (var i = 0; i < _nOls; i++) ZcmOls(32, 4, 1.0 - 1.0 / 162.0)
  ];
  final ResidualMap _mapR = ResidualMap(_nRm, 32, scale: 128);
  final Int32List _prd = Int32List(_nRm);
  final Int32List _err = Int32List(_nRm);
  bool _started = false;

  @override
  int get inputs => _nRm * 2;

  static int _round(double v) {
    if (!v.isFinite) return 0;
    if (v > 32767) return 32767;
    if (v < -32768) return -32768;
    return (v + (v < 0 ? -0.5 : 0.5)).toInt();
  }

  @override
  void mix(ZcmState s, Mixer m) {
    final bpos = s.bpos;
    if (bpos == 0) {
      final c1 = s.c4 & 255;
      if (_started) _mapR.update(c1);
      for (var i = 0; i < _nRm; i++) {
        final e = _rabs(c1, _prd[i]);
        _err[i] = ((_err[i] * 15) >> 4) + e;
      }
      final buf = s.buf;
      final bm = s.bufMask;
      final pos = s.pos;
      final w = c1, ww = buf[(pos - 2) & bm], www = buf[(pos - 3) & bm];
      if (_started) {
        final v = w.toDouble();
        for (var i = 0; i < _nOls; i++) {
          _ols[i].update(v);
        }
      }
      _started = true;
      final o0 = _ols[0], o1 = _ols[1], o2 = _ols[2];
      for (var i = 1; i <= 32; i++) {
        o0.add(buf[(pos - i) & bm].toDouble());
        o1.add(buf[(pos - i * 2) & bm].toDouble());
        o2.add(buf[(pos - i * 3) & bm].toDouble());
      }
      var i = 0;
      for (; i < _nOls; i++) {
        _prd[i] = _round(_ols[i].predict());
      }
      _prd[i++] = (w * 2 - ww).toSigned(16);
      _prd[i++] = (w * 3 - ww * 3 + www).toSigned(16);
      _prd[i++] = (ww * 2 - buf[(pos - 4) & bm]).toSigned(16);
      _prd[i++] = (www * 2 - buf[(pos - 6) & bm]).toSigned(16);
      final bp = s.blockPos & 1;
      for (var j = 0; j < _nRm; j++) {
        final e = _err[j] >> 4;
        _mapR.set(_prd[j], (e < 15 ? e : 15) << 1 | bp);
      }
    }
    _mapR.mix(m, bpos, s.c0);
  }
}

/// One paq8px SimilarityModel (the slow or the fast one of a pair).
final class _Similarity {
  static const int _nRm1 = 16, _nRm2 = 2, _nCm = 8;
  final int maxDistance;
  final int maxRecord;
  final ResidualMap mapR1 = ResidualMap(_nRm1, 32);
  final ResidualMap mapR2 = ResidualMap(_nRm2, 64 * 16);
  final ContextMap cm;
  final Uint16List ema;
  final Int32List matchIndex = Int32List(2);
  final Int32List matchScore = Int32List(2);
  int recordLen = 1;
  int recordScore = 0;
  int mctx1 = 0, mctx2 = 0;

  _Similarity(int bytes, this.maxDistance, this.maxRecord)
      : cm = ContextMap(bytes, _nCm, rich: false, bh: true),
        ema = Uint16List(maxDistance)..fillRange(0, maxDistance, 64 << 8);

  static int inputsFor() => (_nRm1 + _nRm2) * 2 + _nCm * 6;

  // SimilarityModel::update: the best record length.
  void findRecord(int warmup) {
    final count = warmup < maxRecord ? warmup : maxRecord;
    var best = 0x7FFFFFFF;
    final e = ema;
    final md = maxDistance;
    for (var i = 0; i < count; i++) {
      final rl = count - i;
      final r = e[md - rl] + e[md - rl * 2] + e[md - rl * 3] + e[md - rl * 4];
      if (r <= best) {
        recordLen = rl;
        best = r;
      }
    }
    recordScore = best == 0x7FFFFFFF ? 0 : best;
  }

  // SimilarityModel::mix at a byte boundary.
  void byteContexts(ZcmState s) {
    final buf = s.buf;
    final bm = s.bufMask;
    final pos = s.pos;
    final md = maxDistance;
    final d0 = md - matchIndex[0], d1 = md - matchIndex[1];
    final e0 = buf[(pos - d0) & bm];
    final e1 = buf[(pos - d1) & bm];
    final ms0 = matchScore[0], ms1 = matchScore[1];
    mapR1.set(e0, (ms0 >> 8) < 31 ? ms0 >> 8 : 31);
    mapR1.set(e1, (ms1 >> 8) < 31 ? ms1 >> 8 : 31);
    final r = _rabs(e0, e1) >> 1;
    mapR2.set(e0, (r < 63 ? r : 63) << 4 | ((ms0 >> 9) < 15 ? ms0 >> 9 : 15));
    final w = buf[(pos - 1) & bm], ww = buf[(pos - 2) & bm];
    final wwww = buf[(pos - 4) & bm];
    int he0, he1, he2;
    {
      final n0 = buf[(pos - d0) & bm], nw0 = buf[(pos - d0 - 1) & bm];
      final nww0 = buf[(pos - d0 - 2) & bm], nwwww0 = buf[(pos - d0 - 4) & bm];
      he0 = (w + n0 - nw0).toSigned(16);
      mapR1.set(he0, _min(_rabs(w, ww + nw0 - nww0), 31));
      he1 = (ww + n0 - nww0).toSigned(16);
      mapR1.set(he1, _min(_rabs(ww, wwww + nww0 - nwwww0), 31));
    }
    {
      final n0 = buf[(pos - d1) & bm], nw0 = buf[(pos - d1 - 1) & bm];
      final nww0 = buf[(pos - d1 - 2) & bm], nwwww0 = buf[(pos - d1 - 4) & bm];
      he2 = (w + n0 - nw0).toSigned(16);
      mapR1.set(he2, _min(_rabs(w, ww + nw0 - nww0), 31));
      mapR1.set((ww + n0 - nww0).toSigned(16),
          _min(_rabs(ww, wwww + nww0 - nwwww0), 31));
    }
    // Record model.
    final rl = recordLen;
    final n = buf[(pos - (rl)) & bm],
        nn = buf[(pos - (2 * rl)) & bm],
        nnn = buf[(pos - (3 * rl)) & bm],
        nnnn = buf[(pos - (4 * rl)) & bm];
    var bestN = n,
        bestNW = buf[(pos - (rl + 1)) & bm],
        bestNWW = buf[(pos - (rl + 2)) & bm];
    var bestNWWWW = buf[(pos - (rl + 4)) & bm];
    var scoreN = ema[md - rl], scoreNN = ema[md - rl * 2];
    var scoreNNN = ema[md - rl * 3], scoreNNNN = ema[md - rl * 4];
    var bestScore = scoreN;
    if (scoreNN < bestScore) {
      bestN = nn;
      bestNW = buf[(pos - (rl * 2 + 1)) & bm];
      bestNWW = buf[(pos - (rl * 2 + 2)) & bm];
      bestNWWWW = buf[(pos - (rl * 2 + 4)) & bm];
      bestScore = scoreNN;
    }
    if (scoreNNN < bestScore) {
      bestN = nnn;
      bestNW = buf[(pos - (rl * 3 + 1)) & bm];
      bestNWW = buf[(pos - (rl * 3 + 2)) & bm];
      bestNWWWW = buf[(pos - (rl * 3 + 4)) & bm];
      bestScore = scoreNNN;
    }
    if (scoreNNNN < bestScore) {
      bestN = nnnn;
      bestNW = buf[(pos - (rl * 4 + 1)) & bm];
      bestNWW = buf[(pos - (rl * 4 + 2)) & bm];
      bestNWWWW = buf[(pos - (rl * 4 + 4)) & bm];
      bestScore = scoreNNNN;
    }
    bestScore >>= 8;
    scoreN >>= 8;
    scoreNN >>= 8;
    scoreNNN >>= 8;
    scoreNNNN >>= 8;
    final columnScore = _rabs(bestN, n) +
        _rabs(bestN, nn) +
        _rabs(bestN, nnn) +
        _rabs(bestN, nnnn);
    mapR2.set(
        bestN, _min(bestScore >> 1, 31) << 5 | _min(columnScore >> 2, 31));
    mapR1.set((w + bestN - bestNW).toSigned(16),
        _min(_rabs(w, ww + bestNW - bestNWW), 31));
    mapR1.set((ww + bestN - bestNWW).toSigned(16),
        _min(_rabs(ww, wwww + bestNWW - bestNWWWW), 31));
    mapR1.set(n, _min(scoreN >> 1, 31));
    mapR1.set(nn, _min(scoreNN >> 1, 31));
    mapR1.set(nnn, _min(scoreNNN >> 1, 31));
    mapR1.set(nnnn, _min(scoreNNNN >> 1, 31));
    final nw = buf[(pos - (rl + 1)) & bm], nnw = buf[(pos - (2 * rl + 1)) & bm];
    final o2 = (2 * n - nn).toSigned(16);
    mapR1.set(o2, _min(_rabs(w, 2 * nw - nnw), 31));
    final nnnw = buf[(pos - (3 * rl + 1)) & bm],
        nnnnw = buf[(pos - (4 * rl + 1)) & bm],
        nnnnn = buf[(pos - (5 * rl)) & bm];
    final o3 = (3 * n - 3 * nn + nnn).toSigned(16);
    mapR1.set(
        o3,
        _min(
                _rabs(n, 3 * nn - 3 * nnn + nnnn) +
                    _rabs(w, 3 * nw - 3 * nnw + nnnw),
                63) >>
            1);
    final o4 = (4 * n - 6 * nn + 4 * nnn - nnnn).toSigned(16);
    mapR1.set(
        o4,
        _min(
                _rabs(n, 4 * nn - 6 * nnn + 4 * nnnn - nnnnn) +
                    _rabs(w, 4 * nw - 6 * nnw + 4 * nnnw - nnnnw),
                63) >>
            1);
    var lo = n, hi = n;
    if (nn < lo) lo = nn;
    if (nnn < lo) lo = nnn;
    if (nnnn < lo) lo = nnnn;
    if (nn > hi) hi = nn;
    if (nnn > hi) hi = nnn;
    if (nnnn > hi) hi = nnnn;
    mapR1.set((n + nn + nnn + nnnn + 2) >> 2, _min((hi - lo) >> 1, 31));
    // Hashed contexts.
    cm.set(0, hash4(n, nn, nnn, nnnn));
    cm.set(1, hash2(1, e0));
    cm.set(2, hash2(2, e1));
    cm.set(3, hash2(3, he0 + 256));
    cm.set(4, hash2(4, he1 + 256));
    cm.set(5, hash2(5, he2 + 256));
    cm.set(6, hash2(6, o2 + 256));
    cm.set(7, hash2(7, bestN));
    final columnCtx =
        columnScore <= 1 ? 0 : (columnScore < (recordScore >> 10) * 3 ? 1 : 2);
    final matchCtx = ms0 == 0 ? 0 : 1 + _min((ms0 >> 8) >> 2, 30);
    mctx1 = columnCtx << 5 | matchCtx;
    mctx2 = columnCtx << 1 | (recordScore == 0 ? 1 : 0);
  }

  @pragma('vm:prefer-inline')
  static int _min(int a, int b) => a < b ? a : b;
}

/// paq8px SimilarityModelPair: a slow (alpha 1/64) and a fast (alpha
/// 7/64) similarity model over the last [maxDistance] bytes.
final class SimilarityModel implements ZcmModel, ZcmMixerContexts {
  final _Similarity _slow;
  final _Similarity _fast;
  final int maxDistance;
  int _warmup = 0;
  bool _started = false;

  SimilarityModel(int bytes, this.maxDistance)
      : _slow = _Similarity(bytes ~/ 2, maxDistance,
            maxDistance ~/ 4 < 1024 ? maxDistance ~/ 4 : 1024),
        _fast = _Similarity(
            bytes ~/ 4,
            maxDistance,
            (maxDistance ~/ 4 < 1024 ? maxDistance ~/ 4 : 1024) ~/ 2 < 512
                ? (maxDistance ~/ 4 < 1024 ? maxDistance ~/ 4 : 1024) ~/ 2
                : 512);

  @override
  int get inputs => _Similarity.inputsFor() * 2;

  @override
  List<int> get mixerContextSizes => const [3 * 32, 3 * 2, 3 * 32, 3 * 2];

  // SimilarityModelPair::update: the running means of |int8(x - c1)| for
  // every distance, and the two closest distances of each model.
  @pragma('vm:unsafe:no-bounds-checks')
  void _updateEma(ZcmState s) {
    final buf = s.buf;
    final bm = s.bufMask;
    final pos = s.pos;
    final c1 = s.c4 & 255;
    final md = maxDistance;
    final count = _warmup < md ? _warmup : md;
    _warmup++;
    final e1 = _slow.ema, e2 = _fast.ema;
    var i1a = 0, i1b = 0, s1a = 0xFFFF, s1b = 0xFFFF;
    var i2a = 0, i2b = 0, s2a = 0xFFFF, s2b = 0xFFFF;
    final base = pos - 1 - count;
    final eb = md - count;
    for (var i = 0; i < count; i++) {
      var d = (buf[(base + i) & bm] - c1) & 255;
      if (d >= 128) d = 256 - d;
      final cur = d << 8;
      final idx = eb + i;
      final r1 = (e1[idx] * 63 + cur) >> 6;
      e1[idx] = r1;
      final r2 = (e2[idx] * 57 + cur * 7) >> 6;
      e2[idx] = r2;
      if (r1 < s1b) {
        if (r1 < s1a) {
          i1b = i1a;
          s1b = s1a;
          i1a = idx;
          s1a = r1;
        } else {
          i1b = idx;
          s1b = r1;
        }
      }
      if (r2 < s2b) {
        if (r2 < s2a) {
          i2b = i2a;
          s2b = s2a;
          i2a = idx;
          s2a = r2;
        } else {
          i2b = idx;
          s2b = r2;
        }
      }
    }
    _slow.matchIndex[0] = i1a;
    _slow.matchIndex[1] = i1b;
    _slow.matchScore[0] = s1a;
    _slow.matchScore[1] = s1b;
    _fast.matchIndex[0] = i2a;
    _fast.matchIndex[1] = i2b;
    _fast.matchScore[0] = s2a;
    _fast.matchScore[1] = s2b;
  }

  @override
  void mix(ZcmState s, Mixer m) {
    final bpos = s.bpos;
    if (bpos == 0) {
      final c1 = s.c4 & 255;
      if (_started) {
        _slow.mapR1.update(c1);
        _slow.mapR2.update(c1);
        _fast.mapR1.update(c1);
        _fast.mapR2.update(c1);
      }
      _started = true;
      _updateEma(s);
      _slow.findRecord(_warmup);
      _fast.findRecord(_warmup);
      _slow.byteContexts(s);
      _fast.byteContexts(s);
    }
    final c0 = s.c0;
    final y = s.y;
    final c1 = s.c4 & 255;
    for (var k = 0; k < 2; k++) {
      final sm = k == 0 ? _slow : _fast;
      sm.mapR1.mix(m, bpos, c0);
      sm.mapR2.mix(m, bpos, c0);
      sm.cm.mix(m, y, bpos, c0, c1);
    }
  }

  @override
  void setMixerContexts(ZcmState s, Mixer m) {
    m.set(_slow.mctx1);
    m.set(_slow.mctx2);
    m.set(_fast.mctx1);
    m.set(_fast.mctx2);
  }
}
