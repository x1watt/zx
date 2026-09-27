// zx, an archive manager. Command line:
//   zx_app [archive]                     opens the archive
//   zx_app --extract-to-folder <a>...    extracts each archive into a folder
//                                        named after it, then exits
//   zx_app --install-integration [--register | --associations] [--context-menu]
//   zx_app --remove-integration [--associations] [--context-menu]
//   zx_app --integration-status

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'src/app.dart';
import 'src/integration.dart';
import 'src/services.dart';
import 'src/settings.dart';

const _usage = '''
Usage: zx_app [archive]
       zx_app --extract-to-folder <archive>...
       zx_app --install-integration [--register | --associations] [--context-menu]
       zx_app --remove-integration [--associations] [--context-menu]
       zx_app --integration-status

--install-integration registers zx with the desktop (desktop entry and
icons on Linux) and switches on the named parts, both when none is named
(--register alone: nothing but the registration).
--remove-integration switches off the named parts, everything (the desktop
entry too) when none is named.''';

Future<void> main(List<String> args) async {
  final paths = AppPaths.fromEnvironment();
  if (args.contains('--help') || args.contains('-h')) {
    stdout.writeln(_usage);
    exit(0);
  }
  for (final cmd in const [
    '--install-integration',
    '--remove-integration',
    '--integration-status',
  ]) {
    if (args.contains(cmd)) {
      exit(await runIntegrationCommand(cmd, args, paths));
    }
  }

  WidgetsFlutterBinding.ensureInitialized();
  final settings = await Settings.load(paths.settingsFile);
  final services = AppServices(
    paths: paths,
    settings: settings,
    launcher: const SystemLauncher(),
    picker: const SystemFilePicker(),
    integration: DesktopIntegration.forPlatform(paths),
  );
  unawaited(cleanOpenTemp(paths.openTempDir));

  final k = args.indexOf('--extract-to-folder');
  if (k >= 0) {
    final files = [
      for (final a in args.skip(k + 1))
        if (!a.startsWith('--')) a,
    ];
    runApp(
      ExtractToFolderApp(
        services: services,
        archives: files,
        onDone: (code) async {
          await settings.flush();
          exit(code);
        },
      ),
    );
    return;
  }
  final files = [
    for (final a in args)
      if (!a.startsWith('--')) a,
  ];
  runApp(
    ZxApp(
      services: services,
      initialArchive: files.isEmpty ? null : files.first,
    ),
  );
}

/// The integration commands of the command line (also used by
/// tool/install_linux.sh). Returns the exit code.
Future<int> runIntegrationCommand(
  String cmd,
  List<String> args,
  AppPaths paths,
) async {
  final integ = DesktopIntegration.forPlatform(paths);
  if (!integ.supported) {
    stderr.writeln(integ.unsupportedReason);
    return 2;
  }
  final assoc = args.contains('--associations');
  final menu = args.contains('--context-menu');
  // --register: only the desktop entry and the icons
  final both = !assoc && !menu && !args.contains('--register');
  try {
    switch (cmd) {
      case '--install-integration':
        await integ.register();
        if (assoc || both) await integ.setAssociations(true);
        if (menu || both) await integ.setContextMenu(true);
      case '--remove-integration':
        if (!assoc && !menu) {
          await integ.removeAll();
        } else {
          if (assoc) await integ.setAssociations(false);
          if (menu) await integ.setContextMenu(false);
        }
    }
    stdout.writeln(await integ.status());
    return 0;
  } catch (e) {
    stderr.writeln('zx: $e');
    return 1;
  }
}

/// Deletes the files extracted to be opened by other programs more than a
/// day ago.
Future<void> cleanOpenTemp(String dir) async {
  try {
    final d = Directory(dir);
    if (!await d.exists()) return;
    final old = DateTime.now().subtract(const Duration(days: 1));
    await for (final e in d.list()) {
      final st = await e.stat();
      if (st.modified.isBefore(old)) await e.delete(recursive: true);
    }
  } on FileSystemException {
    // another instance is using it, or it is not ours
  }
}
