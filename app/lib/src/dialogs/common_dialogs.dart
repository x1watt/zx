// The small dialogs: password, overwrite question, text input, confirm,
// errors with per item lists.

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:zx/zx.dart';

import '../ui/format_utils.dart';

/// Asks for a password; null when the user gives up.
Future<String?> showPasswordDialog(
  BuildContext context,
  ZxPasswordRequest request,
) {
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PasswordDialog(request: request),
  );
}

class PasswordDialog extends StatefulWidget {
  final ZxPasswordRequest request;
  const PasswordDialog({super.key, required this.request});

  @override
  State<PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<PasswordDialog> {
  final _c = TextEditingController();
  bool _show = false;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _ok() => Navigator.of(context).pop(_c.text);

  @override
  Widget build(BuildContext context) {
    final r = widget.request;
    final cs = Theme.of(context).colorScheme;
    final why = switch (r.reason) {
      ZxPasswordReason.open => 'The file names of this archive are encrypted.',
      ZxPasswordReason.extract =>
        r.itemPath == null
            ? 'Some files of this archive are encrypted.'
            : 'This file is encrypted:',
      ZxPasswordReason.update =>
        'The archive has to decode encrypted files to change them.',
    };
    // the small "Extract to folder" window has no room for the icon
    final compact = MediaQuery.sizeOf(context).height < 420;
    return AlertDialog(
      icon: compact
          ? null
          : Icon(Icons.lock_outline_rounded, color: cs.primary),
      title: const Text('Password required'),
      scrollable: true,
      insetPadding: compact
          ? const EdgeInsets.all(12)
          : const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              p.basename(r.archivePath),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(why),
            if (r.itemPath != null && r.reason == ZxPasswordReason.extract)
              Text(
                r.itemPath!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: cs.onSurfaceVariant),
              ),
            const SizedBox(height: 16),
            if (r.retry)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Icon(Icons.error_outline, size: 18, color: cs.error),
                    const SizedBox(width: 6),
                    Text(
                      'Wrong password, try again.',
                      key: const Key('wrong-password'),
                      style: TextStyle(color: cs.error),
                    ),
                  ],
                ),
              ),
            TextField(
              key: const Key('password-field'),
              controller: _c,
              autofocus: true,
              obscureText: !_show,
              onSubmitted: (_) => _ok(),
              decoration: InputDecoration(
                labelText: 'Password',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  key: const Key('password-show'),
                  tooltip: _show ? 'Hide password' : 'Show password',
                  icon: Icon(
                    _show
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                  ),
                  onPressed: () => setState(() => _show = !_show),
                ),
              ),
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
          key: const Key('password-ok'),
          onPressed: _ok,
          child: const Text('OK'),
        ),
      ],
    );
  }
}

/// Asks what to do with a file that exists.
Future<ZxOverwriteAnswer> showOverwriteDialog(
  BuildContext context,
  ZxOverwriteRequest r,
) async {
  final a = await showDialog<ZxOverwriteAnswer>(
    context: context,
    barrierDismissible: false,
    builder: (context) => OverwriteDialog(request: r),
  );
  return a ?? ZxOverwriteAnswer.cancel;
}

class OverwriteDialog extends StatelessWidget {
  final ZxOverwriteRequest request;
  const OverwriteDialog({super.key, required this.request});

  @override
  Widget build(BuildContext context) {
    final r = request;
    final cs = Theme.of(context).colorScheme;
    Widget side(String label, int? size, DateTime? t) => Expanded(
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 4),
            Text(
              size == null ? 'size unknown' : formatBytes(size, exact: true),
            ),
            Text(t == null ? '' : formatDate(t)),
          ],
        ),
      ),
    );
    void answer(ZxOverwriteAnswer a) => Navigator.of(context).pop(a);
    return AlertDialog(
      icon: Icon(Icons.file_copy_outlined, color: cs.primary),
      title: const Text('Replace the existing file?'),
      scrollable: true,
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(
              r.targetPath,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                side('Existing file', r.existingSize, r.existingModified),
                const SizedBox(width: 12),
                side('From the archive', r.newSize, r.newModified),
              ],
            ),
          ],
        ),
      ),
      actionsOverflowButtonSpacing: 8,
      actions: [
        TextButton(
          key: const Key('ow-cancel'),
          onPressed: () => answer(ZxOverwriteAnswer.cancel),
          child: const Text('Cancel'),
        ),
        OutlinedButton(
          key: const Key('ow-rename'),
          onPressed: () => answer(ZxOverwriteAnswer.rename),
          child: const Text('Keep both'),
        ),
        OutlinedButton(
          key: const Key('ow-no-all'),
          onPressed: () => answer(ZxOverwriteAnswer.skipAll),
          child: const Text('No to all'),
        ),
        OutlinedButton(
          key: const Key('ow-no'),
          onPressed: () => answer(ZxOverwriteAnswer.skip),
          child: const Text('No'),
        ),
        OutlinedButton(
          key: const Key('ow-yes-all'),
          onPressed: () => answer(ZxOverwriteAnswer.overwriteAll),
          child: const Text('Yes to all'),
        ),
        FilledButton(
          key: const Key('ow-yes'),
          onPressed: () => answer(ZxOverwriteAnswer.overwrite),
          child: const Text('Yes'),
        ),
      ],
    );
  }
}

/// A one line text question (rename, new folder); null when cancelled.
Future<String?> showTextInputDialog(
  BuildContext context, {
  required String title,
  required String label,
  String initial = '',
  String ok = 'OK',
  String? Function(String)? validate,
  bool selectStem = false,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _TextInputDialog(
      title: title,
      label: label,
      initial: initial,
      ok: ok,
      validate: validate,
      selectStem: selectStem,
    ),
  );
}

class _TextInputDialog extends StatefulWidget {
  final String title, label, initial, ok;
  final String? Function(String)? validate;
  final bool selectStem;
  const _TextInputDialog({
    required this.title,
    required this.label,
    required this.initial,
    required this.ok,
    required this.validate,
    required this.selectStem,
  });

  @override
  State<_TextInputDialog> createState() => _TextInputDialogState();
}

class _TextInputDialogState extends State<_TextInputDialog> {
  late final _c = TextEditingController(text: widget.initial);
  String? _error;

  @override
  void initState() {
    super.initState();
    final t = widget.initial;
    var end = t.length;
    if (widget.selectStem) {
      final k = t.lastIndexOf('.');
      if (k > 0) end = k;
    }
    _c.selection = TextSelection(baseOffset: 0, extentOffset: end);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _ok() {
    final v = _c.text.trim();
    final e = v.isEmpty ? 'Enter a name.' : widget.validate?.call(v);
    if (e != null) {
      setState(() => _error = e);
      return;
    }
    Navigator.of(context).pop(v);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        child: TextField(
          key: const Key('text-input'),
          controller: _c,
          autofocus: true,
          onSubmitted: (_) => _ok(),
          decoration: InputDecoration(
            labelText: widget.label,
            errorText: _error,
            border: const OutlineInputBorder(),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('text-input-ok'),
          onPressed: _ok,
          child: Text(widget.ok),
        ),
      ],
    );
  }
}

Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String ok = 'OK',
  bool destructive = false,
}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (context) {
      final cs = Theme.of(context).colorScheme;
      return AlertDialog(
        title: Text(title),
        content: SizedBox(width: 420, child: Text(message)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('confirm-ok'),
            style: destructive
                ? FilledButton.styleFrom(
                    backgroundColor: cs.error,
                    foregroundColor: cs.onError,
                  )
                : null,
            autofocus: true,
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(ok),
          ),
        ],
      );
    },
  );
  return r ?? false;
}

/// An error, with an optional list of per item problems.
Future<void> showErrorDialog(
  BuildContext context, {
  required String title,
  required String message,
  List<String> details = const [],
}) {
  return showDialog<void>(
    context: context,
    builder: (context) {
      final cs = Theme.of(context).colorScheme;
      return AlertDialog(
        key: const Key('error-dialog'),
        icon: Icon(Icons.error_outline_rounded, color: cs.error),
        title: Text(title),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(message),
              if (details.isNotEmpty) ...[
                const SizedBox(height: 12),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 280),
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: cs.outlineVariant),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: details.length,
                      itemBuilder: (_, i) => Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        child: SelectableText(
                          details[i],
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          FilledButton(
            key: const Key('error-close'),
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      );
    },
  );
}

/// The result of a test, or of an extraction with errors.
Future<void> showExtractResultDialog(
  BuildContext context, {
  required String title,
  required ZxExtractResult result,
  bool test = false,
}) {
  final ok = result.ok;
  return showDialog<void>(
    context: context,
    builder: (context) {
      final cs = Theme.of(context).colorScheme;
      final line =
          '${result.files} file${result.files == 1 ? '' : 's'}'
          '${result.dirs > 0 ? ', ${result.dirs} folder${result.dirs == 1 ? '' : 's'}' : ''}'
          ', ${formatBytes(result.bytes)}'
          '${result.skipped > 0 ? ', ${result.skipped} skipped' : ''}';
      return AlertDialog(
        key: Key(test ? 'test-result' : 'extract-result'),
        icon: Icon(
          ok ? Icons.check_circle_outline_rounded : Icons.error_outline_rounded,
          color: ok ? const Color(0xFF2E9D6A) : cs.error,
        ),
        title: Text(title),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                ok
                    ? (test ? 'No errors found.' : 'Done.')
                    : '${result.errors.length} error${result.errors.length == 1 ? '' : 's'}.',
                key: const Key('result-summary'),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              Text(line),
              if (!ok) ...[
                const SizedBox(height: 12),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 280),
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: cs.outlineVariant),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: result.errors.length,
                      itemBuilder: (_, i) {
                        final e = result.errors[i];
                        return ListTile(
                          dense: true,
                          leading: Icon(
                            Icons.error_outline,
                            size: 18,
                            color: cs.error,
                          ),
                          title: Text(e.path),
                          subtitle: Text(itemErrorText(e)),
                        );
                      },
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          FilledButton(
            key: const Key('result-close'),
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      );
    },
  );
}
