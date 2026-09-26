// Output of deflated data using Huffman coding: port of trees.c of
// zlib 1.3.1 (Jean-loup Gailly, zlib license, see LICENSE). A part of
// deflate.dart, since both work on the deflate_state.
//
// The static tables are built at first use by tr_static_init (the
// GEN_TREES_H path of trees.c) instead of being read from trees.h; they are
// the same tables.

part of 'deflate.dart';

const int _maxBlBits = 7; // MAX_BL_BITS
const int _endBlock = 256; // END_BLOCK
const int _rep3_6 = 16; // REP_3_6
const int _repz3_10 = 17; // REPZ_3_10
const int _repz11_138 = 18; // REPZ_11_138

// extra_lbits: extra bits for each length code
final Int32List _extraLbits = Int32List.fromList(const [
  0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, //
  5, 5, 5, 5, 0
]);

// extra_dbits: extra bits for each distance code
final Int32List _extraDbits = Int32List.fromList(const [
  0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, //
  11, 11, 12, 12, 13, 13
]);

// extra_blbits: extra bits for each bit length code
final Int32List _extraBlbits = Int32List.fromList(
    const [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 3, 7]);

// bl_order: the lengths of the bit length codes are sent in order of
// decreasing probability, to avoid transmitting the lengths for unused bit
// length codes.
const List<int> _blOrder = [
  16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 //
];

const int _distCodeLen = 512; // DIST_CODE_LEN

/// The static tables of trees.c (static_ltree, static_dtree, _dist_code,
/// _length_code, base_length, base_dist), built by tr_static_init.
class _StaticTables {
  final Uint16List ltreeFc = Uint16List(_lCodes + 2); // static_ltree
  final Uint16List ltreeDl = Uint16List(_lCodes + 2);
  final Uint16List dtreeFc = Uint16List(_dCodes); // static_dtree
  final Uint16List dtreeDl = Uint16List(_dCodes);
  final Uint8List distCode = Uint8List(_distCodeLen); // _dist_code
  final Uint8List lengthCode =
      Uint8List(zMaxMatch - zMinMatch + 1); // _length_code
  final Int32List baseLength = Int32List(_lengthCodes); // base_length
  final Int32List baseDist = Int32List(_dCodes); // base_dist

  // tr_static_init
  _StaticTables() {
    final blCount = Uint16List(_maxBits + 1);

    // Initialize the mapping length (0..255) . length code (0..28)
    var length = 0;
    var code = 0;
    for (code = 0; code < _lengthCodes - 1; code++) {
      baseLength[code] = length;
      for (var n = 0; n < (1 << _extraLbits[code]); n++) {
        lengthCode[length++] = code;
      }
    }
    // Note that the length 255 (match length 258) can be represented in
    // two different ways: code 284 + 5 bits or code 285, so we overwrite
    // length_code[255] to use the best encoding:
    lengthCode[length - 1] = code;

    // Initialize the mapping dist (0..32K) . dist code (0..29)
    var dist = 0;
    for (code = 0; code < 16; code++) {
      baseDist[code] = dist;
      for (var n = 0; n < (1 << _extraDbits[code]); n++) {
        distCode[dist++] = code;
      }
    }
    dist >>= 7; // from now on, all distances are divided by 128
    for (; code < _dCodes; code++) {
      baseDist[code] = dist << 7;
      for (var n = 0; n < (1 << (_extraDbits[code] - 7)); n++) {
        distCode[256 + dist++] = code;
      }
    }

    // Construct the codes of the static literal tree
    var n = 0;
    while (n <= 143) {
      ltreeDl[n++] = 8;
      blCount[8]++;
    }
    while (n <= 255) {
      ltreeDl[n++] = 9;
      blCount[9]++;
    }
    while (n <= 279) {
      ltreeDl[n++] = 7;
      blCount[7]++;
    }
    while (n <= 287) {
      ltreeDl[n++] = 8;
      blCount[8]++;
    }
    // Codes 286 and 287 do not exist, but we must include them in the tree
    // construction to get a canonical Huffman tree (longest code all ones)
    _genCodes(ltreeFc, ltreeDl, _lCodes + 1, blCount);

    // The static distance tree is trivial:
    for (n = 0; n < _dCodes; n++) {
      dtreeDl[n] = 5;
      dtreeFc[n] = _biReverse(n, 5);
    }
  }
}

final _StaticTables _tables = _StaticTables();
final Uint8List _distCode = _tables.distCode;
final Uint8List _lengthCode = _tables.lengthCode;

/// static_tree_desc
class _StaticTreeDesc {
  final Uint16List? staticFc; // static tree or NULL
  final Uint16List? staticDl;
  final Int32List extraBits; // extra bits for each code or NULL
  final int extraBase; // base index for extra_bits
  final int elems; // max number of elements in the tree
  final int maxLength; // max bit length for the codes
  const _StaticTreeDesc(this.staticFc, this.staticDl, this.extraBits,
      this.extraBase, this.elems, this.maxLength);
}

// static_l_desc
final _StaticTreeDesc _staticLDesc = _StaticTreeDesc(_tables.ltreeFc,
    _tables.ltreeDl, _extraLbits, _literals + 1, _lCodes, _maxBits);

// static_d_desc
final _StaticTreeDesc _staticDDesc = _StaticTreeDesc(
    _tables.dtreeFc, _tables.dtreeDl, _extraDbits, 0, _dCodes, _maxBits);

// static_bl_desc
final _StaticTreeDesc _staticBlDesc =
    _StaticTreeDesc(null, null, _extraBlbits, 0, _blCodes, _maxBlBits);

/// tree_desc
class _TreeDesc {
  final Uint16List fc; // the dynamic tree (freq / code)
  final Uint16List dl; // the dynamic tree (dad / len)
  int maxCode = 0; // largest code with non zero frequency
  final _StaticTreeDesc statDesc; // the corresponding static tree
  _TreeDesc(this.fc, this.dl, this.statDesc);
}

// bi_reverse: reverses the first len bits of a code.
int _biReverse(int code, int len) {
  var res = 0;
  do {
    res |= code & 1;
    code >>= 1;
    res <<= 1;
  } while (--len > 0);
  return res >> 1;
}

// gen_codes: generates the codes for a given tree and bit counts (which
// need not be optimal).
void _genCodes(Uint16List fc, Uint16List dl, int maxCode, Uint16List blCount) {
  final nextCode = Uint16List(_maxBits + 1); // next code value for each len
  var code = 0; // running code value

  // The distribution counts are first used to generate the code values
  // without bit reversal.
  for (var bits = 1; bits <= _maxBits; bits++) {
    code = (code + blCount[bits - 1]) << 1;
    nextCode[bits] = code;
  }

  for (var n = 0; n <= maxCode; n++) {
    final len = dl[n];
    if (len == 0) continue;
    // Now reverse the bits
    fc[n] = _biReverse(nextCode[len]++, len);
  }
}

// SMALLEST: index within the heap array of least frequent node in the
// Huffman tree
const int _smallest = 1;

extension _Trees on DeflateState {
  // put_short: outputs a short LSB first on the stream.
  void _putShort(int w) {
    pendingBuf[pending++] = w & 0xff;
    pendingBuf[pending++] = (w >> 8) & 0xff;
  }

  // send_bits: sends a value on a given number of bits.
  void _sendBits(int value, int length) {
    if (biValid > _bufSize - length) {
      biBuf = (biBuf | (value << biValid)) & 0xffff;
      _putShort(biBuf);
      biBuf = (value >> (_bufSize - biValid)) & 0xffff;
      biValid += length - _bufSize;
    } else {
      biBuf |= value << biValid;
      biValid += length;
    }
  }

  // bi_flush: flushes the bit buffer, keeping at most 7 bits in it.
  void _biFlush() {
    if (biValid == 16) {
      _putShort(biBuf);
      biBuf = 0;
      biValid = 0;
    } else if (biValid >= 8) {
      pendingBuf[pending++] = biBuf & 0xff;
      biBuf >>= 8;
      biValid -= 8;
    }
  }

  // bi_windup: flushes the bit buffer and aligns the output on a byte
  // boundary.
  void _biWindup() {
    if (biValid > 8) {
      _putShort(biBuf);
    } else if (biValid > 0) {
      pendingBuf[pending++] = biBuf & 0xff;
    }
    biBuf = 0;
    biValid = 0;
  }

  // init_block: initializes a new block.
  void _initBlock() {
    // Initialize the trees.
    dynLtreeFc.fillRange(0, _lCodes, 0);
    dynDtreeFc.fillRange(0, _dCodes, 0);
    blTreeFc.fillRange(0, _blCodes, 0);

    dynLtreeFc[_endBlock] = 1;
    optLen = staticLen = 0;
    symNext = matches = 0;
  }

  // _tr_init: initializes the tree data structures for a new zlib stream.
  void _trInit() {
    biBuf = 0;
    biValid = 0;

    // Initialize the first block of the first file:
    _initBlock();
  }

  // smaller: compares two subtrees, using the tree depth as tie breaker
  // when the subtrees have equal frequency.
  // pqdownheap: restores the heap property by moving down the tree
  // starting at node k.
  void _pqdownheap(Uint16List tree, int k) {
    final h = heap;
    final d = depth;
    final v = h[k];
    var j = k << 1; // left son of k
    while (j <= heapLen) {
      // Set j to the smallest of the two sons:
      if (j < heapLen) {
        final a = h[j + 1], b = h[j];
        if (tree[a] < tree[b] || (tree[a] == tree[b] && d[a] <= d[b])) j++;
      }
      // Exit if v is smaller than both sons
      final hj = h[j];
      if (tree[v] < tree[hj] || (tree[v] == tree[hj] && d[v] <= d[hj])) {
        break;
      }

      // Exchange v with the smallest son
      h[k] = hj;
      k = j;

      // And continue down the tree, setting j to the left son of k
      j <<= 1;
    }
    h[k] = v;
  }

  // gen_bitlen: computes the optimal bit lengths for a tree and updates
  // the total bit length for the current block.
  void _genBitlen(_TreeDesc desc) {
    final fc = desc.fc;
    final dl = desc.dl;
    final maxCode = desc.maxCode;
    final stree = desc.statDesc.staticDl;
    final extra = desc.statDesc.extraBits;
    final base = desc.statDesc.extraBase;
    final maxLength = desc.statDesc.maxLength;
    int h; // heap index
    int n, m; // iterate over the tree elements
    int bits; // bit length
    int xbits; // extra bits
    int f; // frequency
    var overflow = 0; // number of elements with bit length too large

    blCount.fillRange(0, _maxBits + 1, 0);

    // In a first pass, compute the optimal bit lengths (which may overflow
    // in the case of the bit length tree).
    dl[heap[heapMax]] = 0; // root of the heap

    for (h = heapMax + 1; h < _heapSize; h++) {
      n = heap[h];
      bits = dl[dl[n]] + 1;
      if (bits > maxLength) {
        bits = maxLength;
        overflow++;
      }
      dl[n] = bits;
      // We overwrite tree[n].Dad which is no longer needed

      if (n > maxCode) continue; // not a leaf node

      blCount[bits]++;
      xbits = 0;
      if (n >= base) xbits = extra[n - base];
      f = fc[n];
      optLen += f * (bits + xbits);
      if (stree != null) staticLen += f * (stree[n] + xbits);
    }
    if (overflow == 0) return;

    // This happens for example on obj2 and pic of the Calgary corpus

    // Find the first bit length which could increase:
    do {
      bits = maxLength - 1;
      while (blCount[bits] == 0) {
        bits--;
      }
      blCount[bits]--; // move one leaf down the tree
      blCount[bits + 1] += 2; // move one overflow item as its brother
      blCount[maxLength]--;
      // The brother of the overflow item also moves one step up, but this
      // does not affect bl_count[max_length]
      overflow -= 2;
    } while (overflow > 0);

    // Now recompute all bit lengths, scanning in increasing frequency. h is
    // still equal to HEAP_SIZE. (It is simpler to reconstruct all lengths
    // instead of fixing only the wrong ones.)
    for (bits = maxLength; bits != 0; bits--) {
      n = blCount[bits];
      while (n != 0) {
        m = heap[--h];
        if (m > maxCode) continue;
        if (dl[m] != bits) {
          optLen += (bits - dl[m]) * fc[m];
          dl[m] = bits;
        }
        n--;
      }
    }
  }

  // build_tree: constructs one Huffman tree and assigns the code bit
  // strings and lengths. Updates the total bit length for the current
  // block.
  void _buildTree(_TreeDesc desc) {
    final fc = desc.fc;
    final dl = desc.dl;
    final stree = desc.statDesc.staticDl;
    final elems = desc.statDesc.elems;
    int n, m; // iterate over heap elements
    var maxCode = -1; // largest code with non zero frequency
    int node; // new node being created

    // Construct the initial heap, with least frequent element in
    // heap[SMALLEST]. The sons of heap[n] are heap[2*n] and heap[2*n + 1].
    // heap[0] is not used.
    heapLen = 0;
    heapMax = _heapSize;

    for (n = 0; n < elems; n++) {
      if (fc[n] != 0) {
        heap[++heapLen] = maxCode = n;
        depth[n] = 0;
      } else {
        dl[n] = 0;
      }
    }

    // The pkzip format requires that at least one distance code exists, and
    // that at least one bit should be sent even if there is only one
    // possible code. So to avoid special checks later on we force at least
    // two codes of non zero frequency.
    while (heapLen < 2) {
      node = heap[++heapLen] = (maxCode < 2 ? ++maxCode : 0);
      fc[node] = 1;
      depth[node] = 0;
      optLen--;
      if (stree != null) staticLen -= stree[node];
      // node is 0 or 1 so it does not have extra bits
    }
    desc.maxCode = maxCode;

    // The elements heap[heap_len/2 + 1 .. heap_len] are leaves of the tree,
    // establish sub-heaps of increasing lengths:
    for (n = heapLen ~/ 2; n >= 1; n--) {
      _pqdownheap(fc, n);
    }

    // Construct the Huffman tree by repeatedly combining the least two
    // frequent nodes.
    node = elems; // next internal node of the tree
    do {
      // pqremove(s, tree, n): n = node of least frequency
      n = heap[_smallest];
      heap[_smallest] = heap[heapLen--];
      _pqdownheap(fc, _smallest);

      m = heap[_smallest]; // m = node of next least frequency

      heap[--heapMax] = n; // keep the nodes sorted by frequency
      heap[--heapMax] = m;

      // Create a new node father of n and m
      fc[node] = fc[n] + fc[m];
      depth[node] = (depth[n] >= depth[m] ? depth[n] : depth[m]) + 1;
      dl[n] = dl[m] = node;

      // and insert the new node in the heap
      heap[_smallest] = node++;
      _pqdownheap(fc, _smallest);
    } while (heapLen >= 2);

    heap[--heapMax] = heap[_smallest];

    // At this point, the fields freq and dad are set. We can now generate
    // the bit lengths.
    _genBitlen(desc);

    // The field len is now set, we can generate the bit codes
    _genCodes(fc, dl, maxCode, blCount);
  }

  // scan_tree: scans a literal or distance tree to determine the
  // frequencies of the codes in the bit length tree.
  void _scanTree(Uint16List dl, int maxCode) {
    var prevlen = -1; // last emitted length
    int curlen; // length of current code
    var nextlen = dl[0]; // length of next code
    var count = 0; // repeat count of the current code
    var maxCount = 7; // max repeat count
    var minCount = 4; // min repeat count
    final bl = blTreeFc;

    if (nextlen == 0) {
      maxCount = 138;
      minCount = 3;
    }
    dl[maxCode + 1] = 0xffff; // guard

    for (var n = 0; n <= maxCode; n++) {
      curlen = nextlen;
      nextlen = dl[n + 1];
      if (++count < maxCount && curlen == nextlen) {
        continue;
      } else if (count < minCount) {
        bl[curlen] += count;
      } else if (curlen != 0) {
        if (curlen != prevlen) bl[curlen]++;
        bl[_rep3_6]++;
      } else if (count <= 10) {
        bl[_repz3_10]++;
      } else {
        bl[_repz11_138]++;
      }
      count = 0;
      prevlen = curlen;
      if (nextlen == 0) {
        maxCount = 138;
        minCount = 3;
      } else if (curlen == nextlen) {
        maxCount = 6;
        minCount = 3;
      } else {
        maxCount = 7;
        minCount = 4;
      }
    }
  }

  // send_tree: sends a literal or distance tree in compressed form, using
  // the codes in bl_tree.
  void _sendTree(Uint16List dl, int maxCode) {
    var prevlen = -1; // last emitted length
    int curlen; // length of current code
    var nextlen = dl[0]; // length of next code
    var count = 0; // repeat count of the current code
    var maxCount = 7; // max repeat count
    var minCount = 4; // min repeat count
    final blFc = blTreeFc;
    final blDl = blTreeDl;

    // tree[max_code + 1].Len = -1;  guard already set
    if (nextlen == 0) {
      maxCount = 138;
      minCount = 3;
    }

    for (var n = 0; n <= maxCode; n++) {
      curlen = nextlen;
      nextlen = dl[n + 1];
      if (++count < maxCount && curlen == nextlen) {
        continue;
      } else if (count < minCount) {
        do {
          _sendBits(blFc[curlen], blDl[curlen]);
        } while (--count != 0);
      } else if (curlen != 0) {
        if (curlen != prevlen) {
          _sendBits(blFc[curlen], blDl[curlen]);
          count--;
        }
        _sendBits(blFc[_rep3_6], blDl[_rep3_6]);
        _sendBits(count - 3, 2);
      } else if (count <= 10) {
        _sendBits(blFc[_repz3_10], blDl[_repz3_10]);
        _sendBits(count - 3, 3);
      } else {
        _sendBits(blFc[_repz11_138], blDl[_repz11_138]);
        _sendBits(count - 11, 7);
      }
      count = 0;
      prevlen = curlen;
      if (nextlen == 0) {
        maxCount = 138;
        minCount = 3;
      } else if (curlen == nextlen) {
        maxCount = 6;
        minCount = 3;
      } else {
        maxCount = 7;
        minCount = 4;
      }
    }
  }

  // build_bl_tree: constructs the Huffman tree for the bit lengths and
  // returns the index in bl_order of the last bit length code to send.
  int _buildBlTree() {
    int maxBlindex; // index of last bit length code of non zero freq

    // Determine the bit length frequencies for literal and distance trees
    _scanTree(dynLtreeDl, _lDesc.maxCode);
    _scanTree(dynDtreeDl, _dDesc.maxCode);

    // Build the bit length tree:
    _buildTree(_blDesc);
    // opt_len now includes the length of the tree representations, except
    // the lengths of the bit lengths codes and the 5 + 5 + 4 bits for the
    // counts.

    // Determine the number of bit length codes to send. The pkzip format
    // requires that at least 4 bit length codes be sent.
    for (maxBlindex = _blCodes - 1; maxBlindex >= 3; maxBlindex--) {
      if (blTreeDl[_blOrder[maxBlindex]] != 0) break;
    }
    // Update opt_len to include the bit length tree and counts
    optLen += 3 * (maxBlindex + 1) + 5 + 5 + 4;

    return maxBlindex;
  }

  // send_all_trees: sends the header for a block using dynamic Huffman
  // trees: the counts, the lengths of the bit length codes, the literal
  // tree and the distance tree.
  void _sendAllTrees(int lcodes, int dcodes, int blcodes) {
    _sendBits(lcodes - 257, 5); // not +255 as stated in appnote.txt
    _sendBits(dcodes - 1, 5);
    _sendBits(blcodes - 4, 4); // not -3 as stated in appnote.txt
    for (var rank = 0; rank < blcodes; rank++) {
      _sendBits(blTreeDl[_blOrder[rank]], 3);
    }

    _sendTree(dynLtreeDl, lcodes - 1); // literal tree

    _sendTree(dynDtreeDl, dcodes - 1); // distance tree
  }

  // _tr_stored_block: sends a stored block. [buf] is an offset in the
  // window, or -1 for none.
  void _trStoredBlock(int buf, int storedLen, int last) {
    _sendBits((zStoredBlock << 1) + last, 3); // send block type
    _biWindup(); // align on byte boundary
    _putShort(storedLen & 0xffff);
    _putShort(~storedLen & 0xffff);
    if (storedLen != 0) {
      pendingBuf.setRange(pending, pending + storedLen, window, buf);
    }
    pending += storedLen;
  }

  // _tr_flush_bits: flushes the bits in the bit buffer to pending output
  // (leaves at most 7 bits)
  void _trFlushBits() {
    _biFlush();
  }

  // _tr_align: sends one empty static block to give enough lookahead for
  // inflate. This takes 10 bits, of which 7 may remain in the bit buffer.
  void _trAlign() {
    _sendBits(zStaticTrees << 1, 3);
    _sendBits(_tables.ltreeFc[_endBlock], _tables.ltreeDl[_endBlock]);
    _biFlush();
  }

  // compress_block: sends the block data compressed using the given
  // Huffman trees. The bit buffer is kept in locals (send_bits inline).
  void _compressBlock(
      Uint16List lcodeFc, Uint16List lcodeDl, Uint16List dcodeFc,
      Uint16List dcodeDl) {
    int dist; // distance of matched string
    int lc; // match length or unmatched char (if dist == 0)
    var sx = symBuf; // running index in symbol buffers
    final end = symBuf + symNext;
    int code; // the code to send
    int extra; // number of extra bits to send
    final buf = pendingBuf;
    var bb = biBuf;
    var bv = biValid;
    var p = pending;
    final lengthCode = _lengthCode;
    final distCode = _distCode;
    final baseLength = _tables.baseLength;
    final baseDist = _tables.baseDist;
    final extraL = _extraLbits;
    final extraD = _extraDbits;
    int value, len;

    if (symNext != 0) {
      do {
        dist = buf[sx++];
        dist += buf[sx++] << 8;
        lc = buf[sx++];
        if (dist == 0) {
          // send_code(s, lc, ltree): send a literal byte
          value = lcodeFc[lc];
          len = lcodeDl[lc];
          if (bv > _bufSize - len) {
            bb = (bb | (value << bv)) & 0xffff;
            buf[p++] = bb & 0xff;
            buf[p++] = bb >> 8;
            bb = (value >> (_bufSize - bv)) & 0xffff;
            bv += len - _bufSize;
          } else {
            bb |= value << bv;
            bv += len;
          }
        } else {
          // Here, lc is the match length - MIN_MATCH
          code = lengthCode[lc];
          // send the length code
          value = lcodeFc[code + _literals + 1];
          len = lcodeDl[code + _literals + 1];
          if (bv > _bufSize - len) {
            bb = (bb | (value << bv)) & 0xffff;
            buf[p++] = bb & 0xff;
            buf[p++] = bb >> 8;
            bb = (value >> (_bufSize - bv)) & 0xffff;
            bv += len - _bufSize;
          } else {
            bb |= value << bv;
            bv += len;
          }
          extra = extraL[code];
          if (extra != 0) {
            lc -= baseLength[code];
            // send the extra length bits
            if (bv > _bufSize - extra) {
              bb = (bb | (lc << bv)) & 0xffff;
              buf[p++] = bb & 0xff;
              buf[p++] = bb >> 8;
              bb = (lc >> (_bufSize - bv)) & 0xffff;
              bv += extra - _bufSize;
            } else {
              bb |= lc << bv;
              bv += extra;
            }
          }
          dist--; // dist is now the match distance - 1
          code = dist < 256 ? distCode[dist] : distCode[256 + (dist >> 7)];

          // send the distance code
          value = dcodeFc[code];
          len = dcodeDl[code];
          if (bv > _bufSize - len) {
            bb = (bb | (value << bv)) & 0xffff;
            buf[p++] = bb & 0xff;
            buf[p++] = bb >> 8;
            bb = (value >> (_bufSize - bv)) & 0xffff;
            bv += len - _bufSize;
          } else {
            bb |= value << bv;
            bv += len;
          }
          extra = extraD[code];
          if (extra != 0) {
            dist -= baseDist[code];
            // send the extra distance bits
            if (bv > _bufSize - extra) {
              bb = (bb | (dist << bv)) & 0xffff;
              buf[p++] = bb & 0xff;
              buf[p++] = bb >> 8;
              bb = (dist >> (_bufSize - bv)) & 0xffff;
              bv += extra - _bufSize;
            } else {
              bb |= dist << bv;
              bv += extra;
            }
          }
        } // literal or match pair ?
      } while (sx < end);
    }

    biBuf = bb;
    biValid = bv;
    pending = p;
    // send_code(s, END_BLOCK, ltree)
    _sendBits(lcodeFc[_endBlock], lcodeDl[_endBlock]);
  }

  // detect_data_type: checks if the data type is TEXT or BINARY.
  int _detectDataType() {
    // block_mask is the bit mask of block-listed bytes
    // set bits 0..6, 14..25, and 28..31
    var blockMask = 0xf3ffc07f;
    int n;

    // Check for non-textual ("block-listed") bytes.
    for (n = 0; n <= 31; n++, blockMask >>= 1) {
      if ((blockMask & 1) != 0 && dynLtreeFc[n] != 0) return ZDataType.binary;
    }

    // Check for textual ("allow-listed") bytes.
    if (dynLtreeFc[9] != 0 || dynLtreeFc[10] != 0 || dynLtreeFc[13] != 0) {
      return ZDataType.text;
    }
    for (n = 32; n < _literals; n++) {
      if (dynLtreeFc[n] != 0) return ZDataType.text;
    }

    // There are no "block-listed" or "allow-listed" bytes: this stream
    // either is empty or has tolerated ("gray-listed") bytes only.
    return ZDataType.binary;
  }

  // _tr_flush_block: determines the best encoding for the current block:
  // dynamic trees, static trees or store, and writes out the encoded
  // block. [buf] is an offset in the window, or -1 for none.
  void _trFlushBlock(int buf, int storedLen, int last) {
    int optLenb, staticLenb; // opt_len and static_len in bytes
    var maxBlindex = 0; // index of last bit length code of non zero freq

    // Build the Huffman trees unless a stored block is forced
    if (level > 0) {
      // Check if the file is binary or text
      if (dataType == ZDataType.unknown) dataType = _detectDataType();

      // Construct the literal and distance trees
      _buildTree(_lDesc);

      _buildTree(_dDesc);
      // At this point, opt_len and static_len are the total bit lengths of
      // the compressed block data, excluding the tree representations.

      // Build the bit length tree for the above two trees, and get the
      // index in bl_order of the last bit length code to send.
      maxBlindex = _buildBlTree();

      // Determine the best encoding. Compute the block lengths in bytes.
      optLenb = (optLen + 3 + 7) >> 3;
      staticLenb = (staticLen + 3 + 7) >> 3;

      if (staticLenb <= optLenb || strategy == ZStrategy.fixed) {
        optLenb = staticLenb;
      }
    } else {
      optLenb = staticLenb = storedLen + 5; // force a stored block
    }

    if (storedLen + 4 <= optLenb && buf != -1) {
      // 4: two words for the lengths
      // The test buf != NULL is only necessary if LIT_BUFSIZE > WSIZE.
      // Otherwise we can't have processed more than WSIZE input bytes
      // since the last block flush, because compression would have been
      // successful. If LIT_BUFSIZE <= WSIZE, it is never too late to
      // transform a block into a stored block.
      _trStoredBlock(buf, storedLen, last);
    } else if (staticLenb == optLenb) {
      _sendBits((zStaticTrees << 1) + last, 3);
      _compressBlock(
          _tables.ltreeFc, _tables.ltreeDl, _tables.dtreeFc, _tables.dtreeDl);
    } else {
      _sendBits((zDynTrees << 1) + last, 3);
      _sendAllTrees(_lDesc.maxCode + 1, _dDesc.maxCode + 1, maxBlindex + 1);
      _compressBlock(dynLtreeFc, dynLtreeDl, dynDtreeFc, dynDtreeDl);
    }
    _initBlock();

    if (last != 0) _biWindup();
  }
}
