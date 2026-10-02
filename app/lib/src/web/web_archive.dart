// The archive pane of the web version: the path bar of the levels (nested
// archives) and folders, the list of the folder (FileList), the preview
// with READMEs (PreviewPane), the seal badge, and the Data view of a .zx
// archive with a database. Everything is read only; files are downloaded.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:zx/zx_client.dart';

import '../archive_model.dart';
import '../db_session.dart';
import '../ui/data_view.dart';
import '../ui/file_list.dart';
import '../ui/format_utils.dart';
import '../ui/path_bar.dart';
import '../ui/preview_pane.dart';
import '../ui/save_text.dart';
import '../ui/seal_badge.dart';
import 'web_services.dart';

/// A command of the archive pane: a labelled button where there is room,
/// an icon with a tooltip otherwise.
class WebAction {
  final Key key;
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  const WebAction(this.key, this.icon, this.label, this.onPressed);

  Widget build({required bool labelled}) => labelled
      ? TextButton.icon(
          key: key,
          onPressed: onPressed,
          icon: Icon(icon, size: 18),
          label: Text(label),
        )
      : IconButton(
          key: key,
          tooltip: label,
          visualDensity: VisualDensity.compact,
          onPressed: onPressed,
          icon: Icon(icon, size: 20),
        );
}

class WebArchiveView extends StatefulWidget {
  /// The level shown (its parents are the archives it was opened from).
  final ArchiveModel model;

  /// The database session of the archive file, when it is a .zx archive.
  final DbSession? db;

  /// Opens [item] of the current level as a nested archive; false when it
  /// is not one.
  final Future<bool> Function(ZxItem item) onOpenNested;

  /// Goes to another level (an archive the current one was opened from).
  final void Function(ArchiveModel level, String dir) onLevel;

  /// The actions of the source (Keep in library, Share link, Close), after
  /// those of the archive.
  final List<WebAction> actions;

  /// A line about the source (where the archive is read from).
  final String? sourceText;

  const WebArchiveView({
    super.key,
    required this.model,
    required this.db,
    required this.onOpenNested,
    required this.onLevel,
    this.actions = const [],
    this.sourceText,
  });

  @override
  State<WebArchiveView> createState() => _WebArchiveViewState();
}

class _WebArchiveViewState extends State<WebArchiveView> {
  final _listFocus = FocusNode();
  final _filter = TextEditingController();
  final _filterFocus = FocusNode();
  bool _data = false;

  // the share of the width the preview takes beside the list (the divider
  // between them can be dragged)
  double _previewShare = 0.45;
  String? _busy;
  ZxProgress? _progress;
  ZxCancelToken? _cancel;

  ArchiveModel get m => widget.model;

  @override
  void didUpdateWidget(WebArchiveView old) {
    super.didUpdateWidget(old);
    if (old.model != widget.model) {
      _filter.clear();
      _data = false;
    }
  }

  @override
  void dispose() {
    _listFocus.dispose();
    _filter.dispose();
    _filterFocus.dispose();
    super.dispose();
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<T?> _run<T>(
    String what,
    Future<T> Function(ZxCancelToken cancel) body,
  ) async {
    final c = ZxCancelToken();
    setState(() {
      _busy = what;
      _progress = null;
      _cancel = c;
    });
    try {
      return await body(c);
    } catch (e) {
      if (!(e is SevenZipException && e.kind == SevenZipError.cancelled)) {
        _snack('$what: ${errorText(e)}');
      }
      return null;
    } finally {
      if (mounted) {
        setState(() {
          _busy = null;
          _cancel = null;
        });
      }
    }
  }

  Future<void> _openItem(ZxItem item) async {
    if (item.isDir && !item.isNested) {
      m.navigate(item.path);
      return;
    }
    final nested = await _run(
      'Opening ${item.name}',
      (_) => widget.onOpenNested(item),
    );
    if (nested == false) {
      // not an archive: shown in the preview
      m.selectPaths([item.path]);
    }
  }

  /// Downloads the selected files (folders are left out).
  Future<void> _download([List<ZxItem>? items]) async {
    final files = [
      for (final i in items ?? m.selectedItems)
        if (!i.isDir) i,
    ];
    if (files.isEmpty) {
      _snack('Select one or more files to download.');
      return;
    }
    await _run('Downloading', (cancel) async {
      for (final f in files) {
        final bytes = await m.archive.readBytes(f, cancel: cancel);
        await saveBytes(f.name, bytes);
      }
    });
  }

  Future<void> _test() async {
    final r = await _run(
      'Testing',
      (cancel) => m.archive.test(
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
        cancel: cancel,
      ),
    );
    if (r == null || !mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        icon: Icon(
          r.ok ? Icons.verified_rounded : Icons.error_outline_rounded,
          color: r.ok ? Colors.green : Theme.of(context).colorScheme.error,
        ),
        title: Text(r.ok ? 'No errors' : '${r.errors.length} errors'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520, maxHeight: 320),
          child: SingleChildScrollView(
            child: Text(
              [
                '${r.files} files, ${formatBytes(r.bytes)} checked.',
                for (final e in r.errors.take(50)) itemErrorText(e),
              ].join('\n'),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _readmeInternal(ReadmeInternal t) {
    final item = t.path.isEmpty ? null : m.archive[t.path];
    if (t.path.isEmpty || (item != null && item.isDir)) {
      m.navigate(t.path);
      return;
    }
    if (item == null) {
      _snack('${t.url}: not in the archive');
      return;
    }
    if (m.dir != item.parent) m.navigate(item.parent);
    m.selectPaths([item.path]);
  }

  Future<void> _readmeExternal(String url) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.open_in_new_rounded),
        title: const Text('Open this link?'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: SelectableText(url),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Open'),
          ),
        ],
      ),
    );
    if (ok == true) await const WebLauncher().openUrl(url);
  }

  Future<void> _contextMenu(ZxItem? item, Offset at) async {
    if (item == null) return;
    if (!m.selection.contains(item.path)) m.selectPaths([item.path]);
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: [
        if (item.isDir && !item.isNested)
          const PopupMenuItem(value: 'open', child: Text('Open folder'))
        else ...[
          const PopupMenuItem(value: 'nested', child: Text('Open as archive')),
          const PopupMenuItem(value: 'download', child: Text('Download')),
        ],
      ],
    );
    switch (choice) {
      case 'open':
        m.navigate(item.path);
      case 'nested':
        unawaited(_openItem(item));
      case 'download':
        unawaited(_download());
    }
  }

  List<Widget> _crumbs(BuildContext context) {
    final levels = m.levels;
    final out = <Widget>[];
    for (var k = 0; k < levels.length; k++) {
      final level = levels[k];
      final last = k == levels.length - 1;
      if (out.isNotEmpty) out.add(crumbSeparator(context));
      out.add(
        crumbButton(
          context,
          bold: false,
          key: Key('level$k'),
          label: level.displayName,
          icon: k == 0
              ? Icons.inventory_2_rounded
              : Icons.snippet_folder_rounded,
          iconColor: k == 0 ? null : kImageColor,
          current: last && m.dir.isEmpty,
          onTap: () => widget.onLevel(level, ''),
        ),
      );
      if (!last) continue;
      var path = '';
      for (final part in m.dir.isEmpty ? const <String>[] : m.dir.split('/')) {
        path = path.isEmpty ? part : '$path/$part';
        final p = path;
        out
          ..add(crumbSeparator(context))
          ..add(
            crumbButton(
              context,
              bold: false,
              key: Key('crumb:$p'),
              label: part,
              current: p == m.dir,
              onTap: () => m.navigate(p),
            ),
          );
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final db = widget.db;
    final hasData = db != null && db.available && m.parent == null;
    return ListenableBuilder(
      listenable: Listenable.merge([m, ?db]),
      builder: (context, _) {
        final narrow = MediaQuery.sizeOf(context).width < 760;
        final list = _data && hasData
            ? DataView(session: db, picker: const WebFilePicker())
            : FileList(
                model: m,
                focusNode: _listFocus,
                onOpen: _openItem,
                onContextMenu: _contextMenu,
              );
        final width = MediaQuery.sizeOf(context).width;
        final actions = [
          WebAction(
            const Key('web-download'),
            Icons.download_rounded,
            'Download',
            _busy == null ? _download : null,
          ),
          WebAction(
            const Key('web-test'),
            Icons.fact_check_outlined,
            'Test',
            _busy == null ? _test : null,
          ),
          if (hasData)
            WebAction(
              const Key('web-data'),
              _data ? Icons.folder_open_rounded : Icons.table_chart_outlined,
              _data ? 'Files' : 'Data',
              () => setState(() => _data = !_data),
            ),
          ...widget.actions,
        ];
        // labels when the window is wide enough for them beside the path
        final labelled = width >= 1500;
        return Column(
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(4, narrow ? 4 : 6, 4, 2),
              child: PathBarFrame(
                crumbs: _crumbs(context),
                edit: null,
                compact: narrow,
                onBack: m.canBack ? m.back : null,
                onForward: m.canForward ? m.forward : null,
                onUp: m.canUp
                    ? m.up
                    : m.parent != null
                    ? () => widget.onLevel(m.parent!, m.parent!.dir)
                    : null,
                backTooltip: 'Back',
                upTooltip: 'Up',
                filter: _filter,
                filterFocus: _filterFocus,
                filterHint: 'Filter',
                filterActive: m.filter.isNotEmpty,
                onFilter: (t) => m.filter = t,
                trailing: narrow
                    ? null
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(width: 6),
                          for (final a in actions) a.build(labelled: labelled),
                        ],
                      ),
              ),
            ),
            if (narrow)
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [for (final a in actions) a.build(labelled: true)],
                ),
              ),
            const Divider(),
            Expanded(
              child: narrow || _data
                  ? list
                  : LayoutBuilder(
                      builder: (context, box) {
                        final w = box.maxWidth;
                        final most = w - 320 < 280 ? 280.0 : w - 320;
                        final preview = (w * _previewShare).clamp(280.0, most);
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(child: list),
                            _splitter(cs, (dx) {
                              setState(() {
                                _previewShare = ((preview - dx) / w).clamp(
                                  0.2,
                                  0.75,
                                );
                              });
                            }),
                            SizedBox(
                              width: preview,
                              child: PreviewPane(
                                model: m,
                                db: m.parent == null ? db : null,
                                onInternalLink: _readmeInternal,
                                onExternalLink: _readmeExternal,
                              ),
                            ),
                          ],
                        );
                      },
                    ),
            ),
            const Divider(),
            Container(
              height: 30,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              color: cs.surfaceContainerLow,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _statusText(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                  if (_cancel != null)
                    TextButton(
                      onPressed: () => _cancel?.cancel(),
                      child: const Text('Cancel'),
                    ),
                  SealBadge(archive: m.root.archive),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  /// The divider between the list and the preview; dragging it moves it.
  Widget _splitter(ColorScheme cs, void Function(double dx) onDrag) =>
      MouseRegion(
        cursor: SystemMouseCursors.resizeColumn,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragUpdate: (d) => onDrag(d.delta.dx),
          child: SizedBox(
            width: 7,
            child: Center(child: Container(width: 1, color: cs.outlineVariant)),
          ),
        ),
      );

  String _statusText() {
    final busy = _busy;
    if (busy != null) {
      final f = _progress?.fraction;
      return f == null ? '$busy...' : '$busy... ${(f * 100).round()}%';
    }
    final rows = m.rows;
    final sel = m.selection.length;
    final parts = [
      '${rows.length} items',
      if (sel > 0) '$sel selected (${formatBytes(m.selectedSize)})',
      m.formats.join(' / '),
      formatBytes(m.archive.physicalSize),
      ?widget.sourceText,
    ];
    return parts.join('   ');
  }
}
