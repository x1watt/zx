// Length limited Huffman code lengths and canonical codes for the RAR5
// encoder. The lengths come from a standard Huffman tree; when a length
// exceeds the limit, the lengths are redistributed with the overflow
// correction of zlib's gen_bitlen (trees.c, zlib license), and assigned to
// the symbols by frequency. The canonical codes are the ones the RAR5
// decoder builds (shorter codes first, then by symbol value), as
// create_decode_tables in libarchive's rar5 reader expects them.

import 'dart:typed_data';

/// Computes code lengths (at most [maxLen]) for [freqs] into [lens].
/// Symbols with a zero frequency get length 0. When fewer than two symbols
/// are used, two symbols get length 1 so that the code is complete.
void rarHuffmanLengths(Uint32List freqs, Uint8List lens, int n, int maxLen) {
  lens.fillRange(0, n, 0);
  final used = <int>[];
  for (var i = 0; i < n; i++) {
    if (freqs[i] != 0) used.add(i);
  }
  if (used.length < 2) {
    final a = used.isEmpty ? 0 : used[0];
    final b = a == 0 ? 1 : 0;
    lens[a] = 1;
    lens[b] = 1;
    return;
  }
  // the tree: leaves 0..m-1, internal nodes m..2m-2
  final m = used.length;
  used.sort((x, y) {
    final d = freqs[x] - freqs[y];
    return d != 0 ? d : x - y;
  });
  final weight = Int64List(2 * m);
  final parent = Int32List(2 * m);
  for (var i = 0; i < m; i++) {
    weight[i] = freqs[used[i]];
  }
  // two queue construction over the sorted leaves
  var leaf = 0;
  var node = m;
  var next = m;
  int pick() {
    if (leaf < m && (node >= next || weight[leaf] <= weight[node])) {
      return leaf++;
    }
    return node++;
  }

  while (next < 2 * m - 1) {
    final a = pick();
    final b = pick();
    weight[next] = weight[a] + weight[b];
    parent[a] = next;
    parent[b] = next;
    next++;
  }
  final root = 2 * m - 2;
  final depth = Int32List(2 * m);
  depth[root] = 0;
  for (var i = root - 1; i >= 0; i--) {
    depth[i] = depth[parent[i]] + 1;
  }
  // bl_count with the overflow correction of gen_bitlen
  final blCount = Int32List(maxLen + 1);
  var overflow = 0;
  for (var i = 0; i < m; i++) {
    var d = depth[i];
    if (d > maxLen) {
      d = maxLen;
      overflow++;
    }
    blCount[d]++;
  }
  if (overflow > 0) {
    do {
      var bits = maxLen - 1;
      while (blCount[bits] == 0) {
        bits--;
      }
      blCount[bits]--;
      blCount[bits + 1] += 2;
      blCount[maxLen]--;
      overflow -= 2;
    } while (overflow > 0);
  }
  // the least frequent symbols get the longest codes
  var k = 0;
  for (var bits = maxLen; bits >= 1; bits--) {
    for (var c = blCount[bits]; c > 0; c--) {
      lens[used[k++]] = bits;
    }
  }
}

/// The canonical codes of [lens] into [codes].
void rarHuffmanCodes(Uint8List lens, Uint32List codes, int n) {
  final count = Int32List(17);
  for (var i = 0; i < n; i++) {
    count[lens[i]]++;
  }
  count[0] = 0;
  final nextCode = Int32List(17);
  var code = 0;
  for (var bits = 1; bits <= 16; bits++) {
    code = (code + count[bits - 1]) << 1;
    nextCode[bits] = code;
  }
  for (var i = 0; i < n; i++) {
    final l = lens[i];
    if (l != 0) codes[i] = nextCode[l]++;
  }
}
