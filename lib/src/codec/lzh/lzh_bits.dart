// Bit streams and Huffman trees shared by the LHA and ARJ codecs.
//
// LzhBitReader is bit_stream_reader.c of lhasa (ISC license, see LICENSE),
// reading from an InStream through a buffer instead of a callback; the tree
// functions are tree_decode.c of lhasa. LzhBitWriter is the matching
// writer (most significant bit first), written for the encoders here.

import 'dart:typed_data';

import '../../io/streams.dart';

/// Reads bits, most significant first, from an [InStream].
class LzhBitReader {
  final InStream _in;
  final Uint8List _buf;
  int _pos = 0;
  int _len = 0;
  bool _eof = false;

  /// When true, the end of the input reads as zero bytes (the PMarc
  /// -pm1- decoder, see read_callback_wrapper in pm1_decoder.c).
  final bool zeroFillAtEnd;

  // bits waiting to be read, aligned to bit 31
  int bitBuffer = 0;
  int bits = 0;

  LzhBitReader(this._in, {this.zeroFillAtEnd = false, int bufSize = 1 << 14})
      : _buf = Uint8List(bufSize);

  void _refill() {
    if (_eof) return;
    _len = _in.read(_buf, 0, _buf.length);
    _pos = 0;
    if (_len == 0) _eof = true;
  }

  /// The next input byte, or -1 at the end (the decoder callback).
  int readByte() {
    if (_pos >= _len) {
      _refill();
      if (_pos >= _len) return zeroFillAtEnd ? 0 : -1;
    }
    return _buf[_pos++];
  }

  /// Reads exactly [n] bytes to b[off...]; false when the input ends.
  bool readBytes(Uint8List b, int off, int n) {
    for (var i = 0; i < n; i++) {
      final c = readByte();
      if (c < 0) return false;
      b[off + i] = c;
    }
    return true;
  }

  // peek_bits
  /// The next [n] bits (n <= 24) without removing them, or -1 at the end.
  int peekBits(int n) {
    if (n == 0) return 0;
    while (bits < n) {
      // maximum number of bytes that fit
      final fillBytes = (32 - bits) >> 3;
      var got = 0;
      for (var i = 0; i < fillBytes; i++) {
        final c = readByte();
        if (c < 0) break;
        bitBuffer |= c << (24 - bits);
        bits += 8;
        got++;
      }
      if (got == 0) return -1;
    }
    return (bitBuffer >> (32 - n)) & ((1 << n) - 1);
  }

  // read_bits
  int readBits(int n) {
    final result = peekBits(n);
    if (result >= 0) {
      bitBuffer = (bitBuffer << n) & 0xFFFFFFFF;
      bits -= n;
    }
    return result;
  }

  // read_bit
  int readBit() {
    if (bits == 0) {
      final c = readByte();
      if (c < 0) return -1;
      bitBuffer = c << 24;
      bits = 8;
    }
    final b = (bitBuffer >> 31) & 1;
    bitBuffer = (bitBuffer << 1) & 0xFFFFFFFF;
    bits--;
    return b;
  }
}

/// Writes bits, most significant first, to an [OutStream].
class LzhBitWriter {
  final OutStream _out;
  final Uint8List _buf = Uint8List(1 << 14);
  int _n = 0;
  int _acc = 0;
  int _accBits = 0;

  /// Bytes written to the output so far (flushed or buffered).
  int written = 0;

  LzhBitWriter(this._out);

  /// Writes the low [n] bits of [v] (n <= 24).
  void putBits(int n, int v) {
    if (n == 0) return;
    _acc = (_acc << n) | (v & ((1 << n) - 1));
    _accBits += n;
    while (_accBits >= 8) {
      _accBits -= 8;
      final b = (_acc >> _accBits) & 0xFF;
      if (_n == _buf.length) _drain();
      _buf[_n++] = b;
      written++;
    }
    _acc &= (1 << _accBits) - 1;
  }

  void _drain() {
    if (_n > 0) _out.write(_buf, 0, _n);
    _n = 0;
  }

  /// Pads the last byte with zero bits and writes out the buffer.
  void flush() {
    if (_accBits > 0) putBits(8 - _accBits, 0);
    _drain();
  }
}

// ---------------------------------------------------------------------------
// tree_decode.c: a code tree in an array. Element 0 is the root; a node
// value without [leafFlag] is the index of its two children (value for
// bit 0, value + 1 for bit 1); a leaf holds the code ORed with [leafFlag].

// init_tree
void lzhInitTree(List<int> tree, int treeLen, int leafFlag) {
  for (var i = 0; i < treeLen; i++) {
    tree[i] = leafFlag;
  }
}

// set_tree_single
void lzhSetTreeSingle(List<int> tree, int code, int leafFlag) {
  tree[0] = (code | leafFlag) & (leafFlag * 2 - 1);
}

// build_tree (with expand_queue, read_next_entry, add_codes_with_length)
void lzhBuildTree(List<int> tree, int treeLen, Uint8List codeLengths,
    int numCodeLengths, int leafFlag) {
  var nextEntry = 0;
  var treeAllocated = 1;
  var codeLen = 0;
  for (;;) {
    // expand_queue
    final newNodes = (treeAllocated - nextEntry) * 2;
    if (treeAllocated + newNodes <= treeLen) {
      final endOffset = treeAllocated;
      while (nextEntry < endOffset) {
        tree[nextEntry] = treeAllocated;
        treeAllocated += 2;
        nextEntry++;
      }
    }
    codeLen++;
    // add_codes_with_length
    var codesRemaining = false;
    for (var i = 0; i < numCodeLengths; i++) {
      final l = codeLengths[i];
      if (l == codeLen) {
        // read_next_entry
        var node = 0;
        if (nextEntry < treeAllocated) {
          node = nextEntry;
          nextEntry++;
        }
        tree[node] = i | leafFlag;
      } else if (l > codeLen) {
        codesRemaining = true;
      }
    }
    if (!codesRemaining) break;
  }
}

// read_from_tree
/// Walks [tree] from the root with bits of [r]; the code, or -1 at the
/// end of the input.
int lzhReadFromTree(LzhBitReader r, List<int> tree, int leafFlag) {
  var code = tree[0];
  while ((code & leafFlag) == 0) {
    final bit = r.readBit();
    if (bit < 0) return -1;
    code = tree[code + bit];
  }
  return code & ~leafFlag;
}
