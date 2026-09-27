// UBIFS images made by mkfs.ubifs (lzo, zlib, zstd, none; skipped when
// mtd-utils is missing from the PATH and ref/tools/root/usr/sbin) compared
// with their source tree, and the real Reolink D340W rootfs (skipped when
// the files are absent) compared with the tree ubi_reader extracted.

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/format/item_streams.dart';
import 'package:zx/src/format/ubi/ubi_handler.dart';
import 'package:zx/src/format/ubifs/ubifs_handler.dart';
import 'package:zx/zx.dart';

/// Path of an mtd-utils tool, or null.
String? mtdTool(String name) {
  for (final dir in [
    ...(Platform.environment['PATH'] ?? '').split(':'),
    '/usr/sbin',
    '/sbin',
  ]) {
    if (dir.isEmpty) continue;
    final f = File('$dir/$name');
    if (f.existsSync()) return f.path;
  }
  final local = File('ref/tools/root/usr/sbin/$name');
  if (local.existsSync()) return local.absolute.path;
  return null;
}

Map<String, String> mtdEnv() => {
      'LD_LIBRARY_PATH':
          '${Directory('ref/tools/root/usr/lib/x86_64-linux-gnu').absolute.path}'
              ':${Platform.environment['LD_LIBRARY_PATH'] ?? ''}',
    };

/// A source tree with symlinks, hard links, a sparse file, an empty file,
/// deep folders, unicode names, a fifo and a file larger than 1 MB.
void makeTree(String src) {
  Directory('$src/a/b/c/d/e/f/g').createSync(recursive: true);
  Directory('$src/emptydir').createSync();
  File('$src/hello.txt').writeAsStringSync('hello\n');
  File('$src/empty').writeAsBytesSync([]);
  final big = Uint8List(1500000);
  var x = 12345;
  for (var i = 0; i < big.length; i++) {
    x = (x * 1103515245 + 12345) & 0x7fffffff;
    big[i] = (i % 7 == 0) ? (x >> 16) & 0xFF : i & 0x3F;
  }
  File('$src/big.bin').writeAsBytesSync(big);
  final sb = StringBuffer();
  for (var i = 0; i < 60000; i++) {
    sb.writeln(i);
  }
  File('$src/a/seq.txt').writeAsStringSync(sb.toString());
  final sp = File('$src/sparse').openSync(mode: FileMode.write);
  sp.setPositionSync(1000000);
  sp.writeFromSync([1, 2, 3]);
  sp.truncateSync(3 * 1024 * 1024 + 17);
  sp.closeSync();
  File('$src/a/b/c/d/e/f/g/deep.txt').writeAsStringSync('deep');
  File('$src/ünïcödé_名前.txt')
      .writeAsStringSync('uni');
  Link('$src/link').createSync('hello.txt');
  Link('$src/a/uplink').createSync('../hello.txt');
  Link('$src/dirlink').createSync('a/b/c');
  Process.runSync('ln', ['$src/hello.txt', '$src/hard1']);
  Process.runSync('ln', ['$src/a/seq.txt', '$src/a/b/hard2']);
  Process.runSync('mkfifo', ['$src/fifo']);
  Process.runSync('chmod', ['750', '$src/a/b']);
  Process.runSync('chmod', ['4755', '$src/big.bin']);
}

Uint8List readItem(SeekableInStream s) {
  final out = BytesBuilder(copy: false);
  final buf = Uint8List(10000); // not a multiple of the block size
  for (;;) {
    final n = s.read(buf, 0, buf.length);
    if (n == 0) break;
    out.add(Uint8List.fromList(Uint8List.sublistView(buf, 0, n)));
  }
  return out.takeBytes();
}

bool sameBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Compares the items of [h] with the tree at [root]: the same paths,
/// types, sizes, contents, symlink targets and permission bits. Returns
/// the list of differences. Unreadable source files are skipped.
List<String> compareWithTree(UbifsHandler h, String root,
    {Set<String> skip = const {}, bool checkModes = true}) {
  final diffs = <String>[];
  final want = <String, FileSystemEntity>{};
  for (final e in Directory(root).listSync(recursive: true, followLinks: false)) {
    final rel = e.path.substring(root.length + 1);
    if (skip.contains(rel)) continue;
    want[rel] = e;
  }
  final got = <String, int>{};
  for (var i = 0; i < h.numberOfItems; i++) {
    got[h.getProperty(i, Kpid.path) as String] = i;
  }
  for (final p in want.keys) {
    if (!got.containsKey(p)) diffs.add('missing: $p');
  }
  for (final p in got.keys) {
    if (!want.containsKey(p) && !skip.contains(p)) diffs.add('extra: $p');
  }
  for (final e in want.entries) {
    final i = got[e.key];
    if (i == null) continue;
    final ent = e.value;
    final isDir = h.getProperty(i, Kpid.isDir) as bool;
    final mode = h.getProperty(i, Kpid.posixAttrib) as int;
    final st = ent.statSync();
    if (ent is Link) {
      final t = h.getProperty(i, Kpid.symLink);
      if (t != ent.targetSync()) diffs.add('link ${e.key}: $t');
      continue;
    }
    if (checkModes && (st.mode & 0x1FF) != (mode & 0x1FF)) {
      diffs.add('mode ${e.key}: ${st.mode.toRadixString(8)} '
          '${mode.toRadixString(8)}');
    }
    if (ent is Directory) {
      if (!isDir) diffs.add('not a dir: ${e.key}');
      continue;
    }
    if (st.type != FileSystemEntityType.file) continue;
    final size = h.getProperty(i, Kpid.size) as int;
    if (size != st.size) {
      diffs.add('size ${e.key}: $size ${st.size}');
      continue;
    }
    Uint8List ref;
    try {
      ref = File(ent.path).readAsBytesSync();
    } on FileSystemException {
      continue;
    }
    final data = readItem(h.getStream(i)!);
    if (!sameBytes(data, ref)) diffs.add('data ${e.key}');
  }
  return diffs;
}

const _stockPak = '/home/brito/code/xprs/firmware/models/reolink-d340w/'
    'firmware/stock/DB_566128M5MP_W.4662_2508071282.Reolink-Video-Doorbell-'
    'WiFi.OV05A10.5MP.WIFI8812.REOLINK.pak';
const _work = '/home/brito/code/xprs/firmware/models/reolink-d340w/'
    'firmware/tool/work';
const _unpacked = '/home/brito/code/2026/reolink/cameras/D340W/firmware/'
    'unpacked';

void main() {
  final mkfs = mtdTool('mkfs.ubifs');
  late Directory tmp;
  late String src;

  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('zx_ubifs_');
    src = '${tmp.path}/src';
    makeTree(src);
  });
  tearDownAll(() => tmp.deleteSync(recursive: true));

  group('mkfs.ubifs', () {
    for (final compr in ['lzo', 'zlib', 'zstd', 'none', 'favor_lzo']) {
      test(compr, () async {
        final img = '${tmp.path}/fs_$compr.ubifs';
        final r = Process.runSync(
            mkfs!,
            [
              '-x', compr, '-m', '2048', '-e', '126976', '-c', '200', //
              '-r', src, img
            ],
            environment: mtdEnv());
        if (r.exitCode != 0 && compr == 'zstd') {
          markTestSkipped('mkfs.ubifs without zstd');
          return;
        }
        expect(r.exitCode, 0, reason: '${r.stderr}');
        final s = FileInStream.open(img);
        final h = UbifsHandler();
        expect(h.open(s), isTrue);
        expect(h.lebSize, 126976);
        expect(h.minIoSize, 2048);
        expect(h.getArchiveProperty(Kpid.warning), isNull);
        expect(compareWithTree(h, src, skip: {'fifo'}), isEmpty);
        // links, hard links, fifo, methods
        int idx(String p) {
          for (var i = 0; i < h.numberOfItems; i++) {
            if (h.getProperty(i, Kpid.path) == p) return i;
          }
          return -1;
        }

        expect(h.getProperty(idx('link'), Kpid.symLink), 'hello.txt');
        expect(h.getProperty(idx('a/uplink'), Kpid.symLink), '../hello.txt');
        final hl = h.getProperty(idx('hello.txt'), Kpid.hardLink) ??
            h.getProperty(idx('hard1'), Kpid.hardLink);
        expect(hl, anyOf('hello.txt', 'hard1'));
        expect(h.getProperty(idx('hard1'), Kpid.links), 2);
        expect((h.getProperty(idx('fifo'), Kpid.posixAttrib) as int) & 0xF000,
            0x1000);
        expect(
            (h.getProperty(idx('big.bin'), Kpid.posixAttrib) as int) & 0xFFF,
            0x9ED); // 4755
        final m = h.getProperty(idx('big.bin'), Kpid.method);
        expect(m, compr == 'favor_lzo' ? anyOf('LZO', 'zlib') : isNotNull);
        final st = File('$src/hello.txt').statSync();
        expect(
            h.getProperty(idx('hello.txt'), Kpid.mTime) as int,
            // mkfs.ubifs stores whole seconds
            st.modified.millisecondsSinceEpoch ~/ 1000 * 10000000 +
                116444736000000000);
        // random access in the middle of a block
        final s2 = h.getStream(idx('big.bin'))!;
        s2.position = 5000;
        final b = Uint8List(100);
        expect(s2.read(b, 0, 100), 100);
        final ref = File('$src/big.bin').readAsBytesSync();
        expect(b, ref.sublist(5000, 5100));
        s.raf.closeSync();
      }, skip: mkfs == null ? 'mkfs.ubifs not found' : false);
    }

    test('API with a wrong extension', () async {
      final img = '${tmp.path}/fs.txt';
      final r = Process.runSync(mkfs!,
          ['-m', '2048', '-e', '126976', '-c', '200', '-r', src, img],
          environment: mtdEnv());
      expect(r.exitCode, 0);
      final z = await ZxArchive.open(img);
      expect(z.format, 'UbiFs');
      expect((await z.test()).ok, isTrue);
      final out = '${tmp.path}/out';
      final res = await z.extract(out);
      expect(res.errors, isEmpty);
      final diff = Process.runSync(
          'diff', ['-r', '--no-dereference', '-x', 'fifo', src, out]);
      expect(diff.exitCode, 0, reason: '${diff.stdout}');
      // no extension at all
      final noExt = '${tmp.path}/fsimage';
      File(img).renameSync(noExt);
      final z2 = await ZxArchive.open(noExt);
      expect(z2.format, 'UbiFs');
    }, skip: mkfs == null ? 'mkfs.ubifs not found' : false);

    test('corrupt data node', () {
      final img = '${tmp.path}/fs_bad.ubifs';
      final r = Process.runSync(mkfs!,
          ['-x', 'none', '-m', '2048', '-e', '126976', '-c', '200', '-r', src, img],
          environment: mtdEnv());
      expect(r.exitCode, 0);
      final bytes = File(img).readAsBytesSync();
      // flip a byte of the file data "hello"
      final at = _find(bytes, 'hello\n'.codeUnits);
      expect(at, greaterThan(0));
      bytes[at] ^= 0x20;
      final h = UbifsHandler();
      expect(h.open(MemoryInStream(bytes)), isTrue);
      var i = 0;
      while (h.getProperty(i, Kpid.path) != 'hello.txt') {
        i++;
      }
      expect(() => readItem(h.getStream(i)!),
          throwsA(isA<SevenZipException>()));
    }, skip: mkfs == null ? 'mkfs.ubifs not found' : false);
  });

  group('real firmware', () {
    final rUbifs = File('$_work/_r.ubifs');
    final gt = '$_work/rootfs_ex/153830686/rootfs';
    test('_r.ubifs equals the ubi_reader tree', () {
      final s = FileInStream.open(rUbifs.path);
      final h = UbifsHandler();
      expect(h.open(s), isTrue);
      expect(h.getArchiveProperty(Kpid.method), 'LZO');
      // ubi_reader does not restore the permission bits
      expect(compareWithTree(h, gt, checkModes: false), isEmpty);
      s.raf.closeSync();
    },
        skip: rUbifs.existsSync() && Directory(gt).existsSync()
            ? false
            : 'firmware files absent');

    final pak = File(_stockPak);
    for (final sec in [
      ('rootfs', 0x20f3e8, 0x1320000, '$_unpacked/rootfs/153830686/rootfs'),
      ('app', 0x152f3e8, 0x12a0000, '$_unpacked/app/2017043837/app'),
    ]) {
      test('stock pak ${sec.$1} equals the ubi_reader tree', () {
        final f = FileInStream.open(pak.path);
        final ubi = UbiHandler();
        expect(ubi.open(SubInStream(f, sec.$2, sec.$3)), isTrue);
        expect(ubi.pebSize, 131072);
        expect(ubi.lebSize, 126976);
        expect(ubi.numberOfItems, 1);
        expect(ubi.getProperty(0, Kpid.path), '${sec.$1}.ubifs');
        final h = UbifsHandler();
        expect(h.open(ubi.getStream(0)!), isTrue);
        expect(compareWithTree(h, sec.$4, checkModes: false), isEmpty);
        f.raf.closeSync();
      },
          skip: pak.existsSync() && Directory(sec.$4).existsSync()
              ? false
              : 'firmware files absent');
    }
  });
}

int _find(Uint8List b, List<int> pat) {
  outer:
  for (var i = 0; i + pat.length <= b.length; i++) {
    for (var j = 0; j < pat.length; j++) {
      if (b[i + j] != pat[j]) continue outer;
    }
    return i;
  }
  return -1;
}
