import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/services/bleaching_classifier.dart';
import 'package:reefsight_mobile/services/health_aggregator.dart';

// Spec (Track 3 §6-7 / ReefSight_Specification.md "Tracker integration; per-
// colony health aggregation"): confidence-weighted average across every
// frame a colony is tracked in -- an explicitly project-specific choice over
// majority-vote or best-single-frame. The classifier is binary (NMFS-OSI
// "CORAL" / "CORAL_BL" -- research_logs/stage_c/external_noaa_model_eval),
// so bleached-ness is encoded as a 0/1 score and weighted-averaged by
// per-frame confidence.

void main() {
  group('HealthAggregator', () {
    test('a single healthy classification reports CORAL', () {
      final aggregator = HealthAggregator();
      aggregator.record(
        1,
        const ColonyHealth(label: 'CORAL', confidence: 0.9),
      );

      expect(aggregator.currentLabel(1), 'CORAL');
    });

    test('a single bleached classification reports CORAL_BL', () {
      final aggregator = HealthAggregator();
      aggregator.record(
        1,
        const ColonyHealth(label: 'CORAL_BL', confidence: 0.9),
      );

      expect(aggregator.currentLabel(1), 'CORAL_BL');
    });

    test('an unrecorded track id has no label yet', () {
      final aggregator = HealthAggregator();
      expect(aggregator.currentLabel(999), isNull);
    });

    test(
        'a high-confidence bleached read outweighs a low-confidence healthy '
        'read', () {
      final aggregator = HealthAggregator();
      aggregator.record(
        1,
        const ColonyHealth(label: 'CORAL', confidence: 0.2),
      );
      aggregator.record(
        1,
        const ColonyHealth(label: 'CORAL_BL', confidence: 0.9),
      );

      // weighted bleached score = (0.2*0 + 0.9*1) / (0.2+0.9) = 0.818 -> BL
      expect(aggregator.currentLabel(1), 'CORAL_BL');
    });

    test('flips back to healthy once enough healthy reads accumulate', () {
      final aggregator = HealthAggregator();
      aggregator.record(
        1,
        const ColonyHealth(label: 'CORAL_BL', confidence: 0.55),
      );
      expect(aggregator.currentLabel(1), 'CORAL_BL');

      for (var i = 0; i < 5; i++) {
        aggregator.record(
          1,
          const ColonyHealth(label: 'CORAL', confidence: 0.9),
        );
      }

      expect(aggregator.currentLabel(1), 'CORAL');
    });

    test('tracks are aggregated independently by track id', () {
      final aggregator = HealthAggregator();
      aggregator.record(
        1,
        const ColonyHealth(label: 'CORAL_BL', confidence: 0.9),
      );
      aggregator.record(
        2,
        const ColonyHealth(label: 'CORAL', confidence: 0.9),
      );

      expect(aggregator.currentLabel(1), 'CORAL_BL');
      expect(aggregator.currentLabel(2), 'CORAL');
    });

    test('exposes the underlying weighted bleached score in [0, 1]', () {
      final aggregator = HealthAggregator();
      aggregator.record(
        1,
        const ColonyHealth(label: 'CORAL_BL', confidence: 0.8),
      );

      expect(aggregator.bleachedScore(1), closeTo(1.0, 1e-9));
    });

    test('a null health record (failed classification) is a no-op', () {
      final aggregator = HealthAggregator();
      aggregator.record(1, null);

      expect(aggregator.currentLabel(1), isNull);
    });
  });
}
