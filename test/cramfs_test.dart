// cramfs images made by mkfs.cramfs (util-linux; skipped when missing):
// little and big endian, the 512 byte pad, an 8 KiB block size and
// explicit holes. Listings are compared with `7z l -slt`, extracted trees
// with the source tree; the format is detected under a wrong extension.

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/format/cramfs/cramfs_handler.dart';
import 'package:zx/src/io/streams.dart';
import 'package:zx/zx.dart';

import 'codec_test_util.dart';
import 'fs_image_test_util.dart';

void main() {
  final mkcramfs = findFsTool('mkfs.cramfs');
  final sevenZip = findTool('7z');
  late Directory tmp;
  late String src;

  setUpAll(() {
    tmp = tempDir('cramfs');
    src = '${tmp.path}/src';
    makeFsTree(src, many: 50);
  });
  tearDownAll(() => tmp.deleteSync(recursive: true));

  final variants = <String, List<String>>{
    'le': ['-N', 'little'],
    'be': ['-N', 'big'],
    'pad': ['-p'],
    'b8k_holes': ['-b', '8192', '-z'],
  };

  for (final v in variants.entries) {
    test('mkfs.cramfs ${v.key}', () async {
      final img = '${tmp.path}/${v.key}.cramfs';
      final r = Process.runSync(mkcramfs!, [...v.value, src, img]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      final data = File(img).readAsBytesSync();
      final h = CramfsHandler();
      expect(h.open(MemoryInStream(data)), isTrue);
      expect(h.getArchiveProperty(Kpid.errorFlags), 0);
      expect(h.getArchiveProperty(Kpid.phySize), data.length);
      expect(h.bigEndian, v.key == 'be');
      expect(h.base, v.key == 'pad' ? 512 : 0);
      expect(h.blockSize, v.key == 'b8k_holes' ? 8192 : 4096);
      // 7-Zip opens neither the padded image nor other block sizes
      if (sevenZip != null && (v.key == 'le' || v.key == 'be')) {
        expect(handlerSummary(h), sevenZipSummary(img));
      }
      final li = h.items.indexWhere((e) => e.path == 'd/dangling');
      expect(h.getProperty(li, Kpid.symLink), '../nowhere');

      // random access
      final bi = h.items.indexWhere((e) => e.path == 'big.bin');
      final s = h.getStream(bi)!;
      final want = File('$src/big.bin').readAsBytesSync();
      s.position = 500000;
      final part = Uint8List(100000);
      expect(readFully(s, part, 0, part.length), 100000);
      expect(part, want.sublist(500000, 600000));

      final renamed = '${tmp.path}/${v.key}.bin';
      File(img).copySync(renamed);
      final z = await ZxArchive.open(renamed);
      expect(z.format, 'CramFS');
      expect((await z.test()).ok, isTrue);
      final out = '${tmp.path}/out_${v.key}';
      final res = await z.extract(out);
      expect(res.errors, isEmpty);
      expect(diffTrees(src, out), '');
      Directory(out).deleteSync(recursive: true);
    }, skip: mkcramfs == null ? 'mkfs.cramfs missing' : false);
  }

  test('not cramfs', () {
    expect(CramfsHandler().open(MemoryInStream(Uint8List(2048))), isFalse);
    expect(isArcCramfs(Uint8List(1024), 1024), 0);
  });
}
