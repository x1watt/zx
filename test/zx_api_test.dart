// Tests of the generic archive API (lib/src/zx_api.dart): every format the
// command line tool handles, through ZxArchive.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/zx.dart';

late Directory tmp;
late Directory src;
late Directory big;
var _n = 0;

String fresh(String name) {
  final d = Directory('${tmp.path}/t${_n++}')..createSync();
  return '${d.path}/$name';
}

Uint8List pseudoRandom(int n, int seed) {
  final rnd = Random(seed);
  final b = Uint8List(n);
  for (var i = 0; i < n; i++) {
    b[i] = rnd.nextInt(256);
  }
  return b;
}

/// The test tree: a.txt, dir/b.txt, dir/sub/c.txt, emptydir/.
void makeTree(Directory d) {
  File('${d.path}/a.txt').writeAsStringSync('hello\n');
  Directory('${d.path}/dir/sub').createSync(recursive: true);
  File('${d.path}/dir/b.txt').writeAsStringSync('bee ' * 300);
  File('${d.path}/dir/sub/c.txt').writeAsBytesSync(pseudoRandom(5000, 3));
  Directory('${d.path}/emptydir').createSync();
  File('${d.path}/d.txt').writeAsStringSync('deep file\n');
  File('${d.path}/x.txt').writeAsStringSync('added later\n');
}

/// The sources of the archives: the tree plus a file stored below folders
/// that have no entries (deep and deep/er are implied).
List<ZxSource> sources() => [
      ZxSource('${src.path}/a.txt'),
      ZxSource('${src.path}/dir'),
      ZxSource('${src.path}/emptydir'),
      ZxSource('${src.path}/d.txt', storedAs: 'deep/er/d.txt'),
    ];

/// Relative path to content (null for folders) below [root].
Map<String, String?> readTree(String root) {
  final r = <String, String?>{};
  for (final e in Directory(root).listSync(recursive: true)) {
    final rel = e.path.substring(root.length + 1);
    r[rel] = e is File ? base64.encode(e.readAsBytesSync()) : null;
  }
  return r;
}

String b64(String path) => base64.encode(File(path).readAsBytesSync());

class Fmt {
  final String file;
  final String format;
  final List<String> outer;

  /// Holds several items (the others are compressors of one file).
  final bool multi;
  final bool password;
  final bool headers;
  final bool comment;
  const Fmt(this.file, this.format,
      {this.outer = const [],
      this.multi = true,
      this.password = false,
      this.headers = false,
      this.comment = false});
}

const formats = [
  Fmt('x.7z', '7z', password: true, headers: true),
  Fmt('x.zip', 'zip', password: true, comment: true),
  Fmt('x.jar', 'zip', comment: true),
  Fmt('x.rar', 'Rar5', password: true, headers: true, comment: true),
  Fmt('x.tar', 'tar'),
  Fmt('x.tar.gz', 'tar', outer: ['gzip']),
  Fmt('x.tgz', 'tar', outer: ['gzip']),
  Fmt('x.tar.bz2', 'tar', outer: ['bzip2']),
  Fmt('x.tar.xz', 'tar', outer: ['xz']),
  Fmt('x.lzh', 'Lzh'),
  Fmt('x.arj', 'Arj', password: true),
  Fmt('x.gz', 'gzip', multi: false),
  Fmt('x.bz2', 'bzip2', multi: false),
  Fmt('x.xz', 'xz', multi: false),
  Fmt('x.lzma', 'lzma', multi: false),
];

void main() {
  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('zx_api_test');
    src = Directory('${tmp.path}/src')..createSync();
    makeTree(src);
    // a file for the cancel tests: incompressible, 6 MB
    big = Directory('${tmp.path}/big')..createSync();
    final f = File('${big.path}/big.bin').openSync(mode: FileMode.write);
    for (var i = 0; i < 6; i++) {
      f.writeFromSync(pseudoRandom(1 << 20, 100 + i));
    }
    f.closeSync();
  });
  tearDownAll(() => tmp.deleteSync(recursive: true));

  for (final fmt in formats) {
    group(fmt.file, () {
      if (fmt.multi) {
        multiItemTests(fmt);
      } else {
        singleFileTests(fmt);
      }
      cancelTests(fmt);
    });
  }

  group('general', generalTests);
}

void multiItemTests(Fmt fmt) {
  late ZxArchive a;
  late String path;

  setUpAll(() async {
    path = fresh(fmt.file);
    final events = <ZxProgress>[];
    a = await ZxArchive.create(path, sources(), onProgress: events.add);
    expect(events, isNotEmpty);
  });

  test('list with implied folders', () {
    expect(a.format, fmt.format);
    expect(a.outerFormats, fmt.outer);
    expect(a.errors, isEmpty);
    final paths = {for (final i in a.items) i.path: i};
    expect(paths.keys.toSet(), {
      'a.txt',
      'dir',
      'dir/b.txt',
      'dir/sub',
      'dir/sub/c.txt',
      'emptydir',
      'deep',
      'deep/er',
      'deep/er/d.txt',
    });
    expect(paths['deep']!.isImplied, isTrue);
    expect(paths['deep/er']!.isImplied, isTrue);
    expect(paths['deep']!.index, -1);
    expect(paths['dir']!.isImplied, isFalse);
    expect(paths['dir']!.isDir, isTrue);
    expect(paths['dir/sub/c.txt']!.size, 5000);
    expect(paths['a.txt']!.modified, isNotNull);
    expect(a.children('').map((i) => i.name).toSet(),
        {'a.txt', 'dir', 'emptydir', 'deep'});
    expect(a.children('deep/er').single.name, 'd.txt');
    expect(a['dir/sub/c.txt']!.parent, 'dir/sub');
    expect(a.capabilities.canAdd, isTrue);
    expect(a.capabilities.canSetComment, fmt.comment);
  });

  test('extract all, with progress', () async {
    final out = fresh('out');
    final events = <ZxProgress>[];
    final r = await a.extract(out, onProgress: events.add);
    expect(r.ok, isTrue, reason: '$r');
    expect(r.files, 4);
    expect(events, isNotEmpty);
    expect(events.last.doneBytes, events.last.totalBytes);
    final t = readTree(out);
    expect(t['a.txt'], b64('${src.path}/a.txt'));
    expect(t['dir/sub/c.txt'], b64('${src.path}/dir/sub/c.txt'));
    expect(t['deep/er/d.txt'], b64('${src.path}/d.txt'));
    expect(t.containsKey('emptydir'), isTrue);
    expect(t.keys.where((k) => k.endsWith('.zx-part')), isEmpty);
    final m = File('$out/a.txt').statSync().modified;
    expect(m.difference(a['a.txt']!.modified!).inSeconds.abs() <= 2, isTrue);
  });

  test('extract a folder, without and with its path', () async {
    final out = fresh('out');
    var r = await a.extract(out, items: ['dir/sub'], relativeTo: 'dir');
    expect(r.ok, isTrue, reason: '$r');
    expect(readTree(out).keys.toSet(), {'sub', 'sub/c.txt'});
    final out2 = fresh('out');
    r = await a.extract(out2, items: [a['deep']!]);
    expect(r.files, 1);
    expect(readTree(out2).keys.toSet(), {'deep', 'deep/er', 'deep/er/d.txt'});
    final out3 = fresh('out');
    r = await a.extract(out3, items: ['dir'], keepPaths: false);
    expect(readTree(out3).keys.toSet(), {'b.txt', 'c.txt'});
  });

  test('extract to temp, readBytes, test', () async {
    final p = await a.extractToTemp('dir/sub/c.txt');
    expect(b64(p), b64('${src.path}/dir/sub/c.txt'));
    File(p).parent.deleteSync(recursive: true);
    final head = await a.readBytes(a['dir/b.txt']!, maxBytes: 7);
    expect(utf8.decode(head), 'bee bee');
    final all = await a.readBytes('a.txt');
    expect(utf8.decode(all), 'hello\n');
    final r = await a.test();
    expect(r.ok, isTrue);
    expect(r.files, 4);
    expect(r.bytes, 6 + 1200 + 5000 + 10);
  });

  test('add into a subfolder, delete a folder, rename, create a folder',
      () async {
    final p = fresh(fmt.file);
    File(path).copySync(p);
    final b = await ZxArchive.open(p);
    var u =
        await b.add([ZxSource('${src.path}/x.txt')], destination: 'dir/sub');
    expect(u.added, 1);
    expect(b['dir/sub/x.txt'], isNotNull);
    expect(b['dir/sub/x.txt']!.size, 12);

    u = await b.delete(['dir/sub']);
    expect(u.changed, 3);
    expect(b['dir/sub'], isNull);
    expect(b['dir/sub/c.txt'], isNull);
    expect(b['dir/b.txt'], isNotNull);

    await b.rename('a.txt', 'a2.txt');
    expect(b['a.txt'], isNull);
    expect(b['a2.txt']!.size, 6);
    await b.rename('dir', 'renamed/inner');
    expect(b['dir'], isNull);
    expect(b['renamed/inner/b.txt'], isNotNull);
    expect(b['renamed']!.isImplied, isTrue);

    await b.createFolder('new folder');
    expect(b['new folder']!.isDir, isTrue);
    expect(b['new folder']!.isImplied, isFalse);

    final out = fresh('out');
    final r = await b.extract(out);
    expect(r.ok, isTrue, reason: '$r');
    final t = readTree(out);
    expect(t['a2.txt'], b64('${src.path}/a.txt'));
    expect(t['renamed/inner/b.txt'], b64('${src.path}/dir/b.txt'));
    expect(t.containsKey('new folder'), isTrue);
    expect(t.containsKey('renamed/inner/sub'), isFalse);
    // no temporary files next to the archive
    expect(File(p).parent.listSync().map((e) => e.path).toList(), [p]);
  });

  if (fmt.comment) {
    test('comment', () async {
      final p = fresh(fmt.file);
      File(path).copySync(p);
      final b = await ZxArchive.open(p);
      await b.setComment('a comment');
      expect(b.comment, 'a comment');
      final c = await ZxArchive.open(p);
      expect(c.comment, 'a comment');
      expect(c.items.length, a.items.length);
      await c.setComment(null);
      expect(c.comment, isNull);
    });
  }

  if (fmt.password) {
    test('password: data', () async {
      final p = fresh(fmt.file);
      final e = await ZxArchive.create(p, sources(),
          options: const ZxOptions(password: 'secret'));
      expect(e['dir/b.txt']!.encrypted, isTrue);

      // wrong, then no more answers
      final asked = <ZxPasswordRequest>[];
      var w = await ZxArchive.open(p, onPassword: (r) async {
        asked.add(r);
        return asked.length == 1 ? 'wrong' : null;
      });
      var r = await w.extract(fresh('out'));
      expect(r.wrongPassword, isTrue, reason: '$r');
      expect(asked.length, 2);
      expect(asked[0].reason, ZxPasswordReason.extract);
      expect(asked[1].retry, isTrue);

      // wrong, then right
      asked.clear();
      w = await ZxArchive.open(p, onPassword: (r) async {
        asked.add(r);
        return asked.length == 1 ? 'wrong' : 'secret';
      });
      final out = fresh('out');
      r = await w.extract(out);
      expect(r.ok, isTrue, reason: '$r');
      expect(readTree(out)['dir/sub/c.txt'], b64('${src.path}/dir/sub/c.txt'));
      expect(w.password, 'secret');
      // remembered by the handle
      expect(utf8.decode(await w.readBytes('a.txt')), 'hello\n');

      // an update that has to decode encrypted data (7z: the solid block
      // is packed again without the deleted items) asks for the password
      final p2 = fresh(fmt.file);
      File(p).copySync(p2);
      final asked2 = <ZxPasswordRequest>[];
      final d = await ZxArchive.open(p2, onPassword: (r) async {
        asked2.add(r);
        return 'secret';
      });
      await d.delete(['dir/sub']);
      expect(d['dir/sub'], isNull);
      if (fmt.format == '7z') {
        expect(asked2.map((r) => r.reason), contains(ZxPasswordReason.update));
      }
      final r3 = await d.extract(fresh('out'));
      expect(r3.ok, isTrue, reason: '$r3');
      expect(r3.files, 3);
      expect(d['dir/b.txt']!.encrypted, isTrue);

      // no callback, no password
      final n = await ZxArchive.open(p);
      r = await n.test();
      expect(r.wrongPassword, isTrue);
      await expectLater(
          n.readBytes('a.txt'),
          throwsA(isA<SevenZipException>()
              .having((e) => e.kind, 'kind', SevenZipError.wrongPassword)));
    });
  }

  if (fmt.headers) {
    test('password: encrypted names', () async {
      final p = fresh(fmt.file);
      await ZxArchive.create(p, sources(),
          options: const ZxOptions(password: 'secret', encryptHeaders: true));
      await expectLater(
          ZxArchive.open(p),
          throwsA(isA<SevenZipException>()
              .having((e) => e.kind, 'kind', SevenZipError.wrongPassword)));
      await expectLater(
          ZxArchive.open(p, onPassword: (r) async => null),
          throwsA(isA<SevenZipException>()
              .having((e) => e.kind, 'kind', SevenZipError.cancelled)));
      final asked = <ZxPasswordRequest>[];
      final b = await ZxArchive.open(p, onPassword: (r) async {
        asked.add(r);
        return asked.length == 1 ? 'wrong' : 'secret';
      });
      expect(asked.length, 2);
      expect(asked[0].reason, ZxPasswordReason.open);
      expect(asked[1].retry, isTrue);
      expect(b.encryptedHeaders, isTrue);
      expect(b['dir/sub/c.txt'], isNotNull);
      final r = await b.test();
      expect(r.ok, isTrue, reason: '$r');
      // an update keeps working with the password of the handle
      await b.rename('a.txt', 'b.txt');
      expect(b['b.txt'], isNotNull);
      final c = await ZxArchive.open(p, password: 'secret');
      expect(c['b.txt'], isNotNull);
    });
  }
}

void singleFileTests(Fmt fmt) {
  late ZxArchive a;
  test('create, list, extract, readBytes, test', () async {
    final p = fresh(fmt.file);
    final events = <ZxProgress>[];
    a = await ZxArchive.create(p, [ZxSource('${src.path}/dir/sub/c.txt')],
        onProgress: events.add);
    expect(events, isNotEmpty);
    expect(a.format, fmt.format);
    expect(a.items.length, 1);
    expect(a.items.single.isDir, isFalse);
    expect(a.capabilities.canAdd, isFalse);
    expect(a.capabilities.canDelete, isFalse);
    expect(a.capabilities.canRename, fmt.format == 'gzip');

    final out = fresh('out');
    final r = await a.extract(out);
    expect(r.ok, isTrue, reason: '$r');
    final files = Directory(out).listSync();
    expect(files.length, 1);
    expect(b64(files.single.path), b64('${src.path}/dir/sub/c.txt'));

    final t = await a.extractToTemp(a.items.single);
    expect(b64(t), b64('${src.path}/dir/sub/c.txt'));
    File(t).parent.deleteSync(recursive: true);

    final head = await a.readBytes(a.items.single.index, maxBytes: 100);
    expect(head,
        File('${src.path}/dir/sub/c.txt').readAsBytesSync().sublist(0, 100));
    final tr = await a.test();
    expect(tr.ok, isTrue);
    expect(tr.bytes, 5000);
    await expectLater(a.add([ZxSource('${src.path}/a.txt')]),
        throwsA(isA<SevenZipException>()));
    if (fmt.format == 'gzip') {
      await a.rename(a.items.single.path, 'renamed.bin');
      expect(a.items.single.path, 'renamed.bin');
    }
  });
}

void cancelTests(Fmt fmt) {
  test('cancel while creating and extracting', () async {
    // creating: cancelled at the first progress event
    final dir = File(fresh('c')).parent.path;
    final p = '$dir/${fmt.file}';
    final token = ZxCancelToken();
    final events = <ZxProgress>[];
    await expectLater(
        ZxArchive.create(p, [ZxSource('${big.path}/big.bin')],
            options: const ZxOptions(level: 1), onProgress: (e) {
          // the first event comes when the work starts
          events.add(e);
          token.cancel();
        }, cancel: token),
        throwsA(isA<SevenZipException>()
            .having((e) => e.kind, 'kind', SevenZipError.cancelled)));
    expect(events, isNotEmpty);
    expect(Directory(dir).listSync(), isEmpty);

    // extracting: a stored archive of the big file
    final a = await ZxArchive.create(p, [ZxSource('${big.path}/big.bin')],
        options: const ZxOptions(level: 0));
    final out = fresh('out');
    final t2 = ZxCancelToken();
    await expectLater(
        a.extract(out, onProgress: (e) => t2.cancel(), cancel: t2),
        throwsA(isA<SevenZipException>()
            .having((e) => e.kind, 'kind', SevenZipError.cancelled)));
    expect(
        Directory(out).existsSync() ? Directory(out).listSync() : [], isEmpty);
  });
}

void generalTests() {
  test('overwrite: ask, skip, rename', () async {
    final p = fresh('o.zip');
    final a = await ZxArchive.create(p, sources());
    final out = fresh('out');
    await a.extract(out);
    File('$out/a.txt').writeAsStringSync('mine');

    final asked = <ZxOverwriteRequest>[];
    var r = await a.extract(out, overwrite: ZxOverwrite.ask,
        onOverwrite: (q) async {
      asked.add(q);
      return ZxOverwriteAnswer.skipAll;
    });
    expect(asked.length, 1);
    expect(asked.single.itemPath, 'a.txt');
    expect(asked.single.existingSize, 4);
    expect(asked.single.newSize, 6);
    expect(r.skipped, 4);
    expect(File('$out/a.txt').readAsStringSync(), 'mine');

    r = await a.extract(out, items: ['a.txt'], overwrite: ZxOverwrite.rename);
    expect(File('$out/a_1.txt').readAsStringSync(), 'hello\n');
    expect(File('$out/a.txt').readAsStringSync(), 'mine');

    await expectLater(
        a.extract(out,
            overwrite: ZxOverwrite.ask,
            onOverwrite: (q) async => ZxOverwriteAnswer.cancel),
        throwsA(isA<SevenZipException>()
            .having((e) => e.kind, 'kind', SevenZipError.cancelled)));

    r = await a.extract(out,
        items: ['a.txt'],
        overwrite: ZxOverwrite.ask,
        onOverwrite: (q) async => ZxOverwriteAnswer.overwrite);
    expect(File('$out/a.txt').readAsStringSync(), 'hello\n');

    // two items to the same name without paths
    final p2 = fresh('dup.zip');
    final d = await ZxArchive.create(p2, [
      ZxSource('${src.path}/a.txt', storedAs: 'x/a.txt'),
      ZxSource('${src.path}/x.txt', storedAs: 'y/a.txt'),
    ]);
    final out2 = fresh('out');
    asked.clear();
    r = await d.extract(out2, keepPaths: false, overwrite: ZxOverwrite.ask,
        onOverwrite: (q) async {
      asked.add(q);
      return ZxOverwriteAnswer.rename;
    });
    expect(asked.single.itemPath, 'y/a.txt');
    expect(asked.single.existingSize, isNull);
    expect(readTree(out2), {
      'a.txt': b64('${src.path}/a.txt'),
      'a_1.txt': b64('${src.path}/x.txt'),
    });
  });

  test('symbolic links and modes', () async {
    if (Platform.isWindows) return;
    final d = Directory(fresh('links'))..createSync();
    File('${d.path}/target.txt').writeAsStringSync('target');
    Link('${d.path}/link').createSync('target.txt');
    Link('${d.path}/evil').createSync('../../outside');
    Process.runSync('chmod', ['0751', '${d.path}/target.txt']);
    for (final name in ['l.tar', 'l.zip', 'l.7z', 'l.rar']) {
      final p = fresh(name);
      final a = await ZxArchive.create(p, [ZxSource(d.path, storedAs: '')],
          options: const ZxOptions(storeSymlinks: true));
      expect(a['link']!.isSymlink, isTrue, reason: name);
      final out = fresh('out');
      final r = await a.extract(out);
      expect(FileSystemEntity.isLinkSync('$out/link'), isTrue, reason: name);
      expect(Link('$out/link').targetSync(), 'target.txt');
      expect(File('$out/link').readAsStringSync(), 'target');
      expect(FileSystemEntity.typeSync('$out/evil', followLinks: false),
          FileSystemEntityType.notFound,
          reason: name);
      expect(r.errors.map((e) => e.path), contains('evil'), reason: name);
      expect(File('$out/target.txt').statSync().mode & 0x1FF, 0x1E9,
          reason: name); // 0751
    }
  });

  test('volumes: 7z and rar', () async {
    for (final name in ['v.7z', 'v.rar']) {
      final p = fresh(name);
      final a = await ZxArchive.create(p, [ZxSource('${src.path}/dir')],
          options: const ZxOptions(level: 0, volumeSize: 2048));
      expect(a.volumes.length, greaterThan(1), reason: name);
      expect(a.capabilities.canUpdate, isFalse);
      final b = await ZxArchive.open(a.path);
      final out = fresh('out');
      final r = await b.extract(out);
      expect(r.ok, isTrue, reason: '$r');
      expect(readTree(out)['dir/sub/c.txt'], b64('${src.path}/dir/sub/c.txt'));
    }
  });

  test('errors: not an archive, missing file, CRC error', () async {
    final p = fresh('plain.bin');
    File(p).writeAsStringSync('not an archive at all');
    await expectLater(
        ZxArchive.open(p),
        throwsA(isA<SevenZipException>()
            .having((e) => e.kind, 'kind', SevenZipError.isNotArc)));
    await expectLater(
        ZxArchive.open('${tmp.path}/missing.7z'),
        throwsA(isA<SevenZipException>()
            .having((e) => e.kind, 'kind', SevenZipError.io)));

    final z = fresh('bad.zip');
    await ZxArchive.create(z, [ZxSource('${src.path}/dir')],
        options: const ZxOptions(level: 0));
    final bytes = File(z).readAsBytesSync();
    // a byte of the stored data of dir/sub/c.txt
    final c = File('${src.path}/dir/sub/c.txt').readAsBytesSync();
    final at = _indexOf(bytes, c.sublist(0, 16));
    expect(at, greaterThan(0));
    bytes[at + 100] ^= 0xFF;
    File(z).writeAsBytesSync(bytes);
    final a = await ZxArchive.open(z);
    final r = await a.test();
    expect(r.errors.single.path, 'dir/sub/c.txt');
    expect(r.errors.single.kind, SevenZipError.crc);
    final out = fresh('out');
    final r2 = await a.extract(out);
    expect(r2.errors.single.kind, SevenZipError.crc);
    expect(File('$out/dir/sub/c.txt').existsSync(), isFalse);
    expect(File('$out/dir/b.txt').existsSync(), isTrue);
  });

  test('the 7z API still works', () async {
    final p = fresh('s.7z');
    await SevenZipArchive(p).add([SevenZipSource('${src.path}/dir')]);
    final a = await ZxArchive.open(p);
    expect(a['dir/sub/c.txt']!.size, 5000);
  });
}

int _indexOf(Uint8List h, List<int> n) {
  outer:
  for (var i = 0; i + n.length <= h.length; i++) {
    for (var j = 0; j < n.length; j++) {
      if (h[i + j] != n[j]) continue outer;
    }
    return i;
  }
  return -1;
}
