// An in-memory ZxStore (storage_api.dart): sorted maps, snapshots by
// generation, one writer. It follows the contract exactly and is the
// reference the engine's tests compare against; the SQL engine and the
// system tables use it in their unit tests.
//
// Committed trees are immutable sorted arrays shared by every snapshot
// that sees them. The write transaction copies a tree into a SplayTreeMap
// on its first write to it, and turns it back into arrays at commit, so a
// commit costs O(n) for each tree it changed.

import 'dart:collection';
import 'dart:typed_data';

import 'storage_api.dart';

/// An in-memory [ZxStore]. Generations are numbered from 1; every commit
/// appends one, and they are all kept unless [keepGenerations] is given.
class ZxMemoryStore implements ZxStore {
  /// Keep only the last N generations (null: all).
  final int? keepGenerations;

  /// The clock of the commits (ns since epoch, UTC); tests may fix it.
  int Function() clock;

  final List<_MemGen> _gens = [];
  _MemTxn? _txn;
  bool _closed = false;

  ZxMemoryStore({this.keepGenerations, int Function()? clock})
      : clock = clock ?? _now;

  static int _now() => DateTime.now().microsecondsSinceEpoch * 1000;

  static final _MemGen _empty = _MemGen(0, 0, null, const {});

  void _checkOpen() {
    if (_closed) throw StateError('the store is closed');
  }

  _MemGen get _latest => _gens.isEmpty ? _empty : _gens.last;

  @override
  ZxSnapshot snapshot({int? generation, int? atTimeNs}) {
    _checkOpen();
    if (generation != null) {
      if (generation == 0 && _gens.isEmpty) return _MemSnapshot(_empty);
      for (final g in _gens) {
        if (g.number == generation) return _MemSnapshot(g);
      }
      throw ZxDbException(
          'no generation $generation', ZxDbError.notFound);
    }
    if (atTimeNs != null) {
      _MemGen? best;
      for (final g in _gens) {
        if (g.timeNs <= atTimeNs) best = g;
      }
      if (best == null) {
        throw ZxDbException(
            'no generation at or before $atTimeNs', ZxDbError.notFound);
      }
      return _MemSnapshot(best);
    }
    return _MemSnapshot(_latest);
  }

  @override
  ZxWriteTxn begin({int waitMs = 5000}) {
    _checkOpen();
    // one isolate: a second writer can never be waited for
    if (_txn != null) {
      throw const ZxDbException(
          'a write transaction is open', ZxDbError.busy);
    }
    return _txn = _MemTxn(this, _latest);
  }

  int _commit(_MemTxn t, String? comment) {
    if (!t.changed) {
      _txn = null;
      return _latest.number;
    }
    final trees = Map<String, _MemTreeData>.of(t.base.trees);
    for (final name in t.dropped) {
      trees.remove(name);
    }
    t.trees.forEach((name, tt) {
      trees[name] = tt.freeze();
    });
    var time = clock();
    final last = _latest;
    if (time < last.timeNs) time = last.timeNs;
    final g = _MemGen(last.number + 1, time, comment, trees);
    _gens.add(g);
    final keep = keepGenerations;
    if (keep != null && keep > 0 && _gens.length > keep) {
      _gens.removeRange(0, _gens.length - keep);
    }
    _txn = null;
    return g.number;
  }

  @override
  List<({int generation, int timeNs, String? comment})> get generations => [
        for (final g in _gens)
          (generation: g.number, timeNs: g.timeNs, comment: g.comment)
      ];

  @override
  void close() {
    _txn?._closed = true;
    _txn = null;
    _closed = true;
  }
}

// one committed generation
class _MemGen {
  final int number;
  final int timeNs;
  final String? comment;
  final Map<String, _MemTreeData> trees;
  const _MemGen(this.number, this.timeNs, this.comment, this.trees);
}

// an immutable committed tree
class _MemTreeData {
  final TreeOptions options;
  final List<Uint8List> keys;
  final List<Uint8List> values;
  const _MemTreeData(this.options, this.keys, this.values);
}

// the index of the first key >= k (or > k when !inclusive)
int _lowerBound(List<Uint8List> keys, Uint8List k, bool inclusive) {
  var lo = 0, hi = keys.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    final c = zxCompareKeys(keys[mid], k);
    if (c < 0 || (c == 0 && !inclusive)) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo;
}

// ordered access to one version of a tree
abstract class _View {
  int get length;
  Uint8List? get(Uint8List k);

  // the first entry >= k (> k when !inclusive), the first one when k is
  // null; null at the end
  (Uint8List, Uint8List)? ceil(Uint8List? k, bool inclusive);

  // the last entry <= k (< k when !inclusive), the last one when k is
  // null; null at the start
  (Uint8List, Uint8List)? floor(Uint8List? k, bool inclusive);
}

class _ArrayView implements _View {
  final _MemTreeData d;
  _ArrayView(this.d);

  @override
  int get length => d.keys.length;

  @override
  Uint8List? get(Uint8List k) {
    final i = _lowerBound(d.keys, k, true);
    if (i < d.keys.length && zxCompareKeys(d.keys[i], k) == 0) {
      return d.values[i];
    }
    return null;
  }

  @override
  (Uint8List, Uint8List)? ceil(Uint8List? k, bool inclusive) {
    final i = k == null ? 0 : _lowerBound(d.keys, k, inclusive);
    return i < d.keys.length ? (d.keys[i], d.values[i]) : null;
  }

  @override
  (Uint8List, Uint8List)? floor(Uint8List? k, bool inclusive) {
    final i =
        k == null ? d.keys.length - 1 : _lowerBound(d.keys, k, !inclusive) - 1;
    return i >= 0 ? (d.keys[i], d.values[i]) : null;
  }
}

class _MapView implements _View {
  final SplayTreeMap<Uint8List, Uint8List> m;
  _MapView(this.m);

  @override
  int get length => m.length;

  @override
  Uint8List? get(Uint8List k) => m[k];

  @override
  (Uint8List, Uint8List)? ceil(Uint8List? k, bool inclusive) {
    Uint8List? key;
    if (k == null) {
      key = m.isEmpty ? null : m.firstKey();
    } else if (inclusive && m.containsKey(k)) {
      key = k;
    } else {
      key = m.firstKeyAfter(k);
    }
    return key == null ? null : (key, m[key]!);
  }

  @override
  (Uint8List, Uint8List)? floor(Uint8List? k, bool inclusive) {
    Uint8List? key;
    if (k == null) {
      key = m.isEmpty ? null : m.lastKey();
    } else if (inclusive && m.containsKey(k)) {
      key = k;
    } else {
      key = m.lastKeyBefore(k);
    }
    return key == null ? null : (key, m[key]!);
  }
}

// a cursor that steps by key, so it survives writes to its tree
class _MemCursor implements ZxCursor {
  final _View Function() view;
  final void Function() check;
  final Uint8List? from;
  final Uint8List? to;
  final bool reverse;
  Uint8List? _key;
  Uint8List? _value;
  bool _started = false;
  bool _done = false;

  _MemCursor(this.view, this.check, this.from, this.to, this.reverse);

  @override
  bool moveNext() {
    check();
    if (_done) return false;
    final v = view();
    (Uint8List, Uint8List)? e;
    if (!reverse) {
      e = _started ? v.ceil(_key, false) : v.ceil(from, true);
      if (e != null && to != null && zxCompareKeys(e.$1, to!) >= 0) e = null;
    } else {
      e = _started ? v.floor(_key, false) : v.floor(to, false);
      if (e != null && from != null && zxCompareKeys(e.$1, from!) < 0) {
        e = null;
      }
    }
    _started = true;
    if (e == null) {
      _done = true;
      _key = null;
      _value = null;
      return false;
    }
    _key = e.$1;
    _value = e.$2;
    return true;
  }

  @override
  Uint8List get key => _key ?? (throw StateError('no current entry'));

  @override
  Uint8List get value => _value ?? (throw StateError('no current entry'));

  @override
  void close() {
    _done = true;
  }
}

class _MemTree implements ZxTree {
  @override
  final String name;
  final _MemTreeData d;
  final _MemSnapshot snap;
  late final _ArrayView _v = _ArrayView(d);
  _MemTree(this.name, this.d, this.snap);

  @override
  TreeOptions get options => d.options;

  @override
  Uint8List? get(Uint8List key) {
    snap._check();
    return _v.get(key);
  }

  @override
  ZxCursor scan({Uint8List? from, Uint8List? to, bool reverse = false}) {
    snap._check();
    return _MemCursor(() => _v, snap._check, from, to, reverse);
  }

  @override
  int get length => d.keys.length;
}

class _MemSnapshot implements ZxSnapshot {
  final _MemGen g;
  bool _closed = false;
  _MemSnapshot(this.g);

  void _check() {
    if (_closed) throw StateError('the snapshot is closed');
  }

  @override
  int get generation => g.number;

  @override
  int get timeNs => g.timeNs;

  @override
  List<String> get treeNames {
    _check();
    return g.trees.keys.toList()..sort();
  }

  @override
  ZxTree? tree(String name) {
    _check();
    final d = g.trees[name];
    return d == null ? null : _MemTree(name, d, this);
  }

  @override
  void close() {
    _closed = true;
  }
}

void _checkKey(Uint8List key) {
  if (key.length > zxMaxKeyLength) {
    throw ZxDbException(
        'key of ${key.length} bytes (at most $zxMaxKeyLength)',
        ZxDbError.constraint);
  }
}

// a tree of the write transaction
class _TxnTree implements ZxWritableTree {
  @override
  final String name;
  @override
  TreeOptions options;
  final _MemTxn txn;
  _MemTreeData? _base;
  SplayTreeMap<Uint8List, Uint8List>? _map;

  _TxnTree(this.name, this.options, this.txn, this._base);

  _View get _view {
    final m = _map;
    if (m != null) return _MapView(m);
    final b = _base;
    return b == null ? _MapView(_writable) : _ArrayView(b);
  }

  SplayTreeMap<Uint8List, Uint8List> get _writable {
    txn.changed = true;
    var m = _map;
    if (m != null) return m;
    m = _map = SplayTreeMap<Uint8List, Uint8List>(zxCompareKeys);
    final b = _base;
    if (b != null) {
      for (var i = 0; i < b.keys.length; i++) {
        m[b.keys[i]] = b.values[i];
      }
    }
    _base = null;
    return m;
  }

  _MemTreeData freeze() {
    final m = _map;
    if (m == null) {
      final b = _base;
      if (b != null) return _MemTreeData(options, b.keys, b.values);
      return _MemTreeData(options, const [], const []);
    }
    final keys = List<Uint8List>.of(m.keys, growable: false);
    final values = List<Uint8List>.of(m.values, growable: false);
    return _MemTreeData(options, keys, values);
  }

  @override
  Uint8List? get(Uint8List key) {
    txn._check();
    return _view.get(key);
  }

  @override
  ZxCursor scan({Uint8List? from, Uint8List? to, bool reverse = false}) {
    txn._check();
    return _MemCursor(() => _view, txn._check, from, to, reverse);
  }

  @override
  int get length => _view.length;

  @override
  void put(Uint8List key, Uint8List value) {
    txn._check();
    _checkKey(key);
    _writable[Uint8List.fromList(key)] = Uint8List.fromList(value);
  }

  @override
  bool delete(Uint8List key) {
    txn._check();
    final m = _writable;
    if (!m.containsKey(key)) return false;
    m.remove(key);
    return true;
  }

  @override
  int deleteRange({Uint8List? from, Uint8List? to}) {
    txn._check();
    final m = _writable;
    final doomed = <Uint8List>[];
    var k = from == null
        ? (m.isEmpty ? null : m.firstKey())
        : (m.containsKey(from) ? from : m.firstKeyAfter(from));
    while (k != null && (to == null || zxCompareKeys(k, to) < 0)) {
      doomed.add(k);
      k = m.firstKeyAfter(k);
    }
    for (final d in doomed) {
      m.remove(d);
    }
    return doomed.length;
  }
}

class _MemTxn implements ZxWriteTxn {
  final ZxMemoryStore store;
  final _MemGen base;
  final Map<String, _TxnTree> trees = {};
  final Set<String> dropped = {};
  bool _closed = false;

  /// Something was written (an empty transaction commits nothing).
  bool changed = false;

  _MemTxn(this.store, this.base);

  void _check() {
    if (_closed) throw StateError('the transaction is closed');
  }

  bool _exists(String name) =>
      trees.containsKey(name) ||
      (!dropped.contains(name) && base.trees.containsKey(name));

  @override
  int get generation => base.number;

  @override
  int get timeNs => base.timeNs;

  @override
  List<String> get treeNames {
    _check();
    final s = <String>{
      for (final n in base.trees.keys)
        if (!dropped.contains(n)) n,
      ...trees.keys
    };
    return s.toList()..sort();
  }

  @override
  ZxWritableTree? tree(String name) {
    _check();
    final t = trees[name];
    if (t != null) return t;
    if (dropped.contains(name)) return null;
    final d = base.trees[name];
    if (d == null) return null;
    return trees[name] = _TxnTree(name, d.options, this, d);
  }

  @override
  ZxWritableTree createTree(String name,
      [TreeOptions options = const TreeOptions()]) {
    _check();
    if (name.isEmpty) {
      throw const ZxDbException('empty tree name', ZxDbError.constraint);
    }
    if (_exists(name)) {
      throw ZxDbException('tree "$name" exists', ZxDbError.constraint);
    }
    // a tree dropped and created again in one transaction starts empty
    dropped.add(name);
    changed = true;
    return trees[name] = _TxnTree(name, options, this, null);
  }

  @override
  void dropTree(String name) {
    _check();
    if (!_exists(name)) {
      throw ZxDbException('no tree "$name"', ZxDbError.notFound);
    }
    trees.remove(name);
    dropped.add(name);
    changed = true;
  }

  @override
  void setTreeOptions(String name, TreeOptions options) {
    _check();
    final t = tree(name);
    if (t == null) {
      throw ZxDbException('no tree "$name"', ZxDbError.notFound);
    }
    (t as _TxnTree).options = options;
    changed = true;
  }

  @override
  int commit({String? comment}) {
    _check();
    _closed = true;
    return store._commit(this, comment);
  }

  @override
  void rollback() {
    _check();
    _closed = true;
    store._txn = null;
  }

  @override
  void close() {
    if (!_closed) rollback();
  }
}
