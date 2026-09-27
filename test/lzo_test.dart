// LZO1X decoder tests. Vectors come from the real lzop (its container holds
// raw LZO1X blocks of up to 256 KiB), made at test time; skipped when lzop
// is missing.

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/codec/lzo/lzo1x.dart';
import 'package:zx/src/io/streams.dart';

import 'codec_test_util.dart';

class LzopBlock {
  final int dstLen;
  final Uint8List data; // compressed (or stored when data.length == dstLen)
  LzopBlock(this.dstLen, this.data);
}

int _be32(Uint8List b, int p) =>
    (b[p] << 24) | (b[p + 1] << 16) | (b[p + 2] << 8) | b[p + 3];

/// Splits an lzop file into its blocks.
List<LzopBlock> parseLzop(Uint8List f) {
  const magic = [0x89, 0x4C, 0x5A, 0x4F, 0x00, 0x0D, 0x0A, 0x1A, 0x0A];
  for (var i = 0; i < 9; i++) {
    if (f[i] != magic[i]) throw StateError('not lzop');
  }
  var p = 9;
  final version = (f[p] << 8) | f[p + 1];
  p += 4; // version, lib version
  if (version >= 0x0940) p += 2; // version needed
  p++; // method
  if (version >= 0x0940) p++; // level
  final flags = _be32(f, p);
  p += 4;
  if (flags & 0x800 != 0) p += 4; // filter
  p += 8; // mode, mtime low
  if (version >= 0x0940) p += 4; // mtime high
  p += 1 + f[p]; // name
  p += 4; // header checksum
  if (flags & 0x40 != 0) p += 4 + _be32(f, p) + 4; // extra field
  final blocks = <LzopBlock>[];
  for (;;) {
    final dstLen = _be32(f, p);
    p += 4;
    if (dstLen == 0) break;
    final srcLen = _be32(f, p);
    p += 4;
    if (flags & 1 != 0) p += 4; // adler32 of uncompressed
    if (flags & 0x100 != 0) p += 4; // crc32 of uncompressed
    if (srcLen < dstLen) {
      if (flags & 2 != 0) p += 4;
      if (flags & 0x200 != 0) p += 4;
    }
    blocks.add(LzopBlock(dstLen, Uint8List.sublistView(f, p, p + srcLen)));
    p += srcLen;
  }
  return blocks;
}

void main() {
  final lzop = findTool('lzop');
  late Directory tmp;
  setUpAll(() => tmp = tempDir('lzo'));
  tearDownAll(() => tmp.deleteSync(recursive: true));

  Uint8List lzopCompress(Uint8List data, String level) {
    final f = File('${tmp.path}/in.bin')..writeAsBytesSync(data);
    return runTool(lzop!, ['-c', level, f.path]);
  }

  // decodes every block of an lzop file and joins them
  Uint8List decodeLzop(Uint8List file) {
    final out = BytesBuilder(copy: false);
    for (final b in parseLzop(file)) {
      if (b.data.length == b.dstLen) {
        out.add(b.data);
      } else {
        final d = lzo1xDecompress(b.data, outSize: b.dstLen);
        expect(d.length, b.dstLen);
        out.add(d);
      }
    }
    return out.toBytes();
  }

  group('lzop vectors', () {
    final inputs = <String, Uint8List>{
      'text': genData(1500000, 1),
      'mixed': genData(700000, 2, randomPercent: 40),
      'random': randomData(300000, 3),
      'zeros': Uint8List(600000),
      'small': Uint8List.fromList('hello hello hello hello'.codeUnits),
      'one': Uint8List.fromList([7]),
    };
    for (final level in ['-1', '-3', '-7', '-9']) {
      for (final e in inputs.entries) {
        test('${e.key} $level', () {
          final c = lzopCompress(e.value, level);
          final d = decodeLzop(c);
          expect(sameBytes(d, e.value), isTrue);
        }, skip: lzop == null ? 'lzop not installed' : false);
      }
    }
  });

  test('decompressInto with offsets', () {
    final data = genData(200000, 5);
    final blocks = parseLzop(lzopCompress(data, '-9'));
    final b = blocks.first;
    final src = Uint8List(b.data.length + 20)
      ..setRange(7, 7 + b.data.length, b.data);
    final dst = Uint8List(b.dstLen + 30);
    final n = lzo1xDecompressInto(src, 7, b.data.length, dst, 11, b.dstLen);
    expect(n, b.dstLen);
    expect(sameBytes(Uint8List.sublistView(dst, 11, 11 + n), data), isTrue);
    // too small output
    expect(
        () => lzo1xDecompressInto(src, 7, b.data.length, dst, 0, b.dstLen - 1),
        throwsA(isA<SevenZipException>()));
  }, skip: lzop == null ? 'lzop not installed' : false);

  test('hand made streams', () {
    // empty stream: end marker only
    expect(
        lzo1xDecompress(Uint8List.fromList([0x11, 0, 0]), outSize: 0), isEmpty);
    // first byte 18..: literal run, then end marker
    expect(
        lzo1xDecompress(Uint8List.fromList([17 + 3, 1, 2, 3, 0x11, 0, 0]),
            outSize: 3),
        [1, 2, 3]);
    // lzo-rle (version 1): marker, 2 literals 'ab', then a zero run of
    // ((1 << 3) | 2) + 4 = 14 bytes, then 1 literal, then the end
    final rle = Uint8List.fromList(
        [17, 1, 17 + 2, 0x61, 0x62, 0x1A, 0xFD, 0xFF, 1, 0x63, 0x11, 0, 0]);
    final d = lzo1xDecompress(rle, outSize: 100);
    expect(d, [0x61, 0x62, ...List.filled(14, 0), 0x63]);
  });

  test('corrupt and truncated input throws', () {
    final data = genData(300000, 9);
    final blocks =
        lzop == null ? <LzopBlock>[] : parseLzop(lzopCompress(data, '-1'));
    final samples = <Uint8List>[
      Uint8List.fromList([0x11, 0]),
      Uint8List.fromList([0x10, 0, 0]), // match into an empty dictionary
      Uint8List.fromList([17 + 1, 1, 0x40, 0x00]), // distance too far
      Uint8List.fromList([0, 0, 0, 0]), // endless literal length
      if (blocks.isNotEmpty) blocks.first.data,
    ];
    for (final s in samples) {
      for (var cut = 0; cut < s.length; cut += 1 + s.length ~/ 50) {
        expect(
            () => lzo1xDecompress(Uint8List.sublistView(s, 0, cut),
                outSize: 300000),
            throwsA(isA<SevenZipException>()));
      }
    }
    // random bit flips: either throws SevenZipException or returns
    if (blocks.isNotEmpty) {
      final c = Uint8List.fromList(blocks.first.data);
      var st = 1;
      for (var k = 0; k < 300; k++) {
        final m = Uint8List.fromList(c);
        st = (st * 1103515245 + 12345) & 0x7fffffff;
        m[st % m.length] ^= 1 << (st >> 20 & 7);
        try {
          lzo1xDecompress(m, outSize: blocks.first.dstLen);
        } on SevenZipException {
          // expected
        }
      }
    }
  });
}
