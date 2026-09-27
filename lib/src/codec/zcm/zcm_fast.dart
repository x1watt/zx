// zcm: the level 1 predictor, written as one class for speed.
//
// lpaq1 style (Matt Mahoney): orders 1, 2, 3, 4 and 6 in hashed tables
// with one 64 byte line of 16 entries per context and nibble (the layout
// of lpaq's nibble tables and zpaq's CM component), each entry a fast and
// a slow adaptive probability; an order 1 table indexed directly; a match
// model on the last 6 bytes; one mixer weight set per partial byte; and
// one APM. No model objects, no virtual calls on the bit path.

import 'dart:typed_data';

import 'zcm_components.dart';
import 'zcm_models.dart';
import 'zcm_predictor.dart';
import 'zcm_tables.dart';

/// The predictor of level 1.
final class ZcmFastPredictor implements ZcmBitPredictor {
  static const int _nOrd = 5;
  static const int _nIn = _nOrd + 1 + 2 + 1; // orders, order 1, match, bias
  static const int _stride = 12; // _nIn padded
  static const int _minLen = 6;

  @override
  final ZcmState s;
  final Uint32List _t;
  final int _mask;
  final Int32List _ctx = Int32List(_nOrd);
  final Int32List _base = Int32List(_nOrd);
  final Int32List _idx = Int32List(_nOrd);
  final Uint32List _o1 = Uint32List(1 << 16)..fillRange(0, 1 << 16, 2048 << 20);
  int _o1i = 0;
  // Match model.
  final Int32List _ht;
  final int _htMask;
  int _ptr = 0, _len = 0, _exp = 0;
  final Uint32List _msm = Uint32List(64 * 2)..fillRange(0, 128, 2048 << 20);
  int _msi = 0;
  // Mixer.
  final Int32List _w = Int32List(256 * _stride);
  final Int32List _x = Int32List(_stride);
  int _wo = 0;
  int _pr12 = 2048;
  int _rate = 56 << 16;
  // APM.
  final Apm _apm = Apm(256 * 8);
  int _misses = 0;
  int _pr = 2048;

  @override
  final int tableBytes;

  static final Int32List _dt16 = () {
    final t = Int32List(16);
    for (var i = 0; i < 16; i++) {
      t[i] = (65536 * 2) ~/ (2 * i + 3);
    }
    return t;
  }();

  factory ZcmFastPredictor(int budgetBytes) {
    final buf = zcmBufferBytes(budgetBytes);
    final ht = floorPow2(budgetBytes ~/ 32);
    var tb = budgetBytes - buf - ht * 4 - (1 << 20);
    if (tb < (1 << 16)) tb = 1 << 16;
    return ZcmFastPredictor._(buf, ht, floorPow2(tb ~/ 4));
  }

  ZcmFastPredictor._(int bufBytes, int htEntries, int entries)
      : s = ZcmState(bufBytes),
        _t = Uint32List(entries)
          ..fillRange(0, entries, (2048 << 20) | (32768 << 4)),
        _mask = entries - 1,
        _ht = Int32List(htEntries),
        _htMask = htEntries - 1,
        tableBytes = bufBytes + htEntries * 4 + entries * 4 {
    _w.fillRange(0, _w.length, 16384);
  }

  @override
  void setSegment(int type, int info) {
    s.blockType = type;
    s.blockInfo = info;
    s.blockPos = 0;
  }

  @override
  @pragma('vm:prefer-inline')
  void update(int bit) => s.update(bit);

  // Byte boundary: new contexts and the match model.
  void _byte() {
    final st = s;
    final c4 = st.c4;
    final c8 = st.c8;
    final ctx = _ctx;
    ctx[0] = hash2(c4 & 0xFF, 1);
    ctx[1] = hash2(c4 & 0xFFFF, 2);
    ctx[2] = hash2(c4 & 0xFFFFFF, 3);
    ctx[3] = hash2(c4, 4);
    ctx[4] = hash2(hash2(c4, c8 & 0xFFFF), 6);
    // Match model.
    final buf = st.buf;
    final bm = st.bufMask;
    final pos = st.pos;
    if (_len > 0) {
      if (_exp == (c4 & 255)) {
        _len++;
        if (_len > 65535) _len = 65535;
        _ptr++;
      } else {
        _len = 0;
      }
    }
    if (pos >= _minLen) {
      final h = hash2(c4, c8 & 0xFFFF) & _htMask;
      if (_len == 0) {
        final cand = _ht[h];
        if (cand > 0 && pos - cand < bm - 64) {
          var l = 0;
          while (l < 64 &&
              l < cand &&
              buf[(cand - 1 - l) & bm] == buf[(pos - 1 - l) & bm]) {
            l++;
          }
          if (l >= _minLen) {
            _len = l;
            _ptr = cand;
          }
        }
      }
      _ht[h] = pos;
    }
    if (_len > 0) _exp = buf[_ptr & bm];
  }

  @override
  @pragma('vm:unsafe:no-bounds-checks')
  int p() {
    final st = s;
    final y = st.y;
    final bpos = st.bpos;
    final c0 = st.c0;
    final x = _x;
    final w = _w;
    // Train the mixer with the last bit.
    {
      final err0 = (y << 12) - _pr12;
      if (err0 <= -4 || err0 >= 4) {
        final err = (err0 * _rate) >> 16;
        final o = _wo;
        for (var i = 0; i < _nIn; i++) {
          w[o + i] += (x[i] * err) >> 16;
        }
      }
      if (_rate > (14 << 16)) _rate--;
    }
    if (bpos == 0) _byte();
    // Order n tables: update the last entry, find the next.
    final t = _t;
    final str = kStretch;
    final ctx = _ctx;
    final base = _base;
    final idx = _idx;
    if (bpos == 0 || bpos == 4) {
      final nib = bpos == 0 ? 0 : (c0 & 15) + 1;
      final mask = _mask;
      for (var i = 0; i < _nOrd; i++) {
        base[i] = (hash2(ctx[i], nib) << 4) & mask;
      }
    }
    final sub = bpos < 4 ? c0 : (1 << (bpos - 4)) | (c0 & ((1 << (bpos - 4)) - 1));
    final yf = y << 12;
    final ys = y << 16;
    final dts = _dt16;
    for (var i = 0; i < _nOrd; i++) {
      final li = idx[i];
      final e = t[li];
      var pf = e >> 20;
      var ps = (e >> 4) & 0xFFFF;
      final c = e & 15;
      pf += (yf - pf) >> 2;
      ps += ((ys - ps) * dts[c]) >> 16;
      t[li] = (pf << 20) | (ps << 4) | (c < 14 ? c + 1 : c);
      final ni = base[i] + sub;
      idx[i] = ni;
      final e2 = t[ni];
      x[i] = (str[e2 >> 20] + str[(e2 >> 8) & 0xFFF]) >> 1;
    }
    // Order 1 direct.
    final dt = kDt;
    final target = y << 22;
    {
      final o1 = _o1;
      final e = o1[_o1i];
      final en = e & 1023;
      final ep = e >> 10;
      o1[_o1i] = ((ep + (((target - ep) * dt[en]) >> 31)) << 10) |
          (en < 1023 ? en + 1 : en);
      _o1i = ((st.c4 & 255) << 8) | c0;
      x[_nOrd] = str[o1[_o1i] >> 20];
    }
    // Match model.
    {
      final msm = _msm;
      final e = msm[_msi];
      final en = e & 1023;
      final ep = e >> 10;
      msm[_msi] = ((ep + (((target - ep) * dt[en]) >> 31)) << 10) |
          (en < 1023 ? en + 1 : en);
      if (_len > 0 && ((_exp + 256) >> (8 - bpos)) != c0) _len = 0;
      if (_len > 0) {
        final bit = (_exp >> (7 - bpos)) & 1;
        final lq = _len < 32 ? _len : 32 + (_len >> 6 < 31 ? _len >> 6 : 31);
        _msi = (lq > 63 ? 63 : lq) << 1 | bit;
        final st1 = str[msm[_msi] >> 20];
        x[_nOrd + 1] = st1;
        final lc = _len < 32 ? _len : 32;
        x[_nOrd + 2] = bit != 0 ? lc << 6 : -(lc << 6);
      } else {
        _msi = 0;
        x[_nOrd + 1] = 0;
        x[_nOrd + 2] = 0;
      }
    }
    x[_nOrd + 3] = 256;
    // Mix.
    final o = c0 * _stride;
    _wo = o;
    var dot = 0;
    for (var i = 0; i < _nIn; i++) {
      dot += x[i] * w[o + i];
    }
    dot >>= 16;
    if (dot > 2047) dot = 2047;
    if (dot < -2047) dot = -2047;
    final pr = kSquash[dot + 2048];
    _pr12 = pr;
    // APM on the partial byte and the recent misses.
    final miss = (_pr >= 2048) != (y == 1) ? 1 : 0;
    _misses = ((_misses << 1) | miss) & 0xFFFF;
    final m3 = (_misses & 1) |
        ((_misses & 0xFE) != 0 ? 2 : 0) |
        ((_misses & 0xFF00) != 0 ? 4 : 0);
    final pa = _apm.pp16(y, pr, c0 | m3 << 8);
    var pf = ((pr << 4) * 3 + pa + 2) >> 2;
    if (pf < 1) pf = 1;
    if (pf > 65535) pf = 65535;
    _pr = pf >> 4;
    return pf;
  }
}
