import 'package:flutter/material.dart';

import '../constants/app_colors.dart';
import '../services/device_checks.dart';
import '../services/device_health_monitor.dart';
import 'section_card.dart';

IconData statusIcon(CheckStatus status) => switch (status) {
      CheckStatus.ok => Icons.check_circle_rounded,
      CheckStatus.warn => Icons.warning_rounded,
      CheckStatus.critical => Icons.error_rounded,
      CheckStatus.unavailable => Icons.help_outline_rounded,
    };

Color statusColor(CheckStatus status) => switch (status) {
      CheckStatus.ok => AppColors.healthy,
      CheckStatus.warn => Colors.amber.shade700,
      CheckStatus.critical => AppColors.bleached,
      CheckStatus.unavailable => AppColors.unknown,
    };

/// Sub-plan 13 step 2: the Setup screen's "Ready to dive" card. One row per
/// check, each with its status and one line of reason. Display only -- it
/// never disables Start (decision 1: warn, never block).
class ReadyToDiveCard extends StatelessWidget {
  const ReadyToDiveCard({super.key, required this.health, required this.entryPosition});

  /// `null` until `DeviceHealthMonitor`'s first reading.
  final DeviceHealth? health;

  /// Sub-plan 12's entry fix, from `entryPositionCheck`. `null` while the
  /// first fix is still being acquired.
  final CheckResult? entryPosition;

  @override
  Widget build(BuildContext context) {
    final health = this.health;
    return SectionCard(
      icon: Icons.health_and_safety_outlined,
      title: 'Ready to dive',
      child: Column(
        children: [
          _CheckRow(label: 'Storage', check: health?.storage),
          _CheckRow(label: 'Battery', check: health?.battery),
          _CheckRow(label: 'Heat', check: health?.thermal),
          _CheckRow(label: 'Entry position', check: entryPosition),
        ],
      ),
    );
  }
}

class _CheckRow extends StatelessWidget {
  const _CheckRow({required this.label, required this.check});

  final String label;

  /// `null` while still checking.
  final CheckResult? check;

  @override
  Widget build(BuildContext context) {
    final check = this.check;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            check == null ? Icons.hourglass_empty_rounded : statusIcon(check.status),
            key: ValueKey('device-check-$label'),
            color: check == null ? AppColors.unknown : statusColor(check.status),
            size: 22,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                ),
                Text(
                  check?.reason ?? 'Checking…',
                  style: const TextStyle(fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
