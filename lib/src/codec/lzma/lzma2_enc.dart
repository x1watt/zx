// Port of C/Lzma2Enc.c (LZMA SDK 26.01).
//
// Lzma2EncProps_Normalize follows the multithreaded build of the SDK (as
// used by 7-Zip), so the block size and block thread decisions are the same
// as 7-Zip's for the same -m switches. The encoding itself runs on the
// calling thread:
//   * one block thread (the usual case, and every "solid" setting): the
//     Lzma2Enc_EncodeMt1 stream path, byte identical to the SDK;
//   * several block threads: the blocks that MtCoder would hand to worker
//     threads are encoded one after the other with the same per block code
//     path (Lzma2Enc_MtCallback_Code), so the output is the same as the
//     SDK's multithreaded output. [Lzma2Enc._encodeMtBlocks] is the seam
//     where the blocks could be sent to isolates.

import 'dart:typed_data';

import '../../io/streams.dart';
import '../codec.dart';
import 'lzma_dec.dart'
    show lzmaPropsSize, szErrorOutputEof, szErrorFail, szErrorParam, szOk;
import 'lzma_enc.dart';

const int _lzma2ControlLzma = 1 << 7;
const int _lzma2ControlCopyNoReset = 2;
const int _lzma2ControlCopyResetDic = 1;
const int _lzma2ControlEof = 0;

const int _lzma2LclpMax = 4;

// LZMA2_DIC_SIZE_FROM_PROP
int _lzma2DicSizeFromProp(int p) => (2 | (p & 1)) << (p ~/ 2 + 11);

const int _lzma2PackSizeMax = 1 << 16;
const int _lzma2CopyChunkSize = _lzma2PackSizeMax;
const int _lzma2UnpackSizeMax = 1 << 21;
const int _lzma2KeepWindowSize = _lzma2UnpackSizeMax;

const int _lzma2ChunkSizeCompressedMax = (1 << 16) + 16;

/// LZMA2_ENC_PROPS_BLOCK_SIZE_AUTO
const int lzma2BlockSizeAuto = 0;

/// LZMA2_ENC_PROPS_BLOCK_SIZE_SOLID ((UInt64)(Int64)-1)
const int lzma2BlockSizeSolid = -1;

// MTCODER_THREADS_MAX of the multithreaded build.
const int _mtCoderThreadsMax = 256;

/// CLzma2EncProps
class Lzma2EncProps {
  LzmaEncProps lzmaProps = LzmaEncProps();

  /// [lzma2BlockSizeAuto], [lzma2BlockSizeSolid] or a size in bytes.
  int blockSize = lzma2BlockSizeAuto;
  int numBlockThreadsReduced = -1;
  int numBlockThreadsMax = -1;
  int numTotalThreads = -1;
  int numThreadGroups = 0;

  // Lzma2EncProps_Init
  Lzma2EncProps();

  Lzma2EncProps copy() => Lzma2EncProps()
    ..lzmaProps = lzmaProps.copy()
    ..blockSize = blockSize
    ..numBlockThreadsReduced = numBlockThreadsReduced
    ..numBlockThreadsMax = numBlockThreadsMax
    ..numTotalThreads = numTotalThreads
    ..numThreadGroups = numThreadGroups;

  // Lzma2EncProps_Normalize
  void normalize() {
    int t1, t1n, t2, t2r, t3;
    {
      final lzmaProps2 = lzmaProps.copy()..normalize();
      t1n = lzmaProps2.numThreads;
    }

    t1 = lzmaProps.numThreads;
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

    lzmaProps.numThreads = t1;

    t2r = t2;

    final fileSize = lzmaProps.reduceSize;

    if (blockSize != lzma2BlockSizeSolid &&
        blockSize != lzma2BlockSizeAuto &&
        (fileSize < 0 || blockSize < fileSize)) {
      lzmaProps.reduceSize = blockSize;
    }

    lzmaProps.normalize();

    lzmaProps.reduceSize = fileSize;

    t1 = lzmaProps.numThreads;

    if (blockSize == lzma2BlockSizeSolid) {
      t2r = t2 = 1;
      t3 = t1;
    } else if (blockSize == lzma2BlockSizeAuto && t2 <= 1) {
      /* if there is no block multi-threading, we use SOLID block */
      blockSize = lzma2BlockSizeSolid;
    } else {
      if (blockSize == lzma2BlockSizeAuto) {
        const kMinSize = 1 << 20;
        const kMaxSize = 1 << 28;
        final dictSize = lzmaProps.dictSize;
        var bs = dictSize << 2;
        if (bs < kMinSize) bs = kMinSize;
        if (bs > kMaxSize) bs = kMaxSize;
        if (bs < dictSize) bs = dictSize;
        bs += kMinSize - 1;
        bs &= ~(kMinSize - 1);
        blockSize = bs;
      }

      if (t2 > 1 && fileSize >= 0) {
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
}

/// CLimitedSeqInStream
class _LimitedSeqInStream implements InStream {
  final InStream realStream;
  int limit = -1;
  int processed = 0;
  bool finished = false;
  _LimitedSeqInStream(this.realStream);

  // LimitedSeqInStream_Init
  void init() {
    limit = -1;
    processed = 0;
    finished = false;
  }

  // LimitedSeqInStream_Read
  @override
  int read(Uint8List buf, int off, int len) {
    var size2 = len;
    if (limit >= 0) {
      final rem = limit - processed;
      if (size2 > rem) size2 = rem;
    }
    if (size2 != 0) {
      size2 = realStream.read(buf, off, size2);
      finished = size2 == 0;
      processed += size2;
    }
    return size2;
  }
}

/// CLzma2EncInt
class _Lzma2EncInt {
  LzmaEnc? enc;
  bool propsAreSet = false;
  int propsByte = 0;
  bool needInitState = false;
  bool needInitProp = false;
  int srcPos = 0;

  // Lzma2EncInt_InitStream
  void initStream(Lzma2EncProps props) {
    if (!propsAreSet) {
      enc!.setProps(props.lzmaProps);
      final propsEncoded = enc!.writeProperties();
      assert(propsEncoded.length == lzmaPropsSize);
      propsByte = propsEncoded[0];
      propsAreSet = true;
    }
  }

  // Lzma2EncInt_InitBlock
  void initBlock() {
    srcPos = 0;
    needInitState = true;
    needInitProp = true;
  }

  // Output of encodeSubblock (the C *packSizeRes).
  int packSizeRes = 0;

  // Lzma2EncInt_EncodeSubblock
  int encodeSubblock(Uint8List outBuf, int packSizeLimit, OutStream outStream) {
    final enc = this.enc!;
    var packSize = packSizeLimit;
    var unpackSize = _lzma2UnpackSizeMax;
    final lzHeaderSize = 5 + (needInitProp ? 1 : 0);
    bool useCopyBlock;
    int res;

    packSizeRes = 0;
    if (packSize < lzHeaderSize) return szErrorOutputEof;
    packSize -= lzHeaderSize;

    enc.saveState();
    res = enc.codeOneMemBlock(needInitState, outBuf, lzHeaderSize, packSize,
        _lzma2PackSizeMax, unpackSize);
    packSize = enc.memBlockDestLen;
    unpackSize = enc.memBlockUnpackSize;

    if (unpackSize == 0) return res;

    if (res == szOk) {
      useCopyBlock = packSize + 2 >= unpackSize || packSize > (1 << 16);
    } else {
      if (res != szErrorOutputEof) return res;
      res = szOk;
      useCopyBlock = true;
    }

    if (useCopyBlock) {
      var destPos = 0;
      final src = enc.curBufArray;

      while (unpackSize > 0) {
        final u =
            unpackSize < _lzma2CopyChunkSize ? unpackSize : _lzma2CopyChunkSize;
        if (packSizeLimit - destPos < u + 3) return szErrorOutputEof;
        outBuf[destPos++] =
            srcPos == 0 ? _lzma2ControlCopyResetDic : _lzma2ControlCopyNoReset;
        outBuf[destPos++] = (u - 1) >> 8;
        outBuf[destPos++] = u - 1;
        final from = enc.curBufPos - unpackSize;
        outBuf.setRange(destPos, destPos + u, src, from);
        unpackSize -= u;
        destPos += u;
        srcPos += u;

        packSizeRes += destPos;
        outStream.write(outBuf, 0, destPos);
        destPos = 0;
      }

      enc.restoreState();
      return szOk;
    }

    {
      var destPos = 0;
      final u = unpackSize - 1;
      final pm = packSize - 1;
      final mode =
          srcPos == 0 ? 3 : (needInitState ? (needInitProp ? 2 : 1) : 0);

      outBuf[destPos++] = _lzma2ControlLzma | (mode << 5) | ((u >> 16) & 0x1F);
      outBuf[destPos++] = u >> 8;
      outBuf[destPos++] = u;
      outBuf[destPos++] = pm >> 8;
      outBuf[destPos++] = pm;

      if (needInitProp) outBuf[destPos++] = propsByte;

      needInitProp = false;
      needInitState = false;
      destPos += packSize;
      srcPos += unpackSize;

      outStream.write(outBuf, 0, destPos);

      packSizeRes = destPos;
      return szOk;
    }
  }
}

/// CLzma2Enc: the LZMA2 encoder (Lzma2Enc_Create / Lzma2Enc_Destroy).
class Lzma2Enc {
  Lzma2EncProps _props = Lzma2EncProps();
  int _expectedDataSize = -1;
  Uint8List? _tempBufLzma;
  final _Lzma2EncInt _coder = _Lzma2EncInt();

  // Lzma2Enc_Create
  Lzma2Enc() {
    _props.normalize();
  }

  /// The normalized properties.
  Lzma2EncProps get props => _props;

  /// Lzma2Enc_SetProps. Throws [SevenZipException] when lc + lp > 4.
  void setProps(Lzma2EncProps props) {
    final lzmaProps = props.lzmaProps.copy()..normalize();
    if (lzmaProps.lc + lzmaProps.lp > _lzma2LclpMax) {
      throw const SevenZipException(
          'LZMA2: lc + lp must not exceed 4', SevenZipError.unsupported);
    }
    _props = props.copy()..normalize();
  }

  /// Lzma2Enc_SetDataSize. -1 = unknown.
  void setDataSize(int expectedDataSize) {
    _expectedDataSize = expectedDataSize;
  }

  /// Lzma2Enc_WriteProperties: the one byte LZMA2 dictionary property.
  int writeProperties() {
    final dicSize = _props.lzmaProps.getDictSize();
    var i = 0;
    for (; i < 40; i++) {
      if (dicSize <= _lzma2DicSizeFromProp(i)) break;
    }
    return i;
  }

  // Lzma2Enc_EncodeMt1 for the stream input and stream output case.
  int _encodeMt1Stream(_Lzma2EncInt p, OutStream outStream, InStream inStream,
      bool finished, ProgressCallback? progress) {
    var unpackTotal = 0;
    var packTotal = 0;

    p.enc ??= LzmaEnc();
    final limitedInStream = _LimitedSeqInStream(inStream);
    final tempBuf = _tempBufLzma ??= Uint8List(_lzma2ChunkSizeCompressedMax);

    p.initStream(_props);

    for (;;) {
      var res = szOk;

      p.initBlock();

      limitedInStream.init();
      limitedInStream.limit = _props.blockSize;

      {
        var expected = -1;
        if (_expectedDataSize >= 0 && _expectedDataSize >= unpackTotal) {
          expected = _expectedDataSize - unpackTotal;
        }
        if (_props.blockSize != lzma2BlockSizeSolid &&
            (expected < 0 || expected > _props.blockSize)) {
          expected = _props.blockSize;
        }

        p.enc!.setDataSize(expected);

        final r = p.enc!.prepareForLzma2(limitedInStream, _lzma2KeepWindowSize);
        if (r != szOk) return r;
      }

      for (;;) {
        res =
            p.encodeSubblock(tempBuf, _lzma2ChunkSizeCompressedMax, outStream);
        if (res != szOk) break;
        final packSize = p.packSizeRes;
        packTotal += packSize;
        if (progress != null) progress(unpackTotal + p.srcPos, packTotal);
        if (packSize == 0) break;
      }

      p.enc!.finish();

      unpackTotal += p.srcPos;

      if (res != szOk) return res;

      if (p.srcPos != limitedInStream.processed) return szErrorFail;

      if (limitedInStream.finished) {
        if (finished) {
          outStream.write(Uint8List(1)..[0] = _lzma2ControlEof, 0, 1);
        }
        return szOk;
      }
    }
  }

  // Lzma2Enc_EncodeMt1 for one in memory block (the MtCoder callback
  // Lzma2Enc_MtCallback_Code). The block is src[0, srcSize).
  int _encodeMt1Mem(_Lzma2EncInt p, OutStream outStream, Uint8List src,
      int srcSize, bool finished, int unpackBase, ProgressCallback? progress) {
    var unpackTotal = 0;
    var packTotal = 0;

    p.enc ??= LzmaEnc();
    final tempBuf = _tempBufLzma ??= Uint8List(_lzma2ChunkSizeCompressedMax);

    p.initStream(_props);

    for (;;) {
      var res = szOk;

      p.initBlock();

      var inSizeCur = srcSize - unpackTotal;
      if (_props.blockSize != lzma2BlockSizeSolid &&
          inSizeCur > _props.blockSize) {
        inSizeCur = _props.blockSize;
      }

      {
        final r = p.enc!
            .memPrepare(src, unpackTotal, inSizeCur, _lzma2KeepWindowSize);
        if (r != szOk) return r;
      }

      for (;;) {
        res =
            p.encodeSubblock(tempBuf, _lzma2ChunkSizeCompressedMax, outStream);
        if (res != szOk) break;
        final packSize = p.packSizeRes;
        packTotal += packSize;
        if (progress != null) {
          progress(unpackBase + unpackTotal + p.srcPos, packTotal);
        }
        if (packSize == 0) break;
      }

      p.enc!.finish();

      unpackTotal += p.srcPos;

      if (res != szOk) return res;

      if (p.srcPos != inSizeCur) return szErrorFail;

      if (unpackTotal == srcSize) {
        if (finished) {
          outStream.write(Uint8List(1)..[0] = _lzma2ControlEof, 0, 1);
        }
        return szOk;
      }
    }
  }

  // The multithreaded path of Lzma2Enc_Encode2 (MtCoder with
  // Lzma2Enc_MtCallback_Code / Lzma2Enc_MtCallback_Write), run
  // sequentially. This is the seam for a parallel implementation: each
  // block is independent (it resets the dictionary, the state and the
  // properties), so blocks can be encoded in isolates and their outputs
  // written in order.
  int _encodeMtBlocks(
      OutStream outStream, InStream inStream, ProgressCallback? progress) {
    final blockSize = _props.blockSize;
    final block = Uint8List(blockSize);
    var total = 0;
    for (;;) {
      // SeqInStream_ReadMax
      final size = readFully(inStream, block, 0, blockSize);
      final finished = size != blockSize;
      final res = _encodeMt1Mem(
          _coder, outStream, block, size, finished, total, progress);
      if (res != szOk) return res;
      total += size;
      if (finished) return szOk;
    }
  }

  /// Lzma2Enc_Encode2 with stream input and output: reads [inStream] to
  /// the end and writes the LZMA2 stream (ending with the 0x00 end marker)
  /// to [outStream].
  void encode(OutStream outStream, InStream inStream,
      {ProgressCallback? progress}) {
    _coder.propsAreSet = false;

    int res;
    if (_props.numBlockThreadsReduced > 1) {
      res = _encodeMtBlocks(outStream, inStream, progress);
    } else {
      res = _encodeMt1Stream(_coder, outStream, inStream, true, progress);
    }
    _throwIfError(res);
  }

  /// Lzma2Enc_Encode2 with in memory input (inData, inDataSize) and stream
  /// output: encodes src[0, srcSize) and writes the LZMA2 stream (ending
  /// with the 0x00 end marker) to [outStream]. XzEnc uses this form for
  /// the blocks of its multithreaded path.
  void encodeMem(OutStream outStream, Uint8List src, int srcSize,
      {ProgressCallback? progress}) {
    _coder.propsAreSet = false;

    int res;
    if (_props.numBlockThreadsReduced > 1) {
      res = _encodeMtBlocks(outStream,
          MemoryInStream(Uint8List.sublistView(src, 0, srcSize)), progress);
    } else {
      res = _encodeMt1Mem(_coder, outStream, src, srcSize, true, 0, progress);
    }
    _throwIfError(res);
  }

  void _throwIfError(int res) {
    if (res != szOk) {
      if (res == szErrorParam) {
        throw const SevenZipException(
            'LZMA2 encoder: unsupported parameters', SevenZipError.unsupported);
      }
      throw SevenZipException('LZMA2 encoder error $res');
    }
  }

  /// Lzma2Enc_Destroy: releases the big buffers.
  void destroy() {
    _coder.enc?.destroy();
    _coder.enc = null;
    _tempBufLzma = null;
  }
}
