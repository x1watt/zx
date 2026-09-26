import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/codec/lzh/crc16.dart';
import 'package:zx/src/codec/lzh/lha_decoder.dart';
import 'package:zx/src/codec/lzh/lzh_encoder.dart';
import 'package:zx/src/common/method_props.dart';
import 'package:zx/src/format/archive_types.dart';
import 'package:zx/src/format/lha/lha_handler.dart';
import 'package:zx/src/format/lha/lha_header.dart';
import 'package:zx/src/io/streams.dart';

Uint8List gen(int n, int seed) {
  var st = seed;
  final b = Uint8List(n);
  for (var i = 0; i < n; i++) {
    st = (st * 1103515245 + 12345) & 0x7fffffff;
    b[i] = (st >> 16) & 0xff;
  }
  return b;
}

// text-like data with repeats
Uint8List textLike(int n, int seed) {
  final words = [
    'lorem ', 'ipsum ', 'dolor ', 'sit ', 'amet ', 'archive ', 'header ', //
    'level ', 'huffman ', 'window\n', 'match ', 'offset ', 'block ',
  ];
  final r = gen(n, seed);
  final b = BytesBuilder();
  var i = 0;
  while (b.length < n) {
    b.add(utf8.encode(words[r[i++ % n] % words.length]));
  }
  return Uint8List.fromList(b.takeBytes().sublist(0, n));
}

const String toolRoot = 'ref/tools/root/usr';
final String lhasaPath = '$toolRoot/bin/lhasa';
final bool haveLhasa = File(lhasaPath).existsSync();
final bool have7z = File('/usr/bin/7z').existsSync();
final String javaPath =
    '${Platform.environment['HOME']}/.sdkman/candidates/java/current/bin/java';
final bool haveJlha = File(javaPath).existsSync() &&
    File('$toolRoot/share/java/jlha.jar').existsSync() &&
    File('$toolRoot/share/java/jlhafrontend.jar').existsSync();
const String corpus = 'ref/lhasa/test/archives';

ProcessResult runLhasa(List<String> args, {String? cwd}) =>
    Process.runSync(File(lhasaPath).absolute.path, args,
        workingDirectory: cwd,
        environment: {
          'LD_LIBRARY_PATH':
              Directory('$toolRoot/lib/x86_64-linux-gnu').absolute.path
        });

ProcessResult runJlha(List<String> args, {String? cwd}) => Process.runSync(
    javaPath,
    [
      '-cp',
      '${File('$toolRoot/share/java/jlha.jar').absolute.path}:'
          '${File('$toolRoot/share/java/jlhafrontend.jar').absolute.path}',
      'org.jlhafrontend.JLHAFrontEnd',
      ...args
    ],
    workingDirectory: cwd);

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

/// Results only, the data is discarded.
class _NullCollect extends ArchiveExtractCallback {
  final Map<int, int> results = {};
  int _cur = -1;
  @override
  OutStream? getStream(int index, int askMode) {
    _cur = index;
    return NullOutStream();
  }

  @override
  void setOperationResult(int opRes) => results[_cur] = opRes;
}

/// An output that is not seekable.
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
  final int? posix;
  final int? mTime;
  final String? symLink;
  Up.keep(this.keep, [this.name])
      : isDir = false,
        data = null,
        posix = null,
        mTime = null,
        symLink = null;
  Up.add(String this.name,
      {this.isDir = false, this.data, this.posix, this.mTime, this.symLink})
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
      case Kpid.posixAttrib:
        return u.posix;
      case Kpid.mTime:
        return u.mTime;
      case Kpid.symLink:
        return u.symLink;
    }
    return null;
  }

  @override
  InStream? getStream(int index) =>
      MemoryInStream(ups[index].data ?? Uint8List(0));
}

// FILETIME of a Unix time
int ft(int sec) => sec * 10000000 + 116444736000000000;

Uint8List writeLzh(List<Up> ups,
    {String method = 'lh5', LhaHandler? from, bool seekable = true}) {
  final h = from ?? LhaHandler();
  h.setProperties([MapEntry('m', PropVariant.bstr(method))]);
  if (seekable) {
    final out = MemoryOutStream();
    h.updateItems(out, ups.length, _UpdateCb(ups));
    return Uint8List.fromList(out.toBytes());
  }
  final out = _SeqOut();
  h.updateItems(out, ups.length, _UpdateCb(ups));
  return Uint8List.fromList(out.m.toBytes());
}

LhaHandler openBytes(Uint8List b) {
  final h = LhaHandler();
  expect(h.open(MemoryInStream(b)), isTrue);
  return h;
}

Collect extractAll(LhaHandler h) {
  final c = Collect();
  h.extract(null, false, c);
  return c;
}

// a level 0 or 1 header with -lh0- data, built by hand
Uint8List level01(int level, String name, Uint8List data,
    {List<int> ext = const []}) {
  final nb = latin1.encode(name);
  final hdr = BytesBuilder();
  final minLen = level == 0 ? 22 : 25;
  final len = minLen + nb.length + (level == 1 ? 0 : ext.length);
  hdr.addByte(len);
  hdr.addByte(0); // checksum, below
  hdr.add(latin1.encode('-lh0-'));
  final extLen = level == 1 && ext.isNotEmpty ? ext.length : 0;
  void p32(int v) =>
      hdr.add([v & 255, (v >> 8) & 255, (v >> 16) & 255, v >> 24]);
  p32(data.length + extLen);
  p32(data.length);
  p32((44 << 25) | (6 << 21) | (15 << 16) | (12 << 11) | (30 << 5)); // 2024
  hdr.addByte(0x20);
  hdr.addByte(level);
  hdr.addByte(nb.length);
  hdr.add(nb);
  final crc = lhaCrc16(0, data, 0, data.length);
  hdr.add([crc & 255, crc >> 8]);
  if (level == 0) {
    hdr.add(ext);
  } else {
    hdr.addByte(0x4D); // 'M'
    hdr.add(ext.isEmpty ? [0, 0] : [ext.length & 255, ext.length >> 8]);
  }
  final b = hdr.takeBytes();
  var sum = 0;
  for (var i = 2; i < len + 2; i++) {
    sum += b[i];
  }
  b[1] = sum & 0xFF;
  return Uint8List.fromList([...b, ...(level == 1 ? ext : []), ...data]);
}

void main() {
  final text = textLike(70000, 1);
  final rnd = gen(20000, 2);
  final zeros = Uint8List(50000);

  group('codec', () {
    for (final m in [5, 6, 7]) {
      test('lh$m encoder round trip', () {
        for (final d in [text, rnd, zeros, Uint8List(1), gen(3, 9)]) {
          final out = MemoryOutStream();
          final enc = LzhHuffEncoder.lha(m, out);
          enc.encode(MemoryInStream(d));
          final dec = lhaDecoderForName(
              '-lh$m-', MemoryInStream(Uint8List.fromList(out.toBytes())))!;
          final s = LhaDecoderInStream(dec, d.length);
          expect(readAll(s), equals(d));
          expect(s.crc, lhaCrc16(0, d, 0, d.length));
        }
      });
    }

    test('many blocks and long repeats', () {
      // more than one block of commands, matches at the window limit
      final d = BytesBuilder()
        ..add(gen(40000, 5))
        ..add(gen(40000, 5))
        ..add(text);
      final data = d.takeBytes();
      final out = MemoryOutStream();
      LzhHuffEncoder.lha(5, out, level: 9).encode(MemoryInStream(data));
      final s = LhaDecoderInStream(
          lhaDecoderForName('-lh5-', MemoryInStream(out.toBytes()))!,
          data.length);
      expect(readAll(s), equals(data));
    });
  });

  group('handler', () {
    for (final method in ['lh0', 'lh5', 'lh6', 'lh7']) {
      for (final seekable in [true, false]) {
        test('round trip -$method- ${seekable ? 'seekable' : 'stream'}', () {
          final arc = writeLzh([
            Up.add('dir', isDir: true, mTime: ft(1600000000)),
            Up.add('dir/text.txt',
                data: text, posix: 0x81A4, mTime: ft(1600000002)),
            Up.add('rnd.bin', data: rnd, posix: 0x8180),
            Up.add('zeros', data: zeros),
            Up.add('empty', data: Uint8List(0)),
            Up.add('link', symLink: 'dir/text.txt', posix: 0xA1FF),
          ], method: method, seekable: seekable);
          final h = openBytes(arc);
          expect(h.numberOfItems, 6);
          expect(h.getArchiveProperty(Kpid.errorFlags), 0);
          expect(h.getProperty(0, Kpid.path), 'dir');
          expect(h.getProperty(0, Kpid.isDir), isTrue);
          expect(h.getProperty(1, Kpid.path), 'dir/text.txt');
          expect(h.getProperty(1, Kpid.mTime), ft(1600000002));
          expect(h.getProperty(1, Kpid.posixAttrib), 0x81A4);
          expect(h.getProperty(2, Kpid.posixAttrib), 0x8180);
          expect(h.getProperty(5, Kpid.symLink), 'dir/text.txt');
          expect(h.getProperty(5, Kpid.isDir), isFalse);
          final c = extractAll(h);
          expect(
              c.results.values.every((r) => r == OperationResult.ok), isTrue);
          expect(c.data(1), equals(text));
          expect(c.data(2), equals(rnd));
          expect(c.data(3), equals(zeros));
          expect(c.data(4), isEmpty);
          expect(utf8.decode(c.data(5)), 'dir/text.txt');
          // random data is stored, the rest compressed
          expect(h.getProperty(2, Kpid.method), '-lh0-');
          expect(h.getProperty(1, Kpid.method),
              method == 'lh0' ? '-lh0-' : '-$method-');
        });
      }
    }

    test('update: keep, rename, delete, add', () {
      final a = writeLzh([
        Up.add('a.txt', data: text),
        Up.add('b.bin', data: rnd),
        Up.add('c', data: zeros),
      ]);
      final h = openBytes(a);
      final b = writeLzh([
        Up.keep(0),
        Up.keep(2, 'sub/renamed'),
        Up.add('d.txt', data: gen(100, 3)),
      ], method: 'lh6', from: h);
      // a kept item is copied byte for byte
      final it0 = h.items[0];
      expect(b.sublist(0, it0.endPos), equals(a.sublist(0, it0.endPos)));
      final h2 = openBytes(b);
      expect([for (var i = 0; i < 3; i++) h2.getProperty(i, Kpid.path)],
          ['a.txt', 'sub/renamed', 'd.txt']);
      final c = extractAll(h2);
      expect(c.data(0), equals(text));
      expect(c.data(1), equals(zeros));
      expect(c.data(2), equals(gen(100, 3)));
      expect(h2.getProperty(2, Kpid.method), '-lh0-');
    });

    test('properties', () {
      final h = LhaHandler();
      h.setProperties([MapEntry('m', PropVariant.bstr('-LH7-'))]);
      expect(h.method, 7);
      h.setProperties([const MapEntry('x', PropVariant.ui4(0))]);
      expect(h.method, 0);
      h.setProperties([MapEntry('0', PropVariant.bstr('lh6'))]);
      expect(h.method, 6);
      expect(() => h.setProperties([MapEntry('m', PropVariant.bstr('lh9'))]),
          throwsA(isA<InvalidArgException>()));
    });

    test('level 0 and 1 headers, CRC error', () {
      final d = gen(300, 7);
      for (final level in [0, 1]) {
        final arc =
            Uint8List.fromList([...level01(level, r'DIR\FILE.TXT', d), 0]);
        final h = openBytes(arc);
        expect(h.getProperty(0, Kpid.path), 'DIR/FILE.TXT');
        expect(h.getProperty(0, Kpid.mTime), isNotNull);
        final c = extractAll(h);
        expect(c.results[0], OperationResult.ok);
        expect(c.data(0), equals(d));
        // a changed byte of data
        arc[arc.length - 10] ^= 1;
        final c2 = extractAll(openBytes(arc));
        expect(c2.results[0], OperationResult.crcError);
      }
      // level 1 with a Unix permission extended header (0x50)
      // type, value, the size of the next extended header (none)
      final ext = [0x50, 0xED, 0x81, 0, 0];
      final h =
          openBytes(Uint8List.fromList([...level01(1, 'x', d, ext: ext), 0]));
      expect(h.getProperty(0, Kpid.posixAttrib), 0x81ED);
      expect(extractAll(h).data(0), equals(d));
    });

    test('bad and truncated headers', () {
      final a = writeLzh([Up.add('a', data: text), Up.add('b', data: rnd)]);
      // truncated in the second item
      final t = a.sublist(0, a.length - 100);
      final h = openBytes(t);
      expect(h.errorFlags & ErrorFlags.unexpectedEnd, isNot(0));
      final c = extractAll(h);
      expect(c.results[0], OperationResult.ok);
      expect(c.results[1], OperationResult.unexpectedEnd);
      // a broken header CRC (common extended header)
      final b = Uint8List.fromList(a);
      b[30] ^= 0xFF;
      expect(LhaHandler().open(MemoryInStream(b)), isFalse);
      expect(
          isArcLzh(
              Uint8List.fromList(latin1.encode('hello world, not an '
                  'lzh archive at all')),
              30),
          0);
    });
  });

  group('interop', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('lha_test'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('lhasa and 7z read our archives', () {
      for (final method in ['lh0', 'lh5', 'lh6', 'lh7']) {
        final arc = writeLzh([
          Up.add('d', isDir: true),
          Up.add('d/t.txt', data: text, posix: 0x81A4),
          Up.add('r.bin', data: rnd, posix: 0x81A4),
          Up.add('z', data: zeros, posix: 0x81A4),
        ], method: method);
        final f = File('${tmp.path}/$method.lzh')..writeAsBytesSync(arc);
        if (haveLhasa) {
          final r = runLhasa(['-t', f.path]);
          expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
          final x = Directory('${tmp.path}/x$method')..createSync();
          expect(runLhasa(['-xq', f.path], cwd: x.path).exitCode, 0);
          expect(File('${x.path}/d/t.txt').readAsBytesSync(), equals(text));
          expect(File('${x.path}/z').readAsBytesSync(), equals(zeros));
        }
        if (have7z) {
          final r = Process.runSync('7z', ['t', f.path]);
          expect(r.stdout, contains('Everything is Ok'));
        }
      }
    }, skip: !haveLhasa && !have7z);

    test('we read jlha archives', () {
      final src = Directory('${tmp.path}/src')..createSync();
      File('${src.path}/t.txt').writeAsBytesSync(text);
      File('${src.path}/r.bin').writeAsBytesSync(rnd);
      for (final o in ['o5', 'o6', 'o7']) {
        final r =
            runJlha(['a$o', '../$o.lzh', 't.txt', 'r.bin'], cwd: src.path);
        expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
        final h = openBytes(File('${tmp.path}/$o.lzh').readAsBytesSync());
        expect(h.getProperty(0, Kpid.method), '-lh${o[1]}-');
        final c = extractAll(h);
        expect(c.results.values.every((v) => v == OperationResult.ok), isTrue);
        expect(c.data(0), equals(text));
        expect(c.data(1), equals(rnd));
      }
    }, skip: !haveJlha);

    test('jlha reads our archives', () {
      final arc = writeLzh([
        Up.add('t.txt', data: text),
        Up.add('r.bin', data: rnd),
      ], method: 'lh7');
      File('${tmp.path}/o.lzh').writeAsBytesSync(arc);
      final x = Directory('${tmp.path}/x')..createSync();
      final r = runJlha(['x', '../o.lzh'], cwd: x.path);
      expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
      expect(File('${x.path}/t.txt').readAsBytesSync(), equals(text));
      expect(File('${x.path}/r.bin').readAsBytesSync(), equals(rnd));
    }, skip: !haveJlha);

    test('lhasa test archives (all methods and header levels)', () {
      var n = 0;
      final skip = {'lh2.lzh', 'lh3.lzh', 'evil_pm2.lzh', 'truncated.lzh'};
      for (final e in Directory(corpus).listSync(recursive: true)) {
        if (e is! File) continue;
        final name = e.uri.pathSegments.last;
        if (!RegExp(r'\.(lzh|lha|lzs|pma)$', caseSensitive: false)
                .hasMatch(name) ||
            skip.contains(name)) {
          continue;
        }
        final h = LhaHandler();
        if (!h.open(FileInStream.open(e.path))) continue;
        // h2_huge.lzh: 400 MB of zeros, too slow for a test
        if (h.items.any((it) => it.size > 64 << 20)) continue;
        final c = _NullCollect();
        h.extract(null, true, c);
        for (final r in c.results.entries) {
          expect(r.value, OperationResult.ok,
              reason: '${e.path} ${h.getProperty(r.key, Kpid.path)}');
        }
        n++;
      }
      expect(n, greaterThan(150));
    }, skip: !Directory(corpus).existsSync());
  });

  test('header match', () {
    final b = Uint8List(22);
    b.setRange(2, 7, latin1.encode('-lh5-'));
    b[20] = 2;
    expect(lhaHeaderMatch(b, 0), isTrue);
    b[20] = 4;
    expect(lhaHeaderMatch(b, 0), isFalse);
  });
}
