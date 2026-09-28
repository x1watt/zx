// Tests of the time series of zxdb (lib/src/db/ts/): encodings, the
// store against an in-memory reference model (random appends, seals,
// queries, retention, rollups, reopen, AS OF), SQL and the importers.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/db/engine/compression.dart' show zxDbFastChain;
import 'package:zx/src/db/sql/zx_sql.dart' show zxFormatDatetimeNs;
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

  test('SQL: DATETIME comparisons with text, unixepoch, julianday', () {
    final db = ZxDatabase.open(newPath(), create: true, options: opts());
    final sql = db.sql;
    sql.execute('CREATE TIMESERIES m (ts DATETIME, v INTEGER) '
        "PARTITION BY DAY WITH (seal_rows = 100)");
    // one row per hour from 2026-08-30 00:00 UTC for 5 days; the first
    // 100 are sealed (seal_rows), the rest buffered
    final t0 = DateTime.utc(2026, 8, 30).microsecondsSinceEpoch * 1000;
    const hour = 3600 * sec;
    db.series('m').appendAll([
      for (var i = 0; i < 120; i++) [t0 + i * hour, i]
    ]);
    int count(String where, [List<Object?> p = const []]) =>
        sql.select('SELECT count(*) FROM m WHERE $where', p)[0][0] as int;
    int ref(int from, int to) =>
        [for (var i = 0; i < 120; i++) t0 + i * hour]
            .where((t) => t >= from && t < to)
            .length;
    final d1 = DateTime.utc(2026, 9, 1).microsecondsSinceEpoch * 1000;
    final d2 = DateTime.utc(2026, 9, 2).microsecondsSinceEpoch * 1000;
    const big = 1 << 62;
    expect(count("ts >= '2026-09-01'"), ref(d1, big));
    expect(count("ts < '2026-09-01T00:00:00Z'"), ref(-big, d1));
    expect(count("ts >= '2026-09-01 02:00:00.000000001'"),
        ref(d1 + 2 * hour + 1, big));
    expect(count("ts >= '2026-09-01T03:00:00+02:00'"), ref(d1 + hour, big));
    expect(count("ts BETWEEN '2026-09-01 10:00' AND '2026-09-02'"),
        ref(d1 + 10 * hour, d2 + 1));
    expect(count("'2026-09-01' <= ts"), ref(d1, big));
    expect(count("ts = '2026-09-01 05:00:00'"), 1);
    expect(count("ts IN ('2026-09-01 05:00', '2026-09-01 06:00:00Z')"), 2);
    expect(count("ts >= unixepoch('2026-09-01')"), ref(d1, big));
    expect(count("ts >= unixepoch('2026-09-02') - 86400"), ref(d1, big));
    expect(count("ts >= julianday('2026-09-01')"), ref(d1, big));
    expect(count('ts >= ?', ['2026-09-01']), ref(d1, big));
    expect(count("ts < datetime('2026-09-02', '-1 day')"), ref(-big, d1));
    expect(count("ts >= zx_ns('2026-09-01')"), ref(d1, big));
    expect(count('ts >= ?', [d1]), ref(d1, big));
    // the text bound limits the partitions read (plan)
    final plan = sql
        .select("EXPLAIN QUERY PLAN SELECT * FROM m WHERE ts BETWEEN "
            "'2026-09-01' AND '2026-09-02'")
        .map((r) => r[3])
        .join();
    expect(plan, contains('t>=,t<='));
    // now relative: rows of the last day before now
    final now = DateTime.now().toUtc().microsecondsSinceEpoch * 1000;
    db.series('m').appendAll([
      [now - 2 * day, -1],
      [now - hour, -2]
    ]);
    expect(count("ts > datetime('now', '-1 day')"), 1);
    expect(count("ts > unixepoch('now') - 86400"), 1);
    // date functions read the ns of a DATETIME column; results carry
    // the column type
    final r = sql.execute(
        "SELECT ts, datetime(ts), date(ts), strftime('%H', ts), zx_datetime(ts) "
        'FROM m WHERE v = 5');
    expect(r.rows, [
      [t0 + 5 * hour, '2026-08-30 05:00:00', '2026-08-30', '05',
        '2026-08-30 05:00:00.000000000']
    ]);
    expect(r.types[0], 'DATETIME');
    expect(r.isDatetime(0), isTrue);
    expect(r.isDatetime(1), isFalse);
    expect(sql.execute('SELECT x FROM (SELECT ts AS x FROM m) LIMIT 1')
        .isDatetime(0), isTrue);
    expect(sql.query('SELECT ts FROM m LIMIT 1').isDatetime(0), isTrue);
    expect(zxFormatDatetimeNs(t0 + 1500000), '2026-08-30 00:00:00.001500');
    expect(zxFormatDatetimeNs(-1), '1969-12-31 23:59:59.999999999');
    // plain tables keep SQLite's rules: a DATETIME is NUMERIC there
    sql.execute('CREATE TABLE p (ts DATETIME)');
    sql.execute('INSERT INTO p VALUES (?)', [d1]);
    expect(sql.select("SELECT count(*) FROM p WHERE ts >= '2026-09-01'")[0][0],
        0);
    db.close();
  });

  test('SQL: HISTORY OF a series', () {
    final db = ZxDatabase.open(newPath(), create: true, options: opts());
    final t0 = DateTime.utc(2026, 9, 1).microsecondsSinceEpoch * 1000;
    db.nowMs = () => t0 ~/ 1000000 + 3600 * 1000;
    final s = db.createSeries(
        'h', [ZxTsColumn('ts', 'DATETIME'), ZxTsColumn('v', 'TEXT')],
        partitionBy: 'day', retention: '3d');
    s.appendAll([
      [t0, 'a'],
      [t0 + sec, 'b'],
      [t0 - 2 * day, 'old'],
    ]);
    final gAppend1 = db.store.generations.last.generation;
    s.seal();
    s.appendAll([
      [t0 + 2 * sec, 'c'],
      [t0 + sec, 'b'],
    ]);
    // five days later: the seal drops the partitions past the retention
    db.nowMs = () => t0 ~/ 1000000 + 5 * 86400 * 1000;
    s.appendAll([
      [t0 + 5 * day, 'new'],
    ]);
    s.seal();
    final gLast = db.store.generations.last.generation;
    final h = db.sql.execute(
        'SELECT v, zx_op, zx_rows, zx_generation, datetime(ts) FROM HISTORY OF h');
    final rows = h.rows;
    expect(rows.where((r) => r[1] == 'append').map((r) => r[0]).toList(),
        ['old', 'a', 'b', 'b', 'c', 'new']);
    expect(rows.where((r) => r[1] == 'append' && r[0] == 'a').single[3],
        gAppend1);
    final ret = rows.where((r) => r[1] == 'retention').toList();
    expect(ret.map((r) => r[2]).toList(), [1, 4]);
    expect(ret.map((r) => r[4]).toList(),
        ['2026-08-30 00:00:00', '2026-09-01 00:00:00']);
    expect(ret.every((r) => r[3] == gLast && r[0] == null), isTrue);
    expect(h.isDatetime(4), isFalse);
    expect(
        db.sql.select("SELECT count(*) FROM HISTORY OF h WHERE zx_op = 'append' "
            "AND ts >= '2026-09-01'"),
        [
          [5]
        ]);
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
    // not sealed yet: the rollup aggregates the write buffer on the fly
    expect(sql.select('SELECT sum(n) FROM per_h'), [
      [50]
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

  group('rollups: buffered rows, general WHERE', () {
    test('buffer merge and expression WHERE match a plain aggregate', () {
      final db = ZxDatabase.open(newPath(), create: true, options: opts());
      final sql = db.sql;
      sql.execute('''
        CREATE TIMESERIES m (ts DATETIME, host TEXT, v REAL, msg TEXT)
        PARTITION BY HOUR''');
      final r = Random(7);
      final t0 = 1790000000 * sec;
      final all = <List<Object?>>[];
      void add(int n) {
        final rows = [
          for (var i = 0; i < n; i++)
            [
              t0 + r.nextInt(6 * 3600) * sec,
              'h${r.nextInt(3)}',
              r.nextInt(100) / 4,
              r.nextBool() ? 'Timeout upstream' : 'ok'
            ]
        ];
        all.addAll(rows);
        db.series('m').appendAll(rows);
      }

      // a general WHERE: functions, arithmetic, OR
      sql.execute("CREATE ROLLUP q ON m EVERY '1h' AS "
          "SELECT host, count(*) AS n, sum(v) AS s, min(v) AS lo, "
          "max(v) AS hi, last(v) AS lv FROM m "
          "WHERE lower(msg) LIKE '%timeout%' OR v * 2 > 40 GROUP BY host");
      expect(db.series('m').rollups.single.whereSql, isNotNull);
      // a simple WHERE keeps the fast path
      sql.execute("CREATE ROLLUP f ON m EVERY '1h' AS "
          "SELECT count(*) AS n FROM m WHERE host = 'h1'");
      expect(db.series('m').rollups.firstWhere((d) => d.name == 'f').whereSql,
          isNull);
      const expQ = 'SELECT ts / 3600000000000 * 3600000000000 AS b, host, '
          'count(*), sum(v), min(v), max(v) FROM m '
          "WHERE lower(msg) LIKE '%timeout%' OR v * 2 > 40 "
          'GROUP BY b, host ORDER BY b, host';
      const gotQ = 'SELECT ts, host, n, s, lo, hi FROM q ORDER BY ts, host';
      void check() {
        expect(sql.select(gotQ), sql.select(expQ));
        expect(sql.select('SELECT sum(n) FROM f'),
            sql.select("SELECT count(*) FROM m WHERE host = 'h1'"));
        // descending and a range, merged in order
        final desc = sql.select('SELECT ts, host, n FROM q '
            'WHERE ts >= ? AND ts < ? ORDER BY ts DESC',
            [t0 + 3600 * sec, t0 + 4 * 3600 * sec]);
        final asc = sql.select('SELECT ts, host, n FROM q '
            'WHERE ts >= ? AND ts < ? ORDER BY ts',
            [t0 + 3600 * sec, t0 + 4 * 3600 * sec]);
        expect(desc.map((x) => x[0]).toList(),
            asc.map((x) => x[0]).toList().reversed.toList());
        expect(desc.length, asc.length);
      }

      add(300);
      check(); // everything buffered
      db.series('m').seal();
      check(); // everything sealed
      add(200);
      check(); // sealed and buffered rows in the same buckets
      // the Dart API sees the buffer too; buffer: false only sealed rows
      final d = db.series('m').rollups.firstWhere((d) => d.name == 'f');
      final snap = db.readSnapshot();
      int total(bool buffer) => zxRollupRows(snap, d, buffer: buffer)
          .fold(0, (a, x) => a + (x[1] as int));
      expect(total(true),
          all.where((x) => x[1] == 'h1').length);
      expect(total(false) < total(true), isTrue);
      db.series('m').seal();
      check(); // no double count after the seal
      expect(
          () => sql.execute("CREATE ROLLUP bad ON m EVERY '1h' AS "
              'SELECT count(*) AS n FROM m WHERE nope + 1 > 2'),
          throwsA(anything));
      db.close();
    });
  });

  group('hot tier', () {
    test('LZ4 copies of recent partitions, aging, defaults, drop', () {
      final db = ZxDatabase.open(newPath(), create: true, options: opts());
      final t0 = DateTime.utc(2026, 3, 1).microsecondsSinceEpoch * 1000;
      var now = t0 ~/ 1000000 + 10 * 86400000;
      db.nowMs = () => now;
      const cols = [
        ZxTsColumn('ts', 'DATETIME'),
        ZxTsColumn('n', 'INTEGER'),
        ZxTsColumn('message', 'TEXT'),
      ];
      final r = Random(7);
      final rows = [
        for (var i = 0; i < 4000; i++)
          [
            t0 + i * (10 * day ~/ 4000),
            i,
            'request ${r.nextInt(500)} from host${r.nextInt(9)} took '
                '${r.nextInt(3000)} ms'
          ]
      ];
      for (final (name, hd) in [('h2', 2), ('h20', 20), ('h0', 0)]) {
        db.createSeries(name, cols, compression: 'balanced', hotDays: hd);
        db.series(name).appendAll(rows);
        db.series(name).seal();
      }
      final snap = db.readSnapshot();
      final h2 = zxTsHotBytes(snap, 'h2');
      final h20 = zxTsHotBytes(snap, 'h20');
      expect(h2, greaterThan(0));
      expect(h20, greaterThan(h2 * 3)); // every partition vs the last two
      expect(zxTsHotBytes(snap, 'h0'), 0);
      // scans read the hot copy and give the same rows as the cold one
      for (final name in ['h2', 'h20']) {
        final s = db.series(name);
        zxTsClearCache();
        expect(s.query(), rows);
        zxTsClearCache();
        final cold = ZxTsScan(db.readSnapshot(),
            ZxTsDef.fromJson(name, {...s.def.toJson(), 'hotDays': 0}),
            const ZxTsScanSpec());
        var i = 0;
        while (cold.moveNext()) {
          expect(cold.value(2), rows[i++][2]);
        }
        expect(i, rows.length);
      }
      // the copies age out at the next seal (and VACUUM)
      now += 3 * 86400000;
      db.series('h2').seal();
      expect(zxTsHotBytes(db.readSnapshot(), 'h2'), 0);
      db.vacuum();
      final h20b = zxTsHotBytes(db.readSnapshot(), 'h20');
      expect(h20b, greaterThan(0));
      expect(h20b, lessThanOrEqualTo(h20));
      expect(db.series('h20').query(), rows);
      // defaults: one day; fast text keeps no copy
      db.createSeries('d', cols, compression: 'fast');
      expect(db.series('d').def.hotDays, 1);
      db.series('d').appendAll(rows.sublist(3900));
      db.series('d').seal();
      expect(zxTsHotBytes(db.readSnapshot(), 'd'), 0);
      final sql = db.sql;
      sql.execute('CREATE TIMESERIES s1 (ts DATETIME, m TEXT) '
          'WITH (hot_days = 0)');
      sql.execute("CREATE TIMESERIES s2 (ts DATETIME, m TEXT) "
          "WITH (hot_days = '36h')");
      expect(db.series('s1').def.hotDays, 0);
      expect(db.series('s2').def.hotDays, 2);
      // dropping the series drops its hot tier
      db.dropSeries('h20');
      expect(db.readSnapshot().tree('ts:h20:hot'), isNull);
      db.close();
    });
  });
}
