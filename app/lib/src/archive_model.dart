// The state of the archive view: the open archive, the current folder with
// its history, the sort order, the quick filter and the selection. The
// listing itself lives in ZxArchive (read in a background isolate); this
// class only derives the rows of one folder from it.

import 'package:flutter/foundation.dart';
import 'package:zx/zx.dart';

enum SortColumn { name, size, packed, ratio, modified, method, encrypted, crc }

class FolderStats {
  int files = 0;
  int size = 0;
  int packed = 0;
}

class ArchiveModel extends ChangeNotifier {
  ZxArchive _archive;
  String _dir = '';
  final List<String> _back = [];
  final List<String> _forward = [];
  final Set<String> _selection = {};
  String? _anchor;
  SortColumn _sortColumn = SortColumn.name;
  bool _ascending = true;
  String _filter = '';
  List<ZxItem>? _rows;
  Map<String, FolderStats>? _folderStats;

  /// Bumped when the archive changes on disk (for the views that cache).
  int generation = 0;

  ArchiveModel(this._archive);

  ZxArchive get archive => _archive;
  String get dir => _dir;
  SortColumn get sortColumn => _sortColumn;
  bool get ascending => _ascending;
  String get filter => _filter;
  Set<String> get selection => Set.unmodifiable(_selection);
  bool get canBack => _back.isNotEmpty;
  bool get canForward => _forward.isNotEmpty;
  bool get canUp => _dir.isNotEmpty;

  /// The rows of the current folder: folders first, then sorted, then
  /// filtered.
  List<ZxItem> get rows => _rows ??= _computeRows();

  List<ZxItem> get selectedItems => [
    for (final r in rows)
      if (_selection.contains(r.path)) r,
  ];

  /// The single selected item, or null.
  ZxItem? get focusedItem {
    final s = selectedItems;
    return s.length == 1 ? s.first : null;
  }

  /// The sub folders of [dir], sorted by name (for the tree).
  List<ZxItem> folders(String dir) {
    final l = _archive.children(dir).where((i) => i.isDir).toList()
      ..sort((a, b) => _cmpName(a.name, b.name));
    return l;
  }

  /// Sizes of everything below each folder ('' is the whole archive).
  FolderStats statsOf(String folder) {
    final m = _folderStats ??= () {
      final m = <String, FolderStats>{};
      for (final i in _archive.items) {
        if (i.isDir) continue;
        var d = i.parent;
        while (true) {
          final s = m[d] ??= FolderStats();
          s.files++;
          s.size += i.size ?? 0;
          s.packed += i.packSize ?? 0;
          if (d.isEmpty) break;
          final k = d.lastIndexOf('/');
          d = k < 0 ? '' : d.substring(0, k);
        }
      }
      return m;
    }();
    return m[folder] ?? FolderStats();
  }

  // ---- navigation ----

  void navigate(String dir, {bool record = true}) {
    if (dir == _dir) return;
    if (record) {
      _back.add(_dir);
      _forward.clear();
    }
    _setDir(dir);
  }

  void up() {
    if (!canUp) return;
    final from = _dir;
    final k = _dir.lastIndexOf('/');
    navigate(k < 0 ? '' : _dir.substring(0, k));
    // keep the folder we came from selected, as file managers do
    _selection
      ..clear()
      ..add(from);
    _anchor = from;
    notifyListeners();
  }

  void back() {
    if (!canBack) return;
    _forward.add(_dir);
    _setDir(_back.removeLast());
  }

  void forward() {
    if (!canForward) return;
    _back.add(_dir);
    _setDir(_forward.removeLast());
  }

  void _setDir(String d) {
    _dir = d;
    _filter = '';
    _selection.clear();
    _anchor = null;
    _rows = null;
    notifyListeners();
  }

  // ---- sort and filter ----

  void sortBy(SortColumn c) {
    if (c == _sortColumn) {
      _ascending = !_ascending;
    } else {
      _sortColumn = c;
      _ascending = true;
    }
    _rows = null;
    notifyListeners();
  }

  set filter(String f) {
    if (f == _filter) return;
    _filter = f;
    _rows = null;
    _selection.removeWhere((s) => !rows.any((r) => r.path == s));
    notifyListeners();
  }

  // ---- selection ----

  /// A click on [item]: alone, with ctrl (toggle) or shift (range).
  void click(ZxItem item, {bool ctrl = false, bool shift = false}) {
    if (shift && _anchor != null) {
      final r = rows;
      final a = r.indexWhere((x) => x.path == _anchor);
      final b = r.indexWhere((x) => x.path == item.path);
      if (a >= 0 && b >= 0) {
        if (!ctrl) _selection.clear();
        for (var k = a < b ? a : b; k <= (a < b ? b : a); k++) {
          _selection.add(r[k].path);
        }
        notifyListeners();
        return;
      }
    }
    if (ctrl) {
      if (!_selection.remove(item.path)) _selection.add(item.path);
    } else {
      _selection
        ..clear()
        ..add(item.path);
    }
    _anchor = item.path;
    notifyListeners();
  }

  /// Selects [item] unless it is selected already (right click).
  void ensureSelected(ZxItem item) {
    if (_selection.contains(item.path)) return;
    click(item);
  }

  void selectAll() {
    _selection
      ..clear()
      ..addAll(rows.map((r) => r.path));
    notifyListeners();
  }

  void clearSelection() {
    if (_selection.isEmpty) return;
    _selection.clear();
    _anchor = null;
    notifyListeners();
  }

  void selectPaths(Iterable<String> paths) {
    _selection
      ..clear()
      ..addAll(paths);
    _anchor = _selection.isEmpty ? null : _selection.first;
    notifyListeners();
  }

  /// Arrow keys: moves the focus row by [delta], extending with [shift].
  void moveSelection(int delta, {bool shift = false}) {
    final r = rows;
    if (r.isEmpty) return;
    var cur = _lastIndex();
    final next = cur < 0 ? 0 : (cur + delta).clamp(0, r.length - 1);
    if (shift) {
      _anchor ??= r[cur < 0 ? 0 : cur].path;
      final a = r.indexWhere((x) => x.path == _anchor);
      _selection.clear();
      for (var k = a < next ? a : next; k <= (a < next ? next : a); k++) {
        _selection.add(r[k].path);
      }
      _cursor = r[next].path;
    } else {
      _selection
        ..clear()
        ..add(r[next].path);
      _anchor = r[next].path;
      _cursor = r[next].path;
    }
    notifyListeners();
  }

  String? _cursor;

  /// The row the keyboard is on.
  int get cursorIndex => _lastIndex();

  int _lastIndex() {
    final r = rows;
    final c = _cursor != null && _selection.contains(_cursor)
        ? _cursor
        : _anchor;
    if (c == null) return -1;
    return r.indexWhere((x) => x.path == c);
  }

  // ---- after changes ----

  /// The archive was written or read again: keeps the folder when it
  /// still exists and the selection that is still there.
  void refresh({ZxArchive? archive, Iterable<String>? select}) {
    if (archive != null) _archive = archive;
    generation++;
    _rows = null;
    _folderStats = null;
    while (_dir.isNotEmpty && _archive[_dir] == null) {
      final k = _dir.lastIndexOf('/');
      _dir = k < 0 ? '' : _dir.substring(0, k);
    }
    _back.removeWhere((d) => d.isNotEmpty && _archive[d] == null);
    _forward.removeWhere((d) => d.isNotEmpty && _archive[d] == null);
    if (select != null) {
      _selection
        ..clear()
        ..addAll(select);
    }
    _selection.removeWhere((s) => _archive[s] == null);
    notifyListeners();
  }

  // ---- rows ----

  List<ZxItem> _computeRows() {
    var l = _archive.children(_dir).toList();
    if (_filter.isNotEmpty) {
      final f = _filter.toLowerCase();
      l = l.where((i) => i.name.toLowerCase().contains(f)).toList();
    }
    int cmp(ZxItem a, ZxItem b) {
      int c;
      switch (_sortColumn) {
        case SortColumn.name:
          c = 0;
        case SortColumn.size:
          c = _size(a).compareTo(_size(b));
        case SortColumn.packed:
          c = _packed(a).compareTo(_packed(b));
        case SortColumn.ratio:
          c = (ratioOf(a) ?? -1).compareTo(ratioOf(b) ?? -1);
        case SortColumn.modified:
          c = (a.modified?.millisecondsSinceEpoch ?? 0).compareTo(
            b.modified?.millisecondsSinceEpoch ?? 0,
          );
        case SortColumn.method:
          c = (a.method ?? '').compareTo(b.method ?? '');
        case SortColumn.encrypted:
          c = (a.encrypted ? 1 : 0).compareTo(b.encrypted ? 1 : 0);
        case SortColumn.crc:
          c = (a.crc ?? -1).compareTo(b.crc ?? -1);
      }
      if (c == 0) c = _cmpName(a.name, b.name);
      return _ascending ? c : -c;
    }

    l.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return cmp(a, b);
    });
    return l;
  }

  int _size(ZxItem i) => i.isDir ? statsOf(i.path).size : (i.size ?? 0);
  int _packed(ZxItem i) => i.isDir ? statsOf(i.path).packed : (i.packSize ?? 0);

  /// Packed size over size, when both are known.
  double? ratioOf(ZxItem i) {
    final s = _size(i);
    final pk = _packed(i);
    if (s <= 0 || (!i.isDir && i.packSize == null) || (i.isDir && pk == 0)) {
      return null;
    }
    // in a solid block the first item carries the packed size of the
    // whole block (as 7-Zip lists it): no ratio of its own
    if (_archive.solid && pk > s) return null;
    return pk / s;
  }

  int sizeOf(ZxItem i) => _size(i);
  int? packedOf(ZxItem i) {
    if (i.isDir) {
      final p = statsOf(i.path).packed;
      return p == 0 ? null : p;
    }
    return i.packSize;
  }
}

int _cmpName(String a, String b) {
  final c = a.toLowerCase().compareTo(b.toLowerCase());
  return c != 0 ? c : a.compareTo(b);
}
