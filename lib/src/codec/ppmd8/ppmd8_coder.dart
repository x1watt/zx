// The zip PPMd coder (zip method 98, PKWARE APPNOTE 4.4.5 and 5.10): PPMd
// var.I rev.1 (Ppmd8) after a 2-byte little-endian parameter word:
//
//   bits 0-3: model order - 1
//   bits 4-11: model memory size in MB - 1
//   bits 12-15: restoration method (0 = restart, 1 = cut off)
//
// The packed stream ends with the end marker symbol (-1) and the 4 flush
// bytes of the range encoder, as 7-Zip writes it and as libarchive's zip
// reader (archive_read_support_format_zip.c) expects it.
//
// The decoder follows the way libarchive drives Ppmd8 (header, range
// decoder init, Ppmd8_Init, Ppmd8_DecodeSymbol until the end marker). The
// encoder defaults (order, memory, restoration method per level and the
// memory reduction for small inputs) are the values 7-Zip 23.01 writes with
// `7z a -tzip -mm=PPMd -mx=N`, measured from its archives:
//
//   level:   1  2  3  4  5  6   7   8   9
//   order:   4  5  6  7  8  9  10  11  12   (level + 3)
//   mem MB:  1  2  4  8 16 32  64 128 256   (1 << (level + 19) bytes)
//   restore: 0  0  0  0  0  0   1   1   1   (cut off from level 7)
//
// Level 0 gives the level 1 values. The memory is lowered for small inputs
// like the 7z PPMd encoder does (the smallest power of 2, at least 1 MB, not
// below 16 times the input size) and is rounded down to whole MB.

import 'dart:typed_data';

import '../../common/method_props.dart';
import '../../io/streams.dart';
import '../codec.dart';
import 'ppmd8.dart';
import 'ppmd8_dec.dart';
import 'ppmd8_enc.dart';

const int _kBufSize = 1 << 20;
const int _kMinMemSize = 1 << 20;
const int _kMaxMemSize = 256 << 20;

/// Encoder parameters. -1 means "not set".
class _Ppmd8EncProps {
  int order = -1;
  int memSize = -1;
  int restoreMethod = -1;
  int reduceSize = -1;

  void normalize(int level) {
    if (level < 0) level = 5;
    if (level == 0) level = 1;
    if (level > 9) level = 9;
    if (memSize == -1) memSize = 1 << (level + 19);
    const kMult = 16;
    if (reduceSize >= 0 && memSize ~/ kMult > reduceSize) {
      for (var i = 16; i < 32; i++) {
        final m = 1 << i;
        if (reduceSize <= m ~/ kMult) {
          if (memSize > m) memSize = m;
          break;
        }
      }
    }
    memSize &= ~(_kMinMemSize - 1);
    if (memSize < _kMinMemSize) memSize = _kMinMemSize;
    if (order == -1) order = level + 3;
    if (restoreMethod == -1) {
      restoreMethod =
          level >= 7 ? ppmd8RestoreMethodCutOff : ppmd8RestoreMethodRestart;
    }
  }
}

Never _invalidArg(String msg) => throw InvalidArgException('PPMd: $msg');

_Ppmd8EncProps _setCoderProperties(Iterable<CoderProp> props) {
  var level = -1;
  final p = _Ppmd8EncProps();
  for (final prop in props) {
    final value = prop.value;
    final isInt = value.vt == VarType.ui4 || value.vt == VarType.ui8;
    final v = value.intValue;
    switch (prop.id) {
      case CoderPropId.level:
        if (value.vt != VarType.ui4) _invalidArg('invalid level');
        level = v >= 0x80000000 ? v - 0x100000000 : v; // (int)v
      case CoderPropId.order:
        if (!isInt || v < ppmd8MinOrder || v > ppmd8MaxOrder) {
          _invalidArg('order must be 2..16');
        }
        p.order = v;
      case CoderPropId.usedMemorySize:
        if (!isInt || v < _kMinMemSize || v > _kMaxMemSize) {
          _invalidArg('mem must be 1 MB..256 MB');
        }
        p.memSize = v;
      case CoderPropId.algorithm:
        if (!isInt ||
            (v != ppmd8RestoreMethodRestart && v != ppmd8RestoreMethodCutOff)) {
          _invalidArg('restore method must be 0 or 1');
        }
        p.restoreMethod = v;
      case CoderPropId.reduceSize:
        if (isInt && v >= 0) p.reduceSize = v;
      default:
        break; // numThreads and the others do not apply
    }
  }
  p.normalize(level);
  return p;
}

/// The zip PPMd (method 98) compressor.
class Ppmd8ZipCompressor implements Compressor {
  final _Ppmd8EncProps _props;

  Ppmd8ZipCompressor._(this._props);

  /// Compression [level] 0..9 (default 5) sets the defaults of [order]
  /// (2..16), [memSize] (bytes, 1 MB..256 MB, rounded down to whole MB) and
  /// [restoreMethod] (0 restart, 1 cut off). [reduceSize] is the input size
  /// when known: it lowers the memory for small inputs as 7-Zip does.
  /// Throws [InvalidArgException] for bad values.
  factory Ppmd8ZipCompressor(
      {int level = 5,
      int? order,
      int? memSize,
      int? restoreMethod,
      int? reduceSize}) {
    final props = <CoderProp>[
      CoderProp(CoderPropId.level, PropVariant.ui4(level & 0xFFFFFFFF)),
      if (order != null) CoderProp(CoderPropId.order, PropVariant.ui8(order)),
      if (memSize != null)
        CoderProp(CoderPropId.usedMemorySize, PropVariant.ui8(memSize)),
      if (restoreMethod != null)
        CoderProp(CoderPropId.algorithm, PropVariant.ui8(restoreMethod)),
      if (reduceSize != null)
        CoderProp(CoderPropId.reduceSize, PropVariant.ui8(reduceSize)),
    ];
    return Ppmd8ZipCompressor.fromCoderProps(props);
  }

  /// From coder properties: level, order, usedMemorySize, algorithm (the
  /// restoration method) and reduceSize; the others (numThreads...) are
  /// ignored. Throws [InvalidArgException] for bad values.
  factory Ppmd8ZipCompressor.fromCoderProps(Iterable<CoderProp> props) =>
      Ppmd8ZipCompressor._(_setCoderProperties(props));

  int get order => _props.order;

  /// Model memory in bytes (a whole number of MB).
  int get memSize => _props.memSize;
  int get restoreMethod => _props.restoreMethod;

  /// Zip PPMd has no coder properties outside the packed data.
  @override
  Uint8List get props => Uint8List(0);

  @override
  int encode(InStream input, OutStream output, {ProgressCallback? progress}) {
    final order = _props.order;
    final memMB = _props.memSize >> 20;
    final restore = _props.restoreMethod;

    final out = PpmdByteOut(output, 1 << 16);
    out.init();
    final w = (order - 1) | ((memMB - 1) << 4) | (restore << 12);
    out.writeByte(w & 0xFF);
    out.writeByte(w >> 8);

    final p = Ppmd8();
    p.alloc(memMB << 20);
    p.rcOut = out;
    ppmd8InitRangeEnc(p);
    p.init(order, restore);

    final inBuf = Uint8List(_kBufSize);
    var processed = 0;
    for (;;) {
      final size = input.read(inBuf, 0, _kBufSize);
      if (size == 0) break;
      ppmd8EncodeSymbols(p, inBuf, 0, size);
      processed += size;
      if (progress != null) progress(processed, out.totalProcessed);
    }
    ppmd8EncodeSymbol(p, -1); // end marker
    ppmd8FlushRangeEnc(p);
    out.flushBuf();
    output.flush();
    p.free();
    return processed;
  }
}

const int _kStatusNeedInit = 0;
const int _kStatusNormal = 1;
const int _kStatusFinished = 2;
const int _kStatusError = 3;

/// The zip PPMd (method 98) decoder as a pull stream over the packed data
/// (which starts with the 2-byte parameter word). With [outSize] it stops
/// after that many bytes (an end marker after them is not read); without it
/// the stream ends at the end marker. Throws [SevenZipException]: with
/// [SevenZipError.unsupportedMethod] for invalid parameters, otherwise for
/// data errors and truncated input.
class Ppmd8ZipDecoder implements InStream {
  final Ppmd8 _ppmd = Ppmd8();
  final PpmdByteIn _in;
  final int? _outSize;
  int _processed = 0;
  int _status = _kStatusNeedInit;
  SevenZipException? _error;

  Ppmd8ZipDecoder(InStream packed, {int? outSize})
      : _in = PpmdByteIn(packed, 1 << 16),
        _outSize = outSize;

  /// Unpacked bytes produced so far.
  int get processedSize => _processed;

  /// Packed bytes consumed so far (the parameter word included).
  int get inProcessedSize => _in.totalProcessed;

  Never _fail(SevenZipException e) {
    _status = _kStatusError;
    _ppmd.free();
    throw _error = e;
  }

  void _init() {
    final inp = _in;
    inp.init();
    final w = inp.readByte() | (inp.readByte() << 8);
    if (inp.extra) {
      _fail(const SevenZipException(
          'PPMd: unexpected end of input', SevenZipError.unexpectedEnd));
    }
    final order = (w & 15) + 1;
    final memMB = ((w >> 4) & 0xFF) + 1;
    final restore = w >> 12;
    if (order < ppmd8MinOrder || restore >= ppmd8RestoreMethodUnsupported) {
      _fail(const SevenZipException(
          'PPMd: unsupported parameters', SevenZipError.unsupportedMethod));
    }
    _ppmd.alloc(memMB << 20);
    _ppmd.rcIn = inp;
    if (!ppmd8InitRangeDec(_ppmd)) {
      _fail(const SevenZipException('PPMd: data error'));
    }
    if (inp.extra) {
      _fail(const SevenZipException(
          'PPMd: unexpected end of input', SevenZipError.unexpectedEnd));
    }
    _ppmd.init(order, restore);
    _status = _kStatusNormal;
  }

  @override
  int read(Uint8List buf, int off, int len) {
    if (len <= 0) return 0;
    switch (_status) {
      case _kStatusFinished:
        return 0;
      case _kStatusError:
        throw _error!;
      case _kStatusNeedInit:
        if (_outSize == 0) {
          _status = _kStatusFinished;
          return 0;
        }
        _init();
    }

    final outSize = _outSize;
    if (outSize != null) {
      final rem = outSize - _processed;
      if (len > rem) len = rem;
    }

    final p = _ppmd;
    final inp = _in;
    var sym = 0;
    var i = off;
    final lim = off + len;
    for (; i != lim; i++) {
      sym = ppmd8DecodeSymbol(p);
      if (inp.extra || sym < 0) break;
      buf[i] = sym;
    }
    final n = i - off;
    _processed += n;

    SevenZipException? err;
    if (inp.extra) {
      err = const SevenZipException(
          'PPMd: unexpected end of input', SevenZipError.unexpectedEnd);
    } else if (sym == ppmd8SymError) {
      err = const SevenZipException('PPMd: data error');
    } else if (sym == ppmd8SymEnd) {
      if (outSize != null && _processed != outSize) {
        err = const SevenZipException(
            'PPMd: end marker before the end of data', SevenZipError.data);
      } else {
        _status = _kStatusFinished;
        _ppmd.free();
      }
    } else if (outSize != null && _processed == outSize) {
      _status = _kStatusFinished;
      _ppmd.free();
    }

    if (err != null) {
      // Hand out the bytes decoded before the error first; the next call
      // reports it.
      if (n > 0) {
        _status = _kStatusError;
        _error = err;
        _ppmd.free();
        return n;
      }
      _fail(err);
    }
    return n;
  }
}
