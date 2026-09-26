// The .lzma (LZMA-Alone) and .lzma86 formats: port of
// CPP/7zip/Archive/LzmaHandler.cpp (open, list, extract and test, several
// concatenated streams, the lzma86 variant with its BCJ filter byte), of
// the stream decoder parts of CPP/7zip/Compress/LzmaDecoder.cpp that the
// handler uses (CodeResume, ReadFromInputStream) and, for creating files
// (the handler has no IOutArchive), of the encode path of
// CPP/7zip/Bundles/LzmaCon/LzmaAlone.cpp and C/Lzma86Enc.c of the LZMA SDK
// 26.01.
//
// .lzma header (13 bytes): the 5 LZMA properties (lc/lp/pb byte and the
// dictionary size) and the unpacked size (8 bytes, little endian, all ones
// when unknown: then the stream ends with the end marker). The .lzma86
// header has one more byte in front: 0 = pure LZMA, 1 = x86 BCJ + LZMA.

import 'dart:typed_data';

import '../codec/codec.dart';
import '../codec/filters/bra.dart';
import '../codec/filters/filter_coder.dart';
import '../codec/lzma/lzma_coder.dart';
import '../codec/lzma/lzma_dec.dart';
import '../codec/lzma/lzma_enc.dart';
import '../common/method_props.dart';
import '../io/streams.dart';
import 'archive_types.dart';

// CheckDicSize
bool _checkDicSize(Uint8List p, int off) {
  final dicSize = getUint32LE(p, off);
  if (dicSize == 1) return true;
  for (var i = 0; i <= 30; i++) {
    if (dicSize == (2 << i) || dicSize == (3 << i)) return true;
  }
  return dicSize == 0xFFFFFFFF;
}

/// CHeader of LzmaHandler.cpp.
class LzmaAloneHeader {
  /// Unpacked size, -1 when not stored ((UInt64)(Int64)-1).
  int size = -1;
  int filterId = 0;
  final Uint8List lzmaProps = Uint8List(5);

  // GetProp
  int get prop => lzmaProps[0];
  // GetDicSize
  int get dicSize => getUint32LE(lzmaProps, 1);
  // HasSize
  bool get hasSize => size != -1;

  // CHeader::Parse
  bool parse(Uint8List buf, bool isThereFilter) {
    filterId = 0;
    if (isThereFilter) filterId = buf[0];
    final sig = isThereFilter ? 1 : 0;
    for (var i = 0; i < 5; i++) {
      lzmaProps[i] = buf[sig + i];
    }
    size = getUint64LE(buf, sig + 5);
    return lzmaProps[0] < 5 * 5 * 9 &&
        filterId < 2 &&
        (!hasSize || (size >= 0 && size < (1 << 56))) &&
        _checkDicSize(lzmaProps, 1);
  }
}

// ---------------------------------------------------------------------------
// NCompress::NLzma::CDecoder (the resumable stream decoder)

/// The LZMA stream decoder of LzmaDecoder.cpp with its own input buffer,
/// as the lzma handler drives it: [setDecoderProperties2], [codeResume]
/// for each stream and [readFromInputStream] for the headers between them.
class _LzmaResumeDecoder {
  final InStream _inStream;
  bool finishStream = true;
  bool _propsWereSet = false;
  bool _outSizeDefined = false;
  int _outSize = 0;
  int _outProcessed = 0;
  final int _outStep = 1 << 20;
  final Uint8List _inBuf = Uint8List(1 << 20);
  int _inPos = 0;
  int _inLim = 0;
  int _inProcessed = 0;
  int _lzmaStatus = lzmaStatusNotSpecified;
  final LzmaDec _state = LzmaDec();

  _LzmaResumeDecoder(this._inStream);

  int get inputProcessedSize => _inProcessed;
  int get outputProcessedSize => _outProcessed;

  // NeedsMoreInput
  bool get needsMoreInput => _lzmaStatus == lzmaStatusNeedsMoreInput;

  // CDecoder::SetDecoderProperties2. [maxOutSize] (not in the C code) lets
  // the dictionary buffer be smaller than the dictionary when the stream
  // is known to be short.
  bool setDecoderProperties2(Uint8List prop, {int? maxOutSize}) {
    if (_state.allocate(prop, maxOutSize: maxOutSize) != szOk) return false;
    _propsWereSet = true;
    return true;
  }

  // SetOutStreamSizeResume
  void _setOutStreamSizeResume(int? outSize) {
    _outSizeDefined = outSize != null;
    _outSize = outSize ?? 0;
    _outProcessed = 0;
    _lzmaStatus = lzmaStatusNotSpecified;
    _state.init();
  }

  // CDecoder::CodeSpec. Returns true for S_OK, false for S_FALSE.
  bool _codeSpec(OutStream outStream, ProgressCallback? progress) {
    if (!_propsWereSet) return false;

    final startInProgress = _inProcessed;
    final st = _state;
    var wrPos = st.dicPos;

    for (;;) {
      if (_inPos == _inLim) {
        // a read error of the C code would stop the reads; here it throws
        _inPos = _inLim = 0;
        _inLim = _inStream.read(_inBuf, 0, _inBuf.length);
      }

      final dicPos = st.dicPos;
      int size;
      {
        var next = st.dicBufSize;
        if (next - wrPos > _outStep) next = wrPos + _outStep;
        size = next - dicPos;
      }

      var finishMode = lzmaFinishAny;
      if (_outSizeDefined) {
        final rem = _outSize - _outProcessed;
        if (size >= rem) {
          size = rem;
          if (finishStream) finishMode = lzmaFinishEnd;
        }
      }

      final res = st.decodeToDic(
          dicPos + size, _inBuf, _inPos, _inLim - _inPos, finishMode);
      final inProcessed = st.srcProcessed;
      final status = st.status;

      _lzmaStatus = status;
      _inPos += inProcessed;
      _inProcessed += inProcessed;
      final outProcessed = st.dicPos - dicPos;
      _outProcessed += outProcessed;

      // we check for LZMA_STATUS_NEEDS_MORE_INPUT to allow RangeCoder
      // initialization, if (_outSizeDefined && _outSize == 0)
      final outFinished = _outSizeDefined && _outProcessed >= _outSize;

      final needStop = res != szOk ||
          (inProcessed == 0 && outProcessed == 0) ||
          status == lzmaStatusFinishedWithMark ||
          (outFinished && status != lzmaStatusNeedsMoreInput);

      if (needStop || outProcessed >= size) {
        if (st.dicPos != wrPos) {
          outStream.write(st.dic, wrPos, st.dicPos - wrPos);
        }

        if (st.dicPos == st.dicBufSize) st.dicPos = 0;
        wrPos = st.dicPos;

        if (needStop) {
          if (res != szOk) return false;

          if (status == lzmaStatusFinishedWithMark) {
            if (finishStream) {
              if (_outSizeDefined && _outSize != _outProcessed) return false;
            }
            return true;
          }

          if (outFinished && status != lzmaStatusNeedsMoreInput) {
            if (!finishStream || status == lzmaStatusMaybeFinishedWithoutMark) {
              return true;
            }
          }

          return false;
        }
      }

      if (progress != null) {
        progress(_inProcessed - startInProgress, _outProcessed);
      }
    }
  }

  // CDecoder::CodeResume
  bool codeResume(
      OutStream outStream, int? outSize, ProgressCallback? progress) {
    _setOutStreamSizeResume(outSize);
    return _codeSpec(outStream, progress);
  }

  // CDecoder::ReadFromInputStream. Returns the number of bytes read.
  int readFromInputStream(Uint8List data, int off, int size) {
    var processedSize = 0;
    while (size != 0) {
      if (_inPos == _inLim) {
        _inPos = _inLim = 0;
        _inLim = _inStream.read(_inBuf, 0, _inBuf.length);
        if (_inLim == 0) break;
      }
      var cur = _inLim - _inPos;
      if (cur > size) cur = size;
      data.setRange(off, off + cur, _inBuf, _inPos);
      _inPos += cur;
      _inProcessed += cur;
      size -= cur;
      off += cur;
      processedSize += cur;
    }
    return processedSize;
  }
}

// ---------------------------------------------------------------------------
// NArchive::NLzma::CDecoder

/// The decoder of LzmaHandler.cpp: LZMA plus the optional BCJ filter.
class _Decoder {
  final _LzmaResumeDecoder lzmaDecoder;

  // CDecoder::Create
  _Decoder(InStream inStream) : lzmaDecoder = _LzmaResumeDecoder(inStream) {
    lzmaDecoder.finishStream = true;
  }

  /// CDecoder::Code: throws [SevenZipException] (unsupportedMethod) for
  /// E_NOTIMPL; returns false for S_FALSE.
  bool code(
      LzmaAloneHeader header, OutStream outStream, ProgressCallback? progress) {
    if (header.filterId > 1) {
      throw const SevenZipException(
          'lzma: unsupported filter', SevenZipError.unsupportedMethod);
    }

    if (!lzmaDecoder.setDecoderProperties2(header.lzmaProps,
        maxOutSize: header.hasSize ? header.size : null)) {
      throw const SevenZipException(
          'lzma: unsupported properties', SevenZipError.unsupportedMethod);
    }

    final filteredMode = header.filterId == 1;

    FilterWriter? filterCoder;
    if (filteredMode) {
      filterCoder =
          FilterWriter(outStream, BcjFilter(false), encodeMode: false);
      outStream = filterCoder;
    }

    var res = lzmaDecoder.codeResume(
        outStream, header.hasSize ? header.size : null, progress);

    if (filterCoder != null) filterCoder.finish(); // OutStreamFinish

    if (!res) return false;

    if (header.hasSize) {
      if (lzmaDecoder.outputProcessedSize != header.size) return false;
    }
    return true;
  }
}

// ---------------------------------------------------------------------------
// IsArc_Lzma, IsArc_Lzma86

/// k_IsArc_Res_* values.
abstract final class IsArcResult {
  static const no = 0;
  static const yes = 1;
  static const needMore = 2;
}

/// IsArc_Lzma: quick signature check of a .lzma header.
int isArcLzma(Uint8List p, [int off = 0, int? size]) {
  size ??= p.length - off;
  const kHeaderSize = 1 + 4 + 8;
  if (size < kHeaderSize) return IsArcResult.needMore;
  if (p[off] >= 5 * 5 * 9) return IsArcResult.no;
  final unpackSize = getUint64LE(p, off + 1 + 4);
  if (unpackSize != -1) {
    if (unpackSize < 0 || unpackSize >= (1 << 56)) return IsArcResult.no;
  }
  if (unpackSize != 0) {
    if (size < kHeaderSize + 2) return IsArcResult.needMore;
    if (p[off + kHeaderSize] != 0) return IsArcResult.no;
    if (unpackSize != -1) {
      if ((p[off + kHeaderSize + 1] & 0x80) != 0) return IsArcResult.no;
    }
  }
  if (!_checkDicSize(p, off + 1)) return IsArcResult.no;
  return IsArcResult.yes;
}

/// IsArc_Lzma86
int isArcLzma86(Uint8List p, [int off = 0, int? size]) {
  size ??= p.length - off;
  if (size < 1) return IsArcResult.needMore;
  final filterId = p[off];
  if (filterId != 0 && filterId != 1) return IsArcResult.no;
  return isArcLzma(p, off + 1, size - 1);
}

// ---------------------------------------------------------------------------
// NArchive::NLzma::CHandler

// DictSizeToString
String _dictSizeToString(int val) {
  for (var i = 0; i < 32; i++) {
    if ((1 << i) == val) return '$i';
  }
  var c = 'b';
  if ((val & ((1 << 20) - 1)) == 0) {
    val >>= 20;
    c = 'm';
  } else if ((val & ((1 << 10) - 1)) == 0) {
    val >>= 10;
    c = 'k';
  }
  return '$val$c';
}

/// NArchive::NLzma::CHandler: the "lzma" format, or "lzma86" with
/// [lzma86] set.
class LzmaAloneHandler {
  final bool lzma86;
  bool _isArc = false;
  bool _needSeekToStart = false;
  bool _dataAfterEnd = false;
  bool _needMoreInput = false;
  bool _unsupported = false;
  bool _dataError = false;

  bool _packSizeDefined = false;
  bool _unpackSizeDefined = false;
  bool _numStreamsDefined = false;

  final LzmaAloneHeader _header = LzmaAloneHeader();
  SeekableInStream? _stream;
  InStream? _seqStream;

  int _packSize = 0;
  int _unpackSize = 0;
  int _numStreams = 0;

  LzmaAloneHandler({this.lzma86 = false});

  int get _headerSize => 5 + 8 + (lzma86 ? 1 : 0);

  /// kProps
  static const List<int> itemPropIds = [Kpid.size, Kpid.packSize, Kpid.method];

  /// kArcProps
  static const List<int> archivePropIds = [Kpid.numStreams, Kpid.method];

  /// The header of the first stream (after [open]).
  LzmaAloneHeader get header => _header;

  /// IInArchive::GetArchiveProperty
  Object? getArchiveProperty(int propID) {
    switch (propID) {
      case Kpid.phySize:
        return _packSizeDefined ? _packSize : null;
      case Kpid.numStreams:
        return _numStreamsDefined ? _numStreams : null;
      case Kpid.unpackSize:
        return _unpackSizeDefined ? _unpackSize : null;
      case Kpid.method:
        return _getMethod();
      case Kpid.errorFlags:
        var v = 0;
        if (!_isArc) v |= ErrorFlags.isNotArc;
        if (_needMoreInput) v |= ErrorFlags.unexpectedEnd;
        if (_dataAfterEnd) v |= ErrorFlags.dataAfterEnd;
        if (_unsupported) v |= ErrorFlags.unsupportedMethod;
        if (_dataError) v |= ErrorFlags.dataError;
        return v;
    }
    return null;
  }

  /// IInArchive::GetNumberOfItems
  int get numberOfItems => 1;

  // CHandler::GetMethod
  String? _getMethod() {
    if (_stream == null) return null;

    final s = StringBuffer();
    if (_header.filterId != 0) s.write('BCJ ');
    s.write('LZMA:');
    s.write(_dictSizeToString(_header.dicSize));

    var d = _header.prop;
    {
      final lc = d % 9;
      d ~/= 9;
      final pb = d ~/ 5;
      final lp = d % 5;
      if (lc != 3) s.write(':lc$lc');
      if (lp != 0) s.write(':lp$lp');
      if (pb != 2) s.write(':pb$pb');
    }
    return s.toString();
  }

  /// IInArchive::GetProperty
  Object? getProperty(int index, int propID) {
    switch (propID) {
      case Kpid.size:
        return (_stream != null && _header.hasSize) ? _header.size : null;
      case Kpid.packSize:
        return _packSizeDefined ? _packSize : null;
      case Kpid.method:
        return _getMethod();
    }
    return null;
  }

  /// IInArchive::Open. Returns false when [inStream] is not a .lzma
  /// (.lzma86) file.
  bool open(SeekableInStream inStream) {
    close();

    final headerSize = _headerSize;
    const kBufSize = 1 << 7;
    final buf = Uint8List(kBufSize);
    inStream.position = 0;
    final processedSize = readFully(inStream, buf, 0, kBufSize);
    if (processedSize < headerSize + 2) return false;
    if (!_header.parse(buf, lzma86)) return false;
    final start = headerSize;
    // empty stream with EOS is not 0x80
    if (buf[start] != 0) return false;

    _packSize = inStream.length;

    final srcLen = processedSize - headerSize;

    if (srcLen > 10 && _header.size == 0 && _header.lzmaProps[0] == 0) {
      return false;
    }

    const outLimit = 1 << 11;

    var outSize = outLimit;
    if (_header.size >= 0 && outSize > _header.size) outSize = _header.size;

    final r = lzmaDecode(
        Uint8List(outSize),
        Uint8List.sublistView(buf, start, start + srcLen),
        _header.lzmaProps,
        lzmaFinishAny);

    if (r.res != szOk && r.res != szErrorInputEof) return false;

    _isArc = true;
    _stream = inStream;
    _seqStream = inStream;
    _needSeekToStart = true;
    return true;
  }

  /// IArchiveOpenSeq::OpenSeq
  void openSeq(InStream stream) {
    close();
    _isArc = true;
    _seqStream = stream;
  }

  /// The decoded data of the first stream as a sequential stream
  /// (IInArchiveGetStream for item 0), for a tar inside a .lzma file read
  /// without a temporary file. null for lzma86. The archive stream is
  /// rewound when it was read before.
  InStream? getSeqStream() {
    if (lzma86) return null;
    final s = _seqStream;
    if (s == null) return null;
    if (_needSeekToStart) {
      final st = _stream;
      if (st == null) return null;
      st.position = 0;
    } else {
      _needSeekToStart = true;
    }
    final buf = Uint8List(_headerSize);
    if (readFully(s, buf, 0, buf.length) != buf.length) return null;
    final h = LzmaAloneHeader();
    if (!h.parse(buf, false)) return null;
    return LzmaDecoderStream(Uint8List.fromList(h.lzmaProps), s,
        outSize: h.hasSize ? h.size : null);
  }

  /// IInArchive::Close
  void close() {
    _isArc = false;
    _needSeekToStart = false;
    _dataAfterEnd = false;
    _needMoreInput = false;
    _unsupported = false;
    _dataError = false;

    _packSizeDefined = false;
    _unpackSizeDefined = false;
    _numStreamsDefined = false;

    _packSize = 0;

    _stream = null;
    _seqStream = null;
  }

  /// IInArchive::Extract. [indices] null means all items. Calls
  /// [extractCallback].setOperationResult with an [OperationResult].
  void extract(List<int>? indices, bool testMode,
      ArchiveExtractCallback extractCallback) {
    if (indices != null) {
      if (indices.isEmpty) return;
      if (indices.length != 1 || indices[0] != 0) {
        throw const SevenZipException(
            'lzma: E_INVALIDARG', SevenZipError.unsupported);
      }
    }

    if (_packSizeDefined) extractCallback.setTotal(_packSize);

    int opResult;
    {
      final askMode = testMode ? AskMode.test : AskMode.extract;
      final realOutStream = extractCallback.getStream(0, askMode);
      if (!testMode && realOutStream == null) return;

      extractCallback.prepareOperation(askMode);

      // CDummyOutStream
      final outStream = CountingOutStream(realOutStream ?? NullOutStream());

      if (_needSeekToStart) {
        final s = _stream;
        if (s == null) throw const SevenZipException('lzma: E_FAIL');
        s.position = 0;
      } else {
        _needSeekToStart = true;
      }

      final decoder = _Decoder(_seqStream!);

      var firstItem = true;

      var packSize = 0;
      var unpackSize = 0;
      var numStreams = 0;

      var dataAfterEnd = false;

      var hresOk = true;

      for (;;) {
        extractCallback.setCompleted(packSize);

        const kBufSize = 1 + 5 + 8;
        final buf = Uint8List(kBufSize);
        final headerSize = _headerSize;
        final processed =
            decoder.lzmaDecoder.readFromInputStream(buf, 0, headerSize);
        if (processed != headerSize) {
          if (processed != 0) dataAfterEnd = true;
          break;
        }

        final st = LzmaAloneHeader();
        if (!st.parse(buf, lzma86)) {
          dataAfterEnd = true;
          break;
        }
        numStreams++;
        firstItem = false;

        final packBase = packSize;
        try {
          hresOk = decoder.code(st, outStream, (inSize, outSize) {
            extractCallback.setCompleted(packBase + inSize);
          });
        } on SevenZipException catch (e) {
          if (e.kind != SevenZipError.unsupportedMethod) rethrow;
          // E_NOTIMPL
          packSize = decoder.lzmaDecoder.inputProcessedSize;
          unpackSize = outStream.count;
          _unsupported = true;
          hresOk = false;
          break;
        }

        packSize = decoder.lzmaDecoder.inputProcessedSize;
        unpackSize = outStream.count;

        if (!hresOk) break;
      }

      if (firstItem) {
        _isArc = false;
        hresOk = false;
      } else {
        if (dataAfterEnd) {
          _dataAfterEnd = true;
        } else if (decoder.lzmaDecoder.needsMoreInput) {
          _needMoreInput = true;
        }

        _packSize = packSize;
        _unpackSize = unpackSize;
        _numStreams = numStreams;

        _packSizeDefined = true;
        _unpackSizeDefined = true;
        _numStreamsDefined = true;
      }

      outStream.flush();

      opResult = OperationResult.ok;

      if (!_isArc) {
        opResult = OperationResult.isNotArc;
      } else if (_needMoreInput) {
        opResult = OperationResult.unexpectedEnd;
      } else if (_unsupported) {
        opResult = OperationResult.unsupportedMethod;
      } else if (_dataAfterEnd) {
        opResult = OperationResult.dataAfterEnd;
      } else if (!hresOk) {
        opResult = OperationResult.dataError;
      } else {
        opResult = OperationResult.ok;
      }
    }
    extractCallback.setOperationResult(opResult);
  }
}

// ---------------------------------------------------------------------------
// Creating .lzma files (LzmaAlone.cpp) and .lzma86 files (Lzma86Enc.c)

/// kDictSizeLog of LzmaAlone.cpp
const int _kDictSizeLog = 24;

/// Encodes [input] as a .lzma file, as `lzma e` of LzmaAlone.cpp does:
/// the LzmaAlone defaults (dictionary from the file size up to 16 MiB,
/// fb=128, mf=BT4, lc=3, lp=0, pb=2, a=1) followed by [methodProps], the
/// LZMA properties in 7-Zip's -m syntax (for example "d=24:fb=64:lc=0"),
/// which override them. [size] is the input size (null as for stdin: the
/// dictionary is 16 MiB). With [eos] (the -eos switch; also "eos" in
/// [methodProps], or no [size]) the header has an unknown size and the
/// stream ends with the end marker. Returns the number of input bytes.
int lzmaAloneEncode(InStream input, OutStream output,
    {int? size,
    bool eos = false,
    String methodProps = '',
    ProgressCallback? progress}) {
  final fileSizeDefined = size != null;
  var fileSize = size ?? 0;

  var dict = 1 << _kDictSizeLog;
  if (fileSizeDefined) {
    var i = 16;
    for (; i < _kDictSizeLog; i++) {
      if ((1 << i) >= fileSize) break;
    }
    dict = 1 << i;
  }

  final userProps = parseMethodProps(methodProps);
  eos = eos || !fileSizeDefined;
  for (final p in userProps) {
    if (p.id == CoderPropId.endMarker && p.value.vt == VarType.bool_) {
      eos = eos || p.value.boolValue;
    }
  }

  const pb = 2;
  const lc = 3; // = 0; for 32-bit data
  const lp = 0; // = 2; for 32-bit data
  const algo = 1;
  const fb = 128;

  final props = <CoderProp>[
    CoderProp(CoderPropId.dictionarySize, PropVariant.ui4(dict)),
    CoderProp(CoderPropId.posStateBits, const PropVariant.ui4(pb)),
    CoderProp(CoderPropId.litContextBits, const PropVariant.ui4(lc)),
    CoderProp(CoderPropId.litPosBits, const PropVariant.ui4(lp)),
    CoderProp(CoderPropId.algorithm, const PropVariant.ui4(algo)),
    CoderProp(CoderPropId.numFastBytes, const PropVariant.ui4(fb)),
    CoderProp(CoderPropId.matchFinder, const PropVariant.bstr('BT4')),
    CoderProp(CoderPropId.endMarker, PropVariant.boolean(eos)),
    CoderProp(CoderPropId.numThreads, const PropVariant.ui4(1)),
    ...userProps,
    CoderProp(CoderPropId.endMarker, PropVariant.boolean(eos)),
  ];

  final encoder = LzmaCompressor.fromCoderProps(props);

  // WriteCoderProperties
  final propBytes = encoder.props;
  output.write(propBytes, 0, propBytes.length);

  var fileSizeWasUsed = true;
  if (eos) {
    fileSize = -1;
    fileSizeWasUsed = false;
  }
  {
    final temp = Uint8List(8);
    setUint64LE(temp, 0, fileSize);
    output.write(temp, 0, 8);
  }

  final processedSize = encoder.encode(input, output, progress: progress);
  if (fileSizeWasUsed && processedSize != fileSize) {
    throw const SevenZipException('Incorrect size of processed data');
  }
  return processedSize;
}

/// ESzFilterMode of Lzma86.h
enum Lzma86FilterMode {
  /// SZ_FILTER_NO: pure LZMA.
  no,

  /// SZ_FILTER_YES: x86 BCJ + LZMA.
  yes,

  /// SZ_FILTER_AUTO: tries both and keeps the smaller.
  auto,
}

/// LZMA86_SIZE_OFFSET
const int _lzma86SizeOffset = 1 + 5;

/// LZMA86_HEADER_SIZE
const int lzma86HeaderSize = _lzma86SizeOffset + 8;

/// Lzma86_Encode: encodes [src] into a complete .lzma86 file. [destCapacity]
/// is the output buffer size of the C function (SZ_ERROR_OUTPUT_EOF when
/// the result does not fit); LzmaAlone uses srcLen / 20 * 21 + (1 << 16).
Uint8List lzma86Encode(Uint8List src,
    {int level = 5,
    int dictSize = 1 << _kDictSizeLog,
    Lzma86FilterMode filterMode = Lzma86FilterMode.auto,
    int? destCapacity}) {
  final srcLen = src.length;
  final outSize2 = destCapacity ?? srcLen ~/ 20 * 21 + (1 << 16);
  var mainResult = szErrorOutputEof;
  final props = LzmaEncProps()
    ..level = level
    ..dictSize = dictSize;

  if (outSize2 < lzma86HeaderSize) {
    throw const SevenZipException('lzma86: output buffer is too small');
  }

  final header = Uint8List(lzma86HeaderSize);
  setUint64LE(header, _lzma86SizeOffset, srcLen);

  Uint8List? filteredStream;
  final useFilter = filterMode != Lzma86FilterMode.no;
  if (useFilter) {
    filteredStream = Uint8List.fromList(src);
    final x86State = Uint32List(1)..[0] = kBranchConvStX86StateInitVal;
    z7BranchConvStX86Enc(filteredStream, 0, srcLen, 0, x86State);
  }

  Uint8List? best;
  {
    var minSize = 0;
    var bestIsFiltered = false;
    // passes for SZ_FILTER_AUTO:
    //   0 - BCJ + LZMA
    //   1 - LZMA
    //   2 - BCJ + LZMA again, if pass 0 (BCJ + LZMA) is better.
    final numPasses = filterMode == Lzma86FilterMode.auto ? 3 : 1;
    for (var i = 0; i < numPasses; i++) {
      var curModeIsFiltered = numPasses > 1 && i == numPasses - 1;
      if (curModeIsFiltered && !bestIsFiltered) break;
      if (useFilter && i == 0) curModeIsFiltered = true;
      final r = lzmaEncode(curModeIsFiltered ? filteredStream! : src, props);
      final outSizeProcessed = r.data.length;
      // SZ_ERROR_OUTPUT_EOF when the data does not fit
      if (outSizeProcessed <= outSize2 - lzma86HeaderSize) {
        if (outSizeProcessed <= minSize || mainResult != szOk) {
          minSize = outSizeProcessed;
          bestIsFiltered = curModeIsFiltered;
          mainResult = szOk;
          header.setRange(1, 1 + 5, r.props);
          best = r.data;
        }
      }
    }
    header[0] = bestIsFiltered ? 1 : 0;
  }

  if (mainResult != szOk) {
    throw const SevenZipException('lzma86: output buffer overflow');
  }
  final out = Uint8List(lzma86HeaderSize + best!.length);
  out.setAll(0, header);
  out.setAll(lzma86HeaderSize, best);
  return out;
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

/// A convenience view of a .lzma or .lzma86 file.
class LzmaAloneArchive {
  final LzmaAloneHandler handler;

  LzmaAloneArchive._(this.handler);

  /// Opens [stream] as .lzma ([lzma86] false) or .lzma86. Returns null when
  /// it is not such a file.
  static LzmaAloneArchive? open(SeekableInStream stream,
      {bool lzma86 = false}) {
    final h = LzmaAloneHandler(lzma86: lzma86);
    if (!h.open(stream)) return null;
    return LzmaAloneArchive._(h);
  }

  /// A sequential stream (sizes are known after [extract]).
  static LzmaAloneArchive openSeq(InStream stream, {bool lzma86 = false}) =>
      LzmaAloneArchive._(LzmaAloneHandler(lzma86: lzma86)..openSeq(stream));

  /// The unpacked size of the first stream as the header stores it, or
  /// null when it is not stored; after [extract], the total unpacked size.
  int? get size =>
      (handler.getArchiveProperty(Kpid.unpackSize) as int?) ??
      (handler.getProperty(0, Kpid.size) as int?);

  int? get packSize => handler.getProperty(0, Kpid.packSize) as int?;

  /// For example "LZMA:24" or "BCJ LZMA:23:lc0".
  String? get method => handler.getProperty(0, Kpid.method) as String?;

  int? get numStreams => handler.getArchiveProperty(Kpid.numStreams) as int?;

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
}
