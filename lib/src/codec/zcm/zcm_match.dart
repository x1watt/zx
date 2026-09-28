// zcm: the match model of paq8px.
//
// A port of paq8px's MatchModel and MatchInfo (the paq8px authors, after
// the match model of paq8 by Matt Mahoney): the positions of the last
// three occurrences of the hashes of the last LEN1, LEN2 and LEN3 bytes
// are kept, up to four match candidates are followed at once (the best
// one predicts; the others tell whether the prediction is certain), and
// a candidate that fails on one byte is not dropped at once: it predicts
// in "delta" mode for the rest of that byte and is recovered when the
// byte after the mismatch agrees again (a substitution in a repeated
// string). The contexts are the expected byte, the match length and the
// mode, in state maps, a context map, a hashed stationary map and an
// indirect bit history.
//
// The minimum lengths depend on the segment type (text, binary, exe).

import 'dart:typed_data';

import 'zcm_components.dart';
import 'zcm_maps.dart';
import 'zcm_models.dart';
import 'zcm_tables.dart';

/// A generic StateMap that only learns in the contexts it predicted in
/// (paq8px StateMap with the update broadcaster).
final class _Sm {
  final Uint32List _t;
  int _cx = -1;
  _Sm(int n) : _t = Uint32List(n)..fillRange(0, n, 2048 << 20);

  @pragma('vm:prefer-inline')
  void update(int y) {
    final cx = _cx;
    if (cx >= 0) {
      _t[cx] = adaptEntry(_t[cx], y, 1023);
      _cx = -1;
    }
  }

  @pragma('vm:prefer-inline')
  int p1(int cx) {
    _cx = cx;
    return _t[cx] >> 20;
  }
}

/// paq8px MatchModel with up to 4 candidates and recovery.
final class PxMatchModel implements ZcmMatchInfo, ZcmMixerContexts {
  static const int _n = 4; // candidates
  static const int _slots = 3; // positions per hash element
  static const int _minLenRm = 3;
  static const int _maxLen = 65535;

  final Uint32List _table; // _slots positions per element
  final int _hashBits;
  final _Sm _sm0 = _Sm(28 * 2 * 8);
  final _Sm _sm1 = _Sm(256 * 8 * 256);
  final _Sm _sm2 = _Sm(256 * 256);
  final ContextMap _cm;
  final ZcmLargeStationaryMap _mapL;
  final ZcmStationaryMap _map = ZcmStationaryMap(1 + 6 + 5 + 3, 1);
  final ZcmIndirectContext _iCtx = ZcmIndirectContext(8, 1, contextBits: 6);
  final Int32List _len = Int32List(_n);
  final Int32List _idx = Int32List(_n);
  final Int32List _lenBak = Int32List(_n);
  final Int32List _idxBak = Int32List(_n);
  final Int32List _exp = Int32List(_n);
  final Uint8List _delta = Uint8List(_n);
  int _active = 0;
  bool _mapsMixed = false;

  /// The minimum lengths LEN1, LEN2 and LEN3 per segment type.
  final List<int> lensText;
  final List<int> lensBinary;
  final List<int> lensExe;
  int _l1 = 5, _l2 = 7, _l3 = 9;

  // Results of the last mix.
  int _length = 0;
  int _expected = 0;
  int _mode5 = 0;
  int _mode3 = 0;
  bool _isDelta = false;

  /// [bytes]: the position table (12 bytes per element); [mapBytes]: the
  /// context map.
  PxMatchModel(int bytes, int mapBytes,
      {this.lensText = const [5, 7, 9],
      this.lensBinary = const [5, 7, 9],
      this.lensExe = const [5, 7, 9],
      int mapLBits = 20})
      : _table = Uint32List(_elements(bytes) * _slots),
        _hashBits = log2Exact(_elements(bytes)),
        _cm = ContextMap(mapBytes, 2, rich: false),
        _mapL = ZcmLargeStationaryMap(1, mapLBits);

  static int _elements(int bytes) =>
      floorPow2(bytes ~/ 12 < 4096 ? 4096 : bytes ~/ 12);

  /// Bytes of the tables for [bytes] of positions and [mapLBits].
  static int tableBytes(int bytes, int mapLBits) =>
      _elements(bytes) * 12 +
      (6 << mapLBits) * 7 +
      (1 << 15) * 4 +
      (28 * 2 * 8 + 256 * 8 * 256 + 256 * 256) * 4;

  @override
  int get expectedByte => _length > 0 ? _expected : -1;

  @override
  int get length => _length;

  /// paq8px Match.length2: 0 no match, 1 delta, 2 short, 3 long.
  int get length2 => _isDelta ? 1 : (_length == 0 ? 0 : (_length <= 7 ? 2 : 3));

  /// paq8px Match.mode3 and mode5.
  int get mode3 => _mode3;
  int get mode5 => _mode5;

  @override
  int get inputs => 2 + 2 * 4 + 3 * 2 + 3 + 3;

  @override
  List<int> get mixerContextSizes => const [20];

  @pragma('vm:prefer-inline')
  bool _noMatch(int i) => _len[i] == 0 && _delta[i] == 0 && _lenBak[i] == 0;
  @pragma('vm:prefer-inline')
  bool _preRecovery(int i) => _len[i] == 0 && _delta[i] == 0 && _lenBak[i] != 0;
  @pragma('vm:prefer-inline')
  bool _recovery(int i) => _len[i] != 0 && _lenBak[i] != 0;

  // MatchInfo::update
  void _updateCandidate(int i, ZcmState s, int y, int bpos) {
    if (_len[i] != 0) {
      final expectedBit = (_exp[i] >> ((8 - bpos) & 7)) & 1;
      if (y != expectedBit) {
        if (_recovery(i)) {
          _lenBak[i] = 0;
          _idxBak[i] = 0;
        } else {
          _lenBak[i] = _len[i];
          _idxBak[i] = _idx[i];
          _delta[i] = 1;
        }
        _len[i] = 0;
      }
    }
    if (bpos == 0) {
      if (_preRecovery(i)) {
        _idxBak[i]++;
        if (_lenBak[i] < _maxLen) _lenBak[i]++;
        if (s.buf[_idxBak[i] & s.bufMask] == (s.c4 & 255)) {
          _len[i] = _lenBak[i];
          _idx[i] = _idxBak[i];
        } else {
          _lenBak[i] = 0;
          _idxBak[i] = 0;
        }
      }
      if (_len[i] != 0) {
        _idx[i]++;
        if (_len[i] < _maxLen) _len[i]++;
        if (_recovery(i) && _len[i] - _lenBak[i] >= _minLenRm) {
          _lenBak[i] = 0;
          _idxBak[i] = 0;
        }
      }
      _delta[i] = 0;
    }
  }

  void _remove(int i) {
    for (var j = i; j < _active; j++) {
      _len[j] = _len[j + 1 < _n ? j + 1 : j];
      _idx[j] = _idx[j + 1 < _n ? j + 1 : j];
      _lenBak[j] = _lenBak[j + 1 < _n ? j + 1 : j];
      _idxBak[j] = _idxBak[j + 1 < _n ? j + 1 : j];
      _exp[j] = _exp[j + 1 < _n ? j + 1 : j];
      _delta[j] = _delta[j + 1 < _n ? j + 1 : j];
    }
  }

  bool _isMatch(ZcmState s, int p, int minLen) {
    final buf = s.buf;
    final bm = s.bufMask;
    final pos = s.pos;
    if (pos - p > bm - 64) return false;
    for (var l = 1; l <= minLen; l++) {
      if (buf[(pos - l) & bm] != buf[(p - l) & bm]) return false;
    }
    return true;
  }

  void _addCandidates(ZcmState s, int e, int len) {
    var i = 0;
    final t = _table;
    while (_active < _n && i < _slots) {
      final p = t[e + i];
      if (p == 0) break;
      if (_isMatch(s, p, len)) {
        var same = false;
        for (var j = 0; j < _active; j++) {
          if (_idx[j] == p) {
            same = true;
            break;
          }
        }
        if (!same) {
          final a = _active;
          _len[a] = len - _l1 + 1;
          _idx[a] = p;
          _lenBak[a] = 0;
          _idxBak[a] = 0;
          _exp[a] = 0;
          _delta[a] = 0;
          _active = a + 1;
        }
      }
      i++;
    }
  }

  // Hash of the last [n] bytes.
  static int _hashLast(Uint8List buf, int bm, int pos, int n) {
    var h = n * 0x2F0F3A55;
    for (var k = 1; k <= n; k++) {
      h = (h * 0x2F0F3A55 + buf[(pos - k) & bm] + 1) & 0xFFFFFFFF;
    }
    return hash2(h, n);
  }

  void _addPos(int e, int pos) {
    final t = _table;
    t[e + 2] = t[e + 1];
    t[e + 1] = t[e];
    t[e] = pos;
  }

  void _update(ZcmState s, int y, int bpos) {
    final n = _active > 1 ? _active : 1;
    for (var i = 0; i < n; i++) {
      _updateCandidate(i, s, y, bpos);
      if (_active != 0 && _noMatch(i)) {
        _active--;
        if (_active == i) break;
        _remove(i);
        i--;
      }
    }
    if (bpos == 0) {
      final type = s.blockType;
      final lens = type == ZcmBlockType.text
          ? lensText
          : (type == ZcmBlockType.exe ? lensExe : lensBinary);
      _l1 = lens[0];
      _l2 = lens[1];
      _l3 = lens[2];
      final buf = s.buf;
      final bm = s.bufMask;
      final pos = s.pos;
      final sh = 32 - _hashBits;
      for (var k = 2; k >= 0; k--) {
        final len = k == 2 ? _l3 : (k == 1 ? _l2 : _l1);
        if (pos < len) continue;
        final e = (_hashLast(buf, bm, pos, len) >> sh) * _slots;
        if (_active < _n) _addCandidates(s, e, len);
        _addPos(e, pos);
      }
      for (var i = 0; i < _active; i++) {
        _exp[i] = buf[_idx[i] & bm];
      }
    }
  }

  // MatchInfo::prio
  @pragma('vm:prefer-inline')
  int _prio(int i) =>
      (_len[i] != 0 ? 1 << 49 : 0) |
      (_delta[i] << 48) |
      ((_delta[i] != 0 ? _lenBak[i] : _len[i]) << 32) |
      (_idx[i] & 0xFFFFFFFF);

  @override
  void mix(ZcmState s, Mixer m) {
    final y = s.y;
    final bpos = s.bpos;
    _sm0.update(y);
    _sm1.update(y);
    _sm2.update(y);
    if (_mapsMixed) {
      _mapL.update(y);
      _map.update(y);
    }
    _update(s, y, bpos);
    var best = 0;
    var bestPrio = _prio(0);
    for (var i = 1; i < _active; i++) {
      final p = _prio(i);
      if (p > bestPrio) {
        bestPrio = p;
        best = i;
      }
    }
    final length = _len[best];
    final expectedByte = _exp[best];
    final noMatch = _noMatch(best);
    final isDelta = _delta[best] != 0;
    final preRec = _preRecovery(best);
    final rec = _recovery(best);
    final c0 = s.c0;
    final c1 = s.c4 & 255;
    final expectedBit = length != 0 ? (expectedByte >> (7 - bpos)) & 1 : 0;
    var n0 = 0, n1 = 0;
    for (var i = 0; i < _active; i++) {
      if (_len[i] == 0) continue;
      final b = (_exp[i] >> (7 - bpos)) & 1;
      n0 += 1 - b;
      n1 += b;
    }
    final uncertain = n0 != 0 && n1 != 0 ? 1 : 0;
    final tx = m.tx;
    var k = m.nx;
    var ctx0 = 0, ctx1 = 0, ctx2 = 0;
    if (length != 0) {
      final dl = length <= 16
          ? length - 1
          : 12 + ((length - 1 < 63 ? length - 1 : 63) >> 2);
      ctx0 = 1 + ((dl << 4) | (expectedBit << 3) | bpos);
      ctx1 = 1 + ((expectedByte << 11) | (bpos << 8) | c1);
      final sign = 2 * expectedBit - 1;
      tx[k] = sign * ((length < 32 ? length : 32) << 5);
      tx[k + 1] = sign * (kIlog[length < 65535 ? length : 65535] << 2);
    } else {
      tx[k] = 0;
      tx[k + 1] = 0;
    }
    k += 2;
    if (isDelta) ctx2 = 1 + ((expectedByte << 8) | c0);
    final str = kStretch;
    for (var i = 0; i < 3; i++) {
      final c = i == 0 ? ctx0 : (i == 1 ? ctx1 : ctx2);
      if (c != 0) {
        final sm = i == 0 ? _sm0 : (i == 1 ? _sm1 : _sm2);
        final p1 = sm.p1(i == 2 ? (c - 1) & 0xFFFF : c - 1);
        tx[k] = str[p1] >> 2;
        tx[k + 1] = (p1 - 2048) >> 3;
      } else {
        tx[k] = 0;
        tx[k + 1] = 0;
      }
      k += 2;
    }
    m.nx = k;
    final l2 = (length >> 2) < 3 ? length >> 2 : 3;
    final mode3 =
        noMatch ? 0 : (isDelta ? 1 : (preRec ? 2 : (rec ? 3 : 4 + l2)));
    final mode5 = noMatch
        ? 0
        : (isDelta
            ? 1
            : (preRec
                ? 2
                : (rec ? 3 : 4 + (l2 << 2 | expectedBit << 1 | uncertain))));
    if (bpos == 0) {
      _cm.set(0, hash2((length != 0 ? expectedByte : c1) << 3 | mode3, 1));
      _cm.set(
          1,
          hash3(length != 0 ? expectedByte : (s.c4 >> 8) & 0xFF,
              (c1 << 3) | mode3, 2));
    }
    _cm.mix(m, y, bpos, c0, c1);
    _mapL.set(hash4(expectedByte, c0, s.c4 & 0xFFFFFF, mode5));
    _mapL.mix(m);
    _iCtx.add(y);
    _iCtx.select(mode5 << 3 | bpos);
    _map.set(_iCtx.value << 8 | mode5 << 3 | bpos);
    _map.mix(m);
    _mapsMixed = true;
    _length = length;
    _expected = expectedByte;
    _mode3 = mode3;
    _mode5 = mode5;
    _isDelta = isDelta;
  }

  @override
  void setMixerContexts(ZcmState s, Mixer m) {
    m.set(_mode5);
  }
}
