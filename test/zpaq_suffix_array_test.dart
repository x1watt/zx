// Vendored from zpaq-flutter by tool/sync_zpaq.sh: do not edit here, change
// zpaq-flutter and sync again. Pure Dart port of libzpaq and zpaq 7.15 (Matt
// Mahoney, public domain) with the zpaqfranz attribute format (Franco
// Corbelli, MIT). Copyright (c) 2026 Max Brito, BSD 3-clause; see LICENSE
// for the license and the third party notices.

import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/zpaq/core/divsufsort.dart';
import 'package:zx/src/zpaq/core/suffix_array.dart';

List<int> naive(Uint8List t) {
  final idx = List.generate(t.length, (i) => i);
  idx.sort((a, b) {
    while (a < t.length && b < t.length) {
      if (t[a] != t[b]) return t[a] - t[b];
      ++a;
      ++b;
    }
    return a == t.length ? -1 : 1; // shorter suffix first
  });
  return idx;
}

void main() {
  test('SA-IS and divsufsort match a naive suffix sort', () {
    final r = Random(7);
    for (var round = 0; round < 400; ++round) {
      final n = r.nextInt(300);
      final alpha = [1, 2, 3, 4, 256][r.nextInt(5)];
      final t = Uint8List.fromList(List.generate(n, (_) => r.nextInt(alpha)));
      final sa = Int32List(n + 1);
      saisSuffixArray(t, sa, n);
      expect(sa.sublist(0, n), naive(t), reason: 't=$t');
      buildSuffixArray(t, sa, n);
      expect(sa.sublist(0, n), naive(t), reason: 'divsufsort t=$t');
    }
  });

  test('divsufsort matches SA-IS on large and repetitive text', () {
    final r = Random(11);
    for (var round = 0; round < 120; ++round) {
      final n = r.nextInt(round < 100 ? 5000 : 300000);
      final t = _sample(r, n);
      final s1 = Int32List(n + 1), s2 = Int32List(n + 1);
      saisSuffixArray(t, s1, n);
      buildSuffixArray(t, s2, n);
      expect(s2, s1, reason: 'round $round n $n');
    }
  });
}

/// Random, periodic (tandem repeats) or self copying text over a small or
/// full alphabet, to reach all of divsufsort's sorting paths.
Uint8List _sample(Random r, int n) {
  final kind = r.nextInt(3);
  final alpha = const [1, 2, 3, 4, 20, 256][r.nextInt(6)];
  final t = Uint8List(n);
  if (kind == 0) {
    for (var i = 0; i < n; ++i) {
      t[i] = r.nextInt(alpha);
    }
  } else if (kind == 1) {
    final p = 1 + r.nextInt(40);
    for (var i = 0; i < n; ++i) {
      t[i] = i < p ? r.nextInt(alpha) : t[i - p];
    }
    for (var e = r.nextInt(5); e > 0 && n > 0; --e) {
      t[r.nextInt(n)] = r.nextInt(alpha);
    }
  } else {
    var i = 0;
    while (i < n) {
      if (i > 10 && r.nextBool()) {
        final s = r.nextInt(i), l = 1 + r.nextInt(3000);
        for (var j = 0; j < l && i < n; ++j) {
          t[i++] = t[s + j];
        }
      } else {
        t[i++] = r.nextInt(alpha);
      }
    }
  }
  return t;
}
