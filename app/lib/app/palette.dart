import 'package:flutter/material.dart';

/// Slate and teal. A dark slate navigation rail and a teal accent on a cool
/// off-white page with white cards; in dark mode a deep blue-slate page with
/// lighter teal. Status colours (see `Tone`) are the same in both.
///
/// Every text/background pair here is checked for contrast in
/// `test/palette_test.dart`; change a colour and that test says whether the
/// pair still reads.
class Palette {
  const Palette._({
    required this.brightness,
    required this.page,
    required this.card,
    required this.rail,
    required this.railText,
    required this.railSelected,
    required this.railIndicator,
    required this.primary,
    required this.onPrimary,
    required this.primaryContainer,
    required this.onPrimaryContainer,
    required this.text,
    required this.textSecondary,
    required this.line,
    required this.error,
  });

  final Brightness brightness;
  final Color page;
  final Color card;
  final Color rail;
  final Color railText;
  final Color railSelected;
  final Color railIndicator;
  final Color primary;
  final Color onPrimary;
  final Color primaryContainer;
  final Color onPrimaryContainer;
  final Color text;
  final Color textSecondary;
  final Color line;
  final Color error;

  static const light = Palette._(
    brightness: Brightness.light,
    page: Color(0xFFF3F7F8),
    card: Color(0xFFFFFFFF),
    rail: Color(0xFF1F2D3A),
    railText: Color(0xFFC9D6DE),
    railSelected: Color(0xFFFFFFFF),
    railIndicator: Color(0xFF0B7A75),
    primary: Color(0xFF0B7A75),
    onPrimary: Color(0xFFFFFFFF),
    primaryContainer: Color(0xFFD6F0EC),
    onPrimaryContainer: Color(0xFF0B5F5A),
    text: Color(0xFF1B2A33),
    textSecondary: Color(0xFF566873),
    line: Color(0xFFD5E0E4),
    error: Color(0xFFB3261E),
  );

  static const dark = Palette._(
    brightness: Brightness.dark,
    page: Color(0xFF121C24),
    card: Color(0xFF1A2833),
    rail: Color(0xFF0D161E),
    railText: Color(0xFFB4C4CE),
    railSelected: Color(0xFFFFFFFF),
    railIndicator: Color(0xFF0B7A75),
    primary: Color(0xFF4FD1C5),
    onPrimary: Color(0xFF00302D),
    primaryContainer: Color(0xFF0B5F5A),
    onPrimaryContainer: Color(0xFFD6F0EC),
    text: Color(0xFFE6EEF2),
    textSecondary: Color(0xFF9FB2BD),
    line: Color(0xFF2C3E4B),
    error: Color(0xFFF2B8B5),
  );

  static Palette of(Brightness brightness) => brightness == Brightness.dark ? dark : light;

  ThemeData theme() {
    final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF0B7A75), brightness: brightness).copyWith(
      primary: primary,
      onPrimary: onPrimary,
      primaryContainer: primaryContainer,
      onPrimaryContainer: onPrimaryContainer,
      secondary: primary,
      onSecondary: onPrimary,
      secondaryContainer: primaryContainer,
      onSecondaryContainer: onPrimaryContainer,
      surface: page,
      onSurface: text,
      onSurfaceVariant: textSecondary,
      surfaceContainerLowest: card,
      surfaceContainerLow: card,
      surfaceContainer: card,
      surfaceContainerHigh: card,
      surfaceContainerHighest: brightness == Brightness.dark ? const Color(0xFF243645) : const Color(0xFFE6EDF0),
      outline: textSecondary,
      outlineVariant: line,
      error: error,
    );
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      scaffoldBackgroundColor: page,
      canvasColor: page,
      visualDensity: VisualDensity.standard,
      dividerColor: line,
      cardTheme: CardThemeData(
        elevation: 0,
        color: card,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: line)),
      ),
      dialogTheme: DialogThemeData(backgroundColor: card, surfaceTintColor: Colors.transparent),
      inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder(), isDense: true),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: rail,
        minWidth: 84,
        indicatorColor: railIndicator,
        selectedIconTheme: IconThemeData(color: railSelected),
        unselectedIconTheme: IconThemeData(color: railText),
        selectedLabelTextStyle: TextStyle(color: railSelected, fontWeight: FontWeight.w600, fontSize: 12),
        unselectedLabelTextStyle: TextStyle(color: railText, fontSize: 12),
      ),
    );
  }
}
