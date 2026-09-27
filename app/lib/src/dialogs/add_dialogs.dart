// The add dialog (files into the current folder of an open archive) and
// the new archive dialog (name, format, files, settings).

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:zx/zx.dart';

import '../formats.dart';
import '../services.dart';
import 'compression_form.dart';

/// A list of files and folders with buttons to add more.
class SourceList extends StatelessWidget {
  final List<String> sources;

  /// The entries of [sources] that are folders.
  final Set<String> folders;
  final VoidCallback onChanged;
  final FilePicker picker;
  final String? initialDirectory;
  const SourceList({
    super.key,
    required this.sources,
    required this.folders,
    required this.onChanged,
    required this.picker,
    this.initialDirectory,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          height: 120,
          decoration: BoxDecoration(
            border: Border.all(color: cs.outlineVariant),
            borderRadius: BorderRadius.circular(8),
          ),
          child: sources.isEmpty
              ? Center(
                  child: Text(
                    'No files yet: add files or a folder',
                    style: TextStyle(color: cs.onSurfaceVariant),
                  ),
                )
              : ListView.builder(
                  itemCount: sources.length,
                  itemBuilder: (_, i) {
                    final s = sources[i];
                    final dir = folders.contains(s);
                    return ListTile(
                      dense: true,
                      visualDensity: VisualDensity.compact,
                      leading: Icon(
                        dir
                            ? Icons.folder_rounded
                            : Icons.insert_drive_file_outlined,
                        size: 18,
                        color: dir ? const Color(0xFFE0A526) : null,
                      ),
                      title: Text(p.basename(s)),
                      subtitle: Text(
                        p.dirname(s),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: IconButton(
                        tooltip: 'Remove from the list',
                        icon: const Icon(Icons.close, size: 16),
                        onPressed: () {
                          sources.removeAt(i);
                          onChanged();
                        },
                      ),
                    );
                  },
                ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            OutlinedButton.icon(
              key: const Key('src-add-files'),
              icon: const Icon(Icons.note_add_outlined),
              label: const Text('Add files'),
              onPressed: () async {
                final f = await picker.pickFiles(
                  initialDirectory: initialDirectory,
                );
                for (final x in f) {
                  if (!sources.contains(x)) sources.add(x);
                }
                onChanged();
              },
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              key: const Key('src-add-folder'),
              icon: const Icon(Icons.create_new_folder_outlined),
              label: const Text('Add folder'),
              onPressed: () async {
                final d = await picker.pickFolder(
                  initialDirectory: initialDirectory,
                  title: 'Add',
                );
                if (d != null && !sources.contains(d)) {
                  sources.add(d);
                  folders.add(d);
                }
                onChanged();
              },
            ),
          ],
        ),
      ],
    );
  }
}

/// The entries of [paths] that are folders (read without blocking).
Future<Set<String>> foldersOf(Iterable<String> paths) async {
  final out = <String>{};
  for (final x in paths) {
    if (await FileSystemEntity.isDirectory(x)) out.add(x);
  }
  return out;
}

class AddRequest {
  final List<String> sources;
  final ZxOptions options;
  const AddRequest(this.sources, this.options);
}

Future<AddRequest?> showAddDialog(
  BuildContext context, {
  required List<String> sources,
  Set<String> folders = const {},
  required String archiveName,
  required String destination,
  required NewFormat format,
  required ZxCapabilities caps,
  required int defaultLevel,
  required FilePicker picker,
}) {
  return showDialog<AddRequest>(
    context: context,
    builder: (_) => _AddDialog(
      sources: [...sources],
      folders: {...folders},
      archiveName: archiveName,
      destination: destination,
      format: format,
      caps: caps,
      defaultLevel: defaultLevel,
      picker: picker,
    ),
  );
}

class _AddDialog extends StatefulWidget {
  final List<String> sources;
  final Set<String> folders;
  final String archiveName, destination;
  final NewFormat format;
  final ZxCapabilities caps;
  final int defaultLevel;
  final FilePicker picker;
  const _AddDialog({
    required this.sources,
    required this.folders,
    required this.archiveName,
    required this.destination,
    required this.format,
    required this.caps,
    required this.defaultLevel,
    required this.picker,
  });

  @override
  State<_AddDialog> createState() => _AddDialogState();
}

class _AddDialogState extends State<_AddDialog> {
  late final _settings = CompressionSettings(level: widget.defaultLevel);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      key: const Key('add-dialog'),
      icon: const Icon(Icons.add_box_outlined),
      title: const Text('Add to archive'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text.rich(
                TextSpan(
                  children: [
                    const TextSpan(text: 'Into '),
                    TextSpan(
                      text: '${widget.archiveName}/${widget.destination}',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              SourceList(
                sources: widget.sources,
                folders: widget.folders,
                picker: widget.picker,
                onChanged: () => setState(() {}),
              ),
              const SizedBox(height: 16),
              CompressionForm(
                format: widget.format,
                settings: _settings,
                canEncrypt: widget.caps.canEncrypt,
                canEncryptNames: false,
              ),
              const SizedBox(height: 8),
              Text(
                'Items with the same name are replaced.',
                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('add-ok'),
          onPressed: widget.sources.isEmpty
              ? null
              : () => Navigator.of(context).pop(
                  AddRequest(
                    widget.sources,
                    _settings.toOptions(
                      widget.format,
                      allowPassword: widget.caps.canEncrypt,
                    ),
                  ),
                ),
          child: const Text('Add'),
        ),
      ],
    );
  }
}

class NewArchiveRequest {
  final String path;
  final NewFormat format;
  final List<String> sources;
  final ZxOptions options;
  const NewArchiveRequest(this.path, this.format, this.sources, this.options);
}

Future<NewArchiveRequest?> showNewArchiveDialog(
  BuildContext context, {
  required String folder,
  required List<String> sources,
  Set<String> folders = const {},
  required String formatId,
  required int defaultLevel,
  required FilePicker picker,
}) {
  return showDialog<NewArchiveRequest>(
    context: context,
    builder: (_) => _NewArchiveDialog(
      folder: folder,
      sources: [...sources],
      folders: {...folders},
      formatId: formatId,
      defaultLevel: defaultLevel,
      picker: picker,
    ),
  );
}

class _NewArchiveDialog extends StatefulWidget {
  final String folder, formatId;
  final List<String> sources;
  final Set<String> folders;
  final int defaultLevel;
  final FilePicker picker;
  const _NewArchiveDialog({
    required this.folder,
    required this.sources,
    required this.folders,
    required this.formatId,
    required this.defaultLevel,
    required this.picker,
  });

  @override
  State<_NewArchiveDialog> createState() => _NewArchiveDialogState();
}

class _NewArchiveDialogState extends State<_NewArchiveDialog> {
  late NewFormat _format = newFormatById(widget.formatId);
  late final _folder = TextEditingController(text: widget.folder);
  late final _name = TextEditingController(text: _suggestName());
  late final _settings = CompressionSettings(level: widget.defaultLevel);
  bool _nameEdited = false;
  String? _error;

  String _suggestName() {
    final s = widget.sources;
    if (s.length == 1) return p.basenameWithoutExtension(s.first);
    if (s.isNotEmpty) return p.basename(p.dirname(s.first));
    return 'archive';
  }

  @override
  void dispose() {
    _folder.dispose();
    _name.dispose();
    super.dispose();
  }

  String get _path {
    var n = _name.text.trim();
    final ext = '.${_format.extension}';
    if (!n.toLowerCase().endsWith(ext)) n = '$n$ext';
    return p.join(_folder.text.trim(), n);
  }

  Future<void> _ok() async {
    final s = widget.sources;
    String? e;
    if (_name.text.trim().isEmpty) {
      e = 'Enter a name.';
    } else if (s.isEmpty) {
      e = 'Add at least one file or folder.';
    } else if (_format.singleFile &&
        (s.length != 1 || widget.folders.contains(s.first))) {
      e =
          '${_format.label} holds exactly one file: pick one file, or '
          'choose tar.${_format.extension} for several.';
    } else if (await File(_path).exists()) {
      e = '${p.basename(_path)} exists already.';
    }
    if (!mounted) return;
    if (e != null) {
      setState(() => _error = e);
      return;
    }
    Navigator.of(
      context,
    ).pop(NewArchiveRequest(_path, _format, s, _settings.toOptions(_format)));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      key: const Key('new-dialog'),
      icon: const Icon(Icons.create_new_folder_outlined),
      title: const Text('New archive'),
      content: SizedBox(
        width: 600,
        child: SingleChildScrollView(
          // room for the floating label of the first field
          padding: const EdgeInsets.only(top: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: TextField(
                      key: const Key('new-name'),
                      controller: _name,
                      autofocus: true,
                      onChanged: (_) => _nameEdited = true,
                      decoration: InputDecoration(
                        labelText: 'Name',
                        suffixText: '.${_format.extension}',
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: DropdownButtonFormField<String>(
                      key: const Key('new-format'),
                      initialValue: _format.id,
                      decoration: const InputDecoration(
                        labelText: 'Format',
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        for (final f in kNewFormats)
                          DropdownMenuItem(value: f.id, child: Text(f.label)),
                      ],
                      onChanged: (v) => setState(() {
                        _format = newFormatById(v ?? '7z');
                        _settings.method = null;
                      }),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('new-folder'),
                      controller: _folder,
                      decoration: const InputDecoration(
                        labelText: 'Save in folder',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: () async {
                      final d = await widget.picker.pickFolder(
                        initialDirectory: _folder.text,
                        title: 'Save here',
                      );
                      if (d != null) setState(() => _folder.text = d);
                    },
                    icon: const Icon(Icons.folder_open_outlined),
                    label: const Text('Browse'),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                'Files and folders',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const SizedBox(height: 6),
              SourceList(
                sources: widget.sources,
                folders: widget.folders,
                picker: widget.picker,
                initialDirectory: _folder.text,
                onChanged: () => setState(() {
                  if (!_nameEdited) _name.text = _suggestName();
                }),
              ),
              const SizedBox(height: 16),
              CompressionForm(
                key: ValueKey(_format.id),
                format: _format,
                settings: _settings,
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  key: const Key('new-error'),
                  style: TextStyle(color: cs.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('new-ok'),
          onPressed: _ok,
          child: const Text('Create'),
        ),
      ],
    );
  }
}
