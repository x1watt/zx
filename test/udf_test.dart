// UDF volumes: ISO/UDF bridge discs made by genisoimage -udf (UDF 1.02,
// compared with the system 7z), images made by pycdlib (symbolic links,
// UCS-2 names), empty volumes made by mkudffs for every media type,
// revision and block size it supports (type 1, sparable and VAT partition
// maps, 512 to 4096 byte blocks), and hand made UDF 2.50/2.01 volumes for
// what no tool here writes files to: a metadata partition (and its mirror),
// a VAT, a remapped packet of a sparable partition, allocation extent
// descriptors, unrecorded extents, embedded data, hidden and deleted
// entries. Tools missing: those tests are skipped.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/format/udf/udf_handler.dart';
import 'package:zx/zx.dart';

import 'codec_test_util.dart';
import 'iso_test.dart' show treeOf, sevenZipList, zxList;

String? _findSbin(String name) {
  final local = File('ref/tools/root/usr/sbin/$name');
  if (local.existsSync()) return local.absolute.path;
  for (final d in ['/usr/sbin', '/sbin', '/usr/bin']) {
    if (File('$d/$name').existsSync()) return '$d/$name';
  }
  return null;
}

// ---------- a small UDF image writer for the hand made volumes ----------

class _Img {
  static const ss = 2048;
  final Uint8List b;
  _Img(int sectors) : b = Uint8List(sectors * ss);

  void w16(int o, int v) {
    b[o] = v & 0xFF;
    b[o + 1] = (v >> 8) & 0xFF;
  }

  void w32(int o, int v) {
    w16(o, v & 0xFFFF);
    w16(o + 2, (v >> 16) & 0xFFFF);
  }

  void w64(int o, int v) {
    w32(o, v & 0xFFFFFFFF);
    w32(o + 4, v >> 32);
  }

  void bytes(int o, List<int> v) => b.setRange(o, o + v.length, v);

  /// Descriptor tag at [o] (the checksum covers the tag only).
  void tag(int o, int id, int loc) {
    w16(o, id);
    w16(o + 2, 3);
    w32(o + 12, loc);
    var sum = 0;
    for (var i = 0; i < 16; i++) {
      if (i != 4) sum += b[o + i];
    }
    b[o + 4] = sum & 0xFF;
  }

  void dstring(int o, int n, String s) {
    b[o] = 8;
    bytes(o + 1, latin1.encode(s));
    b[o + n - 1] = 1 + s.length;
  }

  void regid(int o, String ident, [int rev = 0]) {
    bytes(o + 1, ascii.encode(ident));
    if (rev != 0) w16(o + 24, rev);
  }

  void timestamp(int o) {
    w16(o, 0x1000);
    w16(o + 2, 2024);
    b[o + 4] = 5;
    b[o + 5] = 6;
    b[o + 6] = 7;
    b[o + 7] = 8;
    b[o + 8] = 9;
  }

  /// VRS, anchor at 256, and the main volume descriptor sequence at 32:
  /// primary, partition, logical volume and terminating descriptors.
  void volume(
      {required int partStart,
      required int partLen,
      required List<int> maps,
      required int numMaps,
      required int fsdLbn,
      required int fsdRef,
      int rev = 0x0250}) {
    for (final (i, id) in ['BEA01', 'NSR03', 'TEA01'].indexed) {
      final o = (16 + i) * ss;
      b[o] = 0;
      bytes(o + 1, ascii.encode(id));
      b[o + 6] = 1;
    }
    var o = 256 * ss;
    w32(o + 16, 16 * ss);
    w32(o + 20, 32);
    w32(o + 24, 16 * ss);
    w32(o + 28, 32);
    tag(o, 2, 256);
    // primary volume descriptor
    o = 32 * ss;
    w32(o + 16, 1);
    dstring(o + 24, 32, 'HANDVOL');
    w16(o + 56, 1);
    dstring(o + 72, 128, 'HANDSET');
    timestamp(o + 376);
    regid(o + 388, '*zx test');
    tag(o, 1, 32);
    // partition descriptor
    o = 33 * ss;
    w32(o + 16, 2);
    w16(o + 20, 1);
    w16(o + 22, 0);
    regid(o + 24, '+NSR03');
    w32(o + 184, 1);
    w32(o + 188, partStart);
    w32(o + 192, partLen);
    tag(o, 5, 33);
    // logical volume descriptor
    o = 34 * ss;
    w32(o + 16, 3);
    dstring(o + 84, 128, 'HANDLV');
    w32(o + 212, ss);
    regid(o + 216, '*OSTA UDF Compliant', rev);
    w32(o + 248, ss);
    w32(o + 252, fsdLbn);
    w16(o + 256, fsdRef);
    w32(o + 264, maps.length);
    w32(o + 268, numMaps);
    bytes(o + 440, maps);
    tag(o, 6, 34);
    tag(35 * ss, 8, 35);
  }

  static List<int> type1Map(int part) => [1, 6, 1, 0, part & 0xFF, part >> 8];

  static List<int> type2Map(String ident, List<int> tail) {
    final m = Uint8List(64);
    m[0] = 2;
    m[1] = 64;
    m.setRange(5, 5 + ident.length, ascii.encode(ident));
    m[36] = 1; // volume sequence number
    m.setRange(40, 40 + tail.length, tail);
    return m;
  }

  /// File set descriptor at [sector], root directory ICB at (rootLbn,
  /// rootRef).
  void fsd(int sector, int loc, int rootLbn, int rootRef) {
    final o = sector * ss;
    timestamp(o + 16);
    dstring(o + 304, 32, 'HANDFS');
    w32(o + 400, ss);
    w32(o + 404, rootLbn);
    w16(o + 408, rootRef);
    regid(o + 416, '*OSTA UDF Compliant', 0x0250);
    tag(o, 256, loc);
  }

  /// A file entry (extended unless [plain]) at [sector] with the
  /// allocation descriptors (or embedded data) [ad] of type [adType].
  void fileEntry(int sector, int loc,
      {required int fileType,
      required int infoLen,
      required int adType,
      required List<int> ad,
      int perms = 0x14A5, // rwxr-xr-x
      int lbRecorded = 0,
      bool plain = false}) {
    final o = sector * ss;
    w16(o + 16 + 4, 4); // strategy 4
    w16(o + 16 + 8, 1);
    b[o + 16 + 11] = fileType;
    w16(o + 16 + 18, adType);
    w32(o + 36, 1000);
    w32(o + 40, 100);
    w32(o + 44, perms);
    w16(o + 48, 1);
    w64(o + 56, infoLen);
    if (plain) {
      w64(o + 64, lbRecorded);
      timestamp(o + 72);
      timestamp(o + 84);
      timestamp(o + 96);
      w32(o + 172, ad.length);
      bytes(o + 176, ad);
      tag(o, 261, loc);
    } else {
      w64(o + 64, infoLen);
      w64(o + 72, lbRecorded);
      timestamp(o + 80);
      timestamp(o + 92);
      timestamp(o + 104);
      timestamp(o + 116);
      w32(o + 212, ad.length);
      bytes(o + 216, ad);
      tag(o, 266, loc);
    }
  }

  static List<int> shortAd(int len, int pos, [int type = 0]) {
    final r = Uint8List(8);
    final l = len | (type << 30);
    for (var i = 0; i < 4; i++) {
      r[i] = (l >> (8 * i)) & 0xFF;
      r[4 + i] = (pos >> (8 * i)) & 0xFF;
    }
    return r;
  }

  static List<int> longAd(int len, int lbn, int ref, [int type = 0]) {
    final r = Uint8List(16);
    final l = len | (type << 30);
    for (var i = 0; i < 4; i++) {
      r[i] = (l >> (8 * i)) & 0xFF;
      r[4 + i] = (lbn >> (8 * i)) & 0xFF;
    }
    r[8] = ref & 0xFF;
    r[9] = ref >> 8;
    return r;
  }

  /// A file identifier descriptor (padded to 4 bytes).
  static List<int> fid(String name, int lbn, int ref,
      {int chars = 0, bool ucs2 = false}) {
    final nameBytes = <int>[];
    if (name.isNotEmpty) {
      if (ucs2) {
        nameBytes.add(16);
        for (final c in name.codeUnits) {
          nameBytes.addAll([c >> 8, c & 0xFF]);
        }
      } else {
        nameBytes.add(8);
        nameBytes.addAll(latin1.encode(name));
      }
    }
    final len = (38 + nameBytes.length + 3) & ~3;
    final t = _Img(1);
    t.w16(16, 1);
    t.b[18] = chars;
    t.b[19] = nameBytes.length;
    t.bytes(20, longAd(2048, lbn, ref));
    t.bytes(38, nameBytes);
    t.tag(0, 257, 0);
    return t.b.sublist(0, len);
  }

  static List<int> pathComponent(int type, String name) {
    final n = name.isEmpty ? <int>[] : [8, ...latin1.encode(name)];
    return [type, n.length, 0, 0, ...n];
  }
}

/// The hand made UDF 2.50 volume with a metadata partition.
Uint8List metadataVolume({bool breakMain = false}) {
  final img = _Img(560);
  const p = 300; // partition start
  img.volume(
      partStart: p,
      partLen: 260,
      maps: [
        ..._Img.type1Map(0),
        ..._Img.type2Map('*UDF Metadata Partition', [
          0, 0, 0, 0, // metadata file at block 0
          1, 0, 0, 0, // mirror at block 1
          0xFF, 0xFF, 0xFF, 0xFF, // no bitmap
          32, 0, 0, 0, 1, 0, 0,
        ]),
      ],
      numMaps: 2,
      fsdLbn: 0,
      fsdRef: 1);
  // the metadata file and its mirror: metadata blocks 0-4 at partition
  // blocks 10-14, 5-9 at 40-44
  for (final lbn in [0, 1]) {
    img.fileEntry(p + lbn, lbn,
        fileType: lbn == 0 ? 250 : 251,
        infoLen: 10 * 2048,
        adType: 0,
        ad: [..._Img.shortAd(5 * 2048, 10), ..._Img.shortAd(5 * 2048, 40)]);
  }
  if (breakMain) img.b.fillRange(p * 2048, p * 2048 + 2048, 0);
  int meta(int lbn) => lbn < 5 ? p + 10 + lbn : p + 40 + lbn - 5;
  img.fsd(meta(0), 0, 1, 1);
  // root directory (embedded)
  final root = [
    ..._Img.fid('', 1, 1, chars: 0x0A),
    ..._Img.fid('file1.txt', 2, 1),
    ..._Img.fid('sub', 5, 1, chars: 0x02),
    ..._Img.fid('\u00fcn\u00ef \u4e2d.txt', 4, 1, ucs2: true),
    ..._Img.fid('link', 7, 1),
    ..._Img.fid('hidden.txt', 8, 1, chars: 0x01),
    ..._Img.fid('gone', 9, 1, chars: 0x04),
  ];
  img.fileEntry(meta(1), 1,
      fileType: 4, infoLen: root.length, adType: 3, ad: root, perms: 0x14A5);
  // file1.txt: two extents of the physical partition (long_ad)
  img.fileEntry(meta(2), 2,
      fileType: 5,
      infoLen: 3000,
      adType: 1,
      ad: [..._Img.longAd(2048, 100, 0), ..._Img.longAd(952, 150, 0)],
      perms: 0x1884,
      lbRecorded: 2);
  img.b.fillRange((p + 100) * 2048, (p + 101) * 2048, 0x41);
  img.b.fillRange((p + 150) * 2048, (p + 150) * 2048 + 952, 0x42);
  // sub: its directory data in metadata block 6 (short_ad of the ICB's
  // partition, the metadata partition)
  final sub = [
    ..._Img.fid('', 1, 1, chars: 0x0A),
    ..._Img.fid('big.bin', 3, 1),
  ];
  img.fileEntry(meta(5), 5,
      fileType: 4,
      infoLen: sub.length,
      adType: 0,
      ad: _Img.shortAd(sub.length, 6),
      lbRecorded: 1);
  img.bytes(meta(6) * 2048, sub);
  // big.bin: a plain file entry, one extent, then an allocation extent
  // descriptor with a second extent and an unrecorded one (zeros)
  img.fileEntry(meta(3), 3,
      fileType: 5,
      infoLen: 5096,
      adType: 1,
      ad: [..._Img.longAd(2048, 200, 0), ..._Img.longAd(2048, 210, 0, 3)],
      plain: true,
      lbRecorded: 2);
  img.b.fillRange((p + 200) * 2048, (p + 201) * 2048, 0x43);
  img.b.fillRange((p + 220) * 2048, (p + 220) * 2048 + 1000, 0x44);
  final aed = (p + 210) * 2048;
  img.w32(aed + 20, 32);
  img.bytes(
      aed + 24, [..._Img.longAd(1000, 220, 0), ..._Img.longAd(2048, 0, 0, 1)]);
  img.tag(aed, 258, 210);
  // embedded file with a UCS-2 name
  final inl = ascii.encode('inline!\n');
  img.fileEntry(meta(4), 4,
      fileType: 5, infoLen: inl.length, adType: 3, ad: inl, perms: 0x1884);
  // symbolic link sub/big.bin
  final sl = [
    ..._Img.pathComponent(5, 'sub'),
    ..._Img.pathComponent(5, 'big.bin'),
  ];
  img.fileEntry(meta(7), 7,
      fileType: 12, infoLen: sl.length, adType: 3, ad: sl, perms: 0x739C);
  final h = ascii.encode('h\n');
  img.fileEntry(meta(8), 8,
      fileType: 5, infoLen: h.length, adType: 3, ad: h, perms: 0x1884);
  return img.b;
}

/// A VAT volume (UDF 2.01, VAT file type 248 in the last sector).
Uint8List vatVolume() {
  final img = _Img(341);
  const p = 300;
  img.volume(
      partStart: p,
      partLen: 41,
      maps: [
        ..._Img.type1Map(0),
        ..._Img.type2Map('*UDF Virtual Partition', [])
      ],
      numMaps: 2,
      fsdLbn: 0,
      fsdRef: 1,
      rev: 0x0201);
  img.fsd(p + 5, 0, 1, 1);
  final root = [
    ..._Img.fid('', 1, 1, chars: 0x0A),
    ..._Img.fid('vat.txt', 2, 1),
  ];
  img.fileEntry(p + 6, 1,
      fileType: 4, infoLen: root.length, adType: 3, ad: root);
  final data = ascii.encode('hello vat\n');
  img.fileEntry(p + 7, 2,
      fileType: 5,
      infoLen: data.length,
      adType: 1,
      ad: _Img.longAd(data.length, 20, 0),
      lbRecorded: 1);
  img.bytes((p + 20) * 2048, data);
  // the VAT: 152 byte header, then the entries 0-2
  final vat = Uint8List(152 + 12);
  vat[0] = 152;
  for (final (i, v) in [5, 6, 7].indexed) {
    vat[152 + i * 4] = v;
  }
  img.fileEntry(340, 40,
      fileType: 248, infoLen: vat.length, adType: 3, ad: vat);
  return img.b;
}

/// A sparable partition whose packet 32 is remapped to sector 450.
Uint8List sparableVolume() {
  final img = _Img(500);
  const p = 300;
  img.volume(
      partStart: p,
      partLen: 100,
      maps: _Img.type2Map('*UDF Sparable Partition', [
        32, 0, // packet length
        1, 0, // one sparing table
        0, 16, 0, 0, // its size
        24, 1, 0, 0, // at sector 280
      ]),
      numMaps: 1,
      fsdLbn: 0,
      fsdRef: 0,
      rev: 0x0201);
  final st = 280 * 2048;
  img.regid(st + 16, '*UDF Sparing Table');
  img.w16(st + 48, 2);
  img.w32(st + 56, 32);
  img.w32(st + 60, 450);
  img.w32(st + 64, 0xFFFFFFF0);
  img.w32(st + 68, 482);
  img.tag(st, 0, 280);
  img.fsd(p, 0, 1, 0);
  final root = [
    ..._Img.fid('', 1, 0, chars: 0x0A),
    ..._Img.fid('spared.txt', 2, 0),
  ];
  img.fileEntry(p + 1, 1,
      fileType: 4, infoLen: root.length, adType: 3, ad: root);
  img.fileEntry(p + 2, 2,
      fileType: 5, infoLen: 10, adType: 1, ad: _Img.longAd(10, 40, 0));
  img.bytes((p + 40) * 2048, ascii.encode('BAD DATA!!'));
  img.bytes((450 + 8) * 2048, ascii.encode('good data\n'));
  return img.b;
}

void main() {
  final geniso = findTool('genisoimage');
  final sevenZ = findTool('7z');
  final mkudffs = _findSbin('mkudffs');
  final python = findTool('python3');
  late Directory tmp;
  late String src;

  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('zx_udf_test');
    src = '${tmp.path}/src';
    Directory('$src/a/b/c/d/e/f/g/h').createSync(recursive: true);
    Directory('$src/emptydir').createSync();
    File('$src/hello.txt').writeAsStringSync('hello\n');
    File('$src/a/rand.bin').writeAsBytesSync(genData(300000, 9));
    File('$src/a/b/c/d/e/f/g/h/deep.txt').writeAsStringSync('deep\n');
    File('$src/a very long file name with spaces and more than sixty four '
            'characters in it ok.txt')
        .writeAsStringSync('long\n');
    File('$src/\u00fcn\u00efc\u00f6d\u00e9.txt').writeAsStringSync('u\n');
    File('$src/zeros.bin').writeAsBytesSync(Uint8List(70000));
  });

  tearDownAll(() => tmp.deleteSync(recursive: true));

  String run(String tool, List<String> args, {Map<String, String>? env}) {
    final r = Process.runSync(tool, args, environment: env);
    if (r.exitCode != 0) {
      throw StateError('$tool ${args.join(' ')}: ${r.stderr}');
    }
    return r.stdout as String;
  }

  Future<ZxArchive> open(String path, Uint8List data) async {
    File(path).writeAsBytesSync(data);
    return ZxArchive.open(path);
  }

  Future<Map<String, Uint8List>> extractAll(ZxArchive z, String out) async {
    final r = await z.extract(out);
    expect(r.ok, isTrue, reason: '$r');
    final m = <String, Uint8List>{};
    final base = Directory(out).absolute.path;
    for (final e in Directory(base).listSync(recursive: true)) {
      if (e is File) m[e.path.substring(base.length + 1)] = e.readAsBytesSync();
    }
    return m;
  }

  test('bridge disc (genisoimage -udf): listing and data equal 7z', () async {
    final iso = '${tmp.path}/bridge.iso';
    run(geniso!, ['-quiet', '-udf', '-J', '-R', '-o', iso, src]);
    final z = await ZxArchive.open(iso);
    expect(z.format, 'Udf');
    expect(zxList(z), sevenZipList(sevenZ!, iso));
    final out7 = '${tmp.path}/bridge_7z';
    run(sevenZ, ['x', '-o$out7', iso]);
    final out = '${tmp.path}/bridge_zx';
    expect((await z.extract(out)).ok, isTrue);
    // genisoimage cuts UDF names to 64 characters, as 7z shows them
    expect(treeOf(out, modes: false), treeOf(out7, modes: false));
  },
      skip: geniso == null || sevenZ == null
          ? 'genisoimage or 7z missing'
          : false);

  test('pycdlib UDF: symbolic link, UCS-2 name, multi-block file', () async {
    final pyPath =
        Directory('ref/tools/root/usr/lib/python3/dist-packages').absolute.path;
    final env = {'PYTHONPATH': pyPath};
    final probe =
        Process.runSync(python!, ['-c', 'import pycdlib'], environment: env);
    if (probe.exitCode != 0) {
      markTestSkipped('pycdlib missing');
      return;
    }
    final iso = '${tmp.path}/py.iso';
    final script = '''
import io, sys, pycdlib
iso = pycdlib.PyCdlib()
iso.new(udf='2.60', interchange_level=3)
iso.add_directory('/A', udf_path='/a')
d = b'hello udf\\n'
iso.add_fp(io.BytesIO(d), len(d), '/A/X.TXT;1', udf_path='/a/x.txt')
big = bytes(range(256)) * 400
iso.add_fp(io.BytesIO(big), len(big), '/BIG.BIN;1', udf_path='/big \\u4e2d.bin')
iso.add_symlink(udf_symlink_path='/lnk', udf_target='a/x.txt')
iso.write(sys.argv[1])
''';
    run(python, ['-c', script, iso], env: env);
    final h = UdfHandler();
    final z = await ZxArchive.open(iso);
    expect(z.format, 'Udf');
    final lnk = z.items.firstWhere((i) => i.path == 'lnk');
    expect(lnk.symlinkTarget, 'a/x.txt');
    final out = '${tmp.path}/py_out';
    final m = await extractAll(z, out);
    expect(utf8.decode(m['a/x.txt']!), 'hello udf\n');
    final big = m['big \u4e2d.bin']!;
    expect(big.length, 102400);
    for (var i = 0; i < big.length; i++) {
      if (big[i] != (i & 0xFF)) fail('big.bin differs at $i');
    }
    expect(Link('$out/lnk').targetSync(), 'a/x.txt');
    h.close();
  }, skip: python == null ? 'python3 missing' : false);

  test('mkudffs volumes: every media type, revision and block size', () async {
    final cases = [
      ['hd', '1.02', '512'],
      ['hd', '1.50', '2048'],
      ['hd', '2.01', '2048'],
      ['hd', '2.01', '4096'],
      ['hd', '2.01', '1024'],
      ['dvdram', '2.01', '2048'],
      ['cdrw', '2.01', '2048'],
      ['dvdrw', '1.50', '2048'],
      ['cdr', '1.50', '2048'],
      ['cdr', '2.01', '2048'],
      ['cdr', '2.50', '2048'],
      ['dvdr', '2.50', '2048'],
      ['bdr', '2.50', '2048'],
    ];
    for (final c in cases) {
      final img = '${tmp.path}/mk_${c.join('_')}.img';
      final f = File(img)..writeAsBytesSync([]);
      final raf = f.openSync(mode: FileMode.write)..truncateSync(24 << 20);
      raf.closeSync();
      run(mkudffs!, [
        '--media-type=${c[0]}',
        '--udfrev=${c[1]}',
        '--blocksize=${c[2]}',
        '--label=L${c[0]}',
        img
      ]);
      // no extension: found by the recognition sequence
      final plain = '${tmp.path}/mk_${c.join('_')}';
      f.renameSync(plain);
      final z = await ZxArchive.open(plain);
      expect(z.format, 'Udf', reason: c.join(' '));
      // UDF 1.50 on rewritable media: the non-allocatable space file
      expect(
          z.items
              .where((i) => !i.isImplied && i.path != 'Non-Allocatable Space'),
          isEmpty,
          reason: c.join(' '));
      final h = UdfHandler();
      final s = FileInStream.open(plain);
      expect(h.open(s), isTrue);
      expect(h.getArchiveProperty(Kpid.volumeName), 'L${c[0]}');
      expect(h.getArchiveProperty(Kpid.unpackVer), c[1]);
      expect(h.getArchiveProperty(Kpid.clusterSize), int.parse(c[2]));
      expect(h.errorFlags, 0, reason: c.join(' '));
      s.close();
    }
  }, skip: mkudffs == null ? 'mkudffs missing' : false);

  test('metadata partition (UDF 2.50, hand made)', () async {
    for (final breakMain in [false, true]) {
      final z = await open('${tmp.path}/meta_$breakMain.udf',
          metadataVolume(breakMain: breakMain));
      expect(z.format, 'Udf');
      expect(z.items.map((i) => i.path).toList(), [
        'file1.txt',
        'sub',
        'sub/big.bin',
        '\u00fcn\u00ef \u4e2d.txt',
        'link',
        'hidden.txt',
      ]);
      final f1 = z.items[0];
      expect(f1.size, 3000);
      expect(f1.packSize, 4096);
      expect(f1.posixMode, 0x8000 | 0x1A4); // rw-r--r--
      expect(f1.modified!.toUtc(), DateTime.utc(2024, 5, 6, 7, 8, 9));
      expect(z.items[4].symlinkTarget, 'sub/big.bin');
      expect(z.items[5].attrib! & 2, 2);
      final m = await extractAll(z, '${tmp.path}/meta_out_$breakMain');
      expect(m['file1.txt'],
          [...List.filled(2048, 0x41), ...List.filled(952, 0x42)]);
      expect(m['sub/big.bin'], [
        ...List.filled(2048, 0x43),
        ...List.filled(1000, 0x44),
        ...List.filled(2048, 0)
      ]);
      expect(utf8.decode(m['\u00fcn\u00ef \u4e2d.txt']!), 'inline!\n');
      expect(utf8.decode(m['hidden.txt']!), 'h\n');
    }
  });

  test('VAT (virtual partition, hand made)', () async {
    final z = await open('${tmp.path}/vat.udf', vatVolume());
    expect(z.format, 'Udf');
    final m = await extractAll(z, '${tmp.path}/vat_out');
    expect(m.keys, ['vat.txt']);
    expect(utf8.decode(m['vat.txt']!), 'hello vat\n');
  });

  test('sparable partition with a remapped packet (hand made)', () async {
    final z = await open('${tmp.path}/spar.udf', sparableVolume());
    final m = await extractAll(z, '${tmp.path}/spar_out');
    expect(utf8.decode(m['spared.txt']!), 'good data\n');
  });

  test('detection: UDF only images with no or a wrong extension', () async {
    for (final name in ['m_noext', 'm.bin', 'm.txt', 'm.iso', 'm.img']) {
      final z = await open('${tmp.path}/$name', metadataVolume());
      expect(z.format, 'Udf', reason: name);
      expect((await z.test()).ok, isTrue, reason: name);
    }
  });

  test('isArc', () {
    final v = metadataVolume();
    expect(isArcUdf(v, v.length), 1);
    expect(isArcUdf(Uint8List(1 << 20), 1 << 20), 0);
    expect(isArcUdf(v, 1000), 2);
  });
}
