// Vendored from zpaq-flutter by tool/sync_zpaq.sh: do not edit here, change
// zpaq-flutter and sync again. Pure Dart port of libzpaq and zpaq 7.15 (Matt
// Mahoney, public domain) with the zpaqfranz attribute format (Franco
// Corbelli, MIT). Copyright (c) 2026 Max Brito, BSD 3-clause; see LICENSE
// for the license and the third party notices.

import 'dart:typed_data';

import 'io.dart';
import 'divsufsort.dart';

/// E8E9 transform of buf[0..n-1] to improve compression of x86 code.
void e8e9(Uint8List buf, int n) {
  for (var i = n - 5; i >= 0; --i) {
    if ((buf[i] & 254) == 0xe8 && ((buf[i + 4] + 1) & 254) == 0) {
      final a = (buf[i + 1] | buf[i + 2] << 8 | buf[i + 3] << 16) + i;
      buf[i + 1] = a;
      buf[i + 2] = a >> 8;
      buf[i + 3] = a >> 16;
    }
  }
}

/// An LZ77 hash table reused from block to block (it is up to 64 MB).
/// [compressBlock] takes it clean and gives it back clean: after a small
/// block only the entries written are cleared, after a big one the next
/// [take] clears it all. If a block fails midway, the table stays marked
/// and is cleared on the next use.
class LzHashTables {
  Uint32List? _t;
  bool _clean = true, _taken = false;

  /// A zeroed table of [n] entries.
  Uint32List take(int n) {
    var t = _t;
    if (t == null || t.length != n) {
      t = _t = Uint32List(n);
    } else if (!_clean) {
      zeroFill(t);
    }
    _clean = false;
    _taken = true;
    return t;
  }

  /// Ends a use of the table; [cleared] when its entries are all zero.
  void release(bool cleared) {
    if (_taken) _clean = cleared;
    _taken = false;
  }

  /// For tests: whether a table marked clean is all zeros.
  bool get consistent {
    final t = _t;
    if (t == null || !_clean) return true;
    for (var i = 0; i < t.length; ++i) {
      if (t[i] != 0) return false;
    }
    return true;
  }
}

/// LZ77 / BWT preprocessor for compression levels 1..3 (libzpaq LZBuffer).
///
/// args[0] = log2 block size in MB, args[1] = 1 (var LZ77), 2 (byte LZ77),
/// 3 (BWT), +4 for E8E9. args[2] = min match, args[3] = secondary context
/// order, args[4] = log2 bucket, args[5] = log2 hash table size (or SA if
/// >= 21+args[0]), args[6] = secondary context look ahead.
class LzBuffer extends ZReader {
  Uint32List _ht = Uint32List(0);
  final Uint8List _in;
  final ByteData _inBd;
  int _checkbits = 0;
  final int _level;
  int _htsize = 0;
  final int _n;
  int _i = 0;
  final int _minMatch;
  final int _minMatch2;
  static const int _bufsize = 1 << 14;
  final int _maxMatch = _bufsize * 3;
  final int _maxLiteral = _bufsize ~/ 4;
  final int _lookahead;
  int _h1 = 0, _h2 = 0;
  final int _bucket;
  int _shift1 = 0, _shift2 = 0;
  int _minMatchBoth = 0;
  int _rb = 0;
  int _bits = 0, _nbits = 0;
  int _rpos = 0, _wpos = 0;
  int _idx = 0;
  Int32List? _sa;
  Uint32List? _isa;
  final Uint8List _buf = Uint8List(_bufsize);
  final Uint8List _lgt = lgTable;

  /// [hashTable] may supply the LZ77 hash table (it must return a zeroed
  /// table of the given length), to reuse one across blocks.
  LzBuffer(ZBuffer inbuf, List<int> args,
      [Uint32List Function(int length)? hashTable])
      : _in = inbuf.data,
        _inBd = ByteData.sublistView(inbuf.data),
        _level = args[1] & 3,
        _n = inbuf.size,
        _minMatch = args[2],
        _minMatch2 = args[3],
        _lookahead = args[6],
        _bucket = (1 << args[4]) - 1 {
    final useSa = args[5] - args[0] >= 21;
    _checkbits = !useSa ? 12 - args[0] : 17 + args[0];
    _shift1 = _minMatch > 0 ? (args[5] - 1) ~/ _minMatch + 1 : 1;
    _shift2 = _minMatch2 > 0 ? (args[5] - 1) ~/ _minMatch2 + 1 : 0;
    final mb = _minMatch2 + _lookahead;
    _minMatchBoth = (_minMatch > mb ? _minMatch : mb) + 4;
    _rb = args[0] > 4 ? args[0] - 4 : 0;
    if ((_minMatch < 4 && _level == 1) || (_minMatch < 1 && _level == 2)) {
      zpaqError('match length \$3 too small');
    }
    if (args[1] > 4) e8e9(_in, _n);
    if (_level == 3) {
      _ht = Uint32List(0);
      final sa = Int32List(_n + 1);
      buildSuffixArray(_in, sa, _n);
      _sa = sa;
    } else if (useSa) {
      _ht = Uint32List(0);
      final sa = Int32List(_n + 1);
      buildSuffixArray(_in, sa, _n);
      _sa = sa;
      _isa = Uint32List(1 << 17 << args[0]);
    } else {
      _ht = hashTable != null
          ? hashTable(1 << args[5])
          : Uint32List(1 << args[5]);
    }
    _htsize = _ht.length;
  }

  void _putb(int x, int k) {
    x &= (1 << k) - 1;
    _bits |= x << _nbits;
    _nbits += k;
    while (_nbits > 7) {
      _buf[_wpos++] = _bits;
      _bits >>= 8;
      _nbits -= 8;
    }
  }

  void _flushBits() {
    if (_nbits > 0) _buf[_wpos++] = _bits;
    _bits = _nbits = 0;
  }

  void _put(int c) => _buf[_wpos++] = c;

  @override
  int get() {
    var c = -1;
    if (_rpos == _wpos) _fill();
    if (_rpos < _wpos) c = _buf[_rpos++];
    if (_rpos == _wpos) _rpos = _wpos = 0;
    return c;
  }

  @override
  int read(Uint8List buf, int off, int n) {
    if (_rpos == _wpos) _fill();
    var nr = n;
    if (nr > _wpos - _rpos) nr = _wpos - _rpos;
    if (nr > 0) buf.setRange(off, off + nr, _buf, _rpos);
    _rpos += nr;
    if (_rpos == _wpos) _rpos = _wpos = 0;
    return nr;
  }

  int _inAt(int i) => i < _n ? _in[i] : -1;

  @pragma('vm:unsafe:no-bounds-checks')
  void _fill() {
    final inp = _in;
    final n = _n;
    // BWT
    if (_level == 3) {
      final sa = _sa!;
      for (; _wpos < _bufsize && _i < n + 5; ++_i) {
        if (_i == 0) {
          _put(n > 0 ? inp[n - 1] : 255);
        } else if (_i > n) {
          _put(_idx & 255);
          _idx >>= 8;
        } else if (sa[_i - 1] == 0) {
          _idx = _i;
          _put(255);
        } else {
          _put(inp[sa[_i - 1] - 1]);
        }
      }
      return;
    }

    if (_isa != null) {
      _fillSa();
      return;
    }
    if (_minMatch2 == 0) {
      _fillHash();
      return;
    }

    // LZ77: scan the input
    var lit = 0;
    final mask = (1 << _checkbits) - 1;
    final sa = _sa;
    final isa = _isa;
    final ht = _ht;
    final minMatch = _minMatch, minMatch2 = _minMatch2;
    final lookahead = _lookahead, bucket = _bucket, maxMatch = _maxMatch;
    // Hot state in locals: the field loads and stores of every position cost
    // as much as the match search itself.
    final checkbits = _checkbits, minMatchBoth = _minMatchBoth;
    final shift1 = _shift1, shift2 = _shift2, htsize = _htsize;
    final maxLiteral = _maxLiteral;
    var i = _i, h1 = _h1, h2 = _h2, wpos = _wpos;
    while (i < n && wpos * 2 < _bufsize) {
      var blen = minMatch - 1;
      var bp = 0;
      var blit = 0;
      var bscore = 0;
      if (isa != null) {
        if (sa![isa[i & mask]] != i) {
          for (var j = 0; j < n; ++j) {
            if ((sa[j] & ~mask) == (i & ~mask)) isa[sa[j] & mask] = j;
          }
        }
        for (var h = 0; h <= lookahead; ++h) {
          final q = isa[(h + i) & mask];
          if (sa[q] != h + i) continue;
          for (var j = -1; j <= 1; j += 2) {
            for (var k = 1; k <= bucket; ++k) {
              final qi = q + j * k;
              if (qi < 0 || qi >= n) continue;
              final p = sa[qi] - h;
              if (p < 0 || p >= i) continue;
              final l = _matchLen(p, i, h, n, maxMatch);
              var l1 = h;
              while (l1 > 0 && inp[p + l1 - 1] == inp[i + l1 - 1]) {
                --l1;
              }
              var score = (l - l1) * 8 -
                  lg(i - p) -
                  4 * (lit == 0 && l1 > 0 ? 1 : 0) -
                  11;
              for (var a = 0; a < h; ++a) {
                score = (score * 5) ~/ 8;
              }
              if (score > bscore) {
                blen = l;
                bp = p;
                blit = l1;
                bscore = score;
              }
              if (l < blen || l < minMatch || l > 255) break;
            }
          }
          if (bscore <= 0 || blen < minMatch) break;
        }
      } else if (_level == 1 || minMatch <= 64) {
        if (minMatch2 > 0) {
          for (var k = 0; k <= bucket; ++k) {
            var p = ht[h2 ^ k];
            if (p != 0 && (p & mask) == (_inAt(i + 3) & mask)) {
              p >>= checkbits;
              if (p < i &&
                  i + blen <= n &&
                  (blen == 0 || inp[p + blen - 1] == inp[i + blen - 1])) {
                var l = lookahead;
                while (i + l < n && l < maxMatch && inp[p + l] == inp[i + l]) {
                  ++l;
                }
                if (l >= minMatch2 + lookahead) {
                  var l1 = lookahead;
                  while (l1 > 0 && inp[p + l1 - 1] == inp[i + l1 - 1]) {
                    --l1;
                  }
                  final score = (l - l1) * 8 -
                      lg(i - p) -
                      8 * (lit == 0 && l1 > 0 ? 1 : 0) -
                      11;
                  if (score > bscore) {
                    blen = l;
                    bp = p;
                    blit = l1;
                    bscore = score;
                  }
                }
              }
            }
            if (blen >= 128) break;
          }
        }
        if (minMatch2 == 0 || blen < minMatch2) {
          // The 3 byte check target does not change over the 8 probes.
          final i3ok = i + 3 < n;
          final i3m = i3ok ? inp[i + 3] & mask : -1;
          for (var k = 0; k <= bucket; ++k) {
            var p = ht[h1 ^ k];
            if (p != 0 && i3ok && (p & mask) == i3m) {
              p >>= checkbits;
              if (p < i &&
                  i + blen <= n &&
                  (blen == 0 || inp[p + blen - 1] == inp[i + blen - 1])) {
                // Byte by byte here: matches found through the hash table are
                // mostly short, where word compares cost more than they save.
                var l = 0;
                while (i + l < n && l < maxMatch && inp[p + l] == inp[i + l]) {
                  ++l;
                }
                final score = l * 8 - lg(i - p) - 2 * (lit > 0 ? 1 : 0) - 11;
                if (score > bscore) {
                  blen = l;
                  bp = p;
                  blit = 0;
                  bscore = score;
                }
              }
            }
            if (blen >= 128) break;
          }
        }
      }

      final off = i - bp;
      final extra = _level == 2
          ? (off >= (1 << 16) ? 1 : 0) + (off >= (1 << 24) ? 1 : 0)
          : 0;
      if (off > 0 && bscore > 0 && blen - blit >= minMatch + extra) {
        lit += blit;
        _wpos = wpos;
        _writeLiteral(i + blit, lit);
        lit = 0;
        _writeMatch(blen - blit, off);
        wpos = _wpos;
      } else {
        blen = 1;
        ++lit;
      }

      if (isa != null) {
        i += blen;
      } else {
        var ii = i;
        while (blen-- > 0) {
          if (ii + minMatchBoth < n) {
            final ih = (((ii * 1234547) & 0xFFFFFFFF) >> 19) & bucket;
            final p = ((ii << checkbits) | (inp[ii + 3] & mask)) & 0xFFFFFFFF;
            if (minMatch2 != 0) {
              ht[h2 ^ ih] = p;
              h2 = (((h2 * 9) << shift2) +
                      (inp[ii + minMatch2 + lookahead] + 1) * 23456789) &
                  (htsize - 1);
            }
            ht[h1 ^ ih] = p;
            h1 = (((h1 * 5) << shift1) + (inp[ii + minMatch] + 1) * 123456791) &
                (htsize - 1);
          }
          ++ii;
        }
        i = ii;
      }
      if (lit >= maxLiteral) {
        _wpos = wpos;
        _writeLiteral(i, lit);
        wpos = _wpos;
        lit = 0;
      }
    }
    if (i == n) {
      _wpos = wpos;
      _writeLiteral(n, lit);
      lit = 0;
      _flushBits();
      wpos = _wpos;
    }
    _i = i;
    _h1 = h1;
    _h2 = h2;
    _wpos = wpos;
  }

  /// [_fill] for LZ77 with the hash table and one context order (levels 1
  /// to 4 when they use LZ77 without a suffix array). Same output; kept
  /// apart so that its loop has few enough live values to stay in
  /// registers.
  @pragma('vm:unsafe:no-bounds-checks')
  void _fillHash() {
    final inp = _in;
    final n = _n;
    final ht = _ht;
    final checkbits = _checkbits & 63;
    final mask = (1 << checkbits) - 1;
    final minMatch = _minMatch, bucket = _bucket, maxMatch = _maxMatch;
    final shift1 = _shift1 & 63, hmask = _htsize - 1;
    final search = _level == 1 || minMatch <= 64;
    final level2 = _level == 2;
    // Positions below this are inserted into the hash table.
    final insEnd = n - _minMatchBoth;
    final lgt = _lgt;
    var i = _i, h1 = _h1, lit = 0;
    while (i < n && _wpos * 2 < _bufsize) {
      var blen = minMatch - 1;
      var bp = 0;
      var bscore = 0;
      if (search && i + 3 < n) {
        final i3m = inp[i + 3] & mask;
        final lmax = n - i < maxMatch ? n - i : maxMatch;
        for (var k = 0; k <= bucket; ++k) {
          var p = ht[h1 ^ k];
          if (p != 0 && (p & mask) == i3m) {
            p >>= checkbits;
            if (p < i &&
                i + blen <= n &&
                (blen == 0 || inp[p + blen - 1] == inp[i + blen - 1])) {
              var l = 0;
              while (l < lmax && inp[p + l] == inp[i + l]) {
                ++l;
              }
              final score = l * 8 - lgWith(lgt, i - p) - (lit > 0 ? 2 : 0) - 11;
              if (score > bscore) {
                blen = l;
                bp = p;
                bscore = score;
              }
            }
          }
          if (blen >= 128) break;
        }
      }

      final off = i - bp;
      final extra =
          level2 ? (off >= (1 << 16) ? 1 : 0) + (off >= (1 << 24) ? 1 : 0) : 0;
      if (off > 0 && bscore > 0 && blen >= minMatch + extra) {
        _writeLiteral(i, lit);
        lit = 0;
        _writeMatch(blen, off);
      } else {
        blen = 1;
        ++lit;
      }

      final end = i + blen;
      final e = end < insEnd ? end : insEnd;
      for (var ii = i; ii < e; ++ii) {
        final ih = (((ii * 1234547) & 0xFFFFFFFF) >> 19) & bucket;
        ht[h1 ^ ih] = ((ii << checkbits) | (inp[ii + 3] & mask)) & 0xFFFFFFFF;
        h1 = (((h1 * 5) << shift1) + (inp[ii + minMatch] + 1) * 123456791) &
            hmask;
      }
      i = end;
      if (lit >= _maxLiteral) {
        _writeLiteral(i, lit);
        lit = 0;
      }
    }
    if (i == n) {
      _writeLiteral(n, lit);
      lit = 0;
      _flushBits();
    }
    _i = i;
    _h1 = h1;
  }

  /// [_fill] for LZ77 with suffix array matching (levels 2 and 3), where
  /// the match candidates of position i are its neighbors in the suffix
  /// array.
  @pragma('vm:unsafe:no-bounds-checks')
  void _fillSa() {
    final inp = _in;
    final n = _n;
    final sa = _sa!;
    final isa = _isa!;
    final mask = (1 << (_checkbits & 63)) - 1;
    final minMatch = _minMatch, bucket = _bucket, maxMatch = _maxMatch;
    final lookahead = _lookahead;
    final level2 = _level == 2;
    final lgt = _lgt;
    var i = _i, lit = 0;
    while (i < n && _wpos * 2 < _bufsize) {
      var blen = minMatch - 1;
      var bp = 0;
      var blit = 0;
      var bscore = 0;
      if (sa[isa[i & mask]] != i) {
        // Refill the inverse suffix array for the positions of i's window.
        final hi = i & ~mask;
        for (var j = 0; j < n; ++j) {
          final s = sa[j];
          if ((s & ~mask) == hi) isa[s & mask] = j;
        }
      }
      for (var h = 0; h <= lookahead; ++h) {
        final q = isa[(h + i) & mask];
        if (sa[q] != h + i) continue;
        for (var j = -1; j <= 1; j += 2) {
          for (var k = 1; k <= bucket; ++k) {
            final qi = q + j * k;
            // qi moves away from q: once outside, it stays outside
            if (qi < 0 || qi >= n) break;
            final p = sa[qi] - h;
            // Suffixes at or after i are frequent (half of the neighbors):
            // skipping them inside the body keeps the loop's registers.
            if (p >= 0 && p < i) {
              final l = _matchLen(p, i, h, n, maxMatch);
              var l1 = h;
              while (l1 > 0 && inp[p + l1 - 1] == inp[i + l1 - 1]) {
                --l1;
              }
              var score = (l - l1) * 8 -
                  lgWith(lgt, i - p) -
                  (lit == 0 && l1 > 0 ? 4 : 0) -
                  11;
              for (var a = 0; a < h; ++a) {
                score = (score * 5) ~/ 8;
              }
              if (score > bscore) {
                blen = l;
                bp = p;
                blit = l1;
                bscore = score;
              }
              if (l < blen || l < minMatch || l > 255) break;
            }
          }
        }
        if (bscore <= 0 || blen < minMatch) break;
      }

      final off = i - bp;
      final extra =
          level2 ? (off >= (1 << 16) ? 1 : 0) + (off >= (1 << 24) ? 1 : 0) : 0;
      if (off > 0 && bscore > 0 && blen - blit >= minMatch + extra) {
        lit += blit;
        _writeLiteral(i + blit, lit);
        lit = 0;
        _writeMatch(blen - blit, off);
      } else {
        blen = 1;
        ++lit;
      }
      i += blen;
      if (lit >= _maxLiteral) {
        _writeLiteral(i, lit);
        lit = 0;
      }
    }
    if (i == n) {
      _writeLiteral(n, lit);
      lit = 0;
      _flushBits();
    }
    _i = i;
  }

  /// Zeroes the hash table entries this buffer wrote, so that the table
  /// can be reused without clearing all of it (for small blocks, most of
  /// the cost). Replays the insertions of [_fillHash]: the context hash
  /// depends only on the input. Returns false (nothing done) for the other
  /// paths.
  @pragma('vm:unsafe:no-bounds-checks')
  bool clearWritten() {
    if (_level == 3 || _isa != null || _minMatch2 != 0 || _htsize == 0) {
      return false;
    }
    // Replaying costs a random store per position, a full clear a memset:
    // replay only when the block is much smaller than the table.
    if (_n > _htsize >> 4) return false;
    final inp = _in, ht = _ht;
    final bucket = _bucket, minMatch = _minMatch;
    final shift1 = _shift1 & 63, hmask = _htsize - 1;
    final insEnd = _n - _minMatchBoth;
    final end = _i < insEnd ? _i : insEnd;
    var h1 = 0;
    for (var ii = 0; ii < end; ++ii) {
      ht[h1 ^ ((((ii * 1234547) & 0xFFFFFFFF) >> 19) & bucket)] = 0;
      h1 =
          (((h1 * 5) << shift1) + (inp[ii + minMatch] + 1) * 123456791) & hmask;
    }
    return true;
  }

  /// Length of the match between [p] and [i] (p < i) starting at [l], up
  /// to [maxMatch] and the end [n], for the suffix array search, where
  /// matches are long. Compares 8 bytes at a time: the first
  /// differing byte of two little endian words is the lowest set byte of
  /// their XOR.
  @pragma('vm:prefer-inline')
  @pragma('vm:unsafe:no-bounds-checks')
  int _matchLen(int p, int i, int l, int n, int maxMatch) {
    final bd = _inBd, lgt = _lgt;
    final lim = (n - i < maxMatch ? n - i : maxMatch) - 8;
    while (l <= lim) {
      final x = bd.getUint64(p + l, Endian.little) ^
          bd.getUint64(i + l, Endian.little);
      if (x != 0) {
        // index of the lowest nonzero byte (bitLength is slow, lg is a table)
        final lo = x & 0xFFFFFFFF;
        return l +
            (lo != 0
                ? (lgWith(lgt, lo & -lo) - 1) >> 3
                : 4 + ((lgWith(lgt, (x >>> 32) & -(x >>> 32)) - 1) >> 3));
      }
      l += 8;
    }
    final inp = _in;
    while (i + l < n && l < maxMatch && inp[p + l] == inp[i + l]) {
      ++l;
    }
    return l;
  }

  void _writeLiteral(int i, int lit) {
    if (_level == 1) {
      if (lit < 1) return;
      var ll = lg(lit);
      _putb(0, 2);
      --ll;
      while (--ll >= 0) {
        _putb(1, 1);
        _putb((lit >> ll) & 1, 1);
      }
      _putb(0, 1);
      while (lit > 0) {
        _putb(_in[i - lit--], 8);
      }
    } else {
      while (lit > 0) {
        var lit1 = lit;
        if (lit1 > 64) lit1 = 64;
        _put(lit1 - 1);
        for (var j = i - lit; j < i - lit + lit1; ++j) {
          _put(_in[j]);
        }
        lit -= lit1;
      }
    }
  }

  void _writeMatch(int len, int off) {
    if (_level == 1) {
      final buf = _buf, rb = _rb;
      var bits = _bits, nbits = _nbits, wpos = _wpos;
      var ll = lg(len) - 1;
      off += (1 << rb) - 1;
      final lo = lg(off) - 1 - rb;
      // 2 bits of length class, 3 bits of offset class, gamma pairs, a 0,
      // 2 bits of length, then the offset split in rb and lo bits.
      nbits += 5;
      bits |= ((((lo + 8) >> 3) & 3) | ((lo & 7) << 2)) << (nbits - 5);
      while (nbits > 7) {
        buf[wpos++] = bits;
        bits >>= 8;
        nbits -= 8;
      }
      while (--ll >= 2) {
        nbits += 2;
        bits |= 1 << (nbits - 2);
        if ((len >> ll) & 1 != 0) bits |= 1 << (nbits - 1);
        while (nbits > 7) {
          buf[wpos++] = bits;
          bits >>= 8;
          nbits -= 8;
        }
      }
      nbits += 3;
      bits |= ((len & 3) << 1) << (nbits - 3); // a 0 bit, then len & 3
      while (nbits > 7) {
        buf[wpos++] = bits;
        bits >>= 8;
        nbits -= 8;
      }
      nbits += rb;
      bits |= (off & ((1 << rb) - 1)) << (nbits - rb);
      while (nbits > 7) {
        buf[wpos++] = bits;
        bits >>= 8;
        nbits -= 8;
      }
      nbits += lo;
      bits |= ((off >> rb) & ((1 << lo) - 1)) << (nbits - lo);
      while (nbits > 7) {
        buf[wpos++] = bits;
        bits >>= 8;
        nbits -= 8;
      }
      _bits = bits;
      _nbits = nbits;
      _wpos = wpos;
    } else {
      final minMatch = _minMatch;
      --off;
      while (len > 0) {
        final len1 = len > minMatch * 2 + 63
            ? minMatch + 63
            : len > minMatch + 63
                ? len - minMatch
                : len;
        if (off < (1 << 16)) {
          _put(64 + len1 - minMatch);
          _put((off >> 8) & 255);
          _put(off & 255);
        } else if (off < (1 << 24)) {
          _put(128 + len1 - minMatch);
          _put((off >> 16) & 255);
          _put((off >> 8) & 255);
          _put(off & 255);
        } else {
          _put(192 + len1 - minMatch);
          _put((off >> 24) & 255);
          _put((off >> 16) & 255);
          _put((off >> 8) & 255);
          _put(off & 255);
        }
        len -= len1;
      }
    }
  }
}
