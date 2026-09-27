// Deduplication for the .zx writer (docs/zx-format.md, section 6.4): the
// content-defined chunker, the index of the chunks stored so far, and the
// features (solid, dedup) that the extents of a set of entries need.
//
// The chunker is the fragmenter of zpaq 7.15 by Matt Mahoney (public
// domain), as ported in lib/src/zpaq/archive/add.dart (_scanRange): a
// rolling hash over the bytes since the last cut, multiplied by one of two
// constants depending on whether an order 1 context predicted the byte,
// and a cut where the hash falls below a limit. Old bytes leave the hash
// as the even multiplier shifts them out of its high bits, so identical
// runs of data are cut at the same places after a few dozen bytes,
// whatever came before them.

import 'dart:typed_data';

import 'zx_format.dart';

/// The default average chunk size (64 KiB, zpaq's fragment 6).
const int zxDefaultChunkLog2 = 16;

/// The smallest and largest average chunk sizes (-mchunk).
const int zxMinChunkLog2 = 12;
const int zxMaxChunkLog2 = 22;

/// Cuts a stream of bytes into chunks with zpaq's fragmenter. The average
/// chunk is 2^[log2] bytes; a chunk is at least 1/16 of that and at most
/// 127/16 of it (zpaq: 64 << f and 8128 << f bytes for 2^(10 + f)), and at
/// most [maxLimit].
class ZxChunker {
  final int minSize;
  final int maxSize;
  final int _limit;
  final Uint8List _o1 = Uint8List(256);
  int _h = 0;
  int _c1 = 0;
  int _sz = 0;

  ZxChunker._(this.minSize, this.maxSize, this._limit);

  factory ZxChunker(int log2, {int? maxLimit}) {
    final l = log2.clamp(zxMinChunkLog2, zxMaxChunkLog2);
    var max = ((1 << l) * 127) >> 4;
    if (maxLimit != null && max > maxLimit) max = maxLimit;
    var min = (1 << l) >> 4;
    if (min > max) min = max;
    return ZxChunker._(min, max, 1 << (32 - l));
  }

  /// Starts a new file (zpaq cuts every file on its own).
  void reset() {
    _h = 0;
    _c1 = 0;
    _sz = 0;
    _o1.fillRange(0, 256, 0);
  }

  /// Scans b[from, end) and returns the index just after the next cut, or
  /// -1 when there is none in that range (the state is kept for the next
  /// bytes). After a cut the state restarts, as in zpaq.
  @pragma('vm:unsafe:no-bounds-checks')
  int scan(Uint8List b, int from, int end) {
    final o1 = _o1;
    final limit = _limit, minSize = this.minSize, maxSize = this.maxSize;
    var h = _h, c1 = _c1, sz = _sz;
    for (var i = from; i < end; i++) {
      final c = b[i];
      // branch free: whether c was predicted is random on binary data
      final hit = ((c ^ o1[c1]) - 1) >>> 63; // 1 if c == o1[c1]
      h = ((h + c + 1) * (271828182 + hit * (314159265 - 271828182))) &
          0xFFFFFFFF;
      o1[c1] = c;
      c1 = c;
      if (++sz >= maxSize || (h < limit && sz >= minSize)) {
        _h = 0;
        _c1 = 0;
        _sz = 0;
        o1.fillRange(0, 256, 0);
        return i + 1;
      }
    }
    _h = h;
    _c1 = c1;
    _sz = sz;
    return -1;
  }
}

/// The chunks known to a writer: SHA-256, length and location. A location
/// is a block and an offset, or (block -1) a position in the stream of the
/// new data of the generation being written, placed when its block is.
/// Open addressing on the first bytes of the hash, so a chunk costs about
/// 70 bytes.
class ZxChunkIndex {
  Uint8List _sha = Uint8List(32 * 256);
  Int64List _loc = Int64List(3 * 256);
  Int32List _slots = Int32List(512);
  int _count = 0;

  int get length => _count;

  int block(int id) => _loc[3 * id];
  int offset(int id) => _loc[3 * id + 1];
  int size(int id) => _loc[3 * id + 2];

  /// The SHA-256 of chunk [id] (a view).
  Uint8List shaOf(int id) => Uint8List.sublistView(_sha, 32 * id, 32 * id + 32);

  /// The first 4 bytes of a hash at s[o] as a number (the table key).
  static int keyOf(Uint8List s, [int o = 0]) => _key(s, o);

  static int _key(Uint8List s, int o) =>
      s[o] | (s[o + 1] << 8) | (s[o + 2] << 16) | (s[o + 3] << 24);

  bool _same(int id, Uint8List s, int o) {
    final a = _sha;
    final p = 32 * id;
    for (var i = 0; i < 32; i++) {
      if (a[p + i] != s[o + i]) return false;
    }
    return true;
  }

  /// The chunk with SHA-256 s[o, o + 32) and [len] bytes, or -1.
  int find(Uint8List s, int len, [int o = 0]) {
    final mask = _slots.length - 1;
    var i = _key(s, o) & mask;
    for (;;) {
      final v = _slots[i];
      if (v == 0) return -1;
      final id = v - 1;
      if (_loc[3 * id + 2] == len && _same(id, s, o)) return id;
      i = (i + 1) & mask;
    }
  }

  /// Adds a chunk (not already in the index); returns its id.
  int add(Uint8List s, int block, int offset, int len, [int o = 0]) {
    if (_count * 32 + 32 > _sha.length) {
      final ns = Uint8List(_sha.length * 2)..setRange(0, _sha.length, _sha);
      final nl = Int64List(_loc.length * 2)..setRange(0, _loc.length, _loc);
      _sha = ns;
      _loc = nl;
    }
    if (2 * (_count + 1) > _slots.length) _grow();
    final id = _count++;
    _sha.setRange(32 * id, 32 * id + 32, s, o);
    _loc[3 * id] = block;
    _loc[3 * id + 1] = offset;
    _loc[3 * id + 2] = len;
    _place(id);
    return id;
  }

  /// Moves chunk [id] to a block (when its block is written).
  void setLocation(int id, int block, int offset) {
    _loc[3 * id] = block;
    _loc[3 * id + 1] = offset;
  }

  void _place(int id) {
    final mask = _slots.length - 1;
    var i = _key(_sha, 32 * id) & mask;
    while (_slots[i] != 0) {
      i = (i + 1) & mask;
    }
    _slots[i] = id + 1;
  }

  void _grow() {
    _slots = Int32List(_slots.length * 2);
    for (var id = 0; id < _count; id++) {
      _place(id);
    }
  }

  /// Removes the chunks added last, from id [n] on (a file whose new
  /// chunks are dropped). Linear probing deletion: the entries after a
  /// freed slot move back when their home slot allows it.
  void truncate(int n) {
    final mask = _slots.length - 1;
    for (var id = _count - 1; id >= n; id--) {
      var i = _key(_sha, 32 * id) & mask;
      while (_slots[i] != id + 1) {
        i = (i + 1) & mask;
      }
      var j = i;
      for (;;) {
        j = (j + 1) & mask;
        final v = _slots[j];
        if (v == 0) break;
        final home = _key(_sha, 32 * (v - 1)) & mask;
        // v stays when its home lies cyclically in (i, j]
        final stays =
            i <= j ? (i < home && home <= j) : (i < home || home <= j);
        if (stays) continue;
        _slots[i] = v;
        i = j;
      }
      _slots[i] = 0;
    }
    if (n < _count) _count = n;
  }

  /// Adds the chunks of [t] (the table of an earlier generation).
  void addTable(ZxChunkTable t) {
    for (var i = 0; i < t.length; i++) {
      if (find(t.sha, t.locs[3 * i + 2], 32 * i) >= 0) continue;
      add(t.sha, t.locs[3 * i], t.locs[3 * i + 1], t.locs[3 * i + 2], 32 * i);
    }
  }
}

/// The required features that the extents of [entries] need: `solid` when
/// a block holds data of two entries, `dedup` when two extents (of one
/// entry or of two) share bytes.
int zxSharingFeatures(List<ZxEntry> entries) {
  // per block: flat (offset, end, entry)
  final by = <int, List<int>>{};
  for (var i = 0; i < entries.length; i++) {
    final x = entries[i].extents;
    for (var k = 0; k < x.length; k += 3) {
      if (x[k + 2] == 0) continue;
      (by[x[k]] ??= <int>[])
        ..add(x[k + 1])
        ..add(x[k + 1] + x[k + 2])
        ..add(i);
    }
  }
  var f = 0;
  for (final l in by.values) {
    final n = l.length ~/ 3;
    if (n < 2) continue;
    final order = List<int>.generate(n, (i) => i)
      ..sort((a, b) => l[3 * a] - l[3 * b]);
    var end = -1;
    final first = l[3 * order[0] + 2];
    for (final j in order) {
      if (l[3 * j + 2] != first) f |= ZxFeature.solid;
      if (l[3 * j] < end) f |= ZxFeature.dedup;
      if (l[3 * j + 1] > end) end = l[3 * j + 1];
    }
    if (f == ZxFeature.solid | ZxFeature.dedup) break;
  }
  return f;
}

/// Appends the triple (block, offset, length) to [out], merged with the
/// last one when it continues it.
void zxAddExtent(List<int> out, int block, int offset, int length) {
  if (length == 0) return;
  final n = out.length;
  if (n >= 3 &&
      out[n - 3] == block &&
      out[n - 2] + out[n - 1] == offset) {
    out[n - 1] += length;
    return;
  }
  out
    ..add(block)
    ..add(offset)
    ..add(length);
}
