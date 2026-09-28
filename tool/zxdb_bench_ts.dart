// Benchmark of the zxdb time series (lib/src/db/ts/): append rate into
// the write buffer, seal time, time range scans (MB/s of the raw log
// text the rows stand for), and sizes against sqlite3 and against zstd
// and xz of the raw log text, on a deterministic synthetic web/server
// log and optionally on real logs (journalctl -o json, read only).
//
//   dart compile exe tool/zxdb_bench_ts.dart -o /tmp/tsb
//   /tmp/tsb [--rows 1000000] [--levels fast,balanced,max]
//            [--threads 4] [--journal 200000] [--dir /tmp/x] [--hot 1]
//
// --hot N: for max and ultra, also keep the hot tier (hot_days) for the
// last N days of the data and time a cold read of the last day with and
// without it.
// Needs sqlite3, zstd and xz on PATH for the comparisons (skipped when
// missing).

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:zx/src/db/zxdb.dart';

String _arg(List<String> a, String name, String def) {
  final i = a.indexOf(name);
  return i >= 0 && i + 1 < a.length ? a[i + 1] : def;
}

// ------------------------------------------------------------ synthetic

const _hosts = ['web01', 'web02', 'web03', 'web04', 'api01', 'api02', 'db01', 'cache01'];
const _paths = [
  '/', '/index.html', '/login', '/logout', '/api/v1/users', '/api/v1/orders', //
  '/api/v1/orders/{id}', '/api/v1/items/{id}', '/static/app.js',
  '/static/style.css', '/images/logo.png', '/search', '/cart', '/checkout',
  '/api/v2/stream', '/health', '/metrics', '/favicon.ico',
];
const _uas = [
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36',
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15',
  'Mozilla/5.0 (X11; Linux x86_64; rv:127.0) Gecko/20100101 Firefox/127.0',
  'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148',
  'curl/8.5.0',
  'Prometheus/2.51.0',
  'Go-http-client/1.1',
];
const _appMsgs = [
  'user {u} logged in from {ip}',
  'user {u} logged out',
  'order {n} created for user {u} total {m} EUR',
  'payment for order {n} declined: insufficient funds',
  'cache miss for key item:{n}, loading from database',
  'slow query took {t} ms: SELECT * FROM orders WHERE user_id = {u}',
  'connection pool exhausted, waiting for a free connection',
  'retrying request to upstream inventory-service (attempt {a} of 3)',
  'upstream timed out after {t} ms while reading response header',
  'GC pause of {t} ms',
];

class Gen {
  final Random r = Random(20260928);
  int ts = DateTime.utc(2026, 9, 1).microsecondsSinceEpoch * 1000;

  String ip() => '${10 + r.nextInt(3)}.${r.nextInt(8)}.${r.nextInt(64)}.${r.nextInt(250) + 1}';

  // one row: ts, host, level, service, status, bytes, latency, message;
  // and the raw line
  (List<Object?>, String) next() {
    ts += 1000000 + r.nextInt(999000000); // about 2 rows per second
    final host = _hosts[r.nextInt(r.nextInt(8) + 1)];
    final t = DateTime.fromMicrosecondsSinceEpoch(ts ~/ 1000, isUtc: true)
        .toIso8601String();
    if (r.nextInt(5) != 0) {
      final st = [200, 200, 200, 200, 200, 304, 301, 404, 500, 502][r.nextInt(10)];
      var p = _paths[r.nextInt(_paths.length)];
      p = p.replaceAll('{id}', '${r.nextInt(100000)}');
      if (r.nextInt(4) == 0) p = '$p?page=${r.nextInt(20)}';
      final m = ['GET', 'GET', 'GET', 'POST', 'PUT', 'DELETE'][r.nextInt(6)];
      final bytes = st == 304 ? 0 : 200 + r.nextInt(50000);
      final lat = (r.nextInt(2000) + 1) / 1000.0 * (st >= 500 ? 20 : 1);
      final ua = _uas[r.nextInt(_uas.length)];
      final msg = '${ip()} "$m $p HTTP/1.1" "$ua"';
      final level = st >= 500 ? 'error' : st >= 400 ? 'warn' : 'info';
      final line = '$t $host nginx[$level]: $st $bytes ${lat.toStringAsFixed(3)} $msg';
      return ([ts, host, level, 'nginx', st, bytes, lat, msg], line);
    }
    var msg = _appMsgs[r.nextInt(_appMsgs.length)];
    msg = msg
        .replaceAll('{u}', '${r.nextInt(5000)}')
        .replaceAll('{ip}', ip())
        .replaceAll('{n}', '${r.nextInt(1000000)}')
        .replaceAll('{m}', '${r.nextInt(500)}.${r.nextInt(100).toString().padLeft(2, '0')}')
        .replaceAll('{t}', '${r.nextInt(5000)}')
        .replaceAll('{a}', '${r.nextInt(3) + 1}');
    final level = msg.contains('declined') || msg.contains('timed out')
        ? 'error'
        : msg.contains('slow') || msg.contains('exhausted') || msg.contains('retrying')
            ? 'warn'
            : 'info';
    final svc = ['shop', 'payments', 'inventory'][r.nextInt(3)];
    final line = '$t $host $svc[$level]: $msg';
    return ([ts, host, level, svc, null, null, null, msg], line);
  }
}

const _cols = [
  ZxTsColumn('ts', 'DATETIME'),
  ZxTsColumn('host', 'TEXT'),
  ZxTsColumn('level', 'TEXT'),
  ZxTsColumn('service', 'TEXT'),
  ZxTsColumn('status', 'INTEGER'),
  ZxTsColumn('bytes', 'INTEGER'),
  ZxTsColumn('latency', 'REAL'),
  ZxTsColumn('message', 'TEXT'),
];

String _mb(num bytes) => (bytes / 1048576).toStringAsFixed(2);

int? _external(String cmd, List<String> args, File input) {
  try {
    final out = File('${input.path}.cmp');
    final p = Process.runSync('sh', ['-c', '$cmd ${args.join(' ')} < "${input.path}" > "${out.path}"']);
    if (p.exitCode != 0) return null;
    final n = out.lengthSync();
    out.deleteSync();
    return n;
  } on ProcessException {
    return null;
  }
}

int? _sqlite(Directory dir, String name, List<String> colSql,
    Iterable<List<Object?>> rows) {
  final csv = File('${dir.path}/$name.csv');
  final w = csv.openSync(mode: FileMode.write);
  String q(Object? v) {
    if (v == null) return '';
    final s = '$v';
    if (s.contains(RegExp('[",\n\r]')) || s.isEmpty) {
      return '"${s.replaceAll('"', '""')}"';
    }
    return s;
  }

  final sb = StringBuffer();
  for (final r in rows) {
    sb.writeln(r.map(q).join(','));
    if (sb.length > 1 << 20) {
      w.writeStringSync(sb.toString());
      sb.clear();
    }
  }
  w.writeStringSync(sb.toString());
  w.closeSync();
  final db = File('${dir.path}/$name.sqlite');
  if (db.existsSync()) db.deleteSync();
  try {
    final p = Process.runSync('sqlite3', [
      db.path,
      'CREATE TABLE t (${colSql.join(', ')});',
      '.mode csv',
      '.import "${csv.path}" t',
      'CREATE INDEX t_ts ON t(ts);',
      'VACUUM;'
    ]);
    csv.deleteSync();
    if (p.exitCode != 0) {
      stderr.writeln('sqlite3: ${p.stderr}');
      return null;
    }
    final n = db.lengthSync();
    db.deleteSync();
    return n;
  } on ProcessException {
    csv.deleteSync();
    return null;
  }
}

void main(List<String> args) {
  final nRows = int.parse(_arg(args, '--rows', '1000000'));
  final levels = _arg(args, '--levels', 'fast,balanced,max').split(',');
  final threads = int.parse(_arg(args, '--threads', '4'));
  final nJournal = int.parse(_arg(args, '--journal', '0'));
  _hot = int.parse(_arg(args, '--hot', '0'));
  final dir = Directory(_arg(args, '--dir', Directory.systemTemp.path))
      .createTempSync('zxdb_ts_bench_');
  try {
    if (nRows > 0) _synthetic(dir, nRows, levels, threads);
    if (nJournal > 0) _journal(dir, nJournal, levels, threads);
  } finally {
    dir.deleteSync(recursive: true);
  }
}

void _synthetic(Directory dir, int nRows, List<String> levels, int threads) {
  final g = Gen();
  final rows = <List<Object?>>[];
  final raw = File('${dir.path}/raw.log').openSync(mode: FileMode.write);
  var rawBytes = 0;
  final sb = StringBuffer();
  for (var i = 0; i < nRows; i++) {
    final (row, line) = g.next();
    rows.add(row);
    sb.writeln(line);
    rawBytes += utf8.encode(line).length + 1;
    if (sb.length > 1 << 20) {
      raw.writeStringSync(sb.toString());
      sb.clear();
    }
  }
  raw.writeStringSync(sb.toString());
  raw.closeSync();
  final rawFile = File('${dir.path}/raw.log');
  final days = (rows.last[0] as int) - (rows.first[0] as int);
  print('synthetic web/server log: $nRows lines, ${_mb(rawBytes)} MiB of text, '
      '${(days / 86400e9).toStringAsFixed(1)} days');
  final zstd = _external('zstd', ['-19', '-T1', '-c'], rawFile);
  final xz = _external('xz', ['-9', '-T1', '-c'], rawFile);
  print('  zstd -19: ${zstd == null ? 'n/a' : '${_mb(zstd)} MiB (${(rawBytes / zstd).toStringAsFixed(1)}x)'}');
  print('  xz -9:    ${xz == null ? 'n/a' : '${_mb(xz)} MiB (${(rawBytes / xz).toStringAsFixed(1)}x)'}');
  final sq = _sqlite(dir, 'syn', [
    'ts INTEGER', 'host TEXT', 'level TEXT', 'service TEXT', 'status INTEGER', //
    'bytes INTEGER', 'latency REAL', 'message TEXT'
  ], rows);
  print('  sqlite3 (table + index on ts, vacuumed): '
      '${sq == null ? 'n/a' : '${_mb(sq)} MiB'}');
  for (final level in levels) {
    _runLevel(dir, 'syn-$level', _cols, rows, rawBytes, level, threads,
        sq: sq, zstd: zstd, xz: xz, tag: 'host');
  }
}

int _hot = 0;

void _runLevel(Directory dir, String name, List<ZxTsColumn> cols,
    List<List<Object?>> rows, int rawBytes, String level, int threads,
    {int? sq, int? zstd, int? xz, String? tag}) {
  final path = '${dir.path}/$name.zx';
  final db = ZxDatabase.open(path,
      create: true,
      options: ZxDbStoreOptions(durable: false, autoFoldBytes: 0, threads: threads));
  // the data lies in the past: the hot window counts from now
  final slow = level == 'max' || level == 'ultra';
  final lastNs = rows.last[0] as int;
  final agoDays =
      (DateTime.now().microsecondsSinceEpoch * 1000 - lastNs) ~/ 86400000000000;
  final hotDays = slow && _hot > 0 ? agoDays + _hot : null;
  db.createSeries('logs', cols,
      partitionBy: 'day',
      hotDays: hotDays,
      compression: level,
      tags: tag == null ? const [] : [tag],
      sealRows: 1 << 40);
  final s = db.series('logs');
  final sw = Stopwatch()..start();
  const batch = 100000;
  for (var i = 0; i < rows.length; i += batch) {
    s.appendAll(rows.sublist(i, min(rows.length, i + batch)));
  }
  final appendS = sw.elapsedMicroseconds / 1e6;
  sw.reset();
  final sr = s.seal(options: ZxTsSealOptions(threads: threads));
  final sealS = sw.elapsedMicroseconds / 1e6;
  db.vacuum();
  final size = File(path).lengthSync();
  final st = s.stats;
  print('$level: append ${(rows.length / appendS / 1000).toStringAsFixed(0)}k rows/s '
      '(batches of $batch), seal ${sealS.toStringAsFixed(1)} s '
      '(${sr.segments} segments, ${st.partitions} partitions), '
      'archive ${_mb(size)} MiB = ${(rawBytes / size).toStringAsFixed(1)}x of the text'
      '${sq == null ? '' : ', ${(sq / size).toStringAsFixed(1)}x smaller than sqlite3'}'
      '${zstd == null ? '' : ', ${(zstd / size).toStringAsFixed(2)}x of zstd -19'}'
      '${xz == null ? '' : ', ${(xz / size).toStringAsFixed(2)}x of xz -9'}');
  // scans
  final nc = cols.length;
  double scan({Object? from, Object? to, List<String>? columns, bool cold = false,
      Map<String, Object?> where = const {}}) {
    if (cold) zxTsClearCache();
    final w = Stopwatch()..start();
    final sc = s.scan(from: from, to: to, columns: columns, where: where);
    var n = 0;
    final idx = columns == null
        ? [for (var i = 0; i < nc; i++) i]
        : [for (final c in columns) sc.def.columnIndex(c)];
    var h = 0;
    while (sc.moveNext()) {
      for (final i in idx) {
        final v = sc.value(i);
        if (v != null) h ^= v.hashCode;
      }
      n++;
    }
    final secs = w.elapsedMicroseconds / 1e6;
    final logical = rawBytes * n / rows.length;
    if (h == 42) print('');
    return logical / secs / 1048576;
  }

  final t0 = rows.first[0] as int;
  final numCols0 = scan(columns: [
    for (final c in cols)
      if (c.type == 'DATETIME' || c.type == 'INTEGER' || c.type == 'REAL') c.name
  ], cold: true);
  if (slow) {
    // a cold read of zcm text decodes at zcm's speed: minutes here
    print('  scan ts + numbers only (cold): ${numCols0.toStringAsFixed(0)} MB/s of raw text');
    if (hotDays != null) {
      final from = lastNs - 86400 * 1000000000;
      final hotB = zxTsHotBytes(db.readSnapshot(), 'logs');
      double lastDay(ZxTsDef d) {
        zxTsClearCache();
        final w = Stopwatch()..start();
        final sc = ZxTsScan(db.readSnapshot(), d, ZxTsScanSpec(from: from));
        var n = 0, h = 0;
        while (sc.moveNext()) {
          for (var i = 0; i < nc; i++) {
            final v = sc.value(i);
            if (v != null) h ^= v.hashCode;
          }
          n++;
        }
        if (h == 42) print('');
        final secs = w.elapsedMicroseconds / 1e6;
        return rawBytes * n / rows.length / secs / 1048576;
      }

      final d = s.def;
      final withHot = lastDay(d);
      final noHot = lastDay(
          ZxTsDef.fromJson('logs', {...d.toJson(), 'hotDays': 0}));
      print('  last day, all columns, cold: ${noHot.toStringAsFixed(2)} MB/s '
          'without the hot tier, ${withHot.toStringAsFixed(0)} MB/s with it '
          '(hot tier ${_mb(hotB)} MiB for the last $_hot day(s) of data, '
          'archive ${_mb(size)} MiB)');
    }
    db.close();
    File(path).deleteSync();
    return;
  }
  final cold = scan(cold: true);
  final warm = scan();
  final t1 = rows.last[0] as int;
  final day0 = t0 + (t1 - t0) ~/ 3;
  final dayCold = scan(from: day0, to: day0 + 86400 * 1000000000, cold: true);
  final dayWarm = scan(from: day0, to: day0 + 86400 * 1000000000);
  final numCols = numCols0;
  print('  scan all columns: ${cold.toStringAsFixed(0)} MB/s cold, '
      '${warm.toStringAsFixed(0)} MB/s warm; one day: ${dayCold.toStringAsFixed(0)} cold, '
      '${dayWarm.toStringAsFixed(0)} warm; ts + numbers only (cold): '
      '${numCols.toStringAsFixed(0)} MB/s (MB/s of raw text)');
  db.close();
  File(path).deleteSync();
}

void _journal(Directory dir, int n, List<String> levels, int threads) {
  final p = Process.runSync('journalctl', ['-o', 'json', '-n', '$n', '--no-pager'],
      stdoutEncoding: utf8);
  if (p.exitCode != 0) {
    print('journalctl: ${p.stderr}');
    return;
  }
  final lines = LineSplitter.split(p.stdout as String).toList();
  final recs = [for (final l in lines) zxTsParseJournal(l)].whereType<Map<String, Object?>>().toList();
  // the raw text: the short format of journalctl for the same entries
  final short = Process.runSync(
      'journalctl', ['-o', 'short-iso-precise', '-n', '$n', '--no-pager'],
      stdoutEncoding: utf8);
  final rawText = File('${dir.path}/journal.txt')..writeAsStringSync(short.stdout as String);
  final jsonFile = File('${dir.path}/journal.json')..writeAsStringSync(p.stdout as String);
  final rawBytes = rawText.lengthSync();
  print('journald: ${recs.length} entries, short text ${_mb(rawBytes)} MiB, '
      'JSON export ${_mb(jsonFile.lengthSync())} MiB');
  int? jz, jx;
  for (final f in [rawText, jsonFile]) {
    final z = _external('zstd', ['-19', '-T1', '-c'], f);
    final x = _external('xz', ['-9', '-T1', '-c'], f);
    jz = z;
    jx = x;
    print('  ${f.path.endsWith('txt') ? 'text' : 'JSON'}: zstd -19 '
        '${z == null ? 'n/a' : _mb(z)} MiB, xz -9 ${x == null ? 'n/a' : _mb(x)} MiB');
  }
  const cols = [
    ZxTsColumn('ts', 'DATETIME'),
    ZxTsColumn('host', 'TEXT'),
    ZxTsColumn('app', 'TEXT'),
    ZxTsColumn('pid', 'INTEGER'),
    ZxTsColumn('level', 'TEXT'),
    ZxTsColumn('message', 'TEXT'),
    ZxTsColumn('fields', 'JSON'),
  ];
  final rows = <List<Object?>>[
    for (final r in recs)
      if (r['ts'] != null)
        [
          r['ts'], r['host'], r['app'], r['pid'], r['level'], r['message'], //
          r['fields'] == null ? null : jsonEncode(r['fields'])
        ]
  ];
  final sq = _sqlite(dir, 'jr', [
    'ts INTEGER', 'host TEXT', 'app TEXT', 'pid INTEGER', 'level TEXT', //
    'message TEXT', 'fields TEXT'
  ], rows);
  print('  sqlite3 (all fields, vacuumed): ${sq == null ? 'n/a' : '${_mb(sq)} MiB'}');
  for (final level in levels) {
    // sizes against the JSON export (every field is kept)
    _runLevel(dir, 'jr-$level', cols, rows, rawBytes, level, threads,
        sq: sq, zstd: jz, xz: jx, tag: 'app');
  }
}
