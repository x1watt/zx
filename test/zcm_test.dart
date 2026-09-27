// Tests of the zcm context mixing codec (lib/src/codec/zcm).
//
// ZCM_GOLDEN=1 dart test test/zcm_test.dart prints the golden values
// instead of checking them (after an intended change of the model).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/cli/main.dart';
import 'package:zx/src/codec/codec.dart';
import 'package:zx/src/codec/zcm/zcm.dart';
import 'package:zx/src/codec/zcm/zcm_auto.dart';
import 'package:zx/src/codec/zcm/zcm_detect.dart';
import 'package:zx/src/codec/zcm/zcm_dict.dart';
import 'package:zx/src/codec/zcm/zcm_math.dart';
import 'package:zx/src/codec/zcm/zcm_parallel.dart';
import 'package:zx/src/codec/zcm/zcm_predictor.dart';
import 'package:zx/src/crypto/sha256.dart';
import 'package:zx/src/format/zx/zx_codecs.dart';
import 'package:zx/src/format/zx/zx_reader.dart';
import 'package:zx/src/io/streams.dart';
import 'package:zx/src/version.dart';

import 'codec_test_util.dart';
import 'zx_test_util.dart' show makeArchive, openMem, extractAll, testOptions;

final bool _printGolden = Platform.environment['ZCM_GOLDEN'] == '1';

Uint8List _random(int n, int seed) {
  final out = Uint8List(n);
  var s = seed;
  for (var i = 0; i < n; i++) {
    s = (s * 1103515245 + 12345) & 0x7FFFFFFF;
    out[i] = s >> 16;
  }
  return out;
}

// x86-like data: calls with small displacements between random bytes.
Uint8List _exeLike(int n, int seed) {
  final out = _random(n, seed);
  for (var i = 0; i + 5 < n; i += 23) {
    out[i] = 0xE8;
    out[i + 1] = (i * 7) & 255;
    out[i + 2] = (i >> 3) & 255;
    out[i + 3] = 0;
    out[i + 4] = 0;
  }
  return out;
}


// A 24-bit BMP of [w] x [h] pixels (rows padded to 4 bytes).
Uint8List _bmp24(int w, int h, int seed) {
  final stride = (w * 3 + 3) & ~3;
  final size = 54 + stride * h;
  final b = Uint8List(size);
  final d = ByteData.sublistView(b);
  b[0] = 0x42;
  b[1] = 0x4D;
  d.setUint32(2, size, Endian.little);
  d.setUint32(10, 54, Endian.little);
  d.setUint32(14, 40, Endian.little);
  d.setInt32(18, w, Endian.little);
  d.setInt32(22, h, Endian.little);
  d.setUint16(26, 1, Endian.little);
  d.setUint16(28, 24, Endian.little);
  final r = _random(w * h * 3, seed);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      for (var c = 0; c < 3; c++) {
        b[54 + y * stride + x * 3 + c] =
            (x * (c + 1) + y * 2 + (r[(y * w + x) * 3 + c] & 7)) & 255;
      }
    }
  }
  return b;
}

// A binary PGM of [w] x [h] pixels.
Uint8List _pgm(int w, int h, int seed) {
  final head = ascii.encode('P5\n# zcm test\n$w $h\n255\n');
  final b = Uint8List(head.length + w * h);
  b.setAll(0, head);
  final r = _random(w * h, seed);
  for (var i = 0; i < w * h; i++) {
    b[head.length + i] = ((i % w) + (i ~/ w) * 3 + (r[i] & 3)) & 255;
  }
  return b;
}

// A 16-bit stereo PCM WAV of [frames] frames.
Uint8List _wav16(int frames, int seed) {
  final data = frames * 4;
  final b = Uint8List(44 + data);
  final d = ByteData.sublistView(b);
  b.setAll(0, ascii.encode('RIFF'));
  d.setUint32(4, 36 + data, Endian.little);
  b.setAll(8, ascii.encode('WAVEfmt '));
  d.setUint32(16, 16, Endian.little);
  d.setUint16(20, 1, Endian.little);
  d.setUint16(22, 2, Endian.little);
  d.setUint32(24, 44100, Endian.little);
  d.setUint32(28, 44100 * 4, Endian.little);
  d.setUint16(32, 4, Endian.little);
  d.setUint16(34, 16, Endian.little);
  b.setAll(36, ascii.encode('data'));
  d.setUint32(40, data, Endian.little);
  final r = _random(frames, seed);
  var a = 0, v = 0;
  for (var i = 0; i < frames; i++) {
    v += ((i >> 5) & 1) == 0 ? 97 : -97;
    a = v * 20 + (r[i] & 31) - 16;
    d.setInt16(44 + i * 4, a, Endian.little);
    d.setInt16(46 + i * 4, (a >> 1) + 5, Endian.little);
  }
  return b;
}

// An 8-bit mono AIFF of [frames] frames.
Uint8List _aiff8(int frames, int seed) {
  final b = Uint8List(12 + 26 + 16 + frames);
  final d = ByteData.sublistView(b);
  b.setAll(0, ascii.encode('FORM'));
  d.setUint32(4, b.length - 8);
  b.setAll(8, ascii.encode('AIFFCOMM'));
  d.setUint32(16, 18);
  d.setUint16(20, 1);
  d.setUint32(22, frames);
  d.setUint16(26, 8);
  b.setAll(38, ascii.encode('SSND'));
  d.setUint32(42, frames + 8);
  final r = _random(frames, seed);
  for (var i = 0; i < frames; i++) {
    b[54 + i] = ((i * 3) & 63) + (r[i] & 3);
  }
  return b;
}

const String _english =
    'The quick brown fox jumps over the lazy dog. However, ANOTHER dog was '
    'sleeping under the tree; it did not see anything at all, and "NASA" '
    'said so: the Committee reported its results on Monday, together with '
    'the Government and the University of London. Something unusual '
    'happened with &quot;quotes&quot; and @mentions, xYz, ABCdef, IBMs.\n';

String _hex(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

String _sha(Uint8List b) => _hex(Sha256.hash(b)).substring(0, 16);

void _roundTrip(Uint8List data, ZcmOptions o) {
  final packed = zcmCompressBytes(data, o);
  final back = zcmDecompressBytes(packed);
  expect(back.length, data.length);
  expect(back, data);
}

ZcmOptions _opts(int level) => level == 10
    ? const ZcmOptions(level: 9, lstm: true, lstmCells: 8, lstmHorizon: 5)
    : ZcmOptions(level: level);

void main() {
  final text = genData(20000, 7, randomPercent: 2);
  final small = genData(3000, 11, randomPercent: 2);

  group('round trips', () {
    for (var level = 1; level <= 10; level++) {
      final name = level == 10 ? '9+lstm' : '$level';
      final big = level <= 5;
      test('level $name', () {
        final o = _opts(level);
        _roundTrip(Uint8List(0), o);
        _roundTrip(Uint8List.fromList([42]), o);
        _roundTrip(_random(big ? 3000 : 800, level), o);
        _roundTrip(big ? text : small, o);
        _roundTrip(Uint8List(big ? 10000 : 3000), o);
        _roundTrip(_exeLike(big ? 12000 : 3000, level), o);
      });
    }

    test('blocks of different types in one stream', () {
      // 64 KiB text, 64 KiB exe-like, then random: three block types.
      final d = BytesBuilder()
        ..add(genData(65536, 3, randomPercent: 1))
        ..add(_exeLike(65536, 4))
        ..add(_random(20000, 5));
      _roundTrip(d.toBytes(), const ZcmOptions(level: 2));
    });

    test('without block detection', () {
      _roundTrip(_exeLike(20000, 9), const ZcmOptions(level: 3, detect: false));
    });

    test('streaming decoder with small reads and unknown sizes', () {
      final packed = zcmCompressBytes(text, const ZcmOptions(level: 2));
      final dec = ZcmDecoderStream(MemoryInStream(packed));
      final out = BytesBuilder();
      final buf = Uint8List(7);
      while (true) {
        final n = dec.read(buf, 0, buf.length);
        if (n == 0) break;
        out.add(Uint8List.sublistView(buf, 0, n));
      }
      expect(out.toBytes(), text);
      // The compressor without a size hint writes no original size.
      final o = MemoryOutStream();
      ZcmCompressor(const ZcmOptions(level: 1)).encode(MemoryInStream(text), o);
      expect(zcmDecompressBytes(o.toBytes()), text);
    });

    test('decoder factory with props and outSize', () {
      final c = ZcmCompressor(const ZcmOptions(level: 2), inputSize: text.length);
      final o = MemoryOutStream();
      c.encode(MemoryInStream(text), o);
      final s = zcmDecoder(c.props, [MemoryInStream(o.toBytes())], text.length,
          const CoderContext());
      expect(readAll(s), text);
      // Props that do not match the stream are rejected.
      final bad = Uint8List.fromList(c.props)..[1] = 3;
      expect(
          () => readAll(zcmDecoder(bad, [MemoryInStream(o.toBytes())],
              text.length, const CoderContext())),
          throwsA(isA<SevenZipException>()));
    });
  });

  group('options', () {
    test('method strings', () {
      final o = zcmOptionsFromString('cmix:mem=2g:lstm=32/2/15:seg=4m');
      expect(o.level, 9);
      expect(o.memoryMiB, 2048);
      expect(o.lstm, isTrue);
      expect(o.lstmCells, 32);
      expect(o.lstmLayers, 2);
      expect(o.lstmHorizon, 15);
      expect(o.segmentSize, 4 << 20);
      expect(zcmOptionsFromString('fast').level, 2);
      expect(zcmOptionsFromString('', level: 7).level, 7);
      expect(zcmOptionsFromString('9').lstm, isFalse);
      expect(zcmOptionsFromString('3,nodetect').detect, isFalse);
      expect(zcmOptionsFromString('5:nodict').dictionary, isFalse);
      final big = zcmOptionsFromString('cmix:lstm=large');
      expect([big.lstmCells, big.lstmLayers, big.lstmHorizon], [200, 2, 100]);
      expect(() => zcmOptionsFromString('bogus'),
          throwsA(isA<SevenZipException>()));
      final h = ZcmHeader.fromOptions(o, 1 << 30);
      // The budget is capped by the segment size (64 bytes per byte + 8 MiB).
      expect(zcmDescribe(h.props), 'zcm:9:m264:lstm32/2/15:seg4194304');
      expect(zcmParseProps(h.props).lstmHorizon, 15);
    });
  });

  group('data types', () {
    final media = BytesBuilder()
      ..add(genData(3000, 1))
      ..add(_bmp24(61, 40, 2))
      ..add(_random(500, 3))
      ..add(_pgm(64, 48, 4))
      ..add(_wav16(3000, 5))
      ..add(genData(700, 6))
      ..add(_aiff8(3000, 7));
    final data = media.toBytes();

    test('images and audio are found by their headers', () {
      final segs = zcmDetectSegments(data, 0, data.length);
      final types = segs.map((e) => e.type).toList();
      expect(types, contains(ZcmBlockType.image24));
      expect(types, contains(ZcmBlockType.image8));
      expect(types.where((t) => t == ZcmBlockType.audio).length, 2);
      final bmp = segs.firstWhere((e) => e.type == ZcmBlockType.image24);
      expect(bmp.off, 3000 + 54);
      expect(bmp.len, 184 * 40);
      expect(bmp.info & 0xFFFFFF, 184);
      expect(bmp.info >> 24, 1); // one padding byte per row
      var end = 0;
      for (final e in segs) {
        expect(e.off, end);
        end += e.len;
      }
      expect(end, data.length);
    });

    for (final level in [1, 3, 5, 7]) {
      test('round trip with images and audio, level $level', () {
        _roundTrip(data, ZcmOptions(level: level));
      });
    }

    test('corrupt media streams fail cleanly', () {
      final packed = zcmCompressBytes(data, const ZcmOptions(level: 3));
      var st = 5;
      for (var round = 0; round < 12; round++) {
        st = (st * 1103515245 + 12345) & 0x7FFFFFFF;
        final i = 16 + (st >> 4) % (packed.length - 16);
        final bad = Uint8List.fromList(packed)..[i] ^= 1 + (st & 0x7F);
        try {
          expect(zcmDecompressBytes(bad), data);
        } on SevenZipException {
          // expected
        }
      }
    });

    test('the models of a type make the data smaller', () {
      final img = _bmp24(120, 80, 9);
      final a = zcmCompressBytes(img, const ZcmOptions(level: 6)).length;
      final b = zcmCompressBytes(img, const ZcmOptions(level: 6, detect: false))
          .length;
      expect(a < b, isTrue, reason: '$a vs $b');
    });
  });

  group('dictionary transform', () {
    test('English text is transformed and restored', () {
      final text = Uint8List.fromList(
          ascii.encode(List.filled(20, _english).join()));
      final t = zcmDictEncode(text, 0, text.length);
      expect(t, isNotNull);
      expect(t!.length < text.length * 3 ~/ 4, isTrue);
      final back = Uint8List(text.length);
      expect(zcmDictDecode(t, back, 0, text.length), isTrue);
      expect(back, text);
      _roundTrip(text, const ZcmOptions(level: 3));
      final plain = zcmCompressBytes(
          text, const ZcmOptions(level: 3, dictionary: false));
      expect(zcmDecompressBytes(plain), text);
    });

    test('random mixtures of words and bytes stay exact', () {
      const words = [
        'the', 'The', 'THE', 'house', 'HOUSEs', 'Houses', 'xq', 'Q', 'a',
        'information', 'INFORMATIONAL', 'internationalization', '&quot;',
        '@', '\u0006', '\u0007', '\u0008', '\u000c', ' ', '\n', '. ', ','
      ];
      var st = 77;
      for (var round = 0; round < 40; round++) {
        final sb = StringBuffer();
        for (var i = 0; i < 400; i++) {
          st = (st * 1103515245 + 12345) & 0x7FFFFFFF;
          sb.write(words[(st >> 8) % words.length]);
          if ((st & 7) == 0) sb.write(' ');
        }
        final b = Uint8List.fromList(latin1.encode(sb.toString()));
        final t = zcmDictTransform(b, 0, b.length);
        final back = Uint8List(b.length);
        final ok = zcmDictDecode(t, back, 0, b.length);
        final e = zcmDictEncode(b, 0, b.length);
        if (e != null) {
          final back2 = Uint8List(b.length);
          expect(zcmDictDecode(e, back2, 0, b.length), isTrue);
          expect(back2, b);
        }
        if (ok) expect(back, b, reason: 'round $round');
      }
    });
  });

  group('zx container', () {
    final files = <String, Uint8List?>{
      'a.txt': genData(40000, 3),
      'b.bin': _exeLike(20000, 4),
      'e': Uint8List(0),
    };

    test('writer and handler round trip (codec 0x10000)', () {
      expect(zxCodecById(zcmCodecId)?.name, 'zcm');
      final o = testOptions()
        ..coders = [
          const ZxCoderSpec(zcmCodecId, ZxCoderConfig(level: 5, params: 'level=2'))
        ];
      final a = makeArchive(files, o);
      expect(o.warnings.join(), contains('experimental'));
      final r = ZxArchiveReader.open(MemoryInStream(a), const ZxOpenParams())!;
      expect(r.header.minReaderVersion, zxVersion);
      final got = extractAll(openMem(a));
      for (final e in files.entries) {
        expect(got[e.key], e.value, reason: e.key);
      }
    });

    test('command line: -m0=zcm:level=3', () async {
      final tmp = Directory.systemTemp.createTempSync('zcm_zx_');
      try {
        File('${tmp.path}/a.txt').writeAsBytesSync(files['a.txt']!);
        Future<(int, String)> cli(List<String> args) async {
          final out = BytesBuilder();
          final code = await runSevenZipCli(args,
              stdout: out.add, stderr: out.add, workingDirectory: tmp.path);
          return (code, utf8.decode(out.takeBytes(), allowMalformed: true));
        }

        var (code, out) =
            await cli(['a', '-mmt1', '-m0=zcm:level=3', 'z.zx', 'a.txt']);
        expect(code, 0, reason: out);
        (code, out) = await cli(['l', '-slt', 'z.zx']);
        expect(out, contains('zcm:3'), reason: out);
        (code, out) = await cli(['t', 'z.zx']);
        expect(code, 0, reason: out);
        (code, out) = await cli(['x', '-oout', 'z.zx']);
        expect(code, 0, reason: out);
        expect(File('${tmp.path}/out/a.txt').readAsBytesSync(), files['a.txt']);
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });
  });

  group('segments', () {
    test('independent segments round trip and match the parallel coder',
        () async {
      final d = BytesBuilder()
        ..add(text)
        ..add(text)
        ..add(_random(5000, 1));
      final data = d.toBytes();
      const o = ZcmOptions(level: 2, segmentSize: 16384);
      final seq = zcmCompressBytes(data, o);
      expect(zcmDecompressBytes(seq), data);
      final par = await zcmCompressParallel(data, o, threads: 3);
      expect(par, seq);
      expect(await zcmDecompressParallel(par, threads: 3), data);
    });

    test('the synchronous compressor codes segments on a pool', () {
      final data = BytesBuilder()
        ..add(text)
        ..add(_random(9000, 2))
        ..add(text);
      final d = data.toBytes();
      const o = ZcmOptions(level: 1, segmentSize: 8192);
      Uint8List run(int threads, int? size) {
        final out = MemoryOutStream();
        ZcmCompressor(o, inputSize: size, threads: threads)
            .encode(MemoryInStream(d), out);
        return Uint8List.fromList(out.toBytes());
      }

      final one = run(1, d.length);
      expect(run(3, d.length), one);
      expect(zcmDecompressBytes(run(4, null)), d);
      expect(zcmDecompressBytes(one), d);
    });

    test('parallel coder picks a segment size when none is set', () async {
      final data = genData(100000, 5);
      final par = await zcmCompressParallel(
          data, const ZcmOptions(level: 1), threads: 2);
      final (h, _) = zcmParseStream(par);
      expect(h.independent, isTrue);
      expect(await zcmDecompressParallel(par, threads: 2), data);
    });
  });

  group('determinism', () {
    // SHA-256 (first 8 bytes) of the output for fixed inputs. A change
    // here means streams written before do not decode any more: bump
    // zcmVersion, or undo the change.
    const golden = <String, String>{
      'L1': '4091:14b6fba4856c9d7d',
      'L2': '4013:7b1bb95c3f649ae3',
      'L3': '3980:0724f544c202ad29',
      'L4': '3938:32c2d6c2f5b4ffa4',
      'L5': '3933:d4cadf3a273e82f0',
      'L6': '3704:3bd956ac1978bb3c',
      'L7': '3688:4fb243e908d58858',
      'L8': '3649:db6f2c28d9342833',
      'L9': '3649:99db14a68bb31ae6',
      'L9+lstm': '3652:4ebfd67d935e7e86',
      'seg': '4139:aa2c58ea3777e71d',
      'media3': '4893:89a61a6884fa5da3',
      'media7': '4348:445007e417178a33',
    };
    final inputs = BytesBuilder()
      ..add(genData(6000, 21, randomPercent: 3))
      ..add(_exeLike(3000, 22));
    final data = inputs.toBytes();
    final actual = <String, String>{};
    for (var level = 1; level <= 10; level++) {
      final key = level == 10 ? 'L9+lstm' : 'L$level';
      test('golden $key', () {
        final packed = zcmCompressBytes(data, _opts(level));
        actual[key] = '${packed.length}:${_sha(packed)}';
        if (_printGolden) {
          stdout.writeln("      '$key': '${actual[key]}',");
        } else {
          expect(actual[key], golden[key]);
        }
      });
    }
    // Images, audio and English text (the dictionary transform).
    final mixed = BytesBuilder()
      ..add(_bmp24(40, 30, 31))
      ..add(_wav16(1500, 32))
      ..add(ascii.encode(List.filled(8, _english).join()))
      ..add(_pgm(32, 24, 33));
    final mixedData = mixed.toBytes();
    for (final level in [3, 7]) {
      test('golden media$level', () {
        final packed = zcmCompressBytes(mixedData, ZcmOptions(level: level));
        final v = '${packed.length}:${_sha(packed)}';
        if (_printGolden) {
          stdout.writeln("      'media$level': '$v',");
        } else {
          expect(v, golden['media$level']);
          expect(zcmDecompressBytes(packed), mixedData);
        }
      });
    }

    test('golden seg', () {
      final packed =
          zcmCompressBytes(data, const ZcmOptions(level: 3, segmentSize: 4096));
      final v = '${packed.length}:${_sha(packed)}';
      if (_printGolden) {
        stdout.writeln("      'seg': '$v',");
      } else {
        expect(v, golden['seg']);
      }
    });

    test('deterministic math', () {
      // Bit patterns of zexp, ztanh and zsigmoid, pinned on x86-64.
      final v = Float64List.fromList([
        zexp(1.0),
        zexp(-3.25),
        zexp(10.5),
        ztanh(0.3),
        ztanh(-2.0),
        zsigmoid(0.7),
        zsqrt(2.0),
      ]);
      final bits = v.buffer.asUint64List();
      final s = bits.map((b) => b.toRadixString(16)).join(',');
      const pinned = '4005bf0a8b14576a,3fa3da368521902d,40e1bb7015e84d3b,'
          '3fd2a4dda7d914f9,-401126afa1e43c2d,3fe561cb52a19476,'
          '3ff6a09e667f3bcc';
      if (_printGolden) {
        stdout.writeln("      const pinned = '$s';");
      } else {
        expect(s, pinned);
      }
      // And close to the true values.
      expect((zexp(1.0) - 2.718281828459045).abs() < 1e-14, isTrue);
      expect((ztanh(0.3) - 0.2913126124515909).abs() < 1e-14, isTrue);
      expect((zsqrt(2.0) - 1.4142135623730951).abs() < 1e-15, isTrue);
    });
  });

  group('memory budget', () {
    test('tables follow the budget', () {
      for (final level in [2, 5, 8]) {
        for (final mib in [8, 32, 128]) {
          final p = ZcmPredictor(level, mib << 20);
          expect(p.tableBytes <= (mib << 20), isTrue,
              reason: 'level $level, $mib MiB: ${p.tableBytes}');
          expect(p.tableBytes >= (mib << 20) ~/ 4, isTrue,
              reason: 'level $level, $mib MiB: ${p.tableBytes}');
        }
      }
    });

    test('the budget is stored and small inputs get a small one', () {
      final packed = zcmCompressBytes(small, const ZcmOptions(level: 8));
      final (h, _) = zcmParseStream(packed);
      expect(h.level, 8);
      expect(h.memoryMiB, zcmEffectiveMemoryMiB(const ZcmOptions(level: 8), small.length));
      expect(h.memoryMiB < zcmDefaultMemoryMiB(8), isTrue);
      final big = zcmEffectiveMemoryMiB(
          const ZcmOptions(level: 8, memoryMiB: 20000), 1 << 30);
      expect(big, 20000);
    });

    test('different budgets decode with their own tables', () {
      for (final mib in [4, 16]) {
        final o = ZcmOptions(level: 4, memoryMiB: mib);
        _roundTrip(text, o);
      }
    });
  });

  group('corrupt streams', () {
    final packed = zcmCompressBytes(text, const ZcmOptions(level: 1));

    test('truncated streams throw', () {
      for (var n = 0; n < packed.length; n += 1 + packed.length ~/ 40) {
        expect(() => zcmDecompressBytes(Uint8List.sublistView(packed, 0, n)),
            throwsA(isA<SevenZipException>()),
            reason: 'truncated at $n');
      }
    });

    test('changed bytes throw or decode the same data', () {
      // The last bytes the arithmetic coder flushes are not all needed:
      // a change there may leave the data intact, which is fine.
      var thrown = 0;
      for (var i = 0; i < packed.length; i += 1 + packed.length ~/ 60) {
        final bad = Uint8List.fromList(packed)..[i] ^= 0x5A;
        try {
          expect(zcmDecompressBytes(bad), text, reason: 'byte $i changed');
        } on SevenZipException {
          thrown++;
        }
      }
      expect(thrown > 50, isTrue);
    });

    test('version 1 streams are refused with a clear message', () {
      final v1 = Uint8List.fromList(packed)..[3] = 1;
      expect(
          () => zcmDecompressBytes(v1),
          throwsA(isA<SevenZipException>().having(
              (e) => e.toString(), 'message', contains('version 1'))));
    });

    test('bad headers throw', () {
      expect(() => zcmDecompressBytes(Uint8List.fromList([1, 2, 3, 4])),
          throwsA(isA<SevenZipException>()));
      final bad = Uint8List.fromList(packed)..[4] = 12; // level
      expect(() => zcmDecompressBytes(bad), throwsA(isA<SevenZipException>()));
      expect(() => zcmParseProps(Uint8List.fromList([1, 1, 0x80, 4, 0])),
          throwsA(isA<SevenZipException>()));
    });

    test('bad options are rejected', () {
      expect(() => zcmCompressBytes(text, const ZcmOptions(level: 0)),
          throwsA(isA<SevenZipException>()));
      expect(() => zcmCompressBytes(text, const ZcmOptions(segmentSize: 100)),
          throwsA(isA<SevenZipException>()));
    });
  });

  group('auto settings', () {
    const gib = 1 << 30;
    const desk16 = ZcmMachine(availableBytes: 5 * gib, cores: 16);
    const desk32 = ZcmMachine(availableBytes: 28 * gib, cores: 16);
    const phone = ZcmMachine(availableBytes: gib, cores: 8);

    test('usable memory keeps a quarter and 1.5 GiB free', () {
      for (final m in [desk16, desk32, phone]) {
        final u = zcmUsableBytes(m);
        expect(u <= m.availableBytes * 3 ~/ 4 || u == 64 << 20, isTrue);
        expect(u <= m.availableBytes - (3 << 29) || u == 64 << 20, isTrue);
      }
      expect(zcmUsableBytes(desk16), 5 * gib - (3 << 29));
      expect(zcmUsableBytes(desk32), 21 * gib);
      expect(zcmUsableBytes(phone), 64 << 20);
    });

    test('meminfo parsing', () {
      expect(
          zcmParseMemAvailable('MemTotal: 16000000 kB\n'
              'MemFree:  100 kB\nMemAvailable:    5242880 kB\n'),
          5 * gib);
      expect(zcmParseMemAvailable('MemTotal: 1 kB\n'), isNull);
      expect(zcmProbeMachine().cores >= 1, isTrue);
    });

    test('no time budget: normal level, one thread', () {
      final c = zcmAutoSelect(desk16, 50 << 20);
      expect(c.options.level, 4);
      expect(c.threads, 1);
      expect(c.estimatedBytes <= zcmUsableBytes(desk16), isTrue);
    });

    test('more time gives stronger levels', () {
      const size = 10 << 20;
      var last = 0;
      for (final t in [5.0, 60.0, 600.0, 6000.0]) {
        final c = zcmAutoSelect(desk16, size, timeBudgetSeconds: t);
        final strength = c.options.level * 2 + (c.options.lstm ? 1 : 0);
        expect(strength >= last, isTrue, reason: '$t s: $c');
        last = strength;
        expect(c.estimatedBytes <= zcmUsableBytes(desk16), isTrue);
      }
      final huge = zcmAutoSelect(desk32, size, timeBudgetSeconds: 1e7);
      expect(huge.options.level, 9);
      expect(huge.options.lstm, isTrue);
    });

    test('a tight budget uses parallel segments on big inputs', () {
      final c = zcmAutoSelect(desk16, 512 << 20, timeBudgetSeconds: 1000);
      expect(c.threads > 1, isTrue, reason: '$c');
      expect(c.options.segmentSize > 0, isTrue);
      expect(c.estimatedBytes <= zcmUsableBytes(desk16), isTrue);
      final serial = zcmAutoSelect(desk16, 512 << 20,
          timeBudgetSeconds: 1000, allowParallel: false);
      expect(serial.threads, 1);
    });

    test('a small machine gets a small budget', () {
      final c = zcmAutoSelect(phone, 200 << 20, timeBudgetSeconds: 1e6);
      expect(c.estimatedBytes <= zcmUsableBytes(phone) || c.options.memoryMiB == zcmMinMemoryMiB,
          isTrue, reason: '$c');
    });

    test('calibration returns a speed factor', () {
      final f = zcmCalibrate(sample: small, level: 1);
      expect(f > 0, isTrue);
    });
  });
}

