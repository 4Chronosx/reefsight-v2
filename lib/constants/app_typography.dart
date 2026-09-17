import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// New for sub-plan 5 -- v1 used Nunito (`google_fonts: ^6.2.1` in its
/// `pubspec.yaml`) but had no dedicated typography file, setting it ad hoc
/// per-widget. Centralized here instead, applied once via [textTheme] in
/// `main.dart`'s `ThemeData` (`mobile/sub-plans/05-ui-and-reporting.md`,
/// "v1 salvage": "Design system (`app_colors.dart`, Nunito typography) --
/// reuse directly, no CV dependency at all").
class AppTypography {
  static TextTheme textTheme(TextTheme base) => GoogleFonts.nunitoTextTheme(base);
}
