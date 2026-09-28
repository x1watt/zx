// The database parts of the file views: the metadata of a file (zx_meta
// title, description and tags, zx_layers subtitles and transcripts,
// zx_media screenshots) for the Properties dialog and the preview pane,
// and the dialogs "Find similar files" (TLSH, similar()) and "Find by
// SHA-256". The queries run in the database's worker isolate.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:zx/zx.dart' show ZxDbException;

import '../db_session.dart';
import '../ui/format_utils.dart';

String _err(Object e) => e is ZxDbException ? e.message : '$e';

/// The metadata of the file at [path], loaded after [delay] (so a quick
/// change of the selection does not query every file on the way).
class FileMetaView extends StatefulWidget {
  final DbSession session;
  final String path;
  final Duration delay;

  /// Show a "No metadata" line instead of nothing when the file has none.
  final bool showEmpty;

  /// Around the metadata (not applied when nothing is shown).
  final EdgeInsets padding;

  /// A line under the metadata (when there is some).
  final bool divider;

  const FileMetaView({
    this.padding = EdgeInsets.zero,
    this.divider = false,
    super.key,
    required this.session,
    required this.path,
    this.delay = Duration.zero,
    this.showEmpty = false,
  });

  @override
  State<FileMetaView> createState() => _FileMetaViewState();
}

class _FileMetaViewState extends State<FileMetaView> {
  FileMeta? _meta;
  Object? _error;
  Timer? _timer;
  int _ticket = 0;

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_schedule);
    _schedule();
  }

  @override
  void didUpdateWidget(FileMetaView old) {
    super.didUpdateWidget(old);
    if (old.session != widget.session) {
      old.session.removeListener(_schedule);
      widget.session.addListener(_schedule);
    }
    if (old.path != widget.path || old.session != widget.session) {
      _meta = null;
      _schedule();
    }
  }

  @override
  void dispose() {
    widget.session.removeListener(_schedule);
    _timer?.cancel();
    super.dispose();
  }

  void _schedule() {
    _timer?.cancel();
    final t = ++_ticket;
    if (widget.delay == Duration.zero) {
      _load(t);
    } else {
      _timer = Timer(widget.delay, () => _load(t));
    }
  }

  Future<void> _load(int t) async {
    if (!widget.session.available) return;
    try {
      final m = await widget.session.fileMeta(widget.path);
      if (!mounted || t != _ticket) return;
      setState(() {
        _meta = m;
        _error = null;
      });
    } catch (e) {
      if (mounted && t == _ticket) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final m = _meta;
    if (_error != null) {
      return Padding(
        padding: widget.padding,
        child: Text(
          'Metadata: ${_err(_error!)}',
          style: TextStyle(fontSize: 12, color: cs.error),
        ),
      );
    }
    if (m == null) return const SizedBox.shrink();
    if (m.isEmpty) {
      return widget.showEmpty
          ? Text(
              'No metadata in the database',
              key: const Key('meta-empty'),
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            )
          : const SizedBox.shrink();
    }
    final label = TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w600,
      color: cs.onSurfaceVariant,
    );
    final body = Padding(
      padding: widget.padding,
      child: _content(m, label, cs),
    );
    if (!widget.divider) return body;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [body, Divider(height: 1, color: cs.outlineVariant)],
    );
  }

  Widget _content(FileMeta m, TextStyle label, ColorScheme cs) {
    return Column(
      key: const Key('file-meta'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (m.title != null)
          Text(
            m.title!,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
        if (m.description != null) ...[
          const SizedBox(height: 4),
          SelectableText(m.description!, style: const TextStyle(fontSize: 13)),
        ],
        if (m.mime != null) ...[
          const SizedBox(height: 4),
          Text('Type: ${m.mime}', style: const TextStyle(fontSize: 12)),
        ],
        if (m.tags.isNotEmpty) ...[
          const SizedBox(height: 6),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              for (final t in m.tags)
                Chip(
                  label: Text(t, style: const TextStyle(fontSize: 11)),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  padding: EdgeInsets.zero,
                ),
            ],
          ),
        ],
        if (m.layers.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text('Layers', style: label),
          for (final l in m.layers)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(
                children: [
                  Icon(
                    l.kind == 'subtitles'
                        ? Icons.subtitles_outlined
                        : Icons.notes_rounded,
                    size: 14,
                    color: cs.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      [
                        l.kind,
                        if (l.language != null) '(${l.language})',
                        if (l.file != null) l.file!,
                        if (l.tool != null) 'by ${l.tool}',
                      ].join(' '),
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
        ],
        if (m.media.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text('Screenshots and previews', style: label),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final x in m.media)
                Tooltip(
                  message: x.caption ?? x.kind,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: Image.memory(
                      x.data,
                      height: 84,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                      errorBuilder: (_, _, _) => Container(
                        width: 84,
                        height: 84,
                        color: cs.surfaceContainerHigh,
                        alignment: Alignment.center,
                        child: Text(
                          x.kind,
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

/// Lists the files nearest to [path] by TLSH distance; returns the path
/// the user chose to show, or null.
Future<String?> showSimilarFilesDialog(
  BuildContext context,
  DbSession session,
  String path,
) {
  return showDialog<String>(
    context: context,
    builder: (context) => _ResultsDialog<({String path, int distance})>(
      key: const Key('similar-dialog'),
      title: 'Files similar to ${path.split('/').last}',
      icon: Icons.compare_arrows_rounded,
      load: () => session.similar(path, n: 20),
      pathOf: (r) => r.path,
      trailing: (r) => 'distance ${r.distance}',
      emptyText:
          'No similar files (the file needs a TLSH digest: '
          '50 bytes or more, not too uniform).',
    ),
  );
}

/// Asks for a SHA-256 and lists the files with that content; returns the
/// path the user chose to show, or null.
Future<String?> showFindShaDialog(
  BuildContext context,
  DbSession session, {
  String initial = '',
}) {
  return showDialog<String>(
    context: context,
    builder: (context) => _FindShaDialog(session: session, initial: initial),
  );
}

class _FindShaDialog extends StatefulWidget {
  final DbSession session;
  final String initial;
  const _FindShaDialog({required this.session, required this.initial});

  @override
  State<_FindShaDialog> createState() => _FindShaDialogState();
}

class _FindShaDialogState extends State<_FindShaDialog> {
  late final _text = TextEditingController(text: widget.initial);
  List<({String path, int size})>? _found;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _find() async {
    if (parseSha256(_text.text) == null) {
      setState(() => _error = 'A SHA-256 is 64 hexadecimal digits.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await widget.session.bySha256(_text.text);
      if (mounted) setState(() => _found = r);
    } catch (e) {
      if (mounted) setState(() => _error = _err(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final f = _found;
    return AlertDialog(
      key: const Key('sha-dialog'),
      icon: const Icon(Icons.fingerprint_rounded),
      title: const Text('Find by SHA-256'),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const Key('sha-input'),
              controller: _text,
              autofocus: true,
              style: kMonoStyle.copyWith(fontSize: 13),
              decoration: InputDecoration(
                labelText: 'SHA-256 (hex)',
                errorText: _error,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              onSubmitted: (_) => _find(),
            ),
            const SizedBox(height: 10),
            if (_busy) const LinearProgressIndicator(),
            if (f != null && f.isEmpty)
              Text(
                'No file has this content.',
                key: const Key('sha-none'),
                style: TextStyle(color: cs.onSurfaceVariant),
              ),
            if (f != null && f.isNotEmpty)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final r in f)
                      ListTile(
                        key: Key('found:${r.path}'),
                        dense: true,
                        leading: const Icon(
                          Icons.insert_drive_file_outlined,
                          size: 18,
                        ),
                        title: Text(r.path),
                        trailing: Text(formatBytes(r.size)),
                        onTap: () => Navigator.of(context).pop(r.path),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        FilledButton(
          key: const Key('sha-find'),
          onPressed: _busy ? null : _find,
          child: const Text('Find'),
        ),
      ],
    );
  }
}

class _ResultsDialog<T> extends StatefulWidget {
  final String title;
  final IconData icon;
  final Future<List<T>> Function() load;
  final String Function(T) pathOf;
  final String Function(T) trailing;
  final String emptyText;

  const _ResultsDialog({
    super.key,
    required this.title,
    required this.icon,
    required this.load,
    required this.pathOf,
    required this.trailing,
    required this.emptyText,
  });

  @override
  State<_ResultsDialog<T>> createState() => _ResultsDialogState<T>();
}

class _ResultsDialogState<T> extends State<_ResultsDialog<T>> {
  List<T>? _rows;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.load().then(
      (r) {
        if (mounted) setState(() => _rows = r);
      },
      onError: (Object e) {
        if (mounted) setState(() => _error = _err(e));
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final r = _rows;
    Widget body;
    if (_error != null) {
      body = Text(_error!, style: TextStyle(color: cs.error));
    } else if (r == null) {
      body = const LinearProgressIndicator();
    } else if (r.isEmpty) {
      body = Text(
        widget.emptyText,
        key: const Key('results-empty'),
        style: TextStyle(color: cs.onSurfaceVariant),
      );
    } else {
      body = ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 420),
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final x in r)
              ListTile(
                key: Key('result:${widget.pathOf(x)}'),
                dense: true,
                leading: const Icon(Icons.insert_drive_file_outlined, size: 18),
                title: Text(widget.pathOf(x), overflow: TextOverflow.ellipsis),
                trailing: Text(widget.trailing(x)),
                onTap: () => Navigator.of(context).pop(widget.pathOf(x)),
              ),
          ],
        ),
      );
    }
    return AlertDialog(
      icon: Icon(widget.icon),
      title: Text(widget.title, overflow: TextOverflow.ellipsis),
      content: SizedBox(width: 560, child: body),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
