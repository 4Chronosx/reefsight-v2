import 'bleaching_classifier.dart';
import 'classification_policy.dart';

/// Confidence-weighted average of a colony's health classifications, keyed
/// by tracker track id.
///
/// Per `ReefSight_Specification.md` ("Per-colony decisions"): a
/// project-specific engineering choice over majority-vote or
/// best-single-frame alternatives, not literature-derived. The classifier is
/// binary (NMFS-OSI `CORAL` / `CORAL_BL`), so a sample's bleached-ness is
/// encoded as 0/1 and averaged weighted by that sample's classification
/// confidence: `sum(confidence_i * isBleached_i) / sum(confidence_i)`.
///
/// Sub-plan 10 (classifier input and reject) gates what counts: a sample
/// below [confidenceFloor] is ignored here (the history still keeps it,
/// flagged `uncertain`), and a colony has no label -- shown as "Uncertain"
/// -- until it has [minConfidentSamples] confident samples. Because
/// `transect_metrics.dart`'s `bleachingPrevalence` excludes null labels,
/// prevalence is then computed over confidently classified colonies only.
class HealthAggregator {
  HealthAggregator({
    this.confidenceFloor = ClassificationPolicy.classifyConfFloor,
    this.minConfidentSamples = ClassificationPolicy.minConfidentSamples,
  });

  static const String healthyLabel = 'CORAL';
  static const String bleachedLabel = 'CORAL_BL';

  final double confidenceFloor;
  final int minConfidentSamples;

  final Map<int, double> _weightedBleachedSum = {};
  final Map<int, double> _weightSum = {};
  final Map<int, int> _confidentCount = {};

  /// Whether [health] is confident enough to count towards a label.
  bool isConfident(ColonyHealth health) =>
      health.confidence >= confidenceFloor;

  /// Folds one classification into [trackId]'s running average. `null` (a
  /// failed/skipped classification) and below-floor samples are no-ops.
  void record(int trackId, ColonyHealth? health) {
    if (health == null || !isConfident(health)) return;

    final isBleached = health.label == bleachedLabel ? 1.0 : 0.0;
    _weightedBleachedSum[trackId] =
        (_weightedBleachedSum[trackId] ?? 0) + health.confidence * isBleached;
    _weightSum[trackId] = (_weightSum[trackId] ?? 0) + health.confidence;
    _confidentCount[trackId] = (_confidentCount[trackId] ?? 0) + 1;
  }

  /// How many confident samples [trackId] has.
  int confidentSamples(int trackId) => _confidentCount[trackId] ?? 0;

  /// The confidence-weighted average bleached-ness in `[0, 1]` for
  /// [trackId], or `null` until it has [minConfidentSamples] confident
  /// samples.
  double? bleachedScore(int trackId) {
    if (confidentSamples(trackId) < minConfidentSamples) return null;
    final weight = _weightSum[trackId];
    if (weight == null || weight == 0) return null;
    return _weightedBleachedSum[trackId]! / weight;
  }

  /// [bleachedLabel] if the weighted score is >= 0.5, else [healthyLabel].
  /// `null` ("Uncertain") until [trackId] has [minConfidentSamples]
  /// confident samples.
  String? currentLabel(int trackId) {
    final score = bleachedScore(trackId);
    if (score == null) return null;
    return score >= 0.5 ? bleachedLabel : healthyLabel;
  }
}
