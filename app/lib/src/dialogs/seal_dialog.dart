// The write side of signed generations (NOSTR seals, docs/zx-format.md
// "Seals"): activating sealing, signing, the roles (maintainers, who may
// sign), handing over the admin role, and the acceptance signature a new
// admin gives the current admin without sharing its key. The read side
// (the status bar badge and the check) is ui/seal_badge.dart.
//
// This dialog only collects a SealRequest; the caller (browser_page.dart)
// runs ZxArchive.sign with progress and the usual error dialog, as the
// add and new archive dialogs do with their own requests.

import 'package:flutter/material.dart';
import 'package:zx/zx.dart';

import '../ui/format_utils.dart' show errorText;
import '../ui/seal_badge.dart' show shortNpub;

class SealRequest {
  final String key;
  final bool activate;
  final bool deactivate;
  final List<String> addMaintainers;
  final List<String> removeMaintainers;
  final ZxWriteRule? rule;
  final String? newAdmin;
  final String? newAdminKey;
  final String? acceptance;
  const SealRequest({
    required this.key,
    this.activate = false,
    this.deactivate = false,
    this.addMaintainers = const [],
    this.removeMaintainers = const [],
    this.rule,
    this.newAdmin,
    this.newAdminKey,
    this.acceptance,
  });
}

/// The dialog that signs, activates, and changes the roles of [archive]'s
/// seal ([seals], as checked already); null when the dialog is cancelled.
Future<SealRequest?> showManageSealDialog(
  BuildContext context, {
  required ZxArchive archive,
  required List<ZxGenerationSeal> seals,
}) => showDialog<SealRequest>(
  context: context,
  builder: (_) => _ManageSealDialog(archive: archive, seals: seals),
);

class _ManageSealDialog extends StatefulWidget {
  final ZxArchive archive;
  final List<ZxGenerationSeal> seals;
  const _ManageSealDialog({required this.archive, required this.seals});

  @override
  State<_ManageSealDialog> createState() => _ManageSealDialogState();
}

class _ManageSealDialogState extends State<_ManageSealDialog> {
  ZxPolicy? get _policy {
    for (final g in widget.seals.reversed) {
      if (g.policy != null) return g.policy;
    }
    return null;
  }

  bool get _active => _policy?.active ?? false;

  final _key = TextEditingController();
  bool _showKey = false;

  late final List<String> _maintainers = [
    for (final m in _policy?.maintainers ?? const []) npubEncode(m),
  ];
  final _newMaintainer = TextEditingController();
  String? _maintainerError;

  late ZxWriteRule _rule = _policy?.rule ?? ZxWriteRule.maintainers;
  bool _ruleTouched = false;
  bool _deactivate = false;

  final _newAdmin = TextEditingController();
  final _newAdminKey = TextEditingController();
  final _acceptance = TextEditingController();

  final _acceptKey = TextEditingController();
  bool _showAcceptKey = false;
  bool _acceptBusy = false;
  String? _acceptError;
  String? _acceptResult;

  @override
  void dispose() {
    _key.dispose();
    _newMaintainer.dispose();
    _newAdmin.dispose();
    _newAdminKey.dispose();
    _acceptance.dispose();
    _acceptKey.dispose();
    super.dispose();
  }

  String? get _keyError {
    final t = _key.text.trim();
    if (t.isEmpty) return null;
    try {
      parseSecretKey(t);
      return null;
    } on FormatException catch (e) {
      return e.message;
    }
  }

  void _addMaintainer() {
    final t = _newMaintainer.text.trim();
    if (t.isEmpty) return;
    try {
      final npub = npubEncode(parsePublicKey(t));
      setState(() {
        if (!_maintainers.contains(npub)) _maintainers.add(npub);
        _newMaintainer.clear();
        _maintainerError = null;
      });
    } on FormatException catch (e) {
      setState(() => _maintainerError = e.message);
    }
  }

  Future<void> _computeAcceptance() async {
    final k = _acceptKey.text.trim();
    if (k.isEmpty) return;
    setState(() {
      _acceptBusy = true;
      _acceptError = null;
      _acceptResult = null;
    });
    try {
      final r = await widget.archive.acceptanceFor(k);
      if (!mounted) return;
      setState(() {
        _acceptResult =
            'npub: ${r.npub}\n'
            'generation: ${r.generation}\n'
            'acceptance: ${r.signature}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _acceptError = errorText(e));
    } finally {
      if (mounted) setState(() => _acceptBusy = false);
    }
  }

  void _submit() {
    final original = [
      for (final m in _policy?.maintainers ?? const []) npubEncode(m),
    ];
    final added = [
      for (final m in _maintainers)
        if (!original.contains(m)) m,
    ];
    final removed = [
      for (final m in original)
        if (!_maintainers.contains(m)) m,
    ];
    Navigator.of(context).pop(
      SealRequest(
        key: _key.text.trim(),
        activate: !_active,
        deactivate: _active && _deactivate,
        addMaintainers: added,
        removeMaintainers: removed,
        rule: !_active || _ruleTouched ? _rule : null,
        newAdmin: _newAdmin.text.trim().isEmpty ? null : _newAdmin.text.trim(),
        newAdminKey: _newAdminKey.text.trim().isEmpty
            ? null
            : _newAdminKey.text.trim(),
        acceptance: _acceptance.text.trim().isEmpty
            ? null
            : _acceptance.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final summary = zxSealSummary(widget.seals);
    final canSubmit = _key.text.trim().isNotEmpty && _keyError == null;
    return AlertDialog(
      key: const Key('manage-seal-dialog'),
      icon: const Icon(Icons.verified_outlined),
      title: const Text('Seal archive'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 600),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(summary ?? 'Not sealed yet.'),
              const SizedBox(height: 12),
              TextField(
                key: const Key('seal-key'),
                controller: _key,
                obscureText: !_showKey,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: _active
                      ? 'Your key (nsec): the admin, or a maintainer'
                      : 'Admin key (nsec): becomes the admin',
                  errorText: _keyError,
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _showKey
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                    ),
                    onPressed: () => setState(() => _showKey = !_showKey),
                  ),
                ),
              ),
              if (!_active)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    _policy == null
                        ? 'This key becomes the admin; it signs every '
                              'generation from now on.'
                        : 'Sealing is off; signing restarts it (a new '
                              'activation) and this key becomes the admin.',
                    style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
                  ),
                ),
              const Divider(height: 24),
              Text('Maintainers', style: t.labelLarge),
              const SizedBox(height: 6),
              if (_maintainers.isEmpty)
                Text('none', style: TextStyle(color: cs.onSurfaceVariant))
              else
                for (final m in _maintainers)
                  ListTile(
                    key: Key('seal-maintainer-$m'),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      shortNpub(m),
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                    trailing: IconButton(
                      tooltip: 'Remove',
                      icon: const Icon(Icons.close, size: 16),
                      onPressed: () => setState(() => _maintainers.remove(m)),
                    ),
                  ),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('seal-add-maintainer'),
                      controller: _newMaintainer,
                      decoration: InputDecoration(
                        labelText: 'Add maintainer (npub)',
                        errorText: _maintainerError,
                        isDense: true,
                        border: const OutlineInputBorder(),
                      ),
                      onSubmitted: (_) => _addMaintainer(),
                    ),
                  ),
                  IconButton(
                    key: const Key('seal-add-maintainer-go'),
                    icon: const Icon(Icons.add),
                    onPressed: _addMaintainer,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text('Who may sign', style: t.labelLarge),
              RadioGroup<ZxWriteRule>(
                groupValue: _rule,
                onChanged: (v) => setState(() {
                  _rule = v!;
                  _ruleTouched = true;
                }),
                child: Column(
                  children: const [
                    RadioListTile<ZxWriteRule>(
                      key: Key('seal-rule-admin'),
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      value: ZxWriteRule.admin,
                      title: Text('Only the admin'),
                    ),
                    RadioListTile<ZxWriteRule>(
                      key: Key('seal-rule-maintainers'),
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      value: ZxWriteRule.maintainers,
                      title: Text('The admin and the maintainers'),
                    ),
                  ],
                ),
              ),
              if (_active) ...[
                const Divider(height: 24),
                CheckboxListTile(
                  key: const Key('seal-off'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: _deactivate,
                  onChanged: (v) => setState(() => _deactivate = v ?? false),
                  title: const Text('Switch sealing off with this generation'),
                ),
                const Divider(height: 24),
                Text('Hand over the admin role', style: t.labelLarge),
                const SizedBox(height: 6),
                TextField(
                  key: const Key('seal-new-admin'),
                  controller: _newAdmin,
                  decoration: const InputDecoration(
                    labelText: 'New admin (npub)',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  key: const Key('seal-new-admin-key'),
                  controller: _newAdminKey,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: "New admin's key (nsec), when you hold it",
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  key: const Key('seal-acceptance'),
                  controller: _acceptance,
                  decoration: const InputDecoration(
                    labelText: 'Or its acceptance signature (hex)',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
              const Divider(height: 24),
              ExpansionTile(
                key: const Key('seal-acceptance-tool'),
                tilePadding: EdgeInsets.zero,
                title: const Text('I am a new admin: generate my acceptance'),
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Computes what this archive\'s next generation needs '
                      'from you, without sending your key anywhere; give '
                      'the result to the current admin.',
                      style: TextStyle(
                        color: cs.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          key: const Key('seal-accept-key'),
                          controller: _acceptKey,
                          obscureText: !_showAcceptKey,
                          decoration: InputDecoration(
                            labelText: 'Your key (nsec)',
                            isDense: true,
                            border: const OutlineInputBorder(),
                            suffixIcon: IconButton(
                              icon: Icon(
                                _showAcceptKey
                                    ? Icons.visibility_off_outlined
                                    : Icons.visibility_outlined,
                              ),
                              onPressed: () => setState(
                                () => _showAcceptKey = !_showAcceptKey,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        key: const Key('seal-accept-compute'),
                        onPressed: _acceptBusy ? null : _computeAcceptance,
                        child: Text(_acceptBusy ? '...' : 'Compute'),
                      ),
                    ],
                  ),
                  if (_acceptError != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        _acceptError!,
                        style: TextStyle(color: cs.error),
                      ),
                    ),
                  if (_acceptResult != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: SelectableText(
                        _acceptResult!,
                        key: const Key('seal-accept-result'),
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                      ),
                    ),
                ],
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
          key: const Key('seal-submit'),
          onPressed: canSubmit ? _submit : null,
          child: Text(_active ? 'Sign' : 'Activate'),
        ),
      ],
    );
  }
}
