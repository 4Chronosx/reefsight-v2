import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/tracking/bot_sort_tracker.dart';
import 'package:reefsight_mobile/tracking/tracker_detection.dart';

// Sub-plan 3 ("no separate matching/alignment step"): the app needs to know,
// after tracker.update(), which of this frame's detections (mask + health
// classification) matched which output track. These tests exercise that
// payload thread end to end through BoTSortTracker, not just STrack in
// isolation, since the payload copy-through only matters at the points where
// the tracker actually folds a new detection into a persisted track.

TrackerDetection _det(
  double x1,
  double y1, {
  double w = 20,
  double h = 20,
  double score = 0.9,
  Object? payload,
}) =>
    TrackerDetection(
      x1: x1,
      y1: y1,
      x2: x1 + w,
      y2: y1 + h,
      score: score,
      payload: payload,
    );

void main() {
  group('TrackerDetection payload', () {
    test('defaults to null', () {
      expect(_det(0, 0).payload, isNull);
    });

    test('stores whatever object is passed', () {
      final payload = {'health': 'bleached'};
      expect(_det(0, 0, payload: payload).payload, same(payload));
    });
  });

  group('BoTSortTracker payload threading', () {
    test("a newly-activated track carries its detection's payload", () {
      final tracker = BoTSortTracker();
      final payload = {'health': 'healthy'};

      final tracks = tracker.update([_det(0, 0, payload: payload)]);

      expect(tracks.single.payload, same(payload));
    });

    test("a matched track's payload updates to the new frame's detection",
        () {
      final tracker = BoTSortTracker();
      final firstPayload = {'health': 'healthy'};
      final secondPayload = {'health': 'bleached'};

      tracker.update([_det(0, 0, payload: firstPayload)]);
      final tracks = tracker.update([_det(1, 1, payload: secondPayload)]);

      expect(tracks.single.payload, same(secondPayload));
      expect(tracks.single.payload, isNot(same(firstPayload)));
    });

    test('a track recovered from lost carries the recovering payload', () {
      final tracker = BoTSortTracker(trackBuffer: 5);
      final firstPayload = {'health': 'healthy'};
      final recoveredPayload = {'health': 'bleached'};

      tracker.update([_det(0, 0, payload: firstPayload)]);
      tracker.update([]); // one missed frame -> lost, not removed
      final tracks = tracker.update([_det(2, 2, payload: recoveredPayload)]);

      expect(tracks.single.payload, same(recoveredPayload));
    });

    test('two independently-tracked colonies each keep their own payload',
        () {
      final tracker = BoTSortTracker();
      final nearPayload = {'health': 'healthy'};
      final farPayload = {'health': 'bleached'};

      final tracks = tracker.update([
        _det(0, 0, payload: nearPayload),
        _det(500, 500, payload: farPayload),
      ]);

      final near = tracks.firstWhere((t) => t.tlbr[0] < 100);
      final far = tracks.firstWhere((t) => t.tlbr[0] >= 100);
      expect(near.payload, same(nearPayload));
      expect(far.payload, same(farPayload));
    });
  });
}
