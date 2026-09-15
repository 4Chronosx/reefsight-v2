import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/tracking/bot_sort_tracker.dart';
import 'package:reefsight_mobile/tracking/tracker_detection.dart';

TrackerDetection _det(
  double x1,
  double y1, {
  double w = 20,
  double h = 20,
  double score = 0.9,
}) =>
    TrackerDetection(x1: x1, y1: y1, x2: x1 + w, y2: y1 + h, score: score);

void main() {
  group('BoTSortTracker lifecycle', () {
    test('a high-score detection is tracked from the first frame', () {
      final tracker = BoTSortTracker();
      final tracks = tracker.update([_det(0, 0)]);

      expect(tracks.length, 1);
      expect(tracks.first.trackId, 1);
    });

    test('a track keeps its id across consecutive matching frames', () {
      final tracker = BoTSortTracker();
      tracker.update([_det(0, 0)]);
      final id = tracker.tracks.first.trackId;

      tracker.update([_det(1, 1)]);
      tracker.update([_det(2, 2)]);

      expect(tracker.tracks.single.trackId, id);
    });

    test('a track is removed after being missed for track_buffer frames', () {
      final tracker = BoTSortTracker(trackBuffer: 3);
      tracker.update([_det(0, 0)]);
      expect(tracker.tracks.length, 1);

      // Frame 2: miss (goes lost). Frames 3-5: still within the 3-frame
      // buffer. Frame 6: buffer exceeded (frameId - endFrame > 3) -> removed.
      for (var i = 0; i < 5; i++) {
        tracker.update([]);
      }

      expect(tracker.tracks, isEmpty);
    });

    test('a briefly-missed track is recovered (not just re-created)', () {
      final tracker = BoTSortTracker(trackBuffer: 5);
      tracker.update([_det(0, 0)]);
      final id = tracker.tracks.first.trackId;

      tracker.update([]); // one missed frame — track goes "lost", not removed
      expect(tracker.tracks, isEmpty); // lost tracks aren't in `tracks`

      tracker.update([_det(2, 2)]); // recovers within the buffer window
      expect(tracker.tracks.single.trackId, id);
    });
  });

  group('BoTSortTracker assignment correctness', () {
    test('assigns each of two nearby detections to the correct existing track',
        () {
      final tracker = BoTSortTracker();
      tracker.update([_det(0, 0), _det(100, 100)]);
      final idNearOrigin =
          tracker.tracks.firstWhere((t) => t.tlbr[0] < 50).trackId;
      final idFar = tracker.tracks.firstWhere((t) => t.tlbr[0] >= 50).trackId;

      // Detections move slightly but stay closest to their own track.
      tracker.update([_det(2, 2), _det(102, 102)]);

      final near = tracker.tracks.firstWhere((t) => t.tlbr[0] < 50);
      final far = tracker.tracks.firstWhere((t) => t.tlbr[0] >= 50);
      expect(near.trackId, idNearOrigin);
      expect(far.trackId, idFar);
    });

    test('a low-score detection recovers a track the high threshold missed',
        () {
      // BoT-SORT's whole point (via ByteTrack's mechanism): a partially
      // confident detection on an already-tracked colony still keeps the
      // track alive through the second-stage low-score association, instead
      // of being dropped as noise.
      final tracker = BoTSortTracker();
      tracker.update([_det(0, 0, score: 0.9)]);
      final id = tracker.tracks.first.trackId;

      tracker.update([_det(1, 1, score: 0.3)]); // between low/high thresh
      expect(tracker.tracks.single.trackId, id);
    });
  });

  group('BoTSortTracker multi-object isolation', () {
    test('two simultaneous non-overlapping detections get separate ids', () {
      final tracker = BoTSortTracker();
      final tracks = tracker.update([_det(0, 0), _det(200, 200)]);

      expect(tracks.length, 2);
      expect(tracks.map((t) => t.trackId).toSet().length, 2);
    });

    test('losing one of several tracked colonies does not affect the others',
        () {
      final tracker = BoTSortTracker(trackBuffer: 2);
      tracker.update([_det(0, 0), _det(200, 200)]);
      final survivorId =
          tracker.tracks.firstWhere((t) => t.tlbr[0] < 100).trackId;

      // Only the colony near (0,0) keeps getting detected.
      for (var i = 0; i < 4; i++) {
        tracker.update([_det(i.toDouble(), i.toDouble())]);
      }

      expect(tracker.tracks.length, 1);
      expect(tracker.tracks.single.trackId, survivorId);
    });
  });
}
