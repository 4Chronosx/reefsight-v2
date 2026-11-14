import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/services/lens_calibration.dart';
import 'package:reefsight_mobile/services/scale_estimation.dart';

// Issue #14: distance and cm per pixel from a calibrated lens (alignment doc
// §6, "How the virtual frame measures"). Every test builds the image from a
// known scene through the same camera model, so the estimate must recover
// the scene exactly.

LensIntrinsics _lens({double f = 3000, List<double> dist = const [0, 0, 0, 0, 0]}) => LensIntrinsics(
      lens: CameraLens.main,
      medium: CalibrationMedium.water,
      imageWidth: 3024,
      imageHeight: 4032,
      fx: f,
      fy: f,
      cx: 1512,
      cy: 2016,
      distortion: dist,
    );

/// A world point (camera coordinates, metres) as the camera would image it.
PlanePoint _image(LensIntrinsics lens, double x, double y, double z) => lens.projectNormalized(x / z, y / z);

void main() {
  group('distanceFromDotPair', () {
    test('two dots 10 cm apart at 1.2 m, no distortion', () {
      final lens = _lens();
      final est = distanceFromDotPair(
        lens: lens,
        dotA: _image(lens, -0.05, 0, 1.2),
        dotB: _image(lens, 0.05, 0, 1.2),
        baselineM: 0.10,
      )!;
      expect(est.distanceM, closeTo(1.2, 1e-9));
      expect(est.dotGapPx, closeTo(250, 1e-9));
      // At the image centre, 1.2 m away: 120 cm over 3000 px.
      expect(est.cmPerPx, closeTo(0.04, 1e-9));
    });

    test('recovers the distance through strong distortion, dots off-centre', () {
      final lens = _lens(f: 1700, dist: const [-0.28, 0.09, 0.0008, -0.0005, -0.012]);
      for (final z in [0.8, 1.0, 1.2, 1.4, 1.6]) {
        final est = distanceFromDotPair(
          lens: lens,
          dotA: _image(lens, 0.30, -0.20, z),
          dotB: _image(lens, 0.30, -0.10, z),
          baselineM: 0.10,
        )!;
        expect(est.distanceM, closeTo(z, 1e-6), reason: 'z = $z');
      }
    });

    test('dots on top of each other give no estimate', () {
      expect(
        distanceFromDotPair(lens: _lens(), dotA: (x: 1500, y: 2000), dotB: (x: 1501, y: 2000), baselineM: 0.1),
        isNull,
      );
    });

    test('a dot outside the calibrated range gives no estimate', () {
      // Barrel distortion this strong folds the polynomial back inside the image corner.
      final lens = _lens(f: 1000, dist: const [-0.9, 0, 0, 0, 0]);
      expect(
        distanceFromDotPair(lens: lens, dotA: (x: 1512, y: 2016), dotB: (x: 3024, y: 4032), baselineM: 0.1),
        isNull,
      );
    });

    test('a non-positive baseline is refused', () {
      expect(
        () => distanceFromDotPair(lens: _lens(), dotA: (x: 0, y: 0), dotB: (x: 100, y: 0), baselineM: 0),
        throwsArgumentError,
      );
    });
  });

  group('footprintAt', () {
    test('without distortion: distance × image size / focal length', () {
      final fp = footprintAt(_lens(), 1.2);
      expect(fp.widthM, closeTo(1.2 * 3024 / 3000, 1e-9));
      expect(fp.heightM, closeTo(1.2 * 4032 / 3000, 1e-9));
    });

    test('barrel distortion widens the footprint beyond the pinhole estimate', () {
      final fp = footprintAt(_lens(f: 1700, dist: const [-0.2, 0.05, 0, 0, 0]), 1.2);
      expect(fp.widthM, greaterThan(1.2 * 3024 / 1700));
    });
  });

  group('squareCornersAt', () {
    test('a 1 m square at 1.2 m, centred, in image order', () {
      final sq = squareCornersAt(_lens(), 1.2);
      // Half-side 0.5 m at 1.2 m = 1250 px.
      expect(sq.fits, isTrue);
      final [tl, tr, br, bl] = sq.corners;
      expect(tl.x, closeTo((1512 - 1250) / 3024, 1e-9));
      expect(tl.y, closeTo((2016 - 1250) / 4032, 1e-9));
      expect(tr.x, closeTo((1512 + 1250) / 3024, 1e-9));
      expect(br.y, closeTo((2016 + 1250) / 4032, 1e-9));
      expect(bl.x, closeTo(tl.x, 1e-12));
    });

    test('too close for the lens: the square does not fit', () {
      // Half-side 0.5 m at 0.8 m = 1875 px, wider than half the 3024 px frame.
      expect(squareCornersAt(_lens(), 0.8).fits, isFalse);
    });

    test('a smaller square fits where 1 m does not', () {
      expect(squareCornersAt(_lens(), 0.8, sideM: 0.5).fits, isTrue);
    });
  });

  group('distance tolerance (D1)', () {
    test('±10 cm counts as within, beyond does not', () {
      expect(withinDistanceTolerance(1.29, 1.2), isTrue);
      expect(withinDistanceTolerance(1.10, 1.2), isTrue);
      expect(withinDistanceTolerance(1.31, 1.2), isFalse);
    });

    test('summary passes only when every shot in the 1.0-1.4 m range is within', () {
      final ok = summarizeDistanceAccuracy([(1.05, 1.0), (1.18, 1.2), (1.45, 1.4), (2.0, 1.6)]);
      expect(ok.shots, 4);
      expect(ok.shotsInRange, 3);
      expect(ok.withinInRange, 3);
      expect(ok.passes, isTrue); // 1.6 m is outside the checked range
      expect(ok.maxAbsErrorInRangeM, closeTo(0.05, 1e-9));

      final bad = summarizeDistanceAccuracy([(1.05, 1.0), (1.35, 1.2)]);
      expect(bad.passes, isFalse);
      expect(bad.meanErrorInRangeM, closeTo(0.1, 1e-9));
    });

    test('no shots in range never passes', () {
      expect(summarizeDistanceAccuracy([(0.7, 0.8)]).passes, isFalse);
      expect(summarizeDistanceAccuracy(const []).passes, isFalse);
    });
  });
}
