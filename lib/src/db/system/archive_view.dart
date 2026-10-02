// A read-only view of a .zx archive for the system tables
// (docs/zxdb-design.md, 1.1): the generations, the Index of any generation
// (decoded once and cached), and per Index the lookups the tables plan
// with: path equality and prefix (a path-sorted order built on first use),
// SHA-256 equality (the sorted lookup table of docs/zx-format.md 6.5, by
// binary search), the TLSH list, and the packed size and method of an
// entry. Nothing is copied out of the archive; the view reads the Index
// records the reader already decoded.

import 'dart:typed_data';

import '../../format/zx/zx_codecs.dart' show zxChainName;
import '../../format/zx/zx_format.dart';
import '../../format/zx/zx_reader.dart';
import '../../io/streams.dart';
import '../storage_api.dart';
import 'sys_vtab.dart';

/// Kind names of zx_files.kind (docs/zx-format.md 6.2, attribute 0x53).
const List<String> zxKindNames = [
  'file', 'dir', 'symlink', 'hardlink', 'chardev', 'blockdev', 'fifo', //
  'socket',
];

String zxKindName(int k) =>
    k >= 0 && k < zxKindNames.length ? zxKindNames[k] : 'kind$k';

class ZxArchiveView {
  final ZxArchiveReader reader;
  final bool _owned;

  /// Decoded Indexes by generation number (the current one always kept).
  final Map<int, ZxIndexView> _cache = {};
  final List<int> _lru = [];

  /// How many older Indexes stay decoded.
  int cacheSize = 8;

  ZxArchiveView(this.reader) : _owned = false;
  ZxArchiveView._owned(this.reader) : _owned = true;

  /// Opens the archive at [path] (the last volume of a set is found as zx
  /// does). Null when the file is not a .zx archive.
  static ZxArchiveView? open(String path, {String? password}) {
    final s = openInputFile(path);
    try {
      final r = ZxArchiveReader.open(
          s, ZxOpenParams(path: path, password: () => password));
      if (r == null) {
        s.close();
        return null;
      }
      return ZxArchiveView._owned(r);
    } catch (_) {
      s.close();
      rethrow;
    }
  }

  /// Opens an archive held in memory.
  static ZxArchiveView? memory(Uint8List bytes, {String? password}) {
    final r = ZxArchiveReader.open(
        MemoryInStream(bytes), ZxOpenParams(password: () => password));
    return r == null ? null : ZxArchiveView._owned(r);
  }

  /// The data blocks are encrypted.
  bool get encrypted => reader.header.kdf != null;

  /// Every generation, oldest first. An archive without generation records
  /// has one, number 1, at its creation time.
  List<ZxGeneration> get generations {
    final g = reader.generations;
    if (g.isNotEmpty) return g;
    return [
      ZxGeneration(1, reader.header.creationTime ?? 0, '', null,
          reader.lastIndex.entries.length)
    ];
  }

  ZxGeneration get latest => generations.last;

  /// The generation [asOf] selects (null: the latest). Throws
  /// [ZxDbException] (notFound) when there is none (a number that does not
  /// exist, a date before the first generation).
  ZxGeneration resolve(SysAsOf? asOf) {
    final gens = generations;
    if (asOf == null) return gens.last;
    final n = asOf.generation;
    if (n != null) {
      for (final g in gens) {
        if (g.number == n) return g;
      }
      throw ZxDbException(
          'there is no generation $n (the archive has ${gens.last.number})',
          ZxDbError.notFound);
    }
    int end; // exclusive
    if (asOf.date != null) {
      final e = zxParseGenerationDate(asOf.date!);
      if (e == null) {
        throw ZxDbException('bad date "${asOf.date}"', ZxDbError.syntax);
      }
      end = e;
    } else {
      end = asOf.timeNs! + 1;
    }
    ZxGeneration? found;
    for (final g in gens) {
      if (g.time < end) found = g;
    }
    if (found == null) {
      throw ZxDbException(
          'the archive has no generation $asOf', ZxDbError.notFound);
    }
    return found;
  }

  /// The generations up to and including [asOf].
  List<ZxGeneration> generationsUpTo(SysAsOf? asOf) {
    final last = resolve(asOf).number;
    return [
      for (final g in generations)
        if (g.number <= last) g
    ];
  }

  /// The Index of generation [asOf].
  ZxIndexView at(SysAsOf? asOf) => indexOf(resolve(asOf));

  ZxIndexView get current => indexOf(latest);

  ZxIndexView indexOf(ZxGeneration g) {
    final hit = _cache[g.number];
    if (hit != null) {
      _lru
        ..remove(g.number)
        ..add(g.number);
      return hit;
    }
    final idx = reader.generations.isEmpty ||
            g.number == reader.lastIndex.generation?.number
        ? reader.lastIndex
        : reader.indexOf(g);
    final v = ZxIndexView._(this, idx, g);
    _cache[g.number] = v;
    _lru.add(g.number);
    final keep = latest.number;
    while (_lru.length > cacheSize + 1) {
      final old = _lru.firstWhere((n) => n != keep, orElse: () => -1);
      if (old < 0) break;
      _lru.remove(old);
      _cache.remove(old);
    }
    return v;
  }

  void close() {
    _cache.clear();
    if (_owned) reader.close();
  }
}

/// One generation's Index with lazily built lookups.
class ZxIndexView {
  final ZxArchiveView archive;
  final ZxIndex index;
  final ZxGeneration generation;
  ZxIndexView._(this.archive, this.index, this.generation);

  List<ZxEntry> get entries => index.entries;

  Map<String, int>? _byPath;
  Int32List? _sorted;
  List<(Uint8List, int)>? _sha;
  final Map<int, String> _methods = {};

  /// Entry number of [path], or null.
  int? entryOf(String path) {
    var m = _byPath;
    if (m == null) {
      m = <String, int>{};
      final e = entries;
      for (var i = 0; i < e.length; i++) {
        m[e[i].path] = i;
      }
      _byPath = m;
    }
    return m[path];
  }

  /// Entry numbers in path order (unsigned UTF-16 code unit order, as Dart
  /// compares strings; for ASCII paths the same as memcmp of UTF-8).
  Int32List get sortedByPath {
    var s = _sorted;
    if (s != null) return s;
    final e = entries;
    final l = List<int>.generate(e.length, (i) => i)
      ..sort((a, b) => e[a].path.compareTo(e[b].path));
    return _sorted = Int32List.fromList(l);
  }

  /// Entry numbers whose path is in [lo, hi) (null bounds are open), in
  /// path order; [loInclusive]/[hiInclusive] adjust the bounds.
  Iterable<int> pathRange(String? lo, String? hi,
      {bool loInclusive = true, bool hiInclusive = false}) sync* {
    final s = sortedByPath;
    final e = entries;
    int lower(String k, bool strict) {
      var a = 0, b = s.length;
      while (a < b) {
        final m = (a + b) >> 1;
        final c = e[s[m]].path.compareTo(k);
        if (c < 0 || (strict && c == 0)) {
          a = m + 1;
        } else {
          b = m;
        }
      }
      return a;
    }

    final from = lo == null ? 0 : lower(lo, !loInclusive);
    final to = hi == null ? s.length : lower(hi, hiInclusive);
    for (var i = from; i < to; i++) {
      yield s[i];
    }
  }

  /// Entry numbers whose path starts with [prefix], in path order.
  Iterable<int> pathPrefix(String prefix) =>
      pathRange(prefix, prefix.isEmpty ? null : _prefixEnd(prefix));

  static String? _prefixEnd(String p) {
    // the smallest string greater than every string starting with p
    final cu = p.codeUnits.toList();
    while (cu.isNotEmpty) {
      if (cu.last < 0xFFFF) {
        cu[cu.length - 1]++;
        return String.fromCharCodes(cu);
      }
      cu.removeLast();
    }
    return null;
  }

  /// The sorted (sha256, entry) table: the archive's (record 0x30) when it
  /// has one, else built from the entries once.
  List<(Uint8List, int)> get shaTable {
    var t = _sha ?? index.shaTable;
    if (t != null) return _sha = t;
    final e = entries;
    t = [
      for (var i = 0; i < e.length; i++)
        if (e[i].sha256 != null) (e[i].sha256!, i)
    ]..sort((a, b) {
        final c = sysCompareBytes(a.$1, b.$1);
        return c != 0 ? c : a.$2 - b.$2;
      });
    return _sha = t;
  }

  /// Entry numbers with content [sha256], by binary search.
  List<int> findBySha256(Uint8List sha256) {
    if (sha256.length != 32) return const [];
    final t = shaTable;
    var a = 0, b = t.length;
    while (a < b) {
      final m = (a + b) >> 1;
      if (sysCompareBytes(t[m].$1, sha256) < 0) {
        a = m + 1;
      } else {
        b = m;
      }
    }
    final out = <int>[];
    for (var i = a; i < t.length && sysCompareBytes(t[i].$1, sha256) == 0; i++) {
      out.add(t[i].$2);
    }
    return out;
  }

  /// (TLSH digest, entry) of the files that have one (record 0x32, or the
  /// entries' attributes).
  List<(String, int)> get tlshList {
    final l = index.tlshList;
    if (l != null) return l;
    final e = entries;
    return [
      for (var i = 0; i < e.length; i++)
        if (e[i].tlsh != null) (e[i].tlsh!, i)
    ];
  }

  /// The packed bytes of entry [i]: its share of each block it uses (the
  /// extent length over the block's unpacked size, times the block's
  /// packed size). Shared (dedup, solid) blocks are shared out by use, so
  /// the sum over entries can exceed a block when extents overlap.
  int packedOf(int i) {
    final x = entries[i].extents;
    final blocks = index.blocks;
    var p = 0.0;
    for (var k = 0; k + 2 < x.length; k += 3) {
      final b = x[k];
      if (b < 0 || b >= blocks.length) continue;
      final ref = blocks[b];
      if (ref.unpackedSize <= 0) continue;
      p += ref.packedSize * x[k + 2] / ref.unpackedSize;
    }
    return p.round();
  }

  /// The chain names of the blocks of entry [i] ('' for no data).
  String methodOf(int i) {
    final x = entries[i].extents;
    if (x.isEmpty) return '';
    if (x.length == 3) {
      final b = x[0];
      final chain = b >= 0 && b < index.blocks.length
          ? index.blocks[b].chainId
          : -1;
      return _methods[chain] ??= _chainName(chain);
    }
    final ids = <int>{};
    for (var k = 0; k < x.length; k += 3) {
      final b = x[k];
      if (b >= 0 && b < index.blocks.length) ids.add(index.blocks[b].chainId);
    }
    return [for (final id in ids) _methods[id] ??= _chainName(id)].join(' ');
  }

  String _chainName(int id) {
    if (id < 0) return '?';
    final c = id == 0 ? const ZxChain(0, []) : index.chains[id];
    return c == null ? '?' : zxChainName(c);
  }
}
