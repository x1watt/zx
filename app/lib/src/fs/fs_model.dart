// The state of the file system view of the explorer: the folder shown
// with its history, the listing (read in a worker isolate), sort, hidden
// files, the quick filter, the recursive search and the selection.

import 'dart:async';
import 'dart:io' show FileSystemException;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'fs_ops.dart';

enum FsSort { name, size, type, modified }

typedef FsLister = Future<List<FsEntry>> Function(String dir);

class FsModel extends ChangeNotifier {
  final FsLister lister;
  int? Function(String path)? folderSizeResolver;
  String _dir;
  final List<String> _back = [];
  final List<String> _forward = [];
  List<FsEntry> _entries = const [];
  final Map<String, FsEntry> _entryByPath = {};
  bool _loading = false;
  String? _error;
  int _token = 0;
  Future<void> _idle = Future.value();

  FsSort _sort = FsSort.name;
  bool _ascending = true;
  bool _showHidden = false;
  String _filter = '';
  List<FsEntry>? _rows;

  final Set<String> _selection = {};
  String? _anchor;
  String? _cursor;

  // the recursive search
  FsSearch? _search;
  List<FsEntry>? _results;
  bool _searching = false;
  String _query = '';

  FsModel(this._dir, {this.lister = listDirectory});

  String get dir => _dir;
  bool get loading => _loading;
  String? get error => _error;

  /// Completes when the listing being read is shown.
  Future<void> get idle => _idle;
  FsSort get sort => _sort;
  bool get ascending => _ascending;
  bool get showHidden => _showHidden;
  String get filter => _filter;
  bool get canBack => _back.isNotEmpty;
  bool get canForward => _forward.isNotEmpty;
  bool get canUp => p.dirname(_dir) != _dir;

  /// The results of a recursive search are shown instead of the folder.
  bool get inSearch => _results != null;

  /// Looks up an item from the current or recursive-search listing in O(1).
  FsEntry? entry(String path) => _entryByPath[path];

  /// Size of a file, or its indexed recursive size for a folder.
  int sizeOf(FsEntry entry) =>
      entry.isDir ? folderSizeResolver?.call(entry.path) ?? 0 : entry.size;

  /// Redraws size columns and totals when the background index changes.
  void refreshIndexedSizes() => notifyListeners();

  bool get searching => _searching;
  String get query => _query;

  Set<String> get selection => Set.unmodifiable(_selection);

  // ---- navigation ----

  /// Shows [dir] (read again when it is the current one).
  Future<void> navigate(String dir, {bool record = true}) {
    final d = p.normalize(dir);
    if (d != _dir && record) {
      _back.add(_dir);
      _forward.clear();
    }
    return _setDir(d);
  }

  Future<void> up() {
    if (!canUp) return Future.value();
    final from = _dir;
    return navigate(p.dirname(_dir)).then((_) {
      if (_entries.any((e) => e.path == from)) selectPaths([from]);
    });
  }

  Future<void> back() {
    if (!canBack) return Future.value();
    _forward.add(_dir);
    return _setDir(_back.removeLast());
  }

  Future<void> forward() {
    if (!canForward) return Future.value();
    _back.add(_dir);
    return _setDir(_forward.removeLast());
  }

  Future<void> _setDir(String d) {
    stopSearch(notify: false);
    final changed = d != _dir;
    _dir = d;
    if (changed) {
      _filter = '';
      _selection.clear();
      _anchor = _cursor = null;
      _entries = const [];
      _entryByPath.clear();
    }
    return reload();
  }

  /// Reads the folder again, keeping the selection that is still there
  /// (or selecting [select]).
  Future<void> reload({Iterable<String>? select}) {
    final t = ++_token;
    _loading = true;
    _error = null;
    _rows = null;
    notifyListeners();
    final f = () async {
      List<FsEntry> l;
      String? err;
      try {
        l = await lister(_dir);
      } on FileSystemException catch (e) {
        l = const [];
        err = e.osError?.message ?? e.message;
      }
      if (t != _token) return;
      _entries = l;
      _entryByPath
        ..clear()
        ..addEntries(l.map((e) => MapEntry(e.path, e)));
      _error = err;
      _loading = false;
      _rows = null;
      if (select != null) {
        _selection
          ..clear()
          ..addAll(select);
      }
      final have = {for (final e in l) e.path};
      _selection.removeWhere((s) => !have.contains(s));
      notifyListeners();
    }();
    _idle = f;
    return f;
  }

  // ---- sort, hidden, filter ----

  void sortBy(FsSort s) {
    if (s == _sort) {
      _ascending = !_ascending;
    } else {
      _sort = s;
      _ascending = true;
    }
    _rows = null;
    notifyListeners();
  }

  set showHidden(bool v) {
    if (v == _showHidden) return;
    _showHidden = v;
    _rows = null;
    _selection.removeWhere((s) => !rows.any((r) => r.path == s));
    notifyListeners();
  }

  set filter(String f) {
    if (f == _filter) return;
    _filter = f;
    _rows = null;
    _selection.removeWhere((s) => !rows.any((r) => r.path == s));
    notifyListeners();
  }

  /// The rows shown: folders first, sorted, filtered (or the search
  /// results).
  List<FsEntry> get rows => _rows ??= _compute();

  List<FsEntry> _compute() {
    var l = (_results ?? _entries).where((e) => _showHidden || !e.hidden);
    if (_filter.isNotEmpty && _results == null) {
      final f = _filter.toLowerCase();
      l = l.where((e) => e.name.toLowerCase().contains(f));
    }
    final out = l.toList();
    int cmp(FsEntry a, FsEntry b) {
      int c;
      switch (_sort) {
        case FsSort.name:
          c = 0;
        case FsSort.size:
          c = sizeOf(a).compareTo(sizeOf(b));
        case FsSort.type:
          c = typeOf(a).compareTo(typeOf(b));
        case FsSort.modified:
          c = (a.modified?.millisecondsSinceEpoch ?? 0).compareTo(
            b.modified?.millisecondsSinceEpoch ?? 0,
          );
      }
      if (c == 0) c = compareNames(a.name, b.name);
      return _ascending ? c : -c;
    }

    // Folders keep their name order: the size of a folder is only known
    // from the background index, so sorting on it would jump around while
    // a scan is still filling the totals in.
    out.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      if (a.isDir) return compareNames(a.name, b.name);
      return cmp(a, b);
    });
    return out;
  }

  // ---- recursive search ----

  /// Searches the names below the current folder (a worker isolate);
  /// the results replace the rows as they come.
  Future<void> startSearch(String query) async {
    stopSearch(notify: false);
    if (query.isEmpty) {
      notifyListeners();
      return;
    }
    final s = FsSearch(_dir, query, showHidden: _showHidden);
    _search = s;
    _query = query;
    _results = [];
    _searching = true;
    _selection.clear();
    _rows = null;
    notifyListeners();
    final done = Completer<void>();
    s.results.listen(
      (batch) {
        if (_search != s) return;
        _results!.addAll(batch);
        _entryByPath.addEntries(batch.map((e) => MapEntry(e.path, e)));
        _rows = null;
        notifyListeners();
      },
      onDone: () {
        if (_search == s) {
          _searching = false;
          notifyListeners();
        }
        if (!done.isCompleted) done.complete();
      },
    );
    await s.start();
    await done.future;
  }

  /// Stops the search (the results stay) when [keepResults], else shows
  /// the folder again.
  void stopSearch({bool keepResults = false, bool notify = true}) {
    _search?.cancel();
    _search = null;
    _searching = false;
    if (!keepResults) {
      _results = null;
      _query = '';
      _entryByPath
        ..clear()
        ..addEntries(_entries.map((e) => MapEntry(e.path, e)));
    }
    _rows = null;
    if (notify) notifyListeners();
  }

  // ---- selection ----

  List<FsEntry> get selectedEntries => [
    for (final r in rows)
      if (_selection.contains(r.path)) r,
  ];

  int get cursorIndex {
    final c = _cursor != null && _selection.contains(_cursor)
        ? _cursor
        : _anchor;
    if (c == null) return -1;
    return rows.indexWhere((x) => x.path == c);
  }

  void click(FsEntry e, {bool ctrl = false, bool shift = false}) {
    final r = rows;
    if (shift && _anchor != null) {
      final a = r.indexWhere((x) => x.path == _anchor);
      final b = r.indexWhere((x) => x.path == e.path);
      if (a >= 0 && b >= 0) {
        if (!ctrl) _selection.clear();
        for (var k = a < b ? a : b; k <= (a < b ? b : a); k++) {
          _selection.add(r[k].path);
        }
        _cursor = e.path;
        notifyListeners();
        return;
      }
    }
    if (ctrl) {
      if (!_selection.remove(e.path)) _selection.add(e.path);
    } else {
      _selection
        ..clear()
        ..add(e.path);
    }
    _anchor = _cursor = e.path;
    notifyListeners();
  }

  /// Adds or removes [e] (the selection mode of a touch screen).
  void toggle(FsEntry e) => click(e, ctrl: true);

  void ensureSelected(FsEntry e) {
    if (_selection.contains(e.path)) return;
    click(e);
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
    _anchor = _cursor = null;
    notifyListeners();
  }

  void selectPaths(Iterable<String> paths) {
    _selection
      ..clear()
      ..addAll(paths);
    _anchor = _cursor = _selection.isEmpty ? null : _selection.first;
    notifyListeners();
  }

  void moveSelection(int delta, {bool shift = false}) {
    final r = rows;
    if (r.isEmpty) return;
    final cur = cursorIndex;
    final next = cur < 0 ? 0 : (cur + delta).clamp(0, r.length - 1);
    if (shift) {
      _anchor ??= r[cur < 0 ? 0 : cur].path;
      final a = r.indexWhere((x) => x.path == _anchor);
      _selection.clear();
      for (var k = a < next ? a : next; k <= (a < next ? next : a); k++) {
        _selection.add(r[k].path);
      }
    } else {
      _selection
        ..clear()
        ..add(r[next].path);
      _anchor = r[next].path;
    }
    _cursor = r[next].path;
    notifyListeners();
  }

  @override
  void dispose() {
    _search?.cancel();
    super.dispose();
  }
}

/// Case-insensitive name order, with numbers in their natural order
/// ("file2" before "file10").
int compareNames(String a, String b) {
  final x = a.toLowerCase(), y = b.toLowerCase();
  var i = 0, j = 0;
  while (i < x.length && j < y.length) {
    final cx = x.codeUnitAt(i), cy = y.codeUnitAt(j);
    if (_digit(cx) && _digit(cy)) {
      var ie = i, je = j;
      while (ie < x.length && _digit(x.codeUnitAt(ie))) {
        ie++;
      }
      while (je < y.length && _digit(y.codeUnitAt(je))) {
        je++;
      }
      final nx = x.substring(i, ie).replaceFirst(RegExp('^0+'), '');
      final ny = y.substring(j, je).replaceFirst(RegExp('^0+'), '');
      if (nx.length != ny.length) return nx.length - ny.length;
      final c = nx.compareTo(ny);
      if (c != 0) return c;
      i = ie;
      j = je;
      continue;
    }
    if (cx != cy) return cx - cy;
    i++;
    j++;
  }
  final c = (x.length - i) - (y.length - j);
  return c != 0 ? c : a.compareTo(b);
}

bool _digit(int c) => c >= 48 && c <= 57;

/// A short type for the Type column: "Folder", "PNG file", "File".
String typeOf(FsEntry e) {
  if (e.isDir) return 'Folder';
  final k = e.name.lastIndexOf('.');
  if (k <= 0 || k == e.name.length - 1) return 'File';
  return '${e.name.substring(k + 1).toUpperCase()} file';
}
