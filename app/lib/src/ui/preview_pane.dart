// The preview of the selected file: the start of a text file, an image, or
// a hex dump. The bytes are read by ZxArchive.readBytes in a background
// isolate, capped, and the read is cancelled when the selection changes.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:zx/zx.dart';

import '../archive_model.dart';
import '../db_session.dart';
import '../dialogs/db_dialogs.dart';
import 'format_utils.dart';

const _maxPreviewBytes = 512 * 1024;
const _maxTextChars = 64 * 1024;

class PreviewPane extends StatefulWidget {
  final ArchiveModel model;

  /// The archive's database: the file's metadata is shown above the
  /// preview.
  final DbSession? db;
  const PreviewPane({super.key, required this.model, this.db});

  @override
  State<PreviewPane> createState() => _PreviewPaneState();
}

enum _Kind {
  none,
  loading,
  text,
  image,
  binary,
  error,
  encrypted,
  folder,
  many,
}

class _PreviewPaneState extends State<PreviewPane> {
  _Kind _kind = _Kind.none;
  ZxItem? _item;
  String _text = '';
  Uint8List? _bytes;
  ZxCancelToken? _cancel;
  Timer? _debounce;
  int _gen = -1;

  @override
  void initState() {
    super.initState();
    widget.model.addListener(_onModel);
    _onModel();
  }

  @override
  void didUpdateWidget(PreviewPane old) {
    super.didUpdateWidget(old);
    if (old.model != widget.model) {
      old.model.removeListener(_onModel);
      widget.model.addListener(_onModel);
      _onModel();
    }
  }

  @override
  void dispose() {
    widget.model.removeListener(_onModel);
    _cancel?.cancel();
    _debounce?.cancel();
    super.dispose();
  }

  void _onModel() {
    final m = widget.model;
    final sel = m.selectedItems;
    final item = sel.length == 1 ? sel.first : null;
    if (item?.path == _item?.path && m.generation == _gen && item != null) {
      return;
    }
    _gen = m.generation;
    _cancel?.cancel();
    _cancel = null;
    _debounce?.cancel();
    _item = item;
    if (item == null) {
      _set(sel.length > 1 ? _Kind.many : _Kind.none);
      return;
    }
    if (item.isDir) {
      _set(_Kind.folder);
      return;
    }
    if (item.encrypted && m.archive.password == null) {
      _set(_Kind.encrypted);
      return;
    }
    _set(_Kind.loading);
    _debounce = Timer(const Duration(milliseconds: 180), () => _load(item));
  }

  void _set(_Kind k) {
    if (!mounted) return;
    setState(() => _kind = k);
  }

  Future<void> _load(ZxItem item) async {
    final cancel = ZxCancelToken();
    _cancel = cancel;
    try {
      final b = await widget.model.archive.readBytes(
        item,
        maxBytes: _maxPreviewBytes,
        cancel: cancel,
      );
      if (!mounted || _item?.path != item.path || cancel.isCancelled) return;
      _bytes = b;
      if (isImageName(item.name)) {
        _set(_Kind.image);
        return;
      }
      final head = b.length > 8192 ? b.sublist(0, 8192) : b;
      final binary =
          head.contains(0) ||
          head.where((c) => c < 9 || (c > 13 && c < 32)).length >
              head.length ~/ 20;
      if (binary && !isTextName(item.name)) {
        _set(_Kind.binary);
        return;
      }
      final part = b.length > _maxTextChars ? b.sublist(0, _maxTextChars) : b;
      _text = utf8.decode(part, allowMalformed: true);
      _set(_Kind.text);
    } catch (e) {
      if (!mounted || _item?.path != item.path || cancel.isCancelled) return;
      _text = errorText(e);
      _set(_Kind.error);
    }
  }

  String _hex(Uint8List b) {
    final n = b.length < 512 ? b.length : 512;
    final sb = StringBuffer();
    for (var off = 0; off < n; off += 16) {
      sb.write(off.toRadixString(16).padLeft(6, '0'));
      sb.write('  ');
      final end = off + 16 < n ? off + 16 : n;
      for (var i = off; i < off + 16; i++) {
        sb.write(i < end ? b[i].toRadixString(16).padLeft(2, '0') : '  ');
        sb.write(i == off + 7 ? '  ' : ' ');
      }
      sb.write(' ');
      for (var i = off; i < end; i++) {
        final c = b[i];
        sb.writeCharCode(c >= 32 && c < 127 ? c : 46);
      }
      sb.writeln();
    }
    return sb.toString();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final item = _item;
    Widget center(IconData icon, String text) => Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 40,
              color: cs.onSurfaceVariant.withValues(alpha: 0.6),
            ),
            const SizedBox(height: 8),
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(color: cs.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
    const mono = kMonoStyle;
    Widget body;
    switch (_kind) {
      case _Kind.none:
        body = center(Icons.preview_outlined, 'Select a file to preview it');
      case _Kind.many:
        body = center(
          Icons.select_all_rounded,
          '${widget.model.selection.length} items selected',
        );
      case _Kind.folder:
        final st = widget.model.statsOf(item!.path);
        body = center(
          Icons.folder_rounded,
          '${item.name}\n${st.files} ${st.files == 1 ? 'file' : 'files'}, ${formatBytes(st.size)}',
        );
      case _Kind.encrypted:
        body = center(
          Icons.lock_outline_rounded,
          'Encrypted file.\nOpen or extract it to enter the password.',
        );
      case _Kind.loading:
        body = const Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
        );
      case _Kind.error:
        body = center(Icons.error_outline_rounded, _text);
      case _Kind.image:
        body = Padding(
          padding: const EdgeInsets.all(12),
          child: Center(
            child: Image.memory(
              _bytes!,
              key: const Key('preview-image'),
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => center(
                Icons.broken_image_outlined,
                'Can not show this image',
              ),
            ),
          ),
        );
      case _Kind.text:
        body = Scrollbar(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: SelectableText(
              _text,
              key: const Key('preview-text'),
              style: mono,
            ),
          ),
        );
      case _Kind.binary:
        body = Scrollbar(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            scrollDirection: Axis.vertical,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SelectableText(
                _hex(_bytes!),
                key: const Key('preview-hex'),
                style: mono,
              ),
            ),
          ),
        );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          color: cs.surfaceContainerLow,
          alignment: Alignment.centerLeft,
          child: Text(
            item == null ? 'Preview' : item.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelMedium!.copyWith(
              color: cs.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Divider(height: 1, color: cs.outlineVariant),
        if (widget.db != null &&
            widget.db!.available &&
            item != null &&
            !item.isDir)
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 260),
            child: SingleChildScrollView(
              child: FileMetaView(
                key: const Key('preview-meta'),
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                divider: true,
                session: widget.db!,
                path: item.path,
                delay: const Duration(milliseconds: 180),
              ),
            ),
          ),
        Expanded(child: body),
      ],
    );
  }
}
