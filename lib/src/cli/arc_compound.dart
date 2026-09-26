// Compound archives: a tar inside a compressor (x.tar.gz, x.tgz,
// x.tar.bz2, x.tbz2, x.tar.xz, x.txz, x.tar.lzma, x.tlz) handled as one
// archive by the command line tool.
//
// 7-Zip's CArchiveLink::Open (OpenArchive.cpp) opens the next level only
// when the handler gives kpidMainSubfile and a seekable stream of that
// item (IInArchiveGetStream returning an IInStream). The compressors give
// neither, so 7-Zip lists a .tar.gz as a gzip archive holding one .tar
// file. The port adds that level for them (open_archive.dart calls
// [openCompoundTar] after the loop of CArchiveLink::Open):
//
// - reading (l, t, x, e, h): the tar is read with TarHandler.openSeq from
//   the decoded data ([InArchive.getSeqStream]), no temporary file. The
//   items are extracted in one pass, as with -si.
// - updating (a, u, d, rn on an existing archive): the tar is decoded to a
//   temporary file (in the -w folder or next to the archive), opened with
//   TarHandler.open as the archive to update, and deleted when the archive
//   is closed.
// - writing: [CompoundOutArc] runs TarHandler.updateItemsSteps and feeds
//   the tar bytes as the single item of the compressor's UpdateItems, so no
//   temporary tar is written.
//
// This is behavior of the port, not of 7-Zip; `-tgzip`, `-tbzip2`, `-txz`
// and `-tlzma` keep 7-Zip's single level view.

import 'dart:io';
import 'dart:typed_data';

import '../common/method_props.dart';
import '../format/archive_types.dart';
import '../io/streams.dart';
import 'arc_handlers.dart';
import 'arc_tar.dart';
import 'common.dart';
import 'load_codecs.dart';

/// The formats that hold one compressed stream, and can hold a tar.
const Set<String> kCompoundOuterFormats = {'gzip', 'bzip2', 'xz', 'lzma'};

/// The extensions that name a compressed tar by themselves.
const Set<String> _kCompoundExts = {
  'tgz', 'tpz', 'taz', 'tbz', 'tbz2', 'tb2', 'txz', 'tlz', //
};

bool isCompoundOuterFormat(ArcInfoEx ai) =>
    kCompoundOuterFormats.contains(ai.name.toLowerCase());

String _extOf(String name) {
  final dot = name.lastIndexOf('.');
  return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
}

String _stripExt(String name) {
  final dot = name.lastIndexOf('.');
  return dot < 0 ? name : name.substring(0, dot);
}

/// True when [arcFileName] (a file name without folders) names a
/// compressed tar: x.tgz, x.tbz2, x.txz, x.tlz..., or x.tar.gz and the
/// other x.tar.* names.
bool isCompoundTarName(String arcFileName) {
  final ext = _extOf(arcFileName);
  if (ext.isEmpty) return false;
  if (_kCompoundExts.contains(ext)) return true;
  return _stripExt(arcFileName).toLowerCase().endsWith('.tar');
}

/// The name of the tar inside the compressed file [arcFileName]:
/// x.tar.gz and x.tgz give x.tar.
String compoundInnerName(String arcFileName) {
  final base = _stripExt(arcFileName);
  if (base.toLowerCase().endsWith('.tar')) return base;
  return '$base.tar';
}

/// True when item 0 of the compressor [outerPath] ([innerPath] as the
/// handler names it) is a tar by its name.
bool looksLikeCompoundTar(String outerPath, String innerPath) {
  if (innerPath.toLowerCase().endsWith('.tar')) return true;
  final name = outerPath.replaceAll('\\', '/');
  return isCompoundTarName(name.substring(name.lastIndexOf('/') + 1));
}

// ---------------------------------------------------------------------------
// Reading

/// Decoded data of the compressor with its first error kept: after an
/// error the stream ends (the tar reader then sees an unexpected end), and
/// [errorFlags] tells what happened.
class _CheckedInStream implements InStream {
  final InStream _s;
  int errorFlags = 0;
  int opRes = OperationResult.ok;
  bool _end = false;
  _CheckedInStream(this._s);

  @override
  int read(Uint8List buf, int off, int len) {
    if (_end) return 0;
    try {
      final n = _s.read(buf, off, len);
      if (n == 0) _end = true;
      return n;
    } on SevenZipException catch (e) {
      final (flag, res) = switch (e.kind) {
        SevenZipError.crc => (ErrorFlags.crcError, OperationResult.crcError),
        SevenZipError.unexpectedEnd => (
            ErrorFlags.unexpectedEnd,
            OperationResult.unexpectedEnd
          ),
        SevenZipError.unsupportedMethod => (
            ErrorFlags.unsupportedMethod,
            OperationResult.unsupportedMethod
          ),
        SevenZipError.isNotArc => (
            ErrorFlags.isNotArc,
            OperationResult.isNotArc
          ),
        SevenZipError.data => (ErrorFlags.dataError, OperationResult.dataError),
        _ => (0, 0),
      };
      if (flag == 0) rethrow;
      errorFlags |= flag;
      opRes = res;
      _end = true;
      return 0;
    }
  }

  /// Reads the rest (the zeros after the tar end marker, the trailer of the
  /// compressor) so that its checks run.
  void drain() {
    final b = Uint8List(1 << 16);
    while (read(b, 0, b.length) != 0) {}
  }
}

/// A tar read in one pass from the decoded data of a compressor.
class SeqTarArc extends InArchive {
  final TarArc tar = TarArc();
  final _CheckedInStream _src;

  SeqTarArc(InStream decoded) : _src = _CheckedInStream(decoded);

  /// IArchiveOpenSeq::OpenSeq of the tar handler over the decoded data.
  int openSeqTar() => tar.openSeq(_src);

  @override
  int open(SeekableInStream stream, int maxCheckStartPosition,
          ArchiveOpenCallback? callback) =>
      HRes.sFalse;

  @override
  void close() => tar.close();

  @override
  int get numberOfItems => tar.numberOfItems;

  @override
  Object? getProperty(int index, int propId) => tar.getProperty(index, propId);

  @override
  Object? getArchiveProperty(int propId) {
    final v = tar.getArchiveProperty(propId);
    if (propId == Kpid.errorFlags && _src.errorFlags != 0) {
      // an error of the compressor is an error of this archive
      var f = (v is int ? v : 0) | _src.errorFlags;
      if ((_src.errorFlags & ErrorFlags.unexpectedEnd) == 0) {
        f &= ~ErrorFlags.unexpectedEnd;
      }
      return f;
    }
    return v;
  }

  @override
  List<int> get itemPropIds => tar.itemPropIds;

  @override
  List<int> get archivePropIds => tar.archivePropIds;

  @override
  int get timePrec => tar.timePrec;

  @override
  void setProperties(List<MapEntry<String, PropVariant>> props) =>
      tar.setProperties(props);

  /// Extracts in archive order ([indices] are ignored: the censor of the
  /// extract callback selects, as with -si). The result of the last item
  /// is held until the rest of the compressed data is checked, so a CRC
  /// error in the trailer is reported for it.
  @override
  void extract(List<int>? indices, bool testMode, ArchiveExtractCallback cb) {
    final d = _DeferLastResult(cb);
    tar.extract(indices, testMode, d);
    _src.drain();
    d.finish(_src.opRes);
  }
}

/// Forwards an extract callback and holds back the last SetOperationResult.
class _DeferLastResult extends ArchiveExtractCallback {
  final ArchiveExtractCallback _cb;
  int? _pending;
  _DeferLastResult(this._cb);

  void _flush() {
    final p = _pending;
    if (p != null) {
      _pending = null;
      _cb.setOperationResult(p);
    }
  }

  /// Reports the held result, replaced by [srcOpRes] when the compressed
  /// data had an error.
  void finish(int srcOpRes) {
    final p = _pending;
    if (p != null &&
        srcOpRes != OperationResult.ok &&
        (p == OperationResult.ok || p == OperationResult.unexpectedEnd)) {
      _pending = srcOpRes;
    }
    _flush();
  }

  @override
  void setTotal(int total) => _cb.setTotal(total);
  @override
  void setCompleted(int completeValue) => _cb.setCompleted(completeValue);
  @override
  OutStream? getStream(int index, int askMode) {
    _flush();
    return _cb.getStream(index, askMode);
  }

  @override
  void prepareOperation(int askMode) => _cb.prepareOperation(askMode);
  @override
  void setOperationResult(int opRes) {
    _flush();
    _pending = opRes;
  }
}

/// Extract callback that writes item 0 to [out].
class _ToFileExtractCallback extends ArchiveExtractCallback {
  final OutStream out;
  int opRes = -1;
  _ToFileExtractCallback(this.out);
  @override
  OutStream? getStream(int index, int askMode) => index == 0 ? out : null;
  @override
  void setOperationResult(int opRes) => this.opRes = opRes;
}

int _tempCounter = 0;

/// Decodes item 0 of [outer] into a new temporary file in [dir] (with its
/// separator, or empty for the current folder). Returns its path, or null
/// when the data has errors (the file is deleted).
String? decodeCompoundToTempFile(InArchive outer, String dir) {
  File? file;
  var path = '';
  for (var i = 0; i < 1000; i++) {
    path = '${dir}zx${pid}_${_tempCounter++}.tar.tmp';
    final f = File(path);
    try {
      f.createSync(exclusive: true);
      file = f;
      break;
    } on FileSystemException {
      if (f.existsSync()) continue;
      rethrow;
    }
  }
  if (file == null) return null;
  final out = FileOutStream(file.openSync(mode: FileMode.write));
  final cb = _ToFileExtractCallback(out);
  var ok = false;
  try {
    outer.extract([0], false, cb);
    out.flush();
    ok = cb.opRes == OperationResult.ok;
  } finally {
    out.close();
    if (!ok) {
      try {
        file.deleteSync();
      } on FileSystemException {
        // ignore
      }
    }
  }
  return ok ? path : null;
}

// ---------------------------------------------------------------------------
// Writing

/// Output that keeps what is written until [read] takes it.
class _ChunkSink implements OutStream {
  final List<Uint8List> _chunks = [];
  int _head = 0; // read position in _chunks.first

  bool get isEmpty => _chunks.isEmpty;

  @override
  void write(Uint8List buf, int off, int len) {
    if (len <= 0) return;
    _chunks.add(Uint8List.fromList(Uint8List.sublistView(buf, off, off + len)));
  }

  @override
  void flush() {}

  int read(Uint8List buf, int off, int len) {
    var n = 0;
    while (n < len && _chunks.isNotEmpty) {
      final c = _chunks.first;
      var k = c.length - _head;
      if (k > len - n) k = len - n;
      buf.setRange(off + n, off + n + k, c, _head);
      n += k;
      _head += k;
      if (_head == c.length) {
        _chunks.removeAt(0);
        _head = 0;
      }
    }
    return n;
  }
}

/// The tar written by a step generator as a pull stream.
class _StepsInStream implements InStream {
  final Iterator<void> _steps;
  final _ChunkSink _sink;
  bool _done = false;
  _StepsInStream(this._steps, this._sink);

  @override
  int read(Uint8List buf, int off, int len) {
    while (_sink.isEmpty) {
      if (_done) return 0;
      if (!_steps.moveNext()) _done = true;
    }
    return _sink.read(buf, off, len);
  }

  /// Runs the steps the reader did not ask for (none when it read to the
  /// end).
  void finish() {
    while (!_done) {
      if (!_steps.moveNext()) _done = true;
    }
  }
}

/// The update callback of the compressor: one new item, the tar.
class _TarItemCallback extends ArchiveUpdateCallback {
  final InStream stream;
  final String name;
  final int sizeEstimate;
  final int mTime;
  _TarItemCallback(this.stream, this.name, this.sizeEstimate, this.mTime);

  @override
  UpdateItemInfo getUpdateItemInfo(int index) =>
      const UpdateItemInfo(true, true, -1);

  @override
  Object? getProperty(int index, int propId) {
    switch (propId) {
      case Kpid.path:
        return name;
      case Kpid.isDir:
        return false;
      case Kpid.size:
        // an upper bound: the compressors use it only to size their
        // buffers and dictionary (reduceSize)
        return sizeEstimate;
      case Kpid.mTime:
        return mTime;
    }
    return null;
  }

  @override
  InStream? getStream(int index) => stream;
}

/// The tar options of -m in a compound archive: m=gnu|pax|posix and the
/// time switches (tm, tc, ta, tp) and cp; everything else goes to the
/// compressor (x, mt, d, fb, pass, mm=deflate...).
bool isTarPropertyName(String name, PropVariant value) {
  final n = name.toLowerCase();
  if (n == 'tm' || n == 'tc' || n == 'ta' || n == 'tp' || n == 'cp') {
    return true;
  }
  if (n == 'm' && value.vt == VarType.bstr) {
    final v = value.stringValue.toLowerCase();
    return v == 'gnu' || v == 'pax' || v == 'posix';
  }
  return false;
}

/// IOutArchive for a compound archive: [tar] writes the items, [outer]
/// compresses the tar as its only item named [innerName].
class CompoundOutArc extends InArchive {
  final InArchive outer;
  final TarArc tar;
  final String innerName;

  CompoundOutArc(this.outer, this.tar, this.innerName);

  @override
  int open(SeekableInStream stream, int maxCheckStartPosition,
          ArchiveOpenCallback? callback) =>
      HRes.sFalse;

  @override
  void close() {}

  @override
  int get numberOfItems => tar.numberOfItems;

  @override
  Object? getProperty(int index, int propId) => tar.getProperty(index, propId);

  @override
  Object? getArchiveProperty(int propId) => tar.getArchiveProperty(propId);

  @override
  List<int> get itemPropIds => tar.itemPropIds;

  @override
  List<int> get archivePropIds => tar.archivePropIds;

  @override
  void extract(List<int>? indices, bool testMode, ArchiveExtractCallback cb) =>
      tar.extract(indices, testMode, cb);

  @override
  bool get supportsUpdate => true;

  @override
  int getFileTimeType() => tar.getFileTimeType();

  @override
  void setProperties(List<MapEntry<String, PropVariant>> props) {
    final t = <MapEntry<String, PropVariant>>[];
    final o = <MapEntry<String, PropVariant>>[];
    for (final p in props) {
      (isTarPropertyName(p.key, p.value) ? t : o).add(p);
    }
    tar.setProperties(t);
    outer.setProperties(o);
  }

  @override
  void updateItems(
      OutStream out, int numItems, ArchiveUpdateCallback callback) {
    var estimate = 10240;
    for (var i = 0; i < numItems; i++) {
      final info = callback.getUpdateItemInfo(i);
      estimate += 1536;
      if (info.newData) {
        final s = callback.getProperty(i, Kpid.size);
        if (s is int) estimate += s;
      } else if (info.indexInArchive >= 0) {
        final s = tar.getProperty(info.indexInArchive, Kpid.packSize);
        if (s is int) estimate += s;
      }
    }
    final sink = _ChunkSink();
    final steps = tar.h.updateItemsSteps(sink, numItems, callback).iterator;
    final stream = _StepsInStream(steps, sink);
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    final mTime = now * 10000 + 116444736000000000;
    outer.updateItems(
        out, 1, _TarItemCallback(stream, innerName, estimate, mTime));
    stream.finish();
  }
}
