import 'package:flutter/material.dart';

/// Lightweight, DADS-inspired UI defaults built entirely from Flutter Material 3.
///
/// This is not a port of the DADS component library or a claim of full DADS
/// conformance. Native Material controls retain their keyboard, focus, touch,
/// screen reader and high contrast behavior.
abstract final class AppTheme {
  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    const accent = Colors.blue;
    return ThemeData(
      useMaterial3: true,
      // Preserve existing palette to avoid unexpectedly redesigning screens.
      colorSchemeSeed: accent,
      brightness: brightness,
      // Keep familiar Material touch sizes, rather than creating custom
      // compact controls. State is conveyed by text as well as color.
      visualDensity: VisualDensity.standard,
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 48),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 48),
        ),
      ),
    );
  }
}
