// A SeekableInStream over a remote file read with HTTP Range requests
// (docs/architecture.md section 20): only the parts an archive's reader
// asks for are fetched. Blocks are cached (least recently used), runs of
// missing blocks are fetched in one request, sequential reads grow a
// readahead, and the first and last blocks of the file stay cached (zip,
// 7z and .zx keep their directories at the end, and every format is
// recognized by its start). The transport is synchronous (XMLHttpRequest
// in a worker); tests use a fake one. Pure Dart apart from the transport.

import 'dart:typed_data';

import '../io/streams.dart';

/// One answer to a range request.
class RangeResponse {
  final int status;
  final Uint8List bytes;

  /// The Content-Range header ("bytes 0-99/1234") when the server exposes
  /// it, the ETag and the Content-Encoding likewise.
  final String? contentRange;
  final String? etag;
  final String? contentEncoding;
  const RangeResponse(this.status, this.bytes,
      {this.contentRange, this.etag, this.contentEncoding});
}

/// Fetches byte ranges of one URL, synchronously.
abstract interface class RangeTransport {
  /// The bytes [start] to [endInclusive] (the server may send fewer at the
  /// end of the file).
  RangeResponse fetch(int start, int endInclusive);
}

/// The total size of a Content-Range header ("bytes 0-99/1234"), or null.
int? contentRangeTotal(String? header) {
  if (header == null) return null;
  final i = header.lastIndexOf('/');
  if (i < 0) return null;
  return int.tryParse(header.substring(i + 1).trim());
}

class HttpRangeInStream implements ClosableInStream {
  final RangeTransport transport;
  @override
  final int length;
  final int blockSize;
  final int maxReadahead;
  final String? etag;
  final int _maxBlocks;

  // index -> block, least recently used first
  final Map<int, Uint8List> _lru = {};
  // the first and last blocks of the file, never evicted
  final Map<int, Uint8List> _pinned = {};
  final Set<int> _pinnedIndices = {};

  @override
  int position = 0;
  int _nextSequential = -1;
  int _readahead;

  /// Statistics: requests made and bytes fetched.
  int requests = 0;
  int bytesFetched = 0;

  HttpRangeInStream(this.transport, this.length,
      {this.blockSize = 256 << 10,
      int cacheBytes = 64 << 20,
      this.maxReadahead = 4 << 20,
      this.etag,
      int pinHead = 64 << 10,
      int pinTail = 128 << 10})
      : _maxBlocks = cacheBytes ~/ blockSize < 4 ? 4 : cacheBytes ~/ blockSize,
        _readahead = blockSize {
    if (length <= 0) return;
    final last = (length - 1) ~/ blockSize;
    for (var i = 0; i * blockSize < pinHead && i <= last; i++) {
      _pinnedIndices.add(i);
    }
    final tailStart = length - pinTail < 0 ? 0 : length - pinTail;
    for (var i = tailStart ~/ blockSize; i <= last; i++) {
      _pinnedIndices.add(i);
    }
  }

  int get _lastIndex => (length - 1) ~/ blockSize;

  Uint8List? _cached(int index) {
    final p = _pinned[index];
    if (p != null) return p;
    final b = _lru.remove(index);
    if (b != null) _lru[index] = b; // most recently used
    return b;
  }

  void _store(int index, Uint8List block) {
    if (_pinnedIndices.contains(index)) {
      _pinned[index] = block;
      return;
    }
    _lru.remove(index);
    while (_lru.length >= _maxBlocks) {
      _lru.remove(_lru.keys.first);
    }
    _lru[index] = block;
  }

  bool _has(int index) => _pinned.containsKey(index) || _lru.containsKey(index);

  /// Fetches the blocks [first] to [last] (missing ones only, in runs).
  void _fetchBlocks(int first, int last) {
    var i = first;
    while (i <= last) {
      if (_has(i)) {
        i++;
        continue;
      }
      var j = i;
      while (j + 1 <= last && !_has(j + 1)) {
        j++;
      }
      _fetchRun(i, j);
      i = j + 1;
    }
  }

  void _fetchRun(int first, int last) {
    final start = first * blockSize;
    var end = (last + 1) * blockSize - 1;
    if (end > length - 1) end = length - 1;
    final r = transport.fetch(start, end);
    requests++;
    final enc = r.contentEncoding;
    if (enc != null && enc.isNotEmpty && enc.toLowerCase() != 'identity') {
      throw SevenZipException(
          'the server compresses the file ($enc): byte ranges can not be '
          'read',
          SevenZipError.io);
    }
    if (r.status != 206) {
      throw SevenZipException(
          'the server stopped serving byte ranges (HTTP ${r.status})',
          SevenZipError.io);
    }
    final want = end - start + 1;
    if (r.bytes.length != want) {
      throw SevenZipException(
          'the server sent ${r.bytes.length} bytes instead of $want',
          SevenZipError.io);
    }
    final total = contentRangeTotal(r.contentRange);
    if (total != null && total != length) {
      throw const SevenZipException(
          'the file on the server changed', SevenZipError.io);
    }
    if (etag != null && r.etag != null && r.etag != etag) {
      throw const SevenZipException(
          'the file on the server changed', SevenZipError.io);
    }
    bytesFetched += r.bytes.length;
    for (var b = first; b <= last; b++) {
      final o = (b - first) * blockSize;
      var e = o + blockSize;
      if (e > r.bytes.length) e = r.bytes.length;
      _store(b, Uint8List.sublistView(r.bytes, o, e));
    }
  }

  /// Fetches the pinned head and tail blocks in (at most) two requests.
  void prefetch() {
    if (length <= 0) return;
    final idx = _pinnedIndices.toList()..sort();
    var i = 0;
    while (i < idx.length) {
      var j = i;
      while (j + 1 < idx.length && idx[j + 1] == idx[j] + 1) {
        j++;
      }
      _fetchBlocks(idx[i], idx[j]);
      i = j + 1;
    }
  }

  @override
  int read(Uint8List buf, int off, int len) {
    if (position >= length || len <= 0) return 0;
    if (len > length - position) len = length - position;
    final first = position ~/ blockSize;
    var last = (position + len - 1) ~/ blockSize;
    // sequential reads grow the readahead; a seek resets it
    if (position == _nextSequential) {
      _readahead =
          _readahead * 2 > maxReadahead ? maxReadahead : _readahead * 2;
    } else {
      _readahead = blockSize;
    }
    if (!_has(last)) {
      var ahead = last + _readahead ~/ blockSize - 1;
      if (ahead > _lastIndex) ahead = _lastIndex;
      if (ahead > last) last = ahead;
    }
    _fetchBlocks(first, last);
    var done = 0;
    var pos = position;
    while (done < len) {
      final index = pos ~/ blockSize;
      final block = _cached(index);
      if (block == null) break;
      final inBlock = pos - index * blockSize;
      if (inBlock >= block.length) break;
      var n = block.length - inBlock;
      if (n > len - done) n = len - done;
      buf.setRange(off + done, off + done + n, block, inBlock);
      done += n;
      pos += n;
    }
    position = pos;
    _nextSequential = pos;
    return done;
  }

  @override
  void close() {
    _lru.clear();
    _pinned.clear();
  }
}
