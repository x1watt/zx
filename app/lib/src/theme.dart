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

// ---------------------------------------------------------------------------
// The themes of the web version

/// The colors of the item icons when a theme sets them (the retro themes:
/// everything in the phosphor color); null keeps the colors by file type.
class IconTint extends ThemeExtension<IconTint> {
  final Color folder;
  final Color file;
  const IconTint(this.folder, this.file);

  @override
  IconTint copyWith({Color? folder, Color? file}) =>
      IconTint(folder ?? this.folder, file ?? this.file);

  @override
  IconTint lerp(IconTint? other, double t) => other == null
      ? this
      : IconTint(
          Color.lerp(folder, other.folder, t)!,
          Color.lerp(file, other.file, t)!,
        );
}

/// The theme of the web version.
enum WebTheme {
  dark('Dark'),
  light('Light'),
  green('Green'),
  orange('Orange'),
  eighties('80s');

  final String label;
  const WebTheme(this.label);

  /// The phosphor monitors (scanlines over the page).
  bool get retro => this == green || this == orange;

  /// The desktop of an early Macintosh (windows on a gray pattern).
  bool get classic => this == eighties;

  static WebTheme? byName(String? name) {
    for (final t in values) {
      if (t.name == name) return t;
    }
    return null;
  }
}

/// A phosphor monitor: [glow] on black, dimmer shades of it for the rest.
ColorScheme _phosphorScheme(Color glow, Color paper) {
  Color shade(double a) => Color.alphaBlend(glow.withValues(alpha: a), paper);
  return ColorScheme(
    brightness: Brightness.dark,
    primary: glow,
    onPrimary: paper,
    primaryContainer: shade(0.22),
    onPrimaryContainer: glow,
    secondary: shade(0.75),
    onSecondary: paper,
    secondaryContainer: shade(0.16),
    onSecondaryContainer: glow,
    tertiary: shade(0.6),
    onTertiary: paper,
    error: const Color(0xFFFF3B5C),
    onError: paper,
    surface: paper,
    onSurface: shade(0.92),
    onSurfaceVariant: shade(0.6),
    surfaceContainerLowest: paper,
    surfaceContainerLow: shade(0.04),
    surfaceContainer: shade(0.06),
    surfaceContainerHigh: shade(0.09),
    surfaceContainerHighest: shade(0.13),
    outline: shade(0.45),
    outlineVariant: shade(0.2),
    inverseSurface: glow,
    onInverseSurface: paper,
    inversePrimary: paper,
    shadow: glow,
    scrim: Colors.black,
    surfaceTint: Colors.transparent,
  );
}

const kRetroFont = 'ShareTechMono';
const kClassicFont = 'PixelifySans';

/// Marks the 80s theme: the web page draws its panes as windows with
/// pinstriped title bars on a gray desktop pattern.
class ClassicDesktop extends ThemeExtension<ClassicDesktop> {
  const ClassicDesktop();
  @override
  ClassicDesktop copyWith() => this;
  @override
  ClassicDesktop lerp(ClassicDesktop? other, double t) => this;
}

/// One bit: black on white, inverted selection, square frames, rounded
/// push buttons, the pixel font at the sizes where it is sharp.
ThemeData _classicTheme() {
  const ink = Colors.black;
  const paper = Colors.white;
  const cs = ColorScheme(
    brightness: Brightness.light,
    primary: ink,
    onPrimary: paper,
    primaryContainer: ink,
    onPrimaryContainer: paper,
    secondary: ink,
    onSecondary: paper,
    secondaryContainer: ink,
    onSecondaryContainer: paper,
    tertiary: ink,
    onTertiary: paper,
    error: ink,
    onError: paper,
    surface: paper,
    onSurface: ink,
    onSurfaceVariant: Color(0xFF555555),
    surfaceContainerLowest: paper,
    surfaceContainerLow: paper,
    surfaceContainer: paper,
    surfaceContainerHigh: paper,
    surfaceContainerHighest: paper,
    outline: ink,
    outlineVariant: ink,
    inverseSurface: ink,
    onInverseSurface: paper,
    inversePrimary: paper,
    shadow: ink,
    scrim: Color(0x66000000),
    surfaceTint: Colors.transparent,
  );
  final base = buildTheme(Brightness.light, monochrome: true);
  // The pixel font is crisp only where its pixels fall on screen pixels:
  // one of them is 1/11 of the font size, so 11 and 22. It is used there
  // (window titles, headings); the text in between is Roboto, which reads
  // well at any size.
  TextStyle? pixel(TextStyle? s, double size) => s?.copyWith(
    fontFamily: kClassicFont,
    fontSize: size,
    fontWeight: FontWeight.w400,
    letterSpacing: 0,
    height: 1.2,
  );
  final plain = base.textTheme.apply(bodyColor: ink, displayColor: ink);
  final text = plain.copyWith(
    headlineSmall: pixel(plain.headlineSmall, 22),
    titleLarge: pixel(plain.titleLarge, 22),
    titleSmall: pixel(plain.titleSmall, 11),
  );
  const frame = BorderSide(color: ink);
  const square = RoundedRectangleBorder(side: frame);
  final push = ButtonStyle(
    shape: const WidgetStatePropertyAll(
      RoundedRectangleBorder(
        side: frame,
        borderRadius: BorderRadius.all(Radius.circular(7)),
      ),
    ),
    backgroundColor: WidgetStateProperty.resolveWith(
      (s) => s.contains(WidgetState.pressed) ? ink : paper,
    ),
    foregroundColor: WidgetStateProperty.resolveWith(
      (s) => s.contains(WidgetState.pressed)
          ? paper
          : s.contains(WidgetState.disabled)
          ? const Color(0xFF999999)
          : ink,
    ),
    overlayColor: const WidgetStatePropertyAll(Colors.transparent),
    textStyle: WidgetStatePropertyAll(text.labelLarge),
  );
  return base.copyWith(
    colorScheme: cs,
    scaffoldBackgroundColor: paper,
    textTheme: text,
    primaryTextTheme: text,
    iconTheme: const IconThemeData(color: ink),
    dividerTheme: const DividerThemeData(color: ink, thickness: 1, space: 1),
    appBarTheme: AppBarTheme(
      backgroundColor: paper,
      foregroundColor: ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      shape: const Border(bottom: frame),
      titleTextStyle: text.titleLarge,
    ),
    filledButtonTheme: FilledButtonThemeData(style: push),
    outlinedButtonTheme: OutlinedButtonThemeData(style: push),
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStateProperty.resolveWith(
          (s) =>
              s.contains(WidgetState.disabled) ? const Color(0xFF999999) : ink,
        ),
        overlayColor: const WidgetStatePropertyAll(Color(0x22000000)),
        shape: const WidgetStatePropertyAll(RoundedRectangleBorder()),
        textStyle: WidgetStatePropertyAll(text.labelLarge),
      ),
    ),
    inputDecorationTheme: base.inputDecorationTheme.copyWith(
      fillColor: paper,
      border: const OutlineInputBorder(
        borderRadius: BorderRadius.zero,
        borderSide: frame,
      ),
      enabledBorder: const OutlineInputBorder(
        borderRadius: BorderRadius.zero,
        borderSide: frame,
      ),
      focusedBorder: const OutlineInputBorder(
        borderRadius: BorderRadius.zero,
        borderSide: BorderSide(color: ink, width: 2),
      ),
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: paper,
      elevation: 0,
      shape: RoundedRectangleBorder(side: BorderSide(color: ink, width: 2)),
    ),
    popupMenuTheme: const PopupMenuThemeData(
      color: paper,
      elevation: 0,
      shape: square,
    ),
    menuTheme: const MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(paper),
        elevation: WidgetStatePropertyAll(0),
        shape: WidgetStatePropertyAll(square),
      ),
    ),
    tooltipTheme: TooltipThemeData(
      textStyle: text.bodySmall?.copyWith(color: ink),
      decoration: BoxDecoration(
        color: paper,
        border: Border.all(color: ink),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: paper,
      contentTextStyle: text.bodyMedium?.copyWith(color: ink),
      shape: square,
      elevation: 0,
    ),
    scrollbarTheme: const ScrollbarThemeData(
      thickness: WidgetStatePropertyAll(10),
      radius: Radius.zero,
      thumbColor: WidgetStatePropertyAll(ink),
    ),
    checkboxTheme: CheckboxThemeData(
      shape: const RoundedRectangleBorder(),
      side: frame,
      fillColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? ink : paper,
      ),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: ink,
      linearTrackColor: Color(0xFFCCCCCC),
    ),
    extensions: const [IconTint(ink, ink), ClassicDesktop()],
  );
}

ThemeData buildWebTheme(WebTheme t) {
  switch (t) {
    case WebTheme.dark:
      return buildTheme(Brightness.dark, monochrome: true);
    case WebTheme.light:
      return buildTheme(Brightness.light, monochrome: true);
    case WebTheme.eighties:
      return _classicTheme();
    case WebTheme.green:
    case WebTheme.orange:
      final glow = t == WebTheme.green
          ? const Color(0xFF39FF6A)
          : const Color(0xFFFFA22B);
      final paper = t == WebTheme.green
          ? const Color(0xFF020803)
          : const Color(0xFF0A0501);
      final cs = _phosphorScheme(glow, paper);
      final base = buildTheme(Brightness.dark, monochrome: true);
      final glowText = [
        Shadow(color: glow.withValues(alpha: 0.55), blurRadius: 6),
      ];
      final text = base.textTheme
          .apply(
            fontFamily: kRetroFont,
            bodyColor: cs.onSurface,
            displayColor: glow,
          )
          .copyWith(
            headlineSmall: base.textTheme.headlineSmall?.copyWith(
              fontFamily: kRetroFont,
              color: glow,
              shadows: glowText,
            ),
            titleLarge: base.textTheme.titleLarge?.copyWith(
              fontFamily: kRetroFont,
              color: glow,
              shadows: glowText,
            ),
          );
      return base.copyWith(
        colorScheme: cs,
        scaffoldBackgroundColor: paper,
        textTheme: text,
        primaryTextTheme: text,
        iconTheme: IconThemeData(color: glow),
        dividerTheme: DividerThemeData(
          color: glow.withValues(alpha: 0.28),
          thickness: 1,
          space: 1,
        ),
        appBarTheme: AppBarTheme(
          backgroundColor: paper,
          foregroundColor: glow,
          titleTextStyle: text.titleLarge,
        ),
        inputDecorationTheme: base.inputDecorationTheme.copyWith(
          fillColor: cs.surfaceContainerHigh,
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(2),
            borderSide: BorderSide(color: glow.withValues(alpha: 0.35)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(2),
            borderSide: BorderSide(color: glow, width: 1.5),
          ),
        ),
        dialogTheme: DialogThemeData(
          backgroundColor: cs.surfaceContainerLow,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(2),
            side: BorderSide(color: glow.withValues(alpha: 0.6)),
          ),
        ),
        extensions: [IconTint(glow, cs.secondary)],
      );
  }
}
