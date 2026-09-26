import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/codec/bzip2/bzip2_coder.dart';
import 'package:zx/src/codec/codec.dart';
import 'package:zx/src/common/method_props.dart';
import 'package:zx/src/format/archive_types.dart';
import 'package:zx/src/format/bzip2/bzip2_handler.dart';
import 'package:zx/src/io/streams.dart';

/// Deterministic text-like data with runs.
Uint8List gen(int n, int seed) {
  var st = seed;
  int next() {
    st = (st * 1103515245 + 12345) & 0x7fffffff;
    return st >> 16;
  }

  const words = ['alpha ', 'beta ', 'gamma ', 'delta ', 'bzip2 ', 'block\n'];
  final out = BytesBuilder();
  while (out.length < n) {
    final r = next();
    switch (r % 8) {
      case 0:
        out.add(List.filled(next() % 300, r & 0xff));
      case 1:
      case 2:
      case 3:
        out.add(words[next() % words.length].codeUnits);
      default:
        out.addByte(r & 0xff);
    }
  }
  return Uint8List.sublistView(out.toBytes(), 0, n);
}

Uint8List random(int n, int seed) {
  var st = seed;
  final b = Uint8List(n);
  for (var i = 0; i < n; i++) {
    st = (st * 1103515245 + 12345) & 0x7fffffff;
    b[i] = st >> 16;
  }
  return b;
}

Uint8List compress(Uint8List data, {int level = 9, bool seam = false}) {
  final out = MemoryOutStream();
  if (seam) {
    final s = Bzip2StreamEncoder(level, separateBlockWriters: true);
    s.write(data, 0, data.length, out);
    s.finish(out);
  } else {
    Bzip2Compressor(blockSize100k: level).encode(MemoryInStream(data), out);
  }
  return Uint8List.fromList(out.toBytes());
}

Uint8List decompress(Uint8List bz) =>
    readAll(Bzip2DecoderStream(MemoryInStream(bz)));

bool _have(String exe, List<String> args) {
  try {
    return Process.runSync(exe, args).exitCode == 0;
  } on ProcessException {
    return false;
  }
}

final bool haveBzip2 = _have('bzip2', ['--help']);
final bool haveBzip2108 = haveBzip2 &&
    (Process.runSync('bzip2', ['--help']).stderr as String)
        .contains('Version 1.0.8');
final bool have7z = File('/usr/bin/7z').existsSync();

Uint8List runBzip2(List<String> args, Uint8List input) {
  final dir = Directory.systemTemp.createTempSync('zxbz');
  try {
    final f = File('${dir.path}/in')..writeAsBytesSync(input);
    final r =
        Process.runSync('bzip2', [...args, '-c', f.path], stdoutEncoding: null);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    return Uint8List.fromList(r.stdout as List<int>);
  } finally {
    dir.deleteSync(recursive: true);
  }
}

SevenZipError? decodeError(Uint8List bz) {
  try {
    decompress(bz);
    return null;
  } on SevenZipException catch (e) {
    return e.kind;
  }
}

void main() {
  final inputs = <String, Uint8List>{
    'empty': Uint8List(0),
    'one byte': Uint8List.fromList([65]),
    'text': gen(150000, 1),
    'random': random(60000, 2),
    'zeros': Uint8List(200000),
    // repetitive: the main sort gives up, the fallback sort runs
    'abab': Uint8List.fromList(List.generate(60000, (i) => 97 + (i & 1))),
    'small repetitive': Uint8List.fromList(List.generate(5000, (i) => i % 3)),
  };

  group('round trip', () {
    for (final e in inputs.entries) {
      for (final level in [1, 9]) {
        test('${e.key} -$level', () {
          final bz = compress(e.value, level: level);
          expect(String.fromCharCodes(bz, 0, 4), 'BZh$level');
          expect(decompress(bz), e.value);
        });
      }
    }

    test('several blocks at block size 1', () {
      final data = random(350000, 3);
      final bz = compress(data, level: 1);
      final d = Bzip2DecoderStream(MemoryInStream(bz));
      expect(readAll(d), data);
      expect(d.numBlocks, greaterThan(3));
      expect(d.numStreams, 1);
      expect(d.inProcessed, bz.length);
    });

    test('block seam (each block in its own writer) gives the same bytes', () {
      final data = gen(350000, 4);
      for (final level in [1, 2]) {
        expect(compress(data, level: level, seam: true),
            compress(data, level: level));
      }
    });

    test('block boundary: input ends when the block is full', () {
      // no runs: nblock is the input size minus the pending byte
      for (final n in [99981, 99982, 99983]) {
        final data = random(n, 5);
        expect(decompress(compress(data, level: 1)), data);
      }
    });
  });

  group('byte identity with bzip2 1.0.8',
      skip: haveBzip2108 ? false : 'bzip2 1.0.8 not installed', () {
    for (final e in inputs.entries) {
      test(e.key, () {
        for (final level in [1, 5, 9]) {
          expect(
              compress(e.value, level: level), runBzip2(['-$level'], e.value),
              reason: 'level $level');
        }
      });
    }

    test('all block sizes, several blocks', () {
      final data = gen(250000, 6);
      for (var level = 1; level <= 9; level++) {
        expect(compress(data, level: level), runBzip2(['-$level'], data),
            reason: 'level $level');
      }
    });

    test('block boundary', () {
      for (final n in [99981, 99982, 99983]) {
        final data = random(n, 7);
        expect(compress(data, level: 1), runBzip2(['-1'], data));
      }
    });

    test('bzip2 -t accepts the output', () {
      final data = gen(120000, 8);
      final dir = Directory.systemTemp.createTempSync('zxbz');
      try {
        final f = File('${dir.path}/a.bz2')
          ..writeAsBytesSync(compress(data, level: 3));
        expect(Process.runSync('bzip2', ['-t', f.path]).exitCode, 0);
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  });

  group('decode bzip2 output', skip: haveBzip2 ? false : 'no bzip2', () {
    test('levels 1 to 9', () {
      final data = gen(220000, 9);
      for (var level = 1; level <= 9; level++) {
        expect(decompress(runBzip2(['-$level'], data)), data);
      }
    });

    test('concatenated streams', () {
      final a = gen(120000, 10), b = random(1000, 11);
      final bz = Uint8List.fromList([
        ...runBzip2(['-1'], a),
        ...runBzip2(['-9'], Uint8List(0)),
        ...runBzip2(['-2'], b),
      ]);
      final d = Bzip2DecoderStream(MemoryInStream(bz));
      expect(readAll(d), [...a, ...b]);
      expect(d.numStreams, 3);
      expect(d.dataAfterEnd, isFalse);
    });

    test('single stream mode leaves the rest unused', () {
      final a = gen(1000, 12);
      final s1 = runBzip2(['-1'], a);
      final bz = Uint8List.fromList([...s1, ...s1]);
      final d = Bzip2DecoderStream(MemoryInStream(bz), multiStream: false);
      expect(readAll(d), a);
      expect(d.inProcessed, s1.length);
    });
  });

  group('errors', () {
    final data = gen(100000, 13);
    final bz = compress(data, level: 1);

    test('not bzip2', () {
      expect(decodeError(Uint8List.fromList('hello world'.codeUnits)),
          SevenZipError.isNotArc);
      expect(decodeError(Uint8List(0)), SevenZipError.isNotArc);
    });

    test('truncated', () {
      for (final n in [5, 40, bz.length ~/ 2, bz.length - 1]) {
        expect(decodeError(Uint8List.sublistView(bz, 0, n)),
            SevenZipError.unexpectedEnd,
            reason: 'at $n');
      }
    });

    test('corrupt bytes are detected', () {
      var st = 99;
      for (var t = 0; t < 60; t++) {
        st = (st * 1103515245 + 12345) & 0x7fffffff;
        final c = Uint8List.fromList(bz);
        final pos = 4 + (st >> 8) % (bz.length - 4);
        c[pos] ^= 1 << (st & 7);
        final k = decodeError(c);
        expect(k, anyOf(SevenZipError.crc, SevenZipError.data), reason: '$pos');
      }
    });

    test('stored CRCs are checked', () {
      // the block CRC follows the 4 byte header and the 6 byte magic
      final c = Uint8List.fromList(bz);
      c[10] ^= 0x01;
      expect(decodeError(c), SevenZipError.crc);
      // the combined CRC is in the last bytes
      final e = compress(Uint8List(0));
      e[e.length - 2] ^= 0x10;
      expect(decodeError(e), SevenZipError.crc);
    });

    test('trailing data', () {
      final d = Bzip2DecoderStream(
          MemoryInStream(Uint8List.fromList([...bz, 0, 0, 0, 1])));
      expect(readAll(d), data);
      expect(d.dataAfterEnd, isTrue);
      expect(d.inProcessed, bz.length);
    });
  });

  group('coder properties', () {
    int bs(String s) => Bzip2Compressor.fromString(s).blockSize100k;

    test('levels (Get_BZip2_BlockSize)', () {
      expect(Bzip2Compressor.fromCoderProps([]).blockSize100k, 9);
      expect(bs('x=0'), 1);
      expect(bs('x=1'), 1);
      expect(bs('x=2'), 3);
      expect(bs('x=3'), 5);
      expect(bs('x=4'), 7);
      expect(bs('x=5'), 9);
      expect(bs('x=9'), 9);
    });

    test('d', () {
      expect(bs('d=100000b'), 1);
      expect(bs('d=500k'), 5);
      expect(bs('d=900k'), 9);
      expect(bs('d=1m'), 9);
      expect(bs('d=50k'), 1);
      expect(bs('x=1:d=700000b'), 7);
    });

    test('pass and mt are accepted, others rejected', () {
      expect(bs('pass=2:mt=4'), 9);
      expect(() => Bzip2Compressor.fromString('fb=64'),
          throwsA(isA<InvalidArgException>()));
    });

    test('decoder registry', () {
      final reg = <int, DecoderFactory>{};
      registerBzip2Codecs(reg);
      final data = gen(5000, 14);
      final dec = reg[MethodId.bzip2]!(Uint8List(0),
          [MemoryInStream(compress(data))], data.length, const CoderContext());
      expect(readAll(dec), data);
    });
  });

  group('handler', () {
    Uint8List create(Uint8List data, List<MapEntry<String, String>> props) {
      final out = MemoryOutStream();
      Bzip2Archive.create(MemoryInStream(data), out, data.length,
          properties: props);
      return Uint8List.fromList(out.toBytes());
    }

    test('create with -m properties', () {
      final data = gen(30000, 15);
      expect(create(data, [])[3], 0x39);
      expect(create(data, [const MapEntry('x', '1')])[3], 0x31);
      expect(create(data, [const MapEntry('x', '3')])[3], 0x35);
      expect(create(data, [const MapEntry('d', '500k')])[3], 0x35);
      expect(create(data, [const MapEntry('x1', '')])[3], 0x31);
      expect(create(data, [const MapEntry('mt', '4')]), compress(data));
    });

    test('open, test, extract, properties', () {
      final data = random(250000, 16);
      final bz = create(data, [const MapEntry('x', '1')]);
      final a = Bzip2Archive.open(MemoryInStream(bz))!;
      expect(a.size, isNull);
      expect(a.test(), OperationResult.ok);
      expect(a.size, data.length);
      expect(a.packSize, bz.length);
      expect(a.numStreams, 1);
      expect(a.numBlocks, 3);
      final out = MemoryOutStream();
      expect(a.extract(out), OperationResult.ok);
      expect(out.toBytes(), data);
      expect(a.errorFlags, 0);
    });

    test('not a bzip2 file', () {
      expect(Bzip2Archive.open(MemoryInStream(Uint8List(20))), isNull);
      expect(
          Bzip2Archive.open(
              MemoryInStream(Uint8List.fromList('BZh9'.codeUnits))),
          isNull);
    });

    test('errors as operation results', () {
      final data = gen(20000, 17);
      final bz = compress(data, level: 1);
      final trailing = Bzip2Archive.open(
          MemoryInStream(Uint8List.fromList([...bz, 1, 2, 3])))!;
      expect(trailing.test(), OperationResult.dataAfterEnd);
      expect(trailing.errorFlags & ErrorFlags.dataAfterEnd, isNot(0));
      final truncated = Bzip2Archive.open(
          MemoryInStream(Uint8List.sublistView(bz, 0, bz.length - 10)))!;
      expect(truncated.test(), OperationResult.unexpectedEnd);
      final c = Uint8List.fromList(bz);
      c[10] ^= 1;
      expect(Bzip2Archive.open(MemoryInStream(c))!.test(),
          OperationResult.crcError);
    });

    test('openSeq', () {
      final data = gen(10000, 18);
      final a = Bzip2Archive.openSeq(MemoryInStream(compress(data)));
      final out = MemoryOutStream();
      expect(a.extract(out), OperationResult.ok);
      expect(out.toBytes(), data);
    });
  });

  group('7-Zip interop', skip: have7z ? false : 'no /usr/bin/7z', () {
    test('7z tests our output and we decode 7z output', () {
      final data = gen(300000, 19);
      final dir = Directory.systemTemp.createTempSync('zxbz');
      try {
        final ours = File('${dir.path}/ours.bz2')
          ..writeAsBytesSync(compress(data, level: 2));
        var r = Process.runSync('/usr/bin/7z', ['t', ours.path]);
        expect(r.exitCode, 0, reason: '${r.stdout}');
        File('${dir.path}/in').writeAsBytesSync(data);
        r = Process.runSync('/usr/bin/7z',
            ['a', '-tbzip2', '-mx1', '${dir.path}/7z.bz2', '${dir.path}/in']);
        expect(r.exitCode, 0, reason: '${r.stdout}');
        expect(decompress(File('${dir.path}/7z.bz2').readAsBytesSync()), data);
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  });
}
