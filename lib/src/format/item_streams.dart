// Small helpers shared by the read-only firmware and image handlers (pak,
// uimage, fdt, cpio): a seekable window over a part of a stream, a seekable
// view of a sequential decoder, and the extract loop of handlers whose
// items are plain byte ranges or decoded streams.

import 'dart:convert';
import 'dart:typed_data';

import '../io/streams.dart';
import 'archive_types.dart';

/// Random access to [size] bytes of [base] starting at [start]
/// (IInArchiveGetStream::GetStream of an item stored as is). Each read
/// seeks the shared base stream first, so several windows can be read in
/// turn.
class SubInStream implements SeekableInStream {
  final SeekableInStream _base;
  final int _start;
  final int _size;
  int _pos = 0;
  SubInStream(this._base, this._start, this._size);

  @override
  int read(Uint8List buf, int off, int len) {
    final left = _size - _pos;
    if (left <= 0 || len <= 0) return 0;
    if (len > left) len = left;
    _base.position = _start + _pos;
    final n = _base.read(buf, off, len);
    _pos += n;
    return n;
  }

  @override
  int get position => _pos;
  @override
  set position(int v) => _pos = v;
  @override
  int get length => _size;
}

/// A seekable view of a sequential decoder: [open] creates a new decoder
/// at offset 0. A backward seek decodes again from the start, a forward
/// seek skips. [length] decodes the whole stream once when it is not known.
class ReopenSeekableInStream implements SeekableInStream {
  final InStream Function() _open;
  int? _length;
  InStream? _s;
  int _decPos = 0; // position of the decoder
  int _pos = 0; // position asked by the caller
  Uint8List? _skipBuf;

  ReopenSeekableInStream(this._open, [this._length]);

  Uint8List get _skip => _skipBuf ??= Uint8List(1 << 16);

  InStream _atPos() {
    var s = _s;
    if (s == null || _pos < _decPos) {
      s = _open();
      _s = s;
      _decPos = 0;
    }
    while (_decPos < _pos) {
      var want = _pos - _decPos;
      if (want > _skip.length) want = _skip.length;
      final n = s.read(_skip, 0, want);
      if (n == 0) break;
      _decPos += n;
    }
    return s;
  }

  @override
  int read(Uint8List buf, int off, int len) {
    if (len <= 0) return 0;
    final s = _atPos();
    if (_decPos < _pos) return 0;
    final n = s.read(buf, off, len);
    _decPos += n;
    _pos += n;
    return n;
  }

  @override
  int get position => _pos;
  @override
  set position(int v) => _pos = v;

  @override
  int get length {
    final l = _length;
    if (l != null) return l;
    final s = _open();
    final b = _skip;
    var total = 0;
    for (;;) {
      final n = s.read(b, 0, b.length);
      if (n == 0) break;
      total += n;
    }
    _length = total;
    return total;
  }
}

/// The OperationResult of a decoding error.
int operationResultOf(SevenZipException e) {
  switch (e.kind) {
    case SevenZipError.unsupportedMethod:
    case SevenZipError.unsupported:
      return OperationResult.unsupportedMethod;
    case SevenZipError.crc:
      return OperationResult.crcError;
    case SevenZipError.unexpectedEnd:
      return OperationResult.unexpectedEnd;
    case SevenZipError.dataAfterEnd:
      return OperationResult.dataAfterEnd;
    case SevenZipError.cancelled:
    case SevenZipError.io:
      throw e;
    default:
      return OperationResult.dataError;
  }
}

/// IInArchive::Extract for handlers whose items are folders or byte
/// streams: [isDir] tells the folders, [sizeOf] the unpacked size used for
/// the progress (null when unknown), [open] gives the data of an item
/// (it may throw [SevenZipException] for a bad item, reported as the
/// item's operation result). [expectedSize] (optional) is the exact size
/// the data must have; a shorter stream is an unexpected end.
void extractSimpleItems(
    int numItems,
    List<int>? indices,
    bool testMode,
    ArchiveExtractCallback cb,
    bool Function(int index) isDir,
    int? Function(int index) sizeOf,
    InStream Function(int index) open,
    {int? Function(int index)? expectedSize,
    int Function(int index)? verify}) {
  final ix = indices ?? [for (var i = 0; i < numItems; i++) i];
  var total = 0;
  for (final i in ix) {
    total += sizeOf(i) ?? 0;
  }
  cb.setTotal(total);
  var completed = 0;
  final buf = Uint8List(1 << 16);
  for (final index in ix) {
    cb.setCompleted(completed);
    var askMode = testMode ? AskMode.test : AskMode.extract;
    final out = cb.getStream(index, askMode);
    final dir = isDir(index);
    if (!testMode && out == null && !dir) askMode = AskMode.skip;
    cb.prepareOperation(askMode);
    if (dir) {
      cb.setOperationResult(OperationResult.ok);
      continue;
    }
    var opRes = OperationResult.ok;
    var done = 0;
    try {
      final src = open(index);
      for (;;) {
        final n = src.read(buf, 0, buf.length);
        if (n == 0) break;
        out?.write(buf, 0, n);
        done += n;
        if ((done & 0xFFFFF) < n) cb.setCompleted(completed + done);
      }
      final exp = expectedSize?.call(index);
      if (exp != null && done < exp) opRes = OperationResult.unexpectedEnd;
      if (opRes == OperationResult.ok && verify != null) opRes = verify(index);
    } on SevenZipException catch (e) {
      opRes = operationResultOf(e);
    }
    out?.flush();
    completed += sizeOf(index) ?? done;
    cb.setOperationResult(opRes);
  }
  cb.setCompleted(completed);
}

/// Unix seconds as a FILETIME (100 ns ticks since 1601).
int unixSecondsToFileTime(int seconds) =>
    seconds * 10000000 + 116444736000000000;

/// Big endian helpers.
int getUint16BE(Uint8List b, int o) => (b[o] << 8) | b[o + 1];

int getUint32BE(Uint8List b, int o) =>
    (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

int getUint64BE(Uint8List b, int o) =>
    (getUint32BE(b, o) << 32) | getUint32BE(b, o + 4);

/// Reads [len] bytes at [pos] of [s]; fewer at the end of the stream.
Uint8List readAt(SeekableInStream s, int pos, int len) {
  final b = Uint8List(len);
  s.position = pos;
  final n = readFully(s, b, 0, len);
  return n == len ? b : Uint8List.sublistView(b, 0, n);
}

/// A NUL terminated (or padded) byte string of b[off, off+len) as text:
/// UTF-8 when valid, else Latin-1.
String cString(Uint8List b, int off, int len) {
  var end = off;
  final lim = off + len;
  while (end < lim && b[end] != 0) {
    end++;
  }
  return bytesToName(Uint8List.sublistView(b, off, end));
}

/// Name bytes as text: UTF-8 when valid, else Latin-1.
String bytesToName(Uint8List b) {
  var ascii = true;
  for (var i = 0; i < b.length; i++) {
    if (b[i] >= 0x80) {
      ascii = false;
      break;
    }
  }
  if (ascii) return String.fromCharCodes(b);
  try {
    return utf8.decode(b);
  } on FormatException {
    return String.fromCharCodes(b);
  }
}

/// The IInArchive side of a read-only handler (pak, uimage, fdt, cpio),
/// adapted for the command line by `ReadOnlyArc` (lib/src/cli/arc_simple.dart).
abstract class ReadOnlyHandler {
  /// IInArchive::Open: false when [stream] is not of this format. [name]
  /// is the archive file name when known (some handlers name an item
  /// after it).
  bool open(SeekableInStream stream, {String? name});

  void close();

  int get numberOfItems;

  Object? getProperty(int index, int propId);

  Object? getArchiveProperty(int propId);

  List<int> get itemPropIds;

  List<int> get archivePropIds;

  /// k_PropVar_TimePrec_* of the times, 0 when not given.
  int get timePrec => 0;

  void extract(List<int>? indices, bool testMode, ArchiveExtractCallback cb);

  /// Random access to the data of item [index], null for folders.
  SeekableInStream? getStream(int index) => null;
}
