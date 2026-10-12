// zxsfx decoder: the PPMd var.H model (Dmitry Shkarin), port of the model
// part of lib/src/codec/ppmd/ppmd7.dart, a port of C/Ppmd7.c of the LZMA
// SDK (Igor Pavlov, public domain). Offsets into one arena replace the
// pointers; the layout of the records is the one of the C code:
//
//   CPpmd_State (6 bytes): +0 Symbol, +1 Freq, +2 Successor_0 (u16),
//     +4 Successor_1 (u16)
//   CPpmd7_Context (12 bytes): +0 NumStats (u16), +2 SummFreq (u16) or
//     OneState.Symbol/Freq, +4 Stats (u32) or OneState.Successor, +8
//     Suffix (u32)
//   CPpmd7_Node (12 bytes): +0 Stamp (u16), +2 NU (u16), +4 Next (u32)

#include "zc_ppmd.h"

#define K_MAX_FREQ 124
#define K_UNIT_SIZE 12

static const u8 kExpEscape[16] = {25, 14, 9, 7, 5, 5, 4, 4,
                                  4,  3,  3, 3, 2, 2, 2, 2};
static const u16 kInitBinEsc[8] = {0x3CDD, 0x1F3F, 0x59BF, 0x48F3,
                                   0x64A1, 0x5ABC, 0x6632, 0x6051};

// Ppmd7_Construct
void ppmd7_construct(Ppmd7 *p) {
  i64 k = 0;
  for (i64 i = 0; i < PPMD_NUM_INDEXES; i++) {
    i64 step = (i >= 12 ? 4 : (i >> 2) + 1);
    do {
      p->units2Indx[k++] = (u8)i;
    } while (--step != 0);
    p->indx2Units[i] = (u8)k;
  }
  p->ns2BSIndx[0] = (0 << 1);
  p->ns2BSIndx[1] = (1 << 1);
  for (i64 i = 2; i < 11; i++) p->ns2BSIndx[i] = (2 << 1);
  for (i64 i = 11; i < 256; i++) p->ns2BSIndx[i] = (3 << 1);
  i64 i = 0;
  for (; i < 3; i++) p->ns2Indx[i] = (u8)i;
  for (i64 m = i, k2 = 1; i < 256; i++) {
    p->ns2Indx[i] = (u8)m;
    if (--k2 == 0) k2 = (++m) - 2;
  }
  for (i64 j = 0; j < 16; j++) p->expEscape[j] = kExpEscape[j];
}

// Ppmd7_Alloc
void ppmd7_alloc(Ppmd7 *p, i64 size) {
  p->alignOffset = (4 - size) & 3;
  i64 n = p->alignOffset + size;
  u8 *m = ZNEW(u8, (n + 3) & ~(i64)3);
  p->mem = m;
  p->mem16 = (u16a *)m;
  p->mem32 = (u32a *)m;
  p->size = size;
}

// Ppmd7_InsertNode
static void insertNode(Ppmd7 *p, i64 node, i64 indx) {
  p->mem32[node >> 2] = p->freeList[indx];
  p->freeList[indx] = (u32)node;
}

// Ppmd7_RemoveNode
static i64 removeNode(Ppmd7 *p, i64 indx) {
  i64 node = p->freeList[indx];
  p->freeList[indx] = p->mem32[node >> 2];
  return node;
}

// Ppmd7_SplitBlock
static void splitBlock(Ppmd7 *p, i64 ptr, i64 oldIndx, i64 newIndx) {
  i64 nu = (i64)p->indx2Units[oldIndx] - p->indx2Units[newIndx];
  ptr += (i64)p->indx2Units[newIndx] * K_UNIT_SIZE;
  i64 i = p->units2Indx[nu - 1];
  if (p->indx2Units[i] != nu) {
    i64 k = p->indx2Units[--i];
    insertNode(p, ptr + k * K_UNIT_SIZE, nu - k - 1);
  }
  insertNode(p, ptr, i);
}

// Ppmd7_GlueFreeBlocks
static void glueFreeBlocks(Ppmd7 *p) {
  u16a *m16 = p->mem16;
  u32a *m32 = p->mem32;
  i64 n = 0;
  p->glueCount = 255;
  // We set guard NODE at LoUnit.
  if (p->loUnit != p->hiUnit) m16[p->loUnit >> 1] = 1;
  // Create list of free blocks.
  for (i64 i = 0; i < PPMD_NUM_INDEXES; i++) {
    i64 nu = p->indx2Units[i];
    i64 next = p->freeList[i];
    p->freeList[i] = 0;
    while (next != 0) {
      i64 tmp = next;
      next = m32[tmp >> 2];
      m16[tmp >> 1] = 0;             // Stamp = EMPTY_NODE
      m16[(tmp >> 1) + 1] = (u16)nu; // NU
      m32[(tmp >> 2) + 1] = (u32)n;  // Next
      n = tmp;
    }
  }
  i64 head = n;
  // Glue free blocks. (prev) is the offset of the u32 link to update, or
  // -1 for (head).
  i64 prev = -1;
  while (n != 0) {
    i64 node = n;
    i64 nu = m16[(node >> 1) + 1];
    n = m32[(node >> 2) + 1];
    if (nu == 0) {
      if (prev < 0) {
        head = n;
      } else {
        m32[prev >> 2] = (u32)n;
      }
      continue;
    }
    prev = node + 4;
    for (;;) {
      i64 node2 = node + nu * K_UNIT_SIZE;
      nu += m16[(node2 >> 1) + 1];
      if (m16[node2 >> 1] != 0 || nu >= 0x10000) break;
      m16[(node >> 1) + 1] = (u16)nu;
      m16[(node2 >> 1) + 1] = 0;
    }
  }
  // Fill lists of free blocks.
  for (n = head; n != 0;) {
    i64 node = n;
    i64 nu = m16[(node >> 1) + 1];
    n = m32[(node >> 2) + 1];
    if (nu == 0) continue;
    for (; nu > 128; nu -= 128, node += 128 * K_UNIT_SIZE) {
      insertNode(p, node, PPMD_NUM_INDEXES - 1);
    }
    i64 i = p->units2Indx[nu - 1];
    if (p->indx2Units[i] != nu) {
      i64 k = p->indx2Units[--i];
      insertNode(p, node + k * K_UNIT_SIZE, nu - k - 1);
    }
    insertNode(p, node, i);
  }
}

// Ppmd7_AllocUnitsRare. Returns 0 for NULL.
static i64 allocUnitsRare(Ppmd7 *p, i64 indx) {
  if (p->glueCount == 0) {
    glueFreeBlocks(p);
    if (p->freeList[indx] != 0) return removeNode(p, indx);
  }
  i64 i = indx;
  do {
    if (++i == PPMD_NUM_INDEXES) {
      i64 numBytes = (i64)p->indx2Units[indx] * K_UNIT_SIZE;
      i64 us = p->unitsStart;
      p->glueCount = (p->glueCount - 1) & 0xFFFFFFFF;
      if (us - p->text > numBytes) {
        p->unitsStart = us - numBytes;
        return p->unitsStart;
      }
      return 0;
    }
  } while (p->freeList[i] == 0);
  i64 block = removeNode(p, i);
  splitBlock(p, block, i, indx);
  return block;
}

// Ppmd7_AllocUnits. Returns 0 for NULL.
static i64 allocUnits(Ppmd7 *p, i64 indx) {
  if (p->freeList[indx] != 0) return removeNode(p, indx);
  i64 numBytes = (i64)p->indx2Units[indx] * K_UNIT_SIZE;
  i64 lo = p->loUnit;
  if (p->hiUnit - lo >= numBytes) {
    p->loUnit = lo + numBytes;
    return lo;
  }
  return allocUnitsRare(p, indx);
}

// MEM_12_CPY
static void mem12Cpy(Ppmd7 *p, i64 dest, i64 src, i64 num) {
  memmove(p->mem + dest, p->mem + src, (size_t)(num * 12));
}

// SetSuccessor
static void setSuccessor(Ppmd7 *p, i64 s, i64 v) {
  i64 i = (s >> 1) + 1;
  p->mem16[i] = (u16)v;
  p->mem16[i + 1] = (u16)(v >> 16);
}

// *dest = *src for CPpmd_State.
static void copyState(Ppmd7 *p, i64 dest, i64 src) {
  u16a *m16 = p->mem16;
  i64 d = dest >> 1;
  i64 s = src >> 1;
  m16[d] = m16[s];
  m16[d + 1] = m16[s + 1];
  m16[d + 2] = m16[s + 2];
}

// SWAP_STATES(s): swaps s[0] and s[-1].
static void swapStates(Ppmd7 *p, i64 s) {
  u16a *m16 = p->mem16;
  i64 a = s >> 1;
  i64 b = a - 3;
  u16 t0 = m16[a], t1 = m16[a + 1], t2 = m16[a + 2];
  m16[a] = m16[b];
  m16[a + 1] = m16[b + 1];
  m16[a + 2] = m16[b + 2];
  m16[b] = t0;
  m16[b + 1] = t1;
  m16[b + 2] = t2;
}

// Ppmd7_RestartModel
static void restartModel(Ppmd7 *p) {
  for (i64 i = 0; i < PPMD_NUM_INDEXES; i++) p->freeList[i] = 0;
  p->text = p->alignOffset;
  p->hiUnit = p->text + p->size;
  p->loUnit = p->unitsStart =
      p->hiUnit - p->size / 8 / K_UNIT_SIZE * 7 * K_UNIT_SIZE;
  p->glueCount = 0;
  p->orderFall = p->maxOrder;
  p->runLength = p->initRL = -((p->maxOrder < 12) ? p->maxOrder : 12) - 1;
  p->prevSuccess = 0;
  {
    u8 *m8 = p->mem;
    u16a *m16 = p->mem16;
    i64 mc = (p->hiUnit -= K_UNIT_SIZE); // AllocContext(p)
    i64 s = p->loUnit; // Ppmd7_AllocUnits(p, PPMD_NUM_INDEXES - 1)
    p->loUnit += (256 / 2) * K_UNIT_SIZE;
    p->maxContext = p->minContext = mc;
    p->foundState = s;
    m16[mc >> 1] = 256;              // NumStats
    m16[(mc >> 1) + 1] = 256 + 1;    // SummFreq
    p->mem32[(mc >> 2) + 1] = (u32)s; // Stats
    p->mem32[(mc >> 2) + 2] = 0;     // Suffix
    for (i64 i = 0; i < 256; i++, s += 6) {
      m8[s] = (u8)i;
      m8[s + 1] = 1;
      m16[(s >> 1) + 1] = 0;
      m16[(s >> 1) + 2] = 0;
    }
  }
  for (i64 i = 0; i < 128; i++) {
    for (i64 k = 0; k < 8; k++) {
      i64 dest = i * 64 + k;
      i64 val = PPMD_BIN_SCALE - kInitBinEsc[k] / (i + 2);
      for (i64 m = 0; m < 64; m += 8) p->binSumm[dest + m] = (u16)val;
    }
  }
  for (i64 i = 0; i < 25; i++) {
    i64 summ = ((5 * i + 10) << (PPMD_PERIOD_BITS - 4));
    for (i64 k = 0; k < 16; k++) {
      i64 s = i * 16 + k;
      p->seeSumm[s] = (u16)summ;
      p->seeShift[s] = PPMD_PERIOD_BITS - 4;
      p->seeCount[s] = 4;
    }
  }
  p->seeSumm[PPMD_DUMMY_SEE] = 0; // unused
  p->seeShift[PPMD_DUMMY_SEE] = PPMD_PERIOD_BITS;
  p->seeCount[PPMD_DUMMY_SEE] = 64; // unused
}

// Ppmd7_Init
void ppmd7_init(Ppmd7 *p, i64 maxOrder) {
  p->maxOrder = maxOrder;
  restartModel(p);
}

// Ppmd7_CreateSuccessors. Returns 0 for NULL.
static i64 createSuccessors(Ppmd7 *p) {
  u8 *m8 = p->mem;
  u16a *m16 = p->mem16;
  u32a *m32 = p->mem32;
  u32 *ps = p->ps;
  i64 c = p->minContext;
  i64 upBranch = ppmd7_successor(p, p->foundState);
  i64 numPs = 0;
  if (p->orderFall != 0) ps[numPs++] = (u32)p->foundState;
  while (m32[(c >> 2) + 2] != 0) {
    i64 s;
    c = m32[(c >> 2) + 2];
    if (m16[c >> 1] != 1) {
      i64 sym = m8[p->foundState];
      for (s = m32[(c >> 2) + 1]; m8[s] != sym; s += 6) {
      }
    } else {
      s = c + 2;
    }
    i64 succ = ppmd7_successor(p, s);
    if (succ != upBranch) {
      // (c) is real record Context here.
      c = succ;
      if (numPs == 0) {
        // (c) is real record MAX Order Context here.
        return c;
      }
      break;
    }
    ps[numPs++] = (u32)s;
  }
  i64 newSym = m8[upBranch];
  upBranch++;
  i64 newFreq;
  if (m16[c >> 1] == 1) {
    newFreq = m8[c + 3];
  } else {
    i64 s;
    for (s = m32[(c >> 2) + 1]; m8[s] != newSym; s += 6) {
    }
    i64 cf = (i64)m8[s + 1] - 1;
    i64 s0 = (i64)m16[(c >> 1) + 1] - m16[c >> 1] - cf;
    newFreq = (1 + ((2 * cf <= s0) ? (5 * cf > s0 ? 1 : 0)
                                   : (2 * cf + s0 - 1) / (2 * s0) + 1)) &
              0xFF;
  }
  // Create new single-symbol contexts from low order to high order.
  do {
    i64 c1;
    if (p->hiUnit != p->loUnit) {
      c1 = (p->hiUnit -= K_UNIT_SIZE);
    } else if (p->freeList[0] != 0) {
      c1 = removeNode(p, 0);
    } else {
      c1 = allocUnitsRare(p, 0);
      if (c1 == 0) return 0;
    }
    m16[c1 >> 1] = 1; // NumStats
    m8[c1 + 2] = (u8)newSym;
    m8[c1 + 3] = (u8)newFreq;
    m16[(c1 >> 1) + 2] = (u16)upBranch;
    m16[(c1 >> 1) + 3] = (u16)(upBranch >> 16);
    m32[(c1 >> 2) + 2] = (u32)c; // Suffix
    setSuccessor(p, ps[--numPs], c1);
    c = c1;
  } while (numPs != 0);
  return c;
}

// Ppmd7_UpdateModel
static void updateModel(Ppmd7 *p) {
  u8 *m8 = p->mem;
  u16a *m16 = p->mem16;
  u32a *m32 = p->mem32;
  i64 fs = p->foundState;
  i64 fSymbol = m8[fs];
  i64 fFreq = m8[fs + 1];

  if (fFreq < K_MAX_FREQ / 4 && m32[(p->minContext >> 2) + 2] != 0) {
    // Update Freqs in Suffix Context.
    i64 c = m32[(p->minContext >> 2) + 2];
    if (m16[c >> 1] == 1) {
      i64 s = c + 2;
      if (m8[s + 1] < 32) m8[s + 1]++;
    } else {
      i64 s = m32[(c >> 2) + 1];
      if (m8[s] != fSymbol) {
        do {
          s += 6;
        } while (m8[s] != fSymbol);
        if (m8[s + 1] >= m8[s - 6 + 1]) {
          swapStates(p, s);
          s -= 6;
        }
      }
      if (m8[s + 1] < K_MAX_FREQ - 9) {
        m8[s + 1] += 2;
        m16[(c >> 1) + 1] += 2;
      }
    }
  }

  if (p->orderFall == 0) {
    // MAX ORDER context. (FoundState.Successor) is RAW-Successor.
    p->maxContext = p->minContext = createSuccessors(p);
    if (p->minContext == 0) {
      restartModel(p);
      return;
    }
    setSuccessor(p, p->foundState, p->minContext);
    return;
  }

  // NON-MAX ORDER context.
  i64 maxSuccessor;
  {
    i64 t = p->text;
    m8[t++] = (u8)fSymbol;
    p->text = t;
    if (t >= p->unitsStart) {
      restartModel(p);
      return;
    }
    maxSuccessor = t;
  }

  i64 minSuccessor = ppmd7_successor(p, fs);

  if (minSuccessor != 0) {
    // There is Successor for FoundState in MinContext.
    if (minSuccessor <= maxSuccessor) {
      // minSuccessor is RAW-Successor. So we create real context records.
      i64 cs = createSuccessors(p);
      if (cs == 0) {
        restartModel(p);
        return;
      }
      minSuccessor = cs;
    }
    // minSuccessor now is real Context pointer to existing (Order+1)
    // context.
    if (--p->orderFall == 0) {
      maxSuccessor = minSuccessor;
      if (p->maxContext != p->minContext) p->text--;
    }
  } else {
    // FoundState has NULL-Successor here (root 0-order context only).
    setSuccessor(p, fs, maxSuccessor);
    minSuccessor = p->minContext;
  }

  i64 mc = p->minContext;
  i64 c = p->maxContext;

  p->maxContext = p->minContext = minSuccessor;

  if (c == mc) return;

  // s0 : is pure Escape Freq
  i64 ns = m16[mc >> 1];
  i64 s0 = (i64)m16[(mc >> 1) + 1] - ns - ((i64)m8[fs + 1] - 1);
  i64 fsFreq = m8[fs + 1];

  do {
    i64 sum;
    i64 ns1 = m16[c >> 1];
    if (ns1 != 1) {
      if ((ns1 & 1) == 0) {
        // Expand for one UNIT.
        i64 oldNU = ns1 >> 1;
        i64 i = p->units2Indx[oldNU - 1];
        if (i != p->units2Indx[oldNU]) {
          i64 ptr = allocUnits(p, i + 1);
          if (ptr == 0) {
            restartModel(p);
            return;
          }
          i64 oldPtr = m32[(c >> 2) + 1];
          mem12Cpy(p, ptr, oldPtr, oldNU);
          insertNode(p, oldPtr, i);
          m32[(c >> 2) + 1] = (u32)ptr;
        }
      }
      sum = m16[(c >> 1) + 1];
      sum += ((2 * ns1 < ns) ? 1 : 0) +
             2 * (((4 * ns1 <= ns) && (sum <= 8 * ns1)) ? 1 : 0);
    } else {
      // Instead of One-symbol context we create 2-symbol context.
      i64 s = allocUnits(p, 0);
      if (s == 0) {
        restartModel(p);
        return;
      }
      i64 freq = m8[c + 3];
      m8[s] = m8[c + 2];
      m16[(s >> 1) + 1] = m16[(c >> 1) + 2];
      m16[(s >> 1) + 2] = m16[(c >> 1) + 3];
      m32[(c >> 2) + 1] = (u32)s;
      if (freq < K_MAX_FREQ / 4 - 1) {
        freq <<= 1;
      } else {
        freq = K_MAX_FREQ - 4;
      }
      m8[s + 1] = (u8)freq;
      sum = freq + p->initEsc + (ns > 3 ? 1 : 0);
    }

    {
      i64 s = (i64)m32[(c >> 2) + 1] + ns1 * 6;
      i64 cf = 2 * (sum + 6) * fsFreq;
      i64 sf = s0 + sum;
      m8[s] = (u8)fSymbol;
      m16[c >> 1] = (u16)(ns1 + 1);
      setSuccessor(p, s, maxSuccessor);
      if (cf < 6 * sf) {
        cf = 1 + (cf > sf ? 1 : 0) + (cf >= 4 * sf ? 1 : 0);
        sum += 3;
      } else {
        cf = 4 + (cf >= 9 * sf ? 1 : 0) + (cf >= 12 * sf ? 1 : 0) +
             (cf >= 15 * sf ? 1 : 0);
        sum += cf;
      }
      m16[(c >> 1) + 1] = (u16)sum;
      m8[s + 1] = (u8)cf;
    }
    c = m32[(c >> 2) + 2];
  } while (c != mc);
}

// Ppmd7_Rescale
static void rescale(Ppmd7 *p) {
  u8 *m8 = p->mem;
  u16a *m16 = p->mem16;
  i64 mc = p->minContext;
  i64 stats = p->mem32[(mc >> 2) + 1];
  i64 s = p->foundState;

  // Sort the list by Freq.
  if (s != stats) {
    u16 t0 = m16[s >> 1], t1 = m16[(s >> 1) + 1], t2 = m16[(s >> 1) + 2];
    do {
      copyState(p, s, s - 6);
      s -= 6;
    } while (s != stats);
    m16[s >> 1] = t0;
    m16[(s >> 1) + 1] = t1;
    m16[(s >> 1) + 2] = t2;
  }

  i64 sumFreq = m8[s + 1];
  i64 escFreq = (i64)m16[(mc >> 1) + 1] - sumFreq;

  // adder = 0 allows removing symbols from MAX order contexts.
  i64 adder = (p->orderFall != 0) ? 1 : 0;

  sumFreq = (sumFreq + 4 + adder) >> 1;
  i64 i = (i64)m16[mc >> 1] - 1;
  m8[s + 1] = (u8)sumFreq;

  do {
    s += 6;
    i64 freq = m8[s + 1];
    escFreq -= freq;
    freq = (freq + adder) >> 1;
    sumFreq += freq;
    m8[s + 1] = (u8)freq;
    if (freq > m8[s - 6 + 1]) {
      u16 t0 = m16[s >> 1], t1 = m16[(s >> 1) + 1], t2 = m16[(s >> 1) + 2];
      i64 s1 = s;
      do {
        copyState(p, s1, s1 - 6);
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
    i64 numStats = m16[mc >> 1];
    i64 numStatsNew = numStats - i;
    m16[mc >> 1] = (u16)numStatsNew;
    i64 n0 = (numStats + 1) >> 1;

    if (numStatsNew == 1) {
      // Create Single-Symbol context.
      i64 freq = m8[stats + 1];
      do {
        escFreq >>= 1;
        freq = (freq + 1) >> 1;
      } while (escFreq > 1);
      s = mc + 2;
      copyState(p, s, stats);
      m8[s + 1] = (u8)freq;
      p->foundState = s;
      insertNode(p, stats, p->units2Indx[n0 - 1]);
      return;
    }

    i64 n1 = (numStatsNew + 1) >> 1;
    if (n0 != n1) {
      i64 i0 = p->units2Indx[n0 - 1];
      i64 i1 = p->units2Indx[n1 - 1];
      if (i0 != i1) {
        if (p->freeList[i1] != 0) {
          i64 ptr = removeNode(p, i1);
          p->mem32[(mc >> 2) + 1] = (u32)ptr;
          mem12Cpy(p, ptr, stats, n1);
          insertNode(p, stats, i0);
        } else {
          splitBlock(p, stats, i0, i1);
        }
      }
    }
  }
  m16[(mc >> 1) + 1] = (u16)(sumFreq + escFreq - (escFreq >> 1));
  p->foundState = p->mem32[(mc >> 2) + 1];
}

// Ppmd_See_UPDATE
void ppmd7_seeUpdate(Ppmd7 *p, i64 see) {
  i64 shift = p->seeShift[see];
  if (shift < PPMD_PERIOD_BITS && --p->seeCount[see] == 0) {
    p->seeSumm[see] = (u16)(p->seeSumm[see] << 1);
    p->seeCount[see] = (u8)(3 << shift);
    p->seeShift[see] = (u8)(shift + 1);
  }
}

// Ppmd7_NextContext
static void nextContext(Ppmd7 *p) {
  i64 c = ppmd7_successor(p, p->foundState);
  if (p->orderFall == 0 && c > p->text) {
    p->maxContext = p->minContext = c;
  } else {
    updateModel(p);
  }
}

// Ppmd7_Update1
void ppmd7_update1(Ppmd7 *p) {
  i64 s = p->foundState;
  u8 *m8 = p->mem;
  i64 freq = (i64)m8[s + 1] + 4;
  p->mem16[(p->minContext >> 1) + 1] += 4;
  m8[s + 1] = (u8)freq;
  if (freq > m8[s - 6 + 1]) {
    swapStates(p, s);
    p->foundState = s -= 6;
    if (freq > K_MAX_FREQ) rescale(p);
  }
  nextContext(p);
}

// Ppmd7_Update1_0
void ppmd7_update1_0(Ppmd7 *p) {
  i64 s = p->foundState;
  i64 mc = p->minContext;
  u8 *m8 = p->mem;
  i64 freq = m8[s + 1];
  i64 summFreq = p->mem16[(mc >> 1) + 1];
  p->prevSuccess = (2 * freq > summFreq) ? 1 : 0;
  p->runLength += p->prevSuccess;
  p->mem16[(mc >> 1) + 1] = (u16)(summFreq + 4);
  freq += 4;
  m8[s + 1] = (u8)freq;
  if (freq > K_MAX_FREQ) rescale(p);
  nextContext(p);
}

// Ppmd7_UpdateBin
void ppmd7_updateBin(Ppmd7 *p, i64 s) {
  i64 freq = p->mem[s + 1];
  i64 c = ppmd7_successor(p, s);
  p->foundState = s;
  p->prevSuccess = 1;
  p->runLength++;
  p->mem[s + 1] = (u8)(freq + (freq < 128 ? 1 : 0));
  if (p->orderFall == 0 && c > p->text) {
    p->maxContext = p->minContext = c;
  } else {
    updateModel(p);
  }
}

// Ppmd7_Update2
void ppmd7_update2(Ppmd7 *p) {
  i64 s = p->foundState;
  i64 freq = (i64)p->mem[s + 1] + 4;
  p->runLength = p->initRL;
  p->mem16[(p->minContext >> 1) + 1] += 4;
  p->mem[s + 1] = (u8)freq;
  if (freq > K_MAX_FREQ) rescale(p);
  updateModel(p);
}

// Ppmd7_GetBinSumm: index into binSumm; also sets hiBitsFlag.
i64 ppmd7_getBinSumm(Ppmd7 *p) {
  i64 mc = p->minContext;
  u8 *m8 = p->mem;
  i64 suffix = p->mem32[(mc >> 2) + 2];
  p->hiBitsFlag = ((m8[p->foundState] + 0xC0) >> (8 - 3)) & (1 << 3);
  return ((i64)m8[mc + 3] - 1) * 64 + p->prevSuccess +
         ((p->runLength >> 26) & 0x20) +
         p->ns2BSIndx[p->mem16[suffix >> 1] - 1] +
         (((m8[mc + 2] + 0xC0) >> (8 - 4)) & (1 << 4)) + p->hiBitsFlag;
}
