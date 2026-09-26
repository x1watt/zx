// Tests for lib/src/codec/lzma: byte identity with the LZMA SDK (golden
// sizes and CRCs produced by a C build of LZMA SDK 26.01 on the inputs of
// test/lzma_test_data.dart, see tool/lzma_golden.dart), round trips,
// interop with xz, the method property parser and error handling.

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/codec/codec.dart';
import 'package:zx/src/codec/lzma/lzma2_dec.dart';
import 'package:zx/src/codec/lzma/lzma_coder.dart';
import 'package:zx/src/codec/lzma/lzma_dec.dart';
import 'package:zx/src/codec/lzma/lzma_enc.dart';
import 'package:zx/src/io/streams.dart';
import 'package:zx/src/util/crc.dart';

import 'lzma_test_data.dart';

// (packed size, CRC-32 of the packed stream) per input; 'props' holds the
// coder properties as an integer (5 bytes for LZMA, 1 byte for LZMA2).
// Keys are "<method>|<7-Zip method properties>".
const _golden = <String, Map<String, (int, int)>>{
  'lzma|x0': {
    'empty': (5, 0xc622f71d),
    'one': (6, 0xff81b4d9),
    'zeros': (112, 0xf722d262),
    'text': (152017, 0x813ec356),
    'binary': (190836, 0xfbf83fff),
    'random': (202847, 0xf55d1d7c),
    'mixed': (243889, 0x642c2129),
    'props': (0, 0x5d00000100),
  },
  'lzma|x1': {
    'empty': (5, 0xc622f71d),
    'one': (6, 0xff81b4d9),
    'zeros': (112, 0xf722d262),
    'text': (152164, 0x8f18bc70),
    'binary': (190444, 0x9609faa6),
    'random': (202895, 0xe92c2865),
    'mixed': (243824, 0x6c6f607e),
    'props': (0, 0x5d00000400),
  },
  'lzma|x5:d=4m': {
    'empty': (5, 0xc622f71d),
    'one': (6, 0xff81b4d9),
    'zeros': (112, 0xf722d262),
    'text': (112229, 0xb336c0a9),
    'binary': (189277, 0xf6993a9a),
    'random': (202771, 0x72b619ed),
    'mixed': (227690, 0x6b1c2018),
    'props': (0, 0x5d00004000),
  },
  'lzma|x9:d=1m': {
    'empty': (5, 0xc622f71d),
    'one': (6, 0xff81b4d9),
    'zeros': (112, 0xf722d262),
    'text': (112128, 0xa106c73c),
    'binary': (187851, 0xba37ea8d),
    'random': (202771, 0x72b619ed),
    'mixed': (227197, 0x3864ea1f),
    'props': (0, 0x5d00001000),
  },
  'lzma|x5:a=0:mf=hc4:d=256k': {
    'empty': (5, 0xc622f71d),
    'one': (6, 0xff81b4d9),
    'zeros': (112, 0xf722d262),
    'text': (155136, 0x7b7cbd10),
    'binary': (190522, 0xae5d29af),
    'random': (202895, 0xe92c2865),
    'mixed': (244992, 0x04fd9091),
    'props': (0, 0x5d00000400),
  },
  'lzma|x5:lc=0:lp=2:pb=0:d=64k': {
    'empty': (5, 0xc622f71d),
    'one': (6, 0xff81b4d9),
    'zeros': (94, 0xe2008558),
    'text': (118242, 0xf31c38bc),
    'binary': (189780, 0x8bd3a67e),
    'random': (202738, 0x702db725),
    'mixed': (229294, 0xa9157d0e),
    'props': (0, 0x1200000100),
  },
  'lzma|x7:fb=273:mc=100:mf=bt2:d=128k': {
    'empty': (5, 0xc622f71d),
    'one': (6, 0xff81b4d9),
    'zeros': (112, 0xf722d262),
    'text': (115406, 0xea845e0b),
    'binary': (186905, 0xa83b84f9),
    'random': (202769, 0xd14e5d7f),
    'mixed': (227402, 0x9e670f48),
    'props': (0, 0x5d00000200),
  },
  'lzma|x5:mf=bt3:eos:d=512k': {
    'empty': (10, 0xa48dbe7f),
    'one': (11, 0x438eca63),
    'zeros': (118, 0x8c6b678d),
    'text': (112292, 0x48ee360b),
    'binary': (189285, 0x889f2539),
    'random': (202778, 0xfdc1da9e),
    'mixed': (227695, 0xc0242e55),
    'props': (0, 0x5d00000800),
  },
  'lzma|x5:mf=bt5:d=64k': {
    'empty': (5, 0xc622f71d),
    'one': (6, 0xff81b4d9),
    'zeros': (112, 0xf722d262),
    'text': (117987, 0x241b7417),
    'binary': (189991, 0xc92e8e58),
    'random': (202771, 0x72b619ed),
    'mixed': (229312, 0xe26f1ea3),
    'props': (0, 0x5d00000100),
  },
  'lzma|x3:mf=hc5:d=64k': {
    'empty': (5, 0xc622f71d),
    'one': (6, 0xff81b4d9),
    'zeros': (112, 0xf722d262),
    'text': (152017, 0x813ec356),
    'binary': (190836, 0xfbf83fff),
    'random': (202847, 0xf55d1d7c),
    'mixed': (243889, 0x642c2129),
    'props': (0, 0x5d00000100),
  },
  'lzma2|x5:d=1m': {
    'empty': (1, 0xd202ef8d),
    'one': (5, 0x1220a0e9),
    'zeros': (119, 0xcafd4440),
    'text': (112268, 0x4a12b485),
    'binary': (189318, 0xb79e2ad0),
    'random': (200016, 0x47b6d874),
    'mixed': (226364, 0x89200d29),
    'props': (0, 0x10),
  },
  'lzma2|x1:c=100000b:d=64k': {
    'empty': (1, 0xd202ef8d),
    'one': (5, 0x1220a0e9),
    'zeros': (271, 0x2bfaa6c1),
    'text': (154778, 0x0a2af6c3),
    'binary': (192710, 0xaa2fe99e),
    'random': (200019, 0x917d52ce),
    'mixed': (243726, 0xa46c9a14),
    'props': (0, 0x08),
  },
  'lzma2|x9:d=1m:lc=4:lp=0:pb=0': {
    'empty': (1, 0xd202ef8d),
    'one': (5, 0x1220a0e9),
    'zeros': (101, 0xfcdec578),
    'text': (112081, 0x3fc6d8e0),
    'binary': (187722, 0x283f3c0b),
    'random': (200016, 0x68d2eb68),
    'mixed': (225637, 0xac8775d9),
    'props': (0, 0x10),
  },
  'lzma2|x5:mt=4:c=200000b:d=256k': {
    'empty': (1, 0xd202ef8d),
    'one': (5, 0x1220a0e9),
    'zeros': (195, 0x1fc7c6a1),
    'text': (119413, 0xac330f14),
    'binary': (190567, 0x83184fdd),
    'random': (200016, 0x47b6d874),
    'mixed': (228282, 0x621be1d0),
    'props': (0, 0x0c),
  },
};

int _crc(Uint8List b) => (Crc32()..update(b)).value;

Uint8List _encode(Compressor c, Uint8List data) {
  final out = MemoryOutStream();
  final n = c.encode(MemoryInStream(data), out);
  expect(n, data.length);
  return Uint8List.fromList(out.toBytes());
}

Uint8List _decodeLzma(Uint8List props, Uint8List packed, int? size) => readAll(
    lzmaDecoder(props, [MemoryInStream(packed)], size, const CoderContext()));

Uint8List _decodeLzma2(Uint8List props, Uint8List packed, int? size) => readAll(
    lzma2Decoder(props, [MemoryInStream(packed)], size, const CoderContext()));

int _propsInt(Uint8List p) {
  var v = 0;
  for (final b in p) {
    v = (v << 8) | b;
  }
  return v;
}

/// An input stream that returns at most [chunk] bytes per read.
class _Trickle implements InStream {
  final Uint8List data;
  final int chunk;
  int pos = 0;
  _Trickle(this.data, this.chunk);
  @override
  int read(Uint8List buf, int off, int len) {
    var n = data.length - pos;
    if (n > len) n = len;
    if (n > chunk) n = chunk;
    buf.setRange(off, off + n, data, pos);
    pos += n;
    return n;
  }
}

bool _haveXz() {
  try {
    return Process.runSync('xz', ['--version']).exitCode == 0;
  } catch (_) {
    return false;
  }
}

void main() {
  final inputs = goldenInputs();

  group('byte identity with the SDK', () {
    _golden.forEach((key, expected) {
      final sep = key.indexOf('|');
      final method = key.substring(0, sep);
      final methodProps = key.substring(sep + 1);
      test(key, () {
        final Compressor c = method == 'lzma'
            ? LzmaCompressor.fromString(methodProps)
            : Lzma2Compressor.fromString(methodProps);
        expect(_propsInt(c.props), expected['props']!.$2, reason: 'props');
        for (final name in inputs.keys) {
          final data = inputs[name]!;
          final packed = _encode(c, data);
          final exp = expected[name]!;
          expect((packed.length, _crc(packed)), exp, reason: name);
          final unpacked = method == 'lzma'
              ? _decodeLzma(c.props, packed, data.length)
              : _decodeLzma2(c.props, packed, data.length);
          expect(unpacked, data, reason: 'round trip $name');
        }
      });
    });
  });

  group('LZMA', () {
    test('end marker, unknown size, small reads', () {
      final data = genText(200000, 42);
      final c = LzmaCompressor.fromString('x5:d=64k:eos');
      expect(c.writeEndMark, isTrue);
      final packed = _encode(c, data);
      final dec = LzmaDecoderStream(c.props, _Trickle(packed, 7));
      final out = MemoryOutStream();
      final buf = Uint8List(1000);
      for (;;) {
        final n = dec.read(buf, 0, 1 + (out.length % 997));
        if (n == 0) break;
        out.write(buf, 0, n);
      }
      expect(out.toBytes(), data);
      expect(dec.finishedWithMark, isTrue);
      expect(dec.inProcessed, packed.length);
    });

    test('end marker with known size', () {
      final data = genBinary(50000, 5);
      final c = LzmaCompressor.fromString('x1:eos');
      final packed = _encode(c, data);
      expect(_decodeLzma(c.props, packed, data.length), data);
    });

    test('small dictionary buffer wraps', () {
      // A 4 KiB dictionary with unknown size: the decoder buffer wraps
      // many times.
      final data = genText(300000, 3);
      final c = LzmaCompressor.fromString('x5:d=4k:eos');
      final packed = _encode(c, data);
      expect(_decodeLzma(c.props, packed, null), data);
    });

    test('one call interfaces', () {
      final data = genBinary(100000, 1);
      final r = lzmaEncode(data, LzmaEncProps()..dictSize = 1 << 16);
      final dest = Uint8List(data.length);
      final d = lzmaDecode(dest, r.data, r.props, lzmaFinishEnd);
      expect(d.res, szOk);
      expect(d.destLen, data.length);
      expect(dest, data);
      // Direct input mode (LzmaEnc_MemEncode) gives the stream mode output
      // when the data size is known.
      final c = LzmaCompressor(LzmaEncProps()..dictSize = 1 << 16)
        ..expectedDataSize = data.length;
      expect(_encode(c, data), r.data);
    });

    test('corrupt and truncated data', () {
      final data = genText(100000, 8);
      final c = LzmaCompressor.fromString('d=64k');
      final packed = _encode(c, data);
      final truncated = Uint8List.sublistView(packed, 0, packed.length - 20);
      expect(
          () => _decodeLzma(c.props, truncated, data.length),
          throwsA(isA<SevenZipException>()
              .having((e) => e.kind, 'kind', SevenZipError.unexpectedEnd)));
      final bad = Uint8List.fromList(packed);
      for (var i = 100; i < bad.length; i += 97) {
        bad[i] ^= 0x55;
      }
      expect(() => _decodeLzma(c.props, bad, data.length),
          throwsA(isA<SevenZipException>()));
      // Declared size shorter than the stream.
      expect(() => _decodeLzma(c.props, packed, data.length - 1),
          throwsA(isA<SevenZipException>()));
      expect(
          () => lzmaDecoder(Uint8List.fromList([225, 0, 0, 1, 0]),
              [MemoryInStream(packed)], null, const CoderContext()),
          throwsA(isA<SevenZipException>()));
    });
  });

  group('LZMA2', () {
    test('multi block path equals the one block path per block', () {
      final data = genText(500000, 4);
      final c = Lzma2Compressor.fromString('x1:c=64k:mt=4:d=64k');
      expect(c.normalizedProps.numBlockThreadsReduced, greaterThan(1));
      final packed = _encode(c, data);
      expect(_decodeLzma2(c.props, packed, data.length), data);
      expect(_decodeLzma2(c.props, packed, null), data);
    });

    test('raw decoder with a dictionary size, unused input', () {
      final data = genBinary(120000, 2);
      final c = Lzma2Compressor.fromString('x5:d=64k');
      final packed = _encode(c, data);
      final withTail = Uint8List.fromList([...packed, 1, 2, 3, 4]);
      final dec = Lzma2DecoderStream.withDictSize(
          lzma2DictSizeFromProp(c.props[0]), MemoryInStream(withTail));
      expect(readAll(dec), data);
      expect(dec.inProcessed, packed.length);
      expect(dec.unusedInput, [1, 2, 3, 4]);
    });

    test('dictionary property', () {
      expect(lzma2PropForDictSize(1 << 20), 16);
      expect(lzma2PropForDictSize(3 << 20), 19);
      expect(lzma2PropForDictSize(0xFFFFFFFF), 40);
      expect(Lzma2Compressor.fromString('d=64m').props, [0x1C]);
    });

    test('truncated and corrupt data', () {
      final data = genText(100000, 8);
      final c = Lzma2Compressor.fromString('d=64k');
      final packed = _encode(c, data);
      expect(
          () => _decodeLzma2(c.props,
              Uint8List.sublistView(packed, 0, packed.length - 1), null),
          throwsA(isA<SevenZipException>()
              .having((e) => e.kind, 'kind', SevenZipError.unexpectedEnd)));
      final bad = Uint8List.fromList(packed)..[0] = 0x03;
      expect(() => _decodeLzma2(c.props, bad, null),
          throwsA(isA<SevenZipException>()));
    });
  });

  group('method properties', () {
    test('LZMA names and values', () {
      final p = lzmaPropsFromCoderProps(parseMethodProps(
          'd=64m:fb=64:mc=48:lc=4:lp=0:pb=1:a=1:mf=bt4:eos:x7'));
      expect(p.dictSize, 64 << 20);
      expect(p.fb, 64);
      expect(p.mc, 48);
      expect(p.lc, 4);
      expect(p.lp, 0);
      expect(p.pb, 1);
      expect(p.algo, 1);
      expect(p.btMode, 1);
      expect(p.numHashBytes, 4);
      expect(p.writeEndMark, isTrue);
      expect(p.level, 7);
      expect(
          lzmaPropsFromCoderProps(parseMethodProps('d24')).dictSize, 1 << 24);
      expect(lzmaPropsFromCoderProps(parseMethodProps('24')).dictSize, 1 << 24);
      expect(lzmaPropsFromCoderProps(parseMethodProps('d=1536k')).dictSize,
          1536 << 10);
      expect(lzmaPropsFromCoderProps(parseMethodProps('d=4g')).dictSize,
          0xFFFFFFFF);
      final hc = lzmaPropsFromCoderProps(parseMethodProps('mf=HC5:eos=off'));
      expect(hc.btMode, 0);
      expect(hc.numHashBytes, 5);
      expect(hc.writeEndMark, isFalse);
    });

    test('LZMA2 names', () {
      final p = lzma2PropsFromCoderProps(parseMethodProps('c=16m:mt=4:d=1m'));
      expect(p.blockSize, 16 << 20);
      expect(p.numTotalThreads, 4);
      expect(p.lzmaProps.dictSize, 1 << 20);
    });

    test('invalid', () {
      for (final s in ['mf=bt6', 'mf=hc3', 'zz=1', 'fb=abc', 'd=5q', 'eos=2']) {
        expect(() => lzmaPropsFromCoderProps(parseMethodProps(s)),
            throwsA(isA<SevenZipException>()),
            reason: s);
      }
      // LZMA does not take a block size, LZMA2 does not take eos.
      expect(() => lzmaPropsFromCoderProps(parseMethodProps('c=1m')),
          throwsA(isA<SevenZipException>()));
      expect(() => lzma2PropsFromCoderProps(parseMethodProps('eos')),
          throwsA(isA<SevenZipException>()));
      expect(() => LzmaCompressor.fromString('lc=9'),
          throwsA(isA<SevenZipException>()));
      expect(() => Lzma2Compressor.fromString('lc=4:lp=1'),
          throwsA(isA<SevenZipException>()));
    });
  });

  group('registry', () {
    test('registerLzmaCodecs', () {
      final reg = <int, DecoderFactory>{};
      registerLzmaCodecs(reg);
      expect(reg.keys, containsAll([MethodId.lzma, MethodId.lzma2]));
    });
  });

  group('xz interop', skip: _haveXz() ? false : 'xz not installed', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('zx_lzma_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('xz --format=lzma to Dart', () {
      final data = genText(400000, 12);
      final f = File('${tmp.path}/a');
      f.writeAsBytesSync(data);
      final r = Process.runSync('xz', ['-k', '-6', '--format=lzma', f.path]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      final lz = File('${f.path}.lzma').readAsBytesSync();
      final props = Uint8List.sublistView(lz, 0, 5);
      final size = getUint64LE(lz, 5);
      final body = Uint8List.sublistView(lz, 13);
      // xz writes an unknown size and an end marker.
      expect(size, 0xFFFFFFFFFFFFFFFF.toSigned(64));
      expect(_decodeLzma(props, body, null), data);
    });

    test('Dart LZMA to xz -d --format=lzma', () {
      final data = genBinary(300000, 13);
      for (final eos in [false, true]) {
        final c = LzmaCompressor.fromString('x5:d=1m${eos ? ':eos' : ''}');
        final packed = _encode(c, data);
        final header = Uint8List(13)..setRange(0, 5, c.props);
        setUint64LE(header, 5, eos ? -1 : data.length);
        final f = File('${tmp.path}/b.lzma');
        f.writeAsBytesSync([...header, ...packed]);
        final r = Process.runSync('xz', ['-d', '-c', '--format=lzma', f.path],
            stdoutEncoding: null);
        expect(r.exitCode, 0, reason: '${r.stderr}');
        expect(r.stdout as List<int>, data);
      }
    });

    test('xz --format=raw --lzma2 to Dart', () {
      final data = genBinary(500000, 14);
      final f = File('${tmp.path}/c');
      f.writeAsBytesSync(data);
      final r = Process.runSync(
          'xz', ['-c', '--format=raw', '--lzma2=preset=6,dict=1MiB', f.path],
          stdoutEncoding: null);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      final packed = Uint8List.fromList(r.stdout as List<int>);
      final dec =
          Lzma2DecoderStream.withDictSize(1 << 20, MemoryInStream(packed));
      expect(readAll(dec), data);
      expect(
          _decodeLzma2(Uint8List.fromList([lzma2PropForDictSize(1 << 20)]),
              packed, data.length),
          data);
    });

    test('Dart LZMA2 to xz -d --format=raw', () {
      final data = genText(600000, 15);
      for (final m in ['x5:d=1m', 'x1:d=1m:c=200000b:mt=4']) {
        final c = Lzma2Compressor.fromString(m);
        final packed = _encode(c, data);
        final f = File('${tmp.path}/d.raw');
        f.writeAsBytesSync(packed);
        final r = Process.runSync(
            'xz', ['-d', '-c', '--format=raw', '--lzma2=dict=1MiB', f.path],
            stdoutEncoding: null);
        expect(r.exitCode, 0, reason: '${r.stderr}');
        expect(r.stdout as List<int>, data, reason: m);
      }
    });
  });
}
