// The warm set of a database in parts (io/part_set.dart, docs/architecture.md
// section 21): the blocks that opening the database and the app's usual
// queries read first, recorded once with `zx parts warm` and listed in the
// manifest, so the web engine fetches them in parallel when it opens the
// set instead of one request after another while a query walks its trees.
//
// The queries run with cold caches, one at a time, on the set read
// through a stream that notes every block read. Kept: every block opening
// reads, and every block that at least [minHits] queries read (the roots
// and upper levels that queries of one kind share; a leaf read by one
// query only is left out). Most shared first, up to [maxBytes].

import 'dart:typed_data';

import '../io/part_set.dart';
import '../io/streams.dart';
import 'engine/store.dart' show ZxDbStoreOptions;
import 'zxdb.dart' show ZxDatabase;

class _Recording implements ClosableInStream {
  final ClosableInStream inner;
  final int blockSize;
  Set<int> blocks = {};
  _Recording(this.inner, this.blockSize);

  @override
  int get length => inner.length;
  @override
  int get position => inner.position;
  @override
  set position(int p) => inner.position = p;

  @override
  int read(Uint8List buf, int off, int len) {
    final at = inner.position;
    final n = inner.read(buf, off, len);
    if (n > 0) {
      for (var b = at ~/ blockSize; b <= (at + n - 1) ~/ blockSize; b++) {
        blocks.add(b);
      }
    }
    return n;
  }

  Set<int> take() {
    final s = blocks;
    blocks = {};
    return s;
  }

  @override
  void close() => inner.close();
}

class _OneFile implements HostFiles {
  final String path;
  final _Recording stream;
  _OneFile(this.path, this.stream);
  @override
  int? sizeOf(String p) => p == path ? stream.length : null;
  @override
  ClosableInStream open(String p) {
    if (p != path) throw SevenZipException('$p is not open', SevenZipError.io);
    return stream;
  }
}

/// What [zxRecordWarmSet] found.
class ZxWarmReport {
  final ZxPartManifest manifest;
  final int openBlocks;
  final int sharedBlocks;
  final int leftOut;
  const ZxWarmReport(
      this.manifest, this.openBlocks, this.sharedBlocks, this.leftOut);
}

/// Records the warm set of the database whose part manifest is at
/// [manifestPath] (native files) from [sqls], in blocks of [blockSize]
/// (the web engine's block size); returns the manifest with it (the file
/// is not written).
ZxWarmReport zxRecordWarmSet(String manifestPath, List<String> sqls,
    {int blockSize = 64 << 10, int minHits = 2, int maxBytes = 8 << 20}) {
  final m = readPartManifest(manifestPath);
  final rec = _Recording(openPartSet(manifestPath), blockSize);
  final path = '/warm/${m.name}';
  final saved = hostFiles;
  hostFiles = _OneFile(path, rec);
  final Set<int> open;
  final counts = <int, int>{};
  try {
    final db = ZxDatabase.open(path,
        readOnly: true,
        options: ZxDbStoreOptions(threads: 1, refreshMicros: 1 << 40));
    try {
      open = rec.take();
      for (final sql in sqls) {
        db.store.clearCaches();
        rec.take();
        db.sql.execute(sql);
        for (final b in rec.take()) {
          counts[b] = (counts[b] ?? 0) + 1;
        }
      }
    } finally {
      db.close();
    }
  } finally {
    hostFiles = saved;
    rec.close();
  }
  final shared = [
    for (final e in counts.entries)
      if (e.value >= minHits && !open.contains(e.key)) e,
  ]..sort((a, b) => b.value != a.value ? b.value - a.value : a.key - b.key);
  final maxBlocks = maxBytes ~/ blockSize;
  final chosen = <int>{...open};
  var left = 0;
  for (final e in shared) {
    if (chosen.length < maxBlocks) {
      chosen.add(e.key);
    } else {
      left++;
    }
  }
  final sorted = chosen.toList()..sort();
  final ranges = <(int, int)>[];
  for (var i = 0; i < sorted.length;) {
    var j = i;
    while (j + 1 < sorted.length && sorted[j + 1] == sorted[j] + 1) {
      j++;
    }
    final start = sorted[i] * blockSize;
    var end = (sorted[j] + 1) * blockSize;
    if (end > m.size) end = m.size;
    ranges.add((start, end - start));
    i = j + 1;
  }
  return ZxWarmReport(
      m.withWarm(ranges), open.length, chosen.length - open.length, left);
}
