// Tests of the self-extracting .zx archives (x.zx.sfx, zx_sfx.dart): zx
// opens the archive after the stub and refuses to update it, the check of
// what the decoder reads, and, on Linux with sh, the archive extracting
// itself through its engine and decoder (native/sfx).

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/codec/zcm/zcm.dart' show zcmCodecId;
import 'package:zx/src/format/archive_types.dart' show Kpid;
import 'package:zx/src/format/zx/zx_codecs.dart';
import 'package:zx/src/format/zx/zx_format.dart';
import 'package:zx/src/format/zx/zx_reader.dart';
import 'package:zx/src/format/zx/zx_sfx.dart';
import 'package:zx/src/format/zx/zx_sfx_payload.dart';
import 'package:zx/src/format/zx/zx_writer.dart' show ZxWriteOptions;
import 'package:zx/src/io/streams.dart';

import 'zx_test_util.dart';

Map<String, Uint8List?> _files() => {
      'dir': null,
      'dir/a.txt': textBytes(40000, 1),
      'dir/b.bin': lcgBytes(20000, 2),
      'c.txt': textBytes(3000, 3),
      'empty': Uint8List(0),
    };

Uint8List _sfx(Uint8List archive, [List<String> arches = const ['x86_64']]) =>
    Uint8List.fromList([...zxSfxPrefix(arches), ...archive]);

String? _check(Uint8List archive) {
  final r = ZxArchiveReader.open(MemoryInStream(archive), ZxOpenParams())!;
  return zxSfxCheck(
      r, (off, len) => Uint8List.sublistView(archive, off, off + len));
}

// The host CPU as the stub names it, or null.
String? _hostArch() {
  try {
    final m = (Process.runSync('uname', ['-m']).stdout as String).trim();
    return switch (m) {
      'x86_64' || 'amd64' => 'x86_64',
      'aarch64' || 'arm64' => 'aarch64',
      _ => null,
    };
  } on Object {
    return null;
  }
}

void main() {
  final hasPayload = zxSfxDecoder().isNotEmpty;

  test('zx opens the archive after the stub', () {
    final files = _files();
    final a = makeArchive(files, testOptions());
    final s = _sfx(a);
    expect(zxSfxArchiveStart(MemoryInStream(s)), s.length - a.length);
    expect(zxSfxArchiveStart(MemoryInStream(a)), isNull);
    final h = openMem(s);
    expect(h.isSelfExtracting, isTrue);
    final x = MemExtract();
    h.extract(null, false, x);
    for (var i = 0; i < h.numberOfItems; i++) {
      final p = h.getProperty(i, Kpid.path) as String;
      final d = files[p];
      if (d != null) expect(x.data[i]!.toBytes(), d, reason: p);
    }
  }, skip: hasPayload ? null : 'tool/build_sfx.sh not run');

  test('the check accepts what the decoder reads', () {
    final o = testOptions();
    expect(_check(makeArchive(_files(), o)), isNull);
    o.coders = const [
      ZxCoderSpec(ZxCodecId.bcj),
      ZxCoderSpec(ZxCodecId.lzma, ZxCoderConfig(level: 1)),
    ];
    expect(_check(makeArchive(_files(), o)), isNull);
    o.coders = const [
      ZxCoderSpec(zcmCodecId, ZxCoderConfig(level: 5, params: 'level=2'))
    ];
    expect(_check(makeArchive(_files(), o)), isNull);
  });

  test('the check refuses what the decoder does not read', () {
    final o = testOptions()
      ..coders = const [ZxCoderSpec(ZxCodecId.ppmd7, ZxCoderConfig(level: 5))];
    expect(_check(makeArchive(_files(), o)), contains('does not read'));
    final o2 = testOptions()..checkType = ZxCheck.blake2sp;
    expect(_check(makeArchive(_files(), o2)), contains('checks blocks'));
  });

  group('sh x.zx.sfx', () {
    final arch = _hostArch();
    final skip = !Platform.isLinux || arch == null
        ? 'needs Linux on x86_64 or aarch64'
        : (hasPayload ? null : 'tool/build_sfx.sh not run');

    void run(String name, void Function(ZxWriteOptions o) set,
        {String? password}) {
      test(name, () {
        final files = _files();
        final o = testOptions();
        set(o);
        final dir = Directory.systemTemp.createTempSync('zxsfx');
        try {
          final f = File('${dir.path}/t.zx.sfx')
            ..writeAsBytesSync(_sfx(makeArchive(files, o), [arch!]));
          final r = Process.runSync('sh', [
            f.path,
            '-q',
            if (password != null) '-p$password',
            '-o',
            '${dir.path}/out'
          ]);
          expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
          for (final e in files.entries) {
            final p = '${dir.path}/out/${e.key}';
            if (e.value == null) {
              expect(Directory(p).existsSync(), isTrue, reason: e.key);
            } else {
              expect(File(p).readAsBytesSync(), e.value, reason: e.key);
            }
          }
          final t = Process.runSync(
              'sh', [f.path, '-t', if (password != null) '-p$password']);
          expect(t.exitCode, 0, reason: '${t.stdout}${t.stderr}');
          expect(t.stdout as String, contains('Everything is OK'));
        } finally {
          dir.deleteSync(recursive: true);
        }
      }, skip: skip);
    }

    run('LZMA2', (o) {});
    run('encrypted', (o) => o.password = 'secret', password: 'secret');
    run('BCJ and LZMA', (o) {
      o.coders = const [
        ZxCoderSpec(ZxCodecId.bcj),
        ZxCoderSpec(ZxCodecId.lzma, ZxCoderConfig(level: 1)),
      ];
    });
    for (final level in [1, 2, 5]) {
      run('zcm level $level', (o) {
        o.coders = [
          ZxCoderSpec(
              zcmCodecId, ZxCoderConfig(level: 5, params: 'level=$level'))
        ];
      });
    }
  });
}
