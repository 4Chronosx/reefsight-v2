import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/services/health_history_recorder.dart';
import 'package:reefsight_mobile/services/tracked_colony_record.dart';
import 'package:reefsight_mobile/services/transect_metrics.dart';

// Sub-plan 4 (storage-and-metrics), task 6: post-transect analysis
// (density, size-frequency, bleaching prevalence) per the belt-transect
// methodology cited in ReefSight_Development_Plan.md §9-10 (English/
// Wilkinson/Baker; NOAA NCRMP; AIMS marked-tape). Density's denominator is
// the physical tape length, never GPS/pixel-derived -- these functions take
// it as a plain parameter, not something computed here. Bleaching
// prevalence counts a colony as bleached iff its final aggregated
// `healthLabel` is `HealthAggregator.bleachedLabel` ('CORAL_BL'), matching
// sub-plan 3's confidence-weighted-average decision rather than a fresh
// per-record vote.

TrackedColonyRecord colony({
  String? healthLabel,
  double? sizePx,
}) {
  final now = DateTime.utc(2026, 1, 1);
  return TrackedColonyRecord(
    sessionId: 1,
    trackId: 1,
    healthLabel: healthLabel,
    healthHistory: const <HealthHistorySample>[],
    sizePx: sizePx,
    firstSeenAt: now,
    lastSeenAt: now,
  );
}

void main() {
  intervalTests();

  group('density', () {
    test('colony count per linear meter of tape, default 1m belt width', () {
      expect(density(colonyCount: 20, tapeLengthMeters: 10), 2.0);
    });

    test('divides by belt area (length x width) when width is given', () {
      expect(
        density(colonyCount: 20, tapeLengthMeters: 10, beltWidthMeters: 2),
        1.0,
      );
    });

    test('zero colonies gives zero density', () {
      expect(density(colonyCount: 0, tapeLengthMeters: 10), 0.0);
    });
  });

  group('sizeFrequency', () {
    test('bins pixel-area sizes into the requested number of equal-width '
        'buckets', () {
      final sizes = [0.0, 10.0, 20.0, 30.0, 40.0];
      final histogram = sizeFrequency(sizes, binCount: 2);

      expect(histogram, hasLength(2));
      final totalCount = histogram.fold<int>(0, (sum, b) => sum + b.count);
      expect(totalCount, 5);
    });

    test('an empty size list gives an empty histogram', () {
      expect(sizeFrequency(const [], binCount: 4), isEmpty);
    });

    test('all-identical sizes land in a single bucket', () {
      final histogram = sizeFrequency([5.0, 5.0, 5.0], binCount: 3);
      final nonEmpty = histogram.where((b) => b.count > 0);

      expect(nonEmpty, hasLength(1));
      expect(nonEmpty.single.count, 3);
    });
  });

  group('bleachingPrevalence', () {
    test('fraction of colonies whose final label is CORAL_BL', () {
      final colonies = [
        colony(healthLabel: 'CORAL'),
        colony(healthLabel: 'CORAL_BL'),
        colony(healthLabel: 'CORAL_BL'),
        colony(healthLabel: 'CORAL'),
      ];

      expect(bleachingPrevalence(colonies), 0.5);
    });

    test('colonies never successfully classified (null label) are excluded '
        'from the denominator', () {
      final colonies = [
        colony(healthLabel: 'CORAL_BL'),
        colony(healthLabel: null),
      ];

      expect(bleachingPrevalence(colonies), 1.0);
    });

    test('no classified colonies gives null, not a divide-by-zero', () {
      expect(bleachingPrevalence([colony(healthLabel: null)]), isNull);
    });

    test('an empty colony list gives null', () {
      expect(bleachingPrevalence(const []), isNull);
    });
  });
}

// Sub-plan 17: 95% intervals on prevalence (Wilson score) and on the colony
// count behind density (exact Poisson, Garwood). Reference values are the
// published ones where a source exists -- Newcombe (1998), Stat Med
// 17:857-872, Table I, method 3 (Wilson without continuity correction) --
// and the closed forms otherwise.
void expectInterval(
  ConfidenceInterval? actual,
  double low,
  double high, {
  double tolerance = 1e-4,
}) {
  expect(actual, isNotNull);
  expect(actual!.low, closeTo(low, tolerance), reason: 'low');
  expect(actual.high, closeTo(high, tolerance), reason: 'high');
}

void intervalTests() {
  group('wilsonInterval', () {
    test('matches Newcombe (1998) Table I', () {
      expectInterval(wilsonInterval(81, 263), 0.2553, 0.3662);
      expectInterval(wilsonInterval(15, 148), 0.0624, 0.1605);
      expectInterval(wilsonInterval(0, 20), 0.0, 0.1611);
      expectInterval(wilsonInterval(1, 29), 0.0061, 0.1718);
    });

    test('matches the closed form at 0/10, 5/10, 10/10 and 18/100', () {
      // 0/10's upper bound is (z²/n) / (1 + z²/n) = 0.38416 / 1.38416.
      expectInterval(wilsonInterval(0, 10), 0.0, 0.2775);
      expectInterval(wilsonInterval(5, 10), 0.2366, 0.7634);
      expectInterval(wilsonInterval(10, 10), 0.7225, 1.0);
      expectInterval(wilsonInterval(18, 100), 0.1170, 0.2667);
    });

    test('stays inside [0, 1] and contains k/n for every k <= n <= 200', () {
      for (var n = 1; n <= 200; n++) {
        for (var k = 0; k <= n; k++) {
          final interval = wilsonInterval(k, n)!;
          expect(interval.low, greaterThanOrEqualTo(0.0));
          expect(interval.high, lessThanOrEqualTo(1.0));
          expect(interval.low, lessThanOrEqualTo(k / n));
          expect(interval.high, greaterThanOrEqualTo(k / n));
        }
      }
    });

    test('n = 0 gives null, not a divide-by-zero', () {
      expect(wilsonInterval(0, 0), isNull);
    });
  });

  group('poissonCountInterval', () {
    test('count 0 and 1 match the closed forms', () {
      // Lower(1) = -ln(0.975); Upper(0) = -ln(0.025).
      expectInterval(poissonCountInterval(0), 0.0, 3.6889);
      expectInterval(poissonCountInterval(1), 0.0253, 5.5716);
    });

    test('count 10 and 100 match the chi-square tables', () {
      // chi²(0.025; 20)/2, chi²(0.975; 22)/2 and chi²(0.025; 200)/2,
      // chi²(0.975; 202)/2.
      expectInterval(poissonCountInterval(10), 4.7954, 18.3904, tolerance: 1e-3);
      expectInterval(poissonCountInterval(100), 81.364, 121.63, tolerance: 1e-2);
    });

    test('a large count stays close to the normal approximation', () {
      final interval = poissonCountInterval(1000);
      expect(interval.low, closeTo(1000 - 1.96 * 31.62, 2.0));
      expect(interval.high, closeTo(1000 + 1.96 * 31.62, 2.0));
    });
  });

  group('densityInterval', () {
    test('divides the count interval by the belt area', () {
      expectInterval(
        densityInterval(colonyCount: 10, tapeLengthMeters: 10, beltWidthMeters: 2),
        4.7954 / 20,
        18.3904 / 20,
      );
    });
  });
}
