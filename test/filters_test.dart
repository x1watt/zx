import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/codec/codec.dart';
import 'package:zx/src/codec/filters/bcj2.dart';
import 'package:zx/src/codec/filters/filters.dart';
import 'package:zx/src/crypto/sha256.dart';
import 'package:zx/src/io/streams.dart';

/// Deterministic x86-like test data with many e8/e9/0f8x markers. The
/// expected hashes below come from the LZMA SDK C code on the same input.
Uint8List gen(int n, int seed) {
  var st = seed;
  int next() {
    st = (st * 1103515245 + 12345) & 0x7fffffff;
    return st >> 16;
  }

  final out = BytesBuilder();
  void le32(int v) {
    final b = ByteData(4)..setInt32(0, v, Endian.little);
    out.add(b.buffer.asUint8List());
  }

  while (out.length < n) {
    final r = next();
    final k = r % 10;
    if (k == 0) {
      out.addByte(0xe8);
      le32((next() % 4000) - 2000);
    } else if (k == 1) {
      out.add([0x0f, 0x80 + next() % 16]);
      le32((next() % 65536) - 32768);
    } else if (k == 2) {
      out.addByte(0xe9);
      for (var i = 0; i < 4; i++) {
        out.addByte(next() & 0xff);
      }
    } else {
      out.addByte(r & 0xff);
    }
  }
  return Uint8List.sublistView(out.toBytes(), 0, n);
}

String hex(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

String sha(Uint8List b) => hex(Sha256.hash(b));

/// Returns at most [chunk] bytes per read, to exercise the buffering.
class ChunkIn implements InStream {
  final InStream base;
  final int chunk;
  ChunkIn(this.base, this.chunk);
  @override
  int read(Uint8List buf, int off, int len) =>
      base.read(buf, off, len < chunk ? len : chunk);
}

Uint8List drain(InStream s, [int bufSize = 997]) {
  final out = MemoryOutStream();
  final buf = Uint8List(bufSize);
  for (;;) {
    final n = s.read(buf, 0, buf.length);
    if (n == 0) break;
    out.write(buf, 0, n);
  }
  return Uint8List.fromList(out.toBytes());
}

final Map<int, DecoderFactory> reg = () {
  final r = <int, DecoderFactory>{};
  registerFilterCodecs(r);
  return r;
}();

Uint8List decodeWith(int id, Uint8List props, Uint8List packed, int? size,
    [int chunk = 1 << 20]) {
  return drain(reg[id]!(props, [ChunkIn(MemoryInStream(packed), chunk)], size,
      const CoderContext()));
}

void main() {
  final data = gen(70001, 7);

  test('generator matches the reference input', () {
    expect(sha(data),
        '93430c0326db09724d7ce0b4efd9a3a6a786c736520b22e85768b16ef308d062');
  });

  // (method, -m props, SHA-256 of the SDK encoder output)
  final cases = <(String, int, Map<String, String>, String)>[
    (
      'BCJ',
      MethodId.bcj,
      {},
      '40ee99386b3bf8664cd80c85241d202e4a8696aae24c6f307911ff813607b6f9'
    ),
    (
      'ARM64',
      MethodId.arm64,
      {},
      'a968f5bcba3e981c31fa965653f5f380e6e52f296b8998fcc14b8fd5d1846471'
    ),
    (
      'ARM64 offset',
      MethodId.arm64,
      {'offset': '4096'},
      'e1d749039093519104e17783e411aa7ab934cbcbb52493e72941b7a145a8b80c'
    ),
    (
      'ARM',
      MethodId.arm,
      {},
      'f3f7ccd8ee66bd9cf3664dbea700935d57b31ead9a8734a88d35c94919721fd6'
    ),
    (
      'ARMT',
      MethodId.armt,
      {},
      '81405f30f860c43ef0110b3dffb5e8ee8aaddd278d0fb803b64f7eee62a00847'
    ),
    (
      'PPC',
      MethodId.ppc,
      {},
      '30e4360bf87c6d6ab5347b30e4031307ddfa47c5335a4bae43b5f091e3a92ac2'
    ),
    (
      'SPARC',
      MethodId.sparc,
      {},
      'bc7d5cf740a1f97813a537852d6f3870e931d5181bf79fec9d0e2d614e3ca539'
    ),
    (
      'IA64',
      MethodId.ia64,
      {},
      'dd36ca7302ea314893a2e0fbad00aed1b835f299933ad8d0e144f83ca2793e94'
    ),
    (
      'RISCV',
      MethodId.riscv,
      {},
      '8c0620626f29925bf7c987fc4d27a396bbb9afd43ec8085d94a06eb4b4daca12'
    ),
    (
      'RISCV offset',
      MethodId.riscv,
      {'': '6'},
      'f22f7686baae81a46a2058778f64e824ae1b33871780c30c199250547824f16f'
    ),
    (
      'SWAP2',
      MethodId.swap2,
      {},
      'c6b62ac6cd73b724d78015163e27979fd9c293eaa13edaff8cf0071c25e0169f'
    ),
    (
      'SWAP4',
      MethodId.swap4,
      {},
      '3e6e3774933733e70f91807db45be4d3ed59b3ff5d7d68e7232a370a5bf67c76'
    ),
    (
      'Delta:1',
      MethodId.delta,
      {},
      'f3170c64fcd38e363e38d18dda310b637783886a1d7437ae3e183f3999ed8a73'
    ),
    (
      'Delta:4',
      MethodId.delta,
      {'': '4'},
      'a238508a5efa16b375f512a978c07a4fe0198731dbf6cc51ff608e60b4c5144a'
    ),
    (
      'Delta:256',
      MethodId.delta,
      {'': '256'},
      'a56cce0e249c76da3919892416a9a1203a17eed04e9e8ec54ed63ea4d6ff5832'
    ),
  ];

  for (final (name, id, props, expected) in cases) {
    test('$name matches the SDK and round trips', () {
      final fc = createFilterEncoder(id, props)!;
      for (final chunk in [1 << 20, 13, 1]) {
        final enc = drain(fc.encoder(ChunkIn(MemoryInStream(data), chunk)));
        expect(sha(enc), expected, reason: 'read chunk $chunk');
        final dec = decodeWith(id, fc.props, enc, data.length, chunk);
        expect(dec, data, reason: 'read chunk $chunk');
        // Unknown output size works too.
        expect(decodeWith(id, fc.props, enc, null, chunk), data);
      }
      // Odd lengths near the alignment and look ahead limits.
      for (var n = 0; n < 40; n++) {
        final small = Uint8List.sublistView(data, 1000, 1000 + n);
        final enc = drain(fc.encoder(MemoryInStream(small)));
        expect(enc.length, n);
        expect(decodeWith(id, fc.props, enc, n), small, reason: 'length $n');
      }
    });
  }

  test('filter properties', () {
    expect(createFilterEncoder(MethodId.delta, {'': '4'})!.props, [3]);
    expect(createFilterEncoder(MethodId.delta, {})!.props, [0]);
    expect(createFilterEncoder(MethodId.bcj, {})!.props, isEmpty);
    expect(createFilterEncoder(MethodId.arm64, {})!.props, isEmpty);
    expect(createFilterEncoder(MethodId.arm64, {'offset': '4096'})!.props,
        [0, 0x10, 0, 0]);
    expect(() => createFilterEncoder(MethodId.arm64, {'': '2'}),
        throwsA(isA<SevenZipException>()));
    expect(() => createFilterEncoder(MethodId.delta, {'': '257'}),
        throwsA(isA<SevenZipException>()));
    expect(() => createFilterEncoder(MethodId.bcj, {'': '1'}),
        throwsA(isA<SevenZipException>()));
    expect(createFilterEncoder(MethodId.bcj, {'mt': '4'}), isNotNull);
    expect(createFilterEncoder(MethodId.lzma, {}), isNull);
    // Decoders reject properties they do not support (7zDecode.cpp).
    expect(
        () => reg[MethodId.bcj]!(
            Uint8List(1), [MemoryInStream(data)], null, const CoderContext()),
        throwsA(isA<SevenZipException>()
            .having((e) => e.kind, 'kind', SevenZipError.unsupportedMethod)));
    expect(
        () => reg[MethodId.delta]!(
            Uint8List(0), [MemoryInStream(data)], null, const CoderContext()),
        throwsA(isA<SevenZipException>()));
  });

  group('BCJ2', () {
    const noSub = {
      'main': (
        43965,
        '1a6b62432ee03e88214dca0922b11fd9667682adbe12faf40e5d08ebc97e5e93'
      ),
      'call': (
        12388,
        '073348d49fff62f27930e4f6adafa13ea560a1662cf5fe30b1000ed88cbf4f4e'
      ),
      'jump': (
        13648,
        'fa93a48c148a24a14e5a797fc352b30066237214a5a7baea427f781840a3be7d'
      ),
      'rc': (
        526,
        '9912d32fb7ceeb3bf7251eae6e1ddc5b45b8cb0648091ccdf46a2541ab82155d'
      ),
    };
    const withSub = {
      'main': (
        51821,
        'abf821fadb7967ac293f17927937c69e98cc7e718b82b896728c5c0a5de1ec46'
      ),
      'call': (
        11988,
        'db9d5a2c0c44a98f46cc7cb7d507ef77dd28b4bff4611a6983078a9f76d325cb'
      ),
      'jump': (
        6192,
        '9d65fe4b60475c6d2d37d2c05883cd8247857d8457f560f58331244c774d4f7b'
      ),
      'rc': (
        587,
        '58186c3528432a145b07d92325dbca8aa4efe2253e156a7a71785ad5ff43ad44'
      ),
    };

    List<Uint8List> encode(Uint8List input, int chunk, List<int>? subs) {
      final outs = List.generate(4, (_) => MemoryOutStream());
      final read = bcj2Encode(ChunkIn(MemoryInStream(input), chunk), outs[0],
          outs[1], outs[2], outs[3],
          subStreamSize:
              subs == null ? null : (i) => i < subs.length ? subs[i] : null);
      expect(read, input.length);
      return [for (final o in outs) Uint8List.fromList(o.toBytes())];
    }

    Uint8List decode(List<Uint8List> s, int? size, int chunk) {
      return drain(Bcj2Decoder(
          [for (final p in s) ChunkIn(MemoryInStream(p), chunk)],
          outSize: size, bufSize: 64));
    }

    for (final (label, subs, expected) in [
      ('one block', null, noSub),
      ('sub streams', [30000, 1, 40000], withSub),
    ]) {
      test('encoder matches the SDK ($label)', () {
        for (final chunk in [1 << 18, 4093, 1]) {
          final s = encode(data, chunk, subs);
          const names = ['main', 'call', 'jump', 'rc'];
          for (var i = 0; i < 4; i++) {
            expect(s[i].length, expected[names[i]]!.$1);
            expect(sha(s[i]), expected[names[i]]!.$2,
                reason: '${names[i]} chunk $chunk');
          }
          expect(decode(s, data.length, 7), data);
          expect(decode(s, null, 1000), data);
        }
      });
    }

    test('registry decoder and small inputs', () {
      for (var n = 0; n < 30; n++) {
        final small = Uint8List.sublistView(data, 2000, 2000 + n);
        final s = encode(small, 3, null);
        final out = drain(reg[MethodId.bcj2]!(Uint8List(0),
            [for (final p in s) MemoryInStream(p)], n, const CoderContext()));
        expect(out, small, reason: 'length $n');
      }
    });

    test('corrupt RC stream is a data error', () {
      final s = encode(data, 1 << 18, null);
      s[3] = Uint8List.fromList([1, ...s[3].skip(1)]); // first byte must be 0
      expect(
          () => decode(s, data.length, 100), throwsA(isA<SevenZipException>()));
    });
  });
}
