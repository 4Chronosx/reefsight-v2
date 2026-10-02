import 'dart:math' as math;

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

/// A two-sided confidence interval, `[low, high]`.
class ConfidenceInterval {
  const ConfidenceInterval(this.low, this.high);

  final double low;
  final double high;
}

/// Sub-plan 17: the 95% (by default) Wilson score interval on a proportion
/// of [successes] out of [n] -- for bleaching prevalence, (bleached,
/// classified). Wilson rather than the normal approximation because it stays
/// sensible at small n and at 0% or 100%: never a negative lower bound,
/// never a zero-width interval (Newcombe 1998, Stat Med 17:857-872, method
/// 3). At k = 0 and k = n the bounds are exactly 0 and 1; they are set
/// directly there, since floating-point drift would land a hair inside.
/// `null` when [n] is 0, matching [bleachingPrevalence].
ConfidenceInterval? wilsonInterval(int successes, int n, {double z = 1.96}) {
  assert(successes >= 0 && successes <= n);
  if (n == 0) return null;

  final p = successes / n;
  final z2 = z * z;
  final denominator = 1 + z2 / n;
  final centre = (p + z2 / (2 * n)) / denominator;
  final halfWidth =
      z / denominator * math.sqrt(p * (1 - p) / n + z2 / (4 * n * n));
  return ConfidenceInterval(
    successes == 0 ? 0.0 : math.max(0.0, centre - halfWidth),
    successes == n ? 1.0 : math.min(1.0, centre + halfWidth),
  );
}

/// Sub-plan 17: the exact (Garwood 1936) two-sided interval on a Poisson
/// [count] at level `1 - alpha` -- the colony count behind density, from
/// sampling one belt. The usual chi-square form, `chi²(alpha/2; 2k) / 2` to
/// `chi²(1 - alpha/2; 2k + 2) / 2`, is computed as the equivalent gamma
/// quantiles (shape k and k + 1, scale 1). Those are found by bisection on
/// the regularized incomplete gamma function rather than a lookup table:
/// about as short, exact at every count, and no switch to a normal
/// approximation at some cutoff. The lower bound is 0 for a count of 0.
ConfidenceInterval poissonCountInterval(int count, {double alpha = 0.05}) {
  assert(count >= 0);
  final low = count == 0 ? 0.0 : _gammaQuantile(alpha / 2, count.toDouble());
  final high = _gammaQuantile(1 - alpha / 2, count + 1.0);
  return ConfidenceInterval(low, high);
}

/// Sub-plan 17: [density]'s interval -- [poissonCountInterval] on
/// [colonyCount] divided by the same belt area. Sampling uncertainty only:
/// it says nothing about detector misses or double counts.
ConfidenceInterval densityInterval({
  required int colonyCount,
  required double tapeLengthMeters,
  double beltWidthMeters = 1.0,
  double alpha = 0.05,
}) {
  final area = tapeLengthMeters * beltWidthMeters;
  final count = poissonCountInterval(colonyCount, alpha: alpha);
  return ConfidenceInterval(count.low / area, count.high / area);
}

/// The x with `P(shape, x) == probability`, by bisection. P is monotone in
/// x, so this always converges; 200 halvings is far past double precision.
double _gammaQuantile(double probability, double shape) {
  var low = 0.0;
  var high = shape + 20 * math.sqrt(shape) + 20;
  while (_regularizedGammaP(shape, high) < probability) {
    high *= 2;
  }
  for (var i = 0; i < 200 && high - low > 1e-12 * math.max(1.0, high); i++) {
    final mid = (low + high) / 2;
    if (_regularizedGammaP(shape, mid) < probability) {
      low = mid;
    } else {
      high = mid;
    }
  }
  return (low + high) / 2;
}

/// The regularized lower incomplete gamma function P(a, x): a series for
/// `x < a + 1`, otherwise 1 minus a Lentz continued fraction for Q(a, x)
/// (Numerical Recipes, `gammp`).
double _regularizedGammaP(double a, double x) {
  if (x <= 0) return 0.0;
  const epsilon = 1e-15;
  final logPrefactor = -x + a * math.log(x) - _logGamma(a);

  if (x < a + 1) {
    var term = 1 / a;
    var sum = term;
    for (var ap = a + 1; ap < a + 1000; ap++) {
      term *= x / ap;
      sum += term;
      if (term.abs() < sum.abs() * epsilon) break;
    }
    return sum * math.exp(logPrefactor);
  }

  const tiny = 1e-300;
  var b = x + 1 - a;
  var c = 1 / tiny;
  var d = 1 / b;
  var h = d;
  for (var i = 1; i < 1000; i++) {
    final an = -i * (i - a);
    b += 2;
    d = an * d + b;
    if (d.abs() < tiny) d = tiny;
    c = b + an / c;
    if (c.abs() < tiny) c = tiny;
    d = 1 / d;
    final delta = d * c;
    h *= delta;
    if ((delta - 1).abs() < epsilon) break;
  }
  return 1 - math.exp(logPrefactor) * h;
}

/// ln Γ(x) for x > 0, Lanczos approximation (Numerical Recipes, `gammln`;
/// relative error below 2e-10).
double _logGamma(double x) {
  const coefficients = [
    76.18009172947146,
    -86.50532032941677,
    24.01409824083091,
    -1.231739572450155,
    0.1208650973866179e-2,
    -0.5395239384953e-5,
  ];
  var y = x;
  var tmp = x + 5.5;
  tmp -= (x + 0.5) * math.log(tmp);
  var series = 1.000000000190015;
  for (final coefficient in coefficients) {
    y += 1;
    series += coefficient / y;
  }
  return -tmp + math.log(2.5066282746310005 * series / x);
}
