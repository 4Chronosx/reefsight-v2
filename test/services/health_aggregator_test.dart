import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/services/bleaching_classifier.dart';
import 'package:reefsight_mobile/services/classification_policy.dart';
import 'package:reefsight_mobile/services/health_aggregator.dart';

// Spec (Track 3 §6-7 / ReefSight_Specification.md "Per-colony decisions"):
// confidence-weighted average across a colony's classified samples -- an
// explicitly project-specific choice over majority-vote or
// best-single-frame. The classifier is binary (NMFS-OSI "CORAL" /
// "CORAL_BL" -- research_logs/stage_c/external_noaa_model_eval), so
// bleached-ness is encoded as a 0/1 score and weighted-averaged by
// per-sample confidence.
//
// Sub-plan 10 (classifier input and reject) adds a policy on top: samples
// below `classifyConfFloor` don't count, and a colony has no label
// ("Uncertain") until it has `minConfidentSamples` confident ones.

const _healthy = ColonyHealth(label: 'CORAL', confidence: 0.9);
const _bleached = ColonyHealth(label: 'CORAL_BL', confidence: 0.9);

void main() {
  group('HealthAggregator weighting (permissive policy)', () {
    // Floor 0 and one sample: isolates the weighted-average arithmetic from
    // the sub-plan 10 gating, which has its own group below.
    HealthAggregator permissive() =>
        HealthAggregator(confidenceFloor: 0, minConfidentSamples: 1);

    test('a single healthy classification reports CORAL', () {
      final aggregator = permissive()..record(1, _healthy);
      expect(aggregator.currentLabel(1), 'CORAL');
    });

    test('a single bleached classification reports CORAL_BL', () {
      final aggregator = permissive()..record(1, _bleached);
      expect(aggregator.currentLabel(1), 'CORAL_BL');
    });

    test('an unrecorded track id has no label yet', () {
      expect(permissive().currentLabel(999), isNull);
    });

    test(
        'a high-confidence bleached read outweighs a low-confidence healthy '
        'read', () {
      final aggregator = permissive()
        ..record(1, const ColonyHealth(label: 'CORAL', confidence: 0.2))
        ..record(1, const ColonyHealth(label: 'CORAL_BL', confidence: 0.9));

      // weighted bleached score = (0.2*0 + 0.9*1) / (0.2+0.9) = 0.818 -> BL
      expect(aggregator.currentLabel(1), 'CORAL_BL');
    });

    test('flips back to healthy once enough healthy reads accumulate', () {
      final aggregator = permissive()
        ..record(1, const ColonyHealth(label: 'CORAL_BL', confidence: 0.55));
      expect(aggregator.currentLabel(1), 'CORAL_BL');

      for (var i = 0; i < 5; i++) {
        aggregator.record(1, _healthy);
      }

      expect(aggregator.currentLabel(1), 'CORAL');
    });

    test('tracks are aggregated independently by track id', () {
      final aggregator = permissive()
        ..record(1, _bleached)
        ..record(2, _healthy);

      expect(aggregator.currentLabel(1), 'CORAL_BL');
      expect(aggregator.currentLabel(2), 'CORAL');
    });

    test('exposes the underlying weighted bleached score in [0, 1]', () {
      final aggregator = permissive()
        ..record(1, const ColonyHealth(label: 'CORAL_BL', confidence: 0.8));

      expect(aggregator.bleachedScore(1), closeTo(1.0, 1e-9));
    });

    test('a null health record (failed classification) is a no-op', () {
      final aggregator = permissive()..record(1, null);
      expect(aggregator.currentLabel(1), isNull);
    });
  });

  group('HealthAggregator default policy (sub-plan 10)', () {
    test('defaults come from ClassificationPolicy', () {
      final aggregator = HealthAggregator();
      expect(aggregator.confidenceFloor, ClassificationPolicy.classifyConfFloor);
      expect(
        aggregator.minConfidentSamples,
        ClassificationPolicy.minConfidentSamples,
      );
    });

    test('one confident sample is not enough: the label stays null', () {
      final aggregator = HealthAggregator()..record(1, _bleached);

      expect(aggregator.confidentSamples(1), 1);
      expect(aggregator.currentLabel(1), isNull);
      expect(aggregator.bleachedScore(1), isNull);
    });

    test('two confident samples give a label', () {
      final aggregator = HealthAggregator()
        ..record(1, _bleached)
        ..record(1, _bleached);

      expect(aggregator.currentLabel(1), 'CORAL_BL');
    });

    test('a sample below the confidence floor does not move the label', () {
      final aggregator = HealthAggregator()
        ..record(1, _healthy)
        ..record(1, _healthy)
        // Binary top-1 is always >= 0.5; 0.69 is just under the 0.7 floor.
        ..record(1, const ColonyHealth(label: 'CORAL_BL', confidence: 0.69))
        ..record(1, const ColonyHealth(label: 'CORAL_BL', confidence: 0.69))
        ..record(1, const ColonyHealth(label: 'CORAL_BL', confidence: 0.69));

      expect(aggregator.currentLabel(1), 'CORAL');
      expect(aggregator.bleachedScore(1), 0);
      expect(aggregator.confidentSamples(1), 2);
    });

    test('a sample exactly at the floor counts as confident', () {
      final aggregator = HealthAggregator()
        ..record(1, const ColonyHealth(label: 'CORAL', confidence: 0.7))
        ..record(1, const ColonyHealth(label: 'CORAL', confidence: 0.7));

      expect(aggregator.currentLabel(1), 'CORAL');
    });

    test('isConfident matches the floor', () {
      final aggregator = HealthAggregator();
      expect(
        aggregator.isConfident(
          const ColonyHealth(label: 'CORAL', confidence: 0.7),
        ),
        isTrue,
      );
      expect(
        aggregator.isConfident(
          const ColonyHealth(label: 'CORAL', confidence: 0.6999),
        ),
        isFalse,
      );
    });
  });
}
