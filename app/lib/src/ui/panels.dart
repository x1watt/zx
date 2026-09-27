// The panels around the file list: folder tree, path bar with the quick
// filter, toolbar, status bar and the welcome view.

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../archive_model.dart';
import '../dialogs/properties_dialog.dart';
import 'format_utils.dart';

// ---------------------------------------------------------------------------
// Folder tree

class FolderTree extends StatefulWidget {
  final ArchiveModel model;
  const FolderTree({super.key, required this.model});

  @override
  State<FolderTree> createState() => _FolderTreeState();
}

class _FolderTreeState extends State<FolderTree> {
  final Set<String> _expanded = {''};
  String? _lastDir;
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _expandTo(String dir) {
    var d = dir;
    while (d.isNotEmpty) {
      final k = d.lastIndexOf('/');
      d = k < 0 ? '' : d.substring(0, k);
      _expanded.add(d);
    }
  }

  List<(String path, String name, int depth)> _visible() {
    final m = widget.model;
    final out = <(String, String, int)>[('', p.basename(m.archive.path), 0)];
    void walk(String dir, int depth) {
      if (!_expanded.contains(dir)) return;
      for (final f in m.folders(dir)) {
        out.add((f.path, f.name, depth));
        walk(f.path, depth + 1);
      }
    }

    walk('', 1);
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: widget.model,
      builder: (context, _) {
        final m = widget.model;
        if (m.dir != _lastDir) {
          // a new folder: show it and its sub folders
          _lastDir = m.dir;
          _expandTo(m.dir);
          _expanded.add(m.dir);
        }
        final nodes = _visible();
        return ListView.builder(
          key: const Key('folder-tree'),
          controller: _scroll,
          padding: const EdgeInsets.symmetric(vertical: 6),
          itemExtent: 28,
          itemCount: nodes.length,
          itemBuilder: (context, i) {
            final (path, name, depth) = nodes[i];
            final current = path == m.dir;
            final hasChildren = m.folders(path).isNotEmpty;
            final open = _expanded.contains(path);
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Material(
                color: current ? cs.secondaryContainer : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
                child: InkWell(
                  key: Key('tree:$path'),
                  borderRadius: BorderRadius.circular(6),
                  onTap: () => m.navigate(path),
                  child: Row(
                    children: [
                      SizedBox(width: depth * 14.0),
                      SizedBox(
                        width: 22,
                        child: hasChildren
                            ? InkResponse(
                                radius: 12,
                                onTap: () => setState(() {
                                  if (open && path.isNotEmpty) {
                                    _expanded.remove(path);
                                  } else {
                                    _expanded.add(path);
                                  }
                                }),
                                child: Icon(
                                  open
                                      ? Icons.expand_more_rounded
                                      : Icons.chevron_right_rounded,
                                  size: 18,
                                  color: cs.onSurfaceVariant,
                                ),
                              )
                            : null,
                      ),
                      Icon(
                        path.isEmpty
                            ? Icons.folder_zip_rounded
                            : (current || open
                                  ? Icons.folder_open_rounded
                                  : Icons.folder_rounded),
                        size: 18,
                        color: path.isEmpty
                            ? cs.primary
                            : const Color(0xFFE0A526),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: current
                                ? FontWeight.w600
                                : FontWeight.normal,
                            color: current
                                ? cs.onSecondaryContainer
                                : cs.onSurface,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Path bar

class PathBar extends StatelessWidget {
  final ArchiveModel model;
  final TextEditingController filter;
  final FocusNode filterFocus;
  const PathBar({
    super.key,
    required this.model,
    required this.filter,
    required this.filterFocus,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: model,
      builder: (context, _) {
        final parts = model.dir.isEmpty ? <String>[] : model.dir.split('/');
        Widget crumb(String label, String path, {bool first = false}) {
          final current = path == model.dir;
          return InkWell(
            key: Key('crumb:$path'),
            borderRadius: BorderRadius.circular(6),
            onTap: current ? null : () => model.navigate(path),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (first) ...[
                    Icon(Icons.folder_zip_rounded, size: 16, color: cs.primary),
                    const SizedBox(width: 4),
                  ],
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: current ? FontWeight.w600 : FontWeight.normal,
                      color: current ? cs.onSurface : cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        final crumbs = <Widget>[
          crumb(p.basename(model.archive.path), '', first: true),
        ];
        for (var i = 0; i < parts.length; i++) {
          crumbs.add(
            Icon(
              Icons.chevron_right_rounded,
              size: 16,
              color: cs.onSurfaceVariant,
            ),
          );
          crumbs.add(crumb(parts[i], parts.sublist(0, i + 1).join('/')));
        }
        return Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              IconButton(
                key: const Key('nav-back'),
                tooltip: 'Back (Alt+Left)',
                visualDensity: VisualDensity.compact,
                onPressed: model.canBack ? model.back : null,
                icon: const Icon(Icons.arrow_back_rounded, size: 20),
              ),
              IconButton(
                key: const Key('nav-forward'),
                tooltip: 'Forward (Alt+Right)',
                visualDensity: VisualDensity.compact,
                onPressed: model.canForward ? model.forward : null,
                icon: const Icon(Icons.arrow_forward_rounded, size: 20),
              ),
              IconButton(
                key: const Key('nav-up'),
                tooltip: 'Up one folder (Backspace)',
                visualDensity: VisualDensity.compact,
                onPressed: model.canUp ? model.up : null,
                icon: const Icon(Icons.arrow_upward_rounded, size: 20),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Container(
                  height: 32,
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: LayoutBuilder(
                    builder: (context, box) => SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      reverse: true,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(minWidth: box.maxWidth),
                        child: Row(children: crumbs),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 240,
                height: 32,
                child: TextField(
                  key: const Key('filter'),
                  controller: filter,
                  focusNode: filterFocus,
                  onChanged: (v) => model.filter = v,
                  style: const TextStyle(fontSize: 13),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: 'Filter this folder',
                    prefixIcon: const Icon(Icons.search_rounded, size: 18),
                    suffixIcon: model.filter.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Clear the filter',
                            icon: const Icon(Icons.close_rounded, size: 16),
                            onPressed: () {
                              filter.clear();
                              model.filter = '';
                            },
                          ),
                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                    filled: true,
                    fillColor: cs.surfaceContainerHighest.withValues(
                      alpha: 0.6,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Toolbar

class ToolAction {
  final String id;
  final IconData icon;
  final String label;
  final String tooltip;

  /// Why the action is not available, or null when it is.
  final String? disabledReason;
  final VoidCallback onPressed;
  const ToolAction(
    this.id,
    this.icon,
    this.label,
    this.tooltip,
    this.disabledReason,
    this.onPressed,
  );
}

class Toolbar extends StatelessWidget {
  final List<ToolAction?> actions; // null: a separator
  const Toolbar({super.key, required this.actions});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final a in actions)
              if (a == null)
                Container(
                  width: 1,
                  height: 36,
                  margin: const EdgeInsets.symmetric(horizontal: 6),
                  color: cs.outlineVariant,
                )
              else
                Tooltip(
                  message: a.disabledReason ?? a.tooltip,
                  waitDuration: const Duration(milliseconds: 400),
                  child: _ToolButton(action: a),
                ),
          ],
        ),
      ),
    );
  }
}

class _ToolButton extends StatelessWidget {
  final ToolAction action;
  const _ToolButton({required this.action});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final enabled = action.disabledReason == null;
    final color = enabled ? cs.onSurface : cs.onSurface.withValues(alpha: 0.35);
    return InkWell(
      key: Key('tool-${action.id}'),
      borderRadius: BorderRadius.circular(8),
      onTap: enabled ? action.onPressed : null,
      child: Container(
        constraints: const BoxConstraints(minWidth: 64),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(action.icon, size: 24, color: enabled ? cs.primary : color),
            const SizedBox(height: 3),
            Text(action.label, style: TextStyle(fontSize: 12, color: color)),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Status bar

class StatusBar extends StatelessWidget {
  final ArchiveModel? model;
  final String? message;
  const StatusBar({super.key, required this.model, this.message});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final style = TextStyle(fontSize: 12, color: cs.onSurfaceVariant);
    final m = model;
    Widget body;
    if (m == null) {
      body = Text(message ?? 'Ready', style: style);
    } else {
      body = ListenableBuilder(
        listenable: m,
        builder: (context, _) {
          final rows = m.rows;
          final sel = m.selectedItems;
          var selSize = 0;
          for (final i in sel) {
            selSize += m.sizeOf(i);
          }
          var total = 0;
          for (final i in rows) {
            total += m.sizeOf(i);
          }
          final a = m.archive;
          final left = sel.isEmpty
              ? '${rows.length} item${rows.length == 1 ? '' : 's'}, ${formatBytes(total)}'
              : '${sel.length} of ${rows.length} selected, ${formatBytes(selSize)}';
          final info = [
            formatDescription(a),
            if (a.method != null && a.method!.isNotEmpty) a.method!,
            if (a.solid) 'solid',
            if (a.encryptedHeaders || a.items.any((i) => i.encrypted))
              'encrypted',
            formatBytes(a.physicalSize),
          ].join('  |  ');
          return Row(
            children: [
              Expanded(
                child: Text(
                  message ?? left,
                  key: const Key('status-left'),
                  style: style,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Text(
                  info,
                  key: const Key('status-right'),
                  style: style,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          );
        },
      );
    }
    return Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        border: Border(top: BorderSide(color: cs.outlineVariant)),
      ),
      alignment: Alignment.centerLeft,
      child: body,
    );
  }
}

// ---------------------------------------------------------------------------
// Welcome

class WelcomeView extends StatelessWidget {
  final List<String> recent;
  final VoidCallback onOpen;
  final VoidCallback onNew;
  final void Function(String path) onOpenRecent;
  final void Function(String path) onRemoveRecent;
  const WelcomeView({
    super.key,
    required this.recent,
    required this.onOpen,
    required this.onNew,
    required this.onOpenRecent,
    required this.onRemoveRecent,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset('assets/icon/zx-128.png', width: 88, height: 88),
              const SizedBox(height: 12),
              Text(
                'zx',
                style: t.headlineMedium!.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                'Open an archive, create a new one, or drop files here.',
                style: t.bodyLarge!.copyWith(color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  FilledButton.icon(
                    key: const Key('welcome-open'),
                    onPressed: onOpen,
                    icon: const Icon(Icons.folder_open_rounded),
                    label: const Text('Open archive'),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    key: const Key('welcome-new'),
                    onPressed: onNew,
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('New archive'),
                  ),
                ],
              ),
              const SizedBox(height: 28),
              if (recent.isNotEmpty)
                Card(
                  elevation: 0,
                  color: cs.surfaceContainerLow,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(color: cs.outlineVariant),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                          child: Text('Recent archives', style: t.titleSmall),
                        ),
                        for (final r in recent)
                          ListTile(
                            key: Key('recent:$r'),
                            dense: true,
                            leading: Icon(
                              Icons.folder_zip_outlined,
                              color: cs.primary,
                            ),
                            title: Text(p.basename(r)),
                            subtitle: Text(
                              p.dirname(r),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: () => onOpenRecent(r),
                            trailing: IconButton(
                              tooltip: 'Remove from the list',
                              icon: const Icon(Icons.close_rounded, size: 18),
                              onPressed: () => onRemoveRecent(r),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
