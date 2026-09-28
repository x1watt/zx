import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/codec/lz4/lz4.dart';
import 'package:zx/src/codec/lz4/lz4_encode.dart';
import 'package:zx/src/format/zx/zx_codecs.dart';
import 'package:zx/src/format/zx/zx_format.dart';
import 'package:zx/src/io/streams.dart';

Uint8List _text(int n, int seed) {
  final r = Random(seed);
  const words = ['alpha ', 'beta ', 'gamma ', 'delta\n', 'key=', 'value;'];
  final b = BytesBuilder();
  while (b.length < n) {
    b.add(words[r.nextInt(words.length)].codeUnits);
    if (r.nextInt(10) == 0) b.addByte(r.nextInt(256));
  }
  return Uint8List.sublistView(b.toBytes(), 0, n);
}

Uint8List _random(int n, int seed) {
  final r = Random(seed);
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

Uint8List _frameDecode(Uint8List f) {
  final s = Lz4FrameDecoderStream(MemoryInStream(f));
  return Uint8List.fromList(readAll(s));
}

void main() {
  final inputs = <String, Uint8List>{
    'empty': Uint8List(0),
    'one': Uint8List.fromList([7]),
    'short': Uint8List.fromList('abcabcabcabc'.codeUnits),
    'zeros': Uint8List(100000),
    'text': _text(300000, 1),
    'random': _random(70000, 2),
    'mixed': Uint8List.fromList([..._text(50000, 3), ..._random(5000, 4), ..._text(50000, 3)]),
    'big text': _text(5 << 20, 5),
  };
  for (final e in inputs.entries) {
    test('block and frame round trip: ${e.key}', () {
      for (final depth in [1, 4, 16]) {
        final blk = lz4CompressBlockBytes(e.value, depth: depth);
        expect(lz4BlockDecompress(blk, outSize: e.value.length), e.value);
        final fr = lz4CompressFrame(e.value, depth: depth);
        expect(_frameDecode(fr), e.value);
      }
    });
  }

  test('compresses text and zeros', () {
    expect(lz4CompressFrame(Uint8List(100000)).length, lessThan(1000));
    expect(lz4CompressFrame(_text(300000, 1)).length, lessThan(150000));
    // incompressible data is stored with little overhead
    expect(lz4CompressFrame(_random(70000, 2)).length, lessThan(70000 + 40));
  });

  test('zx codec registry writes and reads LZ4', () {
    final data = _text(200000, 9);
    final c = zxParseCoder('LZ4', 5);
    final (p, cs) = zxEncodeChain(Uint8List.fromList(data), [c]);
    expect(p.length, lessThan(data.length));
    expect(zxDecodeChain(p, ZxChain(2, cs), data.length), data);
  });

  final lz4 = Process.runSync('sh', ['-c', 'command -v lz4']).exitCode == 0;
  test('the lz4 tool decodes our frames', () {
    final dir = Directory.systemTemp.createTempSync('lz4enc');
    try {
      final data = _text(1 << 20, 11);
      File('${dir.path}/a.lz4').writeAsBytesSync(lz4CompressFrame(data));
      final r = Process.runSync('lz4', ['-d', '-f', '${dir.path}/a.lz4', '${dir.path}/a']);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      expect(File('${dir.path}/a').readAsBytesSync(), data);
    } finally {
      dir.deleteSync(recursive: true);
    }
  }, skip: lz4 ? false : 'lz4 not installed');
}
