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
