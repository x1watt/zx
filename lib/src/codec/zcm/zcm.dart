// zcm: a variable strength context mixing codec (experimental).
//
// Levels 1 to 9 go from a fast order-n mixer to a paq8/cmix class model
// set. The model designs, state tables and parameters come from paq8 and
// lpaq (Matt Mahoney), paq8px (Matt Mahoney, Alexander Rhatushnyak, Serge
// Osnach, Jan Ondrus, Marcio Pais, Andrew Epstein, Zoltan Gotthardt and
// others), cmix (Byron Knoll) and PPMd (Dmitry Shkarin); see the README
// credits. The code is written for this package.
//
// Determinism. A stream written on one machine must decode on every
// other, so the model must compute exactly the same probabilities:
//   * every paq-style component (states, StateMaps, APMs, the mixers and
//     their weights) is integer arithmetic on Dart's 64-bit ints, with
//     explicit masks where 32-bit wraparound is meant;
//   * the few components that use floating point (the LSTM and the PPMd
//     byte distribution of level 9) use doubles with +, -, *, / and
//     comparisons only, which IEEE 754 defines exactly (round to nearest
//     even, no fused multiply-add in Dart), and exp, tanh, the logistic
//     function and sqrt built from those (zcm_math.dart); dart:math is
//     never used;
//   * tables (squash, stretch, ilog, reciprocals) are built with integers;
//   * everything the model depends on (level, memory budget, flags) is
//     stored in the stream header, so the decoder builds the same tables;
//   * the golden hashes of test/zcm_test.dart pin the output bytes.
// The 64-bit integer arithmetic assumes the Dart native VM (not the web).
//
// Stream layout (all integers little endian, vint = unsigned LEB128):
//   'z' 'c' 'm'           magic
//   u8  version           1 (zcm 1.0; zcm is experimental, so the
//                         version is not bumped when the output changes)
//   u8  level             1..9
//   u8  flags             bit 0: independent segments, bit 1: LSTM,
//                         bit 2: data type detection, bit 3: x86 E8/E9
//                         transform on exe segments, bit 4: the English
//                         dictionary transform on text segments
//   vint memoryMiB        model memory budget (all table sizes follow it)
//   vint segmentSize      bytes per independent segment (0 when solid)
//   with the LSTM flag:   vint cells, u8 layers, vint horizon
//   vint originalSize + 1 (0 when unknown)
//   chunks:
//     vint rawLen         0 ends the stream
//     u32  crc32          of the raw bytes of the chunk
//     vint packedLen
//     packedLen bytes     arithmetic coded bits (16 bit probabilities):
//                         with detection, the chunk is a series of
//                         segments (zcm_detect.dart), each introduced by
//                         its type (4 bits), length (32 bits), info (32
//                         bits, image and audio types only) and for text
//                         with the dictionary flag one bit (1: the
//                         segment is coded transformed, then its
//                         transformed length in 32 bits), all with
//                         p = 1/2; then the bits of the (transformed)
//                         bytes, most significant first, each with the
//                         model's probability. Without detection the
//                         chunk is one binary segment with no header.
// Solid streams keep one model across all chunks (chunks are framing, at
// most 16 MiB each); with independent segments every chunk is a segment
// with a fresh model, so segments can be coded in parallel.
//
// Props (for a container): the header bytes after the magic, without the
// original size (version, level, flags, memoryMiB, segmentSize and the
// LSTM size). The decoder checks that they match the stream header.

import 'dart:typed_data';

import '../../common/method_props.dart';
import '../../io/streams.dart';
import '../../sync_pool.dart';
import '../../util/crc.dart';
import '../codec.dart';
import 'zcm_audio.dart';
import 'zcm_coder.dart';
import 'zcm_detect.dart';
import 'zcm_dict.dart';
import 'zcm_predictor.dart';

/// Format version written by this code.
const int zcmVersion = 1;

/// Experimental codec id for the zx registry (section 11 of zx-format.md).
const int zcmCodecId = 0x10000;

/// Bytes per detection block (and the segment size unit of the parallel
/// coder).
const int zcmBlockSize = zcmDetectBlockSize;

/// Largest chunk of a solid stream.
const int zcmSolidChunk = 1 << 24;

const int _fIndependent = 1;
const int _fLstm = 2;
const int _fDetect = 4;
const int _fE8E9 = 8;
const int _fDict = 16;

/// Options of the zcm codec.
final class ZcmOptions {
  /// 1 (fastest) to 9 (cmix class, slowest).
  final int level;

  /// Model memory budget in MiB; 0 picks the level's default.
  final int memoryMiB;

  /// Adds the LSTM byte model (level 9 only).
  final bool lstm;

  /// LSTM cells per layer, layers and training horizon (bytes). The
  /// defaults are a small network (a few KB/s); cmix uses 200, 2 and 100.
  final int lstmCells;
  final int lstmLayers;
  final int lstmHorizon;

  /// Bytes per independent segment; 0 compresses the input as one solid
  /// stream. Segments lose some ratio (each starts with an empty model)
  /// and let zcmCompressParallel use several isolates.
  final int segmentSize;

  /// Detects text, binary, exe, image and audio data to choose models.
  final bool detect;

  /// Codes English text through the dictionary transform (zcm_dict.dart)
  /// when that is smaller (with [detect] only).
  final bool dictionary;

  const ZcmOptions(
      {this.level = 4,
      this.memoryMiB = 0,
      this.lstm = false,
      this.lstmCells = 64,
      this.lstmLayers = 1,
      this.lstmHorizon = 20,
      this.segmentSize = 0,
      this.detect = true,
      this.dictionary = true});

  /// Named levels: fast (2), normal (4), max (6), ultra (8), cmix (9).
  factory ZcmOptions.named(String name,
      {int memoryMiB = 0, int segmentSize = 0}) {
    final level = zcmLevelByName(name);
    if (level == null) {
      throw InvalidArgException('zcm: unknown level "$name"');
    }
    return ZcmOptions(
        level: level,
        memoryMiB: memoryMiB,
        lstm: level == 9,
        segmentSize: segmentSize);
  }

  ZcmOptions copyWith(
          {int? level,
          int? memoryMiB,
          bool? lstm,
          int? lstmCells,
          int? lstmLayers,
          int? lstmHorizon,
          int? segmentSize,
          bool? detect,
          bool? dictionary}) =>
      ZcmOptions(
          level: level ?? this.level,
          memoryMiB: memoryMiB ?? this.memoryMiB,
          lstm: lstm ?? this.lstm,
          lstmCells: lstmCells ?? this.lstmCells,
          lstmLayers: lstmLayers ?? this.lstmLayers,
          lstmHorizon: lstmHorizon ?? this.lstmHorizon,
          segmentSize: segmentSize ?? this.segmentSize,
          detect: detect ?? this.detect,
          dictionary: dictionary ?? this.dictionary);

  @override
  String toString() =>
      'ZcmOptions(level: $level, memoryMiB: $memoryMiB, lstm: $lstm'
      '${lstm ? ' $lstmCells/$lstmLayers/$lstmHorizon' : ''}, '
      'segmentSize: $segmentSize, detect: $detect, dictionary: $dictionary)';
}

/// Level of a name (or of a digit string), null when unknown.
int? zcmLevelByName(String name) {
  switch (name.toLowerCase()) {
    case 'fast':
      return 2;
    case 'normal':
      return 4;
    case 'max':
      return 6;
    case 'ultra':
      return 8;
    case 'cmix':
      return 9;
  }
  final n = int.tryParse(name);
  return n != null && n >= 1 && n <= 9 ? n : null;
}

/// Default memory budget of a level (MiB).
int zcmDefaultMemoryMiB(int level) =>
    const [0, 32, 48, 96, 160, 256, 512, 1024, 2048, 3072][level];

/// Smallest budget a stream may declare (MiB).
const int zcmMinMemoryMiB = 4;

/// Largest budget a stream may declare (MiB), 64 GiB.
const int zcmMaxMemoryMiB = 64 << 10;

/// Bytes of tables per input byte that saturate a level: the hashed
/// context maps of the strong levels (a hundred and more contexts, three
/// bucket lookups per byte each) keep gaining up to about a kilobyte per
/// input byte (docs/performance.md).
int zcmTableBytesPerInputByte(int level) =>
    const [0, 64, 64, 64, 64, 64, 256, 1024, 2048, 2048][level];

/// The budget used for an input of [inputSize] bytes (when known): tables
/// much larger than the input only cost time, so small inputs get a
/// smaller budget ([zcmTableBytesPerInputByte] plus 8 MiB). The result is
/// stored in the stream.
int zcmEffectiveMemoryMiB(ZcmOptions o, int? inputSize) {
  var mib = o.memoryMiB > 0 ? o.memoryMiB : zcmDefaultMemoryMiB(o.level);
  final seg = o.segmentSize;
  var size = inputSize;
  if (seg > 0 && (size == null || size > seg)) size = seg;
  if (size != null) {
    final cap = ((size * zcmTableBytesPerInputByte(o.level)) >> 20) + 8;
    if (cap < mib) mib = cap;
  }
  if (mib < zcmMinMemoryMiB) mib = zcmMinMemoryMiB;
  if (mib > zcmMaxMemoryMiB) mib = zcmMaxMemoryMiB;
  return mib;
}

/// Decoded header fields.
final class ZcmHeader {
  final int version;
  final int level;
  final int flags;
  final int memoryMiB;
  final int segmentSize;
  final int lstmCells;
  final int lstmLayers;
  final int lstmHorizon;
  final int? originalSize;

  const ZcmHeader(this.version, this.level, this.flags, this.memoryMiB,
      this.segmentSize, this.originalSize,
      {this.lstmCells = 0, this.lstmLayers = 0, this.lstmHorizon = 0});

  bool get independent => (flags & _fIndependent) != 0;
  bool get lstm => (flags & _fLstm) != 0;
  bool get detect => (flags & _fDetect) != 0;
  bool get e8e9 => (flags & _fE8E9) != 0;
  bool get dictionary => (flags & _fDict) != 0;

  ZcmHeader withOriginalSize(int? size) =>
      ZcmHeader(version, level, flags, memoryMiB, segmentSize, size,
          lstmCells: lstmCells,
          lstmLayers: lstmLayers,
          lstmHorizon: lstmHorizon);

  /// The props bytes (the header without the magic and the original
  /// size): version, level, flags, vint memoryMiB, vint segmentSize, and
  /// with the LSTM flag vint cells, u8 layers, vint horizon.
  Uint8List get props {
    final b = ZcmByteSink(16);
    b.add(version);
    b.add(level);
    b.add(flags);
    _putVint(b, memoryMiB);
    _putVint(b, segmentSize);
    if (lstm) {
      _putVint(b, lstmCells);
      b.add(lstmLayers);
      _putVint(b, lstmHorizon);
    }
    return Uint8List.fromList(b.view());
  }

  static ZcmHeader fromOptions(ZcmOptions o, int? inputSize) {
    if (o.level < 1 || o.level > 9) {
      throw InvalidArgException('zcm: level ${o.level} out of range 1..9');
    }
    if (o.segmentSize < 0 || (o.segmentSize > 0 && o.segmentSize < 4096)) {
      throw InvalidArgException('zcm: segment size ${o.segmentSize} too small');
    }
    final useLstm = o.lstm && o.level == 9;
    if (useLstm &&
        (o.lstmCells < 1 ||
            o.lstmCells > zcmMaxLstmCells ||
            o.lstmLayers < 1 ||
            o.lstmLayers > zcmMaxLstmLayers ||
            o.lstmHorizon < 1 ||
            o.lstmHorizon > zcmMaxLstmHorizon)) {
      throw InvalidArgException('zcm: LSTM size out of range');
    }
    var flags = 0;
    if (o.segmentSize > 0) flags |= _fIndependent;
    if (useLstm) flags |= _fLstm;
    if (o.detect) flags |= _fDetect | _fE8E9;
    if (o.detect && o.dictionary) flags |= _fDict;
    return ZcmHeader(zcmVersion, o.level, flags,
        zcmEffectiveMemoryMiB(o, inputSize), o.segmentSize, inputSize,
        lstmCells: useLstm ? o.lstmCells : 0,
        lstmLayers: useLstm ? o.lstmLayers : 0,
        lstmHorizon: useLstm ? o.lstmHorizon : 0);
  }

  /// Writes the whole stream header.
  void write(ZcmByteSink b) {
    b.add(0x7A);
    b.add(0x63);
    b.add(0x6D);
    b.addBytes(props);
    _putVint(b, originalSize == null ? 0 : originalSize! + 1);
  }
}

/// Named LSTM sizes (cells, layers, horizon): small is the default of
/// [ZcmOptions], large is the configuration of cmix (Byron Knoll), about
/// 30 times slower than small.
const Map<String, List<int>> zcmLstmPresets = {
  'small': [64, 1, 20],
  'medium': [128, 2, 40],
  'large': [200, 2, 100],
};

/// Limits of the LSTM size a stream may declare.
const int zcmMaxLstmCells = 1024;
const int zcmMaxLstmLayers = 8;
const int zcmMaxLstmHorizon = 1000;

void _putVint(ZcmByteSink b, int v) {
  while (v >= 0x80) {
    b.add((v & 0x7F) | 0x80);
    v >>= 7;
  }
  b.add(v);
}

// Reads a vint from a stream; throws on truncation or overflow.
int _readVint(InStream s, Uint8List one) {
  var v = 0;
  for (var shift = 0; shift < 63; shift += 7) {
    if (s.read(one, 0, 1) != 1) throw _truncated();
    final b = one[0];
    v |= (b & 0x7F) << shift;
    if (b < 0x80) return v;
  }
  throw _corrupt('bad varint');
}

SevenZipException _truncated() => const SevenZipException(
    'zcm: unexpected end of data', SevenZipError.unexpectedEnd);

SevenZipException _corrupt(String what) =>
    SevenZipException('zcm: data error ($what)', SevenZipError.data);

/// Parses props (as [ZcmHeader.props] writes them).
ZcmHeader zcmParseProps(Uint8List props) {
  final s = MemoryInStream(props);
  final one = Uint8List(1);
  return _readHeaderBody(s, one, null);
}

ZcmHeader _readHeaderBody(InStream s, Uint8List one, int? originalSize) {
  if (s.read(one, 0, 1) != 1) throw _truncated();
  final version = one[0];
  if (version != zcmVersion) {
    throw SevenZipException(
        'zcm: unsupported version $version', SevenZipError.unsupportedMethod);
  }
  if (s.read(one, 0, 1) != 1) throw _truncated();
  final level = one[0];
  if (s.read(one, 0, 1) != 1) throw _truncated();
  final flags = one[0];
  final mem = _readVint(s, one);
  final seg = _readVint(s, one);
  if (level < 1 || level > 9 || (flags & ~31) != 0) {
    throw _corrupt('bad header');
  }
  if (mem < zcmMinMemoryMiB || mem > zcmMaxMemoryMiB) {
    throw _corrupt('bad memory budget');
  }
  final indep = (flags & _fIndependent) != 0;
  if (indep != (seg > 0) || seg > (1 << 40)) throw _corrupt('bad segments');
  var cells = 0, layers = 0, horizon = 0;
  if ((flags & _fLstm) != 0) {
    cells = _readVint(s, one);
    if (s.read(one, 0, 1) != 1) throw _truncated();
    layers = one[0];
    horizon = _readVint(s, one);
    if (level != 9 ||
        cells < 1 ||
        cells > zcmMaxLstmCells ||
        layers < 1 ||
        layers > zcmMaxLstmLayers ||
        horizon < 1 ||
        horizon > zcmMaxLstmHorizon) {
      throw _corrupt('bad LSTM size');
    }
  }
  return ZcmHeader(version, level, flags, mem, seg, originalSize,
      lstmCells: cells, lstmLayers: layers, lstmHorizon: horizon);
}

// ---------------------------------------------------------------------
// Block detection and the x86 transform.

/// E8/E9 forward transform of paq8px (ExeFilter): the relative targets of
/// CALL, JMP and Jcc (E8/E9 xx xx xx 00/FF, 0F 8x xx xx xx 00/FF) become
/// absolute (mod 2^25), the low bytes xored with 176. Scans backwards so
/// that [zcmE8E9Decode] can undo it scanning forwards. [base] is the
/// stream position of b[off].
void zcmE8E9Encode(Uint8List b, int off, int len, int base) {
  for (var i = len - 1; i >= 5; i--) {
    final p = off + i;
    final hi = b[p];
    final op = b[p - 4];
    if ((hi == 0 || hi == 0xFF) &&
        (op == 0xE8 ||
            op == 0xE9 ||
            (b[p - 5] == 0x0F && (op & 0xF0) == 0x80))) {
      var a = b[p - 3] | b[p - 2] << 8 | b[p - 1] << 16 | hi << 24;
      a = (a + base + i + 1) & 0x1FFFFFF;
      if (a >= 0x1000000) a -= 0x2000000;
      b[p] = (a >> 24) & 255;
      b[p - 1] = (a ^ 176) & 255;
      b[p - 2] = ((a >> 8) ^ 176) & 255;
      b[p - 3] = ((a >> 16) ^ 176) & 255;
    }
  }
}

/// Inverse of [zcmE8E9Encode].
void zcmE8E9Decode(Uint8List b, int off, int len, int base) {
  for (var i = 5; i < len; i++) {
    final p = off + i;
    final hi = b[p];
    final op = b[p - 4];
    if ((hi == 0 || hi == 0xFF) &&
        (op == 0xE8 ||
            op == 0xE9 ||
            (b[p - 5] == 0x0F && (op & 0xF0) == 0x80))) {
      var a = (b[p - 1] ^ 176) |
          (b[p - 2] ^ 176) << 8 |
          (b[p - 3] ^ 176) << 16 |
          hi << 24;
      a = (a - base - i - 1) & 0x1FFFFFF;
      if (a >= 0x1000000) a -= 0x2000000;
      b[p] = (a >> 24) & 255;
      b[p - 1] = (a >> 16) & 255;
      b[p - 2] = (a >> 8) & 255;
      b[p - 3] = a & 255;
    }
  }
}

// ---------------------------------------------------------------------
// Chunk coding.

/// Builds the predictor a header asks for.
ZcmBitPredictor zcmNewPredictor(ZcmHeader h) =>
    zcmCreatePredictor(h.level, h.memoryMiB << 20,
        lstmCells: h.lstm ? h.lstmCells : 0,
        lstmLayers: h.lstmLayers,
        lstmHorizon: h.lstmHorizon);

/// Codes [len] bytes of [data] at [off] with [pred] (whose history is at
/// stream position [base]) and returns the packed bytes. [data] is
/// changed in place by the exe transform.
Uint8List zcmEncodeChunk(ZcmBitPredictor pred, ZcmHeader h, Uint8List data,
    int off, int len, int base,
    {ProgressCallback? progress, int progressBase = 0, int outBase = 0}) {
  final sink = ZcmByteSink(len ~/ 3 + 1024);
  final enc = ZcmEncoder(sink);
  final segs = h.detect
      ? zcmDetectSegments(data, off, len)
      : [ZcmSegment(ZcmBlockType.binary, 0, len)];
  var done = 0;
  var nextReport = zcmBlockSize;
  for (final seg in segs) {
    final type = seg.type;
    var bytes = data;
    var bo = off + seg.off;
    var bl = seg.len;
    if (h.detect) {
      enc.encodeDirect(type, 4);
      enc.encodeDirect(bl, 32);
      if (ZcmBlockType.hasInfo(type)) enc.encodeDirect(seg.info, 32);
      if (type == ZcmBlockType.exe && h.e8e9) {
        zcmE8E9Encode(data, bo, bl, base + seg.off);
      }
      if (_swapped(type, seg.info)) zcmSwap16(data, bo, bl);
      if (type == ZcmBlockType.text && h.dictionary) {
        final t = zcmDictEncode(data, bo, bl);
        enc.encodeDirect(t == null ? 0 : 1, 1);
        if (t != null) {
          enc.encodeDirect(t.length, 32);
          bytes = t;
          bo = 0;
          bl = t.length;
        }
      }
    }
    pred.setSegment(type, seg.info);
    final end = bo + bl;
    for (var i = bo; i < end; i++) {
      final c = bytes[i];
      for (var j = 7; j >= 0; j--) {
        final bit = (c >> j) & 1;
        enc.encode(bit, pred.p());
        pred.update(bit);
      }
      if (progress != null && identical(bytes, data) && i - off >= nextReport) {
        progress(progressBase + i - off, outBase + sink.length);
        nextReport += zcmBlockSize;
      }
    }
    done += seg.len;
    if (progress != null) progress(progressBase + done, outBase + sink.length);
  }
  enc.flush();
  return Uint8List.fromList(sink.view());
}

// 16-bit little endian audio is coded most significant byte first.
bool _swapped(int type, int info) =>
    type == ZcmBlockType.audio && (info & 1) != 0 && (info & 4) == 0;

/// Decodes [len] bytes from [packed] into [out] at [off] (the inverse of
/// [zcmEncodeChunk]).
void zcmDecodeChunk(ZcmBitPredictor pred, ZcmHeader h, Uint8List packed,
    Uint8List out, int off, int len, int base) {
  final dec = ZcmDecoder(packed);
  var done = 0;
  while (done < len) {
    var type = ZcmBlockType.binary;
    var bl = len;
    var info = 0;
    Uint8List? t;
    if (h.detect) {
      type = dec.decodeDirect(4);
      if (type >= ZcmBlockType.count) throw _corrupt('bad segment type');
      bl = dec.decodeDirect(32);
      if (bl < 1 || bl > len - done) throw _corrupt('bad segment length');
      if (ZcmBlockType.hasInfo(type)) {
        info = dec.decodeDirect(32);
        final bad = type == ZcmBlockType.audio
            ? info > 15
            : (info >= (1 << 26) ||
                (info & 0xFFFFFF) == 0 ||
                (info & 0xFFFFFF) > zcmMaxImageStride);
        if (info < 1 || bad) throw _corrupt('bad segment info');
      }
      if (type == ZcmBlockType.text &&
          h.dictionary &&
          dec.decodeDirect(1) != 0) {
        final tl = dec.decodeDirect(32);
        if (tl < 1 || tl > bl * 2 + 16) throw _corrupt('bad text length');
        t = Uint8List(tl);
      }
      if (dec.overrun > 4) throw _truncated();
    }
    pred.setSegment(type, info);
    final target = t ?? out;
    final start = t == null ? off + done : 0;
    final end = t == null ? start + bl : t.length;
    for (var i = start; i < end; i++) {
      var c = 0;
      for (var j = 0; j < 8; j++) {
        final bit = dec.decode(pred.p());
        pred.update(bit);
        c = (c << 1) | bit;
      }
      target[i] = c;
      if (dec.overrun > 4) throw _truncated();
    }
    if (t != null) {
      if (!zcmDictDecode(t, out, off + done, bl)) {
        throw _corrupt('bad text transform');
      }
    }
    if (type == ZcmBlockType.exe && h.e8e9) {
      zcmE8E9Decode(out, off + done, bl, base + done);
    }
    if (_swapped(type, info)) zcmSwap16(out, off + done, bl);
    done += bl;
  }
  if (dec.overrun > 0) throw _truncated();
}

/// Writes one chunk record.
void zcmWriteChunk(ZcmByteSink out, Uint8List raw, int off, int len,
    Uint8List packed, int crc) {
  _putVint(out, len);
  out.add(crc & 255);
  out.add((crc >> 8) & 255);
  out.add((crc >> 16) & 255);
  out.add((crc >> 24) & 255);
  _putVint(out, packed.length);
  out.addBytes(packed);
}

/// The zcm compressor. [inputSize] (when known) is stored in the header
/// and lowers the memory budget for small inputs.
final class ZcmCompressor implements Compressor {
  final ZcmOptions options;
  final int? inputSize;

  /// Worker isolates for streams with independent segments (the
  /// synchronous pool of lib/src/sync_pool.dart); the output does not
  /// depend on it.
  final int threads;
  late final ZcmHeader header = ZcmHeader.fromOptions(options, inputSize);

  ZcmCompressor(this.options, {this.inputSize, this.threads = 1});

  @override
  Uint8List get props => header.props;

  @override
  int encode(InStream input, OutStream output, {ProgressCallback? progress}) {
    final h = header;
    if (h.independent && threads > 1) {
      return _encodeSegmentsParallel(input, output, progress);
    }
    final sink = ZcmByteSink(64);
    h.write(sink);
    output.write(sink.view(), 0, sink.length);
    var outTotal = sink.length;
    final chunkSize = h.independent ? h.segmentSize : zcmSolidChunk;
    final bufSize = inputSize != null && inputSize! < chunkSize
        ? (inputSize! < 1 ? 1 : inputSize!)
        : chunkSize;
    var buf = Uint8List(bufSize);
    ZcmBitPredictor? pred;
    var total = 0;
    var pre = 0; // bytes already in buf (from the end probe)
    while (true) {
      final n = pre + readFully(input, buf, pre, buf.length - pre);
      pre = 0;
      if (n == 0) break;
      final crc = Crc32.of(buf, 0, n);
      if (pred == null || h.independent) pred = zcmNewPredictor(h);
      final base = h.independent ? 0 : total;
      final packed = zcmEncodeChunk(pred, h, buf, 0, n, base,
          progress: progress, progressBase: total, outBase: outTotal);
      sink.clear();
      zcmWriteChunk(sink, buf, 0, n, packed, crc);
      output.write(sink.view(), 0, sink.length);
      outTotal += sink.length;
      total += n;
      if (n < buf.length) break;
      if (buf.length < chunkSize) {
        // The size hint was reached: look for more input before growing.
        final probe = Uint8List(1);
        if (readFully(input, probe, 0, 1) == 0) break;
        buf = Uint8List(chunkSize);
        buf[0] = probe[0];
        pre = 1;
      }
    }
    sink.clear();
    _putVint(sink, 0);
    output.write(sink.view(), 0, sink.length);
    if (h.originalSize != null && h.originalSize != total) {
      throw SevenZipException(
          'zcm: input size ${h.originalSize} declared, $total read',
          SevenZipError.data);
    }
    output.flush();
    return total;
  }
}

extension on ZcmCompressor {
  // Independent segments on a SyncJobPool: at most [threads] segments in
  // flight, written in order.
  int _encodeSegmentsParallel(
      InStream input, OutStream output, ProgressCallback? progress) {
    final h = header;
    final head = zcmHeaderBytes(h);
    output.write(head, 0, head.length);
    var outTotal = head.length;
    final seg = h.segmentSize;
    final props = h.props;
    final orig = h.originalSize ?? -1;
    final pool = SyncJobPool(threads);
    final tickets = <int>[];
    final sizes = <int>[];
    var total = 0;
    var eof = false;
    try {
      while (!eof || tickets.isNotEmpty) {
        while (!eof && tickets.length < threads) {
          final buf = Uint8List(seg);
          final n = readFully(input, buf, 0, seg);
          if (n == 0) {
            eof = true;
            break;
          }
          if (n < seg) eof = true;
          final data = n == seg
              ? buf
              : Uint8List.fromList(Uint8List.sublistView(buf, 0, n));
          tickets.add(pool.submit(_zcmSegmentJob, [props, orig, data]));
          sizes.add(n);
        }
        if (tickets.isEmpty) break;
        final r = pool.take(tickets.removeAt(0)).data;
        output.write(r, 0, r.length);
        outTotal += r.length;
        total += sizes.removeAt(0);
        if (progress != null) progress(total, outTotal);
      }
    } finally {
      pool.close();
    }
    final end = zcmEndBytes();
    output.write(end, 0, end.length);
    if (h.originalSize != null && h.originalSize != total) {
      throw SevenZipException(
          'zcm: input size ${h.originalSize} declared, $total read',
          SevenZipError.data);
    }
    output.flush();
    return total;
  }
}

// A segment job of [ZcmCompressor] (runs in a worker isolate).
SyncJobResult _zcmSegmentJob(Object? arg) {
  final a = arg as List<Object?>;
  final orig = a[1] as int;
  final h =
      zcmParseProps(a[0] as Uint8List).withOriginalSize(orig < 0 ? null : orig);
  final data = a[2] as Uint8List;
  return SyncJobResult(zcmEncodeSegmentRecord(h, data, 0, data.length));
}

/// Pull decoder of a zcm stream.
final class ZcmDecoderStream implements InStream {
  final InStream _in;
  final Uint8List? _props;
  final int? _outSize;
  final Uint8List _one = Uint8List(1);
  ZcmHeader? _h;
  ZcmBitPredictor? _pred;
  Uint8List _chunk = Uint8List(0);
  int _chunkLen = 0;
  int _chunkPos = 0;
  int _total = 0;
  bool _end = false;

  ZcmDecoderStream(this._in, {Uint8List? props, int? outSize})
      : _props = props,
        _outSize = outSize;

  /// The stream header (after the first read).
  ZcmHeader? get header => _h;

  void _readHeader() {
    final m = Uint8List(3);
    if (readFully(_in, m, 0, 3) != 3) throw _truncated();
    if (m[0] != 0x7A || m[1] != 0x63 || m[2] != 0x6D) {
      throw const SevenZipException('zcm: bad magic', SevenZipError.data);
    }
    final body = _readHeaderBody(_in, _one, null);
    final orig = _readVint(_in, _one);
    final h = body.withOriginalSize(orig == 0 ? null : orig - 1);
    final p = _props;
    if (p != null && p.isNotEmpty) {
      final hp = h.props;
      var same = hp.length == p.length;
      for (var i = 0; same && i < hp.length; i++) {
        same = hp[i] == p[i];
      }
      if (!same) throw _corrupt('props do not match the stream header');
    }
    _h = h;
  }

  bool _nextChunk() {
    final h = _h!;
    final rawLen = _readVint(_in, _one);
    if (rawLen == 0) {
      final expect = h.originalSize ?? _outSize;
      if (expect != null && expect != _total) throw _corrupt('size mismatch');
      return false;
    }
    final maxChunk = h.independent ? h.segmentSize : zcmSolidChunk;
    if (rawLen > maxChunk) throw _corrupt('chunk too large');
    final limit = h.originalSize ?? _outSize;
    if (limit != null && _total + rawLen > limit) throw _corrupt('too long');
    final crcb = Uint8List(4);
    readExactly(_in, crcb, 0, 4);
    final crc = crcb[0] | crcb[1] << 8 | crcb[2] << 16 | crcb[3] << 24;
    final packedLen = _readVint(_in, _one);
    if (packedLen > rawLen + (rawLen >> 3) + 4096) {
      throw _corrupt('packed size');
    }
    final packed = Uint8List(packedLen);
    readExactly(_in, packed, 0, packedLen);
    if (_chunk.length < rawLen) _chunk = Uint8List(rawLen);
    if (_pred == null || h.independent) _pred = zcmNewPredictor(h);
    final base = h.independent ? 0 : _total;
    zcmDecodeChunk(_pred!, h, packed, _chunk, 0, rawLen, base);
    if (Crc32.of(_chunk, 0, rawLen) != crc) {
      throw const SevenZipException('zcm: CRC error', SevenZipError.crc);
    }
    _chunkLen = rawLen;
    _chunkPos = 0;
    return true;
  }

  @override
  int read(Uint8List buf, int off, int len) {
    if (len == 0 || _end) return 0;
    if (_h == null) _readHeader();
    while (_chunkPos == _chunkLen) {
      if (!_nextChunk()) {
        _end = true;
        return 0;
      }
    }
    var n = _chunkLen - _chunkPos;
    if (n > len) n = len;
    buf.setRange(off, off + n, _chunk, _chunkPos);
    _chunkPos += n;
    _total += n;
    return n;
  }
}

/// Decoder factory for a registry ([DecoderFactory] shape).
InStream zcmDecoder(Uint8List props, List<InStream> inputs, int? outSize,
        CoderContext ctx) =>
    ZcmDecoderStream(inputs[0], props: props, outSize: outSize);

/// Compresses [data] in memory.
Uint8List zcmCompressBytes(Uint8List data,
    [ZcmOptions options = const ZcmOptions()]) {
  final out = MemoryOutStream();
  ZcmCompressor(options, inputSize: data.length)
      .encode(MemoryInStream(Uint8List.fromList(data)), out);
  return out.toBytes();
}

/// Decompresses a zcm stream in memory.
Uint8List zcmDecompressBytes(Uint8List packed) =>
    readAll(ZcmDecoderStream(MemoryInStream(packed)));

// ---------------------------------------------------------------------
// Pieces for the segment parallel coder (zcm_parallel.dart).

/// The stream header bytes of [h].
Uint8List zcmHeaderBytes(ZcmHeader h) {
  final b = ZcmByteSink(32);
  h.write(b);
  return Uint8List.fromList(b.view());
}

/// The end record of a stream.
Uint8List zcmEndBytes() => Uint8List.fromList(const [0]);

/// Codes one independent segment ([len] bytes of [data] at [off]) and
/// returns its chunk record, exactly as [ZcmCompressor] writes it.
Uint8List zcmEncodeSegmentRecord(
    ZcmHeader h, Uint8List data, int off, int len) {
  final buf = Uint8List.fromList(Uint8List.sublistView(data, off, off + len));
  final crc = Crc32.of(buf, 0, len);
  final packed = zcmEncodeChunk(zcmNewPredictor(h), h, buf, 0, len, 0);
  final sink = ZcmByteSink(packed.length + 16);
  zcmWriteChunk(sink, buf, 0, len, packed, crc);
  return Uint8List.fromList(sink.view());
}

/// A chunk of a stream in memory: where its packed bytes are.
final class ZcmChunkRef {
  final int rawLen;
  final int crc;
  final int packedOff;
  final int packedLen;
  const ZcmChunkRef(this.rawLen, this.crc, this.packedOff, this.packedLen);
}

/// Parses the header and the chunk table of a whole stream in memory.
(ZcmHeader, List<ZcmChunkRef>) zcmParseStream(Uint8List packed) {
  final s = MemoryInStream(packed);
  final one = Uint8List(1);
  final m = Uint8List(3);
  if (readFully(s, m, 0, 3) != 3) throw _truncated();
  if (m[0] != 0x7A || m[1] != 0x63 || m[2] != 0x6D) {
    throw const SevenZipException('zcm: bad magic', SevenZipError.data);
  }
  final body = _readHeaderBody(s, one, null);
  final orig = _readVint(s, one);
  final h = body.withOriginalSize(orig == 0 ? null : orig - 1);
  final chunks = <ZcmChunkRef>[];
  final maxChunk = h.independent ? h.segmentSize : zcmSolidChunk;
  var total = 0;
  while (true) {
    final rawLen = _readVint(s, one);
    if (rawLen == 0) break;
    if (rawLen > maxChunk) throw _corrupt('chunk too large');
    final crcb = Uint8List(4);
    readExactly(s, crcb, 0, 4);
    final crc = crcb[0] | crcb[1] << 8 | crcb[2] << 16 | crcb[3] << 24;
    final packedLen = _readVint(s, one);
    if (packedLen > rawLen + (rawLen >> 3) + 4096) {
      throw _corrupt('packed size');
    }
    final off = s.position;
    if (off + packedLen > packed.length) throw _truncated();
    s.position = off + packedLen;
    chunks.add(ZcmChunkRef(rawLen, crc, off, packedLen));
    total += rawLen;
  }
  if (h.originalSize != null && h.originalSize != total) {
    throw _corrupt('size mismatch');
  }
  return (h, chunks);
}

/// Decodes one independent segment (a chunk of [packed]) into [out] at
/// [outOff] and checks its CRC.
void zcmDecodeSegment(
    ZcmHeader h, Uint8List packed, ZcmChunkRef c, Uint8List out, int outOff) {
  final p =
      Uint8List.sublistView(packed, c.packedOff, c.packedOff + c.packedLen);
  zcmDecodeChunk(zcmNewPredictor(h), h, p, out, outOff, c.rawLen, 0);
  if (Crc32.of(out, outOff, outOff + c.rawLen) != c.crc) {
    throw const SevenZipException('zcm: CRC error', SevenZipError.crc);
  }
}

// ---------------------------------------------------------------------
// Text forms for a container's method switches and listings.

/// Parses a method parameter string into options: items separated by ':'
/// or ',' (case does not matter):
///   `1`..`9`, `fast`, `normal`, `max`, `ultra`, `cmix`, `level=N`  the
///                 level
///   `mem=N`       memory budget in MiB (`mem=2g`, `mem=512m` also work)
///   `lstm` or `lstm=C/L/H`  the LSTM (level 9) with C cells, L layers,
///                 horizon H; `lstm=small`, `lstm=medium`, `lstm=large`
///                 are presets ([zcmLstmPresets])
///   `seg=N`       independent segments of N bytes (`4m`, `64k`)
///   `nodetect`    no data type detection
///   `nodict`      no dictionary transform of English text
/// [level] is the default level (from -mx, for example).
ZcmOptions zcmOptionsFromString(String spec, {int level = 4}) {
  var o = ZcmOptions(level: level, lstm: level == 9);
  for (final raw in spec.split(RegExp('[:,]'))) {
    final t = raw.trim().toLowerCase();
    if (t.isEmpty) continue;
    final lv = zcmLevelByName(t);
    if (lv != null) {
      o = o.copyWith(level: lv, lstm: t == 'cmix' || (o.lstm && lv == 9));
      continue;
    }
    final eq = t.indexOf('=');
    final key = eq < 0 ? t : t.substring(0, eq);
    final val = eq < 0 ? '' : t.substring(eq + 1);
    switch (key) {
      case 'level':
      case 'l':
      case 'x':
        final lv2 = zcmLevelByName(val);
        if (lv2 == null) throw InvalidArgException('zcm: bad level "$val"');
        o = o.copyWith(level: lv2, lstm: val == 'cmix' || (o.lstm && lv2 == 9));
      case 'mem':
        final b = _parseSize(val, 1 << 20);
        o = o.copyWith(memoryMiB: b >> 20);
      case 'seg':
        o = o.copyWith(segmentSize: _parseSize(val, 1));
      case 'lstm':
        if (val.isEmpty) {
          o = o.copyWith(lstm: true);
        } else if (zcmLstmPresets.containsKey(val)) {
          final p = zcmLstmPresets[val]!;
          o = o.copyWith(
              lstm: true, lstmCells: p[0], lstmLayers: p[1], lstmHorizon: p[2]);
        } else {
          final p = val.split('/').map(int.tryParse).toList();
          if (p.isEmpty || p.any((x) => x == null)) {
            throw InvalidArgException('zcm: bad lstm "$val"');
          }
          o = o.copyWith(
              lstm: true,
              lstmCells: p[0],
              lstmLayers: p.length > 1 ? p[1] : 1,
              lstmHorizon: p.length > 2 ? p[2] : 20);
        }
      case 'nolstm':
        o = o.copyWith(lstm: false);
      case 'nodetect':
        o = o.copyWith(detect: false);
      case 'nodict':
        o = o.copyWith(dictionary: false);
      default:
        throw InvalidArgException('zcm: unknown parameter "$raw"');
    }
  }
  return o;
}

int _parseSize(String v, int unit) {
  final m = RegExp(r'^(\d+)([kmg]?)b?$').firstMatch(v);
  if (m == null) throw InvalidArgException('zcm: bad size "$v"');
  var n = int.parse(m.group(1)!);
  switch (m.group(2)) {
    case 'k':
      n <<= 10;
    case 'm':
      n <<= 20;
    case 'g':
      n <<= 30;
    default:
      n *= unit;
  }
  return n;
}

/// The props as a method name for listings: `zcm:9:m2048:lstm32/1/10`.
String zcmDescribe(Uint8List props) {
  try {
    final h = zcmParseProps(props);
    final b = StringBuffer('zcm:${h.level}:m${h.memoryMiB}');
    if (h.lstm) b.write(':lstm${h.lstmCells}/${h.lstmLayers}/${h.lstmHorizon}');
    if (h.independent) b.write(':seg${h.segmentSize}');
    if (!h.detect) b.write(':nodetect');
    if (h.detect && !h.dictionary) b.write(':nodict');
    return b.toString();
  } on SevenZipException {
    return 'zcm:?';
  }
}
