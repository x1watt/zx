import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/format/archive_types.dart';
import 'package:zx/src/format/split.dart';
import 'package:zx/src/io/streams.dart';

Uint8List gen(int n, int seed) {
  var st = seed;
  final b = Uint8List(n);
  for (var i = 0; i < n; i++) {
    st = (st * 1103515245 + 12345) & 0x7fffffff;
    b[i] = (st >> 16) & 0xff;
  }
  return b;
}

final bool have7z = File('/usr/bin/7z').existsSync();

List<String> volumeNames(Directory d) =>
    d.listSync().map((e) => e.uri.pathSegments.last).toList()..sort();

class _Collect extends ArchiveExtractCallback {
  final out = MemoryOutStream();
  int result = -1;
  @override
  OutStream? getStream(int index, int askMode) => out;
  @override
  void setOperationResult(int opRes) => result = opRes;
}

void main() {
  late Directory tmp;
  final data = gen(250000, 5);

  setUp(() => tmp = Directory.systemTemp.createTempSync('zx_split_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('MultiInStream', () {
    test('reads and seeks across parts', () {
      final parts = [
        (MemoryInStream(data.sublist(0, 1000)), 1000),
        (MemoryInStream(data.sublist(1000, 1000)), 0),
        (MemoryInStream(data.sublist(1000, 50000)), 49000),
        (MemoryInStream(data.sublist(50000)), data.length - 50000),
      ];
      final m = MultiInStream(parts);
      expect(m.length, data.length);
      expect(readAll(m), data);
      final buf = Uint8List(3000);
      for (final pos in [48000, 0, 999, 200000]) {
        m.position = pos;
        final n = readFully(m, buf, 0, buf.length);
        expect(buf.sublist(0, n), data.sublist(pos, pos + n));
      }
    });
  });

  group('SplitHandler', () {
    test('numbered volumes', () {
      for (var i = 0; i < 3; i++) {
        File('${tmp.path}/f.bin.00${i + 1}')
            .writeAsBytesSync(data.sublist(i * 100000,
                i == 2 ? data.length : (i + 1) * 100000));
      }
      final h = SplitHandler();
      expect(h.openFiles('${tmp.path}/f.bin.001'), isTrue);
      expect(h.numVolumes, 3);
      expect(h.getProperty(0, Kpid.path), 'f.bin');
      expect(h.getProperty(0, Kpid.size), data.length);
      expect(h.getArchiveProperty(Kpid.phySize), 100000);
      final cb = _Collect();
      h.extract(null, false, cb);
      expect(cb.result, OperationResult.ok);
      expect(cb.out.toBytes(), data);
      final m = h.getStream(0);
      expect(readAll(m), data);
      m.close();
    });

    test('split style names (aa, ab ...)', () {
      File('${tmp.path}/x.aa').writeAsBytesSync(data.sublist(0, 7));
      File('${tmp.path}/x.ab').writeAsBytesSync(data.sublist(7, 20));
      final m = MultiInStream.openFiles('${tmp.path}/x.aa')!;
      expect(readAll(m), data.sublist(0, 20));
      m.close();
      // one "aa" volume is not a split archive
      File('${tmp.path}/y.aa').writeAsBytesSync(data.sublist(0, 7));
      expect(MultiInStream.openFiles('${tmp.path}/y.aa'), isNull);
      // not a volume name
      File('${tmp.path}/z.bin').writeAsBytesSync(data.sublist(0, 7));
      expect(MultiInStream.openFiles('${tmp.path}/z.bin'), isNull);
    });
  });

  group('MultiOutStream', () {
    test('volumes of the given sizes, last size repeats', () {
      final m = MultiOutStream('${tmp.path}/v.7z.', [30000, 100000]);
      m.write(data, 0, data.length);
      expect(m.finalFlushAndCloseFiles(), 4);
      expect(volumeNames(tmp),
          ['v.7z.001', 'v.7z.002', 'v.7z.003', 'v.7z.004']);
      final sizes = [
        for (final n in volumeNames(tmp)) File('${tmp.path}/$n').lengthSync()
      ];
      expect(sizes, [30000, 100000, 100000, 20000]);
      final m2 = MultiInStream.openFiles('${tmp.path}/v.7z.001')!;
      expect(readAll(m2), data);
      m2.close();
    });

    test('seek back and rewrite, as archive writers do', () {
      final m = MultiOutStream('${tmp.path}/w.', [64000]);
      m.write(Uint8List(32), 0, 32); // start header placeholder
      m.write(data, 32, data.length - 32);
      m.position = 0;
      m.write(data, 0, 32);
      m.truncate(data.length); // SetSize to the same length
      expect(m.finalFlushAndCloseFiles(), 4);
      final m2 = MultiInStream.openFiles('${tmp.path}/w.001')!;
      expect(readAll(m2), data);
      m2.close();
    });

    test('restriction closes finished volumes early', () {
      final m = MultiOutStream('${tmp.path}/r.', [10000]);
      m.setRestriction(0, 0);
      m.write(data, 0, 35000);
      // volumes 1 to 3 are complete and renamed already
      expect(File('${tmp.path}/r.001').existsSync(), isTrue);
      expect(File('${tmp.path}/r.003').existsSync(), isTrue);
      expect(File('${tmp.path}/r.004.tmp').existsSync(), isTrue);
      expect(m.finalFlushAndCloseFiles(), 4);
      expect(File('${tmp.path}/r.004').lengthSync(), 5000);
    });

    test('destruct deletes the volumes', () {
      final m = MultiOutStream('${tmp.path}/d.', [10000]);
      m.write(data, 0, 25000);
      m.destruct();
      expect(tmp.listSync(), isEmpty);
    });

    test('truncate removes volumes after the end', () {
      final m = MultiOutStream('${tmp.path}/t.', [10000]);
      m.write(data, 0, 45000);
      m.truncate(15000);
      expect(m.finalFlushAndCloseFiles(), 2);
      expect(volumeNames(tmp), ['t.001', 't.002']);
      expect(File('${tmp.path}/t.002').lengthSync(), 5000);
    });
  });

  group('7-Zip interop', skip: have7z ? false : 'no /usr/bin/7z', () {
    test('7z a -v100k volumes read as one stream', () {
      final input = File('${tmp.path}/in.bin')..writeAsBytesSync(data);
      final r = Process.runSync('/usr/bin/7z',
          ['a', '-v100k', '-mx=0', '${tmp.path}/a.7z', input.path]);
      expect(r.exitCode, 0, reason: '${r.stdout}');
      final names = volumeNames(tmp).where((n) => n.startsWith('a.7z.'));
      expect(names.length, greaterThan(1));
      final whole = BytesBuilder();
      for (final n in names) {
        whole.add(File('${tmp.path}/$n').readAsBytesSync());
      }
      final m = MultiInStream.openFiles('${tmp.path}/a.7z.001')!;
      expect(readAll(m), whole.toBytes());
      m.close();
    });

    test('7z reads volumes written by MultiOutStream', () {
      final input = File('${tmp.path}/in.bin')..writeAsBytesSync(data);
      final arc = '${tmp.path}/b.7z';
      final r = Process.runSync('/usr/bin/7z', ['a', '-mx=0', arc, input.path]);
      expect(r.exitCode, 0);
      final bytes = File(arc).readAsBytesSync();
      final m = MultiOutStream('$arc.', [60000]);
      m.write(bytes, 0, bytes.length);
      m.finalFlushAndCloseFiles();
      File(arc).deleteSync();
      final t = Process.runSync('/usr/bin/7z', ['t', '$arc.001']);
      expect(t.stdout as String, contains('Everything is Ok'));
    });
  });
}
