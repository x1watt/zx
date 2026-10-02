// The themes of the app (light and dark from one seed color, or black and
// white for the web version; compact for the desktop).

import 'package:flutter/material.dart';

const kSeedColor = Color(0xFF2F62D6);

/// Black, white and neutral grays, no hue (the web version).
ColorScheme monochromeScheme(Brightness b) {
  final dark = b == Brightness.dark;
  Color g(int v) => Color.fromARGB(255, v, v, v);
  final ink = dark ? Colors.white : Colors.black;
  final paper = dark ? Colors.black : Colors.white;
  return ColorScheme(
    brightness: b,
    primary: ink,
    onPrimary: paper,
    primaryContainer: dark ? g(0x2A) : g(0xE4),
    onPrimaryContainer: ink,
    secondary: dark ? g(0xC8) : g(0x40),
    onSecondary: paper,
    secondaryContainer: dark ? g(0x33) : g(0xDD),
    onSecondaryContainer: ink,
    tertiary: dark ? g(0xB0) : g(0x50),
    onTertiary: paper,
    error: dark ? const Color(0xFFFF6B6B) : const Color(0xFFC62828),
    onError: paper,
    surface: paper,
    onSurface: ink,
    onSurfaceVariant: dark ? g(0xA8) : g(0x5A),
    surfaceContainerLowest: paper,
    surfaceContainerLow: dark ? g(0x0D) : g(0xF6),
    surfaceContainer: dark ? g(0x14) : g(0xF0),
    surfaceContainerHigh: dark ? g(0x1C) : g(0xEA),
    surfaceContainerHighest: dark ? g(0x26) : g(0xE2),
    outline: dark ? g(0x5C) : g(0x9A),
    outlineVariant: dark ? g(0x30) : g(0xD4),
    inverseSurface: ink,
    onInverseSurface: paper,
    inversePrimary: paper,
    shadow: Colors.black,
    scrim: Colors.black,
    surfaceTint: Colors.transparent,
  );
}

/// The theme of the app; [monochrome]: black and white (the web version),
/// else from the seed color.
ThemeData buildTheme(Brightness b, {bool monochrome = false}) {
  final cs = monochrome
      ? monochromeScheme(b)
      : ColorScheme.fromSeed(seedColor: kSeedColor, brightness: b);
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
