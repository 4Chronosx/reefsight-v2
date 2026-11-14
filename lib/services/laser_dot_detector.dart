import 'dart:math' as math;
import 'dart:typed_data';

import 'package:opencv_dart/opencv_dart.dart' as cv;

import 'lens_calibration.dart' show PlanePoint;

/// Issue #14: the two laser dots in a still (alignment doc §6, "Paired
/// lasers (preferred)": two parallel green lasers on the housing, a fixed
/// distance apart; green carries furthest underwater). Their pixel gap,
/// through the calibrated lens, gives the distance (`scale_estimation.dart`).
///
/// A camera records a laser dot as a **blown-out, near-white core inside a
/// saturated green halo**. So the mask takes green pixels that are either
/// saturated (the halo) or very bright **and next to a halo** (the core,
/// whose low saturation makes its hue unreliable), then closes small holes.
/// Pale bleached coral is bright and unsaturated too, but has no saturated
/// green around it, so it stays out. Thresholds are starting values, to be
/// tuned on the pool photos.
///
/// Decoding is at half resolution (`IMREAD_REDUCED_COLOR_2`): a 12 MP still
/// becomes 1512 × 2016, plenty for dots ~10 px across at 1.2 m, and four
/// times less work. Positions and areas are reported in full-resolution
/// pixels.

/// OpenCV hue (0-180) band counted as laser green.
const kLaserHueMin = 35;
const kLaserHueMax = 85;

/// The halo: saturated and reasonably bright.
const kHaloMinSaturation = 80;
const kHaloMinValue = 120;

/// The core: very bright, any saturation.
const kCoreMinValue = 230;

/// Blob area limits, in full-resolution pixels. Below: JPEG noise and specks.
/// Above: a green object, not a dot.
const kMinDotAreaPx = 20.0;
const kMaxDotAreaPx = 40000.0;

/// Two dots of the same lasers are of similar size; beyond this ratio of
/// areas they aren't a pair.
const kMaxDotAreaRatio = 4.0;

/// A third blob at least this fraction of the smaller dot's area means the
/// pick could be wrong: reported as ambiguous.
const kAmbiguousAreaFraction = 0.5;

/// Dots closer than this (full-resolution pixels) are one smeared spot.
const kMinPairGapPx = 12.0;

class DotBlob {
  const DotBlob({required this.x, required this.y, required this.areaPx});

  /// Centroid, in full-resolution pixels.
  final double x, y;
  final double areaPx;

  PlanePoint get point => (x: x, y: y);

  Map<String, Object?> toJson() => {'x': x, 'y': y, 'area_px': areaPx};
}

class DotPair {
  const DotPair({required this.a, required this.b, required this.ambiguous});

  /// The two dots, left one first.
  final DotBlob a, b;

  /// Another blob nearly as large as the pair was seen: the reading should
  /// be checked by eye, not trusted for auto-capture.
  final bool ambiguous;

  double get gapPx => math.sqrt(math.pow(a.x - b.x, 2) + math.pow(a.y - b.y, 2));
}

/// Picks the laser pair from candidate blobs: the two largest of similar
/// size, far enough apart. `null` when there is no such pair.
DotPair? pickDotPair(List<DotBlob> blobs) {
  final candidates = [
    for (final b in blobs)
      if (b.areaPx >= kMinDotAreaPx && b.areaPx <= kMaxDotAreaPx) b,
  ]..sort((p, q) => q.areaPx.compareTo(p.areaPx));
  if (candidates.length < 2) return null;
  final first = candidates[0], second = candidates[1];
  if (first.areaPx / second.areaPx > kMaxDotAreaRatio) return null;
  final (left, right) = first.x <= second.x ? (first, second) : (second, first);
  final pair = DotPair(a: left, b: right, ambiguous: false);
  if (pair.gapPx < kMinPairGapPx) return null;
  final ambiguous = candidates.length > 2 && candidates[2].areaPx >= kAmbiguousAreaFraction * second.areaPx;
  return DotPair(a: left, b: right, ambiguous: ambiguous);
}

class LaserDetection {
  const LaserDetection({this.blobs = const [], this.pair, this.error, this.imageWidth, this.imageHeight});

  /// Every blob that passed the area limits, largest first.
  final List<DotBlob> blobs;
  final DotPair? pair;

  /// The still's size as decoded (EXIF orientation applied), in full-resolution pixels (±1 for an odd size,
  /// from the half-resolution decode). A distance is only valid when this matches the calibration's size.
  final int? imageWidth, imageHeight;

  /// Why the image couldn't be read, if it couldn't.
  final String? error;
}

/// Finds laser dots in an encoded still (JPEG or PNG). Never throws: an
/// unreadable image comes back with [LaserDetection.error] set.
///
/// Synchronous and CPU-bound; callers on the UI isolate should run it
/// through `Isolate.run`.
LaserDetection detectLaserDots(Uint8List encoded) {
  final toDispose = <cv.Mat>[];
  cv.Mat keep(cv.Mat m) {
    toDispose.add(m);
    return m;
  }

  try {
    final bgr = keep(cv.imdecode(encoded, cv.IMREAD_REDUCED_COLOR_2));
    if (bgr.isEmpty) return const LaserDetection(error: 'not a readable image');
    const scale = 2.0;
    final hsv = keep(cv.cvtColor(bgr, cv.COLOR_BGR2HSV));
    final halo = keep(cv.inRangebyScalar(
      hsv,
      cv.Scalar(kLaserHueMin.toDouble(), kHaloMinSaturation.toDouble(), kHaloMinValue.toDouble()),
      cv.Scalar(kLaserHueMax.toDouble(), 255, 255),
    ));
    final core = keep(cv.inRangebyScalar(
      hsv,
      cv.Scalar(kLaserHueMin.toDouble(), 0, kCoreMinValue.toDouble()),
      cv.Scalar(kLaserHueMax.toDouble(), 255, 255),
    ));
    // A near-white pixel's hue is mostly JPEG noise, so bright pixels count
    // only next to a saturated green halo: a dot's core, never pale coral.
    final reach = keep(cv.getStructuringElement(cv.MORPH_ELLIPSE, (9, 9)));
    final nearHalo = keep(cv.dilate(halo, reach));
    final anchoredCore = keep(cv.bitwiseAND(core, nearHalo));
    final both = keep(cv.bitwiseOR(halo, anchoredCore));
    final kernel = keep(cv.getStructuringElement(cv.MORPH_ELLIPSE, (5, 5)));
    final mask = keep(cv.morphologyEx(both, cv.MORPH_CLOSE, kernel));

    final labels = keep(cv.Mat.empty());
    final stats = keep(cv.Mat.empty());
    final centroids = keep(cv.Mat.empty());
    final n = cv.connectedComponentsWithStats(mask, labels, stats, centroids, 8, cv.MatType.CV_32S, -1);

    final blobs = <DotBlob>[];
    for (var i = 1; i < n; i++) {
      // Label 0 is the background.
      final area = stats.atI32(i, i1: cv.CC_STAT_AREA) * scale * scale;
      if (area < kMinDotAreaPx || area > kMaxDotAreaPx) continue;
      // A reduced pixel i covers full-resolution pixels 2i and 2i + 1.
      blobs.add(DotBlob(
        x: centroids.atF64(i, i1: 0) * scale + 0.5,
        y: centroids.atF64(i, i1: 1) * scale + 0.5,
        areaPx: area,
      ));
    }
    blobs.sort((p, q) => q.areaPx.compareTo(p.areaPx));
    return LaserDetection(
      blobs: blobs,
      pair: pickDotPair(blobs),
      imageWidth: bgr.cols * 2,
      imageHeight: bgr.rows * 2,
    );
  } on Object catch (e) {
    return LaserDetection(error: '$e');
  } finally {
    for (final m in toDispose) {
      m.dispose();
    }
  }
}
