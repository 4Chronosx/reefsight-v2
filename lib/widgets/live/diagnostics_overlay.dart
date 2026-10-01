import 'package:flutter/material.dart';

import '../../services/device_checks.dart';
import '../../services/health_aggregator.dart';
import '../../tracking/strack.dart';

/// The per-track debug list + segmentation timing (sub-plan 6,
/// ui-ux-overhaul, step 6): kept for field debugging and thesis
/// screenshots, but hidden by default and toggled from Settings ("Show
/// diagnostics") rather than always-on. This used to be
/// `_PerformanceAndTracksOverlay` and doubled as the only place segmentation
/// / recording / storage errors showed up; those now have their own
/// `LiveErrorBanner`, so this widget carries only performance/track debug
/// info, docked to the left edge when shown.
class DiagnosticsOverlay extends StatelessWidget {
  const DiagnosticsOverlay({
    super.key,
    required this.segProcessingMs,
    required this.tracks,
    required this.healthAggregator,
    required this.sizesPx,
    this.loopSummary,
    this.checkpointFailures = 0,
    this.thermal,
  });

  /// Current iOS thermal state (sub-plan 13 step 3), so a frame-rate drop
  /// can be matched to heat. `null` when unreadable.
  final ThermalLevel? thermal;

  /// Failed colony checkpoints this session (`SessionCheckpointer`,
  /// sub-plan 11) -- a data write failing must be visible, not swallowed.
  final int checkpointFailures;

  final double? segProcessingMs;

  /// `LiveLoopSummary.format()` (sub-plan 09): events/s, tracker updates/s,
  /// update gaps, classifications/s. `null` until the first event.
  final String? loopSummary;
  final List<STrack> tracks;
  final HealthAggregator healthAggregator;
  final Map<int, double> sizesPx;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'seg: ${segProcessingMs?.toStringAsFixed(1) ?? '--'}ms   '
            'tracks: ${tracks.length}',
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
          if (loopSummary != null)
            Text(
              loopSummary!,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          if (thermal != null)
            Text(
              'thermal: ${thermal!.name}',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          if (checkpointFailures > 0)
            Text(
              'checkpoint failed ×$checkpointFailures',
              style: const TextStyle(
                color: Colors.redAccent,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          for (final track in tracks)
            Text(
              '#${track.trackId}: '
              '${healthAggregator.currentLabel(track.trackId) ?? '--'} '
              '(${sizesPx[track.trackId]?.toStringAsFixed(0) ?? '--'}px²)',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
        ],
      ),
    );
  }
}
