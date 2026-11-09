// zxdb in a browser (dart2wasm): ZxSqlDb over the in-memory files of
// lib/src/host/web_fs.dart, persisted and restored as a page reload would.
//   CHROME_EXECUTABLE=/usr/bin/chromium dart test -p chrome -c dart2wasm test/browser
@TestOn('browser')
library;

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/host/web_fs.dart';
import 'package:zx/zxdb.dart';

void main() {
  test('create, write in transactions, KV, compact, persist, restore, read',
      () {
    final fs = ZxWebFs.instance..reset();
    Directory('/xprs/data').createSync(recursive: true);
    var db = ZxSqlDb.open('/xprs/data/a.zx', password: 'f' * 64, scryptLog2N: 1);
    db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)');
    for (var r = 0; r < 20; r++) {
      db.transaction(() {
        for (var i = 0; i < 100; i++) {
          db.execute('INSERT OR REPLACE INTO t VALUES (?, ?)', [i, 'v$r-$i']);
        }
      });
    }
    db.kv('cache').putString('k', 'value');
    expect(db.maybeCompact(force: true), isTrue);
    db.execute("INSERT INTO t VALUES (1000, 'after compaction')");
    db.dispose();

    // what a host would store: the files by id, with their chunks
    final stored = <int, (String, int, Map<int, Uint8List>)>{};
    for (final c in fs.changes()) {
      switch (c) {
        case ZxWebFsDelete(:final id):
          stored.remove(id);
        case ZxWebFsFile(:final path, :final id, :final length, :final chunks):
          final old = stored[id]?.$3 ?? <int, Uint8List>{};
          old.removeWhere((n, _) => n * zxWebChunk >= length);
          old.addAll(chunks);
          stored[id] = (path, length, old);
        case ZxWebFsDir():
          break;
      }
    }
    // a reload: memory gone, files put back
    fs.reset();
    stored.forEach((id, f) {
      final (path, length, chunks) = f;
      final bytes = Uint8List(length);
      chunks.forEach((n, b) => bytes.setRange(n * zxWebChunk, n * zxWebChunk + b.length, b));
      fs.restore(path, id, bytes, DateTime.now());
    });
    db = ZxSqlDb.open('/xprs/data/a.zx', password: 'f' * 64);
    expect(db.select('SELECT COUNT(*) c FROM t').single['c'], 101);
    expect(db.select('SELECT v FROM t WHERE id = 7').single['v'], 'v19-7');
    expect(db.kv('cache').getString('k'), 'value');
    db.dispose();
  });
}
