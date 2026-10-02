import 'package:flutter/material.dart';

import '../../constants/app_colors.dart';

/// The top-edge tally HUD (sub-plan 6, ui-ux-overhaul, step 6): seen,
/// healthy, and bleached counts in their health colours plus elapsed
/// transect time -- v1's `colony_counter_hud.dart` pattern, adapted for
/// landscape (decision 7) and this project's tracker-driven counts. Replaces
/// the pre-sub-plan-6 `_TallyBadge` (`live_transect_screen.dart`), a single
/// `black54` line of 13 sp text -- below decision 4's bar (minimum 16 sp
/// body text, high-contrast backing, readable at arm's length through a
/// housing).
class TallyHud extends StatelessWidget {
  const TallyHud({
    super.key,
    required this.seenCount,
    required this.healthyCount,
    required this.bleachedCount,
    required this.elapsed,
    this.showCounts = true,
  });

  final int seenCount;
  final int healthyCount;
  final int bleachedCount;
  final Duration elapsed;

  /// `false` for a "Recount planned" transect (sub-plan 14 step 3): the
  /// diver doing or briefing the recount must not see the app's counts, so
  /// only the elapsed time shows.
  final bool showCounts;

  @override
  Widget build(BuildContext context) {
    final minutes = elapsed.inMinutes.toString().padLeft(2, '0');
    final seconds = (elapsed.inSeconds % 60).toString().padLeft(2, '0');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF0D2E48).withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.secondary.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$minutes:$seconds',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          if (showCounts) ...[
            const SizedBox(width: 16),
            _Count(label: 'Seen', value: seenCount, color: Colors.white),
            const SizedBox(width: 12),
            _Count(label: 'Healthy', value: healthyCount, color: AppColors.healthy),
            const SizedBox(width: 12),
            _Count(label: 'Bleached', value: bleachedCount, color: AppColors.bleached),
          ],
        ],
      ),
    );
  }
}

class _Count extends StatelessWidget {
  const _Count({required this.label, required this.value, required this.color});

  final String label;
  final int value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          margin: const EdgeInsets.only(right: 6),
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        Text('$label ', style: const TextStyle(color: Colors.white70, fontSize: 16)),
        Text(
          '$value',
          style: TextStyle(color: color, fontSize: 16, fontWeight: FontWeight.bold),
        ),
      ],
    );
  }
}
