import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

/// An integer-aligned crop region, guaranteed to lie within the frame it was
/// computed against and to have a positive width/height.
class CropRegion {
  const CropRegion({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  final int left;
  final int top;
  final int width;
  final int height;
}

/// Converts a detection's pixel-space bounding box into a [CropRegion]
/// clamped to the frame it was detected in.
///
/// Segmentation boxes can be fractional, and occasionally extend a pixel or
/// two past the frame edge or collapse to zero size for a low-confidence
/// detection. Clamping here keeps every caller (the crop-and-classify
/// pipeline) from having to special-case an out-of-bounds or degenerate
/// image crop.
CropRegion computeCropRegion(
  Rect boxPixels, {
  required int frameWidth,
  required int frameHeight,
}) {
  if (frameWidth <= 0 || frameHeight <= 0) {
    // The native plugin should never report a non-positive frame size, but
    // the clamp() calls below require min <= max, so guard the boundary
    // rather than let a malformed streaming payload crash the crop pipeline.
    return const CropRegion(left: 0, top: 0, width: 1, height: 1);
  }

  final left = boxPixels.left.floor().clamp(0, frameWidth - 1);
  final top = boxPixels.top.floor().clamp(0, frameHeight - 1);
  final right = boxPixels.right.ceil().clamp(left + 1, frameWidth);
  final bottom = boxPixels.bottom.ceil().clamp(top + 1, frameHeight);

  return CropRegion(
    left: left,
    top: top,
    width: right - left,
    height: bottom - top,
  );
}

/// Sub-plan 18 decision 1: the region a colony's context photo is cut from
/// -- the detection box grown by [scale] about its centre, so the photo
/// shows a little of the reef around the colony, clamped like
/// [computeCropRegion].
CropRegion computeContextRegion(
  Rect boxPixels, {
  required int frameWidth,
  required int frameHeight,
  double scale = 1.5,
}) {
  return computeCropRegion(
    Rect.fromCenter(
      center: boxPixels.center,
      width: boxPixels.width * scale,
      height: boxPixels.height * scale,
    ),
    frameWidth: frameWidth,
    frameHeight: frameHeight,
  );
}

/// How the bleaching classifier's input is cut from the frame (sub-plan 10,
/// "Crop spec v1"). [insideMaskSquare] is the live default; the other two
/// are kept behind a debug setting for ML sub-plan 2's comparison.
enum CropStyle {
  /// A square centred on the point deepest inside the colony's mask, side
  /// `min(box w, h)` clamped to `[64, shorter frame edge]`, shifted (not
  /// shrunk) into the frame. Mostly coral, nothing stretched.
  insideMaskSquare,

  /// The detection box itself, later stretched to 224x224 -- the crop the
  /// app used before sub-plan 10.
  boxStretch,

  /// The box padded to a square with the frame's own pixels.
  boxSquarePad,
}

/// [style]'s display name, as Settings -> Diagnostics and the report show it.
String cropStyleLabel(CropStyle style) => switch (style) {
  CropStyle.insideMaskSquare => 'Inside mask',
  CropStyle.boxStretch => 'Box stretch',
  CropStyle.boxSquarePad => 'Box square',
};

/// A classifier crop window in frame pixels (integer-aligned) and the
/// fraction of it that is colony mask. [coverage] is only meaningful for
/// [CropStyle.insideMaskSquare]; the box styles report 1.0 and aren't gated
/// on it.
class ClassifierCrop {
  const ClassifierCrop({required this.window, required this.coverage});

  final Rect window;
  final double coverage;
}

/// The mask cell furthest from the mask's boundary -- the point deepest
/// inside the colony -- or `null` if no cell is at or above [threshold].
///
/// Two-pass 3-4 chamfer distance on the grid itself (masks are small, so
/// this is cheap and needs no OpenCV). Cells outside the grid count as
/// background, so a mask that fills its whole grid peaks in the middle.
/// Ties (e.g. a uniform-thickness strip) go to the tied cell nearest the
/// mask's centroid, so the anchor sits mid-colony rather than at whichever
/// end the scan reached first.
({int row, int col})? deepestMaskCell(
  List<List<double>> mask, {
  double threshold = 0.5,
}) {
  final rows = mask.length;
  final cols = rows == 0 ? 0 : mask.first.length;
  if (rows == 0 || cols == 0) return null;

  const far = 1 << 30;
  final dist = List.generate(
    rows,
    (r) => List.generate(
      cols,
      (c) => c < mask[r].length && mask[r][c] >= threshold ? far : 0,
    ),
  );
  int at(int r, int c) =>
      r < 0 || r >= rows || c < 0 || c >= cols ? 0 : dist[r][c];

  for (var r = 0; r < rows; r++) {
    for (var c = 0; c < cols; c++) {
      if (dist[r][c] == 0) continue;
      var d = dist[r][c];
      d = math.min(d, at(r - 1, c) + 3);
      d = math.min(d, at(r, c - 1) + 3);
      d = math.min(d, at(r - 1, c - 1) + 4);
      d = math.min(d, at(r - 1, c + 1) + 4);
      dist[r][c] = d;
    }
  }
  for (var r = rows - 1; r >= 0; r--) {
    for (var c = cols - 1; c >= 0; c--) {
      if (dist[r][c] == 0) continue;
      var d = dist[r][c];
      d = math.min(d, at(r + 1, c) + 3);
      d = math.min(d, at(r, c + 1) + 3);
      d = math.min(d, at(r + 1, c + 1) + 4);
      d = math.min(d, at(r + 1, c - 1) + 4);
      dist[r][c] = d;
    }
  }

  var best = 0;
  var sumRow = 0.0, sumCol = 0.0, count = 0;
  for (var r = 0; r < rows; r++) {
    for (var c = 0; c < cols; c++) {
      final d = dist[r][c];
      if (d == 0) continue;
      sumRow += r;
      sumCol += c;
      count++;
      if (d > best) best = d;
    }
  }
  if (count == 0) return null;

  final centroidRow = sumRow / count, centroidCol = sumCol / count;
  ({int row, int col})? anchor;
  var anchorDistSq = double.infinity;
  for (var r = 0; r < rows; r++) {
    for (var c = 0; c < cols; c++) {
      if (dist[r][c] != best) continue;
      final dr = r - centroidRow, dc = c - centroidCol;
      final dSq = dr * dr + dc * dc;
      if (dSq < anchorDistSq) {
        anchorDistSq = dSq;
        anchor = (row: r, col: c);
      }
    }
  }
  return anchor;
}

/// The classifier crop for one detection under [style] (sub-plan 10, crop
/// spec v1), or `null` when [CropStyle.insideMaskSquare] has no usable mask.
///
/// [mask] is treated as a box-local grid -- cell (r, c) covers the box's
/// r-th row band and c-th column band -- the same assumption
/// `colony_size.dart`'s `maskAreaPixels` makes. Sub-plan 10 step 0 verifies
/// this on-device; if the grid turns out to be full-frame or model-input
/// space, [_maskCellRect] is the one place to change.
ClassifierCrop? computeClassifierCrop({
  required CropStyle style,
  required Rect box,
  List<List<double>>? mask,
  required int frameWidth,
  required int frameHeight,
  int minSide = 64,
  double threshold = 0.5,
}) {
  if (frameWidth <= 0 || frameHeight <= 0) return null;
  final shortEdge = math.min(frameWidth, frameHeight);

  switch (style) {
    case CropStyle.boxStretch:
      final r = computeCropRegion(
        box,
        frameWidth: frameWidth,
        frameHeight: frameHeight,
      );
      return ClassifierCrop(
        window: Rect.fromLTWH(
          r.left.toDouble(),
          r.top.toDouble(),
          r.width.toDouble(),
          r.height.toDouble(),
        ),
        coverage: 1.0,
      );

    case CropStyle.boxSquarePad:
      final side =
          math.max(box.width, box.height).ceil().clamp(1, shortEdge).toInt();
      return ClassifierCrop(
        window: _squareInFrame(box.center, side, frameWidth, frameHeight),
        coverage: 1.0,
      );

    case CropStyle.insideMaskSquare:
      if (mask == null) return null;
      final anchorCell = deepestMaskCell(mask, threshold: threshold);
      if (anchorCell == null) return null;

      final rows = mask.length, cols = mask.first.length;
      final anchor =
          _maskCellRect(box, rows, cols, anchorCell.row, anchorCell.col).center;
      final side = math
          .min(box.width, box.height)
          .round()
          .clamp(math.min(minSide, shortEdge), shortEdge)
          .toInt();
      final window = _squareInFrame(anchor, side, frameWidth, frameHeight);

      var maskArea = 0.0;
      for (var r = 0; r < rows; r++) {
        for (var c = 0; c < cols && c < mask[r].length; c++) {
          if (mask[r][c] < threshold) continue;
          final overlap = _maskCellRect(box, rows, cols, r, c).intersect(window);
          if (overlap.width > 0 && overlap.height > 0) {
            maskArea += overlap.width * overlap.height;
          }
        }
      }
      return ClassifierCrop(
        window: window,
        coverage: maskArea / (window.width * window.height),
      );
  }
}

/// The frame-pixel rect a mask cell covers, assuming a box-local grid.
Rect _maskCellRect(Rect box, int rows, int cols, int row, int col) {
  final cellW = box.width / cols, cellH = box.height / rows;
  return Rect.fromLTWH(
    box.left + col * cellW,
    box.top + row * cellH,
    cellW,
    cellH,
  );
}

/// Whether frame point ([x], [y]) lies on a foreground cell of [mask], under
/// the same box-local grid assumption as [_maskCellRect] -- sub-plan 10
/// step 0's fix must change both, so the photo overlay (sub-plan 18) and the
/// coverage gate stay in agreement.
bool maskCoversPoint(
  List<List<double>> mask,
  Rect box,
  double x,
  double y, {
  double threshold = 0.5,
}) {
  final rows = mask.length;
  final cols = rows == 0 ? 0 : mask.first.length;
  if (rows == 0 || cols == 0 || box.width <= 0 || box.height <= 0) return false;
  if (x < box.left || x >= box.right || y < box.top || y >= box.bottom) return false;
  final r = ((y - box.top) / box.height * rows).floor().clamp(0, rows - 1);
  final c = ((x - box.left) / box.width * cols).floor().clamp(0, cols - 1);
  return c < mask[r].length && mask[r][c] >= threshold;
}

/// The pixel size of a [width] x [height] region scaled so its longer side
/// is [longSide], aspect kept -- how context photos are sized, shared so a
/// mask overlay is rendered at exactly its photo's size.
({int width, int height}) scaledToLongSide(int width, int height, int longSide) {
  final scale = longSide / math.max(width, height);
  return (
    width: math.max(1, (width * scale).round()),
    height: math.max(1, (height * scale).round()),
  );
}

/// What a colony photo needs to draw its mask over itself: the detection's
/// [mask] and [box] (frame pixels) and the frame regions its context photo
/// and classifier crop were cut from. [cropRegion] is `null` for a
/// context-only (fallback) photo.
class MaskOverlay {
  const MaskOverlay({
    required this.mask,
    required this.box,
    required this.contextRegion,
    this.cropRegion,
  });

  final List<List<double>> mask;
  final Rect box;
  final CropRegion contextRegion;
  final CropRegion? cropRegion;
}

/// A [side]-px square centred on [center], shifted (never shrunk) to lie
/// inside the frame, on integer pixels. [side] must fit the frame.
Rect _squareInFrame(Offset center, int side, int frameWidth, int frameHeight) {
  final left = (center.dx - side / 2).round().clamp(0, frameWidth - side);
  final top = (center.dy - side / 2).round().clamp(0, frameHeight - side);
  return Rect.fromLTWH(
    left.toDouble(),
    top.toDouble(),
    side.toDouble(),
    side.toDouble(),
  );
}
