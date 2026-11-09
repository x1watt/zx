// The browser's files (lib/src/host/web_fs.dart), on the VM: the dart:io
// subset the database uses, and the change list a host persists.
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/host/web_fs.dart' as w;

void main() {
  final fs = w.ZxWebFs.instance;
  setUp(fs.reset);

  test('files: create, append, read at offsets, truncate, length', () {
    w.Directory('/data').createSync();
    final f = w.File('/data/a.zx');
    expect(f.existsSync(), isFalse);
    expect(() => f.openSync(), throwsA(isA<w.FileSystemException>()));
    // opened for writing, a file gets its folders
    w.File('/made/on/write').openSync(mode: w.FileMode.write).closeSync();
    expect(w.Directory('/made/on').existsSync(), isTrue);
    final raf = f.openSync(mode: w.FileMode.append);
    raf.writeFromSync([1, 2, 3, 4, 5]);
    raf.writeFromSync([6, 7], 0, 2);
    expect(raf.lengthSync(), 7);
    raf.setPositionSync(2);
    final buf = Uint8List(3);
    expect(raf.readIntoSync(buf), 3);
    expect(buf, [3, 4, 5]);
    raf.truncateSync(4);
    expect(raf.lengthSync(), 4);
    raf.closeSync();
    expect(f.readAsBytesSync(), [1, 2, 3, 4]);
    expect(w.FileStat.statSync('/data/a.zx').size, 4);
    expect(w.FileStat.statSync('/nope').type, w.FileSystemEntityType.notFound);
    // append mode starts at the end
    final r2 = f.openSync(mode: w.FileMode.append)..writeFromSync([9]);
    r2.closeSync();
    expect(f.readAsBytesSync(), [1, 2, 3, 4, 9]);
    // write mode truncates
    f.writeAsStringSync('hi');
    expect(f.readAsStringSync(), 'hi');
  });

  test('exclusive create, rename over a file, delete, directories', () {
    final m = w.File('/x/lock.1')..createSync(recursive: true);
    expect(() => m.createSync(exclusive: true),
        throwsA(isA<w.FileSystemException>()));
    w.File('/x/a').writeAsStringSync('new');
    w.File('/x/b').writeAsStringSync('old');
    w.File('/x/a').renameSync('/x/b');
    expect(w.File('/x/a').existsSync(), isFalse);
    expect(w.File('/x/b').readAsStringSync(), 'new');
    expect(w.Directory('/x').listSync().map((e) => e.path).toSet(),
        {'/x/lock.1', '/x/b'});
    w.File('/x/b').deleteSync();
    expect(() => w.Directory('/x').deleteSync(),
        throwsA(isA<w.FileSystemException>()));
    w.Directory('/x').deleteSync(recursive: true);
    expect(w.Directory('/x').existsSync(), isFalse);
  });

  test('changes: dirty chunks only, deletions, a rename keeps the id', () {
    final f = w.File('/d/big')..createSync(recursive: true);
    f.writeAsBytesSync(Uint8List(3 * w.zxWebChunk + 10));
    var ch = fs.changes();
    expect(ch.whereType<w.ZxWebFsDir>().map((d) => d.path), contains('/d'));
    final first = ch.whereType<w.ZxWebFsFile>().single;
    expect(first.length, 3 * w.zxWebChunk + 10);
    expect(first.chunks.keys.toSet(), {0, 1, 2, 3});
    expect(first.chunks[3]!.length, 10);
    expect(fs.changes(), isEmpty, reason: 'nothing changed since');
    // an append touches the last chunk only
    f.openSync(mode: w.FileMode.append)
      ..writeFromSync([1, 2])
      ..closeSync();
    ch = fs.changes();
    expect(ch.whereType<w.ZxWebFsFile>().single.chunks.keys, [3]);
    // rename: the same id under the new path; replacing a file deletes its id
    w.File('/d/other').writeAsStringSync('x');
    final otherId = fs.changes().whereType<w.ZxWebFsFile>().single.id;
    f.renameSync('/d/other');
    ch = fs.changes();
    expect(ch.whereType<w.ZxWebFsDelete>().map((d) => d.id), [otherId]);
    final moved = ch.whereType<w.ZxWebFsFile>().single;
    expect(moved.path, '/d/other');
    expect(moved.id, first.id);
  });

  test('restore puts files back as they were stored', () {
    fs.restore('/r/a', 7, Uint8List.fromList([5, 6]), DateTime(2026));
    expect(w.File('/r/a').readAsBytesSync(), [5, 6]);
    expect(w.Directory('/r').existsSync(), isTrue);
    expect(fs.changes(), isEmpty);
    w.File('/r/b').writeAsStringSync('z');
    expect(fs.changes().whereType<w.ZxWebFsFile>().single.id, greaterThan(7));
  });

  test('markAllDirty lists everything again (a failed host write)', () {
    w.File('/m/a').writeAsBytesSync(Uint8List(w.zxWebChunk + 5));
    fs.changes();
    expect(fs.changes(), isEmpty);
    fs.markAllDirty();
    final f = fs.changes().whereType<w.ZxWebFsFile>().single;
    expect(f.chunks.keys.toSet(), {0, 1});
  });

  test('what the archiver needs beyond the database: types, times, '
      'directory renames, links refused', () async {
    w.File('/a/b/c.txt').openSync(mode: w.FileMode.write)
      ..writeFromSync([1, 2, 3])
      ..closeSync();
    expect(w.FileSystemEntity.typeSync('/a/b/c.txt'), w.FileSystemEntityType.file);
    expect(w.FileSystemEntity.typeSync('/a/b'), w.FileSystemEntityType.directory);
    expect(w.FileSystemEntity.typeSync('/nope'), w.FileSystemEntityType.notFound);
    expect(w.FileSystemEntity.isLinkSync('/a/b/c.txt'), isFalse);

    final t = DateTime.utc(2020, 1, 2, 3, 4, 5);
    w.File('/a/b/c.txt').setLastModifiedSync(t);
    expect(w.File('/a/b/c.txt').lastModifiedSync(), t);
    w.File('/a/b/c.txt').setLastAccessedSync(t); // accepted, not kept

    fs.changes(); // settle
    w.Directory('/a').renameSync('/z');
    expect(w.Directory('/a').existsSync(), isFalse);
    expect(w.File('/z/b/c.txt').readAsBytesSync(), [1, 2, 3]);
    expect(w.Directory('/z/b').existsSync(), isTrue);
    final changes = fs.changes();
    expect(changes.whereType<w.ZxWebFsDelete>(), isEmpty,
        reason: 'a rename keeps the file id: no delete and re-add');

    await w.Directory('/z').delete(recursive: true);
    expect(w.Directory('/z').existsSync(), isFalse);

    final l = w.Link('/l');
    expect(l.existsSync(), isFalse);
    expect(() => l.createSync('/z'), throwsA(isA<w.FileSystemException>()));
    expect(() => l.targetSync(), throwsA(isA<w.FileSystemException>()));
  });
}
