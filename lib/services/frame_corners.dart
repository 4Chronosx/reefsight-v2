import 'dart:math';

import 'transect_frame.dart' show NormPoint;

/// Issue #5: geometry of a frame's 1 × 1 m area -- the four corners the
/// diver drags onto the physical frame (CPCe-style), normalized to 0-1 of
/// the photo as displayed. Points are placed only inside it (#6).

/// Where the editor starts on a photo with no corners yet: a centered
/// square inset 15 %, roughly where a frame sits in a 1.2 m shot.
List<NormPoint> defaultCorners() => const [
      (x: 0.15, y: 0.15),
      (x: 0.85, y: 0.15),
      (x: 0.85, y: 0.85),
      (x: 0.15, y: 0.85),
    ];

/// The corners in image order -- top-left, top-right, bottom-right,
/// bottom-left -- whatever order they were dragged into: sorted by angle
/// round the centroid (clockwise on screen, where y points down), starting
/// at the one nearest the top-left.
List<NormPoint> orderCorners(List<NormPoint> corners) {
  final cx = corners.map((c) => c.x).reduce((a, b) => a + b) / corners.length;
  final cy = corners.map((c) => c.y).reduce((a, b) => a + b) / corners.length;
  final sorted = [...corners]..sort((a, b) => atan2(a.y - cy, a.x - cx).compareTo(atan2(b.y - cy, b.x - cx)));
  var start = 0;
  for (var i = 1; i < sorted.length; i++) {
    if (sorted[i].x + sorted[i].y < sorted[start].x + sorted[start].y) start = i;
  }
  return [...sorted.sublist(start), ...sorted.sublist(0, start)];
}

/// Shoelace area, in normalized units (1 = the whole photo).
double quadArea(List<NormPoint> c) {
  var twice = 0.0;
  for (var i = 0; i < c.length; i++) {
    final a = c[i], b = c[(i + 1) % c.length];
    twice += a.x * b.y - b.x * a.y;
  }
  return twice.abs() / 2;
}

/// Smallest area accepted: 1 % of the photo. A real 1 × 1 m frame shot
/// from 1.2 m fills most of it; anything this small is a slip.
const kMinFrameArea = 0.01;

/// Four corners, in the given order, forming a convex quadrilateral of at
/// least [kMinFrameArea] -- what a flat square frame looks like from any
/// angle. A crossed or dented shape means two corners were swapped or
/// misplaced.
bool isValidFrame(List<NormPoint> c) {
  if (c.length != 4) return false;
  int? sign;
  for (var i = 0; i < 4; i++) {
    final a = c[i], b = c[(i + 1) % 4], d = c[(i + 2) % 4];
    final cross = (b.x - a.x) * (d.y - b.y) - (b.y - a.y) * (d.x - b.x);
    if (cross.abs() < 1e-9) return false;
    final s = cross.sign.toInt();
    if (sign != null && s != sign) return false;
    sign = s;
  }
  return quadArea(c) >= kMinFrameArea;
}

NormPoint clampNorm(NormPoint p) => (x: p.x.clamp(0.0, 1.0).toDouble(), y: p.y.clamp(0.0, 1.0).toDouble());
