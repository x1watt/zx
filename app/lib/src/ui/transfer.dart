// What copy, cut and drag carry between the views of the explorer: files
// of the file system, or items of an open archive (with the level they
// belong to, which stays open while the clipboard holds them).

import '../archive_model.dart';

class Transfer {
  final List<String> _fsPaths;
  final ArchiveModel? _model;
  final List<String> _items;
  final String _relDir;
  final bool _cut;
  final bool _fromArchive;
  final int Function()? _count;
  final Transfer Function()? _resolve;
  Transfer? _resolved;

  /// Paths of the file system (empty for archive items).
  List<String> get fsPaths => _value._fsPaths;

  /// The archive level of [items], null for file system paths.
  ArchiveModel? get model => _value._model;

  /// Paths of items of [model].
  List<String> get items => _value._items;

  /// The folder of [model] the items were taken from (their paths are
  /// kept relative to it).
  String get relDir => _value._relDir;

  /// Cut (moved at the paste) rather than copied.
  bool get cut => _value._cut;

  Transfer.files(List<String> fsPaths, {this._cut = false})
    : _fsPaths = fsPaths,
      _model = null,
      _items = const [],
      _relDir = '',
      _fromArchive = false,
      _count = null,
      _resolve = null;

  Transfer.archive(
    ArchiveModel model,
    List<String> items,
    String relDir, {
    this._cut = false,
  }) : _fsPaths = const [],
       _model = model,
       _items = items,
       _relDir = relDir,
       _fromArchive = true,
       _count = null,
       _resolve = null;

  /// Holds a small proxy for drag feedback; selected paths are copied only
  /// if a drop target asks for the payload.
  Transfer.deferred({
    required this._fromArchive,
    required this._count,
    required this._resolve,
  }) : _fsPaths = const [],
       _model = null,
       _items = const [],
       _relDir = '',
       _cut = false;

  Transfer get _value {
    if (_resolve == null) return this;
    final value = _resolved;
    if (value != null) return value;
    return _resolved = _resolve();
  }

  bool get fromArchive => _fromArchive;
  int get count =>
      _count?.call() ?? (_model != null ? _items.length : _fsPaths.length);
  bool get isEmpty => count == 0;

  String get label => '$count item${count == 1 ? '' : 's'}';
}
