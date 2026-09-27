// Chunk runs of the .zx dedup writer (docs/zx-format.md, section 6.4.1):
// the chunks a deduplicating writer stored, sorted by SHA-256 in blocks of
// type 6 that the writer searches by random access instead of loading
// every chunk into memory. Each generation writes the chunks it stored as
// a new run; runs of similar size are merged (a size tiered scheme, so a
// chunk is written again only a few times); the Index lists the runs
// (record 0x36).
//
// A run holds fixed size records in pages of 64, a fence table (the first
// 8 bytes of the first hash of each page and a check of the page), a
// Bloom filter, and a check of the fences and the filter. A writer keeps
// the fences and the filter in memory (about 1.5 bytes per chunk) and
// reads one page (3 KiB) for a lookup the filter lets through. In an
// encrypted archive the run is encrypted like a data block (AES-256-CTR,
// which can be decrypted from any 16 byte boundary) and the page checks
// are keyed (HMAC-SHA-256), so a page read alone is authenticated.

import 'dart:typed_data';

import '../../io/streams.dart';
import '../../util/xxhash.dart';
import 'zx_crypto.dart';
import 'zx_format.dart';
import 'zx_reader.dart';

/// Bytes of one record: SHA-256, u32 block, u32 length, u64 offset.
const int zxRunRecordSize = 48;

/// Records of a page, and bytes of a full page.
const int zxRunPageRecords = 64;
const int zxRunPageBytes = zxRunRecordSize * zxRunPageRecords;

/// The fixed parts of a run.
const int zxRunHeaderSize = 16;
const int zxRunFenceSize = 16;
const int zxRunTrailerSize = 16;

/// The largest run zx writes (48 MiB of records); a larger merge is cut
/// into several runs.
const int zxRunMaxRecords = 1 << 20;

/// The Bloom filter zx writes: 10 bits and 7 probes per chunk (about 1%
/// of false positives).
const int zxRunBloomBitsPerKey = 10;
const int zxRunBloomProbes = 7;

/// The byte layout of the plaintext of a run of [count] records.
class ZxRunLayout {
  final int count;
  final int bloomBytes;
  final int probes;
  const ZxRunLayout(this.count, this.bloomBytes, this.probes);

  /// The layout zx writes for [count] records.
  factory ZxRunLayout.forCount(int count) {
    var bits = count * zxRunBloomBitsPerKey;
    if (bits > 0xFFFFFFFF) bits = 0xFFFFFFFF;
    // a multiple of 128 bits, so every part starts at a 16 byte boundary
    final bytes = ((bits + 127) >> 7) << 4;
    return ZxRunLayout(count, bytes, zxRunBloomProbes);
  }

  int get pages => (count + zxRunPageRecords - 1) ~/ zxRunPageRecords;
  int get recordsOffset => zxRunHeaderSize;
  int get fencesOffset => zxRunHeaderSize + count * zxRunRecordSize;
  int get bloomOffset => fencesOffset + pages * zxRunFenceSize;
  int get trailerOffset => bloomOffset + bloomBytes;

  /// Bytes of the plaintext payload.
  int get size => trailerOffset + zxRunTrailerSize;

  /// Records in page [p].
  int recordsIn(int p) {
    final left = count - p * zxRunPageRecords;
    return left < zxRunPageRecords ? left : zxRunPageRecords;
  }

  Uint8List encodeHeader() {
    final b = Uint8List(zxRunHeaderSize);
    setUint64LE(b, 0, count);
    setUint32LE(b, 8, bloomBytes);
    b[12] = probes;
    b[13] = 6; // log2 of the records of a page
    return b;
  }

  /// The layout of a run header; null when it is not one zx reads.
  static ZxRunLayout? decodeHeader(Uint8List b) {
    final count = getUint64LE(b, 0);
    final bloom = getUint32LE(b, 8);
    final k = b[12];
    if (b[13] != 6 || b[14] != 0 || b[15] != 0) return null;
    if (count <= 0 || (bloom & 15) != 0 || k > 32) return null;
    if (bloom > 0 && k == 0) return null;
    return ZxRunLayout(count, bloom, k);
  }
}

/// The bytes of the whole block (header and payload) of a run of [count]
/// records, [encrypted] or not.
int zxRunBlockSize(int count, bool encrypted) {
  final l = ZxRunLayout.forCount(count);
  final packed = l.size + (encrypted ? zxNonceSize + zxMacSize : 0);
  final hdr = ZxBlockHeader.encode(
      ZxBlockType.chunkRun, 0, l.size, packed, ZxCheck.none, Uint8List(0));
  return hdr.length + packed;
}

/// The first 8 bytes of the hash at s[o] as a signed number that orders
/// as the bytes do.
int zxRunKey(Uint8List s, int o) {
  final hi = ((s[o] << 24) | (s[o + 1] << 16) | (s[o + 2] << 8) | s[o + 3]) ^
      0x80000000;
  final lo = (s[o + 4] << 24) | (s[o + 5] << 16) | (s[o + 6] << 8) | s[o + 7];
  return (hi << 32) | lo;
}

/// Compares the 32 byte hashes a[ao] and b[bo].
int zxCompareHash(Uint8List a, int ao, Uint8List b, int bo) {
  for (var i = 0; i < 32; i++) {
    final d = a[ao + i] - b[bo + i];
    if (d != 0) return d;
  }
  return 0;
}

/// The Bloom filter positions of the hash at s[o]: h1 + i * h2 (mod 2^32)
/// mod the number of bits, h1 and h2 the u32 (little endian) at bytes 8
/// and 12 of the hash, h2 made odd.
bool _bloomHas(Uint8List bloom, int k, Uint8List s, int o) {
  final m = bloom.length * 8;
  if (m == 0) return true;
  final h1 = getUint32LE(s, o + 8), h2 = getUint32LE(s, o + 12) | 1;
  for (var i = 0; i < k; i++) {
    final p = ((h1 + i * h2) & 0xFFFFFFFF) % m;
    if ((bloom[p >> 3] & (1 << (p & 7))) == 0) return false;
  }
  return true;
}

void _bloomAdd(Uint8List bloom, int k, Uint8List s, int o) {
  final m = bloom.length * 8;
  if (m == 0) return;
  final h1 = getUint32LE(s, o + 8), h2 = getUint32LE(s, o + 12) | 1;
  for (var i = 0; i < k; i++) {
    final p = ((h1 + i * h2) & 0xFFFFFFFF) % m;
    bloom[p >> 3] |= 1 << (p & 7);
  }
}

// the check of page [p] (its plaintext b[off, off + len)): xxHash64, or in
// an encrypted archive the first 8 bytes of HMAC-SHA-256(key_mac, 0x01,
// nonce, u64 p, page)
Uint8List _pageCheck(ZxHmac? mac, Uint8List? nonce, int p, Uint8List b,
    int off, int len) {
  final out = Uint8List(8);
  if (mac == null) {
    setUint64LE(out, 0, xxh64(b, off, off + len));
    return out;
  }
  final pre = Uint8List(1 + 16 + 8);
  pre[0] = 1;
  pre.setRange(1, 17, nonce!);
  setUint64LE(pre, 17, p);
  mac
    ..update(pre)
    ..update(b, off, off + len);
  out.setRange(0, 8, mac.finish());
  return out;
}

// the check of the header, the fences and the filter: xxHash64 and 8 zero
// bytes, or the first 16 bytes of HMAC-SHA-256(key_mac, 0x02, nonce,
// those bytes)
Uint8List _trailerCheck(
    ZxHmac? mac, Uint8List? nonce, Uint8List header, Uint8List tail) {
  final out = Uint8List(16);
  if (mac == null) {
    final h = Xxh64()
      ..update(header, 0, header.length)
      ..update(tail, 0, tail.length);
    setUint64LE(out, 0, h.digest);
    return out;
  }
  final pre = Uint8List(17);
  pre[0] = 2;
  pre.setRange(1, 17, nonce!);
  mac
    ..update(pre)
    ..update(header)
    ..update(tail);
  out.setRange(0, 16, mac.finish());
  return out;
}

bool _same(Uint8List a, int ao, Uint8List b, int bo, int n) {
  var d = 0;
  for (var i = 0; i < n; i++) {
    d |= a[ao + i] ^ b[bo + i];
  }
  return d == 0;
}

// ---------------------------------------------------------------------------
// writing

/// Writes one run, record by record in SHA-256 order, through [write]
/// (the block header first). The caller checks that the block
/// ([zxRunBlockSize]) fits where it goes.
class ZxRunWriter {
  final void Function(Uint8List b) _write;
  final ZxKeys? _keys;
  final ZxRunLayout layout;
  final Uint8List _page = Uint8List(zxRunPageBytes);
  final Uint8List _fences;
  final Uint8List _bloom;
  final Uint8List _header;
  Uint8List? _nonce;
  ZxHmac? _blockMac;
  ZxHmac? _pageMac;
  int _inPage = 0;
  int _page0 = 0; // number of the page being filled
  int _n = 0;
  int _pt = 0; // plaintext bytes written
  final Uint8List _last = Uint8List(32);

  /// Bytes of the whole block.
  late final int blockSize;

  ZxRunWriter(this._write, int count, this._keys)
      : layout = ZxRunLayout.forCount(count),
        _fences = Uint8List(
            ((count + zxRunPageRecords - 1) ~/ zxRunPageRecords) *
                zxRunFenceSize),
        _bloom = Uint8List(ZxRunLayout.forCount(count).bloomBytes),
        _header = ZxRunLayout.forCount(count).encodeHeader() {
    if (count <= 0) throw ArgumentError('empty run');
    final keys = _keys;
    final packed = layout.size + (keys != null ? zxNonceSize + zxMacSize : 0);
    final hdr = ZxBlockHeader.encode(ZxBlockType.chunkRun, 0, layout.size,
        packed, ZxCheck.none, Uint8List(0));
    blockSize = hdr.length + packed;
    _write(hdr);
    if (keys != null) {
      final nonce = _nonce = zxRandomBytes(zxNonceSize);
      _write(nonce);
      _blockMac = ZxHmac(keys.macKey)
        ..update(ZxBlockHeader.macPart(hdr))
        ..update(nonce);
      _pageMac = ZxHmac(keys.macKey);
    }
    _emit(Uint8List.fromList(_header));
  }

  // writes plaintext bytes (encrypted in place in an encrypted archive)
  void _emit(Uint8List b, [int len = -1]) {
    final n = len < 0 ? b.length : len;
    final part = n == b.length ? b : Uint8List.sublistView(b, 0, n);
    final keys = _keys;
    if (keys != null) {
      keys.ctrAt(_nonce!, _pt, part);
      _blockMac!.update(part);
    }
    _write(part);
    _pt += n;
  }

  /// Adds a record; hashes come in ascending order (equal ones allowed).
  void add(Uint8List sha, int o, int block, int offset, int length) {
    if (_n >= layout.count) throw StateError('run full');
    if (_n > 0 && zxCompareHash(_last, 0, sha, o) > 0) {
      throw StateError('run records out of order');
    }
    _last.setRange(0, 32, sha, o);
    final p = _inPage * zxRunRecordSize;
    _page.setRange(p, p + 32, sha, o);
    setUint32LE(_page, p + 32, block);
    setUint32LE(_page, p + 36, length);
    setUint64LE(_page, p + 40, offset);
    _bloomAdd(_bloom, layout.probes, sha, o);
    _n++;
    if (++_inPage == zxRunPageRecords) _flushPage();
  }

  void _flushPage() {
    if (_inPage == 0) return;
    final len = _inPage * zxRunRecordSize;
    final f = _page0 * zxRunFenceSize;
    _fences.setRange(f, f + 8, _page);
    _fences.setRange(
        f + 8, f + 16, _pageCheck(_pageMac, _nonce, _page0, _page, 0, len));
    _emit(_page, len);
    _page0++;
    _inPage = 0;
  }

  /// Writes the fences, the filter and the checks; every record must have
  /// been added.
  void finish() {
    if (_n != layout.count) throw StateError('run not complete');
    _flushPage();
    final tail = Uint8List(_fences.length + _bloom.length);
    tail.setRange(0, _fences.length, _fences);
    tail.setRange(_fences.length, tail.length, _bloom);
    final check = _trailerCheck(_pageMac, _nonce, _header, tail);
    _emit(tail);
    _emit(check);
    final m = _blockMac;
    if (m != null) _write(m.finish());
  }
}

// ---------------------------------------------------------------------------
// reading

/// A sorted source of chunk records (a run on disk, the chunks in memory).
abstract class ZxChunkCursor {
  /// Moves to the next record; false at the end.
  bool next();
  Uint8List get sha;
  int get shaOff;
  int get block;
  int get offset;
  int get length;
}

/// Chunks held in memory, sorted by SHA-256 for a run.
class ZxMemChunks {
  final Uint8List sha;
  final Int64List locs; // block, offset, length
  final Int32List order;
  ZxMemChunks._(this.sha, this.locs, this.order);

  int get length => order.length;

  /// Sorts [n] chunks: sha[32 i, 32 i + 32), locs[3 i, 3 i + 3).
  factory ZxMemChunks.sort(Uint8List sha, Int64List locs, int n) {
    final keys = Int64List(n);
    for (var i = 0; i < n; i++) {
      keys[i] = zxRunKey(sha, 32 * i);
    }
    final o = List<int>.generate(n, (i) => i)
      ..sort((a, b) {
        final ka = keys[a], kb = keys[b];
        if (ka != kb) return ka < kb ? -1 : 1;
        return zxCompareHash(sha, 32 * a, sha, 32 * b);
      });
    return ZxMemChunks._(sha, locs, Int32List.fromList(o));
  }

  ZxChunkCursor cursor() => _MemCursor(this);
}

class _MemCursor implements ZxChunkCursor {
  final ZxMemChunks m;
  int _i = -1;
  int _id = 0;
  _MemCursor(this.m);
  @override
  bool next() {
    if (++_i >= m.order.length) return false;
    _id = m.order[_i];
    return true;
  }

  @override
  Uint8List get sha => m.sha;
  @override
  int get shaOff => 32 * _id;
  @override
  int get block => m.locs[3 * _id];
  @override
  int get offset => m.locs[3 * _id + 1];
  @override
  int get length => m.locs[3 * _id + 2];
}

/// A chunk found in a run.
typedef ZxRunHit = ({int block, int offset, int length});

/// A run opened for lookups: its fences and Bloom filter in memory, its
/// pages read on demand.
class ZxChunkRun {
  final ZxChunkRunRef ref;
  final ZxRunLayout layout;
  final ZxVolumes _vols;
  final ZxKeys? _keys;
  final Uint8List? _nonce;
  final ZxHmac? _mac;

  /// The absolute position of the plaintext of the payload (after the
  /// nonce in an encrypted archive).
  final int _base;
  final Int64List _fenceKeys;
  final Uint8List _fenceChecks;
  final Uint8List _bloom;

  /// Pages read (lookups and scans) and pages found damaged.
  int pagesRead = 0;
  int damagedPages = 0;

  // the last page read
  int _cachedPage = -1;
  Uint8List? _cache;

  ZxChunkRun._(this.ref, this.layout, this._vols, this._keys, this._nonce,
      this._mac, this._base, this._fenceKeys, this._fenceChecks, this._bloom);

  /// The bytes the run keeps in memory.
  int get memoryBytes =>
      _fenceKeys.lengthInBytes + _fenceChecks.lengthInBytes + _bloom.length;

  int get count => layout.count;

  /// Opens run [ref] of [vols]; [keys] in an encrypted archive. Throws
  /// [SevenZipException] when the run is damaged (its header, fences or
  /// filter) or its volume is missing.
  static ZxChunkRun open(ZxVolumes vols, ZxChunkRunRef ref, ZxKeys? keys) {
    final headLen = ref.size < 300 ? ref.size : 300;
    final head = vols.readAt(ref.volume, ref.offset, headLen);
    final h = ZxBlockHeader.tryParse(head, 0, head.length);
    if (h == null ||
        h.type != ZxBlockType.chunkRun ||
        h.chainId != 0 ||
        h.headerSize + h.packedSize != ref.size) {
      zxDamaged('damaged chunk run');
    }
    final enc = keys != null;
    if (h.packedSize != h.unpackedSize + (enc ? zxNonceSize + zxMacSize : 0)) {
      zxDamaged('damaged chunk run');
    }
    var pos = ref.offset + h.headerSize;
    Uint8List? nonce;
    if (enc) {
      nonce = vols.readAt(ref.volume, pos, zxNonceSize);
      pos += zxNonceSize;
    }
    final base = pos;
    final hb = vols.readAt(ref.volume, base, zxRunHeaderSize);
    if (enc) keys.ctrAt(nonce!, 0, hb);
    final l = ZxRunLayout.decodeHeader(hb);
    if (l == null || l.count != ref.count || l.size != h.unpackedSize) {
      zxDamaged('damaged chunk run');
    }
    final tailLen = l.trailerOffset - l.fencesOffset;
    final tail = vols.readAt(
        ref.volume, base + l.fencesOffset, tailLen + zxRunTrailerSize);
    if (enc) keys.ctrAt(nonce!, l.fencesOffset, tail);
    final mac = enc ? ZxHmac(keys.macKey) : null;
    final want = _trailerCheck(
        mac, nonce, hb, Uint8List.sublistView(tail, 0, tailLen));
    if (!_same(want, 0, tail, tailLen, zxRunTrailerSize)) {
      zxDamaged('damaged chunk run (check mismatch)');
    }
    final pages = l.pages;
    final fk = Int64List(pages);
    final fc = Uint8List(8 * pages);
    for (var p = 0; p < pages; p++) {
      fk[p] = zxRunKey(tail, p * zxRunFenceSize);
      fc.setRange(8 * p, 8 * p + 8, tail, p * zxRunFenceSize + 8);
    }
    final bloom = Uint8List.fromList(Uint8List.sublistView(
        tail, pages * zxRunFenceSize, pages * zxRunFenceSize + l.bloomBytes));
    return ZxChunkRun._(ref, l, vols, keys, nonce, mac, base, fk, fc, bloom);
  }

  /// False when the filter says the hash at s[o] is not in the run.
  bool mightContain(Uint8List s, int o) =>
      _bloomHas(_bloom, layout.probes, s, o);

  /// Page [p], checked; null when it is damaged.
  Uint8List? page(int p) {
    if (p == _cachedPage) return _cache;
    final len = layout.recordsIn(p) * zxRunRecordSize;
    final off = layout.recordsOffset + p * zxRunPageBytes;
    Uint8List b;
    try {
      b = _vols.readAt(ref.volume, _base + off, len);
    } on SevenZipException {
      damagedPages++;
      return null;
    }
    pagesRead++;
    final keys = _keys;
    if (keys != null) keys.ctrAt(_nonce!, off, b);
    final c = _pageCheck(_mac, _nonce, p, b, 0, len);
    if (!_same(c, 0, _fenceChecks, 8 * p, 8) ||
        zxRunKey(b, 0) != _fenceKeys[p]) {
      damagedPages++;
      return null;
    }
    _cachedPage = p;
    _cache = b;
    return b;
  }

  /// The chunk with the hash at s[o], or null (a damaged page counts as
  /// not found).
  ZxRunHit? find(Uint8List s, int o) {
    if (!mightContain(s, o)) return null;
    final key = zxRunKey(s, o);
    final f = _fenceKeys;
    // the first page whose first key is greater than key
    var lo = 0, hi = f.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (f[mid] <= key) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    final end = lo - 1;
    if (end < 0) return null;
    // pages that start with the same 8 bytes may hold the hash at their
    // end, so the page before them is searched too
    var start = end;
    while (start > 0 && f[start] == key) {
      start--;
    }
    for (var p = start; p <= end; p++) {
      final b = page(p);
      if (b == null) continue;
      var a = 0, z = b.length ~/ zxRunRecordSize;
      while (a < z) {
        final mid = (a + z) >> 1;
        final c = zxCompareHash(b, mid * zxRunRecordSize, s, o);
        if (c == 0) {
          final r = mid * zxRunRecordSize;
          return (
            block: getUint32LE(b, r + 32),
            offset: getUint64LE(b, r + 40),
            length: getUint32LE(b, r + 36)
          );
        }
        if (c < 0) {
          a = mid + 1;
        } else {
          z = mid;
        }
      }
    }
    return null;
  }

  /// Every record in order (damaged pages are skipped).
  ZxChunkCursor cursor() => _RunCursor(this);
}

class _RunCursor implements ZxChunkCursor {
  final ZxChunkRun run;
  int _p = -1;
  Uint8List _b = Uint8List(0);
  int _i = 0;
  int _n = 0;
  _RunCursor(this.run);

  @override
  bool next() {
    while (++_i >= _n) {
      if (++_p >= run.layout.pages) return false;
      final b = run.page(_p);
      _b = b ?? Uint8List(0);
      _n = _b.length ~/ zxRunRecordSize;
      _i = -1;
    }
    return true;
  }

  @override
  Uint8List get sha => _b;
  @override
  int get shaOff => _i * zxRunRecordSize;
  @override
  int get block => getUint32LE(_b, _i * zxRunRecordSize + 32);
  @override
  int get offset => getUint64LE(_b, _i * zxRunRecordSize + 40);
  @override
  int get length => getUint32LE(_b, _i * zxRunRecordSize + 36);
}

// ---------------------------------------------------------------------------
// merging

/// How many of the last runs ([counts], oldest first) a new run of [n]
/// records is merged with: the trailing runs not at [cap] that are at most
/// 4 times the records gathered so far (size tiers with a ratio of 4, so
/// the number of runs grows with the logarithm of the chunks).
int zxRunsToMerge(List<int> counts, int n, int cap) {
  if (n <= 0) return 0;
  var acc = n, k = 0;
  for (var i = counts.length - 1; i >= 0; i--) {
    final c = counts[i];
    if (c >= cap || c > 4 * acc) break;
    acc += c;
    k++;
  }
  return k;
}

/// What a merge keeps of a record: its (block, offset) in the output, or
/// null to drop it.
typedef ZxChunkMap = (int, int)? Function(int block, int offset, int length);

/// Merges the sorted [sources] (made again for each pass; the first
/// source wins among equal hashes) into runs of at most [maxRecords],
/// written by [writeRun] (which gets the record count and returns a
/// [ZxRunWriter]); [map] keeps or moves a record. Returns the counts of
/// the runs written. Two passes: the records are counted, then written.
List<int> zxMergeRuns(List<ZxChunkCursor> Function() sources,
    ZxRunWriter Function(int count) writeRun,
    {ZxChunkMap? map, int maxRecords = zxRunMaxRecords}) {
  var total = 0;
  _merge(sources(), map, (s, o, b, off, len) => total++);
  if (total == 0) return const [];
  final pieces = (total + maxRecords - 1) ~/ maxRecords;
  final counts = [
    for (var i = 0; i < pieces; i++)
      total ~/ pieces + (i < total % pieces ? 1 : 0)
  ];
  var k = 0, inRun = 0;
  ZxRunWriter? w;
  _merge(sources(), map, (s, o, b, off, len) {
    w ??= writeRun(counts[k]);
    w!.add(s, o, b, off, len);
    if (++inRun == counts[k]) {
      w!.finish();
      w = null;
      inRun = 0;
      k++;
    }
  });
  return counts;
}

void _merge(List<ZxChunkCursor> cs, ZxChunkMap? map,
    void Function(Uint8List s, int o, int b, int off, int len) out) {
  final live = <ZxChunkCursor>[
    for (final c in cs)
      if (c.next()) c
  ];
  final pick = Uint8List(32);
  while (live.isNotEmpty) {
    // the smallest hash
    var m = live[0];
    for (var i = 1; i < live.length; i++) {
      final c = live[i];
      if (zxCompareHash(c.sha, c.shaOff, m.sha, m.shaOff) < 0) m = c;
    }
    pick.setRange(0, 32, m.sha, m.shaOff);
    // the first source with it (and a record the map keeps) wins
    var done = false;
    for (var i = 0; i < live.length;) {
      final c = live[i];
      if (zxCompareHash(c.sha, c.shaOff, pick, 0) != 0) {
        i++;
        continue;
      }
      if (!done) {
        final b = c.block, off = c.offset, len = c.length;
        final to = map == null ? (b, off) : map(b, off, len);
        if (to != null) {
          out(pick, 0, to.$1, to.$2, len);
          done = true;
        }
      }
      if (c.next()) {
        i++;
      } else {
        live.removeAt(i);
      }
    }
  }
}

/// Every chunk of [idx] (its runs and a chunk table of zx 0.5.0), sorted
/// by block then offset, as a [ZxChunkTable] (fingerprint 0). Damaged runs
/// are skipped. For tests and tools: it holds every chunk in memory.
ZxChunkTable zxAllChunks(ZxVolumes vols, ZxIndex idx, ZxKeys? keys) {
  final sha = <int>[];
  final locs = <int>[];
  final runs = idx.chunkRunsValid;
  if (runs != null) {
    for (final ref in runs.runs) {
      ZxChunkCursor c;
      try {
        c = ZxChunkRun.open(vols, ref, keys).cursor();
      } on SevenZipException {
        continue;
      }
      while (c.next()) {
        sha.addAll(Uint8List.sublistView(c.sha, c.shaOff, c.shaOff + 32));
        locs
          ..add(c.block)
          ..add(c.offset)
          ..add(c.length);
      }
    }
  }
  final t = idx.chunksValid;
  if (t != null) {
    sha.addAll(t.sha);
    locs.addAll(t.locs);
  }
  final n = locs.length ~/ 3;
  final order = List<int>.generate(n, (i) => i)
    ..sort((a, b) {
      final d = locs[3 * a] - locs[3 * b];
      return d != 0 ? d : locs[3 * a + 1] - locs[3 * b + 1];
    });
  final l2 = Int64List(3 * n);
  final s2 = Uint8List(32 * n);
  for (var i = 0; i < n; i++) {
    final o = order[i];
    l2.setRange(3 * i, 3 * i + 3, locs, 3 * o);
    s2.setRange(32 * i, 32 * i + 32, sha, 32 * o);
  }
  return ZxChunkTable(0, l2, s2);
}
