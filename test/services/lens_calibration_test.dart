import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/services/lens_calibration.dart';

// Issue #14: the underwater lens calibration (alignment doc §6, build order
// step 2). Notebook 31 fits OpenCV's pinhole + Brown-Conrady model to pool
// photos; the app reads the JSON and needs exact round trips between pixels
// and the undistorted normalized plane.

LensIntrinsics _lens({
  double fx = 3000,
  double fy = 3000,
  double cx = 1512,
  double cy = 2016,
  List<double> dist = const [0, 0, 0, 0, 0],
}) =>
    LensIntrinsics(
      lens: CameraLens.main,
      medium: CalibrationMedium.water,
      imageWidth: 3024,
      imageHeight: 4032,
      fx: fx,
      fy: fy,
      cx: cx,
      cy: cy,
      distortion: dist,
    );

Map<String, Object?> _lensJson({String lens = 'main', String medium = 'water'}) => {
      'lens': lens,
      'medium': medium,
      'image_width': 3024,
      'image_height': 4032,
      'fx': 3000.0,
      'fy': 3010.0,
      'cx': 1500.0,
      'cy': 2000.0,
      'distortion': [0.01, -0.02, 0.0, 0.0, 0.001],
      'rms_px': 0.6,
      'n_images': 18,
    };

String _fileJson(List<Map<String, Object?>> lenses, {int version = 1}) => jsonEncode({
      'format': 'reefsight-lens-calibration',
      'version': version,
      'calibration_id': '20261120_101500',
      'created': '2026-11-20T10:15:00',
      'lenses': lenses,
    });

void main() {
  group('LensIntrinsics projection', () {
    test('the principal point maps to the optical axis', () {
      final p = _lens().undistortPixel(1512, 2016);
      expect(p.x, closeTo(0, 1e-12));
      expect(p.y, closeTo(0, 1e-12));
    });

    test('without distortion, pixel = f * normalized + c', () {
      final px = _lens().projectNormalized(0.1, -0.2);
      expect(px.x, closeTo(1512 + 300, 1e-9));
      expect(px.y, closeTo(2016 - 600, 1e-9));
    });

    test('undistort inverts distort for strong ultra-wide barrel distortion', () {
      // Typical iPhone ultra-wide magnitudes (k1 < 0 barrel), plus tangential terms.
      final lens = _lens(fx: 1700, fy: 1700, dist: const [-0.28, 0.09, 0.0008, -0.0005, -0.012]);
      for (final (x, y) in [(0.0, 0.0), (0.3, 0.2), (-0.5, 0.6), (0.7, -0.7), (-0.85, -0.1)]) {
        final px = lens.projectNormalized(x, y);
        final back = lens.undistortPixel(px.x, px.y);
        expect(back.x, closeTo(x, 1e-7), reason: '($x, $y)');
        expect(back.y, closeTo(y, 1e-7), reason: '($x, $y)');
      }
    });
  });

  group('LensCalibration.parse', () {
    test('reads every lens with its fields', () {
      final cal = LensCalibration.parse(_fileJson([_lensJson(), _lensJson(lens: 'ultra_wide')]));
      expect(cal.calibrationId, '20261120_101500');
      expect(cal.lenses, hasLength(2));
      final main = cal.forLens(CameraLens.main, CalibrationMedium.water)!;
      expect(main.fy, 3010.0);
      expect(main.distortion, [0.01, -0.02, 0.0, 0.0, 0.001]);
      expect(main.rmsPx, 0.6);
      expect(main.imagesUsed, 18);
      expect(cal.forLens(CameraLens.ultraWide, CalibrationMedium.water), isNotNull);
      expect(cal.forLens(CameraLens.main, CalibrationMedium.air), isNull);
    });

    test('round-trips through toJson', () {
      final cal = LensCalibration.parse(_fileJson([_lensJson()]));
      final again = LensCalibration.parse(jsonEncode(cal.toJson()));
      expect(again.forLens(CameraLens.main, CalibrationMedium.water)!.cx, 1500.0);
      expect(again.calibrationId, cal.calibrationId);
    });

    test('a four-term distortion vector is padded with k3 = 0', () {
      final cal = LensCalibration.parse(_fileJson([
        {..._lensJson(), 'distortion': [0.1, 0.2, 0.0, 0.0]},
      ]));
      expect(cal.lenses.single.distortion, [0.1, 0.2, 0.0, 0.0, 0.0]);
    });

    final bad = <String, String>{
      'not JSON': '{',
      'not an object': '[]',
      'wrong format tag': jsonEncode({'format': 'x', 'version': 1, 'calibration_id': 'a', 'lenses': []}),
      'newer version': _fileJson([_lensJson()], version: 2),
      'no lenses': _fileJson([]),
      'unknown lens': _fileJson([_lensJson(lens: 'telephoto')]),
      'unknown medium': _fileJson([_lensJson(medium: 'oil')]),
      'duplicate lens and medium': _fileJson([_lensJson(), _lensJson()]),
      'zero focal length': _fileJson([
        {..._lensJson(), 'fx': 0.0},
      ]),
      'a string where a number belongs': _fileJson([
        {..._lensJson(), 'cx': 'NaN'},
      ]),
      'principal point outside the image': _fileJson([
        {..._lensJson(), 'cx': 5000.0},
      ]),
      'landscape image size': _fileJson([
        {..._lensJson(), 'image_width': 4032, 'image_height': 3024},
      ]),
      'six distortion terms': _fileJson([
        {..._lensJson(), 'distortion': [0, 0, 0, 0, 0, 0]},
      ]),
      'missing calibration id': jsonEncode({
        'format': 'reefsight-lens-calibration',
        'version': 1,
        'lenses': [_lensJson()],
      }),
    };
    for (final MapEntry(key: name, value: text) in bad.entries) {
      test('refuses $name', () {
        expect(() => LensCalibration.parse(text), throwsFormatException);
      });
    }
  });

  test('CameraLens db values', () {
    expect(CameraLens.main.db, 'main');
    expect(CameraLens.ultraWide.db, 'ultra_wide');
  });
}
