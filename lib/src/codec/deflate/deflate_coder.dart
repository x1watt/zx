// The Deflate and Deflate64 coders of the port: the [Compressor] and the
// pull decoders over the zlib ports (deflate.dart, inflate.dart,
// infback9.dart), their registration, and in memory helpers.
//
// The compressor feeds zlib's deflate() the way zpipe.c does: input in
// chunks of [deflateChunk] bytes with Z_NO_FLUSH, then Z_FINISH, with an
// output buffer of [deflateChunk] bytes. At every level and strategy the
// output is then byte for byte the one of zlib 1.3.1 driven the same way
// (only level 0, the stored blocks, depends on the buffer sizes at all).

import 'dart:typed_data';

import '../../common/method_props.dart';
import '../../io/streams.dart';
import '../codec.dart';
import 'deflate.dart';
import 'infback9.dart';
import 'inflate.dart';
import 'zutil.dart';

/// Input and output chunk size of [DeflateCompressor.encode].
const int deflateChunk = 1 << 16;

const int _progressStep = 1 << 20;

/// Raw deflate compressor (zlib's deflate with windowBits -15).
class DeflateCompressor implements Compressor {
  /// zlib compression level, 0 (stored) to 9.
  final int level;

  /// zlib strategy ([ZStrategy]).
  final int strategy;

  /// zlib memLevel, 1 to 9 (8 is the zlib default).
  final int memLevel;

  DeflateCompressor(
      {int level = 6,
      this.strategy = ZStrategy.defaultStrategy,
      this.memLevel = zDefMemLevel})
      : level = level < 0 ? 6 : (level > 9 ? 9 : level);

  /// From 7-Zip coder properties (the -m switch of the Deflate method):
  /// x (level) is the zlib level. fb (fast bytes), pass (passes), mc
  /// (match finder cycles) and a (algorithm) tune 7-Zip's own deflate
  /// encoder, which this port does not have; they are accepted and ignored,
  /// so that the output stays the one of zlib at that level. The other
  /// properties (mt, reduce, expect...) are ignored too.
  factory DeflateCompressor.fromCoderProps(List<CoderProp> props) {
    var level = 6;
    for (final p in props) {
      if (p.id == CoderPropId.level) {
        final v = p.value;
        if (v.vt == VarType.ui4 || v.vt == VarType.ui8) level = v.intValue;
      }
    }
    return DeflateCompressor(level: level);
  }

  /// Deflate has no coder properties.
  @override
  Uint8List get props => Uint8List(0);

  @override
  int encode(InStream input, OutStream output, {ProgressCallback? progress}) {
    final s = DeflateState(
        level: level, memLevel: memLevel, strategy: strategy);
    final inBuf = Uint8List(deflateChunk);
    final outBuf = Uint8List(deflateChunk);
    var total = 0;
    var nextProgress = _progressStep;
    int flush;
    do {
      final n = readFully(input, inBuf, 0, deflateChunk);
      total += n;
      flush = n < deflateChunk ? ZFlush.finish : ZFlush.noFlush;
      s.nextIn = inBuf;
      s.nextInPos = 0;
      s.availIn = n;
      // run deflate() on input until output buffer not full, finish
      // compression if all of source has been read in
      do {
        s.nextOut = outBuf;
        s.nextOutPos = 0;
        s.availOut = deflateChunk;
        s.deflate(flush);
        final have = deflateChunk - s.availOut;
        if (have != 0) output.write(outBuf, 0, have);
      } while (s.availOut == 0);
      if (progress != null && total >= nextProgress) {
        nextProgress = total + _progressStep;
        progress(total, s.totalOut);
      }
    } while (flush != ZFlush.finish);
    s.deflateEnd();
    output.flush();
    return total;
  }
}

/// Compresses [data] to raw deflate in one call (deflate() with the whole
/// input and a deflateBound() output buffer, Z_FINISH).
Uint8List deflateBytes(Uint8List data,
    {int level = 6, int strategy = ZStrategy.defaultStrategy}) {
  final s = DeflateState(level: level, strategy: strategy);
  final out = Uint8List(s.deflateBound(data.length));
  s.nextIn = data;
  s.nextInPos = 0;
  s.availIn = data.length;
  s.nextOut = out;
  s.nextOutPos = 0;
  s.availOut = out.length;
  final ret = s.deflate(ZFlush.finish);
  if (ret != ZResult.streamEnd) {
    throw SevenZipException('deflate failed ($ret)');
  }
  return Uint8List.sublistView(out, 0, s.totalOut);
}

/// Decompresses raw deflate [data]. Throws [SevenZipException] for invalid
/// or truncated data. Bytes after the end of the deflate stream are
/// ignored.
Uint8List inflateBytes(Uint8List data) =>
    readAll(InflateDecoderStream(MemoryInStream(data)));

/// Decompresses raw Deflate64 [data], as [inflateBytes].
Uint8List inflate64Bytes(Uint8List data) =>
    readAll(Deflate64DecoderStream(MemoryInStream(data)));

/// Pull raw inflate decoder. Reads its input in chunks, so it can read
/// past the end of the deflate stream: after the end ([isFinished]),
/// [unusedInput] holds the bytes read but not used, and [inProcessed] is
/// the size of the deflate stream.
///
/// With [outSize] the stream returns at most that many bytes and fails
/// with [SevenZipError.unexpectedEnd] when the deflate stream ends before;
/// the deflate stream is not read past [outSize] bytes of output.
class InflateDecoderStream implements InStream {
  final InStream _input;
  final int? outSize;
  final ProgressCallback? progress;
  final InflateState _z = InflateState();
  final Uint8List _inBuf;
  bool _inEnd = false;
  bool _finished = false;
  SevenZipException? _error;

  // internal output for small reads
  final Uint8List _outBuf = Uint8List(1 << 16);
  int _outPos = 0;
  int _outLim = 0;
  int _outProcessed = 0; // bytes handed out
  int _nextProgress = _progressStep;

  InflateDecoderStream(this._input,
      {this.outSize, this.progress, int inBufSize = 1 << 16})
      : _inBuf = Uint8List(inBufSize) {
    _z.nextIn = _inBuf;
  }

  /// Size of the deflate stream consumed so far (all of it once
  /// [isFinished]).
  int get inProcessed => _z.totalIn;

  /// Unpacked bytes returned so far.
  int get outProcessed => _outProcessed;

  /// True when the end of the deflate stream was reached.
  bool get isFinished => _finished;

  /// Bytes read from the input but not used by the decoder. After the end
  /// of the deflate stream they belong to whatever follows it (a gzip
  /// trailer, the next zip item...).
  Uint8List get unusedInput =>
      Uint8List.sublistView(_inBuf, _z.nextInPos, _z.nextInPos + _z.availIn);

  // Runs inflate() into dst[off, off+len). Returns the bytes written; 0
  // only at the end or on error (then _finished or _error is set).
  int _run(Uint8List dst, int off, int len) {
    final z = _z;
    z.nextOut = dst;
    z.nextOutPos = off;
    z.availOut = len;
    for (;;) {
      if (z.availIn == 0 && !_inEnd) {
        final n = _input.read(_inBuf, 0, _inBuf.length);
        z.nextInPos = 0;
        z.availIn = n;
        if (n == 0) _inEnd = true;
      }
      final ret = z.inflate(ZFlush.noFlush);
      final produced = len - z.availOut;
      if (ret == ZResult.streamEnd) {
        _finished = true;
        return produced;
      }
      if (ret == ZResult.dataError) {
        _error = SevenZipException('Deflate data error: ${z.msg}');
        return produced;
      }
      if (ret == ZResult.bufError && _inEnd && z.availIn == 0) {
        _error = const SevenZipException(
            'Unexpected end of deflate data', SevenZipError.unexpectedEnd);
        return produced;
      }
      if (ret != ZResult.ok && ret != ZResult.bufError) {
        _error = SevenZipException('Deflate error ($ret)');
        return produced;
      }
      if (produced != 0) return produced;
    }
  }

  @override
  int read(Uint8List buf, int off, int len) {
    if (len <= 0) return 0;
    final limit = outSize;
    if (limit != null) {
      final rem = limit - _outProcessed;
      if (rem <= 0) return 0;
      if (len > rem) len = rem;
    }
    int n;
    if (_outPos < _outLim) {
      n = _outLim - _outPos;
      if (n > len) n = len;
      buf.setRange(off, off + n, _outBuf, _outPos);
      _outPos += n;
    } else {
      if (_finished) return _atEnd();
      final e = _error;
      if (e != null) throw e;
      if (len >= _outBuf.length ~/ 4) {
        n = _run(buf, off, len);
      } else {
        final got = _run(_outBuf, 0, _outBuf.length);
        _outPos = 0;
        _outLim = got;
        n = got < len ? got : len;
        buf.setRange(off, off + n, _outBuf, 0);
        _outPos = n;
      }
      if (n == 0) {
        if (_finished) return _atEnd();
        throw _error!;
      }
    }
    _outProcessed += n;
    final p = progress;
    if (p != null && _outProcessed >= _nextProgress) {
      _nextProgress = _outProcessed + _progressStep;
      p(_z.totalIn, _outProcessed);
    }
    return n;
  }

  int _atEnd() {
    final limit = outSize;
    if (limit != null && _outProcessed < limit) {
      throw const SevenZipException(
          'Unexpected end of deflate data', SevenZipError.unexpectedEnd);
    }
    return 0;
  }
}

/// Pull raw Deflate64 decoder, with the same [unusedInput] / [inProcessed]
/// and [outSize] behavior as [InflateDecoderStream].
class Deflate64DecoderStream implements InStream {
  final int? outSize;
  final ProgressCallback? progress;
  final Inflate9 _z;
  bool _finished = false;
  SevenZipException? _error;
  int _outPos = 0; // read position in the window
  int _outLim = 0; // end of the output available in the window
  bool _windowPending = false; // the full window is being handed out
  int _outProcessed = 0;
  int _nextProgress = _progressStep;

  Deflate64DecoderStream(InStream input,
      {this.outSize, this.progress, int inBufSize = 1 << 16})
      : _z = Inflate9(input, inBufSize: inBufSize);

  /// Size of the Deflate64 stream consumed so far.
  int get inProcessed => _z.inTotal - _z.have;

  /// Unpacked bytes returned so far.
  int get outProcessed => _outProcessed;

  /// True when the end of the stream was reached.
  bool get isFinished => _finished;

  /// Bytes read from the input but not used by the decoder.
  Uint8List get unusedInput =>
      Uint8List.sublistView(_z.inBuf, _z.next, _z.next + _z.have);

  void _step() {
    if (_windowPending) {
      _z.windowTaken();
      _windowPending = false;
    }
    final start = _z.put;
    final ret = _z.decode();
    switch (ret) {
      case Inflate9.windowFull:
        _outPos = start;
        _outLim = _z.put;
        _windowPending = true;
      case Inflate9.streamEnd:
        _outPos = start;
        _outLim = _z.put;
        _finished = true;
      case Inflate9.bufError:
        _outPos = start;
        _outLim = _z.put;
        _error = const SevenZipException(
            'Unexpected end of Deflate64 data', SevenZipError.unexpectedEnd);
      default:
        _outPos = start;
        _outLim = _z.put;
        _error = SevenZipException('Deflate64 data error: ${_z.msg}');
    }
  }

  @override
  int read(Uint8List buf, int off, int len) {
    if (len <= 0) return 0;
    final limit = outSize;
    if (limit != null) {
      final rem = limit - _outProcessed;
      if (rem <= 0) return 0;
      if (len > rem) len = rem;
    }
    while (_outPos >= _outLim) {
      if (_finished) {
        if (limit != null && _outProcessed < limit) {
          throw const SevenZipException('Unexpected end of Deflate64 data',
              SevenZipError.unexpectedEnd);
        }
        return 0;
      }
      final e = _error;
      if (e != null) throw e;
      _step();
    }
    var n = _outLim - _outPos;
    if (n > len) n = len;
    buf.setRange(off, off + n, _z.window, _outPos);
    _outPos += n;
    _outProcessed += n;
    final p = progress;
    if (p != null && _outProcessed >= _nextProgress) {
      _nextProgress = _outProcessed + _progressStep;
      p(inProcessed, _outProcessed);
    }
    return n;
  }
}

/// [DecoderFactory] for MethodId.deflate (raw deflate, no properties).
InStream deflateDecoder(Uint8List props, List<InStream> inputs, int? outSize,
        CoderContext ctx) =>
    InflateDecoderStream(inputs[0], outSize: outSize, progress: ctx.progress);

/// [DecoderFactory] for MethodId.deflate64 (raw Deflate64).
InStream deflate64Decoder(Uint8List props, List<InStream> inputs,
        int? outSize, CoderContext ctx) =>
    Deflate64DecoderStream(inputs[0],
        outSize: outSize, progress: ctx.progress);

/// Registers the Deflate and Deflate64 decoders.
void registerDeflateCodecs(Map<int, DecoderFactory> reg) {
  reg[MethodId.deflate] = deflateDecoder;
  reg[MethodId.deflate64] = deflate64Decoder;
}
