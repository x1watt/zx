// Tests of the time series through ZxDatabaseAsync (a worker isolate):
// packed appends, streamed scans with backpressure, seal and stats, and
// KV watch with group commits.

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/db/zxdb.dart';
import 'package:zx/src/db/zxdb_async.dart';

ZxDbStoreOptions opts() => ZxDbStoreOptions(
    pageSize: 4096,
    autoFoldBytes: 0,
    durable: false,
    refreshMicros: 0,
    threads: 1);

const int sec = 1000000000;
const int t0 = 1790000000 * sec;

Uint8List b(String s) => Uint8List.fromList(s.codeUnits);

void main() {
  late Directory dir;
  var n = 0;
  setUp(() => dir = Directory.systemTemp.createTempSync('zxdb_ts_async'));
  tearDown(() => dir.deleteSync(recursive: true));
  String newPath() => '${dir.path}/db${n++}.zx';

  test('packing keeps values and types', () {
    final rows = <List<Object?>>[
      [
        1,
        1.5,
        'a',
        null,
        3,
        Uint8List.fromList([1, 2])
      ],
      [2, null, '', null, 'x', null],
      [3, 2.25, null, null, 4.0, 'y'],
      [-(1 << 63), -0.0, 'long text\nwith a newline', null, null, 7],
    ];
    final p = zxTsPackRowsForTest(rows, 6);
    expect(zxTsUnpackRowsForTest(p), rows);
    // big columns go as TransferableTypedData
    final big = [
      for (var i = 0; i < 20000; i++) [t0 + i, i * 0.5, 'm$i']
    ];
    final pb = zxTsPackRowsForTest(big, 3);
    expect(((pb[1] as List)[1]), isA<TransferableTypedData>());
    expect(zxTsUnpackRowsForTest(pb), big);
  });

  test('series through the worker', () async {
    final db =
        await ZxDatabaseAsync.open(newPath(), create: true, options: opts());
    final s = await db.createSeries(
        'logs',
        const [
          ZxTsColumn('ts', 'DATETIME'),
          ZxTsColumn('host', 'TEXT'),
          ZxTsColumn('lat', 'REAL'),
          ZxTsColumn('n', 'INTEGER'),
          ZxTsColumn('msg', 'TEXT'),
        ],
        tags: ['host'],
        segmentRows: 1000);
    expect(await db.seriesNames(), ['logs']);
    final want = <List<Object?>>[];
    for (var i = 0; i < 5000; i++) {
      want.add([
        t0 + i * sec,
        'h${i % 3}',
        i % 7 == 0 ? null : i / 4,
        i,
        'message $i'
      ]);
    }
    await s.appendAll(want.sublist(0, 3000));
    // Maps and DateTime values
    await s.appendAll([
      for (final r in want.sublist(3000))
        {
          'ts': DateTime.fromMicrosecondsSinceEpoch((r[0] as int) ~/ 1000,
              isUtc: true),
          'host': r[1],
          'lat': r[2],
          'n': r[3],
          'msg': r[4],
        }
    ]);
    var st = await s.stats();
    expect(st.buffered, 5000);
    expect(await s.query(), want);
    final sr = await s.seal(threads: 1);
    expect(sr.rows, 5000);
    st = await s.stats();
    expect(st.buffered, 0);
    expect(st.rows, 5000);
    expect(st.segments, greaterThanOrEqualTo(5));
    expect(await s.query(), want);
    expect(
        await s.query(
            from: t0 + 10 * sec,
            to: DateTime.fromMicrosecondsSinceEpoch((t0 + 20 * sec) ~/ 1000,
                isUtc: true),
            columns: ['n', 'host'],
            where: {'host': 'h1'}),
        [
          for (var i = 10; i < 20; i++)
            if (i % 3 == 1) [i, 'h1']
        ]);
    expect(await s.query(descending: true, limit: 3, columns: ['n']), [
      [4999],
      [4998],
      [4997]
    ]);

    // Backpressure: while paused, no further batch is read.
    final got = <int>[];
    final done = Completer<void>();
    late StreamSubscription<List<List<Object?>>> sub;
    sub = s.scanBatches(columns: ['n'], batchRows: 100).listen((batch) {
      got.add(batch.length);
      if (got.length == 2) {
        sub.pause();
        Future<void>.delayed(const Duration(milliseconds: 100), () {
          expect(got.length, 2);
          sub.resume();
        });
      }
    }, onDone: done.complete);
    await done.future;
    expect(got.length, 50);
    expect(got.every((x) => x == 100), true);

    // Cancel ends the scan early; the worker keeps working.
    var batches = 0;
    await for (final _ in s.scanBatches(batchRows: 10)) {
      if (++batches == 3) break;
    }
    expect(batches, 3);
    expect((await s.stats()).rows, 5000);

    // SQL sees the same series
    expect(await db.select('SELECT count(*) FROM logs'), [
      [5000]
    ]);
    // result column types cross the isolate boundary
    final tr = await db.execute(
        "SELECT ts, count(*) FROM logs WHERE ts >= '1970-01-01' GROUP BY 1 LIMIT 1");
    expect(tr.isDatetime(0), isTrue);
    expect(tr.isDatetime(1), isFalse);
    expect(() => db.series('none').stats(), throwsA(isA<ZxDbException>()));
    await db.dropSeries('logs');
    expect(await db.seriesNames(), isEmpty);
    await db.close();
  });

  test('KV watch through the async API (group commit)', () async {
    final db = await ZxDatabaseAsync.open(newPath(),
        create: true,
        options: opts(),
        groupCommit: const Duration(milliseconds: 20));
    final kv = await db.createKvStore('a');
    final other = await db.createKvStore('b');
    final got = <ZxKvChange>[];
    final all = <ZxKvChange>[];
    final s1 = kv.watch(prefix: b('p/')).listen(got.add);
    final s2 = db.watch('b').listen(all.add);
    await kv.put(b('p/1'), b('x'));
    await kv.put(b('q/1'), b('y'));
    await other.put(b('z'), b('w'));
    await kv.delete(b('p/1'));
    await db.flush();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect([
      for (final c in got)
        [
          String.fromCharCodes(c.key),
          c.value == null ? null : String.fromCharCodes(c.value!)
        ]
    ], [
      ['p/1', 'x'],
      ['p/1', null],
    ]);
    expect(got.every((c) => c.generation > 0), true);
    expect(all.length, 1);
    expect(all.single.store, 'b');
    await s1.cancel();
    await s2.cancel();
    await db.close();
  });
}
