// Vendored from zpaq-flutter by tool/sync_zpaq.sh: do not edit here, change
// zpaq-flutter and sync again. Pure Dart port of libzpaq and zpaq 7.15 (Matt
// Mahoney, public domain) with the zpaqfranz attribute format (Franco
// Corbelli, MIT). Copyright (c) 2026 Max Brito, BSD 3-clause; see LICENSE
// for the license and the third party notices.

// Port of divsufsort.c from libdivsufsort-lite (as included in libzpaq):
//
// Copyright (c) 2003-2008 Yuta Mori All Rights Reserved.
//
// Permission is hereby granted, free of charge, to any person obtaining a
// copy of this software and associated documentation files (the
// "Software"), to deal in the Software without restriction, including
// without limitation the rights to use, copy, modify, merge, publish,
// distribute, sublicense, and/or sell copies of the Software, and to permit
// persons to whom the Software is furnished to do so, subject to the
// following conditions:
//
// The above copyright notice and this permission notice shall be included
// in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
// OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN
// NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
// DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
// OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE
// USE OR OTHER DEALINGS IN THE SOFTWARE.
//
// Every C pointer into the suffix array is an index into [_Dss.sa] here,
// every pointer into the text an index into [_Dss.t].

import 'dart:typed_data';

const int _ssInsertionsortThreshold = 8;
const int _ssBlocksize = 1024;
const int _ssMisortStacksize = 16;
const int _ssSmergeStacksize = 32;
const int _trInsertionsortThreshold = 8;
const int _trStacksize = 64;

const List<int> _lgTable = [
  -1, 0, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 3, 3, 3, 3, 4, 4, 4, 4, 4, 4, 4, 4, //
  4, 4, 4, 4, 4, 4, 4, 4, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
  5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 6, 6, 6, 6, 6, 6, 6, 6,
  6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6,
  6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6,
  6, 6, 6, 6, 6, 6, 6, 6, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
  7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
  7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
  7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
  7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
  7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
];

const List<int> _sqqTable = [
  0, 16, 22, 27, 32, 35, 39, 42, 45, 48, 50, 53, 55, 57, 59, 61, //
  64, 65, 67, 69, 71, 73, 75, 76, 78, 80, 81, 83, 84, 86, 87, 89,
  90, 91, 93, 94, 96, 97, 98, 99, 101, 102, 103, 104, 106, 107, 108, 109,
  110, 112, 113, 114, 115, 116, 117, 118, 119, 120, 121, 122, 123, 124, 125,
  126, 128, 128, 129, 130, 131, 132, 133, 134, 135, 136, 137, 138, 139, 140,
  141, 142, 143, 144, 144, 145, 146, 147, 148, 149, 150, 150, 151, 152, 153,
  154, 155, 155, 156, 157, 158, 159, 160, 160, 161, 162, 163, 163, 164, 165,
  166, 167, 167, 168, 169, 170, 170, 171, 172, 173, 173, 174, 175, 176, 176,
  177, 178, 178, 179, 180, 181, 181, 182, 183, 183, 184, 185, 185, 186, 187,
  187, 188, 189, 189, 190, 191, 192, 192, 193, 193, 194, 195, 195, 196, 197,
  197, 198, 199, 199, 200, 201, 201, 202, 203, 203, 204, 204, 205, 206, 206,
  207, 208, 208, 209, 209, 210, 211, 211, 212, 212, 213, 214, 214, 215, 215,
  216, 217, 217, 218, 218, 219, 219, 220, 221, 221, 222, 222, 223, 224, 224,
  225, 225, 226, 226, 227, 227, 228, 229, 229, 230, 230, 231, 231, 232, 232,
  233, 234, 234, 235, 235, 236, 236, 237, 237, 238, 238, 239, 240, 240, 241,
  241, 242, 242, 243, 243, 244, 244, 245, 245, 246, 246, 247, 247, 248, 248,
  249, 249, 250, 250, 251, 251, 252, 252, 253, 253, 254, 254, 255,
];

@pragma('vm:prefer-inline')
int _ssIlg(int n) => (n & 0xff00) != 0
    ? 8 + _lgTable[(n >> 8) & 0xff]
    : 0 + _lgTable[(n >> 0) & 0xff];

@pragma('vm:prefer-inline')
int _trIlg(int n) => (n & 0xffff0000) != 0
    ? ((n & 0xff000000) != 0
        ? 24 + _lgTable[(n >> 24) & 0xff]
        : 16 + _lgTable[(n >> 16) & 0xff])
    : ((n & 0x0000ff00) != 0
        ? 8 + _lgTable[(n >> 8) & 0xff]
        : 0 + _lgTable[(n >> 0) & 0xff]);

@pragma('vm:prefer-inline')
int _ssIsqrt(int x) {
  if (x >= _ssBlocksize * _ssBlocksize) return _ssBlocksize;
  final e = (x & 0xffff0000) != 0
      ? ((x & 0xff000000) != 0
          ? 24 + _lgTable[(x >> 24) & 0xff]
          : 16 + _lgTable[(x >> 16) & 0xff])
      : ((x & 0x0000ff00) != 0
          ? 8 + _lgTable[(x >> 8) & 0xff]
          : 0 + _lgTable[(x >> 0) & 0xff]);
  int y;
  if (e >= 16) {
    y = _sqqTable[x >> ((e - 6) - (e & 1))] << ((e >> 1) - 7);
    if (e >= 24) y = (y + 1 + x ~/ y) >> 1;
    y = (y + 1 + x ~/ y) >> 1;
  } else if (e >= 8) {
    y = (_sqqTable[x >> ((e - 6) - (e & 1))] >> (7 - (e >> 1))) + 1;
  } else {
    return _sqqTable[x] >> 4;
  }
  return (x < y * y) ? y - 1 : y;
}

/// Builds the suffix array of [t] (length [n]) into [sa] (length >= n),
/// the array libzpaq builds for BWT and LZ77 with suffix array matching.
@pragma('vm:unsafe:no-bounds-checks')
void buildSuffixArray(Uint8List t, Int32List sa, int n) {
  if (n == 0) return;
  if (n == 1) {
    sa[0] = 0;
    return;
  }
  if (n == 2) {
    final m = t[0] < t[1] ? 1 : 0;
    sa[m ^ 1] = 0;
    sa[m] = 1;
    return;
  }
  final d = _Dss(t, sa);
  final m = d.sortTypeBstar(n);
  d.constructSA(n, m);
}

class _Dss {
  final Uint8List t;
  final Int32List sa;
  final Int32List bucketA = Int32List(256);
  final Int32List bucketB = Int32List(256 * 256);

  // Stacks: 4 or 5 ints per entry.
  final Int32List _misort = Int32List(_ssMisortStacksize * 4);
  final Int32List _smerge = Int32List(_ssSmergeStacksize * 4);
  final Int32List _trstack = Int32List(_trStacksize * 5);

  // trbudget
  int _chance = 0, _remain = 0, _incval = 0, _count = 0;

  _Dss(this.t, this.sa);

  // ---------------------------------------------------------------- sssort

  /// Compares two suffixes: p1..e1 and p2..e2 (e = next PA value + 2).
  @pragma('vm:unsafe:no-bounds-checks')
  int _ssCompareV(int s1, int n1, int s2, int n2, int depth) {
    final t = this.t;
    var u1 = depth + s1, u2 = depth + s2;
    final u1n = n1 + 2, u2n = n2 + 2;
    while (u1 < u1n && u2 < u2n && t[u1] == t[u2]) {
      ++u1;
      ++u2;
    }
    return u1 < u1n ? (u2 < u2n ? t[u1] - t[u2] : 1) : (u2 < u2n ? -1 : 0);
  }

  /// ss_compare(T, p1, p2, depth) with p1, p2 indexes into sa.
  @pragma('vm:unsafe:no-bounds-checks')
  int _ssCompare(int p1, int p2, int depth) {
    final sa = this.sa;
    return _ssCompareV(sa[p1], sa[p1 + 1], sa[p2], sa[p2 + 1], depth);
  }

  @pragma('vm:unsafe:no-bounds-checks')
  void _ssInsertionsort(int pa, int first, int last, int depth) {
    final sa = this.sa;
    int r = 0;
    for (var i = last - 2; first <= i; --i) {
      final t = sa[i];
      var j = i + 1;
      for (; 0 < (r = _ssCompare(pa + t, pa + sa[j], depth));) {
        do {
          sa[j - 1] = sa[j];
        } while (++j < last && sa[j] < 0);
        if (last <= j) break;
      }
      if (r == 0) sa[j] = ~sa[j];
      sa[j - 1] = t;
    }
  }

  @pragma('vm:unsafe:no-bounds-checks')
  void _ssFixdown(int td, int pa, int base, int i, int size) {
    final sa = this.sa, t = this.t;
    final v = sa[base + i];
    final c = t[td + sa[pa + v]];
    int j, k;
    while ((j = 2 * i + 1) < size) {
      k = j++;
      var d = t[td + sa[pa + sa[base + k]]];
      final e = t[td + sa[pa + sa[base + j]]];
      if (d < e) {
        k = j;
        d = e;
      }
      if (d <= c) break;
      sa[base + i] = sa[base + k];
      i = k;
    }
    sa[base + i] = v;
  }

  @pragma('vm:unsafe:no-bounds-checks')
  void _ssHeapsort(int td, int pa, int base, int size) {
    final sa = this.sa, t = this.t;
    var m = size;
    if ((size % 2) == 0) {
      m--;
      if (t[td + sa[pa + sa[base + m ~/ 2]]] < t[td + sa[pa + sa[base + m]]]) {
        final x = sa[base + m];
        sa[base + m] = sa[base + m ~/ 2];
        sa[base + m ~/ 2] = x;
      }
    }
    for (var i = m ~/ 2 - 1; 0 <= i; --i) {
      _ssFixdown(td, pa, base, i, m);
    }
    if ((size % 2) == 0) {
      final x = sa[base];
      sa[base] = sa[base + m];
      sa[base + m] = x;
      _ssFixdown(td, pa, base, 0, m);
    }
    for (var i = m - 1; 0 < i; --i) {
      final x = sa[base];
      sa[base] = sa[base + i];
      _ssFixdown(td, pa, base, 0, i);
      sa[base + i] = x;
    }
  }

  @pragma('vm:unsafe:no-bounds-checks')
  int _ssV(int td, int pa, int p) => t[td + sa[pa + sa[p]]];

  int _ssMedian3(int td, int pa, int v1, int v2, int v3) {
    if (_ssV(td, pa, v1) > _ssV(td, pa, v2)) {
      final x = v1;
      v1 = v2;
      v2 = x;
    }
    if (_ssV(td, pa, v2) > _ssV(td, pa, v3)) {
      return _ssV(td, pa, v1) > _ssV(td, pa, v3) ? v1 : v3;
    }
    return v2;
  }

  int _ssMedian5(int td, int pa, int v1, int v2, int v3, int v4, int v5) {
    int x;
    if (_ssV(td, pa, v2) > _ssV(td, pa, v3)) {
      x = v2;
      v2 = v3;
      v3 = x;
    }
    if (_ssV(td, pa, v4) > _ssV(td, pa, v5)) {
      x = v4;
      v4 = v5;
      v5 = x;
    }
    if (_ssV(td, pa, v2) > _ssV(td, pa, v4)) {
      x = v2;
      v2 = v4;
      v4 = x;
      x = v3;
      v3 = v5;
      v5 = x;
    }
    if (_ssV(td, pa, v1) > _ssV(td, pa, v3)) {
      x = v1;
      v1 = v3;
      v3 = x;
    }
    if (_ssV(td, pa, v1) > _ssV(td, pa, v4)) {
      x = v1;
      v1 = v4;
      v4 = x;
      x = v3;
      v3 = v5;
      v5 = x;
    }
    if (_ssV(td, pa, v3) > _ssV(td, pa, v4)) return v4;
    return v3;
  }

  @pragma('vm:unsafe:no-bounds-checks')
  int _ssPivot(int td, int pa, int first, int last) {
    var t = last - first;
    var middle = first + t ~/ 2;
    if (t <= 512) {
      if (t <= 32) return _ssMedian3(td, pa, first, middle, last - 1);
      t >>= 2;
      return _ssMedian5(
          td, pa, first, first + t, middle, last - 1 - t, last - 1);
    }
    t >>= 3;
    first = _ssMedian3(td, pa, first, first + t, first + (t << 1));
    middle = _ssMedian3(td, pa, middle - t, middle, middle + t);
    last = _ssMedian3(td, pa, last - 1 - (t << 1), last - 1 - t, last - 1);
    return _ssMedian3(td, pa, first, middle, last);
  }

  @pragma('vm:unsafe:no-bounds-checks')
  int _ssPartition(int pa, int first, int last, int depth) {
    final sa = this.sa;
    var a = first - 1, b = last;
    for (;;) {
      for (; ++a < b && (sa[pa + sa[a]] + depth) >= (sa[pa + sa[a] + 1] + 1);) {
        sa[a] = ~sa[a];
      }
      for (; a < --b && (sa[pa + sa[b]] + depth) < (sa[pa + sa[b] + 1] + 1);) {}
      if (b <= a) break;
      final t = ~sa[b];
      sa[b] = sa[a];
      sa[a] = t;
    }
    if (first < a) sa[first] = ~sa[first];
    return a;
  }

  @pragma('vm:unsafe:no-bounds-checks')
  void _ssMintrosort(int pa, int first, int last, int depth) {
    final sa = this.sa, T = t;
    final stack = _misort;
    var ssize = 0;
    var limit = _ssIlg(last - first);
    int a, b, c, d, e, f, s, x = 0, v;

    for (;;) {
      if (last - first <= _ssInsertionsortThreshold) {
        if (1 < last - first) _ssInsertionsort(pa, first, last, depth);
        if (ssize == 0) return;
        --ssize;
        first = stack[ssize * 4];
        last = stack[ssize * 4 + 1];
        depth = stack[ssize * 4 + 2];
        limit = stack[ssize * 4 + 3];
        continue;
      }

      final td = depth;
      if (limit-- == 0) _ssHeapsort(td, pa, first, last - first);
      if (limit < 0) {
        a = first + 1;
        v = T[td + sa[pa + sa[first]]];
        for (; a < last; ++a) {
          if ((x = T[td + sa[pa + sa[a]]]) != v) {
            if (1 < a - first) break;
            v = x;
            first = a;
          }
        }
        if (T[td + sa[pa + sa[first]] - 1] < v) {
          first = _ssPartition(pa, first, a, depth);
        }
        if (a - first <= last - a) {
          if (1 < a - first) {
            stack[ssize * 4] = a;
            stack[ssize * 4 + 1] = last;
            stack[ssize * 4 + 2] = depth;
            stack[ssize * 4 + 3] = -1;
            ++ssize;
            last = a;
            depth += 1;
            limit = _ssIlg(a - first);
          } else {
            first = a;
            limit = -1;
          }
        } else {
          if (1 < last - a) {
            stack[ssize * 4] = first;
            stack[ssize * 4 + 1] = a;
            stack[ssize * 4 + 2] = depth + 1;
            stack[ssize * 4 + 3] = _ssIlg(a - first);
            ++ssize;
            first = a;
            limit = -1;
          } else {
            last = a;
            depth += 1;
            limit = _ssIlg(a - first);
          }
        }
        continue;
      }

      // choose pivot
      a = _ssPivot(td, pa, first, last);
      v = T[td + sa[pa + sa[a]]];
      var tt = sa[first];
      sa[first] = sa[a];
      sa[a] = tt;

      // partition
      for (b = first; ++b < last && (x = T[td + sa[pa + sa[b]]]) == v;) {}
      if ((a = b) < last && x < v) {
        for (; ++b < last && (x = T[td + sa[pa + sa[b]]]) <= v;) {
          if (x == v) {
            tt = sa[b];
            sa[b] = sa[a];
            sa[a] = tt;
            ++a;
          }
        }
      }
      for (c = last; b < --c && (x = T[td + sa[pa + sa[c]]]) == v;) {}
      if (b < (d = c) && x > v) {
        for (; b < --c && (x = T[td + sa[pa + sa[c]]]) >= v;) {
          if (x == v) {
            tt = sa[c];
            sa[c] = sa[d];
            sa[d] = tt;
            --d;
          }
        }
      }
      for (; b < c;) {
        tt = sa[b];
        sa[b] = sa[c];
        sa[c] = tt;
        for (; ++b < c && (x = T[td + sa[pa + sa[b]]]) <= v;) {
          if (x == v) {
            tt = sa[b];
            sa[b] = sa[a];
            sa[a] = tt;
            ++a;
          }
        }
        for (; b < --c && (x = T[td + sa[pa + sa[c]]]) >= v;) {
          if (x == v) {
            tt = sa[c];
            sa[c] = sa[d];
            sa[d] = tt;
            --d;
          }
        }
      }

      if (a <= d) {
        c = b - 1;
        var t2 = b - a;
        if ((s = a - first) > t2) s = t2;
        e = first;
        f = b - s;
        for (; 0 < s; --s, ++e, ++f) {
          tt = sa[e];
          sa[e] = sa[f];
          sa[f] = tt;
        }
        t2 = last - d - 1;
        if ((s = d - c) > t2) s = t2;
        e = b;
        f = last - s;
        for (; 0 < s; --s, ++e, ++f) {
          tt = sa[e];
          sa[e] = sa[f];
          sa[f] = tt;
        }

        a = first + (b - a);
        c = last - (d - c);
        b = (v <= T[td + sa[pa + sa[a]] - 1])
            ? a
            : _ssPartition(pa, a, c, depth);

        if (a - first <= last - c) {
          if (last - c <= c - b) {
            stack[ssize * 4] = b;
            stack[ssize * 4 + 1] = c;
            stack[ssize * 4 + 2] = depth + 1;
            stack[ssize * 4 + 3] = _ssIlg(c - b);
            ++ssize;
            stack[ssize * 4] = c;
            stack[ssize * 4 + 1] = last;
            stack[ssize * 4 + 2] = depth;
            stack[ssize * 4 + 3] = limit;
            ++ssize;
            last = a;
          } else if (a - first <= c - b) {
            stack[ssize * 4] = c;
            stack[ssize * 4 + 1] = last;
            stack[ssize * 4 + 2] = depth;
            stack[ssize * 4 + 3] = limit;
            ++ssize;
            stack[ssize * 4] = b;
            stack[ssize * 4 + 1] = c;
            stack[ssize * 4 + 2] = depth + 1;
            stack[ssize * 4 + 3] = _ssIlg(c - b);
            ++ssize;
            last = a;
          } else {
            stack[ssize * 4] = c;
            stack[ssize * 4 + 1] = last;
            stack[ssize * 4 + 2] = depth;
            stack[ssize * 4 + 3] = limit;
            ++ssize;
            stack[ssize * 4] = first;
            stack[ssize * 4 + 1] = a;
            stack[ssize * 4 + 2] = depth;
            stack[ssize * 4 + 3] = limit;
            ++ssize;
            first = b;
            last = c;
            depth += 1;
            limit = _ssIlg(c - b);
          }
        } else {
          if (a - first <= c - b) {
            stack[ssize * 4] = b;
            stack[ssize * 4 + 1] = c;
            stack[ssize * 4 + 2] = depth + 1;
            stack[ssize * 4 + 3] = _ssIlg(c - b);
            ++ssize;
            stack[ssize * 4] = first;
            stack[ssize * 4 + 1] = a;
            stack[ssize * 4 + 2] = depth;
            stack[ssize * 4 + 3] = limit;
            ++ssize;
            first = c;
          } else if (last - c <= c - b) {
            stack[ssize * 4] = first;
            stack[ssize * 4 + 1] = a;
            stack[ssize * 4 + 2] = depth;
            stack[ssize * 4 + 3] = limit;
            ++ssize;
            stack[ssize * 4] = b;
            stack[ssize * 4 + 1] = c;
            stack[ssize * 4 + 2] = depth + 1;
            stack[ssize * 4 + 3] = _ssIlg(c - b);
            ++ssize;
            first = c;
          } else {
            stack[ssize * 4] = first;
            stack[ssize * 4 + 1] = a;
            stack[ssize * 4 + 2] = depth;
            stack[ssize * 4 + 3] = limit;
            ++ssize;
            stack[ssize * 4] = c;
            stack[ssize * 4 + 1] = last;
            stack[ssize * 4 + 2] = depth;
            stack[ssize * 4 + 3] = limit;
            ++ssize;
            first = b;
            last = c;
            depth += 1;
            limit = _ssIlg(c - b);
          }
        }
      } else {
        limit += 1;
        if (T[td + sa[pa + sa[first]] - 1] < v) {
          first = _ssPartition(pa, first, last, depth);
          limit = _ssIlg(last - first);
        }
        depth += 1;
      }
    }
  }

  @pragma('vm:unsafe:no-bounds-checks')
  void _ssBlockswap(int a, int b, int n) {
    final sa = this.sa;
    for (; 0 < n; --n, ++a, ++b) {
      final t = sa[a];
      sa[a] = sa[b];
      sa[b] = t;
    }
  }

  @pragma('vm:unsafe:no-bounds-checks')
  void _ssRotate(int first, int middle, int last) {
    final sa = this.sa;
    int a, b, t;
    var l = middle - first, r = last - middle;
    for (; 0 < l && 0 < r;) {
      if (l == r) {
        _ssBlockswap(first, middle, l);
        break;
      }
      if (l < r) {
        a = last - 1;
        b = middle - 1;
        t = sa[a];
        for (;;) {
          sa[a--] = sa[b];
          sa[b--] = sa[a];
          if (b < first) {
            sa[a] = t;
            last = a;
            if ((r -= l + 1) <= l) break;
            a -= 1;
            b = middle - 1;
            t = sa[a];
          }
        }
      } else {
        a = first;
        b = middle;
        t = sa[a];
        for (;;) {
          sa[a++] = sa[b];
          sa[b++] = sa[a];
          if (last <= b) {
            sa[a] = t;
            first = a + 1;
            if ((l -= r + 1) <= r) break;
            a += 1;
            b = middle;
            t = sa[a];
          }
        }
      }
    }
  }

  @pragma('vm:unsafe:no-bounds-checks')
  void _ssInplacemerge(int pa, int first, int middle, int last, int depth) {
    final sa = this.sa;
    int p, a, b, len, half, q, r, x;
    for (;;) {
      if (sa[last - 1] < 0) {
        x = 1;
        p = pa + ~sa[last - 1];
      } else {
        x = 0;
        p = pa + sa[last - 1];
      }
      a = first;
      len = middle - first;
      half = len >> 1;
      r = -1;
      for (; 0 < len; len = half, half >>= 1) {
        b = a + half;
        q = _ssCompare(pa + ((0 <= sa[b]) ? sa[b] : ~sa[b]), p, depth);
        if (q < 0) {
          a = b + 1;
          half -= (len & 1) ^ 1;
        } else {
          r = q;
        }
      }
      if (a < middle) {
        if (r == 0) sa[a] = ~sa[a];
        _ssRotate(a, middle, last);
        last -= middle - a;
        middle = a;
        if (first == middle) break;
      }
      --last;
      if (x != 0) {
        while (sa[--last] < 0) {}
      }
      if (middle == last) break;
    }
  }

  @pragma('vm:unsafe:no-bounds-checks')
  void _ssMergeforward(
      int pa, int first, int middle, int last, int buf, int depth) {
    final sa = this.sa;
    final bufend = buf + (middle - first) - 1;
    _ssBlockswap(buf, first, middle - first);
    var a = first, b = buf, c = middle;
    final t = sa[a];
    for (;;) {
      final r = _ssCompare(pa + sa[b], pa + sa[c], depth);
      if (r < 0) {
        do {
          sa[a++] = sa[b];
          if (bufend <= b) {
            sa[bufend] = t;
            return;
          }
          sa[b++] = sa[a];
        } while (sa[b] < 0);
      } else if (r > 0) {
        do {
          sa[a++] = sa[c];
          sa[c++] = sa[a];
          if (last <= c) {
            while (b < bufend) {
              sa[a++] = sa[b];
              sa[b++] = sa[a];
            }
            sa[a] = sa[b];
            sa[b] = t;
            return;
          }
        } while (sa[c] < 0);
      } else {
        sa[c] = ~sa[c];
        do {
          sa[a++] = sa[b];
          if (bufend <= b) {
            sa[bufend] = t;
            return;
          }
          sa[b++] = sa[a];
        } while (sa[b] < 0);

        do {
          sa[a++] = sa[c];
          sa[c++] = sa[a];
          if (last <= c) {
            while (b < bufend) {
              sa[a++] = sa[b];
              sa[b++] = sa[a];
            }
            sa[a] = sa[b];
            sa[b] = t;
            return;
          }
        } while (sa[c] < 0);
      }
    }
  }

  @pragma('vm:unsafe:no-bounds-checks')
  void _ssMergebackward(
      int pa, int first, int middle, int last, int buf, int depth) {
    final sa = this.sa;
    int p1, p2;
    final bufend = buf + (last - middle) - 1;
    _ssBlockswap(buf, middle, last - middle);

    var x = 0;
    if (sa[bufend] < 0) {
      p1 = pa + ~sa[bufend];
      x |= 1;
    } else {
      p1 = pa + sa[bufend];
    }
    if (sa[middle - 1] < 0) {
      p2 = pa + ~sa[middle - 1];
      x |= 2;
    } else {
      p2 = pa + sa[middle - 1];
    }
    var a = last - 1, b = bufend, c = middle - 1;
    final t = sa[a];
    for (;;) {
      final r = _ssCompare(p1, p2, depth);
      if (0 < r) {
        if ((x & 1) != 0) {
          do {
            sa[a--] = sa[b];
            sa[b--] = sa[a];
          } while (sa[b] < 0);
          x ^= 1;
        }
        sa[a--] = sa[b];
        if (b <= buf) {
          sa[buf] = t;
          break;
        }
        sa[b--] = sa[a];
        if (sa[b] < 0) {
          p1 = pa + ~sa[b];
          x |= 1;
        } else {
          p1 = pa + sa[b];
        }
      } else if (r < 0) {
        if ((x & 2) != 0) {
          do {
            sa[a--] = sa[c];
            sa[c--] = sa[a];
          } while (sa[c] < 0);
          x ^= 2;
        }
        sa[a--] = sa[c];
        sa[c--] = sa[a];
        if (c < first) {
          while (buf < b) {
            sa[a--] = sa[b];
            sa[b--] = sa[a];
          }
          sa[a] = sa[b];
          sa[b] = t;
          break;
        }
        if (sa[c] < 0) {
          p2 = pa + ~sa[c];
          x |= 2;
        } else {
          p2 = pa + sa[c];
        }
      } else {
        if ((x & 1) != 0) {
          do {
            sa[a--] = sa[b];
            sa[b--] = sa[a];
          } while (sa[b] < 0);
          x ^= 1;
        }
        sa[a--] = ~sa[b];
        if (b <= buf) {
          sa[buf] = t;
          break;
        }
        sa[b--] = sa[a];
        if ((x & 2) != 0) {
          do {
            sa[a--] = sa[c];
            sa[c--] = sa[a];
          } while (sa[c] < 0);
          x ^= 2;
        }
        sa[a--] = sa[c];
        sa[c--] = sa[a];
        if (c < first) {
          while (buf < b) {
            sa[a--] = sa[b];
            sa[b--] = sa[a];
          }
          sa[a] = sa[b];
          sa[b] = t;
          break;
        }
        if (sa[b] < 0) {
          p1 = pa + ~sa[b];
          x |= 1;
        } else {
          p1 = pa + sa[b];
        }
        if (sa[c] < 0) {
          p2 = pa + ~sa[c];
          x |= 2;
        } else {
          p2 = pa + sa[c];
        }
      }
    }
  }

  @pragma('vm:unsafe:no-bounds-checks')
  static int _getIdx(int a) => (0 <= a) ? a : ~a;

  @pragma('vm:unsafe:no-bounds-checks')
  void _mergeCheck(int pa, int a, int b, int c, int depth) {
    final sa = this.sa;
    if ((c & 1) != 0 ||
        ((c & 2) != 0 &&
            _ssCompare(pa + _getIdx(sa[a - 1]), pa + sa[a], depth) == 0)) {
      sa[a] = ~sa[a];
    }
    if ((c & 4) != 0 &&
        _ssCompare(pa + _getIdx(sa[b - 1]), pa + sa[b], depth) == 0) {
      sa[b] = ~sa[b];
    }
  }

  @pragma('vm:unsafe:no-bounds-checks')
  void _ssSwapmerge(int pa, int first, int middle, int last, int buf,
      int bufsize, int depth) {
    final sa = this.sa;
    final stack = _smerge;
    int l, r, lm, rm, m, len, half, next;
    var ssize = 0, check = 0;

    for (;;) {
      if (last - middle <= bufsize) {
        if (first < middle && middle < last) {
          _ssMergebackward(pa, first, middle, last, buf, depth);
        }
        _mergeCheck(pa, first, last, check, depth);
        if (ssize == 0) return;
        --ssize;
        first = stack[ssize * 4];
        middle = stack[ssize * 4 + 1];
        last = stack[ssize * 4 + 2];
        check = stack[ssize * 4 + 3];
        continue;
      }

      if (middle - first <= bufsize) {
        if (first < middle) {
          _ssMergeforward(pa, first, middle, last, buf, depth);
        }
        _mergeCheck(pa, first, last, check, depth);
        if (ssize == 0) return;
        --ssize;
        first = stack[ssize * 4];
        middle = stack[ssize * 4 + 1];
        last = stack[ssize * 4 + 2];
        check = stack[ssize * 4 + 3];
        continue;
      }

      final ml = middle - first, mr = last - middle;
      m = 0;
      len = ml < mr ? ml : mr;
      half = len >> 1;
      for (; 0 < len; len = half, half >>= 1) {
        if (_ssCompare(pa + _getIdx(sa[middle + m + half]),
                pa + _getIdx(sa[middle - m - half - 1]), depth) <
            0) {
          m += half + 1;
          half -= (len & 1) ^ 1;
        }
      }

      if (0 < m) {
        lm = middle - m;
        rm = middle + m;
        _ssBlockswap(lm, middle, m);
        l = r = middle;
        next = 0;
        if (rm < last) {
          if (sa[rm] < 0) {
            sa[rm] = ~sa[rm];
            if (first < lm) {
              for (; sa[--l] < 0;) {}
              next |= 4;
            }
            next |= 1;
          } else if (first < lm) {
            for (; sa[r] < 0; ++r) {}
            next |= 2;
          }
        }

        if (l - first <= last - r) {
          stack[ssize * 4] = r;
          stack[ssize * 4 + 1] = rm;
          stack[ssize * 4 + 2] = last;
          stack[ssize * 4 + 3] = (next & 3) | (check & 4);
          ++ssize;
          middle = lm;
          last = l;
          check = (check & 3) | (next & 4);
        } else {
          if ((next & 2) != 0 && r == middle) next ^= 6;
          stack[ssize * 4] = first;
          stack[ssize * 4 + 1] = lm;
          stack[ssize * 4 + 2] = l;
          stack[ssize * 4 + 3] = (check & 3) | (next & 4);
          ++ssize;
          first = r;
          middle = rm;
          check = (next & 3) | (check & 4);
        }
      } else {
        if (_ssCompare(pa + _getIdx(sa[middle - 1]), pa + sa[middle], depth) ==
            0) {
          sa[middle] = ~sa[middle];
        }
        _mergeCheck(pa, first, last, check, depth);
        if (ssize == 0) return;
        --ssize;
        first = stack[ssize * 4];
        middle = stack[ssize * 4 + 1];
        last = stack[ssize * 4 + 2];
        check = stack[ssize * 4 + 3];
      }
    }
  }

  @pragma('vm:unsafe:no-bounds-checks')
  void _sssort(int pa, int first, int last, int buf, int bufsize, int depth,
      int n, bool lastsuffix) {
    final sa = this.sa;
    int a, b, middle, curbuf, j, k, curbufsize, limit, i;
    if (lastsuffix) ++first;

    if (bufsize < _ssBlocksize &&
        bufsize < last - first &&
        bufsize < (limit = _ssIsqrt(last - first))) {
      if (_ssBlocksize < limit) limit = _ssBlocksize;
      buf = middle = last - limit;
      bufsize = limit;
    } else {
      middle = last;
      limit = 0;
    }
    a = first;
    i = 0;
    for (; _ssBlocksize < middle - a; a += _ssBlocksize, ++i) {
      _ssMintrosort(pa, a, a + _ssBlocksize, depth);
      curbufsize = last - (a + _ssBlocksize);
      curbuf = a + _ssBlocksize;
      if (curbufsize <= bufsize) {
        curbufsize = bufsize;
        curbuf = buf;
      }
      b = a;
      k = _ssBlocksize;
      j = i;
      for (; (j & 1) != 0; b -= k, k <<= 1, j >>= 1) {
        _ssSwapmerge(pa, b - k, b, b + k, curbuf, curbufsize, depth);
      }
    }
    _ssMintrosort(pa, a, middle, depth);
    for (k = _ssBlocksize; i != 0; k <<= 1, i >>= 1) {
      if ((i & 1) != 0) {
        _ssSwapmerge(pa, a - k, a, middle, buf, bufsize, depth);
        a -= k;
      }
    }
    if (limit != 0) {
      _ssMintrosort(pa, middle, last, depth);
      _ssInplacemerge(pa, first, middle, last, depth);
    }

    if (lastsuffix) {
      // Insert last type B* suffix.
      final pai0 = sa[pa + sa[first - 1]], pai1 = n - 2;
      i = sa[first - 1];
      for (a = first;
          a < last &&
              (sa[a] < 0 ||
                  0 <
                      _ssCompareV(pai0, pai1, sa[pa + sa[a]],
                          sa[pa + sa[a] + 1], depth));
          ++a) {
        sa[a - 1] = sa[a];
      }
      sa[a - 1] = i;
    }
  }

  // ---------------------------------------------------------------- trsort

  @pragma('vm:unsafe:no-bounds-checks')
  void _trInsertionsort(int isad, int first, int last) {
    final sa = this.sa;
    int r = 0;
    for (var a = first + 1; a < last; ++a) {
      final t = sa[a];
      var b = a - 1;
      for (; 0 > (r = sa[isad + t] - sa[isad + sa[b]]);) {
        do {
          sa[b + 1] = sa[b];
        } while (first <= --b && sa[b] < 0);
        if (b < first) break;
      }
      if (r == 0) sa[b] = ~sa[b];
      sa[b + 1] = t;
    }
  }

  @pragma('vm:unsafe:no-bounds-checks')
  void _trFixdown(int isad, int base, int i, int size) {
    final sa = this.sa;
    final v = sa[base + i];
    final c = sa[isad + v];
    int j, k;
    while ((j = 2 * i + 1) < size) {
      k = j++;
      var d = sa[isad + sa[base + k]];
      final e = sa[isad + sa[base + j]];
      if (d < e) {
        k = j;
        d = e;
      }
      if (d <= c) break;
      sa[base + i] = sa[base + k];
      i = k;
    }
    sa[base + i] = v;
  }

  @pragma('vm:unsafe:no-bounds-checks')
  void _trHeapsort(int isad, int base, int size) {
    final sa = this.sa;
    var m = size;
    if ((size % 2) == 0) {
      m--;
      if (sa[isad + sa[base + m ~/ 2]] < sa[isad + sa[base + m]]) {
        final x = sa[base + m];
        sa[base + m] = sa[base + m ~/ 2];
        sa[base + m ~/ 2] = x;
      }
    }
    for (var i = m ~/ 2 - 1; 0 <= i; --i) {
      _trFixdown(isad, base, i, m);
    }
    if ((size % 2) == 0) {
      final x = sa[base];
      sa[base] = sa[base + m];
      sa[base + m] = x;
      _trFixdown(isad, base, 0, m);
    }
    for (var i = m - 1; 0 < i; --i) {
      final x = sa[base];
      sa[base] = sa[base + i];
      _trFixdown(isad, base, 0, i);
      sa[base + i] = x;
    }
  }

  @pragma('vm:unsafe:no-bounds-checks')
  int _trV(int isad, int p) => sa[isad + sa[p]];

  int _trMedian3(int isad, int v1, int v2, int v3) {
    if (_trV(isad, v1) > _trV(isad, v2)) {
      final x = v1;
      v1 = v2;
      v2 = x;
    }
    if (_trV(isad, v2) > _trV(isad, v3)) {
      return _trV(isad, v1) > _trV(isad, v3) ? v1 : v3;
    }
    return v2;
  }

  int _trMedian5(int isad, int v1, int v2, int v3, int v4, int v5) {
    int x;
    if (_trV(isad, v2) > _trV(isad, v3)) {
      x = v2;
      v2 = v3;
      v3 = x;
    }
    if (_trV(isad, v4) > _trV(isad, v5)) {
      x = v4;
      v4 = v5;
      v5 = x;
    }
    if (_trV(isad, v2) > _trV(isad, v4)) {
      x = v2;
      v2 = v4;
      v4 = x;
      x = v3;
      v3 = v5;
      v5 = x;
    }
    if (_trV(isad, v1) > _trV(isad, v3)) {
      x = v1;
      v1 = v3;
      v3 = x;
    }
    if (_trV(isad, v1) > _trV(isad, v4)) {
      x = v1;
      v1 = v4;
      v4 = x;
      x = v3;
      v3 = v5;
      v5 = x;
    }
    if (_trV(isad, v3) > _trV(isad, v4)) return v4;
    return v3;
  }

  @pragma('vm:unsafe:no-bounds-checks')
  int _trPivot(int isad, int first, int last) {
    var t = last - first;
    var middle = first + t ~/ 2;
    if (t <= 512) {
      if (t <= 32) return _trMedian3(isad, first, middle, last - 1);
      t >>= 2;
      return _trMedian5(isad, first, first + t, middle, last - 1 - t, last - 1);
    }
    t >>= 3;
    first = _trMedian3(isad, first, first + t, first + (t << 1));
    middle = _trMedian3(isad, middle - t, middle, middle + t);
    last = _trMedian3(isad, last - 1 - (t << 1), last - 1 - t, last - 1);
    return _trMedian3(isad, first, middle, last);
  }

  @pragma('vm:unsafe:no-bounds-checks')
  bool _budgetCheck(int size) {
    if (size <= _remain) {
      _remain -= size;
      return true;
    }
    if (_chance == 0) {
      _count += size;
      return false;
    }
    _remain += _incval - size;
    _chance -= 1;
    return true;
  }

  // Results of _trPartition.
  int _pa = 0, _pb = 0;

  @pragma('vm:unsafe:no-bounds-checks')
  void _trPartition(int isad, int first, int middle, int last, int v) {
    final sa = this.sa;
    int a, b, c, d, e, f, s, t, x = 0;
    for (b = middle - 1; ++b < last && (x = sa[isad + sa[b]]) == v;) {}
    if ((a = b) < last && x < v) {
      for (; ++b < last && (x = sa[isad + sa[b]]) <= v;) {
        if (x == v) {
          t = sa[b];
          sa[b] = sa[a];
          sa[a] = t;
          ++a;
        }
      }
    }
    for (c = last; b < --c && (x = sa[isad + sa[c]]) == v;) {}
    if (b < (d = c) && x > v) {
      for (; b < --c && (x = sa[isad + sa[c]]) >= v;) {
        if (x == v) {
          t = sa[c];
          sa[c] = sa[d];
          sa[d] = t;
          --d;
        }
      }
    }
    for (; b < c;) {
      t = sa[b];
      sa[b] = sa[c];
      sa[c] = t;
      for (; ++b < c && (x = sa[isad + sa[b]]) <= v;) {
        if (x == v) {
          t = sa[b];
          sa[b] = sa[a];
          sa[a] = t;
          ++a;
        }
      }
      for (; b < --c && (x = sa[isad + sa[c]]) >= v;) {
        if (x == v) {
          t = sa[c];
          sa[c] = sa[d];
          sa[d] = t;
          --d;
        }
      }
    }

    if (a <= d) {
      c = b - 1;
      var t2 = b - a;
      if ((s = a - first) > t2) s = t2;
      e = first;
      f = b - s;
      for (; 0 < s; --s, ++e, ++f) {
        t = sa[e];
        sa[e] = sa[f];
        sa[f] = t;
      }
      t2 = last - d - 1;
      if ((s = d - c) > t2) s = t2;
      e = b;
      f = last - s;
      for (; 0 < s; --s, ++e, ++f) {
        t = sa[e];
        sa[e] = sa[f];
        sa[f] = t;
      }
      first += b - a;
      last -= d - c;
    }
    _pa = first;
    _pb = last;
  }

  @pragma('vm:unsafe:no-bounds-checks')
  void _trCopy(int isa, int first, int a, int b, int last, int depth) {
    final sa = this.sa;
    int c, d, e, s;
    final v = b - 1;
    c = first;
    d = a - 1;
    for (; c <= d; ++c) {
      if (0 <= (s = sa[c] - depth) && sa[isa + s] == v) {
        sa[++d] = s;
        sa[isa + s] = d;
      }
    }
    c = last - 1;
    e = d + 1;
    d = b;
    for (; e < d; --c) {
      if (0 <= (s = sa[c] - depth) && sa[isa + s] == v) {
        sa[--d] = s;
        sa[isa + s] = d;
      }
    }
  }

  @pragma('vm:unsafe:no-bounds-checks')
  void _trPartialcopy(int isa, int first, int a, int b, int last, int depth) {
    final sa = this.sa;
    int c, d, e, s, rank;
    var lastrank = -1, newrank = -1;
    final v = b - 1;
    c = first;
    d = a - 1;
    for (; c <= d; ++c) {
      if (0 <= (s = sa[c] - depth) && sa[isa + s] == v) {
        sa[++d] = s;
        rank = sa[isa + s + depth];
        if (lastrank != rank) {
          lastrank = rank;
          newrank = d;
        }
        sa[isa + s] = newrank;
      }
    }

    lastrank = -1;
    for (e = d; first <= e; --e) {
      rank = sa[isa + sa[e]];
      if (lastrank != rank) {
        lastrank = rank;
        newrank = e;
      }
      if (newrank != rank) sa[isa + sa[e]] = newrank;
    }

    lastrank = -1;
    c = last - 1;
    e = d + 1;
    d = b;
    for (; e < d; --c) {
      if (0 <= (s = sa[c] - depth) && sa[isa + s] == v) {
        sa[--d] = s;
        rank = sa[isa + s + depth];
        if (lastrank != rank) {
          lastrank = rank;
          newrank = d;
        }
        sa[isa + s] = newrank;
      }
    }
  }

  @pragma('vm:unsafe:no-bounds-checks')
  void _trIntrosort(int isa, int isad, int first, int last) {
    final sa = this.sa;
    final stack = _trstack;
    int a, b, c, t, v, x = 0, next;
    final incr = isad - isa;
    var ssize = 0, trlink = -1;
    var limit = _trIlg(last - first);

    for (;;) {
      if (limit < 0) {
        if (limit == -1) {
          // tandem repeat partition
          _trPartition(isad - incr, first, first, last, last - 1);
          a = _pa;
          b = _pb;

          // update ranks
          if (a < last) {
            c = first;
            v = a - 1;
            for (; c < a; ++c) {
              sa[isa + sa[c]] = v;
            }
          }
          if (b < last) {
            c = a;
            v = b - 1;
            for (; c < b; ++c) {
              sa[isa + sa[c]] = v;
            }
          }

          // push
          if (1 < b - a) {
            stack[ssize * 5] = 0;
            stack[ssize * 5 + 1] = a;
            stack[ssize * 5 + 2] = b;
            stack[ssize * 5 + 3] = 0;
            stack[ssize * 5 + 4] = 0;
            ++ssize;
            stack[ssize * 5] = isad - incr;
            stack[ssize * 5 + 1] = first;
            stack[ssize * 5 + 2] = last;
            stack[ssize * 5 + 3] = -2;
            stack[ssize * 5 + 4] = trlink;
            ++ssize;
            trlink = ssize - 2;
          }
          if (a - first <= last - b) {
            if (1 < a - first) {
              stack[ssize * 5] = isad;
              stack[ssize * 5 + 1] = b;
              stack[ssize * 5 + 2] = last;
              stack[ssize * 5 + 3] = _trIlg(last - b);
              stack[ssize * 5 + 4] = trlink;
              ++ssize;
              last = a;
              limit = _trIlg(a - first);
            } else if (1 < last - b) {
              first = b;
              limit = _trIlg(last - b);
            } else {
              if (ssize == 0) return;
              --ssize;
              final o = ssize * 5;
              isad = stack[o];
              first = stack[o + 1];
              last = stack[o + 2];
              limit = stack[o + 3];
              trlink = stack[o + 4];
            }
          } else {
            if (1 < last - b) {
              stack[ssize * 5] = isad;
              stack[ssize * 5 + 1] = first;
              stack[ssize * 5 + 2] = a;
              stack[ssize * 5 + 3] = _trIlg(a - first);
              stack[ssize * 5 + 4] = trlink;
              ++ssize;
              first = b;
              limit = _trIlg(last - b);
            } else if (1 < a - first) {
              last = a;
              limit = _trIlg(a - first);
            } else {
              if (ssize == 0) return;
              --ssize;
              final o = ssize * 5;
              isad = stack[o];
              first = stack[o + 1];
              last = stack[o + 2];
              limit = stack[o + 3];
              trlink = stack[o + 4];
            }
          }
        } else if (limit == -2) {
          // tandem repeat copy
          --ssize;
          a = stack[ssize * 5 + 1];
          b = stack[ssize * 5 + 2];
          if (stack[ssize * 5 + 3] == 0) {
            _trCopy(isa, first, a, b, last, isad - isa);
          } else {
            if (0 <= trlink) stack[trlink * 5 + 3] = -1;
            _trPartialcopy(isa, first, a, b, last, isad - isa);
          }
          if (ssize == 0) return;
          --ssize;
          final o = ssize * 5;
          isad = stack[o];
          first = stack[o + 1];
          last = stack[o + 2];
          limit = stack[o + 3];
          trlink = stack[o + 4];
        } else {
          // sorted partition
          if (0 <= sa[first]) {
            a = first;
            do {
              sa[isa + sa[a]] = a;
            } while (++a < last && 0 <= sa[a]);
            first = a;
          }
          if (first < last) {
            a = first;
            do {
              sa[a] = ~sa[a];
            } while (sa[++a] < 0);
            next = (sa[isa + sa[a]] != sa[isad + sa[a]])
                ? _trIlg(a - first + 1)
                : -1;
            if (++a < last) {
              b = first;
              v = a - 1;
              for (; b < a; ++b) {
                sa[isa + sa[b]] = v;
              }
            }

            // push
            if (_budgetCheck(a - first)) {
              if (a - first <= last - a) {
                stack[ssize * 5] = isad;
                stack[ssize * 5 + 1] = a;
                stack[ssize * 5 + 2] = last;
                stack[ssize * 5 + 3] = -3;
                stack[ssize * 5 + 4] = trlink;
                ++ssize;
                isad += incr;
                last = a;
                limit = next;
              } else {
                if (1 < last - a) {
                  stack[ssize * 5] = isad + incr;
                  stack[ssize * 5 + 1] = first;
                  stack[ssize * 5 + 2] = a;
                  stack[ssize * 5 + 3] = next;
                  stack[ssize * 5 + 4] = trlink;
                  ++ssize;
                  first = a;
                  limit = -3;
                } else {
                  isad += incr;
                  last = a;
                  limit = next;
                }
              }
            } else {
              if (0 <= trlink) stack[trlink * 5 + 3] = -1;
              if (1 < last - a) {
                first = a;
                limit = -3;
              } else {
                if (ssize == 0) return;
                --ssize;
                final o = ssize * 5;
                isad = stack[o];
                first = stack[o + 1];
                last = stack[o + 2];
                limit = stack[o + 3];
                trlink = stack[o + 4];
              }
            }
          } else {
            if (ssize == 0) return;
            --ssize;
            final o = ssize * 5;
            isad = stack[o];
            first = stack[o + 1];
            last = stack[o + 2];
            limit = stack[o + 3];
            trlink = stack[o + 4];
          }
        }
        continue;
      }

      if (last - first <= _trInsertionsortThreshold) {
        _trInsertionsort(isad, first, last);
        limit = -3;
        continue;
      }

      if (limit-- == 0) {
        _trHeapsort(isad, first, last - first);
        for (a = last - 1; first < a; a = b) {
          x = sa[isad + sa[a]];
          b = a - 1;
          for (; first <= b && sa[isad + sa[b]] == x; --b) {
            sa[b] = ~sa[b];
          }
        }
        limit = -3;
        continue;
      }

      // choose pivot
      a = _trPivot(isad, first, last);
      t = sa[first];
      sa[first] = sa[a];
      sa[a] = t;
      v = sa[isad + sa[first]];

      // partition
      _trPartition(isad, first, first + 1, last, v);
      a = _pa;
      b = _pb;
      if (last - first != b - a) {
        next = (sa[isa + sa[a]] != v) ? _trIlg(b - a) : -1;

        // update ranks
        c = first;
        v = a - 1;
        for (; c < a; ++c) {
          sa[isa + sa[c]] = v;
        }
        if (b < last) {
          c = a;
          v = b - 1;
          for (; c < b; ++c) {
            sa[isa + sa[c]] = v;
          }
        }

        // push
        if (1 < b - a && _budgetCheck(b - a)) {
          if (a - first <= last - b) {
            if (last - b <= b - a) {
              if (1 < a - first) {
                stack[ssize * 5] = isad + incr;
                stack[ssize * 5 + 1] = a;
                stack[ssize * 5 + 2] = b;
                stack[ssize * 5 + 3] = next;
                stack[ssize * 5 + 4] = trlink;
                ++ssize;
                stack[ssize * 5] = isad;
                stack[ssize * 5 + 1] = b;
                stack[ssize * 5 + 2] = last;
                stack[ssize * 5 + 3] = limit;
                stack[ssize * 5 + 4] = trlink;
                ++ssize;
                last = a;
              } else if (1 < last - b) {
                stack[ssize * 5] = isad + incr;
                stack[ssize * 5 + 1] = a;
                stack[ssize * 5 + 2] = b;
                stack[ssize * 5 + 3] = next;
                stack[ssize * 5 + 4] = trlink;
                ++ssize;
                first = b;
              } else {
                isad += incr;
                first = a;
                last = b;
                limit = next;
              }
            } else if (a - first <= b - a) {
              if (1 < a - first) {
                stack[ssize * 5] = isad;
                stack[ssize * 5 + 1] = b;
                stack[ssize * 5 + 2] = last;
                stack[ssize * 5 + 3] = limit;
                stack[ssize * 5 + 4] = trlink;
                ++ssize;
                stack[ssize * 5] = isad + incr;
                stack[ssize * 5 + 1] = a;
                stack[ssize * 5 + 2] = b;
                stack[ssize * 5 + 3] = next;
                stack[ssize * 5 + 4] = trlink;
                ++ssize;
                last = a;
              } else {
                stack[ssize * 5] = isad;
                stack[ssize * 5 + 1] = b;
                stack[ssize * 5 + 2] = last;
                stack[ssize * 5 + 3] = limit;
                stack[ssize * 5 + 4] = trlink;
                ++ssize;
                isad += incr;
                first = a;
                last = b;
                limit = next;
              }
            } else {
              stack[ssize * 5] = isad;
              stack[ssize * 5 + 1] = b;
              stack[ssize * 5 + 2] = last;
              stack[ssize * 5 + 3] = limit;
              stack[ssize * 5 + 4] = trlink;
              ++ssize;
              stack[ssize * 5] = isad;
              stack[ssize * 5 + 1] = first;
              stack[ssize * 5 + 2] = a;
              stack[ssize * 5 + 3] = limit;
              stack[ssize * 5 + 4] = trlink;
              ++ssize;
              isad += incr;
              first = a;
              last = b;
              limit = next;
            }
          } else {
            if (a - first <= b - a) {
              if (1 < last - b) {
                stack[ssize * 5] = isad + incr;
                stack[ssize * 5 + 1] = a;
                stack[ssize * 5 + 2] = b;
                stack[ssize * 5 + 3] = next;
                stack[ssize * 5 + 4] = trlink;
                ++ssize;
                stack[ssize * 5] = isad;
                stack[ssize * 5 + 1] = first;
                stack[ssize * 5 + 2] = a;
                stack[ssize * 5 + 3] = limit;
                stack[ssize * 5 + 4] = trlink;
                ++ssize;
                first = b;
              } else if (1 < a - first) {
                stack[ssize * 5] = isad + incr;
                stack[ssize * 5 + 1] = a;
                stack[ssize * 5 + 2] = b;
                stack[ssize * 5 + 3] = next;
                stack[ssize * 5 + 4] = trlink;
                ++ssize;
                last = a;
              } else {
                isad += incr;
                first = a;
                last = b;
                limit = next;
              }
            } else if (last - b <= b - a) {
              if (1 < last - b) {
                stack[ssize * 5] = isad;
                stack[ssize * 5 + 1] = first;
                stack[ssize * 5 + 2] = a;
                stack[ssize * 5 + 3] = limit;
                stack[ssize * 5 + 4] = trlink;
                ++ssize;
                stack[ssize * 5] = isad + incr;
                stack[ssize * 5 + 1] = a;
                stack[ssize * 5 + 2] = b;
                stack[ssize * 5 + 3] = next;
                stack[ssize * 5 + 4] = trlink;
                ++ssize;
                first = b;
              } else {
                stack[ssize * 5] = isad;
                stack[ssize * 5 + 1] = first;
                stack[ssize * 5 + 2] = a;
                stack[ssize * 5 + 3] = limit;
                stack[ssize * 5 + 4] = trlink;
                ++ssize;
                isad += incr;
                first = a;
                last = b;
                limit = next;
              }
            } else {
              stack[ssize * 5] = isad;
              stack[ssize * 5 + 1] = first;
              stack[ssize * 5 + 2] = a;
              stack[ssize * 5 + 3] = limit;
              stack[ssize * 5 + 4] = trlink;
              ++ssize;
              stack[ssize * 5] = isad;
              stack[ssize * 5 + 1] = b;
              stack[ssize * 5 + 2] = last;
              stack[ssize * 5 + 3] = limit;
              stack[ssize * 5 + 4] = trlink;
              ++ssize;
              isad += incr;
              first = a;
              last = b;
              limit = next;
            }
          }
        } else {
          if (1 < b - a && 0 <= trlink) stack[trlink * 5 + 3] = -1;
          if (a - first <= last - b) {
            if (1 < a - first) {
              stack[ssize * 5] = isad;
              stack[ssize * 5 + 1] = b;
              stack[ssize * 5 + 2] = last;
              stack[ssize * 5 + 3] = limit;
              stack[ssize * 5 + 4] = trlink;
              ++ssize;
              last = a;
            } else if (1 < last - b) {
              first = b;
            } else {
              if (ssize == 0) return;
              --ssize;
              final o = ssize * 5;
              isad = stack[o];
              first = stack[o + 1];
              last = stack[o + 2];
              limit = stack[o + 3];
              trlink = stack[o + 4];
            }
          } else {
            if (1 < last - b) {
              stack[ssize * 5] = isad;
              stack[ssize * 5 + 1] = first;
              stack[ssize * 5 + 2] = a;
              stack[ssize * 5 + 3] = limit;
              stack[ssize * 5 + 4] = trlink;
              ++ssize;
              first = b;
            } else if (1 < a - first) {
              last = a;
            } else {
              if (ssize == 0) return;
              --ssize;
              final o = ssize * 5;
              isad = stack[o];
              first = stack[o + 1];
              last = stack[o + 2];
              limit = stack[o + 3];
              trlink = stack[o + 4];
            }
          }
        }
      } else {
        if (_budgetCheck(last - first)) {
          limit = _trIlg(last - first);
          isad += incr;
        } else {
          if (0 <= trlink) stack[trlink * 5 + 3] = -1;
          if (ssize == 0) return;
          --ssize;
          final o = ssize * 5;
          isad = stack[o];
          first = stack[o + 1];
          last = stack[o + 2];
          limit = stack[o + 3];
          trlink = stack[o + 4];
        }
      }
    }
  }

  /// Tandem repeat sort. The suffix array part is sa[0..n), ISA at [isa].
  @pragma('vm:unsafe:no-bounds-checks')
  void _trsort(int isa, int n, int depth) {
    final sa = this.sa;
    _chance = _trIlg(n) * 2 ~/ 3;
    _remain = _incval = n;
    for (var isad = isa + depth; -n < sa[0]; isad += isad - isa) {
      var first = 0;
      var skip = 0;
      var unsorted = 0;
      do {
        final t = sa[first];
        if (t < 0) {
          first -= t;
          skip += t;
        } else {
          if (skip != 0) {
            sa[first + skip] = skip;
            skip = 0;
          }
          final last = sa[isa + t] + 1;
          if (1 < last - first) {
            _count = 0;
            _trIntrosort(isa, isad, first, last);
            if (_count != 0) {
              unsorted += _count;
            } else {
              skip = first - last;
            }
          } else if (last - first == 1) {
            skip = -1;
          }
          first = last;
        }
      } while (first < n);
      if (skip != 0) sa[first + skip] = skip;
      if (unsorted == 0) break;
    }
  }

  // ------------------------------------------------------------ top level

  @pragma('vm:unsafe:no-bounds-checks')
  int sortTypeBstar(int n) {
    final T = t, sa = this.sa;
    final bA = bucketA, bB = bucketB;
    int i, j, k, t2, m, c0, c1;

    // Count the first one or two characters of each type A, B and B*
    // suffix, and store the positions of the type B* suffixes.
    i = n - 1;
    m = n;
    c0 = T[n - 1];
    for (; 0 <= i;) {
      // type A suffix
      do {
        ++bA[c1 = c0];
      } while (0 <= --i && (c0 = T[i]) >= c1);
      if (0 <= i) {
        // type B* suffix
        ++bB[(c0 << 8) | c1];
        sa[--m] = i;
        // type B suffix
        --i;
        c1 = c0;
        for (; 0 <= i && (c0 = T[i]) <= c1; --i, c1 = c0) {
          ++bB[(c1 << 8) | c0];
        }
      }
    }
    m = n - m;

    // Start/end point of each bucket.
    c0 = 0;
    i = 0;
    j = 0;
    for (; c0 < 256; ++c0) {
      t2 = i + bA[c0];
      bA[c0] = i + j; // start point
      i = t2 + bB[(c0 << 8) | c0];
      for (c1 = c0 + 1; c1 < 256; ++c1) {
        j += bB[(c0 << 8) | c1];
        bB[(c0 << 8) | c1] = j; // end point
        i += bB[(c1 << 8) | c0];
      }
    }

    if (0 < m) {
      // Sort the type B* suffixes by their first two characters.
      final pab = n - m, isab = m;
      for (i = m - 2; 0 <= i; --i) {
        t2 = sa[pab + i];
        c0 = T[t2];
        c1 = T[t2 + 1];
        sa[--bB[(c0 << 8) | c1]] = i;
      }
      t2 = sa[pab + m - 1];
      c0 = T[t2];
      c1 = T[t2 + 1];
      sa[--bB[(c0 << 8) | c1]] = m - 1;

      // Sort the type B* substrings using sssort.
      final buf = m, bufsize = n - 2 * m;
      c0 = 254;
      j = m;
      for (; 0 < j; --c0) {
        for (c1 = 255; c0 < c1; j = i, --c1) {
          i = bB[(c0 << 8) | c1];
          if (1 < j - i) {
            _sssort(pab, i, j, buf, bufsize, 2, n, sa[i] == m - 1);
          }
        }
      }

      // Compute ranks of type B* substrings.
      for (i = m - 1; 0 <= i; --i) {
        if (0 <= sa[i]) {
          j = i;
          do {
            sa[isab + sa[i]] = i;
          } while (0 <= --i && 0 <= sa[i]);
          sa[i + 1] = i - j;
          if (i <= 0) break;
        }
        j = i;
        do {
          sa[isab + (sa[i] = ~sa[i])] = j;
        } while (sa[--i] < 0);
        sa[isab + sa[i]] = j;
      }

      // Construct the inverse suffix array of type B* suffixes (trsort).
      _trsort(isab, m, 1);

      // Set the sorted order of type B* suffixes.
      i = n - 1;
      j = m;
      c0 = T[n - 1];
      for (; 0 <= i;) {
        --i;
        c1 = c0;
        for (; 0 <= i && (c0 = T[i]) >= c1; --i, c1 = c0) {}
        if (0 <= i) {
          t2 = i;
          --i;
          c1 = c0;
          for (; 0 <= i && (c0 = T[i]) <= c1; --i, c1 = c0) {}
          sa[sa[isab + --j]] = (t2 == 0 || 1 < t2 - i) ? t2 : ~t2;
        }
      }

      // Start/end point of each bucket.
      bB[(255 << 8) | 255] = n; // end point
      c0 = 254;
      k = m - 1;
      for (; 0 <= c0; --c0) {
        i = bA[c0 + 1] - 1;
        for (c1 = 255; c0 < c1; --c1) {
          t2 = i - bB[(c1 << 8) | c0];
          bB[(c1 << 8) | c0] = i; // end point

          // Move all type B* suffixes to the correct position.
          i = t2;
          j = bB[(c0 << 8) | c1];
          for (; j <= k; --i, --k) {
            sa[i] = sa[k];
          }
        }
        bB[(c0 << 8) | (c0 + 1)] = i - bB[(c0 << 8) | c0] + 1; // start
        bB[(c0 << 8) | c0] = i; // end point
      }
    }
    return m;
  }

  @pragma('vm:unsafe:no-bounds-checks')
  void constructSA(int n, int m) {
    final T = t, sa = this.sa;
    final bA = bucketA, bB = bucketB;
    int i, j, k, s, c0, c1, c2;

    if (0 < m) {
      // Sorted order of type B suffixes from that of type B* suffixes.
      for (c1 = 254; 0 <= c1; --c1) {
        // Scan the suffix array from right to left.
        i = bB[(c1 << 8) | (c1 + 1)];
        j = bA[c1 + 1] - 1;
        k = -1;
        c2 = -1;
        for (; i <= j; --j) {
          if (0 < (s = sa[j])) {
            sa[j] = ~s;
            c0 = T[--s];
            if (0 < s && T[s - 1] > c0) s = ~s;
            if (c0 != c2) {
              if (0 <= c2) bB[(c1 << 8) | c2] = k;
              k = bB[(c1 << 8) | (c2 = c0)];
            }
            sa[k--] = s;
          } else {
            sa[j] = ~s;
          }
        }
      }
    }

    // The suffix array from the sorted order of type B suffixes.
    k = bA[c2 = T[n - 1]];
    sa[k++] = (T[n - 2] < c2) ? ~(n - 1) : (n - 1);
    // Scan the suffix array from left to right.
    i = 0;
    j = n;
    for (; i < j; ++i) {
      if (0 < (s = sa[i])) {
        c0 = T[--s];
        if (s == 0 || T[s - 1] < c0) s = ~s;
        if (c0 != c2) {
          bA[c2] = k;
          k = bA[c2 = c0];
        }
        sa[k++] = s;
      } else {
        sa[i] = ~s;
      }
    }
  }
}
