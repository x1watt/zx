// Vendored from zpaq-flutter by tool/sync_zpaq.sh: do not edit here, change
// zpaq-flutter and sync again. Pure Dart port of libzpaq and zpaq 7.15 (Matt
// Mahoney, public domain) with the zpaqfranz attribute format (Franco
// Corbelli, MIT). Copyright (c) 2026 Max Brito, BSD 3-clause; see LICENSE
// for the license and the third party notices.

// The generated predictors (kernels.g.dart) and context programs
// (hcomp.g.dart) must give exactly the output of the generic code.
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/zpaq/core/decompresser.dart';
import 'package:zx/src/zpaq/core/io.dart';
import 'package:zx/src/zpaq/core/method.dart';
import 'package:zx/src/zpaq/core/predictor.dart';
import 'package:zx/src/zpaq/core/zpaql.dart';

Uint8List _compress(Uint8List data, String method, bool generated) {
  Predictor.kernelsEnabled = generated;
  Zpaql.nativeEnabled = generated;
  try {
    final out = ZBuffer();
    compressBlock(ZBuffer.of(Uint8List.fromList(data)), out, method);
    return Uint8List.fromList(out.bytes);
  } finally {
    Predictor.kernelsEnabled = true;
    Zpaql.nativeEnabled = true;
  }
}

Uint8List _decompress(Uint8List z, bool generated) {
  Predictor.kernelsEnabled = generated;
  Zpaql.nativeEnabled = generated;
  try {
    final out = ZBuffer();
    decompressAll(MemoryReader(z), out);
    return Uint8List.fromList(out.bytes);
  } finally {
    Predictor.kernelsEnabled = true;
    Zpaql.nativeEnabled = true;
  }
}

/// Data with the given record length (level 5 adds periodic models for it)
/// or text like, or random.
Uint8List _sample(Random r, int n, int kind) {
  final b = Uint8List(n);
  for (var i = 0; i < n; ++i) {
    switch (kind) {
      case 0:
        b[i] = r.nextInt(256);
      case 1:
        b[i] = 97 + r.nextInt(20) + (i % 7 == 0 ? -65 : 0);
      default:
        // records of `kind` bytes with slowly changing fields
        final f = i % kind;
        b[i] = f < 4 ? (i ~/ kind) >> (8 * f) : (f * 13 + r.nextInt(3));
    }
  }
  return b;
}

void main() {
  test('generated code matches the generic code, both directions', () {
    final r = Random(99);
    const methods = [
      '3',
      '4',
      '5',
      '3,200,1',
      '4,200,1',
      '5,200,1',
      '3,200,0',
      '3,30,0',
      '4,30,0',
      '5,200,2',
      '4,200,2',
      'x4,3ci1',
    ];
    const kinds = [0, 1, 12, 100, 256, 300];
    for (var round = 0; round < 24; ++round) {
      final kind = kinds[round % kinds.length];
      final data = _sample(r, 5000 + r.nextInt(60000), kind);
      final m = methods[r.nextInt(methods.length)];
      final generic = _compress(data, m, false);
      final generated = _compress(data, m, true);
      expect(generated, generic, reason: 'method $m kind $kind');
      expect(_decompress(generated, true), data, reason: 'decode $m $kind');
      expect(_decompress(generated, false), data, reason: 'generic decode');
    }
  });
}
