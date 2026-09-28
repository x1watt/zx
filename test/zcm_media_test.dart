// Tests of zcm's image and audio detection and models: BMP with 1, 4 and
// 8 (palette) bits per pixel, PBM, raw (headerless) images, and round
// trips of every image and audio type at the levels with light and full
// media models.
//
// ZCM_GOLDEN=1 dart test test/zcm_media_test.dart prints the golden values
// instead of checking them (after an intended change of the model).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/codec/zcm/zcm.dart';
import 'package:zx/src/codec/zcm/zcm_detect.dart';
import 'package:zx/src/crypto/sha256.dart';

final bool _printGolden = Platform.environment['ZCM_GOLDEN'] == '1';

Uint8List _random(int n, int seed) {
  final out = Uint8List(n);
  var s = seed;
  for (var i = 0; i < n; i++) {
    s = (s * 1103515245 + 12345) & 0x7FFFFFFF;
    out[i] = s >> 16;
  }
  return out;
}

// A smooth synthetic picture: value of plane [c] at (x, y).
int _pixel(int x, int y, int c, Uint8List r, int i) =>
    ((x * (c + 2) + y * 3 + ((x * y) >> 6) + (r[i] & 7)) & 255);

// A BMP of [w] x [h] pixels with [bpp] bits per pixel; 8-bit images get
// a gray ramp or a scrambled palette.
Uint8List _bmp(int w, int h, int bpp, int seed, {bool grayPalette = false}) {
  final colors = bpp <= 8 ? 1 << bpp : 0;
  final stride = ((w * bpp + 7) >> 3) + 3 & ~3;
  final dataOff = 54 + colors * 4;
  final size = dataOff + stride * h;
  final b = Uint8List(size);
  final d = ByteData.sublistView(b);
  b[0] = 0x42;
  b[1] = 0x4D;
  d.setUint32(2, size, Endian.little);
  d.setUint32(10, dataOff, Endian.little);
  d.setUint32(14, 40, Endian.little);
  d.setInt32(18, w, Endian.little);
  d.setInt32(22, h, Endian.little);
  d.setUint16(26, 1, Endian.little);
  d.setUint16(28, bpp, Endian.little);
  d.setUint32(46, colors, Endian.little);
  for (var k = 0; k < colors; k++) {
    final g = grayPalette ? k : (k * 37 + 11) & 255;
    b[54 + k * 4] = g;
    b[55 + k * 4] = grayPalette ? k : (k * 91) & 255;
    b[56 + k * 4] = grayPalette ? k : (k * 13 + 5) & 255;
  }
  final r = _random(w * h * 3, seed);
  for (var y = 0; y < h; y++) {
    final row = dataOff + y * stride;
    for (var x = 0; x < w; x++) {
      final i = y * w + x;
      if (bpp == 1) {
        final on = ((x - w ~/ 2) * (x - w ~/ 2) + (y - h ~/ 2) * (y - h ~/ 2)) <
                (w * h) >> 3 ||
            (r[i] & 63) == 0;
        if (on) b[row + (x >> 3)] |= 0x80 >> (x & 7);
      } else if (bpp == 4) {
        final v = ((x >> 3) + (y >> 2) + ((r[i] & 15) == 0 ? 1 : 0)) & 15;
        b[row + (x >> 1)] |= (x & 1) == 0 ? v << 4 : v;
      } else if (bpp == 8) {
        b[row + x] = grayPalette
            ? _pixel(x, y, 0, r, i)
            : ((x >> 2) * 7 + (y >> 3) * 3 + (r[i] & 1)) & 255;
      } else {
        for (var c = 0; c < 3; c++) {
          b[row + x * 3 + c] = _pixel(x, y, c, r, i * 3 + c);
        }
      }
    }
  }
  return b;
}

// A PBM (P4) of [w] x [h] pixels.
Uint8List _pbm(int w, int h) {
  final head = ascii.encode('P4\n$w $h\n');
  final stride = (w + 7) >> 3;
  final b = Uint8List(head.length + stride * h);
  b.setAll(0, head);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      if (((x ~/ 5) + (y ~/ 7)) % 3 == 0) {
        b[head.length + y * stride + (x >> 3)] |= 0x80 >> (x & 7);
      }
    }
  }
  return b;
}

// A triangle wave of period 512 (0..255).
int _tri(int t) {
  final m = t & 511;
  return m < 256 ? m : 511 - m;
}

// Raw pixels without a header: [w] x [h] with [bpp] bytes per pixel.
Uint8List _raw(int w, int h, int bpp, int seed) {
  final b = Uint8List(w * h * bpp);
  final r = _random(b.length, seed);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      for (var c = 0; c < bpp; c++) {
        final i = (y * w + x) * bpp + c;
        // Smooth gradients in two directions, like a photo.
        b[i] = (_tri(x * 3 + y * 2 + c * 50) +
                _tri(x - y * 4 + c * 20) +
                (r[i] & 3)) >>
            1;
      }
    }
  }
  return b;
}

// A 16-bit stereo or 8-bit mono WAV of [frames] frames.
Uint8List _wav(int frames, int bits, int channels, int seed) {
  final unit = channels * (bits >> 3);
  final data = frames * unit;
  final b = Uint8List(44 + data);
  final d = ByteData.sublistView(b);
  b.setAll(0, ascii.encode('RIFF'));
  d.setUint32(4, 36 + data, Endian.little);
  b.setAll(8, ascii.encode('WAVEfmt '));
  d.setUint32(16, 16, Endian.little);
  d.setUint16(20, 1, Endian.little);
  d.setUint16(22, channels, Endian.little);
  d.setUint32(24, 22050, Endian.little);
  d.setUint32(28, 22050 * unit, Endian.little);
  d.setUint16(32, unit, Endian.little);
  d.setUint16(34, bits, Endian.little);
  b.setAll(36, ascii.encode('data'));
  d.setUint32(40, data, Endian.little);
  final r = _random(frames, seed);
  var p1 = 0, p2 = 0;
  for (var i = 0; i < frames; i++) {
    // A resonant filter driven by noise: a predictable waveform.
    final v = (p1 * 15 ~/ 8) - (p2 * 15 ~/ 16) + (r[i] - 128) * 4;
    p2 = p1;
    p1 = v.clamp(-30000, 30000);
    if (bits == 16) {
      for (var c = 0; c < channels; c++) {
        d.setInt16(44 + i * unit + c * 2, c == 0 ? p1 : (p1 * 3) >> 2,
            Endian.little);
      }
    } else {
      b[44 + i] = 128 + (p1 >> 8).clamp(-128, 127);
    }
  }
  return b;
}

String _sha(Uint8List b) => Sha256.hash(b)
    .map((x) => x.toRadixString(16).padLeft(2, '0'))
    .join()
    .substring(0, 16);

void _roundTrip(Uint8List data, int level) {
  final packed = zcmCompressBytes(data, ZcmOptions(level: level));
  expect(zcmDecompressBytes(packed), data);
}

List<ZcmSegment> _media(Uint8List b) => zcmDetectSegments(b, 0, b.length)
    .where((s) => s.type != ZcmBlockType.binary &&
        s.type != ZcmBlockType.text &&
        s.type != ZcmBlockType.exe)
    .toList();

void main() {
  final bmp1 = _bmp(200, 120, 1, 1);
  final bmp4 = _bmp(150, 90, 4, 2);
  final bmp8g = _bmp(120, 80, 8, 3, grayPalette: true);
  final bmp8p = _bmp(120, 80, 8, 4);
  final bmp24 = _bmp(96, 64, 24, 5);
  final pbm = _pbm(300, 100);
  final raw8 = _raw(320, 120, 1, 6);
  final raw24 = _raw(160, 80, 3, 7);
  final wav16 = _wav(6000, 16, 2, 8);
  final wav8 = _wav(8000, 8, 1, 9);

  group('zcm media detection', () {
    test('BMP 1, 4 and 8 bits, gray and palette', () {
      final s1 = _media(bmp1).single;
      expect(s1.type, ZcmBlockType.image1);
      expect(s1.info & 0xFFFFFF, 28); // 25 bytes, padded to 28
      expect(s1.info >> 24, 3);
      expect(_media(bmp4).single.type, ZcmBlockType.image4);
      expect(_media(bmp8g).single.type, ZcmBlockType.image8);
      expect(_media(bmp8p).single.type, ZcmBlockType.image8pal);
      expect(_media(bmp24).single.type, ZcmBlockType.image24);
      final p = _media(pbm).single;
      expect(p.type, ZcmBlockType.image1);
      expect(p.info, zcmImageInfo(38, 0));
      expect(p.len, 38 * 100);
    });

    test('raw images are found by their rows', () {
      final s8 = _media(raw8);
      expect(s8, isNotEmpty);
      expect(s8.first.type, ZcmBlockType.image8);
      expect(s8.first.info & 0xFFFFFF, 320);
      final s24 = _media(raw24);
      expect(s24, isNotEmpty);
      expect(s24.first.type, ZcmBlockType.image24);
      expect(s24.first.info & 0xFFFFFF, 480);
    });

    test('random, flat and text data are not raw images', () {
      expect(_media(_random(100000, 11)), isEmpty);
      expect(_media(Uint8List(100000)), isEmpty);
      final text = ascii.encode(List.filled(3000, 'lorem ipsum dolor sit '
              'amet, consectetur adipiscing elit. ')
          .join());
      expect(_media(Uint8List.fromList(text)), isEmpty);
      // Records of a table: periodic but not smooth.
      final rec = Uint8List(100000);
      final r = _random(100000, 12);
      for (var i = 0; i < rec.length; i++) {
        rec[i] = i % 40 < 4 ? i ~/ 40 : r[i];
      }
      expect(_media(rec), isEmpty);
    });

    test('segments cover the input', () {
      final all = BytesBuilder()
        ..add(_random(3000, 13))
        ..add(bmp1)
        ..add(bmp4)
        ..add(pbm)
        ..add(raw24)
        ..add(bmp8p)
        ..add(wav8);
      final b = all.toBytes();
      var end = 0;
      for (final s in zcmDetectSegments(b, 0, b.length)) {
        expect(s.off, end);
        end += s.len;
      }
      expect(end, b.length);
    });
  });

  group('zcm media round trips', () {
    final inputs = {
      'bmp1': bmp1,
      'bmp4': bmp4,
      'bmp8g': bmp8g,
      'bmp8p': bmp8p,
      'bmp24': bmp24,
      'pbm': pbm,
      'raw8': raw8,
      'raw24': raw24,
      'wav16': wav16,
      'wav8': wav8,
    };
    for (final level in [1, 3, 6, 7]) {
      test('level $level', () {
        for (final e in inputs.entries) {
          _roundTrip(e.value, level);
        }
      });
    }

    test('the media models beat the generic ones', () {
      for (final name in ['bmp1', 'bmp4', 'bmp8p', 'raw24', 'pbm']) {
        final d = inputs[name]!;
        final on = zcmCompressBytes(d, const ZcmOptions(level: 6)).length;
        final off = zcmCompressBytes(
                d, const ZcmOptions(level: 6, detect: false))
            .length;
        expect(on, lessThan(off), reason: name);
      }
    });

    // Golden sizes and hashes: the output of the media models is pinned.
    const golden = <String, String>{
      'l3': '65212:8a4cc1f28039817f',
      'l7': '47770:e2b0285afd3ae77e',
    };
    for (final level in [3, 7]) {
      test('golden media level $level', () {
        final all = BytesBuilder();
        for (final d in inputs.values) {
          all.add(d);
        }
        final packed =
            zcmCompressBytes(all.toBytes(), ZcmOptions(level: level));
        final v = '${packed.length}:${_sha(packed)}';
        if (_printGolden || golden['l$level'] == null) {
          // ignore: avoid_print
          print("'l$level': '$v',");
        } else {
          expect(v, golden['l$level']);
        }
      });
    }
  });
}
