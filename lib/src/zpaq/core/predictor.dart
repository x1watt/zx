// Vendored from zpaq-flutter by tool/sync_zpaq.sh: do not edit here, change
// zpaq-flutter and sync again. Pure Dart port of libzpaq and zpaq 7.15 (Matt
// Mahoney, public domain) with the zpaqfranz attribute format (Franco
// Corbelli, MIT). Copyright (c) 2026 Max Brito, BSD 3-clause; see LICENSE
// for the license and the third party notices.

import 'dart:typed_data';

import 'io.dart';
import 'tables.dart';
import 'zpaql.dart';

part 'kernels.g.dart';

const int _m32 = 0xFFFFFFFF;

/// Shared model independent lookup tables.
class _Tables {
  static final Uint16List squasht = () {
    final t = Uint16List(4096);
    t.setRange(1376, 1376 + 1344, kSsquasht);
    for (var i = 2720; i < 4096; ++i) {
      t[i] = 32767;
    }
    return t;
  }();

  static final Int16List stretcht = () {
    final t = Int16List(32768);
    var k = 16384;
    for (var i = 0; i < 712; ++i) {
      for (var j = kStdt[i]; j > 0; --j) {
        t[k++] = i;
      }
    }
    for (var i = 0; i < 16384; ++i) {
      t[i] = -t[32767 - i];
    }
    return t;
  }();

  /// cminit for each state: initial probability of 1 * 2^23.
  static final Uint32List cminit = () {
    final t = Uint32List(256);
    for (var s = 0; s < 256; ++s) {
      t[s] = ((kSns[s * 4 + 3] * 2 + 1) << 22) ~/
          (kSns[s * 4 + 2] + kSns[s * 4 + 3] + 1);
    }
    return t;
  }();
}

final Uint32List _empty32 = Uint32List(0);
final Int32List _emptyI32 = Int32List(0);
final Uint8List _empty8 = Uint8List(0);
final Uint16List _empty16 = Uint16List(0);

/// Bit predictor driven by the COMP section of a ZPAQL header.
///
/// Component state lives in typed arrays indexed by component number (no
/// per-component objects with int fields), which keeps the hot loops free
/// of boxing.
class Predictor {
  final Zpaql z;
  int _c8 = 1;
  int _hmap4 = 1;
  int _n = 0;
  final Int32List _p = Int32List(256); // predictions
  final Uint32List _h = Uint32List(256); // contexts from z.h
  final Int32List _cpos = Int32List(256); // header offset of each component
  final Uint8List _type = Uint8List(256);

  // Scalar component state
  final Int64List _limit = Int64List(256); // max count for cm
  final Int64List _cxt = Int64List(256); // saved context
  final Int64List _ca = Int64List(256); // MATCH length
  final Int64List _cb = Int64List(256); // MATCH offset (mod buffer size)
  final Int64List _cc = Int64List(256); // bit / row / size
  final Int64List _cmMask = Int64List(256);
  final Int64List _htMask = Int64List(256);

  // Array component state
  final List<Uint32List> _cm = List.filled(256, _empty32);
  final List<Int32List> _cmi = List.filled(256, _emptyI32); // signed view
  final List<Uint8List> _ht = List.filled(256, _empty8);
  final List<Uint16List> _a16 = List.filled(256, _empty16);

  // Instance copies of the shared tables: static finals are lazily
  // initialized and checked on every access in the hot loops.
  final Uint16List _squasht = _Tables.squasht;
  final Int16List _stretcht = _Tables.stretcht;
  final Int32List _dt = kSdt;
  final Int32List _dt2k = kSdt2k;
  final Uint8List _sns = kSns;
  final Uint32List _cminit = _Tables.cminit;

  Predictor(this.z);

  bool get isModeled => z.header[6] != 0;

  @pragma('vm:prefer-inline')
  static int _clamp2k(int x) => x < -2048 ? -2048 : (x > 2047 ? 2047 : x);
  @pragma('vm:prefer-inline')
  static int _clamp512k(int x) =>
      x < -(1 << 19) ? -(1 << 19) : (x >= (1 << 19) ? (1 << 19) - 1 : x);

  void _setCm(int i, int n) {
    final cm = Uint32List(n);
    _cm[i] = cm;
    _cmi[i] = Int32List.view(cm.buffer);
    _cmMask[i] = n - 1;
  }

  void _setHt(int i, int n) {
    _ht[i] = Uint8List(n);
    _htMask[i] = n - 1;
  }

  static void _checkBits(int bits, int extra) {
    if (bits + extra > 31) {
      zpaqError('model component too large for this platform');
    }
  }

  /// Builds the model from z.header.
  void init() {
    z.inith();
    _c8 = 1;
    _hmap4 = 1;
    for (var i = 0; i < 256; ++i) {
      _h[i] = 0;
      _p[i] = 0;
      _limit[i] = _cxt[i] = _ca[i] = _cb[i] = _cc[i] = 0;
      _cmMask[i] = _htMask[i] = 0;
      _cm[i] = _empty32;
      _cmi[i] = _emptyI32;
      _ht[i] = _empty8;
      _a16[i] = _empty16;
    }
    final hd = z.header;
    final n = _n = hd[6];
    var cp = 7;
    for (var i = 0; i < n; ++i) {
      _cpos[i] = cp;
      final type = _type[i] = hd[cp];
      switch (type) {
        case compCons:
          _p[i] = (hd[cp + 1] - 128) * 4;
        case compCm:
          if (hd[cp + 1] > 32) zpaqError('max size for CM is 32');
          _checkBits(hd[cp + 1], 2);
          _setCm(i, 1 << hd[cp + 1]);
          _limit[i] = hd[cp + 2] * 4;
          fill32(_cm[i], 0x80000000);
        case compIcm:
          if (hd[cp + 1] > 26) zpaqError('max size for ICM is 26');
          _limit[i] = 1023;
          _setCm(i, 256);
          _setHt(i, 64 << hd[cp + 1]);
          for (var j = 0; j < 256; ++j) {
            _cm[i][j] = _cminit[j];
          }
        case compMatch:
          if (hd[cp + 1] > 32 || hd[cp + 2] > 32) {
            zpaqError('max size for MATCH is 32 32');
          }
          _checkBits(hd[cp + 1], 2);
          _checkBits(hd[cp + 2], 0);
          _setCm(i, 1 << hd[cp + 1]);
          _setHt(i, 1 << hd[cp + 2]);
          _ht[i][0] = 1;
        case compAvg:
          if (hd[cp + 1] >= i) zpaqError('AVG j >= i');
          if (hd[cp + 2] >= i) zpaqError('AVG k >= i');
        case compMix2:
          if (hd[cp + 1] > 32) zpaqError('max size for MIX2 is 32');
          if (hd[cp + 3] >= i) zpaqError('MIX2 k >= i');
          if (hd[cp + 2] >= i) zpaqError('MIX2 j >= i');
          _checkBits(hd[cp + 1], 1);
          final size = 1 << hd[cp + 1];
          _cc[i] = size;
          _a16[i] = Uint16List(size)..fillRange(0, size, 32768);
        case compMix:
          if (hd[cp + 1] > 32) zpaqError('max size for MIX is 32');
          if (hd[cp + 2] >= i) zpaqError('MIX j >= i');
          if (hd[cp + 3] < 1 || hd[cp + 3] > i - hd[cp + 2]) {
            zpaqError('MIX m not in 1..i-j');
          }
          final m = hd[cp + 3];
          _checkBits(hd[cp + 1], 2);
          final size = 1 << hd[cp + 1];
          _cc[i] = size;
          _setCm(i, m * size);
          fill32(_cm[i], 65536 ~/ m);
        case compIsse:
          if (hd[cp + 1] > 32) zpaqError('max size for ISSE is 32');
          if (hd[cp + 2] >= i) zpaqError('ISSE j >= i');
          _checkBits(hd[cp + 1], 6);
          _setHt(i, 64 << hd[cp + 1]);
          _setCm(i, 512);
          final wt = _cmi[i];
          for (var j = 0; j < 256; ++j) {
            wt[j * 2] = 1 << 15;
            wt[j * 2 + 1] = _clamp512k(_stretcht[_cminit[j] >> 8] * 1024);
          }
        case compSse:
          if (hd[cp + 1] > 32) zpaqError('max size for SSE is 32');
          if (hd[cp + 2] >= i) zpaqError('SSE j >= i');
          if (hd[cp + 3] > hd[cp + 4] * 4) zpaqError('SSE start > limit*4');
          _checkBits(hd[cp + 1], 7);
          _setCm(i, 32 << hd[cp + 1]);
          _limit[i] = hd[cp + 4] * 4;
          final cm = _cm[i];
          for (var j = 0; j < cm.length; ++j) {
            cm[j] = (_squasht[(j & 31) * 64 - 992 + 2048] << 17) | hd[cp + 3];
          }
        default:
          zpaqError('unknown component type');
      }
      cp += compsize[hd[cp]];
    }
    _kernel = kernelsEnabled ? _kernelFor(_layoutSignature(), this) : null;
  }

  /// Use the generated predictors for makeConfig's model layouts (see
  /// tool/gen_kernels.dart); false forces the generic code, for tests.
  static bool kernelsEnabled = true;

  _Kernel? _kernel;

  /// The model layout: component types and wiring, as gen_kernels names it.
  String _layoutSignature() {
    final hd = z.header;
    final parts = <String>[];
    for (var i = 0; i < _n; ++i) {
      final cp = _cpos[i];
      final t = hd[cp];
      switch (t) {
        case compIsse:
        case compSse:
          parts.add('$t:${hd[cp + 2]}');
        case compAvg:
          parts.add('$t:${hd[cp + 1]}:${hd[cp + 2]}');
        case compMix2:
          parts.add('$t:${hd[cp + 2]}:${hd[cp + 3]}');
        case compMix:
          parts.add('$t:${hd[cp + 2]}:${hd[cp + 3]}');
        default:
          parts.add('$t');
      }
    }
    return parts.join(',');
  }

  /// Predicts, then trains on bit [y]: returns the probability (0..32767)
  /// to code [y] with. One call per bit instead of two, and the generated
  /// predictors keep the model state in locals between the two halves.
  int encodeBit(int y) {
    final k = _kernel;
    if (k != null) return k.codeBit(y, null);
    final p = _predict();
    _update(y);
    return p;
  }

  /// Predicts, decodes a bit with [dec], trains on it, returns it.
  int decodeBit(BitDecoder dec) {
    final k = _kernel;
    if (k != null) return k.codeBit(0, dec);
    final y = dec.decodeBit(_predict() * 2 + 1);
    _update(y);
    return y;
  }

  /// Probability that the next bit is 1, scaled 0..32767.
  @pragma('vm:unsafe:no-bounds-checks')
  int _predict() {
    final hd = z.header;
    final p = _p;
    final h = _h;
    final st = _stretcht;
    final c8 = _c8, hmap4 = _hmap4;
    final cpos = _cpos;
    final type = _type;
    final cxtA = _cxt;
    final n = _n;
    for (var i = 0; i < n; ++i) {
      switch (type[i]) {
        case compCons:
          break;
        case compCm:
          final cxt = h[i] ^ hmap4;
          cxtA[i] = cxt;
          p[i] = st[_cm[i][cxt & _cmMask[i]] >> 17];
        case compIcm:
          final ht = _ht[i];
          if (c8 == 1 || (c8 & 0xf0) == 16) {
            _cc[i] = _find(ht, hd[cpos[i] + 1] + 2, (h[i] + 16 * c8) & _m32);
          }
          final cxt = ht[_cc[i] + (hmap4 & 15)];
          cxtA[i] = cxt;
          p[i] = st[_cm[i][cxt] >> 8];
        case compMatch:
          final len = _ca[i];
          if (len == 0) {
            p[i] = 0;
          } else {
            final ht = _ht[i];
            final bit =
                (ht[(_limit[i] - _cb[i]) & _htMask[i]] >> (7 - cxtA[i])) & 1;
            _cc[i] = bit;
            p[i] = st[(_dt2k[len] * (bit * -2 + 1)) & 32767];
          }
        case compAvg:
          final cp = cpos[i];
          p[i] = (p[hd[cp + 1]] * hd[cp + 3] +
                  p[hd[cp + 2]] * (256 - hd[cp + 3])) >>
              8;
        case compMix2:
          final cp = cpos[i];
          final cxt = (h[i] + (c8 & hd[cp + 5])) & (_cc[i] - 1);
          cxtA[i] = cxt;
          final w = _a16[i][cxt];
          p[i] = (w * p[hd[cp + 2]] + (65536 - w) * p[hd[cp + 3]]) >> 16;
        case compMix:
          final cp = cpos[i];
          final m = hd[cp + 3];
          final base = (((h[i] + (c8 & hd[cp + 5])) & _m32) & (_cc[i] - 1)) * m;
          cxtA[i] = base;
          final wt = _cmi[i];
          final j0 = hd[cp + 2];
          var s = 0;
          for (var j = 0; j < m; ++j) {
            s += (wt[base + j] >> 8) * p[j0 + j];
          }
          p[i] = _clamp2k(s >> 8);
        case compIsse:
          final cp = cpos[i];
          final ht = _ht[i];
          if (c8 == 1 || (c8 & 0xf0) == 16) {
            _cc[i] = _find(ht, hd[cp + 1] + 2, (h[i] + 16 * c8) & _m32);
          }
          final cxt = ht[_cc[i] + (hmap4 & 15)];
          cxtA[i] = cxt;
          final wt = _cmi[i];
          p[i] = _clamp2k(
              (wt[cxt * 2] * p[hd[cp + 2]] + wt[cxt * 2 + 1] * 64) >> 16);
        case compSse:
          final cp = cpos[i];
          var cxt = ((h[i] + c8) * 32) & _m32;
          var pq = p[hd[cp + 2]] + 992;
          if (pq < 0) pq = 0;
          if (pq > 1983) pq = 1983;
          final wt = pq & 63;
          pq >>= 6;
          cxt += pq;
          final cm = _cm[i];
          final mk = _cmMask[i];
          p[i] = st[((cm[cxt & mk] >> 10) * (64 - wt) +
                  (cm[(cxt + 1) & mk] >> 10) * wt) >>
              13];
          cxtA[i] = cxt + (wt >> 5);
        default:
          zpaqError('component predict not implemented');
      }
    }
    return _squasht[p[n - 1] + 2048];
  }

  /// Trains the model on bit [y].
  @pragma('vm:unsafe:no-bounds-checks')
  void _update(int y) {
    final hd = z.header;
    final p = _p;
    final hmap4 = _hmap4;
    final cpos = _cpos;
    final type = _type;
    final cxtA = _cxt;
    final sq = _squasht;
    final n = _n;
    for (var i = 0; i < n; ++i) {
      switch (type[i]) {
        case compCons:
          break;
        case compCm:
        case compSse:
          final cm = _cm[i];
          final idx = cxtA[i] & _cmMask[i];
          final pn = cm[idx];
          final count = pn & 0x3ff;
          final error = y * 32767 - (pn >> 17);
          cm[idx] =
              pn + ((error * _dt[count]) & -1024) + (count < _limit[i] ? 1 : 0);
        case compIcm:
          final ht = _ht[i];
          final hi = _cc[i] + (hmap4 & 15);
          ht[hi] = _sns[ht[hi] * 4 + y];
          final cm = _cm[i];
          final idx = cxtA[i];
          final pn = cm[idx];
          cm[idx] = pn + ((y * 32767 - (pn >> 8)) >> 2);
        case compMatch:
          if (_cc[i] != y) _ca[i] = 0;
          final ht = _ht[i];
          final mk = _htMask[i];
          var limit = _limit[i];
          final lim = limit & mk;
          ht[lim] = ht[lim] * 2 + y;
          if (++cxtA[i] == 8) {
            cxtA[i] = 0;
            ++limit;
            limit &= (1 << hd[cpos[i] + 2]) - 1;
            _limit[i] = limit;
            final cm = _cm[i];
            final hi = _h[i] & _cmMask[i];
            var a = _ca[i];
            if (a == 0) {
              final b = (limit - cm[hi]) & mk;
              _cb[i] = b;
              if (b != 0) {
                while (a < 255 &&
                    ht[(limit - a - 1) & mk] == ht[(limit - a - b - 1) & mk]) {
                  ++a;
                }
              }
            } else if (a < 255) {
              ++a;
            }
            _ca[i] = a;
            cm[hi] = limit;
          }
        case compAvg:
          break;
        case compMix2:
          final cp = cpos[i];
          final err = ((y * 32767 - sq[p[i] + 2048]) * hd[cp + 4]) >> 5;
          final a16 = _a16[i];
          final cxt = cxtA[i];
          var w = a16[cxt];
          w += (err * (p[hd[cp + 2]] - p[hd[cp + 3]]) + (1 << 12)) >> 13;
          if (w < 0) w = 0;
          if (w > 65535) w = 65535;
          a16[cxt] = w;
        case compMix:
          final cp = cpos[i];
          final m = hd[cp + 3];
          final err = ((y * 32767 - sq[p[i] + 2048]) * hd[cp + 4]) >> 4;
          final wt = _cmi[i];
          final base = cxtA[i];
          final j0 = hd[cp + 2];
          for (var j = 0; j < m; ++j) {
            wt[base + j] = _clamp512k(
                wt[base + j] + ((err * p[j0 + j] + (1 << 12)) >> 13));
          }
        case compIsse:
          final cp = cpos[i];
          final err = y * 32767 - sq[p[i] + 2048];
          final wt = _cmi[i];
          final cxt = cxtA[i];
          final k = cxt * 2;
          wt[k] = _clamp512k(wt[k] + ((err * p[hd[cp + 2]] + (1 << 12)) >> 13));
          wt[k + 1] = _clamp512k(wt[k + 1] + ((err + 16) >> 5));
          _ht[i][_cc[i] + (hmap4 & 15)] = _sns[cxt * 4 + y];
        default:
          zpaqError('component update not implemented');
      }
    }

    // Save bit y in c8, hmap4
    _c8 += _c8 + y;
    if (_c8 >= 256) {
      z.run(_c8 - 256);
      _hmap4 = 1;
      _c8 = 1;
      final zh = z.hArray, zm = z.hMask;
      for (var i = 0; i < n; ++i) {
        _h[i] = zh[i & zm];
      }
    } else if (_c8 >= 16 && _c8 < 32) {
      _hmap4 = ((_hmap4 & 0xf) << 5) | (y << 4) | 1;
    } else {
      _hmap4 = (_hmap4 & 0x1f0) | (((_hmap4 & 0xf) * 2 + y) & 0xf);
    }
  }

  /// Finds or creates the 16 byte row for context [cxt] in hash table [ht].
  @pragma('vm:prefer-inline')
  @pragma('vm:unsafe:no-bounds-checks')
  static int _find(Uint8List ht, int sizebits, int cxt) {
    final chk = (cxt >> sizebits) & 255;
    final h0 = (cxt * 16) & (ht.length - 16);
    if (ht[h0] == chk) return h0;
    final h1 = h0 ^ 16;
    if (ht[h1] == chk) return h1;
    final h2 = h0 ^ 32;
    if (ht[h2] == chk) return h2;
    int r;
    if (ht[h0 + 1] <= ht[h1 + 1] && ht[h0 + 1] <= ht[h2 + 1]) {
      r = h0;
    } else if (ht[h1 + 1] < ht[h2 + 1]) {
      r = h1;
    } else {
      r = h2;
    }
    // 16 plain stores: fillRange checks its range on every call
    ht[r] = chk;
    for (var k = 1; k < 16; ++k) {
      ht[r + k] = 0;
    }
    return r;
  }
}

/// A predictor specialized for one model layout (generated).
abstract class _Kernel {
  final Predictor pr;
  int _c8 = 1, _hmap4 = 1;
  final Int16List _st;
  final Uint16List _sq;
  final Int32List _dt, _dt2k;
  final Uint8List _sns;

  _Kernel(this.pr)
      : _st = pr._stretcht,
        _sq = pr._squasht,
        _dt = pr._dt,
        _dt2k = pr._dt2k,
        _sns = pr._sns;

  /// Predicts, then trains on the bit: with no [dec] the bit is [y] and the
  /// probability (0..32767) to code it with is returned; with [dec] the bit
  /// is decoded with it and returned.
  int codeBit(int y, BitDecoder? dec);
}

/// The arithmetic decoder as the predictors see it.
abstract interface class BitDecoder {
  /// Decodes one bit that is 1 with probability [p] / 65536.
  int decodeBit(int p);
}
