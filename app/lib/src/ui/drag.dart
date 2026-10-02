// Dragging items and dropping them on folders, shared by the views of
// folders and archives (views.dart, file_list.dart).

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'transfer.dart';

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
    if (start == null ||
        pendingDelta == null ||
        pendingDelta!.distance <= _slop) {
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
