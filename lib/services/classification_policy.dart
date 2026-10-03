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

/// The [ClassificationPolicy] thresholds as one value, so Settings ->
/// Diagnostics can override them for a transect (a comparison tool, like
/// the crop style). [defaults] is the policy itself.
class ClassificationThresholds {
  const ClassificationThresholds({
    this.segFloor = ClassificationPolicy.classifySegFloor,
    this.minCoverage = ClassificationPolicy.minCoverage,
    this.confFloor = ClassificationPolicy.classifyConfFloor,
    this.minConfidentSamples = ClassificationPolicy.minConfidentSamples,
  });

  static const ClassificationThresholds defaults = ClassificationThresholds();

  final double segFloor;
  final double minCoverage;
  final double confFloor;
  final int minConfidentSamples;

  bool get isDefault => this == defaults;

  ClassificationThresholds copyWith({
    double? segFloor,
    double? minCoverage,
    double? confFloor,
    int? minConfidentSamples,
  }) => ClassificationThresholds(
    segFloor: segFloor ?? this.segFloor,
    minCoverage: minCoverage ?? this.minCoverage,
    confFloor: confFloor ?? this.confFloor,
    minConfidentSamples: minConfidentSamples ?? this.minConfidentSamples,
  );

  /// Stored per session (schema v10) -- names match `transect_database.dart`'s
  /// `transect_sessions` columns, like `GeoFix.toColumns`.
  Map<String, Object?> toColumns() => {
    'threshold_seg_floor': segFloor,
    'threshold_min_coverage': minCoverage,
    'threshold_conf_floor': confFloor,
    'threshold_min_samples': minConfidentSamples,
  };

  static const Map<String, Object?> nullColumns = {
    'threshold_seg_floor': null,
    'threshold_min_coverage': null,
    'threshold_conf_floor': null,
    'threshold_min_samples': null,
  };

  /// `null` for a session recorded before schema v10.
  static ClassificationThresholds? fromColumns(Map<String, Object?> map) {
    final seg = map['threshold_seg_floor'] as num?;
    final coverage = map['threshold_min_coverage'] as num?;
    final conf = map['threshold_conf_floor'] as num?;
    final samples = map['threshold_min_samples'] as int?;
    if (seg == null || coverage == null || conf == null || samples == null) return null;
    return ClassificationThresholds(
      segFloor: seg.toDouble(),
      minCoverage: coverage.toDouble(),
      confFloor: conf.toDouble(),
      minConfidentSamples: samples,
    );
  }

  /// For the debug log, e.g. `seg 0.4 cov 0.6 conf 0.7 n 2`.
  String format() =>
      'seg $segFloor cov $minCoverage conf $confFloor n $minConfidentSamples';

  @override
  bool operator ==(Object other) =>
      other is ClassificationThresholds &&
      other.segFloor == segFloor &&
      other.minCoverage == minCoverage &&
      other.confFloor == confFloor &&
      other.minConfidentSamples == minConfidentSamples;

  @override
  int get hashCode => Object.hash(segFloor, minCoverage, confFloor, minConfidentSamples);
}
