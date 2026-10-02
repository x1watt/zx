// The MaterialApp (the themes are in theme.dart) and the two kinds of
// windows (the archive manager and the small "Extract to folder" window).

import 'package:flutter/material.dart';

import 'services.dart';
import 'theme.dart';
import 'ui/browser_page.dart';
import 'ui/extract_to_folder.dart';

export 'theme.dart';

class ZxApp extends StatelessWidget {
  final AppServices services;
  final String? initialArchive;

  /// Key of the browser page (tests reach its state through it).
  final GlobalKey<BrowserPageState>? browserKey;

  const ZxApp({
    super.key,
    required this.services,
    this.initialArchive,
    this.browserKey,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: services.settings,
      builder: (context, _) => MaterialApp(
        title: 'zx',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: services.settings.theme,
        home: BrowserPage(
          key: browserKey,
          services: services,
          initialArchive: initialArchive,
        ),
      ),
    );
  }
}

class ExtractToFolderApp extends StatelessWidget {
  final AppServices services;
  final List<String> archives;
  final void Function(int code) onDone;
  const ExtractToFolderApp({
    super.key,
    required this.services,
    required this.archives,
    required this.onDone,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'zx: extract',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: services.settings.theme,
      home: ExtractToFolderPage(
        archives: archives,
        launcher: services.launcher,
        onDone: onDone,
      ),
    );
  }
}
