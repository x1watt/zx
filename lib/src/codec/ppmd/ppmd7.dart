// Port of C/Ppmd7.c and C/Ppmd7.h (+ C/Ppmd.h): the PPMdH model shared by
// the 7z range coder variant (ppmd7_dec.dart, ppmd7_enc.dart).
//
// The C code keeps every model record in one memory block and links records
// with 32-bit offsets from Base (CPpmd_Void_Ref and friends, the
// non-PPMD_32BIT mode). Here that block is one Uint8List arena (the offsets
// are indexes into it) with Uint16List and Uint32List views over the same
// buffer, and the exact C layout:
//
//   CPpmd_State (6 bytes, 2-byte aligned):
//     +0 Symbol (u8), +1 Freq (u8), +2 Successor_0 (u16), +4 Successor_1 (u16)
//   CPpmd7_Context (12 bytes, 4-byte aligned):
//     +0 NumStats (u16), +2 SummFreq (u16) or OneState.Symbol/Freq (u8, u8),
//     +4 Stats (u32) or OneState.Successor_0/1 (u16, u16), +8 Suffix (u32)
//   CPpmd7_Node (free block, 12 bytes):
//     +0 Stamp (u16), +2 NU (u16), +4 Next (u32)
//
// The typed views use the host byte order, like the C code does; the values
// never leave the process, so the result is the same on every host.
//
// The range coder fields of the C union CPpmd7::rc live in [Ppmd7] as well.

import 'dart:typed_data';

import '../../io/streams.dart';

// Ppmd7.h
const int ppmd7MinOrder = 2;
const int ppmd7MaxOrder = 64;
const int ppmd7MinMemSize = 1 << 11;
const int ppmd7MaxMemSize = 0xFFFFFFFF - 12 * 3;

/// Ppmd7*_DecodeSymbol results (PPMD7_SYM_END, PPMD7_SYM_ERROR).
const int ppmd7SymEnd = -1;
const int ppmd7SymError = -2;

// Ppmd.h
const int ppmdIntBits = 7;
const int ppmdPeriodBits = 7;
const int ppmdBinScale = 1 << (ppmdIntBits + ppmdPeriodBits);
const int _ppmdN1 = 4;
const int _ppmdN2 = 4;
const int _ppmdN3 = 4;
const int _ppmdN4 = (128 + 3 - 1 * _ppmdN1 - 2 * _ppmdN2 - 3 * _ppmdN3) ~/ 4;
const int ppmdNumIndexes = _ppmdN1 + _ppmdN2 + _ppmdN3 + _ppmdN4;

// Ppmd7.c
const int _kMaxFreq = 124;
const int _kUnitSize = 12;
const List<int> _kExpEscape = [
  25, 14, 9, 7, 5, 5, 4, 4, 4, 3, 3, 3, 2, 2, 2, 2 //
];
const List<int> _kInitBinEsc = [
  0x3CDD, 0x1F3F, 0x59BF, 0x48F3, 0x64A1, 0x5ABC, 0x6632, 0x6051 //
];

/// Index of CPpmd7::DummySee in the See arrays (after See[25][16]).
const int ppmdDummySee = 25 * 16;

/// IByteIn for the range decoder: CByteInBufWrap (CPP/7zip/Common/
/// CWrappers.cpp). After the end of the stream it returns 0 and sets
/// [extra].
final class PpmdByteIn {
  final InStream stream;
  final Uint8List buf;
  int cur = 0;
  int lim = 0;
  int processed = 0;
  bool extra = false;

  PpmdByteIn(this.stream, [int size = 1 << 16]) : buf = Uint8List(size);

  // CByteInBufWrap::Init
  void init() {
    cur = 0;
    lim = 0;
    processed = 0;
    extra = false;
  }

  // CByteInBufWrap::GetProcessed
  int get totalProcessed => processed + cur;

  // Wrap_ReadByte
  @pragma('vm:prefer-inline')
  int readByte() {
    final c = cur;
    if (c != lim) {
      cur = c + 1;
      return buf[c];
    }
    return readByteFromNewBlock();
  }

  // CByteInBufWrap::ReadByteFromNewBlock
  int readByteFromNewBlock() {
    if (!extra) {
      final avail = stream.read(buf, 0, buf.length);
      processed += cur;
      cur = 0;
      lim = avail;
      if (avail != 0) {
        cur = 1;
        return buf[0];
      }
    }
    extra = true;
    return 0;
  }
}

/// IByteOut for the range encoder: CByteOutBufWrap (CPP/7zip/Common/
/// CWrappers.cpp).
final class PpmdByteOut {
  final OutStream stream;
  final Uint8List buf;
  int cur = 0;
  int processed = 0;

  PpmdByteOut(this.stream, [int size = 1 << 16]) : buf = Uint8List(size);

  // CByteOutBufWrap::Init
  void init() {
    cur = 0;
    processed = 0;
  }

  // CByteOutBufWrap::GetProcessed
  int get totalProcessed => processed + cur;

  // Wrap_WriteByte
  @pragma('vm:prefer-inline')
  void writeByte(int b) {
    buf[cur++] = b;
    if (cur == buf.length) flushBuf();
  }

  // CByteOutBufWrap::Flush (without the stream flush)
  void flushBuf() {
    if (cur != 0) {
      stream.write(buf, 0, cur);
      processed += cur;
      cur = 0;
    }
  }
}

/// CPpmd7: the PPMdH model plus the range coder state.
final class Ppmd7 {
  // Model state. Every "pointer" is an offset into [mem].
  int minContext = 0;
  int maxContext = 0;
  int foundState = 0;
  int orderFall = 0;
  int initEsc = 0;
  int prevSuccess = 0;
  int maxOrder = 0;
  int hiBitsFlag = 0;
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

  // rc.dec / rc.enc (CPpmd7_RangeDec, CPpmd7z_RangeEnc).
  int rcRange = 0;
  int rcCode = 0;
  int rcLow = 0;
  int rcCache = 0;
  int rcCacheSize = 0;
  PpmdByteIn? rcIn;
  PpmdByteOut? rcOut;

  final Uint8List indx2Units = Uint8List(ppmdNumIndexes + 2);
  final Uint8List units2Indx = Uint8List(128);
  final Uint32List freeList = Uint32List(ppmdNumIndexes);
  final Uint8List ns2BSIndx = Uint8List(256);
  final Uint8List ns2Indx = Uint8List(256);
  final Uint8List expEscape = Uint8List(16);

  /// See[25][16] followed by DummySee (index [ppmdDummySee]).
  final Uint16List seeSumm = Uint16List(25 * 16 + 1);
  final Uint8List seeShift = Uint8List(25 * 16 + 1);
  final Uint8List seeCount = Uint8List(25 * 16 + 1);

  /// BinSumm[128][64].
  final Uint16List binSumm = Uint16List(128 * 64);

  /// The charMask scratch array of the symbol coders (on the stack in C).
  final Uint8List charMask = Uint8List(256);
  late final Uint64List _charMask64 = charMask.buffer.asUint64List(0, 32);

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

  /// The ps[] array of Ppmd7_CreateSuccessors.
  final Uint32List _ps = Uint32List(ppmd7MaxOrder);

  /// Second result of [makeEscFreq] (the escFreq out parameter).
  int escFreqOut = 0;

  // Ppmd7_Construct
  Ppmd7() {
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
    for (; i < 3; i++) {
      ns2Indx[i] = i;
    }
    for (var m = i, k = 1; i < 256; i++) {
      ns2Indx[i] = m;
      if (--k == 0) k = (++m) - 2;
    }

    expEscape.setAll(0, _kExpEscape);
  }

  // Ppmd7_WasAllocated
  bool get wasAllocated => mem.isNotEmpty;

  // Ppmd7_Free
  void free() {
    size = 0;
    mem = Uint8List(0);
    mem16 = Uint16List(0);
    mem32 = Uint32List(0);
  }

  // Ppmd7_Alloc
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

  // Ppmd7_InsertNode
  @pragma('vm:prefer-inline')
  void _insertNode(int node, int indx) {
    mem32[node >> 2] = freeList[indx];
    freeList[indx] = node;
  }

  // Ppmd7_RemoveNode
  @pragma('vm:prefer-inline')
  int _removeNode(int indx) {
    final node = freeList[indx];
    freeList[indx] = mem32[node >> 2];
    return node;
  }

  // Ppmd7_SplitBlock
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

  // Ppmd7_GlueFreeBlocks
  void _glueFreeBlocks() {
    final m16 = mem16;
    final m32 = mem32;
    var n = 0;

    glueCount = 255;

    // We set guard NODE at LoUnit.
    if (loUnit != hiUnit) m16[loUnit >> 1] = 1;

    // Create list of free blocks.
    for (var i = 0; i < ppmdNumIndexes; i++) {
      final nu = indx2Units[i];
      var next = freeList[i];
      freeList[i] = 0;
      while (next != 0) {
        final tmp = next;
        next = m32[tmp >> 2];
        m16[tmp >> 1] = 0; // Stamp = EMPTY_NODE
        m16[(tmp >> 1) + 1] = nu; // NU
        m32[(tmp >> 2) + 1] = n; // Next
        n = tmp;
      }
    }

    var head = n;
    // Glue free blocks. (prev) is the offset of the u32 link to update, or
    // -1 for (head).
    var prev = -1;
    while (n != 0) {
      final node = n;
      var nu = m16[(node >> 1) + 1];
      n = m32[(node >> 2) + 1];
      if (nu == 0) {
        if (prev < 0) {
          head = n;
        } else {
          m32[prev >> 2] = n;
        }
        continue;
      }
      prev = node + 4;
      for (;;) {
        final node2 = node + nu * _kUnitSize;
        nu += m16[(node2 >> 1) + 1];
        if (m16[node2 >> 1] != 0 || nu >= 0x10000) break;
        m16[(node >> 1) + 1] = nu;
        m16[(node2 >> 1) + 1] = 0;
      }
    }

    // Fill lists of free blocks.
    for (n = head; n != 0;) {
      var node = n;
      var nu = m16[(node >> 1) + 1];
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

  // Ppmd7_AllocUnitsRare. Returns 0 for NULL.
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
        if (us - text > numBytes) {
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

  // Ppmd7_AllocUnits. Returns 0 for NULL.
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

  // SUCCESSOR (Ppmd_GET_SUCCESSOR) of the state at [s].
  @pragma('vm:prefer-inline')
  int successor(int s) {
    final i = (s >> 1) + 1;
    return mem16[i] | (mem16[i + 1] << 16);
  }

  // SetSuccessor (Ppmd_SET_SUCCESSOR)
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

  // SWAP_STATES(s): swaps s[0] and s[-1].
  @pragma('vm:prefer-inline')
  void _swapStates(int s) {
    final m16 = mem16;
    final a = s >> 1;
    final b = a - 3;
    final t0 = m16[a], t1 = m16[a + 1], t2 = m16[a + 2];
    m16[a] = m16[b];
    m16[a + 1] = m16[b + 1];
    m16[a + 2] = m16[b + 2];
    m16[b] = t0;
    m16[b + 1] = t1;
    m16[b + 2] = t2;
  }

  // Ppmd7_RestartModel
  void _restartModel() {
    freeList.fillRange(0, ppmdNumIndexes, 0);

    text = alignOffset;
    hiUnit = text + size;
    loUnit = unitsStart =
        hiUnit - size ~/ 8 ~/ _kUnitSize * 7 * _kUnitSize;
    glueCount = 0;

    orderFall = maxOrder;
    runLength = initRL = -((maxOrder < 12) ? maxOrder : 12) - 1;
    prevSuccess = 0;

    {
      final m8 = mem;
      final m16 = mem16;
      final mc = (hiUnit -= _kUnitSize); // AllocContext(p)
      var s = loUnit; // Ppmd7_AllocUnits(p, PPMD_NUM_INDEXES - 1)

      loUnit += (256 ~/ 2) * _kUnitSize;
      maxContext = minContext = mc;
      foundState = s;

      m16[mc >> 1] = 256; // NumStats
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
    for (var i = 0; i < 128; i++) {
      for (var k = 0; k < 8; k++) {
        final dest = i * 64 + k;
        final val = ppmdBinScale - _kInitBinEsc[k] ~/ (i + 2);
        for (var m = 0; m < 64; m += 8) {
          bs[dest + m] = val;
        }
      }
    }

    for (var i = 0; i < 25; i++) {
      final summ = ((5 * i + 10) << (ppmdPeriodBits - 4));
      for (var k = 0; k < 16; k++) {
        final s = i * 16 + k;
        seeSumm[s] = summ;
        seeShift[s] = ppmdPeriodBits - 4;
        seeCount[s] = 4;
      }
    }

    seeSumm[ppmdDummySee] = 0; // unused
    seeShift[ppmdDummySee] = ppmdPeriodBits;
    seeCount[ppmdDummySee] = 64; // unused
  }

  // Ppmd7_Init
  void init(int maxOrder) {
    this.maxOrder = maxOrder;
    _restartModel();
  }

  // Ppmd7_CreateSuccessors. Returns 0 for NULL.
  int _createSuccessors() {
    final m8 = mem;
    final m16 = mem16;
    final m32 = mem32;
    final ps = _ps;
    var c = minContext;
    var upBranch = successor(foundState);
    var numPs = 0;

    if (orderFall != 0) ps[numPs++] = foundState;

    while (m32[(c >> 2) + 2] != 0) {
      int s;
      c = m32[(c >> 2) + 2];
      if (m16[c >> 1] != 1) {
        final sym = m8[foundState];
        for (s = m32[(c >> 2) + 1]; m8[s] != sym; s += 6) {}
      } else {
        s = c + 2;
      }
      final succ = successor(s);
      if (succ != upBranch) {
        // (c) is real record Context here.
        c = succ;
        if (numPs == 0) {
          // (c) is real record MAX Order Context here.
          return c;
        }
        break;
      }
      ps[numPs++] = s;
    }

    final newSym = m8[upBranch];
    upBranch++;

    int newFreq;
    if (m16[c >> 1] == 1) {
      newFreq = m8[c + 3];
    } else {
      int s;
      for (s = m32[(c >> 2) + 1]; m8[s] != newSym; s += 6) {}
      final cf = m8[s + 1] - 1;
      final s0 = m16[(c >> 1) + 1] - m16[c >> 1] - cf;
      newFreq = (1 +
              ((2 * cf <= s0)
                  ? (5 * cf > s0 ? 1 : 0)
                  : (2 * cf + s0 - 1) ~/ (2 * s0) + 1)) &
          0xFF;
    }

    // Create new single-symbol contexts from low order to high order.
    do {
      int c1;
      if (hiUnit != loUnit) {
        c1 = (hiUnit -= _kUnitSize);
      } else if (freeList[0] != 0) {
        c1 = _removeNode(0);
      } else {
        c1 = _allocUnitsRare(0);
        if (c1 == 0) return 0;
      }
      m16[c1 >> 1] = 1; // NumStats
      m8[c1 + 2] = newSym;
      m8[c1 + 3] = newFreq;
      m16[(c1 >> 1) + 2] = upBranch;
      m16[(c1 >> 1) + 3] = upBranch >> 16;
      m32[(c1 >> 2) + 2] = c; // Suffix
      setSuccessor(ps[--numPs], c1);
      c = c1;
    } while (numPs != 0);

    return c;
  }

  // Ppmd7_UpdateModel
  void updateModel() {
    final m8 = mem;
    final m16 = mem16;
    final m32 = mem32;
    final fs = foundState;
    final fSymbol = m8[fs];
    final fFreq = m8[fs + 1];

    if (fFreq < _kMaxFreq ~/ 4 && m32[(minContext >> 2) + 2] != 0) {
      // Update Freqs in Suffix Context.
      final c = m32[(minContext >> 2) + 2];
      if (m16[c >> 1] == 1) {
        final s = c + 2;
        if (m8[s + 1] < 32) m8[s + 1]++;
      } else {
        var s = m32[(c >> 2) + 1];
        if (m8[s] != fSymbol) {
          do {
            s += 6;
          } while (m8[s] != fSymbol);
          if (m8[s + 1] >= m8[s - 6 + 1]) {
            _swapStates(s);
            s -= 6;
          }
        }
        if (m8[s + 1] < _kMaxFreq - 9) {
          m8[s + 1] += 2;
          m16[(c >> 1) + 1] += 2;
        }
      }
    }

    if (orderFall == 0) {
      // MAX ORDER context. (FoundState.Successor) is RAW-Successor.
      maxContext = minContext = _createSuccessors();
      if (minContext == 0) {
        _restartModel();
        return;
      }
      setSuccessor(foundState, minContext);
      return;
    }

    // NON-MAX ORDER context.
    int maxSuccessor;
    {
      var t = text;
      m8[t++] = fSymbol;
      text = t;
      if (t >= unitsStart) {
        _restartModel();
        return;
      }
      maxSuccessor = t;
    }

    var minSuccessor = successor(fs);

    if (minSuccessor != 0) {
      // There is Successor for FoundState in MinContext.
      if (minSuccessor <= maxSuccessor) {
        // minSuccessor is RAW-Successor. So we create real context records.
        final cs = _createSuccessors();
        if (cs == 0) {
          _restartModel();
          return;
        }
        minSuccessor = cs;
      }
      // minSuccessor now is real Context pointer to existing (Order+1)
      // context.
      if (--orderFall == 0) {
        maxSuccessor = minSuccessor;
        if (maxContext != minContext) text--;
      }
    } else {
      // FoundState has NULL-Successor here (root 0-order context only).
      setSuccessor(fs, maxSuccessor);
      minSuccessor = minContext;
    }

    final mc = minContext;
    var c = maxContext;

    maxContext = minContext = minSuccessor;

    if (c == mc) return;

    // s0 : is pure Escape Freq
    final ns = m16[mc >> 1];
    final s0 = m16[(mc >> 1) + 1] - ns - (m8[fs + 1] - 1);
    final fsFreq = m8[fs + 1];

    do {
      int sum;
      final ns1 = m16[c >> 1];
      if (ns1 != 1) {
        if ((ns1 & 1) == 0) {
          // Expand for one UNIT.
          final oldNU = ns1 >> 1;
          final i = units2Indx[oldNU - 1];
          if (i != units2Indx[oldNU]) {
            final ptr = _allocUnits(i + 1);
            if (ptr == 0) {
              _restartModel();
              return;
            }
            final oldPtr = m32[(c >> 2) + 1];
            _mem12Cpy(ptr, oldPtr, oldNU);
            _insertNode(oldPtr, i);
            m32[(c >> 2) + 1] = ptr;
          }
        }
        sum = m16[(c >> 1) + 1];
        sum += ((2 * ns1 < ns) ? 1 : 0) +
            2 * (((4 * ns1 <= ns) && (sum <= 8 * ns1)) ? 1 : 0);
      } else {
        // Instead of One-symbol context we create 2-symbol context.
        final s = _allocUnits(0);
        if (s == 0) {
          _restartModel();
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
        sum = freq + initEsc + (ns > 3 ? 1 : 0);
      }

      {
        final s = m32[(c >> 2) + 1] + ns1 * 6;
        var cf = 2 * (sum + 6) * fsFreq;
        final sf = s0 + sum;
        m8[s] = fSymbol;
        m16[c >> 1] = ns1 + 1;
        setSuccessor(s, maxSuccessor);

        if (cf < 6 * sf) {
          cf = 1 + (cf > sf ? 1 : 0) + (cf >= 4 * sf ? 1 : 0);
          sum += 3;
        } else {
          cf = 4 +
              (cf >= 9 * sf ? 1 : 0) +
              (cf >= 12 * sf ? 1 : 0) +
              (cf >= 15 * sf ? 1 : 0);
          sum += cf;
        }
        m16[(c >> 1) + 1] = sum;
        m8[s + 1] = cf;
      }
      c = m32[(c >> 2) + 2];
    } while (c != mc);
  }

  // Ppmd7_Rescale
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

    // adder = 0 allows removing symbols from MAX order contexts.
    final adder = (orderFall != 0) ? 1 : 0;

    sumFreq = (sumFreq + 4 + adder) >> 1;
    var i = m16[mc >> 1] - 1;
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

      escFreq += i;
      final numStats = m16[mc >> 1];
      final numStatsNew = numStats - i;
      m16[mc >> 1] = numStatsNew;
      final n0 = (numStats + 1) >> 1;

      if (numStatsNew == 1) {
        // Create Single-Symbol context.
        var freq = m8[stats + 1];
        do {
          escFreq >>= 1;
          freq = (freq + 1) >> 1;
        } while (escFreq > 1);

        s = mc + 2;
        _copyState(s, stats);
        m8[s + 1] = freq;
        foundState = s;
        _insertNode(stats, units2Indx[n0 - 1]);
        return;
      }

      final n1 = (numStatsNew + 1) >> 1;
      if (n0 != n1) {
        final i0 = units2Indx[n0 - 1];
        final i1 = units2Indx[n1 - 1];
        if (i0 != i1) {
          if (freeList[i1] != 0) {
            final ptr = _removeNode(i1);
            mem32[(mc >> 2) + 1] = ptr;
            _mem12Cpy(ptr, stats, n1);
            _insertNode(stats, i0);
          } else {
            _splitBlock(stats, i0, i1);
          }
        }
      }
    }
    m16[(mc >> 1) + 1] = sumFreq + escFreq - (escFreq >> 1);
    foundState = mem32[(mc >> 2) + 1];
  }

  // Ppmd7_MakeEscFreq. Returns the See index, escFreq goes to [escFreqOut].
  int makeEscFreq(int numMasked) {
    final mc = minContext;
    final numStats = mem16[mc >> 1];
    if (numStats != 256) {
      final nonMasked = numStats - numMasked;
      final suffix = mem32[(mc >> 2) + 2];
      final see = ns2Indx[nonMasked - 1] * 16 +
          (nonMasked < ((mem16[suffix >> 1] - numStats) & 0xFFFFFFFF) ? 1 : 0) +
          2 * (mem16[(mc >> 1) + 1] < 11 * numStats ? 1 : 0) +
          4 * (numMasked > nonMasked ? 1 : 0) +
          hiBitsFlag;
      final summ = seeSumm[see];
      final r = summ >> seeShift[see];
      seeSumm[see] = summ - r;
      escFreqOut = r + (r == 0 ? 1 : 0);
      return see;
    }
    escFreqOut = 1;
    return ppmdDummySee;
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

  // Ppmd7_NextContext
  @pragma('vm:prefer-inline')
  void _nextContext() {
    final c = successor(foundState);
    if (orderFall == 0 && c > text) {
      maxContext = minContext = c;
    } else {
      updateModel();
    }
  }

  // Ppmd7_Update1
  void update1() {
    var s = foundState;
    final m8 = mem;
    final freq = m8[s + 1] + 4;
    mem16[(minContext >> 1) + 1] += 4;
    m8[s + 1] = freq;
    if (freq > m8[s - 6 + 1]) {
      _swapStates(s);
      foundState = s -= 6;
      if (freq > _kMaxFreq) _rescale();
    }
    _nextContext();
  }

  // Ppmd7_Update1_0
  void update1_0() {
    final s = foundState;
    final mc = minContext;
    final m8 = mem;
    var freq = m8[s + 1];
    final summFreq = mem16[(mc >> 1) + 1];
    prevSuccess = (2 * freq > summFreq) ? 1 : 0;
    runLength += prevSuccess;
    mem16[(mc >> 1) + 1] = summFreq + 4;
    freq += 4;
    m8[s + 1] = freq;
    if (freq > _kMaxFreq) _rescale();
    _nextContext();
  }

  // Ppmd7_UpdateBin (inlined in the coders in C; used by both here)
  @pragma('vm:prefer-inline')
  void updateBin(int s) {
    final freq = mem[s + 1];
    final c = successor(s);
    foundState = s;
    prevSuccess = 1;
    runLength++;
    mem[s + 1] = freq + (freq < 128 ? 1 : 0);
    if (orderFall == 0 && c > text) {
      maxContext = minContext = c;
    } else {
      updateModel();
    }
  }

  // Ppmd7_Update2
  void update2() {
    final s = foundState;
    final freq = mem[s + 1] + 4;
    runLength = initRL;
    mem16[(minContext >> 1) + 1] += 4;
    mem[s + 1] = freq;
    if (freq > _kMaxFreq) _rescale();
    updateModel();
  }

  // Ppmd7_GetBinSumm: index into [binSumm]; also sets [hiBitsFlag].
  @pragma('vm:prefer-inline')
  int getBinSumm() {
    final mc = minContext;
    final m8 = mem;
    final suffix = mem32[(mc >> 2) + 2];
    return (m8[mc + 3] - 1) * 64 +
        prevSuccess +
        ((runLength >> 26) & 0x20) +
        ns2BSIndx[mem16[suffix >> 1] - 1] +
        (((m8[mc + 2] + 0xC0) >> (8 - 4)) & (1 << 4)) +
        (hiBitsFlag = ((m8[foundState] + 0xC0) >> (8 - 3)) & (1 << 3));
  }
}

// PPMD7_HiBitsFlag_3
@pragma('vm:prefer-inline')
int ppmd7HiBitsFlag3(int sym) => ((sym + 0xC0) >> (8 - 3)) & (1 << 3);
