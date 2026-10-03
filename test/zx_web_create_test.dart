// lib/src/web/zx_web_create.dart: creating a .zx archive from web-style
// sources (no dart:io, no dart:js_interop) into a non-seekable sink, the
// shape the browser's OPFS OutStream has (library.dart).

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/cli/zx_zcm_auto.dart' show ZxAutoSpeed;
import 'package:zx/src/codec/zcm/zcm.dart' show ZcmOptions;
import 'package:zx/src/format/zx/zx_reader.dart';
import 'package:zx/src/io/streams.dart';
import 'package:zx/src/web/zx_web_create.dart';
import 'package:zx/src/zx_estimate.dart' show ZxCompression;

import 'zx_test_util.dart';

/// A non-seekable OutStream (like the browser's OPFS sink): proves the
/// write path needs nothing but sequential writes.
class _PipeOut implements OutStream {
  final _buf = BytesBuilder(copy: false);
  @override
  void write(Uint8List buf, int off, int len) =>
      _buf.add(Uint8List.sublistView(buf, off, off + len));
  @override
  void flush() {}
  Uint8List bytes() => _buf.takeBytes();
}

ZxWebSource _source(String path, Uint8List data, {int? mTime}) =>
    ZxWebSource(path, data.length, mTime, () => MemoryInStream(data));

void main() {
  group('buildZxArchive', () {
    test('round-trips several files through a non-seekable sink', () {
      final files = {
        'a.txt': textBytes(90000, 1),
        'b.bin': lcgBytes(20000, 2),
        'empty.txt': Uint8List(0),
      };
      final out = _PipeOut();
      final warnings = buildZxArchive(
        out,
        [for (final e in files.entries) _source(e.key, e.value)],
        compression: const ZxCompression.manual(chain: 'store'),
        solid: true,
      );
      expect(warnings, isEmpty);
      final bytes = out.bytes();
      expect(ZxArchiveReader.readHeader(MemoryInStream(bytes))!.streamed, true);
      final got = extractAll(openMem(bytes));
      expect(got.length, files.length);
      for (final e in files.entries) {
        expect(got[e.key], e.value, reason: e.key);
      }
    });

    test('progress is reported as bytes are written', () {
      final data = textBytes(50000, 3);
      final out = _PipeOut();
      final seen = <int>[];
      buildZxArchive(
        out,
        [_source('f.txt', data)],
        compression: const ZxCompression.manual(chain: 'store'),
        solid: false,
        onProgress: (done, total, file) {
          seen.add(done);
          expect(total, data.length);
          expect(file, 'f.txt');
        },
      );
      expect(seen, isNotEmpty);
      expect(seen.last, data.length);
    });

    test('a password protects the archive; the wrong one fails', () {
      final data = textBytes(5000, 4);
      final out = _PipeOut();
      buildZxArchive(
        out,
        [_source('secret.txt', data)],
        compression: const ZxCompression.manual(chain: 'store'),
        solid: true,
        password: 'right',
      );
      final bytes = out.bytes();
      expect(extractAll(openMem(bytes, password: 'right'))['secret.txt'], data);
      expect(
        () => openMem(bytes, password: 'wrong'),
        throwsA(anything),
      );
    });

    test('same-size files do not crash dedup-off handling', () {
      // two files of the same size: a dedup candidate if dedup were on
      final a = lcgBytes(8000, 10), b = lcgBytes(8000, 11);
      final out = _PipeOut();
      buildZxArchive(
        out,
        [_source('x', a), _source('y', b)],
        compression: const ZxCompression.manual(chain: 'store'),
        solid: true,
      );
      final got = extractAll(openMem(out.bytes()));
      expect(got['x'], a);
      expect(got['y'], b);
    });

    test('manual zcm and auto compression both round-trip', () {
      final data = textBytes(60000, 5);
      final zcmOut = _PipeOut();
      buildZxArchive(
        zcmOut,
        [_source('f', data)],
        compression: const ZxCompression.manual(zcm: ZcmOptions(level: 3)),
        solid: true,
      );
      expect(extractAll(openMem(zcmOut.bytes()))['f'], data);

      final autoOut = _PipeOut();
      buildZxArchive(
        autoOut,
        [_source('f', data)],
        compression: const ZxCompression.auto(speed: ZxAutoSpeed.fast),
        solid: true,
      );
      expect(extractAll(openMem(autoOut.bytes()))['f'], data);
    });
  });

  group('compressionFromWire', () {
    test('auto', () {
      final c = compressionFromWire({
        'auto': true,
        'speed': 'fast',
      });
      expect(c.auto, true);
      expect(c.speed, ZxAutoSpeed.fast);
    });

    test('manual chain', () {
      final c = compressionFromWire({'auto': false, 'chain': 'store'});
      expect(c.auto, false);
      expect(c.chain, 'store');
    });

    test('manual zcm', () {
      final c = compressionFromWire({
        'auto': false,
        'zcmLevel': 6,
        'zcmMemoryMiB': 128,
        'lstm': false,
      });
      expect(c.auto, false);
      expect(c.zcm!.level, 6);
      expect(c.zcm!.memoryMiB, 128);
    });
  });

  group('sanitizeArchiveItemNames', () {
    test('de-duplicates and normalizes', () {
      final names = sanitizeArchiveItemNames(['a.txt', 'a.txt', 'a.txt', '']);
      expect(names, ['a.txt', 'a (2).txt', 'a (3).txt', 'file']);
    });

    test('flattens path separators', () {
      expect(sanitizeArchiveItemNames(['a/b\\c']), ['a_b_c']);
    });
  });
}
