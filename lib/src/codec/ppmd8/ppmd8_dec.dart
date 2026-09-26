// Port of C/Ppmd8Dec.c: the Ppmd8 (PPMdI) decoder with its own range
// decoder (the carryless range coder of Dmitry Subbotin).

import 'ppmd8.dart';

const int _kTop = 1 << 24;
const int _kBot = 1 << 15;

// Ppmd8_Init_RangeDec
bool ppmd8InitRangeDec(Ppmd8 p) {
  final inp = p.rcIn!;
  var code = 0;
  p.rcRange = 0xFFFFFFFF;
  p.rcLow = 0;
  for (var i = 0; i < 4; i++) {
    code = ((code << 8) | inp.readByte()) & 0xFFFFFFFF;
  }
  p.rcCode = code;
  return code < 0xFFFFFFFF;
}

// Ppmd8_RangeDec_IsFinishedOK
bool ppmd8RangeDecIsFinishedOK(Ppmd8 p) => p.rcCode == 0;

// RC_NORM (RC_NORM_REMOTE)
@pragma('vm:prefer-inline')
void _rcNorm(Ppmd8 p) {
  var low = p.rcLow;
  var range = p.rcRange;
  if ((low ^ ((low + range) & 0xFFFFFFFF)) < _kTop || range < _kBot) {
    var code = p.rcCode;
    final inp = p.rcIn!;
    for (;;) {
      if ((low ^ ((low + range) & 0xFFFFFFFF)) >= _kTop) {
        if (range >= _kBot) break;
        range = (-low) & (_kBot - 1);
      }
      code = ((code << 8) | inp.readByte()) & 0xFFFFFFFF;
      range = (range << 8) & 0xFFFFFFFF;
      low = (low << 8) & 0xFFFFFFFF;
    }
    p.rcCode = code;
    p.rcRange = range;
    p.rcLow = low;
  }
}

// Ppmd8_RD_Decode (RC_NORM_LOCAL is empty)
@pragma('vm:prefer-inline')
void _rcDecode(Ppmd8 p, int start, int size) {
  start = (start * p.rcRange) & 0xFFFFFFFF;
  p.rcLow = (p.rcLow + start) & 0xFFFFFFFF;
  p.rcCode = (p.rcCode - start) & 0xFFFFFFFF;
  p.rcRange = (p.rcRange * size) & 0xFFFFFFFF;
}

// RC_GetThreshold
@pragma('vm:prefer-inline')
int _rcGetThreshold(Ppmd8 p, int total) =>
    p.rcCode ~/ (p.rcRange = p.rcRange ~/ total);

/// Ppmd8_DecodeSymbol. Returns the byte, [ppmd8SymEnd] or [ppmd8SymError].
int ppmd8DecodeSymbol(Ppmd8 p) {
  final m8 = p.mem;
  final m32 = p.mem32;
  final charMask = p.charMask;
  var mc = p.minContext;

  if (m8[mc] != 0) {
    var s = m32[(mc >> 2) + 1];
    var summFreq = p.mem16[(mc >> 1) + 1];

    // PPMD8_CORRECT_SUM_RANGE
    if (summFreq > p.rcRange) summFreq = p.rcRange;

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
    var i = m8[mc];

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

    if (hiCnt >= summFreq) return ppmd8SymError;

    hiCnt = (hiCnt - count) & 0xFFFFFFFF;
    _rcDecode(p, hiCnt, summFreq - hiCnt);

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
      _rcNorm(p);
      final sym = m8[s];
      p.updateBin(s);
      return sym;
    }

    p.binSumm[prob] = pr;
    p.initEsc = p.expEscape[pr >> 10];

    p.rcLow = (p.rcLow + size0) & 0xFFFFFFFF;
    p.rcCode = (p.rcCode - size0) & 0xFFFFFFFF;
    p.rcRange = (p.rcRange & ~(ppmdBinScale - 1) & 0xFFFFFFFF) - size0;

    p.setAllBitsInCharMask();
    charMask[m8[s]] = 0;
    p.prevSuccess = 0;
  }

  for (;;) {
    _rcNorm(p);
    mc = p.minContext;
    final numMasked = m8[mc];

    do {
      p.orderFall++;
      final suffix = m32[(mc >> 2) + 2];
      if (suffix == 0) return ppmd8SymEnd;
      mc = suffix;
    } while (m8[mc] == numMasked);

    var s = m32[(mc >> 2) + 1];
    int hiCnt;
    {
      var num = m8[mc] + 1;
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
    var freqSum2 = freqSum;
    // PPMD8_CORRECT_SUM_RANGE
    if (freqSum2 > p.rcRange) freqSum2 = p.rcRange;

    var count = _rcGetThreshold(p, freqSum2);

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

      // new (see.Summ) value can overflow over 16-bits in some rare cases
      p.seeUpdate(see);
      p.foundState = s;
      final sym = m8[s];
      p.update2();
      return sym;
    }

    if (count >= freqSum2) return ppmd8SymError;

    _rcDecode(p, hiCnt, freqSum2 - hiCnt);

    // We increase (see.Summ) for sum of Freqs of all non_Masked symbols.
    p.seeSumm[see] = p.seeSumm[see] + freqSum;

    s = m32[(p.minContext >> 2) + 1];
    final s2 = s + (m8[p.minContext] + 1) * 6;
    do {
      charMask[m8[s]] = 0;
      s += 6;
    } while (s != s2);
  }
}
