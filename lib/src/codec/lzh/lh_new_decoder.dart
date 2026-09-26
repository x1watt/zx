// Decoder of the "new" LHA methods with static Huffman blocks: -lh4-,
// -lh5-, -lh6-, -lh7-, -lhx- and LHARK's -lk7-, and of ARJ methods 1 to 3,
// which use the same block format. A port of lh_new_decoder.c of lhasa (ISC
// license, see LICENSE) with the parameters of lh5_decoder.c,
// lh6_decoder.c, lh7_decoder.c, lhx_decoder.c and lk7_decoder.c.

import 'dart:typed_data';

import 'lha_decoder.dart';
import 'lzh_bits.dart';

// COPY_THRESHOLD
const int _kCopyThreshold = 3;
// TEMP_CODE_BITS, MAX_TEMP_CODES
const int _kTempCodeBits = 5;
const int _kMaxTempCodes = (1 << _kTempCodeBits) - 1;
const int _kLeaf = 0x8000; // TREE_NODE_LEAF of a uint16_t tree

/// The parameters of one method (HISTORY_BITS, OFFSET_BITS, NUM_CODES,
/// LHARK).
class LhNewParams {
  final int historyBits;
  final int offsetBits;
  final int numCodes;
  final bool lhark;
  const LhNewParams(this.historyBits, this.offsetBits, this.numCodes,
      {this.lhark = false});

  // lh5_decoder.c (-lh4- is the same with a smaller block size)
  static const lh5 = LhNewParams(14, 4, 510);
  // lh6_decoder.c
  static const lh6 = LhNewParams(16, 5, 510);
  // lh7_decoder.c
  static const lh7 = LhNewParams(17, 5, 510);
  // lhx_decoder.c
  static const lhx = LhNewParams(20, 5, 510);
  // lk7_decoder.c
  static const lk7 = LhNewParams(16, 6, 289, lhark: true);

  /// ARJ methods 1 to 3: a 26624 byte dictionary, offsets coded like
  /// -lh6-, so the -lh6- parameters decode them.
  static const arj = lh6;
}

/// LHANewDecoder.
class LhNewDecoder extends LhaDecoder {
  final LzhBitReader r;
  final LhNewParams p;
  final Uint8List ringbuf;
  final int _mask;
  int ringbufPos = 0;
  int blockRemaining = 0;
  final Uint16List tempTree = Uint16List(_kMaxTempCodes * 2);
  final Uint16List codeTree;
  final Uint16List offsetTree;
  final int _maxOffsetCodes;
  final Uint8List _codeLengths;

  // lha_lh_new_init
  LhNewDecoder(this.r, this.p)
      : ringbuf = Uint8List(1 << p.historyBits),
        _mask = (1 << p.historyBits) - 1,
        codeTree = Uint16List(p.numCodes * 2),
        offsetTree = Uint16List(((1 << p.offsetBits) - 1) * 2),
        _maxOffsetCodes = (1 << p.offsetBits) - 1,
        _codeLengths = Uint8List(p.numCodes) {
    // init_ring_buffer
    ringbuf.fillRange(0, ringbuf.length, 0x20);
    lzhInitTree(codeTree, codeTree.length, _kLeaf);
    lzhInitTree(offsetTree, offsetTree.length, _kLeaf);
    lzhInitTree(tempTree, tempTree.length, _kLeaf);
  }

  // max_read: the longest copy (514 for the LHARK length codes)
  @override
  int get maxRead => p.lhark ? 514 : 256;

  // read_length_value
  int _readLengthValue() {
    var len = r.readBits(3);
    if (len < 0) return -1;
    if (len == 7) {
      for (;;) {
        final i = r.readBit();
        if (i < 0) return -1;
        if (i == 0) break;
        len++;
      }
    }
    return len;
  }

  // read_temp_table
  bool _readTempTable() {
    final codeLengths = Uint8List(_kMaxTempCodes);
    var n = r.readBits(_kTempCodeBits);
    if (n < 0) return false;
    if (n == 0) {
      final code = r.readBits(5);
      if (code < 0) return false;
      lzhSetTreeSingle(tempTree, code, _kLeaf);
      return true;
    }
    if (n > _kMaxTempCodes) n = _kMaxTempCodes;
    for (var i = 0; i < n; i++) {
      var len = _readLengthValue();
      if (len < 0) return false;
      codeLengths[i] = len;
      if (i == 2) {
        len = r.readBits(2);
        if (len < 0) return false;
        for (var j = 0; j < len; j++) {
          i++;
          codeLengths[i] = 0;
        }
      }
    }
    lzhBuildTree(tempTree, _kMaxTempCodes * 2, codeLengths, n, _kLeaf);
    return true;
  }

  // read_skip_count
  int _readSkipCount(int skiprange) {
    if (skiprange == 0) return 1;
    if (skiprange == 1) {
      final result = r.readBits(4);
      if (result < 0) return -1;
      return result + 3;
    }
    final result = r.readBits(9);
    if (result < 0) return -1;
    return result + 20;
  }

  // read_code_table
  bool _readCodeTable() {
    final codeLengths = _codeLengths;
    var n = r.readBits(9);
    if (n < 0) return false;
    if (n == 0) {
      final code = r.readBits(9);
      if (code < 0) return false;
      lzhSetTreeSingle(codeTree, code, _kLeaf);
      return true;
    }
    if (n > p.numCodes) n = p.numCodes;
    var i = 0;
    while (i < n) {
      final code = lzhReadFromTree(r, tempTree, _kLeaf);
      if (code < 0) return false;
      if (code <= 2) {
        final skipCount = _readSkipCount(code);
        if (skipCount < 0) return false;
        for (var j = 0; j < skipCount && i < n; j++) {
          codeLengths[i] = 0;
          i++;
        }
      } else {
        codeLengths[i] = code - 2;
        i++;
      }
    }
    lzhBuildTree(codeTree, p.numCodes * 2, codeLengths, n, _kLeaf);
    return true;
  }

  // read_offset_table
  bool _readOffsetTable() {
    final codeLengths = Uint8List(_maxOffsetCodes);
    var n = r.readBits(p.offsetBits);
    if (n < 0) return false;
    if (n == 0) {
      final code = r.readBits(p.offsetBits);
      if (code < 0) return false;
      lzhSetTreeSingle(offsetTree, code, _kLeaf);
      return true;
    }
    if (n > _maxOffsetCodes) n = _maxOffsetCodes;
    for (var i = 0; i < n; i++) {
      final len = _readLengthValue();
      if (len < 0) return false;
      codeLengths[i] = len;
    }
    lzhBuildTree(offsetTree, _maxOffsetCodes * 2, codeLengths, n, _kLeaf);
    return true;
  }

  // start_new_block
  bool _startNewBlock() {
    final len = r.readBits(16);
    if (len < 0) return false;
    blockRemaining = len;
    return _readTempTable() && _readCodeTable() && _readOffsetTable();
  }

  // lhark_read_offset_code
  int _lharkReadOffsetCode(int code) {
    if (code < 4) return code;
    final numLowBits = (code - 2) >> 1;
    final lowBits = r.readBits(numLowBits);
    if (lowBits < 0) return -1;
    return ((2 + (code & 1)) << numLowBits) + lowBits;
  }

  // read_offset_code
  int _readOffsetCode() {
    final bits = lzhReadFromTree(r, offsetTree, _kLeaf);
    if (bits < 0) return -1;
    if (bits == 0) return 0;
    if (bits == 1) return 1;
    if (p.lhark) return _lharkReadOffsetCode(bits);
    final result = r.readBits(bits - 1);
    if (result < 0) return -1;
    return result + (1 << (bits - 1));
  }

  // lhark_decode_copy_count
  int _lharkDecodeCopyCount(int code) {
    if (code < 264) return code - 256 + _kCopyThreshold;
    if (code < 288) {
      final numLowBits = (code - 260) >> 2;
      final lowBits = r.readBits(numLowBits);
      if (lowBits < 0) return -1;
      return ((4 + (code & 3)) << numLowBits) + lowBits + 3;
    }
    return 514;
  }

  // lha_lh_new_read
  @override
  int read(Uint8List buf, int off) {
    while (blockRemaining == 0) {
      if (!_startNewBlock()) return 0;
    }
    blockRemaining--;
    // read_code
    final code = lzhReadFromTree(r, codeTree, _kLeaf);
    if (code < 0) return 0;
    final ring = ringbuf;
    final mask = _mask;
    if (code < 256) {
      // output_byte
      buf[off] = code;
      ring[ringbufPos] = code;
      ringbufPos = (ringbufPos + 1) & mask;
      return 1;
    }
    final copyCount =
        p.lhark ? _lharkDecodeCopyCount(code) : code - 256 + _kCopyThreshold;
    if (copyCount < 0) return 0;
    // copy_from_history
    final offset = _readOffsetCode();
    if (offset < 0) return 0;
    var pos = ringbufPos;
    final start = pos + ring.length - offset - 1;
    for (var i = 0; i < copyCount; i++) {
      final b = ring[(start + i) & mask];
      buf[off + i] = b;
      ring[pos] = b;
      pos = (pos + 1) & mask;
    }
    ringbufPos = pos;
    return copyCount;
  }
}
