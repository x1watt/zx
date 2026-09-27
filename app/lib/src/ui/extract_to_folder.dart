// The "Extract to folder" mode (zx_app --extract-to-folder a.zip b.7z):
// a small window that extracts each archive into a new folder named after
// it, next to it, asks for passwords when needed, and closes itself when
// everything went well.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:zx/zx.dart';

import '../dialogs/common_dialogs.dart';
import '../formats.dart';
import '../services.dart';
import 'format_utils.dart';

/// [dir]/[name], or name (2), name (3)... when that exists.
Future<String> uniqueFolder(String dir, String name) async {
  var k = 1;
  while (true) {
    final c = p.join(dir, k == 1 ? name : '$name ($k)');
    if (!await FileSystemEntity.isDirectory(c) &&
        !await File(c).exists() &&
        !await Link(c).exists()) {
      return c;
    }
    k++;
  }
}

class _Outcome {
  final String archive;
  final String? folder;
  final String? error;
  final List<ZxItemError> itemErrors;
  final bool cancelled;
  _Outcome(
    this.archive, {
    this.folder,
    this.error,
    this.itemErrors = const [],
    this.cancelled = false,
  });
  bool get ok => error == null && itemErrors.isEmpty && !cancelled;
}

class ExtractToFolderPage extends StatefulWidget {
  final List<String> archives;
  final Launcher launcher;

  /// Called when the window should close (exit code).
  final void Function(int code) onDone;

  const ExtractToFolderPage({
    super.key,
    required this.archives,
    required this.launcher,
    required this.onDone,
  });

  @override
  State<ExtractToFolderPage> createState() => _ExtractToFolderPageState();
}

class _ExtractToFolderPageState extends State<ExtractToFolderPage> {
  int _index = 0;
  ZxProgress? _progress;
  ZxCancelToken? _cancel;
  bool _stopAll = false;
  final List<_Outcome> _done = [];
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<String?> _askPassword(ZxPasswordRequest r) async {
    if (!mounted) return null;
    return showPasswordDialog(context, r);
  }

  Future<void> _run() async {
    for (var i = 0; i < widget.archives.length && !_stopAll; i++) {
      setState(() {
        _index = i;
        _progress = null;
      });
      _done.add(await _one(p.absolute(widget.archives[i])));
    }
    if (!mounted) return;
    setState(() => _finished = true);
    if (_done.every((o) => o.ok)) {
      await Future<void>.delayed(const Duration(milliseconds: 350));
      widget.onDone(0);
    }
  }

  Future<_Outcome> _one(String path) async {
    final cancel = ZxCancelToken();
    _cancel = cancel;
    String? folder;
    try {
      final a = await ZxArchive.open(
        path,
        onPassword: _askPassword,
        cancel: cancel,
      );
      folder = await uniqueFolder(p.dirname(path), folderNameFor(path));
      await Directory(folder).create(recursive: true);
      final r = await a.extract(
        folder,
        overwrite: ZxOverwrite.rename,
        onProgress: (pr) {
          if (mounted) setState(() => _progress = pr);
        },
        cancel: cancel,
      );
      return _Outcome(path, folder: folder, itemErrors: r.errors);
    } on SevenZipException catch (e) {
      final cancelled = e.kind == SevenZipError.cancelled;
      await _removeIfEmpty(folder);
      return _Outcome(
        path,
        folder: null,
        error: cancelled ? null : errorText(e),
        cancelled: cancelled,
      );
    } on FileSystemException catch (e) {
      await _removeIfEmpty(folder);
      return _Outcome(path, error: errorText(e));
    }
  }

  Future<void> _removeIfEmpty(String? folder) async {
    if (folder == null) return;
    try {
      final d = Directory(folder);
      if (await d.exists() && await d.list().isEmpty) await d.delete();
    } on FileSystemException {
      // leave it
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final n = widget.archives.length;
    final name = n == 0 ? '' : p.basename(widget.archives[_index]);
    Widget body;
    if (!_finished) {
      final f = _progress?.fraction;
      body = Column(
        key: const Key('etf-running'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Image.asset('assets/icon/zx-64.png', width: 32, height: 32),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Extracting $name',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.titleMedium,
                    ),
                    Text(
                      'to "${folderNameFor(name)}"'
                      '${n > 1 ? '  (${_index + 1} of $n)' : ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: cs.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(value: f ?? 0, minHeight: 8),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(
                  _progress?.currentFile ?? 'Opening...',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
              ),
              if (f != null)
                Text('${(f * 100).floor()}%', style: t.labelMedium),
            ],
          ),
          const Spacer(),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              key: const Key('etf-cancel'),
              onPressed: () {
                _stopAll = true;
                _cancel?.cancel();
              },
              child: const Text('Cancel'),
            ),
          ),
        ],
      );
    } else {
      final failed = _done.where((o) => !o.ok).toList();
      body = Column(
        key: const Key('etf-finished'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                failed.isEmpty
                    ? Icons.check_circle_outline_rounded
                    : Icons.error_outline_rounded,
                color: failed.isEmpty ? const Color(0xFF2E9D6A) : cs.error,
              ),
              const SizedBox(width: 8),
              Text(
                failed.isEmpty ? 'Done' : 'Some archives were not extracted',
                style: t.titleMedium,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView(
              children: [
                for (final o in _done)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(
                      '${p.basename(o.archive)}: '
                      '${o.cancelled ? 'cancelled' : o.error ?? (o.itemErrors.isEmpty ? 'extracted to ${p.basename(o.folder!)}' : '${o.itemErrors.length} errors (${o.itemErrors.take(3).map((e) => '${e.path}: ${itemErrorText(e)}').join('; ')})')}',
                      style: TextStyle(
                        fontSize: 13,
                        color: o.ok ? cs.onSurface : cs.error,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (_done.any((o) => o.folder != null))
                TextButton(
                  onPressed: () => widget.launcher.openFolder(
                    _done.lastWhere((o) => o.folder != null).folder!,
                  ),
                  child: const Text('Open folder'),
                ),
              const SizedBox(width: 8),
              FilledButton(
                key: const Key('etf-close'),
                onPressed: () => widget.onDone(failed.isEmpty ? 0 : 1),
                child: const Text('Close'),
              ),
            ],
          ),
        ],
      );
    }
    return Scaffold(
      body: Padding(padding: const EdgeInsets.all(18), child: body),
    );
  }
}
