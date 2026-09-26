// Encoders of the LHA -lh5-, -lh6-, -lh7- methods, ARJ methods 1 to 3 (the
// same static Huffman block format) and ARJ method 4.
//
// No permissive source contains these encoders, so they are written here
// from the format that the decoders read (lh_new_decoder.c of lhasa for the
// blocks, arj4_decoder.dart for method 4). The LZ77 parse follows
// deflate_slow, longest_match and fill_window of zlib's deflate.c (zlib
// license, see LICENSE) with a 256 byte maximum match and the window of
// each method; code lengths are Huffman lengths limited to 16 bits with the
// length adjustment of the JPEG standard (ITU T.81, Annex K.3).

import 'dart:typed_data';

import '../../io/streams.dart';
import 'lzh_bits.dart';

const int _kMinMatch = 3;
const int _kMaxMatch = 256;
// MIN_LOOKAHEAD
const int _kMinLookahead = _kMaxMatch + _kMinMatch + 1;
const int _kHashBits = 15;
const int _kHashSize = 1 << _kHashBits;
// TOO_FAR: a 3 byte match further away costs more than three literals
const int _kTooFar = 4096;

/// The match search effort (zlib's configuration_table: good_length,
/// max_lazy, nice_length, max_chain).
class LzParams {
  final int good;
  final int lazy;
  final int nice;
  final int chain;
  const LzParams(this.good, this.lazy, this.nice, this.chain);

  /// Parameters for a level from 1 (fastest) to 9 (best).
  static LzParams forLevel(int level) {
    if (level <= 1) return const LzParams(4, 4, 16, 8);
    if (level <= 3) return const LzParams(4, 8, 32, 32);
    if (level <= 5) return const LzParams(8, 32, 128, 256);
    if (level <= 7) return const LzParams(32, 128, 256, 1024);
    return const LzParams(32, 256, 256, 4096);
  }
}

/// The LZ77 parse: a sliding window of [wSize] bytes, matches of 3 to 256
/// bytes at a distance of 1 to [wSize]. Commands are collected in
/// [cmd] (a literal byte, or 256 + length - 3) and [dist] (distance - 1),
/// and [flushCommands] is called when [blockCommands] are collected and at
/// the end.
abstract class Lz77Parser {
  final int wSize;
  final LzParams params;
  final bool tooFar;
  final int blockCommands;

  final Uint8List _win;
  final Int32List _head = Int32List(_kHashSize);
  final Int32List _prev;
  int _strstart = 0;
  int _lookahead = 0;
  int _matchStart = 0;
  bool _eof = false;

  final Uint16List cmd;
  final Uint16List dist;
  int count = 0;

  /// Bytes read from the input.
  int inSize = 0;

  Lz77Parser(this.wSize, this.params,
      {this.tooFar = true, this.blockCommands = 32000})
      : _win = Uint8List(2 * wSize + _kMaxMatch + 8),
        _prev = Int32List(2 * wSize),
        cmd = Uint16List(blockCommands),
        dist = Uint16List(blockCommands) {
    _head.fillRange(0, _kHashSize, -1);
  }

  /// Codes cmd[0, n) and dist[0, n).
  void flushCommands(int n);

  void _emitLiteral(int b) {
    cmd[count] = b;
    dist[count] = 0;
    if (++count == blockCommands) {
      flushCommands(count);
      count = 0;
    }
  }

  void _emitMatch(int length, int distance) {
    cmd[count] = 256 + length - _kMinMatch;
    dist[count] = distance - 1;
    if (++count == blockCommands) {
      flushCommands(count);
      count = 0;
    }
  }

  int _hash(int p) {
    final w = _win;
    final v = w[p] | (w[p + 1] << 8) | (w[p + 2] << 16);
    return ((v * 0x9E3779B1) & 0xFFFFFFFF) >> (32 - _kHashBits);
  }

  // INSERT_STRING: returns the previous head of the chain
  int _insert(int p) {
    final h = _hash(p);
    final head = _head[h];
    _prev[p] = head;
    _head[h] = p;
    return head;
  }

  // fill_window
  void _fillWindow(InStream input) {
    final w = wSize;
    do {
      if (_strstart >= w + (w - _kMinLookahead)) {
        // slide the upper half down
        _win.setRange(0, w, _win, w);
        _matchStart -= w;
        _strstart -= w;
        final head = _head;
        for (var i = 0; i < _kHashSize; i++) {
          final v = head[i];
          head[i] = v >= w ? v - w : -1;
        }
        final prev = _prev;
        for (var i = 0; i < w; i++) {
          final v = prev[i + w];
          prev[i] = v >= w ? v - w : -1;
        }
      }
      if (_eof) return;
      final at = _strstart + _lookahead;
      final space = 2 * w - at;
      final n = input.read(_win, at, space);
      if (n == 0) {
        _eof = true;
        return;
      }
      _lookahead += n;
      inSize += n;
    } while (_lookahead < _kMinLookahead);
  }

  // longest_match
  int _longestMatch(int curMatch, int prevLength) {
    final w = _win;
    var chainLength = params.chain;
    final scan = _strstart;
    var bestLen = prevLength;
    var maxLen = _lookahead < _kMaxMatch ? _lookahead : _kMaxMatch;
    var nice = params.nice < maxLen ? params.nice : maxLen;
    final limit = scan - wSize;
    if (prevLength >= params.good) chainLength >>= 2;
    if (bestLen >= maxLen) return bestLen < maxLen ? bestLen : maxLen;
    final prev = _prev;
    do {
      final match = curMatch;
      if (w[match + bestLen] != w[scan + bestLen] ||
          w[match] != w[scan] ||
          w[match + 1] != w[scan + 1]) {
        continue;
      }
      var len = 2;
      while (len < maxLen && w[match + len] == w[scan + len]) {
        len++;
      }
      if (len > bestLen) {
        _matchStart = match;
        bestLen = len;
        if (len >= nice) break;
      }
    } while ((curMatch = prev[curMatch]) > limit &&
        curMatch >= 0 &&
        --chainLength != 0);
    return bestLen < maxLen ? bestLen : maxLen;
  }

  /// deflate_slow: parses the whole [input] and flushes the last commands.
  void parse(InStream input, [void Function(int inSize)? progress]) {
    var matchLength = _kMinMatch - 1;
    var matchAvailable = false;
    var prevLength = _kMinMatch - 1;
    var prevMatch = 0;
    var nextProgress = 1 << 20;
    for (;;) {
      if (_lookahead < _kMinLookahead) {
        _fillWindow(input);
        if (_lookahead == 0) break;
        if (progress != null && inSize >= nextProgress) {
          progress(inSize);
          nextProgress = inSize + (1 << 20);
        }
      }
      var hashHead = -1;
      if (_lookahead >= _kMinMatch) hashHead = _insert(_strstart);
      prevLength = matchLength;
      prevMatch = _matchStart;
      matchLength = _kMinMatch - 1;
      if (hashHead >= 0 &&
          prevLength < params.lazy &&
          _strstart - hashHead <= wSize) {
        matchLength = _longestMatch(hashHead, prevLength);
        if (matchLength == _kMinMatch &&
            tooFar &&
            _strstart - _matchStart > _kTooFar) {
          matchLength = _kMinMatch - 1;
        }
        if (matchLength < _kMinMatch) matchLength = _kMinMatch - 1;
      }
      if (prevLength >= _kMinMatch && matchLength <= prevLength) {
        final maxInsert = _strstart + _lookahead - _kMinMatch;
        _emitMatch(prevLength, _strstart - 1 - prevMatch);
        _lookahead -= prevLength - 1;
        prevLength -= 2;
        do {
          if (++_strstart <= maxInsert) _insert(_strstart);
        } while (--prevLength != 0);
        matchAvailable = false;
        matchLength = _kMinMatch - 1;
        _strstart++;
      } else if (matchAvailable) {
        _emitLiteral(_win[_strstart - 1]);
        _strstart++;
        _lookahead--;
      } else {
        matchAvailable = true;
        _strstart++;
        _lookahead--;
      }
    }
    if (matchAvailable) _emitLiteral(_win[_strstart - 1]);
    if (count > 0) flushCommands(count);
    count = 0;
    progress?.call(inSize);
  }
}

// ---------------------------------------------------------------------------
// Huffman code lengths and codes

/// Code lengths for [freq][0, n) limited to [limit] bits, stored in [lens].
/// Returns the number of used symbols; with one symbol its length is 0.
int lzhMakeLengths(Int32List freq, int n, int limit, Uint8List lens) {
  lens.fillRange(0, n, 0);
  var used = 0;
  for (var i = 0; i < n; i++) {
    if (freq[i] > 0) used++;
  }
  if (used <= 1) return used;
  // Huffman tree over the used symbols: nodes [0, used) are leaves,
  // then the inner nodes; a binary heap of node indices by weight
  final total = 2 * used - 1;
  final weight = Int64List(total);
  final parent = Int32List(total);
  final sym = Int32List(used);
  var k = 0;
  for (var i = 0; i < n; i++) {
    if (freq[i] > 0) {
      sym[k] = i;
      weight[k] = freq[i];
      k++;
    }
  }
  final heap = Int32List(used);
  var hn = 0;
  // heap order: by weight, then by index (deterministic)
  bool less(int a, int b) =>
      weight[a] < weight[b] || (weight[a] == weight[b] && a < b);
  void push(int v) {
    var i = hn++;
    while (i > 0) {
      final p = (i - 1) >> 1;
      if (!less(v, heap[p])) break;
      heap[i] = heap[p];
      i = p;
    }
    heap[i] = v;
  }

  int pop() {
    final top = heap[0];
    final last = heap[--hn];
    var i = 0;
    for (;;) {
      var c = 2 * i + 1;
      if (c >= hn) break;
      if (c + 1 < hn && less(heap[c + 1], heap[c])) c++;
      if (!less(heap[c], last)) break;
      heap[i] = heap[c];
      i = c;
    }
    if (hn > 0) heap[i] = last;
    return top;
  }

  for (var i = 0; i < used; i++) {
    push(i);
  }
  var next = used;
  while (hn > 1) {
    final a = pop();
    final b = pop();
    weight[next] = weight[a] + weight[b];
    parent[a] = next;
    parent[b] = next;
    push(next);
    next++;
  }
  // depths: the root is the last node
  final depth = Int32List(total);
  final maxDepthCount = Int32List(64);
  var maxDepth = 0;
  for (var i = total - 2; i >= 0; i--) {
    depth[i] = depth[parent[i]] + 1;
  }
  for (var i = 0; i < used; i++) {
    var d = depth[i];
    if (d > 63) d = 63;
    maxDepthCount[d]++;
    if (d > maxDepth) maxDepth = d;
  }
  // Annex K.3 (Adjust_BITS): move codes longer than the limit up
  final bits = maxDepthCount;
  for (var i = maxDepth; i > limit; i--) {
    while (bits[i] > 0) {
      var j = i - 2;
      while (bits[j] == 0) {
        j--;
      }
      bits[i] -= 2;
      bits[i - 1]++;
      bits[j + 1] += 2;
      bits[j]--;
    }
  }
  // the shortest lengths to the most frequent symbols
  final order = List<int>.generate(used, (i) => i);
  order.sort((a, b) {
    final c = freq[sym[b]].compareTo(freq[sym[a]]);
    return c != 0 ? c : sym[a].compareTo(sym[b]);
  });
  var len = 1;
  for (var i = 0; i < used; i++) {
    while (bits[len] == 0) {
      len++;
    }
    bits[len]--;
    lens[sym[order[i]]] = len;
  }
  return used;
}

/// Canonical codes for [lens][0, n): the order build_tree of lhasa gives
/// (shorter codes first, then by symbol).
void lzhMakeCodes(Uint8List lens, int n, Int32List codes) {
  final count = Int32List(18);
  for (var i = 0; i < n; i++) {
    count[lens[i]]++;
  }
  count[0] = 0;
  final start = Int32List(18);
  var code = 0;
  for (var l = 1; l <= 17; l++) {
    code = (code + count[l - 1]) << 1;
    start[l] = code;
  }
  for (var i = 0; i < n; i++) {
    final l = lens[i];
    if (l != 0) codes[i] = start[l]++;
  }
}

/// The number of bits of [d] (0 for 0).
int _bitLength(int d) {
  var b = 0;
  while (d > 0) {
    b++;
    d >>= 1;
  }
  return b;
}

// ---------------------------------------------------------------------------

/// The static Huffman block encoder of -lh5-, -lh6-, -lh7- and ARJ methods
/// 1 to 3.
class LzhHuffEncoder extends Lz77Parser {
  static const int _nc = 510; // NC: 256 literals and 254 lengths
  static const int _nt = 19; // NT: the lengths 0..16 and 3 run codes
  static const int _tbit = 5;
  static const int _cbit = 9;

  /// NP: the number of offset codes; PBIT: the width of their count.
  final int np;
  final int pbit;
  final LzhBitWriter _w;

  final Int32List _cFreq = Int32List(_nc);
  final Int32List _pFreq;
  final Int32List _tFreq = Int32List(_nt);
  final Uint8List _cLen = Uint8List(_nc);
  final Uint8List _pLen;
  final Uint8List _tLen = Uint8List(_nt);
  final Int32List _cCode = Int32List(_nc);
  final Int32List _pCode;
  final Int32List _tCode = Int32List(_nt);

  LzhHuffEncoder._(
      int wSize, this.np, this.pbit, OutStream out, LzParams params)
      : _w = LzhBitWriter(out),
        _pFreq = Int32List(np),
        _pLen = Uint8List(np),
        _pCode = Int32List(np),
        super(wSize, params);

  /// -lh5-: 8 KiB window. -lh6-: 32 KiB. -lh7-: 64 KiB.
  factory LzhHuffEncoder.lha(int method, OutStream out, {int level = 5}) {
    final p = LzParams.forLevel(level);
    switch (method) {
      case 5:
        return LzhHuffEncoder._(1 << 13, 14, 4, out, p);
      case 6:
        return LzhHuffEncoder._(1 << 15, 16, 5, out, p);
      case 7:
        return LzhHuffEncoder._(1 << 16, 17, 5, out, p);
    }
    throw ArgumentError('lh$method');
  }

  /// ARJ methods 1 to 3: a 26624 byte dictionary; [level] sets the effort.
  factory LzhHuffEncoder.arj(OutStream out, {int level = 9}) =>
      LzhHuffEncoder._(26624, 17, 5, out, LzParams.forLevel(level));

  /// Compresses [input] to the end; returns the packed size.
  int encode(InStream input, [void Function(int inSize)? progress]) {
    parse(input, progress);
    _w.flush();
    return _w.written;
  }

  // writes a length the way read_length_value reads it
  void _writeLength(int len) {
    final w = _w;
    if (len < 7) {
      w.putBits(3, len);
      return;
    }
    w.putBits(3, 7);
    for (var i = 7; i < len; i++) {
      w.putBits(1, 1);
    }
    w.putBits(1, 0);
  }

  // the zero runs and lengths of the code table as temp codes; [emit]
  // false only counts them
  void _codeTableSymbols(int cn, bool emit) {
    var i = 0;
    final w = _w;
    while (i < cn) {
      final l = _cLen[i];
      if (l != 0) {
        _tSym(l + 2, emit);
        i++;
        continue;
      }
      var run = 1;
      while (i + run < cn && _cLen[i + run] == 0) {
        run++;
      }
      i += run;
      if (run <= 2) {
        for (var k = 0; k < run; k++) {
          _tSym(0, emit);
        }
      } else if (run <= 18) {
        _tSym(1, emit);
        if (emit) w.putBits(4, run - 3);
      } else if (run == 19) {
        _tSym(0, emit);
        _tSym(1, emit);
        if (emit) w.putBits(4, 15);
      } else {
        _tSym(2, emit);
        if (emit) w.putBits(_cbit, run - 20);
      }
    }
  }

  void _tSym(int t, bool emit) {
    if (emit) {
      _w.putBits(_tLen[t], _tCode[t]);
    } else {
      _tFreq[t]++;
    }
  }

  @override
  void flushCommands(int n) {
    final w = _w;
    final cFreq = _cFreq, pFreq = _pFreq;
    cFreq.fillRange(0, _nc, 0);
    pFreq.fillRange(0, np, 0);
    for (var i = 0; i < n; i++) {
      final c = cmd[i];
      cFreq[c]++;
      if (c >= 256) pFreq[_bitLength(dist[i])]++;
    }
    w.putBits(16, n);

    // code table (with the temp table before it)
    final cUsed = lzhMakeLengths(cFreq, _nc, 16, _cLen);
    if (cUsed == 1) {
      var s = 0;
      while (cFreq[s] == 0) {
        s++;
      }
      w.putBits(_tbit, 0);
      w.putBits(_tbit, 0);
      w.putBits(_cbit, 0);
      w.putBits(_cbit, s);
      _cLen[s] = 0;
      _cCode[s] = 0;
    } else {
      lzhMakeCodes(_cLen, _nc, _cCode);
      var cn = _nc;
      while (cn > 0 && _cLen[cn - 1] == 0) {
        cn--;
      }
      _tFreq.fillRange(0, _nt, 0);
      _codeTableSymbols(cn, false);
      final tUsed = lzhMakeLengths(_tFreq, _nt, 16, _tLen);
      if (tUsed == 1) {
        var s = 0;
        while (_tFreq[s] == 0) {
          s++;
        }
        w.putBits(_tbit, 0);
        w.putBits(_tbit, s);
        _tLen[s] = 0;
        _tCode[s] = 0;
      } else {
        lzhMakeCodes(_tLen, _nt, _tCode);
        var tn = _nt;
        while (tn > 0 && _tLen[tn - 1] == 0) {
          tn--;
        }
        w.putBits(_tbit, tn);
        for (var i = 0; i < tn; i++) {
          _writeLength(_tLen[i]);
          if (i == 2) {
            var k = 0;
            while (k < 3 && i + 1 + k < tn && _tLen[i + 1 + k] == 0) {
              k++;
            }
            w.putBits(2, k);
            i += k;
          }
        }
      }
      w.putBits(_cbit, cn);
      _codeTableSymbols(cn, true);
    }

    // offset table
    final pUsed = lzhMakeLengths(pFreq, np, 16, _pLen);
    if (pUsed <= 1) {
      var s = 0;
      while (s < np && pFreq[s] == 0) {
        s++;
      }
      if (s == np) s = 0;
      w.putBits(pbit, 0);
      w.putBits(pbit, s);
      _pLen[s] = 0;
      _pCode[s] = 0;
    } else {
      lzhMakeCodes(_pLen, np, _pCode);
      var pn = np;
      while (pn > 0 && _pLen[pn - 1] == 0) {
        pn--;
      }
      w.putBits(pbit, pn);
      for (var i = 0; i < pn; i++) {
        _writeLength(_pLen[i]);
      }
    }

    // the commands
    final cLen = _cLen, cCode = _cCode, pLen = _pLen, pCode = _pCode;
    for (var i = 0; i < n; i++) {
      final c = cmd[i];
      w.putBits(cLen[c], cCode[c]);
      if (c >= 256) {
        final d = dist[i];
        final b = _bitLength(d);
        w.putBits(pLen[b], pCode[b]);
        if (b > 1) w.putBits(b - 1, d);
      }
    }
  }
}

/// The encoder of ARJ method 4 ("fastest"): LZ77 with a 15872 byte
/// window, lengths and distances in prefix codes (see arj4_decoder.dart).
class Arj4Encoder extends Lz77Parser {
  final LzhBitWriter _w;

  Arj4Encoder(OutStream out, {int level = 5})
      : _w = LzhBitWriter(out),
        super(15872, LzParams.forLevel(level), tooFar: false);

  /// Compresses [input] to the end; returns the packed size.
  int encode(InStream input, [void Function(int inSize)? progress]) {
    parse(input, progress);
    _w.flush();
    return _w.written;
  }

  @override
  void flushCommands(int n) {
    final w = _w;
    for (var i = 0; i < n; i++) {
      final c = cmd[i];
      if (c < 256) {
        w.putBits(9, c); // a 0 bit, then the byte
        continue;
      }
      // length - 2 in 1..254: width ones (and a zero below 7), width bits
      final v = c - 256 + 1;
      var width = 0;
      while (width < 7 && v >= (2 << width) - 1) {
        width++;
      }
      if (width < 7) {
        w.putBits(width + 1, ((1 << width) - 1) << 1);
      } else {
        w.putBits(7, 0x7F);
      }
      w.putBits(width, v - ((1 << width) - 1));
      // distance - 1 in 0..15871: widths 9 to 13
      final d = dist[i];
      var pw = 9;
      while (pw < 13 && d >= (2 << pw) - 512) {
        pw++;
      }
      final ones = pw - 9;
      if (pw < 13) {
        w.putBits(ones + 1, ((1 << ones) - 1) << 1);
      } else {
        w.putBits(4, 0xF);
      }
      w.putBits(pw, d - ((1 << pw) - 512));
    }
  }
}
