// MBR partitioned disk images made with sfdisk on an image file (skipped
// when sfdisk is missing): primary partitions, an extended partition with
// logical partitions, the unallocated tail, FAT and ext file systems
// written into the partitions and opened from the partition streams.
// Listings are compared with sfdisk's and 7-Zip's. Hand made tables check
// a loop in the extended boot record chain, a protective MBR and a FAT
// boot sector.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/format/disk/mbr_handler.dart';
import 'package:zx/src/format/ext/ext_handler.dart';
import 'package:zx/src/format/fat/fat_handler.dart';
import 'package:zx/zx.dart';

import 'codec_test_util.dart';

final String? _sfdisk = findTool('sfdisk');
final String? _mkfs = findTool('mkfs.vfat') ?? findTool('mkfs.fat');
final String? _mke2fs = findTool('mke2fs');

void _dd(String from, String to, int sector) {
  final r = Process.runSync('dd', [
    'if=$from',
    'of=$to',
    'bs=512',
    'seek=$sector',
    'conv=notrunc',
    'status=none'
  ]);
  if (r.exitCode != 0) throw StateError('dd: ${r.stderr}');
}

Uint8List _entry(int status, int type, int lba, int n) {
  final e = Uint8List(16);
  e[0] = status;
  e[4] = type;
  final bd = ByteData.sublistView(e);
  bd.setUint32(8, lba, Endian.little);
  bd.setUint32(12, n, Endian.little);
  return e;
}

void main() {
  late Directory tmp;

  setUpAll(() => tmp = tempDir('mbr'));
  tearDownAll(() => tmp.deleteSync(recursive: true));

  test('primary, extended and logical partitions with FAT and ext', () async {
    final disk = '${tmp.path}/disk.img';
    File(disk).openSync(mode: FileMode.write)
      ..truncateSync(48 << 20)
      ..closeSync();
    final p = await Process.start(_sfdisk!, [disk]);
    p.stdin.write('label: dos\n'
        'start=2048, size=8M, type=c, bootable\n'
        'start=18432, size=8M, type=83\n'
        'start=34816, type=5\n'
        'start=36864, size=8M, type=83\n'
        'start=55296, size=4M, type=82\n');
    await p.stdin.close();
    expect(await p.exitCode, 0);

    // file systems written into the partitions
    final src = Directory('${tmp.path}/src')..createSync();
    File('${src.path}/hello.txt').writeAsStringSync('hello disk\n');
    final fat = '${tmp.path}/p1.fat';
    Process.runSync(_mkfs!, ['-C', fat, '8192']);
    _dd(fat, disk, 2048);
    final ext = '${tmp.path}/p2.ext';
    Process.runSync(
        _mke2fs!, ['-q', '-F', '-t', 'ext4', '-d', src.path, ext, '8M']);
    _dd(ext, disk, 18432);
    final ext2 = '${tmp.path}/p5.ext';
    Process.runSync(
        _mke2fs!, ['-q', '-F', '-t', 'ext2', '-d', src.path, ext2, '8M']);
    _dd(ext2, disk, 36864);

    final h = MbrHandler();
    final s = FileInStream(File(disk).openSync());
    expect(h.open(s), isTrue);
    expect([for (final it in h.items) it.path],
        ['0.fat', '1.ext', '2.ext', '3.img', '4']);
    expect(h.getArchiveProperty(Kpid.errorFlags), 0);

    // sfdisk's view: every partition but the extended container
    final js =
        jsonDecode(Process.runSync(_sfdisk!, ['-J', disk]).stdout as String)
            as Map<String, dynamic>;
    final parts = [
      for (final p in (js['partitiontable'] as Map)['partitions'] as List)
        if (p['type'] != '5') p
    ];
    expect(parts.length, 4);
    for (var i = 0; i < 4; i++) {
      expect(h.items[i].offset, (parts[i]['start'] as int) * 512);
      expect(h.items[i].size, (parts[i]['size'] as int) * 512);
    }
    expect(h.items[0].active, isTrue);
    expect(h.items[2].primary, isFalse);
    expect(h.items[3].fileSystem, 'Solaris x86 / Linux swap');
    expect(h.items[4].offset + h.items[4].size, 48 << 20);

    // 7-Zip lists the same partitions (it names Linux ones ".img")
    if (findTool('7z') != null) {
      final l = Process.runSync('7z', ['l', '-slt', disk]).stdout as String;
      final offs = RegExp(r'^Offset = (\d+)$', multiLine: true)
          .allMatches(l)
          .map((m) => int.parse(m.group(1)!))
          .toList();
      final sizes = RegExp(r'^Size = (\d+)$', multiLine: true)
          .allMatches(l)
          .map((m) => int.parse(m.group(1)!))
          .toList();
      expect(offs, [for (final it in h.items) it.offset]);
      expect(sizes, [for (final it in h.items) it.size]);
    }

    // the partitions open as file systems through their streams
    final f = FatHandler();
    expect(f.open(h.getStream(0)!), isTrue);
    final e = ExtHandler();
    expect(e.open(h.getStream(1)!), isTrue);
    expect(e.items.any((it) => it.path == 'hello.txt'), isTrue);
    final e2 = ExtHandler();
    expect(e2.open(h.getStream(2)!), isTrue);
    final hi = e2.items.indexWhere((it) => it.path == 'hello.txt');
    expect(readAll(e2.getStream(hi)!), 'hello disk\n'.codeUnits);
    s.raf.closeSync();

    // the API, with no extension and with a wrong one
    for (final n in ['disk', 'disk.zip']) {
      final path = '${tmp.path}/$n';
      File(disk).copySync(path);
      final z = await ZxArchive.open(path);
      expect(z.format, 'MBR');
      expect(z.items.map((i) => i.path).toList(),
          ['0.fat', '1.ext', '2.ext', '3.img', '4']);
      expect(await z.readBytes(z.items[1]),
          File(ext).readAsBytesSync().sublist(0, 8 << 20));
      File(path).deleteSync();
    }
  },
      skip: _sfdisk == null || _mkfs == null || _mke2fs == null
          ? 'sfdisk, mkfs.vfat or mke2fs missing'
          : false);

  test('a loop in the extended boot records, a protective MBR, a FAT volume',
      () {
    final d = Uint8List(1 << 20);
    d.setRange(446, 462, _entry(0x80, 0x0C, 1500, 100));
    d.setRange(462, 478, _entry(0, 0x05, 200, 1000));
    d[510] = 0x55;
    d[511] = 0xAA;
    // EBR at 200: a logical partition and a link back to itself
    const e = 200 * 512;
    d.setRange(e + 446, e + 462, _entry(0, 0x83, 10, 20));
    d.setRange(e + 462, e + 478, _entry(0, 0x05, 0, 0));
    d[e + 510] = 0x55;
    d[e + 511] = 0xAA;
    final h = MbrHandler();
    expect(isArcMbr(d, d.length), 1);
    expect(h.open(MemoryInStream(d)), isTrue);
    expect([for (final it in h.items) it.path], ['0.fat', '1.img', '2']);
    expect(h.items[1].offset, (200 + 10) * 512);
    // a link to a record already read
    d.setRange(e + 462, e + 478, _entry(0, 0x05, 300, 10));
    const e2 = 500 * 512;
    d.setRange(e2 + 462, e2 + 478, _entry(0, 0x05, 300, 10));
    d.setRange(e2 + 446, e2 + 462, _entry(0, 0x83, 1, 1));
    d[e2 + 510] = 0x55;
    d[e2 + 511] = 0xAA;
    expect(h.open(MemoryInStream(d)), isTrue);
    expect(h.getArchiveProperty(Kpid.errorFlags), isNot(0));

    // a protective MBR with a GPT header defers to GPT
    final g = Uint8List(64 << 10);
    g.setRange(446, 462, _entry(0, 0xEE, 1, 127));
    g[510] = 0x55;
    g[511] = 0xAA;
    g.setRange(512, 520, 'EFI PART'.codeUnits);
    expect(isArcMbr(g, g.length), 0);
    expect(h.open(MemoryInStream(g)), isFalse);

    // a status byte that is not 0 or 0x80
    final bad = Uint8List.fromList(d);
    bad[446] = 0x12;
    expect(isArcMbr(bad, bad.length), 0);
  });

  test('a FAT volume is not taken for an MBR', () async {
    final img = '${tmp.path}/vol.mbr';
    final r = Process.runSync(_mkfs!, ['-C', img, '4096']);
    expect(r.exitCode, 0);
    final b = File(img).readAsBytesSync();
    expect(isArcMbr(b, b.length), 0);
    final z = await ZxArchive.open(img);
    expect(z.format, 'FAT');
  }, skip: _mkfs == null ? 'mkfs.vfat missing' : false);
}
