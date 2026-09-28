import 'package:flutter/material.dart';

/// The `deep-sea.jpg` photo plus its blue gradient tint, used by Home and by
/// Live's loading/error states (sub-plan 6, ui-ux-overhaul, step 1). v1's
/// `home_screen.dart` and `scan_screen.dart` each duplicated this stack
/// inline; this is the shared version, with an optional [child] painted on
/// top.
class UnderwaterBackground extends StatelessWidget {
  const UnderwaterBackground({super.key, this.child});

  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.asset('assets/images/deep-sea.jpg', fit: BoxFit.cover),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                const Color(0xFF01579B).withValues(alpha: 0.82),
                const Color(0xFF006994).withValues(alpha: 0.68),
              ],
            ),
          ),
        ),
        ?child,
      ],
    );
  }
}
