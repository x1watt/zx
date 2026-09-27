// Flattened device trees: blobs compiled by dtc (from PATH or ref/tools)
// from sources that cover the value heuristics, and the real D340W blobs
// (skipped when absent). The generated .dts must equal `dtc -I dtb -O dts`.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/format/fdt/fdt_handler.dart';
import 'package:zx/src/format/pak/pak_handler.dart';
import 'package:zx/zx.dart';

import 'codec_test_util.dart';

const _appDtb = '/home/brito/code/2026/reolink/cameras/D340W/firmware/'
    'unpacked/rootfs/153830686/rootfs/etc/application.dtb';
const _realPak = '/home/brito/code/xprs/firmware/models/reolink-d340w/'
    'firmware/stock/DB_566128M5MP_W.4662_2508071282.Reolink-Video-Doorbell-'
    'WiFi.OV05A10.5MP.WIFI8812.REOLINK.pak';

const _source = r'''
/dts-v1/;
/memreserve/ 0x10000000 0x4000;
/memreserve/ 0x20000000 0x100;
/ {
	model = "zx test board";
	compatible = "zx,test", "zx,generic";
	#address-cells = <1>;
	#size-cells = <1>;
	s1 = "quote\"back\\nl\ntab\tbell\a";
	s2 = "a", "", "b";
	s3 = "";
	s5 = [c3 a9 00];
	s6 = [41 42];
	s8 = [01 41 00];
	s9 = [7f 41 00];
	s10 = [41 00 00];
	s11 = [00 41 00];
	s12 = [08 0c 0b 0d 00];
	s13 = [1b 41 00];
	s14 = [41 41 00 00 41 00];
	s15 = [41 41 00 00 00];
	s16 = [00 41 42 43 44 00];
	s17 = [41 00 00 00];
	b1 = [01 02 03];
	b2 = [01 02 03 04 05 06 07 08];
	c1 = <0x12345678 0x0 0xffffffff 5>;
	e1;
	w = /bits/ 16 <1 2 3>;
	cpus {
		#address-cells = <1>;
		#size-cells = <0>;
		cpu@0 {
			device_type = "cpu";
			reg = <0>;
		};
	};
	lbl: n1 { p = <1>; child@1 { }; };
	n2 { };
	empty-parent { inner { v = "x"; }; };
};
''';

String _dtcDts(String dtc, String dtb) {
  final r = Process.runSync(dtc, ['-q', '-I', 'dtb', '-O', 'dts', dtb]);
  if (r.exitCode != 0) throw StateError('dtc: ${r.stderr}');
  return r.stdout as String;
}

void main() {
  final dtc = findTool('dtc');
  late Directory tmp;
  setUpAll(() => tmp = tempDir('fdt'));
  tearDownAll(() => tmp.deleteSync(recursive: true));

  test('blob compiled by dtc', () async {
    File('${tmp.path}/t.dts').writeAsStringSync(_source);
    final dtb = '${tmp.path}/board.dtb';
    final r = Process.runSync(
        dtc!, ['-q', '-I', 'dts', '-O', 'dtb', '-o', dtb, '${tmp.path}/t.dts']);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    final h = FdtHandler();
    expect(
        h.open(MemoryInStream(File(dtb).readAsBytesSync()), name: dtb), isTrue);
    expect(utf8.decode(h.dtsText), _dtcDts(dtc, dtb));
    final paths = [
      for (var i = 0; i < h.numberOfItems; i++)
        (h.getProperty(i, Kpid.path) as String, h.getProperty(i, Kpid.isDir))
    ];
    expect(paths.first, ('board.dts', false));
    expect(paths, contains(('cpus', true)));
    expect(paths, contains(('cpus/cpu@0', true)));
    expect(paths, contains(('cpus/cpu@0/reg', false)));
    expect(paths, contains(('empty-parent/inner/v', false)));
    expect(paths, contains(('n1/child@1', true)));
    Uint8List value(String p) {
      final i = paths.indexWhere((e) => e.$1 == p);
      return readAll(h.getStream(i)!);
    }

    expect(value('model'), utf8.encode('zx test board\x00'));
    expect(value('c1'), [
      0x12,
      0x34,
      0x56,
      0x78,
      0,
      0,
      0,
      0,
      0xff,
      0xff,
      0xff,
      0xff,
      0,
      0,
      0,
      5
    ]);
    expect(value('e1'), isEmpty);
    expect(value('cpus/cpu@0/device_type'), utf8.encode('cpu\x00'));

    // through the API, with no extension
    final noExt = '${tmp.path}/blob';
    File(dtb).copySync(noExt);
    final z = await ZxArchive.open(noExt);
    expect(z.format, 'Fdt');
    expect((await z.test()).ok, isTrue);
    expect(z.items.first.path, 'blob.dts');
    expect(utf8.decode(await z.readBytes(z.items.first)), _dtcDts(dtc, dtb));
  }, skip: dtc == null ? 'dtc missing' : false);

  test('application.dtb of the D340W rootfs', () {
    final h = FdtHandler();
    final fs = FileInStream.open(_appDtb);
    try {
      expect(h.open(fs, name: _appDtb), isTrue);
    } finally {
      fs.close();
    }
    expect(utf8.decode(h.dtsText), _dtcDts(dtc!, _appDtb));
    expect(h.getProperty(0, Kpid.path), 'application.dts');
    expect(h.getArchiveProperty(Kpid.errorFlags), 0);
  },
      skip: dtc == null || !File(_appDtb).existsSync()
          ? 'dtc or sample missing'
          : false);

  test('fdt section of the D340W firmware', () {
    final fs = FileInStream.open(_realPak);
    try {
      final pak = PakHandler();
      expect(pak.open(fs), isTrue);
      final k = [
        for (var i = 0; i < pak.numberOfItems; i++)
          if (pak.getProperty(i, Kpid.path) == 'fdt') i
      ].single;
      final blob = readAll(pak.getStream(k)!);
      final path = '${tmp.path}/fdt.dtb';
      File(path).writeAsBytesSync(blob);
      final h = FdtHandler();
      expect(h.open(MemoryInStream(blob), name: 'fdt'), isTrue);
      expect(h.getProperty(0, Kpid.path), 'fdt.dts');
      expect(utf8.decode(h.dtsText), _dtcDts(dtc!, path));
      final paths = [
        for (var i = 0; i < h.numberOfItems; i++) h.getProperty(i, Kpid.path)
      ];
      expect(paths, contains('model'));
      expect(paths, contains('cpus/cpu@0/compatible'));
      expect(h.getArchiveProperty(Kpid.errorFlags), 0);
    } finally {
      fs.close();
    }
  },
      skip: dtc == null || !File(_realPak).existsSync()
          ? 'dtc or firmware missing'
          : false);
}
