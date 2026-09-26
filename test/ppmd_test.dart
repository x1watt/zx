import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/codec/codec.dart';
import 'package:zx/src/codec/ppmd/ppmd7.dart';
import 'package:zx/src/codec/ppmd/ppmd7_enc.dart';
import 'package:zx/src/codec/ppmd/ppmd_coder.dart';
import 'package:zx/src/io/streams.dart';
import 'package:zx/src/util/crc.dart';

// Deterministic inputs, the same as the generator used to get the reference
// results from the C code (C/Ppmd7.c + C/Ppmd7Enc.c built with gcc).
Iterable<int> _lcg(int seed) sync* {
  var x = seed;
  for (;;) {
    x = (x * 1103515245 + 12345) & 0x7FFFFFFF;
    yield x;
  }
}

const _words = [
  'the ', 'quick ', 'brown ', 'fox ', 'jumps ', 'over ', 'lazy ', 'dog ', //
  '\n', 'PPMd ', 'model ', '7-Zip ',
];

Uint8List _text(int n, [int seed = 1]) {
  final b = BytesBuilder();
  final g = _lcg(seed).iterator;
  while (b.length < n) {
    g.moveNext();
    b.add(_words[(g.current >> 16) % 12].codeUnits);
  }
  return Uint8List.sublistView(b.takeBytes(), 0, n);
}

Uint8List _random(int n, [int seed = 7]) {
  final out = Uint8List(n);
  final g = _lcg(seed).iterator;
  for (var i = 0; i < n; i++) {
    g.moveNext();
    out[i] = (g.current >> 16) & 0xFF;
  }
  return out;
}

Uint8List _input(String name) => switch (name) {
      'text' => _text(100000),
      'random' => _random(50000),
      'zeros' => Uint8List(30000),
      _ => throw ArgumentError(name),
    };

// Encodes with the C level API (any order and memory size).
Uint8List _encodeRaw(Uint8List data, int order, int mem) {
  final out = MemoryOutStream();
  final p = Ppmd7()..alloc(mem);
  final bo = PpmdByteOut(out);
  p.rcOut = bo;
  ppmd7zInitRangeEnc(p);
  p.init(order);
  ppmd7zEncodeSymbols(p, data, 0, data.length);
  ppmd7zFlushRangeEnc(p);
  bo.flushBuf();
  return Uint8List.fromList(out.toBytes());
}

Uint8List _props(int order, int mem) {
  final b = Uint8List(5);
  b[0] = order;
  setUint32LE(b, 1, mem);
  return b;
}

Uint8List _decode(Uint8List packed, int order, int mem, int? size) =>
    readAll(ppmdDecoder(_props(order, mem), [MemoryInStream(packed)], size,
        const CoderContext()));

void main() {
  group('byte identity with the C encoder', () {
    // (input, order, mem, packed size, packed CRC-32) from the C code.
    const cases = [
      ('text', 6, 1048576, 9680, 0x5CA1222F),
      ('text', 2, 65536, 9501, 0x25B8A845),
      ('text', 32, 65536, 15469, 0x95A1BF3C),
      ('random', 16, 65536, 51785, 0x3BD04815),
      ('zeros', 32, 65536, 17, 0xC9EFF1BD),
      ('text', 64, 2051, 77075, 0x3A6188E5),
      ('random', 64, 3000, 53490, 0xE282BB82),
      ('text', 12, 2048, 77171, 0x1DA900EF),
    ];
    for (final (name, order, mem, size, crc) in cases) {
      test('$name o=$order mem=$mem', () {
        final data = _input(name);
        final packed = _encodeRaw(data, order, mem);
        expect(packed.length, size);
        expect(Crc32.of(packed), crc);
        expect(_decode(packed, order, mem, data.length), data);
        if (order <= 32 && mem >= 1 << 16) {
          final c = PpmdCompressor(order: order, memSize: mem);
          final out = MemoryOutStream();
          expect(c.encode(MemoryInStream(data), out), data.length);
          expect(out.toBytes(), packed);
        }
      });
    }
  });

  test('round trips', () {
    final inputs = [
      Uint8List(0),
      Uint8List.fromList([42]),
      Uint8List.fromList('abracadabra'.codeUnits),
      _text(20000, 3),
      _random(5000, 9),
    ];
    for (final data in inputs) {
      for (final order in [2, 3, 6, 16, 32]) {
        final c = PpmdCompressor(order: order, memSize: 1 << 16);
        final out = MemoryOutStream();
        c.encode(MemoryInStream(data), out);
        final packed = Uint8List.fromList(out.toBytes());
        expect(_decode(packed, order, 1 << 16, data.length), data);
      }
    }
  });

  test('empty input packs to 5 zero bytes', () {
    final out = MemoryOutStream();
    PpmdCompressor().encode(MemoryInStream(Uint8List(0)), out);
    expect(out.toBytes(), [0, 0, 0, 0, 0]);
  });

  group('properties', () {
    test('defaults (CEncProps::Normalize)', () {
      final c = PpmdCompressor();
      expect(c.order, 6);
      expect(c.memSize, 1 << 24);
      expect(c.props, [6, 0, 0, 0, 1]);
      expect(PpmdCompressor(level: 9).order, 32);
      expect(PpmdCompressor(level: 9).memSize, 1 << 28);
      expect(PpmdCompressor(level: 0).order, 3);
      expect(PpmdCompressor(level: 0).memSize, 1 << 19);
      // reduceSize shrinks the model.
      expect(PpmdCompressor(reduceSize: 300000).memSize, 1 << 23);
      expect(PpmdCompressor(level: 9, reduceSize: 100).memSize, 1 << 16);
    });

    test('method strings', () {
      var c = PpmdCompressor.parse('o=8:mem=24', reduceSize: 300000);
      expect((c.order, c.memSize), (8, 1 << 23));
      c = PpmdCompressor.parse('o=8:mem=24');
      expect((c.order, c.memSize), (8, 1 << 24));
      c = PpmdCompressor.parse('mem=16m:o32');
      expect((c.order, c.memSize), (32, 16 << 20));
      c = PpmdCompressor.parse('MEM=64k');
      expect(c.memSize, 64 << 10);
      c = PpmdCompressor.parse('mem=65540b');
      expect(c.memSize, 65540);
      c = PpmdCompressor.parse('x9');
      expect((c.order, c.memSize), (32, 1 << 28));
      c = PpmdCompressor.parse('', level: 1);
      expect((c.order, c.memSize), (4, 1 << 20));
      c = PpmdCompressor.parse('mt=4:mem=4g');
      expect(c.memSize, 0x100000000 - 1024);
      for (final bad in [
        'o=1', 'o=33', 'o=', 'mem=100', 'mem=65537b', 'mem=1k', 'd=20',
        'foo=1', 'o=x', 'mem=5g', //
      ]) {
        expect(() => PpmdCompressor.parse(bad),
            throwsA(isA<SevenZipException>()),
            reason: bad);
      }
    });

    test('decoder rejects bad properties', () {
      for (final p in [
        Uint8List(4),
        _props(1, 1 << 20),
        _props(65, 1 << 20),
        _props(6, 2047),
      ]) {
        expect(
            () => ppmdDecoder(
                p, [MemoryInStream(Uint8List(5))], 0, const CoderContext()),
            throwsA(isA<SevenZipException>().having(
                (e) => e.kind, 'kind', SevenZipError.unsupportedMethod)));
      }
    });

    test('registry', () {
      final reg = <int, DecoderFactory>{};
      registerPpmdCodecs(reg);
      expect(reg[MethodId.ppmd], isNotNull);
    });
  });

  group('decoder errors', () {
    final data = _text(20000, 5);
    final packed = _encodeRaw(data, 6, 1 << 20);

    test('truncated input', () {
      final cut = Uint8List.sublistView(packed, 0, packed.length - 10);
      expect(() => _decode(cut, 6, 1 << 20, data.length),
          throwsA(isA<SevenZipException>()));
    });

    test('bad first byte', () {
      final bad = Uint8List.fromList(packed)..[0] = 1;
      expect(() => _decode(bad, 6, 1 << 20, data.length),
          throwsA(isA<SevenZipException>()));
    });

    test('size larger than the data', () {
      expect(() => _decode(packed, 6, 1 << 20, data.length + 100),
          throwsA(isA<SevenZipException>()));
    });

    test('corrupt data', () {
      final bad = Uint8List.fromList(packed);
      bad[packed.length ~/ 2] ^= 0x55;
      Uint8List? out;
      try {
        out = _decode(bad, 6, 1 << 20, data.length);
      } on SevenZipException {
        return;
      }
      expect(out, isNot(equals(data)));
    });

    test('partial output before an error', () {
      final cut = Uint8List.sublistView(packed, 0, packed.length ~/ 2);
      final dec = ppmdDecoder(_props(6, 1 << 20), [MemoryInStream(cut)],
          data.length, const CoderContext());
      final buf = Uint8List(data.length);
      final n = dec.read(buf, 0, buf.length);
      expect(n, greaterThan(0));
      expect(buf.sublist(0, n), data.sublist(0, n));
      expect(() => dec.read(buf, 0, buf.length),
          throwsA(isA<SevenZipException>()));
    });
  });

  // Interop with the system 7z: its packed stream must decode, and our
  // encoder must produce the same bytes. For one non-solid file without
  // filters the pack stream starts right after the 32-byte signature header.
  final has7z = File('/usr/bin/7z').existsSync();
  group('7z interop', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('zx_ppmd_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    for (final (params, name) in [
      ('o=8:mem=24', 'text'),
      ('o=2:mem=64k', 'random'),
      ('o=32:mem=1m', 'text'),
    ]) {
      test('7z a -m0=PPMd:$params ($name)', () {
        final data = _input(name);
        final f = File('${tmp.path}/$name.bin')..writeAsBytesSync(data);
        final arc = '${tmp.path}/x.7z';
        final r = Process.runSync(
            '/usr/bin/7z', ['a', '-m0=PPMd:$params', arc, f.path]);
        expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
        final l = Process.runSync('/usr/bin/7z', ['l', '-slt', arc]);
        final packedSize = int.parse(RegExp(r'^Packed Size = (\d+)$',
                multiLine: true)
            .firstMatch(l.stdout as String)!
            .group(1)!);
        final bytes = File(arc).readAsBytesSync();
        final pack = Uint8List.sublistView(bytes, 32, 32 + packedSize);

        final c = PpmdCompressor.parse(params, reduceSize: data.length);
        expect(_decode(pack, c.order, c.memSize, data.length), data);
        final out = MemoryOutStream();
        c.encode(MemoryInStream(data), out);
        expect(out.toBytes(), pack);
      });
    }
  }, skip: has7z ? false : 'no /usr/bin/7z');
}
