// Tests of the isolate based API (lib/src/api.dart) and of the parallel xz
// encoder (lib/src/parallel.dart), with interop against the system 7z
// (7-Zip 23.01 at /usr/bin/7z) where it is installed.

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/zx.dart';

const sevenZ = '/usr/bin/7z';
final bool have7z = File(sevenZ).existsSync();

late Directory tmp;
late Directory src;

Uint8List pseudoRandom(int n, int seed) {
  final rnd = Random(seed);
  final b = Uint8List(n);
  for (var i = 0; i < n; i++) {
    b[i] = rnd.nextInt(256);
  }
  return b;
}

/// Compressible data: text lines with some structure.
Uint8List textData(int lines, [int seed = 0]) {
  final sb = StringBuffer();
  for (var i = 0; i < lines; i++) {
    sb.writeln('line $i: the quick brown fox ${(i + seed) * 7919 % 1000}');
  }
  return Uint8List.fromList(sb.toString().codeUnits);
}

void makeTree(Directory d) {
  File('${d.path}/a.txt').writeAsStringSync('hello\n');
  Directory('${d.path}/dir/sub').createSync(recursive: true);
  Directory('${d.path}/emptydir').createSync();
  File('${d.path}/dir/b.bin').writeAsBytesSync(pseudoRandom(40000, 1));
  File('${d.path}/dir/nums.txt').writeAsBytesSync(textData(3000));
  File('${d.path}/empty.txt').writeAsBytesSync([]);
  File('${d.path}/dir/sub/unicode \u00fc\u20ac.txt')
      .writeAsStringSync('unicode\n');
  Link('${d.path}/link').createSync('a.txt');
}

/// Relative path to content (null for directories) of every entry below
/// [root], links followed like the API does by default.
Map<String, Uint8List?> readTree(String root) {
  final r = <String, Uint8List?>{};
  for (final e in Directory(root).listSync(recursive: true)) {
    final rel = e.path.substring(root.length + 1);
    r[rel] = e is File ? e.readAsBytesSync() : null;
  }
  return r;
}

void expectSameTree(String a, String b) {
  final ta = readTree(a), tb = readTree(b);
  expect(tb.keys.toSet(), ta.keys.toSet());
  for (final k in ta.keys) {
    expect(tb[k], ta[k], reason: k);
  }
}

void main() {
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('zx_api_');
    src = Directory('${tmp.path}/src')..createSync();
    makeTree(src);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  List<String> leftovers() => [
        for (final e in tmp.listSync(recursive: true))
          if (e.path.endsWith('.zx-part')) e.path
      ];

  group('7z', () {
    test('add, list, extract, test round trip', () async {
      final arc = SevenZipArchive('${tmp.path}/a.7z');
      final events = <SevenZipProgress>[];
      final res = await arc.add([SevenZipSource(src.path, storedAs: '')],
          onProgress: events.add);
      expect(res.changed, 9); // 6 files, 3 directories, the link as a file
      expect(res.kept, 0);
      expect(events, isNotEmpty);

      final l = await arc.list();
      expect(l.isSolid, isTrue);
      final names = l.entries.map((e) => e.path).toSet();
      expect(names, contains('dir/sub/unicode \u00fc\u20ac.txt'));
      expect(names, contains('emptydir'));
      final link = l.entries.firstWhere((e) => e.path == 'link');
      expect(link.isSymlink, isFalse);
      expect(link.size, 6);

      final out = '${tmp.path}/out';
      final x = await arc.extract(out);
      expect(x.ok, isTrue);
      expect(x.files, 6);
      expect(x.dirs, 3);
      expectSameTree(src.path, out);
      final m = File('$out/dir/nums.txt').lastModifiedSync();
      final m0 = File('${src.path}/dir/nums.txt').lastModifiedSync();
      expect(m.difference(m0).inSeconds.abs(), lessThan(2));

      final t = await arc.test();
      expect(t.ok, isTrue);
      expect(t.files, 6);
      expect(await arc.readFile('dir/nums.txt'), textData(3000));
      expect(leftovers(), isEmpty);
    });

    test('7z reads what the API writes, the API reads what 7z writes',
        () async {
      final arc = SevenZipArchive('${tmp.path}/b.7z');
      await arc.add([SevenZipSource(src.path)],
          options: const SevenZipOptions(level: 9, method: 'PPMd'));
      var r = Process.runSync(sevenZ, ['t', arc.path]);
      expect(r.exitCode, 0, reason: '${r.stdout}');

      r = Process.runSync(sevenZ, ['a', '-snl', 'c.7z', './src/*'],
          workingDirectory: tmp.path);
      expect(r.exitCode, 0, reason: '${r.stdout}');
      final x =
          await SevenZipArchive('${tmp.path}/c.7z').extract('${tmp.path}/xc');
      expect(x.ok, isTrue);
      expect(Link('${tmp.path}/xc/link').targetSync(), 'a.txt');
      expectSameTree(src.path, '${tmp.path}/xc');
    }, skip: have7z ? false : 'no /usr/bin/7z');

    test('password and encrypted headers', () async {
      final path = '${tmp.path}/e.7z';
      await SevenZipArchive(path, password: 'secret').add(
          [SevenZipSource(src.path, storedAs: '')],
          options: const SevenZipOptions(encryptHeaders: true));
      await expectLater(
          SevenZipArchive(path).list(),
          throwsA(isA<SevenZipException>()
              .having((e) => e.kind, 'kind', SevenZipError.wrongPassword)));
      final l = await SevenZipArchive(path, password: 'secret').list();
      expect(l.entries.every((e) => e.isDir || e.size == 0 || e.encrypted),
          isTrue);
      final x = await SevenZipArchive(path, password: 'secret')
          .extract('${tmp.path}/x');
      expect(x.ok, isTrue);
      expectSameTree(src.path, '${tmp.path}/x');
      if (have7z) {
        final r = Process.runSync(sevenZ, ['t', '-psecret', path]);
        expect(r.exitCode, 0, reason: '${r.stdout}');
      }

      // Data encrypted, names not: a wrong password shows at extraction.
      final p2 = '${tmp.path}/e2.7z';
      await SevenZipArchive(p2, password: 'right')
          .add([SevenZipSource('${src.path}/dir/nums.txt')]);
      final bad = await SevenZipArchive(p2, password: 'wrong').test();
      expect(bad.ok, isFalse);
      expect(bad.wrongPassword, isTrue);
    });

    test('update, delete, rename', () async {
      final arc = SevenZipArchive('${tmp.path}/u.7z');
      await arc.add([SevenZipSource(src.path, storedAs: '')]);
      File('${src.path}/a.txt').writeAsStringSync('changed\n');
      File('${src.path}/new.txt').writeAsStringSync('new\n');
      final u = await arc.add([
        SevenZipSource('${src.path}/a.txt', storedAs: 'a.txt'),
        SevenZipSource('${src.path}/new.txt', storedAs: 'new.txt'),
      ]);
      expect(u.changed, 2);
      expect(u.kept, 8);
      expect(String.fromCharCodes(await arc.readFile('a.txt')), 'changed\n');

      final d = await arc.delete(['dir']);
      expect(d.changed, 5); // dir, dir/sub, and three files
      var names = (await arc.list()).entries.map((e) => e.path).toSet();
      expect(names.any((n) => n.startsWith('dir')), isFalse);

      final rn = await arc.rename({'new.txt': 'renamed.txt', 'emptydir': 'ed'});
      expect(rn.changed, 2);
      names = (await arc.list()).entries.map((e) => e.path).toSet();
      expect(names, containsAll(['renamed.txt', 'ed', 'a.txt', 'link']));
      expect(names, isNot(contains('new.txt')));
      expect(String.fromCharCodes(await arc.readFile('renamed.txt')), 'new\n');
      expect((await arc.test()).ok, isTrue);
      if (have7z) {
        final r = Process.runSync(sevenZ, ['t', arc.path]);
        expect(r.exitCode, 0, reason: '${r.stdout}');
      }
      expect(leftovers(), isEmpty);
    });

    test('selection and overwrite policies', () async {
      final arc = SevenZipArchive('${tmp.path}/s.7z');
      await arc.add([SevenZipSource(src.path, storedAs: '')],
          options: const SevenZipOptions(solid: false));
      final out = '${tmp.path}/o';
      var x = await arc.extract(out, paths: ['dir/sub']);
      expect(x.files, 1);
      expect(Directory(out).listSync().map((e) => e.path.split('/').last),
          ['dir']);

      File('$out/a.txt').writeAsStringSync('mine');
      x = await arc.extract(out,
          paths: ['a.txt'], overwrite: SevenZipOverwrite.skip);
      expect(x.skipped, 1);
      expect(File('$out/a.txt').readAsStringSync(), 'mine');
      x = await arc.extract(out,
          paths: ['a.txt'], overwrite: SevenZipOverwrite.rename);
      expect(File('$out/a_1.txt').readAsStringSync(), 'hello\n');
      x = await arc.extract(out, paths: ['a.txt']);
      expect(File('$out/a.txt').readAsStringSync(), 'hello\n');
    });

    test('names can not escape the output folder', () async {
      final bytes = sevenZipCompressBytes({
        '../evil.txt': Uint8List.fromList([1]),
        '/abs/x.txt': Uint8List.fromList([2]),
        'ok/../../y.txt': Uint8List.fromList([3]),
      });
      File('${tmp.path}/evil.7z').writeAsBytesSync(bytes);
      final out = '${tmp.path}/jail';
      final x = await SevenZipArchive('${tmp.path}/evil.7z').extract(out);
      expect(x.ok, isTrue);
      expect(File('${tmp.path}/evil.txt').existsSync(), isFalse);
      expect(File('$out/evil.txt').readAsBytesSync(), [1]);
      expect(File('$out/abs/x.txt').readAsBytesSync(), [2]);
      expect(File('$out/ok/y.txt').readAsBytesSync(), [3]);
    });

    test('split volumes', () async {
      final r = Process.runSync(
          sevenZ, ['a', '-v20k', '-mx0', 'v.7z', './src/*'],
          workingDirectory: tmp.path);
      expect(r.exitCode, 0, reason: '${r.stdout}');
      expect(File('${tmp.path}/v.7z.003').existsSync(), isTrue);
      final arc = SevenZipArchive('${tmp.path}/v.7z.001');
      expect((await arc.list()).entries.length, 9);
      expect((await arc.test()).ok, isTrue);
    }, skip: have7z ? false : 'no /usr/bin/7z');

    test('in memory helpers', () {
      final files = {
        'a.txt': textData(100),
        'd/b.bin': pseudoRandom(1000, 3),
      };
      final z = sevenZipCompressBytes(files, password: 'pw');
      expect(sevenZipDecompressBytes(z, password: 'pw'), files);
    });

    test('errors cross the isolate boundary', () async {
      await expectLater(SevenZipArchive('${tmp.path}/missing.7z').list(),
          throwsA(isA<FileSystemException>()));
      File('${tmp.path}/junk.7z').writeAsBytesSync(pseudoRandom(1000, 9));
      await expectLater(
          SevenZipArchive('${tmp.path}/junk.7z').list(),
          throwsA(isA<SevenZipException>()
              .having((e) => e.kind, 'kind', SevenZipError.isNotArc)));
      await expectLater(
          SevenZipArchive('${tmp.path}/a.7z').add([SevenZipSource(src.path)],
              options: const SevenZipOptions(method: 'BZip2')),
          throwsA(isA<SevenZipException>()));
      expect(File('${tmp.path}/a.7z').existsSync(), isFalse);
      expect(leftovers(), isEmpty);
    });

    test('cancellation', () async {
      final big = File('${tmp.path}/big.bin');
      final sink = big.openSync(mode: FileMode.write);
      for (var i = 0; i < 8; i++) {
        sink.writeFromSync(textData(40000, i));
      }
      sink.closeSync();
      final arc = SevenZipArchive('${tmp.path}/c.7z');
      await arc.add([SevenZipSource('${src.path}/a.txt')]);
      final before = File(arc.path).readAsBytesSync();

      final token = SevenZipCancelToken();
      final f = arc.add([SevenZipSource(big.path)],
          options: const SevenZipOptions(level: 9),
          onProgress: (p) => token.cancel(),
          cancel: token);
      await expectLater(
          f,
          throwsA(isA<SevenZipException>()
              .having((e) => e.kind, 'kind', SevenZipError.cancelled)));
      expect(File(arc.path).readAsBytesSync(), before);
      expect(leftovers(), isEmpty);

      // A cancelled token fails at once.
      await expectLater(arc.list().then((_) => arc.test(cancel: token)),
          throwsA(isA<SevenZipException>()));

      // Extraction: the file being written is removed. PPMd decodes
      // slowly enough for the cancellation to arrive in the middle.
      await arc.add([SevenZipSource(big.path)],
          options: const SevenZipOptions(method: 'PPMd'));
      final t2 = SevenZipCancelToken();
      await expectLater(
          arc.extract('${tmp.path}/xo', onProgress: (p) {
            if (p.doneBytes > 0) t2.cancel();
          }, cancel: t2),
          throwsA(isA<SevenZipException>()));
      expect(leftovers(), isEmpty);
    });
  });

  group('xz and lzma', () {
    late Uint8List data;
    late File input;
    setUp(() {
      final b = BytesBuilder();
      for (var i = 0; i < 6; i++) {
        b.add(textData(2000, i));
        b.add(pseudoRandom(5000, i));
      }
      data = b.toBytes();
      input = File('${tmp.path}/in.bin')..writeAsBytesSync(data);
    });

    for (final (name, sw, threads) in [
      ('4 threads, 40k blocks', ['s=40k'], 4),
      ('3 threads, BCJ, SHA-256', ['s=64k', 'f=BCJ', 'crc=32'], 3),
      ('2 threads, 1 block', ['s=16m'], 2),
      ('1 thread', <String>[], 1),
    ]) {
      test('parallel xz: $name, same bytes as the sequential path', () async {
        final out = '${tmp.path}/o.xz';
        final events = <SevenZipProgress>[];
        await xzCompressFile(input.path, out,
            level: 5, threads: threads, switches: sw, onProgress: events.add);
        final got = File(out).readAsBytesSync();
        // The sequential path of the same properties (XzEnc on one isolate).
        final ref = MemoryOutStream();
        XzArchive.create(MemoryInStream(data), ref, data.length,
            properties: CompressionOptions.parse(['x=5', ...sw, 'mt=$threads'])
                .properties);
        expect(got, ref.toBytes());
        expect(events.last.doneBytes, data.length);
        expect(xzDecompress(got), data);

        if (have7z) {
          final r7 = '${tmp.path}/r7.xz';
          final r = Process.runSync(sevenZ, [
            'a',
            '-txz',
            '-mx5',
            for (final s in sw) '-m$s',
            '-mmt=$threads',
            r7,
            input.path
          ]);
          expect(r.exitCode, 0, reason: '${r.stdout}');
          expect(got, File(r7).readAsBytesSync());
        }

        final back = '${tmp.path}/back.bin';
        await xzDecompressFile(out, back);
        expect(File(back).readAsBytesSync(), data);
        expect(leftovers(), isEmpty);
      });
    }

    test('lzma files and in memory helpers', () async {
      final out = '${tmp.path}/o.lzma';
      await lzmaCompressFile(input.path, out, properties: 'd=20');
      final packed = File(out).readAsBytesSync();
      expect(packed.length, lessThan(data.length));
      expect(lzmaDecompress(packed), data);
      await lzmaDecompressFile(out, '${tmp.path}/b.bin');
      expect(File('${tmp.path}/b.bin').readAsBytesSync(), data);
      expect(lzmaDecompress(lzmaCompress(data)), data);
      expect(xzDecompress(xzCompress(data, level: 1)), data);
      if (have7z) {
        final r = Process.runSync(sevenZ, ['t', out]);
        expect(r.exitCode, 0, reason: '${r.stdout}');
      }
    });

    test('corrupt xz fails and leaves no output', () async {
      final z = xzCompress(data);
      z[z.length ~/ 2] ^= 0x55;
      File('${tmp.path}/bad.xz').writeAsBytesSync(z);
      await expectLater(xzDecompressFile('${tmp.path}/bad.xz', '${tmp.path}/o'),
          throwsA(isA<SevenZipException>()));
      expect(File('${tmp.path}/o').existsSync(), isFalse);
      expect(leftovers(), isEmpty);
    });

    test('cancel parallel xz kills the workers', () async {
      final big = File('${tmp.path}/big.bin');
      final sink = big.openSync(mode: FileMode.write);
      for (var i = 0; i < 20; i++) {
        sink.writeFromSync(textData(40000, i));
      }
      sink.closeSync();
      final token = SevenZipCancelToken();
      final f = xzCompressFile(big.path, '${tmp.path}/big.xz',
          level: 9, threads: 2, switches: ['s=1m'], cancel: token);
      Timer(const Duration(milliseconds: 300), token.cancel);
      await expectLater(f, throwsA(isA<SevenZipException>()));
      expect(File('${tmp.path}/big.xz').existsSync(), isFalse);
      expect(leftovers(), isEmpty);
    });
  });
}
