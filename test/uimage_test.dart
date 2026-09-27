// U-Boot legacy images made by mkimage (u-boot-tools, from PATH or
// ref/tools) with every compression, a multi-file image, damaged images
// and the kernel section of the real D340W firmware (skipped when absent).

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/format/archive_types.dart';
import 'package:zx/src/format/pak/pak_handler.dart';
import 'package:zx/src/format/uimage/uimage_handler.dart';
import 'package:zx/src/io/streams.dart';
import 'package:zx/zx.dart';

import 'codec_test_util.dart';

const _realPak = '/home/brito/code/xprs/firmware/models/reolink-d340w/'
    'firmware/stock/DB_566128M5MP_W.4662_2508071282.Reolink-Video-Doorbell-'
    'WiFi.OV05A10.5MP.WIFI8812.REOLINK.pak';

void main() {
  final mkimage = findTool('mkimage');
  late Directory tmp;
  late Uint8List payload;
  late String payloadPath;

  setUpAll(() {
    tmp = tempDir('uimage');
    payload = genData(200000, 7);
    payloadPath = '${tmp.path}/payload';
    File(payloadPath).writeAsBytesSync(payload);
  });
  tearDownAll(() => tmp.deleteSync(recursive: true));

  String mk(String comp, String data, String out,
      {String type = 'kernel', String name = 'Linux-test'}) {
    final r = Process.runSync(mkimage!, [
      '-A', 'arm', '-O', 'linux', '-T', type, '-C', comp, //
      '-a', '0x8000', '-e', '0x8040', '-n', name, '-d', data, out
    ]);
    if (r.exitCode != 0) throw StateError('mkimage: ${r.stderr}');
    return out;
  }

  // compression: (tool, arguments) writing the compressed payload to stdout
  final compressors = <String, List<(String, List<String>)>>{
    'none': [],
    'gzip': [
      ('gzip', ['-9c'])
    ],
    'bzip2': [
      ('bzip2', ['-c'])
    ],
    'lzma': [
      ('lzma', ['-c'])
    ],
    'lzo': [
      ('lzop', ['-c'])
    ],
    'lz4': [
      ('lz4', ['-q', '-c']),
      ('lz4', ['-q', '-l', '-c']),
      ('lz4', ['-q', '-BD', '-B4', '-c']),
    ],
    'zstd': [
      ('zstd', ['-q', '-c'])
    ],
  };

  for (final e in compressors.entries) {
    final comp = e.key;
    final variants = e.value.isEmpty ? [null] : e.value;
    for (var v = 0; v < variants.length; v++) {
      final variant = variants[v];
      final tool = variant == null ? 'mkimage' : variant.$1;
      final have = mkimage != null && findTool(tool) != null;
      test('$comp payload${variants.length > 1 ? ' $v' : ''}', () async {
        var data = payloadPath;
        if (variant != null) {
          data = '${tmp.path}/p.$comp.$v';
          File(data).writeAsBytesSync(
              runTool(findTool(variant.$1)!, [...variant.$2, payloadPath]));
        }
        final img = mk(comp, data, '${tmp.path}/$comp$v.img');
        final h = UImageHandler();
        final fs = FileInStream.open(img);
        try {
          expect(h.open(fs), isTrue);
          expect(h.numberOfItems, 1);
          expect(h.getProperty(0, Kpid.path), 'Linux-test.bin');
          expect(h.getProperty(0, Kpid.hostOS), 'linux');
          expect(h.getProperty(0, Kpid.cpu), 'arm');
          expect(h.getProperty(0, Kpid.characts), 'kernel');
          expect(h.getProperty(0, Kpid.va), 0x8000);
          expect(h.header.ep, 0x8040);
          expect(h.getArchiveProperty(Kpid.warningFlags), isNull);
          expect(h.getArchiveProperty(Kpid.errorFlags), 0);
          final size = h.getProperty(0, Kpid.size);
          if (size != null) expect(size, payload.length);
          final s = h.getStream(0)!;
          expect(sameBytes(readAll(s), payload), isTrue);
          // a backward seek of the decoded stream
          s.position = 1000;
          final b = Uint8List(10);
          readExactly(s, b, 0, 10);
          expect(b, payload.sublist(1000, 1010));
        } finally {
          fs.close();
        }
        // through the API, with a wrong extension
        final renamed = '${tmp.path}/renamed_$comp$v.zip';
        File(img).copySync(renamed);
        final z = await ZxArchive.open(renamed);
        expect(z.format, 'UImage');
        expect((await z.test()).ok, isTrue);
        expect(sameBytes(await z.readBytes(z.items.single), payload), isTrue);
      }, skip: have ? false : '$tool or mkimage missing');
    }
  }

  test('multi-file image', () {
    final gz = '${tmp.path}/m.gz';
    File(gz).writeAsBytesSync(runTool(findTool('gzip')!, ['-9c', payloadPath]));
    final odd = '${tmp.path}/odd';
    File(odd).writeAsBytesSync(payload.sublist(0, 1001));
    final img = mk('gzip', '$gz:$odd:$payloadPath', '${tmp.path}/multi.img',
        type: 'multi', name: 'multi');
    final h = UImageHandler();
    expect(h.open(MemoryInStream(File(img).readAsBytesSync())), isTrue);
    expect(h.numberOfItems, 3);
    expect([for (var i = 0; i < 3; i++) h.getProperty(i, Kpid.path)],
        ['multi.0.bin', 'multi.1.bin', 'multi.2.bin']);
    expect([for (var i = 0; i < 3; i++) h.getProperty(i, Kpid.method)],
        ['gzip', 'Copy', 'Copy']);
    expect(sameBytes(readAll(h.getStream(0)!), payload), isTrue);
    expect(readAll(h.getStream(1)!), payload.sublist(0, 1001));
    expect(sameBytes(readAll(h.getStream(2)!), payload), isTrue);
  }, skip: mkimage == null ? 'mkimage missing' : false);

  test('damaged images', () async {
    final img = mk('none', payloadPath, '${tmp.path}/d.img');
    final data = File(img).readAsBytesSync();
    // a data byte: CRC warning, extraction reports a CRC error
    final d1 = Uint8List.fromList(data);
    d1[5000] ^= 0xFF;
    final h = UImageHandler();
    expect(h.open(MemoryInStream(d1)), isTrue);
    expect(h.getArchiveProperty(Kpid.warningFlags), ErrorFlags.crcError);
    final p = '${tmp.path}/d1.img';
    File(p).writeAsBytesSync(d1);
    final z = await ZxArchive.open(p);
    final r = await z.test();
    expect(r.ok, isFalse);
    expect(r.errors.single.kind, SevenZipError.crc);
    // the name: header CRC error
    final d2 = Uint8List.fromList(data);
    d2[40] ^= 1;
    expect(h.open(MemoryInStream(d2)), isTrue);
    expect(h.getArchiveProperty(Kpid.errorFlags), ErrorFlags.headersError);
    // truncated
    final d3 = Uint8List.sublistView(data, 0, 1000);
    expect(h.open(MemoryInStream(d3)), isTrue);
    expect(
        h.getArchiveProperty(Kpid.errorFlags) as int, ErrorFlags.unexpectedEnd);
  }, skip: mkimage == null ? 'mkimage missing' : false);

  test('kernel section of the real firmware', () {
    final fs = FileInStream.open(_realPak);
    try {
      final pak = PakHandler();
      expect(pak.open(fs), isTrue);
      final k = [
        for (var i = 0; i < pak.numberOfItems; i++)
          if (pak.getProperty(i, Kpid.path) == 'kernel') i
      ].single;
      final h = UImageHandler();
      expect(h.open(pak.getStream(k)!), isTrue);
      expect(h.header.name, 'Linux-4.19.91');
      expect(h.header.osName, 'linux');
      expect(h.header.archName, 'arm');
      expect(h.header.typeName, 'kernel');
      expect(h.header.compName, 'none');
      expect(h.header.load, 0x8000);
      expect(h.getArchiveProperty(Kpid.warningFlags), isNull);
      expect(h.getArchiveProperty(Kpid.errorFlags), 0);
      expect(h.getProperty(0, Kpid.size), 1710664);
      final data = readAll(h.getStream(0)!);
      expect(Crc32.of(data), h.header.dcrc);
    } finally {
      fs.close();
    }
  }, skip: File(_realPak).existsSync() ? false : 'firmware missing');
}
