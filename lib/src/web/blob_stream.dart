// A SeekableInStream over a browser Blob (an uploaded File), read in
// blocks with FileReaderSync: random access to a file of any size without
// copying it into memory (workers only).

import 'dart:js_interop';
import 'dart:typed_data';

import '../io/streams.dart';
import 'block_cache.dart';
import 'js_bindings.dart';

class BlobInStream implements ClosableInStream {
  final JSBlob blob;
  final JSFileReaderSync _reader = JSFileReaderSync();
  final BlockCache _cache;
  @override
  final int length;
  @override
  int position = 0;

  BlobInStream(this.blob, {int blockSize = 1 << 20, int cacheBytes = 8 << 20})
      : length = blob.size,
        _cache = BlockCache(blockSize, cacheBytes);

  Uint8List _load(int index) {
    final start = index * _cache.blockSize;
    var end = start + _cache.blockSize;
    if (end > length) end = length;
    final buf = _reader.readAsArrayBuffer(blob.slice(start, end));
    return Uint8List.fromList(buf.toDart.asUint8List());
  }

  @override
  int read(Uint8List buf, int off, int len) {
    if (position >= length || len <= 0) return 0;
    if (len > length - position) len = length - position;
    final n = _cache.read(position, buf, off, len, _load);
    position += n;
    return n;
  }

  @override
  void close() => _cache.clear();
}
