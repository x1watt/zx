// The file list of the current folder: sortable columns, multi selection
// with ctrl and shift, double click, context menu. Rows are built lazily.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:zx/zx.dart';

import '../archive_model.dart';
import 'format_utils.dart';
import 'transfer.dart';
import 'views.dart' show DragSourceItem, FolderDropTarget;

const double kRowHeight = 26;

class ColumnSpec {
  final SortColumn column;
  final String label;

  /// Fixed width, or null for the flexible name column.
  final double? width;
  final bool alignEnd;
  const ColumnSpec(
    this.column,
    this.label,
    this.width, {
    this.alignEnd = false,
  });
}

const kColumns = <ColumnSpec>[
  ColumnSpec(SortColumn.name, 'Name', null),
  ColumnSpec(SortColumn.size, 'Size', 92, alignEnd: true),
  ColumnSpec(SortColumn.packed, 'Packed', 92, alignEnd: true),
  ColumnSpec(SortColumn.ratio, 'Ratio', 60, alignEnd: true),
  ColumnSpec(SortColumn.modified, 'Modified', 136),
  ColumnSpec(SortColumn.method, 'Method', 112),
  ColumnSpec(SortColumn.encrypted, 'Enc.', 44),
  ColumnSpec(SortColumn.crc, 'CRC', 84),
];

class FileList extends StatefulWidget {
  final ArchiveModel model;
  final FocusNode focusNode;
  final void Function(ZxItem item) onOpen;
  final void Function(ZxItem? item, Offset globalPosition) onContextMenu;

  /// What a drag of an item carries (null: no drag).
  final Transfer? Function(ZxItem item)? dragData;

  /// A drop on the folder [folder] (null: the folder shown).
  final void Function(ZxItem? folder, Transfer t)? onDrop;

  const FileList({
    super.key,
    required this.model,
    required this.focusNode,
    required this.onOpen,
    required this.onContextMenu,
    this.dragData,
    this.onDrop,
  });

  @override
  State<FileList> createState() => _FileListState();
}

class _FileListState extends State<FileList> {
  final _scroll = ScrollController();
  final _clock = Stopwatch()..start();
  String? _lastClickPath;
  int _lastClickMs = -100000;

  @override
  void initState() {
    super.initState();
    widget.model.addListener(_onModel);
  }

  @override
  void didUpdateWidget(FileList old) {
    super.didUpdateWidget(old);
    if (old.model != widget.model) {
      old.model.removeListener(_onModel);
      widget.model.addListener(_onModel);
    }
  }

  @override
  void dispose() {
    widget.model.removeListener(_onModel);
    _scroll.dispose();
    super.dispose();
  }

  String _lastDir = '';

  void _onModel() {
    final m = widget.model;
    if (m.dir != _lastDir) {
      _lastDir = m.dir;
      if (_scroll.hasClients) _scroll.jumpTo(0);
    } else {
      _ensureVisible(m.cursorIndex);
    }
  }

  void _ensureVisible(int i) {
    if (i < 0 || !_scroll.hasClients) return;
    final pos = _scroll.position;
    final top = i * kRowHeight;
    if (top < pos.pixels) {
      _scroll.jumpTo(top);
    } else if (top + kRowHeight > pos.pixels + pos.viewportDimension) {
      _scroll.jumpTo(top + kRowHeight - pos.viewportDimension);
    }
  }

  bool _rowHit = false;

  void _pointerDown(PointerDownEvent e, ZxItem item) {
    _rowHit = true;
    widget.focusNode.requestFocus();
    final m = widget.model;
    if (e.buttons == kSecondaryMouseButton) {
      m.ensureSelected(item);
      widget.onContextMenu(item, e.position);
      return;
    }
    if (e.buttons != kPrimaryMouseButton) return;
    final kb = HardwareKeyboard.instance;
    final now = _clock.elapsedMilliseconds;
    final isDouble =
        _lastClickPath == item.path &&
        now - _lastClickMs < kDoubleTapTimeout.inMilliseconds + 100 &&
        !kb.isControlPressed &&
        !kb.isShiftPressed;
    _lastClickPath = item.path;
    _lastClickMs = isDouble ? -100000 : now;
    if (isDouble) {
      widget.onOpen(item);
      return;
    }
    m.click(
      item,
      ctrl: kb.isControlPressed || kb.isMetaPressed,
      shift: kb.isShiftPressed,
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: widget.model,
      builder: (context, _) {
        final m = widget.model;
        final rows = m.rows;
        final sel = m.selection;
        return LayoutBuilder(
          builder: (context, box) {
            final cols = visibleColumns(box.maxWidth);
            return Column(
              children: [
                _Header(model: m, columns: cols),
                Divider(height: 1, color: cs.outlineVariant),
                Expanded(
                  child: Listener(
                    behavior: HitTestBehavior.opaque,
                    // after the row's listener: a click on the empty area
                    // clears the selection, a right click there shows the menu
                    onPointerDown: (e) {
                      final onRow = _rowHit;
                      _rowHit = false;
                      if (onRow) return;
                      widget.focusNode.requestFocus();
                      m.clearSelection();
                      if (e.buttons == kSecondaryMouseButton) {
                        widget.onContextMenu(null, e.position);
                      }
                    },
                    child: _dropHere(
                      rows.isEmpty
                          ? _EmptyHint(filtered: m.filter.isNotEmpty)
                          : Scrollbar(
                              controller: _scroll,
                              thumbVisibility: true,
                              child: ListView.builder(
                                key: const Key('file-list'),
                                controller: _scroll,
                                itemExtent: kRowHeight,
                                itemCount: rows.length,
                                itemBuilder: (context, i) {
                                  final item = rows[i];
                                  Widget row = _Row(
                                    key: ValueKey('row:${item.path}'),
                                    columns: cols,
                                    model: m,
                                    item: item,
                                    selected: sel.contains(item.path),
                                    odd: i.isOdd,
                                  );
                                  final drag = widget.dragData;
                                  if (drag != null) {
                                    row = DragSourceItem(
                                      id: item.path,
                                      data: (_) => drag(item),
                                      child: row,
                                    );
                                  }
                                  final drop = widget.onDrop;
                                  if (drop != null && item.isDir) {
                                    row = FolderDropTarget(
                                      id: item.path,
                                      onDrop: (t) => drop(item, t),
                                      child: row,
                                    );
                                  }
                                  return Listener(
                                    onPointerDown: (e) => _pointerDown(e, item),
                                    child: row,
                                  );
                                },
                              ),
                            ),
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

extension on _FileListState {
  Widget _dropHere(Widget child) {
    final drop = widget.onDrop;
    if (drop == null) return child;
    return DragTarget<Transfer>(
      onAcceptWithDetails: (d) => drop(null, d.data),
      builder: (context, _, _) => child,
    );
  }
}

/// The columns that fit in [width], the name keeping at least 220 pixels
/// (the others are dropped in the reverse order of [_priority]).
List<ColumnSpec> visibleColumns(double width) {
  const priority = [
    SortColumn.size,
    SortColumn.modified,
    SortColumn.packed,
    SortColumn.ratio,
    SortColumn.method,
    SortColumn.encrypted,
    SortColumn.crc,
  ];
  var room = width - 22 - 220;
  final keep = <SortColumn>{SortColumn.name};
  for (final c in priority) {
    final w = kColumns.firstWhere((x) => x.column == c).width!;
    if (room < w) break;
    room -= w;
    keep.add(c);
  }
  return [
    for (final c in kColumns)
      if (keep.contains(c.column)) c,
  ];
}

class _EmptyHint extends StatelessWidget {
  final bool filtered;
  const _EmptyHint({required this.filtered});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Text(
        filtered ? 'No items match the filter' : 'This folder is empty',
        style: TextStyle(color: cs.onSurfaceVariant),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final ArchiveModel model;
  final List<ColumnSpec> columns;
  const _Header({required this.model, required this.columns});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.labelMedium!
        .copyWith(color: cs.onSurfaceVariant, fontWeight: FontWeight.w600);
    return Container(
      height: 30,
      color: cs.surfaceContainerLow,
      padding: const EdgeInsets.only(left: 8, right: 14),
      child: Row(
        children: [
          for (final c in columns)
            _cell(
              c,
              InkWell(
                key: Key('col-${c.column.name}'),
                onTap: () => model.sortBy(c.column),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Row(
                    mainAxisAlignment: c.alignEnd
                        ? MainAxisAlignment.end
                        : MainAxisAlignment.start,
                    children: [
                      Flexible(
                        child: Text(
                          c.label,
                          style: style,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (model.sortColumn == c.column)
                        Icon(
                          model.ascending
                              ? Icons.arrow_drop_up_rounded
                              : Icons.arrow_drop_down_rounded,
                          size: 18,
                          color: cs.primary,
                        ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

Widget _cell(ColumnSpec c, Widget child) => c.width == null
    ? Expanded(child: child)
    : SizedBox(width: c.width, child: child);

class _Row extends StatelessWidget {
  final List<ColumnSpec> columns;
  final ArchiveModel model;
  final ZxItem item;
  final bool selected;
  final bool odd;
  const _Row({
    super.key,
    required this.columns,
    required this.model,
    required this.item,
    required this.selected,
    required this.odd,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (icon, color) = iconFor(
      item,
      cs,
      inContainer: model.inContainer(item),
    );
    final base = Theme.of(context).textTheme.bodyMedium!.copyWith(fontSize: 13);
    final fg = selected ? cs.onSecondaryContainer : cs.onSurface;
    final dim = selected ? cs.onSecondaryContainer : cs.onSurfaceVariant;
    Widget text(String s, ColumnSpec c, {bool dimmed = true}) => _cell(
      c,
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Text(
          s,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: c.alignEnd ? TextAlign.end : TextAlign.start,
          style: base.copyWith(color: dimmed ? dim : fg),
        ),
      ),
    );
    final size = model.sizeOf(item);
    return Container(
      padding: const EdgeInsets.only(left: 8, right: 14),
      decoration: BoxDecoration(
        color: selected
            ? cs.secondaryContainer
            : odd
            ? cs.surfaceContainerLow.withValues(alpha: 0.55)
            : null,
      ),
      child: Row(
        children: [
          for (final c in columns)
            switch (c.column) {
              SortColumn.name => _cell(
                c,
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Row(
                    children: [
                      Icon(icon, size: 18, color: color),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          item.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: base.copyWith(color: fg),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SortColumn.size => text(
                item.isDir && size == 0 ? '' : formatBytes(size),
                c,
              ),
              SortColumn.packed => text(formatBytes(model.packedOf(item)), c),
              SortColumn.ratio => text(formatRatio(model.ratioOf(item)), c),
              SortColumn.modified => text(formatDate(item.modified), c),
              SortColumn.method => text(
                item.isDir ? '' : (item.method ?? ''),
                c,
              ),
              SortColumn.encrypted => _cell(
                c,
                item.encrypted
                    ? Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Tooltip(
                            message: 'Encrypted',
                            child: Icon(
                              Icons.lock_rounded,
                              size: 15,
                              color: cs.tertiary,
                            ),
                          ),
                        ),
                      )
                    : const SizedBox(),
              ),
              SortColumn.crc => text(formatCrc(item.crc), c),
            },
        ],
      ),
    );
  }
}
