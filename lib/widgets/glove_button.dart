import 'package:flutter/material.dart';

import '../constants/app_colors.dart';
import '../theme/app_theme.dart';

/// A primary or destructive button sized for glove operation (sub-plan 6,
/// decision 4: 56 dp minimum topside, 64 dp minimum in-water). Every
/// pre-existing screen built its own `SizedBox(height: ...) +
/// ElevatedButton.styleFrom(...)` inline (`transect_setup_screen.dart`,
/// `live_transect_screen.dart`'s End Transect button); this replaces that
/// with one widget so glove sizing can't silently regress on a new screen.
class GloveButton extends StatelessWidget {
  const GloveButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.destructive = false,
    this.inWater = false,
    this.busy = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool destructive;

  /// Live-screen controls need the larger 64 dp minimum (decision 4);
  /// topside controls use the theme's 56 dp default.
  final bool inWater;

  /// Shows a spinner in place of [icon] and disables the button, regardless
  /// of [onPressed] -- matches `live_transect_screen.dart`'s existing
  /// `_endingTransect` busy-state pattern.
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final minHeight = inWater
        ? AppTheme.minInWaterControlHeight
        : AppTheme.minTopsideControlHeight;

    final style = destructive
        ? ElevatedButton.styleFrom(
            backgroundColor: AppColors.bleached,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            textStyle:
                const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          )
        : null; // falls back to the theme's elevatedButtonTheme

    final leading = busy
        ? const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Colors.white,
            ),
          )
        : icon == null
            ? null
            : Icon(icon);

    return SizedBox(
      height: minHeight,
      child: leading == null
          ? ElevatedButton(
              onPressed: busy ? null : onPressed,
              style: style,
              child: Text(label),
            )
          : ElevatedButton.icon(
              onPressed: busy ? null : onPressed,
              style: style,
              icon: leading,
              label: Text(label),
            ),
    );
  }
}
