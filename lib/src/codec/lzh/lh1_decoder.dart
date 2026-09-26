// Decoder of -lh1- (LHarc 1.x, adaptive Huffman codes and a 4 KiB window):
// a port of lh1_decoder.c of lhasa (ISC license, see LICENSE). The Node
// structure is kept as parallel typed arrays.

import 'dart:typed_data';

import 'lha_decoder.dart';
import 'lzh_bits.dart';

const int _kRingBufferSize = 4096;
const int _kTreeReorderLimit = 32 * 1024;
const int _kNumCodes = 314;
const int _kNumTreeNodes = _kNumCodes * 2 - 1;
const int _kNumOffsets = 64;
const int _kMinOffsetLength = 3;
const int _kCopyThreshold = 3;

// offset_fdist
const List<int> _offsetFdist = [1, 3, 8, 12, 24, 16];

/// LHALH1Decoder.
class Lh1Decoder extends LhaDecoder {
  final LzhBitReader r;
  final Uint8List ringbuf = Uint8List(_kRingBufferSize);
  int ringbufPos = 0;

  // Node: leaf, child_index, parent, freq, group
  final Uint8List _leaf = Uint8List(_kNumTreeNodes);
  final Uint16List _child = Uint16List(_kNumTreeNodes);
  final Uint16List _parent = Uint16List(_kNumTreeNodes);
  final Uint16List _freq = Uint16List(_kNumTreeNodes);
  final Uint16List _group = Uint16List(_kNumTreeNodes);

  final Uint16List _leafNodes = Uint16List(_kNumCodes);
  final Uint16List _groups = Uint16List(_kNumTreeNodes);
  int _numGroups = 0;
  final Uint16List _groupLeader = Uint16List(_kNumTreeNodes);
  final Uint8List _offsetLookup = Uint8List(256);
  final Uint8List _offsetLengths = Uint8List(_kNumOffsets);

  // lha_lh1_init
  Lh1Decoder(this.r) {
    _initGroups();
    _initTree();
    _initOffsetTable();
    ringbuf.fillRange(0, _kRingBufferSize, 0x20);
    ringbufPos = 0;
  }

  @override
  int get maxRead => _kNumCodes - 256 + _kCopyThreshold;

  // alloc_group
  int _allocGroup() => _groups[_numGroups++];

  // free_group
  void _freeGroup(int group) {
    _numGroups--;
    _groups[_numGroups] = group;
  }

  // init_groups
  void _initGroups() {
    for (var i = 0; i < _kNumTreeNodes; i++) {
      _groups[i] = i;
    }
    _numGroups = 0;
  }

  // init_tree
  void _initTree() {
    var nodeIndex = _kNumTreeNodes - 1;
    final leafGroup = _allocGroup();
    for (var i = 0; i < _kNumCodes; i++) {
      _leaf[nodeIndex] = 1;
      _child[nodeIndex] = i;
      _freq[nodeIndex] = 1;
      _group[nodeIndex] = leafGroup;
      _groupLeader[leafGroup] = nodeIndex;
      _leafNodes[i] = nodeIndex;
      nodeIndex--;
    }
    var child = _kNumTreeNodes - 1;
    while (nodeIndex >= 0) {
      _leaf[nodeIndex] = 0;
      _child[nodeIndex] = child;
      _parent[child] = nodeIndex;
      _parent[child - 1] = nodeIndex;
      _freq[nodeIndex] = _freq[child] + _freq[child - 1];
      if (_freq[nodeIndex] == _freq[nodeIndex + 1]) {
        _group[nodeIndex] = _group[nodeIndex + 1];
      } else {
        _group[nodeIndex] = _allocGroup();
      }
      _groupLeader[_group[nodeIndex]] = nodeIndex;
      nodeIndex--;
      child -= 2;
    }
  }

  // fill_offset_range
  void _fillOffsetRange(int code, int mask, int offset) {
    for (var i = 0; (i & ~mask) == 0; i++) {
      _offsetLookup[code | i] = offset;
    }
  }

  // init_offset_table
  void _initOffsetTable() {
    var code = 0;
    var offset = 0;
    for (var i = 0; i < _offsetFdist.length; i++) {
      final len = i + _kMinOffsetLength;
      final iterbit = 1 << (8 - len);
      for (var j = 0; j < _offsetFdist[i]; j++) {
        _fillOffsetRange(code, (iterbit - 1) & 0xFF, offset);
        _offsetLengths[offset] = len;
        code = (code + iterbit) & 0xFF;
        offset++;
      }
    }
  }

  // make_group_leader
  int _makeGroupLeader(int nodeIndex) {
    final group = _group[nodeIndex];
    final leaderIndex = _groupLeader[group];
    if (leaderIndex == nodeIndex) return nodeIndex;
    var tmp = _leaf[leaderIndex];
    _leaf[leaderIndex] = _leaf[nodeIndex];
    _leaf[nodeIndex] = tmp;
    tmp = _child[leaderIndex];
    _child[leaderIndex] = _child[nodeIndex];
    _child[nodeIndex] = tmp;
    _relink(nodeIndex);
    _relink(leaderIndex);
    return leaderIndex;
  }

  // the parent and leaf index updates of make_group_leader
  void _relink(int index) {
    final c = _child[index];
    if (_leaf[index] != 0) {
      _leafNodes[c] = index;
    } else {
      _parent[c] = index;
      _parent[c - 1] = index;
    }
  }

  // increment_node_freq
  void _incrementNodeFreq(int nodeIndex) {
    final other = nodeIndex - 1;
    _freq[nodeIndex]++;
    if (nodeIndex < _kNumTreeNodes - 1 &&
        _group[nodeIndex] == _group[nodeIndex + 1]) {
      _groupLeader[_group[nodeIndex]]++;
      if (_freq[nodeIndex] == _freq[other]) {
        _group[nodeIndex] = _group[other];
      } else {
        final g = _allocGroup();
        _group[nodeIndex] = g;
        _groupLeader[g] = nodeIndex;
      }
    } else {
      if (_freq[nodeIndex] == _freq[other]) {
        _freeGroup(_group[nodeIndex]);
        _group[nodeIndex] = _group[other];
      }
    }
  }

  void _copyNode(int to, int from) {
    _leaf[to] = _leaf[from];
    _child[to] = _child[from];
    _parent[to] = _parent[from];
    _freq[to] = _freq[from];
    _group[to] = _group[from];
  }

  // reconstruct_tree
  void _reconstructTree() {
    var leaf = 0;
    for (var i = 0; i < _kNumTreeNodes; i++) {
      if (_leaf[i] != 0) {
        _leaf[leaf] = 1;
        _child[leaf] = _child[i];
        _freq[leaf] = ((_freq[i] + 1) & 0xFFFF) >> 1;
        leaf++;
      }
    }
    leaf = _kNumCodes - 1;
    var child = _kNumTreeNodes - 1;
    var i = _kNumTreeNodes - 1;
    while (i >= 0) {
      while (child - i < 2) {
        _copyNode(i, leaf);
        _leafNodes[_child[leaf]] = i;
        i--;
        leaf--;
      }
      final freq = _freq[child] + _freq[child - 1];
      while (leaf >= 0 && freq >= _freq[leaf]) {
        _copyNode(i, leaf);
        _leafNodes[_child[leaf]] = i;
        i--;
        leaf--;
      }
      _leaf[i] = 0;
      _freq[i] = freq;
      _child[i] = child;
      _parent[child] = i;
      _parent[child - 1] = i;
      i--;
      child -= 2;
    }
    _initGroups();
    var group = _allocGroup();
    _group[0] = group;
    _groupLeader[group] = 0;
    for (i = 1; i < _kNumTreeNodes; i++) {
      if (_freq[i] == _freq[i - 1]) {
        _group[i] = _group[i - 1];
      } else {
        group = _allocGroup();
        _group[i] = group;
        _groupLeader[group] = i;
      }
    }
  }

  // increment_for_code
  void _incrementForCode(int code) {
    if (_freq[0] >= _kTreeReorderLimit) _reconstructTree();
    _freq[0]++;
    var nodeIndex = _leafNodes[code];
    while (nodeIndex != 0) {
      nodeIndex = _makeGroupLeader(nodeIndex);
      _incrementNodeFreq(nodeIndex);
      nodeIndex = _parent[nodeIndex];
    }
  }

  // read_code
  int _readCode() {
    var nodeIndex = 0;
    while (_leaf[nodeIndex] == 0) {
      final bit = r.readBit();
      if (bit < 0) return -1;
      nodeIndex = _child[nodeIndex] - bit;
    }
    final result = _child[nodeIndex];
    _incrementForCode(result);
    return result;
  }

  // read_offset
  int _readOffset() {
    final future = r.peekBits(8);
    if (future < 0) return -1;
    final offset = _offsetLookup[future];
    r.readBits(_offsetLengths[offset]);
    final offset2 = r.readBits(6);
    if (offset2 < 0) return -1;
    return (offset << 6) | offset2;
  }

  // lha_lh1_read
  @override
  int read(Uint8List buf, int off) {
    final code = _readCode();
    if (code < 0) return 0;
    const mask = _kRingBufferSize - 1;
    if (code < 0x100) {
      buf[off] = code;
      ringbuf[ringbufPos] = code;
      ringbufPos = (ringbufPos + 1) & mask;
      return 1;
    }
    final offset = _readOffset();
    if (offset < 0) return 0;
    final count = code - 0x100 + _kCopyThreshold;
    final start = ringbufPos - offset + _kRingBufferSize - 1;
    for (var i = 0; i < count; i++) {
      final b = ringbuf[(start + i) & mask];
      buf[off + i] = b;
      ringbuf[ringbufPos] = b;
      ringbufPos = (ringbufPos + 1) & mask;
    }
    return count;
  }
}
