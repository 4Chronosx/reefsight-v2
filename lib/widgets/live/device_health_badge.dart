import 'package:flutter/material.dart';

import '../../services/device_checks.dart';
import '../../services/device_health_monitor.dart';

/// Sub-plan 13 step 3: a small HUD badge when the phone gets hot
/// (`serious` or worse) or battery or storage turns red mid-transect. Sits
/// on the HUD edge, never over the frame (sub-plan 06 decision 4), in the
/// same dark pill as `RecordingIndicator`. Hidden otherwise.
class DeviceHealthBadge extends StatelessWidget {
  const DeviceHealthBadge({super.key, required this.health});

  final DeviceHealth? health;

  @override
  Widget build(BuildContext context) {
    final health = this.health;
    if (health == null || !health.needsAttention) return const SizedBox.shrink();

    final thermal = health.thermalLevel;
    final items = [
      if (thermal == ThermalLevel.serious) 'Phone hot',
      if (thermal == ThermalLevel.critical) 'Phone very hot',
      if (health.battery.status == CheckStatus.critical) 'Battery low',
      if (health.storage.status == CheckStatus.critical) 'Storage low',
    ];
    final critical = thermal == ThermalLevel.critical ||
        health.battery.status == CheckStatus.critical ||
        health.storage.status == CheckStatus.critical;
    final color = critical ? Colors.redAccent : Colors.amber;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF0D2E48).withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.warning_rounded, color: color, size: 16),
          const SizedBox(width: 6),
          Text(
            items.join(' · '),
            style: TextStyle(color: color, fontSize: 15, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }
}
