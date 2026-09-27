// The compression settings shared by the add and new archive dialogs:
// level, method, password (with the zip cipher), encrypted names, solid;
// for .zx the Compression section of zx_compression.dart (Auto or Manual)
// in place of the level and method.

import 'package:flutter/material.dart';
import 'package:zx/zx.dart';

import '../formats.dart';
import '../settings.dart';
import 'zx_compression.dart';

class CompressionSettings {
  int level;
  String? method;
  String password = '';
  bool encryptNames = false;
  bool solid = true;
  bool zipAes = true;

  /// The .zx compression (Auto or Manual) and its estimate.
  final ZxCompressionState zx;

  CompressionSettings({this.level = 5, ZxPrefs zx = const ZxPrefs()})
    : zx = ZxCompressionState(zx);

  ZxOptions toOptions(NewFormat f, {bool allowPassword = true}) {
    final pw = allowPassword && f.password && password.isNotEmpty
        ? password
        : null;
    final sw = <String, String>{};
    String? m;
    if (f.id == 'zx') {
      final c = zx.compression;
      final zcm = !zx.prefs.auto && zcmLevelOf(zx.prefs.method) != null;
      return ZxOptions(
        // the level of the other methods (zcm has its own)
        level: zx.prefs.auto || zcm ? null : level,
        password: pw,
        encryptHeaders: pw != null && f.encryptNames && encryptNames
            ? true
            : null,
        solid: solid,
        compression: c,
        dedup: zx.prefs.dedup,
      );
    }
    if (method != null && f.methods.contains(method)) {
      if (f.id == '7z' || f.id == 'zip') {
        m = method;
      } else {
        sw['m'] = method!;
      }
    }
    if (pw != null && f.id == 'zip' && zipAes) sw['em'] = 'AES256';
    return ZxOptions(
      level: f.levels ? level : null,
      method: m,
      password: pw,
      encryptHeaders: pw != null && f.encryptNames && encryptNames
          ? true
          : null,
      solid: f.solid ? solid : null,
      switches: sw,
    );
  }
}

const _levels = <int, String>{
  0: 'Store (no compression)',
  1: 'Fastest',
  3: 'Fast',
  5: 'Normal',
  7: 'Maximum',
  9: 'Ultra',
};

String levelLabel(int l) => _levels[l] ?? 'Level $l';

class CompressionForm extends StatefulWidget {
  final NewFormat format;
  final CompressionSettings settings;

  /// The archive can hold encrypted items (false for an update of a format
  /// that can not).
  final bool canEncrypt;
  final bool canEncryptNames;

  /// The files to add (the .zx estimate), changed in place by the dialog.
  final List<String> sources;
  final Estimator estimator;
  const CompressionForm({
    super.key,
    required this.format,
    required this.settings,
    this.canEncrypt = true,
    this.canEncryptNames = true,
    this.sources = const [],
    this.estimator = ZxArchive.estimate,
  });

  @override
  State<CompressionForm> createState() => _CompressionFormState();
}

class _CompressionFormState extends State<CompressionForm> {
  bool _show = false;
  late final _pw = TextEditingController(text: widget.settings.password);

  @override
  void dispose() {
    _pw.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.format;
    final s = widget.settings;
    final t = Theme.of(context).textTheme;
    final pwOk = f.password && widget.canEncrypt;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (f.id == 'zx')
          ZxCompressionSection(
            state: s.zx,
            sources: widget.sources,
            level: s.level,
            onLevel: (v) => setState(() => s.level = v),
            estimator: widget.estimator,
          )
        else
          Wrap(
            spacing: 24,
            runSpacing: 8,
            children: [
              if (f.levels)
                _labeled(
                  'Compression level',
                  DropdownButton<int>(
                    key: const Key('opt-level'),
                    value: _levels.containsKey(s.level) ? s.level : 5,
                    onChanged: (v) => setState(() => s.level = v ?? 5),
                    items: [
                      for (final e in _levels.entries)
                        DropdownMenuItem(value: e.key, child: Text(e.value)),
                    ],
                  ),
                ),
              if (f.methods.isNotEmpty)
                _labeled(
                  'Method',
                  DropdownButton<String?>(
                    key: const Key('opt-method'),
                    value: f.methods.contains(s.method) ? s.method : null,
                    onChanged: (v) => setState(() => s.method = v),
                    items: [
                      const DropdownMenuItem(
                        value: null,
                        child: Text('Default'),
                      ),
                      for (final m in f.methods)
                        DropdownMenuItem(
                          value: m,
                          child: Text(methodLabel(f, m)),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        if (f.solid)
          CheckboxListTile(
            key: const Key('opt-solid'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: s.solid,
            onChanged: (v) => setState(() => s.solid = v ?? true),
            title: const Text('Solid archive (smaller, slower to update)'),
          ),
        const SizedBox(height: 8),
        Text('Encryption', style: t.labelLarge),
        const SizedBox(height: 6),
        if (!pwOk)
          Tooltip(
            message: f.password
                ? 'This archive can not get encrypted items'
                : '${f.label} archives can not be encrypted',
            child: Text(
              'Not available for ${f.label}',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          )
        else ...[
          TextField(
            key: const Key('opt-password'),
            controller: _pw,
            obscureText: !_show,
            onChanged: (v) => setState(() => s.password = v),
            decoration: InputDecoration(
              labelText: 'Password (empty: no encryption)',
              isDense: true,
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
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
          if (f.id == 'zip')
            CheckboxListTile(
              key: const Key('opt-zip-aes'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: s.zipAes,
              onChanged: s.password.isEmpty
                  ? null
                  : (v) => setState(() => s.zipAes = v ?? true),
              title: const Text(
                'AES-256 (off: ZipCrypto, for old unzip tools)',
              ),
            ),
          if (f.encryptNames)
            _maybeTooltip(
              widget.canEncryptNames
                  ? null
                  : 'Names can only be encrypted when the archive is created',
              CheckboxListTile(
                key: const Key('opt-encrypt-names'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: s.encryptNames,
                onChanged: s.password.isEmpty || !widget.canEncryptNames
                    ? null
                    : (v) => setState(() => s.encryptNames = v ?? false),
                title: const Text('Encrypt file names'),
              ),
            ),
        ],
      ],
    );
  }

  Widget _maybeTooltip(String? message, Widget child) =>
      message == null ? child : Tooltip(message: message, child: child);

  Widget _labeled(String label, Widget child) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(label, style: Theme.of(context).textTheme.labelLarge),
      child,
    ],
  );
}
