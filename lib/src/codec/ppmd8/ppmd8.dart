// Port of C/Ppmd8.c and C/Ppmd8.h (+ the parts of C/Ppmd.h they use): the
// PPMd var.I rev.1 model (PPMdI) used by zip method 98 (ppmd8_dec.dart,
// ppmd8_enc.dart, ppmd8_coder.dart). The public domain C files are in
// ref/7zip-public-domain-c. PPMD8_FREEZE_SUPPORT is not defined there, so
// the FREEZE restore method is not supported here either.
//
// As in the Ppmd7 port (../ppmd/ppmd7.dart) the model lives in one
// Uint8List arena with Uint16List and Uint32List views over the same bytes,
// and every "pointer" is an offset into it (the non-PPMD_32BIT mode of the
// C code). The layout is the C one:
//
//   CPpmd_State (6 bytes, 2-byte aligned):
//     +0 Symbol (u8), +1 Freq (u8), +2 Successor_0 (u16), +4 Successor_1 (u16)
//   CPpmd8_Context (12 bytes, 4-byte aligned):
//     +0 NumStats (u8), +1 Flags (u8),
//     +2 SummFreq (u16) or State2.Symbol/Freq (u8, u8),
//     +4 Stats (u32) or State4.Successor_0/1 (u16, u16), +8 Suffix (u32)
//   CPpmd8_Node (free block, 12 bytes):
//     +0 Stamp (u32), +4 Next (u32), +8 NU (u32)
//
// The typed views use the host byte order, like the C code does; the values
// never leave the process, so the result is the same on every host.
//
// The range coder fields of CPpmd8 (Range, Code, Low, Stream) live in
// [Ppmd8] as well.

import 'dart:typed_data';

import '../ppmd/ppmd7.dart'
    show ppmdBinScale, ppmdNumIndexes, ppmdPeriodBits, PpmdByteIn, PpmdByteOut;

export '../ppmd/ppmd7.dart'
    show ppmdBinScale, ppmdIntBits, ppmdPeriodBits, PpmdByteIn, PpmdByteOut;

// Ppmd8.h
const int ppmd8MinOrder = 2;
const int ppmd8MaxOrder = 16;

/// PPMD8_RESTORE_METHOD_RESTART, PPMD8_RESTORE_METHOD_CUT_OFF and
/// PPMD8_RESTORE_METHOD_UNSUPPPORTED (FREEZE is not compiled in).
const int ppmd8RestoreMethodRestart = 0;
const int ppmd8RestoreMethodCutOff = 1;
const int ppmd8RestoreMethodUnsupported = 2;

/// Ppmd8_DecodeSymbol results (PPMD8_SYM_END, PPMD8_SYM_ERROR).
const int ppmd8SymEnd = -1;
const int ppmd8SymError = -2;

// Ppmd8.c
const int _kMaxFreq = 124;
const int _kUnitSize = 12;
const int _kEmptyNode = 0xFFFFFFFF;
const int _kFlagRescaled = 1 << 2;
const int _kFlagPrevHigh = 1 << 4;
const List<int> _kExpEscape = [
  25, 14, 9, 7, 5, 5, 4, 4, 4, 3, 3, 3, 2, 2, 2, 2 //
];
const List<int> _kInitBinEsc = [
  0x3CDD, 0x1F3F, 0x59BF, 0x48F3, 0x64A1, 0x5ABC, 0x6632, 0x6051 //
];

/// Index of CPpmd8::DummySee in the See arrays (after See[24][32]).
const int ppmd8DummySee = 24 * 32;

// PPMD8_HiBitsFlag_3
@pragma('vm:prefer-inline')
int ppmd8HiBitsFlag3(int sym) => ((sym + 0xC0) >> (8 - 3)) & (1 << 3);

// PPMD8_HiBitsFlag_4
@pragma('vm:prefer-inline')
int _hiBitsFlag4(int sym) => ((sym + 0xC0) >> (8 - 4)) & (1 << 4);

/// CPpmd8: the PPMdI model plus the range coder state.
final class Ppmd8 {
  // Model state. Every "pointer" is an offset into [mem].
  int minContext = 0;
  int maxContext = 0;
  int foundState = 0;
  int orderFall = 0;
  int initEsc = 0;
  int prevSuccess = 0;
  int maxOrder = 0;
  int restoreMethod = 0;
  int runLength = 0;
  int initRL = 0;

  int size = 0;
  int glueCount = 0;
  int alignOffset = 0;

  /// Base: the arena. [mem16] and [mem32] view the same bytes.
  Uint8List mem = Uint8List(0);
  Uint16List mem16 = Uint16List(0);
  Uint32List mem32 = Uint32List(0);
  int loUnit = 0;
  int hiUnit = 0;
  int text = 0;
  int unitsStart = 0;

  // Range, Code, Low and Stream.
  int rcRange = 0;
  int rcCode = 0;
  int rcLow = 0;
  PpmdByteIn? rcIn;
  PpmdByteOut? rcOut;

  final Uint8List indx2Units = Uint8List(ppmdNumIndexes + 2);
  final Uint8List units2Indx = Uint8List(128);
  final Uint32List freeList = Uint32List(ppmdNumIndexes);
  final Uint32List stamps = Uint32List(ppmdNumIndexes);
  final Uint8List ns2BSIndx = Uint8List(256);
  final Uint8List ns2Indx = Uint8List(260);
  final Uint8List expEscape = Uint8List(16);

  /// See[24][32] followed by DummySee (index [ppmd8DummySee]).
  final Uint16List seeSumm = Uint16List(24 * 32 + 1);
  final Uint8List seeShift = Uint8List(24 * 32 + 1);
  final Uint8List seeCount = Uint8List(24 * 32 + 1);

  /// BinSumm[25][64].
  final Uint16List binSumm = Uint16List(25 * 64);

  /// The charMask scratch array of the symbol coders (on the stack in C).
  final Uint8List charMask = Uint8List(256);
  late final Uint64List _charMask64 = charMask.buffer.asUint64List(0, 32);

  /// The ps[] array of Ppmd8_CreateSuccessors.
  final Uint32List _ps = Uint32List(ppmd8MaxOrder + 1);

  /// The count[] array of ExpandTextArea.
  final Uint32List _count = Uint32List(ppmdNumIndexes);

  /// Second result of [makeEscFreq] (the escFreq out parameter).
  int escFreqOut = 0;

  // Ppmd8_Construct
  Ppmd8() {
    var k = 0;
    for (var i = 0; i < ppmdNumIndexes; i++) {
      var step = (i >= 12 ? 4 : (i >> 2) + 1);
      do {
        units2Indx[k++] = i;
      } while (--step != 0);
      indx2Units[i] = k;
    }

    ns2BSIndx[0] = (0 << 1);
    ns2BSIndx[1] = (1 << 1);
    ns2BSIndx.fillRange(2, 11, (2 << 1));
    ns2BSIndx.fillRange(11, 256, (3 << 1));

    var i = 0;
    for (; i < 5; i++) {
      ns2Indx[i] = i;
    }
    for (var m = i, k = 1; i < 260; i++) {
      ns2Indx[i] = m;
      if (--k == 0) k = (++m) - 4;
    }

    expEscape.setAll(0, _kExpEscape);
  }

  // PPMD_SetAllBitsIn256Bytes(charMask)
  @pragma('vm:prefer-inline')
  void setAllBitsInCharMask() {
    final m = _charMask64;
    for (var z = 0; z < 32; z += 8) {
      m[z] = -1;
      m[z + 1] = -1;
      m[z + 2] = -1;
      m[z + 3] = -1;
      m[z + 4] = -1;
      m[z + 5] = -1;
      m[z + 6] = -1;
      m[z + 7] = -1;
    }
  }

  // Ppmd8_WasAllocated
  bool get wasAllocated => mem.isNotEmpty;

  // Ppmd8_Free
  void free() {
    size = 0;
    mem = Uint8List(0);
    mem16 = Uint16List(0);
    mem32 = Uint32List(0);
  }

  // Ppmd8_Alloc
  void alloc(int size) {
    if (mem.isEmpty || this.size != size) {
      free();
      alignOffset = (4 - size) & 3;
      final m = Uint8List(alignOffset + size);
      mem = m;
      mem16 = m.buffer.asUint16List(0, m.length >> 1);
      mem32 = m.buffer.asUint32List(0, m.length >> 2);
      this.size = size;
    }
  }

  // Internal memory allocator

  // Ppmd8_InsertNode
  @pragma('vm:prefer-inline')
  void _insertNode(int node, int indx) {
    final m32 = mem32;
    final n = node >> 2;
    m32[n] = _kEmptyNode;
    m32[n + 1] = freeList[indx];
    m32[n + 2] = indx2Units[indx];
    freeList[indx] = node;
    stamps[indx]++;
  }

  // Ppmd8_RemoveNode
  @pragma('vm:prefer-inline')
  int _removeNode(int indx) {
    final node = freeList[indx];
    freeList[indx] = mem32[(node >> 2) + 1];
    stamps[indx]--;
    return node;
  }

  // Ppmd8_SplitBlock
  void _splitBlock(int ptr, int oldIndx, int newIndx) {
    final nu = indx2Units[oldIndx] - indx2Units[newIndx];
    ptr += indx2Units[newIndx] * _kUnitSize;
    var i = units2Indx[nu - 1];
    if (indx2Units[i] != nu) {
      final k = indx2Units[--i];
      _insertNode(ptr + k * _kUnitSize, nu - k - 1);
    }
    _insertNode(ptr, i);
  }

  // Ppmd8_GlueFreeBlocks
  void _glueFreeBlocks() {
    final m32 = mem32;
    // (n) is the local list head; (prev) is the offset of the u32 link to
    // update, or -1 for (n).
    var n = 0;

    glueCount = 1 << 13;
    stamps.fillRange(0, ppmdNumIndexes, 0);

    // We set guard NODE at LoUnit.
    if (loUnit != hiUnit) m32[loUnit >> 2] = 0;

    {
      // Glue free blocks.
      var prev = -1;
      for (var i = 0; i < ppmdNumIndexes; i++) {
        var next = freeList[i];
        freeList[i] = 0;
        while (next != 0) {
          final node = next;
          var nu = m32[(node >> 2) + 2];
          if (prev < 0) {
            n = next;
          } else {
            m32[prev >> 2] = next;
          }
          next = m32[(node >> 2) + 1];
          if (nu != 0) {
            prev = node + 4;
            for (;;) {
              final node2 = node + nu * _kUnitSize;
              if (m32[node2 >> 2] != _kEmptyNode) break;
              nu = (nu + m32[(node2 >> 2) + 2]) & 0xFFFFFFFF;
              m32[(node2 >> 2) + 2] = 0;
              m32[(node >> 2) + 2] = nu;
            }
          }
        }
      }
      if (prev < 0) {
        n = 0;
      } else {
        m32[prev >> 2] = 0;
      }
    }

    // Fill lists of free blocks.
    while (n != 0) {
      var node = n;
      var nu = m32[(node >> 2) + 2];
      n = m32[(node >> 2) + 1];
      if (nu == 0) continue;
      for (; nu > 128; nu -= 128, node += 128 * _kUnitSize) {
        _insertNode(node, ppmdNumIndexes - 1);
      }
      var i = units2Indx[nu - 1];
      if (indx2Units[i] != nu) {
        final k = indx2Units[--i];
        _insertNode(node + k * _kUnitSize, nu - k - 1);
      }
      _insertNode(node, i);
    }
  }

  // Ppmd8_AllocUnitsRare. Returns 0 for NULL.
  int _allocUnitsRare(int indx) {
    if (glueCount == 0) {
      _glueFreeBlocks();
      if (freeList[indx] != 0) return _removeNode(indx);
    }
    var i = indx;
    do {
      if (++i == ppmdNumIndexes) {
        final numBytes = indx2Units[indx] * _kUnitSize;
        final us = unitsStart;
        glueCount = (glueCount - 1) & 0xFFFFFFFF;
        if (((us - text) & 0xFFFFFFFF) > numBytes) {
          unitsStart = us - numBytes;
          return unitsStart;
        }
        return 0;
      }
    } while (freeList[i] == 0);
    final block = _removeNode(i);
    _splitBlock(block, i, indx);
    return block;
  }

  // Ppmd8_AllocUnits. Returns 0 for NULL.
  int _allocUnits(int indx) {
    if (freeList[indx] != 0) return _removeNode(indx);
    final numBytes = indx2Units[indx] * _kUnitSize;
    final lo = loUnit;
    if (hiUnit - lo >= numBytes) {
      loUnit = lo + numBytes;
      return lo;
    }
    return _allocUnitsRare(indx);
  }

  // MEM_12_CPY
  @pragma('vm:prefer-inline')
  void _mem12Cpy(int dest, int src, int num) {
    final d = dest >> 2;
    mem32.setRange(d, d + num * 3, mem32, src >> 2);
  }

  // ShrinkUnits
  int _shrinkUnits(int oldPtr, int oldNU, int newNU) {
    final i0 = units2Indx[oldNU - 1];
    final i1 = units2Indx[newNU - 1];
    if (i0 == i1) return oldPtr;
    if (freeList[i1] != 0) {
      final ptr = _removeNode(i1);
      _mem12Cpy(ptr, oldPtr, newNU);
      _insertNode(oldPtr, i0);
      return ptr;
    }
    _splitBlock(oldPtr, i0, i1);
    return oldPtr;
  }

  // FreeUnits
  @pragma('vm:prefer-inline')
  void _freeUnits(int ptr, int nu) {
    _insertNode(ptr, units2Indx[nu - 1]);
  }

  // SpecialFreeUnit
  void _specialFreeUnit(int ptr) {
    if (ptr != unitsStart) {
      _insertNode(ptr, 0);
    } else {
      unitsStart += _kUnitSize;
    }
  }

  // ExpandTextArea
  void _expandTextArea() {
    final m32 = mem32;
    final count = _count;
    count.fillRange(0, ppmdNumIndexes, 0);
    if (loUnit != hiUnit) m32[loUnit >> 2] = 0;

    {
      var node = unitsStart;
      while (m32[node >> 2] == _kEmptyNode) {
        final nu = m32[(node >> 2) + 2];
        m32[node >> 2] = 0;
        count[units2Indx[nu - 1]]++;
        node += nu * _kUnitSize;
      }
      unitsStart = node;
    }

    for (var i = 0; i < ppmdNumIndexes; i++) {
      var cnt = count[i];
      if (cnt == 0) continue;
      // (prev) is the offset of the u32 link to update, or -1 for
      // FreeList[i].
      var prev = -1;
      var n = freeList[i];
      stamps[i] -= cnt;
      for (;;) {
        final node = n;
        n = m32[(node >> 2) + 1];
        if (m32[node >> 2] != 0) {
          prev = node + 4;
          continue;
        }
        if (prev < 0) {
          freeList[i] = n;
        } else {
          m32[prev >> 2] = n;
        }
        if (--cnt == 0) break;
      }
    }
  }

  // SUCCESSOR (Ppmd_GET_SUCCESSOR) of the state at [s].
  @pragma('vm:prefer-inline')
  int successor(int s) {
    final i = (s >> 1) + 1;
    return mem16[i] | (mem16[i + 1] << 16);
  }

  // Ppmd8State_SetSuccessor (Ppmd_SET_SUCCESSOR)
  @pragma('vm:prefer-inline')
  void setSuccessor(int s, int v) {
    final i = (s >> 1) + 1;
    mem16[i] = v;
    mem16[i + 1] = v >> 16;
  }

  // *dest = *src for CPpmd_State.
  @pragma('vm:prefer-inline')
  void _copyState(int dest, int src) {
    final m16 = mem16;
    final d = dest >> 1;
    final s = src >> 1;
    m16[d] = m16[s];
    m16[d + 1] = m16[s + 1];
    m16[d + 2] = m16[s + 2];
  }

  // SWAP_STATES(t1, t2)
  @pragma('vm:prefer-inline')
  void _swapStates(int t1, int t2) {
    final m16 = mem16;
    final a = t1 >> 1;
    final b = t2 >> 1;
    final x0 = m16[a], x1 = m16[a + 1], x2 = m16[a + 2];
    m16[a] = m16[b];
    m16[a + 1] = m16[b + 1];
    m16[a + 2] = m16[b + 2];
    m16[b] = x0;
    m16[b + 1] = x1;
    m16[b + 2] = x2;
  }

  // Ppmd8_RestartModel
  void _restartModel() {
    freeList.fillRange(0, ppmdNumIndexes, 0);
    stamps.fillRange(0, ppmdNumIndexes, 0);
    text = alignOffset; // RESET_TEXT(0)
    hiUnit = text + size;
    loUnit = unitsStart = hiUnit - size ~/ 8 ~/ _kUnitSize * 7 * _kUnitSize;
    glueCount = 0;

    orderFall = maxOrder;
    runLength = initRL = -((maxOrder < 12) ? maxOrder : 12) - 1;
    prevSuccess = 0;

    {
      final m8 = mem;
      final m16 = mem16;
      final mc = (hiUnit -= _kUnitSize); // AllocContext(p)
      var s = loUnit; // Ppmd8_AllocUnits(p, PPMD_NUM_INDEXES - 1)

      loUnit += (256 ~/ 2) * _kUnitSize;
      maxContext = minContext = mc;
      foundState = s;
      m8[mc + 1] = 0; // Flags
      m8[mc] = 256 - 1; // NumStats
      m16[(mc >> 1) + 1] = 256 + 1; // SummFreq
      mem32[(mc >> 2) + 1] = s; // Stats
      mem32[(mc >> 2) + 2] = 0; // Suffix

      for (var i = 0; i < 256; i++, s += 6) {
        m8[s] = i;
        m8[s + 1] = 1;
        m16[(s >> 1) + 1] = 0;
        m16[(s >> 1) + 2] = 0;
      }
    }

    final bs = binSumm;
    for (var i = 0, m = 0; m < 25; m++) {
      while (ns2Indx[i] == m) {
        i++;
      }
      for (var k = 0; k < 8; k++) {
        final dest = m * 64 + k;
        final val = ppmdBinScale - _kInitBinEsc[k] ~/ (i + 1);
        for (var r = 0; r < 64; r += 8) {
          bs[dest + r] = val;
        }
      }
    }

    for (var i = 0, m = 0; m < 24; m++) {
      while (ns2Indx[i + 3] == m + 3) {
        i++;
      }
      final summ = ((2 * i + 5) << (ppmdPeriodBits - 4));
      for (var k = 0; k < 32; k++) {
        final s = m * 32 + k;
        seeSumm[s] = summ;
        seeShift[s] = ppmdPeriodBits - 4;
        seeCount[s] = 7;
      }
    }

    seeSumm[ppmd8DummySee] = 0; // unused
    seeShift[ppmd8DummySee] = ppmdPeriodBits;
    seeCount[ppmd8DummySee] = 64; // unused
  }

  // Ppmd8_Init
  void init(int maxOrder, int restoreMethod) {
    this.maxOrder = maxOrder;
    this.restoreMethod = restoreMethod;
    _restartModel();
  }

  // Refresh
  void _refresh(int ctx, int oldNU, int scale) {
    final m8 = mem;
    final m16 = mem16;
    var i = m8[ctx];
    var s = _shrinkUnits(mem32[(ctx >> 2) + 1], oldNU, (i + 2) >> 1);
    mem32[(ctx >> 2) + 1] = s;

    final summFreq = m16[(ctx >> 1) + 1];
    scale |= (summFreq >= (1 << 15)) ? 1 : 0;

    var flags = m8[s] + 0xC0; // HiBits_Prepare
    var escFreq = 0;
    var sumFreq = 0;
    {
      var freq = m8[s + 1];
      escFreq = summFreq - freq;
      freq = (freq + scale) >> scale;
      sumFreq = freq;
      m8[s + 1] = freq;
    }

    do {
      s += 6;
      var freq = m8[s + 1];
      escFreq -= freq;
      freq = (freq + scale) >> scale;
      sumFreq += freq;
      m8[s + 1] = freq;
      flags |= m8[s] + 0xC0;
    } while (--i != 0);

    m16[(ctx >> 1) + 1] = sumFreq + (((escFreq + scale) & 0xFFFFFFFF) >> scale);
    m8[ctx + 1] = (m8[ctx + 1] & (_kFlagPrevHigh + _kFlagRescaled * scale)) +
        ((flags >> (8 - 3)) & (1 << 3));
  }

  // CutOff. Returns the context reference or 0.
  int _cutOff(int ctx, int order) {
    final m8 = mem;
    final m32 = mem32;
    var ns = m8[ctx];

    if (ns == 0) {
      final s = ctx + 2;
      var succ = successor(s);
      if (succ >= unitsStart) {
        if (order < maxOrder) {
          succ = _cutOff(succ, order + 1);
        } else {
          succ = 0;
        }
        setSuccessor(s, succ);
        if (succ != 0 || order <= 9) return ctx; // O_BOUND
      }
      _specialFreeUnit(ctx);
      return 0;
    }

    final nu = (ns + 2) >> 1;
    int stats;
    {
      final indx = units2Indx[nu - 1];
      stats = m32[(ctx >> 2) + 1];

      if (((stats - unitsStart) & 0xFFFFFFFF) <= (1 << 14) &&
          stats <= freeList[indx]) {
        final ptr = _removeNode(indx);
        m32[(ctx >> 2) + 1] = ptr;
        _mem12Cpy(ptr, stats, nu);
        if (stats != unitsStart) {
          _insertNode(stats, indx);
        } else {
          unitsStart += indx2Units[indx] * _kUnitSize;
        }
        stats = ptr;
      }
    }

    {
      var s = stats + ns * 6;
      do {
        final succ = successor(s);
        if (succ < unitsStart) {
          final s2 = stats + (ns--) * 6;
          if (order != 0) {
            if (s != s2) _copyState(s, s2);
          } else {
            _swapStates(s, s2);
            setSuccessor(s2, 0);
          }
        } else {
          if (order < maxOrder) {
            setSuccessor(s, _cutOff(succ, order + 1));
          } else {
            setSuccessor(s, 0);
          }
        }
      } while ((s -= 6) >= stats);
    }

    if (ns != m8[ctx] && order != 0) {
      if (ns < 0) {
        _freeUnits(stats, nu);
        _specialFreeUnit(ctx);
        return 0;
      }
      m8[ctx] = ns;
      if (ns == 0) {
        final sym = m8[stats];
        m8[ctx + 1] = (m8[ctx + 1] & _kFlagPrevHigh) + ppmd8HiBitsFlag3(sym);
        m8[ctx + 2] = sym;
        m8[ctx + 3] = (m8[stats + 1] + 11) >> 3;
        mem16[(ctx >> 1) + 2] = mem16[(stats >> 1) + 1];
        mem16[(ctx >> 1) + 3] = mem16[(stats >> 1) + 2];
        _freeUnits(stats, nu);
      } else {
        _refresh(ctx, nu, mem16[(ctx >> 1) + 1] > 16 * ns ? 1 : 0);
      }
    }

    return ctx;
  }

  // GetUsedMemory
  int _getUsedMemory() {
    var v = 0;
    for (var i = 0; i < ppmdNumIndexes; i++) {
      v += stamps[i] * indx2Units[i];
    }
    return (size -
            (hiUnit - loUnit) -
            (unitsStart - text) -
            (v & 0xFFFFFFFF) * _kUnitSize) &
        0xFFFFFFFF;
  }

  // RestoreModel
  void _restoreModel(int ctxError) {
    final m8 = mem;
    final m16 = mem16;
    final m32 = mem32;
    int c;
    text = alignOffset; // RESET_TEXT(0)

    // We remove last symbol from each of contexts [p.MaxContext ...
    // ctxError) contexts. So we rollback all created (symbols) before error.
    for (c = maxContext; c != ctxError; c = m32[(c >> 2) + 2]) {
      final ns = (m8[c] - 1) & 0xFF;
      m8[c] = ns;
      if (ns == 0) {
        final s = m32[(c >> 2) + 1];
        m8[c + 1] = (m8[c + 1] & _kFlagPrevHigh) + ppmd8HiBitsFlag3(m8[s]);
        m8[c + 2] = m8[s];
        m8[c + 3] = (m8[s + 1] + 11) >> 3;
        m16[(c >> 1) + 2] = m16[(s >> 1) + 1];
        m16[(c >> 1) + 3] = m16[(s >> 1) + 2];
        _specialFreeUnit(s);
      } else {
        // Refresh() can increase Escape_Freq on value of Freq of last
        // symbol, that was added before error.
        _refresh(c, (ns + 3) >> 1, 0);
      }
    }

    // Increase Escape Freq for context [ctxError ... p.MinContext).
    for (; c != minContext; c = m32[(c >> 2) + 2]) {
      final ns = m8[c];
      if (ns == 0) {
        m8[c + 3] = (m8[c + 3] + 1) >> 1;
      } else {
        final sf = (m16[(c >> 1) + 1] + 4) & 0xFFFF;
        m16[(c >> 1) + 1] = sf;
        if (sf > 128 + 4 * ns) _refresh(c, (ns + 2) >> 1, 1);
      }
    }

    if (restoreMethod == ppmd8RestoreMethodRestart ||
        _getUsedMemory() < (size >> 1)) {
      _restartModel();
    } else {
      while (m32[(maxContext >> 2) + 2] != 0) {
        maxContext = m32[(maxContext >> 2) + 2];
      }
      do {
        _cutOff(maxContext, 0);
        _expandTextArea();
      } while (_getUsedMemory() > 3 * (size >> 2));
      glueCount = 0;
      orderFall = maxOrder;
    }
    minContext = maxContext;
  }

  // Ppmd8_CreateSuccessors. [skip] is a bool (0 or 1), [s1] 0 for NULL.
  // Returns 0 for NULL.
  int _createSuccessors(bool skip, int s1, int c) {
    final m8 = mem;
    final m16 = mem16;
    final m32 = mem32;
    final ps = _ps;
    final fs = foundState;
    var upBranch = successor(fs);
    var numPs = 0;

    if (!skip) ps[numPs++] = fs;

    while (m32[(c >> 2) + 2] != 0) {
      int s;
      c = m32[(c >> 2) + 2];

      if (s1 != 0) {
        s = s1;
        s1 = 0;
      } else if (m8[c] != 0) {
        final sym = m8[fs];
        for (s = m32[(c >> 2) + 1]; m8[s] != sym; s += 6) {}
        if (m8[s + 1] < _kMaxFreq - 9) {
          m8[s + 1]++;
          m16[(c >> 1) + 1]++;
        }
      } else {
        s = c + 2;
        final freq = m8[s + 1];
        if (m8[m32[(c >> 2) + 2]] == 0 && freq < 24) m8[s + 1] = freq + 1;
      }
      final succ = successor(s);
      if (succ != upBranch) {
        c = succ;
        if (numPs == 0) return c;
        break;
      }
      ps[numPs++] = s;
    }

    final newSym = m8[upBranch];
    upBranch++;
    final flags = _hiBitsFlag4(m8[fs]) + ppmd8HiBitsFlag3(newSym);

    int newFreq;
    if (m8[c] == 0) {
      newFreq = m8[c + 3];
    } else {
      int s;
      for (s = m32[(c >> 2) + 1]; m8[s] != newSym; s += 6) {}
      final cf = m8[s + 1] - 1;
      final s0 = (m16[(c >> 1) + 1] - m8[c] - cf) & 0xFFFFFFFF;
      newFreq = (1 +
              ((2 * cf <= s0)
                  ? (5 * cf > s0 ? 1 : 0)
                  : ((cf + 2 * s0 - 3) & 0xFFFFFFFF) ~/ s0)) &
          0xFF;
    }

    do {
      int c1;
      // = AllocContext(p);
      if (hiUnit != loUnit) {
        c1 = (hiUnit -= _kUnitSize);
      } else if (freeList[0] != 0) {
        c1 = _removeNode(0);
      } else {
        c1 = _allocUnitsRare(0);
        if (c1 == 0) return 0;
      }
      m8[c1 + 1] = flags;
      m8[c1] = 0;
      m8[c1 + 2] = newSym;
      m8[c1 + 3] = newFreq;
      m16[(c1 >> 1) + 2] = upBranch;
      m16[(c1 >> 1) + 3] = upBranch >> 16;
      m32[(c1 >> 2) + 2] = c;
      setSuccessor(ps[--numPs], c1);
      c = c1;
    } while (numPs != 0);

    return c;
  }

  // ReduceOrder. [s1] is 0 for NULL. Returns 0 for NULL.
  int _reduceOrder(int s1, int c) {
    final m8 = mem;
    final m16 = mem16;
    final m32 = mem32;
    var s = 0;
    final c1 = c;
    final upBranch = text;
    final fSymbol = m8[foundState];

    setSuccessor(foundState, upBranch);
    orderFall++;

    for (;;) {
      if (s1 != 0) {
        c = m32[(c >> 2) + 2];
        s = s1;
        s1 = 0;
      } else {
        if (m32[(c >> 2) + 2] == 0) return c;
        c = m32[(c >> 2) + 2];
        if (m8[c] != 0) {
          s = m32[(c >> 2) + 1];
          while (m8[s] != fSymbol) {
            s += 6;
          }
          if (m8[s + 1] < _kMaxFreq - 9) {
            m8[s + 1] += 2;
            m16[(c >> 1) + 1] += 2;
          }
        } else {
          s = c + 2;
          final freq = m8[s + 1];
          if (freq < 32) m8[s + 1] = freq + 1;
        }
      }
      if (successor(s) != 0) break;
      setSuccessor(s, upBranch);
      orderFall++;
    }

    if (successor(s) <= upBranch) {
      final s2 = foundState;
      foundState = s;
      final succ = _createSuccessors(false, 0, c);
      setSuccessor(s, succ);
      foundState = s2;
    }

    {
      final succ = successor(s);
      if (orderFall == 1 && c1 == maxContext) {
        setSuccessor(foundState, succ);
        text--;
      }
      return succ;
    }
  }

  // Ppmd8_UpdateModel
  void updateModel() {
    final m8 = mem;
    final m16 = mem16;
    final m32 = mem32;
    final fs = foundState;
    var minSuccessor = successor(fs);
    int maxSuccessor;
    int c;
    final fFreq = m8[fs + 1];
    final fSymbol = m8[fs];
    {
      var s = 0;
      if (fFreq < _kMaxFreq ~/ 4 && m32[(minContext >> 2) + 2] != 0) {
        // Update Freqs in Suffix Context.
        c = m32[(minContext >> 2) + 2];
        if (m8[c] == 0) {
          s = c + 2;
          if (m8[s + 1] < 32) m8[s + 1]++;
        } else {
          s = m32[(c >> 2) + 1];
          if (m8[s] != fSymbol) {
            do {
              s += 6;
            } while (m8[s] != fSymbol);
            if (m8[s + 1] >= m8[s - 6 + 1]) {
              _swapStates(s, s - 6);
              s -= 6;
            }
          }
          if (m8[s + 1] < _kMaxFreq - 9) {
            m8[s + 1] += 2;
            m16[(c >> 1) + 1] += 2;
          }
        }
      }

      c = maxContext;
      if (orderFall == 0 && minSuccessor != 0) {
        final cs = _createSuccessors(true, s, minContext);
        if (cs == 0) {
          setSuccessor(foundState, 0);
          _restoreModel(c);
          return;
        }
        setSuccessor(foundState, cs);
        minContext = maxContext = cs;
        return;
      }

      {
        var t = text;
        m8[t++] = m8[foundState];
        text = t;
        if (t >= unitsStart) {
          _restoreModel(c); // check it
          return;
        }
        maxSuccessor = t;
      }

      if (minSuccessor == 0) {
        final cs = _reduceOrder(s, minContext);
        if (cs == 0) {
          _restoreModel(c);
          return;
        }
        minSuccessor = cs;
      } else if (minSuccessor < unitsStart) {
        final cs = _createSuccessors(false, s, minContext);
        if (cs == 0) {
          _restoreModel(c);
          return;
        }
        minSuccessor = cs;
      }

      if (--orderFall == 0) {
        maxSuccessor = minSuccessor;
        if (maxContext != minContext) text--;
      }
    }

    final flag = ppmd8HiBitsFlag3(fSymbol);
    final ns = m8[minContext];
    final s0 = m16[(minContext >> 1) + 1] - ns - fFreq;

    for (; c != minContext; c = m32[(c >> 2) + 2]) {
      final ns1 = m8[c];
      int sum;

      if (ns1 != 0) {
        if ((ns1 & 1) != 0) {
          // Expand for one UNIT.
          final oldNU = (ns1 + 1) >> 1;
          final i = units2Indx[oldNU - 1];
          if (i != units2Indx[oldNU]) {
            final ptr = _allocUnits(i + 1);
            if (ptr == 0) {
              _restoreModel(c);
              return;
            }
            final oldPtr = m32[(c >> 2) + 1];
            _mem12Cpy(ptr, oldPtr, oldNU);
            _insertNode(oldPtr, i);
            m32[(c >> 2) + 1] = ptr;
          }
        }
        sum = m16[(c >> 1) + 1];
        // max increase of Escape_Freq is 1 here.
        sum += (3 * ns1 + 1 < ns) ? 1 : 0;
      } else {
        final s = _allocUnits(0);
        if (s == 0) {
          _restoreModel(c);
          return;
        }
        var freq = m8[c + 3];
        m8[s] = m8[c + 2];
        m16[(s >> 1) + 1] = m16[(c >> 1) + 2];
        m16[(s >> 1) + 2] = m16[(c >> 1) + 3];
        m32[(c >> 2) + 1] = s;
        if (freq < _kMaxFreq ~/ 4 - 1) {
          freq <<= 1;
        } else {
          freq = _kMaxFreq - 4;
        }
        m8[s + 1] = freq;
        sum = freq + initEsc + (ns > 2 ? 1 : 0); // Ppmd8 (> 2)
      }

      {
        final s = m32[(c >> 2) + 1] + (ns1 + 1) * 6;
        var cf = 2 * (sum + 6) * fFreq;
        final sf = s0 + sum;
        m8[s] = fSymbol;
        m8[c] = ns1 + 1;
        setSuccessor(s, maxSuccessor);
        m8[c + 1] |= flag;
        if (cf < 6 * sf) {
          cf = 1 + (cf > sf ? 1 : 0) + (cf >= 4 * sf ? 1 : 0);
          sum += 4;
          // It can add (1, 2, 3) to Escape_Freq.
        } else {
          cf = 4 +
              (cf > 9 * sf ? 1 : 0) +
              (cf > 12 * sf ? 1 : 0) +
              (cf > 15 * sf ? 1 : 0);
          sum += cf;
        }
        m16[(c >> 1) + 1] = sum;
        m8[s + 1] = cf;
      }
    }
    maxContext = minContext = minSuccessor;
  }

  // Ppmd8_Rescale
  void _rescale() {
    final m8 = mem;
    final m16 = mem16;
    final mc = minContext;
    final stats = mem32[(mc >> 2) + 1];
    var s = foundState;

    // Sort the list by Freq.
    if (s != stats) {
      final t0 = m16[s >> 1], t1 = m16[(s >> 1) + 1], t2 = m16[(s >> 1) + 2];
      do {
        _copyState(s, s - 6);
        s -= 6;
      } while (s != stats);
      m16[s >> 1] = t0;
      m16[(s >> 1) + 1] = t1;
      m16[(s >> 1) + 2] = t2;
    }

    var sumFreq = m8[s + 1];
    var escFreq = m16[(mc >> 1) + 1] - sumFreq;

    final adder = (orderFall != 0) ? 1 : 0;

    sumFreq = (sumFreq + 4 + adder) >> 1;
    var i = m8[mc];
    m8[s + 1] = sumFreq;

    do {
      s += 6;
      var freq = m8[s + 1];
      escFreq -= freq;
      freq = (freq + adder) >> 1;
      sumFreq += freq;
      m8[s + 1] = freq;
      if (freq > m8[s - 6 + 1]) {
        final t0 = m16[s >> 1], t1 = m16[(s >> 1) + 1], t2 = m16[(s >> 1) + 2];
        var s1 = s;
        do {
          _copyState(s1, s1 - 6);
          s1 -= 6;
        } while (s1 != stats && freq > m8[s1 - 6 + 1]);
        m16[s1 >> 1] = t0;
        m16[(s1 >> 1) + 1] = t1;
        m16[(s1 >> 1) + 2] = t2;
      }
    } while (--i != 0);

    if (m8[s + 1] == 0) {
      // Remove all items with Freq == 0.
      i = 0;
      do {
        i++;
        s -= 6;
      } while (m8[s + 1] == 0);

      escFreq = (escFreq + i) & 0xFFFFFFFF;
      final numStats = m8[mc];
      final numStatsNew = numStats - i;
      m8[mc] = numStatsNew;
      final n0 = (numStats + 2) >> 1;

      if (numStatsNew == 0) {
        var freq = (2 * m8[stats + 1] + escFreq - 1) ~/ escFreq;
        if (freq > _kMaxFreq ~/ 3) freq = _kMaxFreq ~/ 3;
        m8[mc + 1] =
            (m8[mc + 1] & _kFlagPrevHigh) + ppmd8HiBitsFlag3(m8[stats]);
        s = mc + 2;
        _copyState(s, stats);
        m8[s + 1] = freq;
        foundState = s;
        _insertNode(stats, units2Indx[n0 - 1]);
        return;
      }

      final n1 = (numStatsNew + 2) >> 1;
      if (n0 != n1) mem32[(mc >> 2) + 1] = _shrinkUnits(stats, n0, n1);
    }

    escFreq &= 0xFFFFFFFF;
    m16[(mc >> 1) + 1] = sumFreq + escFreq - (escFreq >> 1);
    m8[mc + 1] |= _kFlagRescaled;
    foundState = mem32[(mc >> 2) + 1];
  }

  // Ppmd8_MakeEscFreq. Returns the See index, escFreq goes to [escFreqOut].
  int makeEscFreq(int numMasked1) {
    final m8 = mem;
    final mc = minContext;
    final numStats = m8[mc];
    if (numStats != 0xFF) {
      final see = (ns2Indx[numStats + 2] - 3) * 32 +
          (mem16[(mc >> 1) + 1] > 11 * (numStats + 1) ? 1 : 0) +
          2 * (2 * numStats < m8[mem32[(mc >> 2) + 2]] + numMasked1 ? 1 : 0) +
          m8[mc + 1];
      final summ = seeSumm[see];
      final r = summ >> seeShift[see];
      seeSumm[see] = summ - r;
      escFreqOut = r + (r == 0 ? 1 : 0);
      return see;
    }
    escFreqOut = 1;
    return ppmd8DummySee;
  }

  // Ppmd_See_UPDATE
  @pragma('vm:prefer-inline')
  void seeUpdate(int see) {
    final shift = seeShift[see];
    if (shift < ppmdPeriodBits && --seeCount[see] == 0) {
      seeSumm[see] = seeSumm[see] << 1;
      seeCount[see] = 3 << shift;
      seeShift[see] = shift + 1;
    }
  }

  // Ppmd8_NextContext
  @pragma('vm:prefer-inline')
  void _nextContext() {
    final c = successor(foundState);
    if (orderFall == 0 && c >= unitsStart) {
      maxContext = minContext = c;
    } else {
      updateModel();
    }
  }

  // Ppmd8_Update1
  void update1() {
    var s = foundState;
    final m8 = mem;
    final freq = m8[s + 1] + 4;
    mem16[(minContext >> 1) + 1] += 4;
    m8[s + 1] = freq;
    if (freq > m8[s - 6 + 1]) {
      _swapStates(s, s - 6);
      foundState = s -= 6;
      if (freq > _kMaxFreq) _rescale();
    }
    _nextContext();
  }

  // Ppmd8_Update1_0
  void update1_0() {
    final s = foundState;
    final mc = minContext;
    final m8 = mem;
    var freq = m8[s + 1];
    final summFreq = mem16[(mc >> 1) + 1];
    prevSuccess = (2 * freq >= summFreq) ? 1 : 0; // Ppmd8 (>=)
    runLength += prevSuccess;
    mem16[(mc >> 1) + 1] = summFreq + 4;
    freq += 4;
    m8[s + 1] = freq;
    if (freq > _kMaxFreq) _rescale();
    _nextContext();
  }

  // Ppmd8_UpdateBin (inlined in the coders in C; used by both here)
  @pragma('vm:prefer-inline')
  void updateBin(int s) {
    final freq = mem[s + 1];
    final c = successor(s);
    foundState = s;
    prevSuccess = 1;
    runLength++;
    mem[s + 1] = freq + (freq < 196 ? 1 : 0); // Ppmd8 (196)
    if (orderFall == 0 && c >= unitsStart) {
      maxContext = minContext = c;
    } else {
      updateModel();
    }
  }

  // Ppmd8_Update2
  void update2() {
    final s = foundState;
    final freq = mem[s + 1] + 4;
    runLength = initRL;
    mem16[(minContext >> 1) + 1] += 4;
    mem[s + 1] = freq;
    if (freq > _kMaxFreq) _rescale();
    updateModel();
  }

  // Ppmd8_GetBinSumm: index into [binSumm].
  @pragma('vm:prefer-inline')
  int getBinSumm() {
    final mc = minContext;
    final m8 = mem;
    return ns2Indx[m8[mc + 3] - 1] * 64 +
        prevSuccess +
        ((runLength >> 26) & 0x20) +
        ns2BSIndx[m8[mem32[(mc >> 2) + 2]]] +
        m8[mc + 1];
  }
}
