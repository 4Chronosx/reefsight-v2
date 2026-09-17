import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/services/bleaching_classifier.dart';
import 'package:reefsight_mobile/services/health_history_recorder.dart';

// Sub-plan 4 (storage-and-metrics), task 3: `HealthAggregator` (sub-plan 3)
// deliberately keeps only running weighted sums, not the raw per-frame
// sequence -- it can't reconstruct "confidence history across frames" for
// the SQLite schema (ReefSight_Specification.md, "Storage"). This recorder
// is the missing piece: same `record(trackId, health)` call site, but it
// appends instead of folding, so the schema's history column has real data.

void main() {
  group('HealthHistoryRecorder', () {
    test('an unrecorded track id has an empty history', () {
      final recorder = HealthHistoryRecorder();
      expect(recorder.samplesFor(999), isEmpty);
    });

    test('records a single sample with its label, confidence, and time', () {
      final recorder = HealthHistoryRecorder();
      final at = DateTime.utc(2026, 1, 1, 12);

      recorder.record(
        1,
        const ColonyHealth(label: 'CORAL', confidence: 0.9),
        at,
      );

      final samples = recorder.samplesFor(1);
      expect(samples, hasLength(1));
      expect(samples.single.label, 'CORAL');
      expect(samples.single.confidence, 0.9);
      expect(samples.single.at, at);
    });

    test('accumulates samples in recorded order', () {
      final recorder = HealthHistoryRecorder();
      recorder.record(
        1,
        const ColonyHealth(label: 'CORAL', confidence: 0.9),
        DateTime.utc(2026, 1, 1, 12, 0),
      );
      recorder.record(
        1,
        const ColonyHealth(label: 'CORAL_BL', confidence: 0.6),
        DateTime.utc(2026, 1, 1, 12, 1),
      );

      final samples = recorder.samplesFor(1);
      expect(samples, hasLength(2));
      expect(samples[0].label, 'CORAL');
      expect(samples[1].label, 'CORAL_BL');
    });

    test('tracks are recorded independently by track id', () {
      final recorder = HealthHistoryRecorder();
      recorder.record(
        1,
        const ColonyHealth(label: 'CORAL_BL', confidence: 0.9),
        DateTime.utc(2026, 1, 1),
      );
      recorder.record(
        2,
        const ColonyHealth(label: 'CORAL', confidence: 0.9),
        DateTime.utc(2026, 1, 1),
      );

      expect(recorder.samplesFor(1), hasLength(1));
      expect(recorder.samplesFor(2), hasLength(1));
      expect(recorder.samplesFor(1).single.label, 'CORAL_BL');
    });

    test('a null health record (failed classification) is a no-op', () {
      final recorder = HealthHistoryRecorder();
      recorder.record(1, null, DateTime.utc(2026, 1, 1));

      expect(recorder.samplesFor(1), isEmpty);
    });

    test('samplesFor returns an unmodifiable view', () {
      final recorder = HealthHistoryRecorder();
      recorder.record(
        1,
        const ColonyHealth(label: 'CORAL', confidence: 0.9),
        DateTime.utc(2026, 1, 1),
      );

      expect(
        () => recorder.samplesFor(1).add(
              HealthHistorySample(
                label: 'CORAL',
                confidence: 0.5,
                at: DateTime.utc(2026, 1, 1),
              ),
            ),
        throwsUnsupportedError,
      );
    });
  });
}
