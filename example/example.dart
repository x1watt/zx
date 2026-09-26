// Creates an encrypted 7z archive from a folder, updates it, lists it,
// extracts it, and compresses a file to xz. Run with:
//   dart run example/example.dart
import 'dart:io';

import 'package:zx/zx.dart';

Future<void> main() async {
  final work = Directory.systemTemp.createTempSync('zx_example_');
  try {
    final docs = Directory('${work.path}/docs')..createSync();
    File('${docs.path}/notes.txt').writeAsStringSync('first draft\n' * 1000);
    File('${docs.path}/todo.txt').writeAsStringSync('buy milk\n');

    final archive = SevenZipArchive('${work.path}/docs.7z', password: 'secret');

    // Everything below docs/ is stored as docs/...
    print(await archive.add([SevenZipSource(docs.path)],
        options: const SevenZipOptions(level: 9, encryptHeaders: true)));

    // Replace one file; the rest is kept as it is (and the names stay
    // encrypted, as with 7-Zip).
    File('${docs.path}/notes.txt').writeAsStringSync('second draft\n' * 1000);
    print(await archive.add(
        [SevenZipSource('${docs.path}/notes.txt', storedAs: 'docs/notes.txt')],
        onProgress: (p) => print('  $p')));

    for (final e in (await archive.list()).entries) {
      print('${e.isDir ? 'D' : ' '} ${e.size.toString().padLeft(6)} ${e.path}');
    }

    await archive.rename({'docs/todo.txt': 'docs/done.txt'});
    final result = await archive.extract('${work.path}/restore');
    print(result); // 2 files, 1 dirs
    print(File('${work.path}/restore/docs/notes.txt')
        .readAsLinesSync()
        .first); // second draft

    // Without the password the names are not readable.
    try {
      await SevenZipArchive(archive.path).list();
    } on SevenZipException catch (e) {
      print(e.kind); // SevenZipError.wrongPassword
    }

    // xz, with the blocks compressed by two worker isolates.
    final big = File('${work.path}/big.txt')
      ..writeAsStringSync('the quick brown fox\n' * 200000);
    await xzCompressFile(big.path, '${big.path}.xz',
        threads: 2, switches: ['s=1m']);
    print('${big.lengthSync()} bytes to '
        '${File('${big.path}.xz').lengthSync()} bytes');
  } finally {
    work.deleteSync(recursive: true);
  }
}
