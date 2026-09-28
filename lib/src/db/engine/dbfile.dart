// The .zx file under a database store: reading Index blocks and database
// page blocks by offset, with the caches of decoded blocks, map pages and
// pages (keyed by their place in the file, so they are shared by every
// snapshot and stay valid across commits).

import 'dart:io';
import 'dart:typed_data';

import '../../format/zx/zx_blocks.dart';
import '../../format/zx/zx_crypto.dart';
import '../../format/zx/zx_format.dart';
import '../../format/zx/zx_reader.dart';
import '../../io/streams.dart' show SevenZipException;
import '../storage_api.dart';
import 'cache.dart';
import 'page.dart';

/// One opened archive file (a store opens it again when another process
/// replaces it, for example after a vacuum).
class DbFile {
  final String path;
  final RandomAccessFile raf;
  final ZxHeader header;
  final ZxKeys? keys;

  /// Every chain seen in an Index (ids are never redefined in a file).
  final Map<int, ZxChain> chains = {};

  /// Decoded page blocks (type 7), by offset.
  final LruCache<Uint8List> blocks;

  /// Decoded pages, by [ZxDbLoc.cacheKey].
  final LruCache<Node> pages;

  /// Decoded map pages, by [ZxDbLoc.cacheKey].
  final LruCache<Uint8List> maps;

  DbFile(this.path, this.raf, this.header, this.keys,
      {int pageCacheBytes = 64 << 20, int blockCacheBytes = 16 << 20})
      : blocks = LruCache<Uint8List>(blockCacheBytes, (b) => b.length + 64),
        pages = LruCache<Node>(pageCacheBytes, (n) => n.memory),
        maps = LruCache<Uint8List>(
            pageCacheBytes ~/ 8 < mapPageBytes * 4
                ? mapPageBytes * 4
                : pageCacheBytes ~/ 8,
            (b) => b.length + 64);

  void addChains(Map<int, ZxChain> m) {
    m.forEach((id, c) => chains.putIfAbsent(id, () => c));
  }

  Uint8List readAt(int off, int len) {
    final b = Uint8List(len);
    raf.setPositionSync(off);
    var n = 0;
    while (n < len) {
      final k = raf.readIntoSync(b, n, len);
      if (k <= 0) {
        throw const ZxDbException(
            'unexpected end of the archive', ZxDbError.corrupt);
      }
      n += k;
    }
    return b;
  }

  int get length => raf.lengthSync();

  /// Reads and decodes the Index at [loc] (as ZxArchiveReader.readIndex).
  ZxIndex readIndex(ZxIndexLoc loc) {
    try {
      final raw = readAt(loc.offset, loc.size);
      final parts = <Uint8List>[];
      var pos = 0, total = 0;
      while (pos < raw.length) {
        final h = ZxBlockHeader.tryParse(raw, pos, raw.length);
        if (h == null || h.type != ZxBlockType.index) {
          zxDamaged('damaged Index block');
        }
        final end = pos + h.headerSize + h.packedSize;
        if (end > raw.length) zxDamaged('truncated Index block');
        final chain = ZxArchiveReader.metaChainOf(header, h.chainId);
        final k = header.encryptedMetadata ? keys : null;
        final data = zxDecodeBlock(ZxDecodeArg(
            Uint8List.sublistView(raw, pos, end), chain, k?.aesKey, k?.macKey));
        parts.add(data);
        total += data.length;
        pos = end;
      }
      final all = Uint8List(total);
      var o = 0;
      for (final p in parts) {
        all.setRange(o, o + p.length, p);
        o += p.length;
      }
      final idx = ZxIndex.decode(all, multiVolume: header.multiVolume);
      addChains(idx.chains);
      return idx;
    } on SevenZipException catch (e) {
      zxDbCorrupt(e);
    }
  }

  /// The decoded payload of the page block at [offset] ([size] bytes).
  Uint8List block(int offset, int size) {
    final hit = blocks.get(offset);
    if (hit != null) return hit;
    final Uint8List data;
    try {
      final raw = readAt(offset, size);
      final h = ZxBlockHeader.tryParse(raw, 0, raw.length);
      if (h == null || h.type != ZxBlockType.dbPages) {
        throw const ZxDbException(
            'damaged database page block', ZxDbError.corrupt);
      }
      final chain = h.chainId == 0 ? const ZxChain(0, []) : chains[h.chainId];
      if (chain == null) {
        throw ZxDbException(
            'undeclared chain ${h.chainId} of a database page block',
            ZxDbError.corrupt);
      }
      final k = keys;
      data = zxDecodeBlock(ZxDecodeArg(raw, chain, k?.aesKey, k?.macKey));
    } on SevenZipException catch (e) {
      zxDbCorrupt(e);
    }
    blocks.put(offset, data);
    return data;
  }

  /// The bytes of the page at [loc] (a view of its decoded block).
  Uint8List pageBytes(ZxDbLoc loc) {
    final b = block(loc.blockOffset, loc.blockSize);
    if (loc.inOffset + loc.length > b.length) {
      throw const ZxDbException(
          'database page outside its block', ZxDbError.corrupt);
    }
    return Uint8List.sublistView(b, loc.inOffset, loc.inOffset + loc.length);
  }

  /// The decoded page at [loc].
  Node node(ZxDbLoc loc) {
    final key = loc.cacheKey;
    final hit = pages.get(key);
    if (hit != null) return hit;
    final b = block(loc.blockOffset, loc.blockSize);
    if (loc.inOffset + loc.length > b.length) {
      throw const ZxDbException(
          'database page outside its block', ZxDbError.corrupt);
    }
    final n = Node.decode(b, loc.inOffset, loc.length);
    pages.put(key, n);
    return n;
  }

  /// The map page at [loc] (1024 entries of 24 bytes).
  Uint8List mapPage(ZxDbLoc loc) {
    final key = loc.cacheKey;
    final hit = maps.get(key);
    if (hit != null) return hit;
    final b = block(loc.blockOffset, loc.blockSize);
    if (loc.length != mapPageBytes || loc.inOffset + loc.length > b.length) {
      throw const ZxDbException('damaged database map page', ZxDbError.corrupt);
    }
    final m = Uint8List.fromList(
        Uint8List.sublistView(b, loc.inOffset, loc.inOffset + loc.length));
    maps.put(key, m);
    return m;
  }

  void close() {
    try {
      raf.closeSync();
    } on FileSystemException {
      // ignore
    }
  }
}

/// Resolves page ids of one generation's database (its page map).
class DbView implements PageReader {
  final DbFile file;
  final ZxDbRoot? root;

  // the pages read through this view by id (a view does
  // not change, so neither do its pages); bounded
  final Map<int, Node> _memo = {};
  static const int _memoMax = 4096;

  DbView(this.file, this.root);

  int get catalogRoot => root?.catalogRoot ?? 0;

  ZxDbLoc? locOf(int id) {
    final r = root;
    if (r == null || id <= 0 || id >= r.nextPageId) return null;
    final k = id >> ZxDbRoot.mapPageLog2;
    if (k >= r.maps.length) return null;
    final ml = r.maps[k];
    if (ml == null) return null;
    final m = file.mapPage(ml);
    return ZxDbLoc.readEntry(
        m, (id & (ZxDbRoot.mapPageEntries - 1)) * ZxDbLoc.entrySize);
  }

  @override
  Node read(int id) => page(id);

  Node page(int id) {
    final hit = _memo[id];
    if (hit != null) {
      file.pages.hits++;
      return hit;
    }
    final loc = locOf(id);
    if (loc == null) {
      throw ZxDbException('missing database page $id', ZxDbError.corrupt);
    }
    final n = file.node(loc);
    if (_memo.length >= _memoMax) _memo.clear();
    _memo[id] = n;
    return n;
  }
}
