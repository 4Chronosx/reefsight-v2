import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/services/bleaching_classifier.dart';
import 'package:reefsight_mobile/services/crop_geometry.dart';
import 'package:reefsight_mobile/services/live_frame_processor.dart';
import 'package:reefsight_mobile/services/live_loop_metrics.dart';
import 'package:reefsight_mobile/tracking/bot_sort_tracker.dart';
import 'package:reefsight_mobile/tracking/strack.dart';

// Sub-plan 09 (live-loop decoupling), steps 2-4. The processor is the live
// screen's per-event logic pulled out of the widget so it can be driven
// without the native YOLOView:
// - every streaming event reaches the tracker, including empty ones;
// - classification never delays a tracker update;
// - only confirmed tracks are classified.
// The last group replays a steady 8 Hz stream through both the legacy loop
// and the decoupled one with a fake classifier of realistic latency -- the
// simulated before/after the sub-plan asks for when on-device numbers aren't
// available.

Map<String, dynamic> _det(double x, double y, {double score = 0.9}) => {
  'classIndex': 0,
  'className': 'coral',
  'confidence': score,
  'boundingBox': {'left': x, 'top': y, 'right': x + 40, 'bottom': y + 40},
  'normalizedBox': {'left': 0.0, 'top': 0.0, 'right': 0.1, 'bottom': 0.1},
};

final _frame = Uint8List.fromList([0xFF, 0xD8, 0xFF]);

Map<String, dynamic> _event(List<Map<String, dynamic>> detections) => {
  'detections': detections,
  'originalImage': _frame,
  'imageWidth': 640,
  'imageHeight': 480,
};

const _healthy = ColonyHealth(label: 'CORAL', confidence: 0.9);

/// Records every batch and answers immediately (or never, if [hang]).
class _FakeClassifier {
  _FakeClassifier({this.hang = false});

  final bool hang;
  final calls = <List<Rect>>[];

  Future<List<ColonyHealth?>> call(
    Uint8List frameBytes,
    List<Rect> boxes, {
    required int frameWidth,
    required int frameHeight,
  }) {
    calls.add(boxes);
    if (hang) return Completer<List<ColonyHealth?>>().future;
    return Future.value([for (final _ in boxes) _healthy]);
  }
}

void main() {
  group('LiveFrameProcessor (decoupled)', () {
    test('an event with no detections still advances the tracker', () {
      final tracker = BoTSortTracker(trackBuffer: 3);
      final processor = LiveFrameProcessor(
        tracker: tracker,
        classify: _FakeClassifier().call,
        cropStyle: CropStyle.boxStretch,
        onTracks: (_) {},
        onHealth: (_, _, _) {},
      );

      processor.handleEvent(_event([_det(100, 100)]));
      final id = tracker.tracks.single.trackId;

      // 5 empty events exceed the 3-frame buffer, so the track is removed.
      // The old loop returned before `update` on empty frames, so the same
      // colony reappearing here would have been "recovered" with its old id.
      for (var i = 0; i < 5; i++) {
        processor.handleEvent(_event(const []));
      }
      processor.handleEvent(_event([_det(100, 100)]));

      expect(tracker.tracks.single.trackId, isNot(id));
    });

    test('an event without a frame image still updates the tracker', () {
      final tracker = BoTSortTracker();
      final fake = _FakeClassifier();
      final processor = LiveFrameProcessor(
        tracker: tracker,
        classify: fake.call,
        cropStyle: CropStyle.boxStretch,
        onTracks: (_) {},
        onHealth: (_, _, _) {},
      );

      processor.handleEvent({
        'detections': [_det(100, 100)],
      });

      expect(tracker.tracks, hasLength(1));
      expect(fake.calls, isEmpty);
    });

    test('degenerate boxes are dropped before the tracker', () {
      final tracker = BoTSortTracker();
      final processor = LiveFrameProcessor(
        tracker: tracker,
        classify: _FakeClassifier().call,
        cropStyle: CropStyle.boxStretch,
        onTracks: (_) {},
        onHealth: (_, _, _) {},
      );

      processor.handleEvent(
        _event([
          {
            ..._det(0, 0),
            'boundingBox': {'left': 5.0, 'top': 5.0, 'right': 5.0, 'bottom': 9.0},
          },
        ]),
      );

      expect(tracker.tracks, isEmpty);
    });

    test('onTracks gets every update, carrying this frame\'s mask and box',
        () {
      final updates = <List<STrack>>[];
      final processor = LiveFrameProcessor(
        tracker: BoTSortTracker(),
        classify: _FakeClassifier().call,
        cropStyle: CropStyle.boxStretch,
        onTracks: updates.add,
        onHealth: (_, _, _) {},
      );

      processor.handleEvent(
        _event([
          {
            ..._det(100, 100),
            'mask': [
              [1.0, 0.0],
              [0.0, 1.0],
            ],
          },
        ]),
      );
      processor.handleEvent(_event(const []));

      expect(updates, hasLength(2));
      final payload = updates.first.single.payload as LiveDetectionPayload;
      expect(payload.box, const Rect.fromLTRB(100, 100, 140, 140));
      expect(payload.mask, [
        [1.0, 0.0],
        [0.0, 1.0],
      ]);
      expect(updates.last, isEmpty);
    });

    test('a classifier that never returns does not hold up the tracker', () {
      final tracker = BoTSortTracker();
      final fake = _FakeClassifier(hang: true);
      final metrics = LiveLoopMetrics();
      var updates = 0;
      final processor = LiveFrameProcessor(
        tracker: tracker,
        classify: fake.call,
        cropStyle: CropStyle.boxStretch,
        onTracks: (_) => updates++,
        onHealth: (_, _, _) {},
        metrics: metrics,
      );

      for (var i = 0; i < 8; i++) {
        processor.handleEvent(_event([_det(100.0 + i, 100)]));
      }

      expect(updates, 8);
      expect(fake.calls, hasLength(1));
    });

    test('a track is classified only once it is confirmed', () async {
      final fake = _FakeClassifier();
      final processor = LiveFrameProcessor(
        tracker: BoTSortTracker(),
        classify: fake.call,
        cropStyle: CropStyle.boxStretch,
        onTracks: (_) {},
        onHealth: (_, _, _) {},
      );

      // Frame 1: A starts (first-frame tracks are confirmed immediately).
      processor.handleEvent(_event([_det(100, 100)]));
      await pumpEventQueue();
      // Frame 2: B appears -- unconfirmed until matched a second time.
      processor.handleEvent(_event([_det(100, 100), _det(400, 300)]));
      await pumpEventQueue();
      // Frame 3: B matched again -> confirmed -> due.
      processor.handleEvent(_event([_det(100, 100), _det(400, 300)]));
      await pumpEventQueue();

      expect(fake.calls, [
        [const Rect.fromLTRB(100, 100, 140, 140)],
        [const Rect.fromLTRB(400, 300, 440, 340)],
      ]);
    });

    test('results reach onHealth under the classified track\'s id', () async {
      final health = <(int, ColonyHealth)>[];
      final tracker = BoTSortTracker();
      final processor = LiveFrameProcessor(
        tracker: tracker,
        classify: _FakeClassifier().call,
        cropStyle: CropStyle.boxStretch,
        onTracks: (_) {},
        onHealth: (id, h, _) => health.add((id, h)),
      );

      processor.handleEvent(_event([_det(100, 100)]));
      await pumpEventQueue();

      expect(health, [(tracker.tracks.single.trackId, _healthy)]);
    });

    test('after close, events are ignored', () async {
      final tracker = BoTSortTracker();
      final processor = LiveFrameProcessor(
        tracker: tracker,
        classify: _FakeClassifier().call,
        cropStyle: CropStyle.boxStretch,
        onTracks: (_) {},
        onHealth: (_, _, _) {},
      );

      await processor.close();
      processor.handleEvent(_event([_det(100, 100)]));

      expect(tracker.tracks, isEmpty);
    });
  });

  // Sub-plan 10 (classifier input and reject), steps 1-2. The tests above
  // pin `boxStretch` because they're about the loop; these are about which
  // crop is offered, and whether it's offered at all.
  group('LiveFrameProcessor gating (sub-plan 10)', () {
    List<List<double>> full(int rows, int cols) =>
        List.generate(rows, (_) => List.filled(cols, 1.0));

    Map<String, dynamic> detWithMask(
      Rect box,
      List<List<double>> mask, {
      double score = 0.9,
    }) => {
      ..._det(box.left, box.top, score: score),
      'boundingBox': {
        'left': box.left,
        'top': box.top,
        'right': box.right,
        'bottom': box.bottom,
      },
      'mask': mask,
    };

    test('insideMaskSquare is the default and offers the square window',
        () async {
      final fake = _FakeClassifier();
      final processor = LiveFrameProcessor(
        tracker: BoTSortTracker(),
        classify: fake.call,
        onTracks: (_) {},
        onHealth: (_, _, _) {},
      );

      // A 200x100 box, fully masked: side = min(200, 100) = 100, centred on
      // the deepest cell (row 2, col 4 of a 5x10 grid -> x 190, y 150).
      processor.handleEvent(
        _event([detWithMask(const Rect.fromLTWH(100, 100, 200, 100), full(5, 10))]),
      );
      await pumpEventQueue();

      expect(processor.cropStyle, CropStyle.insideMaskSquare);
      expect(fake.calls.single, [const Rect.fromLTWH(140, 100, 100, 100)]);
    });

    test('a low-coverage crop is not offered, counts once per retry window, '
        'and the track stays due', () async {
      var clockMs = 0;
      DateTime now() =>
          DateTime.utc(2026, 10, 1).add(Duration(milliseconds: clockMs));
      final fake = _FakeClassifier();
      final metrics = LiveLoopMetrics(now: now);
      final processor = LiveFrameProcessor(
        tracker: BoTSortTracker(),
        classify: fake.call,
        onTracks: (_) {},
        onHealth: (_, _, _) {},
        metrics: metrics,
        now: now,
      );

      // Only the middle row of the box is coral: the 100 px window is the
      // box itself, and 20% of it is mask.
      final thin = List.generate(5, (r) => List.filled(5, r == 2 ? 1.0 : 0.0));
      processor.handleEvent(
        _event([detWithMask(const Rect.fromLTWH(100, 100, 100, 100), thin)]),
      );
      await pumpEventQueue();

      expect(fake.calls, isEmpty);
      expect(metrics.summary().insufficientViews, 1);

      // 125 ms later, still a poor view: inside the 250 ms retry window, so
      // it's neither re-cropped nor counted again.
      clockMs = 125;
      processor.handleEvent(
        _event([detWithMask(const Rect.fromLTWH(100, 100, 100, 100), thin)]),
      );
      await pumpEventQueue();
      expect(metrics.summary().insufficientViews, 1);

      // Same colony, now seen fully after the retry window: still due (an
      // insufficient view isn't an attempt), so it's offered.
      clockMs = 375;
      processor.handleEvent(
        _event([detWithMask(const Rect.fromLTWH(100, 100, 100, 100), full(5, 5))]),
      );
      await pumpEventQueue();

      expect(fake.calls, hasLength(1));
    });

    test('a detection without a mask is not offered under insideMaskSquare',
        () async {
      final fake = _FakeClassifier();
      final processor = LiveFrameProcessor(
        tracker: BoTSortTracker(),
        classify: fake.call,
        onTracks: (_) {},
        onHealth: (_, _, _) {},
      );

      processor.handleEvent(_event([_det(100, 100)]));
      await pumpEventQueue();

      expect(fake.calls, isEmpty);
    });

    test('a detection below the segmentation floor is never offered',
        () async {
      final fake = _FakeClassifier();
      final processor = LiveFrameProcessor(
        tracker: BoTSortTracker(),
        classify: fake.call,
        cropStyle: CropStyle.boxStretch,
        onTracks: (_) {},
        onHealth: (_, _, _) {},
        reclassifyEvery: Duration.zero,
      );

      processor.handleEvent(_event([_det(100, 100)]));
      await pumpEventQueue();
      expect(fake.calls, hasLength(1));

      // Same colony at 0.35: still tracked (BoT-SORT's low-score second
      // pass), due again (reclassifyEvery 0), but below the 0.4 floor.
      processor.handleEvent(_event([_det(101, 100, score: 0.35)]));
      await pumpEventQueue();

      expect(fake.calls, hasLength(1));
    });

    test('control: a second-pass match above the floor (0.5) is offered',
        () async {
      // Same setup as the 0.35 case, so that test can only pass because of
      // the floor -- not because the low-score detection failed to match.
      final fake = _FakeClassifier();
      final processor = LiveFrameProcessor(
        tracker: BoTSortTracker(),
        classify: fake.call,
        cropStyle: CropStyle.boxStretch,
        onTracks: (_) {},
        onHealth: (_, _, _) {},
        reclassifyEvery: Duration.zero,
      );

      processor.handleEvent(_event([_det(100, 100)]));
      await pumpEventQueue();
      processor.handleEvent(_event([_det(101, 100, score: 0.5)]));
      await pumpEventQueue();

      expect(fake.calls, hasLength(2));
    });

    test('boxSquarePad offers a square around the box', () async {
      final fake = _FakeClassifier();
      final processor = LiveFrameProcessor(
        tracker: BoTSortTracker(),
        classify: fake.call,
        cropStyle: CropStyle.boxSquarePad,
        onTracks: (_) {},
        onHealth: (_, _, _) {},
      );

      processor.handleEvent(
        _event([detWithMask(const Rect.fromLTWH(100, 100, 200, 100), full(2, 2))]),
      );
      await pumpEventQueue();

      expect(fake.calls.single, [const Rect.fromLTWH(100, 50, 200, 200)]);
    });
  });

  group('LiveFrameProcessor (legacy loop, sub-plan 09 baseline)', () {
    test('classifies every detection before updating, one box per call',
        () async {
      final fake = _FakeClassifier();
      final health = <int>[];
      final tracker = BoTSortTracker();
      final processor = LiveFrameProcessor(
        tracker: tracker,
        classify: fake.call,
        cropStyle: CropStyle.boxStretch,
        onTracks: (_) {},
        onHealth: (id, _, _) => health.add(id),
        useLegacyLoop: true,
      );

      processor.handleEvent(_event([_det(100, 100), _det(400, 300)]));
      await pumpEventQueue();

      expect(fake.calls, hasLength(2));
      expect(fake.calls.every((boxes) => boxes.length == 1), isTrue);
      expect(health.toSet(), tracker.tracks.map((t) => t.trackId).toSet());
    });

    test('drops events while busy and skips empty ones, as before', () async {
      final fake = _FakeClassifier(hang: true);
      var updates = 0;
      final processor = LiveFrameProcessor(
        tracker: BoTSortTracker(),
        classify: fake.call,
        cropStyle: CropStyle.boxStretch,
        onTracks: (_) => updates++,
        onHealth: (_, _, _) {},
        useLegacyLoop: true,
      );

      processor.handleEvent(_event(const []));
      processor.handleEvent(_event([_det(100, 100)]));
      processor.handleEvent(_event([_det(100, 100)]));
      await pumpEventQueue();

      expect(updates, 0);
      expect(fake.calls, hasLength(1));
    });
  });

  group('simulated 8 Hz stream, 3 colonies, 60 ms per classified crop', () {
    // Deterministic stand-in for sub-plan 09's on-device measurement: the
    // native stream is a perfect 8 Hz here (no real stalls), so this isolates
    // what the *loop* does to the update rate.
    Future<LiveLoopSummary> simulate(
      WidgetTester tester, {
      required bool legacy,
    }) async {
      var clockMs = 0;
      DateTime now() =>
          DateTime.utc(2026, 10, 1).add(Duration(milliseconds: clockMs));

      Future<List<ColonyHealth?>> slowClassify(
        Uint8List frameBytes,
        List<Rect> boxes, {
        required int frameWidth,
        required int frameHeight,
      }) => Future.delayed(
        Duration(milliseconds: 60 * boxes.length),
        () => [for (final _ in boxes) _healthy],
      );

      final metrics = LiveLoopMetrics(now: now);
      final processor = LiveFrameProcessor(
        tracker: BoTSortTracker(),
        classify: slowClassify,
        cropStyle: CropStyle.boxStretch,
        onTracks: (_) {},
        onHealth: (_, _, _) {},
        metrics: metrics,
        useLegacyLoop: legacy,
        now: now,
      );

      // 10 s of stream, stepped in 5 ms so batch timings resolve finely.
      for (clockMs = 0; clockMs <= 10000; clockMs += 5) {
        if (clockMs % 125 == 0) {
          // Slow drift so the colonies move a little, as on a swim.
          final dx = clockMs / 100;
          processor.handleEvent(
            _event([_det(50 + dx, 50), _det(250 + dx, 150), _det(450 + dx, 250)]),
          );
        }
        await tester.pump(const Duration(milliseconds: 5));
      }
      clockMs = 10000;
      final summary = metrics.summary();
      // close() awaits the in-flight batch, whose Future.delayed only fires
      // when fake time advances -- so pump past it before awaiting.
      final closed = processor.close();
      await tester.pump(const Duration(seconds: 1));
      await closed;
      return summary;
    }

    testWidgets('legacy loop: the tracker sees well under the event rate',
        (tester) async {
      final s = await simulate(tester, legacy: true);
      debugPrint('sub-plan 09 simulated BEFORE (legacy): ${s.format()}');

      expect(s.eventsPerSecond, closeTo(8, 0.1));
      expect(s.updatesPerSecond, lessThan(5));
      expect(s.gapMaxMs, greaterThanOrEqualTo(250));
    });

    testWidgets('decoupled loop: the tracker sees every event', (tester) async {
      final s = await simulate(tester, legacy: false);
      debugPrint('sub-plan 09 simulated AFTER (decoupled): ${s.format()}');

      expect(s.eventsPerSecond, closeTo(8, 0.1));
      expect(s.updatesPerSecond, closeTo(8, 0.1));
      expect(s.gapMaxMs, 125);
      // 3 colonies, each reclassified about once a second.
      expect(s.classificationsPerSecond, closeTo(3, 0.5));
    });
  });
}
