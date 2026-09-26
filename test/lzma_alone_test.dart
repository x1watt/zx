import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/format/lzma_alone.dart';
import 'package:zx/src/format/archive_types.dart';
import 'package:zx/src/io/streams.dart';

/// Deterministic x86-like data with call opcodes and text runs.
Uint8List gen(int n, int seed) {
  var st = seed;
  int next() {
    st = (st * 1103515245 + 12345) & 0x7fffffff;
    return st >> 16;
  }

  const words = ['lzma ', 'alone ', 'stream ', 'header\n'];
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

(int, Uint8List, LzmaAloneArchive) extract(Uint8List file, {bool lzma86 = false}) {
  final a = LzmaAloneArchive.open(MemoryInStream(file), lzma86: lzma86)!;
  final out = MemoryOutStream();
  final r = a.extract(out);
  return (r, Uint8List.fromList(out.toBytes()), a);
}

Uint8List encode(Uint8List data,
    {bool eos = false, String props = '', bool withSize = true}) {
  final out = MemoryOutStream();
  lzmaAloneEncode(MemoryInStream(data), out,
      size: withSize ? data.length : null, eos: eos, methodProps: props);
  return Uint8List.fromList(out.toBytes());
}

void main() {
  late Directory tmp;
  final data = gen(120000, 3);
  final data2 = gen(40000, 9);

  setUpAll(() => tmp = Directory.systemTemp.createTempSync('zx_lzma_test'));
  tearDownAll(() => tmp.deleteSync(recursive: true));

  File writeTmp(String name, List<int> bytes) =>
      File('${tmp.path}/$name')..writeAsBytesSync(bytes);

  group('port round trip', () {
    test('with size', () {
      final f = encode(data);
      expect(getUint64LE(f, 5), data.length);
      final (r, d, a) = extract(f);
      expect(r, OperationResult.ok);
      expect(d, data);
      expect(a.method, 'LZMA:17');
      expect(a.packSize, f.length);
    });

    test('end marker, unknown size', () {
      final f = encode(data, eos: true);
      expect(getUint64LE(f, 5), -1);
      final (r, d, a) = extract(f);
      expect(r, OperationResult.ok);
      expect(d, data);
      expect(a.size, data.length);
    });

    test('-m properties', () {
      final f = encode(data, props: 'd=20:lc=0:lp=2:pb=0:fb=32:mf=hc4');
      final (r, d, a) = extract(f);
      expect(r, OperationResult.ok);
      expect(d, data);
      expect(a.method, 'LZMA:20:lc0:lp2:pb0');
    });

    test('empty input', () {
      for (final eos in [false, true]) {
        final f = encode(Uint8List(0), eos: eos);
        final (r, d, _) = extract(f);
        expect(r, OperationResult.ok);
        expect(d, isEmpty);
      }
    });

    test('several streams, data after end, truncated', () {
      final a = encode(data);
      final b = encode(data2, eos: true);
      var (r, d, arc) = extract(Uint8List.fromList([...a, ...b]));
      expect(r, OperationResult.ok);
      expect(d, [...data, ...data2]);
      expect(arc.numStreams, 2);

      (r, d, arc) = extract(Uint8List.fromList([...a, 1, 2, 3]));
      expect(r, OperationResult.dataAfterEnd);
      expect(d, data);

      (r, d, arc) = extract(a.sublist(0, 20000));
      expect(r, OperationResult.unexpectedEnd);
      expect(arc.errorFlags & ErrorFlags.unexpectedEnd, isNot(0));
    });

    test('not an lzma file', () {
      expect(LzmaAloneArchive.open(MemoryInStream(data)), isNull);
      expect(isArcLzma(data), IsArcResult.no);
      expect(isArcLzma(encode(data)), IsArcResult.yes);
    });

    test('lzma86', () {
      for (final mode in Lzma86FilterMode.values) {
        final f = lzma86Encode(data, dictSize: 1 << 20, filterMode: mode);
        if (mode == Lzma86FilterMode.no) expect(f[0], 0);
        if (mode == Lzma86FilterMode.yes) expect(f[0], 1);
        expect(isArcLzma86(f), IsArcResult.yes);
        final (r, d, a) = extract(f, lzma86: true);
        expect(r, OperationResult.ok);
        expect(d, data);
        expect(a.method, f[0] == 1 ? 'BCJ LZMA:20' : 'LZMA:20');
      }
    });
  });

  group('xz interop', skip: haveXz ? false : 'xz not installed', () {
    test('decode xz --format=lzma', () {
      final input = writeTmp('in.bin', data);
      for (final opts in [
        ['-0'],
        ['-6'],
        ['--lzma1=preset=2,lc=0,lp=2,pb=0'],
      ]) {
        final r = Process.runSync(
            'xz', ['--format=lzma', ...opts, '-c', input.path],
            stdoutEncoding: null);
        expect(r.exitCode, 0);
        final (res, d, _) = extract(Uint8List.fromList(r.stdout as List<int>));
        expect(res, OperationResult.ok);
        expect(d, data);
      }
    });

    test('xz decodes the port output', () {
      for (final eos in [false, true]) {
        final f = writeTmp('p.lzma', encode(data, eos: eos));
        final r = Process.runSync('xz', ['--format=lzma', '-dc', f.path],
            stdoutEncoding: null);
        expect(r.exitCode, 0, reason: '${r.stderr}');
        expect(r.stdout, data);
      }
    });
  });

  group('7-Zip interop', skip: have7z ? false : 'no /usr/bin/7z', () {
    test('7z tests and lists the port output', () {
      final f = writeTmp('q.lzma', encode(data, props: 'd=22'));
      final r = Process.runSync('/usr/bin/7z', ['l', '-slt', f.path]);
      expect(r.exitCode, 0);
      expect(r.stdout as String, contains('Method = LZMA:22'));
      final t = Process.runSync('/usr/bin/7z', ['t', f.path]);
      expect(t.stdout as String, contains('Everything is Ok'));
      final g = writeTmp('q.lzma86', lzma86Encode(data, dictSize: 1 << 20));
      final t2 = Process.runSync('/usr/bin/7z', ['t', '-tlzma86', g.path]);
      expect(t2.stdout as String, contains('Everything is Ok'));
    });
  });
}
