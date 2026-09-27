// Vendored from zpaq-flutter by tool/sync_zpaq.sh: do not edit here, change
// zpaq-flutter and sync again. Pure Dart port of libzpaq and zpaq 7.15 (Matt
// Mahoney, public domain) with the zpaqfranz attribute format (Franco
// Corbelli, MIT). Copyright (c) 2026 Max Brito, BSD 3-clause; see LICENSE
// for the license and the third party notices.

// The directory scan skips symbolic links, like zpaq (lstat): links inside
// a tree, and a source that is itself a link. It takes regular files and
// directories, and orders names as their UTF-8 bytes.
import 'dart:io';

import 'package:test/test.dart';
import 'package:zx/src/zpaq/zpaq.dart';

void main() {
  test('symbolic links are skipped; names in UTF-8 order', () async {
    final dir = Directory.systemTemp.createTempSync('zpaq_scan');
    try {
      String p(String s) => '${dir.path}/$s';
      Directory(p('src/sub')).createSync(recursive: true);
      File(p('src/a.txt')).writeAsStringSync('a');
      File(p('src/sub/b.txt')).writeAsStringSync('b');
      // names whose UTF-16 and UTF-8 orders differ (U+FF21 against U+1F600)
      File(p('src/\u{FF21}.txt')).writeAsStringSync('c');
      File(p('src/\u{1F600}.txt')).writeAsStringSync('d');
      Link(p('src/link_file')).createSync(p('src/a.txt'));
      Link(p('src/link_dir')).createSync(p('src/sub'));
      Link(p('linked_src')).createSync(p('src'));

      final arc = ZpaqArchive(p('a.zpaq'));
      final r = await arc.add([
        ZpaqSource(p('src'), storedAs: 'src'),
        ZpaqSource(p('linked_src'), storedAs: 'linked'),
      ]);
      expect(r.errors, isEmpty);
      // history lists the index entries in the order they were written
      final l = await arc.list(allVersions: true);
      final names = l.history!.map((e) => e.name).toList();
      expect(names, [
        'src/',
        'src/a.txt',
        'src/sub/',
        'src/sub/b.txt',
        'src/\u{FF21}.txt',
        'src/\u{1F600}.txt',
      ]);
      // and the listing is in the same order, zpaq's
      expect(l.entries.map((e) => e.name).toList(), names);
    } finally {
      dir.deleteSync(recursive: true);
    }
  });
}
