// Tests of the 7z handler (lib/src/format/sevenz) against the system 7z
// (7-Zip 23.01 at /usr/bin/7z): reading its archives, writing archives it
// accepts, byte exact rewrites with the same settings, updates.

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/common/method_props.dart';
import 'package:zx/src/format/handler_out.dart';
import 'package:zx/src/format/sevenz/sevenz.dart';
import 'package:zx/src/io/streams.dart';

const sevenZ = '/usr/bin/7z';
final bool have7z = File(sevenZ).existsSync();

late Directory tmp;
late Directory src;

ProcessResult run7z(List<String> args, {String? cwd}) {
  final r = Process.runSync(sevenZ, ['-bd', ...args],
      workingDirectory: cwd ?? tmp.path);
  return r;
}

void expect7zOk(List<String> args, {String? cwd}) {
  final r = run7z(args, cwd: cwd);
  expect(r.exitCode, 0, reason: '7z ${args.join(' ')}\n${r.stdout}${r.stderr}');
}

Uint8List pseudoRandom(int n, int seed) {
  final rnd = Random(seed);
  final b = Uint8List(n);
  for (var i = 0; i < n; i++) {
    b[i] = rnd.nextInt(256);
  }
  return b;
}

Uint8List textData(int lines) {
  final sb = StringBuffer();
  for (var i = 0; i < lines; i++) {
    sb.writeln('line $i: the quick brown fox ${i * 7919 % 1000}');
  }
  return Uint8List.fromList(sb.toString().codeUnits);
}

Uint8List wavData() {
  const n = 3000;
  final data = ByteData(n * 4);
  for (var i = 0; i < n; i++) {
    data.setInt16(i * 4, (3000 * sin(i / 10)).round(), Endian.little);
    data.setInt16(i * 4 + 2, (3000 * cos(i / 7)).round(), Endian.little);
  }
  final h = ByteData(44);
  void s(int o, String t) {
    for (var k = 0; k < 4; k++) {
      h.setUint8(o + k, t.codeUnitAt(k));
    }
  }

  s(0, 'RIFF');
  h.setUint32(4, 36 + n * 4, Endian.little);
  s(8, 'WAVE');
  s(12, 'fmt ');
  h.setUint32(16, 16, Endian.little);
  h.setUint16(20, 1, Endian.little);
  h.setUint16(22, 2, Endian.little);
  h.setUint32(24, 44100, Endian.little);
  h.setUint32(28, 44100 * 4, Endian.little);
  h.setUint16(32, 4, Endian.little);
  h.setUint16(34, 16, Endian.little);
  s(36, 'data');
  h.setUint32(40, n * 4, Endian.little);
  return Uint8List.fromList(
      [...h.buffer.asUint8List(), ...data.buffer.asUint8List()]);
}

void makeTree(Directory d) {
  File('${d.path}/a.txt').writeAsStringSync('hello\n');
  Directory('${d.path}/dir/sub').createSync(recursive: true);
  Directory('${d.path}/emptydir').createSync();
  File('${d.path}/dir/b.bin').writeAsBytesSync(pseudoRandom(40000, 1));
  File('${d.path}/dir/nums.txt').writeAsBytesSync(textData(3000));
  File('${d.path}/empty.txt').writeAsBytesSync([]);
  File('${d.path}/dir/sub/ünïcødé €.txt').writeAsStringSync('unicode\n');
  File('${d.path}/snd.wav').writeAsBytesSync(wavData());
  // A small ELF executable for the BCJ / BCJ2 analysis.
  final exe = File('/usr/bin/true');
  if (exe.existsSync()) {
    exe.copySync('${d.path}/true');
    Process.runSync('chmod', ['755', '${d.path}/true']);
  }
  Link('${d.path}/link').createSync('a.txt');
}

/// Lists [dir] as new update items (like 7-Zip's scan, with POSIX modes in
/// the high attribute bits).
List<SevenZipUpdateItem> itemsFromDir(Directory dir) {
  final items = <SevenZipUpdateItem>[];
  for (final f in dir.listSync(recursive: true, followLinks: false)) {
    final rel = f.path.substring(dir.path.length + 1);
    final st = f.statSync();
    final mt = dateTimeToFileTime(st.modified);
    final type = FileSystemEntity.typeSync(f.path, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      items.add(SevenZipUpdateItem.dir(
          path: rel,
          mTime: mt,
          attrib: 0x10 | 0x8000 | ((0x4000 | (st.mode & 0xFFF)) << 16)));
    } else if (type == FileSystemEntityType.link) {
      final data = Uint8List.fromList(Link(f.path).targetSync().codeUnits);
      items.add(SevenZipUpdateItem.file(
          path: rel,
          size: data.length,
          mTime: mt,
          attrib: 0x20 | 0x8000 | ((0xA000 | 0x1FF) << 16),
          open: () => MemoryInStream(data)));
    } else {
      items.add(SevenZipUpdateItem.file(
          path: rel,
          size: st.size,
          mTime: mt,
          attrib: 0x20 | 0x8000 | ((0x8000 | (st.mode & 0xFFF)) << 16),
          open: () => FileInStream.open(f.path)));
    }
  }
  return items;
}

SevenZipReader openArc(String path, {String? password}) =>
    SevenZipReader.open(FileInStream.open(path), password: password);

void closeArc(SevenZipReader r) => (r.stream as FileInStream).close();

void writeArc(String path, List<SevenZipUpdateItem> items,
    {List<String> opts = const [], String? password, SevenZipReader? old}) {
  final tmpPath = '$path.tmp';
  final out = FileOutStream.create(tmpPath);
  try {
    SevenZipWriter.update(
        old: old,
        out: out,
        items: items,
        options: CompressionOptions.parse(opts),
        password: password);
  } finally {
    out.close();
  }
  File(tmpPath).renameSync(path);
}

/// Re-creates archive [inPath] from its entries as new items with [opts].
void rewrite(String inPath, String outPath, List<String> opts) {
  final r = openArc(inPath);
  try {
    final items = <SevenZipUpdateItem>[];
    for (final e in r.entries) {
      if (e.isDir) {
        items.add(SevenZipUpdateItem.dir(
            path: e.path,
            attrib: e.attrib,
            mTime: e.mTime,
            cTime: e.cTime,
            aTime: e.aTime));
      } else {
        items.add(SevenZipUpdateItem.file(
            path: e.path,
            size: e.size,
            attrib: e.attrib,
            mTime: e.mTime,
            cTime: e.cTime,
            aTime: e.aTime,
            open: () => MemoryInStream(r.readItem(e.index))));
      }
    }
    writeArc(outPath, items, opts: opts);
  } finally {
    closeArc(r);
  }
}

/// Compares the file contents of two trees (symlinks by target).
void expectSameTree(String a, String b) {
  final r = Process.runSync('diff', ['-r', '--no-dereference', a, b]);
  expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
}

void main() {
  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('zx_sevenz_test');
    src = Directory('${tmp.path}/src')..createSync();
    makeTree(src);
  });
  tearDownAll(() => tmp.deleteSync(recursive: true));

  group('properties', () {
    test('method strings (MethodProps.cpp)', () {
      final m = OneMethodInfo()
        ..parseMethodFromString('LZMA2:d=64m:fb=64:mf=bt3');
      expect(m.methodName, 'LZMA2');
      expect(m.getDicSize(), 64 << 20);
      expect(m.props[1].id, CoderPropId.numFastBytes);
      expect(m.props[1].value.intValue, 64);
      expect(m.props[2].value.stringValue, 'bt3');
      final d = OneMethodInfo()..parseMethodFromString('Delta:4');
      expect(d.props.single.id, CoderPropId.defaultProp);
      final l = OneMethodInfo()..parseMethodFromString('LZMA:d24:lc0');
      expect(l.getLzmaDicSize(), 1 << 24);
      expect(() => OneMethodInfo().parseMethodFromString('LZMA:zz=1'),
          throwsA(isA<InvalidArgException>()));
    });

    test('-m switches (7zHandlerOut.cpp)', () {
      final h = SevenZipHandler();
      h.setPropertiesFromStrings(const [
        MapEntry('x', '9'),
        MapEntry('0', 'PPMd:o=8'),
        MapEntry('s', '100f10m'),
        MapEntry('hc', 'off'),
        MapEntry('he', ''),
        MapEntry('tc', 'on'),
        MapEntry('mt', '2'),
        MapEntry('qs', ''),
        MapEntry('yx', '7'),
      ]);
      expect(h.getLevel(), 9);
      expect(h.methods.single.methodName, 'PPMd');
      expect(h.numSolidFiles, 100);
      expect(h.numSolidBytes, 10 << 20);
      expect(h.compressHeaders, isFalse);
      expect(h.encryptHeaders, isTrue);
      expect(h.timeOptions.writeCTime.val, isTrue);
      expect(h.numThreads, 2);
      expect(h.useTypeSorting, isTrue);
      expect(h.getAnalysisLevel(), 7);
      h.setPropertiesFromStrings(const [MapEntry('s', 'off')]);
      expect(h.numSolidFiles, 1);
      h.setPropertiesFromStrings(const [MapEntry('tm-', '')]);
      expect(h.timeOptions.writeMTime.def, isTrue);
      expect(h.timeOptions.writeMTime.val, isFalse);
      expect(() => h.setPropertiesFromStrings(const [MapEntry('s', 'zz')]),
          throwsA(isA<InvalidArgException>()));
      expect(parseSizeString('', const PropVariant.bstr('50%'), 1000), 500);
    });

    test('Get_Xz_BlockSize compares block sizes unsigned', () {
      // -ms=on sets kBlockSize2 to (UInt64)(Int64)-1 (solid); a smaller
      // chunk size "c" must win, as in the C code's UInt64 compare.
      final m = OneMethodInfo()..parseMethodFromString('LZMA2:c=16m');
      m.props.add(CoderProp(CoderPropId.blockSize2, const PropVariant.ui8(-1)));
      expect(m.getXzBlockSize(), 16 << 20);
      final m2 = OneMethodInfo()
        ..props.add(
            CoderProp(CoderPropId.blockSize2, const PropVariant.ui8(-1)));
      expect(m2.getXzBlockSize(), -1);
      final m3 = OneMethodInfo()..parseMethodFromString('LZMA2:c=16m:b=4m');
      expect(m3.getXzBlockSize(), 4 << 20);
    });
  });

  group('read archives written by 7z', skip: !have7z, () {
    test('Copy, plain header', () {
      expect7zOk(['a', '-m0=Copy', '-mhc=off', 'copy.7z', './src/*']);
      final r = openArc('${tmp.path}/copy.7z');
      try {
        expect(r.isSolid, isFalse);
        expect(r.getArchiveProperty(Kpid.method), 'Copy Delta BCJ');
        final byName = {for (final e in r.entries) e.path: e};
        expect(byName['dir']!.isDir, isTrue);
        expect(byName['emptydir']!.isDir, isTrue);
        expect(byName['empty.txt']!.size, 0);
        expect(byName['empty.txt']!.isDir, isFalse);
        expect(byName['dir/sub/ünïcødé €.txt'], isNotNull);
        expect(byName['a.txt']!.posixMode! & 0xF000, 0x8000);
        expect(byName['dir']!.posixMode! & 0xF000, 0x4000);
        expect(byName['a.txt']!.mTime, isNotNull);
        expect(byName['a.txt']!.crc, isNotNull);
        expect(r.readItem(byName['dir/b.bin']!.index),
            File('${src.path}/dir/b.bin').readAsBytesSync());
        expect(r.test().every((x) => x.ok), isTrue);
      } finally {
        closeArc(r);
      }
    });

    test('default LZMA2, solid, symlinks (-snl)', () {
      expect7zOk(['a', '-snl', 'def.7z', './src/*']);
      final r = openArc('${tmp.path}/def.7z');
      try {
        expect(r.isSolid, isTrue);
        final link = r.entries.firstWhere((e) => e.path == 'link');
        expect(link.isSymlink, isTrue);
        expect(String.fromCharCodes(r.readItem(link.index)), 'a.txt');
        // Extract everything and compare with the source tree.
        final outDir = Directory('${tmp.path}/x_def')..createSync();
        OutStream? cur;
        r.extract(null, open: (e) {
          final p = '${outDir.path}/${e.path}';
          if (e.isDir) {
            Directory(p).createSync(recursive: true);
            return null;
          }
          File(p).parent.createSync(recursive: true);
          return cur = e.isSymlink ? _LinkSink(p) : FileOutStream.create(p);
        }, done: (e, res) {
          expect(res, OperationResult.ok);
          final c = cur;
          if (c is FileOutStream) c.close();
          if (c is _LinkSink) c.flush();
          if (!e.isDir && c == null) {
            // empty files get no data but must exist
            File('${outDir.path}/${e.path}').createSync(recursive: true);
          }
          cur = null;
        });
        expectSameTree(src.path, outDir.path);
      } finally {
        closeArc(r);
      }
    });

    test('solid and non solid, test mode, partial extraction', () {
      expect7zOk(['a', '-mx9', 'x9.7z', './src/*']);
      expect7zOk(['a', '-ms=off', 'ns.7z', './src/*']);
      expect7zOk(['a', '-m0=PPMd', 'ppmd.7z', './src/*']);
      for (final name in ['x9.7z', 'ns.7z', 'ppmd.7z']) {
        final r = openArc('${tmp.path}/$name');
        try {
          expect(r.test().every((x) => x.ok), isTrue, reason: name);
          for (final e in r.entries.where((e) => !e.isDir && e.size > 0)) {
            final p = '${src.path}/${e.path}';
            if (FileSystemEntity.isLinkSync(p)) continue;
            expect(r.readItem(e.index), File(p).readAsBytesSync(),
                reason: '$name ${e.path}');
          }
        } finally {
          closeArc(r);
        }
      }
    });

    test('AES and encrypted headers', () {
      expect7zOk(['a', '-psecret', 'aes.7z', './src/*']);
      expect7zOk(['a', '-psecret', '-mhe=on', 'aeshe.7z', './src/*']);
      for (final name in ['aes.7z', 'aeshe.7z']) {
        final r = openArc('${tmp.path}/$name', password: 'secret');
        try {
          expect(r.entries.where((e) => e.size > 0).every((e) => e.encrypted),
              isTrue);
          expect(r.test().every((x) => x.ok), isTrue, reason: name);
        } finally {
          closeArc(r);
        }
      }
      final bad = openArc('${tmp.path}/aes.7z', password: 'wrong');
      try {
        final res = bad.test();
        expect(res.where((x) => !x.ok), isNotEmpty);
        expect(res.where((x) => !x.ok).every((x) => x.possiblyWrongPassword),
            isTrue);
      } finally {
        closeArc(bad);
      }
      expect(
          () => openArc('${tmp.path}/aeshe.7z', password: 'wrong'),
          throwsA(isA<SevenZipException>()
              .having((e) => e.kind, 'kind', SevenZipError.wrongPassword)));
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('write archives', skip: !have7z, () {
    void checkWith7z(String name, {String? password}) {
      final pw = password == null ? <String>[] : ['-p$password'];
      expect7zOk(['t', ...pw, name]);
      final outDir = '${tmp.path}/x_$name';
      Directory(outDir).createSync();
      expect7zOk(['x', '-y', ...pw, '-o$outDir', name]);
      expectSameTree(src.path, outDir);
    }

    test('Copy with a plain header', () {
      writeArc('${tmp.path}/w_copy.7z', itemsFromDir(src),
          opts: ['0=Copy', 'hc=off']);
      checkWith7z('w_copy.7z');
    });

    test('defaults (LZMA2, BCJ for exe, Delta for wav)', () {
      writeArc('${tmp.path}/w_def.7z', itemsFromDir(src));
      checkWith7z('w_def.7z');
      final r = run7z(['l', '-slt', 'w_def.7z']);
      expect(r.stdout as String, contains('BCJ'));
      expect(r.stdout as String, contains('Delta:4'));
    });

    test('-mx9 (BCJ2), PPMd, non solid', () {
      writeArc('${tmp.path}/w_x9.7z', itemsFromDir(src), opts: ['x=9']);
      checkWith7z('w_x9.7z');
      writeArc('${tmp.path}/w_ppmd.7z', itemsFromDir(src),
          opts: ['0=PPMd:o=6:mem=16m', 's=off']);
      checkWith7z('w_ppmd.7z');
    });

    test('AES with and without encrypted headers', () {
      writeArc('${tmp.path}/w_aes.7z', itemsFromDir(src), password: 'pw1');
      checkWith7z('w_aes.7z', password: 'pw1');
      writeArc('${tmp.path}/w_aeshe.7z', itemsFromDir(src),
          password: 'pw2', opts: ['he=on']);
      checkWith7z('w_aeshe.7z', password: 'pw2');
      final r = run7z(['l', '-pwrong', 'w_aeshe.7z']);
      expect(r.exitCode, isNot(0));
    });

    test('anti items and empty archives', () {
      writeArc('${tmp.path}/w_anti.7z', [
        const SevenZipUpdateItem.anti(path: 'gone.txt'),
        const SevenZipUpdateItem.anti(path: 'olddir', isDir: true),
        SevenZipUpdateItem.file(
            path: 'x.txt',
            size: 3,
            open: () => MemoryInStream(Uint8List.fromList([1, 2, 3]))),
      ]);
      expect7zOk(['t', 'w_anti.7z']);
      final r = openArc('${tmp.path}/w_anti.7z');
      try {
        final anti = r.entries.where((e) => e.isAnti).map((e) => e.path);
        expect(anti, containsAll(['gone.txt', 'olddir']));
      } finally {
        closeArc(r);
      }
      writeArc('${tmp.path}/w_empty.7z', const []);
      expect7zOk(['t', 'w_empty.7z']);
      expect(openArc('${tmp.path}/w_empty.7z').length, 0);
    });
  });

  group('byte exact with 7z', skip: !have7z, () {
    // 7z writes an archive, we rewrite it from its entries with the same
    // settings: the files must be identical.
    for (final opts in [
      ['0=Copy', 'hc=off'],
      <String>[],
      ['s=off'],
      ['x=9'],
      ['x=1'],
      ['0=PPMd'],
      ['0=LZMA'],
      ['f=BCJ2'],
      ['s=e', 'qs'],
      ['tc', 'ta'],
    ]) {
      test(opts.join(' '), () {
        final name = 'bx_${opts.join('_').replaceAll('=', '')}.7z';
        expect7zOk(['a', ...opts.map((o) => '-m$o'), name, './src/*']);
        rewrite('${tmp.path}/$name', '${tmp.path}/rw_$name', opts);
        expect(File('${tmp.path}/rw_$name').readAsBytesSync(),
            File('${tmp.path}/$name').readAsBytesSync());
      });
    }
  });

  group('update', skip: !have7z, () {
    test('delete matches 7z d (copy and repack)', () {
      for (final opts in [
        <String>[],
        ['s=off'],
        ['x=9'],
        ['f=BCJ2'],
        ['0=PPMd'],
      ]) {
        final base = 'upd_${opts.join('_').replaceAll('=', '')}.7z';
        expect7zOk(['a', ...opts.map((o) => '-m$o'), base, './src/*']);
        File('${tmp.path}/$base').copySync('${tmp.path}/d_$base');
        expect7zOk(
            ['d', ...opts.map((o) => '-m$o'), 'd_$base', 'dir/nums.txt']);
        final r = openArc('${tmp.path}/$base');
        try {
          writeArc(
              '${tmp.path}/o_$base',
              [
                for (final e in r.entries)
                  if (e.path != 'dir/nums.txt') SevenZipUpdateItem.keep(e.index)
              ],
              opts: opts,
              old: r);
        } finally {
          closeArc(r);
        }
        expect(File('${tmp.path}/o_$base').readAsBytesSync(),
            File('${tmp.path}/d_$base').readAsBytesSync(),
            reason: opts.join(' '));
      }
    });

    test('add, rename, and 7z updates our archive', () {
      expect7zOk(['a', 'u.7z', './src/*']);
      final r = openArc('${tmp.path}/u.7z');
      try {
        final a = r.entries.firstWhere((e) => e.path == 'a.txt');
        writeArc(
            '${tmp.path}/u2.7z',
            [
              for (final e in r.entries)
                if (e.path == 'a.txt')
                  SevenZipUpdateItem.newProps(e.index,
                      path: 'renamed.txt', attrib: a.attrib, mTime: a.mTime)
                else
                  SevenZipUpdateItem.keep(e.index),
              SevenZipUpdateItem.file(
                  path: 'new/added.txt',
                  size: 5,
                  open: () =>
                      MemoryInStream(Uint8List.fromList('added'.codeUnits))),
            ],
            old: r);
      } finally {
        closeArc(r);
      }
      expect7zOk(['t', 'u2.7z']);
      final l = run7z(['l', 'u2.7z']).stdout as String;
      expect(l, contains('renamed.txt'));
      expect(l, contains('new/added.txt'));
      expect7zOk(['d', 'u2.7z', 'dir/b.bin']);
      final r2 = openArc('${tmp.path}/u2.7z');
      try {
        expect(r2.test().every((x) => x.ok), isTrue);
        final added = r2.entries.firstWhere((e) => e.path == 'new/added.txt');
        expect(String.fromCharCodes(r2.readItem(added.index)), 'added');
      } finally {
        closeArc(r2);
      }
    });
  });

  test('not an archive', () {
    expect(
        () => SevenZipReader.open(MemoryInStream(Uint8List(100))),
        throwsA(isA<SevenZipException>()
            .having((e) => e.kind, 'kind', SevenZipError.isNotArc)));
  });
}

class _LinkSink implements OutStream {
  final String path;
  final BytesBuilder _b = BytesBuilder();
  _LinkSink(this.path);
  @override
  void write(Uint8List buf, int off, int len) =>
      _b.add(Uint8List.sublistView(buf, off, off + len));
  @override
  void flush() => Link(path).createSync(String.fromCharCodes(_b.toBytes()));
}
