// Tests of the 7zr console program port, driven in-process.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/cli/main.dart';

class _Run {
  final int code;
  final String out;
  final String err;
  final Uint8List outBytes;
  _Run(this.code, this.outBytes, this.err)
      : out = utf8.decode(outBytes, allowMalformed: true);
}

Future<_Run> _run(Directory dir, List<String> args, {Uint8List? stdin}) async {
  final out = BytesBuilder();
  final err = BytesBuilder();
  final code = await runSevenZipCli(args,
      stdout: out.add,
      stderr: err.add,
      stdin: stdin,
      workingDirectory: dir.path);
  return _Run(code, out.takeBytes(), utf8.decode(err.takeBytes()));
}

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
  File('${src.path}/empty.txt').writeAsBytesSync([]);
  Directory('${src.path}/emptydir').createSync();
  Directory('${src.path}/sub/deep').createSync(recursive: true);
  File('${src.path}/sub/numbers.txt')
      .writeAsStringSync([for (var i = 1; i <= 3000; i++) '$i'].join('\n'));
  File('${src.path}/sub/deep/d.txt').writeAsStringSync('deep\n');
  File('${src.path}/ü名前.txt').writeAsStringSync('unicode\n');
  Link('${src.path}/link.txt').createSync('a.txt');
}

bool get _have7z => File('/usr/bin/7z').existsSync();

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('zx_cli_');
    _makeTree(tmp);
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // ignore
    }
  });

  test('help and banner', () async {
    final r = await _run(tmp, []);
    expect(r.code, 0);
    expect(r.out, contains('7-Zip (r) 26.01'));
    expect(r.out, contains('Usage: 7zr <command>'));
  });

  test('i lists the formats and codecs', () async {
    final r = await _run(tmp, ['i']);
    expect(r.code, 0);
    expect(r.out, contains('   C...F..........c.a.m+..  7z       7z'));
    expect(r.out, contains(' EDF  6F10701 7zAES'));
    expect(r.out, contains('     32        A SHA256'));
  });

  test('command line errors exit with 7', () async {
    var r = await _run(tmp, ['zz']);
    expect(r.code, 7);
    expect(r.err, contains('Command Line Error:\nUnsupported command:\nzz'));
    r = await _run(tmp, ['a', '-bad', 'x.7z']);
    expect(r.code, 7);
    expect(r.err, contains('Too long switch:\n-bad'));
    r = await _run(tmp, ['x']);
    expect(r.code, 7);
    expect(r.err, contains('Cannot find archive name'));
  });

  test('missing archive is a fatal error', () async {
    final r = await _run(tmp, ['l', 'nothere.7z']);
    expect(r.code, 2);
    expect(r.err, contains('errno=2 : No such file or directory'));
  });

  test('a, l, t, x round trip', () async {
    var r = await _run(tmp, ['a', 'arc.7z', 'src']);
    expect(r.code, 0, reason: r.err);
    expect(r.out, contains('Scanning the drive:'));
    expect(r.out, contains('4 folders, 7 files'));
    expect(r.out, contains('Files read from disk: 6'));
    expect(r.out, contains('Everything is Ok'));

    r = await _run(tmp, ['l', 'arc.7z']);
    expect(r.code, 0);
    expect(r.out, contains('Type = 7z'));
    expect(r.out, contains('src/a.txt'));
    expect(r.out, contains('7 files, 4 folders'));

    r = await _run(tmp, ['l', '-slt', 'arc.7z']);
    expect(r.out, contains('Path = src/a.txt\nSize = 12\n'));
    expect(r.out, contains('CRC = AF083B2D'));

    r = await _run(tmp, ['t', 'arc.7z']);
    expect(r.code, 0);
    expect(r.out, contains('Everything is Ok'));

    r = await _run(tmp, ['x', 'arc.7z', '-oout']);
    expect(r.code, 0, reason: r.err);
    expect(File('${tmp.path}/out/src/a.txt').readAsStringSync(),
        'hello world\n');
    expect(File('${tmp.path}/out/src/bin.dat').readAsBytesSync(),
        File('${tmp.path}/src/bin.dat').readAsBytesSync());
    expect(File('${tmp.path}/out/src/ü名前.txt').existsSync(),
        isTrue);
    expect(Directory('${tmp.path}/out/src/emptydir').existsSync(), isTrue);

    // e: no paths, with a wildcard and recursion
    r = await _run(tmp, ['e', 'arc.7z', '-oflat', '*.txt', '-r']);
    expect(r.code, 0);
    expect(File('${tmp.path}/flat/d.txt').existsSync(), isTrue);
    expect(File('${tmp.path}/flat/bin.dat').existsSync(), isFalse);

    // -aos keeps the existing files
    File('${tmp.path}/flat/d.txt').writeAsStringSync('changed');
    r = await _run(tmp, ['e', 'arc.7z', '-oflat', 'src/sub/deep/d.txt', '-aos']);
    expect(r.code, 0);
    expect(File('${tmp.path}/flat/d.txt').readAsStringSync(), 'changed');
    r = await _run(tmp, ['e', 'arc.7z', '-oflat', 'src/sub/deep/d.txt', '-aou']);
    expect(File('${tmp.path}/flat/d_1.txt').readAsStringSync(), 'deep\n');
  });

  test('update, delete and rename', () async {
    await _run(tmp, ['a', 'arc.7z', 'src', '-x!src/bin.dat']);
    var r = await _run(tmp, ['u', 'arc.7z', 'src']);
    expect(r.code, 0, reason: r.err);
    expect(r.out, contains('Updating archive: arc.7z'));
    r = await _run(tmp, ['d', 'arc.7z', 'src/a.txt']);
    expect(r.code, 0);
    r = await _run(tmp, ['rn', 'arc.7z', 'src/sub', 'src/sub2']);
    expect(r.code, 0);
    r = await _run(tmp, ['l', '-ba', 'arc.7z']);
    expect(r.out, isNot(contains('src/a.txt')));
    expect(r.out, contains('src/sub2/numbers.txt'));
    expect(r.out, contains('src/bin.dat'));
  });

  test('passwords and encrypted headers', () async {
    var r = await _run(tmp, ['a', '-psecret', '-mhe', 'p.7z', 'src']);
    expect(r.code, 0);
    r = await _run(tmp, ['t', '-psecret', 'p.7z']);
    expect(r.code, 0);
    r = await _run(tmp, ['t', '-pwrong', 'p.7z']);
    expect(r.code, 2);
    expect(r.err, contains('Cannot open encrypted archive. Wrong password?'));
    // the password from the prompt (standard input)
    r = await _run(tmp, ['t', 'p.7z'],
        stdin: Uint8List.fromList(utf8.encode('secret\n')));
    expect(r.code, 0, reason: r.err);
    expect(r.out, contains('Enter password'));
  });

  test('volumes, xz, stdin and stdout', () async {
    var r = await _run(tmp, ['a', '-v7k', 'v.7z', 'src']);
    expect(r.code, 0);
    expect(r.out, contains('Volumes: 4'));
    r = await _run(tmp, ['t', 'v.7z.001']);
    expect(r.code, 0, reason: r.err);
    expect(r.out, contains('Type = Split'));

    r = await _run(tmp, ['a', '-txz', 'n.xz', 'src/sub/numbers.txt']);
    expect(r.code, 0);
    r = await _run(tmp, ['x', '-so', 'n.xz']);
    expect(r.code, 0);
    expect(r.outBytes,
        File('${tmp.path}/src/sub/numbers.txt').readAsBytesSync());

    final data = Uint8List.fromList(utf8.encode('from stdin\n' * 100));
    r = await _run(tmp, ['a', '-si', '-txz', 's.xz'], stdin: data);
    expect(r.code, 0);
    r = await _run(tmp, ['e', '-so', 's.xz']);
    expect(r.outBytes, data);
  });

  test('h with every hasher', () async {
    final r = await _run(tmp, ['h', '-scrc*', 'src/a.txt']);
    expect(r.code, 0);
    expect(r.out, contains('AF083B2D'));
    expect(r.out, contains('CRC32  for data:'));
    expect(r.out, contains('SHA256 for data:'));
  });

  test('interop with the system 7z', () async {
    if (!_have7z) {
      markTestSkipped('/usr/bin/7z is not installed');
      return;
    }
    var r = await _run(tmp, ['a', 'ours.7z', 'src', '-snl']);
    expect(r.code, 0);
    final t = Process.runSync('/usr/bin/7z', ['t', 'ours.7z'],
        workingDirectory: tmp.path);
    expect(t.exitCode, 0, reason: '${t.stdout}');
    Process.runSync('/usr/bin/7z', ['a', 'theirs.7z', 'src', '-mx=9'],
        workingDirectory: tmp.path);
    r = await _run(tmp, ['x', 'theirs.7z', '-otheirs']);
    expect(r.code, 0, reason: r.err);
    expect(File('${tmp.path}/theirs/src/bin.dat').readAsBytesSync(),
        File('${tmp.path}/src/bin.dat').readAsBytesSync());
  });
}
