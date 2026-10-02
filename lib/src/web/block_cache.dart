// A least-recently-used cache of fixed-size blocks of a random access
// source (the Blob and HTTP range streams of the web engine). Pure Dart, so
// it is tested on the VM.

import 'dart:collection';
import 'dart:typed_data';

class BlockCache {
  final int blockSize;
  final int maxBlocks;
  final LinkedHashMap<int, Uint8List> _blocks = LinkedHashMap();

  BlockCache(this.blockSize, int cacheBytes)
      : maxBlocks = cacheBytes ~/ blockSize < 2 ? 2 : cacheBytes ~/ blockSize;

  int get length => _blocks.length;

  /// Copies up to [len] bytes at [pos] into [buf] from the block that
  /// holds [pos], loading it with [load] (the block's index) when it is not
  /// cached; returns the bytes copied (at most to the end of that block).
  int read(int pos, Uint8List buf, int off, int len,
      Uint8List Function(int index) load) {
    final index = pos ~/ blockSize;
    var block = _blocks.remove(index);
    if (block == null) {
      block = load(index);
      while (_blocks.length >= maxBlocks) {
        _blocks.remove(_blocks.keys.first);
      }
    }
    _blocks[index] = block;
    final inBlock = pos - index * blockSize;
    if (inBlock >= block.length) return 0;
    var n = block.length - inBlock;
    if (n > len) n = len;
    buf.setRange(off, off + n, block, inBlock);
    return n;
  }

  /// Puts a block loaded ahead (readahead, prefetch).
  void put(int index, Uint8List block) {
    _blocks.remove(index);
    while (_blocks.length >= maxBlocks) {
      _blocks.remove(_blocks.keys.first);
    }
    _blocks[index] = block;
  }

  bool has(int index) => _blocks.containsKey(index);

  void clear() => _blocks.clear();
}
