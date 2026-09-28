// The left sidebar of the explorer (a drawer on a phone): the places, the
// drives and volumes, the pinned folders and the recent archives. A drop
// on a place copies or moves there.

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../platform/places.dart';
import 'transfer.dart';

IconData placeIcon(PlaceKind k) => switch (k) {
  PlaceKind.home => Icons.home_rounded,
  PlaceKind.desktop => Icons.desktop_windows_rounded,
  PlaceKind.documents => Icons.description_rounded,
  PlaceKind.downloads => Icons.download_rounded,
  PlaceKind.pictures => Icons.image_rounded,
  PlaceKind.music => Icons.music_note_rounded,
  PlaceKind.videos => Icons.movie_rounded,
  PlaceKind.root => Icons.computer_rounded,
  PlaceKind.volume => Icons.storage_rounded,
  PlaceKind.bookmark => Icons.push_pin_rounded,
};

class Sidebar extends StatelessWidget {
  final List<Place> places;
  final List<Place> volumes;
  final List<String> bookmarks;
  final List<String> recent;

  /// The folder shown (its place is highlighted), null inside an archive.
  final String? current;
  final void Function(String path) onPlace;
  final void Function(String path) onArchive;
  final void Function(String path) onRemoveBookmark;
  final void Function(String path, Transfer t)? onDrop;

  /// Shown under the places (the folder tree of an open archive).
  final Widget? bottom;

  const Sidebar({
    super.key,
    required this.places,
    required this.volumes,
    required this.bookmarks,
    required this.recent,
    required this.current,
    required this.onPlace,
    required this.onArchive,
    required this.onRemoveBookmark,
    this.onDrop,
    this.bottom,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget header(String t) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
      child: Text(
        t,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
          color: cs.onSurfaceVariant,
        ),
      ),
    );
    Widget tile(
      String key,
      IconData icon,
      String label,
      String path, {
      VoidCallback? onTap,
      Widget? trailing,
      bool droppable = true,
    }) {
      final sel = current != null && p.equals(current!, path);
      Widget w = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        child: Material(
          color: sel ? cs.secondaryContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            key: Key(key),
            borderRadius: BorderRadius.circular(8),
            onTap: onTap ?? () => onPlace(path),
            child: SizedBox(
              height: 38,

              child: Row(
                children: [
                  const SizedBox(width: 10),
                  Icon(
                    icon,
                    size: 18,
                    color: sel ? cs.onSecondaryContainer : cs.primary,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Tooltip(
                      message: path,
                      waitDuration: const Duration(seconds: 1),
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: sel ? cs.onSecondaryContainer : cs.onSurface,
                          fontWeight: sel ? FontWeight.w600 : FontWeight.normal,
                        ),
                      ),
                    ),
                  ),
                  ?trailing,
                ],
              ),
            ),
          ),
        ),
      );
      final drop = onDrop;
      if (drop != null && droppable) {
        final inner = w;
        w = DragTarget<Transfer>(
          onAcceptWithDetails: (d) => drop(path, d.data),
          builder: (context, cand, _) => cand.isEmpty
              ? inner
              : DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(color: cs.primary, width: 2),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: inner,
                ),
        );
      }
      return w;
    }

    final list = <Widget>[
      header('PLACES'),
      for (final pl in places)
        tile('place:${pl.path}', placeIcon(pl.kind), pl.label, pl.path),
      if (volumes.isNotEmpty) ...[
        header('DEVICES'),
        for (final v in volumes)
          tile(
            'place:${v.path}',
            v.removable ? Icons.usb_rounded : Icons.storage_rounded,
            v.label,
            v.path,
          ),
      ],
      if (bookmarks.isNotEmpty) ...[
        header('PINNED'),
        for (final b in bookmarks)
          tile(
            'bookmark:$b',
            Icons.push_pin_rounded,
            p.basename(b).isEmpty ? b : p.basename(b),
            b,
            trailing: IconButton(
              tooltip: 'Unpin',
              visualDensity: VisualDensity.compact,
              iconSize: 16,
              onPressed: () => onRemoveBookmark(b),
              icon: const Icon(Icons.close_rounded),
            ),
          ),
      ],
      if (recent.isNotEmpty) ...[
        header('RECENT ARCHIVES'),
        for (final r in recent.take(8))
          tile(
            'recent:$r',
            Icons.folder_zip_rounded,
            p.basename(r),
            r,
            onTap: () => onArchive(r),
            droppable: false,
          ),
      ],
    ];
    final b = bottom;
    if (b == null) {
      return ListView(
        key: const Key('sidebar'),
        padding: const EdgeInsets.only(bottom: 8),
        children: list,
      );
    }
    return Column(
      children: [
        Flexible(
          child: ListView(
            key: const Key('sidebar'),
            shrinkWrap: true,
            children: list,
          ),
        ),
        Divider(height: 1, color: cs.outlineVariant),
        Expanded(child: b),
      ],
    );
  }
}
