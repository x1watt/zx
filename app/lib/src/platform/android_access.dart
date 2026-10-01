// The Android pieces that need Flutter widgets or the app's services: the
// explanation shown before the storage permission is asked for, and the
// Launcher of AppServices (open a file with another app).
//
// Wiring (done by the app on Android, see main.dart):
//   AndroidPlaces.explainer =
//       () => showStorageAccessDialog(navigatorKey.currentContext!);
//   launcher: const AndroidLauncher(),

import 'package:flutter/material.dart';

import '../services.dart' show Launcher;
import 'android_places.dart';

/// Explains why zx asks for "All files access" and offers the fallback
/// (one folder through the system's folder picker).
Future<StorageChoice> showStorageAccessDialog(BuildContext context) async {
  final r = await showDialog<StorageChoice>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.folder_open),
      title: const Text('Access to your files'),
      content: const SingleChildScrollView(
        child: Text(
          'zx is a file manager for archives: to browse your folders, open '
          'archives where they are and extract or compress next to them, '
          'it needs "All files access".\n\n'
          'On the next screen, switch on "Allow access to manage all '
          'files" for zx, then come back.\n\n'
          'zx reads and writes only the files you work with, and has no '
          'internet permission: nothing leaves the device.\n\n'
          'Without it, you can choose one folder that zx may use, or work '
          'in the zx files folder.',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, StorageChoice.cancel),
          child: const Text('Not now'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, StorageChoice.folder),
          child: const Text('Choose a folder'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, StorageChoice.allFiles),
          child: const Text('Continue'),
        ),
      ],
    ),
  );
  return r ?? StorageChoice.cancel;
}

/// Opens files with the app Android picks (the chooser when there is no
/// default). Folders are shown by zx itself.
class AndroidLauncher implements Launcher {
  final AndroidPlaces places;

  const AndroidLauncher([this.places = const AndroidPlaces()]);

  @override
  Future<void> openFile(String path) async {
    await places.open(path);
  }

  @override
  Future<void> openFolder(String path) async {}

  @override
  Future<bool> openUrl(String url) async => false;
}
