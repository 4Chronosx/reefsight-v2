import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/tracking/bot_sort_tracker.dart';
import 'package:reefsight_mobile/tracking/camera_motion_compensation.dart';
import 'package:reefsight_mobile/tracking/tracker_detection.dart';

TrackerDetection _det(
  double x1,
  double y1, {
  double w = 20,
  double h = 20,
  double score = 0.9,
}) =>
    TrackerDetection(x1: x1, y1: y1, x2: x1 + w, y2: y1 + h, score: score);

/// A checkerboard: strong, evenly-distributed corners for the estimator to
/// lock onto — a flat/blank image has none.
List<int> _checkerboard(int width, int height, {int cell = 10}) {
  return [
    for (var y = 0; y < height; y++)
      for (var x = 0; x < width; x++)
        ((x ~/ cell) + (y ~/ cell)).isEven ? 40 : 220,
  ];
}

void main() {
  group('BoTSortTracker camera motion compensation', () {
    test('a compensator with no frame passed behaves exactly like none', () {
      // `STrack`'s id counter is process-wide static state (a faithful port
      // of the reference's own `BaseTrack._count` class attribute, which
      // has the same characteristic) — reset by each `BoTSortTracker`
      // constructor. Running two tracker instances' `update()` calls
      // sequentially (not interleaved) keeps each run's id sequence
      // self-consistent so the two runs are actually comparable.
      final detSequence = [
        for (var i = 0; i < 3; i++) [_det(i.toDouble(), i.toDouble())],
      ];

      final withCompensator = BoTSortTracker(
        cameraMotionCompensator: CameraMotionCompensator(),
      );
      final withResults = [
        for (final dets in detSequence) withCompensator.update(dets),
      ];

      final withoutCompensator = BoTSortTracker();
      final withoutResults = [
        for (final dets in detSequence) withoutCompensator.update(dets),
      ];

      // Same detections, no `frame:` argument on either — the CMC branch in
      // update() requires both a compensator AND a frame, so this should be
      // byte-for-byte identical to the no-CMC path.
      for (var i = 0; i < detSequence.length; i++) {
        final a = withResults[i];
        final b = withoutResults[i];
        expect(a.length, b.length);
        for (var j = 0; j < a.length; j++) {
          expect(a[j].trackId, b[j].trackId);
          expect(a[j].tlbr, b[j].tlbr);
        }
      }
    });

    test(
        'providing a compensator and real frames does not crash and keeps '
        'tracking a static scene normally', () {
      final tracker = BoTSortTracker(
        cameraMotionCompensator: CameraMotionCompensator(downscale: 1),
      );
      final frame = GrayscaleFrame(
        width: 160,
        height: 160,
        pixels: _checkerboard(160, 160),
      );

      tracker.update([_det(50, 50)], frame: frame);
      final id = tracker.tracks.first.trackId;

      // Static scene (frame content unchanged across calls) -> the
      // estimated warp should be near-identity, so tracking should proceed
      // normally rather than being perturbed by CMC.
      for (var i = 1; i < 4; i++) {
        tracker.update([_det(50 + i.toDouble(), 50)], frame: frame);
      }

      expect(tracker.tracks.single.trackId, id);
    });
  });
}
