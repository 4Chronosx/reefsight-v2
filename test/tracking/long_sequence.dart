// Deterministic long detection sequence for test/tracking/removed_stracks_bound_test.dart (sub-plan
// 08 step 5). Pure Dart (no flutter_test) so a one-off script can also record the golden output.
import 'package:reefsight_mobile/tracking/tracker_detection.dart';

/// Tracker buffer used with this sequence: short, so tracks are removed (and the removed list
/// would grow) many times over.
const longSequenceTrackBuffer = 5;

/// Fixed-constant LCG instead of `dart:math` `Random`, so the sequence -- and the recorded golden
/// output -- can't drift with the Dart SDK's RNG implementation.
class _Lcg {
  _Lcg(this._state);
  int _state;
  double next() {
    _state = (_state * 1103515245 + 12345) & 0x7fffffff;
    return _state / 0x7fffffff;
  }
}

TrackerDetection _box(double x, double y, double w, double h, double score) =>
    TrackerDetection(x1: x, y1: y, x2: x + w, y2: y + h, score: score);

/// Frames 1..1240 of detections:
/// - frames 1-40, hand-built: a colony last seen on frame 2 reappears after exactly
///   `trackBuffer + 1` empty updates (frame 9), so it is re-found while its id is already in the
///   removed list; it is lost again on frame 13 and reappears on frame 14. Whether it keeps its id
///   on frame 14 depends on that stale removed-list entry -- the case a careless bound would break.
/// - frames 41-1240, generated: ~60 colonies with random births, lifetimes, drift, size, score,
///   detection dropouts (including gaps around the buffer length) and false-positive flicker.
List<List<TrackerDetection>> buildLongSequence() {
  final frames = <List<TrackerDetection>>[];
  for (var f = 1; f <= 40; f++) {
    final dets = <TrackerDetection>[];
    final present = f <= 2 || (f >= 9 && f <= 12) || (f >= 14 && f <= 20);
    if (present) dets.add(_box(300.0 + f, 200, 40, 40, 0.9));
    dets.add(_box(800, 500.0 + f * 0.5, 60, 50, 0.85)); // a steady neighbour
    frames.add(dets);
  }

  final rng = _Lcg(20261004);
  final colonies = <Map<String, double>>[];
  for (var i = 0; i < 60; i++) {
    final birth = 41 + (rng.next() * 1100).floorToDouble();
    colonies.add({
      'birth': birth,
      'death': birth + 20 + (rng.next() * 280).floorToDouble(),
      'x': 50 + rng.next() * 1100,
      'y': 50 + rng.next() * 600,
      'vx': (rng.next() - 0.5) * 6,
      'vy': (rng.next() - 0.5) * 4,
      'w': 20 + rng.next() * 60,
      'h': 20 + rng.next() * 60,
      'score': 0.3 + rng.next() * 0.65,
      'gapUntil': 0,
    });
  }
  for (var f = 41; f <= 1240; f++) {
    final drift = 2.0 * (f % 200 < 100 ? 1 : -1); // camera panning back and forth
    final dets = <TrackerDetection>[];
    for (final c in colonies) {
      if (f < c['birth']! || f > c['death']!) continue;
      c['x'] = (c['x']! + c['vx']! + drift).clamp(0, 1180).toDouble();
      c['y'] = (c['y']! + c['vy']!).clamp(0, 640).toDouble();
      if (f <= c['gapUntil']!) continue;
      final r = rng.next();
      if (r < 0.02) {
        // a dropout lasting 1..(trackBuffer + 3) frames -- straddles the removal horizon
        c['gapUntil'] = f + 1 + (rng.next() * (longSequenceTrackBuffer + 3)).floorToDouble();
        continue;
      }
      if (r < 0.10) continue; // single-frame miss
      final score = (c['score']! + (rng.next() - 0.5) * 0.3).clamp(0.05, 0.99).toDouble();
      dets.add(_box(c['x']!, c['y']!, c['w']!, c['h']!, score));
    }
    if (rng.next() < 0.15) {
      dets.add(_box(rng.next() * 1200, rng.next() * 650, 25, 25, 0.2 + rng.next() * 0.6));
    }
    frames.add(dets);
  }
  return frames;
}
