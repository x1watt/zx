// GPT disk images made with sgdisk on an image file (skipped when sgdisk
// is missing): partition names (with non-ASCII text), type GUIDs, a FAT
// and an ext file system in the partitions, a damaged primary header or
// entry array (the backup is used), and a hand made table with 4096 byte
// sectors. Listings are compared with sgdisk's and 7-Zip's.

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/format/disk/gpt_handler.dart';
import 'package:zx/src/format/disk/mbr_handler.dart';
import 'package:zx/src/format/ext/ext_handler.dart';
import 'package:zx/src/format/fat/fat_handler.dart';
import 'package:zx/zx.dart';

import 'codec_test_util.dart';

final String? _sgdisk = findTool('sgdisk');
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

void _put32(Uint8List b, int o, int v) =>
    ByteData.sublistView(b).setUint32(o, v, Endian.little);
void _put64(Uint8List b, int o, int v) =>
    ByteData.sublistView(b).setUint64(o, v, Endian.little);

// a GPT disk of [sectors] sectors of [ss] bytes with one partition (the
// Linux file system type) from LBA 10 to 19, named "four k"
Uint8List _handMadeGpt(int ss, int sectors) {
  final d = Uint8List(ss * sectors);
  // protective MBR
  d[446 + 4] = 0xEE;
  _put32(d, 446 + 8, 1);
  _put32(d, 446 + 12, sectors - 1);
  d[510] = 0x55;
  d[511] = 0xAA;
  final entries = Uint8List(128 * 4);
  const linux = [
    0xAF, 0x3D, 0xC6, 0x0F, 0x83, 0x84, 0x72, 0x47, //
    0x8E, 0x79, 0x3D, 0x69, 0xD8, 0x47, 0x7D, 0xE4
  ];
  entries.setRange(0, 16, linux);
  for (var i = 16; i < 32; i++) {
    entries[i] = i;
  }
  _put64(entries, 32, 10);
  _put64(entries, 40, 19);
  final name = 'four k'.codeUnits;
  for (var i = 0; i < name.length; i++) {
    entries[56 + i * 2] = name[i];
  }
  final ecrc = Crc32.of(entries);
  void header(int my, int alt, int entryLba) {
    final h = Uint8List(92);
    h.setRange(0, 8, 'EFI PART'.codeUnits);
    _put32(h, 8, 0x10000);
    _put32(h, 12, 92);
    _put64(h, 24, my);
    _put64(h, 32, alt);
    _put64(h, 40, 6);
    _put64(h, 48, sectors - 6);
    for (var i = 0; i < 16; i++) {
      h[56 + i] = 0xA0 + i;
    }
    _put64(h, 72, entryLba);
    _put32(h, 80, 4);
    _put32(h, 84, 128);
    _put32(h, 88, ecrc);
    _put32(h, 16, Crc32.of(h));
    d.setRange(my * ss, my * ss + 92, h);
    d.setRange(entryLba * ss, entryLba * ss + entries.length, entries);
  }

  header(1, sectors - 1, 2);
  header(sectors - 1, 1, sectors - 2);
  return d;
}

void main() {
  late Directory tmp;

  setUpAll(() => tmp = tempDir('gpt'));
  tearDownAll(() => tmp.deleteSync(recursive: true));

  test('sgdisk partitions with names, types and file systems', () async {
    final disk = '${tmp.path}/disk.img';
    File(disk).openSync(mode: FileMode.write)
      ..truncateSync(40 << 20)
      ..closeSync();
    final r = Process.runSync(_sgdisk!, [
      '-n1:2048:+8M', '-t1:ef00', '-c1:EFI System', //
      '-n2:0:+8M', '-t2:8300', '-c2:root fs \u00e9',
      '-n3:0:+4M', '-t3:8200',
      '-n4:0:+4M', '-t4:0700', '-c4:a/b',
      '-n5:0:+2M', '-t5:ea00',
      disk
    ]);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    final fat = '${tmp.path}/efi.fat';
    Process.runSync(_mkfs!, ['-C', fat, '8192']);
    _dd(fat, disk, 2048);
    final src = Directory('${tmp.path}/src')..createSync();
    File('${src.path}/f.txt').writeAsStringSync('gpt\n');
    final ext = '${tmp.path}/root.ext';
    Process.runSync(
        _mke2fs!, ['-q', '-F', '-t', 'ext4', '-d', src.path, ext, '8M']);
    _dd(ext, disk, 18432);

    final h = GptHandler();
    final s = FileInStream(File(disk).openSync());
    expect(h.open(s), isTrue);
    expect(h.usedBackup, isFalse);
    expect([for (final it in h.items) it.path],
        ['0.EFI System.fat', '1.root fs \u00e9.ext', '2.img', '3.a_b.img', '4.img']);
    expect([
      for (final it in h.items) it.fileSystem
    ], [
      'EFI System',
      'Linux Data',
      'Linux Swap',
      'Windows BDP',
      'Linux Extended Boot'
    ]);
    // sgdisk's view of each partition
    for (var i = 0; i < h.items.length; i++) {
      final info =
          Process.runSync(_sgdisk!, ['-i${i + 1}', disk]).stdout as String;
      final first =
          int.parse(RegExp(r'First sector: (\d+)').firstMatch(info)!.group(1)!);
      final last =
          int.parse(RegExp(r'Last sector: (\d+)').firstMatch(info)!.group(1)!);
      final id = RegExp(r'unique GUID: (\S+)').firstMatch(info)!.group(1)!;
      final type = RegExp(r'GUID code: (\S+)').firstMatch(info)!.group(1)!;
      expect(h.getProperty(i, Kpid.offset), first * 512);
      expect(h.getProperty(i, Kpid.size), (last - first + 1) * 512);
      expect(h.getProperty(i, Kpid.id), id);
      expect(h.items[i].typeGuid, type);
    }
    final diskId = RegExp(r'Disk identifier \(GUID\): (\S+)')
        .firstMatch(Process.runSync(_sgdisk!, ['-p', disk]).stdout as String)!
        .group(1);
    expect(h.getArchiveProperty(Kpid.id), diskId);

    if (findTool('7z') != null) {
      final l = Process.runSync('7z', ['l', '-slt', disk]).stdout as String;
      final offs = RegExp(r'^Offset = (\d+)$', multiLine: true)
          .allMatches(l)
          .map((m) => int.parse(m.group(1)!))
          .toList();
      expect(offs, [for (var i = 0; i < 5; i++) h.getProperty(i, Kpid.offset)]);
      final ids = RegExp(r'^ID = (\S+)$', multiLine: true)
          .allMatches(l)
          .map((m) => m.group(1)!)
          .toList();
      expect(ids, [diskId, for (final it in h.items) it.id]);
    }

    // the file systems open through the partition streams
    expect(FatHandler().open(h.getStream(0)!), isTrue);
    final e = ExtHandler();
    expect(e.open(h.getStream(1)!), isTrue);
    final fi = e.items.indexWhere((it) => it.path == 'f.txt');
    expect(readAll(e.getStream(fi)!), 'gpt\n'.codeUnits);
    // the protective MBR is not listed as an MBR disk
    expect(MbrHandler().open(s), isFalse);
    s.raf.closeSync();

    // the API with no extension
    final plain = '${tmp.path}/plain';
    File(disk).copySync(plain);
    final z = await ZxArchive.open(plain);
    expect(z.format, 'GPT');
    expect(z.items.length, 5);

    // a damaged primary header: the backup at the end is used
    final b = File(disk).readAsBytesSync();
    final damaged = Uint8List.fromList(b);
    damaged[512 + 30] ^= 1; // MyLBA, under the header CRC
    expect(h.open(MemoryInStream(damaged)), isTrue);
    expect(h.usedBackup, isTrue);
    expect(h.getArchiveProperty(Kpid.warning), contains('backup'));
    expect(h.items.length, 5);
    // a damaged entry array
    final damaged2 = Uint8List.fromList(b);
    damaged2[1024 + 56] ^= 1;
    expect(h.open(MemoryInStream(damaged2)), isTrue);
    expect(h.usedBackup, isTrue);
    expect(h.items[0].name, 'EFI System');
    // both tables damaged
    damaged2[b.length - 512 + 30] ^= 1;
    damaged2[512 + 16] ^= 1;
    expect(h.open(MemoryInStream(damaged2)), isFalse);
  },
      skip: _sgdisk == null || _mkfs == null || _mke2fs == null
          ? 'sgdisk, mkfs.vfat or mke2fs missing'
          : false);

  test('4096 byte sectors (hand made)', () {
    final d = _handMadeGpt(4096, 64);
    expect(isArcGpt(d, d.length), 1);
    final h = GptHandler();
    expect(h.open(MemoryInStream(d)), isTrue);
    expect(h.sectorSize, 4096);
    expect(h.items.single.path, '0.four k.img');
    expect(h.getProperty(0, Kpid.offset), 10 * 4096);
    expect(h.getProperty(0, Kpid.size), 10 * 4096);
    expect(h.getProperty(0, Kpid.id), '13121110-1514-1716-1819-1A1B1C1D1E1F');
    expect(
        h.getArchiveProperty(Kpid.id), 'A3A2A1A0-A5A4-A7A6-A8A9-AAABACADAEAF');
    // the primary header at 4096 wiped: the backup in the last sector
    d.fillRange(4096, 4096 + 92, 0);
    expect(h.open(MemoryInStream(d)), isTrue);
    expect(h.usedBackup, isTrue);
    expect(h.items.single.name, 'four k');
  });
}
