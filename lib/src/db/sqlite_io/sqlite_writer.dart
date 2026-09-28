// A writer of SQLite database files (https://www.sqlite.org/fileformat2.html)
// without the SQLite library: UTF-8, schema format 4, no freelist, no
// auto-vacuum. Table b-trees are built bottom up from rows given in rowid
// order (leaves are written as they fill); index b-trees from records
// sorted by the caller. Large payloads spill to overflow pages.

import 'dart:io';
import 'dart:typed_data';

import 'sqlite_format.dart';

/// Builds a SQLite file page by page.
class SqliteFileWriter {
  final int pageSize;
  final RandomAccessFile _f;
  int _next = 2; // page 1 is written by finish()
  bool _done = false;

  SqliteFileWriter._(this._f, this.pageSize);

  /// Creates (or truncates) the file at [path].
  factory SqliteFileWriter.create(String path, {int pageSize = 4096}) {
    if (pageSize < 512 || pageSize > 65536 || pageSize & (pageSize - 1) != 0) {
      throw ArgumentError('bad page size $pageSize');
    }
    final f = File(path).openSync(mode: FileMode.write);
    f.truncateSync(0);
    return SqliteFileWriter._(f, pageSize);
  }

  int get usable => pageSize;

  /// Pages allocated so far (the database size once finished).
  int get pageCount => _next - 1;

  int _alloc() => _next++;

  void _write(int n, Uint8List data) {
    _f.setPositionSync((n - 1) * pageSize);
    _f.writeFromSync(data);
  }

  // writes the overflow pages of payload bytes [from..] and returns the
  // first page number
  int _overflow(Uint8List payload, int from) {
    final per = usable - 4;
    final n = (payload.length - from + per - 1) ~/ per;
    final pages = [for (var i = 0; i < n; i++) _alloc()];
    for (var i = 0; i < n; i++) {
      final pg = Uint8List(pageSize);
      final bd = ByteData.sublistView(pg);
      bd.setUint32(0, i + 1 < n ? pages[i + 1] : 0);
      final s = from + i * per;
      final e = s + per < payload.length ? s + per : payload.length;
      pg.setRange(4, 4 + e - s, payload, s);
      _write(pages[i], pg);
    }
    return pages[0];
  }

  // size of a cell holding [payload] (without the child pointer or rowid)
  int _payloadCellSize(int p, bool tableLeaf) {
    final local = localPayload(p, usable, tableLeaf: tableLeaf);
    return varintLength(p) + local + (local < p ? 4 : 0);
  }

  // the cell bytes after the prefix: size varint, [rowid], local, overflow
  Uint8List _payloadCell(Uint8List payload, bool tableLeaf,
      {int? rowid, int prefix = 0}) {
    final p = payload.length;
    final local = localPayload(p, usable, tableLeaf: tableLeaf);
    final n = prefix +
        varintLength(p) +
        (rowid == null ? 0 : varintLength(rowid)) +
        local +
        (local < p ? 4 : 0);
    final out = Uint8List(n);
    var o = prefix + writeVarint(out, prefix, p);
    if (rowid != null) o += writeVarint(out, o, rowid);
    out.setRange(o, o + local, payload);
    o += local;
    if (local < p) {
      ByteData.sublistView(out).setUint32(o, _overflow(payload, local));
    }
    return out;
  }

  // lays out a b-tree page: [flag] 13 table leaf, 5 table interior,
  // 10 index leaf, 2 index interior
  Uint8List _page(int flag, List<Uint8List> cells,
      {int rightChild = 0, int top = 0, Uint8List? into}) {
    final pg = into ?? Uint8List(pageSize);
    final bd = ByteData.sublistView(pg);
    final interior = flag == 5 || flag == 2;
    final hdr = interior ? 12 : 8;
    var end = usable;
    pg[top] = flag;
    bd.setUint16(top + 1, 0);
    bd.setUint16(top + 3, cells.length);
    for (var i = 0; i < cells.length; i++) {
      final c = cells[i];
      final sz = c.length < 4 ? 4 : c.length;
      end -= sz;
      pg.setRange(end, end + c.length, c);
      bd.setUint16(top + hdr + 2 * i, end);
    }
    if (top + hdr + 2 * cells.length > end) {
      throw StateError('b-tree page overflow');
    }
    bd.setUint16(top + 5, end == 65536 ? 0 : end);
    pg[top + 7] = 0;
    if (interior) bd.setUint32(top + 8, rightChild);
    return pg;
  }

  static int _cost(int cellLen) => (cellLen < 4 ? 4 : cellLen) + 2;

  /// A builder of a table b-tree; rows must come in rowid order. With
  /// [page1] the root is page 1 (the schema table).
  SqliteTableTreeBuilder table({bool page1 = false}) =>
      SqliteTableTreeBuilder._(this, page1);

  /// Writes an index b-tree (or a WITHOUT ROWID table) holding the
  /// records [sorted] (in key order); returns its root page.
  int index(List<Uint8List> sorted) {
    final cap = usable - 12; // interior header; leaves have 4 more
    final leafCap = usable - 8;
    // leaf level: leaves separated by entries that move up
    final children = <int>[];
    final seps = <Uint8List>[];
    var cells = <Uint8List>[];
    var used = 0;
    var i = 0;
    while (i < sorted.length) {
      final r = sorted[i];
      final c = _cost(_payloadCellSize(r.length, false));
      if (cells.isNotEmpty && used + c > leafCap) {
        // close this leaf; the next entry is the separator
        final pg = _alloc();
        _write(pg, _page(10, cells));
        children.add(pg);
        seps.add(r);
        cells = [];
        used = 0;
        i++;
        continue;
      }
      cells.add(_payloadCell(r, false));
      used += c;
      i++;
    }
    if (children.isEmpty) {
      final root = _alloc();
      _write(root, _page(10, cells));
      return root;
    }
    if (cells.isEmpty) {
      // the last entry became a separator: it is the last leaf instead
      cells.add(_payloadCell(seps.removeLast(), false));
    }
    final pg = _alloc();
    _write(pg, _page(10, cells));
    children.add(pg);
    return _indexInterior(children, seps, cap);
  }

  int _indexInterior(List<int> children, List<Uint8List> seps, int cap) {
    while (true) {
      // does the level fit in one page?
      var all = 0;
      for (final s in seps) {
        all += _cost(4 + _payloadCellSize(s.length, false));
      }
      if (all <= cap) {
        final root = _alloc();
        _write(
            root,
            _page(2, [
              for (var k = 0; k < seps.length; k++)
                _cellWithChild(children[k], seps[k])
            ], rightChild: children.last));
        return root;
      }
      // groups: (first child, last child) ranges; separators between
      // groups move up
      final groups = <(int, int)>[];
      var start = 0;
      var used = 0;
      for (var k = 0; k < seps.length; k++) {
        final c = _cost(4 + _payloadCellSize(seps[k].length, false));
        if (k > start && used + c > cap) {
          groups.add((start, k)); // cells start..k-1, right child k
          start = k + 1; // seps[k] moves up
          used = 0;
          continue;
        }
        used += c;
      }
      groups.add((start, children.length - 1));
      if (groups.last.$1 == groups.last.$2) {
        // one child only: take the last cell of the previous group
        final (ps, pe) = groups[groups.length - 2];
        groups[groups.length - 2] = (ps, pe - 1);
        groups[groups.length - 1] = (pe, children.length - 1);
      }
      final nc = <int>[];
      final ns = <Uint8List>[];
      for (var g = 0; g < groups.length; g++) {
        final (s, e) = groups[g];
        final pg = _alloc();
        _write(
            pg,
            _page(2, [
              for (var k = s; k < e; k++) _cellWithChild(children[k], seps[k])
            ], rightChild: children[e]));
        nc.add(pg);
        if (g + 1 < groups.length) ns.add(seps[e]);
      }
      children = nc;
      seps = ns;
    }
  }

  Uint8List _cellWithChild(int child, Uint8List payload) {
    final c = _payloadCell(payload, false, prefix: 4);
    ByteData.sublistView(c).setUint32(0, child);
    return c;
  }

  /// Writes page 1 (header and the schema root, already placed by the
  /// schema builder's [finish]) and closes the file.
  void finish(Uint8List page1, {int userVersion = 0}) {
    if (_done) return;
    _done = true;
    final bd = ByteData.sublistView(page1);
    page1.setRange(0, 16, sqliteMagic);
    bd.setUint16(16, pageSize == 65536 ? 1 : pageSize);
    page1[18] = 1;
    page1[19] = 1;
    page1[20] = 0;
    page1[21] = 64;
    page1[22] = 32;
    page1[23] = 32;
    bd.setUint32(24, 1); // file change counter
    bd.setUint32(28, pageCount);
    bd.setUint32(32, 0);
    bd.setUint32(36, 0);
    bd.setUint32(40, 1); // schema cookie
    bd.setUint32(44, 4); // schema format
    bd.setUint32(48, 0);
    bd.setUint32(52, 0);
    bd.setUint32(56, 1); // UTF-8
    bd.setInt32(60, userVersion);
    bd.setUint32(64, 0);
    bd.setUint32(68, 0);
    bd.setUint32(92, 1); // version-valid-for
    bd.setUint32(96, sqliteVersionNumber);
    _write(1, page1);
    _f.truncateSync(pageCount * pageSize);
    _f.closeSync();
  }

  /// Closes the file without finishing it.
  void abort() {
    if (_done) return;
    _done = true;
    _f.closeSync();
  }
}

/// Builds one table b-tree from rows in rowid order.
class SqliteTableTreeBuilder {
  final SqliteFileWriter _w;
  final bool _page1;
  final List<(int, int)> _children = []; // (page, max rowid)
  List<Uint8List> _cells = [];
  int _used = 0;
  int _last = 0;
  Uint8List? _rootPage;

  SqliteTableTreeBuilder._(this._w, this._page1);

  int get _top => _page1 ? 100 : 0;

  /// Adds a row; [record] is an encoded record.
  void add(int rowid, Uint8List record) {
    final cell = _w._payloadCell(record, true, rowid: rowid);
    final c = SqliteFileWriter._cost(cell.length);
    if (_cells.isNotEmpty && _used + c > _w.usable - 8 - _top) _flush();
    _cells.add(cell);
    _used += c;
    _last = rowid;
  }

  void _flush() {
    final pg = _w._alloc();
    _w._write(pg, _w._page(13, _cells));
    _children.add((pg, _last));
    _cells = [];
    _used = 0;
  }

  /// Writes what is left; returns the root page (1 with page1, whose
  /// bytes are then in [page1Bytes]).
  int finish() {
    if (_children.isEmpty) {
      return _root((root, into) =>
          _w._page(13, _cells, top: root == 1 ? 100 : 0, into: into));
    }
    _flush();
    var level = _children;
    final cap = _w.usable - 12 - _top;
    while (true) {
      var all = 0;
      for (var k = 0; k < level.length - 1; k++) {
        all += SqliteFileWriter._cost(4 + varintLength(level[k].$2));
      }
      if (all <= cap) {
        final l = level;
        return _root((root, into) => _w._page(
            5,
            [for (var k = 0; k < l.length - 1; k++) _cell(l[k])],
            rightChild: l.last.$1,
            top: root == 1 ? 100 : 0,
            into: into));
      }
      final groups = <List<(int, int)>>[];
      var g = <(int, int)>[];
      var used = 0;
      for (final ch in level) {
        final c = SqliteFileWriter._cost(4 + varintLength(ch.$2));
        if (g.isNotEmpty && used + c > cap) {
          groups.add(g);
          g = [];
          used = 0;
        }
        g.add(ch);
        used += c;
      }
      groups.add(g);
      if (groups.last.length == 1 && groups.length > 1) {
        groups.last.insert(0, groups[groups.length - 2].removeLast());
      }
      final next = <(int, int)>[];
      for (final gr in groups) {
        final pg = _w._alloc();
        _w._write(
            pg,
            _w._page(5, [for (var k = 0; k < gr.length - 1; k++) _cell(gr[k])],
                rightChild: gr.last.$1));
        next.add((pg, gr.last.$2));
      }
      level = next;
    }
  }

  Uint8List _cell((int, int) ch) {
    final c = Uint8List(4 + varintLength(ch.$2));
    ByteData.sublistView(c).setUint32(0, ch.$1);
    writeVarint(c, 4, ch.$2);
    return c;
  }

  int _root(Uint8List Function(int root, Uint8List? into) make) {
    if (_page1) {
      _rootPage = make(1, Uint8List(_w.pageSize));
      return 1;
    }
    final root = _w._alloc();
    _w._write(root, make(root, null));
    return root;
  }

  /// Page 1 as built by [finish] (with page1), the header still empty.
  Uint8List get page1Bytes => _rootPage!;
}
