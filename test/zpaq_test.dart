// The zpaq format end to end: the command line tool (create, add a second
// version, delete, rename, list and extract per version with -mversion,
// test, password, detection by signature) and ZxArchive (create, add,
// delete, rename, versions, open at a version, password). Interop with the
// reference tools runs when they are found: set ZPAQ_BIN (zpaq 7.15) and
// ZPAQFRANZ_BIN (zpaqfranz), or put zpaq and zpaqfranz on the PATH.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/cli/main.dart';
import 'package:zx/zx.dart';

class _Run {
  final int code;
  final String out;
  final String err;
  _Run(this.code, Uint8List outBytes, this.err)
      : out = utf8.decode(outBytes, allowMalformed: true);
  @override
  String toString() => 'exit $code\n$out\n$err';
}

Future<_Run> _zx(Directory dir, List<String> args) async {
  final out = BytesBuilder();
  final err = BytesBuilder();
  final code = await runSevenZipCli(args,
      stdout: out.add, stderr: err.add, workingDirectory: dir.path);
  return _Run(code, out.takeBytes(), utf8.decode(err.takeBytes()));
}

String? _tool(String env, String name) {
  final e = Platform.environment[env];
  if (e != null && File(e).existsSync()) return e;
  for (final d in (Platform.environment['PATH'] ?? '').split(':')) {
    if (d.isEmpty) continue;
    final p = '$d/$name';
    if (File(p).existsSync()) return p;
  }
  return null;
}

final String? _zpaq = _tool('ZPAQ_BIN', 'zpaq');
final String? _franz = _tool('ZPAQFRANZ_BIN', 'zpaqfranz');

ProcessResult _run(String exe, List<String> args, Directory cwd) {
  final r = Process.runSync(exe, args, workingDirectory: cwd.path);
  if (r.exitCode != 0) {
    fail('$exe ${args.join(' ')}: exit ${r.exitCode}\n${r.stdout}\n'
        '${r.stderr}');
  }
  return r;
}

Uint8List _random(int n, int seed) {
  final r = Random(seed);
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

Uint8List _text(int n, int seed) {
  final r = Random(seed);
  const words = ['zpaq', 'journal', 'version', 'block', 'fragment', 'zx '];
  final sb = StringBuffer();
  while (sb.length < n) {
    sb.write(words[r.nextInt(words.length)]);
    sb.write(r.nextInt(9) == 0 ? '\n' : ' ');
  }
  return Uint8List.fromList(utf8.encode(sb.toString().substring(0, n)));
}

void _write(Directory d, String rel, List<int> data, [DateTime? t]) {
  final f = File('${d.path}/$rel');
  f.parent.createSync(recursive: true);
  f.writeAsBytesSync(data);
  f.setLastModifiedSync(t ?? DateTime(2025, 3, 4, 5, 6, 8));
}

/// Relative path to content of every file under [dir].
Map<String, List<int>> _tree(String dir) {
  final out = <String, List<int>>{};
  final base = Directory(dir);
  if (!base.existsSync()) return out;
  for (final e in base.listSync(recursive: true, followLinks: false)) {
    if (e is File) out[e.path.substring(dir.length + 1)] = e.readAsBytesSync();
  }
  return out;
}

/// Names in `zx l -ba` output (last column).
List<String> _names(String listing) => [
      for (final l in const LineSplitter().convert(listing))
        if (l.length > 53) l.substring(53)
    ];

late Directory tmp;

void _source() {
  _write(tmp, 'src/a.txt', _text(60000, 1));
  _write(tmp, 'src/b.bin', _random(150000, 2));
  _write(tmp, 'src/sub/c.txt', _text(3000, 3));
  _write(tmp, 'src/empty', const []);
}

void main() {
  setUp(() => tmp = Directory.systemTemp.createTempSync('zx_zpaq_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('command line', () {
    test('create, versions, delete, rename, list and extract per version',
        () async {
      _source();
      var r = await _zx(tmp, ['a', 'x.zpaq', 'src', '-bso0']);
      expect(r.code, 0, reason: '$r');
      // a second version: one changed file, one new file
      _write(tmp, 'src/sub/c.txt', _text(3100, 4), DateTime(2025, 3, 5));
      _write(tmp, 'src/d.txt', _text(500, 5));
      r = await _zx(tmp, ['u', 'x.zpaq', 'src', '-bso0']);
      expect(r.code, 0, reason: '$r');
      r = await _zx(tmp, ['d', 'x.zpaq', 'src/empty', '-bso0']);
      expect(r.code, 0, reason: '$r');
      final before = File('${tmp.path}/x.zpaq').lengthSync();
      r = await _zx(tmp, ['rn', 'x.zpaq', 'src/b.bin', 'src/b2.bin', '-bso0']);
      expect(r.code, 0, reason: '$r');
      // a rename reuses the fragments: only an index entry is added
      expect(File('${tmp.path}/x.zpaq').lengthSync() - before, lessThan(2000));

      r = await _zx(tmp, ['l', '-slt', 'x.zpaq']);
      expect(r.code, 0, reason: '$r');
      expect(r.out, contains('Type = zpaq'));
      expect(r.out, contains('Versions = 4'));
      expect(r.out, contains('Version = 4'));

      final last = _names((await _zx(tmp, ['l', '-ba', 'x.zpaq'])).out);
      expect(last,
          ['src', 'src/a.txt', 'src/b2.bin', 'src/d.txt', 'src/sub', 'src/sub/c.txt']);
      final v1 = _names(
          (await _zx(tmp, ['l', '-ba', 'x.zpaq', '-mversion=1'])).out);
      expect(v1,
          ['src', 'src/a.txt', 'src/b.bin', 'src/empty', 'src/sub', 'src/sub/c.txt']);
      final v3 = _names(
          (await _zx(tmp, ['l', '-ba', 'x.zpaq', '-mversion=3'])).out);
      expect(v3, contains('src/b.bin'));
      expect(v3, isNot(contains('src/empty')));

      // extract version 1 and the last one
      r = await _zx(tmp, ['x', 'x.zpaq', '-mversion=1', '-oout1', '-bso0']);
      expect(r.code, 0, reason: '$r');
      final t1 = _tree('${tmp.path}/out1/src');
      expect(t1['sub/c.txt'], _text(3000, 3));
      expect(t1['b.bin'], _random(150000, 2));
      expect(t1['empty'], isEmpty);
      r = await _zx(tmp, ['x', 'x.zpaq', '-oout4', '-bso0']);
      expect(r.code, 0, reason: '$r');
      final t4 = _tree('${tmp.path}/out4/src');
      expect(t4.keys.toSet(), {'a.txt', 'b2.bin', 'd.txt', 'sub/c.txt'});
      expect(t4['sub/c.txt'], _text(3100, 4));
      expect(t4['b2.bin'], _random(150000, 2));
      expect(
          File('${tmp.path}/out4/src/a.txt').lastModifiedSync(),
          DateTime(2025, 3, 4, 5, 6, 8));

      r = await _zx(tmp, ['t', 'x.zpaq']);
      expect(r.code, 0, reason: '$r');
      expect(r.out, contains('Everything is Ok'));
      // an archive opened at an older version is not updated
      r = await _zx(tmp, ['d', 'x.zpaq', 'src/a.txt', '-mversion=1']);
      expect(r.code, isNot(0));
    });

    test('methods, a damaged block, detection without the extension',
        () async {
      _source();
      for (final m in ['0', '2', '3', '5']) {
        final r = await _zx(tmp, ['a', 'm$m.zpaq', 'src', '-mx=$m', '-bso0']);
        expect(r.code, 0, reason: '$r');
        final t = await _zx(tmp, ['t', 'm$m.zpaq', '-bso0']);
        expect(t.code, 0, reason: 'method $m: $t');
      }
      final l = await _zx(tmp, ['l', '-slt', 'm5.zpaq']);
      expect(l.out, contains('Method = CM'));
      // no extension, and a misleading one
      File('${tmp.path}/m0.zpaq').copySync('${tmp.path}/noext');
      File('${tmp.path}/m0.zpaq').copySync('${tmp.path}/fake.7z');
      for (final n in ['noext', 'fake.7z']) {
        final r = await _zx(tmp, ['l', n]);
        expect(r.out, contains('Type = zpaq'), reason: n);
      }
      // a damaged data byte of a stored block: CRC error on its file
      final bytes = File('${tmp.path}/m0.zpaq').readAsBytesSync();
      final at = bytes.length ~/ 2;
      bytes[at] ^= 0x55;
      File('${tmp.path}/bad.zpaq').writeAsBytesSync(bytes);
      final t = await _zx(tmp, ['t', 'bad.zpaq']);
      expect(t.code, isNot(0));
    });

    test('password (zpaq -key)', () async {
      _source();
      var r = await _zx(tmp, ['a', 'e.zpaq', 'src', '-psecret', '-bso0']);
      expect(r.code, 0, reason: '$r');
      final head = File('${tmp.path}/e.zpaq').openSync().readSync(4);
      expect(head, isNot([0x37, 0x6b, 0x53, 0x74]));
      r = await _zx(tmp, ['l', 'e.zpaq', '-pwrong']);
      expect(r.code, isNot(0));
      _write(tmp, 'more.txt', _text(1000, 9));
      r = await _zx(tmp, ['a', 'e.zpaq', 'more.txt', '-psecret', '-bso0']);
      expect(r.code, 0, reason: '$r');
      r = await _zx(tmp, ['x', 'e.zpaq', '-psecret', '-oout', '-bso0']);
      expect(r.code, 0, reason: '$r');
      expect(_tree('${tmp.path}/out')['more.txt'], _text(1000, 9));
      expect(_tree('${tmp.path}/out')['src/b.bin'], _random(150000, 2));
      // -tzpaq opens it whatever its name
      File('${tmp.path}/e.zpaq').copySync('${tmp.path}/e.bin');
      r = await _zx(tmp, ['t', '-tzpaq', 'e.bin', '-psecret']);
      expect(r.code, 0, reason: '$r');
    });
  });

  group('ZxArchive', () {
    test('create, add, delete, rename, versions, open at a version',
        () async {
      _source();
      final path = '${tmp.path}/api.zpaq';
      var a = await ZxArchive.create(
          path, [ZxSource('${tmp.path}/src', storedAs: 'src')]);
      expect(a.format, 'zpaq');
      expect(a.versions.length, 1);
      expect(a.capabilities.canAdd, isTrue);
      _write(tmp, 'n.txt', _text(2000, 7));
      await a.add([ZxSource('${tmp.path}/n.txt')], destination: 'src');
      await a.delete(['src/empty']);
      await a.rename('src/a.txt', 'src/a2.txt');
      expect(a.versions.length, 4);
      expect(a.numVersions, 4);
      expect(a.version, 4);
      expect(a['src/a2.txt'], isNotNull);
      expect(a['src/a.txt'], isNull);
      expect(a['src/empty'], isNull);
      expect(await a.readBytes('src/n.txt'), _text(2000, 7));
      expect((await a.test()).errors, isEmpty);

      final v1 = await ZxArchive.open(path, version: 1);
      expect(v1.version, 1);
      expect(v1.numVersions, 4);
      expect(v1.capabilities.canAdd, isFalse);
      expect(v1['src/a.txt'], isNotNull);
      expect(v1['src/n.txt'], isNull);
      expect(v1['src/empty'], isNotNull);
      expect(await v1.readBytes('src/a.txt'), _text(60000, 1));
      final out = '${tmp.path}/v1';
      final res = await v1.extract(out);
      expect(res.errors, isEmpty);
      expect(_tree('$out/src')['b.bin'], _random(150000, 2));
      expect(_tree('$out/src').containsKey('n.txt'), isFalse);

      a = await ZxArchive.open(path);
      expect(a.versions.map((v) => v.number), [1, 2, 3, 4]);
      expect(a.versions[2].deleted, 1);
    });

    test('password', () async {
      _source();
      final path = '${tmp.path}/pw.zpaq';
      await ZxArchive.create(path, [ZxSource('${tmp.path}/src')],
          options: const ZxOptions(password: 'pw', level: 2));
      await expectLater(ZxArchive.open(path, password: 'bad'),
          throwsA(isA<SevenZipException>()));
      final a = await ZxArchive.open(path, password: 'pw');
      expect(a.encryptedHeaders, isTrue);
      final f = a.items.firstWhere((i) => i.path.endsWith('b.bin'));
      expect(await a.readBytes(f), _random(150000, 2));
      _write(tmp, 'late.txt', _text(700, 11));
      await a.add([ZxSource('${tmp.path}/late.txt')]);
      final b = await ZxArchive.open(path, password: 'pw');
      expect(await b.readBytes('late.txt'), _text(700, 11));
    });
  });

  group('interop', () {
    test('zpaq 7.15 reads and updates zx archives, zx reads and updates its',
        () async {
      final zpaq = _zpaq!;
      _source();
      // zx writes, zpaq lists, extracts and adds a version
      var r = await _zx(tmp, ['a', 'x.zpaq', 'src', '-bso0']);
      expect(r.code, 0, reason: '$r');
      _run(zpaq, ['x', 'x.zpaq', '-to', 'o1'], tmp);
      expect(_tree('${tmp.path}/o1/src'), _tree('${tmp.path}/src'));
      _write(tmp, 'src/z.txt', _text(900, 12));
      _run(zpaq, ['a', 'x.zpaq', 'src', '-m2'], tmp);
      r = await _zx(tmp, ['x', 'x.zpaq', '-oo2', '-bso0']);
      expect(r.code, 0, reason: '$r');
      expect(_tree('${tmp.path}/o2/src'), _tree('${tmp.path}/src'));
      // zx deletes, zpaq sees the deletion and every older version
      r = await _zx(tmp, ['d', 'x.zpaq', 'src/a.txt', '-bso0']);
      expect(r.code, 0, reason: '$r');
      final l = _run(zpaq, ['l', 'x.zpaq'], tmp).stdout as String;
      expect(l, isNot(contains('src/a.txt')));
      expect(l, contains('src/z.txt'));
      final l1 =
          _run(zpaq, ['l', 'x.zpaq', '-until', '1'], tmp).stdout as String;
      expect(l1, contains('src/a.txt'));
      // encrypted, both ways
      r = await _zx(tmp, ['a', 'e.zpaq', 'src', '-pk', '-mx=3', '-bso0']);
      expect(r.code, 0, reason: '$r');
      _run(zpaq, ['x', 'e.zpaq', '-key', 'k', '-to', 'o3'], tmp);
      expect(_tree('${tmp.path}/o3/src'), _tree('${tmp.path}/src'));
      _run(zpaq, ['a', 'k.zpaq', 'src', '-key', 'k', '-m4'], tmp);
      r = await _zx(tmp, ['x', 'k.zpaq', '-pk', '-oo4', '-bso0']);
      expect(r.code, 0, reason: '$r');
      expect(_tree('${tmp.path}/o4'), isNotEmpty);
    }, skip: _zpaq == null ? 'zpaq not found (ZPAQ_BIN)' : false);

    test('zpaqfranz checks zx archives, zx reads zpaqfranz archives',
        () async {
      final franz = _franz!;
      _source();
      final r = await _zx(tmp, ['a', 'x.zpaq', 'src', '-bso0']);
      expect(r.code, 0, reason: '$r');
      final t = _run(franz, ['t', 'x.zpaq'], tmp).stdout as String;
      expect(t, isNot(contains('ERROR')));
      _run(franz, ['v', 'x.zpaq'], tmp);
      _run(franz, ['a', 'f.zpaq', 'src'], tmp);
      final r2 = await _zx(tmp, ['x', 'f.zpaq', '-oo', '-bso0']);
      expect(r2.code, 0, reason: '$r2');
      expect(_tree('${tmp.path}/o/src'), _tree('${tmp.path}/src'));
      final l = await _zx(tmp, ['l', '-slt', 'f.zpaq']);
      expect(l.out, contains('CRC = '));
    }, skip: _franz == null ? 'zpaqfranz not found (ZPAQFRANZ_BIN)' : false);
  });
}
