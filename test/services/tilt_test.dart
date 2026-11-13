import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/services/tilt.dart';

// Issue #4: the level indicator's math (alignment doc §6). Tilt is the angle
// between the back camera's axis (the phone's -z) and straight down, from
// the accelerometer's gravity vector.

const _g = 9.81;

void main() {
  group('tiltFromVerticalDeg', () {
    test('lying flat (camera straight down) is 0°', () {
      expect(tiltFromVerticalDeg(0, 0, -_g), closeTo(0, 1e-9));
    });

    test('face down and face up read the same', () {
      expect(tiltFromVerticalDeg(0, 0, _g), closeTo(0, 1e-9));
    });

    test('standing on an edge is 90°', () {
      expect(tiltFromVerticalDeg(0, -_g, 0), closeTo(90, 1e-9));
      expect(tiltFromVerticalDeg(_g, 0, 0), closeTo(90, 1e-9));
    });

    test('a 30° tilt about either axis reads 30°', () {
      final r = 30 * math.pi / 180;
      expect(tiltFromVerticalDeg(0, _g * math.sin(r), -_g * math.cos(r)), closeTo(30, 1e-9));
      expect(tiltFromVerticalDeg(_g * math.sin(r), 0, -_g * math.cos(r)), closeTo(30, 1e-9));
    });

    test('scale does not matter (m/s² or g)', () {
      final r = 12 * math.pi / 180;
      expect(tiltFromVerticalDeg(0, math.sin(r), -math.cos(r)), closeTo(12, 1e-9));
    });

    test('no gravity reading (free fall, a zero sample) is null', () {
      expect(tiltFromVerticalDeg(0, 0, 0), isNull);
    });
  });

  group('TiltFilter', () {
    test('has no reading before the first sample', () {
      expect(TiltFilter().tiltDeg, isNull);
    });

    test('the first sample is taken as is', () {
      final f = TiltFilter()..add(0, 0, -_g);
      expect(f.tiltDeg, closeTo(0, 1e-9));
    });

    test('smooths a single jolt, then converges to a held angle', () {
      final r = 20 * math.pi / 180;
      final f = TiltFilter(alpha: 0.2)..add(0, 0, -_g);
      f.add(0, _g * math.sin(r), -_g * math.cos(r));
      expect(f.tiltDeg!, lessThan(10), reason: 'one sample only moves it part of the way');
      for (var i = 0; i < 60; i++) {
        f.add(0, _g * math.sin(r), -_g * math.cos(r));
      }
      expect(f.tiltDeg, closeTo(20, 0.1));
    });

    test('ignores a zero sample rather than resetting', () {
      final f = TiltFilter()..add(0, 0, -_g);
      f.add(0, 0, 0);
      expect(f.tiltDeg, closeTo(0, 1e-9));
    });

    test('alpha outside (0, 1] is rejected', () {
      expect(() => TiltFilter(alpha: 0), throwsArgumentError);
      expect(() => TiltFilter(alpha: 1.5), throwsArgumentError);
    });
  });

  group('TiltLevel', () {
    test('within ±5° is level, to 10° is near, beyond is off', () {
      expect(tiltLevelOf(0), TiltLevel.level);
      expect(tiltLevelOf(kLevelToleranceDeg), TiltLevel.level);
      expect(tiltLevelOf(7.5), TiltLevel.near);
      expect(tiltLevelOf(kNearToleranceDeg), TiltLevel.near);
      expect(tiltLevelOf(10.01), TiltLevel.off);
      expect(tiltLevelOf(null), TiltLevel.unknown);
    });
  });
}
