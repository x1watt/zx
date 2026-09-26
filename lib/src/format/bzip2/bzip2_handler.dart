// The bzip2 (.bz2) archive handler: one item, the data of one or more
// concatenated bzip2 streams. It follows the shape of the xz handler
// (IInArchive, IArchiveOpenSeq, ISetProperties, IOutArchive), with the
// codec of lib/src/codec/bzip2 (a port of bzip2 1.0.8). It is written from
// the bzip2 format and the behavior of the bzip2 program; no 7-Zip handler
// code is used.
//
// The unpacked size and the packed size are known only after the data was
// decoded (extract or test), as with 7-Zip, which lists them empty.

import 'dart:typed_data';

import '../../codec/bzip2/bzip2_coder.dart';
import '../../codec/codec.dart';
import '../../common/method_props.dart';
import '../../io/streams.dart';
import '../archive_types.dart';
import '../handler_out.dart';
import '../split.dart' show StreamSetRestriction;

/// The bzip2 signature test: "BZh", the block size digit, then the magic
/// of a block (0x314159265359) or of the end of stream (0x177245385090).
/// Returns true when [p] (at least 10 bytes) starts a bzip2 stream.
bool isBzip2Signature(Uint8List p, [int off = 0, int? size]) {
  final n = size ?? p.length - off;
  if (n < 10) return false;
  if (p[off] != 0x42 || p[off + 1] != 0x5A || p[off + 2] != 0x68) {
    return false;
  }
  final d = p[off + 3];
  if (d < 0x31 || d > 0x39) return false;
  const block = [0x31, 0x41, 0x59, 0x26, 0x53, 0x59];
  const end = [0x17, 0x72, 0x45, 0x38, 0x50, 0x90];
  var isBlock = true, isEnd = true;
  for (var i = 0; i < 6; i++) {
    if (p[off + 4 + i] != block[i]) isBlock = false;
    if (p[off + 4 + i] != end[i]) isEnd = false;
  }
  return isBlock || isEnd;
}

/// The result of one decode, kept for the properties.
class _Stat {
  int inSize = 0;
  int outSize = 0;
  int numStreams = 0;
  int numBlocks = 0;
  bool finished = false;
  bool dataAfterEnd = false;
  int errorFlags = 0;
}

/// The bzip2 handler.
class Bzip2Handler {
  SeekableInStream? _stream;
  InStream? _seqStream;
  bool _isArc = false;
  bool _needSeekToStart = false;
  _Stat? _stat;

  // ---- ISetProperties ----
  int _level = -1;
  final OneMethodInfo _methodProps = OneMethodInfo();

  /// CCommonMethodProps: -mmt and -mmemuse.
  final CommonMethodProps props = CommonMethodProps();

  /// kProps
  static const List<int> itemPropIds = [Kpid.size, Kpid.packSize];

  /// kArcProps
  static const List<int> archivePropIds = [Kpid.numStreams, Kpid.numBlocks];

  /// IInArchive::GetArchiveProperty
  Object? getArchiveProperty(int propID) {
    final stat = _stat;
    switch (propID) {
      case Kpid.phySize:
        return stat?.inSize;
      case Kpid.unpackSize:
        return stat != null && stat.finished ? stat.outSize : null;
      case Kpid.numStreams:
        return stat != null && stat.finished ? stat.numStreams : null;
      case Kpid.numBlocks:
        return stat != null && stat.finished ? stat.numBlocks : null;
      case Kpid.errorFlags:
        var v = 0;
        if (!_isArc) v |= ErrorFlags.isNotArc;
        if (stat != null) v |= stat.errorFlags;
        return v != 0 ? v : null;
    }
    return null;
  }

  /// IInArchive::GetNumberOfItems
  int get numberOfItems => 1;

  /// IInArchive::GetProperty
  Object? getProperty(int index, int propID) {
    final stat = _stat;
    switch (propID) {
      case Kpid.size:
        return stat != null && stat.finished ? stat.outSize : null;
      case Kpid.packSize:
        return stat != null && stat.finished ? stat.inSize : null;
    }
    return null;
  }

  /// IInArchive::Open. Returns false when [inStream] does not start with a
  /// bzip2 stream (S_FALSE).
  bool open(SeekableInStream inStream) {
    close();
    inStream.position = 0;
    final sig = Uint8List(10);
    final n = readFully(inStream, sig, 0, 10);
    if (!isBzip2Signature(sig, 0, n)) return false;
    _stream = inStream;
    _seqStream = inStream;
    _isArc = true;
    _needSeekToStart = true;
    return true;
  }

  /// IArchiveOpenSeq::OpenSeq
  void openSeq(InStream stream) {
    close();
    _seqStream = stream;
    _isArc = true;
    _needSeekToStart = false;
  }

  /// The decoded data as a sequential stream (IInArchiveGetStream for
  /// item 0), for a tar inside the bzip2 file read without a temporary
  /// file. The archive stream is rewound when it was read before.
  InStream? getSeqStream() {
    final s = _seqStream;
    if (s == null) return null;
    if (_needSeekToStart) {
      final st = _stream;
      if (st == null) return null;
      st.position = 0;
    } else {
      _needSeekToStart = true;
    }
    return Bzip2DecoderStream(s);
  }

  /// IInArchive::Close
  void close() {
    _stream = null;
    _seqStream = null;
    _isArc = false;
    _needSeekToStart = false;
    _stat = null;
  }

  /// IInArchive::Extract. [indices] null means all items. Calls
  /// [extractCallback].setOperationResult with an [OperationResult].
  void extract(List<int>? indices, bool testMode,
      ArchiveExtractCallback extractCallback) {
    if (indices != null) {
      if (indices.isEmpty) return;
      if (indices.length != 1 || indices[0] != 0) {
        throw const SevenZipException(
            'bzip2: E_INVALIDARG', SevenZipError.unsupported);
      }
    }

    final s = _stream;
    if (s != null) extractCallback.setTotal(s.length);
    extractCallback.setCompleted(0);

    final askMode = testMode ? AskMode.test : AskMode.extract;
    final realOutStream = extractCallback.getStream(0, askMode);
    if (!testMode && realOutStream == null) return;
    extractCallback.prepareOperation(askMode);

    if (_needSeekToStart) {
      if (s == null) throw const SevenZipException('bzip2: E_FAIL');
      s.position = 0;
    } else {
      _needSeekToStart = true;
    }

    final stat = _Stat();
    final decoder = Bzip2DecoderStream(_seqStream!,
        progress: (inSize, outSize) => extractCallback.setCompleted(inSize));
    final out = realOutStream ?? NullOutStream();
    var opRes = OperationResult.ok;
    try {
      copyStream(decoder, out);
      stat.finished = true;
    } on SevenZipException catch (e) {
      switch (e.kind) {
        case SevenZipError.isNotArc:
          opRes = OperationResult.isNotArc;
          stat.errorFlags |= ErrorFlags.isNotArc;
        case SevenZipError.unexpectedEnd:
          opRes = OperationResult.unexpectedEnd;
          stat.errorFlags |= ErrorFlags.unexpectedEnd;
        case SevenZipError.crc:
          opRes = OperationResult.crcError;
          stat.errorFlags |= ErrorFlags.crcError;
        case SevenZipError.data:
          opRes = OperationResult.dataError;
          stat.errorFlags |= ErrorFlags.dataError;
        default:
          rethrow;
      }
    }
    out.flush();
    stat.inSize = decoder.inProcessed;
    stat.outSize = decoder.outProcessed;
    stat.numStreams = decoder.numStreams;
    stat.numBlocks = decoder.numBlocks;
    if (decoder.dataAfterEnd) {
      stat.dataAfterEnd = true;
      stat.errorFlags |= ErrorFlags.dataAfterEnd;
      if (opRes == OperationResult.ok) opRes = OperationResult.dataAfterEnd;
    }
    _stat = stat;
    extractCallback.setOperationResult(opRes);
  }

  /// IOutArchive::GetFileTimeType
  int getFileTimeType() => FileTimeType.notDefined;

  /// The coder properties the current -m settings give ("x" as the level
  /// property, then "d", "pass" and "mt").
  List<CoderProp> get coderProps {
    final r = <CoderProp>[];
    if (_level >= 0) {
      r.add(CoderProp(CoderPropId.level, PropVariant.ui4(_level)));
    }
    r.addAll(_methodProps.props.map((p) => p.copy()));
    if (_methodProps.findProp(CoderPropId.numThreads) < 0) {
      r.add(
          CoderProp(CoderPropId.numThreads, PropVariant.ui4(props.numThreads)));
    }
    return r;
  }

  /// The encoder UpdateItems uses with the current properties.
  Bzip2Compressor createEncoder() => Bzip2Compressor.fromCoderProps(coderProps);

  /// IOutArchive::UpdateItems: writes a new .bz2 file to [outStream] from
  /// item 0 of [updateCallback] (the new data, or the data of the open
  /// archive when the item is kept).
  void updateItems(
      OutStream outStream, int numItems, ArchiveUpdateCallback updateCallback) {
    if (numItems == 0) {
      // an empty stream
      createEncoder().encode(MemoryInStream(Uint8List(0)), outStream);
      return;
    }

    if (numItems != 1) {
      throw const SevenZipException(
          'bzip2: only one file can be compressed', SevenZipError.unsupported);
    }

    if (outStream is StreamSetRestriction) {
      (outStream as StreamSetRestriction).setRestriction(0, 0);
    }

    final info = updateCallback.getUpdateItemInfo(0);

    if (info.newProps) {
      final prop = updateCallback.getProperty(0, Kpid.isDir);
      if (prop != null && (prop is! bool || prop != false)) {
        throw const SevenZipException(
            'bzip2: directories are not supported', SevenZipError.unsupported);
      }
    }

    if (info.newData) {
      var dataSize = 0;
      {
        final prop = updateCallback.getProperty(0, Kpid.size);
        if (prop is! int) {
          throw const SevenZipException(
              'bzip2: E_INVALIDARG (size)', SevenZipError.unsupported);
        }
        dataSize = prop;
      }

      final encoder = createEncoder();

      final fileInStream = updateCallback.getStream(0);
      if (fileInStream == null) return; // S_FALSE
      if (fileInStream is StreamGetSize) {
        final size = (fileInStream as StreamGetSize).streamSize;
        if (size != null) dataSize = size;
      }
      updateCallback.setTotal(dataSize);
      encoder.encode(fileInStream, outStream,
          progress: (inSize, outSize) => updateCallback.setCompleted(inSize));

      updateCallback.setOperationResult(0); // NUpdate::NOperationResult::kOK
      return;
    }

    if (info.indexInArchive != 0) {
      throw const SevenZipException(
          'bzip2: E_INVALIDARG', SevenZipError.unsupported);
    }

    if (updateCallback is ArchiveUpdateCallbackFile) {
      (updateCallback as ArchiveUpdateCallbackFile).reportOperation(
          EventIndexType.inArcIndex, 0, UpdateNotifyOp.replicate);
    }

    final stream = _stream;
    if (stream == null) {
      throw const SevenZipException(
          'bzip2: E_NOTIMPL (no archive stream)', SevenZipError.unsupported);
    }
    updateCallback.setTotal(stream.length);
    stream.position = 0;
    copyStream(stream, outStream);
    outStream.flush();
  }

  // SetProperty
  void _setProperty(String nameSpec, PropVariant value) {
    final name = nameSpec.toLowerCase();
    if (name.isEmpty) invalidArg();
    if (name[0] == 'x') {
      _level = parsePropToUInt32(name.substring(1), value, 9);
      return;
    }
    if (props.setCommonProperty(name, value)) return;
    if (name.startsWith('d') || name.startsWith('pass')) {
      _methodProps.parseParamsFromPropVariant(name, value);
      return;
    }
    invalidArg('bzip2: unknown property $nameSpec');
  }

  /// ISetProperties::SetProperties: the -m switch pairs, for example
  /// ("x", "1"), ("d", "900k"), ("pass", "2"), ("mt", "4"). Throws
  /// [InvalidArgException] for invalid properties.
  void setProperties(List<MapEntry<String, PropVariant>> properties) {
    _level = -1;
    _methodProps.clear();
    props.initCommon();
    for (final p in properties) {
      _setProperty(p.key, p.value);
    }
    // the block size is checked here, as the encoder would
    createEncoder();
  }

  /// [setProperties] from string pairs as the command line gives them.
  void setPropertiesFromStrings(List<MapEntry<String, String>> properties) {
    setProperties([
      for (final p in properties) convertCliProperty(p.key, p.value),
    ]);
  }
}

// ---------------------------------------------------------------------------
// Convenience API

class _SingleExtractCallback extends ArchiveExtractCallback {
  final OutStream? out;
  final ProgressCallback? progress;
  int result = OperationResult.ok;
  _SingleExtractCallback(this.out, this.progress);

  @override
  OutStream? getStream(int index, int askMode) => out;

  @override
  void setCompleted(int completeValue) => progress?.call(completeValue, 0);

  @override
  void setOperationResult(int opRes) => result = opRes;
}

class _SingleUpdateCallback extends ArchiveUpdateCallback
    implements StreamGetSize {
  final InStream input;
  final int size;
  final ProgressCallback? progress;
  _SingleUpdateCallback(this.input, this.size, this.progress);

  @override
  UpdateItemInfo getUpdateItemInfo(int index) =>
      const UpdateItemInfo(true, true, -1);

  @override
  Object? getProperty(int index, int propId) {
    if (propId == Kpid.size) return size;
    if (propId == Kpid.isDir) return false;
    return null;
  }

  @override
  InStream? getStream(int index) => input;

  @override
  int? get streamSize => size;

  @override
  void setCompleted(int completeValue) => progress?.call(completeValue, 0);
}

/// A convenience view of a .bz2 file: open, extract, test and create.
class Bzip2Archive {
  final Bzip2Handler handler = Bzip2Handler();

  Bzip2Archive._();

  /// Opens [stream]. Returns null when it is not a bzip2 file.
  static Bzip2Archive? open(SeekableInStream stream) {
    final a = Bzip2Archive._();
    if (!a.handler.open(stream)) return null;
    return a;
  }

  /// Opens a sequential stream.
  static Bzip2Archive openSeq(InStream stream) =>
      Bzip2Archive._()..handler.openSeq(stream);

  /// Unpacked size, known after [extract] or [test].
  int? get size => handler.getProperty(0, Kpid.size) as int?;

  /// Packed size (the bytes of the bzip2 streams), known after [extract]
  /// or [test].
  int? get packSize => handler.getProperty(0, Kpid.packSize) as int?;

  int? get numStreams => handler.getArchiveProperty(Kpid.numStreams) as int?;
  int? get numBlocks => handler.getArchiveProperty(Kpid.numBlocks) as int?;

  /// kpidErrorFlags ([ErrorFlags] bits), 0 when there is no error.
  int get errorFlags =>
      (handler.getArchiveProperty(Kpid.errorFlags) as int?) ?? 0;

  /// Decodes to [out]; returns an [OperationResult] value.
  int extract(OutStream out, {ProgressCallback? progress}) {
    final cb = _SingleExtractCallback(out, progress);
    handler.extract(null, false, cb);
    return cb.result;
  }

  /// Decodes without output; returns an [OperationResult] value.
  int test({ProgressCallback? progress}) {
    final cb = _SingleExtractCallback(null, progress);
    handler.extract(null, true, cb);
    return cb.result;
  }

  /// Creates a .bz2 file from [input] ([size] bytes) with the -m
  /// properties of the handler, for example `[MapEntry('x', '1')]` or
  /// `[MapEntry('d', '500k')]`.
  static void create(InStream input, OutStream output, int size,
      {List<MapEntry<String, String>> properties = const [],
      ProgressCallback? progress}) {
    final h = Bzip2Handler();
    h.setPropertiesFromStrings(properties);
    h.updateItems(output, 1, _SingleUpdateCallback(input, size, progress));
  }
}
