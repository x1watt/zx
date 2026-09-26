// Port of C/Ppmd8Enc.c: the Ppmd8 (PPMdI) encoder with its own range
// encoder (the carryless range coder of Dmitry Subbotin).

import 'dart:typed_data';

import 'ppmd8.dart';

const int _kTop = 1 << 24;
const int _kBot = 1 << 15;

// Ppmd8_Init_RangeEnc
void ppmd8InitRangeEnc(Ppmd8 p) {
  p.rcLow = 0;
  p.rcRange = 0xFFFFFFFF;
}

// Ppmd8_Flush_RangeEnc
void ppmd8FlushRangeEnc(Ppmd8 p) {
  final out = p.rcOut!;
  var low = p.rcLow;
  for (var i = 0; i < 4; i++, low = (low << 8) & 0xFFFFFFFF) {
    out.writeByte(low >> 24); // WRITE_BYTE
  }
  p.rcLow = low;
}

// RC_NORM (RC_NORM_REMOTE)
@pragma('vm:prefer-inline')
void _rcNorm(Ppmd8 p) {
  var low = p.rcLow;
  var range = p.rcRange;
  if ((low ^ ((low + range) & 0xFFFFFFFF)) < _kTop || range < _kBot) {
    final out = p.rcOut!;
    for (;;) {
      if ((low ^ ((low + range) & 0xFFFFFFFF)) >= _kTop) {
        if (range >= _kBot) break;
        range = (-low) & (_kBot - 1);
      }
      out.writeByte(low >> 24); // WRITE_BYTE
      range = (range << 8) & 0xFFFFFFFF;
      low = (low << 8) & 0xFFFFFFFF;
    }
    p.rcRange = range;
    p.rcLow = low;
  }
}

// Ppmd8_RangeEnc_Encode (RC_NORM_LOCAL is empty)
@pragma('vm:prefer-inline')
void _rcEncode(Ppmd8 p, int start, int size, int total) {
  final r = p.rcRange ~/ total;
  p.rcLow = (p.rcLow + start * r) & 0xFFFFFFFF;
  p.rcRange = (r * size) & 0xFFFFFFFF;
}

/// Ppmd8_EncodeSymbol. [symbol] is a byte, or -1 for the end marker.
void ppmd8EncodeSymbol(Ppmd8 p, int symbol) {
  final m8 = p.mem;
  final m32 = p.mem32;
  final charMask = p.charMask;
  var mc = p.minContext;

  if (m8[mc] != 0) {
    var s = m32[(mc >> 2) + 1];
    var summFreq = p.mem16[(mc >> 1) + 1];

    // PPMD8_CORRECT_SUM_RANGE
    if (summFreq > p.rcRange) summFreq = p.rcRange;

    if (m8[s] == symbol) {
      _rcEncode(p, 0, m8[s + 1], summFreq);
      _rcNorm(p);
      p.foundState = s;
      p.update1_0();
      return;
    }
    p.prevSuccess = 0;
    var sum = m8[s + 1];
    var i = m8[mc];
    do {
      s += 6;
      if (m8[s] == symbol) {
        _rcEncode(p, sum, m8[s + 1], summFreq);
        _rcNorm(p);
        p.foundState = s;
        p.update1();
        return;
      }
      sum += m8[s + 1];
    } while (--i != 0);

    _rcEncode(p, sum, summFreq - sum, summFreq);

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
      _rcNorm(p);
      p.updateBin(s);
      return;
    }

    p.binSumm[prob] = pr;
    p.initEsc = p.expEscape[pr >> 10];
    p.rcLow = (p.rcLow + bound) & 0xFFFFFFFF;
    p.rcRange = (p.rcRange & ~(ppmdBinScale - 1) & 0xFFFFFFFF) - bound;

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
      if (suffix == 0) return; // EndMarker (symbol = -1)
      mc = suffix;
    } while (m8[mc] == numMasked);

    p.minContext = mc;

    final see = p.makeEscFreq(numMasked);
    final escFreq = p.escFreqOut;

    var s = m32[(mc >> 2) + 1];
    var sum = 0;
    var i = m8[mc] + 1;

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

        // PPMD8_CORRECT_SUM_RANGE
        if (sum > p.rcRange) sum = p.rcRange;

        _rcEncode(p, low, freq, sum);
        _rcNorm(p);
        p.update2();
        return;
      }
      sum += (m8[s + 1] & charMask[cur]);
      s += 6;
    } while (--i != 0);

    {
      var total = sum + escFreq;
      p.seeSumm[see] = p.seeSumm[see] + total;
      // PPMD8_CORRECT_SUM_RANGE
      if (total > p.rcRange) total = p.rcRange;
      _rcEncode(p, sum, total - sum, total);
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

/// Encodes buf[start..lim) (a loop of Ppmd8_EncodeSymbol).
void ppmd8EncodeSymbols(Ppmd8 p, Uint8List buf, int start, int lim) {
  for (var i = start; i < lim; i++) {
    ppmd8EncodeSymbol(p, buf[i]);
  }
}
