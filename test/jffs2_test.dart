// JFFS2 images made by mkfs.jffs2 (mtd-utils; skipped when missing):
// both byte orders, 64 and 128 KiB erase blocks, padding, the zlib, rtime
// and lzo compressors and a device table. Extracted trees are compared
// with the source tree. A hand edited image adds newer and older node
// versions, a partial overwrite, a truncation, an unlink, a rename and a
// node with a bad data CRC, to check that the newest version wins.

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/format/jffs2/jffs2_handler.dart';
import 'package:zx/src/util/crc.dart';
import 'package:zx/zx.dart';

import 'codec_test_util.dart';
import 'fs_image_test_util.dart';

int _crc(List<int> b) {
  final u = Uint8List.fromList(b);
  return crc32Update(0, u, 0, u.length);
}

class _Node {
  final bool be;
  final List<int> b = [];
  _Node(this.be);
  void u8(int v) => b.add(v & 0xFF);
  void u16(int v) => be
      ? b.addAll([v >> 8 & 0xFF, v & 0xFF])
      : b.addAll([v & 0xFF, v >> 8 & 0xFF]);
  void u32(int v) => be
      ? b.addAll([v >> 24 & 0xFF, v >> 16 & 0xFF, v >> 8 & 0xFF, v & 0xFF])
      : b.addAll([v & 0xFF, v >> 8 & 0xFF, v >> 16 & 0xFF, v >> 24 & 0xFF]);
}

List<int> _header(_Node n, int type, int totlen) {
  n.u16(0x1985);
  n.u16(type);
  n.u32(totlen);
  n.u32(_crc(n.b.sublist(0, 8)));
  return n.b;
}

/// A JFFS2 inode node with raw (uncompressed) data.
List<int> inodeNode(bool be, int ino, int version, int mode, int isize,
    int offset, List<int> data,
    {bool badDataCrc = false}) {
  final n = _Node(be);
  _header(n, 0xE002, 68 + data.length);
  n.u32(ino);
  n.u32(version);
  n.u32(mode);
  n.u16(1000);
  n.u16(1000);
  n.u32(isize);
  n.u32(1700000000); // atime
  n.u32(1700000000); // mtime
  n.u32(1700000000); // ctime
  n.u32(offset);
  n.u32(data.length); // csize
  n.u32(data.length); // dsize
  n.u8(0); // compr none
  n.u8(0);
  n.u16(0);
  n.u32(_crc(data) ^ (badDataCrc ? 1 : 0));
  n.u32(_crc(n.b.sublist(0, 60)));
  n.b.addAll(data);
  while (n.b.length % 4 != 0) {
    n.b.add(0xFF);
  }
  return n.b;
}

/// A JFFS2 directory entry node.
List<int> direntNode(bool be, int pino, int version, int ino, String name,
    {int type = 8}) {
  final nb = name.codeUnits;
  final n = _Node(be);
  _header(n, 0xE001, 40 + nb.length);
  n.u32(pino);
  n.u32(version);
  n.u32(ino);
  n.u32(1700000000);
  n.u8(nb.length);
  n.u8(type);
  n.u16(0);
  n.u32(_crc(n.b.sublist(0, 32)));
  n.u32(_crc(nb));
  n.b.addAll(nb);
  while (n.b.length % 4 != 0) {
    n.b.add(0xFF);
  }
  return n.b;
}

String _content(Jffs2Handler h, String path) {
  final i = h.items.indexWhere((e) => e.path == path);
  if (i < 0) return '<missing>';
  return String.fromCharCodes(readStream(h.getStream(i)!));
}

void main() {
  final mkjffs2 = findFsTool('mkfs.jffs2');
  final skip = mkjffs2 == null ? 'mkfs.jffs2 missing' : false;
  late Directory tmp;
  late String src;
  final lzo = mkjffs2 != null &&
      '${Process.runSync(mkjffs2, ['-L']).stderr}${Process.runSync(mkjffs2, [
            '-L'
          ]).stdout}'
          .contains('lzo');

  setUpAll(() {
    tmp = tempDir('jffs2');
    src = '${tmp.path}/src';
    makeFsTree(src, sparse: false, many: 60);
    File('${tmp.path}/devtab').writeAsStringSync(
        '/dev c 666 0 0 1 3 0 0 -\n/blk b 640 0 6 8 1 0 0 -\n/fifo p 644 0 0 0 0 0 0 -\n');
  });
  tearDownAll(() => tmp.deleteSync(recursive: true));

  final variants = <String, List<String>>{
    'le_64k': ['-l', '-e', '64KiB'],
    'be_128k_pad': ['-b', '-e', '128KiB', '--pad'],
    'rtime': ['-l', '-x', 'zlib'],
    if (lzo) 'lzo': ['-l', '-X', 'lzo', '-x', 'zlib', '-x', 'rtime'],
    'no_cleanmarkers_4k': ['-l', '-n', '-e', '4KiB'],
  };

  for (final v in variants.entries) {
    test('mkfs.jffs2 ${v.key}', () async {
      final img = '${tmp.path}/${v.key}.jffs2';
      final r = Process.runSync(mkjffs2!, [
        '-r',
        src,
        '-o',
        img,
        '-D',
        '${tmp.path}/devtab',
        ...v.value,
      ]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      final data = File(img).readAsBytesSync();
      final h = Jffs2Handler();
      expect(h.open(MemoryInStream(data)), isTrue);
      expect(h.getArchiveProperty(Kpid.errorFlags), 0);
      expect(h.crcErrors, 0);
      expect(h.bigEndian, v.key.startsWith('be'));
      if (v.key == 'be_128k_pad') expect(h.eraseBlockSize, 128 << 10);
      if (v.key == 'le_64k') expect(h.eraseBlockSize, 64 << 10);
      final methods = {for (final it in h.items) ...it.method.split(' ')};
      if (v.key == 'rtime') expect(methods, contains('rtime'));
      if (v.key == 'lzo') expect(methods, contains('lzo'));
      if (v.key.startsWith('le')) expect(methods, contains('zlib'));

      String itemOf(String p) {
        final i = h.items.indexWhere((e) => e.path == p);
        return '${modeString(h.getProperty(i, Kpid.posixAttrib) as int)} '
            '${h.getProperty(i, Kpid.deviceMajor)},'
            '${h.getProperty(i, Kpid.deviceMinor)}';
      }

      expect(itemOf('dev'), 'crw-rw-rw- 1,3');
      expect(itemOf('blk'), 'brw-r----- 8,1');
      expect(itemOf('fifo'), 'prw-r--r-- null,null');
      final li = h.items.indexWhere((e) => e.path == 'lnk');
      expect(h.getProperty(li, Kpid.symLink), 'a.txt');
      final hl = [
        for (final it in h.items)
          if (it.hardLink != null) '${it.path}=${it.hardLink}'
      ];
      expect(hl.length, 1);

      final renamed = '${tmp.path}/${v.key}.dat';
      File(img).copySync(renamed);
      final z = await ZxArchive.open(renamed);
      expect(z.format, 'Jffs2');
      expect((await z.test()).ok, isTrue);
      final out = '${tmp.path}/out_${v.key}';
      final res = await z.extract(out);
      expect(res.errors, isEmpty);
      for (final n in ['dev', 'blk', 'fifo']) {
        final f = File('$out/$n');
        if (f.existsSync()) f.deleteSync();
      }
      expect(diffTrees(src, out), '');
      Directory(out).deleteSync(recursive: true);
    }, skip: skip);
  }

  for (final be in [false, true]) {
    test('newest version wins (${be ? 'BE' : 'LE'})', () {
      final small = '${tmp.path}/small_$be';
      Directory(small).createSync();
      File('$small/a.txt').writeAsStringSync('hello');
      File('$small/b.txt').writeAsStringSync('bye');
      final img = '${tmp.path}/small_$be.jffs2';
      final r = Process.runSync(mkjffs2!,
          ['-r', small, '-o', img, be ? '-b' : '-l', '-e', '64KiB', '--pad']);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      final data = File(img).readAsBytesSync();
      var h = Jffs2Handler();
      expect(h.open(MemoryInStream(data)), isTrue);
      expect(_content(h, 'a.txt'), 'hello');
      final ino = h.items.firstWhere((e) => e.path == 'a.txt').ino;
      final inoB = h.items.firstWhere((e) => e.path == 'b.txt').ino;
      const mode = 0x81A4;
      // the end of the last node: the first 0xFF word after the nodes
      var end = 0;
      for (var p = 0; p + 4 <= data.length; p += 4) {
        if (data[p] != 0xFF || data[p + 1] != 0xFF) end = p + 4;
      }
      final extra = <int>[
        // a newer version, then an older one written after it
        ...inodeNode(be, ino, 100, mode, 15, 0, 'HELLO v2 longer'.codeUnits),
        ...inodeNode(be, ino, 50, mode, 5, 0, 'OLD!!'.codeUnits),
        // a partial overwrite
        ...inodeNode(be, ino, 101, mode, 15, 2, 'XYZ'.codeUnits),
        // a truncation (no data)
        ...inodeNode(be, ino, 102, mode, 8, 0, const []),
        // a newest node with a bad data CRC: skipped
        ...inodeNode(be, ino, 103, mode, 15, 0, 'BROKEN BROKEN!!'.codeUnits,
            badDataCrc: true),
        // unlink b.txt, and rename a.txt to c.txt
        ...direntNode(be, 1, 100, 0, 'b.txt'),
        ...direntNode(be, 1, 101, ino, 'c.txt'),
        ...direntNode(be, 1, 102, 0, 'a.txt'),
        // an old entry for a d.txt that a newer one removed first
        ...direntNode(be, 1, 104, 0, 'd.txt'),
        ...direntNode(be, 1, 103, inoB, 'd.txt'),
      ];
      final edited = Uint8List.fromList(data);
      edited.setAll(end, extra);
      h = Jffs2Handler();
      expect(h.open(MemoryInStream(edited)), isTrue);
      expect(h.crcErrors, 1);
      expect([for (final it in h.items) it.path], ['c.txt']);
      expect(_content(h, 'c.txt'), 'HEXYZ v2');
      expect(h.items.single.size, 8);
    }, skip: skip);
  }

  test('summary nodes (sumtool)', () {
    final img = '${tmp.path}/sum_src.jffs2';
    final sum = '${tmp.path}/sum.jffs2';
    Process.runSync(mkjffs2!, ['-r', src, '-o', img, '-l', '-e', '64KiB']);
    final r = Process.runSync(
        findFsTool('sumtool')!, ['-i', img, '-o', sum, '-e', '64KiB', '-l']);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    final h1 = Jffs2Handler();
    final h2 = Jffs2Handler();
    expect(h1.open(MemoryInStream(File(img).readAsBytesSync())), isTrue);
    expect(h2.open(MemoryInStream(File(sum).readAsBytesSync())), isTrue);
    expect(h2.crcErrors, 0);
    expect(handlerSummary(h2), handlerSummary(h1));
    expect(_content(h2, 'big.bin'), _content(h1, 'big.bin'));
  },
      skip: mkjffs2 == null || findFsTool('sumtool') == null
          ? 'mkfs.jffs2 or sumtool missing'
          : false);

  test('not JFFS2', () {
    expect(Jffs2Handler().open(MemoryInStream(Uint8List(4096))), isFalse);
    final b = Uint8List(64)..setAll(0, [0x85, 0x19, 0x01, 0xE0]);
    expect(isArcJffs2(b, b.length), 0);
  });
}
