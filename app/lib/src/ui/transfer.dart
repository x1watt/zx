// What copy, cut and drag carry between the views of the explorer: files
// of the file system, or items of an open archive (with the level they
// belong to, which stays open while the clipboard holds them).

import '../archive_model.dart';

class Transfer {
  /// Paths of the file system (empty for archive items).
  final List<String> fsPaths;

  /// The archive level of [items], null for file system paths.
  final ArchiveModel? model;

  /// Paths of items of [model].
  final List<String> items;

  /// The folder of [model] the items were taken from (their paths are
  /// kept relative to it).
  final String relDir;

  /// Cut (moved at the paste) rather than copied.
  final bool cut;

  const Transfer.files(this.fsPaths, {this.cut = false})
    : model = null,
      items = const [],
      relDir = '';

  const Transfer.archive(
    ArchiveModel this.model,
    this.items,
    this.relDir, {
    this.cut = false,
  }) : fsPaths = const [];

  bool get fromArchive => model != null;
  int get count => fromArchive ? items.length : fsPaths.length;
  bool get isEmpty => count == 0;

  String get label => '$count item${count == 1 ? '' : 's'}';
}
