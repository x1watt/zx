// Benchmarks of zxdb (docs/zxdb-design.md section 7): KV get hot, KV put
// batched, the size of the same KV data against a SQLite file (when the
// sqlite3 tool is installed), and the persisted TLSH band index of the
// system tables with many digests.
//
//   dart compile exe tool/zxdb_bench.dart -o /tmp/zxdb_bench
//   systemd-run --user --scope -q -p MemoryMax=3G -p MemorySwapMax=0 \
//     /tmp/zxdb_bench [--dir=DIR] [--tlsh=1000000] [--skip-max]
//     [--only=kv,size,tlsh]
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
  var only = {'kv', 'size', 'tlsh'};
  for (final a in args) {
    if (a.startsWith('--only=')) only = a.substring(7).split(',').toSet();
    if (a.startsWith('--dir=')) dir = a.substring(6);
    if (a.startsWith('--tlsh=')) tlshN = int.parse(a.substring(7));
    if (a == '--skip-max') skipMax = true;
  }
  Directory(dir).createSync(recursive: true);
  print('zxdb bench in $dir');
  final opts = ZxDbStoreOptions(durable: false, autoFoldBytes: 0);

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

  // ---- sizes against SQLite
  final hasSqlite =
      Process.runSync('sh', ['-c', 'command -v sqlite3']).exitCode == 0;
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
