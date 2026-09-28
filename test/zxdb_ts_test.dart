// Tests of the time series of zxdb (lib/src/db/ts/): encodings, the
// store against an in-memory reference model (random appends, seals,
// queries, retention, rollups, reopen, AS OF), SQL and the importers.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/db/engine/compression.dart' show zxDbFastChain;
import 'package:zx/src/db/ts/ts_codec.dart';
import 'package:zx/src/db/ts/ts_store.dart' show zxTsPartStart, ZxTsPartition;
import 'package:zx/src/db/zxdb.dart';

ZxDbStoreOptions opts() => ZxDbStoreOptions(
    pageSize: 4096,
    autoFoldBytes: 0,
    durable: false,
    refreshMicros: 0,
    threads: 1);

const int sec = 1000000000;
const int day = 86400 * sec;

List<Object?> roundTrip(List<Object?> v) {
  final d = tsEncodeColumn(v);
  for (final s in d.sections) {
    final r = tsCode(s.raw, zxDbFastChain);
    if (r != null) {
      s.payload = r.$1;
      s.coders = r.$2;
    }
  }
  final c = TsColumn.decode(d.build());
  return [for (var i = 0; i < v.length; i++) c.value(i)];
}

void main() {
  group('encodings', () {
    test('timestamps: delta of delta, edge values', () {
      final r = Random(1);
      for (final vals in [
        <int>[],
        [5],
        [0, -1],
        [-(1 << 63), (1 << 63) - 1, 0, -(1 << 63)],
        [for (var i = 0; i < 1000; i++) 1700000000 * sec + i * sec],
        [for (var i = 0; i < 1000; i++) r.nextInt(1 << 32) * 1000 - (1 << 40)],
      ]) {
        final a = Int64List.fromList(vals);
        expect(tsDecodeTimestamps(tsEncodeTimestamps(a), a.length), a);
        final c = TsColumn.decode(tsEncodeTsColumn(a).build());
        expect([for (var i = 0; i < a.length; i++) c.value(i)], vals);
      }
    });

    test('integers, floats, NaN, nulls', () {
      final ints = <Object?>[0, -1, 1, -(1 << 63), (1 << 63) - 1, null, 42, -7];
      expect(roundTrip(ints), ints);
      final fl = <Object?>[
        0.0, -0.0, 1.5, double.infinity, double.negativeInfinity, //
        double.minPositive, double.maxFinite, 3.14159, 3.14159, null, -2.5e-300
      ];
      final back = roundTrip(fl);
      for (var i = 0; i < fl.length; i++) {
        if (fl[i] == null) {
          expect(back[i], isNull);
        } else {
          final a = ByteData(8)..setFloat64(0, fl[i] as double);
          final b = ByteData(8)..setFloat64(0, back[i] as double);
          expect(b.getInt64(0), a.getInt64(0), reason: '$i');
        }
      }
      final nan = roundTrip([double.nan, 1.0, double.nan]);
      expect((nan[0] as double).isNaN, true);
      expect(nan[1], 1.0);
      final r = Random(2);
      final many = [for (var i = 0; i < 5000; i++) r.nextDouble() * 100];
      expect(roundTrip(many), many);
      final mi = [for (var i = 0; i < 5000; i++) r.nextInt(1000) - 500];
      expect(roundTrip(mi), mi);
    });

    test('strings: dictionary, plain, newlines, empty, generic', () {
      final lv = [for (var i = 0; i < 1000; i++) ['info', 'warn', 'error'][i % 3]];
      final d = tsEncodeColumn(lv);
      expect(d.head[0], tsKindDict);
      expect(roundTrip(lv), lv);
      final plain = [for (var i = 0; i < 300; i++) 'message $i é中'];
      expect(tsEncodeColumn(plain).head[0], tsKindText);
      expect(roundTrip(plain), plain);
      final nl = ['a\nb', '', 'c', '\n', ''];
      expect(roundTrip(nl), nl);
      expect(roundTrip(['']), ['']);
      expect(roundTrip(['', '', '']), ['', '', '']);
      final withNull = ['x', null, 'y', null];
      expect(roundTrip(withNull), withNull);
      final mixed = <Object?>[1, 'a', 2.5, null, Uint8List.fromList([1, 2]), -9];
      expect(roundTrip(mixed), mixed);
      expect(roundTrip([null, null]), [null, null]);
    });

    test('bloom filter has no false negatives', () {
      final vals = [for (var i = 0; i < 500; i++) 'host$i'];
      final f = tsBloomBuild(vals.map(tsHashValue), vals.length);
      for (final v in vals) {
        expect(tsBloomMay(f, tsHashValue(v)), true);
      }
      var fp = 0;
      for (var i = 0; i < 2000; i++) {
        if (tsBloomMay(f, tsHashValue('other$i'))) fp++;
      }
      expect(fp, lessThan(100));
    });

    test('partitions', () {
      final t = DateTime.utc(2026, 9, 30, 13, 5).microsecondsSinceEpoch * 1000;
      expect(zxTsPartStart(ZxTsPartition.hour, t),
          DateTime.utc(2026, 9, 30, 13).microsecondsSinceEpoch * 1000);
      expect(zxTsPartStart(ZxTsPartition.day, t),
          DateTime.utc(2026, 9, 30).microsecondsSinceEpoch * 1000);
      // 2026-09-28 is a Monday
      expect(zxTsPartStart(ZxTsPartition.week, t),
          DateTime.utc(2026, 9, 28).microsecondsSinceEpoch * 1000);
      expect(zxTsPartStart(ZxTsPartition.month, t),
          DateTime.utc(2026, 9).microsecondsSinceEpoch * 1000);
      expect(zxTsPartStart(ZxTsPartition.day, -1), -day);
    });
  });

  late Directory tmp;
  var n = 0;
  String newPath() => '${tmp.path}/ts${n++}.zx';
  setUp(() => tmp = Directory.systemTemp.createTempSync('zxdb_ts_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('random appends, seals, queries, retention, rollups, reopen, AS OF',
      () {
    final path = newPath();
    var db = ZxDatabase.open(path, create: true, options: opts());
    final base = DateTime.utc(2026, 1, 1).microsecondsSinceEpoch * 1000;
    var now = base ~/ 1000000 + 12 * 86400000;
    db.nowMs = () => now;
    db.createSeries(
        'm',
        const [
          ZxTsColumn('ts', 'DATETIME'),
          ZxTsColumn('host', 'TEXT'),
          ZxTsColumn('v', 'INTEGER'),
          ZxTsColumn('x', 'REAL'),
          ZxTsColumn('msg', 'TEXT'),
        ],
        partitionBy: 'day',
        retention: '10d',
        compression: 'balanced',
        fts: 'msg',
        tags: ['host'],
        segmentRows: 700,
        sealRows: 1 << 30);
    db.sql.execute("CREATE ROLLUP hr ON m EVERY '6h' AS SELECT host, "
        'count(*) AS n, sum(v) AS s, min(x) AS lo, max(x) AS hi, '
        'first(msg) AS f, last(msg) AS l FROM m WHERE v >= 0 GROUP BY host');
    final r = Random(7);
    int rl(int max) =>
        ((r.nextInt(1 << 30) << 30) + r.nextInt(1 << 30)) % max;
    // model rows: [ts, host, v, x, msg], in append order
    final model = <List<Object?>>[];
    final fed = <List<Object?>>[];
    var buffered = <List<Object?>>[];
    final words = ['alpha', 'beta', 'gamma', 'delta', 'timeout', 'error'];
    final snaps = <(int, List<List<Object?>>)>[];
    var dropped = 0, nonEmpty = 0;

    List<List<Object?>> expected(List<List<Object?>> rows,
        {int? from, int? to, String? host, String? word, bool desc = false}) {
      final idx = <int>[
        for (var i = 0; i < rows.length; i++)
          if ((from == null || (rows[i][0] as int) >= from) &&
              (to == null || (rows[i][0] as int) < to) &&
              (host == null || rows[i][1] == host) &&
              (word == null ||
                  '${rows[i][4]}'.split(' ').contains(word)))
            i
      ];
      idx.sort((a, b) {
        final d = (rows[a][0] as int).compareTo(rows[b][0] as int);
        return d != 0 ? d : a - b;
      });
      final out = [for (final i in idx) rows[i]];
      return desc ? out.reversed.toList() : out;
    }

    void check(ZxDatabase db, List<List<Object?>> rows, {int? gen}) {
      final s = db.series('m', generation: gen);
      for (var q = 0; q < 12; q++) {
        final from = r.nextBool() ? null : base + rl(14 * day);
        final to = r.nextBool() ? null : (from ?? base) + rl(5 * day);
        final host = r.nextInt(3) == 0 ? 'h${r.nextInt(4)}' : null;
        final word = r.nextInt(4) == 0 ? words[r.nextInt(words.length)] : null;
        final desc = r.nextBool();
        final got = s.query(
            from: from,
            to: to,
            where: host == null ? const {} : {'host': host},
            match: word,
            descending: desc);
        if (got.isNotEmpty) nonEmpty++;
        expect(got,
            expected(rows, from: from, to: to, host: host, word: word, desc: desc),
            reason: 'query $q from $from to $to host $host word $word desc $desc');
      }
      // a column subset
      final sub = s.query(columns: ['v', 'ts']);
      expect(sub, [for (final e in expected(rows)) [e[2], e[0]]]);
    }

    void checkRollup(ZxDatabase db) {
      final every = 6 * 3600 * sec;
      final groups = <String, List<List<Object?>>>{};
      for (final row in fed) {
        if ((row[2] as int) < 0) continue;
        final b = (row[0] as int) ~/ every * every;
        (groups['$b|${row[1]}'] ??= []).add(row);
      }
      final keys = groups.keys.toList()
        ..sort((a, b) {
          final pa = a.split('|'), pb = b.split('|');
          final d = int.parse(pa[0]).compareTo(int.parse(pb[0]));
          return d != 0 ? d : pa[1].compareTo(pb[1]);
        });
      final exp = <List<Object?>>[];
      for (final k in keys) {
        final g = groups[k]!;
        var firstRow = g.first, lastRow = g.first;
        for (final x in g) {
          if ((x[0] as int) < (firstRow[0] as int)) firstRow = x;
          if ((x[0] as int) >= (lastRow[0] as int)) lastRow = x;
        }
        exp.add([
          int.parse(k.split('|')[0]),
          g[0][1],
          g.length,
          g.fold<int>(0, (a, x) => a + (x[2] as int)),
          g.map((x) => x[3] as double).reduce(min),
          g.map((x) => x[3] as double).reduce(max),
          firstRow[4],
          lastRow[4],
        ]);
      }
      final got = db.sql.select('SELECT * FROM hr ORDER BY ts, host');
      expect(got, exp);
    }

    for (var step = 0; step < 30; step++) {
      final k = 1 + r.nextInt(400);
      final rows = <List<Object?>>[];
      for (var i = 0; i < k; i++) {
        final ts = base + rl(14 * day) ~/ 1000 * 1000;
        rows.add([
          ts,
          'h${r.nextInt(4)}',
          r.nextInt(2000) - 100,
          (r.nextInt(100000) / 7).toDouble(),
          '${words[r.nextInt(6)]} ${words[r.nextInt(6)]} n${r.nextInt(50)}',
        ]);
        if (r.nextInt(10) == 0 && rows.length > 1) {
          rows.last[0] = rows[rows.length - 2][0]; // equal times
        }
      }
      db.series('m').appendAll(rows);
      model.addAll(rows);
      buffered.addAll(rows);
      if (r.nextInt(3) == 0) {
        now += r.nextInt(2) * 86400000;
        db.series('m').seal();
        fed.addAll(buffered);
        buffered = [];
        final cutoff = (now - 10 * 86400000) * 1000000;
        final before = model.length;
        model.removeWhere((row) =>
            zxTsPartStart(ZxTsPartition.day, row[0] as int) + day <= cutoff);
        dropped += before - model.length;
        checkRollup(db);
      }
      if (step % 5 == 0) {
        snaps.add((db.store.lastGeneration, [for (final x in model) x]));
      }
      if (step % 7 == 6) {
        db.close();
        db = ZxDatabase.open(path, options: opts());
        db.nowMs = () => now;
      }
      check(db, model);
    }
    for (final (g, rows) in snaps) {
      check(db, rows, gen: g);
    }
    final st = db.series('m').stats;
    expect(dropped, greaterThan(0));
    expect(st.segments, greaterThan(10));
    expect(st.partitions, greaterThan(5));
    expect(nonEmpty, greaterThan(100));
    // SQL sees the same rows, ORDER BY ts consumed
    final sqlRows = db.sql.select('SELECT ts, host, v, x, msg FROM m ORDER BY ts');
    expect(sqlRows, expected(model));
    final lo = base + 3 * day, hi = base + 5 * day;
    expect(
        db.sql.select(
            'SELECT * FROM m WHERE ts >= ? AND ts < ? AND host = ? ORDER BY ts DESC',
            [lo, hi, 'h1']),
        expected(model, from: lo, to: hi, host: 'h1', desc: true));
    expect(
        db.sql.select("SELECT ts, host, v, x, msg FROM m WHERE search = 'timeout' "
            'ORDER BY ts'),
        expected(model, word: 'timeout'));
    final plan = db.sql
        .select('EXPLAIN QUERY PLAN SELECT * FROM m ORDER BY ts DESC')
        .map((e) => e.join(' '))
        .join('\n');
    expect(plan.contains('TEMP B-TREE'), false, reason: plan);
    // AS OF in SQL
    final (g0, rows0) = snaps[1];
    expect(
        db.sql.select(
            'SELECT ts, host, v, x, msg FROM m AS OF GENERATION $g0 ORDER BY ts'),
        expected(rows0));
    db.close();
  });

  test('SQL statements, rollups, zcm max, drop', () {
    final db = ZxDatabase.open(newPath(), create: true, options: opts());
    final sql = db.sql;
    sql.execute('''
      CREATE TIMESERIES logs (ts DATETIME, level TEXT, host TEXT,
        message TEXT, fields JSON, latency REAL)
      PARTITION BY HOUR RETENTION '400d'
      WITH (compression = 'max', fts = on, tags = (host, level))''');
    expect(() => sql.execute('CREATE TIMESERIES logs (ts DATETIME)'),
        throwsA(isA<ZxDbException>()));
    sql.execute('CREATE TIMESERIES IF NOT EXISTS logs (ts DATETIME)');
    final t0 = DateTime.now().toUtc().microsecondsSinceEpoch * 1000;
    for (var i = 0; i < 50; i++) {
      sql.execute('INSERT INTO logs VALUES (?, ?, ?, ?, ?, ?)', [
        t0 + i * 60 * sec,
        i % 5 == 0 ? 'error' : 'info',
        'web${i % 3}',
        'request $i served in ${i * 3} ms',
        '{"i": $i}',
        i * 1.5,
      ]);
    }
    sql.execute("CREATE ROLLUP per_h ON logs EVERY '1h' AS "
        'SELECT level, count(*) AS n, avg(latency) AS lat FROM logs GROUP BY level');
    // not sealed yet: the rollup is empty
    expect(sql.select('SELECT count(*) FROM per_h'), [
      [0]
    ]);
    expect(sql.select('SELECT count(*) FROM logs'), [
      [50]
    ]);
    final res = db.series('logs').seal();
    expect(res.rows, 50);
    expect(db.series('logs').stats.buffered, 0);
    final agg = sql.select('SELECT level, sum(n), sum(n * lat) FROM per_h '
        'GROUP BY level ORDER BY level');
    expect(agg[0][0], 'error');
    expect(agg[0][1], 10);
    expect(agg[1][1], 40);
    final lat = sql.select("SELECT sum(latency) FROM logs WHERE level = 'error'")[0][0]
        as double;
    expect((agg[0][2] as double) - lat, closeTo(0, 1e-6));
    expect(
        sql.select("SELECT count(*) FROM logs WHERE search = 'request served'"), [
      [50]
    ]);
    expect(sql.select("SELECT message FROM logs WHERE search = 'request 7'"), [
      ['request 7 served in 21 ms']
    ]);
    expect(sql.select("SELECT json_extract(fields, '\$.i') FROM logs "
        'WHERE ts >= ? ORDER BY ts LIMIT 2', [t0 + 10 * 60 * sec]), [
      [10],
      [11]
    ]);
    expect(
        sql.select("SELECT count(*) FROM logs WHERE host = 'web1' "
            "AND ts < zx_ns('2200-01-01')"),
        [
          [17]
        ]);
    expect(() => sql.execute('DELETE FROM logs'), throwsA(isA<ZxDbException>()));
    // row by row inserts in one transaction: the tiny buffer blocks are
    // written again as big ones
    sql.execute('BEGIN');
    for (var i = 0; i < 1100; i++) {
      sql.execute('INSERT INTO logs (ts, level, message) VALUES (?, ?, ?)',
          [t0 + 7200 * sec + i, 'debug', 'tick $i']);
    }
    sql.execute('COMMIT');
    expect(sql.select("SELECT count(*), min(message), max(ts) - min(ts) FROM logs WHERE level = 'debug'"), [
      [1100, 'tick 0', 1099]
    ]);
    sql.execute('DROP TIMESERIES logs');
    expect(() => sql.select('SELECT * FROM per_h'), throwsA(anything));
    expect(db.seriesNames, isEmpty);
    db.close();
  });

  test('importers: syslog, journald, JSON lines, CSV', () {
    final a = zxTsParseSyslog(
        '<34>Oct 11 22:14:15 mymachine su[123]: \'su root\' failed',
        year: 2025)!;
    expect(a['level'], 'crit');
    expect(a['facility'], 4);
    expect(a['host'], 'mymachine');
    expect(a['app'], 'su');
    expect(a['pid'], 123);
    expect(a['message'], "'su root' failed");
    expect(a['ts'], DateTime.utc(2025, 10, 11, 22, 14, 15).microsecondsSinceEpoch * 1000);
    final b = zxTsParseSyslog('<165>1 2003-10-11T22:14:15.003Z host.example '
        'evntslog - ID47 [exampleSDID@32473 iut="3"] An application event')!;
    expect(b['level'], 'notice');
    expect(b['app'], 'evntslog');
    expect(b['message'], 'An application event');
    expect(b['ts'], DateTime.utc(2003, 10, 11, 22, 14, 15, 3).microsecondsSinceEpoch * 1000);
    expect(zxTsParseSyslog('garbage'), isNull);
    final j = zxTsParseJournal('{"__REALTIME_TIMESTAMP":"1700000000123456",'
        '"_HOSTNAME":"box","SYSLOG_IDENTIFIER":"sshd","_PID":"42",'
        '"PRIORITY":"6","MESSAGE":"hello","_UID":"0"}')!;
    expect(j['ts'], 1700000000123456000);
    expect(j['level'], 'info');
    expect(j['fields'], {'_UID': '0'});
    final csv = zxTsParseCsv('ts,msg\n2026-01-01 00:00:00,"a, ""b"""\n'
            '2026-01-02,"x\ny"\n')
        .toList();
    expect(csv, [
      {'ts': '2026-01-01 00:00:00', 'msg': 'a, "b"'},
      {'ts': '2026-01-02', 'msg': 'x\ny'},
    ]);
    final db = ZxDatabase.open(newPath(), create: true, options: opts());
    final s = db.createSeries(
        'sys',
        const [
          ZxTsColumn('ts', 'DATETIME'),
          ZxTsColumn('host', 'TEXT'),
          ZxTsColumn('level', 'TEXT'),
          ZxTsColumn('message', 'TEXT'),
          ZxTsColumn('fields', 'JSON'),
        ],
        compression: 'fast');
    expect(zxTsImport(s, [a, b, j, zxTsParseJsonLine('{"ts": 5, "message": "m", "k": 1}')!]), 4);
    s.seal();
    final rows = s.query();
    expect(rows.length, 4);
    expect(rows[0], [5, null, null, 'm', '{"k":1}']);
    expect(jsonDecode(rows[2][4] as String)['_UID'], '0');
    expect(jsonDecode(rows[3][4] as String), {'facility': 4, 'app': 'su', 'pid': 123});
    db.close();
  });
}
