import 'bleaching_classifier.dart';

/// Confidence-weighted average of per-frame health classifications, keyed by
/// tracker track id.
///
/// Per `ReefSight_Specification.md` (Track 3 §6-7): a project-specific
/// engineering choice over majority-vote or best-single-frame alternatives,
/// not literature-derived. The classifier is binary (NMFS-OSI `CORAL` /
/// `CORAL_BL`), so a frame's bleached-ness is encoded as 0/1 and averaged
/// weighted by that frame's classification confidence:
/// `sum(confidence_i * isBleached_i) / sum(confidence_i)`.
class HealthAggregator {
  static const String healthyLabel = 'CORAL';
  static const String bleachedLabel = 'CORAL_BL';

  final Map<int, double> _weightedBleachedSum = {};
  final Map<int, double> _weightSum = {};

  /// Folds one frame's classification into [trackId]'s running average.
  /// `null` (a failed/skipped classification for this frame) is a no-op.
  void record(int trackId, ColonyHealth? health) {
    if (health == null) return;

    final isBleached = health.label == bleachedLabel ? 1.0 : 0.0;
    _weightedBleachedSum[trackId] =
        (_weightedBleachedSum[trackId] ?? 0) + health.confidence * isBleached;
    _weightSum[trackId] = (_weightSum[trackId] ?? 0) + health.confidence;
  }

  /// The confidence-weighted average bleached-ness in `[0, 1]` for
  /// [trackId], or `null` if nothing has been recorded for it yet.
  double? bleachedScore(int trackId) {
    final weight = _weightSum[trackId];
    if (weight == null || weight == 0) return null;
    return _weightedBleachedSum[trackId]! / weight;
  }

  /// [bleachedLabel] if the weighted score is >= 0.5, else [healthyLabel].
  /// `null` if nothing has been recorded for [trackId] yet.
  String? currentLabel(int trackId) {
    final score = bleachedScore(trackId);
    if (score == null) return null;
    return score >= 0.5 ? bleachedLabel : healthyLabel;
  }
}
