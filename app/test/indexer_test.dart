import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zx/zx.dart';
import 'package:zx_app/src/fs/fs_ops.dart' show sha256OfFile;
import 'package:zx_app/src/platform/places.dart';
import 'package:zx_app/src/ui/indexer.dart';
import 'package:zx_app/src/ui/thumbnail_cache.dart';

class _Places implements PlatformPlaces {
  final String root;
  _Places(this.root);
  @override
  Future<List<Place>> places() async => [Place('Home', root, PlaceKind.home)];
  @override
  Future<List<Place>> volumes() async => const [];
  @override
  Future<SpaceInfo?> space(String path) async => null;
  @override
  Future<bool> ensureAccess() async => true;
  @override
  Future<bool> openWithChooser(String path) async => false;
  @override
  Future<List<AppChoice>> appsFor(String path) async => const [];
  @override
  Future<void> openWith(AppChoice app, String path) async {}
  @override
  bool get canShare => false;
  @override
  Future<void> share(List<String> paths) async {}
}

void main() {
  test('indexes file hashes and recursive folder sizes persistently', () async {
    final temp = Directory.systemTemp.createTempSync('zx_index_test_');
    addTearDown(() => temp.deleteSync(recursive: true));
    final home = Directory(p.join(temp.path, 'home'))..createSync();
    final nested = Directory(p.join(home.path, 'docs', 'deep'))
      ..createSync(recursive: true);
    final random = Random(73);
    final bytes = Uint8List.fromList(
      List.generate(4096, (_) => random.nextInt(256)),
    );
    final first = File(p.join(nested.path, 'guide.txt'))
      ..writeAsBytesSync(bytes);
    final duplicate = File(p.join(home.path, 'guide-copy.txt'))
      ..writeAsBytesSync(bytes);
    final cacheDir = p.join(home.path, '.zx-data');
    final cache = ThumbnailCache(
      archivePath: p.join(cacheDir, 'thumbnails.zx'),
      tempDir: Directory.systemTemp.path,
    );
    final indexer = FileIndexer(
      cache: cache,
      places: _Places(home.path),
      home: home.path,
      excludedDataPath: cacheDir,
    );

    await indexer.start();
    for (var attempt = 0; attempt < 600; attempt++) {
      final drives = indexer.drives;
      if (drives.isNotEmpty &&
          !drives.single.scanning &&
          drives.single.files == 2) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }

    final drive = indexer.drives.single;
    expect(drive.scanning, isFalse);
    expect(drive.files, 2);
    expect(drive.bytes, bytes.length * 2);
    expect(indexer.folderSize(home.path), bytes.length * 2);
    expect(indexer.folderSize(p.join(home.path, 'docs')), bytes.length);
    expect(indexer.folderSize(nested.path), bytes.length);

    final sha = await sha256OfFile(first.path);
    expect(
      indexer.findBySha256(sha),
      containsAll([first.path, duplicate.path]),
    );

    await indexer.close();
    await cache.close();
    final stored = await ZxArchive.open(p.join(cacheDir, 'thumbnails.zx'));
    final shardItems = stored.items
        .where((item) => !item.isDir && item.path.startsWith('index/v1/files/'))
        .toList();
    expect(shardItems, isNotEmpty);
    final records = <Map>[];
    for (final shard in shardItems) {
      records.addAll(
        (jsonDecode(utf8.decode(await stored.readBytes(shard))) as List)
            .cast<Map>(),
      );
    }
    expect(records, hasLength(2));
    expect(records.map((record) => record['h']), everyElement(sha));
    expect(records.map((record) => record['t']), everyElement(isA<String>()));
    expect(
      stored.items.any((item) => item.path.startsWith('index/v1/drives/')),
      isTrue,
    );
    await stored.close();
  });
}
