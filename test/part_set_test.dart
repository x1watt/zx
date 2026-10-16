// Part sets (lib/src/io/part_set.dart, docs/architecture.md section 21):
// one file cut into parts with a manifest, read as one stream natively and
// over HTTP ranges (lib/src/web/url_parts.dart, with a fake transport),
// including a zxdb database queried across its parts.

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/cli/main.dart' show runSevenZipCliSync;
import 'package:zx/src/cli/std_stream.dart' show CliIo;
import 'package:zx/src/db/warm_set.dart';
import 'package:zx/src/db/zxdb.dart';
import 'package:zx/src/io/part_set.dart';
import 'package:zx/src/io/streams.dart';
import 'package:zx/src/web/range_stream.dart';
import 'package:zx/src/web/url_parts.dart';

class _Mem implements ClosableInStream {
  final Uint8List data;
  bool closed = false;
  @override
  int position = 0;
  _Mem(this.data);
  @override
  int get length => data.length;
  @override
  int read(Uint8List buf, int off, int len) {
    final n = min(len, data.length - position);
    if (n <= 0) return 0;
    buf.setRange(off, off + n, data, position);
    position += n;
    return n;
  }

  @override
  void close() => closed = true;
}

/// Serves byte ranges of the files at its URLs.
class _Server {
  final Map<String, Uint8List> files = {};
  final List<String> asked = [];
  RangeTransport transport(String url) => _Transport(this, url);
}

class _Transport implements RangeTransport {
  final _Server server;
  final String url;
  _Transport(this.server, this.url);
  @override
  RangeResponse fetch(int start, int endInclusive) {
    server.asked.add(url);
    final d = server.files[url]!;
    final end = min(endInclusive + 1, d.length);
    return RangeResponse(206, Uint8List.sublistView(d, start, end),
        contentRange: 'bytes $start-${end - 1}/${d.length}');
  }
}

class _Files implements HostFiles {
  final Map<String, ClosableInStream> s = {};
  @override
  int? sizeOf(String path) => s[path]?.length;
  @override
  ClosableInStream open(String path) => s[path]!;
}

Uint8List _bytes(int n, int seed) {
  final r = Random(seed);
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

Uint8List _readAll(ClosableInStream s, {int chunk = 777}) {
  final out = BytesBuilder();
  final buf = Uint8List(chunk);
  s.position = 0;
  int n;
  while ((n = s.read(buf, 0, chunk)) > 0) {
    out.add(Uint8List.sublistView(buf, 0, n));
  }
  return out.takeBytes();
}

ZxDbStoreOptions _opts() => ZxDbStoreOptions(
    pageSize: 4096,
    autoFoldBytes: 0,
    durable: false,
    refreshMicros: 0,
    threads: 1);

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('zx_parts_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('reads across part boundaries, opening few parts at a time', () {
    final data = _bytes(10000, 1);
    const p = 1000;
    final parts = [
      for (var i = 0; i < 10; i++)
        Uint8List.sublistView(data, i * p, (i + 1) * p)
    ];
    final m = ZxPartManifest('x', data.length, p,
        [for (var i = 0; i < 10; i++) ZxPart('x.${i + 1}', p)]);
    final opened = <_Mem>[];
    final s = PartSetInStream(m, (i) {
      final x = _Mem(parts[i]);
      opened.add(x);
      return x;
    }, maxOpen: 2);
    expect(_readAll(s), data);
    // random reads that straddle boundaries
    final r = Random(2);
    final buf = Uint8List(2500);
    for (var k = 0; k < 200; k++) {
      final at = r.nextInt(data.length);
      s.position = at;
      var got = 0;
      while (got < buf.length) {
        final n = s.read(buf, got, buf.length - got);
        if (n == 0) break;
        got += n;
      }
      expect(Uint8List.sublistView(buf, 0, got),
          Uint8List.sublistView(data, at, min(at + 2500, data.length)));
    }
    expect(s.opens, greaterThan(10)); // parts closed and opened again
    s.close();
    expect(opened.every((m) => m.closed), isTrue);
  });

  test('the manifest is checked: sizes, versions, fields', () {
    expect(
        () => ZxPartManifest(
            'x', 25, 10, const [ZxPart('a', 10), ZxPart('b', 10)]),
        throwsA(isA<SevenZipException>()));
    expect(
        () => ZxPartManifest(
            'x', 20, 10, const [ZxPart('a', 9), ZxPart('b', 11)]),
        throwsA(isA<SevenZipException>()));
    expect(() => ZxPartManifest.parse('{"zxParts": 9, "name": "x"}'),
        throwsA(isA<SevenZipException>()));
    expect(() => ZxPartManifest.parse('{"zxParts": 1}'),
        throwsA(isA<SevenZipException>()));
    final m = ZxPartManifest(
        'x', 15, 10, const [ZxPart('a', 10, 'ff'), ZxPart('b', 5)]);
    final back = ZxPartManifest.parse(m.toJsonText());
    expect(back.parts.map((p) => (p.file, p.size, p.sha256)),
        [('a', 10, 'ff'), ('b', 5, null)]);
  });

  test('split, check, join; a damaged part is reported', () {
    final data = _bytes(5000, 3);
    final f = File('${tmp.path}/big.bin')..writeAsBytesSync(data);
    final m = zxSplitFile(f.path, 1024);
    expect(m.parts.map((p) => p.file).toList(), [
      'big.bin.001',
      'big.bin.002',
      'big.bin.003',
      'big.bin.004',
      'big.bin.005'
    ]);
    expect(m.parts.last.size, 5000 - 4 * 1024);
    final manifest = '${tmp.path}/big.bin.parts';
    expect(zxCheckParts(manifest), isEmpty);
    zxJoinParts(manifest, '${tmp.path}/back.bin');
    expect(File('${tmp.path}/back.bin').readAsBytesSync(), data);
    // the original gone: openInputFile reads the set in its place
    f.deleteSync();
    final s = openInputFile(f.path);
    expect(s, isA<PartSetInStream>());
    expect(_readAll(s), data);
    s.close();
    final p3 = File('${tmp.path}/big.bin.003');
    final bad = p3.readAsBytesSync()..[10] ^= 1;
    p3.writeAsBytesSync(bad);
    expect(zxCheckParts(manifest), ['big.bin.003: SHA-256 does not match']);
    p3.writeAsBytesSync(bad.sublist(0, 100));
    expect(zxCheckParts(manifest),
        ['big.bin.003: 100 bytes, the manifest says 1024']);
  });

  ZxDatabase makeDb(String path) {
    final db = ZxDatabase.open(path, create: true, options: _opts());
    db.sql.execute(
        'CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT, n INTEGER)');
    db.sql.execute('CREATE INDEX t_name ON t (name)');
    db.sql.execute('BEGIN');
    for (var i = 0; i < 3000; i++) {
      db.sql.execute(
          'INSERT INTO t VALUES (?, ?, ?)', [i, 'name $i', i * 7 % 101]);
    }
    db.sql.execute('COMMIT');
    db.fold();
    return db;
  }

  List<List<Object?>> queries(ZxDatabase db) => [
        db.sql.execute('SELECT count(*), sum(n) FROM t').rows.first,
        db.sql.execute("SELECT id FROM t WHERE name = 'name 2718'").rows.first,
        db.sql.execute('SELECT name FROM t WHERE id = 1234').rows.first,
      ];

  test('a database in parts answers the same queries, read only', () {
    final path = '${tmp.path}/db.zx';
    final db = makeDb(path);
    final want = queries(db);
    db.close();
    final size = File(path).lengthSync();
    final m = zxSplitFile(path, 16 << 10);
    expect(m.parts.length, (size + (16 << 10) - 1) ~/ (16 << 10));
    expect(m.parts.length, greaterThan(3));
    File(path).deleteSync();
    final ro = ZxDatabase.open(path, readOnly: true, options: _opts());
    expect(queries(ro), want);
    ro.close();
    expect(
        () => ZxDatabase.open(path, options: _opts()),
        throwsA(isA<ZxDbException>()
            .having((e) => e.kind, 'kind', ZxDbError.readOnly)));
    // the CLI reads the set too
    final out = BytesBuilder();
    final io = CliIo(writeOut: out.add, writeErr: out.add);
    expect(runSevenZipCliSync(['parts', 'check', '$path.parts'], io), 0);
    expect(String.fromCharCodes(out.takeBytes()), contains('Everything is Ok'));
    expect(
        runSevenZipCliSync(
            ['sql', '-readonly', path, 'SELECT count(*) FROM t'], io),
        0);
    expect(String.fromCharCodes(out.takeBytes()), contains('3000'));
  });

  test('a database in parts over HTTP ranges, parts on two sites', () {
    final path = '${tmp.path}/web.zx';
    final db = makeDb(path);
    final want = queries(db);
    db.close();
    final m0 = zxSplitFile(path, 8 << 10);
    // parts 1..k on site A next to the manifest, the rest on site B
    final server = _Server();
    final half = m0.parts.length ~/ 2;
    final parts = [
      for (var i = 0; i < m0.parts.length; i++)
        ZxPart(i < half ? m0.parts[i].file : '../site-b/${m0.parts[i].file}',
            m0.parts[i].size)
    ];
    final m = ZxPartManifest(m0.name, m0.size, m0.partSize, parts);
    const manifestUrl = 'https://example.org/site-a/web.zx.parts';
    for (var i = 0; i < parts.length; i++) {
      final url = Uri.parse(manifestUrl).resolve(parts[i].file).toString();
      server.files[url] =
          File('${tmp.path}/${m0.parts[i].file}').readAsBytesSync();
    }
    expect(partUrls(m, manifestUrl).last,
        startsWith('https://example.org/site-b/web.zx.'));
    final made = <HttpRangeInStream>[];
    final files = _Files()
      ..s['/url/1/web.zx'] =
          urlPartSet(m, manifestUrl, server.transport, created: made.add);
    final saved = hostFiles;
    hostFiles = files;
    try {
      final remote =
          ZxDatabase.open('/url/1/web.zx', readOnly: true, options: _opts());
      expect(queries(remote), want);
      remote.close();
    } finally {
      hostFiles = saved;
    }
    final fetched = made.fold(0, (a, s) => a + s.bytesFetched);
    expect(made, isNotEmpty);
    expect(server.asked.toSet().any((u) => u.contains('site-b')), isTrue);
    // only part of the set was read for three queries
    expect(fetched, lessThanOrEqualTo(m.size));
  });

  test('the warm set: in the manifest, split at part boundaries', () {
    final m = ZxPartManifest(
        'x', 25, 10, const [ZxPart('a', 10), ZxPart('b', 10), ZxPart('c', 5)],
        warm: const [(2, 3), (8, 14)]);
    expect(m.warmRequests(), [(0, 2, 3), (0, 8, 2), (1, 0, 10), (2, 0, 2)]);
    expect(ZxPartManifest.parse(m.toJsonText()).warm, m.warm);
    expect(m.warmBytes, 17);
    expect(
        () => m.withWarm(const [(20, 9)]), throwsA(isA<SevenZipException>()));
  });

  test('a recorded warm set, prefetched, saves requests of a cold query',
      () async {
    // random names, so the pages do not compress into a few blocks
    final path = '${tmp.path}/w.zx';
    final r = Random(7);
    String name(int i) => 'n$i-'
        '${List.generate(40, (_) => r.nextInt(16).toRadixString(16)).join()}';
    final names = [for (var i = 0; i < 20000; i++) name(i)];
    final db = ZxDatabase.open(path, create: true, options: _opts());
    db.sql.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)');
    db.sql.execute('CREATE INDEX t_name ON t (name)');
    db.sql.execute('BEGIN');
    for (var i = 0; i < names.length; i++) {
      db.sql.execute('INSERT INTO t VALUES (?, ?)', [i, names[i]]);
    }
    db.sql.execute('COMMIT');
    db.fold();
    db.close();
    zxSplitFile(path, 256 << 10);
    final manifestPath = '$path.parts';
    final rep = zxRecordWarmSet(
        manifestPath,
        [
          for (final i in [5, 900, 4777, 12500, 19999])
            "SELECT id FROM t WHERE name = '${names[i]}'",
        ],
        blockSize: 4096);
    final m = rep.manifest;
    expect(m.warm, isNotEmpty);
    expect(rep.openBlocks, greaterThan(0));
    expect(rep.sharedBlocks, greaterThan(0));
    final files = <String, Uint8List>{
      for (final p in m.parts)
        'https://h/x/${p.file}': File('${tmp.path}/${p.file}').readAsBytesSync()
    };
    int syncRequests = 0;
    RangeTransport transport(String url) =>
        RedirectCachingTransport(url, (u, s, e) {
          syncRequests++;
          final d = files[u.split('?').first]!;
          final end = min(e + 1, d.length);
          return RangeResponse(206, Uint8List.sublistView(d, s, end),
              contentRange: 'bytes $s-${end - 1}/${d.length}', url: u);
        });
    Future<int> coldQuery(ZxPartManifest man, {required bool warm}) async {
      syncRequests = 0;
      final set =
          urlPartSet(man, 'https://h/x/w.zx.parts', transport, blockSize: 4096);
      if (warm) {
        await prefetchWarm(set, (url, s, e) async {
          final d = files[url.split('?').first]!;
          return (
            Uint8List.sublistView(d, s, e + 1),
            '$url?Expires=9999999999'
          );
        });
      }
      final saved = hostFiles;
      hostFiles = _Files()..s['/url/w.zx'] = set;
      try {
        final db =
            ZxDatabase.open('/url/w.zx', readOnly: true, options: _opts());
        expect(
            db.sql
                .execute("SELECT id FROM t WHERE name = '${names[8888]}'")
                .rows,
            [
              [8888]
            ]);
        db.close();
      } finally {
        hostFiles = saved;
      }
      return syncRequests;
    }

    final without = await coldQuery(m.withWarm(const []), warm: false);
    final withWarm = await coldQuery(m, warm: true);
    expect(withWarm, lessThan(without));
  });
}
