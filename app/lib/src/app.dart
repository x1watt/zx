// The MaterialApp: themes (light and dark from one seed color, compact
// for the desktop) and the two kinds of windows (the archive manager and
// the small "Extract to folder" window).

import 'package:flutter/material.dart';

import 'services.dart';
import 'ui/browser_page.dart';
import 'ui/extract_to_folder.dart';

const kSeedColor = Color(0xFF2F62D6);

ThemeData buildTheme(Brightness b) {
  final cs = ColorScheme.fromSeed(seedColor: kSeedColor, brightness: b);
  final base = ThemeData(
    colorScheme: cs,
    useMaterial3: true,
    visualDensity: VisualDensity.compact,
    scaffoldBackgroundColor: cs.surface,
  );
  return base.copyWith(
    dividerTheme: DividerThemeData(
      color: cs.outlineVariant.withValues(alpha: 0.72),
      thickness: 1,
      space: 1,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: cs.surfaceContainerHighest.withValues(alpha: 0.55),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(
          color: cs.outlineVariant.withValues(alpha: 0.55),
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: cs.primary, width: 1.5),
      ),
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: cs.primary,
      selectionColor: cs.primary.withValues(alpha: 0.24),
      selectionHandleColor: cs.primary,
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 500),
      textStyle: TextStyle(fontSize: 12, color: cs.onInverseSurface),
      decoration: BoxDecoration(
        color: cs.inverseSurface,
        borderRadius: BorderRadius.circular(6),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: cs.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(cs.surfaceContainer),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: cs.surfaceContainer,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
        ),
        overlayColor: WidgetStatePropertyAll(
          cs.primary.withValues(alpha: b == Brightness.dark ? 0.16 : 0.09),
        ),
      ),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thickness: const WidgetStatePropertyAll(8),
      radius: const Radius.circular(4),
      thumbColor: WidgetStatePropertyAll(cs.onSurface.withValues(alpha: 0.25)),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: cs.inverseSurface,
      contentTextStyle: TextStyle(color: cs.onInverseSurface),
    ),
  );
}

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
