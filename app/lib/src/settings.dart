// The folders the app uses and its settings (a small JSON file in the
// configuration folder, read and written asynchronously).

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

/// Where things go. Tests build one on a temporary folder so the real
/// desktop is never touched.
class AppPaths {
  final String home;

  /// XDG_CONFIG_HOME (~/.config) on Linux, %APPDATA% on Windows,
  /// ~/Library/Application Support on macOS.
  final String configHome;

  /// XDG_DATA_HOME (~/.local/share) on Linux.
  final String dataHome;

  /// The system temporary folder.
  final String temp;

  const AppPaths({
    required this.home,
    required this.configHome,
    required this.dataHome,
    required this.temp,
  });

  factory AppPaths.fromEnvironment() {
    final env = Platform.environment;
    final home = env['HOME'] ?? env['USERPROFILE'] ?? Directory.current.path;
    String configHome, dataHome;
    if (Platform.isWindows) {
      configHome = env['APPDATA'] ?? p.join(home, 'AppData', 'Roaming');
      dataHome = env['LOCALAPPDATA'] ?? p.join(home, 'AppData', 'Local');
    } else if (Platform.isMacOS) {
      configHome = p.join(home, 'Library', 'Application Support');
      dataHome = configHome;
    } else {
      final c = env['XDG_CONFIG_HOME'];
      final d = env['XDG_DATA_HOME'];
      configHome = c != null && c.isNotEmpty ? c : p.join(home, '.config');
      dataHome = d != null && d.isNotEmpty
          ? d
          : p.join(home, '.local', 'share');
    }
    return AppPaths(
      home: home,
      configHome: configHome,
      dataHome: dataHome,
      temp: Directory.systemTemp.path,
    );
  }

  /// The app's own settings folder.
  String get appConfigDir => p.join(configHome, 'zx');
  String get settingsFile => p.join(appConfigDir, 'settings.json');

  /// Files extracted to be opened with another program.
  String get openTempDir {
    final user =
        Platform.environment['USER'] ??
        Platform.environment['USERNAME'] ??
        'user';
    return p.join(temp, 'zx-open-$user');
  }
}

/// The settings, a ChangeNotifier that saves itself after each change.
class Settings extends ChangeNotifier {
  final String? file;

  ThemeMode _theme = ThemeMode.system;
  String _defaultFormat = '7z';
  int _defaultLevel = 5;
  bool _confirmDelete = true;
  bool _showPreview = true;
  bool _openFolderAfterExtract = false;
  bool _showInnerFilesystems = false;
  List<String> _recent = [];

  Settings({this.file});

  ThemeMode get theme => _theme;
  String get defaultFormat => _defaultFormat;
  int get defaultLevel => _defaultLevel;
  bool get confirmDelete => _confirmDelete;
  bool get showPreview => _showPreview;
  bool get openFolderAfterExtract => _openFolderAfterExtract;

  /// Archives open with their nested file systems as folders (a firmware
  /// section shows the files of its UBIFS volume), read-only.
  bool get showInnerFilesystems => _showInnerFilesystems;
  List<String> get recent => List.unmodifiable(_recent);

  set theme(ThemeMode v) => _change(() => _theme = v);
  set defaultFormat(String v) => _change(() => _defaultFormat = v);
  set defaultLevel(int v) => _change(() => _defaultLevel = v.clamp(0, 9));
  set confirmDelete(bool v) => _change(() => _confirmDelete = v);
  set showPreview(bool v) => _change(() => _showPreview = v);
  set openFolderAfterExtract(bool v) =>
      _change(() => _openFolderAfterExtract = v);
  set showInnerFilesystems(bool v) => _change(() => _showInnerFilesystems = v);

  static const maxRecent = 12;

  void addRecent(String path) => _change(() {
    _recent.remove(path);
    _recent.insert(0, path);
    if (_recent.length > maxRecent) _recent.length = maxRecent;
  });

  void removeRecent(String path) => _change(() => _recent.remove(path));
  void clearRecent() => _change(() => _recent.clear());

  void _change(void Function() f) {
    f();
    notifyListeners();
    _save();
  }

  Future<void>? _saving;
  bool _dirty = false;

  /// Saves the settings; changes during a save are written after it.
  void _save() {
    if (file == null) return;
    _dirty = true;
    _saving ??= () async {
      while (_dirty) {
        _dirty = false;
        try {
          final f = File(file!);
          await f.parent.create(recursive: true);
          final tmp = File('${f.path}.tmp');
          await tmp.writeAsString(
            const JsonEncoder.withIndent('  ').convert(toJson()),
          );
          await tmp.rename(f.path);
        } on FileSystemException {
          // settings are a convenience: a read-only home keeps them in memory
        }
      }
      _saving = null;
    }();
  }

  /// Completes when the pending changes are on disk (for tests).
  Future<void> flush() async {
    while (_saving != null) {
      await _saving;
    }
  }

  Map<String, Object?> toJson() => {
    'theme': _theme.name,
    'defaultFormat': _defaultFormat,
    'defaultLevel': _defaultLevel,
    'confirmDelete': _confirmDelete,
    'showPreview': _showPreview,
    'openFolderAfterExtract': _openFolderAfterExtract,
    'showInnerFilesystems': _showInnerFilesystems,
    'recent': _recent,
  };

  void _fromJson(Map<String, Object?> j) {
    _theme = ThemeMode.values.firstWhere(
      (m) => m.name == j['theme'],
      orElse: () => ThemeMode.system,
    );
    final f = j['defaultFormat'];
    if (f is String) _defaultFormat = f;
    final l = j['defaultLevel'];
    if (l is int) _defaultLevel = l.clamp(0, 9);
    final c = j['confirmDelete'];
    if (c is bool) _confirmDelete = c;
    final s = j['showPreview'];
    if (s is bool) _showPreview = s;
    final o = j['openFolderAfterExtract'];
    if (o is bool) _openFolderAfterExtract = o;
    final n = j['showInnerFilesystems'];
    if (n is bool) _showInnerFilesystems = n;
    final r = j['recent'];
    if (r is List) {
      _recent = [
        for (final x in r)
          if (x is String) x,
      ];
    }
  }

  /// Reads [file]; a missing or broken file gives the defaults.
  static Future<Settings> load(String file) async {
    final s = Settings(file: file);
    try {
      final text = await File(file).readAsString();
      final j = jsonDecode(text);
      if (j is Map<String, Object?>) s._fromJson(j);
    } on FileSystemException {
      // first start
    } on FormatException {
      // broken file: defaults
    }
    return s;
  }
}
