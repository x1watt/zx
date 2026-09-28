// Benchmarks of zxdb (docs/zxdb-design.md section 7): KV get hot, KV put
// batched, the size of the same KV data against a SQLite file (when the
// sqlite3 tool is installed), and the persisted TLSH band index of the
// system tables with many digests.
//
//   dart compile exe tool/zxdb_bench.dart -o /tmp/zxdb_bench
//   systemd-run --user --scope -q -p MemoryMax=3G -p MemorySwapMax=0 \
//     /tmp/zxdb_bench [--dir=DIR] [--tlsh=1000000] [--skip-max]
//     [--only=kv,commit,sql,levels,size,tlsh]
//
// Numbers go to docs/performance.md (measured in AOT, not with dart run).

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:zx/src/db/system/tlsh_index.dart';
import 'package:zx/src/db/zxdb.dart';

Uint8List b(String s) => Uint8List.fromList(utf8.encode(s));

String fmt(double v, [int d = 1]) => v.toStringAsFixed(d);

// a realistic value: a JSON log or settings record of about 100-200 bytes
String jsonValue(int i, Random r) {
  const levels = ['info', 'info', 'info', 'warn', 'debug', 'error'];
  const sources = ['net', 'db', 'ui', 'auth', 'sync', 'cache'];
  return '{"ts":${1790000000000 + i * 37},"level":"${levels[r.nextInt(6)]}",'
      '"source":"${sources[r.nextInt(6)]}","user":"user${r.nextInt(5000)}",'
      '"msg":"request ${r.nextInt(100000)} took ${r.nextInt(900)} ms",'
      '"ok":${r.nextBool()}}';
}

void main(List<String> args) {
  var dir = Directory.systemTemp.createTempSync('zxdb_bench').path;
  var tlshN = 1000000;
  var skipMax = false;
  var cacheMiB = 128;
  var only = {'kv', 'commit', 'sql', 'levels', 'size', 'tlsh'};
  for (final a in args) {
    if (a.startsWith('--only=')) only = a.substring(7).split(',').toSet();
    if (a.startsWith('--dir=')) dir = a.substring(6);
    if (a.startsWith('--tlsh=')) tlshN = int.parse(a.substring(7));
    if (a == '--skip-max') skipMax = true;
    if (a.startsWith('--cache=')) cacheMiB = int.parse(a.substring(8));
  }
  Directory(dir).createSync(recursive: true);
  print('zxdb bench in $dir');
  final opts = ZxDbStoreOptions(
      durable: false, autoFoldBytes: 0, pageCacheBytes: cacheMiB << 20);

  // ---- KV put batched
  if (only.contains('kv')) {
    final path = '$dir/put.zx';
    _rm(path);
    final db = ZxDatabase.open(path, create: true, options: opts);
    final kv = db.createKvStore('bench');
    final r = Random(1);
    const n = 1000000, batch = 10000;
    final keys = [for (var i = 0; i < n; i++) b('user:${(i * 7919 % n).toString().padLeft(8, '0')}')];
    final vals = [for (var i = 0; i < 1000; i++) b(jsonValue(i, r))];
    final sw = Stopwatch()..start();
    for (var i = 0; i < n; i += batch) {
      kv.batch((w) {
        for (var j = i; j < i + batch; j++) {
          w.put(keys[j], vals[j % 1000]);
        }
      });
    }
    final s = sw.elapsedMicroseconds / 1e6;
    print('KV put batched (1M keys, random order, batches of 10k, fast): '
        '${fmt(n / s / 1000)}k puts/s (${fmt(s, 2)} s), '
        'file ${File(path).lengthSync() >> 20} MiB');
    // sequential keys
    final kv2 = db.createKvStore('seq');
    sw.reset();
    for (var i = 0; i < n; i += batch) {
      kv2.batch((w) {
        for (var j = i; j < i + batch; j++) {
          w.put(b('seq:${j.toString().padLeft(8, '0')}'), vals[j % 1000]);
        }
      });
    }
    final s2 = sw.elapsedMicroseconds / 1e6;
    print('KV put batched (1M keys, ascending): ${fmt(n / s2 / 1000)}k puts/s');

    // random puts into the 1M key tree (half overwrite existing keys,
    // half new keys): the delta layer takes them as sorted runs, folded
    // into the tree when they reach half its size
    {
      final rr = Random(5);
      const m = 500000;
      final rk = [
        for (var i = 0; i < m; i++)
          b('seq:${(rr.nextBool() ? rr.nextInt(n) : n + rr.nextInt(4 * n)).toString().padLeft(8, '0')}')
      ];
      final before = File(path).lengthSync();
      sw.reset();
      for (var i = 0; i < m; i += batch) {
        kv2.batch((w) {
          for (var j = i; j < i + batch; j++) {
            w.put(rk[j], vals[j % 1000]);
          }
        });
      }
      final s3 = sw.elapsedMicroseconds / 1e6;
      final grown = File(path).lengthSync() - before;
      sw.reset();
      db.store.foldDeltas();
      final sf = sw.elapsedMicroseconds / 1e6;
      print('KV put batched, random keys into the 1M tree (500k puts, '
          'batches of 10k): ${fmt(m / s3 / 1000)}k puts/s (${fmt(s3, 2)} s, '
          'folds included), file +${grown >> 20} MiB; final fold '
          '${fmt(sf, 2)} s, file ${File(path).lengthSync() >> 20} MiB');
      sw.reset();
      final c = db.store.snapshot().tree('kv:seq')!.scan();
      var cnt = 0, bytes = 0;
      while (c.moveNext()) {
        cnt++;
        bytes += c.value.length;
      }
      final ss = sw.elapsedMicroseconds / 1e6;
      print('  full scan: $cnt entries in ${fmt(ss, 2)} s '
          '(${fmt(cnt / ss / 1e6, 2)} M entries/s, $bytes value bytes)');
      sw.reset();
      db.vacuum();
      print('  vacuum: ${fmt(sw.elapsedMicroseconds / 1e6, 2)} s, file '
          '${File(path).lengthSync() >> 20} MiB');
    }

    // ---- KV get hot: 10k and 100k keys drawn at random from the 1M
    // (spread over every leaf), read until they are in the page cache
    final rnd = Random(2);
    for (final hot in [10000, 100000]) {
      final hk = [for (var i = 0; i < hot; i++) keys[rnd.nextInt(n)]];
      final probe = [for (var i = 0; i < 1000000; i++) hk[rnd.nextInt(hot)]];
      for (var r = 0; r < 2; r++) {
        for (final k in hk) {
          kv.get(k);
        }
      }
      sw.reset();
      var found = 0;
      for (final k in probe) {
        if (kv.get(k) != null) found++;
      }
      final us = sw.elapsedMicroseconds / probe.length;
      print('KV get hot (ZxKvStore.get, $hot random hot keys of 1M): '
          '${fmt(us, 2)} us/get ($found found)');
    }
    final probe = [for (var i = 0; i < 1000000; i++) keys[rnd.nextInt(10000)]];
    for (final k in probe.take(20000)) {
      kv.get(k);
    }
    final tree = db.store.snapshot().tree('kv:bench')!;
    sw.reset();
    for (final k in probe) {
      tree.get(k);
    }
    print('  tree get (ZxTree.get on a snapshot, 10k hot keys): '
        '${fmt(sw.elapsedMicroseconds / probe.length, 2)} us/get');
    // cold: caches dropped
    db.store.clearCaches();
    final cold = db.store.snapshot().tree('kv:bench')!;
    sw.reset();
    for (var i = 0; i < 2000; i++) {
      cold.get(keys[rnd.nextInt(n)]);
    }
    print('  cold get (LZ4 pages, empty caches, 2000 random): '
        '${fmt(sw.elapsedMicroseconds / 2000, 1)} us/get');
    db.close();
  }

  // ---- commit latency: autocommit, durable or not, and group commit
  if (only.contains('commit')) {
    for (final durable in [false, true]) {
      for (final gc in [null, const Duration(milliseconds: 2)]) {
        final path = '$dir/commit.zx';
        _rm(path);
        final o = ZxDbStoreOptions(durable: durable, autoFoldBytes: 0);
        final db = ZxDatabase.open(path,
            create: true, options: o, groupCommit: gc);
        final kv = db.createKvStore('c');
        final r = Random(6);
        const n = 2000;
        final sw = Stopwatch()..start();
        for (var i = 0; i < n; i++) {
          kv.put(b('k${r.nextInt(1 << 30)}'), b(jsonValue(i, r)));
        }
        db.flush();
        final s = sw.elapsedMicroseconds / 1e6;
        final gens = db.store.lastGeneration;
        print('KV put autocommit, durable $durable, group commit '
            '${gc == null ? 'off' : '2 ms'}: ${fmt(n / s)} puts/s, '
            '${fmt(s / gens * 1e6)} us/commit ($gens generations), file '
            '${File(path).lengthSync() >> 10} KiB');
        db.close();
      }
    }
  }

  if (only.contains('sql')) _sqlBench(dir, hasSqlite: _hasSqlite());
  if (only.contains('levels')) _levelsBench(dir, skipMax: skipMax);

  // ---- sizes against SQLite
  final hasSqlite = _hasSqlite();
  for (final n in [20000, 200000]) {
    if (!only.contains('size')) break;
    final r = Random(3);
    final data = <(String, String)>[
      for (var i = 0; i < n; i++)
        ('log:${i.toString().padLeft(9, '0')}', jsonValue(i, r))
    ];
    var raw = 0;
    for (final (k, v) in data) {
      raw += k.length + v.length;
    }
    print('Sizes, $n JSON log records (${fmt(raw / 1048576, 2)} MiB raw):');
    if (hasSqlite) {
      final sq = '$dir/kv$n.sqlite';
      final sql = '$dir/kv$n.sql';
      _rm(sq);
      final out = StringBuffer(
          'PRAGMA page_size=4096;CREATE TABLE kv(key TEXT PRIMARY KEY, value TEXT) WITHOUT ROWID;BEGIN;\n');
      for (final (k, v) in data) {
        out.write("INSERT INTO kv VALUES('$k','${v.replaceAll("'", "''")}');\n");
      }
      out.write('COMMIT;VACUUM;\n');
      File(sql).writeAsStringSync(out.toString());
      final res = Process.runSync('sh', ['-c', 'sqlite3 $sq < $sql']);
      if (res.exitCode == 0) {
        print('  sqlite3 (WITHOUT ROWID, vacuumed): '
            '${fmt(File(sq).lengthSync() / 1024)} KiB');
      } else {
        print('  sqlite3 failed: ${res.stderr}');
      }
      _rm(sql);
    } else {
      print('  sqlite3 not installed: no comparison');
    }
    for (final c in ['fast', 'balanced', if (!skipMax && n <= 20000) 'max']) {
      final path = '$dir/kv$n-$c.zx';
      _rm(path);
      final db = ZxDatabase.open(path, create: true, options: opts);
      final kv = db.createKvStore('logs', compression: c);
      final sw = Stopwatch()..start();
      kv.batch((w) {
        for (final (k, v) in data) {
          w.putString(k, v);
        }
      });
      db.fold();
      db.vacuum();
      final s = sw.elapsedMicroseconds / 1e6;
      print('  zxdb $c (folded, vacuumed): '
          '${fmt(File(path).lengthSync() / 1024)} KiB in ${fmt(s, 1)} s');
      db.close();
    }
  }

  // ---- the TLSH band index of the system tables
  if (tlshN > 0 && only.contains('tlsh')) {
    final r = Random(4);
    Uint8List rnd(int n) {
      final d = Uint8List(n);
      for (var i = 0; i < n; i++) {
        d[i] = r.nextInt(256);
      }
      return d;
    }

    // incremental: ZxTlshStore.addDigest per digest (keys in random
    // order), commits of 10k digests, as ZxTlshStore.sync adds them
    {
      final path = '$dir/tlsh-inc.zx';
      _rm(path);
      final st = ZxDbStore.open(path, create: true, options: opts);
      final n = tlshN < 100000 ? tlshN : 100000;
      final sw = Stopwatch()..start();
      for (var i = 0; i < n; i += 10000) {
        final t = st.begin();
        final bands = t.tree(ZxTlshStore.bandsTree) ??
            t.createTree(ZxTlshStore.bandsTree);
        final digests = t.tree(ZxTlshStore.digestsTree) ??
            t.createTree(ZxTlshStore.digestsTree);
        for (var j = i; j < i + 10000 && j < n; j++) {
          ZxTlshStore.addDigest(bands, digests, rnd(32), rnd(tlshBinSize));
        }
        t.commit();
      }
      final s = sw.elapsedMicroseconds / 1e6;
      print('TLSH band index, incremental: $n digests (17 keys each) in '
          'commits of 10k: ${fmt(s, 1)} s, ${fmt(n * 17 / s / 1000)}k '
          'keys/s, file ${File(path).lengthSync() >> 20} MiB');
      st.close();
    }

    // bulk: the band keys sorted per band, one transaction (pages are
    // spilled as they fill)
    final path = '$dir/tlsh.zx';
    _rm(path);
    final st = ZxDbStore.open(path, create: true, options: opts);
    final shas = [for (var i = 0; i < tlshN; i++) rnd(32)];
    final digs = [for (var i = 0; i < tlshN; i++) rnd(tlshBinSize)];
    final queries = [for (var i = 0; i < 100; i++) digs[i * (tlshN ~/ 100)]];
    final sw = Stopwatch()..start();
    final t = st.begin();
    final bands = t.createTree(ZxTlshStore.bandsTree);
    final digests = t.createTree(ZxTlshStore.digestsTree);
    final order = List<int>.generate(tlshN, (i) => i);
    int cmp(Uint8List a, Uint8List b) => zxCompareKeys(a, b);
    order.sort((a, b) => cmp(shas[a], shas[b]));
    for (final i in order) {
      digests.put(shas[i], digs[i]);
    }
    for (var band = 0; band < tlshBands; band++) {
      final keys = [
        for (var i = 0; i < tlshN; i++)
          ZxTlshStore.bandKey(band,
              (digs[i][3 + 2 * band] << 8) | digs[i][4 + 2 * band], shas[i])
      ]..sort(cmp);
      final empty = Uint8List(0);
      for (final k in keys) {
        bands.put(k, empty);
      }
    }
    t.commit();
    final s = sw.elapsedMicroseconds / 1e6;
    print('TLSH band index, bulk: $tlshN digests (17 keys each, sorted, one '
        'transaction): ${fmt(s, 1)} s, ${fmt(tlshN * 17 / s / 1000)}k keys/s, '
        'file ${File(path).lengthSync() >> 20} MiB');
    final snap = st.snapshot();
    // queries: near duplicates of stored digests (one bucket changed)
    for (var round = 0; round < 2; round++) {
      sw.reset();
      var hits = 0;
      for (final q in queries) {
        final near = Uint8List.fromList(q)..[3] ^= 1;
        final res = ZxTlshStore.query(snap, near, maxDistance: 60, limit: 20);
        if (res.isNotEmpty) hits++;
      }
      print('  query ${round == 0 ? 'cold' : 'warm'} (probe level 1, top '
          '20): ${fmt(sw.elapsedMicroseconds / queries.length / 1000, 2)} '
          'ms/query, $hits of ${queries.length} found their near duplicate');
    }
    st.close();
  }
}

void _rm(String p) {
  for (final f in [p, '$p.zx-lock']) {
    if (File(f).existsSync()) File(f).deleteSync();
  }
}

bool _hasSqlite() =>
    Process.runSync('sh', ['-c', 'command -v sqlite3']).exitCode == 0;

// runs a SQL script with the sqlite3 tool; its time in seconds (the
// process start and the parsing of each statement included)
double _sqlite(String db, String script, String dir) {
  final f = '$dir/script.sql';
  File(f).writeAsStringSync(script);
  final sw = Stopwatch()..start();
  final r = Process.runSync('sh', ['-c', 'sqlite3 $db < $f > /dev/null']);
  final s = sw.elapsedMicroseconds / 1e6;
  if (r.exitCode != 0) throw StateError('sqlite3: ${r.stderr}');
  File(f).deleteSync();
  return s;
}

// SQL: inserts (sequential and random ids, one transaction and
// autocommit), point selects and a scan, zxdb against sqlite3
void _sqlBench(String dir, {required bool hasSqlite}) {
  const n = 100000;
  final r = Random(7);
  final rows = [for (var i = 0; i < n; i++) jsonValue(i, r)];
  final randomIds = [for (var i = 0; i < n; i++) r.nextInt(1 << 30) * 1024 + r.nextInt(1024)];
  final probes = [for (var i = 0; i < 20000; i++) r.nextInt(n)];
  final opts = ZxDbStoreOptions(durable: false, autoFoldBytes: 0);
  print('SQL, $n rows (id INTEGER PRIMARY KEY, v TEXT of JSON):');
  for (final random in [false, true]) {
    final path = '$dir/sql.zx';
    _rm(path);
    final db = ZxDatabase.open(path, create: true, options: opts);
    final sql = db.sql;
    sql.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT) "
        "WITH (compression = 'fast')");
    final ins = sql.prepare('INSERT INTO t VALUES (?, ?)');
    final sw = Stopwatch()..start();
    for (var i = 0; i < n; i += 10000) {
      sql.execute('BEGIN');
      for (var j = i; j < i + 10000; j++) {
        ins.execute([random ? randomIds[j] : j, rows[j]]);
      }
      sql.execute('COMMIT');
    }
    final si = sw.elapsedMicroseconds / 1e6;
    final ids = random ? randomIds : [for (var i = 0; i < n; i++) i];
    final sel = sql.prepare('SELECT v FROM t WHERE id = ?');
    for (final p in probes.take(2000)) {
      sel.select([ids[p]]);
    }
    sw.reset();
    var found = 0;
    for (final p in probes) {
      found += sel.select([ids[p]]).length;
    }
    final ss = sw.elapsedMicroseconds / 1e6;
    sw.reset();
    final agg = sql.select('SELECT count(*), sum(length(v)) FROM t');
    final sc = sw.elapsedMicroseconds / 1e6;
    // autocommit inserts: each one a commit (a generation)
    final g0 = db.store.lastGeneration;
    sw.reset();
    for (var j = 0; j < 1000; j++) {
      ins.execute([(1 << 41) + (random ? randomIds[j] : j), rows[j]]);
    }
    final sa = sw.elapsedMicroseconds / 1e6;
    final commits = db.store.lastGeneration - g0;
    db.fold();
    db.vacuum();
    sw.reset();
    sql.select('SELECT count(*), sum(length(v)) FROM t');
    final sc2 = sw.elapsedMicroseconds / 1e6;
    print('  zxdb ${random ? 'random' : 'sequential'} ids: insert '
        '${fmt(n / si / 1000)}k rows/s (transactions of 10k), select by id '
        '${fmt(ss / probes.length * 1e6, 2)} us ($found found), scan '
        '${fmt(sc * 1000)} ms (${agg.first[0]} rows; ${fmt(sc2 * 1000)} ms '
        'after fold and vacuum), autocommit insert ${fmt(sa * 1000)} us '
        'each ($commits commits of 1000), file '
        '${File(path).lengthSync() >> 10} KiB');
    db.close();
    if (!hasSqlite) continue;
    final sq = '$dir/sql.sqlite';
    _rm(sq);
    final esc = [for (final v in rows) v.replaceAll("'", "''")];
    final w = StringBuffer('PRAGMA synchronous=OFF;PRAGMA journal_mode=DELETE;'
        'CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT);\n');
    for (var i = 0; i < n; i += 10000) {
      w.write('BEGIN;\n');
      for (var j = i; j < i + 10000; j++) {
        w.write("INSERT INTO t VALUES (${ids[j]}, '${esc[j]}');\n");
      }
      w.write('COMMIT;\n');
    }
    final qi = _sqlite(sq, w.toString(), dir);
    final q = StringBuffer();
    for (final p in probes) {
      q.write('SELECT v FROM t WHERE id = ${ids[p]};\n');
    }
    final qs = _sqlite(sq, q.toString(), dir);
    final qc = _sqlite(sq, 'SELECT count(*), sum(length(v)) FROM t;', dir);
    final a = StringBuffer('PRAGMA synchronous=OFF;\n');
    for (var j = 0; j < 1000; j++) {
      a.write("INSERT INTO t VALUES (${(1 << 41) + ids[j]}, '${esc[j]}');\n");
    }
    final qa = _sqlite(sq, a.toString(), dir);
    final a2 = StringBuffer('PRAGMA synchronous=FULL;\n');
    for (var j = 0; j < 1000; j++) {
      a2.write("INSERT INTO t VALUES (${(1 << 42) + ids[j]}, '${esc[j]}');\n");
    }
    final qa2 = _sqlite(sq, a2.toString(), dir);
    _sqlite(sq, 'VACUUM;', dir);
    print('  sqlite3 ${random ? 'random' : 'sequential'} ids (CLI, '
        'synchronous=OFF): insert ${fmt(n / qi / 1000)}k rows/s, select by '
        'id ${fmt(qs / probes.length * 1e6, 2)} us, scan ${fmt(qc * 1000)} '
        'ms, autocommit insert ${fmt(qa * 1000)} us each '
        '(synchronous=FULL: ${fmt(qa2 * 1000)} us), file '
        '${File(sq).lengthSync() >> 10} KiB');
  }
}

const _words = [
  'the', 'archive', 'holds', 'files', 'and', 'a', 'database', 'with', 'pages',
  'compressed', 'by', 'level', 'readers', 'see', 'every', 'generation', 'of',
  'data', 'written', 'in', 'order', 'to', 'keep', 'history', 'small', 'fast',
  'records', 'values', 'keys', 'time', 'user', 'report', 'network', 'error',
];

String _text(Random r) {
  final n = 20 + r.nextInt(60);
  final sb = StringBuffer();
  for (var i = 0; i < n; i++) {
    if (i > 0) sb.write(r.nextInt(12) == 0 ? '. ' : ' ');
    sb.write(_words[r.nextInt(_words.length)]);
  }
  return sb.toString();
}

// file sizes per compression level on three datasets (SQL tables), with
// cold (caches dropped) and hot point read latencies per level
void _levelsBench(String dir, {required bool skipMax}) {
  const n = 20000;
  final r = Random(8);
  final sets = <String, List<List<Object>>>{
    'JSON records': [
      for (var i = 0; i < n; i++) [i, jsonValue(i, r)]
    ],
    'text rows': [
      for (var i = 0; i < n; i++) [i, _text(r)]
    ],
    'numeric rows': [
      for (var i = 0; i < n; i++)
        [
          i,
          1790000000 + i * 60 + r.nextInt(5),
          r.nextInt(1000),
          (r.nextDouble() * 1000).roundToDouble() / 10,
          r.nextInt(3) - 1
        ]
    ],
  };
  final opts = ZxDbStoreOptions(durable: false, autoFoldBytes: 0);
  for (final e in sets.entries) {
    final rows = e.value;
    final cols = rows.first.length;
    final colDefs = [
      'id INTEGER PRIMARY KEY',
      for (var c = 1; c < cols; c++)
        rows.first[c] is String ? 'c$c TEXT' : 'c$c ${rows.first[c] is double ? 'REAL' : 'INTEGER'}'
    ].join(', ');
    var raw = 0;
    for (final row in rows) {
      for (final v in row) {
        raw += v.toString().length + 1;
      }
    }
    print('Sizes, ${e.key}: $n rows, ${fmt(raw / 1024)} KiB as text');
    if (_hasSqlite()) {
      final sq = '$dir/lv.sqlite';
      _rm(sq);
      final w = StringBuffer('CREATE TABLE t ($colDefs);BEGIN;\n');
      for (final row in rows) {
        w.write('INSERT INTO t VALUES (${[
          for (final v in row) v is String ? "'${v.replaceAll("'", "''")}'" : '$v'
        ].join(',')});\n');
      }
      w.write('COMMIT;VACUUM;\n');
      _sqlite(sq, w.toString(), dir);
      print('  sqlite3: ${fmt(File(sq).lengthSync() / 1024)} KiB');
    }
    for (final level in ['store', 'fast', 'balanced', if (!skipMax) 'max']) {
      final path = '$dir/lv-$level.zx';
      _rm(path);
      final db = ZxDatabase.open(path, create: true, options: opts);
      final sql = db.sql;
      sql.execute("CREATE TABLE t ($colDefs) WITH (compression = '$level')");
      final ins = sql.prepare(
          'INSERT INTO t VALUES (${List.filled(cols, '?').join(', ')})');
      final sw = Stopwatch()..start();
      sql.execute('BEGIN');
      for (final row in rows) {
        ins.execute(row);
      }
      sql.execute('COMMIT');
      db.fold();
      db.vacuum();
      final sb = sw.elapsedMicroseconds / 1e6;
      final size = File(path).lengthSync();
      db.close();
      // reads: cold (a fresh store, empty caches), then hot
      final db2 = ZxDatabase.open(path, options: opts);
      final sel = db2.sql.prepare('SELECT * FROM t WHERE id = ?');
      final rr = Random(9);
      sw.reset();
      sel.select([rr.nextInt(n)]);
      final cold = sw.elapsedMicroseconds;
      for (var i = 0; i < n; i++) {
        sel.select([i]);
      }
      sw.reset();
      for (var i = 0; i < 20000; i++) {
        sel.select([rr.nextInt(n)]);
      }
      final hot = sw.elapsedMicroseconds / 20000;
      db2.close();
      print('  zxdb $level: ${fmt(size / 1024)} KiB (${fmt(raw / size, 1)}x) '
          'in ${fmt(sb, 1)} s; first read cold ${fmt(cold / 1000, 1)} ms, '
          'hot ${fmt(hot, 1)} us');
    }
  }
}
