import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/common/method_props.dart';
import 'package:zx/src/codec/ppmd8/ppmd8_coder.dart';
import 'package:zx/src/io/streams.dart';
import 'package:zx/src/util/crc.dart';

// Deterministic inputs, the same as the generator used to get the reference
// results from the C code (C/Ppmd8.c + C/Ppmd8Enc.c built with gcc, end
// marker and Ppmd8_Flush_RangeEnc after the data, as 7-Zip writes zip PPMd).
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

// Text with random runs of 512 bytes: fills a 1 MB model several times, so
// the restart and cut off restoration methods both run.
Uint8List _mixed(int n, [int seed = 3]) {
  final t = _text(n, seed);
  final r = _random(n, seed + 1);
  final out = Uint8List(n);
  for (var i = 0; i < n; i++) {
    out[i] = ((i >> 9) & 1) == 0 ? t[i] : r[i];
  }
  return out;
}

Uint8List _input(String name) => switch (name) {
      'text' => _text(20000),
      'random' => _random(5000),
      'mixed' => _mixed(300000),
      'one' => Uint8List.fromList([0x41]),
      'empty' => Uint8List(0),
      _ => throw ArgumentError(name),
    };

Uint8List _encode(Uint8List data, Ppmd8ZipCompressor c) {
  final out = MemoryOutStream();
  expect(c.encode(MemoryInStream(data), out), data.length);
  return Uint8List.fromList(out.toBytes());
}

Uint8List _decode(Uint8List packed, int? size) {
  final d = Ppmd8ZipDecoder(MemoryInStream(packed), outSize: size);
  final out = MemoryOutStream();
  final buf = Uint8List(4096);
  for (;;) {
    final n = d.read(buf, 0, buf.length);
    if (n == 0) break;
    out.write(buf, 0, n);
  }
  return Uint8List.fromList(out.toBytes());
}

String _hex(List<int> b) =>
    b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();

// A zip archive with one method 98 entry (APPNOTE 4.3.7, 4.3.12, 4.3.16).
Uint8List _zip(String name, Uint8List data, Uint8List packed) {
  final n = Uint8List.fromList(name.codeUnits);
  final crc = Crc32.of(data);
  final b = BytesBuilder();
  void u16(int v) => b.add([v & 0xFF, v >> 8]);
  void u32(int v) => b.add([v & 0xFF, v >> 8 & 0xFF, v >> 16 & 0xFF, v >> 24]);
  u32(0x04034B50);
  u16(63);
  u16(0);
  u16(98);
  u16(0);
  u16(0x21);
  u32(crc);
  u32(packed.length);
  u32(data.length);
  u16(n.length);
  u16(0);
  b.add(n);
  b.add(packed);
  final cdOff = b.length;
  u32(0x02014B50);
  u16(63);
  u16(63);
  u16(0);
  u16(98);
  u16(0);
  u16(0x21);
  u32(crc);
  u32(packed.length);
  u32(data.length);
  u16(n.length);
  u16(0);
  u16(0);
  u16(0);
  u16(0);
  u32(0);
  u32(0);
  b.add(n);
  final cdSize = b.length - cdOff;
  u32(0x06054B50);
  u16(0);
  u16(0);
  u16(1);
  u16(1);
  u32(cdSize);
  u32(cdOff);
  u16(0);
  return b.takeBytes();
}

// The packed data of the first local file entry of a zip archive.
Uint8List _firstEntryData(Uint8List zip) {
  final bd = ByteData.sublistView(zip);
  expect(bd.getUint32(0, Endian.little), 0x04034B50);
  expect(bd.getUint16(8, Endian.little), 98);
  final csize = bd.getUint32(18, Endian.little);
  final off =
      30 + bd.getUint16(26, Endian.little) + bd.getUint16(28, Endian.little);
  return Uint8List.sublistView(zip, off, off + csize);
}

// uudecode of the libarchive test fixtures.
Uint8List _uudecode(String text) {
  final out = BytesBuilder();
  var started = false;
  for (final line in text.split('\n')) {
    if (!started) {
      started = line.startsWith('begin ');
      continue;
    }
    if (line.trim() == 'end') break;
    if (line.isEmpty) continue;
    final n = (line.codeUnitAt(0) - 32) & 63;
    final c = line.codeUnits;
    int v(int i) => i < c.length ? (c[i] - 32) & 63 : 0;
    final bytes = <int>[];
    for (var i = 1; bytes.length < n; i += 4) {
      final w = (v(i) << 18) | (v(i + 1) << 12) | (v(i + 2) << 6) | v(i + 3);
      bytes.addAll([w >> 16, (w >> 8) & 0xFF, w & 0xFF]);
    }
    out.add(bytes.sublist(0, n));
  }
  return out.takeBytes();
}

void main() {
  group('byte identity with the C encoder', () {
    // (input, order, mem MB, restore, packed size, packed CRC-32).
    const cases = [
      ('text', 6, 1, 0, 2045, 0x1026941A),
      ('text', 16, 1, 1, 2160, 0xDF9BB7E4),
      ('text', 4, 1, 1, 2015, 0xA2E4F7CD),
      ('random', 8, 1, 0, 5205, 0xDF3532AE),
      ('mixed', 16, 1, 0, 171020, 0xB5FA9AFC),
      ('mixed', 16, 1, 1, 168375, 0x74E4BD9E),
      ('mixed', 6, 1, 1, 169468, 0xFF1E596E),
      ('mixed', 2, 1, 0, 169553, 0xE1EA11E0),
    ];
    for (final (name, order, mem, restore, size, crc) in cases) {
      test('$name o=$order mem=${mem}m r=$restore', () {
        final data = _input(name);
        final packed = _encode(
            data,
            Ppmd8ZipCompressor(
                order: order, memSize: mem << 20, restoreMethod: restore));
        expect(packed.length, size);
        expect(Crc32.of(packed), crc);
        expect(_decode(packed, data.length), data);
        expect(_decode(packed, null), data);
      });
    }

    test('one byte and empty input', () {
      final c = Ppmd8ZipCompressor(order: 2, memSize: 1 << 20);
      expect(_hex(_encode(_input('one'), c)), '010041bd473700');
      final e = Ppmd8ZipCompressor(order: 8, memSize: 1 << 20);
      expect(_hex(_encode(Uint8List(0), e)), '0700ff00ff0000');
      expect(_decode(Uint8List.fromList([7, 0, 0xFF, 0, 0xFF, 0, 0]), null),
          isEmpty);
    });
  });

  test('round trips', () {
    final inputs = [
      Uint8List.fromList('abracadabra'.codeUnits),
      _text(30000, 5),
      _random(3000, 11),
      Uint8List(20000),
    ];
    for (final data in inputs) {
      for (final (order, restore) in [(2, 0), (3, 1), (8, 0), (16, 1)]) {
        final packed = _encode(
            data,
            Ppmd8ZipCompressor(
                order: order, memSize: 1 << 20, restoreMethod: restore));
        expect(_decode(packed, data.length), data);
        expect(_decode(packed, null), data);
      }
    }
  });

  group('decoder', () {
    final data = _text(5000, 2);
    late Uint8List packed;
    setUpAll(() => packed = _encode(data, Ppmd8ZipCompressor(level: 5)));

    test('stops at outSize', () {
      expect(_decode(packed, 1000), Uint8List.sublistView(data, 0, 1000));
      expect(_decode(packed, 0), isEmpty);
    });

    test('end marker before outSize', () {
      expect(() => _decode(packed, data.length + 1),
          throwsA(isA<SevenZipException>()));
    });

    test('truncated input', () {
      for (final n in [0, 1, 3, 100, packed.length - 5]) {
        final cut = Uint8List.sublistView(packed, 0, n);
        expect(
            () => _decode(cut, data.length), throwsA(isA<SevenZipException>()));
      }
    });

    test('invalid parameters', () {
      for (final w in [0x0000, 0x2007, 0xF007]) {
        final bad = Uint8List.fromList(packed);
        bad[0] = w & 0xFF;
        bad[1] = w >> 8;
        expect(
            () => _decode(bad, data.length),
            throwsA(isA<SevenZipException>().having(
                (e) => e.kind, 'kind', SevenZipError.unsupportedMethod)));
      }
    });

    test('corrupted data fails cleanly', () {
      final g = _lcg(99).iterator;
      for (var k = 0; k < 20; k++) {
        final bad = Uint8List.fromList(packed);
        for (var j = 0; j < 3; j++) {
          g.moveNext();
          final pos = 2 + g.current % (bad.length - 2);
          bad[pos] ^= 1 + (g.current >> 8) % 255;
        }
        try {
          _decode(bad, data.length);
        } on SevenZipException {
          // expected for most corruptions
        }
      }
    });
  });

  group('properties', () {
    test('levels (7-Zip 23.01)', () {
      for (final (level, order, mem, restore) in [
        (0, 4, 1, 0),
        (1, 4, 1, 0),
        (2, 5, 2, 0),
        (3, 6, 4, 0),
        (4, 7, 8, 0),
        (5, 8, 16, 0),
        (6, 9, 32, 0),
        (7, 10, 64, 1),
        (8, 11, 128, 1),
        (9, 12, 256, 1),
      ]) {
        final c = Ppmd8ZipCompressor(level: level);
        expect(
            [c.order, c.memSize >> 20, c.restoreMethod], [order, mem, restore],
            reason: 'level $level');
        expect(c.props, isEmpty);
      }
      expect(Ppmd8ZipCompressor().order, 8);
    });

    test('reduceSize', () {
      for (final (size, mem) in [
        (0, 1),
        (1000, 1),
        (65536, 1),
        (65537, 2),
        (262144, 4),
        (262145, 8),
        (3000000, 16),
      ]) {
        expect(Ppmd8ZipCompressor(reduceSize: size).memSize, mem << 20,
            reason: 'size $size');
      }
      expect(
          Ppmd8ZipCompressor(memSize: 256 << 20, reduceSize: 3000000).memSize,
          64 << 20);
      expect(Ppmd8ZipCompressor(level: 9, reduceSize: 20000000).memSize,
          256 << 20);
    });

    test('explicit values', () {
      final c = Ppmd8ZipCompressor(
          level: 9, order: 5, memSize: 1500 << 10, restoreMethod: 0);
      expect([c.order, c.memSize, c.restoreMethod], [5, 1 << 20, 0]);
      final p = Ppmd8ZipCompressor.fromCoderProps([
        CoderProp(CoderPropId.level, const PropVariant.ui4(3)),
        CoderProp(CoderPropId.numThreads, const PropVariant.ui4(4)),
        CoderProp(CoderPropId.order, const PropVariant.ui4(16)),
        CoderProp(CoderPropId.usedMemorySize, const PropVariant.ui4(3 << 20)),
        CoderProp(CoderPropId.algorithm, const PropVariant.ui4(1)),
        CoderProp(CoderPropId.reduceSize, const PropVariant.ui8(1 << 30)),
      ]);
      expect([p.order, p.memSize, p.restoreMethod], [16, 3 << 20, 1]);
    });

    test('invalid values', () {
      for (final f in <void Function()>[
        () => Ppmd8ZipCompressor(order: 1),
        () => Ppmd8ZipCompressor(order: 17),
        () => Ppmd8ZipCompressor(memSize: 1 << 19),
        () => Ppmd8ZipCompressor(memSize: 257 << 20),
        () => Ppmd8ZipCompressor(restoreMethod: 2),
        () => Ppmd8ZipCompressor.fromCoderProps([
              CoderProp(CoderPropId.order, const PropVariant.bstr('x')),
            ]),
      ]) {
        expect(f, throwsA(isA<InvalidArgException>()));
      }
    });
  });

  // The libarchive fixture: three files packed with method 98.
  final fixture = File('ref/libarchive/libarchive/test/'
      'test_read_format_zip_ppmd8_multi.zipx.uu');
  test('libarchive fixture', () {
    final zip = _uudecode(fixture.readAsStringSync());
    final bd = ByteData.sublistView(zip);
    var pos = 0;
    var count = 0;
    while (bd.getUint32(pos, Endian.little) == 0x04034B50) {
      final crc = bd.getUint32(pos + 14, Endian.little);
      final csize = bd.getUint32(pos + 18, Endian.little);
      final usize = bd.getUint32(pos + 22, Endian.little);
      final off = pos +
          30 +
          bd.getUint16(pos + 26, Endian.little) +
          bd.getUint16(pos + 28, Endian.little);
      final packed = Uint8List.sublistView(zip, off, off + csize);
      final out = _decode(packed, usize);
      expect(out.length, usize);
      expect(Crc32.of(out), crc);
      expect(_decode(packed, null), out);
      pos = off + csize;
      count++;
    }
    expect(count, 3);
  }, skip: fixture.existsSync() ? false : 'no libarchive fixture');

  // Interop with the system 7z, both directions: the data of a zip entry
  // 7-Zip writes must decode and must be what the encoder writes with the
  // same settings, and 7-Zip must extract a zip entry the encoder wrote.
  final has7z = File('/usr/bin/7z').existsSync();
  group('7z interop', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('zx_ppmd8_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    for (final (switches, level, order, mem, name, size) in [
      (['-mx=1'], 1, null, null, 'text', 100000),
      (['-mx=5'], 5, null, null, 'text', 70000),
      (['-mx=9'], 9, null, null, 'text', 5000),
      (['-mx=7', '-mo=16', '-mmem=1m'], 7, 16, 1 << 20, 'mixed', 300000),
      (['-mx=3', '-mmem=3m'], 3, null, 3 << 20, 'text', 300000),
    ]) {
      test('7z a -tzip -mm=PPMd ${switches.join(' ')} ($name)', () {
        final data = name == 'mixed'
            ? _mixed(size)
            : name == 'text'
                ? _text(size, 4)
                : _random(size, 5);
        final f = File('${tmp.path}/$name.bin')..writeAsBytesSync(data);
        final arc = '${tmp.path}/x.zip';
        final r = Process.runSync('/usr/bin/7z',
            ['a', '-tzip', '-mm=PPMd', ...switches, arc, f.path]);
        expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
        final pack = _firstEntryData(File(arc).readAsBytesSync());

        expect(_decode(pack, data.length), data);
        final c = Ppmd8ZipCompressor(
            level: level, order: order, memSize: mem, reduceSize: data.length);
        final packed = _encode(data, c);
        expect(packed, pack);

        // And the other way: 7-Zip extracts our entry.
        final ours = '${tmp.path}/ours.zip';
        File(ours).writeAsBytesSync(_zip('ours.bin', data, packed));
        final x = Process.runSync('/usr/bin/7z', ['x', '-so', ours],
            stdoutEncoding: null);
        expect(x.exitCode, 0, reason: '${x.stderr}');
        expect(x.stdout, data);
      });
    }
  }, skip: has7z ? false : 'no /usr/bin/7z');
}
