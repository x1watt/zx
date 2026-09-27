// ISO 9660 images made by xorriso and genisoimage at test time (skipped when
// the tools are missing): Rock Ridge (modes, symbolic links, long names,
// relocated deep directories, zisofs), Joliet, plain level 1 names, El
// Torito boot images, a multi-extent file, a two session image, raw 2352
// byte sector images and detection with wrong or no extension. Extracted
// trees are compared with the source tree, listings and extracted data with
// the system 7z (black box).

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/format/iso/iso_handler.dart';
import 'package:zx/zx.dart';

import 'codec_test_util.dart';

/// For every entry below [dir]: "d MODE", "l TARGET" or "f MODE SIZE HASH".
Map<String, String> treeOf(String dir, {bool modes = true}) {
  final out = <String, String>{};
  final base = Directory(dir).absolute.path;
  for (final e
      in Directory(base).listSync(recursive: true, followLinks: false)) {
    final rel = e.path.substring(base.length + 1);
    final st = e.statSync();
    if (e is Link) {
      out[rel] = 'l ${e.targetSync()}';
    } else if (e is Directory) {
      out[rel] = modes ? 'd ${(st.mode & 0xFFF).toRadixString(8)}' : 'd';
    } else {
      final b = File(e.path).readAsBytesSync();
      final m = modes ? '${(st.mode & 0xFFF).toRadixString(8)} ' : '';
      out[rel] = 'f $m${b.length} ${_sum(b)}';
    }
  }
  return out;
}

int _sum(Uint8List b) {
  var h = 0;
  for (final x in b) {
    h = (h * 31 + x) & 0x3FFFFFFF;
  }
  return h;
}

/// (path, isDir, size) of `7z l -slt`, sorted.
List<String> sevenZipList(String sevenZ, String arc,
    [List<String> sw = const []]) {
  final r = Process.runSync(sevenZ, ['l', '-slt', ...sw, arc]);
  final lines = (r.stdout as String).split('\n');
  final out = <String>[];
  var inItems = false;
  String? path;
  String? folder;
  for (final l in lines) {
    if (l.startsWith('----------')) {
      inItems = true;
      continue;
    }
    if (!inItems) continue;
    if (l.startsWith('Path = ')) path = l.substring(7);
    if (l.startsWith('Folder = ')) folder = l.substring(9);
    if (l.startsWith('Size = ') && path != null) {
      out.add('$path|${folder == '+'}|${folder == '+' ? '' : l.substring(7)}');
      path = null;
    }
  }
  out.sort();
  return out;
}

List<String> zxList(ZxArchive z) {
  final out = <String>[
    for (final it in z.items)
      if (!it.isImplied)
        '${it.path}|${it.isDir}|${it.isDir ? '' : (it.size ?? '')}'
  ];
  out.sort();
  return out;
}

void main() {
  final xorriso = findTool('xorriso');
  final geniso = findTool('genisoimage');
  final mkzftree = findTool('mkzftree');
  final sevenZ = findTool('7z');
  late Directory tmp;
  late String src;

  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('zx_iso_test');
    src = '${tmp.path}/src';
    Directory('$src/a/b/c/d/e/f/g/h/i/j').createSync(recursive: true);
    Directory('$src/emptydir').createSync();
    File('$src/hello.txt').writeAsStringSync('hello\n');
    File('$src/a/rand.bin').writeAsBytesSync(genData(300000, 7));
    File('$src/a/b/c/d/e/f/g/h/i/j/deep.txt').writeAsStringSync('deep\n');
    File('$src/a very long file name with spaces and more than sixty four '
            'characters in it ok.txt')
        .writeAsStringSync('long\n');
    File('$src/\u00fcn\u00efc\u00f6d\u00e9 \u00f1ame.txt').writeAsStringSync('unicode\n');
    File('$src/a/b/seq.txt')
        .writeAsStringSync([for (var i = 0; i < 20000; i++) '$i\n'].join());
    File('$src/zeros.bin').writeAsBytesSync(Uint8List(70000));
    Link('$src/a/link').createSync('../hello.txt');
    Process.runSync('chmod', ['750', '$src/a/b']);
    Process.runSync('chmod', ['755', '$src/hello.txt']);
    Process.runSync('chmod', ['600', '$src/zeros.bin']);
  });

  tearDownAll(() => tmp.deleteSync(recursive: true));

  String run(String tool, List<String> args) {
    final r = Process.runSync(tool, args);
    if (r.exitCode != 0) {
      throw StateError('$tool ${args.join(' ')}: ${r.stderr}');
    }
    return r.stdout as String;
  }

  Future<Map<String, String>> extractTree(String arc, String out,
      {bool modes = true}) async {
    final z = await ZxArchive.open(arc);
    final r = await z.extract(out);
    expect(r.ok, isTrue, reason: '$arc: $r');
    return treeOf(out, modes: modes);
  }

  test('Rock Ridge and Joliet (xorriso): tree, modes, links', () async {
    final iso = '${tmp.path}/rr.iso';
    run(xorriso!, [
      '-as',
      'mkisofs',
      '-quiet',
      '-R',
      '-J',
      '-V',
      'MYVOL',
      '-o',
      iso,
      src
    ]);
    final z = await ZxArchive.open(iso);
    expect(z.format, 'Iso');
    final link = z.items.firstWhere((i) => i.path == 'a/link');
    expect(link.symlinkTarget, '../hello.txt');
    expect(link.posixMode! & 0xF000, 0xA000);
    final dir = z.items.firstWhere((i) => i.path == 'a/b');
    expect(dir.posixMode, 0x4000 | 0x1E8);
    expect(await extractTree(iso, '${tmp.path}/rr_out'), treeOf(src));
    // the archive properties
    final h = IsoHandler();
    final s = FileInStream.open(iso);
    expect(h.open(s), isTrue);
    expect(h.getArchiveProperty(Kpid.volumeName), 'MYVOL');
    expect(h.getArchiveProperty(Kpid.fileSystem), contains('RockRidge'));
    expect(h.getArchiveProperty(Kpid.phySize), File(iso).lengthSync());
    s.close();
  }, skip: xorriso == null ? 'xorriso missing' : false);

  test('Joliet only (genisoimage): listing and data equal 7z', () async {
    final iso = '${tmp.path}/j.iso';
    run(geniso!, ['-quiet', '-J', '-joliet-long', '-o', iso, src]);
    final z = await ZxArchive.open(iso);
    expect(z.format, 'Iso');
    expect(zxList(z), sevenZipList(sevenZ!, iso));
    final out7 = '${tmp.path}/j_7z';
    run(sevenZ, ['x', '-o$out7', iso]);
    expect(await extractTree(iso, '${tmp.path}/j_zx', modes: false),
        treeOf(out7, modes: false));
  },
      skip: geniso == null || sevenZ == null
          ? 'genisoimage or 7z missing'
          : false);

  test('plain level 1 names (genisoimage): listing equals 7z', () async {
    final iso = '${tmp.path}/plain.iso';
    final p = '${tmp.path}/plainsrc';
    Directory('$p/sub').createSync(recursive: true);
    File('$p/sub/Mixed.Case.txt').writeAsStringSync('a\n');
    File('$p/file_with_long_name.dat').writeAsStringSync('b\n');
    File('$p/hideme.txt').writeAsStringSync('c\n');
    run(geniso!, ['-quiet', '-hidden', 'hideme.txt', '-o', iso, p]);
    final z = await ZxArchive.open(iso);
    expect(zxList(z), sevenZipList(sevenZ!, iso));
    final hidden = z.items.firstWhere((i) => i.path.startsWith('HIDEME'));
    expect(hidden.attrib! & FileAttrib.hidden, FileAttrib.hidden);
  },
      skip: geniso == null || sevenZ == null
          ? 'genisoimage or 7z missing'
          : false);

  test('Rock Ridge relocated deep directories (rr_moved)', () async {
    final iso = '${tmp.path}/deep.iso';
    final d = '${tmp.path}/deepsrc';
    Directory('$d/1/2/3/4/5/6/7/8/9/10/11').createSync(recursive: true);
    File('$d/1/2/3/4/5/6/7/8/9/10/11/f.txt').writeAsStringSync('x\n');
    File('$d/top.txt').writeAsStringSync('top\n');
    run(geniso!, ['-quiet', '-R', '-o', iso, d]);
    final z = await ZxArchive.open(iso);
    expect(
        z.items.any((i) => i.path.toLowerCase().contains('rr_moved')), isFalse);
    expect(await extractTree(iso, '${tmp.path}/deep_out'), treeOf(d));
  }, skip: geniso == null ? 'genisoimage missing' : false);

  test('zisofs (mkzftree + genisoimage -z)', () async {
    final zsrc = '${tmp.path}/zsrc';
    run(mkzftree!, [src, zsrc]);
    final iso = '${tmp.path}/z.iso';
    run(geniso!, ['-quiet', '-R', '-z', '-o', iso, zsrc]);
    final z = await ZxArchive.open(iso);
    final seq = z.items.firstWhere((i) => i.path == 'a/b/seq.txt');
    expect(seq.method, startsWith('zisofs'));
    expect(seq.packSize! < seq.size!, isTrue);
    expect(await extractTree(iso, '${tmp.path}/z_out'), treeOf(src));
  },
      skip: geniso == null || mkzftree == null
          ? 'genisoimage or mkzftree missing'
          : false);

  test('El Torito boot images as [BOOT] items, as 7z names them', () async {
    final e = '${tmp.path}/etsrc';
    Directory('$e/boot').createSync(recursive: true);
    File('$e/boot/boot.img').writeAsBytesSync(genData(6144, 3));
    File('$e/boot/floppy.img').writeAsBytesSync(genData(1474560, 4));
    final iso = '${tmp.path}/et.iso';
    run(xorriso!, [
      '-as',
      'mkisofs',
      '-quiet',
      '-R',
      '-J',
      '-b',
      'boot/boot.img',
      '-no-emul-boot',
      '-boot-load-size',
      '4',
      '-eltorito-alt-boot',
      '-b',
      'boot/floppy.img',
      '-o',
      iso,
      e
    ]);
    final z = await ZxArchive.open(iso);
    expect(zxList(z), sevenZipList(sevenZ!, iso));
    expect(z.items.map((i) => i.path),
        containsAll(['[BOOT]/1-Boot-NoEmul.img', '[BOOT]/2-Boot-1.44M.img']));
    final out7 = '${tmp.path}/et_7z';
    run(sevenZ, ['x', '-o$out7', iso]);
    expect(await extractTree(iso, '${tmp.path}/et_zx', modes: false),
        treeOf(out7, modes: false));
  }, skip: xorriso == null || sevenZ == null ? 'xorriso or 7z missing' : false);

  test('multi-extent file (two directory records joined)', () async {
    // two adjacent files, then their records patched into one file of two
    // extents: the first record gets the multi-extent flag, the second the
    // same name
    final m = '${tmp.path}/mesrc';
    Directory(m).createSync();
    File('$m/A').writeAsBytesSync(Uint8List(4096)..fillRange(0, 4096, 0x61));
    File('$m/B').writeAsBytesSync(Uint8List(3000)..fillRange(0, 3000, 0x62));
    final iso = '${tmp.path}/me.iso';
    run(geniso!, ['-quiet', '-o', iso, m]);
    final b = File(iso).readAsBytesSync();
    final root = (b[0x8000 + 158] | b[0x8000 + 159] << 8) * 2048;
    var p = root;
    int? recA, recB;
    while (b[p] != 0) {
      final nl = b[p + 32];
      final name = String.fromCharCodes(b, p + 33, p + 33 + nl);
      if (name == 'A.;1') recA = p;
      if (name == 'B.;1') recB = p;
      p += b[p];
    }
    b[recA! + 25] |= 0x80;
    b[recB! + 33] = 0x41;
    File(iso).writeAsBytesSync(b);
    final z = await ZxArchive.open(iso);
    expect(z.items.length, 1);
    expect(z.items.single.size, 7096);
    if (sevenZ != null) expect(zxList(z), sevenZipList(sevenZ, iso));
    final out = '${tmp.path}/me_out';
    expect((await z.extract(out)).ok, isTrue);
    final data = File('$out/A').readAsBytesSync();
    expect(data.sublist(0, 4096).every((x) => x == 0x61), isTrue);
    expect(data.sublist(4096).every((x) => x == 0x62), isTrue);
  }, skip: geniso == null ? 'genisoimage missing' : false);

  test('two sessions: the last one is read', () async {
    final s1 = '${tmp.path}/ms1', s2 = '${tmp.path}/ms2';
    Directory(s1).createSync();
    Directory(s2).createSync();
    File('$s1/one.txt').writeAsStringSync('one\n');
    File('$s2/two.txt').writeAsStringSync('two\n');
    final i1 = '${tmp.path}/s1.iso', i2 = '${tmp.path}/s2.iso';
    run(geniso!, ['-quiet', '-R', '-J', '-o', i1, s1]);
    final n = File(i1).lengthSync() ~/ 2048;
    run(geniso, ['-quiet', '-R', '-J', '-C', '0,$n', '-M', i1, '-o', i2, s2]);
    final ms = '${tmp.path}/ms.iso';
    File(ms).writeAsBytesSync(
        [...File(i1).readAsBytesSync(), ...File(i2).readAsBytesSync()]);
    final z = await ZxArchive.open(ms);
    expect(z.items.map((i) => i.path).toSet(), {'one.txt', 'two.txt'});
    final out = '${tmp.path}/ms_out';
    expect((await z.extract(out)).ok, isTrue);
    expect(File('$out/one.txt').readAsStringSync(), 'one\n');
    expect(File('$out/two.txt').readAsStringSync(), 'two\n');
  }, skip: geniso == null ? 'genisoimage missing' : false);

  test('raw 2352 byte sector images (mode 1 and mode 2 form 1)', () async {
    final iso = '${tmp.path}/raw_src.iso';
    run(geniso!, ['-quiet', '-R', '-J', '-o', iso, src]);
    final d = File(iso).readAsBytesSync();
    for (final mode in [1, 2]) {
      final out = BytesBuilder();
      for (var i = 0; i < d.length ~/ 2048; i++) {
        final sec = Uint8List(2352);
        for (var k = 1; k < 11; k++) {
          sec[k] = 0xFF;
        }
        sec[15] = mode;
        final off = mode == 1 ? 16 : 24;
        sec.setRange(off, off + 2048, d, i * 2048);
        out.add(sec);
      }
      final raw = '${tmp.path}/raw$mode.bin';
      File(raw).writeAsBytesSync(out.takeBytes());
      final z = await ZxArchive.open(raw);
      expect(z.format, 'Iso');
      expect(await extractTree(raw, '${tmp.path}/raw${mode}_out'), treeOf(src));
    }
  }, skip: geniso == null ? 'genisoimage missing' : false);

  test('detection with no or a wrong extension', () async {
    final iso = '${tmp.path}/det.iso';
    run(geniso!, ['-quiet', '-R', '-J', '-o', iso, src]);
    for (final name in ['det_noext', 'det.bin', 'det.zip', 'det.img']) {
      final p = '${tmp.path}/$name';
      File(iso).copySync(p);
      final z = await ZxArchive.open(p);
      expect(z.format, 'Iso', reason: name);
      expect((await z.test()).ok, isTrue, reason: name);
    }
  }, skip: geniso == null ? 'genisoimage missing' : false);

  test('ISO/UDF bridge disc: Udf for x.iso, Iso without extension (7-Zip)',
      () async {
    final iso = '${tmp.path}/bridge.iso';
    run(geniso!, ['-quiet', '-udf', '-J', '-R', '-o', iso, src]);
    expect((await ZxArchive.open(iso)).format, 'Udf');
    final p = '${tmp.path}/bridge_noext';
    File(iso).copySync(p);
    expect((await ZxArchive.open(p)).format, 'Iso');
    if (sevenZ != null) {
      String type(String f) =>
          (Process.runSync(sevenZ, ['l', f]).stdout as String)
              .split('\n')
              .firstWhere((l) => l.startsWith('Type = '));
      expect(type(iso), 'Type = Udf');
      expect(type(p), 'Type = Iso');
    }
  }, skip: geniso == null ? 'genisoimage missing' : false);

  test('not an ISO: a file of zeros is rejected', () {
    final h = IsoHandler();
    expect(h.open(MemoryInStream(Uint8List(0x10000))), isFalse);
    expect(isArcIso(Uint8List(0x10000), 0x10000), 0);
  });
}
