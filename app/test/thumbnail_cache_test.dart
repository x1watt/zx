import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zx/zx.dart';
import 'package:zx_app/src/ui/thumbnail_cache.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGA'
  'hKmMIQAAAABJRU5ErkJggg==',
);

Uint8List _solidPng(int width, int height) {
  final raw = Uint8List(height * (1 + width * 4));
  for (var y = 0; y < height; y++) {
    final row = y * (1 + width * 4);
    raw[row] = 0;
    for (var x = 0; x < width; x++) {
      final pixel = row + 1 + x * 4;
      raw[pixel] = 0x36;
      raw[pixel + 1] = 0x8a;
      raw[pixel + 2] = 0xd4;
      raw[pixel + 3] = 0xff;
    }
  }

  final output = BytesBuilder(copy: false)
    ..add([137, 80, 78, 71, 13, 10, 26, 10]);
  void chunk(String type, List<int> data) {
    final name = ascii.encode(type);
    final payload = [...name, ...data];
    output.add(_u32(data.length));
    output.add(payload);
    output.add(_u32(_crc32(payload)));
  }

  chunk('IHDR', [..._u32(width), ..._u32(height), 8, 6, 0, 0, 0]);
  chunk('IDAT', ZLibEncoder().convert(raw));
  chunk('IEND', const []);
  return output.takeBytes();
}

List<int> _u32(int value) => [
  (value >> 24) & 0xff,
  (value >> 16) & 0xff,
  (value >> 8) & 0xff,
  value & 0xff,
];

int _crc32(List<int> bytes) {
  var crc = 0xffffffff;
  for (final byte in bytes) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
    }
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}

void main() {
  testWidgets('encodes portrait images without cropping their proportions', (
    tester,
  ) async {
    final root = Directory.systemTemp.createTempSync('zx_thumb_portrait_');
    addTearDown(() => root.deleteSync(recursive: true));
    const width = 32, height = 96;
    final png = _solidPng(width, height);

    final cache = ThumbnailCache(
      archivePath: p.join(root.path, 'thumbs.zx'),
      tempDir: root.path,
    );
    final bytes = await tester.runAsync(
      () => cache.load(
        ThumbnailRequest('portrait', () async => Uint8List.fromList(png)),
      ),
    );
    expect(bytes, isNotNull);
    final encoded = bytes!;
    final decoded = await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(encoded);
      final frame = await codec.getNextFrame();
      codec.dispose();
      return frame.image;
    });
    expect(decoded!.height, greaterThan(decoded.width));
    decoded.dispose();
    await tester.runAsync(cache.close);
  });

  testWidgets('persists thumbnails in a zx archive and serves cache hits', (
    tester,
  ) async {
    final root = Directory.systemTemp.createTempSync('zx_thumb_test_');
    addTearDown(() => root.deleteSync(recursive: true));
    final archivePath = p.join(root.path, 'zx', 'thumbnails.zx');
    final cache = ThumbnailCache(
      archivePath: archivePath,
      tempDir: p.join(root.path, 'tmp'),
    );
    var reads = 0;
    final key = thumbnailKey('source-a');
    final request = ThumbnailRequest(key, () async {
      reads++;
      return Uint8List.fromList(_png);
    });

    final first = await tester.runAsync(() => cache.load(request));
    expect(first, isNotNull);
    expect(first, isNotEmpty);
    await tester.runAsync(cache.flushWrites);
    expect(File(archivePath).existsSync(), isTrue);
    await cache.close();

    final stored = await tester.runAsync(() => ZxArchive.open(archivePath));
    expect(stored!.format, 'zx');
    expect(stored.items.any((i) => i.path == 'thumbnails/v1/$key.png'), isTrue);
    await stored.close();

    final reopened = ThumbnailCache(
      archivePath: archivePath,
      tempDir: p.join(root.path, 'tmp'),
    );
    final hit = await tester.runAsync(
      () => reopened.load(
        ThumbnailRequest(key, () async {
          reads++;
          return null;
        }),
      ),
    );
    expect(hit, first);
    expect(reads, 1, reason: 'a cache hit must not read the original image');

    // Close must drain a queued update without replacing the existing archive.
    final secondKey = thumbnailKey('source-b');
    final second = await tester.runAsync(
      () => reopened.load(
        ThumbnailRequest(secondKey, () async => Uint8List.fromList(_png)),
      ),
    );
    expect(second, isNotNull);
    await tester.runAsync(reopened.close);

    final persisted = await tester.runAsync(() => ZxArchive.open(archivePath));
    expect(
      persisted!.items.map((item) => item.path),
      containsAll(['thumbnails/v1/$key.png', 'thumbnails/v1/$secondKey.png']),
    );
    await persisted.close();
  });

  testWidgets('bad image data falls back without creating a cache archive', (
    tester,
  ) async {
    final root = Directory.systemTemp.createTempSync('zx_thumb_bad_');
    addTearDown(() => root.deleteSync(recursive: true));
    final archivePath = p.join(root.path, 'zx', 'thumbnails.zx');
    final cache = ThumbnailCache(
      archivePath: archivePath,
      tempDir: p.join(root.path, 'tmp'),
    );
    final result = await tester.runAsync(
      () => cache.load(
        ThumbnailRequest('broken', () async => Uint8List.fromList([1, 2, 3])),
      ),
    );
    expect(result, isNull);
    expect(File(archivePath).existsSync(), isFalse);
    await cache.close();
  });
}
