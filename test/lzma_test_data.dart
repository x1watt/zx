// Deterministic inputs for test/lzma_test.dart (also dumped by
// tool/lzma_golden.dart to produce the reference hashes with the SDK).

import 'dart:typed_data';

/// Linear congruential generator (Numerical Recipes constants).
class Lcg {
  int _s;
  Lcg(int seed) : _s = seed & 0xFFFFFFFF;
  int next() {
    _s = (_s * 1664525 + 1013904223) & 0xFFFFFFFF;
    return _s;
  }
}

const _words = [
  'the',
  'of',
  'and',
  'lzma',
  'range',
  'coder',
  'match',
  'finder',
  'dictionary',
  'literal',
  'distance',
  'length',
  'state',
  'price',
  'optimum',
  'encoder',
  'decoder',
  'stream',
  'block',
  'chunk',
  'window',
  'hash',
  'binary',
  'tree',
  'chain',
  'Igor',
  'Pavlov',
  'public',
  'domain',
];

/// Text-like data: words, punctuation and line breaks.
Uint8List genText(int n, [int seed = 1]) {
  final r = Lcg(seed);
  final out = Uint8List(n);
  var i = 0;
  while (i < n) {
    final w = _words[(r.next() >> 8) % _words.length];
    for (var k = 0; k < w.length && i < n; k++) {
      out[i++] = w.codeUnitAt(k);
    }
    if (i < n) {
      final c = (r.next() >> 12) % 16;
      out[i++] = c == 0 ? 10 : (c == 1 ? 0x2C : 0x20);
    }
  }
  return out;
}

/// Binary-like data: repeated records with small changes, runs, noise.
Uint8List genBinary(int n, [int seed = 7]) {
  final r = Lcg(seed);
  final out = Uint8List(n);
  var i = 0;
  while (i < n) {
    final kind = (r.next() >> 16) % 4;
    final len = 16 + (r.next() >> 20) % 400;
    for (var k = 0; k < len && i < n; k++) {
      switch (kind) {
        case 0:
          out[i] = r.next() >> 24;
        case 1:
          out[i] = 0;
        case 2:
          out[i] = (k * 4) & 0xFF;
        default:
          out[i] = i >= 1000 ? out[i - 1000 + (k & 7)] : k;
      }
      i++;
    }
  }
  return out;
}

/// Uniform noise (incompressible).
Uint8List genRandom(int n, [int seed = 3]) {
  final r = Lcg(seed);
  final out = Uint8List(n);
  for (var i = 0; i < n; i++) {
    out[i] = r.next() >> 24;
  }
  return out;
}

/// All inputs used by the golden tests, by name.
Map<String, Uint8List> goldenInputs() => {
      'empty': Uint8List(0),
      'one': Uint8List.fromList([0x41]),
      'zeros': Uint8List(300000),
      'text': genText(700000),
      'binary': genBinary(600000),
      'random': genRandom(200000),
      'mixed': Uint8List.fromList([
        ...genRandom(100000, 5),
        ...genText(300000, 9),
        ...genBinary(250000, 11)
      ]),
    };
