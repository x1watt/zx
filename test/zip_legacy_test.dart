// Decodes the legacy zip methods 1 (Shrink), 2 to 5 (Reduce) and 6
// (Implode) from the fixtures of tool/zip_legacy_fixtures.py. Each fixture
// holds one entry named "<kind>-<size>-<seed>.bin"; its content is made
// again here by genContent, the same generator as the Python gen_content.
// The local header is parsed here, so the test does not need the zip
// handler.

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/format/zip/zip_implode.dart';
import 'package:zx/src/format/zip/zip_reduce.dart';
import 'package:zx/src/format/zip/zip_shrink.dart';
import 'package:zx/src/io/streams.dart';
import 'package:zx/src/util/crc.dart';

const _words = [
  'shrink', 'reduce', 'implode', 'the', 'of', 'zip', 'tree', 'code', //
  'window', 'length', 'distance', 'follower', 'set', 'literal', 'a', 'and',
  'data', 'Shannon', 'Fano', 'LZW',
];

Uint8List genContent(String kind, int n, int seed) {
  var s = (seed * 2654435761 + 1) & 0xFFFFFFFF;
  if (s == 0) s = 1;
  int next() {
    s ^= (s << 13) & 0xFFFFFFFF;
    s ^= s >> 17;
    s ^= (s << 5) & 0xFFFFFFFF;
    return s;
  }

  if (kind == 'rep') return Uint8List(n)..fillRange(0, n, 0x61);
  final out = <int>[];
  if (kind == 'zbin') {
    out.addAll(List.filled(300, 0));
    kind = 'bin';
  }
  while (out.length < n) {
    final r = next();
    switch (kind) {
      case 'text':
        out.addAll(_words[r % _words.length].codeUnits);
        out.add((r >> 8) % 11 == 0 ? 10 : 32);
      case 'bin':
        final op = r % 4;
        if (op == 0) {
          for (var i = 1 + (r >> 4) % 32; i > 0; i--) {
            out.add(next() & 0xFF);
          }
        } else if (op == 1 && out.isNotEmpty) {
          final lim = out.length < 5000 ? out.length : 5000;
          final dist = 1 + (r >> 4) % lim;
          for (var i = 3 + (r >> 16) % 300; i > 0; i--) {
            out.add(out[out.length - dist]);
          }
        } else if (op == 2) {
          out.addAll(List.filled(1 + (r >> 12) % 100, (r >> 4) & 0xFF));
        } else {
          out.addAll(List.filled(1 + (r >> 4) % 20, 0x90));
        }
      case 'dle':
        final op = r % 3;
        if (op == 0) {
          out.addAll(List.filled(1 + (r >> 4) % 40, 0x90));
        } else if (op == 1) {
          out.add((r >> 4) & 1 != 0 ? 0x90 : (r >> 5) & 0xFF);
        } else {
          out.addAll(_words[(r >> 4) % _words.length].codeUnits);
        }
      default:
        throw ArgumentError(kind);
    }
  }
  return Uint8List.fromList(out.sublist(0, n));
}

class _Entry {
  final String name;
  final int flags;
  final int method;
  final int crc;
  final int size;
  final Uint8List packed;
  _Entry(this.name, this.flags, this.method, this.crc, this.size, this.packed);
}

_Entry _parse(Uint8List z) {
  final d = ByteData.sublistView(z);
  if (d.getUint32(0, Endian.little) != 0x04034B50) {
    throw StateError('not a local header');
  }
  final nameLen = d.getUint16(26, Endian.little);
  final extraLen = d.getUint16(28, Endian.little);
  final packedSize = d.getUint32(18, Endian.little);
  final start = 30 + nameLen + extraLen;
  return _Entry(
    String.fromCharCodes(z, 30, 30 + nameLen),
    d.getUint16(6, Endian.little),
    d.getUint16(8, Endian.little),
    d.getUint32(14, Endian.little),
    d.getUint32(22, Endian.little),
    Uint8List.sublistView(z, start, start + packedSize),
  );
}

InStream _decoder(_Entry e, Uint8List packed) {
  final input = MemoryInStream(packed);
  switch (e.method) {
    case 1:
      return ShrinkDecoder(input, e.size);
    case 2:
    case 3:
    case 4:
    case 5:
      return ReduceDecoder(input, e.size, e.method - 1);
    case 6:
      return ImplodeDecoder(input, e.size,
          bigWindow: e.flags & 2 != 0, literalTree: e.flags & 4 != 0);
  }
  throw StateError('method ${e.method}');
}

// Reads the decoder in chunks of changing sizes, so that matches and
// strings get split across calls.
Uint8List _readChunked(InStream s, int size) {
  final out = Uint8List(size + 16);
  var pos = 0;
  var step = 1;
  while (true) {
    final want = step < out.length - pos ? step : out.length - pos;
    final n = s.read(out, pos, want);
    if (n == 0) break;
    pos += n;
    step = step * 7 % 1013 + 1;
  }
  return Uint8List.sublistView(out, 0, pos);
}

void main() {
  final dir = Directory('test/data/zip_legacy');
  final files = dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.zip'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  test('fixtures present', () {
    expect(files.length, greaterThanOrEqualTo(19));
  });

  for (final f in files) {
    final base = f.uri.pathSegments.last;
    group(base, () {
      final e = _parse(f.readAsBytesSync());
      final parts = e.name.split('.').first.split('-');
      final expected =
          genContent(parts[0], int.parse(parts[1]), int.parse(parts[2]));

      test('decodes', () {
        expect(e.size, expected.length);
        final out = readAll(_decoder(e, e.packed));
        expect(out.length, e.size);
        expect(Crc32.of(out), e.crc);
        expect(out, expected);
      });

      test('decodes in small reads', () {
        final out = _readChunked(_decoder(e, e.packed), e.size);
        expect(out, expected);
      });

      test('truncated input is an unexpected end', () {
        final cut = Uint8List.sublistView(e.packed, 0, e.packed.length ~/ 2);
        expect(
            () => readAll(_decoder(e, cut)),
            throwsA(isA<SevenZipException>()
                .having((x) => x.kind, 'kind', SevenZipError.unexpectedEnd)));
      });

      test('corrupt input does not decode silently', () {
        final bad = Uint8List.fromList(e.packed);
        for (var i = bad.length ~/ 3; i < bad.length; i += 97) {
          bad[i] ^= 0x5A;
        }
        try {
          final out = readAll(_decoder(e, bad));
          expect(Crc32.of(out) == e.crc && _same(out, expected), isFalse);
        } on SevenZipException catch (x) {
          expect(
              x.kind, anyOf(SevenZipError.data, SevenZipError.unexpectedEnd));
        }
      });
    });
  }
}

bool _same(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
