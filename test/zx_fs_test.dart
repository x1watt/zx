// Tests of ZxFs (lib/src/mount/zx_fs.dart): an archive as a file system,
// reading, writing and committing, without FUSE.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/mount/zx_fs.dart';
import 'package:zx/zx.dart';

late Directory tmp;
var _n = 0;

Uint8List b(String s) => Uint8List.fromList(utf8.encode(s));

Future<(ZxArchive, ZxFs)> mountOf(String ext, {bool readOnly = false}) async {
  final d = Directory('${tmp.path}/m${_n++}')..createSync();
  final src = Directory('${d.path}/src')..createSync();
  File('${src.path}/a.txt').writeAsStringSync('hello\n');
  Directory('${src.path}/dir/sub').createSync(recursive: true);
  File('${src.path}/dir/b.txt').writeAsStringSync('bee ' * 300);
  File('${src.path}/dir/sub/c.txt').writeAsStringSync('see');
  final ar = await ZxArchive.create('${d.path}/x.$ext', [
    ZxSource('${src.path}/a.txt'),
    ZxSource('${src.path}/dir'),
  ]);
  final fs = ZxFs(ZxArchiveBackend(ar),
      ZxFsOptions('${d.path}/work', readOnly: readOnly, idleCommit: null));
  return (ar, fs);
}

Future<String> readAll(ZxFs fs, String path) async {
  final fh = await fs.open(path);
  final out = BytesBuilder();
  var off = 0;
  while (true) {
    final c = fs.read(fh, off, 4096);
    if (c.isEmpty) break;
    out.add(c);
    off += c.length;
  }
  fs.release(fh);
  return utf8.decode(out.toBytes());
}

void main() {
  setUpAll(() => tmp = Directory.systemTemp.createTempSync('zxfs_'));
  tearDownAll(() => tmp.deleteSync(recursive: true));

  for (final ext in ['zx', '7z']) {
    group(ext, () {
      test('lists and reads', () async {
        final (_, fs) = await mountOf(ext);
        expect(fs.readdir('/').map((e) => e.$1).toSet(), {'a.txt', 'dir'});
        expect(fs.getattr('/dir').isDir, isTrue);
        expect(fs.getattr('/dir/b.txt').size, 1200);
        expect(await readAll(fs, '/a.txt'), 'hello\n');
        expect(await readAll(fs, '/dir/sub/c.txt'), 'see');
        expect(() => fs.getattr('/nope'),
            throwsA(isA<FsError>().having((e) => e.errno, 'errno', 2)));
        final fh = await fs.open('/dir/b.txt');
        expect(utf8.decode(fs.read(fh, 4, 4)), 'bee ');
        expect(fs.read(fh, 5000, 10), isEmpty);
        fs.release(fh);
        await fs.close();
      });

      test('writes, renames, deletes and commits', () async {
        final (ar, fs) = await mountOf(ext);
        // new file
        var fh = await fs.create('/new.txt');
        fs.write(fh, 0, b('abc'));
        fs.write(fh, 3, b('def'));
        fs.release(fh);
        expect(fs.getattr('/new.txt').size, 6);
        // change an existing one
        fh = await fs.open('/a.txt', write: true);
        fs.write(fh, 0, b('J'));
        fs.release(fh);
        expect(await readAll(fs, '/a.txt'), 'Jello\n');
        await fs.mkdir('/emptydir');
        await fs.rename('/dir/b.txt', '/dir/sub/moved.txt');
        await fs.remove('/dir/sub/c.txt', dir: false);
        expect(fs.hasChanges, isTrue);
        await fs.commit();
        expect(fs.hasChanges, isFalse);

        // what the archive holds now
        final ar2 = await ZxArchive.open(ar.path);
        expect(ar2['new.txt']?.size, 6);
        expect(ar2['dir/sub/moved.txt']?.size, 1200);
        expect(ar2['dir/b.txt'], isNull);
        expect(ar2['dir/sub/c.txt'], isNull);
        expect(ar2['emptydir']?.isDir, isTrue);
        expect(utf8.decode(await ar2.readBytes('a.txt')), 'Jello\n');
        // and the mount still reads it
        expect(await readAll(fs, '/new.txt'), 'abcdef');
        expect(await readAll(fs, '/dir/sub/moved.txt'), 'bee ' * 300);
        expect(await fs.close(), isNull);
      });

      test('truncate, recreate, errors', () async {
        final (_, fs) = await mountOf(ext);
        await fs.truncate('/dir/b.txt', 10);
        expect(fs.getattr('/dir/b.txt').size, 10);
        expect(await readAll(fs, '/dir/b.txt'), 'bee bee be');
        await expectLater(fs.remove('/dir', dir: true),
            throwsA(isA<FsError>().having((e) => e.errno, 'errno', 39)));
        await expectLater(fs.open('/dir'),
            throwsA(isA<FsError>().having((e) => e.errno, 'errno', 21)));
        await expectLater(fs.create('/nodir/x'),
            throwsA(isA<FsError>().having((e) => e.errno, 'errno', 2)));
        // a file created and deleted before a commit never reaches the archive
        final fh = await fs.create('/tmp.txt');
        fs.release(fh);
        await fs.remove('/tmp.txt', dir: false);
        await fs.commit();
        expect(await fs.close(), isNull);
      });
    });
  }

  test('read only', () async {
    final (_, fs) = await mountOf('zx', readOnly: true);
    await expectLater(fs.create('/x'),
        throwsA(isA<FsError>().having((e) => e.errno, 'errno', 30)));
    await expectLater(fs.open('/a.txt', write: true),
        throwsA(isA<FsError>().having((e) => e.errno, 'errno', 30)));
    expect(await readAll(fs, '/a.txt'), 'hello\n');
    await fs.close();
  });
}
