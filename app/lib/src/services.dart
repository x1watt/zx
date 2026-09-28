// The outside world of the app, behind small interfaces so that tests can
// replace them: opening files with other programs and the file dialogs.

import 'dart:io';

import 'package:file_selector/file_selector.dart' as fs;

import 'package:zx/zx.dart' show ZxArchive;

import 'db_session.dart';
import 'dialogs/zx_compression.dart' show Estimator;
import 'integration.dart';
import 'platform/places.dart';
import 'settings.dart';

/// Opens files and folders with the programs of the desktop.
abstract class Launcher {
  Future<void> openFile(String path);
  Future<void> openFolder(String path);
}

/// xdg-open on Linux, open on macOS, start on Windows.
class SystemLauncher implements Launcher {
  const SystemLauncher();

  @override
  Future<void> openFile(String path) => _open(path);

  @override
  Future<void> openFolder(String path) => _open(path);

  Future<void> _open(String path) async {
    if (Platform.isWindows) {
      await Process.start('cmd', [
        '/c',
        'start',
        '',
        path,
      ], mode: ProcessStartMode.detached);
    } else if (Platform.isMacOS) {
      await Process.start('open', [path], mode: ProcessStartMode.detached);
    } else {
      await Process.start('xdg-open', [path], mode: ProcessStartMode.detached);
    }
  }
}

/// The file and folder dialogs.
abstract class FilePicker {
  /// An archive to open.
  Future<String?> openArchive({String? initialDirectory});

  /// Files to add.
  Future<List<String>> pickFiles({String? initialDirectory});

  /// A folder (to add, or to extract to).
  Future<String?> pickFolder({String? initialDirectory, String? title});

  /// Where to save a file (an export).
  Future<String?> saveFile({String? initialDirectory, String? suggestedName});
}

class SystemFilePicker implements FilePicker {
  const SystemFilePicker();

  @override
  Future<String?> openArchive({String? initialDirectory}) async {
    final f = await fs.openFile(
      initialDirectory: initialDirectory,
      confirmButtonText: 'Open',
      acceptedTypeGroups: const [
        fs.XTypeGroup(
          label: 'Archives',
          extensions: [
            '7z',
            'zip',
            'jar',
            'rar',
            'tar',
            'gz',
            'tgz',
            'bz2',
            'tbz2',
            'tbz',
            'xz',
            'txz',
            'lzma',
            'tlz',
            'lzh',
            'lha',
            'arj',
            'zpaq',
            'zx',
            '001',
          ],
        ),
        fs.XTypeGroup(label: 'All files'),
      ],
    );
    return f?.path;
  }

  @override
  Future<List<String>> pickFiles({String? initialDirectory}) async {
    final files = await fs.openFiles(
      initialDirectory: initialDirectory,
      confirmButtonText: 'Select',
    );
    return [for (final f in files) f.path];
  }

  @override
  Future<String?> pickFolder({String? initialDirectory, String? title}) =>
      fs.getDirectoryPath(
        initialDirectory: initialDirectory,
        confirmButtonText: title,
      );

  @override
  Future<String?> saveFile({
    String? initialDirectory,
    String? suggestedName,
  }) async {
    final l = await fs.getSaveLocation(
      initialDirectory: initialDirectory,
      suggestedName: suggestedName,
      confirmButtonText: 'Save',
    );
    return l?.path;
  }
}

/// Everything the app needs from outside, in one place.
class AppServices {
  final AppPaths paths;
  final Settings settings;
  final Launcher launcher;
  final FilePicker picker;
  final DesktopIntegration integration;

  /// The estimate of a .zx compression (a fake in the tests).
  final Estimator estimator;

  /// Opens the database of a .zx archive (a fake in the tests).
  final DbOpener dbOpener;

  /// The places of the sidebar, free space, open with, share.
  final PlatformPlaces places;

  AppServices({
    required this.paths,
    required this.settings,
    required this.launcher,
    required this.picker,
    required this.integration,
    this.estimator = ZxArchive.estimate,
    this.dbOpener = openAsyncDb,
    PlatformPlaces? places,
  }) : places = places ?? PlatformPlaces.forPlatform();
}
