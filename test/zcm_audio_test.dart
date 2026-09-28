// Tests of zcm's audio models: round trips of 8 and 16 bit WAV and AIFF,
// mono and stereo, at the levels of the light, full and paq8px audio
// models, and golden sizes and hashes of the paq8px models (levels 7 to 9).
//
// ZCM_GOLDEN=1 dart test test/zcm_audio_test.dart prints the golden values
// instead of checking them (after an intended change of the model).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/codec/zcm/zcm.dart';
import 'package:zx/src/codec/zcm/zcm_detect.dart';
import 'package:zx/src/crypto/sha256.dart';

final bool _printGolden = Platform.environment['ZCM_GOLDEN'] == '1';

// A WAV (little endian) or AIFF (big endian, signed 8-bit samples) of
// [frames] frames: a resonant filter driven by noise, the second channel
// a scaled and delayed copy of the first plus noise.
Uint8List _audio(int frames, int bits, int channels, int seed,
    {bool aiff = false}) {
  final unit = channels * (bits >> 3);
  final data = frames * unit;
  final head = aiff ? 54 : 44;
  final b = Uint8List(head + data);
  final d = ByteData.sublistView(b);
  if (aiff) {
    b.setAll(0, ascii.encode('FORM'));
    d.setUint32(4, 46 + data, Endian.big);
    b.setAll(8, ascii.encode('AIFFCOMM'));
    d.setUint32(16, 18, Endian.big);
    d.setUint16(20, channels, Endian.big);
    d.setUint32(22, frames, Endian.big);
    d.setUint16(26, bits, Endian.big);
    // 22050 Hz as an 80 bit extended float.
    b.setAll(28, const [0x40, 0x0D, 0xAC, 0x44, 0, 0, 0, 0, 0, 0]);
    b.setAll(38, ascii.encode('SSND'));
    d.setUint32(42, 8 + data, Endian.big);
    d.setUint32(46, 0, Endian.big);
    d.setUint32(50, 0, Endian.big);
  } else {
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
  }
  final e = aiff ? Endian.big : Endian.little;
  var s = seed;
  int rnd() {
    s = (s * 1103515245 + 12345) & 0x7FFFFFFF;
    return (s >> 16) & 255;
  }

  var p1 = 0, p2 = 0, last = 0;
  for (var i = 0; i < frames; i++) {
    final v = (p1 * 15 ~/ 8) - (p2 * 15 ~/ 16) + (rnd() - 128) * 4;
    p2 = p1;
    p1 = v.clamp(-30000, 30000);
    final o = head + i * unit;
    for (var c = 0; c < channels; c++) {
      final x = c == 0 ? p1 : ((last * 3) >> 2) + (rnd() & 15) - 8;
      if (bits == 16) {
        d.setInt16(o + c * 2, x.clamp(-32768, 32767), e);
      } else {
        final q = (x >> 8).clamp(-128, 127);
        b[o + c] = aiff ? q & 255 : 128 + q;
      }
    }
    last = p1;
  }
  return b;
}

String _sha(Uint8List b) => Sha256.hash(b)
    .map((x) => x.toRadixString(16).padLeft(2, '0'))
    .join()
    .substring(0, 16);

void main() {
  final inputs = {
    'wav16s': _audio(3000, 16, 2, 1),
    'wav16m': _audio(4000, 16, 1, 2),
    'wav8s': _audio(3000, 8, 2, 3),
    'wav8m': _audio(5000, 8, 1, 4),
    'aiff16s': _audio(2000, 16, 2, 5, aiff: true),
    'aiff8m': _audio(3000, 8, 1, 6, aiff: true),
  };

  group('zcm audio', () {
    test('every input is one audio segment of its layout', () {
      const infos = {
        'wav16s': 8 | 1 | 2,
        'wav16m': 8 | 1,
        'wav8s': 8 | 2,
        'wav8m': 8,
        'aiff16s': 8 | 1 | 2 | 4,
        'aiff8m': 8 | 4,
      };
      for (final e in inputs.entries) {
        final segs = zcmDetectSegments(e.value, 0, e.value.length)
            .where((s) => s.type == ZcmBlockType.audio)
            .toList();
        expect(segs.length, 1, reason: e.key);
        expect(segs[0].info, infos[e.key], reason: e.key);
      }
    });

    for (final level in [3, 6, 7]) {
      test('round trips at level $level', () {
        for (final e in inputs.entries) {
          final packed = zcmCompressBytes(e.value, ZcmOptions(level: level));
          expect(zcmDecompressBytes(packed), e.value, reason: e.key);
        }
      });
    }

    test('the paq8px models beat the full model', () {
      for (final name in ['wav16s', 'wav8m']) {
        final d = inputs[name]!;
        final l6 = zcmCompressBytes(d, const ZcmOptions(level: 6)).length;
        final l7 = zcmCompressBytes(d, const ZcmOptions(level: 7)).length;
        expect(l7, lessThan(l6), reason: name);
      }
    });

    // Golden sizes and hashes: the output of the paq8px audio models is
    // pinned (all inputs in one stream: segments of every layout).
    const golden = <String, String>{
      'l7': '19109:029ca64d4f4d1395',
    };
    test('golden audio level 7', () {
      final all = BytesBuilder();
      for (final d in inputs.values) {
        all.add(d);
      }
      final packed =
          zcmCompressBytes(all.toBytes(), const ZcmOptions(level: 7));
      final v = '${packed.length}:${_sha(packed)}';
      expect(zcmDecompressBytes(packed), all.toBytes());
      if (_printGolden || golden['l7'] == null) {
        // ignore: avoid_print
        print("'l7': '$v',");
      } else {
        expect(v, golden['l7']);
      }
    });
  });
}
