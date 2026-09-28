// The panels around the file list: folder tree, path bar with the quick
// filter, toolbar, status bar and the welcome view.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../archive_model.dart';
import '../dialogs/properties_dialog.dart';
import '../fs/fs_model.dart';
import '../fs/fs_ops.dart' show FsEntry, listDirectory;
import '../platform/places.dart';
import 'format_utils.dart';
import 'path_bar.dart';

export 'path_bar.dart';

// ---------------------------------------------------------------------------
// Archive folder tree

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

  List<(String, String, int)> _visible() {
    final m = widget.model;
    final out = <(String, String, int)>[('', m.displayName, 0)];
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
                            ? (m.parent != null
                                  ? Icons.storage_rounded
                                  : Icons.folder_zip_rounded)
                            : (m.archive[path]?.isNested ?? false)
                            ? Icons.snippet_folder_rounded
                            : (current || open
                                  ? Icons.folder_open_rounded
                                  : Icons.folder_rounded),
                        size: 18,
                        color: path.isEmpty
                            ? (m.parent != null ? kImageColor : cs.primary)
                            : (m.archive[path]?.isNested ?? false)
                            ? kImageColor
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
// Filesystem folder tree

class FsFolderTree extends StatefulWidget {
  final FsModel model;
  final String root;
  final List<Place> volumes;
  final void Function(String path) onNavigate;
  const FsFolderTree({
    super.key,
    required this.model,
    required this.root,
    required this.volumes,
    required this.onNavigate,
  });
  @override
  State<FsFolderTree> createState() => _FsFolderTreeState();
}

class _FsFolderTreeState extends State<FsFolderTree> {
  final Set<String> _expanded = {};
  final Map<String, List<FsEntry>> _children = {};
  final Set<String> _loading = {};
  final ScrollController _scroll = ScrollController();
  String? _lastDir;

  @override
  void initState() {
    super.initState();
    widget.model.addListener(_onModel);
    _expanded.add(widget.root);
    unawaited(_load(widget.root));
    for (final volume in widget.volumes.where((v) => v.removable)) {
      _expanded.add(volume.path);
      unawaited(_load(volume.path));
    }
  }

  @override
  void didUpdateWidget(FsFolderTree oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.model != widget.model) {
      oldWidget.model.removeListener(_onModel);
      widget.model.addListener(_onModel);
    }
    if (oldWidget.root != widget.root) {
      _expanded.add(widget.root);
      unawaited(_load(widget.root));
    }
    final oldPaths = oldWidget.volumes.map((v) => v.path).toSet();
    for (final volume in widget.volumes.where(
      (v) => v.removable && !oldPaths.contains(v.path),
    )) {
      _expanded.add(volume.path);
      unawaited(_load(volume.path));
    }
  }

  @override
  void dispose() {
    widget.model.removeListener(_onModel);
    _scroll.dispose();
    super.dispose();
  }

  void _onModel() {
    final dir = widget.model.dir;
    if (dir == _lastDir) return;
    _lastDir = dir;
    _expandPath(dir);
    if (mounted) setState(() {});
  }

  void _expandPath(String path) {
    final roots = [widget.root, ...widget.volumes.map((v) => v.path)];
    final root = roots
        .where((r) => p.equals(path, r) || p.isWithin(r, path))
        .fold<String?>(
          null,
          (best, r) => best == null || r.length > best.length ? r : best,
        );
    if (root == null) return;
    var child = path;
    while (child != root && child.isNotEmpty) {
      _expanded.add(child);
      final parent = p.dirname(child);
      if (parent == child ||
          (!p.isWithin(root, parent) && !p.equals(root, parent))) {
        break;
      }
      child = parent;
    }
    _expanded.add(root);
    for (final dir in _expanded.toList()) {
      if (!_children.containsKey(dir)) unawaited(_load(dir));
    }
  }

  Future<void> _load(String path) async {
    if (_loading.contains(path)) return;
    _loading.add(path);
    try {
      final entries = await listDirectory(path);
      entries.sort((a, b) {
        if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
        return compareNames(a.name, b.name);
      });
      if (mounted) setState(() => _children[path] = entries);
    } on FileSystemException {
      if (mounted) setState(() => _children[path] = const []);
    } finally {
      _loading.remove(path);
    }
  }

  List<(String, String, int, bool, bool)> _nodes() {
    final nodes = <(String, String, int, bool, bool)>[];
    void visit(
      String path,
      String name,
      int depth, {
      bool root = false,
      bool removable = false,
    }) {
      nodes.add((path, name, depth, root, removable));
      if (!_expanded.contains(path)) return;
      for (final child in _children[path] ?? const <FsEntry>[]) {
        visit(child.path, child.name, depth + 1);
      }
    }

    visit(
      widget.root,
      p.basename(widget.root).isEmpty ? widget.root : p.basename(widget.root),
      0,
      root: true,
    );
    for (final volume in widget.volumes.where((v) => v.removable)) {
      visit(volume.path, volume.label, 0, root: true, removable: true);
    }
    return nodes;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.model,
    builder: (context, _) {
      final cs = Theme.of(context).colorScheme;
      final nodes = _nodes();
      return ListView.builder(
        key: const Key('fs-folder-tree'),
        controller: _scroll,
        padding: const EdgeInsets.symmetric(vertical: 6),
        itemExtent: 28,
        itemCount: nodes.length,
        itemBuilder: (context, i) {
          final (path, name, depth, root, removable) = nodes[i];
          final active = p.equals(path, widget.model.dir);
          final children = _children[path] ?? const <FsEntry>[];
          final expandable = _loading.contains(path) || children.isNotEmpty;
          final open = _expanded.contains(path);
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Material(
              color: active ? cs.secondaryContainer : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
              child: InkWell(
                key: Key('fs-tree:$path'),
                borderRadius: BorderRadius.circular(6),
                onTap: () => widget.onNavigate(path),
                child: Row(
                  children: [
                    SizedBox(width: depth * 12.0),
                    SizedBox(
                      width: 22,
                      child: expandable
                          ? InkResponse(
                              radius: 12,
                              onTap: () {
                                setState(() {
                                  if (open && !root) {
                                    _expanded.remove(path);
                                  } else {
                                    _expanded.add(path);
                                  }
                                });
                                if (!open || root) unawaited(_load(path));
                              },
                              child: _loading.contains(path)
                                  ? const SizedBox(
                                      width: 10,
                                      height: 10,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 1.5,
                                      ),
                                    )
                                  : Icon(
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
                      root
                          ? (removable ? Icons.usb_rounded : Icons.home_rounded)
                          : (active || open
                                ? Icons.folder_open_rounded
                                : Icons.folder_rounded),
                      size: 17,
                      color: root ? cs.primary : const Color(0xFFE0A526),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: active
                              ? FontWeight.w600
                              : FontWeight.normal,
                          color: active
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

// ---------------------------------------------------------------------------
// Archive path bar

class PathBar extends StatelessWidget {
  final ArchiveModel model;
  final TextEditingController filter;
  final FocusNode filterFocus;
  final VoidCallback? onBack;
  final VoidCallback? onUp;
  final void Function(ArchiveModel level, String dir) onLevel;
  final List<Widget> prefix;
  final PathEdit? edit;
  final bool compact;
  const PathBar({
    super.key,
    required this.model,
    required this.filter,
    required this.filterFocus,
    required this.onBack,
    required this.onUp,
    required this.onLevel,
    this.prefix = const [],
    this.edit,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: model,
      builder: (context, _) {
        final levels = model.levels;
        final last = levels.length - 1;
        Widget crumb(
          int k,
          String label,
          String path, {
          IconData? icon,
          Color? iconColor,
          String? tooltip,
        }) {
          final level = levels[k];
          final current = k == last && path == model.dir;
          if (icon == null && (level.archive[path]?.isNested ?? false)) {
            icon = Icons.snippet_folder_rounded;
            iconColor = kImageColor;
          }
          Widget w = InkWell(
            key: Key(k == last ? 'crumb:$path' : 'crumb$k:$path'),
            borderRadius: BorderRadius.circular(6),
            onTap: current ? null : () => onLevel(level, path),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 16, color: iconColor),
                    const SizedBox(width: 4),
                  ],
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: k == last ? double.infinity : 280,
                    ),
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: current
                            ? FontWeight.w600
                            : FontWeight.normal,
                        color: current ? cs.onSurface : cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
          if (k != last && label.length > 36) {
            tooltip = tooltip == null ? label : '$label ($tooltip)';
          }
          if (tooltip != null) w = Tooltip(message: tooltip, child: w);
          return w;
        }

        Widget sep() => Icon(
          Icons.chevron_right_rounded,
          size: 16,
          color: cs.onSurfaceVariant,
        );
        final crumbs = <Widget>[];
        for (var k = 0; k <= last; k++) {
          final level = levels[k];
          if (k == 0) {
            crumbs.add(
              crumb(
                0,
                level.displayName,
                '',
                icon: Icons.folder_zip_rounded,
                iconColor: cs.primary,
                tooltip: level.formats.join(' > '),
              ),
            );
          } else {
            crumbs.add(
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Icon(
                  Icons.keyboard_double_arrow_right_rounded,
                  key: Key('nest-boundary-$k'),
                  size: 16,
                  color: kImageColor,
                ),
              ),
            );
            crumbs.add(
              crumb(
                k,
                level.displayName,
                '',
                icon: Icons.storage_rounded,
                iconColor: kImageColor,
                tooltip: '${level.formats.join(' > ')} (read-only)',
              ),
            );
          }
          final dir = k == last ? level.dir : levels[k + 1].entry!.parent;
          final parts = dir.isEmpty ? const <String>[] : dir.split('/');
          for (var i = 0; i < parts.length; i++) {
            crumbs.add(sep());
            crumbs.add(crumb(k, parts[i], parts.sublist(0, i + 1).join('/')));
          }
        }
        return PathBarFrame(
          crumbs: [...prefix, ...crumbs],
          edit: edit,
          compact: compact,
          onBack: onBack,
          onForward: model.canForward ? model.forward : null,
          onUp: onUp,
          backTooltip: model.canBack || model.parent == null
              ? 'Back (Alt+Left)'
              : 'Back out of ${model.displayName} (Alt+Left)',
          upTooltip: model.canUp || model.parent == null
              ? 'Up one folder (Backspace)'
              : 'Up out of ${model.displayName} (Backspace)',
          filter: filter,
          filterFocus: filterFocus,
          filterHint: 'Filter this folder',
          filterActive: model.filter.isNotEmpty,
          onFilter: (v) => model.filter = v,
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Action bar

class ToolAction {
  final String id;
  final IconData icon;
  final String label;
  final String tooltip;
  final VoidCallback onPressed;
  const ToolAction(
    this.id,
    this.icon,
    this.label,
    this.tooltip,
    this.onPressed,
  );
}

class ActionBar extends StatelessWidget {
  final Widget? leading;
  final List<ToolAction?> actions;
  final Widget? trailing;
  const ActionBar({
    super.key,
    this.leading,
    required this.actions,
    this.trailing,
  });
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          ?leading,
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final action in actions)
                    if (action == null)
                      Container(
                        width: 1,
                        height: 20,
                        margin: const EdgeInsets.symmetric(horizontal: 6),
                        color: cs.outlineVariant,
                      )
                    else
                      Tooltip(
                        message: action.tooltip,
                        waitDuration: const Duration(milliseconds: 500),
                        child: TextButton.icon(
                          key: Key('tool-${action.id}'),
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            foregroundColor: cs.onSurface,
                            textStyle: const TextStyle(fontSize: 13),
                          ),
                          onPressed: action.onPressed,
                          icon: Icon(action.icon, size: 18, color: cs.primary),
                          label: Text(action.label),
                        ),
                      ),
                ],
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Status bar

class StatusBar extends StatelessWidget {
  final ArchiveModel? model;
  final String? message;
  final Widget? trailing;
  final String leftText;
  final String rightText;
  const StatusBar({
    super.key,
    required this.model,
    this.message,
    this.trailing,
    this.leftText = '',
    this.rightText = '',
  });
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final style = TextStyle(fontSize: 12, color: cs.onSurfaceVariant);
    final m = model;
    Widget body;
    if (m == null) {
      body = Row(
        children: [
          Expanded(
            child: Text(
              message ?? (leftText.isEmpty ? 'Ready' : leftText),
              key: const Key('status-left'),
              style: style,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(rightText, key: const Key('status-right'), style: style),
        ],
      );
    } else {
      body = ListenableBuilder(
        listenable: m,
        builder: (context, _) {
          final rows = m.rows;
          final sel = m.selectedItems;
          final selSize = sel.fold<int>(0, (sum, i) => sum + m.sizeOf(i));
          final total = rows.fold<int>(0, (sum, i) => sum + m.sizeOf(i));
          final a = m.archive;
          final left = sel.isEmpty
              ? '${rows.length} item${rows.length == 1 ? '' : 's'}, ${formatBytes(total)}'
              : '${sel.length} of ${rows.length} selected, ${formatBytes(selSize)}';
          final info = [
            if (m.parent != null)
              m.formats.join(' > ')
            else
              formatDescription(a),
            if (m.readOnlyReason != null && !m.isOldVersion) 'read-only',
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
              if (trailing != null) ...[const SizedBox(width: 8), trailing!],
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
                        for (final path in recent)
                          ListTile(
                            key: Key('recent:$path'),
                            dense: true,
                            leading: Icon(
                              Icons.folder_zip_outlined,
                              color: cs.primary,
                            ),
                            title: Text(p.basename(path)),
                            subtitle: Text(
                              p.dirname(path),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: () => onOpenRecent(path),
                            trailing: IconButton(
                              tooltip: 'Remove from the list',
                              icon: const Icon(Icons.close_rounded, size: 18),
                              onPressed: () => onRemoveRecent(path),
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
