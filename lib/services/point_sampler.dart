import 'transect_frame.dart';

/// Issue #6: CPCe-style scoring points -- [samplePoints] places them at
/// random inside a frame's 1 × 1 m area (TB 2017-05: 10 per frame), from the
/// transect's `point_seed` and the frame's [frameKey], so the same points
/// can be regenerated later to check a stored set. [frameToImage] takes a
/// point from the area to the photo, through the four corners the diver set
/// (#5), for whatever reads the class under it (#7 laptop, #12 phone).
///
/// Points are in the area's own coordinates (0-1 along the top edge, 0-1
/// down the left edge), not the photo's: a frame shot at a slight angle
/// still gets points spread evenly over the real square metre, as CPCe
/// spreads them over the defined area. The reasoning, and how the laptop
/// notebook reproduces these numbers, is in
/// `docs/cpce-point-sampling-and-cover.md`.

const _mask32 = 0xFFFFFFFF;

/// 32-bit multiply, keeping the low 32 bits (JavaScript's `Math.imul`, as
/// unsigned). Dart's 64-bit ints wrap on overflow, which keeps those bits.
int _imul(int a, int b) => (a * b) & _mask32;

/// Mulberry32, a small public-domain 32-bit generator. Used instead of
/// `dart:math`'s `Random(seed)`, whose sequence isn't promised to stay the
/// same across SDK versions: a transect's points must be the same on any
/// app version, and on the laptop (#7).
class Mulberry32 {
  Mulberry32(int seed) : _state = seed & _mask32;

  int _state;

  int nextUint32() {
    _state = (_state + 0x6D2B79F5) & _mask32;
    var t = _imul(_state ^ (_state >> 15), 1 | _state);
    t = ((t + _imul(t ^ (t >> 7), 61 | t)) & _mask32) ^ t;
    return (t ^ (t >> 14)) & _mask32;
  }

  /// In [0, 1).
  double nextDouble() => nextUint32() / 4294967296.0;
}

/// MurmurHash3's 32-bit finalizer: spreads nearby inputs (meter 1, meter 2)
/// to unrelated seeds.
int _fmix32(int h) {
  h &= _mask32;
  h ^= h >> 16;
  h = _imul(h, 0x85EBCA6B);
  h ^= h >> 13;
  h = _imul(h, 0xC2B2AE35);
  h ^= h >> 16;
  return h;
}

/// One frame's seed, from the transect's [pointSeed] and the frame's [key].
int frameSeed(int pointSeed, int key) => _fmix32((pointSeed & _mask32) ^ _imul(key & _mask32, 0x9E3779B1));

/// What identifies a frame within its transect for seeding: a still's meter
/// mark in millimetres, or a video frame's time in ms. Not the row id, which
/// a rebuilt or re-imported database doesn't keep.
int frameKey({required double? meterMark, required int? videoTimeMs}) {
  if (meterMark != null) return (meterMark * 1000).round();
  if (videoTimeMs != null) return videoTimeMs;
  throw ArgumentError('A frame needs a meter mark or a video time to be sampled');
}

/// [count] uniform random points in the frame's area, x then y for each.
List<NormPoint> samplePoints(int pointSeed, int key, int count) {
  if (count <= 0) throw ArgumentError.value(count, 'count', 'Must be > 0');
  final rng = Mulberry32(frameSeed(pointSeed, key));
  return [
    for (var i = 0; i < count; i++) (x: rng.nextDouble(), y: rng.nextDouble()),
  ];
}

/// Where [uv] (a point in the area, 0-1 each way) falls in the photo, given
/// the area's [corners] in image order (TL, TR, BR, BL) -- the projective
/// map of the unit square onto that quadrilateral (Heckbert 1989), which is
/// what a flat square seen through a lens at an angle is. With the camera
/// square to the frame it reduces to a plain scale and shift.
NormPoint frameToImage(List<NormPoint> corners, NormPoint uv) {
  if (corners.length != 4) {
    throw ArgumentError.value(corners.length, 'corners', 'A frame needs exactly 4 corners');
  }
  // A flat square seen through a lens is a strictly convex quadrilateral.
  // Three corners in a line, or a fold, gives a map with no meaning (or a
  // NaN), so refuse it here rather than score a point nowhere -- the editor
  // checks this (`isValidFrame`), but `updateFrameCorners` doesn't.
  final turns = [
    for (var i = 0; i < 4; i++)
      (corners[(i + 1) % 4].x - corners[i].x) * (corners[(i + 2) % 4].y - corners[(i + 1) % 4].y) -
          (corners[(i + 1) % 4].y - corners[i].y) * (corners[(i + 2) % 4].x - corners[(i + 1) % 4].x),
  ];
  if (!turns.every((t) => t > 1e-12) && !turns.every((t) => t < -1e-12)) {
    throw ArgumentError('Frame corners must form a convex quadrilateral (none in a line, no fold)');
  }
  final [p0, p1, p2, p3] = corners;
  final dx1 = p1.x - p2.x, dx2 = p3.x - p2.x, dx3 = p0.x - p1.x + p2.x - p3.x;
  final dy1 = p1.y - p2.y, dy2 = p3.y - p2.y, dy3 = p0.y - p1.y + p2.y - p3.y;

  double g = 0, h = 0;
  if (dx3.abs() > 1e-12 || dy3.abs() > 1e-12) {
    final den = dx1 * dy2 - dx2 * dy1;
    g = (dx3 * dy2 - dx2 * dy3) / den;
    h = (dx1 * dy3 - dx3 * dy1) / den;
  }
  final a = p1.x - p0.x + g * p1.x, b = p3.x - p0.x + h * p3.x, c = p0.x;
  final d = p1.y - p0.y + g * p1.y, e = p3.y - p0.y + h * p3.y, f = p0.y;

  final w = g * uv.x + h * uv.y + 1;
  return (x: (a * uv.x + b * uv.y + c) / w, y: (d * uv.x + e * uv.y + f) / w);
}
