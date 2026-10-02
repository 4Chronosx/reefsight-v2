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
      // Sub-plan 10: a null label means "Uncertain" (never classified, or
      // too few confident samples).
      expect(report.uncertainCount, 1);
      expect(report.classifiedCount, 3);
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

  intervalTests();
}

// Sub-plan 17: the intervals and the small-sample rule (fewer than
// `minClassifiedForPrevalence` classified colonies -> the executive wording
// gives "too few" instead of a percentage).
List<TrackedColonyRecord> colonies({
  int bleached = 0,
  int healthy = 0,
  int uncertain = 0,
}) => [
      for (var i = 0; i < bleached; i++) colony(healthLabel: 'CORAL_BL'),
      for (var i = 0; i < healthy; i++) colony(healthLabel: 'CORAL'),
      for (var i = 0; i < uncertain; i++) colony(healthLabel: null),
    ];

void intervalTests() {
  final session = TransectSession(
    id: 1,
    startedAt: DateTime.utc(2026, 1, 1),
    tapeLengthMeters: 50,
  );

  group('PrevalenceEstimate', () {
    test('is null with nothing classified', () {
      expect(PrevalenceEstimate.of(bleached: 0, classified: 0), isNull);
    });

    test('is reliable from minClassifiedForPrevalence classified up', () {
      expect(minClassifiedForPrevalence, 10);
      expect(PrevalenceEstimate.of(bleached: 3, classified: 9)!.reliable, isFalse);
      expect(PrevalenceEstimate.of(bleached: 3, classified: 10)!.reliable, isTrue);
    });

    test('carries the Wilson interval on (bleached, classified)', () {
      final estimate = PrevalenceEstimate.of(bleached: 18, classified: 100)!;
      expect(estimate.fraction, 0.18);
      expect(estimate.interval.low, closeTo(0.1170, 1e-4));
      expect(estimate.interval.high, closeTo(0.2667, 1e-4));
    });

    test('wording: executive, technical and card', () {
      final estimate = PrevalenceEstimate.of(bleached: 18, classified: 100)!;
      expect(
        estimate.executiveSentence,
        'About 18% of classified colonies were bleached (likely between 12% and 27%).',
      );
      expect(
        estimate.technicalLine,
        'Bleaching prevalence: 18.0% (95% CI 11.7–26.7%, Wilson; n = 100 classified)',
      );
      expect(estimate.cardLabel, '18% bleached (12–27%)');
    });

    test('wording below the threshold: too few, but technical keeps the number', () {
      final estimate = PrevalenceEstimate.of(bleached: 3, classified: 6)!;
      expect(
        estimate.executiveSentence,
        'Too few classified colonies to estimate bleaching reliably (n = 6).',
      );
      expect(estimate.cardLabel, 'Too few classified (n = 6)');
      expect(estimate.technicalLine, startsWith('Bleaching prevalence: 50.0% (95% CI '));
    });
  });

  group('TransectReport intervals', () {
    test('prevalence is over classified colonies only', () {
      final report = TransectReport(
        session: session,
        colonies: colonies(bleached: 5, healthy: 5, uncertain: 7),
      );
      expect(report.prevalence!.classified, 10);
      expect(report.prevalenceReliable, isTrue);
      expect(report.prevalenceInterval!.low, closeTo(0.2366, 1e-4));
    });

    test('prevalenceReliable is false below the threshold', () {
      final report = TransectReport(
        session: session,
        colonies: colonies(bleached: 1, healthy: 8, uncertain: 20),
      );
      expect(report.prevalenceReliable, isFalse);
    });

    test('nothing classified: no prevalence, not reliable', () {
      final report = TransectReport(session: session, colonies: colonies(uncertain: 3));
      expect(report.prevalence, isNull);
      expect(report.prevalenceInterval, isNull);
      expect(report.prevalenceReliable, isFalse);
    });

    test('densityInterval is the count interval over the belt area', () {
      final report = TransectReport(session: session, colonies: colonies(healthy: 10));
      expect(report.densityInterval.low, closeTo(4.7954 / 50, 1e-4));
      expect(report.densityInterval.high, closeTo(18.3904 / 50, 1e-4));
    });

    test('density wording', () {
      final report = TransectReport(session: session, colonies: colonies(healthy: 10));
      expect(report.executiveDensityLine, '≈ 0.20 colonies/m² (0.10–0.37)');
      expect(
        report.technicalDensityLine,
        'Density: 0.20 colonies/m² (95% CI 0.10–0.37, exact Poisson; '
        'n = 10 colonies, 50 m² belt)',
      );
    });
  });
}
