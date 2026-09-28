// Tests of zcm's paq8px image models (zcm_image_px.dart, levels 7 to 9):
// round trips of gray (PGM), 24-bit (PPM, BMP with row padding) and
// 32-bit (BMP) images, and golden sizes and hashes of their output.
//
// ZCM_GOLDEN=1 dart test test/zcm_image_test.dart prints the golden values
// instead of checking them (after an intended change of the model).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/codec/zcm/zcm.dart';
import 'package:zx/src/codec/zcm/zcm_detect.dart';
import 'package:zx/src/crypto/sha256.dart';

final bool _printGolden = Platform.environment['ZCM_GOLDEN'] == '1';

int _seed = 1;
int _rnd() {
  _seed = (_seed * 1103515245 + 12345) & 0x7FFFFFFF;
  return _seed >> 16;
}

// A photo-like value of plane [c] at (x, y): gradients, an edge and noise.
int _value(int x, int y, int c) {
  final base = (x * 2 + y * 3 + c * 40 + ((x * y) >> 7)) & 255;
  final edge = x > y + 20 ? 60 : 0;
  return (base + edge + (_rnd() & 7)) & 255;
}

Uint8List _netpbm(int w, int h, bool color) {
  final head = ascii.encode('${color ? 'P6' : 'P5'}\n$w $h\n255\n');
  final bpp = color ? 3 : 1;
  final b = Uint8List(head.length + w * h * bpp);
  b.setAll(0, head);
  var k = head.length;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      for (var c = 0; c < bpp; c++) {
        b[k++] = _value(x, y, c);
      }
    }
  }
  return b;
}

// A BMP with 24 or 32 bits per pixel (rows padded to 4 bytes).
Uint8List _bmp(int w, int h, int bpp) {
  final bytes = bpp >> 3;
  final stride = (w * bytes + 3) & ~3;
  final size = 54 + stride * h;
  final b = Uint8List(size);
  final d = ByteData.sublistView(b);
  b[0] = 0x42;
  b[1] = 0x4D;
  d.setUint32(2, size, Endian.little);
  d.setUint32(10, 54, Endian.little);
  d.setUint32(14, 40, Endian.little);
  d.setInt32(18, w, Endian.little);
  d.setInt32(22, h, Endian.little);
  d.setUint16(26, 1, Endian.little);
  d.setUint16(28, bpp, Endian.little);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      for (var c = 0; c < bytes; c++) {
        b[54 + y * stride + x * bytes + c] =
            c == 3 ? 255 - (x & 1) : _value(x, y, c);
      }
    }
  }
  return b;
}

String _sha(Uint8List b) => Sha256.hash(b)
    .map((x) => x.toRadixString(16).padLeft(2, '0'))
    .join()
    .substring(0, 16);

void main() {
  _seed = 1;
  final pgm = _netpbm(100, 60, false);
  final ppm = _netpbm(90, 50, true);
  final bmp24 = _bmp(33, 40, 24); // 1 byte of padding per row
  final bmp32 = _bmp(40, 30, 32);
  final inputs = {'pgm': pgm, 'ppm': ppm, 'bmp24': bmp24, 'bmp32': bmp32};

  test('the images are detected', () {
    ZcmSegment media(Uint8List b) => zcmDetectSegments(b, 0, b.length)
        .firstWhere((s) => ZcmBlockType.isImage(s.type));
    expect(media(pgm).type, ZcmBlockType.image8);
    expect(media(ppm).type, ZcmBlockType.image24);
    expect(media(bmp24).type, ZcmBlockType.image24);
    expect(media(bmp32).type, ZcmBlockType.image32);
  });

  for (final level in [7, 8, 9]) {
    test('round trips at level $level', () {
      for (final e in inputs.entries) {
        final packed = zcmCompressBytes(e.value, ZcmOptions(level: level));
        expect(zcmDecompressBytes(packed), e.value, reason: e.key);
      }
    });
  }

  test('the paq8px models beat the level 6 image model', () {
    for (final name in ['pgm', 'ppm']) {
      final d = inputs[name]!;
      final l6 = zcmCompressBytes(d, const ZcmOptions(level: 6)).length;
      final l7 = zcmCompressBytes(d, const ZcmOptions(level: 7)).length;
      expect(l7, lessThan(l6), reason: name);
    }
  });

  // Golden sizes and hashes: the output of the image models is pinned.
  const golden = <String, String>{
    'l7': '11554:bcdac77e247158f9',
  };
  test('golden images level 7', () {
    final all = BytesBuilder();
    for (final d in inputs.values) {
      all.add(d);
    }
    final packed = zcmCompressBytes(all.toBytes(), const ZcmOptions(level: 7));
    final v = '${packed.length}:${_sha(packed)}';
    if (_printGolden || golden['l7'] == null) {
      // ignore: avoid_print
      print("'l7': '$v',");
    } else {
      expect(v, golden['l7']);
    }
  });
}
