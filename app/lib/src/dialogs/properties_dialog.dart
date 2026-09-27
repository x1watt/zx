// The archive information dialog (with the comment, editable where the
// format allows) and the properties of items.

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:zx/zx.dart';

import '../archive_model.dart';
import '../ui/format_utils.dart';

Widget _table(BuildContext context, List<(String, String)> rows) {
  final cs = Theme.of(context).colorScheme;
  return Table(
    columnWidths: const {0: IntrinsicColumnWidth(), 1: FlexColumnWidth()},
    defaultVerticalAlignment: TableCellVerticalAlignment.top,
    children: [
      for (final (k, v) in rows)
        TableRow(
          children: [
            Padding(
              padding: const EdgeInsets.only(right: 16, bottom: 6),
              child: Text(k, style: TextStyle(color: cs.onSurfaceVariant)),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: SelectableText(v.isEmpty ? '-' : v),
            ),
          ],
        ),
    ],
  );
}

String formatDescription(ZxArchive a) {
  final outer = a.outerFormats.where((f) => f != 'Split').toList();
  final base = outer.isEmpty
      ? a.format
      : '${a.format} in ${outer.join(' in ')}';
  return a.volumes.length > 1 ? '$base, ${a.volumes.length} volumes' : base;
}

/// Shows the archive information. [onSaveComment] saves a new comment
/// (null when the format can not store one); it returns an error text or
/// null.
Future<void> showArchiveInfoDialog(
  BuildContext context,
  ArchiveModel model, {
  Future<String?> Function(String comment)? onSaveComment,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) =>
        _ArchiveInfoDialog(model: model, onSaveComment: onSaveComment),
  );
}

class _ArchiveInfoDialog extends StatefulWidget {
  final ArchiveModel model;
  final Future<String?> Function(String comment)? onSaveComment;
  const _ArchiveInfoDialog({required this.model, this.onSaveComment});

  @override
  State<_ArchiveInfoDialog> createState() => _ArchiveInfoDialogState();
}

class _ArchiveInfoDialogState extends State<_ArchiveInfoDialog> {
  late final _comment = TextEditingController(
    text: widget.model.archive.comment ?? '',
  );
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.model.archive;
    final st = widget.model.statsOf('');
    final folders = a.items.where((i) => i.isDir).length;
    final encrypted = a.items.where((i) => i.encrypted).length;
    final c = a.capabilities;
    final caps = [
      if (c.canAdd) 'add',
      if (c.canDelete) 'delete',
      if (c.canRename) 'rename',
      if (c.canCreateFolder) 'new folders',
      if (c.canSetComment) 'comment',
      if (c.canEncrypt) 'encryption',
      if (c.canEncryptHeaders) 'encrypted names',
    ];
    final canComment = widget.onSaveComment != null;
    return AlertDialog(
      key: const Key('info-dialog'),
      icon: const Icon(Icons.info_outline_rounded),
      title: Text(p.basename(a.path)),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _table(context, [
                ('Location', p.dirname(a.path)),
                ('Format', formatDescription(a)),
                ('Method', a.method ?? ''),
                ('Solid', a.solid ? 'yes' : 'no'),
                ('Encrypted names', a.encryptedHeaders ? 'yes' : 'no'),
                ('Encrypted files', '$encrypted'),
                ('Archive size', formatBytes(a.physicalSize, exact: true)),
                ('Files', '${st.files}'),
                ('Folders', '$folders'),
                ('Unpacked size', formatBytes(st.size, exact: true)),
                if (st.size > 0 && st.packed > 0)
                  ('Ratio', formatRatio(st.packed / st.size)),
                if (a.volumes.length > 1)
                  ('Volumes', a.volumes.map(p.basename).join('\n')),
                (
                  'Changes allowed',
                  caps.isEmpty ? 'none (read only)' : caps.join(', '),
                ),
                if (a.errors.isNotEmpty) ('Errors', a.errors.join('\n')),
                if (a.warnings.isNotEmpty) ('Warnings', a.warnings.join('\n')),
              ]),
              if (canComment || _comment.text.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text('Comment', style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 6),
                TextField(
                  key: const Key('info-comment'),
                  controller: _comment,
                  readOnly: !canComment,
                  minLines: 3,
                  maxLines: 8,
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    hintText: canComment
                        ? 'No comment'
                        : 'This format can not store a comment',
                    errorText: _error,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        if (canComment)
          TextButton(
            key: const Key('info-save-comment'),
            onPressed: _saving
                ? null
                : () async {
                    setState(() => _saving = true);
                    final e = await widget.onSaveComment!(_comment.text);
                    if (!context.mounted) return;
                    setState(() {
                      _saving = false;
                      _error = e;
                    });
                    if (e == null) Navigator.of(context).pop();
                  },
            child: const Text('Save comment'),
          ),
        FilledButton(
          key: const Key('info-close'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

Future<void> showItemPropertiesDialog(
  BuildContext context,
  ArchiveModel model,
  List<ZxItem> items,
) {
  return showDialog<void>(
    context: context,
    builder: (context) {
      List<(String, String)> rows;
      String title;
      if (items.length == 1) {
        final i = items.first;
        title = i.name;
        final mode = i.posixMode;
        rows = [
          ('Path', i.path),
          (
            'Type',
            i.isDir ? (i.isImplied ? 'folder (implied)' : 'folder') : 'file',
          ),
          ('Size', formatBytes(model.sizeOf(i), exact: true)),
          ('Packed', formatBytes(model.packedOf(i), exact: true)),
          ('Ratio', formatRatio(model.ratioOf(i))),
          ('Modified', formatDate(i.modified)),
          if (i.created != null) ('Created', formatDate(i.created)),
          if (i.accessed != null) ('Accessed', formatDate(i.accessed)),
          if (!i.isDir) ('Method', i.method ?? ''),
          if (!i.isDir) ('Encrypted', i.encrypted ? 'yes' : 'no'),
          if (!i.isDir) ('CRC', formatCrc(i.crc)),
          if (i.attrib != null)
            ('Attributes', '0x${i.attrib!.toRadixString(16).toUpperCase()}'),
          if (mode != null)
            ('Mode', (mode & 0xFFF).toRadixString(8).padLeft(4, '0')),
          if (i.symlinkTarget != null) ('Link to', i.symlinkTarget!),
          if (i.hardlinkTarget != null) ('Hard link to', i.hardlinkTarget!),
          if (i.comment != null && i.comment!.isNotEmpty)
            ('Comment', i.comment!),
          if (i.index >= 0) ('Index', '${i.index}'),
        ];
      } else {
        title = '${items.length} items';
        var size = 0, packed = 0, files = 0, dirs = 0;
        for (final i in items) {
          size += model.sizeOf(i);
          packed += model.packedOf(i) ?? 0;
          if (i.isDir) {
            dirs++;
          } else {
            files++;
          }
        }
        rows = [
          ('Files', '$files'),
          ('Folders', '$dirs'),
          ('Size', formatBytes(size, exact: true)),
          ('Packed', formatBytes(packed, exact: true)),
        ];
      }
      return AlertDialog(
        key: const Key('item-properties'),
        icon: const Icon(Icons.description_outlined),
        title: Text(title),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(child: _table(context, rows)),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      );
    },
  );
}
