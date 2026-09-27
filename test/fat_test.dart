// FAT12, FAT16 and FAT32 volumes made with mkfs.vfat and filled with
// mcopy (skipped when dosfstools or mtools are missing; mtools can be
// fetched into ref/tools/root with apt-get download). Listings are
// compared with mdir and 7-Zip, extracted trees with the source tree.
// Hand edits check deleted entries, a long name with a wrong checksum,
// the attributes and the case flags of 8.3 names.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/format/fat/fat_handler.dart';
import 'package:zx/zx.dart';

import 'codec_test_util.dart';

final String? _mkfs = findTool('mkfs.vfat') ?? findTool('mkfs.fat');
final String? _mcopy = findTool('mcopy');

Map<String, String> get _mtoolsEnv => {
      'LC_ALL': 'C.UTF-8',
      'MTOOLS_SKIP_CHECK': '1',
      'PATH': '${Platform.environment['PATH']}:'
          '${File('ref/tools/root/usr/bin').absolute.path}',
    };

void _mtool(String name, List<String> args) {
  final t = findTool(name)!;
  final r = Process.runSync(t, args, environment: _mtoolsEnv);
  if (r.exitCode != 0) throw StateError('$name ${args.join(' ')}: ${r.stderr}');
}

List<String> _mdir(String img) {
  final r = Process.runSync(findTool('mdir')!, ['-/', '-b', '-i', img, '::'],
      environment: _mtoolsEnv);
  return [
    for (final l in (r.stdout as String).split('\n'))
      if (l.startsWith('::/'))
        l.substring(3).endsWith('/')
            ? l.substring(3, l.length - 1)
            : l.substring(3)
  ]..sort();
}

void _makeTree(String src) {
  Directory('$src/a/b/c/d/e/f/g/h').createSync(recursive: true);
  File('$src/a/b/c/d/e/f/g/h/deep.txt').writeAsStringSync('deep\n');
  Directory('$src/big').createSync();
  for (var i = 1; i <= 120; i++) {
    File('$src/big/a rather long file name number $i.txt')
        .writeAsStringSync('$i\n');
  }
  File('$src/big/rand.bin').writeAsBytesSync(randomData(300000, 3));
  File('$src/empty').writeAsBytesSync([]);
  Directory('$src/uni/Ordner \u00fc').createSync(recursive: true);
  File('$src/uni/Gr\u00fc\u00dfe \u2603 \u65e5\u672c.txt').writeAsStringSync('unicode\n');
  Directory('$src/UPPER').createSync();
  File('$src/UPPER/SHORT.TXT').writeAsStringSync('upper\n');
  File('$src/lower.txt').writeAsStringSync('lower\n');
  File('$src/Mixed Case Name.Text').writeAsStringSync('mixed\n');
  File('$src/MiXeD.TxT').writeAsStringSync('mixed2\n');
}

int _find(Uint8List b, List<int> pat) {
  outer:
  for (var i = 0; i + pat.length <= b.length; i++) {
    for (var k = 0; k < pat.length; k++) {
      if (b[i + k] != pat[k]) continue outer;
    }
    return i;
  }
  return -1;
}

void main() {
  late Directory tmp;
  late String src;

  setUpAll(() {
    tmp = tempDir('fat');
    src = '${tmp.path}/src';
    Directory(src).createSync();
    _makeTree(src);
  });
  tearDownAll(() => tmp.deleteSync(recursive: true));

  final skip = _mkfs == null
      ? 'mkfs.vfat missing'
      : _mcopy == null
          ? 'mtools missing'
          : false;

  for (final (bits, kib, extra) in [
    (12, 12000, ['-s', '8']),
    (16, 20000, <String>[]),
    (32, 40000, <String>[]),
    (32, 40000, ['-S', '4096']),
  ]) {
    final name = 'fat$bits${extra.isEmpty ? '' : extra.join()}';
    test('mkfs.vfat -F $bits ${extra.join(' ')}', () async {
      final img = '${tmp.path}/$name.img';
      final r = Process.runSync(_mkfs!,
          ['-C', '-F', '$bits', ...extra, '-n', 'LBL$bits', img, '$kib']);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      _mtool('mcopy', [
        '-s',
        '-m',
        '-i',
        img,
        for (final e in Directory(src).listSync()) e.path,
        '::/'
      ]);

      final h = FatHandler();
      final s = FileInStream(File(img).openSync());
      expect(h.open(s), isTrue);
      expect(h.fatBits, bits);
      expect(h.label, 'LBL$bits');
      expect(h.getArchiveProperty(Kpid.errorFlags), 0);
      expect([for (final it in h.items) it.path]..sort(), _mdir(img));
      final mixed = h.items.firstWhere((e) => e.path == 'Mixed Case Name.Text');
      expect(mixed.shortName, 'MIXEDC~1.TEX');
      expect(h.items.firstWhere((e) => e.path == 'lower.txt').shortName,
          'lower.txt');
      // times: modification kept by mcopy -m (2 second steps)
      final it = h.items.firstWhere((e) => e.path == 'big/rand.bin');
      final st = File('$src/big/rand.bin').statSync();
      final secs = (it.mTime! - 116444736000000000) ~/ 10000000;
      expect((secs - st.modified.millisecondsSinceEpoch ~/ 1000).abs(),
          lessThanOrEqualTo(2));
      expect(it.cTime, isNotNull);
      expect(it.aTime, isNotNull);
      s.raf.closeSync();

      if (findTool('7z') != null) {
        final l =
            Process.runSync('7z', ['l', '-slt', img], stdoutEncoding: null);
        final text = utf8.decode(l.stdout as List<int>, allowMalformed: true);
        final paths = RegExp(r'^Path = (.*)$', multiLine: true)
            .allMatches(text)
            .map((m) => m.group(1)!)
            .skip(1)
            .toList();
        final ours = <String>[for (final it in h.items) it.path];
        expect(ours..sort(), paths..sort());
      }

      // extraction through the API, with no extension
      final plain = '${tmp.path}/$name';
      File(img).copySync(plain);
      final z = await ZxArchive.open(plain);
      expect(z.format, 'FAT');
      expect((await z.test()).ok, isTrue);
      final out = '${tmp.path}/out_$name';
      final res = await z.extract(out);
      expect(res.errors, isEmpty);
      final diff = Process.runSync('diff', ['-r', src, out]);
      expect(diff.exitCode, 0, reason: '${diff.stdout}');
    }, skip: skip);
  }

  test('deleted entries, a bad long name checksum, attributes', () {
    final img = '${tmp.path}/edit.img';
    Process.runSync(_mkfs!, ['-C', '-F', '16', img, '20000']);
    _mtool('mcopy', [
      '-i',
      img,
      '$src/Mixed Case Name.Text',
      '$src/lower.txt',
      '$src/MiXeD.TxT',
      '::/'
    ]);
    _mtool('mattrib', ['-i', img, '+r', '+h', '+s', '::/lower.txt']);
    _mtool('mdel', ['-i', img, '::/MiXeD.TxT']);
    final data = File(img).readAsBytesSync();
    // the first long name entry of "Mixed Case Name.Text": its checksum
    // byte is at 13
    final u = [
      for (final c in 'Mixed'.codeUnits) ...[c, 0]
    ];
    final p = _find(data, u);
    expect(p, greaterThan(0));
    final entry = p - 1;
    data[entry + 13] ^= 0xFF;
    final h = FatHandler();
    expect(h.open(MemoryInStream(data)), isTrue);
    final names = [for (final it in h.items) it.path]..sort();
    // the deleted file is gone, the name with a bad checksum falls back to
    // the 8.3 name
    expect(names, ['MIXEDC~1.TEX', 'lower.txt']);
    final low = h.items.firstWhere((e) => e.path == 'lower.txt');
    expect(low.attrib & 0x07, 0x07);
    final i = h.items.indexOf(low);
    expect(h.getProperty(i, Kpid.attrib), low.attrib);
    final cb = h.getStream(i)!;
    expect(readAll(cb), 'lower\n'.codeUnits);
  }, skip: skip);

  test('not FAT: an MBR, random data, a short buffer', () {
    final mbr = Uint8List(512);
    mbr[510] = 0x55;
    mbr[511] = 0xAA;
    expect(isArcFat(mbr, 512), 0);
    expect(isArcFat(randomData(512, 2), 512), 0);
    expect(isArcFat(Uint8List(100), 100), 2);
  });
}
