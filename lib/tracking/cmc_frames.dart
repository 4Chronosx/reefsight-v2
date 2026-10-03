import 'dart:typed_data';

import 'package:opencv_dart/opencv_dart.dart' as cv;

import 'camera_motion_compensation.dart';
import 'linalg.dart' as linalg;

/// A grayscale frame decoded at reduced resolution, plus the factor from its
/// pixels back to the full frame the detections' boxes are in.
class ScaledGrayscaleFrame extends GrayscaleFrame {
  const ScaledGrayscaleFrame({
    required super.width,
    required super.height,
    required super.pixels,
    required this.scale,
  });

  /// Full-frame width / this frame's width.
  final double scale;
}

/// The JPEG decode reduction (1, 2, 4 or 8 -- the factors libjpeg can apply
/// while decoding, far cheaper than a full decode plus resize) whose output
/// width is closest to [targetWidth]. Sub-plan 08 measured CMC offline at
/// an effective 640 px width (1280x720 frames, `downscale: 2`), so 640 is
/// the default.
int reductionFor(int fullWidth, {int targetWidth = 640}) {
  var best = 1;
  for (final r in const [2, 4, 8]) {
    if ((fullWidth / r - targetWidth).abs() < (fullWidth / best - targetWidth).abs()) best = r;
  }
  return best;
}

/// Decodes the live stream's encoded `originalImage` straight to a reduced
/// grayscale [ScaledGrayscaleFrame] for camera motion compensation (sub-plan
/// 08 step 2). Returns `null` if the bytes don't decode.
ScaledGrayscaleFrame? decodeCmcFrame(
  Uint8List encoded, {
  required int fullWidth,
  int targetWidth = 640,
}) {
  final flags = switch (reductionFor(fullWidth, targetWidth: targetWidth)) {
    1 => cv.IMREAD_GRAYSCALE,
    2 => cv.IMREAD_REDUCED_GRAYSCALE_2,
    4 => cv.IMREAD_REDUCED_GRAYSCALE_4,
    _ => cv.IMREAD_REDUCED_GRAYSCALE_8,
  };
  final mat = cv.imdecode(encoded, flags);
  try {
    if (mat.isEmpty || mat.cols == 0) return null;
    return ScaledGrayscaleFrame(
      width: mat.cols,
      height: mat.rows,
      pixels: Uint8List.fromList(mat.data),
      scale: fullWidth / mat.cols,
    );
  } finally {
    mat.dispose();
  }
}

/// [CameraMotionCompensator] for [ScaledGrayscaleFrame]s: estimates the warp
/// at the decoded resolution (no further downscale) and scales its
/// translation back to full-frame pixels, where the tracks' boxes live. The
/// rotation/scale part of a similarity transform is resolution-independent;
/// only the translation scales (x' = a*x + b*y + t at reduced size is
/// X' = a*X + b*Y + s*t at full size, for X = s*x).
///
/// A plain [GrayscaleFrame] is treated as full resolution (scale 1).
class ScaledFrameCompensator extends CameraMotionCompensator {
  ScaledFrameCompensator() : super(downscale: 1);

  @override
  linalg.Matrix apply(GrayscaleFrame frame) {
    final warp = super.apply(frame);
    final s = frame is ScaledGrayscaleFrame ? frame.scale : 1.0;
    return [
      [warp[0][0], warp[0][1], warp[0][2] * s],
      [warp[1][0], warp[1][1], warp[1][2] * s],
    ];
  }
}
