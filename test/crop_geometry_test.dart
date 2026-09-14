import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/services/crop_geometry.dart';

void main() {
  group('computeCropRegion', () {
    test('keeps a box fully inside the frame as-is', () {
      final region = computeCropRegion(
        const Rect.fromLTWH(100, 50, 200, 150),
        frameWidth: 1280,
        frameHeight: 720,
      );

      expect(region.left, 100);
      expect(region.top, 50);
      expect(region.width, 200);
      expect(region.height, 150);
    });

    test('clamps a box that overshoots the right/bottom edge', () {
      final region = computeCropRegion(
        const Rect.fromLTWH(1200, 700, 200, 150),
        frameWidth: 1280,
        frameHeight: 720,
      );

      expect(region.left + region.width, lessThanOrEqualTo(1280));
      expect(region.top + region.height, lessThanOrEqualTo(720));
    });

    test('clamps a box with a negative origin from an imprecise detection', () {
      final region = computeCropRegion(
        const Rect.fromLTWH(-20, -10, 100, 80),
        frameWidth: 640,
        frameHeight: 480,
      );

      expect(region.left, 0);
      expect(region.top, 0);
    });

    test('never returns a zero-size region for a degenerate box at the corner', () {
      final region = computeCropRegion(
        const Rect.fromLTWH(639, 479, 0, 0),
        frameWidth: 640,
        frameHeight: 480,
      );

      expect(region.width, greaterThan(0));
      expect(region.height, greaterThan(0));
    });

    test('never returns a region larger than the frame', () {
      final region = computeCropRegion(
        const Rect.fromLTWH(-100, -100, 2000, 2000),
        frameWidth: 640,
        frameHeight: 480,
      );

      expect(region.left, 0);
      expect(region.top, 0);
      expect(region.width, 640);
      expect(region.height, 480);
    });

    test('falls back to a minimal region for a non-positive frame size', () {
      final region = computeCropRegion(
        const Rect.fromLTWH(0, 0, 10, 10),
        frameWidth: 0,
        frameHeight: 0,
      );

      expect(region.width, greaterThan(0));
      expect(region.height, greaterThan(0));
    });
  });
}
