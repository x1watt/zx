// cpio archives written by GNU cpio (newc, crc, odc, bin; skipped when
// cpio is missing), a big endian binary archive made from the little
// endian one, and hand made archives (devices, a bad checksum, garbage
// before a header). Listings are compared with `cpio -t`, extracted trees
// with the source tree.

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/format/archive_types.dart';
import 'package:zx/src/format/cpio/cpio_handler.dart';
import 'package:zx/zx.dart';

import 'codec_test_util.dart';

String _hex8(int v) => v.toRadixString(16).padLeft(8, '0');

/// One newc entry (070701, or 070702 with [check]).
List<int> newcEntry(String name, int mode, List<int> data,
    {int ino = 1, int nlink = 1, int rmaj = 0, int rmin = 0, int? check}) {
  final nameBytes = [...name.codeUnits, 0];
  final h = StringBuffer(check == null ? '070701' : '070702')
    ..write(_hex8(ino))
    ..write(_hex8(mode))
    ..write(_hex8(1000))
    ..write(_hex8(100))
    ..write(_hex8(nlink))
    ..write(_hex8(1700000000))
    ..write(_hex8(data.length))
    ..write(_hex8(8))
    ..write(_hex8(1))
    ..write(_hex8(rmaj))
    ..write(_hex8(rmin))
    ..write(_hex8(nameBytes.length))
    ..write(_hex8(check ?? 0));
  final out = <int>[...h.toString().codeUnits, ...nameBytes];
  while (out.length % 4 != 0) {
    out.add(0);
  }
  out.addAll(data);
  while (out.length % 4 != 0) {
    out.add(0);
  }
  return out;
}

Uint8List newcArchive(List<List<int>> entries, {bool crc = false}) {
  final out = <int>[];
  for (final e in entries) {
    out.addAll(e);
  }
  out.addAll(newcEntry('TRAILER!!!', 0, [], ino: 0, check: crc ? 0 : null));
  while (out.length % 512 != 0) {
    out.add(0);
  }
  return Uint8List.fromList(out);
}

// byte swaps the 16-bit header fields of a binary archive (LE to BE)
Uint8List swapBin(Uint8List le) {
  final b = Uint8List.fromList(le);
  var p = 0;
  while (p + 26 <= b.length) {
    final magic = b[p] | (b[p + 1] << 8);
    if (magic != 0x71C7) break;
    for (var k = 0; k < 26; k += 2) {
      final t = b[p + k];
      b[p + k] = b[p + k + 1];
      b[p + k + 1] = t;
    }
    final nameSize = (b[p + 20] << 8) | b[p + 21];
    final size =
        (((b[p + 22] << 8) | b[p + 23]) << 16) | ((b[p + 24] << 8) | b[p + 25]);
    final name = String.fromCharCodes(b.sublist(p + 26, p + 26 + nameSize - 1));
    p += 26 + nameSize + (nameSize & 1);
    if (name == 'TRAILER!!!') break;
    p += size + (size & 1);
  }
  return b;
}

void main() {
  final cpio = findTool('cpio');
  late Directory tmp;
  late String src;

  setUpAll(() {
    tmp = tempDir('cpio');
    src = '${tmp.path}/src';
    Directory('$src/d/sub').createSync(recursive: true);
    File('$src/a.txt').writeAsStringSync('hello cpio\n');
    File('$src/d/odd.bin').writeAsBytesSync(genData(12345, 3));
    File('$src/d/sub/empty').writeAsBytesSync([]);
    File('$src/d/${'long' * 40}.txt').writeAsStringSync('long name');
    Link('$src/d/sym').createSync('../a.txt');
    Process.runSync('ln', ['$src/a.txt', '$src/d/hard']);
  });
  tearDownAll(() => tmp.deleteSync(recursive: true));

  for (final fmt in ['newc', 'crc', 'odc', 'bin']) {
    test('GNU cpio -H $fmt', () async {
      final arc = '${tmp.path}/t.$fmt';
      final r = await Process.run('sh', [
        '-c',
        'cd "$src" && find . | LC_ALL=C sort | "$cpio" -o -H $fmt > "$arc"'
      ]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      final listed = (Process.runSync('sh', ['-c', '"$cpio" -t < "$arc"'])
              .stdout as String)
          .split('\n')
          .where((s) => s.isNotEmpty)
          .toList();

      final data = File(arc).readAsBytesSync();
      final variants = {fmt: data, if (fmt == 'bin') 'binBE': swapBin(data)};
      for (final v in variants.entries) {
        final h = CpioHandler();
        expect(h.open(MemoryInStream(v.value)), isTrue, reason: v.key);
        expect([for (final it in h.items) it.name], listed, reason: v.key);
        expect(h.getArchiveProperty(Kpid.errorFlags), 0);
        expect(h.getArchiveProperty(Kpid.phySize), v.value.length);
        if (v.key == 'binBE') {
          expect(h.format, CpioFormat.binBE);
        }
        final i = h.items.indexWhere((e) => e.name == 'd/sym');
        expect(h.getProperty(i, Kpid.symLink), '../a.txt');
        final names = {for (final it in h.items) it.name};
        expect(names, containsAll(['a.txt', 'd/hard']));
        final links = [
          for (final it in h.items)
            if (it.hardLink != null) (it.name, it.hardLink)
        ];
        expect(links.length, 1);
      }

      // extraction through the API, with a wrong extension
      final renamed = '${tmp.path}/t_$fmt.zip';
      File(arc).copySync(renamed);
      final z = await ZxArchive.open(renamed);
      expect(z.format, 'Cpio');
      expect((await z.test()).ok, isTrue);
      final out = '${tmp.path}/out_$fmt';
      final res = await z.extract(out);
      expect(res.errors, isEmpty);
      final diff =
          Process.runSync('diff', ['-r', '--no-dereference', src, out]);
      expect(diff.exitCode, 0, reason: '${diff.stdout}');
      expect(Link('$out/d/sym').targetSync(), '../a.txt');
      expect(File('$out/d/hard').readAsStringSync(), 'hello cpio\n');
    }, skip: cpio == null ? 'cpio missing' : false);
  }

  test('devices, a checksum error and garbage before a header', () {
    final payload = [1, 2, 3, 4, 5];
    var sum = 0;
    for (final b in payload) {
      sum += b;
    }
    final good = newcArchive([
      newcEntry('dev', 0x41ED, [], ino: 2, nlink: 2),
      newcEntry('dev/tty0', 0x2190, [], ino: 3, rmaj: 4, rmin: 0, check: 0),
      newcEntry('dev/sda', 0x61B0, [], ino: 4, rmaj: 8, rmin: 1, check: 0),
      newcEntry('f', 0x81A4, payload, ino: 5, check: sum),
    ], crc: true);
    final h = CpioHandler();
    expect(h.open(MemoryInStream(good)), isTrue);
    expect(h.format, CpioFormat.crc);
    expect(h.numberOfItems, 4);
    expect(h.getProperty(0, Kpid.isDir), isTrue);
    expect(h.getProperty(1, Kpid.deviceMajor), 4);
    expect(h.getProperty(2, Kpid.deviceMajor), 8);
    expect(h.getProperty(2, Kpid.deviceMinor), 1);
    expect(h.getProperty(2, Kpid.posixAttrib), 0x61B0);
    expect(h.getProperty(3, Kpid.userId), 1000);
    expect(h.getProperty(3, Kpid.mTime),
        1700000000 * 10000000 + 116444736000000000);
    final cb = _Collect();
    h.extract([3], false, cb);
    expect(cb.results, [OperationResult.ok]);
    expect(cb.out.toBytes(), payload);

    final bad = newcArchive([
      newcEntry('f', 0x81A4, payload, ino: 5, check: sum + 1),
    ], crc: true);
    expect(h.open(MemoryInStream(bad)), isTrue);
    final cb2 = _Collect();
    h.extract(null, true, cb2);
    expect(cb2.results, [OperationResult.crcError]);

    final withGarbage = Uint8List.fromList([
      ...newcEntry('a', 0x81A4, [65]),
      ...List.filled(37, 0x55),
      ...newcArchive([
        newcEntry('b', 0x81A4, [66])
      ]),
    ]);
    expect(h.open(MemoryInStream(withGarbage)), isTrue);
    expect([for (final it in h.items) it.name], ['a', 'b']);
    expect(h.getArchiveProperty(Kpid.warningFlags), ErrorFlags.headersError);

    final truncated = Uint8List.sublistView(good, 0, 200);
    expect(h.open(MemoryInStream(truncated)), isTrue);
    expect(h.getArchiveProperty(Kpid.errorFlags), ErrorFlags.unexpectedEnd);
  });

  test('gzip compressed cpio opens as gzip with the cpio inside', () async {
    final arc = newcArchive([newcEntry('x', 0x81A4, 'hi'.codeUnits)]);
    final p = '${tmp.path}/initramfs.cpio';
    File(p).writeAsBytesSync(arc);
    Process.runSync(findTool('gzip')!, ['-9', p]);
    final z = await ZxArchive.open('$p.gz');
    expect(z.format, 'gzip');
    expect(z.items.single.path, 'initramfs.cpio');
    expect(await z.readBytes(z.items.single), arc);
  }, skip: findTool('gzip') == null ? 'gzip missing' : false);
}

class _Collect extends ArchiveExtractCallback {
  final MemoryOutStream out = MemoryOutStream();
  final List<int> results = [];
  @override
  OutStream? getStream(int index, int askMode) => out;
  @override
  void setOperationResult(int opRes) => results.add(opRes);
}
