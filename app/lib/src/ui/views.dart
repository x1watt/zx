// The item views of the explorer shared by the file system and the
// archives: the details list of a file system folder, the icon grid (with
// thumbnails of images, decoded by the engine off the UI isolate at the
// tile size and kept in the image cache) and the large touch rows of a
// phone. Clicks, the context menu, long press and drag and drop go to
// [ViewHandlers].

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../fs/fs_model.dart';
import 'file_list.dart' show kRowHeight;
import 'thumbnail_cache.dart';
import 'format_utils.dart';
import 'transfer.dart';

/// One row or tile.
class ViewItem {
  /// The path (file system) or the item path (archive).
  final String id;
  final String name;
  final bool isDir;
  final IconData icon;
  final Color color;

  /// The filesystem/archive entry represented by this row. Pointer handlers
  /// use the already-built row rather than doing a whole-list lookup.
  final Object? source;

  /// Persistent cache lookup for a supported raster image.
  final ThumbnailRequest? thumbnail;

  /// The second line of a touch row (size and date).
  final String subtitle;
  const ViewItem({
    required this.id,
    required this.name,
    required this.isDir,
    required this.icon,
    required this.color,
    this.source,
    this.thumbnail,
    this.subtitle = '',
  });
}

class ViewHandlers {
  final void Function(ViewItem item, {bool ctrl, bool shift}) onClick;
  final void Function(ViewItem item) onOpen;
  final void Function(ViewItem? item, Offset globalPosition) onContextMenu;

  /// Long press (touch): starts or extends the selection.
  final void Function(ViewItem item)? onLongPress;

  /// A tap adds to or removes from the selection (touch selection mode).
  final bool selectionMode;

  /// A touch tap opens (a phone); else a touch is a click (a desktop
  /// with a touch screen).
  final bool touchOpens;

  /// What a drag of the item carries (null: no drag).
  final Transfer? Function(String id)? dragData;

  /// A drop on the folder [id] (null: on the folder shown).
  final void Function(String? id, Transfer t)? onDrop;

  final VoidCallback? onBackgroundTap;

  const ViewHandlers({
    required this.onClick,
    required this.onOpen,
    required this.onContextMenu,
    this.onLongPress,
    this.selectionMode = false,
    this.touchOpens = false,
    this.dragData,
    this.onDrop,
    this.onBackgroundTap,
  });
}

/// Mouse clicks (double click without the delay of a gesture detector),
/// touch taps and long presses, the right button, drag and drop.
class _ItemGestures extends StatefulWidget {
  final ViewItem item;
  final ViewHandlers h;
  final Widget child;
  final void Function() onRowHit;
  const _ItemGestures({
    super.key,
    required this.item,
    required this.h,
    required this.child,
    required this.onRowHit,
  });

  @override
  State<_ItemGestures> createState() => _ItemGesturesState();
}

final _clock = Stopwatch()..start();
String? _lastClickId;
int _lastClickMs = -100000;

class _ItemGesturesState extends State<_ItemGestures> {
  bool _hovered = false;

  /// The item a second click wants to open, waiting for the pointer to
  /// be released: a press that turns into a drag is not a click.
  String? _open;
  Offset? _openDown;
  int? _openPointer;

  @override
  void initState() {
    super.initState();
    GestureBinding.instance.pointerRouter.addGlobalRoute(_route);
  }

  @override
  void didUpdateWidget(_ItemGestures oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.id != widget.item.id) _cancelOpen();
  }

  @override
  void dispose() {
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_route);
    super.dispose();
  }

  void _cancelOpen() {
    _open = null;
    _openDown = null;
    _openPointer = null;
  }

  void _route(PointerEvent e) {
    if (_open == null) return;
    if (e.pointer != _openPointer) return;
    if (e is PointerMoveEvent) {
      if (_openDown == null ||
          (e.position - _openDown!).distance <= kDragStartDistance) {
        return;
      }
      _cancelOpen();
      return;
    }
    if (e is! PointerUpEvent && e is! PointerCancelEvent) return;
    final id = _open;
    _cancelOpen();
    final item = widget.item;
    if (id != null && e is PointerUpEvent) widget.h.onOpen(item);
  }

  void _down(PointerDownEvent e) {
    widget.onRowHit();
    final h = widget.h;
    if (e.kind == PointerDeviceKind.touch && h.touchOpens) return;
    final id = widget.item.id;
    if (e.buttons == kSecondaryMouseButton) {
      h.onContextMenu(widget.item, e.position);
      return;
    }
    if (e.buttons != kPrimaryMouseButton) return;
    final kb = HardwareKeyboard.instance;
    final now = _clock.elapsedMilliseconds;
    final isDouble =
        _lastClickId == id &&
        now - _lastClickMs < kDoubleTapTimeout.inMilliseconds + 100 &&
        !kb.isControlPressed &&
        !kb.isShiftPressed;
    _lastClickId = id;
    _lastClickMs = isDouble ? -100000 : now;
    if (isDouble) {
      // the item opens when the button comes back up, so a press that
      // wanders off into a drag opens nothing
      _open = id;
      _openDown = e.position;
      _openPointer = e.pointer;
      return;
    }
    h.onClick(
      widget.item,
      ctrl: kb.isControlPressed || kb.isMetaPressed,
      shift: kb.isShiftPressed,
    );
  }

  @override
  Widget build(BuildContext context) {
    final h = widget.h;
    final id = widget.item.id;
    Widget w = Listener(
      onPointerDown: _down,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: _hovered
                  ? Theme.of(context).colorScheme.outlineVariant
                  : Colors.transparent,
            ),
          ),
          child: GestureDetector(
            // touch only: the mouse is handled by the listener
            supportedDevices: const {
              PointerDeviceKind.touch,
              PointerDeviceKind.stylus,
            },
            onTap: !h.touchOpens
                ? null
                : () => h.selectionMode
                      ? h.onClick(widget.item, ctrl: true)
                      : h.onOpen(widget.item),
            onLongPressStart: (d) {
              if (h.onLongPress != null) {
                h.onLongPress!(widget.item);
              } else {
                h.onContextMenu(widget.item, d.globalPosition);
              }
            },
            child: widget.child,
          ),
        ),
      ),
    );
    final data = h.dragData;
    if (data != null) {
      w = DragSourceItem(id: id, data: data, child: w);
    }
    final drop = h.onDrop;
    if (drop != null && widget.item.isDir) {
      w = FolderDropTarget(id: id, onDrop: (t) => drop(id, t), child: w);
    }
    return w;
  }
}

/// A folder that accepts drops (highlighted while one hovers), except
/// of itself.
class FolderDropTarget extends StatefulWidget {
  final String id;
  final void Function(Transfer t) onDrop;
  final Widget child;
  const FolderDropTarget({
    super.key,
    required this.id,
    required this.onDrop,
    required this.child,
  });

  @override
  State<FolderDropTarget> createState() => _FolderDropTargetState();
}

class _FolderDropTargetState extends State<FolderDropTarget> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final id = widget.id;
    return DragTarget<Transfer>(
      onWillAcceptWithDetails: (d) {
        final t = d.data;
        final ok = !(t.fsPaths.contains(id) || t.items.contains(id));
        if (ok != _hover) setState(() => _hover = ok);
        return ok;
      },
      onLeave: (_) => setState(() => _hover = false),
      onAcceptWithDetails: (d) {
        setState(() => _hover = false);
        widget.onDrop(d.data);
      },
      builder: (context, _, _) => _hover
          ? DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(
                  color: Theme.of(context).colorScheme.primary,
                  width: 2,
                ),
                borderRadius: BorderRadius.circular(6),
              ),
              child: widget.child,
            )
          : widget.child,
    );
  }
}

/// Starts a drag of what [data] gives for [id] (the selection when the
/// item is selected), with a small "3 items" chip under the pointer.
class DragSourceItem extends StatelessWidget {
  final String id;
  final Transfer? Function(String id) data;
  final Widget child;
  const DragSourceItem({
    super.key,
    required this.id,
    required this.data,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final transfer = data(id);
    if (transfer == null) return child;
    return _ItemDraggable(
      data: transfer,
      maxSimultaneousDrags: 1,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: Material(
        color: cs.primary,
        borderRadius: BorderRadius.circular(16),
        elevation: 4,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Text(
            transfer.label,
            style: TextStyle(color: cs.onPrimary, fontSize: 13),
          ),
        ),
      ),
      child: child,
    );
  }
}

/// How far a precise pointer (mouse, trackpad) has to travel before a
/// press turns into a drag. A mouse drag starts after one pixel and a
/// click is never pixel perfect, so without this a click on a selected
/// item drags it, and letting go over a folder moves it there.
const double kDragStartDistance = 10;

/// A draggable with an immutable payload captured after the last selection
/// update, before any pointer gesture can start.
class _ItemDraggable extends Draggable<Transfer> {
  const _ItemDraggable({
    required super.data,
    required super.maxSimultaneousDrags,
    required super.dragAnchorStrategy,
    required super.feedback,
    required super.child,
  });

  @override
  MultiDragGestureRecognizer createRecognizer(
    GestureMultiDragStartCallback onStart,
  ) => _TravelRecognizer()..onStart = onStart;
}

class _TravelRecognizer extends ImmediateMultiDragGestureRecognizer {
  @override
  MultiDragPointerState createNewPointerState(PointerDownEvent event) =>
      _TravelPointerState(event.position, event.kind, gestureSettings);
}

class _TravelPointerState extends MultiDragPointerState {
  _TravelPointerState(super.initialPosition, super.kind, super.gestureSettings);

  GestureMultiDragStartCallback? _starter;

  @override
  void accepted(GestureMultiDragStartCallback starter) => _starter = starter;

  @override
  void checkForResolutionAfterMove() {
    final start = _starter;
    if (start == null || pendingDelta == null || pendingDelta!.distance <= _slop) {
      return;
    }
    _starter = null;
    start(initialPosition);
  }

  void checkForResolutionAfterUp() {
    if (_starter == null) return;
    _starter = null;
    resolve(GestureDisposition.rejected);
  }

  double get _slop {
    final device = computeHitSlop(kind, gestureSettings);
    return device > kDragStartDistance ? device : kDragStartDistance;
  }
}

/// The empty area of a view: a click clears the selection, a right click
/// opens the menu of the folder, a drop goes into the folder shown.
class _Background extends StatefulWidget {
  final ViewHandlers h;
  final bool Function() consumeRowHit;
  final Widget child;
  const _Background({
    required this.h,
    required this.consumeRowHit,
    required this.child,
  });

  @override
  State<_Background> createState() => _BackgroundState();
}

class _BackgroundState extends State<_Background> {
  @override
  Widget build(BuildContext context) {
    final h = widget.h;
    Widget w = Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (e) {
        if (widget.consumeRowHit()) return;
        if (e.kind == PointerDeviceKind.touch && h.touchOpens) return;
        h.onBackgroundTap?.call();
        if (e.buttons == kSecondaryMouseButton) {
          h.onContextMenu(null, e.position);
        }
      },
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        supportedDevices: const {PointerDeviceKind.touch},
        onLongPressStart: (d) => h.onContextMenu(null, d.globalPosition),
        child: widget.child,
      ),
    );
    final drop = h.onDrop;
    if (drop == null) return w;
    final inner = w;
    return DragTarget<Transfer>(
      onAcceptWithDetails: (d) => drop(null, d.data),
      builder: (context, _, _) => inner,
    );
  }
}

/// A thumbnail of a local image, decoded at [size] pixels by the engine,
/// or [fallback] (for a file that is not an image, too large or broken).
class Thumb extends StatefulWidget {
  final ThumbnailCache cache;
  final ThumbnailRequest request;
  final double size;
  final Widget fallback;
  const Thumb({
    super.key,
    required this.cache,
    required this.request,
    required this.size,
    required this.fallback,
  });

  @override
  State<Thumb> createState() => _ThumbState();
}

class _ThumbState extends State<Thumb> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(Thumb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.request.key != widget.request.key ||
        oldWidget.cache != widget.cache) {
      _bytes = null;
      _load();
    }
  }

  Future<void> _load() async {
    final key = widget.request.key;
    final bytes = await widget.cache.load(widget.request);
    if (mounted && widget.request.key == key && bytes != null) {
      setState(() => _bytes = bytes);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes == null) return widget.fallback;
    final px = (widget.size * MediaQuery.devicePixelRatioOf(context)).round();
    return Image(
      image: ResizeImage(MemoryImage(bytes), width: px, allowUpscaling: false),
      width: widget.size,
      height: widget.size,
      fit: BoxFit.contain,
      gaplessPlayback: true,
      filterQuality: FilterQuality.medium,
      errorBuilder: (_, _, _) => widget.fallback,
      frameBuilder: (_, child, frame, sync) =>
          frame == null && !sync ? widget.fallback : child,
    );
  }
}

/// The icon grid.
class ItemGrid extends StatefulWidget {
  final List<ViewItem> items;
  final Set<String> selection;
  final ViewHandlers handlers;
  final ThumbnailCache thumbnailCache;
  final double tile;
  const ItemGrid({
    super.key,
    required this.items,
    required this.selection,
    required this.handlers,
    required this.thumbnailCache,
    this.tile = 112,
  });

  @override
  State<ItemGrid> createState() => _ItemGridState();
}

class _ItemGridState extends State<ItemGrid> {
  final _scroll = ScrollController();
  bool _rowHit = false;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final items = widget.items;
    return _Background(
      h: widget.handlers,
      consumeRowHit: () {
        final r = _rowHit;
        _rowHit = false;
        return r;
      },
      child: Scrollbar(
        controller: _scroll,
        child: GridView.builder(
          key: const Key('item-grid'),
          controller: _scroll,
          padding: const EdgeInsets.all(8),
          gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: widget.tile,
            mainAxisExtent: widget.tile + 34,
            crossAxisSpacing: 4,
            mainAxisSpacing: 4,
          ),
          itemCount: items.length,
          itemBuilder: (context, i) {
            final it = items[i];
            final sel = widget.selection.contains(it.id);
            final iconSize = widget.tile * 0.55;
            final icon = Icon(it.icon, size: iconSize, color: it.color);
            final thumbSize = widget.tile - 16;
            return _ItemGestures(
              key: ValueKey('tile:${it.id}'),
              item: it,
              h: widget.handlers,
              onRowHit: () => _rowHit = true,
              child: Container(
                decoration: BoxDecoration(
                  color: sel ? cs.secondaryContainer : null,
                  borderRadius: BorderRadius.circular(8),
                ),
                padding: const EdgeInsets.all(4),
                child: Column(
                  children: [
                    SizedBox(
                      width: thumbSize,
                      height: thumbSize,
                      child: Center(
                        child: it.thumbnail == null
                            ? icon
                            : ClipRRect(
                                borderRadius: BorderRadius.circular(6),
                                child: Thumb(
                                  cache: widget.thumbnailCache,
                                  request: it.thumbnail!,
                                  size: thumbSize,
                                  fallback: icon,
                                ),
                              ),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Tooltip(
                      message: it.name,
                      waitDuration: const Duration(milliseconds: 650),
                      child: Text(
                        it.name,
                        maxLines: 2,
                        textAlign: TextAlign.center,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: sel ? cs.onSecondaryContainer : cs.onSurface,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// The large rows of a phone: icon or thumbnail, the name and a second
/// line; a check box in the selection mode.
class TileList extends StatefulWidget {
  final List<ViewItem> items;
  final Set<String> selection;
  final ViewHandlers handlers;
  final ThumbnailCache thumbnailCache;
  const TileList({
    super.key,
    required this.items,
    required this.selection,
    required this.handlers,
    required this.thumbnailCache,
  });

  @override
  State<TileList> createState() => _TileListState();
}

class _TileListState extends State<TileList> {
  final _scroll = ScrollController();
  bool _rowHit = false;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final items = widget.items;
    final h = widget.handlers;
    return _Background(
      h: h,
      consumeRowHit: () {
        final r = _rowHit;
        _rowHit = false;
        return r;
      },
      child: ListView.builder(
        key: const Key('tile-list'),
        controller: _scroll,
        itemExtent: 60,
        itemCount: items.length,
        itemBuilder: (context, i) {
          final it = items[i];
          final sel = widget.selection.contains(it.id);
          final icon = Icon(it.icon, size: 30, color: it.color);
          return _ItemGestures(
            key: ValueKey('row:${it.id}'),
            item: it,
            h: h,
            onRowHit: () => _rowHit = true,
            child: Container(
              color: sel ? cs.secondaryContainer : Colors.transparent,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  SizedBox(
                    width: 40,
                    height: 40,
                    child: Center(
                      child: it.thumbnail == null
                          ? icon
                          : ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: Thumb(
                                cache: widget.thumbnailCache,
                                request: it.thumbnail!,
                                size: 40,
                                fallback: icon,
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          it.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 15, color: cs.onSurface),
                        ),
                        if (it.subtitle.isNotEmpty)
                          Text(
                            it.subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (h.selectionMode)
                    Icon(
                      sel
                          ? Icons.check_circle_rounded
                          : Icons.radio_button_unchecked_rounded,
                      color: sel ? cs.primary : cs.outline,
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// The details list of a file system folder

class _FsColumn {
  final FsSort sort;
  final String label;
  final double? width;
  final bool alignEnd;
  const _FsColumn(this.sort, this.label, this.width, {this.alignEnd = false});
}

const _fsColumns = [
  _FsColumn(FsSort.name, 'Name', null),
  _FsColumn(FsSort.size, 'Size', 96, alignEnd: true),
  _FsColumn(FsSort.type, 'Type', 120),
  _FsColumn(FsSort.modified, 'Modified', 140),
];

class FsDetailsList extends StatefulWidget {
  final FsModel model;
  final List<ViewItem> items;
  final ViewHandlers handlers;
  const FsDetailsList({
    super.key,
    required this.model,
    required this.items,
    required this.handlers,
  });

  @override
  State<FsDetailsList> createState() => _FsDetailsListState();
}

class _FsDetailsListState extends State<FsDetailsList> {
  final _scroll = ScrollController();
  bool _rowHit = false;
  String? _lastDir;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
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

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final m = widget.model;
    if (m.dir != _lastDir) {
      _lastDir = m.dir;
      if (_scroll.hasClients) _scroll.jumpTo(0);
    } else {
      final c = m.cursorIndex;
      WidgetsBinding.instance.addPostFrameCallback((_) => _ensureVisible(c));
    }
    final rows = m.rows;
    final sel = m.selection;
    final base = Theme.of(context).textTheme.bodyMedium!.copyWith(fontSize: 13);
    final head = Theme.of(context).textTheme.labelMedium!
        .copyWith(color: cs.onSurfaceVariant, fontWeight: FontWeight.w600);
    return LayoutBuilder(
      builder: (context, box) {
        final cols = [
          for (final c in _fsColumns)
            if (c.width == null ||
                box.maxWidth > 360 + (c.sort == FsSort.type ? 240 : 0))
              c,
        ];
        Widget cell(_FsColumn c, Widget child) => c.width == null
            ? Expanded(child: child)
            : SizedBox(width: c.width, child: child);
        return Column(
          children: [
            Container(
              height: 30,
              color: cs.surfaceContainerLow,
              padding: const EdgeInsets.only(left: 8, right: 14),
              child: Row(
                children: [
                  for (final c in cols)
                    cell(
                      c,
                      InkWell(
                        key: Key('fscol-${c.sort.name}'),
                        onTap: () => m.sortBy(c.sort),
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
                                  style: head,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (m.sort == c.sort)
                                Icon(
                                  m.ascending
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
            ),
            Divider(height: 1, color: cs.outlineVariant),
            Expanded(
              child: _Background(
                h: widget.handlers,
                consumeRowHit: () {
                  final r = _rowHit;
                  _rowHit = false;
                  return r;
                },
                child: rows.isEmpty
                    ? Center(
                        child: Text(
                          m.loading
                              ? 'Reading...'
                              : m.error ??
                                    (m.inSearch
                                        ? (m.searching
                                              ? 'Searching...'
                                              : 'Nothing found')
                                        : m.filter.isNotEmpty
                                        ? 'No items match the filter'
                                        : 'This folder is empty'),
                          style: TextStyle(color: cs.onSurfaceVariant),
                        ),
                      )
                    : Scrollbar(
                        controller: _scroll,
                        thumbVisibility: true,
                        child: ListView.builder(
                          key: const Key('fs-list'),
                          controller: _scroll,
                          itemExtent: kRowHeight,
                          itemCount: rows.length,
                          itemBuilder: (context, i) {
                            final e = rows[i];
                            final it = widget.items[i];
                            final s = sel.contains(e.path);
                            final fg = s
                                ? cs.onSecondaryContainer
                                : cs.onSurface;
                            final dim = s
                                ? cs.onSecondaryContainer
                                : cs.onSurfaceVariant;
                            Widget text(String t, _FsColumn c) => cell(
                              c,
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                ),
                                child: Text(
                                  t,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: c.alignEnd
                                      ? TextAlign.end
                                      : TextAlign.start,
                                  style: base.copyWith(color: dim),
                                ),
                              ),
                            );
                            return _ItemGestures(
                              key: ValueKey('fsrow:${e.path}'),
                              item: it,
                              h: widget.handlers,
                              onRowHit: () => _rowHit = true,
                              child: Container(
                                padding: const EdgeInsets.only(
                                  left: 8,
                                  right: 14,
                                ),
                                color: s
                                    ? cs.secondaryContainer
                                    : i.isOdd
                                    ? cs.surfaceContainerLow.withValues(
                                        alpha: 0.55,
                                      )
                                    : Colors.transparent,
                                child: Row(
                                  children: [
                                    for (final c in cols)
                                      switch (c.sort) {
                                        FsSort.name => cell(
                                          c,
                                          Padding(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 6,
                                            ),
                                            child: Row(
                                              children: [
                                                Icon(
                                                  it.icon,
                                                  size: 18,
                                                  color: e.hidden
                                                      ? it.color.withValues(
                                                          alpha: 0.5,
                                                        )
                                                      : it.color,
                                                ),
                                                const SizedBox(width: 8),
                                                Expanded(
                                                  child: Text(
                                                    m.inSearch
                                                        ? it.subtitle
                                                        : e.name,
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: base.copyWith(
                                                      color: fg,
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                        FsSort.size => text(
                                          e.isDir
                                              ? (m.sizeOf(e) > 0
                                                    ? formatBytes(m.sizeOf(e))
                                                    : '')
                                              : formatBytes(e.size),
                                          c,
                                        ),
                                        FsSort.type => text(typeOf(e), c),
                                        FsSort.modified => text(
                                          formatDate(e.modified),
                                          c,
                                        ),
                                      },
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
              ),
            ),
          ],
        );
      },
    );
  }
}
