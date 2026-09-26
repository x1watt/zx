import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/format/archive_types.dart';
import 'package:zx/src/format/xz/xz.dart';
import 'package:zx/src/format/xz/xz_dec.dart';
import 'package:zx/src/format/xz/xz_enc.dart';
import 'package:zx/src/format/xz/xz_handler.dart';
import 'package:zx/src/io/streams.dart';

/// Deterministic x86-like data with call/jump opcodes and text runs.
Uint8List gen(int n, int seed) {
  var st = seed;
  int next() {
    st = (st * 1103515245 + 12345) & 0x7fffffff;
    return st >> 16;
  }

  const words = ['alpha ', 'beta ', 'gamma ', 'delta ', 'xz ', 'block\n'];
  final out = BytesBuilder();
  while (out.length < n) {
    final r = next();
    switch (r % 8) {
      case 0:
        out.addByte(0xe8);
        final v = (next() % 4000) - 2000;
        out.add([v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff]);
      case 1:
      case 2:
        out.add(words[next() % words.length].codeUnits);
      default:
        out.addByte(r & 0xff);
    }
  }
  return Uint8List.sublistView(out.toBytes(), 0, n);
}

bool _have(String exe, List<String> args) {
  try {
    return Process.runSync(exe, args).exitCode == 0;
  } on ProcessException {
    return false;
  }
}

final bool haveXz = _have('xz', ['--version']);
final bool have7z = File('/usr/bin/7z').existsSync();

Uint8List runXz(List<String> args, File input) {
  final r = Process.runSync('xz', [...args, '-c', input.path],
      stdoutEncoding: null);
  expect(r.exitCode, 0, reason: '${r.stderr}');
  return Uint8List.fromList(r.stdout as List<int>);
}

/// Decodes with XzDecoder (sequential); returns (result, stat, data).
(XzDecodeResult, XzStatInfo, Uint8List) decodeSeq(Uint8List xz) {
  final out = MemoryOutStream();
  final d = XzDecoder();
  final r = d.decode(MemoryInStream(xz), out);
  return (r, d.stat, Uint8List.fromList(out.toBytes()));
}

Uint8List encode(Uint8List data, void Function(XzProps p) setup) {
  final p = XzProps();
  setup(p);
  final out = MemoryOutStream();
  xzEncode(out, MemoryInStream(data), p);
  return Uint8List.fromList(out.toBytes());
}

void main() {
  late Directory tmp;
  final data = gen(150000, 1);
  final data2 = gen(70000, 7);

  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('zx_xz_test');
  });
  tearDownAll(() => tmp.deleteSync(recursive: true));

  File writeTmp(String name, List<int> bytes) =>
      File('${tmp.path}/$name')..writeAsBytesSync(bytes);

  group('xz container', () {
    test('varint round trip', () {
      final buf = Uint8List(16);
      for (final v in [0, 1, 127, 128, 300, 1 << 35, (1 << 62) + 5]) {
        final n = xzWriteVarInt(buf, 0, v);
        final (s, r) = xzReadVarInt(buf, 0, n);
        expect(s, n);
        expect(r, v);
      }
      // a non minimal encoding is an error
      final (s, _) = xzReadVarInt(Uint8List.fromList([0x80, 0x00]), 0, 2);
      expect(s, 0);
    });

    test('empty xz stream', () {
      final out = MemoryOutStream();
      xzEncodeEmpty(out);
      final (r, st, d) = decodeSeq(out.toBytes());
      expect(r, XzDecodeResult.ok);
      expect(d, isEmpty);
      expect(st.numStreams, 1);
      expect(st.numBlocks, 0);
    });
  });

  group('encode and decode (port only)', () {
    for (final entry in <String, void Function(XzProps)>{
      'default': (p) {},
      'level 0': (p) => p.lzma2Props.lzmaProps.level = 0,
      'no check': (p) => p.checkId = xzCheckNo,
      'crc64': (p) => p.checkId = xzCheckCrc64,
      'sha256': (p) => p.checkId = xzCheckSha256,
      'bcj': (p) => p.filterProps.id = xzIdX86,
      'delta 4': (p) => p.filterProps
        ..id = xzIdDelta
        ..delta = 4,
      'arm64 with ip': (p) => p.filterProps
        ..id = xzIdArm64
        ..ip = 4096
        ..ipDefined = true,
      'riscv': (p) => p.filterProps.id = xzIdRiscv,
      'blocks, one thread': (p) => p
        ..blockSize = 40000
        ..numTotalThreads = 1,
      'blocks, several threads (sizes in headers)': (p) => p
        ..blockSize = 40000
        ..numTotalThreads = 4
        ..filterProps.id = xzIdX86,
      'forced sizes in headers': (p) => p
        ..blockSize = 60000
        ..forceWriteSizesInHeader = 1,
      'solid': (p) => p.blockSize = xzPropsBlockSizeSolid,
    }.entries) {
      test(entry.key, () {
        final xz = encode(data, entry.value);
        final (r, st, d) = decodeSeq(xz);
        expect(r, XzDecodeResult.ok);
        expect(d, data);
        expect(st.inSize, xz.length);
      });
    }

    test('empty input', () {
      final xz = encode(Uint8List(0), (p) {});
      final (r, st, d) = decodeSeq(xz);
      expect(r, XzDecodeResult.ok);
      expect(d, isEmpty);
      expect(st.numBlocks, 1);
    });

    test('random access stream (GetStream)', () {
      final xz = encode(data, (p) => p
        ..blockSize = 30000
        ..numTotalThreads = 4);
      final a = XzArchive.open(MemoryInStream(xz))!;
      expect(a.numBlocks, 5);
      final s = a.getStream()!;
      expect(s.length, data.length);
      final buf = Uint8List(5000);
      for (final pos in [123456, 0, 29990, 149000]) {
        s.position = pos;
        final n = readFully(s, buf, 0, buf.length);
        final want = data.length - pos < 5000 ? data.length - pos : 5000;
        expect(n, want);
        expect(buf.sublist(0, n), data.sublist(pos, pos + n));
      }
    });
  });

  group('decode files made by xz', skip: haveXz ? false : 'xz not installed',
      () {
    late File input;
    late File input2;
    setUpAll(() {
      input = writeTmp('in.bin', data);
      input2 = writeTmp('in2.bin', data2);
    });

    for (final opts in [
      ['-0'],
      ['-6'],
      ['-9e'],
      ['--check=none'],
      ['--check=crc32'],
      ['--check=crc64'],
      ['--check=sha256'],
      ['--x86', '--lzma2'],
      ['--delta=dist=4', '--lzma2'],
      ['--arm', '--lzma2'],
      ['--armthumb', '--lzma2'],
      ['--arm64', '--lzma2'],
      ['--powerpc', '--lzma2'],
      ['--ia64', '--lzma2'],
      ['--sparc', '--lzma2'],
      ['--x86', '--delta=dist=2', '--lzma2=preset=1'],
      ['-T4', '--block-size=20000'],
    ]) {
      test(opts.join(' '), () {
        final xz = runXz(opts, input);
        final (r, st, d) = decodeSeq(xz);
        expect(r, XzDecodeResult.ok);
        expect(d, data);
        expect(st.inSize, xz.length);
        final a = XzArchive.open(MemoryInStream(xz))!;
        expect(a.size, data.length);
        expect(a.packSize, xz.length);
        final out = MemoryOutStream();
        expect(a.extract(out), OperationResult.ok);
        expect(out.toBytes(), data);
      });
    }

    test('multi-stream with padding', () {
      final a = runXz(['-1'], input);
      final b = runXz(['--check=sha256'], input2);
      final xz = BytesBuilder()
        ..add(a)
        ..add(Uint8List(8))
        ..add(b)
        ..add(Uint8List(4));
      final bytes = xz.toBytes();
      final (r, st, d) = decodeSeq(bytes);
      expect(r, XzDecodeResult.ok);
      expect(d, [...data, ...data2]);
      expect(st.numStreams, 2);
      final arc = XzArchive.open(MemoryInStream(bytes))!;
      expect(arc.numStreams, 2);
      expect(arc.size, data.length + data2.length);
      expect(arc.method, 'LZMA2:20 CRC64 SHA256');
    });

    test('errors', () {
      final xz = runXz(['-1'], input);
      // data after the end
      var (r, st, _) = decodeSeq(Uint8List.fromList([...xz, 1, 2, 3]));
      expect(r, XzDecodeResult.ok);
      expect(st.dataAfterEnd, isTrue);
      // padding that is not a multiple of 4
      final d2 = XzDecoder();
      d2.decode(MemoryInStream(Uint8List.fromList([...xz, 0, 0, 0])),
          NullOutStream());
      expect(d2.mainDecodeSRes, szErrorInputEof);
      // truncated
      final a = XzArchive.open(MemoryInStream(xz.sublist(0, 20000)))!;
      expect(a.test(), OperationResult.unexpectedEnd);
      // corrupted data
      final bad = Uint8List.fromList(xz);
      bad[5000] ^= 0x55;
      final b = XzArchive.open(MemoryInStream(bad))!;
      expect(b.test(),
          anyOf(OperationResult.dataError, OperationResult.crcError));
      // not xz
      expect(XzArchive.open(MemoryInStream(data)), isNull);
    });

    test('ports produce what xz accepts', () {
      for (final setup in <void Function(XzProps)>[
        (p) {},
        (p) => p.checkId = xzCheckSha256,
        (p) => p.filterProps.id = xzIdX86,
        (p) => p
          ..blockSize = 40000
          ..numTotalThreads = 4,
      ]) {
        final xz = writeTmp('p.xz', encode(data, setup));
        final r = Process.runSync('xz', ['-dc', xz.path], stdoutEncoding: null);
        expect(r.exitCode, 0, reason: '${r.stderr}');
        expect(r.stdout, data);
      }
    });
  });

  group('7-Zip interop', skip: have7z ? false : 'no /usr/bin/7z', () {
    late File input;
    setUpAll(() => input = writeTmp('in7.bin', data));

    Map<String, String> list7z(String path) {
      final r = Process.runSync('/usr/bin/7z', ['l', '-slt', path]);
      final m = <String, String>{};
      for (final line in (r.stdout as String).split('\n')) {
        final i = line.indexOf(' = ');
        if (i > 0) m[line.substring(0, i)] = line.substring(i + 3);
      }
      return m;
    }

    for (final props in [
      <String>[],
      ['-mx=1'],
      ['-mx=9'],
      ['-mf=BCJ'],
      ['-mf=Delta:4'],
      ['-mcrc=0'],
      ['-mcrc=8'],
      ['-mcrc=32'],
      ['-ms=on'],
      ['-mmt=1'],
      ['-mmt=4', '-ms=40k'],
      ['-m0=LZMA2:d=64k:c=50k', '-mmt=3'],
    ]) {
      test('create ${props.join(' ')}: same bytes as 7z a -txz', () {
        final ref = File('${tmp.path}/ref.xz');
        if (ref.existsSync()) ref.deleteSync();
        final r = Process.runSync(
            '/usr/bin/7z', ['a', '-txz', ...props, ref.path, input.path]);
        expect(r.exitCode, 0, reason: '${r.stdout}');

        final out = MemoryOutStream();
        XzArchive.create(MemoryInStream(data), out, data.length, properties: [
          for (final p in props)
            if (p.contains('='))
              MapEntry(p.substring(2, p.indexOf('=')),
                  p.substring(p.indexOf('=') + 1))
            else
              MapEntry(p.substring(2), ''),
        ]);
        expect(out.toBytes(), ref.readAsBytesSync());

        // and the listing matches
        final ours = XzArchive.open(MemoryInStream(out.toBytes()))!;
        final l = list7z(ref.path);
        expect(ours.method, l['Method']);
        expect('${ours.size}', l['Size']);
        expect('${ours.packSize}', l['Packed Size']);
        expect(ours.test(), OperationResult.ok);
      });
    }

    test('7z accepts the port output', () {
      final xz = writeTmp('t.xz', encode(data, (p) => p
        ..checkId = xzCheckSha256
        ..filterProps.id = xzIdX86
        ..blockSize = 50000
        ..numTotalThreads = 2));
      final r = Process.runSync('/usr/bin/7z', ['t', xz.path]);
      expect(r.exitCode, 0, reason: '${r.stdout}');
      expect(r.stdout as String, contains('Everything is Ok'));
    });
  });
}
