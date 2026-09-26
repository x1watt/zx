// The xz archive handler: port of CPP/7zip/Archive/XzHandler.cpp of the
// LZMA SDK 26.01 (IInArchive, IArchiveOpenSeq, IInArchiveGetStream,
// ISetProperties, IOutArchive). The HandlerOut.cpp parts it uses
// (CMultiMethodProps, ParseSizeString) are in ../handler_out.dart.
//
// [XzHandler] keeps the 7-Zip handler shape (properties by PROPID, extract
// and update callbacks). [XzArchive] is a small convenience layer on top.

import 'dart:typed_data';

import '../../codec/codec.dart';
import '../../common/method_props.dart';
import '../../io/streams.dart';
import '../archive_types.dart';
import '../handler_out.dart';
import '../split.dart' show StreamSetRestriction;
import 'xz.dart';
import 'xz_dec.dart';
import 'xz_enc.dart';

const String _kLzma2Name = 'LZMA2';

/// CBlockInfo
class _BlockInfo {
  int streamFlags = 0;
  int packPos = 0;
  int packSize =
      0; // pure value from Index record, it doesn't include pad zeros
  int unpackPos = 0;
}

// Lzma2PropToString
String _lzma2PropToString(int prop) {
  var c = '';
  int size;
  if ((prop & 1) == 0) {
    size = prop ~/ 2 + 12;
  } else {
    c = 'k';
    size = (2 | (prop & 1)) << (prop ~/ 2 + 1);
    if (prop > 17) {
      size >>= 10;
      c = 'm';
    }
  }
  return '$size$c';
}

// g_NamePairs (XzHandler.cpp)
const List<(int, String)> _namePairs = [
  (xzIdSubblock, 'SB'),
  (xzIdDelta, 'Delta'),
  (xzIdX86, 'BCJ'),
  (xzIdPpc, 'PPC'),
  (xzIdIa64, 'IA64'),
  (xzIdArm, 'ARM'),
  (xzIdArmt, 'ARMT'),
  (xzIdSparc, 'SPARC'),
  (xzIdArm64, 'ARM64'),
  (xzIdRiscv, 'RISCV'),
  (xzIdLzma2, 'LZMA2'),
];

const String _hexUpper = '0123456789ABCDEF';

// AddMethodString
void _addMethodString(StringBuffer s, XzFilter f) {
  String? p;
  for (final pair in _namePairs) {
    if (pair.$1 == f.id) {
      p = pair.$2;
      break;
    }
  }
  s.write(p ?? '${f.id}');

  if (f.propsSize > 0) {
    s.write(':');
    if (f.id == xzIdLzma2 && f.propsSize == 1) {
      s.write(_lzma2PropToString(f.props[0]));
    } else if (f.id == xzIdDelta && f.propsSize == 1) {
      s.write(f.props[0] + 1);
    } else if (f.id == xzIdArm64 && f.propsSize == 1) {
      s.write(f.props[0] + 16 + 2);
    } else {
      s.write('[');
      for (var bi = 0; bi < f.propsSize; bi++) {
        final v = f.props[bi];
        s.write(_hexUpper[v >> 4]);
        s.write(_hexUpper[v & 15]);
      }
      s.write(']');
    }
  }
}

// kChecks
const List<String?> _kChecks = [
  'NoCheck', 'CRC32', null, null, 'CRC64', null, null, null, //
  null, null, 'SHA256', null, null, null, null, null,
];

// AddCheckString
void _addCheckString(StringBuffer s, Xzs xzs) {
  var mask = 0;
  for (final st in xzs.streams) {
    mask |= 1 << xzFlagsGetCheckType(st.flags);
  }
  for (var i = 0; i <= xzCheckMask; i++) {
    if (((mask >> i) & 1) != 0) {
      if (s.isNotEmpty) s.write(' ');
      final name = _kChecks[i];
      s.write(name ?? 'Check-$i');
    }
  }
}

// SRes_to_Open_HRESULT: true for S_OK, false for S_FALSE.
bool _sresToOpenOk(int res) {
  switch (res) {
    case szOk:
      return true;
    case szErrorMem:
      throw const SevenZipException('Out of memory', SevenZipError.io);
    case szErrorProgress:
      throw const SevenZipException('Cancelled', SevenZipError.cancelled);
  }
  return false;
}

// Get_Extract_OperationResult
int _getExtractOperationResult(XzDecoder decoder) {
  final sres = decoder.mainDecodeSRes;
  if (sres == szErrorNoArchive) return OperationResult.isNotArc;
  if (sres == szErrorInputEof) return OperationResult.unexpectedEnd;
  if (decoder.stat.dataAfterEnd) return OperationResult.dataAfterEnd;
  if (sres == szErrorCrc) return OperationResult.crcError;
  if (sres == szErrorUnsupported) return OperationResult.unsupportedMethod;
  if (sres == szErrorArchive) return OperationResult.dataError;
  if (sres == szErrorData) return OperationResult.dataError;
  if (sres != szOk) return OperationResult.dataError;
  return OperationResult.ok;
}

// ---------------------------------------------------------------------------
// CHandler

/// NArchive::NXz::CHandler
class XzHandler {
  bool _statDefined = false;
  bool _stat2Defined = false;
  bool _isArc = false;
  bool _needSeekToStart = false;
  bool _firstBlockWasRead = false;
  int _stat2DecodeSRes = szOk;

  final XzStatInfo _stat = XzStatInfo(); // it's stat from backward parsing
  final XzStatInfo _stat2 = XzStatInfo(); // data from forward parsing

  XzStatInfo? _getStat() {
    if (_statDefined) return _stat;
    if (_stat2Defined) return _stat2;
    return null;
  }

  String _methodsString = '';

  // ---- IOutArchive side ----
  int _filterId = 0;
  int _numSolidBytes = xzPropsBlockSizeAuto;

  /// CMultiMethodProps
  final MultiMethodProps props = MultiMethodProps();

  List<_BlockInfo>? _blocks;
  int _maxBlocksSize = 0;
  SeekableInStream? _stream;
  InStream? _seqStream;

  final XzBlock _firstBlock = XzBlock();

  XzHandler() {
    _initXz();
  }

  // InitXz
  void _initXz() {
    _filterId = 0;
    _numSolidBytes = xzPropsBlockSizeAuto;
  }

  // Init
  void _init() {
    _initXz();
    props.init();
  }

  // CHandler::Decode
  XzDecodeResult _decode(XzDecoder decoder, InStream seqInStream,
      OutStream outStream, ProgressCallback? progress) {
    decoder.numThreads = props.numThreads;
    decoder.memUsage = props.memUsageDecompress;

    final hres = decoder.decode(seqInStream, outStream,
        outSizeLimit: null, finishStream: true, progress: progress);

    if (decoder.mainDecodeSResWasUsed &&
        decoder.mainDecodeSRes != szErrorMem &&
        decoder.mainDecodeSRes != szErrorUnsupported) {
      _stat2DecodeSRes = decoder.mainDecodeSRes;
      _stat2.copyFrom(decoder.stat);
      _stat2Defined = true;
    }
    return hres;
  }

  /// kProps
  static const List<int> itemPropIds = [Kpid.size, Kpid.packSize, Kpid.method];

  /// kArcProps
  static const List<int> archivePropIds = [
    Kpid.method,
    Kpid.numStreams,
    Kpid.numBlocks,
    Kpid.clusterSize,
    Kpid.characts,
  ];

  /// IInArchive::GetArchiveProperty
  Object? getArchiveProperty(int propID) {
    final stat = _getStat();
    switch (propID) {
      case Kpid.phySize:
        return stat?.inSize;
      case Kpid.numStreams:
        return (stat != null && stat.numStreamsDefined)
            ? stat.numStreams
            : null;
      case Kpid.numBlocks:
        return (stat != null && stat.numBlocksDefined) ? stat.numBlocks : null;
      case Kpid.unpackSize:
        return (stat != null && stat.unpackSizeDefined) ? stat.outSize : null;
      case Kpid.clusterSize:
        if (_statDefined && _stat.numBlocksDefined && stat!.numBlocks > 1) {
          return _maxBlocksSize;
        }
        return null;
      case Kpid.characts:
        if (_firstBlockWasRead) {
          final s = <String>[];
          if (_firstBlock.hasPackSize) s.add('BlockPackSize');
          if (_firstBlock.hasUnpackSize) s.add('BlockUnpackSize');
          if (s.isNotEmpty) return s.join(' ');
        }
        return null;
      case Kpid.method:
        return _methodsString.isNotEmpty ? _methodsString : null;
      case Kpid.errorFlags:
        var v = 0;
        final sres = _stat2DecodeSRes;
        if (!_isArc) v |= ErrorFlags.isNotArc;
        if (sres == szErrorInputEof) v |= ErrorFlags.unexpectedEnd;
        if (_stat2Defined && _stat2.dataAfterEnd) v |= ErrorFlags.dataAfterEnd;
        if (sres == szErrorArchive) v |= ErrorFlags.headersError;
        if (sres == szErrorUnsupported) v |= ErrorFlags.unsupportedMethod;
        if (sres == szErrorData) v |= ErrorFlags.dataError;
        if (sres == szErrorCrc) v |= ErrorFlags.crcError;
        return v != 0 ? v : null;
    }
    return null;
  }

  /// IInArchive::GetNumberOfItems
  int get numberOfItems => 1;

  /// IInArchive::GetProperty
  Object? getProperty(int index, int propID) {
    final stat = _getStat();
    switch (propID) {
      case Kpid.size:
        return (stat != null && stat.unpackSizeDefined) ? stat.outSize : null;
      case Kpid.packSize:
        return stat?.inSize;
      case Kpid.method:
        return _methodsString.isNotEmpty ? _methodsString : null;
    }
    return null;
  }

  // CHandler::Open2. Returns false for S_FALSE (not an xz archive).
  bool _open2(SeekableInStream inStream, ArchiveProgress? callback) {
    _needSeekToStart = true;

    {
      final (res, _) = xzReadHeader(inStream);
      if (res != szOk) return _sresToOpenOk(res);

      {
        final block = XzBlock();
        final info = XzBlockHeaderInfo();

        final res2 = xzBlockReadHeader(block, inStream, info);

        if (res2 != szOk) {
          if (res2 == szErrorInputEof) {
            _stat2DecodeSRes = res2;
            _stream = inStream;
            _seqStream = inStream;
            _isArc = true;
            return true;
          }
          if (res2 == szErrorArchive) return false;
        } else if (!info.isIndex) {
          _firstBlockWasRead = true;
          _firstBlock.copyFrom(block);

          final s = StringBuffer();
          final numFilters = block.numFilters;
          for (var i = 0; i < numFilters; i++) {
            if (s.isNotEmpty) s.write(' ');
            _addMethodString(s, block.filters[i]);
          }
          _methodsString = s.toString();
        }
      }
    }

    _stat.inSize = inStream.length;
    callback?.setTotal(_stat.inSize);

    final xzs = Xzs();
    final startPosition = [0];
    var res = xzs.readBackward(inStream, startPosition,
        progress: callback == null ? null : (v) => callback.setCompleted(v));
    if (res == szOk && startPosition[0] == 0) {
      _statDefined = true;

      _stat.outSize = xzs.getUnpackSize();
      _stat.unpackSizeDefined = true;

      _stat.numStreams = xzs.num;
      _stat.numStreamsDefined = true;

      _stat.numBlocks = xzs.getNumBlocks();
      _stat.numBlocksDefined = true;

      final s = StringBuffer(_methodsString);
      _addCheckString(s, xzs);
      _methodsString = s.toString();

      final blocks = <_BlockInfo>[];
      var unpackPos = 0;

      for (var si = xzs.num; si != 0;) {
        si--;
        final str = xzs.streams[si];
        var packPos = str.startOffset + xzStreamHeaderSize;

        for (final bs in str.blocks) {
          final packSizeAligned = bs.totalSize + ((-bs.totalSize) & 3);

          if (bs.unpackSize != 0) {
            if (blocks.length >= _stat.numBlocks) {
              throw const SevenZipException('xz: E_FAIL');
            }
            blocks.add(_BlockInfo()
              ..streamFlags = str.flags
              ..packSize = bs.totalSize
              ..packPos = packPos
              ..unpackPos = unpackPos);
          }
          packPos += packSizeAligned;
          unpackPos += bs.unpackSize;
          if (_maxBlocksSize < bs.unpackSize) _maxBlocksSize = bs.unpackSize;
        }
      }

      if (_stat.outSize != unpackPos) {
        throw const SevenZipException('xz: E_FAIL');
      }
      blocks.add(_BlockInfo()..unpackPos = unpackPos);
      _blocks = blocks;
    } else {
      res = szOk;
    }

    if (!_sresToOpenOk(res)) return false;

    _stream = inStream;
    _seqStream = inStream;
    _isArc = true;
    return true;
  }

  /// IInArchive::Open. Returns false when [inStream] is not an xz archive
  /// (S_FALSE). [callback] receives the total size and the progress of
  /// the backward index parsing.
  bool open(SeekableInStream inStream, {ArchiveProgress? callback}) {
    close();
    inStream.position = 0;
    return _open2(inStream, callback);
  }

  /// IArchiveOpenSeq::OpenSeq
  void openSeq(InStream stream) {
    close();
    _seqStream = stream;
    _isArc = true;
    _needSeekToStart = false;
  }

  /// IInArchive::Close
  void close() {
    _stat.clear();
    _stat2.clear();
    _statDefined = false;
    _stat2Defined = false;
    _stat2DecodeSRes = szOk;

    _isArc = false;
    _needSeekToStart = false;
    _firstBlockWasRead = false;

    _methodsString = '';
    _stream = null;
    _seqStream = null;

    _blocks = null;
    _maxBlocksSize = 0;
  }

  // SeekToPackPos
  void _seekToPackPos(int pos) => _stream!.position = pos;

  /// IInArchiveGetStream::GetStream: a random access stream over the
  /// unpacked data, decoded block by block. null (S_FALSE) when the index
  /// was not read or the blocks are too big.
  SeekableInStream? getStream(int index) {
    if (index != 0) {
      throw const SevenZipException(
          'xz: E_INVALIDARG', SevenZipError.unsupported);
    }

    if (!_stat.unpackSizeDefined ||
        _maxBlocksSize == 0 || // 18.02
        _maxBlocksSize > _kMaxBlockSizeForGetStream) {
      return null;
    }

    final memSize = getRamSize() ?? (8 << 28);
    if (_maxBlocksSize > memSize ~/ 4) return null;

    return _XzInStream(this, _maxBlocksSize, _stat.outSize);
  }

  static const int _kMaxBlockSizeForGetStream = 1 << 40;

  /// IInArchive::Extract. [indices] null means all items. Calls
  /// [extractCallback].setOperationResult with an [OperationResult].
  void extract(List<int>? indices, bool testMode,
      ArchiveExtractCallback extractCallback) {
    if (indices != null) {
      if (indices.isEmpty) return;
      if (indices.length != 1 || indices[0] != 0) {
        throw const SevenZipException(
            'xz: E_INVALIDARG', SevenZipError.unsupported);
      }
    }

    final stat = _getStat();

    if (stat != null) extractCallback.setTotal(stat.inSize);

    extractCallback.setCompleted(0);
    int opRes;
    {
      final askMode = testMode ? AskMode.test : AskMode.extract;

      final realOutStream = extractCallback.getStream(0, askMode);

      if (!testMode && realOutStream == null) return;

      extractCallback.prepareOperation(askMode);

      if (_needSeekToStart) {
        final s = _stream;
        if (s == null) throw const SevenZipException('xz: E_FAIL');
        s.position = 0;
      } else {
        _needSeekToStart = true;
      }

      final decoder = XzDecoder();

      final hres = _decode(
          decoder,
          _seqStream!,
          realOutStream ?? NullOutStream(),
          (inSize, outSize) => extractCallback.setCompleted(inSize));

      if (!decoder.mainDecodeSResWasUsed) {
        throw const SevenZipException('xz: E_FAIL');
      }

      opRes = _getExtractOperationResult(decoder);
      if (opRes == OperationResult.ok && hres != XzDecodeResult.ok) {
        opRes = OperationResult.dataError;
      }
    }
    extractCallback.setOperationResult(opRes);
  }

  /// IOutArchive::GetFileTimeType
  int getFileTimeType() => FileTimeType.notDefined;

  /// The encoder CHandler::UpdateItems sets up for [dataSize] bytes of new
  /// data with the current properties (the part of UpdateItems between
  /// the size and the stream). lib/src/parallel.dart uses it to get the
  /// same XzProps as [updateItems].
  XzEncoder createEncoder(int dataSize) {
    final encoder = XzEncoder();

    final xzProps = encoder.xzProps;
    final lzma2Props = xzProps.lzma2Props;

    lzma2Props.lzmaProps.level = props.getLevel();

    xzProps.reduceSize = dataSize;

    var numThreads = props.numThreads;

    const kNumThreadsMax = 1024;
    if (numThreads > kNumThreadsMax) numThreads = kNumThreadsMax;

    if (!props.numThreadsWasForced &&
        props.numThreads >= 1 &&
        props.memUsageWasSet) {
      final oneMethodInfo =
          props.methods.isNotEmpty ? props.methods[0].copy() : OneMethodInfo();

      props.setGlobalLevelTo(oneMethodInfo);

      final numThreadsWasSpecifiedInMethod = oneMethodInfo.getNumThreads() >= 0;
      if (!numThreadsWasSpecifiedInMethod) {
        // here we set the (NCoderPropID::kNumThreads) property in each
        // method, only if there is no such property already
        MultiMethodProps.setMethodThreadsToIfNotFinded(
            oneMethodInfo, numThreads);
      }

      var cs = _numSolidBytes;
      if (cs != xzPropsBlockSizeAuto) oneMethodInfo.addPropBlockSize2(cs);
      cs = oneMethodInfo.getXzBlockSize();

      if (cs != xzPropsBlockSizeAuto && cs != xzPropsBlockSizeSolid) {
        final lzmaThreads = oneMethodInfo.getLzmaNumThreads();
        final numBlockThreadsOriginal = numThreads ~/ lzmaThreads;

        if (numBlockThreadsOriginal > 1) {
          var numBlockThreads = numBlockThreadsOriginal;
          {
            final lzmaMemUsage = oneMethodInfo.getLzmaMemUsage(false);
            for (; numBlockThreads > 1; numBlockThreads--) {
              var size = numBlockThreads * (lzmaMemUsage + cs);
              var numPackChunks = numBlockThreads + (numBlockThreads ~/ 8) + 1;
              if (cs < (1 << 26)) numPackChunks++;
              if (cs < (1 << 24)) numPackChunks++;
              if (cs < (1 << 22)) numPackChunks++;
              size += numPackChunks * cs;
              if (size <= props.memUsageCompress) break;
            }
          }
          if (numBlockThreads == 0) numBlockThreads = 1;
          if (numBlockThreads != numBlockThreadsOriginal) {
            numThreads = numBlockThreads * lzmaThreads;
          }
        }
      }
    }
    xzProps.numTotalThreads = numThreads;

    xzProps.blockSize = _numSolidBytes;
    if (_numSolidBytes == xzPropsBlockSizeSolid) {
      xzProps.lzma2Props.blockSize = xzPropsBlockSizeSolid;
    }

    encoder.setCheckSize(props.crcSize);

    {
      final filter = xzProps.filterProps;

      if (_filterId == xzIdDelta) {
        var deltaDefined = false;
        for (final prop in props.filterMethod.props) {
          if (prop.id == CoderPropId.defaultProp &&
              prop.value.vt == VarType.ui4) {
            final delta = prop.value.intValue;
            if (delta < 1 || delta > 256) {
              throw const SevenZipException(
                  'xz: invalid Delta distance', SevenZipError.unsupported);
            }
            filter.delta = delta;
            deltaDefined = true;
          } else {
            throw const SevenZipException(
                'xz: invalid Delta property', SevenZipError.unsupported);
          }
        }
        if (!deltaDefined) {
          throw const SevenZipException(
              'xz: the Delta filter needs a distance (-mf=Delta:4)',
              SevenZipError.unsupported);
        }
      }
      filter.id = _filterId;
    }

    for (final m in props.methods) {
      for (final prop in m.props) {
        encoder.setCoderProp(prop);
      }
    }
    return encoder;
  }

  /// IOutArchive::UpdateItems: writes a new xz archive to [outStream] from
  /// item 0 of [updateCallback] (the new data, or the data of the open
  /// archive when the item is kept).
  void updateItems(
      OutStream outStream, int numItems, ArchiveUpdateCallback updateCallback) {
    if (numItems == 0) {
      xzEncodeEmpty(outStream);
      return;
    }

    if (numItems != 1) {
      throw const SevenZipException(
          'xz: only one file can be compressed', SevenZipError.unsupported);
    }

    if (outStream is StreamSetRestriction) {
      (outStream as StreamSetRestriction).setRestriction(0, 0);
    }

    final info = updateCallback.getUpdateItemInfo(0);

    if (info.newProps) {
      final prop = updateCallback.getProperty(0, Kpid.isDir);
      if (prop != null && (prop is! bool || prop != false)) {
        throw const SevenZipException(
            'xz: directories are not supported', SevenZipError.unsupported);
      }
    }

    if (info.newData) {
      var dataSize = 0;
      {
        final prop = updateCallback.getProperty(0, Kpid.size);
        if (prop is! int) {
          throw const SevenZipException(
              'xz: E_INVALIDARG (size)', SevenZipError.unsupported);
        }
        dataSize = prop;
      }

      final encoder = createEncoder(dataSize);

      {
        final fileInStream = updateCallback.getStream(0);
        if (fileInStream == null) return; // S_FALSE
        if (fileInStream is StreamGetSize) {
          final size = (fileInStream as StreamGetSize).streamSize;
          if (size != null) dataSize = size;
        }
        updateCallback.setTotal(dataSize);
        encoder.encode(fileInStream, outStream,
            progress: (inSize, outSize) => updateCallback.setCompleted(inSize));
      }

      updateCallback.setOperationResult(0); // NUpdate::NOperationResult::kOK
      return;
    }

    if (info.indexInArchive != 0) {
      throw const SevenZipException(
          'xz: E_INVALIDARG', SevenZipError.unsupported);
    }

    if (updateCallback is ArchiveUpdateCallbackFile) {
      (updateCallback as ArchiveUpdateCallbackFile).reportOperation(
          EventIndexType.inArcIndex, 0, UpdateNotifyOp.replicate);
    }

    final stream = _stream;
    if (stream != null) {
      final stat = _getStat();
      if (stat != null) updateCallback.setTotal(stat.inSize);
      stream.position = 0;
    }

    // NCompress::CopyStream
    copyStream(_stream!, outStream);
    outStream.flush();
  }

  // CHandler::SetProperty
  void _setProperty(String nameSpec, PropVariant value) {
    final name = nameSpec.toLowerCase();
    if (name.isEmpty) invalidArg();

    if (name[0] == 's') {
      final s = name.substring(1);
      if (s.isEmpty) {
        var useStr = false;
        var isSolid = true;
        switch (value.vt) {
          case VarType.empty:
            isSolid = true;
          case VarType.bool_:
            isSolid = value.boolValue;
          case VarType.bstr:
            final b = stringToBool(value.stringValue);
            if (b == null) {
              useStr = true;
            } else {
              isSolid = b;
            }
          default:
            invalidArg();
        }
        if (!useStr) {
          _numSolidBytes =
              isSolid ? xzPropsBlockSizeSolid : xzPropsBlockSizeAuto;
          return;
        }
      }
      final v = parseSizeString(s, value, 0);
      if (v == null) invalidArg('Bad solid block size');
      _numSolidBytes = v;
      return;
    }

    props.setProperty(name, value);
  }

  /// ISetProperties::SetProperties: the -m switch pairs, for example
  /// ("x", "9"), ("0", "LZMA2:d=26"), ("f", "BCJ"), ("crc", "8"),
  /// ("mt", "4"), ("s", "16m"). Throws [InvalidArgException] or
  /// [SevenZipException] for invalid properties.
  void setProperties(List<MapEntry<String, PropVariant>> properties) {
    _init();

    for (final p in properties) {
      _setProperty(p.key, p.value);
    }

    if (props.filterMethod.methodName.isNotEmpty) {
      var k = 0;
      for (; k < _namePairs.length; k++) {
        final pair = _namePairs[k];
        if (props.filterMethod.methodName.toLowerCase() ==
            pair.$2.toLowerCase()) {
          _filterId = pair.$1;
          break;
        }
      }
      if (k == _namePairs.length) {
        invalidArg('Unknown xz filter ${props.filterMethod.methodName}');
      }
    }

    props.methods.removeRange(0, props.getNumEmptyMethods());
    if (props.methods.length > 1) invalidArg('xz supports one method');
    if (props.methods.length == 1) {
      final m = props.methods[0];
      if (m.methodName.isEmpty) {
        m.methodName = _kLzma2Name;
      } else if (m.methodName.toLowerCase() != _kLzma2Name.toLowerCase() &&
          m.methodName.toLowerCase() != 'xz') {
        invalidArg('xz supports only the LZMA2 method');
      }
    }
  }

  /// [setProperties] from string pairs as the command line gives them
  /// (SetProperties.cpp: numbers become VT_UI4 / VT_UI8, a trailing '+'
  /// or '-' in an empty valued name becomes VT_BOOL).
  void setPropertiesFromStrings(List<MapEntry<String, String>> properties) {
    setProperties([
      for (final p in properties) convertCliProperty(p.key, p.value),
    ]);
  }
}

// ---------------------------------------------------------------------------
// CInStream (GetStream)

// FindBlock
int _findBlock(List<_BlockInfo> blocks, int numBlocks, int pos) {
  var left = 0, right = numBlocks;
  for (;;) {
    final mid = (left + right) ~/ 2;
    if (mid == left) return left;
    if (pos < blocks[mid].unpackPos) {
      right = mid;
    } else {
      left = mid;
    }
  }
}

/// CInStream of XzHandler.cpp: random access to the unpacked data.
class _XzInStream implements SeekableInStream {
  final XzHandler _handlerSpec;
  final int size;
  int _virtPos = 0;
  int _cacheStartPos = 0;
  int _cacheSize = 0;
  final Uint8List _cache;
  final XzUnpacker _xz = XzUnpacker();
  Uint8List? _inBuf;

  _XzInStream(this._handlerSpec, int maxBlocksSize, this.size)
      : _cache = Uint8List(maxBlocksSize);

  // DecodeBlock. The C code decodes in the output buffer mode of the
  // unpacker; here the block is decoded into the cache as a destination
  // buffer, which gives the same result.
  bool _decodeBlock(InStream seqInStream, int streamFlags, int packSize,
      int unpackSize, Uint8List dest) {
    const kInBufSize = 1 << 16;

    final xzu = _xz;
    xzu.init();

    final inBuf = _inBuf ??= Uint8List(kInBufSize);

    xzu.streamFlags = streamFlags;
    xzu.prepareToRandomBlockDecoding();

    final packSizeAligned = packSize + ((-packSize) & 3);
    var packRem = packSizeAligned;

    var inSize = 0;
    var inPos = 0;
    var outPos = 0;

    for (;;) {
      if (inPos == inSize) {
        inPos = 0;
        inSize = 0;
        var rem = kInBufSize;
        if (rem > packRem) rem = packRem;
        if (rem != 0) inSize = seqInStream.read(inBuf, 0, rem);
      }

      final res = xzu.code(dest, outPos, unpackSize - outPos, inBuf, inPos,
          inSize - inPos, inSize - inPos == 0, coderFinishEnd);
      final inLen = xzu.srcProcessed;
      final outLen = xzu.destProcessed;

      if (res != szOk) {
        if (res == szErrorCrc) return false;
        if (res == szErrorUnsupported) {
          throw const SevenZipException(
              'xz: unsupported method', SevenZipError.unsupportedMethod);
        }
        return false;
      }

      inPos += inLen;
      outPos += outLen;

      packRem -= inLen;

      final blockFinished = xzu.isBlockFinished;

      if ((inLen == 0 && outLen == 0) || blockFinished) {
        if (packRem != 0 || !blockFinished || unpackSize != outPos) {
          return false;
        }
        if (xzu.packSizeForIndex != packSize) return false;
        return true;
      }
    }
  }

  // CInStream::Read
  @override
  int read(Uint8List data, int off, int size) {
    if (size == 0) return 0;
    if (_virtPos >= this.size) return 0;
    {
      final rem = this.size - _virtPos;
      if (size > rem) size = rem;
    }
    if (size == 0) return 0;

    if (_virtPos < _cacheStartPos || _virtPos >= _cacheStartPos + _cacheSize) {
      final blocks = _handlerSpec._blocks!;
      final bi = _findBlock(blocks, blocks.length, _virtPos);
      final block = blocks[bi];
      final unpackSize = blocks[bi + 1].unpackPos - block.unpackPos;
      if (_cache.length < unpackSize) {
        throw const SevenZipException('xz: E_FAIL');
      }

      _cacheSize = 0;

      _handlerSpec._seekToPackPos(block.packPos);
      if (!_decodeBlock(_handlerSpec._seqStream!, block.streamFlags,
          block.packSize, unpackSize, _cache)) {
        throw const SevenZipException('xz: data error in block');
      }
      _cacheStartPos = block.unpackPos;
      _cacheSize = unpackSize;
    }

    {
      final offset = _virtPos - _cacheStartPos;
      final rem = _cacheSize - offset;
      if (size > rem) size = rem;
      data.setRange(off, off + size, _cache, offset);
      _virtPos += size;
      return size;
    }
  }

  @override
  int get position => _virtPos;

  @override
  set position(int v) {
    if (v < 0) throw const SevenZipException('Negative seek');
    _virtPos = v;
  }

  @override
  int get length => size;
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

/// A convenience view of an xz file: open, list, extract and test.
class XzArchive {
  final XzHandler handler = XzHandler();

  XzArchive._();

  /// Opens [stream]. Returns null when it is not an xz archive.
  static XzArchive? open(SeekableInStream stream) {
    final a = XzArchive._();
    if (!a.handler.open(stream)) return null;
    return a;
  }

  /// Opens a sequential stream: sizes are known only after [extract].
  static XzArchive openSeq(InStream stream) =>
      XzArchive._()..handler.openSeq(stream);

  /// Unpacked size (null when unknown).
  int? get size => handler.getProperty(0, Kpid.size) as int?;

  /// Physical size of the xz data.
  int? get packSize => handler.getProperty(0, Kpid.packSize) as int?;

  /// The method string as 7-Zip lists it, for example "LZMA2:26 CRC64".
  String? get method => handler.getArchiveProperty(Kpid.method) as String?;

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

  /// Random access to the unpacked data (IInArchiveGetStream), or null
  /// when not available.
  SeekableInStream? getStream() => handler.getStream(0);

  /// Creates an xz archive from [input] ([size] bytes, used for the
  /// dictionary and thread choices as 7-Zip does) with the -m properties
  /// of the xz handler, for example
  /// `[MapEntry('x', '9'), MapEntry('f', 'BCJ'), MapEntry('mt', '1')]`.
  static void create(InStream input, OutStream output, int size,
      {List<MapEntry<String, String>> properties = const [],
      ProgressCallback? progress}) {
    final h = XzHandler();
    h.setPropertiesFromStrings(properties);
    h.updateItems(output, 1, _SingleUpdateCallback(input, size, progress));
  }
}
