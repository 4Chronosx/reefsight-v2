import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/services/health_history_recorder.dart';
import 'package:reefsight_mobile/services/report_data.dart';
import 'package:reefsight_mobile/services/tracked_colony_record.dart';
import 'package:reefsight_mobile/services/transect_session.dart';

// Sub-plan 5 (ui-and-reporting), task 3: the report screens' data
// aggregation layer. Pure/dependency-free (no Flutter imports), matching
// `transect_metrics.dart`'s style -- it's a thin wrapper over that file's
// `density`/`sizeFrequency`/`bleachingPrevalence` plus health-label
// counting, not new domain logic.

TrackedColonyRecord colony({String? healthLabel, double? sizePx}) {
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
  group('TransectReport', () {
    final session = TransectSession(
      id: 1,
      startedAt: DateTime.utc(2026, 1, 1),
      tapeLengthMeters: 10,
    );

    test('counts healthy/bleached/unclassified colonies by label', () {
      final report = TransectReport(
        session: session,
        colonies: [
          colony(healthLabel: 'CORAL'),
          colony(healthLabel: 'CORAL'),
          colony(healthLabel: 'CORAL_BL'),
          colony(healthLabel: null),
        ],
      );

      expect(report.totalColonies, 4);
      expect(report.healthyCount, 2);
      expect(report.bleachedCount, 1);
      expect(report.unclassifiedCount, 1);
    });

    test('bleachingPrevalenceFraction delegates to transect_metrics, '
        'excluding unclassified colonies', () {
      final report = TransectReport(
        session: session,
        colonies: [
          colony(healthLabel: 'CORAL_BL'),
          colony(healthLabel: null),
        ],
      );

      expect(report.bleachingPrevalenceFraction, 1.0);
    });

    test('bleachingPrevalenceFraction is null when nothing was classified',
        () {
      final report = TransectReport(session: session, colonies: const []);
      expect(report.bleachingPrevalenceFraction, isNull);
    });

    test('densityPerSquareMeter uses the session\'s tape/belt width', () {
      final report = TransectReport(
        session: session,
        colonies: List.generate(20, (_) => colony(healthLabel: 'CORAL')),
      );

      expect(report.densityPerSquareMeter, 2.0);
    });

    test('sizeFrequencyHistogram bins only colonies with a known size', () {
      final report = TransectReport(
        session: session,
        colonies: [
          colony(sizePx: 10),
          colony(sizePx: 20),
          colony(sizePx: null),
        ],
      );

      final histogram = report.sizeFrequencyHistogram(binCount: 2);
      final totalBinned = histogram.fold<int>(0, (sum, b) => sum + b.count);

      expect(totalBinned, 2);
    });
  });
}
