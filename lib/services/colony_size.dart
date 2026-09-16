/// Pixel area of a segmentation mask's foreground, scaled to the detection
/// box's real pixel dimensions.
///
/// `YOLOResult.mask` (`ultralytics_yolo`) is only documented as "each inner
/// list represents a row of mask values" -- neither the value range nor
/// whether the grid is exactly box-sized is stated. This scales each mask
/// cell by the ratio of [boxWidthPx]/[boxHeightPx] to the mask grid's own
/// cell count, so it is correct whether the grid matches the box 1:1 or is a
/// coarser/finer resolution.
///
/// Pixel-only, matching sub-plan 3's scope -- real-world scaling via the
/// physical transect tape is sub-plan 4's job (Track 3 §8-10).
///
/// [threshold] follows the sub-plan's note that the value convention (binary
/// vs. probability) should be confirmed on-device; 0.5 works for both.
double maskAreaPixels(
  List<List<double>> mask, {
  required double boxWidthPx,
  required double boxHeightPx,
  double threshold = 0.5,
}) {
  final rows = mask.length;
  final cols = rows == 0 ? 0 : mask.first.length;
  if (rows == 0 || cols == 0) return 0;

  var foregroundCells = 0;
  for (final row in mask) {
    for (final value in row) {
      if (value >= threshold) foregroundCells++;
    }
  }

  final cellWidthPx = boxWidthPx / cols;
  final cellHeightPx = boxHeightPx / rows;
  return foregroundCells * cellWidthPx * cellHeightPx;
}
