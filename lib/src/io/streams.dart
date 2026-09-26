// Synchronous byte streams, the Dart counterpart of 7-Zip's ISequentialInStream,
// ISequentialOutStream, IInStream and IOutStream.
//
// Every codec and archive handler in this package works on these interfaces.
// They are synchronous on purpose: the heavy work runs in a background isolate
// (see lib/src/api.dart), where blocking file IO is fine and much faster than
// awaiting a future per chunk.

import 'dart:io';
import 'dart:typed_data';

/// Thrown for corrupt input, unsupported methods, wrong passwords and IO
/// failures inside the port. [kind] mirrors 7-Zip's operation result codes.
class SevenZipException implements Exception {
  final String message;
  final SevenZipError kind;
  const SevenZipException(this.message, [this.kind = SevenZipError.data]);
  @override
  String toString() => 'SevenZipException(${kind.name}): $message';
}

/// Error classes, matching NArchive::NExtract::NOperationResult.
enum SevenZipError {
  unsupportedMethod,
  data,
  crc,
  unavailable,
  unexpectedEnd,
  dataAfterEnd,
  isNotArc,
  headers,
  wrongPassword,
  io,
  cancelled,
  unsupported,
}

/// Pull stream. [read] returns the number of bytes stored at [off], 0 only at
/// the end of the stream. It may return fewer than [len] bytes before the end.
abstract class InStream {
  int read(Uint8List buf, int off, int len);
}

/// Push stream.
abstract class OutStream {
  void write(Uint8List buf, int off, int len);

  /// Flushes buffered data to the underlying sink. Encoders call this once
  /// when they finish.
  void flush() {}
}

/// A random access input, like 7-Zip's IInStream.
abstract class SeekableInStream implements InStream {
  int get position;
  set position(int value);
  int get length;
}

/// A random access output, like 7-Zip's IOutStream.
abstract class SeekableOutStream implements OutStream {
  int get position;
  set position(int value);
  int get length;
  void truncate(int length);
}

/// Reads until [len] bytes are stored or the stream ends. Returns the count.
int readFully(InStream s, Uint8List buf, int off, int len) {
  var done = 0;
  while (done < len) {
    final n = s.read(buf, off + done, len - done);
    if (n == 0) break;
    done += n;
  }
  return done;
}

/// Reads exactly [len] bytes or throws [SevenZipException] (unexpectedEnd).
void readExactly(InStream s, Uint8List buf, int off, int len) {
  if (readFully(s, buf, off, len) != len) {
    throw const SevenZipException(
        'Unexpected end of data', SevenZipError.unexpectedEnd);
  }
}

/// Copies [s] to [out] until the end (or [limit] bytes). Returns the count.
int copyStream(InStream s, OutStream out, {int? limit, int bufSize = 1 << 16}) {
  final buf = Uint8List(bufSize);
  var total = 0;
  while (limit == null || total < limit) {
    var want = bufSize;
    if (limit != null && limit - total < want) want = limit - total;
    final n = s.read(buf, 0, want);
    if (n == 0) break;
    out.write(buf, 0, n);
    total += n;
  }
  return total;
}

/// Drains the whole stream into memory.
Uint8List readAll(InStream s) {
  final out = MemoryOutStream();
  copyStream(s, out);
  return out.toBytes();
}

/// Input from a byte list.
class MemoryInStream implements SeekableInStream {
  final Uint8List data;
  int _pos = 0;
  MemoryInStream(this.data);

  @override
  int read(Uint8List buf, int off, int len) {
    final n = len < data.length - _pos ? len : data.length - _pos;
    if (n <= 0) return 0;
    buf.setRange(off, off + n, data, _pos);
    _pos += n;
    return n;
  }

  @override
  int get position => _pos;
  @override
  set position(int v) => _pos = v;
  @override
  int get length => data.length;
}

/// Growable in-memory output.
class MemoryOutStream implements SeekableOutStream {
  Uint8List _buf;
  int _len = 0;
  int _pos = 0;
  MemoryOutStream([int capacity = 1 << 12]) : _buf = Uint8List(capacity);

  void _ensure(int cap) {
    if (cap <= _buf.length) return;
    var n = _buf.length * 2;
    if (n < cap) n = cap;
    final nb = Uint8List(n);
    nb.setRange(0, _len, _buf);
    _buf = nb;
  }

  @override
  void write(Uint8List buf, int off, int len) {
    _ensure(_pos + len);
    _buf.setRange(_pos, _pos + len, buf, off);
    _pos += len;
    if (_pos > _len) _len = _pos;
  }

  void writeByte(int b) {
    _ensure(_pos + 1);
    _buf[_pos++] = b;
    if (_pos > _len) _len = _pos;
  }

  @override
  void flush() {}
  @override
  int get position => _pos;
  @override
  set position(int v) {
    _ensure(v);
    _pos = v;
    if (_pos > _len) _len = _pos;
  }

  @override
  int get length => _len;
  @override
  void truncate(int length) {
    _ensure(length);
    _len = length;
    if (_pos > _len) _pos = _len;
  }

  /// A view of the bytes written so far (no copy).
  Uint8List toBytes() => Uint8List.sublistView(_buf, 0, _len);
}

/// Discards everything, counting the bytes.
class NullOutStream implements OutStream {
  int count = 0;
  @override
  void write(Uint8List buf, int off, int len) => count += len;
  @override
  void flush() {}
}

/// Counts bytes passing through to [base].
class CountingOutStream implements OutStream {
  final OutStream base;
  int count = 0;
  CountingOutStream(this.base);
  @override
  void write(Uint8List buf, int off, int len) {
    base.write(buf, off, len);
    count += len;
  }

  @override
  void flush() => base.flush();
}

/// Counts bytes read from [base].
class CountingInStream implements InStream {
  final InStream base;
  int count = 0;
  CountingInStream(this.base);
  @override
  int read(Uint8List buf, int off, int len) {
    final n = base.read(buf, off, len);
    count += n;
    return n;
  }
}

/// At most [limit] bytes of [base].
class LimitedInStream implements InStream {
  final InStream base;
  int _left;
  LimitedInStream(this.base, int limit) : _left = limit;
  int get remaining => _left;
  @override
  int read(Uint8List buf, int off, int len) {
    if (_left <= 0) return 0;
    final n = base.read(buf, off, len < _left ? len : _left);
    _left -= n;
    return n;
  }
}

/// An independent window [start, start+size) over a shared seekable stream.
/// Each read seeks first, so several windows over one file can be read in an
/// interleaved way (needed by BCJ2, whose four packed streams are read
/// together).
class WindowInStream implements InStream {
  final SeekableInStream base;
  int _pos;
  final int _end;
  WindowInStream(this.base, int start, int size)
      : _pos = start,
        _end = start + size;
  @override
  int read(Uint8List buf, int off, int len) {
    final left = _end - _pos;
    if (left <= 0) return 0;
    if (len > left) len = left;
    base.position = _pos;
    final n = base.read(buf, off, len);
    _pos += n;
    return n;
  }
}

/// Concatenation of streams.
class ConcatInStream implements InStream {
  final List<InStream> parts;
  int _i = 0;
  ConcatInStream(this.parts);
  @override
  int read(Uint8List buf, int off, int len) {
    while (_i < parts.length) {
      final n = parts[_i].read(buf, off, len);
      if (n > 0) return n;
      _i++;
    }
    return 0;
  }
}

/// Buffered random access file input.
class FileInStream implements SeekableInStream {
  final RandomAccessFile raf;
  final int _length;
  int _pos = 0;
  // Read cache.
  final Uint8List _cache;
  int _cStart = 0;
  int _cLen = 0;

  FileInStream(this.raf, {int cacheSize = 1 << 16})
      : _length = raf.lengthSync(),
        _cache = Uint8List(cacheSize);

  factory FileInStream.open(String path) =>
      FileInStream(File(path).openSync());

  @override
  int read(Uint8List buf, int off, int len) {
    if (_pos >= _length || len <= 0) return 0;
    if (_pos >= _cStart && _pos < _cStart + _cLen) {
      final avail = _cStart + _cLen - _pos;
      final n = len < avail ? len : avail;
      buf.setRange(off, off + n, _cache, _pos - _cStart);
      _pos += n;
      return n;
    }
    if (len >= _cache.length) {
      raf.setPositionSync(_pos);
      final n = raf.readIntoSync(buf, off, off + len);
      _pos += n;
      return n;
    }
    raf.setPositionSync(_pos);
    _cStart = _pos;
    _cLen = raf.readIntoSync(_cache, 0, _cache.length);
    if (_cLen == 0) return 0;
    return read(buf, off, len);
  }

  @override
  int get position => _pos;
  @override
  set position(int v) => _pos = v;
  @override
  int get length => _length;

  void close() => raf.closeSync();
}

/// Buffered random access file output.
class FileOutStream implements SeekableOutStream {
  final RandomAccessFile raf;
  final Uint8List _buf;
  int _bufLen = 0;
  int _pos = 0; // position of _buf[0] in the file
  int _length;

  FileOutStream(this.raf, {int bufSize = 1 << 16})
      : _buf = Uint8List(bufSize),
        _length = raf.lengthSync();

  factory FileOutStream.create(String path) =>
      FileOutStream(File(path).openSync(mode: FileMode.write));

  void _drain() {
    if (_bufLen == 0) return;
    raf.setPositionSync(_pos);
    raf.writeFromSync(_buf, 0, _bufLen);
    _pos += _bufLen;
    if (_pos > _length) _length = _pos;
    _bufLen = 0;
  }

  @override
  void write(Uint8List buf, int off, int len) {
    if (len >= _buf.length) {
      _drain();
      raf.setPositionSync(_pos);
      raf.writeFromSync(buf, off, off + len);
      _pos += len;
      if (_pos > _length) _length = _pos;
      return;
    }
    if (_bufLen + len > _buf.length) _drain();
    _buf.setRange(_bufLen, _bufLen + len, buf, off);
    _bufLen += len;
  }

  @override
  void flush() {
    _drain();
    raf.flushSync();
  }

  @override
  int get position => _pos + _bufLen;
  @override
  set position(int v) {
    _drain();
    _pos = v;
  }

  @override
  int get length {
    final end = _pos + _bufLen;
    return end > _length ? end : _length;
  }

  @override
  void truncate(int length) {
    _drain();
    raf.truncateSync(length);
    _length = length;
    if (_pos > length) _pos = length;
  }

  void close() {
    _drain();
    raf.closeSync();
  }
}

/// Little endian helpers for headers.
int getUint32LE(Uint8List b, int o) =>
    b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);

int getUint64LE(Uint8List b, int o) =>
    getUint32LE(b, o) | (getUint32LE(b, o + 4) << 32);

void setUint32LE(Uint8List b, int o, int v) {
  b[o] = v & 0xFF;
  b[o + 1] = (v >> 8) & 0xFF;
  b[o + 2] = (v >> 16) & 0xFF;
  b[o + 3] = (v >> 24) & 0xFF;
}

void setUint64LE(Uint8List b, int o, int v) {
  setUint32LE(b, o, v & 0xFFFFFFFF);
  setUint32LE(b, o + 4, (v >> 32) & 0xFFFFFFFF);
}
