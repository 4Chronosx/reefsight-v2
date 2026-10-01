/// Thresholds deciding which bleaching-classifier samples count (sub-plan 10,
/// `mobile/sub-plans/10-classifier-input-and-reject.md`, steps 2-3). One
/// place for them, so the live loop, the aggregator and the history agree.
///
/// These are starting values from the sub-plan, not tuned numbers. Revisit
/// once sub-plan 08 step 3 has the detector's score histogram
/// ([classifySegFloor]) and ML sub-plan 2 has measured the classifier's
/// calibration ([classifyConfFloor]).
abstract final class ClassificationPolicy {
  /// A detection below this segmentation confidence is never classified.
  /// A placeholder until sub-plan 08's score histogram exists.
  static const double classifySegFloor = 0.4;

  /// Minimum fraction of an `insideMaskSquare` crop that must be colony
  /// mask. Below it the sample is "insufficient view", not a
  /// classification.
  static const double minCoverage = 0.6;

  /// A classification below this top-1 confidence is recorded in the
  /// history as `uncertain` and doesn't feed the colony's label. The
  /// classifier is binary, so top-1 is always >= 0.5.
  static const double classifyConfFloor = 0.7;

  /// A colony has no label (shown as "Uncertain") until it has this many
  /// confident samples.
  static const int minConfidentSamples = 2;
}
