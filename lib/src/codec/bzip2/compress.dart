// Block compression: port of compress.c of bzip2 1.0.8 (the bit stream
// writer, the MTF and Huffman coding of one block, BZ2_compressBlock).
// bzip2/libbzip2 is Copyright (C) 1996-2019 Julian Seward, under the bzip2
// license (BSD style, see LICENSE).
//
// The C encoder writes every block into one bit buffer that continues from
// the previous block. Here [Bzip2BitWriter] holds that buffer, and
// [Bzip2BlockEncoder.compressBlock] writes one block into any writer: the
// writer of the stream (the sequential path), or a fresh writer whose bits
// are appended to the stream later with [Bzip2BitWriter.appendBits] (the
// seam for encoding blocks in parallel: the blocks are independent, only
// the combined CRC and the bit position link them). Both give the same
// bytes.

import 'dart:typed_data';

import '../../io/streams.dart';
import 'blocksort.dart';
import 'bzip2_tables.dart';
import 'huffman.dart';

/// The bit stream writer (bsW, bsPutUInt32, bsPutUChar, bsFinishWrite).
/// Bits are written most significant first; whole bytes go to [buf].
class Bzip2BitWriter {
  Uint8List buf;
  int pos = 0;

  /// Pending bits (the low [bitCount] bits), fewer than 8 between calls.
  int bitBuf = 0;
  int bitCount = 0;

  Bzip2BitWriter([int capacity = 1 << 16]) : buf = Uint8List(capacity);

  /// Number of bits written so far (bytes in [buf] plus pending bits).
  int get bitLength => pos * 8 + bitCount;

  /// Makes room for [n] more bytes.
  void ensure(int n) {
    if (pos + n <= buf.length) return;
    var cap = buf.length * 2;
    if (cap < pos + n) cap = pos + n;
    final nb = Uint8List(cap);
    nb.setRange(0, pos, buf);
    buf = nb;
  }

  // bsW. [v] must fit in [n] bits (n <= 32). The caller makes room with
  // [ensure].
  void writeBits(int n, int v) {
    var b = (bitBuf << n) | v;
    var c = bitCount + n;
    while (c >= 8) {
      c -= 8;
      buf[pos++] = (b >> c) & 0xFF;
    }
    bitBuf = b & 0xFF;
    bitCount = c;
  }

  // bsPutUChar
  void putUChar(int c) => writeBits(8, c);

  // bsPutUInt32
  void putUInt32(int u) {
    writeBits(8, (u >> 24) & 0xff);
    writeBits(8, (u >> 16) & 0xff);
    writeBits(8, (u >> 8) & 0xff);
    writeBits(8, u & 0xff);
  }

  // bsFinishWrite: pads the last byte with zero bits.
  void finish() {
    if (bitCount > 0) {
      ensure(1);
      buf[pos++] = (bitBuf << (8 - bitCount)) & 0xFF;
      bitBuf = 0;
      bitCount = 0;
    }
  }

  /// Appends the bits of [other] (its whole bytes and its pending bits),
  /// at the current bit position of this writer.
  void appendBits(Bzip2BitWriter other) {
    final n = other.pos;
    ensure(n + 1);
    final src = other.buf;
    if (bitCount == 0) {
      buf.setRange(pos, pos + n, src);
      pos += n;
    } else {
      final c = bitCount;
      var b = bitBuf;
      final out = buf;
      var p = pos;
      for (var i = 0; i < n; i++) {
        b = ((b << 8) | src[i]) & 0xFFFF;
        out[p++] = (b >> c) & 0xFF;
      }
      pos = p;
      bitBuf = b & 0xFF;
    }
    if (other.bitCount > 0) writeBits(other.bitCount, other.bitBuf);
  }

  /// Writes the whole bytes to [out] and keeps the pending bits.
  void flushTo(OutStream out) {
    if (pos > 0) out.write(buf, 0, pos);
    pos = 0;
  }
}

/// One block as the input stage (bzlib.c) leaves it: the run length coded
/// bytes, the used byte map and the CRC of the original bytes.
class Bzip2Block {
  /// The block bytes, with at least bzNOvershoot bytes of room after
  /// [nblock] (the sort writes there).
  final Uint8List block;
  int nblock = 0;

  /// inUse: 1 for every byte value in the block.
  final Uint8List inUse = Uint8List(256);

  /// The finalised block CRC (BZ_FINALISE_CRC already applied).
  int blockCRC = 0;

  Bzip2Block(int blockSize100k)
      : block = Uint8List(100000 * blockSize100k + bzNOvershoot);
}

const int _lesserICost = 0;
const int _greaterICost = 15;

/// The per block part of EState: the sort and coding buffers of one
/// encoder. One instance can encode any number of blocks of at most
/// 100000 * [blockSize100k] bytes.
class Bzip2BlockEncoder {
  final int blockSize100k;
  final int workFactor;
  final BlockSorter _sorter;

  // mtfv: aliases arr1 (ptr) in C; a separate list here.
  final Uint16List _mtfv;
  final Int32List _mtfFreq = Int32List(bzMaxAlphaSize);
  final Uint8List _selector = Uint8List(bzMaxSelectors);
  final Uint8List _selectorMtf = Uint8List(bzMaxSelectors);
  final Uint8List _unseqToSeq = Uint8List(256);

  // len, code, rfreq [BZ_N_GROUPS][BZ_MAX_ALPHA_SIZE], flattened
  final Uint8List _len = Uint8List(bzNGroups * bzMaxAlphaSize);
  final Int32List _code = Int32List(bzNGroups * bzMaxAlphaSize);
  final Int32List _rfreq = Int32List(bzNGroups * bzMaxAlphaSize);
  // len_pack [BZ_MAX_ALPHA_SIZE][4], flattened
  final Int32List _lenPack = Int32List(bzMaxAlphaSize * 4);

  final HuffmanWork _hw = HuffmanWork();
  final Uint8List _yy = Uint8List(256);
  final Int32List _cost = Int32List(bzNGroups);
  final Int32List _fave = Int32List(bzNGroups);

  int _nInUse = 0;
  int _nMTF = 0;

  Bzip2BlockEncoder(this.blockSize100k, {this.workFactor = 30})
      : _sorter = BlockSorter(100000 * blockSize100k),
        _mtfv = Uint16List(100000 * blockSize100k + 2);

  // makeMaps_e
  void _makeMaps(Uint8List inUse) {
    _nInUse = 0;
    for (var i = 0; i < 256; i++) {
      if (inUse[i] != 0) {
        _unseqToSeq[i] = _nInUse;
        _nInUse++;
      }
    }
  }

  // generateMTFValues
  void _generateMTFValues(Uint8List block, int nblock, Uint8List inUse) {
    final ptr = _sorter.ptr;
    final mtfv = _mtfv;
    final mtfFreq = _mtfFreq;
    final unseqToSeq = _unseqToSeq;
    final yy = _yy;

    _makeMaps(inUse);
    final eob = _nInUse + 1;

    for (var i = 0; i <= eob; i++) {
      mtfFreq[i] = 0;
    }

    var wr = 0;
    var zPend = 0;
    for (var i = 0; i < _nInUse; i++) {
      yy[i] = i;
    }

    for (var i = 0; i < nblock; i++) {
      var j = ptr[i] - 1;
      if (j < 0) j += nblock;
      final llI = unseqToSeq[block[j]];

      if (yy[0] == llI) {
        zPend++;
      } else {
        if (zPend > 0) {
          zPend--;
          for (;;) {
            if ((zPend & 1) != 0) {
              mtfv[wr] = bzRunB;
              wr++;
              mtfFreq[bzRunB]++;
            } else {
              mtfv[wr] = bzRunA;
              wr++;
              mtfFreq[bzRunA]++;
            }
            if (zPend < 2) break;
            zPend = (zPend - 2) ~/ 2;
          }
          zPend = 0;
        }
        {
          var rtmp = yy[1];
          yy[1] = yy[0];
          var ryyJ = 1;
          while (llI != rtmp) {
            ryyJ++;
            final rtmp2 = rtmp;
            rtmp = yy[ryyJ];
            yy[ryyJ] = rtmp2;
          }
          yy[0] = rtmp;
          j = ryyJ;
          mtfv[wr] = j + 1;
          wr++;
          mtfFreq[j + 1]++;
        }
      }
    }

    if (zPend > 0) {
      zPend--;
      for (;;) {
        if ((zPend & 1) != 0) {
          mtfv[wr] = bzRunB;
          wr++;
          mtfFreq[bzRunB]++;
        } else {
          mtfv[wr] = bzRunA;
          wr++;
          mtfFreq[bzRunA]++;
        }
        if (zPend < 2) break;
        zPend = (zPend - 2) ~/ 2;
      }
      zPend = 0;
    }

    mtfv[wr] = eob;
    wr++;
    mtfFreq[eob]++;

    _nMTF = wr;
  }

  // sendMTFValues
  void _sendMTFValues(Uint8List inUse, Bzip2BitWriter w) {
    final mtfv = _mtfv;
    final len = _len;
    final code = _code;
    final rfreq = _rfreq;
    final lenPack = _lenPack;
    final selector = _selector;
    final selectorMtf = _selectorMtf;
    final mtfFreq = _mtfFreq;
    final cost = _cost;
    final fave = _fave;
    final nMTF = _nMTF;
    const kA = bzMaxAlphaSize;

    final alphaSize = _nInUse + 2;
    for (var t = 0; t < bzNGroups; t++) {
      for (var v = 0; v < alphaSize; v++) {
        len[t * kA + v] = _greaterICost;
      }
    }

    // Decide how many coding tables to use
    if (nMTF <= 0) throw StateError('bzip2 internal error 3001');
    int nGroups;
    if (nMTF < 200) {
      nGroups = 2;
    } else if (nMTF < 600) {
      nGroups = 3;
    } else if (nMTF < 1200) {
      nGroups = 4;
    } else if (nMTF < 2400) {
      nGroups = 5;
    } else {
      nGroups = 6;
    }

    // Generate an initial set of coding tables
    {
      var nPart = nGroups;
      var remF = nMTF;
      var gs = 0;
      while (nPart > 0) {
        final tFreq = remF ~/ nPart;
        var ge = gs - 1;
        var aFreq = 0;
        while (aFreq < tFreq && ge < alphaSize - 1) {
          ge++;
          aFreq += mtfFreq[ge];
        }

        if (ge > gs &&
            nPart != nGroups &&
            nPart != 1 &&
            ((nGroups - nPart) % 2 == 1)) {
          aFreq -= mtfFreq[ge];
          ge--;
        }

        final row = (nPart - 1) * kA;
        for (var v = 0; v < alphaSize; v++) {
          len[row + v] = (v >= gs && v <= ge) ? _lesserICost : _greaterICost;
        }

        nPart--;
        gs = ge + 1;
        remF -= aFreq;
      }
    }

    // Iterate up to BZ_N_ITERS times to improve the tables.
    var nSelectors = 0;
    for (var iter = 0; iter < bzNIters; iter++) {
      for (var t = 0; t < nGroups; t++) {
        fave[t] = 0;
      }

      for (var t = 0; t < nGroups; t++) {
        for (var v = 0; v < alphaSize; v++) {
          rfreq[t * kA + v] = 0;
        }
      }

      // Set up an auxiliary length table which is used to fast-track the
      // common case (nGroups == 6).
      if (nGroups == 6) {
        for (var v = 0; v < alphaSize; v++) {
          lenPack[v * 4] = (len[kA + v] << 16) | len[v];
          lenPack[v * 4 + 1] = (len[3 * kA + v] << 16) | len[2 * kA + v];
          lenPack[v * 4 + 2] = (len[5 * kA + v] << 16) | len[4 * kA + v];
        }
      }

      nSelectors = 0;
      var gs = 0;
      for (;;) {
        // Set group start & end marks.
        if (gs >= nMTF) break;
        var ge = gs + bzGSize - 1;
        if (ge >= nMTF) ge = nMTF - 1;

        // Calculate the cost of this group as coded by each of the coding
        // tables.
        for (var t = 0; t < nGroups; t++) {
          cost[t] = 0;
        }

        if (nGroups == 6 && 50 == ge - gs + 1) {
          // fast track the common case
          var cost01 = 0, cost23 = 0, cost45 = 0;
          for (var i = gs; i <= ge; i++) {
            final p = mtfv[i] * 4;
            cost01 += lenPack[p];
            cost23 += lenPack[p + 1];
            cost45 += lenPack[p + 2];
          }
          cost[0] = cost01 & 0xffff;
          cost[1] = cost01 >> 16;
          cost[2] = cost23 & 0xffff;
          cost[3] = cost23 >> 16;
          cost[4] = cost45 & 0xffff;
          cost[5] = cost45 >> 16;
        } else {
          // slow version which correctly handles all situations
          for (var i = gs; i <= ge; i++) {
            final icv = mtfv[i];
            for (var t = 0; t < nGroups; t++) {
              cost[t] = (cost[t] + len[t * kA + icv]) & 0xFFFF;
            }
          }
        }

        // Find the coding table which is best for this group, and record
        // its identity in the selector table.
        var bc = 999999999;
        var bt = -1;
        for (var t = 0; t < nGroups; t++) {
          if (cost[t] < bc) {
            bc = cost[t];
            bt = t;
          }
        }
        fave[bt]++;
        selector[nSelectors] = bt;
        nSelectors++;

        // Increment the symbol frequencies for the selected table.
        final row = bt * kA;
        for (var i = gs; i <= ge; i++) {
          rfreq[row + mtfv[i]]++;
        }

        gs = ge + 1;
      }

      // Recompute the tables based on the accumulated frequencies.
      // maxLen was changed from 20 to 17 in bzip2-1.0.3.
      for (var t = 0; t < nGroups; t++) {
        bz2HbMakeCodeLengths(len, t * kA, rfreq, t * kA, alphaSize, 17, _hw);
      }
    }

    if (nGroups >= 8) throw StateError('bzip2 internal error 3002');
    if (!(nSelectors < 32768 && nSelectors <= bzMaxSelectors)) {
      throw StateError('bzip2 internal error 3003');
    }

    // Compute MTF values for the selectors.
    {
      final pos = Uint8List(bzNGroups);
      for (var i = 0; i < nGroups; i++) {
        pos[i] = i;
      }
      for (var i = 0; i < nSelectors; i++) {
        final llI = selector[i];
        var j = 0;
        var tmp = pos[j];
        while (llI != tmp) {
          j++;
          final tmp2 = tmp;
          tmp = pos[j];
          pos[j] = tmp2;
        }
        pos[0] = tmp;
        selectorMtf[i] = j;
      }
    }

    // Assign actual codes for the tables.
    for (var t = 0; t < nGroups; t++) {
      var minLen = 32;
      var maxLen = 0;
      for (var i = 0; i < alphaSize; i++) {
        final l = len[t * kA + i];
        if (l > maxLen) maxLen = l;
        if (l < minLen) minLen = l;
      }
      if (maxLen > 17) throw StateError('bzip2 internal error 3004');
      if (minLen < 1) throw StateError('bzip2 internal error 3005');
      bz2HbAssignCodes(code, t * kA, len, t * kA, minLen, maxLen, alphaSize);
    }

    // Worst case size of the rest of the block: the maps (33 bytes), the
    // selectors (nSelectors * 6 bits), the tables (at most 41 bits per
    // symbol) and nMTF codes of at most 17 bits.
    w.ensure(64 +
        ((nSelectors * 6) >> 3) +
        ((nGroups * alphaSize * 41) >> 3) +
        ((nMTF * 17) >> 3));

    // Transmit the mapping table.
    {
      final inUse16 = Uint8List(16);
      for (var i = 0; i < 16; i++) {
        inUse16[i] = 0;
        for (var j = 0; j < 16; j++) {
          if (inUse[i * 16 + j] != 0) inUse16[i] = 1;
        }
      }

      for (var i = 0; i < 16; i++) {
        w.writeBits(1, inUse16[i] != 0 ? 1 : 0);
      }

      for (var i = 0; i < 16; i++) {
        if (inUse16[i] != 0) {
          for (var j = 0; j < 16; j++) {
            w.writeBits(1, inUse[i * 16 + j] != 0 ? 1 : 0);
          }
        }
      }
    }

    // Now the selectors.
    w.writeBits(3, nGroups);
    w.writeBits(15, nSelectors);
    for (var i = 0; i < nSelectors; i++) {
      for (var j = 0; j < selectorMtf[i]; j++) {
        w.writeBits(1, 1);
      }
      w.writeBits(1, 0);
    }

    // Now the coding tables.
    for (var t = 0; t < nGroups; t++) {
      var curr = len[t * kA];
      w.writeBits(5, curr);
      for (var i = 0; i < alphaSize; i++) {
        final l = len[t * kA + i];
        while (curr < l) {
          w.writeBits(2, 2);
          curr++; // 10
        }
        while (curr > l) {
          w.writeBits(2, 3);
          curr--; // 11
        }
        w.writeBits(1, 0);
      }
    }

    // And finally, the block data proper (bsW inlined).
    {
      final out = w.buf;
      var p = w.pos;
      var b = w.bitBuf;
      var c = w.bitCount;
      var selCtr = 0;
      var gs = 0;
      for (;;) {
        if (gs >= nMTF) break;
        var ge = gs + bzGSize - 1;
        if (ge >= nMTF) ge = nMTF - 1;
        final sel = selector[selCtr];
        if (sel >= nGroups) throw StateError('bzip2 internal error 3006');
        final row = sel * kA;
        for (var i = gs; i <= ge; i++) {
          final m = row + mtfv[i];
          b = (b << len[m]) | code[m];
          c += len[m];
          while (c >= 8) {
            c -= 8;
            out[p++] = (b >> c) & 0xFF;
          }
          b &= 0xFF;
        }
        gs = ge + 1;
        selCtr++;
      }
      if (selCtr != nSelectors) throw StateError('bzip2 internal error 3007');
      w.pos = p;
      w.bitBuf = b & 0xFF;
      w.bitCount = c;
    }
  }

  /// The block part of BZ2_compressBlock: the block header, CRC,
  /// randomised bit and origPtr, then the coded block. Does nothing for an
  /// empty block. The stream header and trailer are written by the caller.
  void compressBlock(Bzip2Block blk, Bzip2BitWriter w) {
    final nblock = blk.nblock;
    if (nblock <= 0) return;

    final origPtr = _sorter.blockSort(blk.block, nblock, workFactor);

    w.ensure(16);
    w.putUChar(0x31);
    w.putUChar(0x41);
    w.putUChar(0x59);
    w.putUChar(0x26);
    w.putUChar(0x53);
    w.putUChar(0x59);

    // Now the block's CRC, so it is in a known place.
    w.putUInt32(blk.blockCRC);

    // A single bit indicating (non-)randomisation: always 'no' since
    // version 0.9.5.
    w.writeBits(1, 0);

    w.writeBits(24, origPtr);
    _generateMTFValues(blk.block, nblock, blk.inUse);
    _sendMTFValues(blk.inUse, w);
  }
}

/// The stream header of BZ2_compressBlock (first block): "BZh" and the
/// block size digit.
void bz2WriteStreamHeader(Bzip2BitWriter w, int blockSize100k) {
  w.ensure(4);
  w.putUChar(bzHdrB);
  w.putUChar(bzHdrZ);
  w.putUChar(bzHdrH);
  w.putUChar(bzHdr0 + blockSize100k);
}

/// The stream trailer of BZ2_compressBlock (last block): the end of
/// stream magic, the combined CRC and the padding (bsFinishWrite).
void bz2WriteStreamTrailer(Bzip2BitWriter w, int combinedCRC) {
  w.ensure(16);
  w.putUChar(0x17);
  w.putUChar(0x72);
  w.putUChar(0x45);
  w.putUChar(0x38);
  w.putUChar(0x50);
  w.putUChar(0x90);
  w.putUInt32(combinedCRC);
  w.finish();
}
