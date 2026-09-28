// INSERT OR REPLACE / OR IGNORE and ON CONFLICT on the writable system
// tables (zx_meta), through the SQL engine and the system table adapter.

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/db/memory_store.dart';
import 'package:zx/src/db/meta/meta_store.dart';
import 'package:zx/src/db/sql/zx_sql.dart';
import 'package:zx/src/db/system/sql_adapter.dart';

void main() {
  late ZxSql sql;

  setUp(() {
    final store = ZxMemoryStore();
    final t = store.begin();
    ZxMetaSchema.create(t);
    t.commit();
    sql = ZxSql(store);
    ZxSystemSql().register(sql.registerVirtualTable, sql.functions);
  });

  final h = Uint8List.fromList(List.filled(32, 7));

  String? title() =>
      sql.execute('SELECT title FROM zx_meta WHERE sha256 = ?', [h]).scalar
          as String?;

  test('plain insert twice is a constraint error', () {
    sql.execute('INSERT INTO zx_meta (sha256, title) VALUES (?, ?)', [h, 'a']);
    expect(
        () => sql.execute(
            'INSERT INTO zx_meta (sha256, title) VALUES (?, ?)', [h, 'b']),
        throwsA(anything));
    expect(title(), 'a');
  });

  test('INSERT OR REPLACE overwrites', () {
    sql.execute('INSERT INTO zx_meta (sha256, title) VALUES (?, ?)', [h, 'a']);
    sql.execute(
        'INSERT OR REPLACE INTO zx_meta (sha256, title) VALUES (?, ?)', [h, 'b']);
    expect(title(), 'b');
    expect(sql.execute('SELECT count(*) FROM zx_meta').scalar, 1);
  });

  test('INSERT OR IGNORE keeps the existing row', () {
    sql.execute('INSERT INTO zx_meta (sha256, title) VALUES (?, ?)', [h, 'a']);
    sql.execute(
        'INSERT OR IGNORE INTO zx_meta (sha256, title) VALUES (?, ?)', [h, 'b']);
    expect(title(), 'a');
  });

  test('ON CONFLICT DO UPDATE and DO NOTHING', () {
    sql.execute('INSERT INTO zx_meta (sha256, title) VALUES (?, ?)', [h, 'a']);
    sql.execute(
        'INSERT INTO zx_meta (sha256, title) VALUES (?, ?) '
        'ON CONFLICT (sha256) DO UPDATE SET title = excluded.title',
        [h, 'c']);
    expect(title(), 'c');
    sql.execute(
        'INSERT INTO zx_meta (sha256, title) VALUES (?, ?) '
        'ON CONFLICT DO NOTHING',
        [h, 'd']);
    expect(title(), 'c');
  });
}
