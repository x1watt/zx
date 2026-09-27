import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/codec/codec.dart';
import 'package:zx/src/codec/deflate/deflate_coder.dart';
import 'package:zx/src/codec/deflate/zutil.dart';
import 'package:zx/src/common/method_props.dart';
import 'package:zx/src/io/streams.dart';
import 'package:zx/src/util/crc.dart';

/// Deterministic test data: runs, words and noise.
Uint8List gen(int n, int seed) {
  var st = seed;
  int next() {
    st = (st * 1103515245 + 12345) & 0x7fffffff;
    return st >> 16;
  }

  const words = [
    'deflate ', 'inflate ', 'zlib ', 'window ', 'match ', 'huffman\n', //
    'the ', 'of '
  ];
  final out = BytesBuilder();
  while (out.length < n) {
    final r = next();
    switch (r % 10) {
      case 0:
        out.add(List.filled(next() % 300, r & 0xff));
      case 1:
      case 2:
      case 3:
      case 4:
        out.add(words[next() % words.length].codeUnits);
      default:
        out.addByte(next() & 0xff);
    }
  }
  return Uint8List.sublistView(out.toBytes(), 0, n);
}

Uint8List compress(Uint8List data, int level,
    {int strategy = ZStrategy.defaultStrategy}) {
  final out = MemoryOutStream();
  DeflateCompressor(level: level, strategy: strategy)
      .encode(MemoryInStream(data), out);
  return Uint8List.fromList(out.toBytes());
}

/// Length and CRC-32 of the raw deflate output of zlib 1.3.1 for gen(n,
/// seed), driven as DeflateCompressor drives it (64 KiB input chunks with
/// Z_NO_FLUSH then Z_FINISH, 64 KiB output buffer): [level, strategy,
/// length, crc]. Made with a C harness built from ref/zlib-1.3.1.
const Map<(int, int), List<List<int>>> zlibReference = {
  (150000, 7): [
    [0, 0, 150015, 0xb839748c], [1, 0, 14073, 0xb5191579], //
    [2, 0, 13929, 0xc18ba430], [3, 0, 13552, 0x6abd2ed2],
    [4, 0, 13310, 0xe36151ff], [5, 0, 13102, 0x78ead4ef],
    [6, 0, 12774, 0x3eb47217], [7, 0, 12724, 0xb01f8384],
    [8, 0, 12418, 0x42dbc95a], [9, 0, 12261, 0x6276077e],
    [1, 1, 14073, 0xb5191579], [6, 1, 13214, 0xd5609c12],
    [9, 1, 12699, 0xc88c1c7f], [1, 2, 115026, 0x270a7026],
    [6, 2, 115026, 0x270a7026], [9, 2, 115026, 0x270a7026],
    [1, 3, 18891, 0x75f03ff5], [6, 3, 18891, 0x75f03ff5],
    [9, 3, 18891, 0x75f03ff5], [1, 4, 15089, 0x06ab7d12],
    [6, 4, 13482, 0xf4549a7f], [9, 4, 12893, 0x06b91496],
  ],
  (70000, 99): [
    [0, 0, 70010, 0x6788ec53], [1, 0, 6592, 0xd3ba1d36], //
    [2, 0, 6505, 0xb455172b], [3, 0, 6338, 0x0d1401cc],
    [4, 0, 6212, 0x95fc2142], [5, 0, 6136, 0x95a0380f],
    [6, 0, 6021, 0x2791c671], [7, 0, 5999, 0xf9e318fc],
    [8, 0, 5864, 0xb603ddfa], [9, 0, 5791, 0x0675c210],
    [1, 1, 6592, 0xd3ba1d36], [6, 1, 6252, 0x74eb5f5a],
    [9, 1, 6034, 0x48cb2982], [1, 2, 53038, 0x78b83f3a],
    [6, 2, 53038, 0x78b83f3a], [9, 2, 53038, 0x78b83f3a],
    [1, 3, 8723, 0xca34c0c1], [6, 3, 8723, 0xca34c0c1],
    [9, 3, 8723, 0xca34c0c1], [1, 4, 7002, 0x8a9a7ac2],
    [6, 4, 6306, 0x2fd9cdd2], [9, 4, 6043, 0xc9c4a87f],
  ],
};

/// zlib 1.3.1 one shot (whole input, deflateBound output, Z_FINISH) for
/// gen(150000, 7): [level, length, crc].
const List<List<int>> zlibOneShot = [
  [0, 150015, 0x4fe5c049],
  [1, 14073, 0xb5191579],
  [6, 12774, 0x3eb47217],
  [9, 12261, 0x6276077e],
];

/// A Deflate64 stream written by 7-Zip 23.01 (7z a -tzip -mm=Deflate64
/// -mx9) for 112300 bytes: 1000 bytes of gen(70000, 99), 40000 zeros, the
/// same 1000 bytes (distance > 32 KiB), 70000 zeros (matches longer than
/// 258) and 300 bytes. CRC-32 of the data: 0x95a338b2.
const String deflate64Vector =
    '5N4xDoJAEAVQa0/BpTwAATZLItBgoLS2srCi9xxGT+MlTEwATTzC+l4ymUw5xe9/PITQ5O32'
    'uRvqtuyGbF1lFfZ5X2Xxj9Tt8tPt9KMY0/Z564KYZK81n8cm74uY9bGaZ7nO98e1C8vxTfA4'
    '2/B4PB6Px+PxeDwej8fj8Xg8Ho/H4/F4PB6Px+PxeDwej8fj8Xg8Ho/H4/F4PB6Px+PxeDwe'
    'j8fj8Xg8Ho/H4/F4PB6Px+PxeDwej8fj8Xg8Ho/H4/F4PB6Px+PxeDwej8fj8Xg8Ho/H4/F4'
    'PB6Px+PxeDwej8fj8Xg8Ho/H4/F4PB6Px+PxeLwU8D0B+Z6AyZlkfE9AHo/H4/F4PB6Px+Px'
    'eDwej8fj8Xg8Ho/H4/F4PB6Px+PxeDwej8fj8Xg8Ho/H4/F4PB6Px+PxeDwej8fj8Xg83rv8'
    'ObYBCAgAKNqbwlIGEFxcwmnImcFS1jGGgkanFO81v/48Ho/H4/F4PB6Px+PxeDwej8fj8Xg8'
    'Ho/H4/F4PB6Px+PxeDwej8fj8Xg8Ho/H4/F4PB6Px+PxeDwej8fj8Xg8Ho/H4/F4PB6Px+Px'
    'eDwej8fj8Xg8Ho/H4/F4PB6Px+PxeDwej8fj8Xg8Ho/H4/F4PB6Px+PxeDwej8fj8Xg8Ho/H'
    '4/F4PB6Px+PxeDwej8fj8Xg8Ho/H4/F4PB6Px+PxeDwej8fj8Xg8Ho/H431Vv4Qw1qk4qhxT'
    'O+XyTtuFoZ67sv+RmK6nfXto1pdO';

bool _have(String exe, List<String> args) {
  try {
    return Process.runSync(exe, args).exitCode == 0;
  } on ProcessException {
    return false;
  }
}

void main() {
  group('deflate matches zlib 1.3.1', () {
    for (final e in zlibReference.entries) {
      final (n, seed) = e.key;
      final data = gen(n, seed);
      for (final row in e.value) {
        final [level, strategy, len, crc] = row;
        test('gen($n, $seed) level $level strategy $strategy', () {
          final z = compress(data, level, strategy: strategy);
          expect(z.length, len);
          expect(Crc32.of(z), crc);
          expect(inflateBytes(z), data);
        });
      }
    }
    final data = gen(150000, 7);
    for (final [level, len, crc] in zlibOneShot) {
      test('deflateBytes level $level', () {
        final z = deflateBytes(data, level: level);
        expect(z.length, len);
        expect(Crc32.of(z), crc);
        expect(inflateBytes(z), data);
      });
    }
  });

  test('round trip of small and edge sizes', () {
    final big = gen(140000, 3);
    for (final n in [0, 1, 2, 3, 4, 257, 258, 259, 32768, 65535, 65536,
        65537, 131072]) {
      final d = Uint8List.sublistView(big, 0, n);
      for (final level in [0, 1, 5, 9]) {
        expect(inflateBytes(compress(d, level)), d, reason: 'n=$n l=$level');
      }
    }
    final zeros = Uint8List(100000);
    expect(inflateBytes(compress(zeros, 9)), zeros);
  });

  test('fromCoderProps takes the level, ignores 7-Zip tuning', () {
    final c = DeflateCompressor.fromCoderProps([
      CoderProp(CoderPropId.level, const PropVariant.ui4(9)),
      CoderProp(CoderPropId.numFastBytes, const PropVariant.ui4(128)),
      CoderProp(CoderPropId.numPasses, const PropVariant.ui4(3)),
    ]);
    expect(c.level, 9);
    expect(c.props, isEmpty);
  });

  test('decoder stream: unusedInput and inProcessed after the end', () {
    final data = gen(50000, 5);
    final z = compress(data, 6);
    final tail = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
    final s = InflateDecoderStream(
        MemoryInStream(Uint8List.fromList([...z, ...tail])));
    expect(readAll(s), data);
    expect(s.isFinished, isTrue);
    expect(s.inProcessed, z.length);
    expect(s.unusedInput, tail);
  });

  test('decoder stream with outSize', () {
    final data = gen(30000, 6);
    final z = compress(data, 6);
    final s = deflateDecoder(Uint8List(0), [MemoryInStream(z)], data.length,
        const CoderContext());
    expect(readAll(s), data);
    final short = InflateDecoderStream(MemoryInStream(z), outSize: 1000);
    expect(readAll(short), Uint8List.sublistView(data, 0, 1000));
    final long = InflateDecoderStream(MemoryInStream(z), outSize: 40000);
    expect(
        () => readAll(long),
        throwsA(isA<SevenZipException>()
            .having((e) => e.kind, 'kind', SevenZipError.unexpectedEnd)));
  });

  test('truncated and corrupt data', () {
    final data = gen(60000, 8);
    final z = compress(data, 6);
    expect(
        () => inflateBytes(Uint8List.sublistView(z, 0, z.length - 10)),
        throwsA(isA<SevenZipException>()
            .having((e) => e.kind, 'kind', SevenZipError.unexpectedEnd)));
    expect(
        () => inflateBytes(Uint8List(0)),
        throwsA(isA<SevenZipException>()
            .having((e) => e.kind, 'kind', SevenZipError.unexpectedEnd)));
    // block type 3 is invalid
    expect(
        () => inflateBytes(Uint8List.fromList([0x07, 0x00])),
        throwsA(isA<SevenZipException>()
            .having((e) => e.kind, 'kind', SevenZipError.data)));
    // stored block with a wrong length complement
    expect(() => inflateBytes(Uint8List.fromList([1, 5, 0, 0, 0])),
        throwsA(isA<SevenZipException>()));
    // random corruption must not crash (an error or wrong data)
    var errors = 0;
    for (var i = 0; i < 40; i++) {
      final c = Uint8List.fromList(z);
      c[(i * 7919) % c.length] ^= 1 << (i & 7);
      try {
        final r = inflateBytes(c);
        if (r.length != data.length) errors++;
      } on SevenZipException {
        errors++;
      }
    }
    expect(errors, greaterThan(0));
  });

  test('Deflate64 stream from 7-Zip', () {
    final z = base64.decode(deflate64Vector);
    final d = inflate64Bytes(z);
    expect(d.length, 112300);
    expect(Crc32.of(d), 0x95a338b2);
    // the registered factory, with outSize, and the end of the stream
    final s = deflate64Decoder(Uint8List(0),
        [MemoryInStream(Uint8List.fromList([...z, 9, 9]))], 112300,
        const CoderContext()) as Deflate64DecoderStream;
    expect(Crc32.of(readAll(s)), 0x95a338b2);
    final s2 = Deflate64DecoderStream(
        MemoryInStream(Uint8List.fromList([...z, 9, 9])));
    readAll(s2);
    expect(s2.isFinished, isTrue);
    expect(s2.inProcessed, z.length);
    expect(s2.unusedInput, [9, 9]);
    expect(() => inflate64Bytes(Uint8List.sublistView(z, 0, z.length - 20)),
        throwsA(isA<SevenZipException>()));
    // the deflate64 data uses distance codes 30 and 31: not plain deflate
    expect(() => inflateBytes(z), throwsA(isA<SevenZipException>()));
  });

  test('Deflate64 compression: round trips, the 64 KiB window', () {
    // repeats 40000 bytes apart: out of reach of Deflate, not of Deflate64
    final far = Uint8List.fromList(
        [...gen(40000, 21), ...gen(40000, 21), ...gen(40000, 21)]);
    final inputs = [
      far,
      Uint8List(100000),
      gen(3, 1),
      Uint8List(0),
      gen(70000, 22),
    ];
    for (final d in inputs) {
      for (final level in [0, 1, 6, 9]) {
        final z = deflateBytes(d, level: level, deflate64: true);
        expect(inflate64Bytes(z), d, reason: 'level $level');
        // the streaming compressor
        final out = MemoryOutStream();
        final n = Deflate64Compressor(level: level)
            .encode(MemoryInStream(d), out);
        expect(n, d.length);
        expect(inflate64Bytes(out.toBytes()), d);
      }
    }
    final z64 = deflateBytes(far, level: 6, deflate64: true);
    final z32 = deflateBytes(far, level: 6);
    expect(z64.length, lessThan(z32.length ~/ 2));
    // distance codes 30 and 31 are used: plain inflate rejects the stream
    expect(() => inflateBytes(z64), throwsA(isA<SevenZipException>()));
    // matches are at most 257 bytes: zeros never need code 285 (16 bits)
    final zz = deflateBytes(Uint8List(100000), level: 9, deflate64: true);
    expect(zz.length, lessThan(600));
    final p = Deflate64Compressor.fromCoderProps(
        [CoderProp(CoderPropId.level, const PropVariant.ui4(9))]);
    expect(p.level, 9);
    expect(p.props, isEmpty);
  });

  test('registerDeflateCodecs', () {
    final reg = <int, DecoderFactory>{};
    registerDeflateCodecs(reg);
    expect(reg.keys, containsAll([MethodId.deflate, MethodId.deflate64]));
  });

  final have7z = File('/usr/bin/7z').existsSync();
  test('Deflate and Deflate64 in zip files made by 7z', () {
    final dir = Directory.systemTemp.createTempSync('zx_deflate');
    try {
      final data = Uint8List.fromList(
          [...gen(80000, 11), ...Uint8List(70000), ...gen(80000, 11)]);
      final f = File('${dir.path}/d.bin')..writeAsBytesSync(data);
      for (final m in ['Deflate', 'Deflate64']) {
        final zip = '${dir.path}/$m.zip';
        final r = Process.runSync(
            '/usr/bin/7z', ['a', '-tzip', '-mm=$m', '-mx9', zip, f.path]);
        expect(r.exitCode, 0);
        final z = File(zip).readAsBytesSync();
        // the first local header: method, packed size, name and extra
        expect(getUint32LE(z, 0), 0x04034b50);
        final method = z[8] | (z[9] << 8);
        final csize = getUint32LE(z, 18);
        final off = 30 + (z[26] | (z[27] << 8)) + (z[28] | (z[29] << 8));
        final raw = Uint8List.sublistView(z, off, off + csize);
        expect(method, m == 'Deflate' ? 8 : 9);
        expect(m == 'Deflate' ? inflateBytes(raw) : inflate64Bytes(raw), data);
      }
    } finally {
      dir.deleteSync(recursive: true);
    }
  }, skip: have7z ? false : '7z not found');

  final haveGzip = _have('gzip', ['--version']);
  test('deflate output inside a gzip wrapper is accepted by gzip', () {
    final data = gen(100000, 12);
    final z = compress(data, 9);
    final gz = BytesBuilder()
      ..add([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 2, 3])
      ..add(z);
    final t = Uint8List(8);
    setUint32LE(t, 0, Crc32.of(data));
    setUint32LE(t, 4, data.length);
    gz.add(t);
    final dir = Directory.systemTemp.createTempSync('zx_deflate');
    try {
      final f = File('${dir.path}/x.gz')..writeAsBytesSync(gz.toBytes());
      final r = Process.runSync('gzip', ['-dc', f.path], stdoutEncoding: null);
      expect(r.exitCode, 0);
      expect(r.stdout, data);
    } finally {
      dir.deleteSync(recursive: true);
    }
  }, skip: haveGzip ? false : 'gzip not found');
}
