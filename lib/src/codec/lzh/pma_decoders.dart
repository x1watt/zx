// Decoders of the PMarc methods -pm1- and -pm2-: ports of pma_common.c,
// pm1_decoder.c and pm2_decoder.c of lhasa (ISC license, see LICENSE).

import 'dart:typed_data';

import 'lha_decoder.dart';
import 'lzh_bits.dart';

// ---------------------------------------------------------------------------
// pma_common.c

// decode_variable_length. The tables are (offset, bits) pairs. An index
// past the table (a corrupt stream) gives -1.
int _decodeVariableLength(LzhBitReader r, List<int> table, int header) {
  if (header < 0 || header * 2 >= table.length) return -1;
  final value = r.readBits(table[header * 2 + 1]);
  if (value < 0) return -1;
  return table[header * 2] + value;
}

/// HistoryLinkedList: byte values in most recently used order.
class _HistoryList {
  final Uint8List prev = Uint8List(256);
  final Uint8List next = Uint8List(256);
  int head = 0;

  // init_history_list
  _HistoryList() {
    for (var i = 0; i < 256; i++) {
      prev[i] = (i + 1) & 0xFF;
      next[i] = (i - 1) & 0xFF;
    }
    head = 0x20;
    prev[0x7F] = 0x00;
    next[0x00] = 0x7F;
    prev[0x1F] = 0xA0;
    next[0xA0] = 0x1F;
    prev[0xDF] = 0x80;
    next[0x80] = 0xDF;
    prev[0x9F] = 0xE0;
    next[0xE0] = 0x9F;
    prev[0xFF] = 0x20;
    next[0x20] = 0xFF;
  }

  // find_in_history_list
  int find(int count) {
    var code = head;
    if (count < 128) {
      for (var i = 0; i < count; i++) {
        code = prev[code];
      }
    } else {
      for (var i = 0; i < 256 - count; i++) {
        code = next[code];
      }
    }
    return code;
  }

  // update_history_list
  void update(int b) {
    if (head == b) return;
    next[prev[b]] = next[b];
    prev[next[b]] = prev[b];
    final oldHead = head;
    prev[b] = oldHead;
    next[b] = next[oldHead];
    prev[next[oldHead]] = b;
    next[oldHead] = b;
    head = b;
  }
}

// ---------------------------------------------------------------------------
// pm1_decoder.c

const int _kPm1RingBufferSize = 16384;
const int _kMaxByteBlockLen = 216;
const int _kMaxCopyBlockLen = 244;

// copy_ranges
const List<int> _copyRanges = [
  0, 6, 64, 8, 0, 6, 64, 9, 576, 11, 2624, 13, //
  64, 8, //
  576, 8, 576, 9, 576, 10, //
  2624, 8, 2624, 9, 2624, 10, 2624, 11, 2624, 12,
];

// byte_ranges
const List<int> _byteRanges = [
  0, 4, 16, 4, 32, 5, 64, 6, 128, 6, 192, 6, //
];

// byte_decode_trees, as the flat array of 32 rows of 5 bytes that the C
// array is in memory (a tree walk may run into the next row)
final Uint8List _byteDecodeTrees = Uint8List.fromList(const [
  0x12, 0x2d, 0xef, 0x1c, 0xab, //
  0x12, 0x23, 0xde, 0xab, 0xcf, //
  0x12, 0x2c, 0xd2, 0xab, 0xef, //
  0x12, 0xa2, 0xd2, 0xbc, 0xef, //
  0x12, 0xa2, 0xc2, 0xbd, 0xef, //
  0x12, 0xa2, 0xcd, 0xb1, 0xef, //
  0x12, 0xab, 0x12, 0xcd, 0xef, //
  0x12, 0xab, 0x1d, 0xc1, 0xef, //
  0x12, 0xab, 0xc1, 0xd1, 0xef, //
  0xa1, 0x12, 0x2c, 0xde, 0xbf, //
  0xa1, 0x1d, 0x1c, 0xb1, 0xef, //
  0xa1, 0x12, 0x2d, 0xef, 0xbc, //
  0xa1, 0x12, 0xb2, 0xde, 0xcf, //
  0xa1, 0x12, 0xbc, 0xd1, 0xef, //
  0xa1, 0x1c, 0xb1, 0xd1, 0xef, //
  0xa1, 0xb1, 0x12, 0xcd, 0xef, //
  0xa1, 0xb1, 0xc1, 0xd1, 0xef, //
  0x12, 0x1c, 0xde, 0xab, 0x00, //
  0x12, 0xa2, 0xcd, 0xbe, 0x00, //
  0x12, 0xab, 0xc1, 0xde, 0x00, //
  0xa1, 0x1d, 0x1c, 0xbe, 0x00, //
  0xa1, 0x12, 0xbc, 0xde, 0x00, //
  0xa1, 0x1c, 0xb1, 0xde, 0x00, //
  0xa1, 0xb1, 0xc1, 0xde, 0x00, //
  0x1d, 0x1c, 0xab, 0x00, 0x00, //
  0x1c, 0xa1, 0xbd, 0x00, 0x00, //
  0x12, 0xab, 0xcd, 0x00, 0x00, //
  0xa1, 0x1c, 0xbd, 0x00, 0x00, //
  0xa1, 0xb1, 0xcd, 0x00, 0x00, //
  0xa1, 0xbc, 0x00, 0x00, 0x00, //
  0xab, 0x00, 0x00, 0x00, 0x00, //
  0x00, 0x00, 0x00, 0x00, 0x00, //
]);

/// LHAPM1Decoder.
class Pm1Decoder extends LhaDecoder {
  /// Must read zeros past the end (read_callback_wrapper).
  final LzhBitReader r;
  int outputStreamPos = 0;
  int _byteDecodeTree = -1;
  final Uint8List ringbuf = Uint8List(_kPm1RingBufferSize);
  int ringbufPos = 0;
  final _HistoryList _history = _HistoryList();

  // lha_pm1_init
  Pm1Decoder(this.r);

  @override
  int get maxRead => _kMaxByteBlockLen + _kMaxCopyBlockLen;

  // read_start_header
  bool _readStartHeader() {
    final index = r.readBits(5);
    if (index < 0) return false;
    _byteDecodeTree = index * 5;
    return true;
  }

  // outputted_byte
  void _outputtedByte(int b) {
    ringbuf[ringbufPos] = b;
    ringbufPos = (ringbufPos + 1) & (_kPm1RingBufferSize - 1);
    _history.update(b);
    outputStreamPos++;
  }

  // read_copy_byte_count
  int _readCopyByteCount() {
    var x = r.readBits(2);
    if (x < 0) return -1;
    if (x < 3) return x + 3;
    x = r.readBits(3);
    if (x < 0) return -1;
    if (x < 5) return x + 6;
    if (x == 5) {
      x = r.readBits(2);
      return x < 0 ? -1 : x + 11;
    }
    if (x == 6) {
      x = r.readBits(3);
      return x < 0 ? -1 : x + 15;
    }
    x = r.readBits(6);
    if (x < 0) return -1;
    if (x < 62) return x + 23;
    if (x == 62) {
      x = r.readBits(5);
      return x < 0 ? -1 : x + 85;
    }
    x = r.readBits(7);
    return x < 0 ? -1 : x + 117;
  }

  // read_bit_after_threshold
  int _readBitAfterThreshold(int threshold, int def) =>
      outputStreamPos >= threshold ? r.readBit() : def;

  // read_copy_type_range
  int _readCopyTypeRange() {
    var x = r.readBit();
    if (x < 0) return -1;
    if (x == 0) {
      x = _readBitAfterThreshold(576, 0);
      if (x < 0) return -1;
      if (x != 0) return 4;
      return _readBitAfterThreshold(64, 0);
    }
    x = _readBitAfterThreshold(64, 1);
    if (x < 0) return -1;
    if (x == 0) return 3;
    x = _readBitAfterThreshold(2624, 1);
    if (x < 0) return -1;
    return x != 0 ? 2 : 5;
  }

  // read_copy_command
  int _readCopyCommand(Uint8List buf, int off) {
    var rangeIndex = _readCopyTypeRange();
    if (rangeIndex < 0) return 0;
    int count;
    if (rangeIndex < 2) {
      count = 2;
    } else {
      count = _readCopyByteCount();
      if (count < 0) return 0;
    }
    final pos = outputStreamPos;
    if (rangeIndex == 3) {
      if (pos < 320) rangeIndex = 6;
    } else if (rangeIndex == 4) {
      if (pos < 832) {
        rangeIndex = 7;
      } else if (pos < 1088) {
        rangeIndex = 8;
      } else if (pos < 1600) {
        rangeIndex = 9;
      }
    } else if (rangeIndex == 5) {
      if (pos < 2880) {
        rangeIndex = 10;
      } else if (pos < 3136) {
        rangeIndex = 11;
      } else if (pos < 3648) {
        rangeIndex = 12;
      } else if (pos < 4672) {
        rangeIndex = 13;
      } else if (pos < 6720) {
        rangeIndex = 14;
      }
    }
    final historyDistance = _decodeVariableLength(r, _copyRanges, rangeIndex);
    if (historyDistance < 0 || historyDistance >= outputStreamPos) return 0;
    const mask = _kPm1RingBufferSize - 1;
    var copyIndex =
        (ringbufPos + _kPm1RingBufferSize - historyDistance - 1) & mask;
    for (var i = 0; i < count; i++) {
      final b = ringbuf[copyIndex];
      buf[off + i] = b;
      _outputtedByte(b);
      copyIndex = (copyIndex + 1) & mask;
    }
    return count;
  }

  // read_byte_decode_index
  int _readByteDecodeIndex() {
    final t = _byteDecodeTrees;
    var ptr = _byteDecodeTree;
    if (t[ptr] == 0) return 0;
    for (;;) {
      final bit = r.readBit();
      if (bit < 0) return -1;
      final child = bit == 0 ? (t[ptr] >> 4) & 0x0F : t[ptr] & 0x0F;
      if (child >= 10) return child - 10;
      ptr += child;
      if (ptr >= t.length) return -1;
    }
  }

  // read_byte
  int _readByte() {
    final index = _readByteDecodeIndex();
    if (index < 0) return -1;
    final count = _decodeVariableLength(r, _byteRanges, index);
    if (count < 0) return -1;
    return _history.find(count & 0xFF);
  }

  // read_byte_block_count
  int _readByteBlockCount() {
    var x = r.readBits(2);
    if (x < 0) return 0;
    if (x < 3) return x + 1;
    x = r.readBits(3);
    if (x < 0) return 0;
    if (x < 7) return x + 4;
    x = r.readBits(4);
    if (x < 0) return 0;
    if (x < 14) return x + 11;
    if (x == 14) {
      x = r.readBits(6);
      return x < 0 ? 0 : x + 25;
    }
    x = r.readBits(7);
    return x < 0 ? 0 : x + 89;
  }

  // read_byte_block
  int _readByteBlock(Uint8List buf, int off) {
    final blockLen = _readByteBlockCount();
    if (blockLen == 0) return 0;
    for (var i = 0; i < blockLen; i++) {
      final byteval = _readByte();
      if (byteval < 0) return 0;
      buf[off + i] = byteval;
      _outputtedByte(byteval);
    }
    if (blockLen == _kMaxByteBlockLen) return blockLen;
    final result2 = _readCopyCommand(buf, off + blockLen);
    if (result2 == 0) return 0;
    return blockLen + result2;
  }

  // lha_pm1_read
  @override
  int read(Uint8List buf, int off) {
    if (_byteDecodeTree < 0 && !_readStartHeader()) return 0;
    final commandType = r.readBit();
    if (commandType == 0) return _readCopyCommand(buf, off);
    return _readByteBlock(buf, off);
  }
}

// ---------------------------------------------------------------------------
// pm2_decoder.c

const int _kPm2RingBufferSize = 8192;
const int _kPm2OutputBufferSize = 256;
const int _kCodeTreeElements = 65;
const int _kOffsetTreeElements = 17;
const int _kLeaf8 = 0x80; // TREE_NODE_LEAF of a uint8_t tree

// PM2RebuildState
const int _unbuilt = 0, _build1 = 1, _build2 = 2, _build3 = 3;
const int _continuing = 4;

// history_decode
const List<int> _historyDecode = [
  0, 3, 8, 3, 16, 4, 32, 5, 64, 5, 96, 5, 128, 6, 192, 6, //
];

// copy_decode
const List<int> _copyDecode = [
  17, 3, 25, 3, 33, 5, 65, 6, 129, 7, 256, 0, //
];

/// LHAPM2Decoder.
class Pm2Decoder extends LhaDecoder {
  final LzhBitReader r;
  int _treeState = _unbuilt;
  int _treeRebuildRemaining = 0;
  final Uint8List ringbuf = Uint8List(_kPm2RingBufferSize);
  int ringbufPos = 0;
  final _HistoryList _history = _HistoryList();
  final Uint8List _codeTree = Uint8List(_kCodeTreeElements);
  bool _needOffsetTree = false;
  final Uint8List _offsetTree = Uint8List(_kOffsetTreeElements);

  // lha_pm2_decoder_init
  Pm2Decoder(this.r) {
    ringbuf.fillRange(0, _kPm2RingBufferSize, 0x20);
    lzhInitTree(_codeTree, _kCodeTreeElements, _kLeaf8);
    lzhInitTree(_offsetTree, _kOffsetTreeElements, _kLeaf8);
  }

  @override
  int get maxRead => _kPm2OutputBufferSize;

  // read_code_tree
  bool _readCodeTree() {
    final codeLengths = Uint8List(31);
    final numCodes = r.readBits(5);
    final minCodeLength = r.readBits(3);
    if (minCodeLength < 0 || numCodes < 0) return false;
    if (numCodes > 29) return false;
    _needOffsetTree = numCodes >= 10 && !(numCodes == 29 && minCodeLength == 0);
    if (minCodeLength == 0) {
      lzhSetTreeSingle(_codeTree, numCodes - 1, _kLeaf8);
      return true;
    }
    final lengthBits = r.readBits(3);
    if (lengthBits < 0) return false;
    for (var i = 0; i < numCodes; i++) {
      final val = r.readBits(lengthBits);
      if (val < 0) return false;
      codeLengths[i] = val == 0 ? 0 : (minCodeLength + val - 1) & 0xFF;
    }
    lzhBuildTree(_codeTree, _kCodeTreeElements, codeLengths, numCodes, _kLeaf8);
    return true;
  }

  // read_offset_tree
  bool _readOffsetTree(int numOffsets) {
    if (!_needOffsetTree) return true;
    final offsetLengths = Uint8List(8);
    var numCodes = 0;
    var singleOffset = 0;
    for (var off = 0; off < numOffsets; off++) {
      final len = r.readBits(3);
      if (len < 0) return false;
      offsetLengths[off] = len;
      if (len != 0) {
        singleOffset = off;
        numCodes++;
      }
    }
    if (numCodes == 1) {
      lzhSetTreeSingle(_offsetTree, singleOffset, _kLeaf8);
      return true;
    }
    lzhBuildTree(
        _offsetTree, _kOffsetTreeElements, offsetLengths, numOffsets, _kLeaf8);
    return true;
  }

  // rebuild_tree
  void _rebuildTree() {
    switch (_treeState) {
      case _unbuilt:
        _readCodeTree();
        _readOffsetTree(5);
        _treeState = _build1;
        _treeRebuildRemaining = 1024;
      case _build1:
        _readOffsetTree(6);
        _treeState = _build2;
        _treeRebuildRemaining = 1024;
      case _build2:
        _readOffsetTree(7);
        _treeState = _build3;
        _treeRebuildRemaining = 2048;
      case _build3:
        if (r.readBit() == 1) _readCodeTree();
        _readOffsetTree(8);
        _treeState = _continuing;
        _treeRebuildRemaining = 4096;
      case _continuing:
        if (r.readBit() == 1) {
          _readCodeTree();
          _readOffsetTree(8);
        }
        _treeRebuildRemaining = 4096;
    }
  }

  // output_byte
  int _outputByte(Uint8List buf, int pos, int b) {
    ringbuf[ringbufPos] = b;
    ringbufPos = (ringbufPos + 1) & (_kPm2RingBufferSize - 1);
    buf[pos] = b;
    _history.update(b);
    _treeRebuildRemaining--;
    if (_treeRebuildRemaining == 0) _rebuildTree();
    return pos + 1;
  }

  // history_get_count
  int _historyGetCount(int code) {
    if (code < 15) return code + 2;
    return _decodeVariableLength(r, _copyDecode, code - 15);
  }

  // history_get_offset
  int _historyGetOffset(int code) {
    var result = 0;
    int bits;
    if (code == 0) {
      bits = 6;
    } else if (code < 20) {
      final val = lzhReadFromTree(r, _offsetTree, _kLeaf8);
      if (val < 0) return -1;
      if (val == 0) {
        bits = 6;
      } else {
        bits = val + 5;
        result = 1 << bits;
      }
    } else {
      return 0;
    }
    final val = r.readBits(bits);
    if (val < 0) return -1;
    return result + val;
  }

  // lha_pm2_decoder_read (with read_single_byte and copy_from_history)
  @override
  int read(Uint8List buf, int off) {
    if (_treeState == _unbuilt) {
      r.readBit();
      _rebuildTree();
    }
    final code = lzhReadFromTree(r, _codeTree, _kLeaf8);
    if (code < 0) return 0;
    var pos = off;
    if (code < 8) {
      final offset = _decodeVariableLength(r, _historyDecode, code);
      if (offset < 0) return 0;
      final b = _history.find(offset & 0xFF);
      pos = _outputByte(buf, pos, b);
      return pos - off;
    }
    final toCopy = _historyGetCount(code - 8);
    final offset = _historyGetOffset(code - 8);
    if (toCopy < 0 || offset < 0) return 0;
    if (toCopy > _kPm2OutputBufferSize) return 0;
    const mask = _kPm2RingBufferSize - 1;
    final start = ringbufPos + _kPm2RingBufferSize - 1 - offset;
    for (var i = 0; i < toCopy; i++) {
      pos = _outputByte(buf, pos, ringbuf[(start + i) & mask]);
    }
    return pos - off;
  }
}
