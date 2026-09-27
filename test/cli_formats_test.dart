// End to end tests of the command line tool with the formats other than 7z
// and xz: zip (and jar), tar, gzip, bzip2, the compound tar.gz, tgz,
// tar.bz2 and tar.xz, lzh, arj and rar. Archives made by zx are checked
// with the system tools (unzip, jar, tar, gzip, bzip2, xz, unrar) and the
// reference tools in ref/tools (lhasa, jlha, arj, rar); archives made by
// those tools are extracted by zx and compared with the source tree.
// Each test is skipped when its tool is missing.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/cli/main.dart';

class _Run {
  final int code;
  final String out;
  final String err;
  _Run(this.code, Uint8List outBytes, this.err)
      : out = utf8.decode(outBytes, allowMalformed: true);
}

Future<_Run> _zx(Directory dir, List<String> args) async {
  final out = BytesBuilder();
  final err = BytesBuilder();
  final code = await runSevenZipCli(args,
      stdout: out.add, stderr: err.add, workingDirectory: dir.path);
  return _Run(code, out.takeBytes(), utf8.decode(err.takeBytes()));
}

const String _toolRoot = 'ref/tools/root/usr';
final String _lhasa = File('$_toolRoot/bin/lhasa').absolute.path;
final String _arj = File('$_toolRoot/bin/arj').absolute.path;
final String _rar = File('$_toolRoot/bin/rar').absolute.path;
final String _javaHome =
    '${Platform.environment['HOME']}/.sdkman/candidates/java/current/bin';
final String _jar = '$_javaHome/jar';
final String _java = '$_javaHome/java';
final String _jlhaCp =
    '${File('$_toolRoot/share/java/jlha.jar').absolute.path}:'
    '${File('$_toolRoot/share/java/jlhafrontend.jar').absolute.path}';

bool _have(String path) => File(path).existsSync();

String? _which(String name) {
  for (final d in (Platform.environment['PATH'] ?? '').split(':')) {
    if (d.isEmpty) continue;
    final p = '$d/$name';
    if (File(p).existsSync()) return p;
  }
  return null;
}

bool get _haveJlha =>
    _have(_java) &&
    _have('$_toolRoot/share/java/jlha.jar') &&
    _have('$_toolRoot/share/java/jlhafrontend.jar');

ProcessResult _tool(String exe, List<String> args, Directory cwd,
        {Map<String, String>? env}) =>
    Process.runSync(exe, args, workingDirectory: cwd.path, environment: env);

ProcessResult _runLhasa(List<String> args, Directory cwd) =>
    _tool(_lhasa, args, cwd, env: {
      'LD_LIBRARY_PATH':
          Directory('$_toolRoot/lib/x86_64-linux-gnu').absolute.path
    });

void _makeTree(Directory root) {
  final src = Directory('${root.path}/src')..createSync();
  File('${src.path}/a.txt').writeAsStringSync('hello world\n');
  final bin = Uint8List(20000);
  var x = 12345;
  for (var i = 0; i < bin.length; i++) {
    x = (x * 1103515245 + 12345) & 0x7FFFFFFF;
    bin[i] = x >> 16;
  }
  File('${src.path}/bin.dat').writeAsBytesSync(bin);
  Directory('${src.path}/sub').createSync();
  File('${src.path}/sub/numbers.txt')
      .writeAsStringSync([for (var i = 1; i <= 5000; i++) '$i'].join('\n'));
  File('${root.path}/extra.txt').writeAsStringSync('extra file\n');
}

/// The regular files under [dir] by relative path.
Map<String, List<int>> _files(Directory dir) {
  final r = <String, List<int>>{};
  for (final e in dir.listSync(recursive: true, followLinks: false)) {
    if (e is File) {
      r[e.path.substring(dir.path.length + 1)] = e.readAsBytesSync();
    }
  }
  return r;
}

void _expectSameTree(Directory a, Directory b) {
  final fa = _files(a);
  final fb = _files(b);
  expect(fb.keys.toSet(), fa.keys.toSet());
  for (final k in fa.keys) {
    expect(fb[k], fa[k], reason: k);
  }
}

void main() {
  late Directory tmp;
  late Directory src;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('zx_fmt_');
    _makeTree(tmp);
    src = Directory('${tmp.path}/src');
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // ignore
    }
  });

  // zx a, the tool check, zx l, zx t, zx x and a comparison
  Future<void> roundTrip(String name, List<String> switches,
      ProcessResult Function()? check) async {
    var r = await _zx(tmp, ['a', name, 'src', ...switches]);
    expect(r.code, 0, reason: r.err + r.out);
    if (check != null) {
      final c = check();
      expect(c.exitCode, 0, reason: '${c.stdout}${c.stderr}');
    }
    // the password, for reading too
    final p = [
      for (final s in switches)
        if (s.startsWith('-p')) s
    ];
    r = await _zx(tmp, ['l', name, ...p]);
    expect(r.code, 0, reason: r.err);
    expect(r.out, contains('src/sub/numbers.txt'));
    r = await _zx(tmp, ['t', name, ...p]);
    expect(r.code, 0, reason: r.err + r.out);
    expect(r.out, contains('Everything is Ok'));
    final out = Directory('${tmp.path}/out_$name');
    r = await _zx(tmp, ['x', name, '-o${out.path}', ...p]);
    expect(r.code, 0, reason: r.err + r.out);
    _expectSameTree(src, Directory('${out.path}/src'));
  }

  // zx a extra.txt, zx d src/a.txt, then the tool check and a listing
  Future<void> updateDelete(String name, ProcessResult Function()? check,
      {List<String> switches = const []}) async {
    var r = await _zx(tmp, ['a', name, 'extra.txt', ...switches]);
    expect(r.code, 0, reason: r.err + r.out);
    r = await _zx(tmp, ['d', name, 'src/a.txt', ...switches]);
    expect(r.code, 0, reason: r.err + r.out);
    r = await _zx(tmp, ['l', name, ...switches]);
    expect(r.code, 0, reason: r.err);
    expect(r.out, contains('extra.txt'));
    expect(r.out, isNot(contains('src/a.txt')));
    expect(r.out, contains('src/sub/numbers.txt'));
    if (check != null) {
      final c = check();
      expect(c.exitCode, 0, reason: '${c.stdout}${c.stderr}');
    }
    // no temporary files are left next to the archive
    final left = tmp
        .listSync()
        .where((e) => e.path.endsWith('.tmp') || e.path.contains('.tmp'))
        .toList();
    expect(left, isEmpty);
  }

  // an archive made by a tool, extracted by zx
  Future<void> extractToolArchive(String name) async {
    final out = Directory('${tmp.path}/tool_$name');
    final r = await _zx(tmp, ['x', name, '-o${out.path}']);
    expect(r.code, 0, reason: r.err + r.out);
    _expectSameTree(src, Directory('${out.path}/src'));
  }

  final unzip = _which('unzip');
  final zip = _which('zip');
  final tar = _which('tar');
  final gzip = _which('gzip');
  final bzip2 = _which('bzip2');
  final xz = _which('xz');
  final unrar = _which('unrar');

  group('zip', () {
    test('create, unzip -t, update, delete', () async {
      await roundTrip('z.zip', [],
          unzip == null ? null : () => _tool(unzip, ['-t', 'z.zip'], tmp));
      await updateDelete('z.zip',
          unzip == null ? null : () => _tool(unzip, ['-t', 'z.zip'], tmp));
    });

    test('methods and encryption switches', () async {
      for (final m in ['copy', 'deflate', 'bzip2']) {
        await roundTrip('m_$m.zip', ['-mm=$m'],
            unzip == null ? null : () => _tool(unzip, ['-t', 'm_$m.zip'], tmp));
      }
      // unzip has no LZMA and PPMd: the system 7z checks them
      final sevenZ = _have('/usr/bin/7z') ? '/usr/bin/7z' : null;
      for (final m in ['lzma', 'ppmd']) {
        await roundTrip(
            'm_$m.zip',
            ['-mm=$m'],
            sevenZ == null
                ? null
                : () => _tool(sevenZ, ['t', 'm_$m.zip'], tmp));
      }
      // Deflate64: unzip and the system 7z both decode it
      await roundTrip(
          'm_d64.zip',
          ['-mm=Deflate64'],
          sevenZ != null
              ? () => _tool(sevenZ, ['t', 'm_d64.zip'], tmp)
              : unzip == null
                  ? null
                  : () => _tool(unzip, ['-t', 'm_d64.zip'], tmp));
      if (unzip != null && sevenZ != null) {
        final u = _tool(unzip, ['-t', 'm_d64.zip'], tmp);
        expect(u.exitCode, 0, reason: '${u.stdout}');
      }
      var l = await _zx(tmp, ['l', '-slt', 'm_d64.zip']);
      expect(l.out, contains('Method = Deflate64'));
      await roundTrip('cu.zip', ['-mcu', '-mx9'], null);
      await roundTrip(
          'zc.zip',
          ['-psecret', '-mem=ZipCrypto'],
          unzip == null
              ? null
              : () => _tool(unzip, ['-t', '-P', 'secret', 'zc.zip'], tmp));
      var r =
          await _zx(tmp, ['a', 'aes.zip', 'src', '-psecret', '-mem=AES256']);
      expect(r.code, 0, reason: r.err);
      r = await _zx(tmp, ['t', 'aes.zip', '-psecret']);
      expect(r.code, 0, reason: r.err + r.out);
      r = await _zx(tmp, ['t', 'aes.zip', '-pwrong']);
      expect(r.code, isNot(0));
      r = await _zx(tmp, ['a', 'bad.zip', 'src', '-mm=nosuch']);
      expect(r.code, isNot(0));
    });

    test('extract an archive made by zip', () async {
      if (zip == null) return markTestSkipped('zip not found');
      final r = _tool(zip, ['-rq', 'tool.zip', 'src'], tmp);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      await extractToolArchive('tool.zip');
    });
  });

  group('jar', () {
    test('create, jar tf, extract a jar made by jar', () async {
      await roundTrip('j.jar', [],
          _have(_jar) ? () => _tool(_jar, ['tf', 'j.jar'], tmp) : null);
      if (!_have(_jar)) return markTestSkipped('jar not found');
      final list = _tool(_jar, ['tf', 'j.jar'], tmp);
      expect('${list.stdout}', contains('src/sub/numbers.txt'));
      final r = _tool(_jar, ['cfM', 'tool.jar', 'src'], tmp);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      await extractToolArchive('tool.jar');
    });
  });

  group('tar', () {
    test('create, tar -tf, update, delete, -mm=gnu|pax|posix', () async {
      await roundTrip('t.tar', [],
          tar == null ? null : () => _tool(tar, ['-tf', 't.tar'], tmp));
      await updateDelete('t.tar',
          tar == null ? null : () => _tool(tar, ['-tf', 't.tar'], tmp));
      for (final m in ['gnu', 'pax', 'posix']) {
        await roundTrip('m_$m.tar', ['-mm=$m'],
            tar == null ? null : () => _tool(tar, ['-tf', 'm_$m.tar'], tmp));
      }
      final r = await _zx(tmp, ['l', '-slt', 'm_pax.tar']);
      expect(r.out, contains('Characteristics = POSIX'));
    });

    test('extract an archive made by tar', () async {
      if (tar == null) return markTestSkipped('tar not found');
      final r = _tool(tar, ['-cf', 'tool.tar', 'src'], tmp);
      expect(r.exitCode, 0);
      await extractToolArchive('tool.tar');
    });
  });

  group('compound tar', () {
    final cases = <(String, String?, String)>[
      ('c.tar.gz', gzip, '-tzf'),
      ('c.tgz', gzip, '-tzf'),
      ('c.tar.bz2', bzip2, '-tjf'),
      ('c.tbz2', bzip2, '-tjf'),
      ('c.tar.xz', xz, '-tJf'),
      ('c.txz', xz, '-tJf'),
    ];
    for (final (name, compressor, tarSwitch) in cases) {
      test('$name: create, tar $tarSwitch, update, delete', () async {
        ProcessResult Function()? check;
        if (tar != null && compressor != null) {
          check = () => _tool(tar, [tarSwitch, name], tmp);
        }
        await roundTrip(name, ['-mx1'], check);
        // one archive of two levels, the tar last
        final l = await _zx(tmp, ['l', name]);
        expect(l.out, contains('Type = tar'));
        expect(RegExp(r'Type = (gzip|bzip2|xz)').hasMatch(l.out), isTrue);
        await updateDelete(name, check);
        // -w puts the temporary tar in another folder
        final w = Directory('${tmp.path}/work')..createSync();
        final r = await _zx(tmp, ['a', name, 'extra.txt', '-w${w.path}']);
        expect(r.code, 0, reason: r.err + r.out);
        expect(w.listSync(), isEmpty);
      });
    }

    for (final name in ['c.tar.lzma', 'c.tlz']) {
      test('$name: create, tar --lzma -tf, xz -t, update, delete', () async {
        ProcessResult Function()? check;
        if (tar != null && xz != null) {
          check = () => _tool(tar, ['--lzma', '-tf', name], tmp);
        }
        await roundTrip(name, ['-mx1', '-md=1m'], check);
        final l = await _zx(tmp, ['l', name]);
        expect(l.out, contains('Type = tar'));
        expect(l.out, contains('Type = lzma'));
        if (xz != null) {
          final t = _tool(xz, ['--format=lzma', '-t', name], tmp);
          expect(t.exitCode, 0, reason: '${t.stderr}');
        }
        await updateDelete(name, check);
      });
    }

    test('a single file as .lzma, and -so', () async {
      var r = await _zx(tmp, ['a', 'e.lzma', 'extra.txt', '-mx9', '-mlc=0']);
      expect(r.code, 0, reason: r.err + r.out);
      if (xz != null) {
        final d = _tool(xz, ['--format=lzma', '-dc', 'e.lzma'], tmp);
        expect(d.exitCode, 0, reason: '${d.stderr}');
        expect(d.stdout, 'extra file\n');
      }
      r = await _zx(tmp, ['e', 'e.lzma', '-so']);
      expect(r.out, 'extra file\n');
      // to stdout the size is unknown: the stream ends with the end marker
      final out = BytesBuilder();
      final code = await runSevenZipCli(
          ['a', '-tlzma', '-so', 'x', 'extra.txt'],
          stdout: out.add, stderr: (_) {}, workingDirectory: tmp.path);
      expect(code, 0);
      final b = out.takeBytes();
      expect(b.sublist(5, 13), List.filled(8, 0xFF));
      File('${tmp.path}/so.lzma').writeAsBytesSync(b);
      r = await _zx(tmp, ['t', 'so.lzma']);
      expect(r.out, contains('Everything is Ok'));
      r = await _zx(tmp, ['a', 'bad.lzma', 'extra.txt', '-mm=PPMd']);
      expect(r.code, isNot(0));
    });

    test('extract archives made by tar', () async {
      if (tar == null) return markTestSkipped('tar not found');
      for (final (name, compressor, _) in cases) {
        if (compressor == null) continue;
        final sw = name.contains('gz')
            ? '-czf'
            : name.contains('bz')
                ? '-cjf'
                : '-cJf';
        final r = _tool(tar, [sw, 'tool_$name', 'src'], tmp);
        expect(r.exitCode, 0, reason: '${r.stderr}');
        await extractToolArchive('tool_$name');
      }
    });

    test('-tgzip keeps one level, -ttar and -ttar.gzip open the tar', () async {
      if (tar == null || gzip == null) {
        return markTestSkipped('tar or gzip not found');
      }
      _tool(tar, ['-czf', 'g.tar.gz', 'src'], tmp);
      var r = await _zx(tmp, ['l', '-tgzip', 'g.tar.gz']);
      expect(r.code, 0, reason: r.err);
      expect(r.out, isNot(contains('Type = tar')));
      expect(r.out, contains('g.tar'));
      r = await _zx(tmp, ['x', '-tgzip', 'g.tar.gz', '-og1']);
      expect(r.code, 0, reason: r.err);
      expect(File('${tmp.path}/g1/g.tar').existsSync(), isTrue);

      // a gzip named without .tar: the decoded data is sniffed for a tar
      // header, so it still opens as a tar (and -tgzip keeps one level)
      File('${tmp.path}/g.tar.gz').renameSync('${tmp.path}/g.bin');
      r = await _zx(tmp, ['l', 'g.bin']);
      expect(r.out, contains('Type = tar'));
      r = await _zx(tmp, ['l', '-tgzip', 'g.bin']);
      expect(r.out, isNot(contains('Type = tar')));
      r = await _zx(tmp, ['l', '-ttar', 'g.bin']);
      expect(r.code, 0, reason: r.err);
      expect(r.out, contains('Type = tar'));
      expect(r.out, contains('src/sub/numbers.txt'));
      r = await _zx(tmp, ['x', '-ttar.gzip', 'g.bin', '-og2']);
      expect(r.code, 0, reason: r.err);
      _expectSameTree(src, Directory('${tmp.path}/g2/src'));

      // -ttar on a gzip that does not hold a tar
      _tool(gzip, ['-k', 'extra.txt'], tmp);
      r = await _zx(tmp, ['l', '-ttar', 'extra.txt.gz']);
      expect(r.code, isNot(0));
    });

    test('a damaged tar.gz is reported', () async {
      var r = await _zx(tmp, ['a', 'd.tar.gz', 'src']);
      expect(r.code, 0);
      final f = File('${tmp.path}/d.tar.gz');
      final b = f.readAsBytesSync();
      // the CRC of the gzip trailer
      b[b.length - 8] ^= 0xFF;
      f.writeAsBytesSync(b);
      r = await _zx(tmp, ['t', 'd.tar.gz']);
      expect(r.code, 2);
      expect(r.out + r.err, contains('CRC Failed'));
      f.writeAsBytesSync(b.sublist(0, b.length ~/ 2));
      r = await _zx(tmp, ['t', 'd.tar.gz']);
      expect(r.code, 2);
    });
  });

  group('gzip and bzip2 files', () {
    test('gz: create, gzip -t, extract a file made by gzip', () async {
      var r = await _zx(tmp, ['a', 'n.gz', 'src/sub/numbers.txt']);
      expect(r.code, 0, reason: r.err);
      if (gzip != null) {
        final c = _tool(gzip, ['-t', 'n.gz'], tmp);
        expect(c.exitCode, 0, reason: '${c.stderr}');
      }
      r = await _zx(tmp, ['x', 'n.gz', '-oo']);
      expect(r.code, 0, reason: r.err);
      expect(File('${tmp.path}/o/numbers.txt').readAsBytesSync(),
          File('${src.path}/sub/numbers.txt').readAsBytesSync());
      r = await _zx(tmp, ['a', '-tgzip', 'two.gz', 'extra.txt', 'src/a.txt']);
      expect(r.code, isNot(0));
      if (gzip == null) return;
      File('${src.path}/bin.dat').copySync('${tmp.path}/b.dat');
      _tool(gzip, ['b.dat'], tmp);
      r = await _zx(tmp, ['x', 'b.dat.gz', '-ot']);
      expect(r.code, 0, reason: r.err);
      expect(File('${tmp.path}/t/b.dat').readAsBytesSync(),
          File('${src.path}/bin.dat').readAsBytesSync());
    });

    test('bz2: create, bzip2 -t, extract a file made by bzip2', () async {
      var r = await _zx(tmp, ['a', 'n.bz2', 'src/sub/numbers.txt', '-mx9']);
      expect(r.code, 0, reason: r.err);
      if (bzip2 != null) {
        final c = _tool(bzip2, ['-t', 'n.bz2'], tmp);
        expect(c.exitCode, 0, reason: '${c.stderr}');
      }
      r = await _zx(tmp, ['t', 'n.bz2']);
      expect(r.code, 0, reason: r.err);
      if (bzip2 == null) return;
      File('${src.path}/bin.dat').copySync('${tmp.path}/b.dat');
      _tool(bzip2, ['b.dat'], tmp);
      r = await _zx(tmp, ['x', 'b.dat.bz2', '-ot']);
      expect(r.code, 0, reason: r.err);
      expect(File('${tmp.path}/t/b.dat').readAsBytesSync(),
          File('${src.path}/bin.dat').readAsBytesSync());
    });
  });

  group('lzh', () {
    test('create with each method, lhasa -t, update, delete', () async {
      final have = _have(_lhasa);
      for (final m in ['lh0', 'lh5', 'lh6', 'lh7']) {
        await roundTrip('m_$m.lzh', ['-mm=$m'],
            have ? () => _runLhasa(['-t', 'm_$m.lzh'], tmp) : null);
      }
      await updateDelete(
          'm_lh5.lzh', have ? () => _runLhasa(['-t', 'm_lh5.lzh'], tmp) : null);
      final r = await _zx(tmp, ['a', 'bad.lzh', 'src', '-mm=lh9']);
      expect(r.code, isNot(0));
    });

    test('extract an archive made by jlha', () async {
      if (!_haveJlha) return markTestSkipped('jlha not found');
      final r = _tool(
          _java,
          [
            '-cp',
            _jlhaCp,
            'org.jlhafrontend.JLHAFrontEnd',
            'a',
            'tool.lzh',
            'src/a.txt',
            'src/bin.dat',
            'src/sub/numbers.txt'
          ],
          tmp);
      expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
      await extractToolArchive('tool.lzh');
    });
  });

  group('arj', () {
    test('create with each method, arj t, update, delete', () async {
      final have = _have(_arj);
      for (final m in ['0', '1', '2', '3', '4']) {
        await roundTrip('m_$m.arj', ['-mm=$m'],
            have ? () => _tool(_arj, ['t', 'm_$m.arj'], tmp) : null);
      }
      await updateDelete(
          'm_1.arj', have ? () => _tool(_arj, ['t', 'm_1.arj'], tmp) : null);
    });

    test('extract an archive made by arj', () async {
      if (!_have(_arj)) return markTestSkipped('arj not found');
      for (final m in ['0', '1', '4']) {
        final r =
            _tool(_arj, ['a', '-r', '-m$m', '-y', 'tool$m.arj', 'src'], tmp);
        expect(r.exitCode, 0, reason: '${r.stdout}');
        await extractToolArchive('tool$m.arj');
      }
    });

    test('garbled: create with -p, arj t -g, wrong passwords', () async {
      final have = _have(_arj);
      for (final m in ['0', '1', '4']) {
        await roundTrip('g$m.arj', ['-mm=$m', '-psecret'],
            have ? () => _tool(_arj, ['t', '-gsecret', 'g$m.arj'], tmp) : null);
        var r = await _zx(tmp, ['t', 'g$m.arj', '-pwrong']);
        expect(r.code, isNot(0));
        expect(r.err, contains('Wrong password?'));
        if (have) {
          final t = _tool(_arj, ['t', '-gwrong', 'g$m.arj'], tmp);
          expect(t.exitCode, 3); // CRC error
        }
      }
      await updateDelete('g1.arj',
          have ? () => _tool(_arj, ['t', '-gsecret', 'g1.arj'], tmp) : null,
          switches: ['-psecret']);
    });

    test('garbled and multi-volume archives made by arj', () async {
      if (!_have(_arj)) return markTestSkipped('arj not found');
      var r = _tool(_arj,
          ['a', '-r', '-m1', '-y', '-gp\u00e4ss', 'toolg.arj', 'src'], tmp);
      expect(r.exitCode, 0, reason: '${r.stdout}');
      final out = Directory('${tmp.path}/tool_g');
      var z =
          await _zx(tmp, ['x', 'toolg.arj', '-pp\u00e4ss', '-o${out.path}']);
      expect(z.code, 0, reason: z.err + z.out);
      _expectSameTree(src, Directory('${out.path}/src'));
      // x.arj, x.a01, x.a02...: the parts of split files are joined
      r = _tool(
          _arj, ['a', '-r', '-m0', '-v10k', '-y', 'toolv.arj', 'src'], tmp);
      expect(r.exitCode, 0, reason: '${r.stdout}');
      expect(File('${tmp.path}/toolv.a02').existsSync(), isTrue);
      await extractToolArchive('toolv.arj');
      z = await _zx(tmp, ['l', 'toolv.arj']);
      expect(z.out, contains('Volumes: '));
    });

    test('symbolic links: -snl, arj x, read back', () async {
      if (Platform.isWindows) return markTestSkipped('POSIX links');
      Link('${src.path}/lnk').createSync('a.txt');
      var r = await _zx(tmp, ['a', 'l.arj', 'src', '-snl']);
      expect(r.code, 0, reason: r.err + r.out);
      final out = Directory('${tmp.path}/out_l');
      r = await _zx(tmp, ['x', 'l.arj', '-snl', '-o${out.path}']);
      expect(r.code, 0, reason: r.err + r.out);
      expect(Link('${out.path}/src/lnk').targetSync(), 'a.txt');
      if (_have(_arj)) {
        final x = Directory('${tmp.path}/arj_l')..createSync();
        final t = _tool(_arj, ['x', '-y', '../l.arj'], x);
        expect(t.exitCode, 0, reason: '${t.stdout}');
        expect(Link('${x.path}/src/lnk').targetSync(), 'a.txt');
      }
    });
  });

  group('rar', () {
    test('create RAR5, unrar t, update, delete', () async {
      final check = unrar == null
          ? null
          : () => _tool(unrar, ['t', '-idq', 'r.rar'], tmp);
      await roundTrip('r.rar', [], check);
      await updateDelete('r.rar', check);
    });

    test('-v writes name.partN.rar volumes, -mrr a recovery record', () async {
      var r = await _zx(tmp, ['a', 'v.rar', 'src', '-mx0', '-v8k', '-mrr=5']);
      expect(r.code, 0, reason: r.err + r.out);
      for (final n in ['v.part1.rar', 'v.part2.rar', 'v.part3.rar']) {
        expect(File('${tmp.path}/$n').lengthSync(), 8192, reason: n);
      }
      expect(File('${tmp.path}/v.rar').existsSync(), isFalse);
      if (unrar != null) {
        final c = _tool(unrar, ['t', '-idq', 'v.part1.rar'], tmp);
        expect(c.exitCode, 0, reason: '${c.stdout}${c.stderr}');
      }
      if (_have(_rar)) {
        final c = _tool(_rar, ['t', 'v.part1.rar'], tmp);
        expect(c.exitCode, 0, reason: '${c.stdout}');
        expect('${c.stdout}', contains('recovery record'));
      }
      r = await _zx(tmp, ['t', 'v.part1.rar']);
      expect(r.out, contains('Everything is Ok'), reason: r.err + r.out);
      final out = Directory('${tmp.path}/out_v');
      r = await _zx(tmp, ['x', 'v.part1.rar', '-o${out.path}']);
      expect(r.code, 0, reason: r.err + r.out);
      _expectSameTree(src, Directory('${out.path}/src'));
      // a set of one volume is named like the archive
      r = await _zx(tmp, ['a', 'one.rar', 'src', '-v1m']);
      expect(r.code, 0, reason: r.err + r.out);
      expect(File('${tmp.path}/one.rar').existsSync(), isTrue);
      expect(File('${tmp.path}/one.part1.rar').existsSync(), isFalse);
    });

    test('extract an archive made by rar', () async {
      if (!_have(_rar)) return markTestSkipped('rar not found');
      final r = _tool(_rar, ['a', '-idq', '-r', 'tool.rar', 'src'], tmp);
      expect(r.exitCode, 0, reason: '${r.stdout}');
      await extractToolArchive('tool.rar');
    });
  });

  test('i lists the formats and codecs of every handler', () async {
    final r = await _zx(tmp, ['i']);
    expect(r.code, 0);
    for (final s in [
      '  zip      zip',
      '  tar      tar',
      '  gzip     gz',
      '  bzip2    bz2',
      '  Arj      arj',
      '  Lzh      lzh',
      '  Rar5     rar',
      ' ED     40108 Deflate',
      ' ED     40109 Deflate64',
      ' ED     40202 BZip2',
      ' ED     40162 PPMdZip',
      ' EDF  6F10101 ZipCrypto',
      ' EDF    40163 wzAES',
      ' ED     40401 Arj',
      ' ED       406 Lzh',
      ' ED     40305 Rar5',
    ]) {
      expect(r.out, contains(s));
    }
  });
}
