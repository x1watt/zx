// The copy-on-write B+tree of zxdb over logical pages.
//
// Pages are named by ids; the page map of each generation says where the
// current bytes of every id are. A write transaction changes copies of
// the pages it touches (under the same ids), so a change to a leaf does
// not rewrite its parents: only splits and merges change a parent. The
// committed pages of earlier generations stay where they are, and their
// page maps keep reading them (snapshots, time travel).

import 'dart:typed_data';

import '../storage_api.dart';
import 'page.dart';

/// Write access (the transaction's).
abstract class PageWriter implements PageReader {
  /// The page, as a copy owned by the transaction (made on first use).
  Node write(int id);

  /// A new page id holding [n].
  int alloc(Node n);

  /// Frees a page id (the page is gone from this generation on).
  void free(int id);
}

/// Where overflow values are kept: identical values share their pages
/// (whole-value deduplication with reference counts, the tree zx$blob of
/// the store). Without one, each value has its own pages.
abstract class BlobStore {
  /// The overflow pages of [value] (new ones, or shared ones).
  Overflow storeBlob(Uint8List value, int tag);

  /// One reference less to [o]; its pages are freed with the last one.
  void releaseBlob(Overflow o);
}

/// The value of a leaf entry, overflow pages read.
Uint8List resolveValue(PageReader p, Object v) {
  if (v is Uint8List) return v;
  final o = v as Overflow;
  final out = Uint8List(o.length);
  var off = 0;
  for (final id in o.pages) {
    final d = p.read(id).data;
    if (d == null || off + d.length > out.length) {
      throw const ZxDbException('damaged overflow value', ZxDbError.corrupt);
    }
    out.setRange(off, off + d.length, d);
    off += d.length;
  }
  if (off != out.length) {
    throw const ZxDbException('damaged overflow value', ZxDbError.corrupt);
  }
  return out;
}

/// The raw value (Uint8List or [Overflow]) of [key] in the tree at [root].
Object? treeGet(PageReader p, int root, Uint8List key) {
  if (root == 0) return null;
  var n = p.read(root);
  while (n.isBranch) {
    n = p.read(n.kids[n.childFor(key)]);
  }
  final i = n.lowerBound(key);
  if (i < n.length && n.compareAt(i, key) == 0) return n.valAt(i);
  return null;
}

/// Every page id of the tree at [root] (overflow pages included).
void treePages(PageReader p, int root, void Function(int id) f) {
  if (root == 0) return;
  final stack = <int>[root];
  while (stack.isNotEmpty) {
    final id = stack.removeLast();
    f(id);
    final n = p.read(id);
    if (n.isBranch) {
      stack.addAll(n.kids);
    } else if (n.isLeaf) {
      for (var i = 0; i < n.length; i++) {
        final v = n.valAt(i);
        if (v is Overflow) v.pages.forEach(f);
      }
    }
  }
}

/// The write operations of one tree in a transaction. [root] changes when
/// the root splits or collapses; [count] follows the entries.
class TreeWriter {
  final PageWriter p;
  int root;
  int count;
  final int pageSize;
  final int tag;

  /// Values longer than this go to overflow pages.
  final int inlineMax;

  /// The size of an overflow page.
  static const int overflowPiece = 64 << 10;

  /// Overflow values go through it (deduplicated) when set.
  final BlobStore? blobs;

  // the split in progress is an append at the right edge
  bool _append = false;

  TreeWriter(this.p, this.root, this.count, this.pageSize, this.tag,
      {this.blobs})
      : inlineMax = pageSize ~/ 4;

  /// Overflow pages holding [value] (no deduplication).
  static Overflow storePieces(PageWriter p, Uint8List value, int tag) {
    final ids = <int>[];
    for (var off = 0; off < value.length; off += overflowPiece) {
      final end = off + overflowPiece < value.length
          ? off + overflowPiece
          : value.length;
      ids.add(p.alloc(Node.overflow(
          Uint8List.fromList(Uint8List.sublistView(value, off, end)))
        ..tree = tag));
    }
    return Overflow(value.length, ids);
  }

  Node _new(Node n) {
    n.tree = tag;
    return n;
  }

  Node _w(int id) => p.write(id)..tree = tag;

  Object _store(Uint8List value) {
    if (value.isEmpty) return emptyBytes;
    if (value.length <= inlineMax) return Uint8List.fromList(value);
    final b = blobs;
    if (b != null) return b.storeBlob(value, tag);
    return storePieces(p, value, tag);
  }

  void _dropValue(Object v) {
    if (v is! Overflow) return;
    final b = blobs;
    if (b != null) {
      b.releaseBlob(v);
    } else {
      v.pages.forEach(p.free);
    }
  }

  /// Inserts or replaces; returns true when the key is new.
  bool put(Uint8List key, Uint8List value) {
    final v = _store(value);
    if (root == 0) {
      root = p.alloc(_new(Node.leaf()));
    }
    final pathIds = <int>[];
    final pathIdx = <int>[];
    var id = root;
    var n = p.read(id);
    while (n.isBranch) {
      final ci = n.childFor(key);
      pathIds.add(id);
      pathIdx.add(ci);
      id = n.kids[ci];
      n = p.read(id);
    }
    final leaf = _w(id);
    final i = leaf.lowerBound(key);
    bool isNew;
    if (i < leaf.keys.length && zxCompareKeys(leaf.keys[i], key) == 0) {
      final old = leaf.vals[i];
      _dropValue(old);
      leaf.bytes += Node.leafEntrySize(key, v) - Node.leafEntrySize(key, old);
      leaf.vals[i] = v;
      isNew = false;
    } else {
      final k = Uint8List.fromList(key);
      leaf.keys.insert(i, k);
      leaf.vals.insert(i, v);
      leaf.bytes += Node.leafEntrySize(k, v);
      count++;
      isNew = true;
    }
    if (leaf.bytes > pageSize && leaf.keys.length > 1) {
      // an append at the right edge of the tree (ascending keys, a bulk
      // load) leaves the left pages full instead of half full
      var edge = isNew && i == leaf.keys.length - 1;
      for (var l = 0; edge && l < pathIds.length; l++) {
        edge = pathIdx[l] == p.read(pathIds[l]).kids.length - 1;
      }
      _append = edge;
      _splitUp(id, leaf, pathIds, pathIdx);
      _append = false;
    }
    return isNew;
  }

  // splits [n] (page [id]) and inserts the new right page in the parents,
  // splitting them too when they overflow
  void _splitUp(int id, Node n, List<int> pathIds, List<int> pathIdx) {
    var (sep, right) = _split(n);
    var level = pathIds.length;
    while (level > 0) {
      level--;
      final pid = pathIds[level];
      final ci = pathIdx[level];
      final parent = _w(pid);
      parent.keys.insert(ci, sep);
      parent.kids.insert(ci + 1, right);
      parent.bytes += Node.branchEntrySize(sep);
      if (parent.bytes <= pageSize || parent.keys.length < 3) return;
      (sep, right) = _split(parent);
    }
    // a new root
    final r = Node.branch([root, right]);
    r.keys.add(sep);
    r.bytes += Node.branchEntrySize(sep);
    root = p.alloc(_new(r));
  }

  // moves the upper half of [n] (by bytes) to a new page; returns the
  // separator and the new page id
  (Uint8List, int) _split(Node n) {
    // appending: the left page keeps all but the last entry (about 7/8 of
    // the page, so a later insert in the middle does not split it at once)
    final half = _append ? n.bytes - n.bytes ~/ 8 : n.bytes ~/ 2;
    var acc = 2;
    var cut = 0;
    final len = n.keys.length;
    if (n.isLeaf) {
      while (cut < len - 1) {
        acc += Node.leafEntrySize(n.keys[cut], n.vals[cut]);
        if (acc >= half) break;
        cut++;
      }
      cut++; // the first entry of the right page
      if (cut >= len) cut = len - 1;
      if (cut < 1) cut = 1;
      final r = Node.leaf();
      r.keys.addAll(n.keys.getRange(cut, len));
      r.vals.addAll(n.vals.getRange(cut, len));
      var rb = 2;
      for (var i = 0; i < r.keys.length; i++) {
        rb += Node.leafEntrySize(r.keys[i], r.vals[i]);
      }
      r.bytes = rb;
      n.keys.removeRange(cut, len);
      n.vals.removeRange(cut, len);
      n.bytes -= rb - 2;
      final sep = shortSeparator(n.keys.last, r.keys.first);
      return (sep, p.alloc(_new(r)));
    }
    // a branch: the middle key goes up
    while (cut < len - 2) {
      acc += Node.branchEntrySize(n.keys[cut]);
      if (acc >= half) break;
      cut++;
    }
    if (cut < 1) cut = 1;
    if (cut > len - 2) cut = len - 2;
    final sep = n.keys[cut];
    final r = Node.branch(n.kids.sublist(cut + 1));
    r.keys.addAll(n.keys.getRange(cut + 1, len));
    for (final k in r.keys) {
      r.bytes += Node.branchEntrySize(k);
    }
    n.keys.removeRange(cut, len);
    n.kids.removeRange(cut + 1, n.kids.length);
    var nb = 7;
    for (final k in n.keys) {
      nb += Node.branchEntrySize(k);
    }
    n.bytes = nb;
    return (sep, p.alloc(_new(r)));
  }

  /// Removes [key]; returns true when it was there.
  bool delete(Uint8List key) {
    if (root == 0) return false;
    final pathIds = <int>[];
    final pathIdx = <int>[];
    var id = root;
    var n = p.read(id);
    while (n.isBranch) {
      final ci = n.childFor(key);
      pathIds.add(id);
      pathIdx.add(ci);
      id = n.kids[ci];
      n = p.read(id);
    }
    final i = n.lowerBound(key);
    if (i >= n.length || n.compareAt(i, key) != 0) return false;
    final leaf = _w(id);
    _dropValue(leaf.vals[i]);
    leaf.bytes -= Node.leafEntrySize(leaf.keys[i], leaf.vals[i]);
    leaf.keys.removeAt(i);
    leaf.vals.removeAt(i);
    count--;
    _rebalance(id, leaf, pathIds, pathIdx);
    return true;
  }

  // after a removal from [n] (page [id]): an empty page leaves its parent,
  // a small one is merged with a neighbour when both fit in one page; the
  // parents follow, and a root with one child gives way to it
  void _rebalance(int id, Node n, List<int> pathIds, List<int> pathIdx) {
    var curId = id;
    var cur = n;
    var level = pathIds.length;
    while (level > 0) {
      level--;
      final pid = pathIds[level];
      final ci = pathIdx[level];
      final empty = cur.isLeaf ? cur.keys.isEmpty : cur.kids.isEmpty;
      if (empty) {
        final parent = _w(pid);
        _removeChild(parent, ci);
        p.free(curId);
        curId = pid;
        cur = parent;
        continue;
      }
      if (cur.bytes >= pageSize ~/ 4) break;
      // merge with the right neighbour, else the left one
      final parent = _w(pid);
      int li, ri;
      if (ci + 1 < parent.kids.length) {
        li = ci;
        ri = ci + 1;
      } else if (ci > 0) {
        li = ci - 1;
        ri = ci;
      } else {
        break;
      }
      final left = p.read(parent.kids[li]);
      final right = p.read(parent.kids[ri]);
      final sepBytes = cur.isLeaf ? 0 : Node.branchEntrySize(parent.keys[li]);
      if (left.bytes + right.bytes + sepBytes > pageSize * 3 ~/ 4) break;
      final l = _w(parent.kids[li]);
      if (cur.isLeaf) {
        l.keys.addAll(right.keys);
        l.vals.addAll(right.vals);
        l.bytes += right.bytes - 2;
      } else {
        l.keys.add(parent.keys[li]);
        l.keys.addAll(right.keys);
        l.kids.addAll(right.kids);
        l.bytes += right.bytes - 7 + sepBytes;
      }
      p.free(parent.kids[ri]);
      _removeChild(parent, ri);
      curId = pid;
      cur = parent;
    }
    // the root: an empty leaf root stays; a branch root with one child
    // gives way to it
    for (;;) {
      final r = p.read(root);
      if (r.isBranch && r.kids.length == 1) {
        final only = r.kids[0];
        p.free(root);
        root = only;
        continue;
      }
      if (r.isBranch && r.kids.isEmpty) {
        p.free(root);
        root = 0;
      } else if (r.isLeaf && r.length == 0) {
        p.free(root);
        root = 0;
      }
      break;
    }
  }

  // removes child [ci] and its separator from a branch
  void _removeChild(Node parent, int ci) {
    parent.kids.removeAt(ci);
    if (parent.keys.isEmpty) {
      parent.bytes = 7;
      return;
    }
    final ki = ci == 0 ? 0 : ci - 1;
    parent.bytes -= Node.branchEntrySize(parent.keys[ki]);
    parent.keys.removeAt(ki);
  }

  /// Frees every page of the tree (its overflow values are released).
  void drop() {
    final ids = <int>[];
    final values = <Overflow>[];
    if (root != 0) {
      final stack = <int>[root];
      while (stack.isNotEmpty) {
        final id = stack.removeLast();
        ids.add(id);
        final n = p.read(id);
        if (n.isBranch) {
          stack.addAll(n.kids);
        } else if (n.isLeaf) {
          for (var i = 0; i < n.length; i++) {
            final v = n.valAt(i);
            if (v is Overflow) values.add(v);
          }
        }
      }
    }
    values.forEach(_dropValue);
    ids.forEach(p.free);
    root = 0;
    count = 0;
  }
}

/// A cursor over a tree: a stack of pages and positions. With [mods] it
/// follows writes: when the counter changed since its last step, it seeks
/// again after the last key it returned.
class TreeCursor implements ZxCursor {
  final PageReader Function() pages;
  final int Function() rootOf;
  final int Function()? mods;
  final void Function() check;
  final Uint8List? from;
  final Uint8List? to;
  final bool reverse;

  final List<Node> _nodes = [];
  final List<int> _idx = [];
  int _seen = -1;
  bool _started = false;
  bool _done = false;
  Uint8List? _key;
  Object? _raw;
  Uint8List? _value;

  TreeCursor(this.pages, this.rootOf, this.check,
      {this.mods, this.from, this.to, this.reverse = false});

  @override
  bool moveNext() {
    check();
    if (_done) return false;
    final p = pages();
    final m = mods?.call() ?? 0;
    bool ok;
    if (!_started) {
      _started = true;
      ok = reverse ? _seekFloor(p, to, false) : _seekCeil(p, from, true);
    } else if (m != _seen) {
      ok = reverse ? _seekFloor(p, _key, false) : _seekCeil(p, _key, false);
    } else {
      ok = reverse ? _prev(p) : _next(p);
    }
    _seen = m;
    if (ok) {
      final leaf = _nodes.last;
      final i = _idx.last;
      final k = leaf.keyAt(i);
      if (!reverse) {
        if (to != null && zxCompareKeys(k, to!) >= 0) ok = false;
      } else {
        if (from != null && zxCompareKeys(k, from!) < 0) ok = false;
      }
      if (ok) {
        _key = k;
        _raw = leaf.valAt(i);
        _value = null;
        return true;
      }
    }
    _done = true;
    _key = null;
    _raw = null;
    _value = null;
    _nodes.clear();
    _idx.clear();
    return false;
  }

  // positions at the first key >= k (> k when !inclusive)
  bool _seekCeil(PageReader p, Uint8List? k, bool inclusive) {
    _nodes.clear();
    _idx.clear();
    final root = rootOf();
    if (root == 0) return false;
    var n = p.read(root);
    while (n.isBranch) {
      final ci = k == null ? 0 : n.childFor(k);
      _nodes.add(n);
      _idx.add(ci);
      n = p.read(n.kids[ci]);
    }
    _nodes.add(n);
    _idx.add(k == null ? 0 : n.lowerBound(k, !inclusive));
    return _fixForward(p);
  }

  // positions at the last key <= k (< k when !inclusive; the last key
  // when k is null)
  bool _seekFloor(PageReader p, Uint8List? k, bool inclusive) {
    _nodes.clear();
    _idx.clear();
    final root = rootOf();
    if (root == 0) return false;
    var n = p.read(root);
    while (n.isBranch) {
      final ci = k == null ? n.kids.length - 1 : n.childFor(k);
      _nodes.add(n);
      _idx.add(ci);
      n = p.read(n.kids[ci]);
    }
    _nodes.add(n);
    _idx.add(k == null ? n.length - 1 : n.lowerBound(k, inclusive) - 1);
    return _fixBackward(p);
  }

  // moves up and right while the leaf position is past its end
  bool _fixForward(PageReader p) {
    for (;;) {
      final top = _nodes.length - 1;
      if (_idx[top] < _nodes[top].length) return true;
      // up to a branch with a next child
      var lv = top - 1;
      while (lv >= 0 && _idx[lv] + 1 >= _nodes[lv].kids.length) {
        lv--;
      }
      if (lv < 0) return false;
      _nodes.length = lv + 1;
      _idx.length = lv + 1;
      _idx[lv]++;
      var n = p.read(_nodes[lv].kids[_idx[lv]]);
      while (n.isBranch) {
        _nodes.add(n);
        _idx.add(0);
        n = p.read(n.kids[0]);
      }
      _nodes.add(n);
      _idx.add(0);
    }
  }

  bool _fixBackward(PageReader p) {
    for (;;) {
      final top = _nodes.length - 1;
      if (_idx[top] >= 0) return true;
      var lv = top - 1;
      while (lv >= 0 && _idx[lv] == 0) {
        lv--;
      }
      if (lv < 0) return false;
      _nodes.length = lv + 1;
      _idx.length = lv + 1;
      _idx[lv]--;
      var n = p.read(_nodes[lv].kids[_idx[lv]]);
      while (n.isBranch) {
        _nodes.add(n);
        _idx.add(n.kids.length - 1);
        n = p.read(n.kids[n.kids.length - 1]);
      }
      _nodes.add(n);
      _idx.add(n.length - 1);
    }
  }

  bool _next(PageReader p) {
    _idx[_idx.length - 1]++;
    return _fixForward(p);
  }

  bool _prev(PageReader p) {
    _idx[_idx.length - 1]--;
    return _fixBackward(p);
  }

  @override
  Uint8List get key => _key ?? (throw StateError('no current entry'));

  @override
  Uint8List get value {
    final v = _value;
    if (v != null) return v;
    final raw = _raw;
    if (raw == null) throw StateError('no current entry');
    return _value = resolveValue(pages(), raw);
  }

  @override
  void close() {
    _done = true;
    _nodes.clear();
    _idx.clear();
  }
}
