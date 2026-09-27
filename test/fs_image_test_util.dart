// Shared helpers of the file system image tests (squashfs, cramfs,
// jffs2): the image tools (also in /usr/sbin and ref/tools/root/usr/sbin),
// a source tree with the usual corner cases, ls style mode strings, the
// `7z l -slt` parser and a tree comparison with diff.

import 'dart:io';
import 'dart:typed_data';

import 'package:zx/src/format/archive_types.dart';
import 'package:zx/src/format/item_streams.dart';
import 'package:zx/src/io/streams.dart';

import 'codec_test_util.dart';

/// Path of [name] on PATH, in the sbin folders or in
/// ref/tools/root/usr/{bin,sbin}; null when missing.
String? findFsTool(String name) {
  final t = findTool(name);
  if (t != null) return t;
  for (final dir in ['/usr/sbin', '/sbin', 'ref/tools/root/usr/sbin']) {
    final f = File('$dir/$name');
    if (f.existsSync()) return f.absolute.path;
  }
  return null;
}

/// Makes the test tree in [src]: small, big (with a fragment tail),
/// block aligned, sparse and empty files, symlinks (one dangling), a hard
/// link, deep folders, unicode names and a folder of many small files.
void makeFsTree(String src,
    {bool sparse = true, bool hardLink = true, int many = 300}) {
  Directory('$src/d').createSync(recursive: true);
  File('$src/a.txt').writeAsStringSync('hello\n');
  File('$src/big.bin').writeAsBytesSync(genData(700001, 1));
  File('$src/aligned.bin').writeAsBytesSync(genData(262144, 2));
  File('$src/empty').writeAsBytesSync([]);
  if (sparse) {
    final f = File('$src/sparse').openSync(mode: FileMode.write);
    f.setPositionSync(600000);
    f.writeFromSync([1, 2, 3]);
    f.truncateSync(1 << 20);
    f.closeSync();
  }
  Link('$src/lnk').createSync('a.txt');
  Link('$src/d/dangling').createSync('../nowhere');
  if (hardLink) Process.runSync('ln', ['$src/a.txt', '$src/d/hard']);
  var deep = '$src/deep';
  for (var i = 1; i <= 20; i++) {
    deep = '$deep/l$i';
  }
  Directory(deep).createSync(recursive: true);
  File('$deep/f.txt').writeAsStringSync('deep\n');
  Directory('$src/\u00fcn\u00ef').createSync();
  File('$src/\u00fcn\u00ef/\u540d\u524d.txt').writeAsStringSync('unicode\n');
  if (many > 0) {
    Directory('$src/many').createSync();
    for (var i = 0; i < many; i++) {
      File('$src/many/file_${i.toString().padLeft(4, '0')}')
          .writeAsStringSync('$i\n' * (i % 7));
    }
  }
}

/// `ls -l` style mode string of st_mode [m].
String modeString(int m) {
  const types = {
    0x4000: 'd',
    0x8000: '-',
    0xA000: 'l',
    0x2000: 'c',
    0x6000: 'b',
    0x1000: 'p',
    0xC000: 's',
  };
  final b = StringBuffer(types[m & 0xF000] ?? '?');
  const rwx = 'rwxrwxrwx';
  for (var i = 0; i < 9; i++) {
    b.write((m & (0x100 >> i)) != 0 ? rwx[i] : '-');
  }
  var s = b.toString();
  String setAt(String s, int i, String c) =>
      s.substring(0, i) + c + s.substring(i + 1);
  if ((m & 0x800) != 0) s = setAt(s, 3, s[3] == 'x' ? 's' : 'S');
  if ((m & 0x400) != 0) s = setAt(s, 6, s[6] == 'x' ? 's' : 'S');
  if ((m & 0x200) != 0) s = setAt(s, 9, s[9] == 'x' ? 't' : 'T');
  return s;
}

/// `7z l -slt` items: path to its properties.
Map<String, Map<String, String>> sevenZipSlt(String archive) {
  final r = Process.runSync('7z', ['l', '-slt', archive]);
  final out = r.stdout as String;
  final i = out.indexOf('\n----------\n');
  final res = <String, Map<String, String>>{};
  if (i < 0) return res;
  Map<String, String>? cur;
  for (final line in out.substring(i + 12).split('\n')) {
    final k = line.indexOf(' = ');
    if (k < 0) {
      if (line.endsWith(' =') && cur != null) {
        cur[line.substring(0, line.length - 2)] = '';
      }
      continue;
    }
    final key = line.substring(0, k);
    final val = line.substring(k + 3);
    if (key == 'Path') {
      cur = res[val] = {};
    } else {
      cur?[key] = val;
    }
  }
  return res;
}

/// Our items as path to (mode, size) for the comparison with 7z.
Map<String, String> handlerSummary(ReadOnlyHandler h) => {
      for (var i = 0; i < h.numberOfItems; i++)
        h.getProperty(i, Kpid.path) as String:
            '${modeString(h.getProperty(i, Kpid.posixAttrib) as int)} '
                '${h.getProperty(i, Kpid.isDir) == true ? '' : h.getProperty(i, Kpid.size)}'
    };

/// The same from `7z l -slt`.
Map<String, String> sevenZipSummary(String archive) => {
      for (final e in sevenZipSlt(archive).entries)
        e.key: '${e.value['Mode']} ${e.value['Size']}'
    };

/// Runs diff -r on two trees; returns its output, empty when equal.
String diffTrees(String a, String b) {
  final r = Process.runSync('diff', ['-r', '--no-dereference', a, b]);
  return r.exitCode == 0 ? '' : '${r.stdout}${r.stderr}';
}

/// Reads all data of [s].
Uint8List readStream(SeekableInStream s) {
  final out = BytesBuilder(copy: false);
  final buf = Uint8List(1 << 16);
  for (;;) {
    final n = s.read(buf, 0, buf.length);
    if (n == 0) break;
    out.add(Uint8List.fromList(Uint8List.sublistView(buf, 0, n)));
  }
  return out.toBytes();
}
