import 'bleaching_classifier.dart';

/// One frame's health classification, timestamped -- the raw sample
/// `HealthAggregator` (sub-plan 3) folds into a running weighted sum instead
/// of retaining.
class HealthHistorySample {
  const HealthHistorySample({
    required this.label,
    required this.confidence,
    required this.at,
  });

  final String label;
  final double confidence;
  final DateTime at;
}

/// Per-track log of raw [HealthHistorySample]s, fed by the same
/// `record(trackId, health)` call site as [HealthAggregator] (sub-plan 3's
/// `live_transect_screen.dart`), kept alongside it rather than replacing it.
///
/// `HealthAggregator` is intentionally O(1)-memory per track (running sums
/// only) for the live overlay's running label. The SQLite schema's "health
/// label + confidence history across frames" column
/// (`ReefSight_Specification.md`, "Storage") needs the actual sequence,
/// which `HealthAggregator` structurally cannot reconstruct after the fact
/// -- hence this separate recorder.
class HealthHistoryRecorder {
  final Map<int, List<HealthHistorySample>> _samples = {};

  /// Appends one frame's classification for [trackId] at [at]. `null` (a
  /// failed/skipped classification for this frame) is a no-op, matching
  /// [HealthAggregator.record]'s handling of the same case.
  void record(int trackId, ColonyHealth? health, DateTime at) {
    if (health == null) return;
    (_samples[trackId] ??= []).add(
      HealthHistorySample(
        label: health.label,
        confidence: health.confidence,
        at: at,
      ),
    );
  }

  /// The recorded sequence for [trackId], in the order it was recorded.
  /// Empty (never a `null`) if nothing has been recorded for it yet.
  List<HealthHistorySample> samplesFor(int trackId) =>
      List.unmodifiable(_samples[trackId] ?? const []);
}
