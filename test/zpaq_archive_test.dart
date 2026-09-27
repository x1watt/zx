// Vendored from zpaq-flutter by tool/sync_zpaq.sh: do not edit here, change
// zpaq-flutter and sync again. Pure Dart port of libzpaq and zpaq 7.15 (Matt
// Mahoney, public domain) with the zpaqfranz attribute format (Franco
// Corbelli, MIT). Copyright (c) 2026 Max Brito, BSD 3-clause; see LICENSE
// for the license and the third party notices.

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/zpaq/core/io.dart';
import 'package:zx/src/zpaq/core/method.dart';
import 'package:zx/src/zpaq/zpaq.dart';

late Directory tmp;

String p(String rel) => '${tmp.path}/$rel';

void writeFile(String rel, List<int> data) {
  final f = File(p(rel));
  f.parent.createSync(recursive: true);
  f.writeAsBytesSync(data);
}

Uint8List randomBytes(int n, int seed) {
  final r = Random(seed);
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

Uint8List textBytes(int n, int seed) {
  final r = Random(seed);
  const words = ['zpaq', 'backup', 'flutter', 'dart', 'version', 'data', ' '];
  final sb = StringBuffer();
  while (sb.length < n) {
    sb.write(words[r.nextInt(words.length)]);
    sb.write(' ');
  }
  return Uint8List.fromList(sb.toString().substring(0, n).codeUnits);
}

/// Content of every regular file under [dir], by relative path.
Map<String, List<int>> snapshot(String dir) {
  final out = <String, List<int>>{};
  final base = Directory(dir);
  if (!base.existsSync()) return out;
  for (final e in base.listSync(recursive: true, followLinks: false)) {
    if (e is File) {
      out[e.path.substring(dir.length + 1)] = e.readAsBytesSync();
    }
  }
  return out;
}

void main() {
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('zpaq_test_');
  });
  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  test('add, list, extract, incremental versions, deletion, dedup', () async {
    writeFile('src/a.txt', textBytes(50000, 1));
    writeFile('src/sub/b.bin', randomBytes(200000, 2));
    writeFile('src/sub/empty', []);
    Directory(p('src/emptydir')).createSync(recursive: true);
    final v1 = snapshot(p('src'));

    final arc = ZpaqArchive(p('backup.zpaq'));
    final sources = [ZpaqSource(p('src'), storedAs: 'src')];
    final r1 = await arc.add(sources);
    expect(r1.version, 1);
    expect(r1.added, 6); // src/, src/sub/, src/emptydir/ and 3 files

    // v2: modify, add, delete
    writeFile('src/a.txt', textBytes(60000, 3));
    writeFile('src/c.bin', randomBytes(1000, 4));
    File(p('src/sub/b.bin')).deleteSync();
    await Future<void>.delayed(const Duration(seconds: 1));
    final r2 = await arc.add(sources);
    expect(r2.version, 2);
    expect(r2.removed, 1);
    final v2 = snapshot(p('src'));

    // v3: a copy of existing content is deduplicated
    writeFile('src/copy.txt', File(p('src/a.txt')).readAsBytesSync());
    final r3 = await arc.add(sources);
    expect(r3.version, 3);
    expect(r3.inputBytes, 60000);
    expect(r3.dedupedBytes, 0);

    // no change: no version
    final size = File(p('backup.zpaq')).lengthSync();
    final r4 = await arc.add(sources);
    expect(r4.version, 0);
    expect(File(p('backup.zpaq')).lengthSync(), size);

    final l = await arc.list();
    expect(l.versions.length, 3);
    expect(
        l.entries.map((e) => e.name),
        containsAll([
          'src/',
          'src/a.txt',
          'src/c.bin',
          'src/copy.txt',
          'src/emptydir/'
        ]));
    expect(l.entries.any((e) => e.name == 'src/sub/b.bin'), isFalse);
    final a = l.entries.firstWhere((e) => e.name == 'src/a.txt');
    expect(a.size, 60000);
    expect(a.franz?.hashType, 'XXHASH64');
    expect(a.franz?.crc32, isNotEmpty);

    final l1 = await arc.list(version: 1);
    expect(l1.versions.length, 1);
    expect(l1.entries.any((e) => e.name == 'src/sub/b.bin'), isTrue);

    final all = await arc.list(allVersions: true);
    expect(all.history!.where((e) => e.isDeleted).map((e) => e.name),
        ['src/sub/b.bin']);

    // Extract each version and compare
    var x = await arc.extract(p('out1'), version: 1);
    expect(x.ok, isTrue, reason: x.errors.join('\n'));
    expect(snapshot(p('out1/src')), v1);
    expect(Directory(p('out1/src/emptydir')).existsSync(), isTrue);
    x = await arc.extract(p('out2'), version: 2);
    expect(snapshot(p('out2/src')), v2);
    x = await arc.extract(p('out3'), threads: 2);
    expect(snapshot(p('out3/src')), snapshot(p('src')));

    // Selective extract and single file read
    x = await arc.extract(p('out4'), paths: ['src/sub']);
    expect(snapshot(p('out4')).keys, ['src/sub/empty']);
    expect(await arc.readFile('src/c.bin'),
        File(p('src/c.bin')).readAsBytesSync());
    expect(await arc.readFile('src/sub/b.bin', version: 1), v1['sub/b.bin']);

    final t = await arc.verify();
    expect(t.ok, isTrue);
    expect(t.files, 4);
  });

  for (final m in ['0', '1', '2', '3', '4', '5']) {
    test('method $m round trip', () async {
      writeFile('d/t.txt', textBytes(30000, 5));
      writeFile('d/r.bin', randomBytes(20000, 6));
      writeFile('d/z.bin', List.filled(40000, 0));
      final arc = ZpaqArchive(p('m$m.zpaq'));
      await arc.add([ZpaqSource(p('d'), storedAs: 'd')],
          options: ZpaqAddOptions(method: m, threads: 1));
      final x = await arc.extract(p('o'));
      expect(x.ok, isTrue);
      expect(snapshot(p('o/d')), snapshot(p('d')));
    });
  }

  test('SHA-1 file hashes on request, kept on metadata only updates', () async {
    writeFile('s/a.txt', textBytes(10000, 15));
    final arc = ZpaqArchive(p('h.zpaq'));
    final opts = const ZpaqAddOptions(fileHash: ZpaqFileHash.sha1);
    await arc.add([ZpaqSource(p('s'), storedAs: 's')], options: opts);
    var e = (await arc.list()).entries.firstWhere((e) => e.name == 's/a.txt');
    expect(e.franz?.hashType, 'SHA-1');
    expect(e.franz?.hash.length, 40);
    // same content, new date: rewritten without reading, hash carried over
    File(p('s/a.txt'))
        .setLastModifiedSync(DateTime.now().add(const Duration(hours: 1)));
    final r = await arc.add([ZpaqSource(p('s'), storedAs: 's')], options: opts);
    expect(r.updated, greaterThan(0));
    final e2 =
        (await arc.list()).entries.firstWhere((e) => e.name == 's/a.txt');
    expect(e2.franz?.hash, e.franz?.hash);
    expect(e2.version, 2);
  });

  test('encrypted archive', () async {
    writeFile('s/secret.txt', textBytes(10000, 7));
    final arc = ZpaqArchive(p('enc.zpaq'), password: 'correct horse');
    await arc.add([ZpaqSource(p('s'), storedAs: 's')]);
    writeFile('s/more.txt', textBytes(100, 8));
    await arc.add([ZpaqSource(p('s'), storedAs: 's')]);
    // no plaintext in the file
    final raw = String.fromCharCodes(File(p('enc.zpaq')).readAsBytesSync());
    expect(raw.contains('jDC'), isFalse);
    expect((await arc.list()).versions.length, 2);
    await expectLater(ZpaqArchive(p('enc.zpaq'), password: 'wrong').list(),
        throwsA(isA<ZpaqException>()));
    await expectLater(
        ZpaqArchive(p('enc.zpaq')).list(), throwsA(isA<ZpaqException>()));
    final x = await arc.extract(p('o'));
    expect(x.ok, isTrue);
    expect(snapshot(p('o/s')), snapshot(p('s')));
  });

  test('an interrupted update is ignored and overwritten', () async {
    writeFile('s/a.txt', textBytes(5000, 9));
    final arc = ZpaqArchive(p('i.zpaq'));
    await arc.add([ZpaqSource(p('s'), storedAs: 's')]);
    final good = File(p('i.zpaq')).lengthSync();

    // Simulate a crash: a transaction header with size -1, then junk.
    final junk = ZBuffer();
    final hdr = ZBuffer(8)..putLE(-1, 8);
    compressBlock(hdr, junk, '0',
        filename: 'jDC20990101000000c0000000001', comment: 'jDC\x01');
    junk.addAll(randomBytes(3000, 10));
    File(p('i.zpaq')).writeAsBytesSync(junk.bytes, mode: FileMode.append);

    final l = await arc.list();
    expect(l.versions.length, 1);
    expect(l.incomplete, isTrue);

    writeFile('s/b.txt', textBytes(100, 11));
    final r = await arc.add([ZpaqSource(p('s'), storedAs: 's')]);
    expect(r.version, 2);
    final l2 = await arc.list();
    expect(l2.incomplete, isFalse);
    expect(l2.versions.length, 2);
    expect(File(p('i.zpaq')).lengthSync(), greaterThan(good));
    final x = await arc.extract(p('o'));
    expect(x.ok, isTrue);
    expect(snapshot(p('o/s')), snapshot(p('s')));
  });

  test('damaged data is reported, not extracted', () async {
    writeFile('s/a.bin', randomBytes(100000, 12));
    final arc = ZpaqArchive(p('d.zpaq'));
    await arc.add([ZpaqSource(p('s'), storedAs: 's')],
        options: const ZpaqAddOptions(method: '0'));
    final bytes = File(p('d.zpaq')).readAsBytesSync();
    bytes[5000] ^= 0x55; // inside the stored data block
    File(p('d.zpaq')).writeAsBytesSync(bytes);
    final t = await arc.verify();
    expect(t.ok, isFalse);
    final x = await arc.extract(p('o'));
    expect(x.ok, isFalse);
    expect(File(p('o/s/a.bin')).existsSync(), isFalse);
    expect(File(p('o/s/a.bin.zpaq-part')).existsSync(), isFalse);
  });

  test('progress is reported', () async {
    writeFile('s/a.bin', randomBytes(3000000, 13));
    final arc = ZpaqArchive(p('pr.zpaq'));
    final events = <ZpaqAddProgress>[];
    await arc.add([ZpaqSource(p('s'), storedAs: 's')], onProgress: events.add);
    expect(events, isNotEmpty);
    expect(events.last.doneBytes, 3000000);
  });

  test('raw stream codec', () {
    for (final m in ['0', '1', '3', '5']) {
      final data = textBytes(100000, 14);
      final z = zpaqCompress(data, method: m, blockSize: 40000);
      expect(zpaqDecompress(z), data);
    }
    expect(zpaqDecompress(zpaqCompress(Uint8List(0))), isEmpty);
  });
}
