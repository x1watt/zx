// Port of C/Ppmd7Enc.c: Ppmd7z (PPMdH with the 7z range coder) encoder.

import 'dart:typed_data';

import 'ppmd7.dart';

const int _kTopValue = 1 << 24;

// Ppmd7z_Init_RangeEnc
void ppmd7zInitRangeEnc(Ppmd7 p) {
  p.rcLow = 0;
  p.rcRange = 0xFFFFFFFF;
  p.rcCache = 0;
  p.rcCacheSize = 1;
}

// Ppmd7z_RangeEnc_ShiftLow
void _shiftLow(Ppmd7 p) {
  final low = p.rcLow;
  if ((low & 0xFFFFFFFF) < 0xFF000000 || (low >> 32) != 0) {
    final out = p.rcOut!;
    var temp = p.rcCache;
    final carry = low >> 32;
    do {
      out.writeByte((temp + carry) & 0xFF);
      temp = 0xFF;
    } while (--p.rcCacheSize != 0);
    p.rcCache = (low >> 24) & 0xFF;
  }
  p.rcCacheSize++;
  p.rcLow = (low << 8) & 0xFFFFFFFF;
}

// RC_NORM_REMOTE (RC_NORM): two conditional normalization steps.
@pragma('vm:prefer-inline')
void _rcNorm(Ppmd7 p) {
  if (p.rcRange < _kTopValue) {
    p.rcRange = (p.rcRange << 8) & 0xFFFFFFFF;
    _shiftLow(p);
    if (p.rcRange < _kTopValue) {
      p.rcRange = (p.rcRange << 8) & 0xFFFFFFFF;
      _shiftLow(p);
    }
  }
}

// Ppmd7z_RangeEnc_Encode (RC_NORM_LOCAL is empty)
@pragma('vm:prefer-inline')
void _rcEncode(Ppmd7 p, int start, int size) {
  p.rcLow += start * p.rcRange;
  p.rcRange *= size;
}

// Ppmd7z_Flush_RangeEnc
void ppmd7zFlushRangeEnc(Ppmd7 p) {
  for (var i = 0; i < 5; i++) {
    _shiftLow(p);
  }
}

// Ppmd7z_EncodeSymbol
void ppmd7zEncodeSymbol(Ppmd7 p, int symbol) {
  final m8 = p.mem;
  final m16 = p.mem16;
  final m32 = p.mem32;
  final charMask = p.charMask;
  var mc = p.minContext;

  if (m16[mc >> 1] != 1) {
    var s = m32[(mc >> 2) + 1];
    final summFreq = m16[(mc >> 1) + 1];
    p.rcRange = p.rcRange ~/ summFreq;

    if (m8[s] == symbol) {
      _rcEncode(p, 0, m8[s + 1]);
      _rcNorm(p);
      p.foundState = s;
      p.update1_0();
      return;
    }
    p.prevSuccess = 0;
    var sum = m8[s + 1];
    var i = m16[mc >> 1] - 1;
    do {
      s += 6;
      if (m8[s] == symbol) {
        _rcEncode(p, sum, m8[s + 1]);
        _rcNorm(p);
        p.foundState = s;
        p.update1();
        return;
      }
      sum += m8[s + 1];
    } while (--i != 0);

    _rcEncode(p, sum, summFreq - sum);

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
    final bound = (p.rcRange >> 14) * pr;
    pr = pr - ((pr + (1 << (ppmdPeriodBits - 2))) >> ppmdPeriodBits);
    if (m8[s] == symbol) {
      p.binSumm[prob] = pr + (1 << ppmdIntBits);
      p.rcRange = bound;
      // RC_NORM_1
      if (bound < _kTopValue) {
        p.rcRange = (bound << 8) & 0xFFFFFFFF;
        _shiftLow(p);
      }
      p.updateBin(s);
      return;
    }

    p.binSumm[prob] = pr;
    p.initEsc = p.expEscape[pr >> 10];
    p.rcLow += bound;
    p.rcRange -= bound;

    p.setAllBitsInCharMask();
    charMask[m8[s]] = 0;
    p.prevSuccess = 0;
  }

  for (;;) {
    int see;
    int escFreq;
    int i;

    _rcNorm(p);

    mc = p.minContext;
    final numMasked = m16[mc >> 1];

    do {
      p.orderFall++;
      final suffix = m32[(mc >> 2) + 2];
      if (suffix == 0) return; // EndMarker (symbol = -1)
      mc = suffix;
      i = m16[mc >> 1];
    } while (i == numMasked);

    p.minContext = mc;

    // see = Ppmd7_MakeEscFreq(p, numMasked, &escFreq);
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
        final low = sum;
        final freq = m8[s + 1];

        p.seeUpdate(see);
        p.foundState = s;
        sum += escFreq;

        var num2 = i >> 1;
        i &= 1;
        if (i != 0) sum += freq;
        if (num2 != 0) {
          s += i * 6;
          do {
            final sym0 = m8[s];
            final sym1 = m8[s + 6];
            s += 12;
            sum += (m8[s - 12 + 1] & charMask[sym0]);
            sum += (m8[s - 6 + 1] & charMask[sym1]);
          } while (--num2 != 0);
        }

        p.rcRange = p.rcRange ~/ sum;
        _rcEncode(p, low, freq);
        _rcNorm(p);
        p.update2();
        return;
      }
      sum += (m8[s + 1] & charMask[cur]);
      s += 6;
    } while (--i != 0);

    {
      final total = sum + escFreq;
      p.seeSumm[see] = p.seeSumm[see] + total;
      p.rcRange = p.rcRange ~/ total;
      _rcEncode(p, sum, escFreq);
    }

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

// Ppmd7z_EncodeSymbols
void ppmd7zEncodeSymbols(Ppmd7 p, Uint8List buf, int start, int lim) {
  for (var i = start; i < lim; i++) {
    ppmd7zEncodeSymbol(p, buf[i]);
  }
}
