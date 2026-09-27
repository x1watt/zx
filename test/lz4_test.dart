// LZ4 block and frame decoder tests against the real lz4 tool (made at
// test time; skipped when lz4 is missing).

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/codec/lz4/lz4.dart';
import 'package:zx/src/io/streams.dart';
import 'package:zx/src/util/xxhash.dart';

import 'codec_test_util.dart';

Uint8List decodeFrames(Uint8List c, {int chunk = 1 << 16}) {
  final s = Lz4FrameDecoderStream(MemoryInStream(c));
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
  final lz4 = findTool('lz4');
  final skip = lz4 == null ? 'lz4 not installed' : false;
  late Directory tmp;
  setUpAll(() => tmp = tempDir('lz4'));
  tearDownAll(() => tmp.deleteSync(recursive: true));

  Uint8List compress(Uint8List data, List<String> opts) {
    final f = File('${tmp.path}/in.bin')..writeAsBytesSync(data);
    return runTool(lz4!, ['-c', '-f', ...opts, f.path]);
  }

  test('xxh32 known values', () {
    expect(xxh32(Uint8List(0)), 0x02CC5D05);
    expect(xxh32(Uint8List.fromList('a'.codeUnits)), 0x550D7456);
    expect(xxh32(Uint8List.fromList('abc'.codeUnits)), 0x32D153FF);
    final long =
        Uint8List.fromList('Nobody inspects the spammish repetition'.codeUnits);
    expect(xxh32(long), 0xE2293B2F);
    // streaming in odd pieces equals one shot
    final d = genData(1000, 3);
    final h = Xxh32();
    for (var i = 0; i < d.length; i += 7) {
      h.update(d, i, i + 7 < d.length ? i + 7 : d.length);
    }
    expect(h.digest, xxh32(d));
  });

  final text = genData(2500000, 11);
  final mixed = genData(600000, 12, randomPercent: 40);
  final rnd = randomData(200000, 13);

  group('frames', () {
    for (var level = 1; level <= 12; level++) {
      test('level $level', () {
        final c = compress(text, ['-$level']);
        expect(sameBytes(decodeFrames(c), text), isTrue);
      }, skip: skip);
    }
    final variants = <String, List<String>>{
      'linked -BD': ['-BD'],
      'linked -BD -B4 -9': ['-BD', '-B4', '-9'],
      'block checksum -BX': ['-BX', '-B5'],
      'no content checksum': ['--no-frame-crc'],
      'content size': ['--content-size'],
      'B4 independent': ['-B4'],
      'B7': ['-B7'],
      'BD BX content size B4': ['-BD', '-BX', '--content-size', '-B4', '-12'],
    };
    for (final e in variants.entries) {
      test(e.key, () {
        for (final d in [text, mixed, rnd, Uint8List(0), Uint8List(1)]) {
          final c = compress(d, e.value);
          expect(sameBytes(decodeFrames(c, chunk: 1000), d), isTrue);
        }
      }, skip: skip);
    }
    test('legacy -l', () {
      for (final d in [text, mixed, rnd, Uint8List(3)]) {
        for (final lv in ['-1', '-9']) {
          final c = compress(d, ['-l', lv]);
          expect(sameBytes(decodeFrames(c), d), isTrue);
          // with the kernel's appended 4 byte size
          final k = Uint8List(c.length + 4)..setRange(0, c.length, c);
          k.buffer.asByteData().setUint32(c.length, d.length, Endian.little);
          expect(sameBytes(decodeFrames(k), d), isTrue);
        }
      }
    }, skip: skip);
    test('legacy with more than 8 MiB (several legacy blocks)', () {
      final big = Uint8List(9 << 20);
      for (var i = 0; i < big.length; i += 4096) {
        big.setRange(i, i + 4096, text, i % 1000000);
      }
      final c = compress(big, ['-l']);
      expect(sameBytes(decodeFrames(c), big), isTrue);
    }, skip: skip);
    test('concatenated and skippable frames', () {
      final a = compress(mixed, ['-BD']);
      final b = compress(text, ['-l']);
      final c = compress(rnd, ['-BX']);
      final skipFrame = Uint8List(8 + 5);
      skipFrame.buffer.asByteData()
        ..setUint32(0, 0x184D2A53, Endian.little)
        ..setUint32(4, 5, Endian.little);
      final all = (BytesBuilder()
            ..add(skipFrame)
            ..add(a)
            ..add(skipFrame)
            ..add(c)
            ..add(b))
          .toBytes();
      final want = (BytesBuilder()
            ..add(mixed)
            ..add(rnd)
            ..add(text))
          .toBytes();
      expect(sameBytes(decodeFrames(all), want), isTrue);
    }, skip: skip);
  });

  test('raw blocks from legacy frames', () {
    final c = compress(mixed, ['-l', '-12']);
    final size = c.buffer.asByteData().getUint32(4, Endian.little);
    final block = Uint8List.sublistView(c, 8, 8 + size);
    expect(sameBytes(lz4BlockDecompress(block, outSize: mixed.length), mixed),
        isTrue);
    final dst = Uint8List(mixed.length + 10);
    final src = Uint8List(size + 3)..setRange(3, 3 + size, block);
    expect(lz4BlockDecompressInto(src, 3, size, dst, 10, mixed.length),
        mixed.length);
    expect(() => lz4BlockDecompress(block, outSize: mixed.length - 1),
        throwsA(isA<SevenZipException>()));
  }, skip: skip);

  test('corrupt and truncated input throws', () {
    for (final opts in [
      ['-BD', '-BX'],
      ['-l'],
      ['--no-frame-crc'],
    ]) {
      final c = compress(genData(300000, 5), opts);
      for (var cut = 0; cut < c.length; cut += 1 + c.length ~/ 40) {
        expect(() => decodeFrames(Uint8List.sublistView(c, 0, cut)),
            cut == 0 ? returnsNormally : throwsA(isA<SevenZipException>()));
      }
      var st = 7;
      var detected = 0;
      for (var k = 0; k < 200; k++) {
        final m = Uint8List.fromList(c);
        st = (st * 1103515245 + 12345) & 0x7fffffff;
        m[st % m.length] ^= 1 << (st >> 20 & 7);
        try {
          decodeFrames(m);
        } on SevenZipException {
          detected++;
        }
      }
      if (opts.contains('-BX')) expect(detected, 200);
    }
    // bad block data
    for (final b in [
      [0x00], // no literals, missing offset
      [0x10, 0x41, 0x00, 0x00], // offset 0
      [0x10, 0x41, 0x02, 0x00], // offset beyond the start
      [0xF0], // truncated literal length
      [0x1F, 0x41, 0x01, 0x00, 0xFF], // truncated match length
    ]) {
      expect(() => lz4BlockDecompress(Uint8List.fromList(b), outSize: 100),
          b[0] == 0 ? returnsNormally : throwsA(isA<SevenZipException>()));
    }
  }, skip: skip);
}
