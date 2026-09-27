// Vendored from zpaq-flutter by tool/sync_zpaq.sh: do not edit here, change
// zpaq-flutter and sync again. Pure Dart port of libzpaq and zpaq 7.15 (Matt
// Mahoney, public domain) with the zpaqfranz attribute format (Franco
// Corbelli, MIT). Copyright (c) 2026 Max Brito, BSD 3-clause; see LICENSE
// for the license and the third party notices.

import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/zpaq/core/compiler.dart';
import 'package:zx/src/zpaq/core/decompresser.dart';
import 'package:zx/src/zpaq/core/io.dart';
import 'package:zx/src/zpaq/core/lzbuffer.dart';
import 'package:zx/src/zpaq/core/method.dart';
import 'package:zx/src/zpaq/core/native_pcomp.dart';
import 'package:zx/src/zpaq/core/zpaql.dart';

Uint8List _decode(Uint8List z, {required bool native}) {
  PostProcessor.nativeEnabled = native;
  try {
    final out = ZBuffer();
    decompressAll(MemoryReader(z), out);
    return Uint8List.fromList(out.bytes);
  } finally {
    PostProcessor.nativeEnabled = true;
  }
}

Uint8List _sample(Random r, int n, int kind) {
  final b = Uint8List(n);
  switch (kind) {
    case 0: // random
      for (var i = 0; i < n; ++i) {
        b[i] = r.nextInt(256);
      }
    case 1: // small alphabet with repeats
      for (var i = 0; i < n; ++i) {
        b[i] = i > 20 && r.nextInt(4) == 0
            ? b[i - 1 - r.nextInt(20)]
            : 97 + r.nextInt(4);
      }
    case 3: // short periods: long matches that overlap themselves
      final period = 1 + r.nextInt(24);
      for (var i = 0; i < n; ++i) {
        b[i] =
            i < period || r.nextInt(500) == 0 ? r.nextInt(256) : b[i - period];
      }
    default: // x86-like: lots of E8/E9 xx xx xx 00/FF patterns
      for (var i = 0; i < n; ++i) {
        final k = r.nextInt(10);
        b[i] = k == 0
            ? 0xe8
            : k == 1
                ? 0xe9
                : k == 2
                    ? 0
                    : k == 3
                        ? 255
                        : r.nextInt(256);
      }
  }
  return b;
}

void main() {
  test('recognizes the canonical programs', () {
    for (final m in [
      'x4,1,4,0,3,24',
      'x9,5,4,0,3,24',
      'x4,2,12,0,7,25',
      'x6,6,33,0,3,20',
      'x4,3',
      'x7,7',
      'x4,4',
    ]) {
      final args = List<int>.filled(9, 0);
      final hz = Zpaql(), pz = Zpaql();
      Compiler(makeConfig(m, args), args, hz, pz).compile();
      final r = recognizePcomp(pz.header, pz.hbegin, pz.hend - pz.hbegin);
      expect(r, isNotNull, reason: m);
      if (m == 'x4,2,12,0,7,25') expect(r!.minMatch, 12);
      if (m == 'x9,5,4,0,3,24') expect(r!.rb, 5);
    }
  });

  test('every standard postprocessor decodes like the interpreter', () {
    for (final m in [
      '1,200,0',
      '1,200,2',
      '2,200,0',
      '2,200,2',
      '3,200,1',
      '3,200,3',
      '3,200,0',
      '3,200,2',
      '4,200,0',
      '0,0,2',
      'x5,3',
      'x5,7',
      'x6,1,4,0,3,24',
      'x4,2,12,0,7,25,1',
      'x4,6,5,0,3,24',
    ]) {
      final z = ZBuffer();
      compressBlock(ZBuffer.of(Uint8List.fromList(List.filled(1000, 7))), z, m);
      // decoding natively must give the same result as the interpreter
      expect(_decode(z.bytes, native: true), _decode(z.bytes, native: false),
          reason: m);
    }
  });

  test('native decoders match the ZPAQL interpreter on random data', () {
    final r = Random(42);
    final methods = [
      '1,200,0',
      '1,200,2',
      '2,200,0',
      '2,200,2',
      '3,200,1',
      '3,200,3',
      '3,200,0',
      '3,200,2',
      '0,0,2',
      'x5,1,4,0,3,24',
      'x5,5,4,0,3,24',
      'x5,3',
      'x5,7',
      'x4,2,1,0,3,20',
      'x4,6,40,0,3,20',
    ];
    for (var round = 0; round < 120; ++round) {
      final n = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 50, 1000, 30000][r.nextInt(13)];
      final data = _sample(r, n, r.nextInt(4));
      final m = methods[r.nextInt(methods.length)];
      final z = ZBuffer();
      compressBlock(ZBuffer.of(Uint8List.fromList(data)), z, m);
      final a = _decode(z.bytes, native: true);
      final b = _decode(z.bytes, native: false);
      expect(a, b, reason: 'method $m size $n');
      expect(a, data, reason: 'method $m size $n roundtrip');
    }
  });

  test('unE8e9 inverts e8e9', () {
    final r = Random(1);
    for (var k = 0; k < 200; ++k) {
      final d = _sample(r, r.nextInt(64), 2);
      final t = Uint8List.fromList(d);
      e8e9(t, t.length);
      unE8e9(t, t.length);
      expect(t, d);
    }
  });
}
