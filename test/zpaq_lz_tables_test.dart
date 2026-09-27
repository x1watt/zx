// Vendored from zpaq-flutter by tool/sync_zpaq.sh: do not edit here, change
// zpaq-flutter and sync again. Pure Dart port of libzpaq and zpaq 7.15 (Matt
// Mahoney, public domain) with the zpaqfranz attribute format (Franco
// Corbelli, MIT). Copyright (c) 2026 Max Brito, BSD 3-clause; see LICENSE
// for the license and the third party notices.

// A hash table reused from block to block (LzHashTables) must give the same
// output as a fresh one, after small blocks (only the written entries are
// cleared) and big ones (all of it is cleared on the next use).
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/zpaq/core/io.dart';
import 'package:zx/src/zpaq/core/lzbuffer.dart';
import 'package:zx/src/zpaq/core/method.dart';

Uint8List _block(Random r, int n) {
  final b = Uint8List(n);
  for (var i = 0; i < n; ++i) {
    b[i] = i > 64 && r.nextInt(3) > 0
        ? b[i - 1 - r.nextInt(64)]
        : 97 + r.nextInt(8);
  }
  return b;
}

Uint8List _compress(Uint8List data, String method, [LzHashTables? t]) {
  final out = ZBuffer();
  compressBlock(ZBuffer.of(Uint8List.fromList(data)), out, method, tables: t);
  return Uint8List.fromList(out.bytes);
}

void main() {
  test('reused hash tables give the output of fresh ones', () {
    final r = Random(3);
    final tables = LzHashTables();
    const methods = ['1', '2', 'x4,1,4,0,3,24', 'x4,2,4,0,3,22', '3', '0'];
    for (var round = 0; round < 40; ++round) {
      // mostly small blocks, sometimes one over a sixteenth of the table
      final n = round % 9 == 8 ? 1500000 : 1 + r.nextInt(40000);
      final data = _block(r, n);
      final m = methods[r.nextInt(methods.length)];
      expect(_compress(data, m, tables), _compress(data, m),
          reason: 'round $round method $m size $n');
      expect(tables.consistent, isTrue, reason: 'round $round clean table');
    }
  });
}
