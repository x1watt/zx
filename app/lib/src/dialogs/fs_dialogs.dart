// The dialogs of the file system side of the explorer: a name that
// exists at the destination (overwrite, skip, keep both, for all), the
// properties of files and folders (size of a folder and SHA-256 computed
// on demand in a worker isolate), and the "Open with" list.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../fs/fs_model.dart';
import '../fs/fs_ops.dart';
import '../platform/places.dart';
import '../ui/format_utils.dart';

Future<FsConflictAnswer> showFsConflictDialog(
  BuildContext context,
  FsConflict c, {
  bool allowRename = true,
}) async {
  var all = false;
  final r = await showDialog<FsConflictAction>(
    context: context,
    barrierDismissible: false,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        key: const Key('conflict-dialog'),
        title: Text(
          c.targetIsDir && c.sourceIsDir
              ? 'The folder "${p.basename(c.target)}" exists'
              : '"${p.basename(c.target)}" exists already',
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              c.targetIsDir && c.sourceIsDir
                  ? 'Replace merges the folders: files with the same name '
                        'are asked for one by one.'
                  : 'In ${p.dirname(c.target)}',
            ),
            const SizedBox(height: 12),
            CheckboxListTile(
              key: const Key('conflict-all'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: all,
              onChanged: (v) => setState(() => all = v ?? false),
              title: const Text('Do this for all conflicts'),
            ),
          ],
        ),
        actions: [
          TextButton(
            key: const Key('conflict-cancel'),
            onPressed: () => Navigator.pop(context, FsConflictAction.cancel),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const Key('conflict-skip'),
            onPressed: () => Navigator.pop(context, FsConflictAction.skip),
            child: const Text('Skip'),
          ),
          if (allowRename)
            TextButton(
              key: const Key('conflict-rename'),
              onPressed: () => Navigator.pop(context, FsConflictAction.rename),
              child: const Text('Keep both'),
            ),
          FilledButton(
            key: const Key('conflict-overwrite'),
            onPressed: () => Navigator.pop(context, FsConflictAction.overwrite),
            child: const Text('Replace'),
          ),
        ],
      ),
    ),
  );
  return FsConflictAnswer(r ?? FsConflictAction.cancel, all: all);
}

/// The permission bits as "rwxr-xr-x".
String modeString(int mode) {
  const s = 'rwxrwxrwx';
  final b = StringBuffer();
  for (var i = 0; i < 9; i++) {
    b.write(mode & (1 << (8 - i)) != 0 ? s[i] : '-');
  }
  return b.toString();
}

Future<void> showFsPropertiesDialog(
  BuildContext context,
  List<FsEntry> entries,
) => showDialog<void>(
  context: context,
  builder: (_) => _FsProperties(entries: entries),
);

class _FsProperties extends StatefulWidget {
  final List<FsEntry> entries;
  const _FsProperties({required this.entries});

  @override
  State<_FsProperties> createState() => _FsPropertiesState();
}

class _FsPropertiesState extends State<_FsProperties> {
  FileStat? _stat;
  (int, int, int)? _size;
  String? _sha;
  bool _hashing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final l = widget.entries;
    if (l.length == 1) {
      final st = await FileStat.stat(l.first.path);
      if (mounted) setState(() => _stat = st);
    }
    var bytes = 0, files = 0, dirs = 0;
    for (final e in l) {
      if (e.isDir) {
        final (b, f, d) = await folderSize(e.path);
        bytes += b;
        files += f;
        dirs += d + 1;
      } else {
        bytes += e.size;
        files++;
      }
    }
    if (mounted) setState(() => _size = (bytes, files, dirs));
  }

  Future<void> _hash() async {
    setState(() => _hashing = true);
    try {
      final h = await sha256OfFile(widget.entries.first.path);
      if (mounted) setState(() => _sha = h);
    } on FileSystemException catch (e) {
      if (mounted) setState(() => _sha = 'error: ${e.message}');
    } finally {
      if (mounted) setState(() => _hashing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l = widget.entries;
    final one = l.length == 1 ? l.first : null;
    final st = _stat;
    final sz = _size;
    Widget row(String k, String v, {Key? key, bool mono = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(k, style: TextStyle(color: cs.onSurfaceVariant)),
          ),
          Expanded(
            child: SelectableText(v, key: key, style: mono ? kMonoStyle : null),
          ),
        ],
      ),
    );
    return AlertDialog(
      key: const Key('fs-properties'),
      title: Text(one?.name ?? '${l.length} items'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (one != null) ...[
              row('Type', typeOf(one)),
              row('Location', p.dirname(one.path)),
            ],
            row(
              'Size',
              sz == null
                  ? 'Counting...'
                  : '${formatBytes(sz.$1)} (${formatBytes(sz.$1, exact: true)})'
                        '${l.any((e) => e.isDir) ? ', ${sz.$2} files, ${sz.$3} folders' : ''}',
              key: const Key('prop-size'),
            ),
            if (st != null) ...[
              row('Modified', formatDate(st.modified)),
              row('Accessed', formatDate(st.accessed)),
              row('Changed', formatDate(st.changed)),
              if (!Platform.isWindows)
                row(
                  'Permissions',
                  '${modeString(st.mode)}  (${(st.mode & 0x1ff).toRadixString(8)})',
                ),
            ],
            if (one != null && !one.isDir) ...[
              const SizedBox(height: 8),
              if (_sha != null)
                row('SHA-256', _sha!, key: const Key('prop-sha'), mono: true)
              else
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    key: const Key('compute-sha'),
                    onPressed: _hashing ? null : _hash,
                    icon: _hashing
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.fingerprint_rounded, size: 18),
                    label: const Text('Compute SHA-256'),
                  ),
                ),
            ],
          ],
        ),
      ),
      actions: [
        if (_sha != null)
          TextButton(
            onPressed: () => Clipboard.setData(ClipboardData(text: _sha!)),
            child: const Text('Copy hash'),
          ),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

/// The programs that can open a file; the one chosen, or null.
Future<AppChoice?> showOpenWithDialog(
  BuildContext context,
  String name,
  List<AppChoice> apps,
) => showDialog<AppChoice>(
  context: context,
  builder: (context) => SimpleDialog(
    title: Text('Open "$name" with'),
    children: [
      if (apps.isEmpty)
        const Padding(
          padding: EdgeInsets.all(24),
          child: Text('No program is registered for this type of file.'),
        ),
      for (final a in apps)
        SimpleDialogOption(
          onPressed: () => Navigator.pop(context, a),
          child: Text(a.name),
        ),
    ],
  ),
);
