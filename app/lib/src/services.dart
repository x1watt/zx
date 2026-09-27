// The outside world of the app, behind small interfaces so that tests can
// replace them: opening files with other programs and the file dialogs.

import 'dart:io';

import 'package:file_selector/file_selector.dart' as fs;

import 'integration.dart';
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
}

/// Everything the app needs from outside, in one place.
class AppServices {
  final AppPaths paths;
  final Settings settings;
  final Launcher launcher;
  final FilePicker picker;
  final DesktopIntegration integration;

  AppServices({
    required this.paths,
    required this.settings,
    required this.launcher,
    required this.picker,
    required this.integration,
  });
}
