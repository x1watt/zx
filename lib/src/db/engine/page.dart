// Database pages (docs/zx-format.md section 16): the B+tree nodes and the
// overflow pages of large values, as decoded objects and as bytes.
//
// Layouts (vint as in the container):
//
//   Leaf     = u8 1, vint count, count x ( vint shared, vint suffix_length,
//              bytes suffix, vint vtag, value )
//              vtag even: an inline value of vtag >> 1 bytes follows;
//              vtag odd: an overflow value of vtag >> 1 bytes, stored in
//              vint page_count pages, vint page ids (each an Overflow).
//   Branch   = u8 2, vint count, vint child_0, count x ( vint shared,
//              vint suffix_length, bytes suffix, vint child )
//              child_i holds the keys >= key_i (and < key_i+1).
//   Overflow = u8 3, bytes (a part of a value, the parts in order).
//
// Keys are prefix compressed: `shared` bytes of the previous key of the
// page, then the suffix.

import 'dart:typed_data';

import '../../format/zx/zx_format.dart';
import '../../io/streams.dart' show SevenZipException;
import '../storage_api.dart';

/// Read access to the pages of one tree version.
abstract class PageReader {
  Node read(int id);
}

abstract final class PageKind {
  static const leaf = 1;
  static const branch = 2;
  static const overflow = 3;
}

/// A value kept in overflow pages.
class Overflow {
  final int length;
  final List<int> pages;
  const Overflow(this.length, this.pages);

  int get encodedSize => 8 + 5 * pages.length;
}

int _vlen(int v) {
  var n = 1;
  while (v >= 0x80) {
    v >>= 7;
    n++;
  }
  return n;
}

/// A decoded page. Committed pages are shared by snapshots and caches
/// and never change; the write transaction changes its own copies
/// ([copy]). A page decoded from the file is flat (its keys in one buffer,
/// its inline values in another, with offsets: no object per entry); a
/// page of the transaction holds lists that it changes.
class Node {
  final int kind;

  // list form (pages of the transaction)
  List<Uint8List>? _keys;
  List<Object>? _vals;

  // flat form (decoded pages): full keys and inline values one after the
  // other, entry i at [_ko[i], _ko[i + 1]) and [_vo[i], _vo[i + 1]);
  // overflow values in [_of] (null when there is none)
  Uint8List? _kb;
  Int32List? _ko;
  Uint8List? _vb;
  Int32List? _vo;
  List<Overflow?>? _of;
  int _n = 0;

  /// Branch children (length + 1).
  final List<int> kids;

  /// Overflow pages: the bytes.
  final Uint8List? data;

  /// The encoded size, at most (without prefix compression).
  int bytes;

  /// The tree the page belongs to (for grouping at commit and fold), set
  /// by the transaction.
  int tree = 0;

  Node(this.kind, List<Uint8List> keys, List<Object> vals, this.kids,
      this.data, this.bytes)
      : _keys = keys,
        _vals = vals;

  Node._flat(this.kind, this._kb, this._ko, this._vb, this._vo, this._of,
      this._n, this.kids, this.bytes)
      : data = null;

  factory Node.leaf() => Node(PageKind.leaf, [], [], const [], null, 2);

  /// A branch with [kids] and no keys yet: [bytes] counts 7 for the
  /// header and the first child, and each key adds [branchEntrySize]
  /// (the key and the child after it).
  factory Node.branch(List<int> kids) =>
      Node(PageKind.branch, [], const [], kids, null, 7);
  factory Node.overflow(Uint8List data) => Node(
      PageKind.overflow, const [], const [], const [], data, 1 + data.length);

  bool get isLeaf => kind == PageKind.leaf;
  bool get isBranch => kind == PageKind.branch;
  int get length => _keys?.length ?? _n;

  /// Key [i] (a view of a flat page).
  Uint8List keyAt(int i) {
    final k = _keys;
    if (k != null) return k[i];
    final o = _ko!;
    return Uint8List.sublistView(_kb!, o[i], o[i + 1]);
  }

  /// Value [i] of a leaf: Uint8List (a view of a flat page) or [Overflow].
  Object valAt(int i) {
    final v = _vals;
    if (v != null) return v[i];
    final of = _of;
    if (of != null) {
      final x = of[i];
      if (x != null) return x;
    }
    final o = _vo!;
    return Uint8List.sublistView(_vb!, o[i], o[i + 1]);
  }

  /// The keys as a list (made from a flat page once, for changes).
  List<Uint8List> get keys =>
      _keys ??= [for (var i = 0; i < _n; i++) keyAt(i)];

  /// The leaf values as a list (Uint8List or [Overflow]).
  List<Object> get vals {
    final v = _vals;
    if (v != null) return v;
    if (kind != PageKind.leaf) return _vals = const [];
    return _vals = [for (var i = 0; i < _n; i++) valAt(i)];
  }

  Node copy() => Node(
      kind,
      List.of(keys),
      kind == PageKind.leaf ? List.of(vals) : const [],
      kind == PageKind.branch ? List.of(kids) : const [],
      data,
      bytes)
    ..tree = tree;

  /// The estimated bytes of a leaf entry.
  static int leafEntrySize(Uint8List k, Object v) =>
      4 +
      k.length +
      (v is Uint8List ? 3 + v.length : (v as Overflow).encodedSize);

  /// The estimated bytes of a branch entry.
  static int branchEntrySize(Uint8List k) => 4 + k.length + 5;

  /// Approximate memory of the decoded page (for the cache budget).
  int get memory {
    if (data != null) return 64 + data!.length;
    final kb = _kb;
    if (kb != null) {
      var m = 128 + kb.length + 4 * (_n + 1) + kids.length * 8;
      final vb = _vb;
      if (vb != null) m += vb.length + 4 * (_n + 1);
      final of = _of;
      if (of != null) m += 8 * of.length + 48 * of.where((x) => x != null).length;
      return m;
    }
    final keys = _keys!;
    var m = 96 + keys.length * 40 + kids.length * 8;
    for (final k in keys) {
      m += k.length;
    }
    for (final v in _vals!) {
      m += v is Uint8List ? v.length + 24 : 48;
    }
    return m;
  }

  /// Compares key [i] with [k] (as zxCompareKeys).
  int compareAt(int i, Uint8List k) {
    final keys = _keys;
    if (keys != null) return zxCompareKeys(keys[i], k);
    final b = _kb!, o = _ko!;
    final s = o[i], e = o[i + 1];
    final la = e - s, lb = k.length;
    final n = la < lb ? la : lb;
    for (var j = 0; j < n; j++) {
      final d = b[s + j] - k[j];
      if (d != 0) return d;
    }
    return la - lb;
  }

  /// The index of the first key >= [k] (or > [k] when [after]).
  int lowerBound(Uint8List k, [bool after = false]) {
    var lo = 0, hi = length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      final c = compareAt(mid, k);
      if (c < 0 || (after && c == 0)) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  /// The child of a branch that holds [k].
  int childFor(Uint8List k) {
    // the number of keys <= k
    var lo = 0, hi = length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (compareAt(mid, k) <= 0) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  /// The exact encoded size.
  int encodedSize() {
    if (kind == PageKind.overflow) return 1 + data!.length;
    var n = 1 + _vlen(keys.length);
    if (kind == PageKind.branch) n += _vlen(kids[0]);
    Uint8List? prev;
    for (var i = 0; i < keys.length; i++) {
      final k = keys[i];
      final sh = prev == null ? 0 : _shared(prev, k);
      n += _vlen(sh) + _vlen(k.length - sh) + k.length - sh;
      if (kind == PageKind.leaf) {
        final v = vals[i];
        if (v is Uint8List) {
          n += _vlen(v.length << 1) + v.length;
        } else {
          final o = v as Overflow;
          n += _vlen((o.length << 1) | 1) + _vlen(o.pages.length);
          for (final p in o.pages) {
            n += _vlen(p);
          }
        }
      } else {
        n += _vlen(kids[i + 1]);
      }
      prev = k;
    }
    return n;
  }

  /// Encodes the page into [out] at [off] (room for [encodedSize] bytes);
  /// returns the end.
  int encodeInto(Uint8List out, int off) {
    var p = off;
    out[p++] = kind;
    if (kind == PageKind.overflow) {
      final d = data!;
      out.setRange(p, p + d.length, d);
      return p + d.length;
    }
    p = _putVint(out, p, keys.length);
    final leaf = kind == PageKind.leaf;
    if (!leaf) p = _putVint(out, p, kids[0]);
    Uint8List? prev;
    for (var i = 0; i < keys.length; i++) {
      final k = keys[i];
      final sh = prev == null ? 0 : _shared(prev, k);
      p = _putVint(out, p, sh);
      p = _putVint(out, p, k.length - sh);
      out.setRange(p, p + k.length - sh, k, sh);
      p += k.length - sh;
      if (leaf) {
        final v = vals[i];
        if (v is Uint8List) {
          p = _putVint(out, p, v.length << 1);
          out.setRange(p, p + v.length, v);
          p += v.length;
        } else {
          final o = v as Overflow;
          p = _putVint(out, p, (o.length << 1) | 1);
          p = _putVint(out, p, o.pages.length);
          for (final id in o.pages) {
            p = _putVint(out, p, id);
          }
        }
      } else {
        p = _putVint(out, p, kids[i + 1]);
      }
      prev = k;
    }
    return p;
  }

  Uint8List encode() {
    final out = Uint8List(encodedSize());
    final end = encodeInto(out, 0);
    if (end != out.length) throw StateError('page size mismatch');
    return out;
  }

  /// Decodes the page in b[off, off + len). The values are copied (the
  /// page does not keep its block alive).
  static Node decode(Uint8List b, int off, int len) {
    final end = off + len;
    if (len < 1) _bad();
    final kind = b[off];
    if (kind == PageKind.overflow) {
      return Node.overflow(
          Uint8List.fromList(Uint8List.sublistView(b, off + 1, end)));
    }
    if (kind != PageKind.leaf && kind != PageKind.branch) _bad();
    final r = _PageReader(b, off + 1, end);
    final n = r.vint();
    if (n > len) _bad();
    final leaf = kind == PageKind.leaf;
    final kids = leaf ? const <int>[] : <int>[r.vint()];
    // pass 1: where the suffixes and values are
    final sh = Int32List(n), sp = Int32List(n), sl = Int32List(n);
    final vp = leaf ? Int32List(n) : null;
    final vl = leaf ? Int32List(n) : null;
    List<Overflow?>? of;
    var keyBytes = 0, valBytes = 0, prevLen = 0;
    var bytes = leaf ? 2 : 7;
    for (var i = 0; i < n; i++) {
      final a = r.vint(), l = r.vint();
      if (a > prevLen || r.p + l > end) _bad();
      sh[i] = a;
      sp[i] = r.p;
      sl[i] = l;
      r.p += l;
      final klen = a + l;
      keyBytes += klen;
      prevLen = klen;
      if (leaf) {
        final tag = r.vint();
        final size = tag >> 1;
        if ((tag & 1) == 0) {
          if (r.p + size > end) _bad();
          vp![i] = r.p;
          vl![i] = size;
          r.p += size;
          valBytes += size;
          bytes += 7 + klen + size;
        } else {
          final pc = r.vint();
          if (pc > len) _bad();
          final ids = List<int>.filled(pc, 0);
          for (var j = 0; j < pc; j++) {
            ids[j] = r.vint();
          }
          final o = Overflow(size, ids);
          (of ??= List<Overflow?>.filled(n, null))[i] = o;
          vl![i] = 0;
          bytes += 4 + klen + o.encodedSize;
        }
      } else {
        kids.add(r.vint());
        bytes += 9 + klen;
      }
    }
    if (r.p != end) _bad();
    // pass 2: the full keys and the values, one after the other
    final kb = Uint8List(keyBytes);
    final ko = Int32List(n + 1);
    var kp = 0, prev = 0;
    for (var i = 0; i < n; i++) {
      ko[i] = kp;
      final a = sh[i];
      if (a > 0) kb.setRange(kp, kp + a, kb, prev);
      kb.setRange(kp + a, kp + a + sl[i], b, sp[i]);
      prev = kp;
      kp += a + sl[i];
    }
    ko[n] = kp;
    Uint8List? vb;
    Int32List? vo;
    if (leaf) {
      vb = Uint8List(valBytes);
      vo = Int32List(n + 1);
      var q = 0;
      for (var i = 0; i < n; i++) {
        vo[i] = q;
        final l = vl![i];
        if (l > 0) vb.setRange(q, q + l, b, vp![i]);
        q += l;
      }
      vo[n] = q;
    }
    return Node._flat(kind, kb, ko, vb, vo, of, n, kids, bytes);
  }
}

// writes v as a vint at out[p]; returns the end
int _putVint(Uint8List out, int p, int v) {
  while (v >= 0x80) {
    out[p++] = (v & 0x7F) | 0x80;
    v >>= 7;
  }
  out[p++] = v;
  return p;
}

// reads the vints of a page
class _PageReader {
  final Uint8List b;
  int p;
  final int end;
  _PageReader(this.b, this.p, this.end);

  int vint() {
    final bb = b, e = end;
    var q = p;
    var v = 0, s = 0;
    for (;;) {
      if (q >= e || s > 63) _bad();
      final c = bb[q++];
      v |= (c & 0x7F) << s;
      if (c < 0x80) {
        p = q;
        return v;
      }
      s += 7;
    }
  }
}

final Uint8List _empty = Uint8List(0);

/// The empty value, shared (index keys often have no value).
final Uint8List emptyBytes = _empty;

int _shared(Uint8List a, Uint8List b) {
  final n = a.length < b.length ? a.length : b.length;
  var i = 0;
  while (i < n && a[i] == b[i]) {
    i++;
  }
  return i;
}

Never _bad() => throw const ZxDbException(
    'damaged database page', ZxDbError.corrupt);

/// Converts container errors of page reads into [ZxDbException].
Never zxDbCorrupt(Object e) {
  if (e is ZxDbException) throw e;
  if (e is SevenZipException) {
    throw ZxDbException('damaged database page: ${e.message}', ZxDbError.corrupt);
  }
  throw ZxDbException('damaged database page: $e', ZxDbError.corrupt);
}

/// The shortest key s with left < s <= right (a branch separator).
Uint8List shortSeparator(Uint8List left, Uint8List right) {
  var i = 0;
  final n = left.length < right.length ? left.length : right.length;
  while (i < n && left[i] == right[i]) {
    i++;
  }
  // right[0 .. i] is greater than left and a prefix of right
  if (i < right.length) return Uint8List.fromList(right.sublist(0, i + 1));
  return right;
}

/// The page kind of a map page is not a tree page: map pages are raw
/// arrays of [ZxDbLoc] entries (1024 x 24 bytes).
const int mapPageBytes = ZxDbRoot.mapPageEntries * ZxDbLoc.entrySize;
