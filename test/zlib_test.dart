// zlib wrapper (RFC 1950) and Adler-32 tests; vectors made by python3's
// zlib module at test time (skipped when python3 is missing).

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/codec/deflate/zlib.dart';
import 'package:zx/src/io/streams.dart';
import 'package:zx/src/util/adler32.dart';

import 'codec_test_util.dart';

void main() {
  final python = findTool('python3');
  final skip = python == null ? 'python3 not installed' : false;
  late Directory tmp;
  setUpAll(() => tmp = tempDir('zlib'));
  tearDownAll(() => tmp.deleteSync(recursive: true));

  // python3 zlib.compressobj(level, DEFLATED, wbits[, zdict]) over [data]
  Uint8List pyCompress(Uint8List data, int level, int wbits,
      {bool dict = false}) {
    final f = File('${tmp.path}/in.bin')..writeAsBytesSync(data);
    final zd = dict ? ", zdict=b'firmware rootfs kernel'" : '';
    return runTool(python!, [
      '-c',
      'import sys, zlib\n'
          'd = open(sys.argv[1], "rb").read()\n'
          'c = zlib.compressobj($level, zlib.DEFLATED, $wbits$zd)\n'
          'sys.stdout.buffer.write(c.compress(d) + c.flush())',
      f.path,
    ]);
  }

  test('adler32', () {
    expect(adler32(1, Uint8List(0)), 1);
    expect(adler32(1, Uint8List.fromList('Wikipedia'.codeUnits)), 0x11E60398);
    final big = Uint8List(100000)..fillRange(0, 100000, 0xFF);
    // running value in pieces equals one shot
    var a = 1;
    for (var i = 0; i < big.length; i += 9999) {
      a = adler32(a, big, i, i + 9999 < big.length ? i + 9999 : big.length);
    }
    expect(a, adler32(1, big));
  });

  test('adler32 against python zlib', () {
    final d = genData(300000, 3);
    final f = File('${tmp.path}/a.bin')..writeAsBytesSync(d);
    final r = Process.runSync(python!, [
      '-c',
      'import sys, zlib; print(zlib.adler32(open(sys.argv[1], "rb").read()))',
      f.path
    ]);
    expect(adler32(1, d), int.parse((r.stdout as String).trim()));
  }, skip: skip);

  test('levels and window sizes', () {
    final inputs = [
      genData(700000, 1),
      randomData(100000, 2),
      Uint8List(0),
      Uint8List(300000),
    ];
    for (final d in inputs) {
      for (final level in [0, 1, 6, 9]) {
        for (final wbits in [9, 12, 15]) {
          final c = pyCompress(d, level, wbits);
          expect(sameBytes(zlibInflateBytes(c), d), isTrue);
          final s = zlibDecoderStream(MemoryInStream(c));
          expect(sameBytes(readAll(s), d), isTrue);
        }
      }
    }
  }, skip: skip);

  test('stream leaves the bytes after the trailer', () {
    final d = genData(50000, 7);
    final c = pyCompress(d, 6, 15);
    final m = MemoryInStream(Uint8List.fromList([...c, 1, 2, 3]));
    final s = ZlibDecoderStream(m);
    expect(sameBytes(readAll(s), d), isTrue);
    expect(s.isFinished, isTrue);
  }, skip: skip);

  test('errors', () {
    final d = genData(100000, 8);
    final c = pyCompress(d, 6, 15);
    // bad Adler-32
    final bad = Uint8List.fromList(c)..[c.length - 1] ^= 1;
    expect(
        () => zlibInflateBytes(bad),
        throwsA(isA<SevenZipException>()
            .having((e) => e.kind, 'kind', SevenZipError.crc)));
    // bad header check and method
    expect(() => zlibInflateBytes(Uint8List.fromList([0x78, 0x9D, 3, 0])),
        throwsA(isA<SevenZipException>()));
    expect(() => zlibInflateBytes(Uint8List.fromList([0x77, 0x9C - 0, 3, 0])),
        throwsA(isA<SevenZipException>()));
    // preset dictionary
    final fd = pyCompress(d, 6, 15, dict: true);
    expect(fd[1] & 0x20, 0x20);
    expect(
        () => zlibInflateBytes(fd),
        throwsA(isA<SevenZipException>()
            .having((e) => e.kind, 'kind', SevenZipError.unsupportedMethod)));
    // truncation anywhere
    for (var cut = 0; cut < c.length; cut += 1 + c.length ~/ 50) {
      expect(() => zlibInflateBytes(Uint8List.sublistView(c, 0, cut)),
          throwsA(isA<SevenZipException>()));
    }
    for (var cut = c.length - 4; cut < c.length; cut++) {
      expect(() => zlibInflateBytes(Uint8List.sublistView(c, 0, cut)),
          throwsA(isA<SevenZipException>()));
    }
  }, skip: skip);
}
