// The LZMA and LZMA2 coders as 7-Zip exposes them:
//   * CPP/7zip/Compress/LzmaEncoder.cpp, Lzma2Encoder.cpp: compressors with
//     SetCoderProperties (SetLzmaProp, SetLzma2Prop, ParseMatchFinder) and
//     SetCoderPropertiesOpt (expected data size);
//   * CPP/7zip/Compress/LzmaDecoder.cpp (CDecoder::CodeSpec) and
//     C/Lzma2DecMt.c (Lzma2Dec_Decode_ST): pull decoders;
//   * the coder properties come from the shared MethodProps.cpp port
//     (common/method_props.dart), so "d=64m:fb=64:mf=bt4" works as with -m.

import 'dart:typed_data';

import '../../common/method_props.dart';
import '../../io/streams.dart';
import '../codec.dart';
import 'lzma2_dec.dart';
import 'lzma2_enc.dart';
import 'lzma_dec.dart';
import 'lzma_enc.dart';

export 'lzma2_enc.dart'
    show Lzma2EncProps, lzma2BlockSizeAuto, lzma2BlockSizeSolid;
export 'lzma_enc.dart' show LzmaEncProps;
export '../../common/method_props.dart'
    show CoderProp, CoderPropId, parseMethodProps, parseMethodParam;

SevenZipException _invalidArg(String what) =>
    InvalidArgException('Invalid method property: $what');

// The VT_UI4 value of [p], E_INVALIDARG for any other type.
int _ui4(CoderProp p) {
  final v = p.value;
  if (v.vt != VarType.ui4) throw _invalidArg(p.toString());
  return v.intValue;
}

// ParseMatchFinder
bool _parseMatchFinder(String s, LzmaEncProps ep) {
  final l = s.toLowerCase();
  if (l.length != 3) return false;
  final num = l.codeUnitAt(2) - 0x30;
  if (l.startsWith('hc')) {
    if (num < 4 || num > 5) return false;
    ep.btMode = 0;
    ep.numHashBytes = num;
    return true;
  }
  if (l.startsWith('bt')) {
    if (num < 2 || num > 5) return false;
    ep.btMode = 1;
    ep.numHashBytes = num;
    return true;
  }
  return false;
}

/// NCompress::NLzma::SetLzmaProp. Throws [SevenZipException] (E_INVALIDARG).
void setLzmaProp(LzmaEncProps ep, CoderProp prop) {
  final id = prop.id;
  final v = prop.value;

  if (id == CoderPropId.matchFinder) {
    if (v.vt != VarType.bstr || !_parseMatchFinder(v.stringValue, ep)) {
      throw _invalidArg('mf=${v.value}');
    }
    return;
  }

  if (id == CoderPropId.affinity || id == CoderPropId.affinityInGroup) {
    if (v.vt != VarType.ui8) throw _invalidArg(prop.toString());
    return; // no thread affinity in this port
  }

  if (id == CoderPropId.threadGroup) {
    _ui4(prop);
    return;
  }

  if (id == CoderPropId.hashBits) {
    ep.numHashOutBits = _ui4(prop);
    return;
  }

  if (id > CoderPropId.reduceSize) return;

  if (id == CoderPropId.reduceSize) {
    if (v.vt != VarType.ui8) throw _invalidArg(prop.toString());
    ep.reduceSize = v.intValue;
    return;
  }

  if (id == CoderPropId.dictionarySize && v.vt == VarType.ui8) {
    // 21.03 : we support 64-bit VT_UI8 for dictionary and (dict == 4 GiB)
    final d = v.intValue;
    // UInt64 compare: a negative Dart int is above 2^63.
    if (d < 0 || d > (1 << 32)) throw _invalidArg(prop.toString());
    ep.dictSize = d == (1 << 32) ? 0xFFFFFFFF : d;
    return;
  }

  final u = _ui4(prop);
  switch (id) {
    case CoderPropId.defaultProp:
      if (u > 32) throw _invalidArg(prop.toString());
      ep.dictSize = u == 32 ? 0xFFFFFFFF : 1 << u;
    case CoderPropId.level:
      ep.level = u;
    case CoderPropId.numFastBytes:
      ep.fb = u;
    case CoderPropId.matchFinderCycles:
      ep.mc = u;
    case CoderPropId.algorithm:
      ep.algo = u;
    case CoderPropId.dictionarySize:
      ep.dictSize = u;
    case CoderPropId.posStateBits:
      ep.pb = u;
    case CoderPropId.litPosBits:
      ep.lp = u;
    case CoderPropId.litContextBits:
      ep.lc = u;
    case CoderPropId.numThreads:
      ep.numThreads = u;
    default:
      throw _invalidArg(prop.toString());
  }
}

/// NCompress::NLzma2::SetLzma2Prop
void setLzma2Prop(Lzma2EncProps p, CoderProp prop) {
  switch (prop.id) {
    case CoderPropId.blockSize:
      final v = prop.value;
      if (v.vt != VarType.ui4 && v.vt != VarType.ui8) {
        throw _invalidArg(prop.toString());
      }
      p.blockSize = v.intValue;
    case CoderPropId.numThreads:
      p.numTotalThreads = _ui4(prop);
    case CoderPropId.numThreadGroups:
      final g = _ui4(prop);
      if (g >= (1 << 16)) throw _invalidArg(prop.toString());
      p.numThreadGroups = g;
    default:
      setLzmaProp(p.lzmaProps, prop);
  }
}

/// NCompress::NLzma::CEncoder::SetCoderProperties: builds the encoder
/// properties from coder props (kEndMarker included).
LzmaEncProps lzmaPropsFromCoderProps(Iterable<CoderProp> props) {
  final ep = LzmaEncProps();
  for (final prop in props) {
    if (prop.id == CoderPropId.endMarker) {
      final v = prop.value;
      if (v.vt != VarType.bool_) throw _invalidArg(prop.toString());
      ep.writeEndMark = v.boolValue;
    } else {
      setLzmaProp(ep, prop);
    }
  }
  return ep;
}

/// NCompress::NLzma2::CEncoder::SetCoderProperties
Lzma2EncProps lzma2PropsFromCoderProps(Iterable<CoderProp> props) {
  final p = Lzma2EncProps();
  for (final prop in props) {
    setLzma2Prop(p, prop);
  }
  return p;
}

// ---------------------------------------------------------------------------
// Compressors

/// The LZMA encoder (NCompress::NLzma::CEncoder). [props] are the 5 bytes
/// stored in 7z / .lzma headers; [encode] writes the raw LZMA stream.
class LzmaCompressor implements Compressor {
  final LzmaEncProps encProps;
  final LzmaEnc _enc = LzmaEnc();

  /// SetCoderPropertiesOpt(kExpectedDataSize): -1 = unknown. It only
  /// selects the hash table size (and so changes the output bytes).
  int expectedDataSize = -1;

  /// Throws [SevenZipException] for unsupported properties.
  LzmaCompressor([LzmaEncProps? props]) : encProps = props ?? LzmaEncProps() {
    _enc.setProps(encProps);
  }

  /// From a 7-Zip method property string such as "d=64m:fb=64:mf=bt4:eos".
  factory LzmaCompressor.fromString(String methodProps) =>
      LzmaCompressor(lzmaPropsFromCoderProps(parseMethodProps(methodProps)));

  /// From parsed coder properties (CEncoder::SetCoderProperties).
  factory LzmaCompressor.fromCoderProps(Iterable<CoderProp> props) =>
      LzmaCompressor(lzmaPropsFromCoderProps(props));

  @override
  Uint8List get props => _enc.writeProperties();

  /// LzmaEnc_IsWriteEndMark
  bool get writeEndMark => _enc.isWriteEndMark;

  /// The normalized dictionary size.
  int get dictSize => _enc.dictSize;

  @override
  int encode(InStream input, OutStream output, {ProgressCallback? progress}) {
    final counting = CountingInStream(input);
    _enc.setProps(encProps);
    _enc.setDataSize(expectedDataSize);
    try {
      _enc.encode(output, counting, progress: progress);
    } finally {
      _enc.destroy();
    }
    output.flush();
    return counting.count;
  }
}

/// The LZMA2 encoder (NCompress::NLzma2::CEncoder). [props] is the one
/// byte dictionary property (7z coder props, xz filter props); [encode]
/// writes the raw LZMA2 stream including the final 0x00, which is also
/// what the xz format stores in a block.
class Lzma2Compressor implements Compressor {
  final Lzma2EncProps encProps;
  final Lzma2Enc _enc = Lzma2Enc();

  /// SetCoderPropertiesOpt(kExpectedDataSize): -1 = unknown.
  int expectedDataSize = -1;

  /// Throws [SevenZipException] for unsupported properties.
  Lzma2Compressor([Lzma2EncProps? props])
      : encProps = props ?? Lzma2EncProps() {
    _enc.setProps(encProps);
  }

  /// From a 7-Zip method property string such as "d=64m:c=16m:mt=4".
  factory Lzma2Compressor.fromString(String methodProps) =>
      Lzma2Compressor(lzma2PropsFromCoderProps(parseMethodProps(methodProps)));

  factory Lzma2Compressor.fromCoderProps(Iterable<CoderProp> props) =>
      Lzma2Compressor(lzma2PropsFromCoderProps(props));

  @override
  Uint8List get props => Uint8List(1)..[0] = _enc.writeProperties();

  /// The normalized properties (block size, block threads...).
  Lzma2EncProps get normalizedProps => _enc.props;

  @override
  int encode(InStream input, OutStream output, {ProgressCallback? progress}) {
    final counting = CountingInStream(input);
    _enc.setProps(encProps);
    _enc.setDataSize(expectedDataSize);
    try {
      _enc.encode(output, counting, progress: progress);
    } finally {
      _enc.destroy();
    }
    output.flush();
    return counting.count;
  }
}

/// The LZMA2 property byte for a dictionary size (Lzma2Enc_WriteProperties).
int lzma2PropForDictSize(int dictSize) {
  var i = 0;
  for (; i < 40; i++) {
    if (dictSize <= lzma2DictSizeFromProp(i)) break;
  }
  return i;
}

// ---------------------------------------------------------------------------
// Pull decoders

const int _defaultInBufSize = 1 << 16;
const int _progressStep = 1 << 20;

/// Pull LZMA decoder (CDecoder::CodeSpec of LzmaDecoder.cpp). With
/// [outSize] given and [finishStream] set (as the 7z extractor does), the
/// stream must end exactly there (an end marker is allowed); without
/// [outSize] the stream must end with the end marker.
class LzmaDecoderStream implements InStream {
  final InStream _input;
  final int? outSize;
  final bool finishStream;
  final ProgressCallback? progress;
  final LzmaDec _dec = LzmaDec();
  final Uint8List _inBuf;
  int _inPos = 0;
  int _inLim = 0;
  bool _inEnd = false;
  int _inProcessed = 0;
  int _outProcessed = 0;
  int _wrPos = 0;
  bool _stopped = false;
  SevenZipException? _error;
  int _nextProgress = _progressStep;

  /// The last ELzmaStatus returned by the decoder.
  int lzmaStatus = lzmaStatusNotSpecified;

  LzmaDecoderStream(Uint8List props, this._input,
      {this.outSize,
      this.finishStream = true,
      this.progress,
      int inBufSize = _defaultInBufSize})
      : _inBuf = Uint8List(inBufSize) {
    if (_dec.allocate(props, maxOutSize: outSize) != szOk) {
      throw const SevenZipException(
          'Unsupported LZMA properties', SevenZipError.unsupportedMethod);
    }
    _dec.init();
  }

  /// Packed bytes consumed by the decoder so far.
  int get inProcessed => _inProcessed;

  /// Bytes decoded so far.
  int get outProcessed => _outProcessed;

  /// True when the stream ended with the end marker.
  bool get finishedWithMark => lzmaStatus == lzmaStatusFinishedWithMark;

  /// Bytes read from the input but not consumed by the decoder (after the
  /// end of the stream they belong to whatever follows it).
  Uint8List get unusedInput => Uint8List.sublistView(_inBuf, _inPos, _inLim);

  @override
  int read(Uint8List buf, int off, int len) {
    if (len <= 0) return 0;
    for (;;) {
      final avail = _dec.dicPos - _wrPos;
      if (avail > 0) {
        final n = avail < len ? avail : len;
        buf.setRange(off, off + n, _dec.dic, _wrPos);
        _wrPos += n;
        return n;
      }
      if (_stopped) {
        final e = _error;
        if (e != null) throw e;
        return 0;
      }
      _step();
    }
  }

  void _step() {
    final dec = _dec;
    if (dec.dicPos == dec.dicBufSize) {
      dec.dicPos = 0;
      _wrPos = 0;
    }
    if (_inPos == _inLim && !_inEnd) {
      _inPos = 0;
      _inLim = _input.read(_inBuf, 0, _inBuf.length);
      if (_inLim == 0) _inEnd = true;
    }

    final dicPos = dec.dicPos;
    var size = dec.dicBufSize - dicPos;
    var finishMode = lzmaFinishAny;
    final outSize = this.outSize;
    if (outSize != null) {
      final rem = outSize - _outProcessed;
      if (size >= rem) {
        size = rem;
        if (finishStream) finishMode = lzmaFinishEnd;
      }
    }

    final res = dec.decodeToDic(
        dicPos + size, _inBuf, _inPos, _inLim - _inPos, finishMode);
    final status = dec.status;
    lzmaStatus = status;
    final inProcessed = dec.srcProcessed;
    _inPos += inProcessed;
    _inProcessed += inProcessed;
    final outProcessed = dec.dicPos - dicPos;
    _outProcessed += outProcessed;

    final outFinished = outSize != null && _outProcessed >= outSize;

    final needStop = res != szOk ||
        (inProcessed == 0 && outProcessed == 0) ||
        status == lzmaStatusFinishedWithMark ||
        (outFinished && status != lzmaStatusNeedsMoreInput);

    final progress = this.progress;
    if (progress != null && _outProcessed >= _nextProgress) {
      _nextProgress = _outProcessed + _progressStep;
      progress(_inProcessed, _outProcessed);
    }

    if (!needStop) return;
    _stopped = true;
    if (res != szOk) {
      _error = const SevenZipException('LZMA data error');
    } else if (status == lzmaStatusFinishedWithMark) {
      if (finishStream && outSize != null && outSize != _outProcessed) {
        _error = const SevenZipException('LZMA data error (end marker)');
      }
    } else if (outFinished &&
        status != lzmaStatusNeedsMoreInput &&
        (!finishStream || status == lzmaStatusMaybeFinishedWithoutMark)) {
      // finished
    } else if (status == lzmaStatusNeedsMoreInput) {
      _error = const SevenZipException(
          'Unexpected end of LZMA data', SevenZipError.unexpectedEnd);
    } else {
      _error = const SevenZipException('LZMA data error');
    }
  }
}

/// Pull LZMA2 decoder (Lzma2Dec_Decode_ST of Lzma2DecMt.c). The stream
/// must end with the LZMA2 end marker (0x00); with [outSize] given and
/// [finishStream] set, the unpacked size must match it too.
class Lzma2DecoderStream implements InStream {
  final InStream _input;
  final int? outSize;
  final bool finishStream;
  final ProgressCallback? progress;
  final Lzma2Dec _dec = Lzma2Dec();
  final Uint8List _inBuf;
  int _inPos = 0;
  int _inLim = 0;
  bool _inEnd = false;
  int _inProcessed = 0;
  int _outProcessed = 0;
  int _wrPos = 0;
  bool _stopped = false;
  SevenZipException? _error;
  int _nextProgress = _progressStep;

  /// The last ELzmaStatus returned by the decoder.
  int lzmaStatus = lzmaStatusNotSpecified;

  /// [prop] is the one byte LZMA2 property (0..40).
  Lzma2DecoderStream(int prop, this._input,
      {this.outSize,
      this.finishStream = true,
      this.progress,
      int inBufSize = _defaultInBufSize})
      : _inBuf = Uint8List(inBufSize) {
    if (_dec.allocate(prop, maxOutSize: outSize) != szOk) {
      throw const SevenZipException(
          'Unsupported LZMA2 properties', SevenZipError.unsupportedMethod);
    }
    _dec.init();
  }

  /// A raw LZMA2 decoder for a dictionary size in bytes.
  Lzma2DecoderStream.withDictSize(int dictSize, this._input,
      {this.outSize,
      this.finishStream = true,
      this.progress,
      int inBufSize = _defaultInBufSize})
      : _inBuf = Uint8List(inBufSize) {
    _dec.allocateForDictSize(dictSize, maxOutSize: outSize);
    _dec.init();
  }

  int get inProcessed => _inProcessed;
  int get outProcessed => _outProcessed;

  /// Bytes read from the input but not consumed by the decoder. After the
  /// end marker they belong to whatever follows the LZMA2 stream (xz block
  /// padding and check, for example).
  Uint8List get unusedInput => Uint8List.sublistView(_inBuf, _inPos, _inLim);

  @override
  int read(Uint8List buf, int off, int len) {
    if (len <= 0) return 0;
    for (;;) {
      final avail = _dec.decoder.dicPos - _wrPos;
      if (avail > 0) {
        final n = avail < len ? avail : len;
        buf.setRange(off, off + n, _dec.decoder.dic, _wrPos);
        _wrPos += n;
        return n;
      }
      if (_stopped) {
        final e = _error;
        if (e != null) throw e;
        return 0;
      }
      _step();
    }
  }

  void _step() {
    final dec = _dec.decoder;
    if (dec.dicPos == dec.dicBufSize) {
      dec.dicPos = 0;
      _wrPos = 0;
    }
    if (_inPos == _inLim && !_inEnd) {
      _inPos = 0;
      _inLim = _input.read(_inBuf, 0, _inBuf.length);
      if (_inLim == 0) _inEnd = true;
    }

    final dicPos = dec.dicPos;
    var size = dec.dicBufSize - dicPos;
    var finishMode = lzmaFinishAny;
    final outSize = this.outSize;
    if (outSize != null) {
      final rem = outSize - _outProcessed;
      if (size >= rem) {
        size = rem;
        if (finishStream) finishMode = lzmaFinishEnd;
      }
    }

    final res = _dec.decodeToDic(
        dicPos + size, _inBuf, _inPos, _inLim - _inPos, finishMode);
    final status = _dec.status;
    lzmaStatus = status;
    final inProcessed = _dec.srcProcessed;
    _inPos += inProcessed;
    _inProcessed += inProcessed;
    final outProcessed = dec.dicPos - dicPos;
    _outProcessed += outProcessed;

    final outFinished = outSize != null && outSize <= _outProcessed;

    final needStop = res != szOk ||
        (inProcessed == 0 && outProcessed == 0) ||
        status == lzmaStatusFinishedWithMark ||
        (!finishStream && outFinished);

    final progress = this.progress;
    if (progress != null && _outProcessed >= _nextProgress) {
      _nextProgress = _outProcessed + _progressStep;
      progress(_inProcessed, _outProcessed);
    }

    if (!needStop) return;
    _stopped = true;
    if (res != szOk) {
      _error = const SevenZipException('LZMA2 data error');
    } else if (status == lzmaStatusFinishedWithMark) {
      if (finishStream && outSize != null && outSize != _outProcessed) {
        _error = const SevenZipException('LZMA2 data error (size)');
      }
    } else if (!finishStream && outFinished) {
      // finished
    } else if (status == lzmaStatusNeedsMoreInput) {
      _error = const SevenZipException(
          'Unexpected end of LZMA2 data', SevenZipError.unexpectedEnd);
    } else {
      _error = const SevenZipException('LZMA2 data error');
    }
  }
}

/// [DecoderFactory] for MethodId.lzma: props are the 5 LZMA bytes.
InStream lzmaDecoder(Uint8List props, List<InStream> inputs, int? outSize,
        CoderContext ctx) =>
    LzmaDecoderStream(props, inputs[0],
        outSize: outSize, progress: ctx.progress);

/// [DecoderFactory] for MethodId.lzma2: props is the 1 byte LZMA2 prop.
InStream lzma2Decoder(
    Uint8List props, List<InStream> inputs, int? outSize, CoderContext ctx) {
  if (props.length != 1) {
    throw const SevenZipException(
        'Unsupported LZMA2 properties', SevenZipError.unsupportedMethod);
  }
  return Lzma2DecoderStream(props[0], inputs[0],
      outSize: outSize, progress: ctx.progress);
}

/// Registers the LZMA and LZMA2 decoders.
void registerLzmaCodecs(Map<int, DecoderFactory> reg) {
  reg[MethodId.lzma] = lzmaDecoder;
  reg[MethodId.lzma2] = lzma2Decoder;
}
