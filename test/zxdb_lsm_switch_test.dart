// A tree that starts small in a write transaction and then takes many
// random writes moves to the delta layer within that transaction
// (_TxnTree._maybeSwitchToLsm); reads, scans, the commit and a reopen
// must not notice.
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/db/engine/store.dart';
import 'package:zx/src/db/storage_api.dart';

Uint8List k(int i) =>
    Uint8List.fromList('key${i.toString().padLeft(7, '0')}'.codeUnits);
Uint8List v(int i, int gen) => Uint8List.fromList('v$i/$gen'.codeUnits);

ZxDbStoreOptions opts() => ZxDbStoreOptions(
    pageSize: 4096,
    compression: 'fast',
    durable: false,
    refreshMicros: 0,
    threads: 1)
  ..lsmMinEntries = 2000
  ..lsmMemBytes = 20000
  ..txnMemoryBytes = 200000;

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('zx_lsm_switch'));
  tearDown(() => tmp.deleteSync(recursive: true));

  void same(ZxTree t, Map<int, int> want) {
    for (final e in want.entries) {
      expect(t.get(k(e.key)), v(e.key, e.value), reason: 'key ${e.key}');
    }
    final c = t.scan();
    final seen = <String>[];
    while (c.moveNext()) {
      seen.add(String.fromCharCodes(c.key));
    }
    c.close();
    expect(seen, [
      for (final i in want.keys.toList()..sort()) String.fromCharCodes(k(i))
    ]);
  }

  test('random writes in one big transaction', () {
    final path = '${tmp.path}/a.zx';
    final st = ZxDbStore.open(path, create: true, options: opts());
    final want = <int, int>{};
    final r = Random(5);
    final t = st.begin();
    final tree = t.createTree('t');
    for (var i = 0; i < 30000; i++) {
      final key = r.nextInt(40000);
      tree.put(k(key), v(key, i));
      want[key] = i;
      if (i % 7 == 0) {
        final d = r.nextInt(40000);
        expect(tree.delete(k(d)), want.remove(d) != null);
      }
      if (i == 15000) same(tree, want); // after the switch, mid transaction
    }
    same(tree, want);
    t.commit();
    same(st.snapshot().tree('t')!, want);
    st.close();
    final again = ZxDbStore.open(path, options: opts());
    same(again.snapshot().tree('t')!, want);
    again.close();
  });

  test('an open cursor keeps the tree direct; sorted loads stay direct', () {
    final st =
        ZxDbStore.open('${tmp.path}/b.zx', create: true, options: opts());
    final t = st.begin();
    final tree = t.createTree('t');
    for (var i = 0; i < 5000; i++) {
      tree.put(k(i * 2), v(i * 2, 0));
    }
    // A scan that writes as it goes (an UPDATE): it sees its own writes
    // after its position, as the contract says, with or without a switch.
    final c = tree.scan();
    var n = 0;
    final r = Random(9);
    while (c.moveNext()) {
      n++;
      final odd = r.nextInt(10000) | 1;
      tree.put(k(odd), v(odd, 1));
    }
    c.close();
    expect(n, greaterThan(5000));
    t.commit();
    expect(st.snapshot().tree('t')!.scan().moveNext(), isTrue);
    st.close();
  });
}
