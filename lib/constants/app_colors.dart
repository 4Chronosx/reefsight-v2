import 'package:flutter/material.dart';

/// Ported from `../reefsight` (v1)'s `lib/constants/app_colors.dart`
/// verbatim -- the design system has no CV/data-model dependency, so
/// sub-plan 5 ("UI, reporting, and v1 salvage") reuses it directly rather
/// than adapting it (`mobile/sub-plans/05-ui-and-reporting.md`, "v1
/// salvage" list, last bullet).
class AppColors {
  // Health / detection states
  static const Color healthy = Color(0xFF00897B); // teal-green
  static const Color bleached = Color(0xFFE53935); // coral-red
  static const Color unknown = Color(0xFF78909C); // blue-grey

  // Ocean light theme
  static const Color primary = Color(0xFF0277BD); // deep ocean blue
  static const Color secondary = Color(0xFF26C6DA); // bright cyan
  static const Color background = Color(0xFFE1F5FE); // very light sky blue
  static const Color surface = Color(0xFFFFFFFF); // white
  static const Color onSurface = Color(0xFF0D2E48); // deep navy

  /// [healthState] matches `HealthAggregator`'s label constants
  /// (`HealthAggregator.healthyLabel` = `'CORAL'`,
  /// `HealthAggregator.bleachedLabel` = `'CORAL_BL'`) -- this project's real
  /// classifier labels, not v1's `'healthy'`/`'bleached'` strings.
  static Color forHealth(String? healthState) {
    switch (healthState) {
      case 'CORAL':
        return healthy;
      case 'CORAL_BL':
        return bleached;
      default:
        return unknown;
    }
  }
}
