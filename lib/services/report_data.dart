import 'health_aggregator.dart';
import 'recount_comparison.dart';
import 'tracked_colony_record.dart';
import 'transect_metrics.dart';
import 'transect_metrics.dart' as metrics show densityInterval;
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

  /// Colonies with no final label, shown as "Uncertain" (sub-plan 10):
  /// never classified, or fewer than `minConfidentSamples` confident
  /// samples. Excluded from [bleachingPrevalenceFraction]'s denominator,
  /// same as `transect_metrics.dart`'s `bleachingPrevalence`.
  int get uncertainCount =>
      colonies.where((colony) => colony.healthLabel == null).length;

  /// Colonies with a confident label -- the denominator of
  /// [bleachingPrevalenceFraction].
  int get classifiedCount => totalColonies - uncertainCount;

  double? get bleachingPrevalenceFraction => bleachingPrevalence(colonies);

  /// Sub-plan 17: prevalence with its Wilson interval, over the same
  /// classified colonies as [bleachingPrevalenceFraction]. `null` when
  /// nothing was classified.
  PrevalenceEstimate? get prevalence =>
      PrevalenceEstimate.of(bleached: bleachedCount, classified: classifiedCount);

  ConfidenceInterval? get prevalenceInterval => prevalence?.interval;

  /// Whether enough colonies were classified for the executive tab to show
  /// a percentage (sub-plan 17 decision 4).
  bool get prevalenceReliable => prevalence?.reliable ?? false;

  /// Sub-plan 14: this report against the session's manual recount, or
  /// `null` if none has been entered.
  RecountComparison? get recountComparison {
    final recount = session.recount;
    if (recount == null) return null;
    return RecountComparison(
      appTotal: totalColonies,
      appBleached: bleachedCount,
      appClassified: classifiedCount,
      recount: recount,
    );
  }

  double get densityPerSquareMeter => density(
        colonyCount: totalColonies,
        tapeLengthMeters: session.tapeLengthMeters,
        beltWidthMeters: session.beltWidthMeters,
      );

  /// Sub-plan 17: [densityPerSquareMeter]'s exact Poisson interval.
  ConfidenceInterval get densityInterval => metrics.densityInterval(
        colonyCount: totalColonies,
        tapeLengthMeters: session.tapeLengthMeters,
        beltWidthMeters: session.beltWidthMeters,
      );

  /// Executive tab: "≈ 0.42 colonies/m² (0.31–0.56)".
  String get executiveDensityLine {
    final interval = densityInterval;
    return '≈ ${densityPerSquareMeter.toStringAsFixed(2)} colonies/m² '
        '(${interval.low.toStringAsFixed(2)}–${interval.high.toStringAsFixed(2)})';
  }

  /// Technical tab: the interval, the method, n and the belt area.
  String get technicalDensityLine {
    final interval = densityInterval;
    final area = session.tapeLengthMeters * session.beltWidthMeters;
    final areaText = area == area.roundToDouble()
        ? area.toStringAsFixed(0)
        : area.toStringAsFixed(1);
    return 'Density: ${densityPerSquareMeter.toStringAsFixed(2)} colonies/m² '
        '(95% CI ${interval.low.toStringAsFixed(2)}–${interval.high.toStringAsFixed(2)}, '
        'exact Poisson; n = $totalColonies ${totalColonies == 1 ? 'colony' : 'colonies'}, '
        '$areaText m² belt)';
  }

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

/// Sub-plan 17 decision 4: below this many classified colonies the
/// executive tab and the survey cards say "too few" instead of giving a
/// percentage; the technical tab still shows the number with its interval.
/// A starting value, kept here so it changes in one place.
const int minClassifiedForPrevalence = 10;

/// Sub-plan 17: bleaching prevalence with its 95% Wilson interval, and the
/// wording every screen uses for it -- one place, so the report tabs and
/// the Home/Surveys cards can't drift apart. Built from counts rather than
/// colonies so the cards can use `SessionSummary`'s counts directly.
class PrevalenceEstimate {
  const PrevalenceEstimate._({
    required this.bleached,
    required this.classified,
    required this.interval,
  });

  /// `null` when nothing was classified -- no estimate at all, not 0%.
  static PrevalenceEstimate? of({required int bleached, required int classified}) {
    final interval = wilsonInterval(bleached, classified);
    if (interval == null) return null;
    return PrevalenceEstimate._(
      bleached: bleached,
      classified: classified,
      interval: interval,
    );
  }

  final int bleached;
  final int classified;
  final ConfidenceInterval interval;

  double get fraction => bleached / classified;

  bool get reliable => classified >= minClassifiedForPrevalence;

  static String _percent(double fraction, int decimals) =>
      (fraction * 100).toStringAsFixed(decimals);

  String get _tooFew => 'n = $classified';

  /// Executive tab: a plain-language sentence, or the too-few message.
  String get executiveSentence => reliable
      ? 'About ${_percent(fraction, 0)}% of classified colonies were bleached '
          '(likely between ${_percent(interval.low, 0)}% and '
          '${_percent(interval.high, 0)}%).'
      : 'Too few classified colonies to estimate bleaching reliably ($_tooFew).';

  /// Technical tab: always the number, its exact interval, method and n.
  String get technicalLine =>
      'Bleaching prevalence: ${_percent(fraction, 1)}% '
      '(95% CI ${_percent(interval.low, 1)}–${_percent(interval.high, 1)}%, '
      'Wilson; n = $classified classified)';

  /// Home and Surveys cards: "18% bleached (12–27%)", or the too-few
  /// message.
  String get cardLabel => reliable
      ? '${_percent(fraction, 0)}% bleached '
          '(${_percent(interval.low, 0)}–${_percent(interval.high, 0)}%)'
      : 'Too few classified ($_tooFew)';
}
