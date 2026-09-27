// The settings: theme, new archive defaults, confirmations, and the
// desktop integration toggles (file associations, file manager menu).

import 'package:flutter/material.dart';

import '../formats.dart';
import '../integration.dart';
import '../services.dart';
import '../dialogs/compression_form.dart';
import 'format_utils.dart';

class SettingsPage extends StatefulWidget {
  final AppServices services;
  const SettingsPage({super.key, required this.services});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  IntegrationStatus? _status;
  bool _working = false;
  String? _error;

  DesktopIntegration get _integration => widget.services.integration;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    if (!_integration.supported) return;
    try {
      final s = await _integration.status();
      if (mounted) setState(() => _status = s);
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    }
  }

  Future<void> _toggle(Future<void> Function() f) async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await f();
    } catch (e) {
      _error = errorText(e);
    }
    await _refresh();
    if (mounted) setState(() => _working = false);
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.services.settings;
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;

    Widget section(String title, List<Widget> children) => Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(
              title,
              style: t.titleSmall!.copyWith(color: cs.primary),
            ),
          ),
          Card(
            elevation: 0,
            margin: EdgeInsets.zero,
            color: cs.surfaceContainerLow,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: cs.outlineVariant),
            ),
            child: Column(children: children),
          ),
        ],
      ),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        backgroundColor: cs.surfaceContainerLow,
      ),
      body: ListenableBuilder(
        listenable: s,
        builder: (context, _) {
          final st = _status;
          return Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  section('Appearance', [
                    ListTile(
                      leading: const Icon(Icons.palette_outlined),
                      title: const Text('Theme'),
                      trailing: SegmentedButton<ThemeMode>(
                        key: const Key('set-theme'),
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment(
                            value: ThemeMode.system,
                            label: Text('System'),
                            icon: Icon(Icons.brightness_auto_outlined),
                          ),
                          ButtonSegment(
                            value: ThemeMode.light,
                            label: Text('Light'),
                            icon: Icon(Icons.light_mode_outlined),
                          ),
                          ButtonSegment(
                            value: ThemeMode.dark,
                            label: Text('Dark'),
                            icon: Icon(Icons.dark_mode_outlined),
                          ),
                        ],
                        selected: {s.theme},
                        onSelectionChanged: (v) => s.theme = v.first,
                      ),
                    ),
                    SwitchListTile(
                      key: const Key('set-preview'),
                      secondary: const Icon(Icons.preview_outlined),
                      title: const Text('Preview pane'),
                      subtitle: const Text(
                        'Show text and images of the selected file',
                      ),
                      value: s.showPreview,
                      onChanged: (v) => s.showPreview = v,
                    ),
                  ]),
                  section('New archives', [
                    ListTile(
                      leading: const Icon(Icons.inventory_2_outlined),
                      title: const Text('Default format'),
                      trailing: DropdownButton<String>(
                        key: const Key('set-format'),
                        value: newFormatById(s.defaultFormat).id,
                        onChanged: (v) => s.defaultFormat = v ?? '7z',
                        items: [
                          for (final f in kNewFormats)
                            DropdownMenuItem(value: f.id, child: Text(f.label)),
                        ],
                      ),
                    ),
                    ListTile(
                      leading: const Icon(Icons.speed_outlined),
                      title: const Text('Default compression level'),
                      trailing: DropdownButton<int>(
                        key: const Key('set-level'),
                        value: const [0, 1, 3, 5, 7, 9].contains(s.defaultLevel)
                            ? s.defaultLevel
                            : 5,
                        onChanged: (v) => s.defaultLevel = v ?? 5,
                        items: [
                          for (final l in const [0, 1, 3, 5, 7, 9])
                            DropdownMenuItem(
                              value: l,
                              child: Text(levelLabel(l)),
                            ),
                        ],
                      ),
                    ),
                  ]),
                  section('Behavior', [
                    SwitchListTile(
                      key: const Key('set-confirm-delete'),
                      secondary: const Icon(Icons.delete_outline_rounded),
                      title: const Text(
                        'Confirm before deleting from an archive',
                      ),
                      value: s.confirmDelete,
                      onChanged: (v) => s.confirmDelete = v,
                    ),
                    SwitchListTile(
                      key: const Key('set-open-folder'),
                      secondary: const Icon(Icons.folder_open_outlined),
                      title: const Text('Open the folder after extracting'),
                      value: s.openFolderAfterExtract,
                      onChanged: (v) => s.openFolderAfterExtract = v,
                    ),
                  ]),
                  section('Desktop integration', [
                    if (!_integration.supported)
                      ListTile(
                        leading: const Icon(Icons.info_outline_rounded),
                        title: const Text('Not available here'),
                        subtitle: Text(_integration.unsupportedReason),
                      )
                    else ...[
                      SwitchListTile(
                        key: const Key('set-assoc'),
                        secondary: const Icon(Icons.link_rounded),
                        title: const Text(
                          'Associate archive file types with zx',
                        ),
                        subtitle: const Text(
                          'Double clicking an archive in the file manager opens it in zx',
                        ),
                        value: st?.associations ?? false,
                        onChanged: st == null || _working
                            ? null
                            : (v) => _toggle(
                                () => _integration.setAssociations(v),
                              ),
                      ),
                      SwitchListTile(
                        key: const Key('set-menu'),
                        secondary: const Icon(Icons.menu_open_rounded),
                        title: const Text(
                          'Add "Extract to folder" to the file manager right-click menu',
                        ),
                        subtitle: const Text('Nautilus and Thunar'),
                        value: st?.contextMenu ?? false,
                        onChanged: st == null || _working
                            ? null
                            : (v) =>
                                  _toggle(() => _integration.setContextMenu(v)),
                      ),
                      if (_working) const LinearProgressIndicator(minHeight: 2),
                      for (final n in st?.notes ?? const <String>[])
                        ListTile(
                          dense: true,
                          leading: Icon(
                            Icons.info_outline_rounded,
                            size: 20,
                            color: cs.onSurfaceVariant,
                          ),
                          title: Text(
                            n,
                            style: TextStyle(color: cs.onSurfaceVariant),
                          ),
                        ),
                      if (_error != null)
                        ListTile(
                          key: const Key('set-error'),
                          dense: true,
                          leading: Icon(Icons.error_outline, color: cs.error),
                          title: Text(
                            _error!,
                            style: TextStyle(color: cs.error),
                          ),
                        ),
                    ],
                  ]),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
