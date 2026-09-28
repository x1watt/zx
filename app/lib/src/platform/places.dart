// The storage of the device as the file explorer sees it: the places of
// the sidebar (home, standard folders, drives and volumes), the free
// space, the access permission, "Open with" and "Share".
//
// This file is the contract between the explorer (app/lib/src/ui and
// app/lib/src/fs, which only call this interface) and the platform code.
// DesktopPlaces below is the Linux, Windows and macOS implementation; the
// Android implementation (storage roots, the all-files permission, the
// intent chooser and the share sheet) lives next to it in this folder and
// is picked by [PlatformPlaces.forPlatform].
//
// Rules for implementations:
// - every method is asynchronous and never blocks the UI isolate (use the
//   async dart:io calls, a platform channel or Process.run);
// - a method that can not do its job returns null / false / an empty list
//   instead of throwing, so the explorer can hide the entry;
// - paths are absolute paths of the local file system (dart:io can open
//   them once [ensureAccess] returned true).

import 'dart:io';

import 'package:path/path.dart' as p;

import 'android_places.dart';

/// What a place is (the sidebar picks the icon from it).
enum PlaceKind {
  home,
  desktop,
  documents,
  downloads,
  pictures,
  music,
  videos,
  root,

  /// A mounted drive, a partition, a USB stick, an SD card.
  volume,

  /// A folder the user pinned to the sidebar.
  bookmark,
}

/// One entry of the sidebar.
class Place {
  final String label;
  final String path;
  final PlaceKind kind;

  /// A volume that can be ejected (USB stick, SD card).
  final bool removable;

  const Place(this.label, this.path, this.kind, {this.removable = false});

  @override
  bool operator ==(Object other) =>
      other is Place && other.path == path && other.kind == kind;

  @override
  int get hashCode => Object.hash(path, kind);

  @override
  String toString() => 'Place($label, $path, $kind)';
}

/// The size of the volume that holds a path.
class SpaceInfo {
  final int total;
  final int free;
  const SpaceInfo({required this.total, required this.free});
}

/// A program that can open a file ("Open with...").
class AppChoice {
  /// The id the platform launches it with (a .desktop file id on Linux).
  final String id;
  final String name;
  const AppChoice(this.id, this.name);
}

abstract class PlatformPlaces {
  /// The implementation of the running platform.
  factory PlatformPlaces.forPlatform() =>
      Platform.isAndroid ? const AndroidPlaces() : DesktopPlaces();

  /// The standard places that exist: home, desktop, documents, downloads,
  /// pictures, music, videos and the root of the file system (on Android
  /// the internal storage and its standard folders).
  Future<List<Place>> places();

  /// The mounted drives and volumes (Linux: /media, /mnt, /run/media/$USER;
  /// Windows: the drive letters; macOS: /Volumes; Android: the SD cards
  /// and USB drives).
  Future<List<Place>> volumes();

  /// Total and free bytes of the volume holding [path], or null.
  Future<SpaceInfo?> space(String path);

  /// Asks for the permission to read and write the shared storage where
  /// the platform needs one (Android). True when the explorer may list
  /// the places; the desktop always has it.
  Future<bool> ensureAccess();

  /// Opens the system's "Open with" chooser for [path]. False when the
  /// platform has none: then the explorer lists [appsFor] itself.
  Future<bool> openWithChooser(String path);

  /// The programs that can open [path], for the explorer's own chooser.
  Future<List<AppChoice>> appsFor(String path);

  /// Opens [path] with [app] (one of [appsFor]).
  Future<void> openWith(AppChoice app, String path);

  /// True when [share] can send files to other apps (Android).
  bool get canShare;

  /// Shares [paths] with another app (the share sheet).
  Future<void> share(List<String> paths);
}

/// Linux, Windows and macOS.
class DesktopPlaces implements PlatformPlaces {
  /// The environment (tests give their own HOME).
  final Map<String, String> env;

  DesktopPlaces({Map<String, String>? env}) : env = env ?? Platform.environment;

  String get _home =>
      env['HOME'] ?? env['USERPROFILE'] ?? Directory.current.path;

  @override
  Future<List<Place>> places() async {
    final home = _home;
    final dirs = await _userDirs(home);
    final out = <Place>[Place('Home', home, PlaceKind.home)];
    for (final (kind, key, name) in const [
      (PlaceKind.desktop, 'DESKTOP', 'Desktop'),
      (PlaceKind.documents, 'DOCUMENTS', 'Documents'),
      (PlaceKind.downloads, 'DOWNLOAD', 'Downloads'),
      (PlaceKind.pictures, 'PICTURES', 'Pictures'),
      (PlaceKind.music, 'MUSIC', 'Music'),
      (PlaceKind.videos, 'VIDEOS', 'Videos'),
    ]) {
      final path = dirs[key] ?? p.join(home, name);
      if (path != home && await Directory(path).exists()) {
        out.add(Place(name, path, kind));
      }
    }
    if (!Platform.isWindows) {
      out.add(const Place('Computer', '/', PlaceKind.root));
    }
    return out;
  }

  /// XDG user directories (~/.config/user-dirs.dirs), Linux only.
  Future<Map<String, String>> _userDirs(String home) async {
    final out = <String, String>{};
    if (!Platform.isLinux) {
      if (Platform.isMacOS) out['VIDEOS'] = p.join(home, 'Movies');
      return out;
    }
    final cfg = env['XDG_CONFIG_HOME'];
    final f = File(
      p.join(
        cfg != null && cfg.isNotEmpty ? cfg : p.join(home, '.config'),
        'user-dirs.dirs',
      ),
    );
    try {
      for (final line in await f.readAsLines()) {
        final m = RegExp(r'^XDG_(\w+)_DIR="(.*)"').firstMatch(line.trim());
        if (m == null) continue;
        out[m[1]!] = m[2]!.replaceAll(r'$HOME', home);
      }
    } on FileSystemException {
      // no file: the English defaults
    }
    return out;
  }

  @override
  Future<List<Place>> volumes() async {
    final out = <Place>[];
    try {
      if (Platform.isWindows) {
        for (var c = 'A'.codeUnitAt(0); c <= 'Z'.codeUnitAt(0); c++) {
          final d = '${String.fromCharCode(c)}:\\';
          if (await Directory(d).exists()) {
            out.add(Place(d.substring(0, 2), d, PlaceKind.volume));
          }
        }
      } else if (Platform.isMacOS) {
        await for (final e in Directory('/Volumes').list()) {
          if (e is Directory || e is Link) {
            out.add(
              Place(
                p.basename(e.path),
                e.path,
                PlaceKind.volume,
                removable: true,
              ),
            );
          }
        }
      } else {
        final user = env['USER'] ?? '';
        final text = await File('/proc/mounts').readAsString();
        for (final line in text.split('\n')) {
          final f = line.split(' ');
          if (f.length < 2) continue;
          final mp = f[1].replaceAll(r'\040', ' ');
          final removable =
              mp.startsWith('/media/') || mp.startsWith('/run/media/$user/');
          if (removable || mp.startsWith('/mnt/')) {
            out.add(
              Place(p.basename(mp), mp, PlaceKind.volume, removable: removable),
            );
          }
        }
      }
    } on FileSystemException {
      // nothing to list
    }
    return out;
  }

  @override
  Future<SpaceInfo?> space(String path) async {
    try {
      if (Platform.isWindows) {
        final drive = p.rootPrefix(p.absolute(path)).replaceAll('\\', '');
        final r = await Process.run('powershell', [
          '-NoProfile',
          '-Command',
          "\$d = Get-PSDrive -Name '${drive.replaceAll(':', '')}'; "
              "\"\$(\$d.Used + \$d.Free) \$(\$d.Free)\"",
        ]);
        final parts = '${r.stdout}'.trim().split(RegExp(r'\s+'));
        if (parts.length != 2) return null;
        return SpaceInfo(total: int.parse(parts[0]), free: int.parse(parts[1]));
      }
      final r = await Process.run('df', ['-Pk', path]);
      if (r.exitCode != 0) return null;
      final lines = '${r.stdout}'.trim().split('\n');
      if (lines.length < 2) return null;
      final f = lines.last.split(RegExp(r'\s+'));
      if (f.length < 4) return null;
      return SpaceInfo(
        total: int.parse(f[1]) * 1024,
        free: int.parse(f[3]) * 1024,
      );
    } on Object {
      return null;
    }
  }

  @override
  Future<bool> ensureAccess() async => true;

  @override
  Future<bool> openWithChooser(String path) async {
    if (!Platform.isWindows) return false;
    try {
      await Process.start('rundll32.exe', [
        'shell32.dll,OpenAs_RunDLL',
        path,
      ], mode: ProcessStartMode.detached);
      return true;
    } on ProcessException {
      return false;
    }
  }

  @override
  Future<List<AppChoice>> appsFor(String path) async {
    if (!Platform.isLinux) return const [];
    try {
      final t = await Process.run('xdg-mime', ['query', 'filetype', path]);
      final mime = '${t.stdout}'.trim();
      if (mime.isEmpty) return const [];
      final r = await Process.run('gio', ['mime', mime]);
      final ids = <String>{};
      for (final line in '${r.stdout}'.split('\n')) {
        final s = line.trim();
        if (s.endsWith('.desktop')) ids.add(s);
      }
      final out = <AppChoice>[];
      for (final id in ids) {
        out.add(AppChoice(id, await _desktopName(id) ?? id));
      }
      return out;
    } on Object {
      return const [];
    }
  }

  /// The Name= of a .desktop file in the XDG data folders.
  Future<String?> _desktopName(String id) async {
    final dataHome = env['XDG_DATA_HOME'];
    final dirs = [
      dataHome != null && dataHome.isNotEmpty
          ? dataHome
          : p.join(_home, '.local', 'share'),
      ...(env['XDG_DATA_DIRS'] ?? '/usr/local/share:/usr/share').split(':'),
    ];
    for (final d in dirs) {
      final f = File(p.join(d, 'applications', id));
      try {
        for (final line in await f.readAsLines()) {
          if (line.startsWith('Name=')) return line.substring(5);
        }
      } on FileSystemException {
        continue;
      }
    }
    return null;
  }

  @override
  Future<void> openWith(AppChoice app, String path) async {
    if (Platform.isLinux) {
      await Process.start('gio', [
        'launch',
        await _desktopPath(app.id),
        path,
      ], mode: ProcessStartMode.detached);
    }
  }

  Future<String> _desktopPath(String id) async {
    for (final d in [
      p.join(_home, '.local', 'share'),
      ...(env['XDG_DATA_DIRS'] ?? '/usr/local/share:/usr/share').split(':'),
    ]) {
      final f = p.join(d, 'applications', id);
      if (await File(f).exists()) return f;
    }
    return id;
  }

  @override
  bool get canShare => false;

  @override
  Future<void> share(List<String> paths) async {}
}
