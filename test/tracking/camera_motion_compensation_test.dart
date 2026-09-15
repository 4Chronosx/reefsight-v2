import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/tracking/camera_motion_compensation.dart';

/// A checkerboard: strong, evenly-distributed corners for
/// `goodFeaturesToTrack` to lock onto — a flat/blank image has none.
List<int> _checkerboard(int width, int height, {int cell = 10}) {
  return [
    for (var y = 0; y < height; y++)
      for (var x = 0; x < width; x++)
        ((x ~/ cell) + (y ~/ cell)).isEven ? 40 : 220,
  ];
}

/// A `w`x`h` crop of `big` (row-major, `bigWidth`x`bigHeight`) starting at
/// `(x0, y0)` — simulates a camera pan by sampling two overlapping windows
/// of the same underlying scene.
List<int> _cropFrom(
  List<int> big,
  int bigWidth,
  int x0,
  int y0,
  int w,
  int h,
) {
  return [
    for (var y = 0; y < h; y++)
      for (var x = 0; x < w; x++) big[(y0 + y) * bigWidth + (x0 + x)],
  ];
}

void main() {
  group('CameraMotionCompensator', () {
    test('returns identity on the first call (nothing to compare against)',
        () {
      final frame = GrayscaleFrame(
        width: 60,
        height: 60,
        pixels: _checkerboard(60, 60),
      );
      final gmc = CameraMotionCompensator(downscale: 1);

      final warp = gmc.apply(frame);
      gmc.dispose();

      expect(warp, identityWarp());
    });

    test('falls back to identity when a frame has no trackable features',
        () {
      final blank = GrayscaleFrame(
        width: 40,
        height: 40,
        pixels: List.filled(40 * 40, 128),
      );
      final gmc = CameraMotionCompensator(downscale: 1);

      gmc.apply(blank);
      final warp = gmc.apply(blank);
      gmc.dispose();

      expect(warp, identityWarp());
    });

    test('returns a near-identity warp for an unchanged (static) scene', () {
      final frame = GrayscaleFrame(
        width: 80,
        height: 80,
        pixels: _checkerboard(80, 80),
      );
      final gmc = CameraMotionCompensator(downscale: 1);

      gmc.apply(frame);
      final warp = gmc.apply(frame);
      gmc.dispose();

      expect(warp[0][0], closeTo(1.0, 0.05));
      expect(warp[1][1], closeTo(1.0, 0.05));
      expect(warp[0][2], closeTo(0.0, 1.0));
      expect(warp[1][2], closeTo(0.0, 1.0));
    });

    test('estimates an approximately correct translation for a panned scene',
        () {
      const bigSize = 160;
      const cropSize = 80;
      const dx = 6, dy = 4;
      final big = _checkerboard(bigSize, bigSize);

      final frame1 = GrayscaleFrame(
        width: cropSize,
        height: cropSize,
        pixels: _cropFrom(big, bigSize, 40, 40, cropSize, cropSize),
      );
      final frame2 = GrayscaleFrame(
        width: cropSize,
        height: cropSize,
        pixels: _cropFrom(big, bigSize, 40 + dx, 40 + dy, cropSize, cropSize),
      );

      final gmc = CameraMotionCompensator(downscale: 1);
      gmc.apply(frame1);
      final warp = gmc.apply(frame2);
      gmc.dispose();

      // Content in frame2 is frame1's content sampled dx/dy further into the
      // scene, so a feature at (px,py) in frame1 appears at
      // (px-dx, py-dy) in frame2 — the fitted translation should be
      // approximately (-dx, -dy).
      expect(warp[0][2], closeTo(-dx, 2.5));
      expect(warp[1][2], closeTo(-dy, 2.5));
    });

    test('dispose is safe to call before any frame was processed', () {
      final gmc = CameraMotionCompensator();
      expect(gmc.dispose, returnsNormally);
    });
  });
}
