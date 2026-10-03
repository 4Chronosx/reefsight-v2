import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/services/classification_policy.dart';

// Settings -> Diagnostics' threshold overrides: one value object whose
// defaults are sub-plan 10's policy, so an untouched setting changes
// nothing.

void main() {
  group('ClassificationThresholds', () {
    test('defaults are the ClassificationPolicy values', () {
      const t = ClassificationThresholds.defaults;

      expect(t.segFloor, ClassificationPolicy.classifySegFloor);
      expect(t.minCoverage, ClassificationPolicy.minCoverage);
      expect(t.confFloor, ClassificationPolicy.classifyConfFloor);
      expect(t.minConfidentSamples, ClassificationPolicy.minConfidentSamples);
      expect(t.isDefault, isTrue);
    });

    test('copyWith changes only the given fields', () {
      final t = ClassificationThresholds.defaults.copyWith(confFloor: 0.6);

      expect(t.confFloor, 0.6);
      expect(t.segFloor, ClassificationPolicy.classifySegFloor);
      expect(t.minCoverage, ClassificationPolicy.minCoverage);
      expect(t.minConfidentSamples, ClassificationPolicy.minConfidentSamples);
      expect(t.isDefault, isFalse);
    });

    test('equal by value', () {
      final a = ClassificationThresholds.defaults.copyWith(minConfidentSamples: 1);
      const b = ClassificationThresholds(minConfidentSamples: 1);

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(ClassificationThresholds.defaults));
    });

    test('format lists all four for the debug log', () {
      expect(
        const ClassificationThresholds(
          segFloor: 0.5,
          minCoverage: 0.4,
          confFloor: 0.65,
          minConfidentSamples: 1,
        ).format(),
        'seg 0.5 cov 0.4 conf 0.65 n 1',
      );
    });
  });
}
