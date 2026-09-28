// zcm: byte predictors turned into bit predictions (level 9).
//
// cmix (Byron Knoll) uses byte models: a model gives a probability for
// each of the 256 next bytes, and the bit predictions follow from the sums
// over the bytes that agree with the bits coded so far (ByteModel in
// cmix). Two such models are here: PPMd var.H (Dmitry Shkarin; the
// port of the LZMA SDK's Ppmd7.c in lib/src/codec/ppmd, used as a
// predictor the way cmix's models/ppmd.cpp uses PPMd var.J) and the LSTM
// of zcm_lstm.dart.
//
// The PPMd distribution is computed with doubles (+, -, *, / only, fixed
// order), the PPMd model itself stays integer; both are deterministic.

import 'dart:typed_data';

import '../ppmd/ppmd7.dart';
import 'zcm_components.dart';
import 'zcm_lstm.dart';
import 'zcm_models.dart';
import 'zcm_tables.dart';

/// Turns a byte distribution into bit predictions (cmix ByteModel).
final class _BitsFromBytes {
  final Float64List cum = Float64List(257);
  int _lo = 0, _hi = 256;

  /// Sets the distribution of the next byte ([p] need not be normalised).
  void setBytes(Float64List p) {
    var s = 0.0;
    cum[0] = 0.0;
    for (var i = 0; i < 256; i++) {
      s += p[i];
      cum[i + 1] = s;
    }
    _lo = 0;
    _hi = 256;
  }

  /// 12 bit probability that the next bit is 1, given the bits so far
  /// (the byte range narrows by one bit per call to [bit]).
  int p() {
    final mid = (_lo + _hi) >> 1;
    final all = cum[_hi] - cum[_lo];
    if (!(all > 0.0)) return 2048;
    final one = cum[_hi] - cum[mid];
    var q = (one / all * 4096.0).floor();
    if (q < 1) q = 1;
    if (q > 4095) q = 4095;
    return q;
  }

  void bit(int y) {
    final mid = (_lo + _hi) >> 1;
    if (y != 0) {
      _lo = mid;
    } else {
      _hi = mid;
    }
  }
}

/// Common part of the byte models: bit inputs and an APM-like refinement.
abstract class _ByteModelBase implements ZcmModel {
  final _BitsFromBytes _bits = _BitsFromBytes();
  final StateMap _sm = StateMap(4096 * 8);
  final Int16List _str = kStretch;
  bool _started = false;

  /// The quick gain check (PPMd at level 9), null for none.
  ZcmGainGate? gate;

  @override
  int get inputs => 3;

  /// Learns [byte] (the byte just coded) and sets the next distribution.
  void byteUpdate(int byte);

  /// The distribution of the next byte.
  Float64List get distribution;

  @override
  void mix(ZcmState s, Mixer m) {
    if (s.bpos == 0) {
      if (_started) byteUpdate(s.c4 & 255);
      _started = true;
      _bits.setBytes(distribution);
    } else {
      _bits.bit(s.y);
    }
    final p = _bits.p();
    final st = _str[p];
    final p2 = _sm.p(s.y, (p >> 4) << 3 | s.bpos);
    final tx = m.tx;
    var k = m.nx;
    final g = gate;
    if (g != null) {
      g.update(s.y);
      g.record(p);
      if (!g.open) {
        tx[k] = 0;
        tx[k + 1] = 0;
        tx[k + 2] = 0;
        m.nx = k + 3;
        return;
      }
    }
    tx[k] = st;
    tx[k + 1] = (p - 2048) >> 2;
    tx[k + 2] = _str[p2];
    m.nx = k + 3;
  }
}

/// PPMd var.H as a byte predictor.
final class PpmdByteModel extends _ByteModelBase {
  final Ppmd7 _p = Ppmd7();
  final Float64List _probs = Float64List(256);
  final Uint8List _mask = Uint8List(256);

  PpmdByteModel(int order, int memBytes) {
    var mem = memBytes;
    if (mem < ppmd7MinMemSize) mem = ppmd7MinMemSize;
    if (mem > (1 << 31)) mem = 1 << 31;
    _p.alloc(mem);
    _p.init(order < 2 ? 2 : (order > 64 ? 64 : order));
    _computeDistribution();
  }

  @override
  Float64List get distribution => _probs;

  @override
  void byteUpdate(int byte) {
    ppmdUpdateSymbol(_p, byte);
    _computeDistribution();
  }

  // The probability of every symbol in the current context chain, with
  // the escapes and exclusions of PPMd (read only: nothing of the model
  // changes here).
  void _computeDistribution() {
    final p = _p;
    final m8 = p.mem;
    final m16 = p.mem16;
    final m32 = p.mem32;
    final probs = _probs;
    final mask = _mask;
    for (var i = 0; i < 256; i++) {
      probs[i] = 0.0;
      mask[i] = 0;
    }
    var mass = 1.0;
    var mc = p.minContext;
    var numMasked = 0;
    int hiBits;
    final ns = m16[mc >> 1];
    if (ns != 1) {
      final summ = m16[(mc >> 1) + 1];
      var s = m32[(mc >> 2) + 1];
      var sum = 0;
      for (var i = 0; i < ns; i++, s += 6) {
        final f = m8[s + 1];
        sum += f;
        probs[m8[s]] += mass * f / summ;
        mask[m8[s]] = 1;
      }
      final esc = summ - sum;
      mass = mass * (esc > 0 ? esc : 1) / summ;
      hiBits = ppmd7HiBitsFlag3(m8[p.foundState]);
      numMasked = ns;
    } else {
      // Binary context: the probability of its only symbol.
      final suffix = m32[(mc >> 2) + 2];
      hiBits = ((m8[p.foundState] + 0xC0) >> (8 - 3)) & (1 << 3);
      final idx = (m8[mc + 3] - 1) * 64 +
          p.prevSuccess +
          ((p.runLength >> 26) & 0x20) +
          p.ns2BSIndx[m16[suffix >> 1] - 1] +
          (((m8[mc + 2] + 0xC0) >> (8 - 4)) & (1 << 4)) +
          hiBits;
      final pr = p.binSumm[idx] / ppmdBinScale;
      probs[m8[mc + 2]] += mass * pr;
      mask[m8[mc + 2]] = 1;
      mass = mass * (1.0 - pr);
      numMasked = 1;
    }
    // Escape to the shorter contexts.
    while (mass > 1e-12) {
      final suffix = m32[(mc >> 2) + 2];
      if (suffix == 0) break;
      mc = suffix;
      final n = m16[mc >> 1];
      if (n == numMasked) continue;
      int esc;
      if (n != 256) {
        final nonMasked = n - numMasked;
        final suf2 = m32[(mc >> 2) + 2];
        final see = p.ns2Indx[nonMasked - 1] * 16 +
            hiBits +
            (nonMasked < ((m16[suf2 >> 1] - n) & 0xFFFFFFFF) ? 1 : 0) +
            2 * (m16[(mc >> 1) + 1] < 11 * n ? 1 : 0) +
            4 * (numMasked > nonMasked ? 1 : 0);
        final r = p.seeSumm[see] >> p.seeShift[see];
        esc = r == 0 ? 1 : r;
      } else {
        esc = 1;
      }
      var s = m32[(mc >> 2) + 1];
      var sum = 0;
      for (var i = 0; i < n; i++, s += 6) {
        if (mask[m8[s]] == 0) sum += m8[s + 1];
      }
      final total = sum + esc;
      s = m32[(mc >> 2) + 1];
      for (var i = 0; i < n; i++, s += 6) {
        final sym = m8[s];
        if (mask[sym] == 0) {
          probs[sym] += mass * m8[s + 1] / total;
          mask[sym] = 1;
        }
      }
      mass = mass * esc / total;
      numMasked = n;
    }
    // Whatever is left goes to the symbols never seen.
    var unseen = 0;
    for (var i = 0; i < 256; i++) {
      if (mask[i] == 0) unseen++;
    }
    if (unseen > 0) {
      final each = mass / unseen;
      for (var i = 0; i < 256; i++) {
        if (mask[i] == 0) probs[i] = each;
      }
    }
    // A floor so that no byte is impossible.
    for (var i = 0; i < 256; i++) {
      probs[i] += 1e-7;
    }
  }
}

/// The LSTM as a byte predictor.
final class LstmByteModel extends _ByteModelBase {
  final ZcmLstm lstm;
  final Float64List _probs = Float64List(256)..fillRange(0, 256, 1 / 256);

  LstmByteModel(int cells, int layers, int horizon)
      : lstm = ZcmLstm(cells: cells, layers: layers, horizon: horizon);

  @override
  Float64List get distribution => _probs;

  @override
  void byteUpdate(int byte) {
    lstm.perceive(byte);
    final o = lstm.probabilities;
    for (var i = 0; i < 256; i++) {
      _probs[i] = o[i] + 1e-7;
    }
  }
}

/// Updates the PPMd model with [symbol] (Ppmd7z_EncodeSymbol without the
/// range coder: the same model changes, in the same order).
void ppmdUpdateSymbol(Ppmd7 p, int symbol) {
  final m8 = p.mem;
  final m16 = p.mem16;
  final m32 = p.mem32;
  final charMask = p.charMask;
  var mc = p.minContext;
  if (m16[mc >> 1] != 1) {
    var s = m32[(mc >> 2) + 1];
    if (m8[s] == symbol) {
      p.foundState = s;
      p.update1_0();
      return;
    }
    p.prevSuccess = 0;
    var i = m16[mc >> 1] - 1;
    do {
      s += 6;
      if (m8[s] == symbol) {
        p.foundState = s;
        p.update1();
        return;
      }
    } while (--i != 0);
    p.hiBitsFlag = ppmd7HiBitsFlag3(m8[p.foundState]);
    p.setAllBitsInCharMask();
    {
      var s2 = m32[(mc >> 2) + 1];
      charMask[m8[s]] = 0;
      do {
        final sym0 = m8[s2];
        final sym1 = m8[s2 + 6];
        s2 += 12;
        charMask[sym0] = 0;
        charMask[sym1] = 0;
      } while (s2 < s);
    }
  } else {
    final prob = p.getBinSumm();
    final s = mc + 2;
    var pr = p.binSumm[prob];
    pr = pr - ((pr + (1 << (ppmdPeriodBits - 2))) >> ppmdPeriodBits);
    if (m8[s] == symbol) {
      p.binSumm[prob] = pr + (1 << ppmdIntBits);
      p.updateBin(s);
      return;
    }
    p.binSumm[prob] = pr;
    p.initEsc = p.expEscape[pr >> 10];
    p.setAllBitsInCharMask();
    charMask[m8[s]] = 0;
    p.prevSuccess = 0;
  }
  for (;;) {
    int see;
    int escFreq;
    int i;
    mc = p.minContext;
    final numMasked = m16[mc >> 1];
    do {
      p.orderFall++;
      final suffix = m32[(mc >> 2) + 2];
      if (suffix == 0) {
        // Not reachable for bytes (the root context has all 256), but a
        // model restart keeps the state valid if it ever happens.
        p.init(p.maxOrder);
        return;
      }
      mc = suffix;
      i = m16[mc >> 1];
    } while (i == numMasked);
    p.minContext = mc;
    if (i != 256) {
      final nonMasked = i - numMasked;
      final suffix = m32[(mc >> 2) + 2];
      see = p.ns2Indx[nonMasked - 1] * 16 +
          p.hiBitsFlag +
          (nonMasked < ((m16[suffix >> 1] - i) & 0xFFFFFFFF) ? 1 : 0) +
          2 * (m16[(mc >> 1) + 1] < 11 * i ? 1 : 0) +
          4 * (numMasked > nonMasked ? 1 : 0);
      final summ = p.seeSumm[see];
      final r = summ >> p.seeShift[see];
      p.seeSumm[see] = summ - r;
      escFreq = r + (r == 0 ? 1 : 0);
    } else {
      see = ppmdDummySee;
      escFreq = 1;
    }
    var s = m32[(mc >> 2) + 1];
    var sum = 0;
    do {
      final cur = m8[s];
      if (cur == symbol) {
        p.seeUpdate(see);
        p.foundState = s;
        p.update2();
        return;
      }
      sum += (m8[s + 1] & charMask[cur]);
      s += 6;
    } while (--i != 0);
    // Ppmd7z_EncodeSymbol adds the coded total back to the See.
    p.seeSumm[see] = p.seeSumm[see] + sum + escFreq;
    {
      var s2 = m32[(p.minContext >> 2) + 1];
      s -= 6;
      charMask[m8[s]] = 0;
      do {
        final sym0 = m8[s2];
        final sym1 = m8[s2 + 6];
        s2 += 12;
        charMask[sym0] = 0;
        charMask[sym1] = 0;
      } while (s2 < s);
    }
  }
}
