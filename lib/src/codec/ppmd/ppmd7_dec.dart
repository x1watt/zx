// Port of C/Ppmd7Dec.c: Ppmd7z (PPMdH with the 7z range coder) decoder.

import 'ppmd7.dart';

const int _kTopValue = 1 << 24;

// Ppmd7z_RangeDec_Init
bool ppmd7zRangeDecInit(Ppmd7 p) {
  final inp = p.rcIn!;
  p.rcCode = 0;
  p.rcRange = 0xFFFFFFFF;
  if (inp.readByte() != 0) return false;
  for (var i = 0; i < 4; i++) {
    p.rcCode = ((p.rcCode << 8) | inp.readByte()) & 0xFFFFFFFF;
  }
  return p.rcCode < 0xFFFFFFFF;
}

// Ppmd7z_RangeDec_IsFinishedOK
bool ppmd7zRangeDecIsFinishedOK(Ppmd7 p) => p.rcCode == 0;

// RC_NORM_REMOTE (RC_NORM): two conditional normalization steps.
@pragma('vm:prefer-inline')
void _rcNorm(Ppmd7 p) {
  if (p.rcRange < _kTopValue) {
    final inp = p.rcIn!;
    p.rcCode = ((p.rcCode << 8) | inp.readByte()) & 0xFFFFFFFF;
    p.rcRange = (p.rcRange << 8) & 0xFFFFFFFF;
    if (p.rcRange < _kTopValue) {
      p.rcCode = ((p.rcCode << 8) | inp.readByte()) & 0xFFFFFFFF;
      p.rcRange = (p.rcRange << 8) & 0xFFFFFFFF;
    }
  }
}

// Ppmd7z_RD_Decode (RC_NORM_LOCAL is empty)
@pragma('vm:prefer-inline')
void _rcDecode(Ppmd7 p, int start, int size) {
  p.rcCode = (p.rcCode - start * p.rcRange) & 0xFFFFFFFF;
  p.rcRange = (p.rcRange * size) & 0xFFFFFFFF;
}

// RC_GetThreshold
@pragma('vm:prefer-inline')
int _rcGetThreshold(Ppmd7 p, int total) =>
    p.rcCode ~/ (p.rcRange = p.rcRange ~/ total);

/// Ppmd7z_DecodeSymbol. Returns the byte, [ppmd7SymEnd] or [ppmd7SymError].
int ppmd7zDecodeSymbol(Ppmd7 p) {
  final m8 = p.mem;
  final m16 = p.mem16;
  final m32 = p.mem32;
  final charMask = p.charMask;
  var mc = p.minContext;

  if (m16[mc >> 1] != 1) {
    var s = m32[(mc >> 2) + 1];
    final summFreq = m16[(mc >> 1) + 1];

    var count = _rcGetThreshold(p, summFreq);
    var hiCnt = count;

    // (Int32)(count -= s.Freq) < 0
    count = (count - m8[s + 1]) & 0xFFFFFFFF;
    if (count >= 0x80000000) {
      _rcDecode(p, 0, m8[s + 1]);
      _rcNorm(p);
      p.foundState = s;
      final sym = m8[s];
      p.update1_0();
      return sym;
    }

    p.prevSuccess = 0;
    var i = m16[mc >> 1] - 1;

    do {
      s += 6;
      count = (count - m8[s + 1]) & 0xFFFFFFFF;
      if (count >= 0x80000000) {
        _rcDecode(p, ((hiCnt - count) & 0xFFFFFFFF) - m8[s + 1], m8[s + 1]);
        _rcNorm(p);
        p.foundState = s;
        final sym = m8[s];
        p.update1();
        return sym;
      }
    } while (--i != 0);

    if (hiCnt >= summFreq) return ppmd7SymError;

    hiCnt -= count;
    _rcDecode(p, hiCnt, summFreq - hiCnt);

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
    final s = mc + 2;
    final prob = p.getBinSumm();
    var pr = p.binSumm[prob];
    final size0 = (p.rcRange >> 14) * pr;
    pr = pr - ((pr + (1 << (ppmdPeriodBits - 2))) >> ppmdPeriodBits);

    if (p.rcCode < size0) {
      p.binSumm[prob] = pr + (1 << ppmdIntBits);
      p.rcRange = size0;
      // RC_NORM_1
      if (size0 < _kTopValue) {
        p.rcCode = ((p.rcCode << 8) | p.rcIn!.readByte()) & 0xFFFFFFFF;
        p.rcRange = (size0 << 8) & 0xFFFFFFFF;
      }
      final sym = m8[s];
      p.updateBin(s);
      return sym;
    }

    p.binSumm[prob] = pr;
    p.initEsc = p.expEscape[pr >> 10];

    p.rcCode -= size0;
    p.rcRange -= size0;

    p.setAllBitsInCharMask();
    charMask[m8[s]] = 0;
    p.prevSuccess = 0;
  }

  for (;;) {
    _rcNorm(p);
    mc = p.minContext;
    final numMasked = m16[mc >> 1];

    do {
      p.orderFall++;
      final suffix = m32[(mc >> 2) + 2];
      if (suffix == 0) return ppmd7SymEnd;
      mc = suffix;
    } while (m16[mc >> 1] == numMasked);

    var s = m32[(mc >> 2) + 1];
    int hiCnt;
    {
      var num = m16[mc >> 1];
      var num2 = num >> 1;
      num &= 1;
      hiCnt = num != 0 ? (m8[s + 1] & charMask[m8[s]]) : 0;
      s += num * 6;
      p.minContext = mc;

      do {
        final sym0 = m8[s];
        final sym1 = m8[s + 6];
        s += 12;
        hiCnt += (m8[s - 12 + 1] & charMask[sym0]);
        hiCnt += (m8[s - 6 + 1] & charMask[sym1]);
      } while (--num2 != 0);
    }

    final see = p.makeEscFreq(numMasked);
    final freqSum = p.escFreqOut + hiCnt;

    var count = _rcGetThreshold(p, freqSum);

    if (count < hiCnt) {
      s = m32[(p.minContext >> 2) + 1];
      hiCnt = count;
      for (;;) {
        count -= m8[s + 1] & charMask[m8[s]];
        s += 6;
        if (count < 0) break;
      }
      s -= 6;
      _rcDecode(p, (hiCnt - count) - m8[s + 1], m8[s + 1]);
      _rcNorm(p);

      p.seeUpdate(see);
      p.foundState = s;
      final sym = m8[s];
      p.update2();
      return sym;
    }

    if (count >= freqSum) return ppmd7SymError;

    _rcDecode(p, hiCnt, freqSum - hiCnt);

    // We increase (see.Summ) for sum of Freqs of all non_Masked symbols.
    p.seeSumm[see] = p.seeSumm[see] + freqSum;

    s = m32[(p.minContext >> 2) + 1];
    final s2 = s + m16[(p.minContext >> 1)] * 6;
    do {
      charMask[m8[s]] = 0;
      s += 6;
    } while (s != s2);
  }
}
