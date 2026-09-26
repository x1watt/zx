import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/codec/lzh/arj4_decoder.dart';
import 'package:zx/src/codec/lzh/lh_new_decoder.dart';
import 'package:zx/src/codec/lzh/lha_decoder.dart';
import 'package:zx/src/codec/lzh/lzh_bits.dart';
import 'package:zx/src/codec/lzh/lzh_encoder.dart';
import 'package:zx/src/common/method_props.dart';
import 'package:zx/src/format/archive_types.dart';
import 'package:zx/src/format/arj/arj_handler.dart';
import 'package:zx/src/io/streams.dart';
import 'package:zx/src/util/crc.dart';

Uint8List gen(int n, int seed) {
  var st = seed;
  final b = Uint8List(n);
  for (var i = 0; i < n; i++) {
    st = (st * 1103515245 + 12345) & 0x7fffffff;
    b[i] = (st >> 16) & 0xff;
  }
  return b;
}

Uint8List textLike(int n, int seed) {
  final words = [
    'alpha ', 'beta ', 'gamma ', 'delta ', 'archive ', 'header ', //
    'volume ', 'garble ', 'method ', 'fastest\n', 'store ', 'crc ',
  ];
  final r = gen(n, seed);
  final b = BytesBuilder();
  var i = 0;
  while (b.length < n) {
    b.add(utf8.encode(words[r[i++ % n] % words.length]));
  }
  return Uint8List.fromList(b.takeBytes().sublist(0, n));
}

final String arjPath = 'ref/tools/root/usr/bin/arj';
final bool haveArj = File(arjPath).existsSync();
final bool have7z = File('/usr/bin/7z').existsSync();

ProcessResult runArj(List<String> args, {String? cwd}) =>
    Process.runSync(File(arjPath).absolute.path, args, workingDirectory: cwd);

class Collect extends ArchiveExtractCallback {
  final Map<int, MemoryOutStream> outs = {};
  final Map<int, int> results = {};
  int _cur = -1;
  @override
  OutStream? getStream(int index, int askMode) {
    _cur = index;
    return outs[index] = MemoryOutStream();
  }

  @override
  void setOperationResult(int opRes) => results[_cur] = opRes;

  Uint8List data(int i) => outs[i]!.toBytes();
}

class _SeqOut implements OutStream {
  final MemoryOutStream m = MemoryOutStream();
  @override
  void write(Uint8List buf, int off, int len) => m.write(buf, off, len);
  @override
  void flush() {}
}

class Up {
  final int keep;
  final String? name;
  final bool isDir;
  final Uint8List? data;
  final int? mTime;
  Up.keep(this.keep, [this.name])
      : isDir = false,
        data = null,
        mTime = null;
  Up.add(String this.name, {this.isDir = false, this.data, this.mTime})
      : keep = -1;
}

class _UpdateCb extends ArchiveUpdateCallback {
  final List<Up> ups;
  _UpdateCb(this.ups);

  @override
  UpdateItemInfo getUpdateItemInfo(int index) {
    final u = ups[index];
    if (u.keep >= 0) return UpdateItemInfo(false, u.name != null, u.keep);
    return const UpdateItemInfo(true, true, -1);
  }

  @override
  Object? getProperty(int index, int propId) {
    final u = ups[index];
    switch (propId) {
      case Kpid.path:
        return u.name;
      case Kpid.isDir:
        return u.keep >= 0 ? null : u.isDir;
      case Kpid.size:
        return u.data?.length ?? 0;
      case Kpid.mTime:
        return u.mTime;
    }
    return null;
  }

  @override
  InStream? getStream(int index) =>
      MemoryInStream(ups[index].data ?? Uint8List(0));
}

// FILETIME of a local time
int localFt(int y, int mo, int d, int h, int mi, int s) =>
    DateTime(y, mo, d, h, mi, s).microsecondsSinceEpoch * 10 +
    116444736000000000;

Uint8List writeArj(List<Up> ups,
    {int method = 1, ArjHandler? from, bool seekable = true}) {
  final h = from ?? ArjHandler();
  h.setProperties([MapEntry('m', PropVariant.ui4(method))]);
  if (seekable) {
    final out = MemoryOutStream();
    h.updateItems(out, ups.length, _UpdateCb(ups));
    return Uint8List.fromList(out.toBytes());
  }
  final out = _SeqOut();
  h.updateItems(out, ups.length, _UpdateCb(ups));
  return Uint8List.fromList(out.m.toBytes());
}

ArjHandler openBytes(Uint8List b) {
  final h = ArjHandler();
  expect(h.open(MemoryInStream(b)), isTrue);
  return h;
}

Collect extractAll(ArjHandler h) {
  final c = Collect();
  h.extract(null, false, c);
  return c;
}

void main() {
  final text = textLike(60000, 1);
  final rnd = gen(20000, 2);
  final zeros = Uint8List(40000);
  final t0 = localFt(2024, 5, 17, 10, 20, 30);

  group('codec', () {
    test('methods 1 to 3 and 4 round trip', () {
      for (final d in [text, rnd, zeros, Uint8List(1), gen(5, 3)]) {
        for (final m in [1, 4]) {
          final out = MemoryOutStream();
          if (m == 4) {
            Arj4Encoder(out).encode(MemoryInStream(d));
          } else {
            LzhHuffEncoder.arj(out).encode(MemoryInStream(d));
          }
          final r = LzhBitReader(MemoryInStream(out.toBytes()));
          final LhaDecoder dec =
              m == 4 ? Arj4Decoder(r) : LhNewDecoder(r, LhNewParams.arj);
          final s = LhaDecoderInStream(dec, d.length, computeCrc16: false);
          expect(readAll(s), equals(d), reason: 'method $m');
        }
      }
    });
  });

  group('handler', () {
    for (final m in [0, 1, 2, 3, 4]) {
      for (final seekable in [true, false]) {
        test('round trip method $m ${seekable ? 'seekable' : 'stream'}', () {
          final arc = writeArj([
            Up.add('dir', isDir: true, mTime: t0),
            Up.add('dir/text.txt', data: text, mTime: t0),
            Up.add('rnd.bin', data: rnd, mTime: t0),
            Up.add('zeros', data: zeros, mTime: t0),
            Up.add('empty', data: Uint8List(0), mTime: t0),
          ], method: m, seekable: seekable);
          final h = openBytes(arc);
          expect(h.numberOfItems, 5);
          expect(h.errorFlags, 0);
          expect(h.getProperty(0, Kpid.isDir), isTrue);
          expect(h.getProperty(1, Kpid.path), 'dir/text.txt');
          expect(h.getProperty(1, Kpid.mTime), t0);
          expect(h.getProperty(1, Kpid.crc), Crc32.of(text));
          expect(h.getProperty(1, Kpid.method), '$m');
          // random data is stored
          expect(h.getProperty(2, Kpid.method), '0');
          final c = extractAll(h);
          expect(
              c.results.values.every((r) => r == OperationResult.ok), isTrue);
          expect(c.data(1), equals(text));
          expect(c.data(2), equals(rnd));
          expect(c.data(3), equals(zeros));
          expect(c.data(4), isEmpty);
        });
      }
    }

    test('update: keep, rename, add; CRC error', () {
      final a = writeArj([
        Up.add('a.txt', data: text, mTime: t0),
        Up.add('b.bin', data: rnd, mTime: t0),
        Up.add('c', data: zeros, mTime: t0),
      ]);
      final h = openBytes(a);
      final b = writeArj([
        Up.keep(0),
        Up.keep(2, 'sub/renamed'),
        Up.add('d.txt', data: gen(100, 3), mTime: t0),
      ], method: 4, from: h);
      final h2 = openBytes(b);
      expect([for (var i = 0; i < 3; i++) h2.getProperty(i, Kpid.path)],
          ['a.txt', 'sub/renamed', 'd.txt']);
      final c = extractAll(h2);
      expect(c.data(0), equals(text));
      expect(c.data(1), equals(zeros));
      expect(c.data(2), equals(gen(100, 3)));
      // a changed byte of packed data
      final it = h2.items[0];
      b[it.dataPos + 100] ^= 0x55;
      final c2 = extractAll(openBytes(b));
      expect(c2.results[0], isNot(OperationResult.ok));
      expect(c2.results[1], OperationResult.ok);
    });

    test('properties', () {
      final h = ArjHandler();
      h.setProperties([MapEntry('m', PropVariant.bstr('4'))]);
      expect(h.method, 4);
      h.setProperties([const MapEntry('x', PropVariant.ui4(0))]);
      expect(h.method, 0);
      h.setProperties([const MapEntry('x', PropVariant.ui4(9))]);
      expect(h.method, 1);
      expect(() => h.setProperties([const MapEntry('m', PropVariant.ui4(7))]),
          throwsA(isA<InvalidArgException>()));
    });

    test('truncated and bad archives', () {
      final a = writeArj([Up.add('a', data: text), Up.add('b', data: rnd)]);
      final h = openBytes(a.sublist(0, a.length - 200));
      expect(h.errorFlags & ErrorFlags.unexpectedEnd, isNot(0));
      final c = extractAll(h);
      expect(c.results[0], OperationResult.ok);
      expect(c.results[1], OperationResult.unexpectedEnd);
      final bad = Uint8List.fromList(a);
      bad[10] ^= 1; // main header CRC
      expect(ArjHandler().open(MemoryInStream(bad)), isFalse);
    });
  });

  group('interop', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('arj_test'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('arj and 7z read our archives', () {
      for (final m in [0, 1, 2, 3, 4]) {
        final arc = writeArj([
          Up.add('d', isDir: true, mTime: t0),
          Up.add('d/t.txt', data: text, mTime: t0),
          Up.add('r.bin', data: rnd, mTime: t0),
          Up.add('z', data: zeros, mTime: t0),
        ], method: m);
        final f = File('${tmp.path}/m$m.arj')..writeAsBytesSync(arc);
        if (haveArj) {
          final r = runArj(['t', '-y', f.path]);
          expect(r.exitCode, 0, reason: '${r.stdout}');
          final x = Directory('${tmp.path}/x$m')..createSync();
          expect(runArj(['x', '-y', f.path], cwd: x.path).exitCode, 0);
          expect(File('${x.path}/d/t.txt').readAsBytesSync(), equals(text));
          expect(File('${x.path}/z').readAsBytesSync(), equals(zeros));
        }
        if (have7z) {
          final r = Process.runSync('7z', ['t', f.path]);
          expect(r.stdout, contains('Everything is Ok'));
        }
      }
    }, skip: !haveArj && !have7z);

    test('we read arj archives, all methods', () {
      final src = Directory('${tmp.path}/src')..createSync();
      File('${src.path}/t.txt').writeAsBytesSync(text);
      File('${src.path}/r.bin').writeAsBytesSync(rnd);
      File('${src.path}/z').writeAsBytesSync(zeros);
      for (final m in [0, 1, 2, 3, 4]) {
        for (final dos in [false, true]) {
          final name = '${tmp.path}/a$m$dos.arj';
          final r = runArj(
              ['a', '-m$m', '-y', if (dos) '-2d', name, 't.txt', 'r.bin', 'z'],
              cwd: src.path);
          expect(r.exitCode, 0, reason: '${r.stdout}');
          final h = openBytes(File(name).readAsBytesSync());
          expect(h.getProperty(0, Kpid.path), 't.txt');
          expect(h.getProperty(0, Kpid.hostOS), dos ? 'MS-DOS' : 'UNIX');
          final t = h.getProperty(0, Kpid.mTime) as int;
          final ms = File('${src.path}/t.txt')
              .lastModifiedSync()
              .millisecondsSinceEpoch;
          final ours = (t - 116444736000000000) ~/ 10000;
          expect((ours - ms).abs(), lessThan(2500));
          final c = extractAll(h);
          expect(c.results.values.every((v) => v == OperationResult.ok), isTrue,
              reason: 'method $m');
          expect(c.data(0), equals(text));
          expect(c.data(1), equals(rnd));
          expect(c.data(2), equals(zeros));
        }
      }
    }, skip: !haveArj);

    test('garbled files are listed and not extracted', () {
      final src = Directory('${tmp.path}/src')..createSync();
      File('${src.path}/t.txt').writeAsBytesSync(text);
      final name = '${tmp.path}/g.arj';
      expect(
          runArj(['a', '-gsecret', '-y', name, 't.txt'], cwd: src.path)
              .exitCode,
          0);
      final h = openBytes(File(name).readAsBytesSync());
      expect(h.getProperty(0, Kpid.encrypted), isTrue);
      final c = extractAll(h);
      expect(c.results[0], OperationResult.unsupportedMethod);
    }, skip: !haveArj);
  });
}
