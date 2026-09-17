import 'health_aggregator.dart';
import 'tracked_colony_record.dart';

/// Post-transect analysis (Dev Plan Track 3 §9-10): density, size-frequency,
/// bleaching prevalence. Structure mirrors established belt-transect reef
/// survey methodology (English/Wilkinson/Baker's survey manual; NOAA
/// NCRMP's belt-transect protocol; AIMS's marked-tape method) -- the one
/// part of Track 3 that's literature-grounded rather than an engineering
/// choice. Deliberately pure/dependency-free (no `sqflite`, no Flutter
/// imports) so it's testable without a database, matching
/// `health_aggregator.dart`/`colony_size.dart`'s existing style.

/// Colonies per unit belt area, using the physical marked transect tape as
/// the length -- never GPS- or software-derived (`ReefSight_Specification.md`,
/// "Density, positioning, and sync"). [beltWidthMeters] defaults to `1.0`,
/// matching NCRMP's 10m x 1m belt convention.
double density({
  required int colonyCount,
  required double tapeLengthMeters,
  double beltWidthMeters = 1.0,
}) {
  return colonyCount / (tapeLengthMeters * beltWidthMeters);
}

/// One equal-width bucket of a size-frequency histogram.
class SizeFrequencyBin {
  const SizeFrequencyBin({
    required this.rangeStart,
    required this.rangeEnd,
    required this.count,
  });

  final double rangeStart;
  final double rangeEnd;
  final int count;
}

/// Buckets [sizesPx] (mask-derived pixel areas -- see `colony_size.dart`;
/// this sub-plan keeps sizes in px², not real-world units) into [binCount]
/// equal-width buckets spanning the observed min/max.
List<SizeFrequencyBin> sizeFrequency(
  List<double> sizesPx, {
  required int binCount,
}) {
  if (sizesPx.isEmpty) return const [];

  final min = sizesPx.reduce((a, b) => a < b ? a : b);
  final max = sizesPx.reduce((a, b) => a > b ? a : b);
  final span = max - min;
  final width = span == 0 ? 1.0 : span / binCount;

  final counts = List<int>.filled(binCount, 0);
  for (final size in sizesPx) {
    var index = span == 0 ? 0 : ((size - min) / width).floor();
    if (index >= binCount) index = binCount - 1;
    if (index < 0) index = 0;
    counts[index]++;
  }

  return List.generate(
    binCount,
    (i) => SizeFrequencyBin(
      rangeStart: min + i * width,
      rangeEnd: min + (i + 1) * width,
      count: counts[i],
    ),
  );
}

/// Fraction of successfully-classified colonies whose final aggregated
/// label (`HealthAggregator.currentLabel`, sub-plan 3's confidence-weighted
/// average) is [HealthAggregator.bleachedLabel]. Colonies never
/// successfully classified (`healthLabel == null`) are excluded from both
/// numerator and denominator, not counted as healthy. `null` (not `0.0`)
/// when no colony was ever classified, so a caller can't mistake "no data"
/// for "zero bleaching."
double? bleachingPrevalence(List<TrackedColonyRecord> colonies) {
  final classified =
      colonies.where((colony) => colony.healthLabel != null).toList();
  if (classified.isEmpty) return null;

  final bleachedCount = classified
      .where((colony) => colony.healthLabel == HealthAggregator.bleachedLabel)
      .length;
  return bleachedCount / classified.length;
}
