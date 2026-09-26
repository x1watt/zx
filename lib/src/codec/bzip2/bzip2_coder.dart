// The bzip2 coders: the compression half of bzlib.c of bzip2 1.0.8 (the
// input stage: add_pair_to_block, flush_RL, ADD_CHAR_TO_BLOCK,
// copy_input_until_stop, handle_compress, prepare_new_block) as a
// [Compressor], and the decoder registration for MethodId.bzip2.
// bzip2/libbzip2 is Copyright (C) 1996-2019 Julian Seward, under the bzip2
// license (BSD style, see LICENSE).
//
// The output is a complete .bz2 stream ("BZh", the blocks, the end of
// stream marker), byte for byte what libbzip2 1.0.8 writes when it is fed
// with BZ_RUN and then finished with BZ_FINISH (as the bzip2 program and
// BZ2_bzWrite do) at the same block size and work factor.

import 'dart:typed_data';

import '../../common/method_props.dart';
import '../../io/streams.dart';
import '../codec.dart';
import 'bzip2_tables.dart';
import 'compress.dart';
import 'decompress.dart';

export 'compress.dart'
    show
        Bzip2BitWriter,
        Bzip2Block,
        Bzip2BlockEncoder,
        bz2WriteStreamHeader,
        bz2WriteStreamTrailer;
export 'decompress.dart' show Bzip2DecoderStream, bzip2Decoder;

/// The bzip2 compressor (a .bz2 stream). [blockSize100k] is 1..9 (the
/// block size in units of 100000 bytes), [workFactor] 0..250 as in
/// BZ2_bzCompressInit (0 means the default, 30).
class Bzip2Compressor implements Compressor {
  final int blockSize100k;
  final int workFactor;

  /// Number of passes (7-Zip's "pass" property): accepted, libbzip2 has one
  /// pass.
  final int numPasses;

  /// Number of threads (7-Zip's "mt" property): accepted; the blocks are
  /// encoded one after the other (see [Bzip2BlockEncoder] for the seam).
  final int numThreads;

  Bzip2Compressor(
      {int blockSize100k = 9,
      int workFactor = 30,
      this.numPasses = 1,
      this.numThreads = 1})
      : blockSize100k = blockSize100k,
        workFactor = workFactor == 0 ? 30 : workFactor {
    if (blockSize100k < 1 || blockSize100k > 9) {
      throw InvalidArgException('bzip2: block size must be 1..9');
    }
    if (workFactor < 0 || workFactor > 250) {
      throw InvalidArgException('bzip2: work factor must be 0..250');
    }
  }

  /// From 7-Zip's BZip2 coder properties: d (the block size in bytes,
  /// 100000 to 900000, rounded down to a multiple of 100000), x (the level
  /// when d is not given: 1 and below 100k, 2 300k, 3 500k, 4 700k, 5 and
  /// above 900k, as Get_BZip2_BlockSize of MethodProps.cpp), pass and mt
  /// (accepted). Throws [InvalidArgException] for other properties.
  factory Bzip2Compressor.fromCoderProps(List<CoderProp> props) {
    final mp = MethodProps();
    var numPasses = 1;
    var numThreads = 1;
    for (final p in props) {
      final v = p.value;
      switch (p.id) {
        case CoderPropId.dictionarySize:
          if (v.vt != VarType.ui4 && v.vt != VarType.ui8) {
            invalidArg('bzip2: bad d value');
          }
          // Get_BZip2_BlockSize reads VT_UI4 only; clamp larger values
          final bytes = v.intValue;
          mp.props.add(CoderProp(p.id,
              PropVariant.ui4(bytes < 0 || bytes > 900000 ? 900000 : bytes)));
        case CoderPropId.level:
          if (v.vt != VarType.ui4) invalidArg('bzip2: bad x value');
          mp.props.add(p.copy());
        case CoderPropId.numPasses:
          if (v.vt != VarType.ui4) invalidArg('bzip2: bad pass value');
          numPasses = v.intValue;
        case CoderPropId.numThreads:
          if (v.vt != VarType.ui4) invalidArg('bzip2: bad mt value');
          numThreads = v.intValue;
        case CoderPropId.reduceSize:
        case CoderPropId.expectedDataSize:
        case CoderPropId.affinity:
        case CoderPropId.affinityInGroup:
        case CoderPropId.threadGroup:
        case CoderPropId.numThreadGroups:
          break;
        default:
          invalidArg('bzip2: unsupported property ${p.id}');
      }
    }
    var bs = mp.getBZip2BlockSize() ~/ 100000;
    if (bs < 1) bs = 1;
    if (bs > 9) bs = 9;
    return Bzip2Compressor(
        blockSize100k: bs, numPasses: numPasses, numThreads: numThreads);
  }

  /// From a property string such as "d=900k" or "x=1".
  factory Bzip2Compressor.fromString(String methodProps) =>
      Bzip2Compressor.fromCoderProps(parseMethodProps(methodProps));

  /// No coder properties: the stream header holds the block size.
  @override
  Uint8List get props => Uint8List(0);

  @override
  int encode(InStream input, OutStream output, {ProgressCallback? progress}) {
    final s = Bzip2StreamEncoder(blockSize100k, workFactor: workFactor);
    final buf = Uint8List(1 << 16);
    var total = 0;
    for (;;) {
      final n = input.read(buf, 0, buf.length);
      if (n <= 0) break;
      total += n;
      s.write(buf, 0, n, output);
      if (progress != null && s.blockWritten) {
        s.blockWritten = false;
        progress(total, s.totalOut);
      }
    }
    s.finish(output);
    output.flush();
    progress?.call(total, s.totalOut);
    return total;
  }
}

/// The compression side of a bz_stream (EState without the block coding):
/// the run length input stage, the block split, the CRCs and the stream
/// header and trailer. Feed it with [write] (BZ_RUN), then call [finish]
/// (BZ_FINISH).
class Bzip2StreamEncoder {
  final int blockSize100k;
  final int workFactor;
  final Bzip2BlockEncoder _encoder;
  final Bzip2Block _blk;
  final Bzip2BitWriter _w = Bzip2BitWriter();

  /// When set, every block is coded into its own writer starting at bit
  /// 0 and then appended at the bit position of the stream: the path of a
  /// parallel encoder (blocks coded by workers, joined in order). The
  /// output is the same.
  final bool separateBlockWriters;
  Bzip2BitWriter? _blockWriter;

  // nblockMAX
  final int _nblockMax;

  // run-length-encoding of the input
  int _stateInCh = 256;
  int _stateInLen = 0;

  int _blockNo = 0;
  int _combinedCRC = 0;
  int _blockCRC = 0xFFFFFFFF;

  /// Bytes written to the output so far.
  int totalOut = 0;

  /// Set when a block was written by the last [write] (for progress).
  bool blockWritten = false;

  Bzip2StreamEncoder(this.blockSize100k,
      {this.workFactor = 30, this.separateBlockWriters = false})
      : _encoder = Bzip2BlockEncoder(blockSize100k, workFactor: workFactor),
        _blk = Bzip2Block(blockSize100k),
        _nblockMax = 100000 * blockSize100k - 19 {
    _initRL();
    _prepareNewBlock();
  }

  // prepare_new_block
  void _prepareNewBlock() {
    _blk.nblock = 0;
    _blockCRC = 0xFFFFFFFF;
    final inUse = _blk.inUse;
    for (var i = 0; i < 256; i++) {
      inUse[i] = 0;
    }
    _blockNo++;
  }

  // init_RL
  void _initRL() {
    _stateInCh = 256;
    _stateInLen = 0;
  }

  // add_pair_to_block
  void _addPairToBlock() {
    final ch = _stateInCh;
    final table = bz2Crc32Table;
    var crc = _blockCRC;
    for (var i = 0; i < _stateInLen; i++) {
      crc = ((crc << 8) & 0xFFFFFFFF) ^ table[(crc >> 24) ^ ch];
    }
    _blockCRC = crc;
    final blk = _blk;
    final block = blk.block;
    blk.inUse[ch] = 1;
    var nblock = blk.nblock;
    switch (_stateInLen) {
      case 1:
        block[nblock++] = ch;
      case 2:
        block[nblock++] = ch;
        block[nblock++] = ch;
      case 3:
        block[nblock++] = ch;
        block[nblock++] = ch;
        block[nblock++] = ch;
      default:
        blk.inUse[_stateInLen - 4] = 1;
        block[nblock++] = ch;
        block[nblock++] = ch;
        block[nblock++] = ch;
        block[nblock++] = ch;
        block[nblock++] = _stateInLen - 4;
    }
    blk.nblock = nblock;
  }

  // flush_RL
  void _flushRL() {
    if (_stateInCh < 256) _addPairToBlock();
    _initRL();
  }

  /// BZ2_bzCompress(BZ_RUN) with buf[off, off + len) as the input: the
  /// full blocks are written to [out].
  void write(Uint8List buf, int off, int len, OutStream out) {
    final end = off + len;
    var i = off;
    while (i < end) {
      // block full? (copy_input_until_stop, then handle_compress)
      if (_blk.nblock >= _nblockMax) {
        _compressBlock(false, out);
        _prepareNewBlock();
      }
      i = _copyInputUntilStop(buf, i, end);
    }
    // handle_compress compresses a full block before it returns
    if (_blk.nblock >= _nblockMax) {
      _compressBlock(false, out);
      _prepareNewBlock();
    }
  }

  // copy_input_until_stop (BZ_M_RUNNING) with ADD_CHAR_TO_BLOCK inlined.
  // Returns the position of the first byte not used.
  int _copyInputUntilStop(Uint8List buf, int i, int end) {
    final blk = _blk;
    final block = blk.block;
    final inUse = blk.inUse;
    final table = bz2Crc32Table;
    final nblockMax = _nblockMax;
    var nblock = blk.nblock;
    var stateInCh = _stateInCh;
    var stateInLen = _stateInLen;
    var crc = _blockCRC;

    while (i < end) {
      // block full?
      if (nblock >= nblockMax) break;
      final zchh = buf[i++];
      // fast track the common case
      if (zchh != stateInCh && stateInLen == 1) {
        final ch = stateInCh;
        crc = ((crc << 8) & 0xFFFFFFFF) ^ table[(crc >> 24) ^ ch];
        inUse[ch] = 1;
        block[nblock++] = ch;
        stateInCh = zchh;
      } else if (zchh != stateInCh || stateInLen == 255) {
        // general, uncommon cases
        if (stateInCh < 256) {
          blk.nblock = nblock;
          _stateInCh = stateInCh;
          _stateInLen = stateInLen;
          _blockCRC = crc;
          _addPairToBlock();
          nblock = blk.nblock;
          crc = _blockCRC;
        }
        stateInCh = zchh;
        stateInLen = 1;
      } else {
        stateInLen++;
      }
    }

    blk.nblock = nblock;
    _stateInCh = stateInCh;
    _stateInLen = stateInLen;
    _blockCRC = crc;
    return i;
  }

  // BZ2_compressBlock and the output of handle_compress
  void _compressBlock(bool isLastBlock, OutStream out) {
    final blk = _blk;
    final w = _w;
    if (blk.nblock > 0) {
      // BZ_FINALISE_CRC
      blk.blockCRC = (~_blockCRC) & 0xFFFFFFFF;
      _combinedCRC =
          (((_combinedCRC << 1) & 0xFFFFFFFF) | (_combinedCRC >> 31)) ^
              blk.blockCRC;
    }

    // If this is the first block, create the stream header.
    if (_blockNo == 1) bz2WriteStreamHeader(w, blockSize100k);

    if (separateBlockWriters) {
      final bw = _blockWriter ??= Bzip2BitWriter();
      bw.pos = 0;
      bw.bitBuf = 0;
      bw.bitCount = 0;
      _encoder.compressBlock(blk, bw);
      w.appendBits(bw);
    } else {
      _encoder.compressBlock(blk, w);
    }

    // If this is the last block, add the stream trailer.
    if (isLastBlock) bz2WriteStreamTrailer(w, _combinedCRC);

    totalOut += w.pos;
    w.flushTo(out);
    blockWritten = true;
  }

  /// BZ2_bzCompress(BZ_FINISH) with no more input: the last block and the
  /// stream trailer.
  void finish(OutStream out) {
    _flushRL();
    _compressBlock(true, out);
  }
}

/// Registers the bzip2 decoder (MethodId.bzip2).
void registerBzip2Codecs(Map<int, DecoderFactory> reg) {
  reg[MethodId.bzip2] = bzip2Decoder;
}
