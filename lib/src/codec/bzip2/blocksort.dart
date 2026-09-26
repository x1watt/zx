// Block sorting: port of blocksort.c of bzip2 1.0.8 (the Burrows-Wheeler
// transform of one block). bzip2/libbzip2 is Copyright (C) 1996-2019 Julian
// Seward, under the bzip2 license (BSD style, see LICENSE).
//
// The C code aliases its buffers: the block bytes are the first bytes of
// arr2, the quadrant array follows them, and the fallback sort uses arr2 as
// its UInt32 eclass array (destroying the block and rebuilding it at the
// end). Here the block, the quadrant and eclass are separate typed lists,
// so the block is never destroyed and the rebuild step is not needed. The
// sorted order (and so the output) is the same.

import 'dart:typed_data';

import 'bzip2_tables.dart';

const int _fallbackQSortSmallThresh = 10;
const int _fallbackQSortStackSize = 100;

const int _mainQSortSmallThresh = 20;
const int _mainQSortDepthThresh = bzNRadix + bzNQSort;
const int _mainQSortStackSize = 100;

const int _setMask = 1 << 21;
const int _clearMask = ~_setMask;

// incs (Knuth's increments)
const List<int> _incs = [
  1, 4, 13, 40, 121, 364, 1093, 3280, //
  9841, 29524, 88573, 265720, 797161, 2391484,
];

/// The block sorting state of one encoder (the arrays of EState that
/// BZ2_blockSort uses). [block] must have room for nblock + bzNOvershoot
/// bytes.
class BlockSorter {
  /// ptr (arr1): the sorted order after [blockSort].
  final Int32List ptr;
  final Uint16List _quadrant;
  final Uint32List _ftab = Uint32List(65537);
  Int32List? _eclass;
  final int _capacity;

  int _budget = 0;

  // stacks of mainQSort3 and fallbackQSort3
  final Int32List _stackLo = Int32List(_mainQSortStackSize);
  final Int32List _stackHi = Int32List(_mainQSortStackSize);
  final Int32List _stackD = Int32List(_mainQSortStackSize);
  final Int32List _nextLo = Int32List(3);
  final Int32List _nextHi = Int32List(3);
  final Int32List _nextD = Int32List(3);

  // mainSort locals
  final Int32List _runningOrder = Int32List(256);
  final Uint8List _bigDone = Uint8List(256);
  final Int32List _copyStart = Int32List(256);
  final Int32List _copyEnd = Int32List(256);

  // fallbackSort locals
  final Int32List _fftab = Int32List(257);

  /// [capacity] is the largest block (100000 * blockSize100k).
  BlockSorter(int capacity)
      : _capacity = capacity,
        ptr = Int32List(capacity),
        _quadrant = Uint16List(capacity + bzNOvershoot + 1);

  // fallbackSimpleSort
  static void _fallbackSimpleSort(
      Int32List fmap, Int32List eclass, int lo, int hi) {
    if (lo == hi) return;

    if (hi - lo > 3) {
      for (var i = hi - 4; i >= lo; i--) {
        final tmp = fmap[i];
        final ecTmp = eclass[tmp];
        var j = i + 4;
        for (; j <= hi && ecTmp > eclass[fmap[j]]; j += 4) {
          fmap[j - 4] = fmap[j];
        }
        fmap[j - 4] = tmp;
      }
    }

    for (var i = hi - 1; i >= lo; i--) {
      final tmp = fmap[i];
      final ecTmp = eclass[tmp];
      var j = i + 1;
      for (; j <= hi && ecTmp > eclass[fmap[j]]; j++) {
        fmap[j - 1] = fmap[j];
      }
      fmap[j - 1] = tmp;
    }
  }

  // fallbackQSort3
  void _fallbackQSort3(Int32List fmap, Int32List eclass, int loSt, int hiSt) {
    final stackLo = _stackLo;
    final stackHi = _stackHi;
    var r = 0;
    var sp = 0;
    stackLo[sp] = loSt;
    stackHi[sp] = hiSt;
    sp++;

    while (sp > 0) {
      if (sp >= _fallbackQSortStackSize - 1) {
        throw StateError('bzip2 internal error 1004');
      }

      sp--;
      final lo = stackLo[sp];
      final hi = stackHi[sp];
      if (hi - lo < _fallbackQSortSmallThresh) {
        _fallbackSimpleSort(fmap, eclass, lo, hi);
        continue;
      }

      // Random partitioning (constants 7621 and 32768 from Sedgewick).
      r = ((r * 7621) + 1) % 32768;
      final r3 = r % 3;
      int med;
      if (r3 == 0) {
        med = eclass[fmap[lo]];
      } else if (r3 == 1) {
        med = eclass[fmap[(lo + hi) >> 1]];
      } else {
        med = eclass[fmap[hi]];
      }

      var unLo = lo, ltLo = lo;
      var unHi = hi, gtHi = hi;

      for (;;) {
        for (;;) {
          if (unLo > unHi) break;
          final n = eclass[fmap[unLo]] - med;
          if (n == 0) {
            final t = fmap[unLo];
            fmap[unLo] = fmap[ltLo];
            fmap[ltLo] = t;
            ltLo++;
            unLo++;
            continue;
          }
          if (n > 0) break;
          unLo++;
        }
        for (;;) {
          if (unLo > unHi) break;
          final n = eclass[fmap[unHi]] - med;
          if (n == 0) {
            final t = fmap[unHi];
            fmap[unHi] = fmap[gtHi];
            fmap[gtHi] = t;
            gtHi--;
            unHi--;
            continue;
          }
          if (n < 0) break;
          unHi--;
        }
        if (unLo > unHi) break;
        final t = fmap[unLo];
        fmap[unLo] = fmap[unHi];
        fmap[unHi] = t;
        unLo++;
        unHi--;
      }

      if (gtHi < ltLo) continue;

      var n = (ltLo - lo) < (unLo - ltLo) ? (ltLo - lo) : (unLo - ltLo);
      _vswap(fmap, lo, unLo - n, n);
      var m = (hi - gtHi) < (gtHi - unHi) ? (hi - gtHi) : (gtHi - unHi);
      _vswap(fmap, unLo, hi - m + 1, m);

      n = lo + unLo - ltLo - 1;
      m = hi - (gtHi - unHi) + 1;

      if (n - lo > hi - m) {
        stackLo[sp] = lo;
        stackHi[sp] = n;
        sp++;
        stackLo[sp] = m;
        stackHi[sp] = hi;
        sp++;
      } else {
        stackLo[sp] = m;
        stackHi[sp] = hi;
        sp++;
        stackLo[sp] = lo;
        stackHi[sp] = n;
        sp++;
      }
    }
  }

  // fvswap / mvswap
  static void _vswap(Int32List a, int p1, int p2, int n) {
    while (n > 0) {
      final t = a[p1];
      a[p1] = a[p2];
      a[p2] = t;
      p1++;
      p2++;
      n--;
    }
  }

  // fallbackSort. [block] holds the block (eclass8 in C), [bhtab] is the
  // ftab area.
  void _fallbackSort(
      Int32List fmap, Uint8List block, Uint32List bhtab, int nblock) {
    final eclass = _eclass ??= Int32List(_capacity);
    final ftab = _fftab;

    // Initial 1-char radix sort to generate initial fmap and initial BH
    // bits.
    for (var i = 0; i < 257; i++) {
      ftab[i] = 0;
    }
    for (var i = 0; i < nblock; i++) {
      ftab[block[i]]++;
    }
    for (var i = 1; i < 257; i++) {
      ftab[i] += ftab[i - 1];
    }

    for (var i = 0; i < nblock; i++) {
      final j = block[i];
      final k = ftab[j] - 1;
      ftab[j] = k;
      fmap[k] = i;
    }

    final nBhtab = 2 + (nblock ~/ 32);
    for (var i = 0; i < nBhtab; i++) {
      bhtab[i] = 0;
    }
    for (var i = 0; i < 256; i++) {
      final zz = ftab[i];
      bhtab[zz >> 5] |= 1 << (zz & 31); // SET_BH
    }

    // Inductively refine the buckets (Manber-Myers style).

    // set sentinel bits for block-end detection
    for (var i = 0; i < 32; i++) {
      final a = nblock + 2 * i;
      bhtab[a >> 5] |= 1 << (a & 31); // SET_BH
      final b = a + 1;
      bhtab[b >> 5] &= ~(1 << (b & 31)); // CLEAR_BH
    }

    // the log(N) loop
    var h = 1;
    for (;;) {
      var j = 0;
      for (var i = 0; i < nblock; i++) {
        if ((bhtab[i >> 5] & (1 << (i & 31))) != 0) j = i;
        var k = fmap[i] - h;
        if (k < 0) k += nblock;
        eclass[k] = j;
      }

      var nNotDone = 0;
      var r = -1;
      for (;;) {
        // find the next non-singleton bucket
        var k = r + 1;
        while ((bhtab[k >> 5] & (1 << (k & 31))) != 0 && (k & 0x1f) != 0) {
          k++;
        }
        if ((bhtab[k >> 5] & (1 << (k & 31))) != 0) {
          while (bhtab[k >> 5] == 0xffffffff) {
            k += 32;
          }
          while ((bhtab[k >> 5] & (1 << (k & 31))) != 0) {
            k++;
          }
        }
        final l = k - 1;
        if (l >= nblock) break;
        while ((bhtab[k >> 5] & (1 << (k & 31))) == 0 && (k & 0x1f) != 0) {
          k++;
        }
        if ((bhtab[k >> 5] & (1 << (k & 31))) == 0) {
          while (bhtab[k >> 5] == 0x00000000) {
            k += 32;
          }
          while ((bhtab[k >> 5] & (1 << (k & 31))) == 0) {
            k++;
          }
        }
        r = k - 1;
        if (r >= nblock) break;

        // now [l, r] bracket current bucket
        if (r > l) {
          nNotDone += (r - l + 1);
          _fallbackQSort3(fmap, eclass, l, r);

          // scan bucket and generate header bits
          var cc = -1;
          for (var i = l; i <= r; i++) {
            final cc1 = eclass[fmap[i]];
            if (cc != cc1) {
              bhtab[i >> 5] |= 1 << (i & 31); // SET_BH
              cc = cc1;
            }
          }
        }
      }

      h *= 2;
      if (h > nblock || nNotDone == 0) break;
    }

    // The C code rebuilds the block in eclass8 here; the block was not
    // overwritten (see the header comment).
  }

  // mainGtU
  bool _mainGtU(
      int i1, int i2, Uint8List block, Uint16List quadrant, int nblock) {
    int c1, c2;
    // 1 .. 12
    c1 = block[i1];
    c2 = block[i2];
    if (c1 != c2) return c1 > c2;
    i1++;
    i2++;
    c1 = block[i1];
    c2 = block[i2];
    if (c1 != c2) return c1 > c2;
    i1++;
    i2++;
    c1 = block[i1];
    c2 = block[i2];
    if (c1 != c2) return c1 > c2;
    i1++;
    i2++;
    c1 = block[i1];
    c2 = block[i2];
    if (c1 != c2) return c1 > c2;
    i1++;
    i2++;
    c1 = block[i1];
    c2 = block[i2];
    if (c1 != c2) return c1 > c2;
    i1++;
    i2++;
    c1 = block[i1];
    c2 = block[i2];
    if (c1 != c2) return c1 > c2;
    i1++;
    i2++;
    c1 = block[i1];
    c2 = block[i2];
    if (c1 != c2) return c1 > c2;
    i1++;
    i2++;
    c1 = block[i1];
    c2 = block[i2];
    if (c1 != c2) return c1 > c2;
    i1++;
    i2++;
    c1 = block[i1];
    c2 = block[i2];
    if (c1 != c2) return c1 > c2;
    i1++;
    i2++;
    c1 = block[i1];
    c2 = block[i2];
    if (c1 != c2) return c1 > c2;
    i1++;
    i2++;
    c1 = block[i1];
    c2 = block[i2];
    if (c1 != c2) return c1 > c2;
    i1++;
    i2++;
    c1 = block[i1];
    c2 = block[i2];
    if (c1 != c2) return c1 > c2;
    i1++;
    i2++;

    var k = nblock + 8;
    int s1, s2;

    do {
      // 1 .. 8
      c1 = block[i1];
      c2 = block[i2];
      if (c1 != c2) return c1 > c2;
      s1 = quadrant[i1];
      s2 = quadrant[i2];
      if (s1 != s2) return s1 > s2;
      i1++;
      i2++;
      c1 = block[i1];
      c2 = block[i2];
      if (c1 != c2) return c1 > c2;
      s1 = quadrant[i1];
      s2 = quadrant[i2];
      if (s1 != s2) return s1 > s2;
      i1++;
      i2++;
      c1 = block[i1];
      c2 = block[i2];
      if (c1 != c2) return c1 > c2;
      s1 = quadrant[i1];
      s2 = quadrant[i2];
      if (s1 != s2) return s1 > s2;
      i1++;
      i2++;
      c1 = block[i1];
      c2 = block[i2];
      if (c1 != c2) return c1 > c2;
      s1 = quadrant[i1];
      s2 = quadrant[i2];
      if (s1 != s2) return s1 > s2;
      i1++;
      i2++;
      c1 = block[i1];
      c2 = block[i2];
      if (c1 != c2) return c1 > c2;
      s1 = quadrant[i1];
      s2 = quadrant[i2];
      if (s1 != s2) return s1 > s2;
      i1++;
      i2++;
      c1 = block[i1];
      c2 = block[i2];
      if (c1 != c2) return c1 > c2;
      s1 = quadrant[i1];
      s2 = quadrant[i2];
      if (s1 != s2) return s1 > s2;
      i1++;
      i2++;
      c1 = block[i1];
      c2 = block[i2];
      if (c1 != c2) return c1 > c2;
      s1 = quadrant[i1];
      s2 = quadrant[i2];
      if (s1 != s2) return s1 > s2;
      i1++;
      i2++;
      c1 = block[i1];
      c2 = block[i2];
      if (c1 != c2) return c1 > c2;
      s1 = quadrant[i1];
      s2 = quadrant[i2];
      if (s1 != s2) return s1 > s2;
      i1++;
      i2++;

      if (i1 >= nblock) i1 -= nblock;
      if (i2 >= nblock) i2 -= nblock;

      k -= 8;
      _budget--;
    } while (k >= 0);

    return false;
  }

  // mainSimpleSort
  void _mainSimpleSort(Int32List ptr, Uint8List block, Uint16List quadrant,
      int nblock, int lo, int hi, int d) {
    final bigN = hi - lo + 1;
    if (bigN < 2) return;

    var hp = 0;
    while (_incs[hp] < bigN) {
      hp++;
    }
    hp--;

    for (; hp >= 0; hp--) {
      final h = _incs[hp];

      var i = lo + h;
      for (;;) {
        // copy 1
        if (i > hi) break;
        var v = ptr[i];
        var j = i;
        while (_mainGtU(ptr[j - h] + d, v + d, block, quadrant, nblock)) {
          ptr[j] = ptr[j - h];
          j = j - h;
          if (j <= (lo + h - 1)) break;
        }
        ptr[j] = v;
        i++;

        // copy 2
        if (i > hi) break;
        v = ptr[i];
        j = i;
        while (_mainGtU(ptr[j - h] + d, v + d, block, quadrant, nblock)) {
          ptr[j] = ptr[j - h];
          j = j - h;
          if (j <= (lo + h - 1)) break;
        }
        ptr[j] = v;
        i++;

        // copy 3
        if (i > hi) break;
        v = ptr[i];
        j = i;
        while (_mainGtU(ptr[j - h] + d, v + d, block, quadrant, nblock)) {
          ptr[j] = ptr[j - h];
          j = j - h;
          if (j <= (lo + h - 1)) break;
        }
        ptr[j] = v;
        i++;

        if (_budget < 0) return;
      }
    }
  }

  // mmed3
  static int _mmed3(int a, int b, int c) {
    if (a > b) {
      final t = a;
      a = b;
      b = t;
    }
    if (b > c) {
      b = c;
      if (a > b) b = a;
    }
    return b;
  }

  // mainQSort3: a 3-way quicksort for strings (Sedgewick and Bentley).
  void _mainQSort3(Int32List ptr, Uint8List block, Uint16List quadrant,
      int nblock, int loSt, int hiSt, int dSt) {
    final stackLo = _stackLo;
    final stackHi = _stackHi;
    final stackD = _stackD;
    final nextLo = _nextLo;
    final nextHi = _nextHi;
    final nextD = _nextD;

    var sp = 0;
    stackLo[sp] = loSt;
    stackHi[sp] = hiSt;
    stackD[sp] = dSt;
    sp++;

    while (sp > 0) {
      if (sp >= _mainQSortStackSize - 2) {
        throw StateError('bzip2 internal error 1001');
      }

      sp--;
      final lo = stackLo[sp];
      final hi = stackHi[sp];
      final d = stackD[sp];
      if (hi - lo < _mainQSortSmallThresh || d > _mainQSortDepthThresh) {
        _mainSimpleSort(ptr, block, quadrant, nblock, lo, hi, d);
        if (_budget < 0) return;
        continue;
      }

      final med = _mmed3(block[ptr[lo] + d], block[ptr[hi] + d],
          block[ptr[(lo + hi) >> 1] + d]);

      var unLo = lo, ltLo = lo;
      var unHi = hi, gtHi = hi;

      for (;;) {
        for (;;) {
          if (unLo > unHi) break;
          final n = block[ptr[unLo] + d] - med;
          if (n == 0) {
            final t = ptr[unLo];
            ptr[unLo] = ptr[ltLo];
            ptr[ltLo] = t;
            ltLo++;
            unLo++;
            continue;
          }
          if (n > 0) break;
          unLo++;
        }
        for (;;) {
          if (unLo > unHi) break;
          final n = block[ptr[unHi] + d] - med;
          if (n == 0) {
            final t = ptr[unHi];
            ptr[unHi] = ptr[gtHi];
            ptr[gtHi] = t;
            gtHi--;
            unHi--;
            continue;
          }
          if (n < 0) break;
          unHi--;
        }
        if (unLo > unHi) break;
        final t = ptr[unLo];
        ptr[unLo] = ptr[unHi];
        ptr[unHi] = t;
        unLo++;
        unHi--;
      }

      if (gtHi < ltLo) {
        stackLo[sp] = lo;
        stackHi[sp] = hi;
        stackD[sp] = d + 1;
        sp++;
        continue;
      }

      var n = (ltLo - lo) < (unLo - ltLo) ? (ltLo - lo) : (unLo - ltLo);
      _vswap(ptr, lo, unLo - n, n);
      var m = (hi - gtHi) < (gtHi - unHi) ? (hi - gtHi) : (gtHi - unHi);
      _vswap(ptr, unLo, hi - m + 1, m);

      n = lo + unLo - ltLo - 1;
      m = hi - (gtHi - unHi) + 1;

      nextLo[0] = lo;
      nextHi[0] = n;
      nextD[0] = d;
      nextLo[1] = m;
      nextHi[1] = hi;
      nextD[1] = d;
      nextLo[2] = n + 1;
      nextHi[2] = m - 1;
      nextD[2] = d + 1;

      if (nextHi[0] - nextLo[0] < nextHi[1] - nextLo[1]) _nextSwap(0, 1);
      if (nextHi[1] - nextLo[1] < nextHi[2] - nextLo[2]) _nextSwap(1, 2);
      if (nextHi[0] - nextLo[0] < nextHi[1] - nextLo[1]) _nextSwap(0, 1);

      for (var z = 0; z < 3; z++) {
        stackLo[sp] = nextLo[z];
        stackHi[sp] = nextHi[z];
        stackD[sp] = nextD[z];
        sp++;
      }
    }
  }

  // mnextswap
  void _nextSwap(int a, int b) {
    var t = _nextLo[a];
    _nextLo[a] = _nextLo[b];
    _nextLo[b] = t;
    t = _nextHi[a];
    _nextHi[a] = _nextHi[b];
    _nextHi[b] = t;
    t = _nextD[a];
    _nextD[a] = _nextD[b];
    _nextD[b] = t;
  }

  // mainSort. [block] must have nblock + bzNOvershoot bytes; the overshoot
  // area is filled here.
  void _mainSort(Int32List ptr, Uint8List block, Uint16List quadrant,
      Uint32List ftab, int nblock) {
    final runningOrder = _runningOrder;
    final bigDone = _bigDone;
    final copyStart = _copyStart;
    final copyEnd = _copyEnd;

    // set up the 2-byte frequency table
    for (var i = 65536; i >= 0; i--) {
      ftab[i] = 0;
    }

    var j = block[0] << 8;
    var i = nblock - 1;
    for (; i >= 3; i -= 4) {
      quadrant[i] = 0;
      j = (j >> 8) | (block[i] << 8);
      ftab[j]++;
      quadrant[i - 1] = 0;
      j = (j >> 8) | (block[i - 1] << 8);
      ftab[j]++;
      quadrant[i - 2] = 0;
      j = (j >> 8) | (block[i - 2] << 8);
      ftab[j]++;
      quadrant[i - 3] = 0;
      j = (j >> 8) | (block[i - 3] << 8);
      ftab[j]++;
    }
    for (; i >= 0; i--) {
      quadrant[i] = 0;
      j = (j >> 8) | (block[i] << 8);
      ftab[j]++;
    }

    // (emphasises close relationship of block & quadrant)
    for (i = 0; i < bzNOvershoot; i++) {
      block[nblock + i] = block[i];
      quadrant[nblock + i] = 0;
    }

    // Complete the initial radix sort
    for (i = 1; i <= 65536; i++) {
      ftab[i] += ftab[i - 1];
    }

    var s = block[0] << 8;
    i = nblock - 1;
    for (; i >= 3; i -= 4) {
      s = (s >> 8) | (block[i] << 8);
      j = ftab[s] - 1;
      ftab[s] = j;
      ptr[j] = i;
      s = (s >> 8) | (block[i - 1] << 8);
      j = ftab[s] - 1;
      ftab[s] = j;
      ptr[j] = i - 1;
      s = (s >> 8) | (block[i - 2] << 8);
      j = ftab[s] - 1;
      ftab[s] = j;
      ptr[j] = i - 2;
      s = (s >> 8) | (block[i - 3] << 8);
      j = ftab[s] - 1;
      ftab[s] = j;
      ptr[j] = i - 3;
    }
    for (; i >= 0; i--) {
      s = (s >> 8) | (block[i] << 8);
      j = ftab[s] - 1;
      ftab[s] = j;
      ptr[j] = i;
    }

    // Now ftab contains the first loc of every small bucket. Calculate the
    // running order, from smallest to largest big bucket.
    for (i = 0; i <= 255; i++) {
      bigDone[i] = 0;
      runningOrder[i] = i;
    }

    {
      var h = 1;
      do {
        h = 3 * h + 1;
      } while (h <= 256);
      do {
        h = h ~/ 3;
        for (i = h; i <= 255; i++) {
          final vv = runningOrder[i];
          j = i;
          // BIGFREQ(b) = ftab[(b+1) << 8] - ftab[b << 8]
          final bigVv = ftab[(vv + 1) << 8] - ftab[vv << 8];
          for (;;) {
            final rj = runningOrder[j - h];
            if (!(ftab[(rj + 1) << 8] - ftab[rj << 8] > bigVv)) break;
            runningOrder[j] = rj;
            j = j - h;
            if (j <= (h - 1)) break;
          }
          runningOrder[j] = vv;
        }
      } while (h != 1);
    }

    // The main sorting loop.

    for (i = 0; i <= 255; i++) {
      // Process big buckets, starting with the least full.
      final ss = runningOrder[i];

      // Step 1: complete the big bucket [ss] by quicksorting any unsorted
      // small buckets [ss, j], for j != ss.
      for (j = 0; j <= 255; j++) {
        if (j != ss) {
          final sb = (ss << 8) + j;
          if ((ftab[sb] & _setMask) == 0) {
            final lo = ftab[sb] & _clearMask;
            final hi = (ftab[sb + 1] & _clearMask) - 1;
            if (hi > lo) {
              _mainQSort3(ptr, block, quadrant, nblock, lo, hi, bzNRadix);
              if (_budget < 0) return;
            }
          }
          ftab[sb] |= _setMask;
        }
      }

      if (bigDone[ss] != 0) throw StateError('bzip2 internal error 1006');

      // Step 2: scan this big bucket [ss] so as to synthesise the sorted
      // order for small buckets [t, ss] for all t, including [ss, ss].
      {
        for (j = 0; j <= 255; j++) {
          copyStart[j] = ftab[(j << 8) + ss] & _clearMask;
          copyEnd[j] = (ftab[(j << 8) + ss + 1] & _clearMask) - 1;
        }
        for (j = ftab[ss << 8] & _clearMask; j < copyStart[ss]; j++) {
          var k = ptr[j] - 1;
          if (k < 0) k += nblock;
          final c1 = block[k];
          if (bigDone[c1] == 0) ptr[copyStart[c1]++] = k;
        }
        for (j = (ftab[(ss + 1) << 8] & _clearMask) - 1; j > copyEnd[ss]; j--) {
          var k = ptr[j] - 1;
          if (k < 0) k += nblock;
          final c1 = block[k];
          if (bigDone[c1] == 0) ptr[copyEnd[c1]--] = k;
        }
      }

      if (!((copyStart[ss] - 1 == copyEnd[ss]) ||
          (copyStart[ss] == 0 && copyEnd[ss] == nblock - 1))) {
        throw StateError('bzip2 internal error 1007');
      }

      for (j = 0; j <= 255; j++) {
        ftab[(j << 8) + ss] |= _setMask;
      }

      // Step 3: the [ss] big bucket is now done. Record this fact, and
      // update the quadrant descriptors (in the overshoot area too).
      bigDone[ss] = 1;

      if (i < 255) {
        final bbStart = ftab[ss << 8] & _clearMask;
        final bbSize = (ftab[(ss + 1) << 8] & _clearMask) - bbStart;
        var shifts = 0;

        while ((bbSize >> shifts) > 65534) {
          shifts++;
        }

        for (j = bbSize - 1; j >= 0; j--) {
          final a2update = ptr[bbStart + j];
          final qVal = (j >> shifts) & 0xFFFF;
          quadrant[a2update] = qVal;
          if (a2update < bzNOvershoot) quadrant[a2update + nblock] = qVal;
        }
        if (((bbSize - 1) >> shifts) > 65535) {
          throw StateError('bzip2 internal error 1002');
        }
      }
    }
  }

  /// BZ2_blockSort: sorts [block] (nblock bytes, with bzNOvershoot bytes
  /// of room after them) into [ptr]. Returns origPtr.
  int blockSort(Uint8List block, int nblock, int workFactor) {
    final ptr = this.ptr;
    final ftab = _ftab;

    if (nblock < 10000) {
      _fallbackSort(ptr, block, ftab, nblock);
    } else {
      final quadrant = _quadrant;

      // (wfact-1) / 3 puts the default-factor-30 transition point at very
      // roughly the same place as with v0.1 and v0.9.0.
      var wfact = workFactor;
      if (wfact < 1) wfact = 1;
      if (wfact > 100) wfact = 100;
      final budgetInit = nblock * ((wfact - 1) ~/ 3);
      _budget = budgetInit;

      _mainSort(ptr, block, quadrant, ftab, nblock);
      if (_budget < 0) {
        // too repetitive; using fallback sorting algorithm
        _fallbackSort(ptr, block, ftab, nblock);
      }
    }

    var origPtr = -1;
    for (var i = 0; i < nblock; i++) {
      if (ptr[i] == 0) {
        origPtr = i;
        break;
      }
    }

    if (origPtr == -1) throw StateError('bzip2 internal error 1003');
    return origPtr;
  }
}
