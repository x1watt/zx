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

/// The compression defaults of new .zx data (Settings, Compression).
class ZxPrefs {
  /// Auto (zx chooses the zcm settings) or manual.
  final bool auto;

  /// Auto: 'fast', 'balanced', 'max' or 'custom' (then [minutes]).
  final String speed;
  final int minutes;

  /// Manual: 'zcm:1'..'zcm:9', 'LZMA2', 'PPMd8', 'PPMd', 'BZip2',
  /// 'Deflate', 'zpaq' or 'store'.
  final String method;

  /// Manual zcm: the memory budget of each stream in MiB (0: the level's
  /// default), the LSTM of level 9 and its size, the threads (0: auto).
  final int memoryMiB;
  final bool lstm;
  final int lstmCells;
  final int lstmLayers;
  final int threads;

  /// Deduplicate identical data (ZxOptions.dedup, on by default).
  final bool dedup;

  const ZxPrefs({
    this.dedup = true,
    this.auto = true,
    this.speed = 'max',
    this.minutes = 10,
    this.method = 'zcm:4',
    this.memoryMiB = 0,
    this.lstm = false,
    this.lstmCells = 64,
    this.lstmLayers = 1,
    this.threads = 0,
  });

  static const speeds = ['fast', 'balanced', 'max', 'custom'];

  ZxPrefs copyWith({
    bool? auto,
    String? speed,
    int? minutes,
    String? method,
    int? memoryMiB,
    bool? lstm,
    int? lstmCells,
    int? lstmLayers,
    int? threads,
    bool? dedup,
  }) => ZxPrefs(
    dedup: dedup ?? this.dedup,
    auto: auto ?? this.auto,
    speed: speed ?? this.speed,
    minutes: minutes ?? this.minutes,
    method: method ?? this.method,
    memoryMiB: memoryMiB ?? this.memoryMiB,
    lstm: lstm ?? this.lstm,
    lstmCells: lstmCells ?? this.lstmCells,
    lstmLayers: lstmLayers ?? this.lstmLayers,
    threads: threads ?? this.threads,
  );

  Map<String, Object?> toJson() => {
    'mode': auto ? 'auto' : 'manual',
    'speed': speed,
    'minutes': minutes,
    'method': method,
    'memoryMiB': memoryMiB,
    'lstm': lstm,
    'lstmCells': lstmCells,
    'lstmLayers': lstmLayers,
    'threads': threads,
    'dedup': dedup,
  };

  static ZxPrefs fromJson(Object? j) {
    if (j is! Map) return const ZxPrefs();
    const d = ZxPrefs();
    T get<T>(String k, T def) {
      final v = j[k];
      return v is T ? v : def;
    }

    final speed = get<String>(
      'speed',
      get<String>('mode', 'auto') == 'auto' && !j.containsKey('speed')
          ? 'max'
          : d.speed,
    );
    return ZxPrefs(
      dedup: get<bool>('dedup', d.dedup),
      auto: get<String>('mode', 'auto') != 'manual',
      speed: speeds.contains(speed) ? speed : d.speed,
      minutes: get<int>('minutes', d.minutes).clamp(1, 24 * 60),
      method: get<String>('method', d.method),
      memoryMiB: get<int>('memoryMiB', d.memoryMiB).clamp(0, 1 << 16),
      lstm: get<bool>('lstm', d.lstm),
      lstmCells: get<int>('lstmCells', d.lstmCells).clamp(1, 1024),
      lstmLayers: get<int>('lstmLayers', d.lstmLayers).clamp(1, 8),
      threads: get<int>('threads', d.threads).clamp(0, 64),
    );
  }
}

/// The settings, a ChangeNotifier that saves itself after each change.
class Settings extends ChangeNotifier {
  final String? file;

  ThemeMode _theme = ThemeMode.system;
  String _defaultFormat = 'zx';
  int _defaultLevel = 5;
  bool _confirmDelete = true;
  bool _showPreview = true;
  bool _openFolderAfterExtract = false;
  bool _showInnerFilesystems = false;
  ZxPrefs _zx = const ZxPrefs();
  List<String> _recent = [];
  bool _gridView = false;
  bool _showHidden = false;
  String _leftPane = 'tree';
  List<String> _bookmarks = [];

  Settings({this.file});

  /// The explorer shows icons (a grid with thumbnails) instead of details.
  bool get gridView => _gridView;
  set gridView(bool v) => _change(() => _gridView = v);

  /// The explorer shows the hidden files (names starting with a dot).
  bool get showHidden => _showHidden;
  set showHidden(bool v) => _change(() => _showHidden = v);

  /// The wide explorer left pane: places, filesystem tree or indexer.
  String get leftPane => _leftPane;
  set leftPane(String v) => _change(
    () => _leftPane = const {'places', 'tree', 'indexer'}.contains(v)
        ? v
        : 'tree',
  );

  /// The folders pinned to the sidebar.
  List<String> get bookmarks => List.unmodifiable(_bookmarks);
  void addBookmark(String path) => _change(() {
    if (!_bookmarks.contains(path)) _bookmarks.add(path);
  });
  void removeBookmark(String path) => _change(() => _bookmarks.remove(path));

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

  /// The compression defaults of new .zx data.
  ZxPrefs get zxCompression => _zx;
  set zxCompression(ZxPrefs v) => _change(() => _zx = v);

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
    'zxCompression': _zx.toJson(),
    'recent': _recent,
    'gridView': _gridView,
    'showHidden': _showHidden,
    'leftPane': _leftPane,
    'bookmarks': _bookmarks,
  };

  void _fromJson(Map<String, Object?> j) {
    _theme = ThemeMode.values.firstWhere(
      (m) => m.name == j['theme'],
      orElse: () => ThemeMode.system,
    );
    final f = j['defaultFormat'];
    if (f is String) _defaultFormat = f;
    if (!j.containsKey('defaultFormat')) _defaultFormat = 'zx';

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
    if (j.containsKey('zxCompression')) {
      _zx = ZxPrefs.fromJson(j['zxCompression']);
    }
    final g = j['gridView'];
    if (g is bool) _gridView = g;
    final h = j['showHidden'];
    if (h is bool) _showHidden = h;
    final leftPane = j['leftPane'];
    if (leftPane is String &&
        const {'places', 'tree', 'indexer'}.contains(leftPane)) {
      _leftPane = leftPane;
    } else if (j['showFileTree'] is bool) {
      _leftPane = j['showFileTree'] == true ? 'tree' : 'places';
    }
    final b = j['bookmarks'];
    if (b is List) {
      _bookmarks = [
        for (final x in b)
          if (x is String) x,
      ];
    }
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
