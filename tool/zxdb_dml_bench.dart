// Memory of INSERT ... SELECT, UPDATE and DELETE over a large table.
//   dart run tool/zxdb_dml_bench.dart OUT.zx [rows]
import 'dart:io';

import 'package:zx/src/db/zxdb.dart';

void main(List<String> args) {
  final path = args[0];
  final rows = args.length > 1 ? int.parse(args[1]) : 2000000;
  for (final f in [path, '$path.zx-lock']) {
    if (File(f).existsSync()) File(f).deleteSync();
  }
  final db = ZxDatabase.open(path,
      create: true,
      options: ZxDbStoreOptions(compression: 'fast', durable: false));
  final sql = db.sql;
  final sw = Stopwatch()..start();
  var peak = 0;
  void log(String s) {
    final r = ProcessInfo.maxRss >> 20;
    if (r > peak) peak = r;
    print('$s: ${sw.elapsed.inSeconds}s, rss ${ProcessInfo.currentRss >> 20} MiB, '
        'peak $r MiB');
  }

  sql.execute('CREATE TABLE a (id INTEGER PRIMARY KEY, n INTEGER, t TEXT)');
  sql.execute('BEGIN');
  const per = 500;
  final one = List.filled(per, '(?,?,?)').join(',');
  for (var i = 0; i < rows; i += per) {
    sql.execute('INSERT INTO a VALUES $one', [
      for (var k = i; k < i + per; k++) ...[k + 1, k, 'text of row $k ' * 4]
    ]);
  }
  sql.execute('COMMIT');
  log('loaded $rows');
  sql.execute('CREATE TABLE b (id INTEGER PRIMARY KEY, n INTEGER, t TEXT)');
  sql.execute('INSERT INTO b SELECT * FROM a');
  log('INSERT ... SELECT');
  sql.execute('UPDATE b SET n = n + 1, t = substr(t, 1, 20)');
  log('UPDATE all');
  sql.execute('DELETE FROM b WHERE n % 2 = 0');
  log('DELETE half');
  print(sql.execute('SELECT count(*), sum(n) FROM b').rows.first);
  db.close();
}
