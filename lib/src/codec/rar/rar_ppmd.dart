// PPMd var.H with the range decoder of RAR 3.x (the "PpmdRAR" decoder of
// libarchive's archive_ppmd7.c: PpmdRAR_RangeDec_Init, Range_GetThreshold,
// Range_Normalize, Range_Decode_RAR, Range_DecodeBit_RAR; Igor Pavlov,
// public domain). The model is the shared Ppmd7 of lib/src/codec/ppmd; the
// symbol decoder follows Ppmd7z_DecodeSymbol (ppmd7_dec.dart) with the RAR
// range coder operations in place of the 7z ones.

import '../ppmd/ppmd7.dart';

const int _kTopValue = 1 << 24;

/// Gives the next input byte (0 after the end).
typedef RarByteSource = int Function();

/// The RAR range decoder state (CPpmd7z_RangeDec with Low and Bottom).
final class RarPpmdRangeDecoder {
  int code = 0;
  int range = 0;
  int low = 0;
  int bottom = 0;
  final RarByteSource readByte;
  RarPpmdRangeDecoder(this.readByte);

  // PpmdRAR_RangeDec_Init
  bool init() {
    low = 0;
    range = 0xFFFFFFFF;
    code = 0;
    for (var i = 0; i < 4; i++) {
      code = ((code << 8) | readByte()) & 0xFFFFFFFF;
    }
    bottom = 0x8000;
    return code < 0xFFFFFFFF;
  }

  // Range_GetThreshold
  @pragma('vm:prefer-inline')
  int getThreshold(int total) {
    range = range ~/ total;
    return ((code - low) & 0xFFFFFFFF) ~/ range;
  }

  // Range_Normalize
  void _normalize() {
    for (;;) {
      if (((low ^ ((low + range) & 0xFFFFFFFF)) & 0xFFFFFFFF) >= _kTopValue) {
        if (range >= bottom) break;
        range = (-low) & (bottom - 1);
      }
      code = ((code << 8) | readByte()) & 0xFFFFFFFF;
      range = (range << 8) & 0xFFFFFFFF;
      low = (low << 8) & 0xFFFFFFFF;
    }
  }

  // Range_Decode_RAR
  @pragma('vm:prefer-inline')
  void decode(int start, int size) {
    low = (low + start * range) & 0xFFFFFFFF;
    range = (range * size) & 0xFFFFFFFF;
    _normalize();
  }

  // Range_DecodeBit_RAR
  int decodeBit(int size0) {
    final value = getThreshold(ppmdBinScale);
    if (value < size0) {
      decode(0, size0);
      return 0;
    }
    decode(size0, ppmdBinScale - size0);
    return 1;
  }
}

/// Ppmd7_DecodeSymbol with the RAR range decoder. Returns the byte,
/// [ppmd7SymEnd] or [ppmd7SymError].
int rarPpmdDecodeSymbol(Ppmd7 p, RarPpmdRangeDecoder rc) {
  final m8 = p.mem;
  final m16 = p.mem16;
  final m32 = p.mem32;
  final charMask = p.charMask;
  var mc = p.minContext;

  if (m16[mc >> 1] != 1) {
    var s = m32[(mc >> 2) + 1];
    final summFreq = m16[(mc >> 1) + 1];
    final count = rc.getThreshold(summFreq);
    var hiCnt = m8[s + 1];
    if (count < hiCnt) {
      rc.decode(0, hiCnt);
      p.foundState = s;
      final sym = m8[s];
      p.update1_0();
      return sym;
    }
    p.prevSuccess = 0;
    var i = m16[mc >> 1] - 1;
    do {
      s += 6;
      hiCnt += m8[s + 1];
      if (hiCnt > count) {
        rc.decode(hiCnt - m8[s + 1], m8[s + 1]);
        p.foundState = s;
        final sym = m8[s];
        p.update1();
        return sym;
      }
    } while (--i != 0);
    if (count >= summFreq) return ppmd7SymError;
    p.hiBitsFlag = ppmd7HiBitsFlag3(m8[p.foundState]);
    rc.decode(hiCnt, summFreq - hiCnt);
    p.setAllBitsInCharMask();
    {
      var s2 = m32[(mc >> 2) + 1];
      charMask[m8[s]] = 0;
      while (s2 < s) {
        charMask[m8[s2]] = 0;
        s2 += 6;
      }
    }
  } else {
    final s = mc + 2;
    final prob = p.getBinSumm();
    var pr = p.binSumm[prob];
    final bit = rc.decodeBit(pr);
    pr = pr - ((pr + (1 << (ppmdPeriodBits - 2))) >> ppmdPeriodBits);
    if (bit == 0) {
      p.binSumm[prob] = pr + (1 << ppmdIntBits);
      final sym = m8[s];
      p.updateBin(s);
      return sym;
    }
    p.binSumm[prob] = pr;
    p.initEsc = p.expEscape[pr >> 10];
    p.setAllBitsInCharMask();
    charMask[m8[s]] = 0;
    p.prevSuccess = 0;
  }

  for (;;) {
    mc = p.minContext;
    final numMasked = m16[mc >> 1];
    do {
      p.orderFall++;
      final suffix = m32[(mc >> 2) + 2];
      if (suffix == 0) return ppmd7SymEnd;
      mc = suffix;
    } while (m16[mc >> 1] == numMasked);
    p.minContext = mc;

    // the non masked symbols and their total
    final numStats = m16[mc >> 1];
    final stats = m32[(mc >> 2) + 1];
    var hiCnt = 0;
    for (var k = 0, s = stats; k < numStats; k++, s += 6) {
      hiCnt += m8[s + 1] & charMask[m8[s]];
    }
    final see = p.makeEscFreq(numMasked);
    final freqSum = p.escFreqOut + hiCnt;
    final count = rc.getThreshold(freqSum);

    if (count < hiCnt) {
      var acc = 0;
      var s = stats;
      for (;;) {
        acc += m8[s + 1] & charMask[m8[s]];
        if (acc > count) break;
        s += 6;
      }
      rc.decode(acc - m8[s + 1], m8[s + 1]);
      p.seeUpdate(see);
      p.foundState = s;
      final sym = m8[s];
      p.update2();
      return sym;
    }
    if (count >= freqSum) return ppmd7SymError;
    rc.decode(hiCnt, freqSum - hiCnt);
    p.seeSumm[see] = p.seeSumm[see] + freqSum;
    for (var k = 0, s = stats; k < numStats; k++, s += 6) {
      charMask[m8[s]] = 0;
    }
  }
}
