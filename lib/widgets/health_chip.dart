import 'package:flutter/material.dart';

import '../constants/app_colors.dart';
import '../services/health_aggregator.dart';

/// A coloured pill for a colony's health label (`CORAL`, `CORAL_BL`, or
/// unclassified), via `AppColors.forHealth` -- sub-plan 6 step 1.
class HealthChip extends StatelessWidget {
  const HealthChip({super.key, required this.healthLabel});

  final String? healthLabel;

  String get _text {
    switch (healthLabel) {
      case HealthAggregator.healthyLabel:
        return 'Healthy';
      case HealthAggregator.bleachedLabel:
        return 'Bleached';
      default:
        return 'Unclassified';
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = AppColors.forHealth(healthLabel);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        _text,
        style:
            TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.bold),
      ),
    );
  }
}

/// A labeled `count`/`total` progress bar in [color] -- replaces
/// `summary_screen.dart`'s private `_HealthBar` (sub-plan 6 step 4: "apply
/// the theme, use `HealthChip`").
class HealthBar extends StatelessWidget {
  const HealthBar({
    super.key,
    required this.label,
    required this.count,
    required this.total,
    required this.color,
  });

  final String label;
  final int count;
  final int total;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final pct = total > 0 ? count / total : 0.0;
    return Row(
      children: [
        SizedBox(
          width: 72,
          child: Text(label, style: const TextStyle(fontSize: 13)),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: pct,
              backgroundColor: color.withValues(alpha: 0.15),
              valueColor: AlwaysStoppedAnimation<Color>(color),
              minHeight: 10,
            ),
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(
          width: 64,
          child: Text(
            '$count (${(pct * 100).toStringAsFixed(0)}%)',
            style:
                TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }
}
