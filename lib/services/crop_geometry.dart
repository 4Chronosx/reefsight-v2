import 'dart:ui' show Rect;

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
