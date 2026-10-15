// Memory of one large write transaction into a table with a text index
// (random keys), the shape of loading Wikipedia's redirects.
//   dart run tool/zxdb_bigtxn_bench.dart OUT.zx [rows]
import 'dart:io';
import 'dart:math';

import 'package:zx/src/db/zxdb.dart';

void main(List<String> args) {
  final path = args[0];
  final rows = args.length > 1 && !args[1].startsWith('--')
      ? int.parse(args[1])
      : 3000000;
  for (final f in [path, '$path.zx-lock']) {
    if (File(f).existsSync()) File(f).deleteSync();
  }
  final db = ZxDatabase.open(path,
      create: true,
      options: ZxDbStoreOptions(compression: 'balanced', durable: false));
  final sql = db.sql;
  sql.execute('CREATE TABLE r (title TEXT, page INTEGER)');
  sql.execute('CREATE INDEX r_title ON r (title COLLATE NOCASE)');
  final rnd = Random(1);
  final sw = Stopwatch()..start();
  sql.execute('BEGIN');
  const per = 200;
  final one = List.filled(per, '(?,?)').join(',');
  final params = <Object?>[];
  for (var i = 0; i < rows; i++) {
    params
      ..add('Title ${rnd.nextInt(1 << 30)} of something ${i * 7}')
      ..add(i);
    if (params.length == per * 2) {
      sql.execute('INSERT INTO r VALUES $one', params);
      params.clear();
    }
    if (i % 500000 == 499999 && args.contains('--commits')) {
      if (params.isNotEmpty) {
        sql.execute(
            'INSERT INTO r VALUES ${List.filled(params.length ~/ 2, '(?,?)').join(',')}',
            params);
        params.clear();
      }
      sql.execute('COMMIT');
      sql.execute('BEGIN');
    }
    if (i % 500000 == 499999) {
      print('${i + 1} rows, ${sw.elapsed.inSeconds}s, '
          'rss ${ProcessInfo.currentRss >> 20} MiB');
    }
  }
  sql.execute('COMMIT');
  print(
      'commit ${sw.elapsed.inSeconds}s, rss ${ProcessInfo.currentRss >> 20} MiB');
  db.close();
}
