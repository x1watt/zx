// PlatformPlaces on Android: the internal storage and its standard
// folders, the SD cards and USB drives of StorageManager, the app's own
// folders, the folders chosen with the document picker (when dart:io can
// read them), the "All files access" permission, the "Open with" chooser
// and the share sheet. The Kotlin side is behind android_channel.dart.

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'android_channel.dart';
import 'places.dart';

/// Shows the explanation of the storage permission before the system
/// screen; returns what the user chose. The UI sets
/// [AndroidPlaces.explainer] to [showStorageAccessDialog] (android_access.dart).
typedef StorageExplainer = Future<StorageChoice> Function();

enum StorageChoice {
  /// Open the system screen "All files access".
  allFiles,

  /// Choose one folder with the document picker instead.
  folder,

  /// Not now.
  cancel,
}

class AndroidPlaces implements PlatformPlaces {
  /// The explanation shown before the permission is asked for (null: the
  /// system screen opens directly).
  static StorageExplainer? explainer;

  final AndroidSaf saf;

  const AndroidPlaces({this.saf = const AndroidSaf()});

  Future<T?> _call<T>(String m, [Map<String, Object?>? args]) async {
    try {
      return await zxAndroidChannel.invokeMethod<T>(m, args);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Whether zx may read and write the shared storage with dart:io.
  Future<bool> hasAccess() async =>
      await _call<bool>('hasAllFilesAccess') ?? false;

  Future<Map<String, String>> _publicDirs() async {
    final m = await _call<Map>('publicDirs') ?? const {};
    return {
      for (final e in m.entries)
        if (e.value is String) '${e.key}': e.value as String,
    };
  }

  /// The app's private folders: always readable and writable, also
  /// without any permission ("files", "cache", "externalFiles").
  Future<Map<String, Object?>> appDirs() async {
    final m = await _call<Map>('appDirs') ?? const {};
    return {for (final e in m.entries) '${e.key}': e.value};
  }

  @override
  Future<List<Place>> places() async {
    final out = <Place>[];
    final access = await hasAccess();
    if (access) {
      final d = await _publicDirs();
      final root = d['root'];
      if (root != null) {
        out.add(Place('Internal storage', root, PlaceKind.home));
      }
      for (final (key, label, kind) in const [
        ('downloads', 'Downloads', PlaceKind.downloads),
        ('documents', 'Documents', PlaceKind.documents),
        ('dcim', 'Camera (DCIM)', PlaceKind.pictures),
        ('pictures', 'Pictures', PlaceKind.pictures),
        ('music', 'Music', PlaceKind.music),
        ('movies', 'Movies', PlaceKind.videos),
      ]) {
        final path = d[key];
        if (path != null && await Directory(path).exists()) {
          out.add(Place(label, path, kind));
        }
      }
    }
    // Folders chosen with the document picker that dart:io can read.
    for (final t in await saf.trees()) {
      final path = t.path;
      if (path != null && !out.any((x) => x.path == path)) {
        out.add(Place(t.name, path, PlaceKind.bookmark));
      }
    }
    // The app's own folder on the shared storage: usable without any
    // permission (archives made or extracted there stay reachable by
    // "Share" and "Open with").
    final a = await appDirs();
    final ext = a['externalFiles'];
    if (ext is List && ext.isNotEmpty && ext.first is String) {
      out.add(Place('zx files', ext.first as String, PlaceKind.bookmark));
    } else if (a['files'] is String) {
      out.add(Place('zx files', a['files'] as String, PlaceKind.bookmark));
    }
    return out;
  }

  /// Where a new archive of shared files goes by default: Downloads with
  /// the permission, the app's own folder on the shared storage without.
  Future<String?> outputFolder() async {
    if (await hasAccess()) {
      final d = (await _publicDirs())['downloads'];
      if (d != null) return d;
    }
    final a = await appDirs();
    final ext = a['externalFiles'];
    if (ext is List && ext.isNotEmpty && ext.first is String) {
      return ext.first as String;
    }
    return a['files'] as String?;
  }

  @override
  Future<List<Place>> volumes() async {
    final l = await _call<List>('volumes') ?? const [];
    final access = await hasAccess();
    final out = <Place>[];
    for (final v in l) {
      if (v is! Map) continue;
      final path = v['path'] as String?;
      if (path == null || v['primary'] == true) continue;
      if (v['state'] != 'mounted' && v['state'] != 'mounted_ro') continue;
      // Without the permission a volume is only listed when readable.
      if (!access && !await _readable(path)) continue;
      out.add(
        Place(
          (v['label'] as String?) ?? p.basename(path),
          path,
          PlaceKind.volume,
          removable: v['removable'] == true,
        ),
      );
    }
    return out;
  }

  Future<bool> _readable(String path) async {
    try {
      await Directory(path).list().first;
      return true;
    } on Object {
      return false;
    }
  }

  @override
  Future<SpaceInfo?> space(String path) async {
    final m = await _call<Map>('freeSpace', {'path': path});
    if (m == null) return null;
    return SpaceInfo(
      total: (m['total'] as num).toInt(),
      free: (m['free'] as num).toInt(),
    );
  }

  @override
  Future<bool> ensureAccess() async {
    if (await hasAccess()) return true;
    final choice =
        await (explainer?.call() ??
            Future<StorageChoice>.value(StorageChoice.allFiles));
    switch (choice) {
      case StorageChoice.allFiles:
        return await _call<bool>('requestAllFilesAccess') ?? false;
      case StorageChoice.folder:
        // the fallback: one folder through the document picker; it shows
        // up in places() when dart:io can read it
        final t = await saf.pickTree();
        return t?.path != null;
      case StorageChoice.cancel:
        return false;
    }
  }

  @override
  Future<bool> openWithChooser(String path) async =>
      await _call<bool>('openWith', {'path': path, 'chooser': true}) ?? false;

  @override
  Future<List<AppChoice>> appsFor(String path) async => const [];

  @override
  Future<void> openWith(AppChoice app, String path) async {
    await openWithChooser(path);
  }

  /// Opens [path] with the default app (the chooser when there is none).
  Future<bool> open(String path) async =>
      await _call<bool>('openWith', {'path': path, 'chooser': false}) ??
      await openWithChooser(path);

  @override
  bool get canShare => true;

  @override
  Future<void> share(List<String> paths) async {
    if (paths.isEmpty) return;
    await _call('share', {'paths': paths});
  }
}
