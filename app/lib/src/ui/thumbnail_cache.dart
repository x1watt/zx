// Persistent thumbnails for the explorer. Thumbnails are small PNGs in a
// private .zx archive; cache failures never prevent the original image from
// being shown.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:path/path.dart' as p;
import 'package:zx/zx.dart';

const _indexPath = 'thumbnails/index.json';
const _thumbPrefix = 'thumbnails/v1/';
const _maxSourceBytes = 40 << 20;
const _maxThumbBytes = 1 << 20;
const _maxEntries = 512;
const _pruneToEntries = 448;
const _maxCacheBytes = 64 << 20;
const _pruneToBytes = 52 << 20;
const _memoryBudget = 16 << 20;
const _writesBetweenCompactions = 32;
const _writeDebounce = Duration(milliseconds: 180);

/// Stable thumbnail identity and an asynchronous source reader.
class ThumbnailRequest {
  final String key;
  final Future<Uint8List?> Function() readSource;

  const ThumbnailRequest(this.key, this.readSource);
}

/// A .zx-backed cache shared by all views in one explorer window.
class ThumbnailCache {
  final String archivePath;
  final String tempDir;

  ZxArchive? _archive;
  Future<ZxArchive?>? _opening;
  final Map<String, Future<Uint8List?>> _pending = {};
  final Map<String, Uint8List> _queuedWrites = {};
  final Set<String> _queuedDeletes = {};
  Future<void>? _drainingWrites;
  final LinkedHashMap<String, Uint8List> _memory = LinkedHashMap();
  final Map<String, int> _lastUsed = {};
  final Queue<Completer<void>> _loadWaiters = Queue();
  int _activeLoads = 0;
  int _memoryBytes = 0;
  int _useClock = 0;
  int _touchesSinceIndex = 0;
  int _writesSinceCompact = 0;
  bool _disabled = false;
  bool _closing = false;
  bool _closed = false;
  Future<void>? _closeFuture;

  ThumbnailCache({required this.archivePath, required this.tempDir});

  /// Returns a cached image, or creates one from [request] without making
  /// the caller wait for the .zx archive write.
  Future<Uint8List?> load(ThumbnailRequest request) {
    if (_closing || _closed) return Future.value(null);
    final inMemory = _memory.remove(request.key);
    if (inMemory != null) {
      _memory[request.key] = inMemory;
      _touch(request.key);
      return Future.value(inMemory);
    }
    final existing = _pending[request.key];
    if (existing != null) return existing;
    final future = _withLoadSlot(() => _load(request));
    _pending[request.key] = future;
    return future.whenComplete(() => _pending.remove(request.key));
  }

  Future<T> _withLoadSlot<T>(Future<T> Function() body) async {
    if (_activeLoads >= 2) {
      final wait = Completer<void>();
      _loadWaiters.addLast(wait);
      await wait.future;
    }
    _activeLoads++;
    try {
      return await body();
    } finally {
      _activeLoads--;
      if (_loadWaiters.isNotEmpty) _loadWaiters.removeFirst().complete();
    }
  }

  Future<Uint8List?> _load(ThumbnailRequest request) async {
    if (_closing || _closed) return null;
    final entryPath = _pathFor(request.key);
    final archive = await _open();
    if (archive != null) {
      final item = archive[entryPath];
      if (item != null && !item.isDir && (item.size ?? 0) <= _maxThumbBytes) {
        try {
          final bytes = await archive.readBytes(item, maxBytes: _maxThumbBytes);
          if (bytes.isNotEmpty) {
            _remember(request.key, bytes);
            _touch(request.key);
            return bytes;
          }
        } on Object {
          // A missing or damaged cache entry is treated as a cache miss.
        }
      }
    }

    try {
      final source = await request.readSource();
      if (source == null || source.isEmpty || source.length > _maxSourceBytes) {
        return null;
      }
      final thumbnail = await _encode(source);
      if (thumbnail == null || thumbnail.length > _maxThumbBytes) return null;
      _remember(request.key, thumbnail);
      _touch(request.key);
      if (!_closed && !_disabled) {
        unawaited(_enqueueWrite(_pathFor(request.key), thumbnail));
      }
      return thumbnail;
    } on Object {
      return null;
    }
  }

  Future<Uint8List?> _encode(Uint8List source) async {
    ui.Codec? codec;
    ui.Image? image;
    try {
      // Specify only a target width: the codec retains the source aspect ratio.
      codec = await ui.instantiateImageCodec(
        source,
        targetWidth: 256,
        allowUpscaling: false,
      );
      final frame = await codec.getNextFrame();
      image = frame.image;
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) return null;
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } on Object {
      return null;
    } finally {
      image?.dispose();
      codec?.dispose();
    }
  }

  Future<ZxArchive?> _open() async {
    if (_closed || _disabled) return null;
    // A queued write must keep using the existing archive while close drains
    // it. Returning null here would create a fresh archive with overwrite and
    // discard the cache that was already on disk.
    final active = _archive;
    if (active != null) return active;
    final opening = _opening;
    if (opening != null) return opening;
    if (_closing) return null;
    final future = () async {
      try {
        if (!await File(archivePath).exists()) return null;
        final archive = await ZxArchive.open(archivePath);
        if (archive.format != 'zx') {
          await archive.close();
          _disabled = true;
          return null;
        }
        _archive = archive;
        await _readIndex(archive);
        return archive;
      } on Object {
        // A broken cache is disposable. Do not block or fail file browsing.
        _disabled = true;
        return null;
      }
    }();
    _opening = future;
    try {
      return await future;
    } finally {
      _opening = null;
    }
  }

  Future<void> _readIndex(ZxArchive archive) async {
    final item = archive[_indexPath];
    if (item == null || item.isDir || (item.size ?? 0) > 2 << 20) return;
    try {
      final bytes = await archive.readBytes(item, maxBytes: 2 << 20);
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map) return;
      final clock = decoded['clock'];
      if (clock is int && clock > _useClock) _useClock = clock;
      final uses = decoded['uses'];
      if (uses is Map) {
        for (final entry in uses.entries) {
          if (entry.key is String && entry.value is int) {
            _lastUsed[entry.key as String] = entry.value as int;
          }
        }
      }
    } on Object {
      // A stale index only affects eviction order.
    }
  }

  void _touch(String key) {
    _lastUsed[key] = ++_useClock;
    _touchesSinceIndex++;
    if (_touchesSinceIndex >= 32) {
      _touchesSinceIndex = 0;
      unawaited(_enqueueWrite(null, null));
    }
  }

  /// Reads one internal archive entry (null when absent). This is used by
  /// the background indexer; callers never hold a second archive handle.
  Future<Uint8List?> readArchiveEntry(
    String path, {
    int maxBytes = 1 << 20,
  }) async {
    final archive = await _open();
    final item = archive?[path];
    if (item == null || item.isDir || (item.size ?? 0) > maxBytes) return null;
    try {
      return await archive!.readBytes(item, maxBytes: maxBytes);
    } on Object {
      return null;
    }
  }

  /// Reads small entries under [prefix], for example the per-drive summaries.
  Future<Map<String, Uint8List>> readArchiveEntries(
    String prefix, {
    int maxEntries = 4096,
    int maxEntryBytes = 1 << 20,
  }) async {
    final archive = await _open();
    if (archive == null) return {};
    final out = <String, Uint8List>{};
    for (final item in archive.items) {
      if (item.isDir || !item.path.startsWith(prefix)) continue;
      if (out.length >= maxEntries) break;
      if ((item.size ?? 0) > maxEntryBytes) continue;
      try {
        out[item.path] = await archive.readBytes(item, maxBytes: maxEntryBytes);
      } on Object {
        // One corrupt index entry does not prevent loading the rest.
      }
    }
    return out;
  }

  /// Queues metadata in this same .zx archive as thumbnails.
  Future<void> writeArchiveEntries(Map<String, Uint8List> entries) async {
    if (_closing || _closed || _disabled || entries.isEmpty) return;
    for (final entry in entries.entries) {
      _queuedDeletes.remove(entry.key);
      _queuedWrites[entry.key] = entry.value;
    }
    await _enqueueWrite(null, null, debounce: false);
  }

  /// Removes stale metadata entries from the shared .zx archive.
  Future<void> deleteArchiveEntries(Iterable<String> paths) async {
    if (_closing || _closed || _disabled) return;
    _queuedDeletes.addAll(paths);
    await _enqueueWrite(null, null, debounce: false);
  }

  /// Completes after the queued archive update has been written.
  Future<void> flushWrites() async {
    while (_drainingWrites != null ||
        _queuedWrites.isNotEmpty ||
        _queuedDeletes.isNotEmpty) {
      final draining = _drainingWrites;
      if (draining != null) {
        await draining;
      } else {
        await _enqueueWrite(null, null);
      }
    }
  }

  /// [debounce] groups the many small writes of the thumbnail path; index
  /// metadata is written at once so it is on disk before the next scan.
  Future<void> _enqueueWrite(
    String? path,
    Uint8List? bytes, {
    bool debounce = true,
  }) async {
    if (_closed || _disabled) return;
    if (path != null && bytes != null) {
      _queuedDeletes.remove(path);
      _queuedWrites[path] = bytes;
    }
    if (_drainingWrites != null) return;
    _drainingWrites =
        (debounce ? Future<void>.delayed(_writeDebounce) : Future<void>.value())
            .then((_) async {
              final batch = Map<String, Uint8List>.of(_queuedWrites);
              final deletes = Set<String>.of(_queuedDeletes);
              _queuedWrites.clear();
              _queuedDeletes.clear();
              try {
                await _writeBatch(batch, deletes);
              } on Object {
                // A cache write failure does not affect the displayed thumbnail.
              }
            })
            .whenComplete(() {
              _drainingWrites = null;
              if ((_queuedWrites.isNotEmpty || _queuedDeletes.isNotEmpty) &&
                  !_closed &&
                  !_disabled) {
                unawaited(_enqueueWrite(null, null));
              }
            });
    await _drainingWrites;
  }

  Future<void> _writeBatch(
    Map<String, Uint8List> entries,
    Set<String> deletes,
  ) async {
    // An already-queued update may finish while close waits for it.
    if (_closed || _disabled) return;
    final archive = await _open();
    await Directory(tempDir).create(recursive: true);
    final stage = await Directory(tempDir).createTemp('zx-thumb-');
    try {
      final sources = <ZxSource>[];
      var sourceId = 0;
      for (final entry in entries.entries) {
        final entryFile = File(p.join(stage.path, 'entry-${sourceId++}.bin'));
        await entryFile.writeAsBytes(entry.value, flush: true);
        sources.add(ZxSource(entryFile.path, storedAs: entry.key));
      }
      final indexFile = File(p.join(stage.path, 'index.json'));
      await indexFile.writeAsString(
        jsonEncode({'clock': _useClock, 'uses': _lastUsed}),
        flush: true,
      );
      sources.add(ZxSource(indexFile.path, storedAs: _indexPath));

      if (archive == null) {
        if (sources.isEmpty) return;
        await Directory(p.dirname(archivePath)).create(recursive: true);
        _archive = await ZxArchive.create(
          archivePath,
          sources,
          options: const ZxOptions(
            compression: ZxCompression.manual(chain: 'store'),
            dedup: false,
          ),
          overwrite: true,
        );
      } else {
        if (deletes.isNotEmpty) {
          await archive.delete(deletes.toList());
          _writesSinceCompact = _writesBetweenCompactions;
        }
        final thumbnailWrites = entries.entries
            .where((entry) => entry.key.startsWith(_thumbPrefix))
            .toList();
        final thumbnails = _thumbnailItems(archive);
        final count = thumbnails.length;
        final existingBytes = thumbnails.fold<int>(
          0,
          (sum, item) => sum + (item.size ?? 0),
        );
        var replacedBytes = 0;
        for (final entry in thumbnailWrites) {
          replacedBytes += archive[entry.key]?.size ?? 0;
        }
        final newKeys = thumbnailWrites.where(
          (entry) => archive[entry.key] == null,
        );
        final projectedCount = count + newKeys.length;
        final addedBytes = thumbnailWrites.fold<int>(
          0,
          (sum, entry) => sum + entry.value.length,
        );
        final projectedBytes = existingBytes - replacedBytes + addedBytes;
        if (projectedCount > _maxEntries || projectedBytes > _maxCacheBytes) {
          await _evict(
            archive,
            count,
            existingBytes,
            addedBytes - replacedBytes,
          );
          // Deletion appends a generation; compact with the next update.
          _writesSinceCompact = _writesBetweenCompactions;
        }
        if (sources.isEmpty) return;
        await archive.add(
          sources,
          options: const ZxOptions(
            compression: ZxCompression.manual(chain: 'store'),
            dedup: false,
          ),
        );
      }
      final activeArchive = _archive;
      if (activeArchive != null) {
        _writesSinceCompact++;
        if (activeArchive.numVersions > 1 &&
            (_writesSinceCompact >= _writesBetweenCompactions ||
                activeArchive.physicalSize > _maxCacheBytes * 2)) {
          await activeArchive.compact(keep: 1);
          _writesSinceCompact = 0;
        }
      }
    } finally {
      try {
        await stage.delete(recursive: true);
      } on FileSystemException {
        // Temporary cache input cleanup is best effort.
      }
    }
  }

  Future<void> _evict(
    ZxArchive archive,
    int count,
    int total,
    int incomingBytes,
  ) async {
    final items = _thumbnailItems(archive);
    if (items.isEmpty) return;
    items.sort((a, b) {
      final au = _lastUsed[_keyFromPath(a.path)] ?? (a.generation ?? 0);
      final bu = _lastUsed[_keyFromPath(b.path)] ?? (b.generation ?? 0);
      return au.compareTo(bu);
    });
    var remainingCount = count;
    var remainingBytes = total;
    final remove = <String>[];
    for (final item in items) {
      if (remainingCount <= _pruneToEntries &&
          remainingBytes + incomingBytes <= _pruneToBytes) {
        break;
      }
      remove.add(item.path);
      remainingCount--;
      remainingBytes -= item.size ?? 0;
      final key = _keyFromPath(item.path);
      _lastUsed.remove(key);
      _memoryBytes -= _memory.remove(key)?.length ?? 0;
    }
    if (remove.isNotEmpty) await archive.delete(remove);
  }

  List<ZxItem> _thumbnailItems(ZxArchive archive) => [
    for (final item in archive.items)
      if (!item.isDir && item.path.startsWith(_thumbPrefix)) item,
  ];

  void _remember(String key, Uint8List bytes) {
    final old = _memory.remove(key);
    if (old != null) _memoryBytes -= old.length;
    _memory[key] = bytes;
    _memoryBytes += bytes.length;
    while (_memoryBytes > _memoryBudget && _memory.isNotEmpty) {
      final first = _memory.keys.first;
      _memoryBytes -= _memory.remove(first)!.length;
    }
  }

  String _pathFor(String key) => '$_thumbPrefix$key.png';

  String _keyFromPath(String path) =>
      path.substring(_thumbPrefix.length, path.length - '.png'.length);

  /// Close the archive handle after pending cache reads and writes drain.
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    if (_closed) return;
    _closing = true;
    final pending = List<Future<Uint8List?>>.of(_pending.values);
    if (pending.isNotEmpty) {
      await Future.wait(pending).timeout(const Duration(seconds: 20));
    }
    try {
      await flushWrites().timeout(const Duration(seconds: 20));
    } on TimeoutException {
      // A cache write must never hold up window disposal indefinitely.
    }
    _closed = true;
    _queuedWrites.clear();
    _queuedDeletes.clear();
    final archive = _archive;
    _archive = null;
    await archive?.close();
    _memory.clear();
    _pending.clear();
    while (_loadWaiters.isNotEmpty) {
      _loadWaiters.removeFirst().complete();
    }
  }
}

/// Content identity for an image source. This hashes only short metadata,
/// never the image contents, so building a tile stays cheap.
String thumbnailKey(String identity) {
  final hash = Sha256()
    ..update(Uint8List.fromList(utf8.encode('zx-thumb-v1\n$identity')));
  return [
    for (final byte in hash.digest()) byte.toRadixString(16).padLeft(2, '0'),
  ].join();
}

/// Reads a local image in a worker isolate, refusing unexpectedly large
/// files before materializing them.
Future<Uint8List?> readThumbnailFile(String path, int expectedSize) =>
    Isolate.run(() async {
      if (expectedSize <= 0 || expectedSize > _maxSourceBytes) return null;
      final file = File(path);
      final stat = await file.stat();
      if (stat.size <= 0 || stat.size > _maxSourceBytes) return null;
      return file.readAsBytes();
    });
