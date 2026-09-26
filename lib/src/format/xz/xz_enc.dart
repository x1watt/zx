// xz encoding: port of C/XzEnc.c and CPP/7zip/Compress/XzEncoder.cpp of
// the LZMA SDK 26.01.
//
// XzEnc_Encode has two paths, chosen by the normalized properties:
//   * one block thread (numBlockThreads_Reduced <= 1): the single thread
//     stream path, byte identical to the SDK;
//   * several block threads: the blocks that MtCoder would hand to worker
//     threads (XzEnc_MtCallback_Code / XzEnc_MtCallback_Write) are encoded
//     one after the other here, so the output is the same as the SDK's
//     multithreaded output (block headers with pack and unpack sizes).
//     Every block is independent: [xzEncodeMtBlock] encodes one and
//     [XzMtBlockWriter] writes them in order, which lib/src/parallel.dart
//     uses to encode the blocks in worker isolates.

import 'dart:typed_data';

import '../../codec/codec.dart';
import '../../codec/filters/bra.dart';
import '../../codec/filters/delta.dart';
import '../../codec/lzma/lzma2_enc.dart';
import '../../codec/lzma/lzma_coder.dart' show setLzma2Prop;
import '../../common/method_props.dart';
import '../../io/streams.dart';
import '../../util/crc.dart';
import 'xz.dart';
import 'xz_dec.dart'
    show
        XzBcFilterFunc,
        XzBcFilterState,
        XzBcFilterStateBase,
        coderFinishAny,
        xzStateCoderBcSetFromMethodFunc;

/// XZ_PROPS_BLOCK_SIZE_AUTO
const int xzPropsBlockSizeAuto = lzma2BlockSizeAuto;

/// XZ_PROPS_BLOCK_SIZE_SOLID
const int xzPropsBlockSizeSolid = lzma2BlockSizeSolid;

// MTCODER_THREADS_MAX of the multithreaded build.
const int _mtCoderThreadsMax = 256;

const int _m32 = 0xFFFFFFFF;

// Unsigned 64-bit comparison a < b (the C code compares UInt64 values, and
// (UInt64)(Int64)-1 is -1 here).
bool _ult(int a, int b) => (a ^ 0x8000000000000000) < (b ^ 0x8000000000000000);

// XZ_GET_PAD_SIZE
int _xzGetPadSize(int dataSize) => (4 - (dataSize & 3)) & 3;

/// CXzFilterProps
class XzFilterProps {
  int id = 0;
  int delta = 0;
  int ip = 0;
  bool ipDefined = false;

  // XzFilterProps_Init
  XzFilterProps();

  XzFilterProps copy() => XzFilterProps()
    ..id = id
    ..delta = delta
    ..ip = ip
    ..ipDefined = ipDefined;
}

/// CXzProps
class XzProps {
  Lzma2EncProps lzma2Props = Lzma2EncProps();
  XzFilterProps filterProps = XzFilterProps();
  int checkId = xzCheckCrc32;
  int numThreadGroups = 0; // 0 : no groups

  /// [xzPropsBlockSizeAuto], [xzPropsBlockSizeSolid] or a size in bytes.
  int blockSize = xzPropsBlockSizeAuto;
  int numBlockThreadsReduced = -1;
  int numBlockThreadsMax = -1;
  int numTotalThreads = -1;
  int forceWriteSizesInHeader = 0;

  /// -1 = unknown.
  int reduceSize = -1;

  // XzProps_Init
  XzProps();

  XzProps copy() => XzProps()
    ..lzma2Props = lzma2Props.copy()
    ..filterProps = filterProps.copy()
    ..checkId = checkId
    ..numThreadGroups = numThreadGroups
    ..blockSize = blockSize
    ..numBlockThreadsReduced = numBlockThreadsReduced
    ..numBlockThreadsMax = numBlockThreadsMax
    ..numTotalThreads = numTotalThreads
    ..forceWriteSizesInHeader = forceWriteSizesInHeader
    ..reduceSize = reduceSize;

  // XzEncProps_Normalize_Fixed
  void _normalizeFixed() {
    int t1, t1n, t2, t2r, t3;
    {
      final tp = lzma2Props.copy();
      if (tp.numTotalThreads <= 0) tp.numTotalThreads = numTotalThreads;
      tp.normalize();
      t1n = tp.numTotalThreads;
    }

    t1 = lzma2Props.numTotalThreads;
    t2 = numBlockThreadsMax;
    t3 = numTotalThreads;

    if (t2 > _mtCoderThreadsMax) t2 = _mtCoderThreadsMax;

    if (t3 <= 0) {
      if (t2 <= 0) t2 = 1;
      t3 = t1n * t2;
    } else if (t2 <= 0) {
      t2 = t3 ~/ t1n;
      if (t2 == 0) {
        t1 = 1;
        t2 = t3;
      }
      if (t2 > _mtCoderThreadsMax) t2 = _mtCoderThreadsMax;
    } else if (t1 <= 0) {
      t1 = t3 ~/ t2;
      if (t1 == 0) t1 = 1;
    } else {
      t3 = t1n * t2;
    }

    lzma2Props.numTotalThreads = t1;

    t2r = t2;

    final fileSize = reduceSize;

    if (_ult(blockSize, fileSize) || fileSize == -1) {
      lzma2Props.lzmaProps.reduceSize = blockSize;
    }

    lzma2Props.normalize();

    t1 = lzma2Props.numTotalThreads;

    {
      if (t2 > 1 && fileSize != -1) {
        var numBlocks = fileSize ~/ blockSize;
        if (numBlocks * blockSize != fileSize) numBlocks++;
        if (numBlocks < t2) {
          t2r = numBlocks;
          if (t2r == 0) t2r = 1;
          t3 = t1 * t2r;
        }
      }
    }

    numBlockThreadsMax = t2;
    numBlockThreadsReduced = t2r;
    numTotalThreads = t3;
  }

  // XzProps_Normalize
  void normalize() {
    // we normalize xzProps properties, but we normalize only some of
    // CXzProps::lzma2Props properties. Lzma2Enc_SetProps() will normalize
    // lzma2Props later.

    if (blockSize == xzPropsBlockSizeSolid) {
      lzma2Props.lzmaProps.reduceSize = reduceSize;
      numBlockThreadsReduced = 1;
      numBlockThreadsMax = 1;
      if (lzma2Props.numTotalThreads <= 0) {
        lzma2Props.numTotalThreads = numTotalThreads;
      }
      return;
    } else {
      final lzma2 = lzma2Props;
      if (blockSize == lzma2BlockSizeAuto) {
        // xz-auto
        lzma2Props.lzmaProps.reduceSize = reduceSize;

        if (lzma2.blockSize == lzma2BlockSizeSolid) {
          // if (xz-auto && lzma2-solid) - we use solid for both
          blockSize = xzPropsBlockSizeSolid;
          numBlockThreadsReduced = 1;
          numBlockThreadsMax = 1;
          if (lzma2Props.numTotalThreads <= 0) {
            lzma2Props.numTotalThreads = numTotalThreads;
          }
        } else {
          // if (xz-auto && (lzma2-auto || lzma2-fixed_)
          //   we calculate block size for lzma2 and use that block size
          //   for xz, lzma2 uses single-chunk per block
          final tp = lzma2Props.copy();
          if (tp.numTotalThreads <= 0) tp.numTotalThreads = numTotalThreads;

          tp.normalize();

          blockSize = tp.blockSize; // fixed or solid
          numBlockThreadsReduced = tp.numBlockThreadsReduced;
          numBlockThreadsMax = tp.numBlockThreadsMax;
          if (lzma2.blockSize == lzma2BlockSizeAuto) {
            lzma2.blockSize = tp.blockSize; // fixed or solid
          }
          if (_ult(tp.blockSize, lzma2.lzmaProps.reduceSize) &&
              tp.blockSize != lzma2BlockSizeSolid) {
            lzma2.lzmaProps.reduceSize = tp.blockSize;
          }
          lzma2.numBlockThreadsReduced = 1;
          lzma2.numBlockThreadsMax = 1;
          return;
        }
      } else {
        // xz-fixed
        // we can use xz::reduceSize or xz::blockSize as base for
        // lzmaProps::reduceSize

        lzma2Props.lzmaProps.reduceSize = reduceSize;
        {
          var r = reduceSize;
          if (_ult(blockSize, r) || r == -1) r = blockSize;
          lzma2.lzmaProps.reduceSize = r;
        }
        if (lzma2.blockSize == lzma2BlockSizeAuto) {
          lzma2.blockSize = lzma2BlockSizeSolid;
        } else if (_ult(blockSize, lzma2.blockSize) &&
            lzma2.blockSize != lzma2BlockSizeSolid) {
          lzma2.blockSize = blockSize;
        }

        _normalizeFixed();
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Headers, index

// Xz_WriteHeader
void _xzWriteHeader(int f, OutStream s) {
  final header = Uint8List(xzStreamHeaderSize);
  header.setAll(0, xzSig);
  header[xzSigSize] = (f >> 8) & 0xFF;
  header[xzSigSize + 1] = f & 0xFF;
  final crc = Crc32.of(header, xzSigSize, xzSigSize + xzStreamFlagsSize);
  setUint32LE(header, xzSigSize + xzStreamFlagsSize, crc);
  s.write(header, 0, xzStreamHeaderSize);
}

// XzBlock_WriteHeader
void _xzBlockWriteHeader(XzBlock p, OutStream s) {
  final header = Uint8List(xzBlockHeaderSizeMax);

  var pos = 1;
  header[pos++] = p.flags;

  if (p.hasPackSize) pos += xzWriteVarInt(header, pos, p.packSize);
  if (p.hasUnpackSize) pos += xzWriteVarInt(header, pos, p.unpackSize);
  final numFilters = p.numFilters;

  for (var i = 0; i < numFilters; i++) {
    final f = p.filters[i];
    pos += xzWriteVarInt(header, pos, f.id);
    pos += xzWriteVarInt(header, pos, f.propsSize);
    header.setRange(pos, pos + f.propsSize, f.props);
    pos += f.propsSize;
  }

  while ((pos & 3) != 0) {
    header[pos++] = 0;
  }

  header[0] = pos >> 2;
  setUint32LE(header, pos, Crc32.of(header, 0, pos));
  s.write(header, 0, pos + 4);
}

/// CXzEncIndex
class _XzEncIndex {
  int numBlocks = 0;
  final MemoryOutStream _blocks = MemoryOutStream();

  // XzEncIndex_Init
  void init() {
    numBlocks = 0;
    _blocks.truncate(0);
    _blocks.position = 0;
  }

  // XzEncIndex_AddIndexRecord
  void addIndexRecord(int unpackSize, int totalSize) {
    final buf = Uint8List(32);
    var pos = xzWriteVarInt(buf, 0, totalSize);
    pos += xzWriteVarInt(buf, pos, unpackSize);
    _blocks.write(buf, 0, pos);
    numBlocks++;
  }

  // XzEncIndex_WriteFooter
  void writeFooter(int flags, OutStream s) {
    final buf = Uint8List(32);
    var crc = 0xFFFFFFFF; // CRC_INIT_VAL
    var pos = 1 + xzWriteVarInt(buf, 1, numBlocks);

    var globalPos = pos;
    buf[0] = 0;
    // WriteBytes_UpdateCrc
    crc = crc32Update(crc, buf, 0, pos);
    s.write(buf, 0, pos);
    final blocks = _blocks.toBytes();
    crc = crc32Update(crc, blocks, 0, blocks.length);
    s.write(blocks, 0, blocks.length);
    globalPos += blocks.length;

    pos = _xzGetPadSize(globalPos);
    buf[1] = 0;
    buf[2] = 0;
    buf[3] = 0;
    globalPos += pos;

    crc = crc32Update(crc, buf, 4 - pos, 4);
    setUint32LE(buf, 4, crc ^ 0xFFFFFFFF);

    setUint32LE(buf, 8 + 4, (globalPos >> 2) & _m32);
    buf[8 + 8] = (flags >> 8) & 0xFF;
    buf[8 + 9] = flags & 0xFF;
    setUint32LE(buf, 8, Crc32.of(buf, 8 + 4, 8 + 4 + 6));
    buf[8 + 10] = xzFooterSig0;
    buf[8 + 11] = xzFooterSig1;

    s.write(buf, 4 - pos, pos + 4 + 12);
  }
}

// ---------------------------------------------------------------------------
// Streams

/// CSeqCheckInStream
class _SeqCheckInStream implements InStream {
  InStream? realStream;
  Uint8List? data;
  int limit = -1;
  int processed = 0;
  bool realStreamFinished = false;
  final XzCheck check = XzCheck();

  // SeqCheckInStream_Init
  void init(int checkMode) {
    limit = -1;
    processed = 0;
    realStreamFinished = false;
    check.init(checkMode);
  }

  // SeqCheckInStream_GetDigest
  void getDigest(Uint8List digest, int off) => check.finalTo(digest, off);

  // SeqCheckInStream_Read
  @override
  int read(Uint8List buf, int off, int len) {
    var size2 = len;
    if (limit != -1) {
      final rem = limit - processed;
      if (size2 > rem) size2 = rem;
    }
    if (size2 != 0) {
      final real = realStream;
      if (real != null) {
        size2 = real.read(buf, off, size2);
        realStreamFinished = size2 == 0;
      } else {
        buf.setRange(off, off + size2, data!, processed);
      }
      check.update(buf, off, size2);
      processed += size2;
    }
    return size2;
  }
}

/// CSeqSizeOutStream (the output is a stream, or a MemoryOutStream for the
/// buffer mode).
class _SeqSizeOutStream implements OutStream {
  OutStream realStream;
  int processed = 0;
  _SeqSizeOutStream(this.realStream);

  // SeqSizeOutStream_Write
  @override
  void write(Uint8List buf, int off, int len) {
    realStream.write(buf, off, len);
    processed += len;
  }

  @override
  void flush() {}
}

// FILTER_BUF_SIZE
const int _filterBufSize = 1 << 20;

// g_Funcs_BranchConv_RISC_Enc
const List<BranchConvFunc> _funcsBranchConvRiscEnc = [
  z7BranchConvPpcEnc,
  z7BranchConvIa64Enc,
  z7BranchConvArmEnc,
  z7BranchConvArmtEnc,
  z7BranchConvSparcEnc,
  z7BranchConvArm64Enc,
  z7BranchConvRiscvEnc,
];

// XzBcFilterStateBase_Filter_Enc
int _xzBcFilterStateBaseFilterEnc(
    XzBcFilterStateBase p, Uint8List data, int off, int size) {
  switch (p.methodId) {
    case xzIdDelta:
      deltaEncode(p.deltaState, p.delta, data, off, size);
    case xzIdX86:
      size = z7BranchConvStX86Enc(data, off, size, p.ip, p.x86State) - off;
    default:
      if (p.methodId >= xzIdPpc) {
        final i = p.methodId - xzIdPpc;
        if (i < _funcsBranchConvRiscEnc.length) {
          size = _funcsBranchConvRiscEnc[i](data, off, size, p.ip) - off;
        }
      }
  }
  p.ip = (p.ip + size) & _m32;
  return size;
}

const XzBcFilterFunc _filterEnc = _xzBcFilterStateBaseFilterEnc;

/// CSeqInFilter
class _SeqInFilter implements InStream {
  InStream? realStream;
  XzBcFilterState? stateCoder;
  Uint8List? _buf;
  int _curPos = 0;
  int _endPos = 0;
  bool _srcWasFinished = false;

  // SeqInFilter_Init
  int init(XzFilter props) {
    _buf ??= Uint8List(_filterBufSize);
    _curPos = _endPos = 0;
    _srcWasFinished = false;
    final sc =
        xzStateCoderBcSetFromMethodFunc(stateCoder, props.id, _filterEnc);
    if (sc == null) return szErrorUnsupported;
    stateCoder = sc;
    final r = sc.setProps(props.props, props.propsSize);
    if (r != szOk) return r;
    sc.init();
    return szOk;
  }

  // SeqInFilter_Read
  @override
  int read(Uint8List data, int off, int size) {
    if (size == 0) return 0;
    final buf = _buf!;
    final sc = stateCoder!;
    for (;;) {
      if (!_srcWasFinished && _curPos == _endPos) {
        _curPos = 0;
        _endPos = realStream!.read(buf, 0, _filterBufSize);
        if (_endPos == 0) _srcWasFinished = true;
      }
      sc.code2(data, off, size, buf, _curPos, _endPos - _curPos,
          _srcWasFinished, coderFinishAny);
      _curPos += sc.srcProcessed;
      if (sc.destProcessed != 0 || sc.srcProcessed == 0) {
        return sc.destProcessed;
      }
    }
  }

  // SeqInFilter_Free
  void free() {
    stateCoder = null;
    _buf = null;
  }
}

/// CLzma2WithFilters
class _Lzma2WithFilters {
  Lzma2Enc? lzma2;
  final _SeqInFilter filter = _SeqInFilter();

  // Lzma2WithFilters_Create
  Lzma2Enc create() => lzma2 ??= Lzma2Enc();

  // Lzma2WithFilters_Free
  void free() {
    filter.free();
    lzma2?.destroy();
    lzma2 = null;
  }
}

/// CXzEncBlockInfo
class _XzEncBlockInfo {
  int unpackSize = 0;
  int totalSize = 0;
  int headerSize = 0;
}

// Xz_CompressBlock. With [outStream] the block is written there (header
// without sizes, data, padding, check). Without it (buffer mode) the header
// with sizes goes to [outBufHeader] and the rest to [outBufData]. The input
// is [inStream], or inBuf[0, inBufSize) when [inStream] is null. Returns
// inStreamFinished.
bool _xzCompressBlock(
    _Lzma2WithFilters lzmaf,
    OutStream? outStream,
    MemoryOutStream? outBufHeader,
    MemoryOutStream? outBufData,
    InStream? inStream,
    Uint8List? inBuf,
    int inBufSize,
    XzProps props,
    ProgressCallback? progress,
    _XzEncBlockInfo blockSizes) {
  final checkInStream = _SeqCheckInStream();
  final block = XzBlock();
  var filterIndex = 0;
  XzFilter? filter;
  XzFilterProps? fp = props.filterProps;
  if (fp.id == 0) fp = null;

  final lzma2 = lzmaf.create();

  lzma2.setProps(props.lzma2Props);

  // XzBlock_ClearFlags_SetNumFilters
  block.flags = (1 + (fp != null ? 1 : 0)) - 1;

  if (fp != null) {
    filter = block.filters[filterIndex++];
    filter.id = fp.id;
    filter.propsSize = 0;

    if (fp.id == xzIdDelta) {
      filter.props[0] = (fp.delta - 1) & 0xFF;
      filter.propsSize = 1;
    } else if (fp.ipDefined) {
      setUint32LE(filter.props, 0, fp.ip);
      filter.propsSize = 4;
    }
  }

  {
    final f = block.filters[filterIndex++];
    f.id = xzIdLzma2;
    f.propsSize = 1;
    f.props[0] = lzma2.writeProperties();
  }

  final seqSizeOutStream = _SeqSizeOutStream(outStream ?? outBufData!);

  if (outStream != null) _xzBlockWriteHeader(block, seqSizeOutStream);

  checkInStream.init(props.checkId);

  checkInStream.realStream = inStream;
  checkInStream.data = inBuf;
  checkInStream.limit = props.blockSize;
  if (inStream == null) checkInStream.limit = inBufSize;

  if (fp != null) {
    lzmaf.filter.realStream = checkInStream;
    final r = lzmaf.filter.init(filter!);
    if (r != szOk) {
      throw const SevenZipException(
          'xz: unsupported filter', SevenZipError.unsupportedMethod);
    }
  }

  {
    final useStream = fp != null || inStream != null;

    if (!useStream) {
      checkInStream.check.update(inBuf!, 0, inBufSize);
      checkInStream.processed = inBufSize;
    }

    if (useStream) {
      lzma2.encode(seqSizeOutStream, fp != null ? lzmaf.filter : checkInStream,
          progress: progress);
    } else {
      lzma2.encodeMem(seqSizeOutStream, inBuf!, inBufSize, progress: progress);
    }

    blockSizes.unpackSize = checkInStream.processed;
  }
  {
    final buf = Uint8List(4 + xzCheckSizeMax);
    final padSize = _xzGetPadSize(seqSizeOutStream.processed);
    final packSize = seqSizeOutStream.processed;

    checkInStream.getDigest(buf, 4);
    seqSizeOutStream.write(
        buf, 4 - padSize, padSize + xzFlagsGetCheckSize(props.checkId));

    blockSizes.totalSize = seqSizeOutStream.processed - padSize;

    if (outStream == null) {
      final headerOut = _SeqSizeOutStream(outBufHeader!);

      block.unpackSize = blockSizes.unpackSize;
      block.flags |= xzBfUnpackSize; // XzBlock_SetHasUnpackSize

      block.packSize = packSize;
      block.flags |= xzBfPackSize; // XzBlock_SetHasPackSize

      _xzBlockWriteHeader(block, headerOut);

      blockSizes.headerSize = headerOut.processed;
      blockSizes.totalSize += headerOut.processed;
    }
  }

  if (inStream != null) return checkInStream.realStreamFinished;
  if (checkInStream.processed != inBufSize) {
    throw const SevenZipException('xz encoder: SZ_ERROR_FAIL');
  }
  return false;
}

// ---------------------------------------------------------------------------
// CXzEnc

/// CXzEnc: XzEnc_Create, XzEnc_SetProps, XzEnc_SetDataSize, XzEnc_Encode.
class XzEnc {
  XzProps _xzProps;
  int _expectedDataSize = -1;
  final _XzEncIndex _xzIndex = _XzEncIndex();
  final _Lzma2WithFilters _lzmaf = _Lzma2WithFilters();

  // XzEnc_Create
  XzEnc() : _xzProps = XzProps()..normalize();

  /// The normalized properties.
  XzProps get props => _xzProps;

  // XzEnc_SetProps
  void setProps(XzProps props) {
    _xzProps = props.copy()..normalize();
  }

  // XzEnc_SetDataSize
  void setDataSize(int expectedDataSize) {
    _expectedDataSize = expectedDataSize;
  }

  /// The expected data size (only used by the multithreaded scheduler of
  /// the C code).
  int get expectedDataSize => _expectedDataSize;

  // XzEnc_Destroy
  void destroy() => _lzmaf.free();

  // The multithreaded path of XzEnc_Encode (MtCoder with
  // XzEnc_MtCallback_Code / XzEnc_MtCallback_Write), run sequentially.
  // lib/src/parallel.dart runs the same two halves ([xzEncodeMtBlock] and
  // [XzMtBlockWriter]) with the blocks encoded in worker isolates.
  void _encodeMtBlocks(
      OutStream outStream, InStream inStream, ProgressCallback? progress) {
    final props = _xzProps;
    final blockSize = xzMtBlockSize(props);
    final writer = XzMtBlockWriter._(props.checkId, outStream, _xzIndex);
    final blockData = MemoryOutStream(1 << 16);
    for (;;) {
      // MtCoder: SeqInStream_ReadMax of one block; the block is the last
      // one when it is not full.
      blockData.truncate(0);
      blockData.position = 0;
      final size = copyStream(inStream, blockData, limit: blockSize);
      final finished = size != blockSize;

      final inOff = writer.inOffset, outOff = writer.outOffset;
      final block = _encodeMtBlock(_lzmaf, props, blockData.toBytes(), size,
          progress == null ? null : (i, o) => progress(i + inOff, o + outOff));
      writer.write(block);
      if (finished) break;
    }
  }

  /// XzEnc_Encode: reads [inStream] to its end and writes one xz stream to
  /// [outStream]. Throws [SevenZipException] on errors.
  void encode(OutStream outStream, InStream inStream,
      {ProgressCallback? progress}) {
    final props = _xzProps;

    _xzIndex.init();
    // XzEncIndex_PreAlloc only reserves memory.

    _xzWriteHeader(props.checkId, outStream);

    if (props.numBlockThreadsReduced > 1) {
      _encodeMtBlocks(outStream, inStream, progress);
    } else {
      var writeStartSizes = false;
      var inOffset = 0;
      var outOffset = 0;

      if (props.blockSize != xzPropsBlockSizeSolid) {
        writeStartSizes = props.forceWriteSizesInHeader > 0;
      }

      final bufData = writeStartSizes ? MemoryOutStream(1 << 16) : null;
      final bufHeader =
          writeStartSizes ? MemoryOutStream(xzBlockHeaderSizeMax) : null;

      for (;;) {
        final blockSizes = _XzEncBlockInfo();
        if (writeStartSizes) {
          bufData!.truncate(0);
          bufData.position = 0;
          bufHeader!.truncate(0);
          bufHeader.position = 0;
        }

        final inOff = inOffset, outOff = outOffset;
        final inStreamFinished = _xzCompressBlock(
            _lzmaf,
            writeStartSizes ? null : outStream,
            bufHeader,
            bufData,
            inStream,
            null,
            0,
            props,
            progress == null ? null : (i, o) => progress(i + inOff, o + outOff),
            blockSizes);

        {
          final totalPackFull =
              blockSizes.totalSize + _xzGetPadSize(blockSizes.totalSize);

          if (writeStartSizes) {
            outStream.write(bufHeader!.toBytes(), 0, blockSizes.headerSize);
            outStream.write(
                bufData!.toBytes(), 0, totalPackFull - blockSizes.headerSize);
          }

          _xzIndex.addIndexRecord(blockSizes.unpackSize, blockSizes.totalSize);

          inOffset += blockSizes.unpackSize;
          outOffset += totalPackFull;
        }

        if (inStreamFinished) break;
      }
    }

    _xzIndex.writeFooter(props.checkId, outStream);
    outStream.flush();
  }
}

/// Xz_Encode
void xzEncode(OutStream outStream, InStream inStream, XzProps props,
    {ProgressCallback? progress}) {
  final xz = XzEnc();
  try {
    xz.setProps(props);
    xz.encode(outStream, inStream, progress: progress);
  } finally {
    xz.destroy();
  }
}

/// Xz_EncodeEmpty
void xzEncodeEmpty(OutStream outStream) {
  final xzIndex = _XzEncIndex();
  _xzWriteHeader(0, outStream);
  xzIndex.writeFooter(0, outStream);
  outStream.flush();
}

// ---------------------------------------------------------------------------
// The two halves of the multithreaded path, for lib/src/parallel.dart.

/// The block size of the multithreaded path for normalized [props] (the
/// blocks MtCoder reads). Throws when [props] do not use that path.
int xzMtBlockSize(XzProps props) {
  if (props.blockSize == xzPropsBlockSizeSolid ||
      props.blockSize == xzPropsBlockSizeAuto) {
    throw const SevenZipException('xz encoder: SZ_ERROR_FAIL');
  }
  return props.blockSize;
}

/// One block of the multithreaded path, encoded: the block header with
/// sizes, the data, the padding and the check, ready to be written.
class XzEncodedMtBlock {
  /// The bytes to write (empty for an empty input block, which is not
  /// written: v23.02).
  final Uint8List bytes;
  final int unpackSize;

  /// The block size the index records (without the padding).
  final int totalSize;
  const XzEncodedMtBlock(this.bytes, this.unpackSize, this.totalSize);
}

// XzEnc_MtCallback_Code
XzEncodedMtBlock _encodeMtBlock(_Lzma2WithFilters lzmaf, XzProps props,
    Uint8List data, int size, ProgressCallback? progress) {
  final bInfo = _XzEncBlockInfo();
  // v23.02: we don't compress empty blocks
  if (size == 0) return XzEncodedMtBlock(Uint8List(0), 0, 0);
  final dest = MemoryOutStream(1 << 16);
  final destHeader = MemoryOutStream(xzBlockHeaderSizeMax);
  _xzCompressBlock(lzmaf, null, destHeader, dest, null, data, size, props,
      progress, bInfo);
  final totalPackFull = bInfo.totalSize + _xzGetPadSize(bInfo.totalSize);
  final out = Uint8List(totalPackFull);
  out.setRange(0, bInfo.headerSize, destHeader.toBytes());
  out.setRange(bInfo.headerSize, totalPackFull, dest.toBytes());
  return XzEncodedMtBlock(out, bInfo.unpackSize, bInfo.totalSize);
}

/// XzEnc_MtCallback_Code for one block data[0, size) with the normalized
/// [props] of an [XzEnc] ([XzEnc.props]) on the multithreaded path. Blocks
/// are independent, so they can be encoded anywhere, in any order.
XzEncodedMtBlock xzEncodeMtBlock(XzProps props, Uint8List data, int size,
    {ProgressCallback? progress}) {
  final lzmaf = _Lzma2WithFilters();
  try {
    return _encodeMtBlock(lzmaf, props, data, size, progress);
  } finally {
    lzmaf.free();
  }
}

/// The writing half of the multithreaded path: the stream header, the
/// blocks in order (XzEnc_MtCallback_Write), the index and the footer.
class XzMtBlockWriter {
  final int _checkId;
  final OutStream _out;
  final _XzEncIndex _index;

  /// Unpacked and packed bytes written so far (for progress).
  int inOffset = 0;
  int outOffset = 0;

  XzMtBlockWriter._(this._checkId, this._out, this._index);

  /// Writes the stream header of normalized [props] to [out].
  factory XzMtBlockWriter(XzProps props, OutStream out) {
    final w = XzMtBlockWriter._(props.checkId, out, _XzEncIndex()..init());
    _xzWriteHeader(props.checkId, out);
    return w;
  }

  // XzEnc_MtCallback_Write
  void write(XzEncodedMtBlock block) {
    // v23.02: we don't write empty blocks
    if (block.unpackSize == 0) return;
    _out.write(block.bytes, 0, block.bytes.length);
    _index.addIndexRecord(block.unpackSize, block.totalSize);
    inOffset += block.unpackSize;
    outOffset += block.bytes.length;
  }

  /// Writes the index and the stream footer.
  void finish() {
    _index.writeFooter(_checkId, _out);
    _out.flush();
  }
}

// ---------------------------------------------------------------------------
// XzEncoder.cpp

// g_NamePairs (XzEncoder.cpp)
const List<(int, String)> _namePairs = [
  (xzIdDelta, 'Delta'),
  (xzIdX86, 'BCJ'),
  (xzIdPpc, 'PPC'),
  (xzIdIa64, 'IA64'),
  (xzIdArm, 'ARM'),
  (xzIdArmt, 'ARMT'),
  (xzIdSparc, 'SPARC'),
];

// FilterIdFromName
int _filterIdFromName(String name) {
  final l = name.toLowerCase();
  for (final pair in _namePairs) {
    if (pair.$2.toLowerCase() == l) return pair.$1;
  }
  return -1;
}

SevenZipException _invalidArg(String what) =>
    InvalidArgException('Invalid xz property: $what');

// ConvertStringToUInt32 (StringToInt.cpp): returns (value, end index).
(int, int) _convertStringToUInt32(String s, int start) {
  final (v, n) = convertStringToUInt32(s, start);
  return (v, start + n);
}

/// NCompress::NXz::CEncoder: the xz encoder with 7-Zip's coder property
/// interface.
class XzEncoder implements Compressor {
  XzProps xzProps = XzProps();
  final XzEnc _encoder = XzEnc();

  // CEncoder::InitCoderProps
  void initCoderProps() => xzProps = XzProps();

  /// CEncoder::SetCheckSize: 0, 4, 8 or 32 bytes.
  void setCheckSize(int checkSizeInBytes) {
    int id;
    switch (checkSizeInBytes) {
      case 0:
        id = xzCheckNo;
      case 4:
        id = xzCheckCrc32;
      case 8:
        id = xzCheckCrc64;
      case 32:
        id = xzCheckSha256;
      default:
        throw _invalidArg('check size $checkSizeInBytes');
    }
    xzProps.checkId = id;
  }

  /// CEncoder::SetCoderProp
  void setCoderProp(CoderProp prop) {
    final v = prop.value;
    if (prop.id == CoderPropId.numThreads) {
      if (v.vt != VarType.ui4) throw _invalidArg('mt');
      xzProps.numTotalThreads = v.intValue;
      return;
    }

    if (prop.id == CoderPropId.checkSize) {
      if (v.vt != VarType.ui4) throw _invalidArg('check');
      setCheckSize(v.intValue);
      return;
    }

    if (prop.id == CoderPropId.blockSize2) {
      if (v.vt != VarType.ui4 && v.vt != VarType.ui8) {
        throw _invalidArg('block size');
      }
      xzProps.blockSize = v.intValue;
      return;
    }

    if (prop.id == CoderPropId.reduceSize) {
      if (v.vt != VarType.ui8) throw _invalidArg('reduce');
      xzProps.reduceSize = v.intValue;
      return;
    }

    if (prop.id == CoderPropId.filter) {
      if (v.vt == VarType.ui4) {
        final id32 = v.intValue;
        if (id32 == xzIdDelta) throw _invalidArg('filter');
        xzProps.filterProps.id = id32;
      } else {
        if (v.vt != VarType.bstr) throw _invalidArg('filter');

        final name = v.stringValue;
        var pos = 0;
        var (id32, end) = _convertStringToUInt32(name, 0);

        if (end != 0) {
          pos = end;
        } else {
          if (name.length >= 5 &&
              name.substring(0, 5).toLowerCase() == 'delta') {
            pos = 5; // strlen("Delta");
            id32 = xzIdDelta;
          } else {
            final filterId = _filterIdFromName(name);
            if (filterId < 0) throw _invalidArg('filter $name');
            id32 = filterId;
          }
        }

        if (id32 == xzIdDelta) {
          final c = pos < name.length ? name[pos] : '';
          if (c != '-' && c != ':') throw _invalidArg('filter $name');
          pos++;
          final (delta, end2) = _convertStringToUInt32(name, pos);
          if (end2 == pos || end2 != name.length || delta == 0 || delta > 256) {
            throw _invalidArg('filter $name');
          }
          xzProps.filterProps.delta = delta;
        }

        xzProps.filterProps.id = id32;
      }
      return;
    }

    setLzma2Prop(xzProps.lzma2Props, prop);
  }

  /// CEncoder::SetCoderProperties
  void setCoderProperties(Iterable<CoderProp> props) {
    xzProps = XzProps();
    for (final p in props) {
      setCoderProp(p);
    }
  }

  /// CEncoder::SetCoderPropertiesOpt (kExpectedDataSize).
  void setExpectedDataSize(int size) => _encoder.setDataSize(size);

  @override
  Uint8List get props => Uint8List(0);

  /// CEncoder::Code: writes one xz stream. Returns the number of bytes
  /// read.
  @override
  int encode(InStream input, OutStream output, {ProgressCallback? progress}) {
    final counting = CountingInStream(input);
    _encoder.setProps(xzProps);
    try {
      _encoder.encode(output, counting, progress: progress);
    } finally {
      _encoder.destroy();
    }
    return counting.count;
  }
}
