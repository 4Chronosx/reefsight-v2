import 'health_aggregator.dart';
import 'tracked_colony_record.dart';
import 'transect_metrics.dart';
import 'transect_session.dart';

/// Sub-plan 5 (ui-and-reporting), task 3: the report screens' data
/// aggregation layer. Deliberately pure/dependency-free (no Flutter
/// imports), matching `transect_metrics.dart`'s own style -- this is a thin
/// wrapper over that file's `density`/`sizeFrequency`/`bleachingPrevalence`
/// plus health-label counting, not new domain logic, so it stays testable
/// without a widget tree or a database.
class TransectReport {
  TransectReport({required this.session, required this.colonies});

  final TransectSession session;
  final List<TrackedColonyRecord> colonies;

  int get totalColonies => colonies.length;

  int get healthyCount => colonies
      .where((colony) => colony.healthLabel == HealthAggregator.healthyLabel)
      .length;

  int get bleachedCount => colonies
      .where((colony) => colony.healthLabel == HealthAggregator.bleachedLabel)
      .length;

  /// Colonies whose final aggregated label was never set (see
  /// `TrackedColonyRecord.healthLabel`'s doc comment) -- excluded from
  /// [bleachingPrevalenceFraction]'s denominator, same as
  /// `transect_metrics.dart`'s `bleachingPrevalence`.
  int get unclassifiedCount =>
      colonies.where((colony) => colony.healthLabel == null).length;

  double? get bleachingPrevalenceFraction => bleachingPrevalence(colonies);

  double get densityPerSquareMeter => density(
        colonyCount: totalColonies,
        tapeLengthMeters: session.tapeLengthMeters,
        beltWidthMeters: session.beltWidthMeters,
      );

  /// Colonies with no mask-derived size (`sizePx == null`, e.g. a track
  /// that was never seen with a mask) are dropped rather than treated as
  /// zero -- a size of zero would be a fabricated data point, not an
  /// observed one.
  List<SizeFrequencyBin> sizeFrequencyHistogram({required int binCount}) {
    final sizes = colonies
        .map((colony) => colony.sizePx)
        .whereType<double>()
        .toList(growable: false);
    return sizeFrequency(sizes, binCount: binCount);
  }
}
