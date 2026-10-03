// The "New archive" dialog of the web version: name, compression (Auto or
// a curated Manual choice), solid, and a password. Built only against
// zx_client.dart/zx_web.dart-safe types (ZxWebCompression, a plain wire
// value) so it can be imported from main_web.dart's graph: the full
// compression picker of the desktop app (dialogs/compression_form.dart,
// dialogs/zx_compression.dart) imports package:zx/zx.dart, which
// test/web_safety_test.dart forbids there. The decision logic those build
// (ZxCompression, zcm:auto resolution) stays engine side
// (lib/src/web/zx_web_create.dart); this dialog only sends plain fields.

import 'package:flutter/material.dart';
import 'package:zx/zx_client.dart' show ZxWebCompression;

/// A curated subset of zx_compression.dart's manual methods: full control
/// (every zcm level, chain, memory budget, LSTM tuning) is desktop only
/// for now.
const _kManualMethods = <String>[
  'store',
  'zcm:1',
  'zcm:3',
  'zcm:5',
  'zcm:7',
  'zcm:9',
  'LZMA2',
];

String _methodLabel(String m) => switch (m) {
  'store' => 'Store (no compression)',
  'zcm:1' => 'zcm fastest',
  'zcm:3' => 'zcm fast',
  'zcm:5' => 'zcm normal',
  'zcm:7' => 'zcm max',
  'zcm:9' => 'zcm ultra (+ optional LSTM)',
  'LZMA2' => 'LZMA2',
  _ => m,
};

int? _zcmLevelOf(String m) =>
    m.startsWith('zcm:') ? int.tryParse(m.substring(4)) : null;

class NewArchiveResult {
  final String name;
  final ZxWebCompression compression;
  final bool solid;
  final String? password;
  const NewArchiveResult(
    this.name,
    this.compression,
    this.solid,
    this.password,
  );
}

/// Collects the settings of a new web .zx archive of [fileCount] files
/// ([totalBytes] together), suggesting [suggestedName] (without ".zx").
Future<NewArchiveResult?> showNewArchiveDialog(
  BuildContext context, {
  required int fileCount,
  required int totalBytes,
  required String suggestedName,
}) => showDialog<NewArchiveResult>(
  context: context,
  builder: (_) => _NewArchiveDialog(
    fileCount: fileCount,
    totalBytes: totalBytes,
    suggestedName: suggestedName,
  ),
);

class _NewArchiveDialog extends StatefulWidget {
  final int fileCount;
  final int totalBytes;
  final String suggestedName;
  const _NewArchiveDialog({
    required this.fileCount,
    required this.totalBytes,
    required this.suggestedName,
  });

  @override
  State<_NewArchiveDialog> createState() => _NewArchiveDialogState();
}

class _NewArchiveDialogState extends State<_NewArchiveDialog> {
  late final _name = TextEditingController(text: widget.suggestedName);
  late final _pw = TextEditingController();
  bool _showPw = false;

  bool _auto = true;
  String _speed = 'balanced';
  String _method = 'zcm:5';
  bool _lstm = false;
  bool _solid = true;

  @override
  void dispose() {
    _name.dispose();
    _pw.dispose();
    super.dispose();
  }

  ZxWebCompression get _compression {
    if (_auto) return ZxWebCompression.auto(speed: _speed);
    final level = _zcmLevelOf(_method);
    if (level == null) return ZxWebCompression.chain(_method);
    return ZxWebCompression.zcm(level, lstm: _lstm && level == 9);
  }

  void _ok() {
    var n = _name.text.trim();
    if (n.isEmpty) n = 'archive';
    if (!n.toLowerCase().endsWith('.zx')) n = '$n.zx';
    Navigator.of(context).pop(
      NewArchiveResult(
        n,
        _compression,
        _solid,
        _pw.text.isEmpty ? null : _pw.text,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final level = _zcmLevelOf(_method);
    return AlertDialog(
      key: const Key('web-new-dialog'),
      icon: const Icon(Icons.create_new_folder_outlined),
      title: const Text('New archive'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${widget.fileCount} file${widget.fileCount == 1 ? '' : 's'}, '
                '${_bytesText(widget.totalBytes)}',
                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('web-new-name'),
                controller: _name,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  suffixText: '.zx',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Text(
                    'Compression',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  const Spacer(),
                  SegmentedButton<bool>(
                    key: const Key('web-new-mode'),
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: true, label: Text('Auto')),
                      ButtonSegment(value: false, label: Text('Manual')),
                    ],
                    selected: {_auto},
                    onSelectionChanged: (v) => setState(() => _auto = v.first),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              if (_auto)
                SegmentedButton<String>(
                  key: const Key('web-new-speed'),
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: 'fast', label: Text('Fast')),
                    ButtonSegment(value: 'balanced', label: Text('Balanced')),
                    ButtonSegment(value: 'max', label: Text('Automatic best')),
                  ],
                  selected: {_speed},
                  onSelectionChanged: (v) => setState(() => _speed = v.first),
                )
              else ...[
                DropdownButton<String>(
                  key: const Key('web-new-method'),
                  isExpanded: true,
                  value: _method,
                  onChanged: (v) => setState(() => _method = v ?? 'zcm:5'),
                  items: [
                    for (final m in _kManualMethods)
                      DropdownMenuItem(value: m, child: Text(_methodLabel(m))),
                  ],
                ),
                if (level == 9)
                  CheckboxListTile(
                    key: const Key('web-new-lstm'),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: _lstm,
                    onChanged: (v) => setState(() => _lstm = v ?? false),
                    title: const Text('LSTM (a little smaller, much slower)'),
                  ),
              ],
              const SizedBox(height: 8),
              CheckboxListTile(
                key: const Key('web-new-solid'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _solid,
                onChanged: (v) => setState(() => _solid = v ?? true),
                title: const Text('Solid archive (smaller, slower to update)'),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const Key('web-new-password'),
                controller: _pw,
                obscureText: !_showPw,
                decoration: InputDecoration(
                  labelText: 'Password (empty: no encryption)',
                  isDense: true,
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _showPw
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                    ),
                    onPressed: () => setState(() => _showPw = !_showPw),
                  ),
                ),
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
          key: const Key('web-new-ok'),
          onPressed: widget.fileCount == 0 ? null : _ok,
          child: const Text('Create'),
        ),
      ],
    );
  }
}

String _bytesText(int b) {
  if (b >= 1 << 30) return '${(b / (1 << 30)).toStringAsFixed(1)} GiB';
  if (b >= 1 << 20) return '${(b / (1 << 20)).round()} MiB';
  if (b >= 1 << 10) return '${(b / (1 << 10)).round()} KiB';
  return '$b B';
}
