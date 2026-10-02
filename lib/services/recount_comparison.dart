import 'recount.dart';

/// Sub-plan 14 step 5: the app's numbers against the manual recount -- the
/// raw material for the Spec's Phase E "mean absolute error or
/// percentage-point difference". Pure and Flutter-free, like
/// `report_data.dart`, so Summary and both CSV exports share one
/// calculation.
///
/// The two prevalences have different denominators, on purpose: the app's
/// is over *classified* colonies (sub-plan 10 -- Uncertain colonies are
/// left out), the recount's over every colony counted. Anything showing
/// [prevalenceDiffPp] should say so.
class RecountComparison {
  const RecountComparison({
    required this.appTotal,
    required this.appBleached,
    required this.appClassified,
    required this.recount,
  });

  final int appTotal;
  final int appBleached;
  final int appClassified;
  final Recount recount;

  /// App minus recount: positive is an overcount.
  int get countError => appTotal - recount.total;

  int get absoluteCountError => countError.abs();

  /// [countError] as a percentage of the recount. `null` when the recount
  /// is zero.
  double? get countErrorPercent =>
      recount.total == 0 ? null : countError / recount.total * 100;

  /// Bleached over classified colonies, as a percentage. `null` with none
  /// classified.
  double? get appPrevalencePercent =>
      appClassified == 0 ? null : appBleached / appClassified * 100;

  /// Bleached over all counted colonies, as a percentage. `null` with none
  /// counted.
  double? get recountPrevalencePercent =>
      recount.total == 0 ? null : recount.bleached / recount.total * 100;

  /// App minus recount prevalence, in percentage points.
  double? get prevalenceDiffPp {
    final app = appPrevalencePercent;
    final manual = recountPrevalencePercent;
    return app == null || manual == null ? null : app - manual;
  }
}
