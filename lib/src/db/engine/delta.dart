// The delta layer of zxdb trees (LSM style, docs/zxdb-design.md 11.2):
// random writes into a large tree do not rewrite its pages at every
// commit. A write transaction keeps the writes of such a tree in a sorted
// table in memory (the memtable); its commit writes them as a new sorted
// run (a small B+tree whose pages are written once, full), and reads merge
// the memtable, the runs (newest first) and the base tree. Runs of similar
// size are merged together, and a fold merges every run into the base in
// one sorted pass (one rewrite of each touched base page per fold).
//
// A run holds the value of a key as u8 0 then the value, or u8 1 alone
// for a deleted key (docs/zx-format.md 16.5).

import 'dart:collection';
import 'dart:typed_data';

import '../storage_api.dart';
import 'btree.dart';
import 'page.dart';

/// A sorted run of a tree's delta layer: its root page, its entries
/// (deletions included) and the bytes of its keys and values.
class DeltaRun {
  final int root;
  final int count;
  final int bytes;
  const DeltaRun(this.root, this.count, this.bytes);
}

/// The deleted mark of a memtable (compared by identity).
final Uint8List deltaTomb = Uint8List(0);

/// The memtable of one tree in a write transaction: key to value, or
/// [deltaTomb] for a deleted key.
SplayTreeMap<Uint8List, Uint8List> newMemtable() =>
    SplayTreeMap<Uint8List, Uint8List>(zxCompareKeys);

/// The stored form of a run value.
Uint8List deltaEncode(Uint8List v) {
  if (identical(v, deltaTomb)) return Uint8List(1)..[0] = 1;
  final out = Uint8List(v.length + 1);
  out.setRange(1, out.length, v);
  return out;
}

/// The value of a run entry: null for a deletion.
Uint8List? deltaDecode(Uint8List stored) {
  if (stored.isEmpty) {
    throw const ZxDbException('damaged delta run', ZxDbError.corrupt);
  }
  if (stored[0] == 1) return null;
  return Uint8List.sublistView(stored, 1);
}

/// Looks [key] up in [runs] (newest first): (found, value or null for a
/// deletion). Not found: the base decides.
(bool, Uint8List?) deltaGet(PageReader p, List<DeltaRun> runs, Uint8List key,
    [RunFilters? filters]) {
  for (final r in runs) {
    if (filters != null) {
      final f = filters.filterOf(r);
      if (f != null && !f.mayContain(key)) continue;
    }
    final v = treeGet(p, r.root, key);
    if (v != null) return (true, deltaDecode(resolveValue(p, v)));
  }
  return (false, null);
}

/// Gives the Bloom filter of a run (null: none, the run is read).
abstract class RunFilters {
  RunFilter? filterOf(DeltaRun r);
}

/// One source of a [MergeCursor]: a cursor whose entries may be deletions.
abstract class DeltaSource {
  bool moveNext();
  Uint8List get key;

  /// The value, null for a deletion.
  Uint8List? get value;
}

/// A base tree cursor as a source.
class TreeSource implements DeltaSource {
  final TreeCursor c;
  TreeSource(this.c);
  @override
  bool moveNext() => c.moveNext();
  @override
  Uint8List get key => c.key;
  @override
  Uint8List? get value => c.value;
}

/// A run cursor as a source.
class RunSource implements DeltaSource {
  final TreeCursor c;
  RunSource(this.c);
  @override
  bool moveNext() => c.moveNext();
  @override
  Uint8List get key => c.key;
  @override
  Uint8List? get value => deltaDecode(c.value);
}

/// A memtable as a source, in [from, to) (reversed when [reverse]).
class MemSource implements DeltaSource {
  final SplayTreeMap<Uint8List, Uint8List> m;
  final Uint8List? from;
  final Uint8List? to;
  final bool reverse;
  Uint8List? _k;
  bool _started = false;
  MemSource(this.m, this.from, this.to, this.reverse);

  @override
  bool moveNext() {
    Uint8List? k;
    if (!reverse) {
      if (!_started) {
        final f = from;
        k = f == null
            ? (m.isEmpty ? null : m.firstKey())
            : (m.containsKey(f) ? f : m.firstKeyAfter(f));
      } else {
        k = m.firstKeyAfter(_k!);
      }
      final t = to;
      if (k != null && t != null && zxCompareKeys(k, t) >= 0) k = null;
    } else {
      if (!_started) {
        final t = to;
        k = t == null ? (m.isEmpty ? null : m.lastKey()) : m.lastKeyBefore(t);
      } else {
        k = m.lastKeyBefore(_k!);
      }
      final f = from;
      if (k != null && f != null && zxCompareKeys(k, f) < 0) k = null;
    }
    _started = true;
    _k = k;
    return k != null;
  }

  @override
  Uint8List get key => _k!;

  @override
  Uint8List? get value {
    final v = m[_k!]!;
    return identical(v, deltaTomb) ? null : v;
  }
}

/// The smallest key after [k] in byte order.
Uint8List keySuccessor(Uint8List k) {
  final out = Uint8List(k.length + 1);
  out.setRange(0, k.length, k);
  return out;
}

/// Merges sources (the first wins on equal keys; deletions hide the key)
/// into one cursor. With [mods] it follows writes as TreeCursor does:
/// when the counter changed, the sources are made again after the last
/// key returned.
class MergeCursor implements ZxCursor {
  /// The sources in [from, to), newest first.
  final List<DeltaSource> Function(Uint8List? from, Uint8List? to) open;
  final int Function()? mods;
  final void Function() check;
  final Uint8List? from;
  final Uint8List? to;
  final bool reverse;

  /// Deletions are returned too, with the value [deltaTomb] (merging
  /// runs).
  final bool keepDeletions;

  List<DeltaSource> _src = const [];
  List<bool> _has = const [];
  int _seen = -1;
  bool _started = false;
  bool _done = false;
  Uint8List? _key;
  Uint8List? _value;

  MergeCursor(this.open, this.check,
      {this.mods,
      this.from,
      this.to,
      this.reverse = false,
      this.keepDeletions = false});

  void _reopen() {
    Uint8List? f = from, t = to;
    final last = _key;
    if (last != null) {
      if (reverse) {
        t = last;
      } else {
        f = keySuccessor(last);
      }
    }
    _src = open(f, t);
    _has = List<bool>.filled(_src.length, false);
    for (var i = 0; i < _src.length; i++) {
      _has[i] = _src[i].moveNext();
    }
  }

  @override
  bool moveNext() {
    check();
    if (_done) return false;
    final m = mods?.call() ?? 0;
    if (!_started || m != _seen) {
      _started = true;
      _reopen();
    } else {
      // step past the entry returned last (in every source holding it)
      final last = _key!;
      for (var i = 0; i < _src.length; i++) {
        if (_has[i] && zxCompareKeys(_src[i].key, last) == 0) {
          _has[i] = _src[i].moveNext();
        }
      }
    }
    _seen = m;
    for (;;) {
      var best = -1;
      Uint8List? bk;
      for (var i = 0; i < _src.length; i++) {
        if (!_has[i]) continue;
        final k = _src[i].key;
        if (best < 0) {
          best = i;
          bk = k;
          continue;
        }
        final c = zxCompareKeys(k, bk!);
        if (reverse ? c > 0 : c < 0) {
          best = i;
          bk = k;
        }
      }
      if (best < 0) {
        _done = true;
        _key = null;
        _value = null;
        return false;
      }
      final v = _src[best].value;
      if (v != null || keepDeletions) {
        _key = bk;
        _value = v ?? deltaTomb;
        return true;
      }
      // a deletion: skip the key in every source
      for (var i = 0; i < _src.length; i++) {
        if (_has[i] && zxCompareKeys(_src[i].key, bk!) == 0) {
          _has[i] = _src[i].moveNext();
        }
      }
    }
  }

  @override
  Uint8List get key => _key ?? (throw StateError('no current entry'));

  @override
  Uint8List get value => _value ?? (throw StateError('no current entry'));

  @override
  void close() {
    _done = true;
    _src = const [];
  }
}

/// The sources of a tree with [runs] over the base at [root], in
/// [from, to), for a [MergeCursor] (newest first; [mem] first when set).
List<DeltaSource> deltaSources(
    PageReader Function() pages,
    void Function() check,
    int root,
    List<DeltaRun> runs,
    SplayTreeMap<Uint8List, Uint8List>? mem,
    Uint8List? from,
    Uint8List? to,
    bool reverse) {
  return [
    if (mem != null && mem.isNotEmpty) MemSource(mem, from, to, reverse),
    for (final r in runs)
      RunSource(TreeCursor(pages, () => r.root, check,
          from: from, to: to, reverse: reverse)),
    TreeSource(TreeCursor(pages, () => root, check,
        from: from, to: to, reverse: reverse)),
  ];
}

/// A Bloom filter of the keys of a committed run (about 10 bits a key, 6
/// probes: about 1% false positives), so that a lookup skips the runs
/// that do not hold its key. Made on first use by reading the run's keys,
/// kept by the run's place in the file (runs do not change).
class RunFilter {
  final Uint32List _bits;
  final int _mask;

  RunFilter._(int bits)
      : _bits = Uint32List(bits >> 5),
        _mask = bits - 1;

  factory RunFilter(int count) {
    var bits = 1024;
    while (bits < count * 10 && bits < (1 << 30)) {
      bits <<= 1;
    }
    return RunFilter._(bits);
  }

  /// The filter of the run at [root] ([count] entries).
  static RunFilter build(PageReader p, int root, int count) {
    final f = RunFilter(count);
    final c = TreeCursor(() => p, () => root, _noCheck);
    while (c.moveNext()) {
      f.add(c.key);
    }
    return f;
  }

  static void _noCheck() {}

  // FNV-1a, 32 bits
  static int _hash(Uint8List k) {
    var h = 0x811C9DC5;
    for (var i = 0; i < k.length; i++) {
      h = ((h ^ k[i]) * 0x01000193) & 0xFFFFFFFF;
    }
    return h;
  }

  void add(Uint8List k) {
    final h1 = _hash(k);
    final h2 = (((h1 >> 15) | (h1 << 17)) & 0xFFFFFFFF) | 1;
    final bits = _bits, mask = _mask;
    var h = h1;
    for (var i = 0; i < 6; i++) {
      final b = h & mask;
      bits[b >> 5] |= 1 << (b & 31);
      h = (h + h2) & 0xFFFFFFFF;
    }
  }

  bool mayContain(Uint8List k) {
    final h1 = _hash(k);
    final h2 = (((h1 >> 15) | (h1 << 17)) & 0xFFFFFFFF) | 1;
    final bits = _bits, mask = _mask;
    var h = h1;
    for (var i = 0; i < 6; i++) {
      final b = h & mask;
      if ((bits[b >> 5] & (1 << (b & 31))) == 0) return false;
      h = (h + h2) & 0xFFFFFFFF;
    }
    return true;
  }
}

/// The exact entry count of a tree whose delta holds blind puts: the base
/// count, plus the keys the delta sets that the base does not hold, less
/// the keys it deletes that the base holds (the delta's keys looked up in
/// the base, in key order).
int deltaExactCount(PageReader p, int root, int baseCount,
    List<DeltaRun> runs, SplayTreeMap<Uint8List, Uint8List>? mem,
    void Function() check) {
  var n = baseCount;
  final c = MergeCursor(
      (f, t) => [
            if (mem != null && mem.isNotEmpty) MemSource(mem, f, t, false),
            for (final r in runs)
              RunSource(TreeCursor(() => p, () => r.root, check))
          ],
      check,
      keepDeletions: true);
  while (c.moveNext()) {
    final inBase = treeGet(p, root, c.key) != null;
    if (identical(c.value, deltaTomb)) {
      if (inBase) n--;
    } else if (!inBase) {
      n++;
    }
  }
  return n;
}
