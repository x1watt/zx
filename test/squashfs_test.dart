// SquashFS 4.0 images made by mksquashfs (skipped when it is missing)
// with every compressor it supports, uncompressed data, fragment and
// block size variants, pseudo devices and a fifo. Listings are compared
// with `unsquashfs -lln` and `7z l -slt`, extracted trees with the source
// tree; the format is detected under a wrong extension.

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/format/squashfs/squashfs_handler.dart';
import 'package:zx/src/io/streams.dart';
import 'package:zx/zx.dart';

import 'codec_test_util.dart';
import 'fs_image_test_util.dart';

// `unsquashfs -lln` as "mode uid/gid size path[ -> target]" lines
List<String> _unsquashfsList(String img) {
  final r = Process.runSync('unsquashfs', ['-lln', img]);
  final re = RegExp(r'^(\S+) (\d+)/(\d+)\s+(\d+|\d+,\s*\d+) \S+ \S+ '
      r'squashfs-root/(.*)$');
  final out = <String>[];
  for (final line in (r.stdout as String).split('\n')) {
    final m = re.firstMatch(line);
    if (m == null) continue;
    final size = m.group(4)!.replaceAll(' ', '');
    out.add('${m.group(1)} ${m.group(2)}/${m.group(3)} $size ${m.group(5)}');
  }
  out.sort();
  return out;
}

List<String> _ourList(SquashfsHandler h) {
  final out = <String>[];
  for (var i = 0; i < h.numberOfItems; i++) {
    final mode = h.getProperty(i, Kpid.posixAttrib) as int;
    final maj = h.getProperty(i, Kpid.deviceMajor);
    final size = maj != null
        ? '$maj,${h.getProperty(i, Kpid.deviceMinor)}'
        : h.getProperty(i, Kpid.isDir) == true
            ? null
            : '${h.getProperty(i, Kpid.size)}';
    final link = h.getProperty(i, Kpid.symLink);
    out.add('${modeString(mode)} ${h.getProperty(i, Kpid.userId)}/'
        '${h.getProperty(i, Kpid.groupId)} ${size ?? 'DIR'} '
        '${h.getProperty(i, Kpid.path)}${link != null ? ' -> $link' : ''}');
  }
  out.sort();
  return out;
}

void main() {
  final mksquashfs = findFsTool('mksquashfs');
  final unsquashfs = findFsTool('unsquashfs');
  final help = mksquashfs == null
      ? ''
      : '${Process.runSync(mksquashfs, ['-help']).stderr}'
          '${Process.runSync(mksquashfs, ['-help']).stdout}';
  late Directory tmp;
  late String src;

  setUpAll(() {
    tmp = tempDir('squashfs');
    src = '${tmp.path}/src';
    makeFsTree(src);
  });
  tearDownAll(() => tmp.deleteSync(recursive: true));

  final variants = <String, List<String>>{
    'gzip': ['-comp', 'gzip'],
    'lzo': ['-comp', 'lzo'],
    'lz4': ['-comp', 'lz4'],
    'xz': ['-comp', 'xz'],
    'xz_bcj': ['-comp', 'xz', '-Xbcj', 'x86,arm'],
    'zstd': ['-comp', 'zstd'],
    'lzma': ['-comp', 'lzma'],
    'uncompressed': ['-noI', '-noD', '-noF', '-noX'],
    'noF_noD': ['-comp', 'gzip', '-noF', '-noD'],
    'b4k': ['-comp', 'lz4', '-b', '4K'],
    'b1m': ['-comp', 'zstd', '-b', '1M'],
    'no_frag': ['-comp', 'gzip', '-no-fragments'],
    'always_frag': ['-comp', 'gzip', '-always-use-fragments'],
  };

  for (final v in variants.entries) {
    final comp = v.value.length > 1 && v.value[0] == '-comp' ? v.value[1] : '';
    final skip = mksquashfs == null
        ? 'mksquashfs missing'
        : (comp.isNotEmpty && !RegExp('\\b$comp\\b').hasMatch(help))
            ? 'mksquashfs without $comp'
            : false;
    test('mksquashfs ${v.key}', () async {
      final img = '${tmp.path}/${v.key}.sqfs';
      final r = Process.runSync(mksquashfs!, [
        src,
        img,
        '-noappend',
        '-quiet',
        '-no-progress',
        ...v.value,
        '-p',
        'dev c 666 0 0 1 3',
        '-p',
        'blk b 640 0 6 8 1',
        '-p',
        'fifo i 644 0 0 f',
      ]);
      expect(r.exitCode, 0, reason: '${r.stderr}');

      final data = File(img).readAsBytesSync();
      final h = SquashfsHandler();
      expect(h.open(MemoryInStream(data)), isTrue);
      expect(h.getArchiveProperty(Kpid.errorFlags), 0);
      expect(h.getArchiveProperty(Kpid.phySize), data.length);
      if (comp.isNotEmpty) expect(h.methodName, comp);
      if (unsquashfs != null) {
        expect(_ourList(h).where((s) => !s.contains(' DIR ')).toList(),
            _unsquashfsList(img).where((s) => !s.startsWith('d')).toList());
      }
      final hard = h.items.firstWhere((e) => e.path == 'd/hard');
      final a = h.items.firstWhere((e) => e.path == 'a.txt');
      expect(hard.hardLink ?? a.hardLink, isNotNull);
      // random access of a file through getStream
      final bi = h.items.indexWhere((e) => e.path == 'big.bin');
      final s = h.getStream(bi)!;
      final want = File('$src/big.bin').readAsBytesSync();
      s.position = 654321;
      final part = Uint8List(40000);
      expect(readFully(s, part, 0, part.length), 40000);
      expect(part, want.sublist(654321, 694321));

      // detection under a wrong extension, test and extraction
      // a wrong extension, or none
      final renamed =
          '${tmp.path}/renamed_${v.key}${v.key.contains('_') ? '' : '.zip'}';
      File(img).copySync(renamed);
      final z = await ZxArchive.open(renamed);
      expect(z.format, 'SquashFS');
      expect((await z.test()).ok, isTrue);
      final out = '${tmp.path}/out_${v.key}';
      final res = await z.extract(out);
      expect(res.errors, isEmpty);
      for (final n in ['dev', 'blk', 'fifo']) {
        final f = File('$out/$n');
        if (f.existsSync()) f.deleteSync();
      }
      expect(diffTrees(src, out), '');
      expect(Link('$out/lnk').targetSync(), 'a.txt');
      File(renamed).deleteSync();
      Directory(out).deleteSync(recursive: true);
    }, skip: skip);
  }

  test('7z lists the same items', () {
    final img = '${tmp.path}/for7z.sqfs';
    Process.runSync(
        mksquashfs!, [src, img, '-noappend', '-quiet', '-no-progress']);
    final h = SquashfsHandler();
    expect(h.open(MemoryInStream(File(img).readAsBytesSync())), isTrue);
    expect(handlerSummary(h), sevenZipSummary(img));
  },
      skip: mksquashfs == null || findTool('7z') == null
          ? 'mksquashfs or 7z missing'
          : false);

  test('not SquashFS', () {
    final h = SquashfsHandler();
    expect(h.open(MemoryInStream(Uint8List(4096))), isFalse);
    final b = Uint8List(96)..setAll(0, 'sqsh'.codeUnits);
    expect(isArcSquashfs(b, b.length), 0);
  });
}
