// zcm: the English dictionary transform of text segments.
//
// The word replacement preprocessor of cmix (Byron Knoll,
// src/preprocess/dictionary.cpp), with its dictionary english.dic (44,515
// words ordered by frequency, the first 80 coded in one byte, the next
// 3,840 in two, the rest in three; zcm_dict_words.dart): words of
// lowercase letters become their codes, a capitalized word gets a 0x40
// prefix, an all uppercase word 0x07 (and 0x06 when lowercase letters
// follow it directly), and bytes that collide with the codes or flags are
// escaped with 0x0C. Words of more than 7 letters that are not in the
// dictionary are coded as a known suffix or prefix plus letters.
//
// The encoder applies it only to text that looks like English (most words
// in the dictionary), and only when decoding its output gives the input
// back exactly (zcmDictEncode checks that), so the transform is always
// reversible.

import 'dart:typed_data';

import 'zcm_dict_words.dart';

const int _kCapitalized = 0x40;
const int _kUppercase = 0x07;
const int _kEndUpper = 0x06;
const int _kEscape = 0x0C;
const int _kQuote = 0x08;
const List<int> _kQuoteStr = [0x26, 0x71, 0x75, 0x6F, 0x74, 0x3B]; // &quot;

// The dictionary: the words as bytes, a hash table from words to their
// numbers, and the codes of cmix (Dictionary::Dictionary).
final class _Dict {
  final Uint8List raw;
  final Int32List start; // offset of word i in raw; start[n] is the end
  final Int32List _table; // open addressing: word number + 1, 0: empty
  final int _mask;
  final int n;
  final int longest;

  factory _Dict() {
    final raw = zcmDictBytes();
    final starts = <int>[];
    var longest = 0;
    var i = 0;
    while (i < raw.length) {
      var j = i;
      while (j < raw.length && raw[j] >= 0x61 && raw[j] <= 0x7A) {
        j++;
      }
      if (j > i) {
        starts.add(i);
        if (j - i > longest) longest = j - i;
      }
      i = j + 1;
    }
    var n = starts.length;
    if (n > _b3) n = _b3;
    final start = Int32List(n + 1);
    for (var k = 0; k < n; k++) {
      start[k] = starts[k];
    }
    // The end of the last word, for its length.
    var e = starts[n - 1];
    while (e < raw.length && raw[e] >= 0x61 && raw[e] <= 0x7A) {
      e++;
    }
    start[n] = e;
    var size = 1;
    while (size < n * 2) {
      size <<= 1;
    }
    return _Dict._(raw, start, Int32List(size), size - 1, n, longest);
  }

  _Dict._(this.raw, this.start, this._table, this._mask, this.n, this.longest) {
    for (var k = 0; k < n; k++) {
      final s = start[k];
      var e = s;
      while (e < raw.length && raw[e] >= 0x61 && raw[e] <= 0x7A) {
        e++;
      }
      var h = _hash(raw, s, e - s) & _mask;
      while (_table[h] != 0) {
        h = (h + 1) & _mask;
      }
      _table[h] = k + 1;
    }
  }

  static const int _b1 = 80, _b2 = _b1 + 3840, _b3 = _b2 + 40960;

  int length(int k) {
    var e = start[k];
    final s = e;
    while (e < raw.length && raw[e] >= 0x61 && raw[e] <= 0x7A) {
      e++;
    }
    return e - s;
  }

  static int _hash(Uint8List b, int off, int len) {
    var h = 0x811C9DC5;
    for (var i = 0; i < len; i++) {
      h = ((h ^ b[off + i]) * 0x01000193) & 0xFFFFFFFF;
    }
    return h ^ (h >> 15);
  }

  /// The number of the word of [len] bytes at [off] of [b], or -1.
  int find(Uint8List b, int off, int len) {
    var h = _hash(b, off, len) & _mask;
    while (true) {
      final v = _table[h];
      if (v == 0) return -1;
      final k = v - 1;
      final s = start[k];
      if (length(k) == len) {
        var i = 0;
        while (i < len && raw[s + i] == b[off + i]) {
          i++;
        }
        if (i == len) return k;
      }
      h = (h + 1) & _mask;
    }
  }

  /// The code of word [k] (up to 3 bytes, low byte first).
  static int code(int k) {
    if (k < _b1) return 0x80 + k;
    if (k < _b2) {
      return (0xD0 + (k - _b1) ~/ 80) | (0x80 + (k - _b1) % 80) << 8;
    }
    final q = (k - _b2) ~/ 80;
    return (0xF0 + q ~/ 32) | (0xD0 + q % 32) << 8 | (0x80 + (k - _b2) % 80) << 16;
  }

  /// The word number of a code, or -1 ([b0] first; [b1], [b2] as read).
  int wordOf(int b0, int b1, int b2) {
    int k;
    if (b0 < 0xD0) {
      k = b0 - 0x80;
    } else if (b1 < 0xD0) {
      if (b1 < 0x80) return -1;
      k = _b1 + (b0 - 0xD0) * 80 + (b1 - 0x80);
    } else {
      if (b0 < 0xF0 || b2 < 0x80 || b2 >= 0xD0) return -1;
      k = _b2 + ((b0 - 0xF0) * 32 + (b1 - 0xD0)) * 80 + (b2 - 0x80);
    }
    return k >= 0 && k < n ? k : -1;
  }
}

_Dict? _dict;
_Dict get _theDict => _dict ??= _Dict();

final class _Out {
  Uint8List b;
  int n = 0;
  _Out(int cap) : b = Uint8List(cap < 16 ? 16 : cap);

  void add(int c) {
    if (n == b.length) {
      final nb = Uint8List(b.length * 2);
      nb.setRange(0, n, b);
      b = nb;
    }
    b[n++] = c;
  }

  Uint8List bytes() => Uint8List.sublistView(b, 0, n);
}

// EncodeByte
void _encodeByte(_Out o, int c) {
  if (c == _kEndUpper ||
      c == _kEscape ||
      c == _kUppercase ||
      c == _kCapitalized ||
      c == _kQuote ||
      c >= 0x80) {
    o.add(_kEscape);
  }
  o.add(c);
}

// EncodeBytes
void _encodeCode(_Out o, int code) {
  o.add(code & 0xFF);
  if ((code & 0xFF00) == 0) return;
  o.add((code >> 8) & 0xFF);
  if ((code & 0xFF0000) != 0) o.add((code >> 16) & 0xFF);
}

// EncodeSubstring: [w] holds the word ([len] lowercase letters).
bool _encodeSubstring(_Dict d, _Out o, Uint8List w, int len) {
  if (len <= 7) return false;
  var size = len - 1;
  if (size > d.longest) size = d.longest;
  // Suffixes, longest first.
  for (var sl = size; sl >= 7; sl--) {
    final k = d.find(w, len - sl, sl);
    if (k >= 0) {
      for (var i = 0; i < len - sl; i++) {
        o.add(w[i]);
      }
      _encodeCode(o, _Dict.code(k));
      return true;
    }
  }
  // Prefixes, longest first.
  for (var pl = size; pl >= 7; pl--) {
    final k = d.find(w, 0, pl);
    if (k >= 0) {
      _encodeCode(o, _Dict.code(k));
      for (var i = pl; i < len; i++) {
        o.add(w[i]);
      }
      return true;
    }
  }
  return false;
}

// EncodeWord
void _encodeWord(
    _Dict d, _Out o, Uint8List w, int len, int numUpper, bool nextLower) {
  if (numUpper > 1) {
    o.add(_kUppercase);
  } else if (numUpper == 1) {
    o.add(_kCapitalized);
  }
  final k = d.find(w, 0, len);
  if (k >= 0) {
    _encodeCode(o, _Dict.code(k));
  } else if (!_encodeSubstring(d, o, w, len)) {
    for (var i = 0; i < len; i++) {
      o.add(w[i]);
    }
  }
  if (numUpper > 1 && nextLower) o.add(_kEndUpper);
}

/// The transform of [len] bytes at [off] of [b] (Dictionary::Encode).
Uint8List zcmDictTransform(Uint8List b, int off, int len) {
  final d = _theDict;
  final o = _Out(len + (len >> 3) + 16);
  final word = Uint8List(d.longest + 2);
  var wl = 0;
  var numUpper = 0, numLower = 0, quoteState = 0;
  for (var pos = 0; pos < len; pos++) {
    final c = b[off + pos];
    if (c == _kQuoteStr[quoteState]) {
      quoteState++;
      if (quoteState == 6) {
        o.add(_kQuote);
        numUpper = 0;
        numLower = 0;
        wl = 0;
        quoteState = 0;
        continue;
      }
    } else {
      quoteState = 0;
    }
    var advance = false;
    if (wl > d.longest) {
      advance = true;
    } else if (c >= 0x61 && c <= 0x7A) {
      if (numUpper > 1) {
        advance = true;
      } else {
        numLower++;
        word[wl++] = c;
      }
    } else if (c >= 0x41 && c <= 0x5A) {
      if (numLower > 0) {
        advance = true;
      } else {
        numUpper++;
        word[wl++] = c + 32;
      }
    } else {
      advance = true;
    }
    if (pos == len - 1 && !advance) {
      _encodeWord(d, o, word, wl, numUpper, false);
    }
    if (advance) {
      if (wl == 0) {
        _encodeByte(o, c);
      } else {
        final nextLower = c >= 0x61 && c <= 0x7A;
        _encodeWord(d, o, word, wl, numUpper, nextLower);
        numLower = 0;
        numUpper = 0;
        wl = 0;
        if (nextLower) {
          numLower++;
          word[wl++] = c;
        } else if (c >= 0x41 && c <= 0x5A) {
          numUpper++;
          word[wl++] = c + 32;
        } else {
          _encodeByte(o, c);
        }
        if (pos == len - 1 && wl != 0) {
          _encodeWord(d, o, word, wl, numUpper, false);
        }
      }
    }
  }
  return o.bytes();
}

/// Inverse of [zcmDictTransform] (Dictionary::Decode): writes the text
/// of [t] to [out] at [off]; false when it does not give exactly [len]
/// bytes or [t] is not a valid transform.
bool zcmDictDecode(Uint8List t, Uint8List out, int off, int len) {
  final d = _theDict;
  final raw = d.raw;
  var upper = false, capital = false;
  var n = 0;
  var i = 0;
  final tl = t.length;
  final end = off + len;
  var p = off;
  while (i < tl) {
    var c = t[i++];
    if (c == _kEscape) {
      upper = false;
      if (i >= tl || p >= end) return false;
      out[p++] = t[i++];
    } else if (c == _kQuote) {
      if (p + 5 > end) return false;
      for (var k = 1; k < 6; k++) {
        out[p++] = _kQuoteStr[k];
      }
    } else if (c == _kUppercase) {
      upper = true;
    } else if (c == _kCapitalized) {
      capital = true;
    } else if (c == _kEndUpper) {
      upper = false;
    } else if (c >= 0x80) {
      var b1 = 0, b2 = 0;
      if (c > 0xCF) {
        if (i >= tl) return false;
        b1 = t[i++];
        if (b1 > 0xCF) {
          if (i >= tl) return false;
          b2 = t[i++];
        }
      }
      final k = d.wordOf(c, b1, b2);
      if (k < 0) return false;
      final s = d.start[k];
      final wl = d.length(k);
      if (p + wl > end) return false;
      for (var j = 0; j < wl; j++) {
        var ch = raw[s + j];
        if (j == 0 && capital) {
          ch -= 32;
          capital = false;
        }
        if (upper) ch = ch - 0x61 + 0x41;
        out[p++] = ch;
      }
    } else {
      if (!((c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A))) {
        upper = false;
      }
      if (capital || upper) c = (c - 0x61 + 0x41) & 0xFF;
      capital = false;
      if (p >= end) return false;
      out[p++] = c;
    }
  }
  n = p - off;
  return n == len;
}

/// Share of the words of a text that are in the dictionary (0 to 100),
/// from a sample of at most [sample] bytes at the start.
int zcmDictCoverage(Uint8List b, int off, int len, {int sample = 1 << 16}) {
  final d = _theDict;
  final end = off + (len < sample ? len : sample);
  var words = 0, known = 0;
  final w = Uint8List(64);
  var wl = 0;
  for (var i = off; i <= end; i++) {
    var c = i < end ? b[i] : 0;
    if (c >= 0x41 && c <= 0x5A) c += 32;
    if (c >= 0x61 && c <= 0x7A) {
      if (wl < 64) w[wl] = c;
      wl++;
    } else {
      if (wl >= 2 && wl <= 64) {
        words++;
        if (d.find(w, 0, wl) >= 0) known++;
      }
      wl = 0;
    }
  }
  return words < 16 ? 0 : known * 100 ~/ words;
}

/// Minimum [zcmDictCoverage] for the transform.
const int zcmDictMinCoverage = 50;

/// The transform of a text segment when it applies: English text (most
/// words in the dictionary) whose transform decodes back exactly. Null
/// otherwise.
Uint8List? zcmDictEncode(Uint8List b, int off, int len) {
  if (len < 1024) return null;
  if (zcmDictCoverage(b, off, len) < zcmDictMinCoverage) return null;
  final t = zcmDictTransform(b, off, len);
  if (t.length * 20 > len * 19) return null;
  final check = Uint8List(len);
  if (!zcmDictDecode(t, check, 0, len)) return null;
  for (var i = 0; i < len; i++) {
    if (check[i] != b[off + i]) return null;
  }
  return Uint8List.fromList(t);
}
