// zstd decoder tests against the real zstd tool (made at test time;
// skipped when zstd is missing).

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/codec/zstd/zstd.dart';
import 'package:zx/src/io/streams.dart';
import 'package:zx/src/util/xxhash.dart';

import 'codec_test_util.dart';

Uint8List streamDecode(Uint8List c, {int chunk = 1 << 16, int? maxWindow}) {
  final s = maxWindow == null
      ? ZstdDecoderStream(MemoryInStream(c))
      : ZstdDecoderStream(MemoryInStream(c), maxWindowSize: maxWindow);
  final out = BytesBuilder(copy: false);
  final buf = Uint8List(chunk);
  for (;;) {
    final n = s.read(buf, 0, chunk);
    if (n == 0) break;
    out.add(Uint8List.fromList(Uint8List.sublistView(buf, 0, n)));
  }
  return out.toBytes();
}

void main() {
  final zstd = findTool('zstd');
  final skip = zstd == null ? 'zstd not installed' : false;
  late Directory tmp;
  setUpAll(() => tmp = tempDir('zstd'));
  tearDownAll(() => tmp.deleteSync(recursive: true));

  // compresses [data] with zstd [opts]; [pipe] hides the size (no frame
  // content size, window from the level)
  Uint8List compress(Uint8List data, List<String> opts, {bool pipe = false}) {
    final f = File('${tmp.path}/in.bin')..writeAsBytesSync(data);
    if (pipe) {
      return runTool('sh', [
        '-c',
        '"\$0" -q -c ${opts.join(' ')} < "\$1"',
        zstd!,
        f.path,
      ]);
    }
    return runTool(zstd!, ['-q', '-c', ...opts, f.path]);
  }

  void check(Uint8List c, Uint8List want) {
    expect(sameBytes(zstdDecompress(c), want), isTrue, reason: 'one shot');
    expect(sameBytes(streamDecode(c, chunk: 777), want), isTrue,
        reason: 'stream');
  }

  test('xxh64 known values', () {
    expect(xxh64(Uint8List(0)), 0xEF46DB3751D8E999);
    expect(xxh64(Uint8List.fromList('a'.codeUnits)), 0xD24EC4F1A98C6E5B);
    expect(xxh64(Uint8List.fromList('abc'.codeUnits)), 0x44BC2CF5AD770999);
    final d = genData(5000, 3);
    final h = Xxh64();
    for (var i = 0; i < d.length; i += 13) {
      h.update(d, i, i + 13 < d.length ? i + 13 : d.length);
    }
    expect(h.digest, xxh64(d));
  });

  final text = genData(1200000, 21);
  final mixed = genData(500000, 22, randomPercent: 40);
  final rnd = randomData(300000, 23);
  final zeros = Uint8List(700000);

  group('levels', () {
    for (var level = 1; level <= 19; level++) {
      test('level $level', () {
        check(compress(text, ['-$level']), text);
        check(compress(mixed, ['-$level']), mixed);
      }, skip: skip);
    }
    test('--ultra -22', () {
      check(compress(text, ['--ultra', '-22']), text);
    }, skip: skip);
    test('negative levels (--fast)', () {
      check(compress(text, ['--fast=5']), text);
      check(compress(mixed, ['--fast=1']), mixed);
    }, skip: skip);
  });

  group('block and frame kinds', () {
    test('inputs that reach every literal and sequence mode', () {
      // real text (4-stream Huffman, treeless literals, repeat mode),
      // 3 byte tokens (more than 0x7F00 sequences in a block), a small
      // skewed alphabet (directly stored Huffman weights), skewed bytes
      // without matches (blocks without sequences)
      final src = BytesBuilder();
      for (final f in Directory('lib/src').listSync(recursive: true)) {
        if (f is File && f.path.endsWith('.dart') && src.length < 3000000) {
          src.add(f.readAsBytesSync());
        }
      }
      var st = 12345;
      int next() {
        st = (st * 1103515245 + 12345) & 0x7fffffff;
        return st >> 8;
      }

      final toks = [for (var i = 0; i < 900; i++) next() & 0xFFFFFF];
      final tok3 = Uint8List(400002);
      for (var i = 0; i < 400000; i += 3) {
        final t = toks[next() % toks.length];
        tok3[i] = t;
        tok3[i + 1] = t >> 8;
        tok3[i + 2] = t >> 16;
      }
      final small = Uint8List(200000);
      for (var i = 0; i < small.length; i++) {
        var v = 0;
        while (v < 15 && next() % 3 != 0) {
          v++;
        }
        small[i] = v;
      }
      final skew = Uint8List(300000);
      for (var i = 0; i < skew.length; i++) {
        final a = next() & 0xFF, b = next() & 0xFF, c = next() & 0xFF;
        skew[i] = a < b ? (a < c ? a : c) : (b < c ? b : c);
      }
      for (final d in [src.toBytes(), tok3, small, skew]) {
        for (final lv in ['-1', '-3', '-9', '-19', '--fast=5']) {
          check(compress(d, [lv]), d);
        }
      }
    }, skip: skip);
    test('hand made frame with RLE literals and no sequences', () {
      final f = Uint8List.fromList(
          [0x28, 0xB5, 0x2F, 0xFD, 0x20, 0x05, 0x1D, 0, 0, 0x29, 0x58, 0]);
      check(f, Uint8List.fromList('XXXXX'.codeUnits));
    });
    test('raw blocks (incompressible)', () {
      check(compress(rnd, ['-3']), rnd);
    }, skip: skip);
    test('RLE blocks (zeros)', () {
      check(compress(zeros, ['-3']), zeros);
      check(compress(zeros, ['-19']), zeros);
    }, skip: skip);
    test('small inputs (single stream literals, single segment)', () {
      for (final n in [0, 1, 2, 5, 17, 100, 500, 1000, 3000, 70000]) {
        final d = Uint8List.sublistView(text, 0, n);
        check(compress(d, ['-3']), d);
        check(compress(d, ['-19']), d);
      }
    }, skip: skip);
    test('checksum off and on', () {
      check(compress(text, ['--no-check']), text);
      check(compress(text, ['--check', '-9']), text);
    }, skip: skip);
    test('no content size (piped), levels 1 3 19', () {
      for (final lv in ['-1', '-3', '-19']) {
        check(compress(text, [lv], pipe: true), text);
        check(compress(mixed, [lv, '--no-check'], pipe: true), mixed);
      }
    }, skip: skip);
    test('--long matches beyond the default window', () {
      // a 3 MB block repeated at a distance of 3 MB
      final part = genData(3 << 20, 99, randomPercent: 60);
      final big = Uint8List(6 << 20)
        ..setRange(0, 3 << 20, part)
        ..setRange(3 << 20, 6 << 20, part);
      final c = compress(big, ['--long=24', '-3']);
      check(c, big);
      check(compress(big, ['--long=27', '-1'], pipe: true), big);
      // the window limit of the stream
      final c2 = compress(big, ['--long=24', '-1'], pipe: true);
      expect(() => streamDecode(c2, maxWindow: 1 << 20),
          throwsA(isA<SevenZipException>()));
    }, skip: skip);
    test('strategies', () {
      for (var s = 1; s <= 9; s++) {
        check(compress(mixed, ['--zstd=strategy=$s']), mixed);
      }
    }, skip: skip);
    test('multiple and skippable frames', () {
      final a = compress(text, ['-5']);
      final b = compress(rnd, ['-1', '--no-check']);
      final z = compress(zeros, ['-3'], pipe: true);
      final skipFrame = Uint8List(8 + 11);
      skipFrame.buffer.asByteData()
        ..setUint32(0, 0x184D2A5E, Endian.little)
        ..setUint32(4, 11, Endian.little);
      final all = (BytesBuilder()
            ..add(a)
            ..add(skipFrame)
            ..add(b)
            ..add(z)
            ..add(a))
          .toBytes();
      final want = (BytesBuilder()
            ..add(text)
            ..add(rnd)
            ..add(zeros)
            ..add(text))
          .toBytes();
      check(all, want);
    }, skip: skip);
    test('maxOutput', () {
      final c = compress(text, ['-3']);
      expect(zstdDecompress(c, maxOutput: text.length).length, text.length);
      expect(() => zstdDecompress(c, maxOutput: text.length - 1),
          throwsA(isA<SevenZipException>()));
      final p = compress(text, ['-3'], pipe: true);
      expect(() => zstdDecompress(p, maxOutput: 1000),
          throwsA(isA<SevenZipException>()));
    }, skip: skip);
  });

  test('corrupt and truncated input throws', () {
    for (final opts in [
      ['-3'],
      ['-19', '--no-check'],
    ]) {
      final d = genData(200000, 31, randomPercent: 20);
      final c = compress(d, opts);
      for (var cut = 0; cut < c.length; cut += 1 + c.length ~/ 60) {
        final t = Uint8List.sublistView(c, 0, cut);
        expect(() => zstdDecompress(t), throwsA(isA<SevenZipException>()));
        if (cut > 0) {
          expect(() => streamDecode(t), throwsA(isA<SevenZipException>()));
        }
      }
      var st = 5;
      for (var k = 0; k < 300; k++) {
        final m = Uint8List.fromList(c);
        st = (st * 1103515245 + 12345) & 0x7fffffff;
        m[st % m.length] ^= 1 << (st >> 20 & 7);
        try {
          final r = zstdDecompress(m);
          // an undetected flip must not change the output (the window
          // descriptor, for example)
          if (!opts.contains('--no-check')) expect(sameBytes(r, d), isTrue);
        } on SevenZipException {
          // expected
        }
        try {
          streamDecode(m);
        } on SevenZipException {
          // expected
        }
      }
    }
    expect(() => zstdDecompress(Uint8List.fromList([1, 2, 3, 4, 5])),
        throwsA(isA<SevenZipException>()));
  }, skip: skip);
}
