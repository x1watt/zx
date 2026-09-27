// zcm: the models. Each model reads the shared history ([ZcmState]),
// updates itself with the last bit and adds its inputs to the mixer.
//
// Designs from paq8l and lpaq1 (Matt Mahoney: match, word, sparse,
// record, indirect and the x86 context of execxt, which paq8 credits to
// Alexander Rhatushnyak and Serge Osnach for the exe work) and paq8px
// (Marcio Pais, Zoltan Gotthardt and others: several match lengths, the
// line and column contexts of the text models). Written in Dart for this
// codec; the parameters were tuned on the zcm benchmark corpus.

import 'dart:typed_data';

import 'zcm_components.dart';
import 'zcm_detect.dart';
import 'zcm_tables.dart';

export 'zcm_detect.dart' show ZcmBlockType;

/// History and bit state shared by all models.
final class ZcmState {
  /// Last coded bit.
  int y = 0;

  /// Bits of the current byte with a leading 1 (1..255).
  int c0 = 1;

  /// Position of the next bit in the byte (0 = most significant).
  int bpos = 0;

  /// Last 4 bytes (c4 & 255 is the last byte) and the 4 before them.
  int c4 = 0;
  int c8 = 0;

  /// Number of whole bytes seen.
  int pos = 0;

  /// Ring buffer of the history.
  final Uint8List buf;
  final int bufMask;

  /// Type of the current segment and its info (row stride of an image,
  /// sample layout of audio).
  int blockType = ZcmBlockType.binary;
  int blockInfo = 0;

  /// Bytes of the current segment seen so far.
  int blockPos = 0;

  ZcmState(int bufBytes)
      : buf = Uint8List(floorPow2(bufBytes < 4096 ? 4096 : bufBytes)),
        bufMask = floorPow2(bufBytes < 4096 ? 4096 : bufBytes) - 1;

  /// Byte [i] positions back (1 = last byte).
  @pragma('vm:prefer-inline')
  int back(int i) => buf[(pos - i) & bufMask];

  /// Records bit [bit].
  @pragma('vm:prefer-inline')
  void update(int bit) {
    y = bit;
    final c = (c0 << 1) | bit;
    if (c >= 256) {
      final b = c & 255;
      buf[pos & bufMask] = b;
      pos++;
      blockPos++;
      c8 = ((c8 << 8) | (c4 >> 24)) & 0xFFFFFFFF;
      c4 = ((c4 << 8) | b) & 0xFFFFFFFF;
      c0 = 1;
      bpos = 0;
    } else {
      c0 = c;
      bpos++;
    }
  }
}

/// A model: adds [inputs] mixer inputs per bit.
abstract class ZcmModel {
  int get inputs;

  /// Updates with the last bit (s.y) and adds the inputs for the next
  /// bit. At s.bpos == 0 the model first computes its byte contexts.
  void mix(ZcmState s, Mixer m);
}

/// Models that add mixer weight set selectors of their own.
abstract interface class ZcmMixerContexts {
  /// Sizes of the selectors this model sets.
  List<int> get mixerContextSizes;

  /// Sets them (after the predictor's own selectors).
  void setMixerContexts(ZcmState s, Mixer m);
}

/// An order-n model: also tells how many of its contexts have been seen.
abstract class ZcmOrders implements ZcmModel {
  /// Contexts with statistics for the next bit.
  int get hits;
}

/// Orders 0 to N (paq8 order-n contexts over the byte history).
final class OrderModel implements ZcmOrders {
  @override
  int get hits => _cm.hits;

  final DirectMap _o0 = DirectMap(0);
  final DirectMap _o1 = DirectMap(8);
  final ContextMap _cm;
  final Int32List orders;
  // paq8px NormalModel smOrder0 and smOrder1: a slow and a fast adaptive
  // probability for orders 0 and 1 (with [pairs]).
  final bool pairs;
  final Uint32List _slow = Uint32List(256 + 65536)
    ..fillRange(0, 256 + 65536, 2048 << 20);
  final Uint32List _fast = Uint32List(256 + 65536)
    ..fillRange(0, 256 + 65536, 2048 << 20);
  int _i0 = 0, _i1 = 256;

  /// [orders] of the hashed contexts (2 and up), [bytes] of table.
  OrderModel(List<int> orders, int bytes,
      {bool rich = true, bool bh = false, this.pairs = false})
      : orders = Int32List.fromList(orders),
        _cm = ContextMap(bytes, orders.length, rich: rich, bh: bh);

  @override
  int get inputs => 4 + (pairs ? 8 : 0) + _cm.nCtx * _cm.inputsPerContext;

  @pragma('vm:unsafe:no-bounds-checks')
  void _mixPairs(Mixer m, int y, int c0, int c1) {
    final slow = _slow, fast = _fast;
    final tx = m.tx;
    var k = m.nx;
    final str = kStretch;
    for (var j = 0; j < 2; j++) {
      final li = j == 0 ? _i0 : _i1;
      slow[li] = adaptEntry(slow[li], y, 1023);
      fast[li] = adaptEntry(fast[li], y, 16);
      final ni = j == 0 ? c0 : 256 + (c1 << 8 | c0);
      if (j == 0) {
        _i0 = ni;
      } else {
        _i1 = ni;
      }
      final ps = slow[ni] >> 20, pf = fast[ni] >> 20;
      tx[k] = (ps - 2048) >> 3;
      tx[k + 1] = str[ps] >> 2;
      tx[k + 2] = (pf - 2048) >> 3;
      tx[k + 3] = str[pf] >> 2;
      k += 4;
    }
    m.nx = k;
  }

  @override
  void mix(ZcmState s, Mixer m) {
    if (s.bpos == 0) {
      final c4 = s.c4;
      _o1.set(c4 & 255);
      for (var i = 0; i < orders.length; i++) {
        final o = orders[i];
        int h;
        if (o <= 4) {
          h = c4 & ((1 << (o * 8)) - 1);
          if (o == 4) h = c4;
          h = hash2(h, o);
        } else if (o <= 8) {
          h = hash3(c4, s.c8 & ((o == 8) ? 0xFFFFFFFF : ((1 << ((o - 4) * 8)) - 1)), o);
        } else {
          // Long orders: hash the bytes from the buffer.
          var hh = hash2(c4, s.c8);
          for (var k = 9; k <= o; k++) {
            hh = (hh * 0x2F0F3A55 + s.back(k) + 1) & 0xFFFFFFFF;
          }
          h = hash2(hh, o);
        }
        _cm.set(i, h);
      }
    }
    final y = s.y;
    final c0 = s.c0;
    _o0.mix(m, y, c0);
    _o1.mix(m, y, c0);
    if (pairs) _mixPairs(m, y, c0, s.c4 & 255);
    _cm.mix(m, y, s.bpos, c0, s.c4 & 255);
  }
}

/// Match model: finds the last occurrence of the recent bytes (two hash
/// lengths, the longer one preferred) and predicts the byte that followed.
final class MatchModel implements ZcmModel {
  final Int32List _htS;
  final Int32List _htL;
  final int _mask;
  final int minS;
  final int minL;
  int _ptr = 0;
  int _len = 0;
  int _exp = 0; // expected byte
  final StateMap _sm1 = StateMap(64 * 2);
  final StateMap _sm2 = StateMap(256 * 8 * 2 * 4);
  final int _bufMask;

  /// Expected byte for other models, or -1.
  int get expectedByte => _len > 0 ? _exp : -1;

  /// Current match length (0 when no match).
  int get length => _len;

  MatchModel(int tableEntries, int bufBytes, {this.minS = 5, this.minL = 12})
      : _htS = Int32List(floorPow2(tableEntries)),
        _htL = Int32List(floorPow2(tableEntries)),
        _mask = floorPow2(tableEntries) - 1,
        _bufMask = floorPow2(bufBytes < 4096 ? 4096 : bufBytes) - 1;

  @override
  int get inputs => 3;

  int _lenQ() {
    final l = _len;
    if (l < 16) return l;
    final q = 16 + ((kIlog[l < 65535 ? l : 65535] - 64) >> 2);
    return q > 63 ? 63 : q;
  }

  @override
  void mix(ZcmState s, Mixer m) {
    final buf = s.buf;
    final bm = _bufMask;
    if (s.bpos == 0) {
      final pos = s.pos;
      if (_len > 0 && _exp != (s.c4 & 255)) _len = 0;
      if (_len > 0) {
        _len++;
        if (_len > 65535) _len = 65535;
        _ptr++;
      }
      if (pos >= minS) {
        var hs = 0;
        for (var k = 1; k <= minS; k++) {
          hs = (hs * 0x2F0F3A55 + buf[(pos - k) & bm] + 1) & 0xFFFFFFFF;
        }
        hs = hash2(hs, minS) & _mask;
        var hl = -1;
        if (pos >= minL) {
          var h = 0;
          for (var k = 1; k <= minL; k++) {
            h = (h * 0x2F0F3A55 + buf[(pos - k) & bm] + 1) & 0xFFFFFFFF;
          }
          hl = hash2(h, minL) & _mask;
        }
        if (_len == 0) {
          // Look for a new match, the long hash first.
          if (hl >= 0) {
            final cand = _htL[hl];
            if (cand > 0) {
              final l = _verify(buf, bm, cand, pos);
              if (l >= minL) {
                _len = l;
                _ptr = cand;
              }
            }
          }
          if (_len == 0) {
            final cand = _htS[hs];
            if (cand > 0) {
              final l = _verify(buf, bm, cand, pos);
              if (l >= minS) {
                _len = l;
                _ptr = cand;
              }
            }
          }
        }
        _htS[hs] = pos;
        if (hl >= 0) _htL[hl] = pos;
      }
      if (_len > 0) _exp = buf[_ptr & bm];
    } else if (_len > 0 && ((_exp + 256) >> (8 - s.bpos)) != s.c0) {
      _len = 0;
    }
    final y = s.y;
    if (_len > 0) {
      final bit = (_exp >> (7 - s.bpos)) & 1;
      final lq = _lenQ();
      final p1 = _sm1.p(y, (lq << 1) | bit);
      final st = kStretch[p1];
      m.add(st);
      final lc = lq < 32 ? lq : 32;
      m.add(bit != 0 ? lc << 6 : -(lc << 6));
      final lb = lq < 16 ? (lq < 8 ? 0 : 1) : (lq < 24 ? 2 : 3);
      final p2 = _sm2.p(y, (((_exp << 3 | s.bpos) << 1 | bit) << 2) | lb);
      m.add(kStretch[p2]);
    } else {
      _sm1.p(y, 0);
      _sm2.p(y, 0);
      m.add(0);
      m.add(0);
      m.add(0);
    }
  }

  // Length of the common history before [cand] and [pos] (capped).
  int _verify(Uint8List buf, int bm, int cand, int pos) {
    if (pos - cand > bm - 64) return 0;
    var l = 0;
    while (l < 400 &&
        l < cand &&
        buf[(cand - 1 - l) & bm] == buf[(pos - 1 - l) & bm]) {
      l++;
    }
    return l;
  }
}

/// Word and text model (after paq8l wordModel): hashes of the current and
/// previous words, the letters of the text, and the line layout (column,
/// the byte above, the indentation), plus the innermost open bracket.
final class WordModel implements ZcmModel {
  final ContextMap _cm;
  int _w0 = 0, _w1 = 0, _w2 = 0, _w3 = 0, _w4 = 0;
  int _text0 = 0;
  int _lastNl = 0, _prevNl = 0;
  int _indent = 0, _inIndent = 1;
  int _punct = 0;
  int _num = 0;
  final Uint8List _brackets = Uint8List(64);
  int _depth = 0;

  /// [contexts]: 5 (the main word contexts), 10 (the word and line
  /// contexts) or 16 (all).
  WordModel(int bytes, {int contexts = 16})
      : _cm = ContextMap(
            bytes, contexts <= 5 ? 5 : (contexts < 16 ? 10 : 16));

  @override
  int get inputs => _cm.nCtx * _cm.inputsPerContext;

  @override
  void mix(ZcmState s, Mixer m) {
    if (s.bpos == 0) {
      var c = s.c4 & 255;
      final pos = s.pos;
      if (c >= 65 && c <= 90) c += 32;
      final letter = (c >= 97 && c <= 122) || c >= 128;
      if (letter) {
        _w0 = hash2(_w0 + 0x9E37, c);
        _text0 = (_text0 * 997 * 16 + c) & 0xFFFFFFFF;
      } else if (_w0 != 0) {
        _w4 = _w3;
        _w3 = _w2;
        _w2 = _w1;
        _w1 = _w0;
        _w0 = 0;
      }
      if (c >= 48 && c <= 57) {
        _num = hash2(_num + 7, c);
      } else if (!letter) {
        _num = 0;
      }
      if (!letter && c != 32 && !(c >= 48 && c <= 57)) {
        _punct = c;
      }
      // Brackets: ( [ { < and their closing forms.
      if (c == 40 || c == 91 || c == 123) {
        if (_depth < 64) _brackets[_depth] = c;
        _depth++;
      } else if ((c == 41 || c == 93 || c == 125) && _depth > 0) {
        _depth--;
      }
      if (c == 10) {
        _prevNl = _lastNl;
        _lastNl = pos;
        _indent = 0;
        _inIndent = 1;
      } else if (_inIndent != 0) {
        if (c == 32 || c == 9) {
          _indent++;
        } else {
          _inIndent = 0;
        }
      }
      final col = pos - _lastNl;
      final lineLen = _lastNl - _prevNl;
      final above = col < lineLen ? s.back(lineLen) : 0;
      final colQ = col < 32 ? col : 32 + (col >> 4) - 2;
      final c1 = s.c4 & 255;
      final c4 = s.c4;
      final h = hash2(_w0, c1);
      final br = _depth == 0 ? 0 : _brackets[(_depth - 1) & 63] | (_depth < 8 ? _depth : 8) << 8;
      _cm.set(0, hash2(_w0, 1));
      _cm.set(1, hash3(h, _w1, 2));
      _cm.set(2, hash4(h, _w1, _w2, 3));
      _cm.set(3, hash3(_w0, _punct, 4));
      if (_cm.nCtx == 5) {
        _cm.set(4, hash3(above, colQ, 7));
        return _mixOnly(s, m);
      }
      _cm.set(4, hash3(h, _w2, 5));
      _cm.set(5, hash3(h, _w3, 6));
      _cm.set(6, hash3(above, colQ, 7));
      _cm.set(7, hash4(above, c1, (c4 >> 8) & 255, 8));
      _cm.set(8, hash3(_num, _w0 == 0 ? c1 : 256, 9));
      _cm.set(9, hash4(h, _w1, _w3, 10));
      if (_cm.nCtx < 16) return _mixOnly(s, m);
      _cm.set(10, hash2(_text0 & 0xFFFFFF, 11));
      _cm.set(11, hash2(_text0 & 0xFFFFF, 12));
      _cm.set(12, hash3(c1 | (c4 >> 8 & 0xFF00), _w4, 13));
      _cm.set(13, hash4(_indent, _inIndent, col < 64 ? col : 64, c1 | 14 << 8));
      _cm.set(14, hash3(br, c1, 15));
      _cm.set(15, hash4(br, _w0, (c4 >> 8) & 255, 16));
    }
    _cm.mix(m, s.y, s.bpos, s.c0, s.c4 & 255);
  }

  void _mixOnly(ZcmState s, Mixer m) =>
      _cm.mix(m, s.y, s.bpos, s.c0, s.c4 & 255);
}

/// Sparse contexts: bytes at gaps (paq8 sparseModel).
final class SparseModel implements ZcmModel {
  final ContextMap _cm;

  /// [light]: 5 of the 10 contexts (faster).
  SparseModel(int bytes, {bool light = false})
      : _cm = ContextMap(bytes, light ? 5 : 10, rich: false);

  @override
  int get inputs => _cm.nCtx * _cm.inputsPerContext;

  @override
  void mix(ZcmState s, Mixer m) {
    if (s.bpos == 0 && _cm.nCtx == 5) {
      final c4 = s.c4;
      final lane = s.pos & 3;
      _cm.set(0, c4 & 0xFF00);
      _cm.set(1, c4 & 0xFF0000);
      _cm.set(2, c4 & 0xFF00FF00);
      _cm.set(3, hash2(c4 & 0xFFFF, s.c8 >> 16));
      _cm.set(4, hash4(lane, c4 >> 24, s.c8 >> 24, 9));
    } else if (s.bpos == 0) {
      final c4 = s.c4;
      _cm.set(0, c4 & 0xFF00);
      _cm.set(1, c4 & 0xFF0000);
      _cm.set(2, c4 & 0xFF000000);
      _cm.set(3, c4 & 0xFFFF0000);
      _cm.set(4, c4 & 0xFF00FF00);
      _cm.set(5, c4 & 0x00FF00FF);
      _cm.set(6, hash2(s.c8 & 0xFFFF, 6));
      _cm.set(7, hash2(c4 & 0xFFFF, s.c8 >> 16));
      // Lanes of 32-bit words (ARM and other fixed size instructions,
      // tables of 32-bit values).
      final lane = s.pos & 3;
      _cm.set(8, hash3(lane, c4 >> 24, 8));
      _cm.set(9, hash4(lane, c4 >> 24, s.c8 >> 24, 9));
    }
    _cm.mix(m, s.y, s.bpos, s.c0, s.c4 & 255);
  }
}

/// Indirect contexts: the bytes that followed the last occurrences of the
/// current contexts (paq8 indirectModel; the extended set of paq8px
/// IndirectModel with [full]: top bit contexts, lowercase text and
/// hashed 3 and 4 byte contexts).
final class IndirectModel implements ZcmModel {
  final ContextMap _cm;
  final bool full;
  final Uint32List _t1 = Uint32List(256);
  final Uint16List _t2 = Uint16List(65536);
  final Uint16List _t3 = Uint16List(32768);
  final Uint16List _t4 = Uint16List(65536);
  final Uint32List _t5 = Uint32List(65536);
  final Uint32List _large;
  final int _largeMask;
  int _chars4 = 0;

  IndirectModel(int bytes, {this.full = false})
      : _cm = ContextMap(full ? bytes * 3 ~/ 4 : bytes, full ? 27 : 6,
            rich: false),
        _large = Uint32List(full ? floorPow2(bytes ~/ 16 < 4096 ? 4096 : bytes ~/ 16) : 1),
        _largeMask = full ? floorPow2(bytes ~/ 16 < 4096 ? 4096 : bytes ~/ 16) - 1 : 0;

  @override
  int get inputs => _cm.nCtx * _cm.inputsPerContext;

  @override
  void mix(ZcmState s, Mixer m) {
    if (s.bpos == 0) {
      if (full) {
        _setFull(s);
      } else {
        final c4 = s.c4;
        final d = c4 & 0xFFFF;
        final c = d & 255;
        _t1[d >> 8] = ((_t1[d >> 8] << 8) | c) & 0xFFFFFFFF;
        final i2 = (c4 >> 8) & 0xFFFF;
        _t2[i2] = ((_t2[i2] << 8) | c) & 0xFFFF;
        var t = (c | (_t1[c] << 8)) & 0xFFFFFFFF;
        _cm.set(0, t & 0xFFFF);
        _cm.set(1, t & 0xFFFFFF);
        _cm.set(2, hash2(t, 2));
        _cm.set(3, t & 0xFF00);
        t = d | (_t2[d] << 16);
        _cm.set(4, hash2(t & 0xFFFFFF, 4));
        _cm.set(5, hash2(t, 5));
      }
    }
    _cm.mix(m, s.y, s.bpos, s.c0, s.c4 & 255);
  }

  void _setFull(ZcmState s) {
    final c4 = s.c4;
    final b1 = c4 & 255, b2 = (c4 >> 8) & 255, b3 = (c4 >> 16) & 255;
    final b4 = (c4 >> 24) & 255, b5 = s.c8 & 255;
    final c1 = b1;
    final d2 = c4 & 0xFFFF;
    final d3 = (b1 >> 3) | (b2 >> 3) << 5 | (b3 >> 3) << 10;
    final d4 = (b1 >> 4) | (b2 >> 4) << 4 | (b3 >> 4) << 8 | (b4 >> 4) << 12;
    final h1 = (c1 | _t1[c1] << 8) & 0xFFFFFFFF;
    final h2 = d2 | _t2[d2] << 16;
    final h3 = d3 | _t3[d3] << 16;
    final h4 = d4 | _t4[d4] << 16;
    _t1[d2 >> 8] = ((_t1[d2 >> 8] << 8) | c1) & 0xFFFFFFFF;
    _t2[(c4 >> 8) & 0xFFFF] = (_t2[(c4 >> 8) & 0xFFFF] << 8) | c1;
    final i3 = (b2 >> 3) | (b3 >> 3) << 5 | (b4 >> 3) << 10;
    _t3[i3] = (_t3[i3] << 8) | c1;
    final i4 = (b2 >> 4) | (b3 >> 4) << 4 | (b4 >> 4) << 8 | (b5 >> 4) << 12;
    _t4[i4] = (_t4[i4] << 8) | c1;
    final text = s.blockType == ZcmBlockType.text;
    _i = s.blockType * 64;
    _k = 0;
    put(h1);
    put(h1 & 0xFFFFFF00);
    put(_t1[c1]);
    put(h2);
    put(h4);
    put(h1 & 0xFFFF);
    put(h2 & 0xFF0000);
    put(h2 & 0xFFFFFF);
    if (!text) {
      put(h1 & 0xFF00);
      put(h3);
      put(h3 & 0xFF0000);
      put(h3 & 0xFFFFFF);
      put(h4 & 0xFF0000);
      put(h4 & 0xFFFFFF);
    }
    // Lowercase text contexts.
    final lc = (c1 >= 65 && c1 <= 90) ? c1 + 32 : c1;
    _chars4 = ((_chars4 << 8) | lc) & 0xFFFFFFFF;
    final h5 = _t5[_chars4 & 0xFFFF];
    final i5 = (_chars4 >> 8) & 0xFFFF;
    _t5[i5] = ((_t5[i5] << 8) | lc) & 0xFFFFFFFF;
    put((h5 & 0xFF) | lc << 8);
    put(h5 & 0xFFFF);
    put(h5 & 0xFFFFFF);
    put(h5);
    // Hashed contexts of 3 and 4 bytes and their byte histories.
    setLarge(c4 >> 8, c1);
    var ctx = c4 & 0xFFFFFF;
    var h6 = getLarge(ctx);
    put(hash2(h6 & 0xFF, ctx & 0xFF));
    put(hash2(h6 & 0xFF, ctx & 0xFFFF));
    put(hash2(h6, ctx & 0xFF));
    setLarge(_chars4 >> 8 | 0x1000000, c1);
    ctx = (_chars4 & 0xFFFFFF) | 0x1000000;
    h6 = getLarge(ctx);
    put(hash2(h6 & 0xFF, ctx));
    put(hash2(h6 & 0xFFFF, ctx));
    put(h6);
    setLarge(hash2(b5 << 24 | c4 >> 8, 7), c1);
    h6 = getLarge(hash2(c4, 7));
    put(hash2(h6 & 0xFF, c4 & 0xFFFF));
    put(hash2(h6 & 0xFFFF, c4 & 0xFF));
    put(h6);
    // Text blocks use fewer contexts: fill the rest.
    while (_k < _cm.nCtx) {
      put(0);
    }
  }

  int _i = 0, _k = 0;

  void put(int h) => _cm.set(_k++, hash2(h, ++_i));

  void setLarge(int ctx, int c1) {
    final j = hash2(ctx, _i) & _largeMask;
    _large[j] = ((_large[j] << 8) | c1) & 0xFFFFFFFF;
  }

  int getLarge(int ctx) => _large[hash2(ctx, _i) & _largeMask];
}

/// Character group contexts (paq8px CharGroupModel): the sequence of
/// character classes (digits, upper, lower, high, others as themselves)
/// with runs of a class collapsed.
final class CharGroupModel implements ZcmModel {
  final ContextMap _cm;
  int _g1 = 0, _g2 = 0, _g3 = 0;

  CharGroupModel(int bytes) : _cm = ContextMap(bytes, 7, bh: true);

  @override
  int get inputs => _cm.nCtx * _cm.inputsPerContext;

  @override
  void mix(ZcmState s, Mixer m) {
    if (s.bpos == 0) {
      final c4 = s.c4;
      var g = c4 & 255;
      if (g >= 48 && g <= 57) {
        g = 48;
      } else if (g >= 65 && g <= 90) {
        g = 65;
      } else if (g >= 97 && g <= 122) {
        g = 97;
      } else if (g >= 128) {
        g = 128;
      }
      final collapse = (g == 48 || g == 65 || g == 97) && g == (_g1 & 255);
      if (!collapse) {
        _g3 = ((_g3 << 8) | (_g2 >> 24)) & 0xFFFFFFFF;
        _g2 = ((_g2 << 8) | (_g1 >> 24)) & 0xFFFFFFFF;
        _g1 = ((_g1 << 8) | g) & 0xFFFFFFFF;
      }
      var i = collapse ? 7 : 0;
      _cm.set(0, hash4(++i, _g3, _g2, _g1));
      _cm.set(1, hash3(++i, _g2, _g1));
      _cm.set(2, hash3(++i, _g2 & 0xFFFF, _g1));
      _cm.set(3, hash2(++i, _g1));
      _cm.set(4, hash2(++i, _g1 & 0xFFFF));
      _cm.set(5, hash4(++i, _g2 & 0xFFFFFF, _g1, c4 & 0xFFFF));
      _cm.set(6, hash4(++i, _g2 & 0xFF, _g1, c4 & 0xFFFFFF));
    }
    _cm.mix(m, s.y, s.bpos, s.c0, s.c4 & 255);
  }
}

/// Record model: finds a record length from repeating byte distances and
/// models the columns (paq8 recordModel).
final class RecordModel implements ZcmModel {
  final ContextMap _cm;
  final Int32List _cpos1 = Int32List(256);
  final Int32List _cpos2 = Int32List(256);
  final Int32List _cpos3 = Int32List(256);
  final Int32List _cpos4 = Int32List(256);
  final Int32List _wpos1 = Int32List(65536);
  int _rlen = 2, _rlen1 = 3, _rlen2 = 4, _rcount1 = 0, _rcount2 = 0;

  RecordModel(int bytes) : _cm = ContextMap(bytes, 6, rich: false);

  @override
  int get inputs => _cm.nCtx * _cm.inputsPerContext;

  /// Detected record length (2 when none).
  int get recordLength => _rlen;

  @override
  void mix(ZcmState s, Mixer m) {
    if (s.bpos == 0) {
      final pos = s.pos;
      final c4 = s.c4;
      final c = c4 & 255;
      final w = c4 & 0xFFFF;
      final r = pos - _cpos1[c];
      if (r > 1 &&
          r == _cpos1[c] - _cpos2[c] &&
          r == _cpos2[c] - _cpos3[c] &&
          r == _cpos3[c] - _cpos4[c] &&
          (r > 15 ||
              (r * 6 + 1 <= pos &&
                  c == s.back(r * 5 + 1) &&
                  c == s.back(r * 6 + 1)))) {
        if (r == _rlen1) {
          _rcount1++;
        } else if (r == _rlen2) {
          _rcount2++;
        } else if (_rcount1 > _rcount2) {
          _rlen2 = r;
          _rcount2 = 1;
        } else {
          _rlen1 = r;
          _rcount1 = 1;
        }
      }
      if (_rcount1 > 15 && _rlen != _rlen1) {
        _rlen = _rlen1;
        _rcount1 = _rcount2 = 0;
      }
      if (_rcount2 > 15 && _rlen != _rlen2) {
        _rlen = _rlen2;
        _rcount1 = _rcount2 = 0;
      }
      _cpos4[c] = _cpos3[c];
      _cpos3[c] = _cpos2[c];
      _cpos2[c] = _cpos1[c];
      _cpos1[c] = pos;
      final dw = pos - _wpos1[w];
      _wpos1[w] = pos;
      final rl = _rlen;
      final above = rl <= pos ? s.back(rl) : 0;
      final above2 = rl * 2 <= pos ? s.back(rl * 2) : 0;
      final col = pos % rl;
      final dc = pos - _cpos2[c];
      _cm.set(0, hash2(c << 8 | (dc < 1020 ? dc >> 2 : 255), 0));
      _cm.set(1, hash2(w << 9 | (kIlog[dw < 65535 ? dw : 65535] >> 2), 1));
      _cm.set(2, hash3(rl, above | above2 << 8, 2));
      _cm.set(3, hash3(rl, above | col << 8, 3));
      _cm.set(4, hash3(rl, c | col << 8, 4));
      _cm.set(5, hash3(rl, w, 5));
    }
    _cm.mix(m, s.y, s.bpos, s.c0, s.c4 & 255);
  }
}

/// x86 contexts (paq8 execxt: prefix, opcode and ModRM of earlier bytes);
/// used on exe blocks, after the E8/E9 transform.
final class ExeModel implements ZcmModel {
  final ContextMap _cm;

  /// [contexts]: 8 (paq8's execxt set) or fewer of them (faster).
  ExeModel(int bytes, {int contexts = 8})
      : _cm = ContextMap(bytes, contexts, rich: false);

  @override
  int get inputs => _cm.nCtx * _cm.inputsPerContext;

  static int _pref(int b) =>
      (b == 0x0F ? 1 : 0) + (b == 0x66 ? 2 : 0) + (b == 0x67 ? 3 : 0);

  // execxt(i, x)
  static int _ctx(ZcmState s, int i, int x) {
    var prefix = 0, opcode = 0, modrm = 0, sib = 0;
    final pos = s.pos;
    if (i > 0 && i <= pos) prefix += 4 * _pref(s.back(i--));
    if (i > 0 && i <= pos) prefix += _pref(s.back(i--));
    if (i > 0 && i <= pos) opcode += s.back(i--);
    if (i > 0 && i <= pos) modrm += s.back(i--) & 0xC7;
    if (i > 0 && i <= pos && (modrm & 7) == 4 && modrm < 0xC0) {
      sib = s.back(i) & 0xC0;
    }
    return prefix | opcode << 4 | modrm << 12 | x << 20 | sib << 22;
  }

  @override
  void mix(ZcmState s, Mixer m) {
    if (s.bpos == 0) {
      final n = _cm.nCtx;
      for (var k = 0; k < n; k++) {
        final i = n == 8 ? k : const [0, 1, 2, 5, 4, 6, 3, 7][k];
        final j = i < 4 ? i + 1 : 5 + (i - 4) * (2 + (i > 6 ? 1 : 0));
        _cm.set(k, hash3(i, _ctx(s, j, j > 6 ? (s.c4 & 255) : 0), s.pos & 3));
      }
    }
    _cm.mix(m, s.y, s.bpos, s.c0, s.c4 & 255);
  }
}

/// Dynamic Markov coding (paq8 dmcModel, after Cormack and Horspool): a
/// state machine of bit contexts that clones states which are reached
/// often, starting from a bytewise order 1 graph and restarting when the
/// node table is full.
final class DmcModel implements ZcmModel {
  final Int32List _nx0;
  final Int32List _nx1;
  final Uint8List _state;
  final Uint16List _c0;
  final Uint16List _c1;
  final int _size;
  final StateMap _sm = StateMap(256, bitHistory: true);
  int _top = 0;
  int _curr = 0;
  int _threshold = 256;
  final int _baseThreshold;
  final ZcmRandom _rnd = ZcmRandom();
  final Int16List _str = kStretch;

  /// [bytes] of nodes (12 bytes each, at least 2^18 nodes).
  DmcModel(int bytes, {int threshold = 256})
      : _size = nodesFor(bytes),
        _nx0 = Int32List(nodesFor(bytes)),
        _nx1 = Int32List(nodesFor(bytes)),
        _state = Uint8List(nodesFor(bytes)),
        _c0 = Uint16List(nodesFor(bytes)),
        _c1 = Uint16List(nodesFor(bytes)),
        _baseThreshold = threshold;

  /// Nodes for a budget of [bytes].
  static int nodesFor(int bytes) => bytes ~/ 12 < (1 << 18) ? 1 << 18 : bytes ~/ 12;

  @override
  int get inputs => 2;

  void _reset() {
    for (var i = 0; i < 256; i++) {
      for (var j = 0; j < 256; j++) {
        final k = j * 256 + i;
        if (i < 127) {
          _nx0[k] = j * 256 + i * 2 + 1;
          _nx1[k] = j * 256 + i * 2 + 2;
        } else {
          _nx0[k] = (i - 127) * 256;
          _nx1[k] = (i + 1) * 256;
        }
        _c0[k] = 128;
        _c1[k] = 128;
        _state[k] = 0;
      }
    }
    _top = 65536;
    _curr = 0;
    _threshold = _baseThreshold;
  }

  @override
  void mix(ZcmState s, Mixer m) {
    final y = s.y;
    if (_top == 0) {
      _reset();
    } else {
      // Clone the next state when it is reached often from here.
      final curr = _curr;
      if (_top < _size) {
        final next = y != 0 ? _nx1[curr] : _nx0[curr];
        final n = y != 0 ? _c1[curr] : _c0[curr];
        final nn = _c0[next] + _c1[next];
        if (n >= _threshold * 2 && nn - n >= _threshold * 3) {
          final r = n * 4096 ~/ nn;
          final top = _top;
          final a0 = (_c0[next] * r) >> 12;
          final a1 = (_c1[next] * r) >> 12;
          _c0[top] = a0;
          _c1[top] = a1;
          _c0[next] -= a0;
          _c1[next] -= a1;
          _nx0[top] = _nx0[next];
          _nx1[top] = _nx1[next];
          _state[top] = _state[next];
          if (y != 0) {
            _nx1[curr] = top;
          } else {
            _nx0[curr] = top;
          }
          _top = top + 1;
          if (_top == _size * 2 ~/ 3) _threshold = _baseThreshold * 2;
          if (_top == _size * 5 ~/ 6) _threshold = _baseThreshold * 3;
        }
      }
      // Update the counts and the state.
      if (y != 0) {
        if (_c1[curr] < 3800) _c1[curr] += 256;
      } else if (_c0[curr] < 3800) {
        _c0[curr] += 256;
      }
      _state[curr] = nextState(_state[curr], y, _rnd);
      _curr = y != 0 ? _nx1[curr] : _nx0[curr];
      if (_top >= _size && s.bpos == 1) _reset();
    }
    final c = _curr;
    final p1 = _sm.p(y, _state[c]);
    final n1 = _c1[c];
    final n0 = _c0[c];
    var p2 = (n1 + 5) * 4096 ~/ (n0 + n1 + 10);
    if (p2 > 4095) p2 = 4095;
    final tx = m.tx;
    final k = m.nx;
    tx[k] = _str[p1];
    tx[k + 1] = _str[p2];
    m.nx = k + 2;
  }
}
