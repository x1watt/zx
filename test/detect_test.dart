// Format detection without a usable file name: every format renamed with
// no extension and with a wrong one must open as itself, and a compressed
// tar made in a pipe (no stored name) must open as a tar.

import 'dart:io';

import 'package:test/test.dart';
import 'package:zx/zx.dart';

void main() {
  late Directory tmp;
  late Directory src;

  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('zx_detect_test');
    src = Directory('${tmp.path}/src')..createSync();
    File('${src.path}/a.txt').writeAsStringSync('hello detection\n' * 50);
    Directory('${src.path}/d').createSync();
    File('${src.path}/d/b.bin')
        .writeAsBytesSync(List.generate(5000, (i) => (i * 7) & 0xFF));
  });

  tearDownAll(() => tmp.deleteSync(recursive: true));

  // extension to create with: expected (outer formats, format)
  const multi = {
    '7z': ([], '7z'),
    'zip': ([], 'zip'),
    'jar': ([], 'zip'),
    'tar': ([], 'tar'),
    'tar.gz': (['gzip'], 'tar'),
    'tar.bz2': (['bzip2'], 'tar'),
    'tar.xz': (['xz'], 'tar'),
    'rar': ([], 'Rar5'),
    'arj': ([], 'Arj'),
    'lzh': ([], 'Lzh'),
  };
  const single = {'gz': 'gzip', 'bz2': 'bzip2', 'xz': 'xz', 'lzma': 'lzma'};

  Future<void> check(String path, List<dynamic> outer, String format) async {
    final z = await ZxArchive.open(path);
    expect(z.format, format, reason: path);
    expect(z.outerFormats, outer, reason: path);
    final r = await z.test();
    expect(r.ok, isTrue, reason: path);
  }

  for (final e in multi.entries) {
    test('${e.key} without extension and with a wrong one', () async {
      final a = '${tmp.path}/m.${e.key}';
      await ZxArchive.create(
          a, [ZxSource('${src.path}/a.txt'), ZxSource('${src.path}/d')]);
      for (final name in [
        'm_${e.key.replaceAll('.', '_')}',
        'm_${e.key.replaceAll('.', '_')}.txt',
        'm_${e.key.replaceAll('.', '_')}.zip'
      ]) {
        final p = '${tmp.path}/$name';
        File(a).copySync(p);
        // a tar.* copied under another name keeps its stored name "m.tar",
        // so it is found by name; the pipe test below covers the sniffing
        await check(p, e.value.$1, e.value.$2);
      }
    });
  }

  for (final e in single.entries) {
    test('${e.key} without extension', () async {
      final a = '${tmp.path}/s.txt.${e.key}';
      await ZxArchive.create(a, [ZxSource('${src.path}/a.txt')]);
      final p = '${tmp.path}/s_${e.key}';
      File(a).copySync(p);
      await check(p, [], e.value);
    });
  }

  final haveTar = File('/usr/bin/tar').existsSync();
  for (final (flag, outer) in [('z', 'gzip'), ('j', 'bzip2'), ('J', 'xz')]) {
    test('tar c$flag from a pipe, no extension, opens as tar', () async {
      final p = '${tmp.path}/pipe_$flag';
      final r = await Process.run(
          '/bin/sh', ['-c', 'tar c${flag}f - src > "$p"'],
          workingDirectory: tmp.path);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      await check(p, [outer], 'tar');
      final z = await ZxArchive.open(p);
      expect(z['src/a.txt'], isNotNull);
      // and it is updated as a compressed tar
      await z.add([ZxSource('${src.path}/a.txt')], destination: 'new');
      final z2 = await ZxArchive.open(p);
      expect(z2.outerFormats, [outer]);
      expect(z2['new/a.txt'], isNotNull);
    }, skip: haveTar ? false : 'no /usr/bin/tar');
  }

  test('a compressed file that is not a tar stays single level', () async {
    final a = '${tmp.path}/plain.gz';
    await ZxArchive.create(a, [ZxSource('${src.path}/d/b.bin')]);
    final p = '${tmp.path}/plain_noext';
    File(a).copySync(p);
    await check(p, [], 'gzip');
  });

  test('not an archive is refused', () async {
    final p = '${tmp.path}/junk';
    File(p).writeAsStringSync('this is not an archive at all\n' * 100);
    await expectLater(
        ZxArchive.open(p),
        throwsA(isA<SevenZipException>()
            .having((e) => e.kind, 'kind', SevenZipError.isNotArc)));
  });
}
