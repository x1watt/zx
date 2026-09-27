// UBI images made by ubinize (skipped when mtd-utils is missing from the
// PATH and ref/tools/root/usr/sbin): several volumes, static and dynamic,
// two PEB sizes, a truncated image and a corrupt static volume; and the
// real Reolink D340W UBI images (skipped when absent) compared with the
// trees ubi_reader extracted.

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/format/ubi/ubi_handler.dart';
import 'package:zx/src/format/ubifs/ubifs_handler.dart';
import 'package:zx/zx.dart';

import 'ubifs_test.dart' show compareWithTree, makeTree, mtdEnv, mtdTool,
    readItem;

const _work = '/home/brito/code/xprs/firmware/models/reolink-d340w/'
    'firmware/tool/work';
const _unpacked = '/home/brito/code/2026/reolink/cameras/D340W/firmware/'
    'unpacked';

void main() {
  final mkfs = mtdTool('mkfs.ubifs');
  final ubinize = mtdTool('ubinize');
  final noTools =
      mkfs == null || ubinize == null ? 'mkfs.ubifs or ubinize not found' : false;
  late Directory tmp;
  late String src;
  late Uint8List staticData;

  // makes a UBI image with ubinize; returns its path
  String makeUbi(String name, List<String> args, String ini) {
    File('${tmp.path}/$name.ini').writeAsStringSync(ini);
    final out = '${tmp.path}/$name.ubi';
    final r = Process.runSync(
        ubinize!, ['-o', out, ...args, '${tmp.path}/$name.ini'],
        environment: mtdEnv());
    expect(r.exitCode, 0, reason: '${r.stderr}');
    return out;
  }

  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('zx_ubi_');
    if (noTools != false) return;
    src = '${tmp.path}/src';
    makeTree(src);
    staticData = Uint8List(300001);
    for (var i = 0; i < staticData.length; i++) {
      staticData[i] = (i * 7 + (i >> 9)) & 0xFF;
    }
    File('${tmp.path}/static.bin').writeAsBytesSync(staticData);
    for (final e in [('lzo', 126976, 2048), ('zstd', 15872, 512)]) {
      final r = Process.runSync(
          mkfs!,
          [
            '-x', e.$1, '-m', '${e.$3}', '-e', '${e.$2}', '-c', '2000', //
            '-r', src, '${tmp.path}/fs_${e.$1}.ubifs'
          ],
          environment: mtdEnv());
      expect(r.exitCode, 0, reason: '${r.stderr}');
    }
  });
  tearDownAll(() => tmp.deleteSync(recursive: true));

  String multiIni(String fs) => '''
[rootfs]
mode=ubi
image=${tmp.path}/$fs
vol_id=0
vol_type=dynamic
vol_name=rootfs
vol_size=8MiB

[kern]
mode=ubi
image=${tmp.path}/static.bin
vol_id=1
vol_type=static
vol_name=kernel

[empty]
mode=ubi
vol_id=2
vol_type=dynamic
vol_name=spare
vol_size=1MiB

[data]
mode=ubi
image=${tmp.path}/static.bin
vol_id=3
vol_type=dynamic
vol_name=data
vol_flags=autoresize
''';

  void checkMulti(UbiHandler h, int peb, int leb) {
    expect(h.pebSize, peb);
    expect(h.lebSize, leb);
    expect(h.numberOfItems, 4);
    expect([for (var i = 0; i < 4; i++) h.getProperty(i, Kpid.path)],
        ['rootfs.ubifs', 'kernel.bin', 'spare.bin', 'data.bin']);
    expect([for (var i = 0; i < 4; i++) h.getProperty(i, Kpid.type)],
        ['dynamic', 'static', 'dynamic', 'dynamic']);
    expect([for (var i = 0; i < 4; i++) h.getProperty(i, Kpid.id)],
        [0, 1, 2, 3]);
    // static: exact size and data
    expect(h.getProperty(1, Kpid.size), staticData.length);
    expect(readItem(h.getStream(1)!), staticData);
    // dynamic: whole LEBs, 0xFF after the data
    final dyn = readItem(h.getStream(3)!);
    expect(dyn.length % leb, 0);
    expect(dyn.length, greaterThanOrEqualTo(staticData.length));
    expect(dyn.sublist(0, staticData.length), staticData);
    expect(dyn.sublist(staticData.length).every((b) => b == 0xFF), isTrue);
    expect(h.getProperty(2, Kpid.size), 0);
    // the UBIFS volume
    final fs = UbifsHandler();
    expect(fs.open(h.getStream(0)!), isTrue);
    expect(compareWithTree(fs, src, skip: {'fifo'}), isEmpty);
    expect(h.getArchiveProperty(Kpid.warning), isNull);
  }

  test('several volumes, PEB 128 KiB', () {
    final img = makeUbi('multi', ['-p', '131072', '-m', '2048', '-s', '2048'],
        multiIni('fs_lzo.ubifs'));
    final h = UbiHandler();
    expect(h.open(FileInStream.open(img)), isTrue);
    checkMulti(h, 131072, 126976);
    expect(h.minIo, 2048);
  }, skip: noTools);

  test('PEB 16 KiB, sub-pages of 256 bytes', () {
    final img = makeUbi('small', ['-p', '16384', '-m', '512', '-s', '256'],
        multiIni('fs_zstd.ubifs'));
    final h = UbiHandler();
    expect(h.open(FileInStream.open(img)), isTrue);
    expect(h.vidHdrOffset, 256);
    expect(h.dataOffset, 512);
    checkMulti(h, 16384, 15872);
    expect(h.minIo, 512);
  }, skip: noTools);

  test('image ending inside a PEB', () {
    final img = makeUbi('trunc', ['-p', '131072', '-m', '2048', '-s', '2048'],
        multiIni('fs_lzo.ubifs'));
    final bytes = File(img).readAsBytesSync();
    // drop the trailing 0xFF bytes of the last PEB
    var end = bytes.length;
    while (end > 0 && bytes[end - 1] == 0xFF) {
      end--;
    }
    expect(end % 131072, isNot(0));
    final h = UbiHandler();
    expect(h.open(MemoryInStream(Uint8List.sublistView(bytes, 0, end))),
        isTrue);
    expect(h.numberOfItems, 4);
    expect(h.getArchiveProperty(Kpid.warning), contains('inside a PEB'));
    final fs = UbifsHandler();
    expect(fs.open(h.getStream(0)!), isTrue);
    expect(compareWithTree(fs, src, skip: {'fifo'}), isEmpty);
    expect(readItem(h.getStream(1)!), staticData);
  }, skip: noTools);

  test('static volume CRC error and wrong extension', () async {
    final img = makeUbi('crc', ['-p', '131072', '-m', '2048', '-s', '2048'],
        multiIni('fs_lzo.ubifs'));
    final bytes = File(img).readAsBytesSync();
    // the first PEB of volume 1 (static): VID header at 2048, vol_id at 8
    var peb = 0;
    for (; peb * 131072 < bytes.length; peb++) {
      final o = peb * 131072 + 2048;
      if (bytes[o + 11] == 1 && bytes[o + 8] == 0) break;
    }
    bytes[peb * 131072 + 4096 + 100] ^= 1;
    final bad = '${tmp.path}/crc.dat';
    File(bad).writeAsBytesSync(bytes);
    final z = await ZxArchive.open(bad);
    expect(z.format, 'Ubi');
    final t = await z.test();
    expect(t.ok, isFalse);
    // the untouched original, with no extension
    final noExt = '${tmp.path}/image';
    File(img).copySync(noExt);
    final z2 = await ZxArchive.open(noExt);
    expect(z2.format, 'Ubi');
    expect((await z2.test()).ok, isTrue);
  }, skip: noTools);

  group('real firmware', () {
    for (final f in [
      ('rootfs_full.ubi', '$_work/rootfs_ex/153830686/rootfs', 'rootfs'),
      ('rootfs.ubi', '$_unpacked/rootfs/153830686/rootfs', 'rootfs'),
      // a rebuilt app (version 4665): only its version files differ from
      // the stock tree (4662)
      ('_val_app.ubi', '$_unpacked/app/2017043837/app', 'app'),
    ]) {
      final path = '$_work/${f.$1}';
      test(f.$1, () {
        final s = FileInStream.open(path);
        final h = UbiHandler();
        expect(h.open(s), isTrue);
        expect(h.pebSize, 131072);
        expect(h.lebSize, 126976);
        expect(h.numberOfItems, 1);
        expect(h.getProperty(0, Kpid.path), '${f.$3}.ubifs');
        final fs = UbifsHandler();
        expect(fs.open(h.getStream(0)!), isTrue);
        final diffs = compareWithTree(fs, f.$2, checkModes: false);
        expect(
            diffs,
            f.$3 == 'app'
                ? unorderedEquals(['data version_file', 'data version.json'])
                : isEmpty);
        s.raf.closeSync();
      },
          skip: File(path).existsSync() && Directory(f.$2).existsSync()
              ? false
              : 'firmware files absent');
    }
  });
}
