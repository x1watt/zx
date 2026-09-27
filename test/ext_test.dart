// ext2, ext3 and ext4 images written by mke2fs -d from a source tree (all
// skipped when e2fsprogs is missing): block maps with 1 KiB blocks,
// extents, inline data, meta_bg, 128 byte inodes, no file type, sparse
// super 2, 32-bit descriptors, hashed folders (e2fsck -D). The extracted
// trees are compared with the source tree (content, symlinks, modes,
// times), listings with 7-Zip's where it reads the variant, devices made
// with debugfs, files larger than 4 GiB (sparse) and a file system that
// needs journal recovery.

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/format/ext/ext_handler.dart';
import 'package:zx/src/io/streams.dart';
import 'package:zx/zx.dart';

import 'codec_test_util.dart';

String? _mke2fs = findTool('mke2fs');
String? _debugfs = findTool('debugfs');

void _run(String tool, List<String> args) {
  final r = Process.runSync(tool, args);
  if (r.exitCode != 0) {
    throw StateError('$tool ${args.join(' ')}: ${r.stderr}');
  }
}

// the source tree: deep folders, long and unicode names, a big folder,
// symlinks (fast and slow), hard links, a fifo, sparse and fragmented
// files
void makeSourceTree(String src) {
  Directory('$src/a/b/c/d/e/f').createSync(recursive: true);
  Directory('$src/big').createSync();
  Directory('$src/uni/Ordner \u00fc').createSync(recursive: true);
  Directory('$src/h').createSync();
  File('$src/a/b/c/d/e/f/deep.txt').writeAsStringSync('hello\n');
  File('$src/small100').writeAsStringSync('x' * 100);
  File('$src/big/rand.bin').writeAsBytesSync(randomData(300000, 7));
  File('$src/empty').writeAsBytesSync([]);
  File('$src/uni/Gr\u00fc\u00dfe \u2603 \u65e5\u672c.txt').writeAsStringSync('m\u00fcller\n');
  Link('$src/fastlink').createSync('a/b/c/d/e/f/deep.txt');
  Link('$src/slowlink')
      .createSync('${'l' * 100}/target/that/is/longer/than/sixty/bytes');
  Process.runSync('ln', ['$src/small100', '$src/hard1']);
  Process.runSync('ln', ['$src/small100', '$src/h/hard2']);
  Process.runSync('mkfifo', ['$src/fifo']);
  final sp = File('$src/sparse').openSync(mode: FileMode.write);
  sp.setPositionSync(500000);
  sp.writeStringSync('mid');
  sp.setPositionSync(1 << 20);
  sp.writeStringSync('end');
  sp.closeSync();
  final fr = File('$src/frag').openSync(mode: FileMode.write);
  for (var i = 0; i < 200; i++) {
    fr.setPositionSync(i * 16384);
    fr.writeFromSync(randomData(100, i));
  }
  fr.closeSync();
  for (var i = 1; i <= 200; i++) {
    File('$src/big/file_with_long_name_$i.txt').writeAsStringSync('$i\n');
  }
}

/// `find` listing of a tree: path, type, mode, mtime seconds (links and
/// fifos by type only).
List<String> treeListing(String dir, {Set<String> skip = const {}}) {
  final r = Process.runSync(
      'find',
      [
        '.',
        '-printf',
        r'%p %y %m %T@\n',
      ],
      workingDirectory: dir);
  final out = <String>[];
  for (final l in (r.stdout as String).split('\n')) {
    if (l.isEmpty) continue;
    final parts = l.split(' ');
    final t = parts.removeLast();
    final path = parts.take(parts.length - 2).join(' ');
    if (path == '.' || skip.any((s) => path == s || path.startsWith('$s/'))) {
      continue;
    }
    final type = parts[parts.length - 2];
    final mode = parts[parts.length - 1];
    if (type == 'l' || type == 'p') {
      out.add('$path $type');
    } else {
      out.add('$path $type $mode ${t.split('.').first}');
    }
  }
  out.sort();
  return out;
}

Map<String, String> _listing7z(String img) {
  final r = Process.runSync('7z', ['l', '-slt', img]);
  final out = <String, String>{};
  final body = (r.stdout as String).split('----------\n');
  if (body.length < 2) return out;
  for (final blk in body[1].split('\n\n')) {
    String? path;
    final f = <String>[];
    for (final line in blk.split('\n')) {
      final k = line.indexOf(' = ');
      if (k < 0) continue;
      final key = line.substring(0, k);
      final v = line.substring(k + 3);
      if (key == 'Path') path = v;
      if (key == 'Size' || key == 'Mode' || key == 'Symbolic Link') {
        f.add('$key=$v');
      }
    }
    if (path != null) out[path] = f.join(' ');
  }
  return out;
}

void main() {
  late Directory tmp;
  late String src;

  setUpAll(() {
    tmp = tempDir('ext');
    src = '${tmp.path}/src';
    Directory(src).createSync();
    makeSourceTree(src);
  });
  tearDownAll(() => tmp.deleteSync(recursive: true));

  final variants = <String, List<String>>{
    'ext2_1k': ['-t', 'ext2', '-b', '1024'],
    'ext3': ['-t', 'ext3'],
    'ext4': ['-t', 'ext4'],
    'inline': ['-t', 'ext4', '-O', 'inline_data', '-I', '256'],
    'blockmap4': ['-t', 'ext4', '-O', '^extent,^64bit'],
    'metabg': ['-t', 'ext4', '-O', 'meta_bg,^resize_inode'],
    'inode128': ['-t', 'ext4', '-I', '128'],
    'nofiletype': ['-t', 'ext2', '-O', '^filetype'],
    'sparse2': ['-t', 'ext4', '-O', 'sparse_super2'],
    'desc32': ['-t', 'ext4', '-O', '^64bit,^flex_bg'],
    'htree': ['-t', 'ext4'],
  };

  for (final v in variants.entries) {
    test('mke2fs ${v.value.join(' ')} (${v.key})', () async {
      final img = '${tmp.path}/${v.key}.img';
      _run(_mke2fs!, ['-q', '-F', ...v.value, '-d', src, img, '16M']);
      if (v.key == 'htree') {
        final fsck = findTool('e2fsck');
        if (fsck == null) return;
        Process.runSync(fsck, ['-fyD', img]);
        final ht = Process.runSync(_debugfs!, ['-R', 'htree big', img]);
        expect(ht.stdout as String, contains('Root node dump'));
      }

      final h = ExtHandler();
      final s = FileInStream(File(img).openSync());
      expect(h.open(s), isTrue);
      expect(h.getArchiveProperty(Kpid.errorFlags), 0);
      final byPath = {for (final it in h.items) it.path: it};
      expect(byPath['fastlink']!.symLink, 'a/b/c/d/e/f/deep.txt');
      expect(byPath['slowlink']!.symLink,
          '${'l' * 100}/target/that/is/longer/than/sixty/bytes');
      // hard links point at the first path of the inode
      final links = [
        for (final it in h.items)
          if (it.hardLink != null) it.path
      ];
      expect(links.length, 2);
      expect(byPath['big/file_with_long_name_200.txt']!.size, 4);
      final fifo = byPath['fifo']!;
      expect(fifo.mode & 0xF000, 0x1000);
      final st = File('$src/small100').statSync();
      final it = byPath['small100']!;
      expect(it.mode & 0xFFF, st.mode & 0xFFF);
      // mke2fs -d keeps whole seconds
      expect(
          it.mTime,
          st.modified.millisecondsSinceEpoch ~/ 1000 * 10000000 +
              116444736000000000);
      expect(it.uid, isNot(isNull));
      s.raf.closeSync();

      // extraction through the API, with a wrong extension
      final list7z = findTool('7z') != null && v.key != 'inline'
          ? _listing7z(img)
          : null;
      final renamed = '${tmp.path}/${v.key}.zip';
      File(img).renameSync(renamed);
      final z = await ZxArchive.open(renamed);
      expect(z.format, 'Ext');
      expect((await z.test()).ok, isTrue);
      final out = '${tmp.path}/out_${v.key}';
      final res = await z.extract(out);
      expect(res.errors, isEmpty);
      final diff = Process.runSync('diff', [
        '-r',
        '--no-dereference',
        '-x',
        'fifo',
        '-x',
        'lost+found',
        '-x',
        '*SYS*',
        src,
        out
      ]);
      expect(diff.exitCode, 0, reason: '${diff.stdout}');
      expect(treeListing(out, skip: {'./lost+found', './[SYS]', './fifo'}),
          treeListing(src, skip: {'./fifo'}));
      expect(File('$out/h/hard2').readAsStringSync(), 'x' * 100);

      // 7-Zip's listing (it does not read inline data)
      if (list7z != null) {
        final a = list7z;
        final b = <String, String>{};
        final z2 = await ZxArchive.open(renamed);
        for (final i in z2.items.where((e) => !e.isImplied)) {
          b[i.path] = [
            if (!i.isDir) 'Size=${i.size}',
            if (i.symlinkTarget != null) 'Symbolic Link=${i.symlinkTarget}',
          ].join(' ');
        }
        expect(b.keys.toSet(), a.keys.toSet());
        for (final p in a.keys) {
          final sz = RegExp(r'Size=(\d+)').firstMatch(a[p]!)?.group(1);
          if (sz != null) expect(b[p], contains('Size=$sz'), reason: p);
          final sl = RegExp(r'Symbolic Link=(\S+)').firstMatch(a[p]!);
          if (sl != null) {
            expect(b[p], contains('Symbolic Link=${sl.group(1)}'));
          }
        }
      }
    }, skip: _mke2fs == null || _debugfs == null ? 'e2fsprogs missing' : false);
  }

  test('devices made with debugfs, journal recovery flag', () {
    final img = '${tmp.path}/dev.img';
    _run(_mke2fs!, ['-q', '-F', '-t', 'ext4', img, '8M']);
    _run(_debugfs!, ['-w', '-R', 'mknod cdev c 4 5', img]);
    _run(_debugfs!, ['-w', '-R', 'mknod bdev b 259 300', img]);
    _run(_debugfs!, ['-w', '-R', 'mknod pipe p', img]);
    final h = ExtHandler();
    final s = FileInStream(File(img).openSync());
    expect(h.open(s), isTrue);
    final byPath = {for (final it in h.items) it.path: it};
    final c = h.items.indexOf(byPath['cdev']!);
    expect(h.getProperty(c, Kpid.deviceMajor), 4);
    expect(h.getProperty(c, Kpid.deviceMinor), 5);
    expect((h.getProperty(c, Kpid.posixAttrib)! as int) & 0xF000, 0x2000);
    final b = h.items.indexOf(byPath['bdev']!);
    expect(h.getProperty(b, Kpid.deviceMajor), 259);
    expect(h.getProperty(b, Kpid.deviceMinor), 300);
    expect(byPath['pipe']!.mode & 0xF000, 0x1000);
    // the extra time field: nanoseconds and epoch bits
    _run(_debugfs!, ['-w', '-R', 'sif cdev mtime 0x10', img]);
    _run(_debugfs!, ['-w', '-R', 'sif cdev mtime_extra 0x773593FD', img]);
    expect(h.open(FileInStream(File(img).openSync())), isTrue);
    final cd = h.items.firstWhere((e) => e.path == 'cdev');
    expect(cd.mTime,
        (0x10 + (1 << 32) + 11644473600) * 10000000 + 499999999 ~/ 100);
    expect(byPath['[SYS]/Journal']!.size, greaterThan(0));
    expect(h.getArchiveProperty(Kpid.warning), isNull);
    s.raf.closeSync();

    _run(_debugfs!, ['-w', '-R', 'feature needs_recovery', img]);
    final s2 = FileInStream(File(img).openSync());
    expect(h.open(s2), isTrue);
    expect(h.needsRecovery, isTrue);
    expect(h.getArchiveProperty(Kpid.warning), contains('recovery'));
    s2.raf.closeSync();
  }, skip: _mke2fs == null || _debugfs == null ? 'e2fsprogs missing' : false);

  for (final opts in [
    ['-t', 'ext2', '-b', '1024'],
    ['-t', 'ext4'],
  ]) {
    test('a sparse file larger than 4 GiB (${opts.join(' ')})', () {
      final src2 = Directory('${tmp.path}/huge_src')..createSync();
      final f = File('${src2.path}/huge').openSync(mode: FileMode.write);
      const five = 5 << 30;
      f.truncateSync(five);
      f.setPositionSync(4608 << 20);
      f.writeStringSync('HUGE');
      f.setPositionSync(five - 4);
      f.writeStringSync('TAIL');
      f.closeSync();
      final img = '${tmp.path}/huge.img';
      _run(_mke2fs!, ['-q', '-F', ...opts, '-d', src2.path, img, '8M']);
      src2.deleteSync(recursive: true);
      final h = ExtHandler();
      final s = FileInStream(File(img).openSync());
      expect(h.open(s), isTrue);
      final i = h.items.indexWhere((e) => e.path == 'huge');
      expect(h.getProperty(i, Kpid.size), five);
      final st = h.getStream(i)!;
      expect(st.length, five);
      final b = Uint8List(4);
      st.position = 4608 << 20;
      readFully(st, b, 0, 4);
      expect(String.fromCharCodes(b), 'HUGE');
      st.position = five - 4;
      readFully(st, b, 0, 4);
      expect(String.fromCharCodes(b), 'TAIL');
      st.position = 3 << 30;
      readFully(st, b, 0, 4);
      expect(b, [0, 0, 0, 0]);
      s.raf.closeSync();
      File(img).deleteSync();
    }, skip: _mke2fs == null ? 'e2fsprogs missing' : false);
  }

  test('not ext: random data, a truncated superblock', () {
    expect(isArcExt(randomData(4096, 1), 4096), 0);
    expect(isArcExt(Uint8List(100), 100), 2);
    expect(ExtHandler().open(MemoryInStream(Uint8List(8192))), isFalse);
  });
}
