import 'dart:math' as math;

import 'lens_calibration.dart';
import 'transect_frame.dart' show NormPoint;

/// Issue #14: camera-to-bottom distance and cm per pixel from a calibrated
/// lens (alignment doc §6, "How the virtual frame measures"). Pure geometry,
/// independent of how the scale reached the image -- two laser dots today;
/// the same [footprintAt] and [squareCornersAt] serve the virtual square
/// (#15) whatever the distance method.
///
/// The model: a pinhole camera behind OpenCV's distortion polynomial,
/// fitted **underwater** through the housing (notebook 31), so the flat
/// window's refraction is folded into the calibration rather than modelled
/// separately. The camera points straight down at a flat bottom; tilt (≤5°
/// in Virtual mode) changes these numbers by under 0.5 % and is ignored here.
/// Reasoning: `../docs/underwater-lens-calibration-and-distance.md`.

/// Decision D1 (2026-11-15): an estimate is good enough when within this of
/// the tape-measured distance...
const kDistanceToleranceM = 0.10;

/// ...over the distances the Virtual frame accepts (§6: the distance check
/// is loose, 1.0-1.4 m). Outside this range accuracy is reported, not judged.
const kDistanceCheckMinM = 1.0;
const kDistanceCheckMaxM = 1.4;

/// Dots closer than this, in pixels, are one blob or noise, not a pair.
const kMinDotGapPx = 8.0;

/// A distance read from two parallel laser dots.
class DotPairEstimate {
  const DotPairEstimate({required this.distanceM, required this.cmPerPx, required this.dotGapPx});

  /// Camera to the plane the dots landed on, along the optical axis.
  final double distanceM;

  /// Centimetres covered by one pixel at the image centre, at [distanceM].
  final double cmPerPx;

  /// The dots' separation in the raw (distorted) image.
  final double dotGapPx;
}

/// The distance to two laser dots from lasers mounted parallel to the
/// camera axis, [baselineM] apart. Parallel beams keep their spacing at any
/// distance, so the undistorted normalized gap is `baseline / distance`:
/// `distance = baseline / gap` (Z = f·B/d in pixels). Where on the housing
/// the lasers sit doesn't matter, only that they are parallel to the camera
/// and to each other.
///
/// `null` when the dots are too close to tell apart ([kMinDotGapPx]) or one
/// lies outside the calibrated range of the lens.
DotPairEstimate? distanceFromDotPair({
  required LensIntrinsics lens,
  required PlanePoint dotA,
  required PlanePoint dotB,
  required double baselineM,
}) {
  if (!(baselineM > 0)) throw ArgumentError.value(baselineM, 'baselineM', 'must be positive');
  final gapPx = _distance(dotA, dotB);
  if (gapPx < kMinDotGapPx) return null;
  final PlanePoint a, b;
  try {
    a = lens.undistortPixel(dotA.x, dotA.y);
    b = lens.undistortPixel(dotB.x, dotB.y);
  } on RangeError {
    return null;
  }
  final gap = _distance(a, b);
  if (!(gap > 0)) return null;
  final distanceM = baselineM / gap;
  return DotPairEstimate(distanceM: distanceM, cmPerPx: cmPerPxAt(lens, distanceM), dotGapPx: gapPx);
}

/// Centimetres per pixel at the image centre, [distanceM] from the camera.
/// Toward the edges distortion changes it; use [footprintAt] or undistort
/// points for anything measured there.
double cmPerPxAt(LensIntrinsics lens, double distanceM) => 100 * distanceM / ((lens.fx + lens.fy) / 2);

/// The area of flat bottom the whole photo covers at [distanceM], measured
/// across the middle of the image (edge midpoints, undistorted).
({double widthM, double heightM}) footprintAt(LensIntrinsics lens, double distanceM) {
  final left = lens.undistortPixel(0, lens.cy);
  final right = lens.undistortPixel(lens.imageWidth.toDouble(), lens.cy);
  final top = lens.undistortPixel(lens.cx, 0);
  final bottom = lens.undistortPixel(lens.cx, lens.imageHeight.toDouble());
  return (widthM: distanceM * (right.x - left.x), heightM: distanceM * (bottom.y - top.y));
}

/// Where a square of [sideM] on the bottom, centred under the camera at
/// [distanceM], appears in the photo: its corners in image order (TL, TR,
/// BR, BL), normalized to 0-1 like every other frame's corners
/// (`transect_frames.corners_json`). [fits] is false when any corner falls
/// outside the photo -- the lens is too narrow at that distance.
///
/// Only the corners go through the distortion; on the ultra-wide the sides
/// bow between them, so #15 should draw the edges with [projectSquareEdge]
/// rather than as straight lines.
({List<NormPoint> corners, bool fits}) squareCornersAt(LensIntrinsics lens, double distanceM, {double sideM = 1.0}) {
  final h = sideM / 2;
  final corners = [
    for (final (x, y) in [(-h, -h), (h, -h), (h, h), (-h, h)])
      _norm(lens, lens.projectNormalized(x / distanceM, y / distanceM)),
  ];
  final fits = corners.every((c) => c.x >= 0 && c.x <= 1 && c.y >= 0 && c.y <= 1);
  return (corners: corners, fits: fits);
}

/// [steps] + 1 points along one side of the square from [squareCornersAt]
/// (side 0 = top, then clockwise), normalized, for drawing the bowed edge.
List<NormPoint> projectSquareEdge(
  LensIntrinsics lens,
  double distanceM, {
  required int side,
  double sideM = 1.0,
  int steps = 16,
}) {
  if (side < 0 || side > 3) throw RangeError.range(side, 0, 3, 'side');
  final h = sideM / 2;
  const ends = [(-1, -1), (1, -1), (1, 1), (-1, 1)];
  final (x0, y0) = ends[side];
  final (x1, y1) = ends[(side + 1) % 4];
  return [
    for (var i = 0; i <= steps; i++)
      _norm(
        lens,
        lens.projectNormalized(
          h * (x0 + (x1 - x0) * i / steps) / distanceM,
          h * (y0 + (y1 - y0) * i / steps) / distanceM,
        ),
      ),
  ];
}

NormPoint _norm(LensIntrinsics lens, PlanePoint px) => (x: px.x / lens.imageWidth, y: px.y / lens.imageHeight);

double _distance(PlanePoint a, PlanePoint b) => math.sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y));

/// Whether an estimate is within [kDistanceToleranceM] of the truth. The
/// tiny epsilon keeps a value exactly on the boundary (1.10 vs 1.20, which
/// floating point makes 0.0999...) from flipping either way.
bool withinDistanceTolerance(double estimatedM, double trueM) =>
    (estimatedM - trueM).abs() <= kDistanceToleranceM + 1e-9;

/// The accuracy table's summary: how estimates compare with tape-measured
/// distances, judged only over [kDistanceCheckMinM]-[kDistanceCheckMaxM].
class DistanceAccuracy {
  const DistanceAccuracy({
    required this.shots,
    required this.shotsInRange,
    required this.withinInRange,
    required this.meanErrorInRangeM,
    required this.maxAbsErrorInRangeM,
    required this.rmseInRangeM,
  });

  final int shots;
  final int shotsInRange;
  final int withinInRange;

  /// Signed mean (estimate − truth): a consistent bias shows here, and a
  /// fixed scale correction can remove it.
  final double? meanErrorInRangeM;
  final double? maxAbsErrorInRangeM;
  final double? rmseInRangeM;

  /// "Done when" for issue #14: at least one shot in range, every one of
  /// them within tolerance.
  bool get passes => shotsInRange > 0 && withinInRange == shotsInRange;
}

/// Summarises `(estimated, true)` distance pairs, in metres.
DistanceAccuracy summarizeDistanceAccuracy(List<(double, double)> pairs) {
  final inRange = [
    for (final (est, truth) in pairs)
      if (truth >= kDistanceCheckMinM - 1e-9 && truth <= kDistanceCheckMaxM + 1e-9) (est, truth),
  ];
  final errors = [for (final (est, truth) in inRange) est - truth];
  return DistanceAccuracy(
    shots: pairs.length,
    shotsInRange: inRange.length,
    withinInRange: inRange.where((p) => withinDistanceTolerance(p.$1, p.$2)).length,
    meanErrorInRangeM: errors.isEmpty ? null : errors.reduce((a, b) => a + b) / errors.length,
    maxAbsErrorInRangeM: errors.isEmpty ? null : errors.map((e) => e.abs()).reduce(math.max),
    rmseInRangeM:
        errors.isEmpty ? null : math.sqrt(errors.map((e) => e * e).reduce((a, b) => a + b) / errors.length),
  );
}
