// Huffman code construction: port of huffman.c of bzip2 1.0.8.
// bzip2/libbzip2 is Copyright (C) 1996-2019 Julian Seward, under the bzip2
// license (BSD style, see LICENSE).

import 'dart:typed_data';

import 'bzip2_tables.dart';

/// The work arrays of BZ2_hbMakeCodeLengths (locals in C).
class HuffmanWork {
  final Int32List heap = Int32List(bzMaxAlphaSize + 2);
  final Int32List weight = Int32List(bzMaxAlphaSize * 2);
  final Int32List parent = Int32List(bzMaxAlphaSize * 2);
}

/// BZ2_hbMakeCodeLengths: code lengths for [alphaSize] symbols with the
/// frequencies freq[freqOff..], at most [maxLen] bits, into len[lenOff..].
void bz2HbMakeCodeLengths(Uint8List len, int lenOff, Int32List freq,
    int freqOff, int alphaSize, int maxLen, HuffmanWork w) {
  // Nodes and heap entries run from 1. Entry 0 for both the heap and
  // nodes is a sentinel.
  final heap = w.heap;
  final weight = w.weight;
  final parent = w.parent;

  for (var i = 0; i < alphaSize; i++) {
    final f = freq[freqOff + i];
    weight[i + 1] = (f == 0 ? 1 : f) << 8;
  }

  for (;;) {
    var nNodes = alphaSize;
    var nHeap = 0;

    heap[0] = 0;
    weight[0] = 0;
    parent[0] = -2;

    for (var i = 1; i <= alphaSize; i++) {
      parent[i] = -1;
      nHeap++;
      heap[nHeap] = i;
      // UPHEAP(nHeap)
      var zz = nHeap;
      final tmp = heap[zz];
      while (weight[tmp] < weight[heap[zz >> 1]]) {
        heap[zz] = heap[zz >> 1];
        zz >>= 1;
      }
      heap[zz] = tmp;
    }

    if (nHeap >= bzMaxAlphaSize + 2) {
      throw StateError('bzip2 internal error 2001');
    }

    while (nHeap > 1) {
      final n1 = heap[1];
      heap[1] = heap[nHeap];
      nHeap--;
      _downHeap(heap, weight, nHeap);
      final n2 = heap[1];
      heap[1] = heap[nHeap];
      nHeap--;
      _downHeap(heap, weight, nHeap);
      nNodes++;
      parent[n1] = parent[n2] = nNodes;
      // ADDWEIGHTS
      final w1 = weight[n1], w2 = weight[n2];
      final d1 = w1 & 0xff, d2 = w2 & 0xff;
      weight[nNodes] =
          ((w1 & 0xffffff00) + (w2 & 0xffffff00)) | (1 + (d1 > d2 ? d1 : d2));
      parent[nNodes] = -1;
      nHeap++;
      heap[nHeap] = nNodes;
      // UPHEAP(nHeap)
      var zz = nHeap;
      final tmp = heap[zz];
      while (weight[tmp] < weight[heap[zz >> 1]]) {
        heap[zz] = heap[zz >> 1];
        zz >>= 1;
      }
      heap[zz] = tmp;
    }

    if (nNodes >= bzMaxAlphaSize * 2) {
      throw StateError('bzip2 internal error 2002');
    }

    var tooLong = false;
    for (var i = 1; i <= alphaSize; i++) {
      var j = 0;
      var k = i;
      while (parent[k] >= 0) {
        k = parent[k];
        j++;
      }
      len[lenOff + i - 1] = j;
      if (j > maxLen) tooLong = true;
    }

    if (!tooLong) break;

    // Scale the counts down and try again (bzip2 1.0.3 and later limit
    // the code length to 17 bits).
    for (var i = 1; i <= alphaSize; i++) {
      var j = weight[i] >> 8;
      j = 1 + (j ~/ 2);
      weight[i] = j << 8;
    }
  }
}

// DOWNHEAP(1)
void _downHeap(Int32List heap, Int32List weight, int nHeap) {
  var zz = 1;
  final tmp = heap[zz];
  for (;;) {
    var yy = zz << 1;
    if (yy > nHeap) break;
    if (yy < nHeap && weight[heap[yy + 1]] < weight[heap[yy]]) yy++;
    if (weight[tmp] < weight[heap[yy]]) break;
    heap[zz] = heap[yy];
    zz = yy;
  }
  heap[zz] = tmp;
}

/// BZ2_hbAssignCodes
void bz2HbAssignCodes(Int32List code, int codeOff, Uint8List length, int lenOff,
    int minLen, int maxLen, int alphaSize) {
  var vec = 0;
  for (var n = minLen; n <= maxLen; n++) {
    for (var i = 0; i < alphaSize; i++) {
      if (length[lenOff + i] == n) {
        code[codeOff + i] = vec;
        vec++;
      }
    }
    vec <<= 1;
  }
}

/// BZ2_hbCreateDecodeTables. [limit], [base] and [perm] are written from
/// offset [off] (one table of bzMaxAlphaSize entries per group).
void bz2HbCreateDecodeTables(
    Int32List limit,
    Int32List base,
    Int32List perm,
    int off,
    Uint8List length,
    int lenOff,
    int minLen,
    int maxLen,
    int alphaSize) {
  var pp = 0;
  for (var i = minLen; i <= maxLen; i++) {
    for (var j = 0; j < alphaSize; j++) {
      if (length[lenOff + j] == i) {
        perm[off + pp] = j;
        pp++;
      }
    }
  }

  for (var i = 0; i < bzMaxCodeLen; i++) {
    base[off + i] = 0;
  }
  for (var i = 0; i < alphaSize; i++) {
    base[off + length[lenOff + i] + 1]++;
  }

  for (var i = 1; i < bzMaxCodeLen; i++) {
    base[off + i] += base[off + i - 1];
  }

  for (var i = 0; i < bzMaxCodeLen; i++) {
    limit[off + i] = 0;
  }
  var vec = 0;

  for (var i = minLen; i <= maxLen; i++) {
    vec += (base[off + i + 1] - base[off + i]);
    limit[off + i] = vec - 1;
    vec <<= 1;
  }
  for (var i = minLen + 1; i <= maxLen; i++) {
    base[off + i] = ((limit[off + i - 1] + 1) << 1) - base[off + i];
  }
}
