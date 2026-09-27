// Nested archives: ZxArchive.openNested, ZxArchive.open(flatten: true)
// and the -snest switch of the command line tool, on synthetic chains (a
// tar holding an ISO holding a SquashFS image, a GPT disk image with a FAT
// and an ext partition, a uImage with a gzip payload holding a cpio, a 7z
// holding a tar) and on a real firmware file when it is present. Also the
// hard links of tar and cpio, extracted as real hard links.
//
// The fixtures are made with the system tools and skipped when they are
// missing: mksquashfs, xorriso or genisoimage, tar, cpio, sgdisk,
// mkfs.vfat + mcopy, mke2fs.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/cli/main.dart';
import 'package:zx/zx.dart';

import 'codec_test_util.dart';

const String _kPak = '/home/brito/code/xprs/firmware/models/reolink-d340w/'
    'firmware/stock/DB_566128M5MP_W.4662_2508071282.Reolink-Video-Doorbell-'
    'WiFi.OV05A10.5MP.WIFI8812.REOLINK.pak';
const String _kTruth = '/home/brito/code/2026/reolink/cameras/D340W/firmware/'
    'unpacked';

String? _tool(String name) {
  final t = findTool(name);
  if (t != null) return t;
  for (final d in ['/usr/sbin', '/sbin', 'ref/tools/root/usr/sbin']) {
    if (File('$d/$name').existsSync()) return File('$d/$name').absolute.path;
  }
  return null;
}

void _runTool(String tool, List<String> args,
    {String? cwd, Map<String, String>? env}) {
  final r =
      Process.runSync(tool, args, workingDirectory: cwd, environment: env);
  if (r.exitCode != 0) {
    fail('$tool ${args.join(' ')}: ${r.stderr}');
  }
}

class _Run {
  final int code;
  final String out;
  final String err;
  _Run(this.code, this.out, this.err);
}

Future<_Run> _zx(String dir, List<String> args) async {
  final out = BytesBuilder();
  final err = BytesBuilder();
  final code = await runSevenZipCli(args,
      stdout: out.add, stderr: err.add, workingDirectory: dir);
  return _Run(code, utf8.decode(out.takeBytes(), allowMalformed: true),
      utf8.decode(err.takeBytes(), allowMalformed: true));
}

Uint8List _data(int n, int seed) {
  final b = Uint8List(n);
  var x = seed;
  for (var i = 0; i < n; i++) {
    x = (x * 1103515245 + 12345) & 0x7FFFFFFF;
    b[i] = x >> 16;
  }
  return b;
}

/// a.txt, d/r.bin, lnk -> a.txt
void _makeSrc(String src) {
  Directory('$src/d').createSync(recursive: true);
  File('$src/a.txt').writeAsStringSync('hello\n');
  File('$src/d/r.bin').writeAsBytesSync(_data(100000, 7));
  Link('$src/lnk').createSync('a.txt');
}

/// A uImage (legacy U-Boot header) of type ramdisk around [payload],
/// compressed with gzip.
Uint8List _uImage(Uint8List payload) {
  final gz = Uint8List.fromList(GZipCodec().encode(payload));
  final h = ByteData(64);
  h.setUint32(0, 0x27051956);
  h.setUint32(8, 1700000000);
  h.setUint32(12, gz.length);
  h.setUint32(24, Crc32.of(gz));
  h.setUint8(28, 5); // Linux
  h.setUint8(29, 2); // ARM
  h.setUint8(30, 3); // ramdisk
  h.setUint8(31, 1); // gzip
  final name = 'initrd'.codeUnits;
  for (var i = 0; i < name.length; i++) {
    h.setUint8(32 + i, name[i]);
  }
  final hb = h.buffer.asUint8List();
  h.setUint32(4, Crc32.of(hb));
  return Uint8List.fromList([...hb, ...gz]);
}

String _sha(String path) {
  final d = Sha256.hash(File(path).readAsBytesSync());
  return [for (final b in d) b.toRadixString(16).padLeft(2, '0')].join();
}

int _inode(String path) {
  final r = Process.runSync('stat', ['-c', '%i', path]);
  return int.parse((r.stdout as String).trim());
}

/// Checks that [out] holds the files of [src] (a.txt, d/r.bin, lnk).
void _expectSrc(String out, String src) {
  expect(File('$out/a.txt').readAsBytesSync(),
      File('$src/a.txt').readAsBytesSync());
  expect(File('$out/d/r.bin').readAsBytesSync(),
      File('$src/d/r.bin').readAsBytesSync());
  expect(Link('$out/lnk').targetSync(), 'a.txt');
}

void main() {
  late Directory tmp;
  late String src;
  final mksquashfs = _tool('mksquashfs');
  final xorriso = _tool('xorriso');
  final genisoimage = _tool('genisoimage') ?? _tool('mkisofs');
  final tar = _tool('tar');
  final cpio = _tool('cpio');

  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('zx_nest_test_');
    src = '${tmp.path}/src';
    _makeSrc(src);
  });
  tearDownAll(() => tmp.deleteSync(recursive: true));

  // ---- tar > iso > squashfs ----

  final noChain = mksquashfs == null
      ? 'mksquashfs missing'
      : (xorriso == null && genisoimage == null)
          ? 'xorriso or genisoimage missing'
          : tar == null
              ? 'tar missing'
              : null;

  group('tar > iso > squashfs', () {
    late String tarPath;
    setUpAll(() {
      if (noChain != null) return;
      final iso = Directory('${tmp.path}/isosrc')..createSync();
      _runTool(mksquashfs!,
          [src, '${iso.path}/sq.img', '-noappend', '-quiet', '-no-progress']);
      File('${iso.path}/plain.txt').writeAsStringSync('plain\n');
      if (xorriso != null) {
        _runTool(xorriso,
            ['-as', 'mkisofs', '-R', '-o', '${tmp.path}/x.iso', iso.path]);
      } else {
        _runTool(genisoimage!, ['-R', '-o', '${tmp.path}/x.iso', iso.path]);
      }
      tarPath = '${tmp.path}/t.tar';
      _runTool(tar!, ['cf', tarPath, 'x.iso', 'src/a.txt'], cwd: tmp.path);
    });

    test('flatten: tree shape, nested formats, read only', () async {
      final z = await ZxArchive.open(tarPath, flatten: true);
      addTearDown(z.close);
      expect(z.flattened, isTrue);
      expect(z.capabilities.canUpdate, isFalse);
      final iso = z['x.iso']!;
      expect(iso.isDir, isTrue);
      expect(iso.nestedFormat, 'Iso');
      final sq = z['x.iso/sq.img']!;
      expect(sq.isDir, isTrue);
      expect(sq.nestedFormat, 'SquashFS');
      expect(z['x.iso/plain.txt']!.isDir, isFalse);
      expect(z['x.iso/sq.img/d/r.bin']!.size, 100000);
      expect(z['x.iso/sq.img/lnk']!.symlinkTarget, 'a.txt');
      expect(z['src/a.txt']!.nestChain, hasLength(1));
      expect(z['x.iso/sq.img/d/r.bin']!.nestChain, hasLength(3));
      expect(z.children('x.iso/sq.img').map((e) => e.name).toSet(),
          {'a.txt', 'd', 'lnk'});
      expect(
          () => z.add([ZxSource(src)]),
          throwsA(isA<SevenZipException>()
              .having((e) => e.kind, 'kind', SevenZipError.unsupported)));
    });

    test('flatten: extract, test, readBytes, extractToTemp', () async {
      final z = await ZxArchive.open(tarPath, flatten: true);
      addTearDown(z.close);
      final out = '${tmp.path}/out_flat';
      final r = await z.extract(out);
      expect(r.errors, isEmpty);
      _expectSrc('$out/x.iso/sq.img', src);
      expect(File('$out/x.iso/plain.txt').readAsStringSync(), 'plain\n');
      expect(File('$out/src/a.txt').readAsStringSync(), 'hello\n');
      final t = await z.test();
      expect(t.ok, isTrue);
      expect(t.files, r.files);
      expect(await z.readBytes('x.iso/sq.img/d/r.bin'),
          File('$src/d/r.bin').readAsBytesSync());
      final part = await z.readBytes('x.iso/sq.img/d/r.bin', maxBytes: 10);
      expect(part, File('$src/d/r.bin').readAsBytesSync().sublist(0, 10));
      final p = await z.extractToTemp('x.iso/sq.img/a.txt');
      expect(File(p).readAsStringSync(), 'hello\n');
      File(p).parent.deleteSync(recursive: true);
      // a selection below a nested folder
      final out2 = '${tmp.path}/out_flat2';
      final r2 = await z.extract(out2, items: ['x.iso/sq.img/d']);
      expect(r2.files, 1);
      expect(File('$out2/x.iso/sq.img/d/r.bin').lengthSync(), 100000);
    });

    test('flatten keeps the versions of a zpaq archive', () async {
      final zp = '${tmp.path}/n.zpaq';
      await ZxArchive.create(zp, [ZxSource(tarPath)], overwrite: true);
      final z = await ZxArchive.open(zp, flatten: true);
      addTearDown(z.close);
      expect(z['t.tar']!.isNested, isTrue);
      expect(z.numVersions, 1);
      expect(z.versions, hasLength(1));
      expect(await z.probeNested('t.tar'), 'tar');
    });

    test('depth limit', () async {
      final z = await ZxArchive.open(tarPath, flatten: true, maxDepth: 1);
      addTearDown(z.close);
      expect(z['x.iso']!.isDir, isTrue);
      final sq = z['x.iso/sq.img']!;
      expect(sq.isDir, isFalse);
      expect(sq.isNested, isFalse);
      expect(z['x.iso/sq.img/a.txt'], isNull);
    });

    test('openNested goes in and back', () async {
      final z = await ZxArchive.open(tarPath);
      expect(z['x.iso']!.isDir, isFalse);
      expect(await z.probeNested('x.iso'), 'Iso');
      expect(await z.probeNested('src/a.txt'), isNull);
      final iso = await z.openNested('x.iso');
      addTearDown(iso.close);
      expect(iso.format, 'Iso');
      expect(iso.parent, same(z));
      expect(iso.nestPath, ['x.iso']);
      expect(iso.capabilities.canUpdate, isFalse);
      expect(await iso.probeNested('sq.img'), 'SquashFS');
      final sq = await iso.openNested('sq.img');
      addTearDown(sq.close);
      expect(sq.format, 'SquashFS');
      expect(sq.nestPath, ['x.iso', 'sq.img']);
      expect(sq.parent!.parent, same(z));
      final out = '${tmp.path}/out_nested';
      final r = await sq.extract(out);
      expect(r.errors, isEmpty);
      _expectSrc(out, src);
      expect(await sq.readBytes('a.txt'), utf8.encode('hello\n'));
      // a folder of a flattened archive opens as its archive
      final f = await ZxArchive.open(tarPath, flatten: true);
      addTearDown(f.close);
      final n = await f.openNested('x.iso/sq.img');
      addTearDown(n.close);
      expect(n.format, 'SquashFS');
      expect(n['d/r.bin']!.size, 100000);
      await expectLater(
          z.openNested('src/a.txt'),
          throwsA(isA<SevenZipException>()
              .having((e) => e.kind, 'kind', SevenZipError.isNotArc)));
    });

    test('openNested from a format without random access (temp copy)',
        () async {
      final p7 = '${tmp.path}/t.7z';
      final seven = await ZxArchive.create(p7, [ZxSource(tarPath)]);
      expect(await seven.probeNested('t.tar'), 'tar');
      final inner = await seven.openNested('t.tar');
      expect(inner.format, 'tar');
      expect(inner['x.iso']!.size, File('${tmp.path}/x.iso').lengthSync());
      final iso = await inner.openNested('x.iso');
      expect(iso.format, 'Iso');
      final before = Directory.systemTemp
          .listSync()
          .where((e) => e.path.contains('zx_nest_'))
          .length;
      await iso.close();
      await inner.close();
      final after = Directory.systemTemp
          .listSync()
          .where((e) => e.path.contains('zx_nest_'))
          .length;
      expect(after, lessThan(before));
      // the same tree flattened: one pass over the 7z
      final f = await ZxArchive.open(p7, flatten: true);
      expect(f['t.tar/x.iso/sq.img/d/r.bin']!.size, 100000);
      final out = '${tmp.path}/out_7z';
      final r = await f.extract(out);
      expect(r.errors, isEmpty);
      _expectSrc('$out/t.tar/x.iso/sq.img', src);
      await f.close();
    });

    test('CLI -snest: l, t, x, e', () async {
      var r = await _zx(tmp.path, ['l', tarPath]);
      expect(r.code, 0);
      expect(r.out, isNot(contains('x.iso/sq.img')));
      r = await _zx(tmp.path, ['l', '-snest', tarPath]);
      expect(r.code, 0, reason: r.err);
      expect(r.out, contains('x.iso/sq.img/d/r.bin'));
      expect(r.out, contains('x.iso/plain.txt'));
      r = await _zx(tmp.path, ['l', '-snest1', tarPath]);
      expect(r.out, contains('x.iso/sq.img'));
      expect(r.out, isNot(contains('x.iso/sq.img/d/r.bin')));
      r = await _zx(tmp.path, ['t', '-snest', tarPath]);
      expect(r.code, 0, reason: r.err);
      expect(r.out, contains('Everything is Ok'));
      r = await _zx(tmp.path, ['x', '-snest', '-ocli_x', tarPath]);
      expect(r.code, 0, reason: r.err);
      _expectSrc('${tmp.path}/cli_x/x.iso/sq.img', src);
      r = await _zx(
          tmp.path, ['e', '-snest', '-ocli_e', tarPath, 'x.iso/sq.img/d/*']);
      expect(r.code, 0, reason: r.err);
      expect(File('${tmp.path}/cli_e/r.bin').lengthSync(), 100000);
      // an -t chain still opens one level
      r = await _zx(tmp.path, ['l', '-ttar', tarPath]);
      expect(r.code, 0);
      expect(r.out, isNot(contains('x.iso/plain.txt')));
      r = await _zx(tmp.path, ['l', '-snestx', tarPath]);
      expect(r.code, isNot(0));
    });
  }, skip: noChain);

  // ---- GPT disk image with FAT and ext partitions ----

  final sgdisk = _tool('sgdisk');
  final mkfsVfat = _tool('mkfs.vfat') ?? _tool('mkfs.fat');
  final mcopy = _tool('mcopy');
  final mke2fs = _tool('mke2fs');
  final noDisk = sgdisk == null
      ? 'sgdisk missing'
      : mkfsVfat == null
          ? 'mkfs.vfat missing'
          : mcopy == null
              ? 'mcopy missing'
              : mke2fs == null
                  ? 'mke2fs missing'
                  : null;

  test('GPT disk image: FAT and ext partitions', () async {
    final disk = '${tmp.path}/disk.img';
    final fat = '${tmp.path}/fat.img';
    final ext = '${tmp.path}/ext.img';
    File(disk).openSync(mode: FileMode.write)
      ..truncateSync(12 << 20)
      ..closeSync();
    _runTool(
        sgdisk!, ['-n1:2048:+3M', '-t1:0700', '-n2:0:+6M', '-t2:8300', disk]);
    File(fat).openSync(mode: FileMode.write)
      ..truncateSync(3 << 20)
      ..closeSync();
    _runTool(mkfsVfat!, [fat]);
    _runTool(mcopy!, [
      '-s',
      '-i',
      fat,
      '$src/a.txt',
      '$src/d',
      '::/'
    ], env: {
      'MTOOLS_SKIP_CHECK': '1',
      'LC_ALL': 'C.UTF-8',
    });
    _runTool(mke2fs!, ['-q', '-t', 'ext4', '-d', src, ext, '6M']);
    final raf = File(disk).openSync(mode: FileMode.append);
    raf.setPositionSync(2048 * 512);
    raf.writeFromSync(File(fat).readAsBytesSync());
    raf.setPositionSync(8192 * 512);
    raf.writeFromSync(File(ext).readAsBytesSync());
    raf.closeSync();

    final z = await ZxArchive.open(disk, flatten: true);
    addTearDown(z.close);
    expect(z.format, 'GPT');
    final top = z.children('');
    final fatDir = top.firstWhere((e) => e.nestedFormat == 'FAT');
    final extDir = top.firstWhere((e) => e.nestedFormat == 'Ext');
    expect(fatDir.isDir && extDir.isDir, isTrue);
    expect(z['${fatDir.path}/d/r.bin']!.size, 100000);
    expect(z['${extDir.path}/lnk']!.symlinkTarget, 'a.txt');
    final out = '${tmp.path}/out_disk';
    final r = await z.extract(out);
    expect(r.errors, isEmpty);
    expect(File('$out/${fatDir.path}/a.txt').readAsStringSync(), 'hello\n');
    expect(File('$out/${fatDir.path}/d/r.bin').readAsBytesSync(),
        File('$src/d/r.bin').readAsBytesSync());
    _expectSrc('$out/${extDir.path}', src);

    final c = await _zx(tmp.path, ['l', '-snest', disk]);
    expect(c.code, 0, reason: c.err);
    expect(c.out, contains('${extDir.path}/d/r.bin'));
  }, skip: noDisk);

  // ---- uImage (gzip) > cpio ----

  test('uImage with a gzip payload holding a cpio', () async {
    final cpioFile = '${tmp.path}/r.cpio';
    final r0 = Process.runSync('sh', ['-c', 'find . | "$cpio" -o -H newc'],
        workingDirectory: src, stdoutEncoding: null);
    expect(r0.exitCode, 0);
    File(cpioFile).writeAsBytesSync(r0.stdout as List<int>);
    final uimg = '${tmp.path}/r.uimg';
    File(uimg).writeAsBytesSync(_uImage(File(cpioFile).readAsBytesSync()));
    _runTool(tar ?? 'tar', ['cf', '${tmp.path}/u.tar', 'r.uimg'],
        cwd: tmp.path);

    // the uImage alone: its one item is the cpio
    final u = await ZxArchive.open(uimg, flatten: true);
    addTearDown(u.close);
    expect(u.format, 'UImage');
    final top = u.children('');
    expect(top, hasLength(1));
    expect(top.first.nestedFormat, 'Cpio');
    expect(u['${top.first.path}/d/r.bin']!.size, 100000);

    // inside a tar: the folder r.uimg holds the files of the cpio
    final z = await ZxArchive.open('${tmp.path}/u.tar', flatten: true);
    addTearDown(z.close);
    expect(z['r.uimg']!.nestedFormat, 'UImage');
    expect(z['r.uimg/lnk']!.symlinkTarget, 'a.txt');
    final out = '${tmp.path}/out_uimg';
    final r = await z.extract(out);
    expect(r.errors, isEmpty);
    _expectSrc('$out/r.uimg', src);

    // without flatten the uImage item is a file that opens nested
    final plain = await ZxArchive.open('${tmp.path}/u.tar');
    final ui = await plain.openNested('r.uimg');
    expect(ui.format, 'UImage');
    final c = await ui.openNested(0);
    expect(c.format, 'Cpio');
    expect(c.nestPath.length, 2);
  }, skip: cpio == null ? 'cpio missing' : null);

  // ---- hard links ----

  group('hard links', () {
    late String hsrc;
    setUpAll(() {
      hsrc = '${tmp.path}/hsrc';
      Directory('$hsrc/d').createSync(recursive: true);
      File('$hsrc/d/a').writeAsStringSync('data\n');
      Process.runSync('ln', ['$hsrc/d/a', '$hsrc/d/b']);
    });

    for (final kind in ['tar', 'cpio']) {
      final missing = kind == 'tar' ? tar == null : cpio == null;
      test('$kind: real hard links (CLI and API)', () async {
        final arc = '${tmp.path}/h.$kind';
        if (kind == 'tar') {
          _runTool(tar!, ['cf', arc, 'd'], cwd: hsrc);
        } else {
          final r = Process.runSync(
              'sh', ['-c', 'find d | "$cpio" -o -H newc > "$arc"'],
              workingDirectory: hsrc);
          expect(r.exitCode, 0);
        }
        final r = await _zx(tmp.path, ['x', '-ohl_cli_$kind', arc]);
        expect(r.code, 0, reason: r.err);
        expect(r.err, isNot(contains('hard link')));
        final c = '${tmp.path}/hl_cli_$kind/d';
        expect(File('$c/b').readAsStringSync(), 'data\n');
        expect(_inode('$c/a'), _inode('$c/b'));

        final z = await ZxArchive.open(arc);
        final out = '${tmp.path}/hl_api_$kind';
        final e = await z.extract(out);
        expect(e.errors, isEmpty);
        expect(File('$out/d/b').readAsStringSync(), 'data\n');
        expect(_inode('$out/d/a'), _inode('$out/d/b'));
      },
          skip: Platform.isWindows
              ? 'POSIX only'
              : (missing ? 'tool missing' : null));
    }
  });

  // ---- the real firmware ----

  final noPak = !File(_kPak).existsSync()
      ? 'firmware file missing'
      : !Directory(_kTruth).existsSync()
          ? 'unpacked firmware missing'
          : null;

  group('real firmware (Reolink D340W .pak)', () {
    // the unpacked trees: rootfs/<image seq>/rootfs, app/<image seq>/app
    String truth(String sec) {
      final d =
          Directory('$_kTruth/$sec').listSync().whereType<Directory>().first;
      return '${d.path}/$sec';
    }

    Map<String, FileSystemEntity> tree(String root) => {
          for (final e
              in Directory(root).listSync(recursive: true, followLinks: false))
            e.path.substring(root.length + 1): e
        };

    test('flatten: sections, kernel, fdt, rootfs and app trees', () async {
      final umask = int.parse(
          (Process.runSync('sh', ['-c', 'umask']).stdout as String).trim(),
          radix: 8);
      final z = await ZxArchive.open(_kPak, flatten: true);
      addTearDown(z.close);
      expect(z.format, 'Pak');
      expect(z.capabilities.canUpdate, isFalse);
      final top = {for (final i in z.children('')) i.name: i};
      expect(top.keys.toSet(),
          {'loader', 'fdt', 'uboot', 'kernel', 'rootfs', 'app'});
      expect(top['loader']!.isDir, isFalse);
      expect(top['uboot']!.isDir, isFalse);
      expect(top['fdt']!.nestedFormat, 'Fdt');
      expect(top['kernel']!.nestedFormat, 'UImage');
      expect(top['rootfs']!.nestedFormat, 'Ubi');
      expect(top['app']!.nestedFormat, 'Ubi');

      // kernel/: the uImage payload, an ARM zImage
      final k = z.children('kernel');
      expect(k, hasLength(1));
      expect(k.first.size, 1710664);
      final head = await z.readBytes(k.first, maxBytes: 64);
      expect(ByteData.sublistView(head).getUint32(0x24, Endian.little),
          0x016F2818);

      // fdt/: the nodes and the source
      expect(z['fdt/fdt.dts'], isNotNull);
      expect(z['fdt/cpus']!.isDir, isTrue);
      expect(z['fdt/model'], isNotNull);

      final out = '${tmp.path}/pak_api';
      final r =
          await z.extract(out, items: ['rootfs', 'app'], restoreTimes: false);
      // absolute links are refused by the library, as links out of the
      // output folder
      for (final e in r.errors) {
        expect(e.message, contains('Dangerous link'));
      }

      for (final sec in ['rootfs', 'app']) {
        final gt = tree(truth(sec));
        final items = {
          for (final i in z.items)
            if (i.path.startsWith('$sec/')) i.path.substring(sec.length + 1): i
        };
        expect(items.keys.toSet(), gt.keys.toSet(), reason: sec);
        for (final MapEntry(key: p, value: e) in gt.entries) {
          final it = items[p]!;
          if (e is Link) {
            expect(it.isSymlink, isTrue, reason: p);
            expect(it.symlinkTarget, e.targetSync(), reason: p);
            final t = e.targetSync();
            if (!t.startsWith('/')) {
              expect(Link('$out/$sec/$p').targetSync(), t, reason: p);
            }
          } else if (e is Directory) {
            expect(it.isDir, isTrue, reason: p);
          } else {
            final f = e as File;
            expect(it.size, f.lengthSync(), reason: p);
            final x = '$out/$sec/$p';
            expect(_sha(x), _sha(f.path), reason: p);
            // the unpacked tree was written without its modes: the modes
            // are checked against the listing
            final m = FileStat.statSync(x).mode & 0xFFF;
            expect(m, it.posixMode! & 0xFFF & ~umask, reason: p);
          }
        }
      }
    });

    test('openNested: rootfs > UBI volume > UBIFS', () async {
      final z = await ZxArchive.open(_kPak);
      final ubi = await z.openNested('rootfs');
      expect(ubi.format, 'Ubi');
      expect(ubi.items, hasLength(1));
      final fs = await ubi.openNested(0);
      expect(fs.format, 'UbiFs');
      expect(fs.nestPath, ['rootfs', ubi.items.first.path]);
      expect(fs['bin/busybox'], isNotNull);
    });

    test('CLI -snest: l, t, x', () async {
      var r = await _zx(tmp.path, ['l', '-snest', _kPak]);
      expect(r.code, 0, reason: r.err);
      expect(r.out, contains('rootfs/bin/busybox'));
      expect(r.out, contains('kernel/Linux-4.19.91.bin'));
      expect(r.out, contains('fdt/fdt.dts'));
      r = await _zx(tmp.path, ['t', '-snest', _kPak]);
      expect(r.code, 0, reason: r.err);
      expect(r.out, contains('Everything is Ok'));
      // -snld20: the links of the firmware go up (../bin/busybox) or are
      // absolute, which 7-Zip refuses by default
      r = await _zx(tmp.path, ['x', '-snest', '-snld20', '-opak_cli', _kPak]);
      expect(r.code, 0, reason: r.err);
      final out = '${tmp.path}/pak_cli';
      for (final sec in ['rootfs', 'app']) {
        final gt = tree(truth(sec));
        final got = tree('$out/$sec');
        expect(got.keys.toSet(), gt.keys.toSet(), reason: sec);
        for (final MapEntry(key: p, value: e) in gt.entries) {
          if (e is Link) {
            final t = e.targetSync();
            // an absolute link is made inside the output folder
            expect(Link('$out/$sec/$p').targetSync(),
                t.startsWith('/') ? '$out$t' : t,
                reason: p);
          } else if (e is File) {
            expect(_sha('$out/$sec/$p'), _sha(e.path), reason: p);
          }
        }
      }
    });
  }, skip: noPak, timeout: const Timeout(Duration(minutes: 10)));
}
