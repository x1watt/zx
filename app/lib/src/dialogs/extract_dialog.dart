// The extract dialog: destination, which items, paths, overwrite policy,
// open the folder afterwards.

import 'package:flutter/material.dart';
import 'package:zx/zx.dart';

import '../services.dart';

class ExtractOptions {
  final String destination;

  /// Only the selected items (else everything).
  final bool selectionOnly;
  final bool keepPaths;
  final ZxOverwrite overwrite;
  final bool openFolder;

  const ExtractOptions({
    required this.destination,
    required this.selectionOnly,
    required this.keepPaths,
    required this.overwrite,
    required this.openFolder,
  });
}

Future<ExtractOptions?> showExtractDialog(
  BuildContext context, {
  required String defaultDestination,
  required int selectedCount,
  required bool openFolderDefault,
  required FilePicker picker,
}) {
  return showDialog<ExtractOptions>(
    context: context,
    builder: (_) => ExtractDialog(
      defaultDestination: defaultDestination,
      selectedCount: selectedCount,
      openFolderDefault: openFolderDefault,
      picker: picker,
    ),
  );
}

class ExtractDialog extends StatefulWidget {
  final String defaultDestination;
  final int selectedCount;
  final bool openFolderDefault;
  final FilePicker picker;
  const ExtractDialog({
    super.key,
    required this.defaultDestination,
    required this.selectedCount,
    required this.openFolderDefault,
    required this.picker,
  });

  @override
  State<ExtractDialog> createState() => _ExtractDialogState();
}

class _ExtractDialogState extends State<ExtractDialog> {
  late final _dest = TextEditingController(text: widget.defaultDestination);
  late bool _selection = widget.selectedCount > 0;
  bool _keepPaths = true;
  ZxOverwrite _overwrite = ZxOverwrite.ask;
  late bool _open = widget.openFolderDefault;

  @override
  void dispose() {
    _dest.dispose();
    super.dispose();
  }

  Future<void> _browse() async {
    final d = await widget.picker.pickFolder(
      initialDirectory: _dest.text,
      title: 'Extract here',
    );
    if (d != null) setState(() => _dest.text = d);
  }

  void _ok() {
    if (_dest.text.trim().isEmpty) return;
    Navigator.of(context).pop(
      ExtractOptions(
        destination: _dest.text.trim(),
        selectionOnly: _selection,
        keepPaths: _keepPaths,
        overwrite: _overwrite,
        openFolder: _open,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return AlertDialog(
      key: const Key('extract-dialog'),
      scrollable: true,
      icon: const Icon(Icons.unarchive_outlined),
      title: const Text('Extract'),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('extract-dest'),
                    controller: _dest,
                    decoration: const InputDecoration(
                      labelText: 'Destination folder',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _browse,
                  icon: const Icon(Icons.folder_open_outlined),
                  label: const Text('Browse'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text('Files', style: t.labelLarge),
            RadioGroup<bool>(
              groupValue: _selection,
              onChanged: (v) => setState(() => _selection = v ?? false),
              child: Column(
                children: [
                  const RadioListTile<bool>(
                    key: Key('extract-all'),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: false,
                    title: Text('All files'),
                  ),
                  RadioListTile<bool>(
                    key: const Key('extract-selected'),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: true,
                    enabled: widget.selectedCount > 0,
                    title: Text('Selected items (${widget.selectedCount})'),
                  ),
                ],
              ),
            ),
            CheckboxListTile(
              key: const Key('extract-keep-paths'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _keepPaths,
              onChanged: (v) => setState(() => _keepPaths = v ?? true),
              title: const Text('Keep folder paths'),
              subtitle: const Text(
                'Off: every file goes into the destination itself',
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 16,
              children: [
                Text('When a file exists', style: t.labelLarge),
                DropdownButton<ZxOverwrite>(
                  key: const Key('extract-overwrite'),
                  value: _overwrite,
                  onChanged: (v) =>
                      setState(() => _overwrite = v ?? _overwrite),
                  items: const [
                    DropdownMenuItem(
                      value: ZxOverwrite.ask,
                      child: Text('Ask'),
                    ),
                    DropdownMenuItem(
                      value: ZxOverwrite.overwrite,
                      child: Text('Overwrite'),
                    ),
                    DropdownMenuItem(
                      value: ZxOverwrite.skip,
                      child: Text('Skip'),
                    ),
                    DropdownMenuItem(
                      value: ZxOverwrite.rename,
                      child: Text('Rename the new file'),
                    ),
                  ],
                ),
              ],
            ),
            CheckboxListTile(
              key: const Key('extract-open-folder'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _open,
              onChanged: (v) => setState(() => _open = v ?? false),
              title: const Text('Open the folder when done'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('extract-ok'),
          onPressed: _ok,
          child: const Text('Extract'),
        ),
      ],
    );
  }
}
