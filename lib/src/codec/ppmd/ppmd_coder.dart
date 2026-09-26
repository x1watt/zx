// Port of CPP/7zip/Compress/PpmdEncoder.cpp and PpmdDecoder.cpp: the 7z
// PPMd (PPMdH with the 7z range coder) coder. Method parameter strings
// ("o=8:mem=24") go through the shared MethodProps.cpp port
// (common/method_props.dart).

import 'dart:typed_data';

import '../../common/method_props.dart';
import '../../io/streams.dart';
import '../codec.dart';
import 'ppmd7.dart';
import 'ppmd7_dec.dart';
import 'ppmd7_enc.dart';

// PpmdEncoder.cpp
const int _kEncBufSize = 1 << 20;
const List<int> _kOrders = [3, 4, 4, 5, 5, 6, 8, 16, 24, 32];

/// Encoder properties: CEncProps (PpmdEncoder.h). -1 (0xFFFFFFFF for the
/// sizes) means "not set".
class PpmdEncProps {
  int memSize = 0xFFFFFFFF;
  int reduceSize = 0xFFFFFFFF;
  int order = -1;

  // CEncProps::Normalize
  void normalize(int level) {
    if (level < 0) level = 5;
    if (level > 9) level = 9;
    if (memSize == 0xFFFFFFFF) memSize = 1 << (level + 19);
    const kMult = 16;
    if (memSize ~/ kMult > reduceSize) {
      for (var i = 16; i < 32; i++) {
        final m = 1 << i;
        if (reduceSize <= m ~/ kMult) {
          if (memSize > m) memSize = m;
          break;
        }
      }
    }
    if (order == -1) order = _kOrders[level];
  }
}

/// The 7z PPMd compressor (NCompress::NPpmd::CEncoder).
class PpmdCompressor implements Compressor {
  final PpmdEncProps _props;

  PpmdCompressor._(this._props);

  /// Order [order] (2..32) and model size [memSize] in bytes (at least
  /// 64 KiB, a multiple of 4), with the defaults of CEncProps::Normalize for
  /// compression [level] (0..9, default 5) and the largest input size
  /// [reduceSize] (shrinks the default model for small inputs).
  factory PpmdCompressor(
      {int level = -1, int? order, int? memSize, int? reduceSize}) {
    final props = <CoderProp>[
      if (level >= 0) CoderProp(CoderPropId.level, PropVariant.ui4(level)),
      if (order != null) CoderProp(CoderPropId.order, PropVariant.ui4(order)),
      if (memSize != null)
        CoderProp(
            CoderPropId.usedMemorySize,
            memSize >= 0 && memSize <= 0xFFFFFFFF
                ? PropVariant.ui4(memSize)
                : PropVariant.ui8(memSize)),
      if (reduceSize != null)
        CoderProp(CoderPropId.reduceSize, PropVariant.ui8(reduceSize)),
    ];
    return PpmdCompressor.fromCoderProps(props);
  }

  /// CEncoder::SetCoderProperties: from coder properties in the order
  /// ICompressSetCoderProperties receives them. Throws
  /// [InvalidArgException] (E_INVALIDARG).
  factory PpmdCompressor.fromCoderProps(Iterable<CoderProp> props) =>
      PpmdCompressor._(_setCoderProperties(props));

  /// Builds the compressor from a 7-Zip method parameter string, the part
  /// after "PPMd:" in -m0=PPMd:o=8:mem=24 ("o=8:mem=24", "mem=16m",
  /// "x9", ...). [level] is the archive level (-mx), applied before the
  /// string like the 7z handler does. Throws [SevenZipException] with
  /// [SevenZipError.unsupported] for invalid parameters (E_INVALIDARG).
  factory PpmdCompressor.parse(String params,
      {int level = -1, int? reduceSize}) {
    final props = <CoderProp>[
      if (level >= 0) CoderProp(CoderPropId.level, PropVariant.ui4(level)),
      ...parseMethodProps(params),
      if (reduceSize != null)
        CoderProp(CoderPropId.reduceSize, PropVariant.ui8(reduceSize)),
    ];
    return PpmdCompressor.fromCoderProps(props);
  }

  int get order => _props.order;
  int get memSize => _props.memSize;

  // CEncoder::WriteCoderProperties
  @override
  Uint8List get props {
    final b = Uint8List(5);
    b[0] = _props.order;
    setUint32LE(b, 1, _props.memSize);
    return b;
  }

  // CEncoder::Code
  @override
  int encode(InStream input, OutStream output, {ProgressCallback? progress}) {
    final inBuf = Uint8List(_kEncBufSize);
    final out = PpmdByteOut(output, 1 << 16);
    final p = Ppmd7();
    p.alloc(_props.memSize);
    p.rcOut = out;
    out.init();

    ppmd7zInitRangeEnc(p);
    p.init(_props.order);

    var processed = 0;
    for (;;) {
      final size = input.read(inBuf, 0, _kEncBufSize);
      if (size == 0) {
        // We don't write EndMark in PPMD-7z.
        ppmd7zFlushRangeEnc(p);
        out.flushBuf();
        output.flush();
        return processed;
      }
      ppmd7zEncodeSymbols(p, inBuf, 0, size);
      processed += size;
      if (progress != null) progress(processed, out.totalProcessed);
    }
  }
}

Never _invalidArg(String msg) => throw InvalidArgException('PPMd: $msg');

// CEncoder::SetCoderProperties
PpmdEncProps _setCoderProperties(Iterable<CoderProp> props) {
  var level = -1;
  final p = PpmdEncProps();
  for (final prop in props) {
    final propId = prop.id;
    final value = prop.value;
    if (propId > CoderPropId.reduceSize) continue;
    if (propId == CoderPropId.reduceSize) {
      // UInt64 compare: a negative Dart int is above 2^63.
      final v = value.intValue;
      if (value.vt == VarType.ui8 && v >= 0 && v < 0xFFFFFFFF) {
        p.reduceSize = v;
      }
      continue;
    }
    if (propId == CoderPropId.usedMemorySize) {
      // here we have selected (4 GiB - 1 KiB) as replacement for (4 GiB)
      // MEM_SIZE.
      const kPpmdDefault4g = 0x100000000 - (1 << 10);
      int v;
      if (value.vt == VarType.ui8) {
        // 21.03 : we support 64-bit values (for 4 GiB value)
        final v64 = value.intValue;
        if (v64 < 0 || v64 > 0x100000000) _invalidArg('mem is too large');
        v = v64 == 0x100000000 ? kPpmdDefault4g : v64;
      } else if (value.vt == VarType.ui4) {
        v = value.intValue;
      } else {
        _invalidArg('invalid mem value');
      }
      if (v > ppmd7MaxMemSize) v = kPpmdDefault4g;
      if (v < (1 << 16) || (v & 3) != 0) _invalidArg('invalid mem value');
      p.memSize = v;
      continue;
    }
    if (value.vt != VarType.ui4) _invalidArg('invalid property value');
    final v = value.intValue;
    switch (propId) {
      case CoderPropId.order:
        if (v < 2 || v > 32) _invalidArg('order must be 2..32');
        p.order = v;
      case CoderPropId.numThreads:
        break;
      case CoderPropId.level:
        level = v >= 0x80000000 ? v - 0x100000000 : v; // (int)v
      default:
        _invalidArg('unsupported property');
    }
  }
  p.normalize(level);
  return p;
}

// Decoder

// PpmdDecoder.cpp
const int _kStatusNeedInit = 0;
const int _kStatusNormal = 1;
const int _kStatusFinishedWithMark = 2;
const int _kStatusError = 3;

/// The 7z PPMd decoder as a pull stream (NCompress::NPpmd::CDecoder, the
/// ISequentialInStream::Read path). [outSize] should be known for 7z PPMd
/// streams (they have no end marker); without it the stream ends only at
/// an end marker, like the C decoder.
class PpmdDecoderStream implements InStream {
  final Ppmd7 _ppmd = Ppmd7();
  final PpmdByteIn _inStream;
  final int _order;

  /// FinishStream (ICompressSetFinishMode). 7z extraction sets it.
  final bool finishStream;
  final bool _outSizeDefined;
  final int _outSize;
  int _processedSize = 0;
  int _status = _kStatusNeedInit;
  SevenZipException? _res;

  // SetDecoderProperties2 + SetOutStreamSize
  PpmdDecoderStream(Uint8List props, InStream input, int? outSize,
      {this.finishStream = true})
      : _inStream = PpmdByteIn(input, 1 << 16),
        _order = props.isNotEmpty ? props[0] : 0,
        _outSizeDefined = outSize != null,
        _outSize = outSize ?? 0 {
    if (props.length < 5) {
      throw const SevenZipException(
          'PPMd: invalid properties', SevenZipError.unsupportedMethod);
    }
    final memSize = getUint32LE(props, 1);
    if (_order < ppmd7MinOrder ||
        _order > ppmd7MaxOrder ||
        memSize < ppmd7MinMemSize ||
        memSize > ppmd7MaxMemSize) {
      throw const SevenZipException(
          'PPMd: unsupported properties', SevenZipError.unsupportedMethod);
    }
    _ppmd.alloc(memSize);
    _ppmd.rcIn = _inStream;
  }

  /// Unpacked bytes produced so far.
  int get processedSize => _processedSize;

  /// Packed bytes consumed so far (GetInStreamProcessedSize).
  int get inProcessedSize => _inStream.totalProcessed;

  SevenZipException _error() {
    _status = _kStatusError;
    return _res = const SevenZipException('PPMd: data error');
  }

  // CHECK_EXTRA_ERROR. A failing input stream throws by itself in Dart, so
  // only the end of input is left here.
  bool _checkExtraError() {
    if (_inStream.extra) {
      _status = _kStatusError;
      _res = const SevenZipException(
          'PPMd: unexpected end of input', SevenZipError.data);
      return true;
    }
    return false;
  }

  // CDecoder::CodeSpec. Returns null for S_OK.
  SevenZipException? _codeSpec(Uint8List memStream, int off, int size) {
    if (_res != null) return _res;

    switch (_status) {
      case _kStatusFinishedWithMark:
        return null;
      case _kStatusError:
        return _res ?? const SevenZipException('PPMd: data error');
      case _kStatusNeedInit:
        _inStream.init();
        if (!ppmd7zRangeDecInit(_ppmd)) return _error();
        if (_checkExtraError()) return _res;
        _status = _kStatusNormal;
        _ppmd.init(_order);
      default:
        break;
    }

    if (_outSizeDefined) {
      final rem = _outSize - _processedSize;
      if (size > rem) size = rem;
    }

    var sym = 0;
    {
      final p = _ppmd;
      final inp = _inStream;
      var buf = off;
      final lim = off + size;
      for (; buf != lim; buf++) {
        sym = ppmd7zDecodeSymbol(p);
        if (inp.extra || sym < 0) break;
        memStream[buf] = sym;
      }
      _processedSize += buf - off;
    }

    if (_checkExtraError()) return _res;

    if (sym >= 0) {
      if (!finishStream ||
          !_outSizeDefined ||
          _outSize != _processedSize ||
          _ppmd.rcCode == 0) {
        return null;
      }
    }

    if (sym != ppmd7SymEnd || _ppmd.rcCode != 0) return _error();

    _status = _kStatusFinishedWithMark;
    return null;
  }

  // CDecoder::Read
  @override
  int read(Uint8List buf, int off, int len) {
    if (len <= 0) return 0;
    final startPos = _processedSize;
    final res = _codeSpec(buf, off, len);
    final n = _processedSize - startPos;
    if (res != null) {
      // Hand out the bytes decoded before the error first; the next call
      // reports it (CodeSpec returns _res at once).
      if (n > 0) return n;
      throw res;
    }
    return n;
  }
}

/// DecoderFactory for MethodId.ppmd.
InStream ppmdDecoder(Uint8List props, List<InStream> inputs, int? outSize,
        CoderContext ctx) =>
    PpmdDecoderStream(props, inputs[0], outSize);

/// Registers the PPMd decoder (PpmdRegister.cpp).
void registerPpmdCodecs(Map<int, DecoderFactory> reg) {
  reg[MethodId.ppmd] = ppmdDecoder;
}
