import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/services/bleaching_classifier.dart';
import 'package:reefsight_mobile/services/classification_scheduler.dart';

// Sub-plan 09 (live-loop decoupling), step 3: classification is keyed by
// track id and scheduled -- never-classified tracks first, then each track
// at most once per `reclassifyEvery`, at most `maxPerFrame` per batch, and
// at most one batch in flight. A batch still running never makes the caller
// wait: `offer` returns immediately either way.

final _t0 = DateTime.utc(2026, 10, 1, 9);
DateTime _at(int ms) => _t0.add(Duration(milliseconds: ms));

ClassificationCandidate _c(int id) => ClassificationCandidate(
  trackId: id,
  box: Rect.fromLTWH(id * 10.0, 0, 10, 10),
);

/// A classifier whose batches complete only when the test says so.
class _FakeClassifier {
  final calls = <List<Rect>>[];
  final _pending = <Completer<List<ColonyHealth?>>>[];

  Future<List<ColonyHealth?>> call(
    Uint8List frameBytes,
    List<Rect> boxes, {
    required int frameWidth,
    required int frameHeight,
  }) {
    calls.add(boxes);
    final completer = Completer<List<ColonyHealth?>>();
    _pending.add(completer);
    return completer.future;
  }

  /// Completes the oldest pending batch with one result per box.
  Future<void> completeNext(List<ColonyHealth?> results) async {
    _pending.removeAt(0).complete(results);
    await pumpEventQueue();
  }

  Future<void> failNext() async {
    _pending.removeAt(0).completeError(StateError('native predict failed'));
    await pumpEventQueue();
  }
}

const _healthy = ColonyHealth(label: 'CORAL', confidence: 0.9);
const _bleached = ColonyHealth(label: 'CORAL_BL', confidence: 0.8);

void main() {
  final frame = Uint8List.fromList([1, 2, 3]);

  group('ClassificationScheduler.selectDue', () {
    test('never-classified tracks are all due, capped at maxPerFrame', () {
      final scheduler = ClassificationScheduler(
        classify: _FakeClassifier().call,
        onResult: (_, _, _) {},
        maxPerFrame: 3,
      );

      final due = scheduler.selectDue([_c(1), _c(2), _c(3), _c(4)], _at(0));

      expect(due, [1, 2, 3]);
    });

    test('a track sampled recently is not due again until reclassifyEvery',
        () async {
      final fake = _FakeClassifier();
      final scheduler = ClassificationScheduler(
        classify: fake.call,
        onResult: (_, _, _) {},
        reclassifyEvery: const Duration(seconds: 1),
      );

      scheduler.offer(
        frameBytes: frame,
        frameWidth: 100,
        frameHeight: 100,
        candidates: [_c(1)],
        sampledAt: _at(0),
      );
      await fake.completeNext([_healthy]);

      expect(scheduler.selectDue([_c(1)], _at(999)), isEmpty);
      expect(scheduler.selectDue([_c(1)], _at(1000)), [1]);
    });

    test('never-classified tracks beat ones waiting to be re-classified',
        () async {
      final fake = _FakeClassifier();
      final scheduler = ClassificationScheduler(
        classify: fake.call,
        onResult: (_, _, _) {},
        maxPerFrame: 2,
      );
      scheduler.offer(
        frameBytes: frame,
        frameWidth: 100,
        frameHeight: 100,
        candidates: [_c(1), _c(2)],
        sampledAt: _at(0),
      );
      await fake.completeNext([_healthy, _healthy]);

      // At 5 s both 1 and 2 are overdue, but 3 has never been classified.
      final due = scheduler.selectDue([_c(1), _c(2), _c(3)], _at(5000));

      expect(due.first, 3);
      expect(due, hasLength(2));
    });

    test('among re-classifications, the longest-waiting track goes first',
        () async {
      final fake = _FakeClassifier();
      final scheduler = ClassificationScheduler(
        classify: fake.call,
        onResult: (_, _, _) {},
        maxPerFrame: 1,
      );
      scheduler.offer(
        frameBytes: frame,
        frameWidth: 100,
        frameHeight: 100,
        candidates: [_c(1)],
        sampledAt: _at(0),
      );
      await fake.completeNext([_healthy]);
      scheduler.offer(
        frameBytes: frame,
        frameWidth: 100,
        frameHeight: 100,
        candidates: [_c(2)],
        sampledAt: _at(500),
      );
      await fake.completeNext([_healthy]);

      // Candidate order lists 2 first; 1 has waited longer.
      expect(scheduler.selectDue([_c(2), _c(1)], _at(3000)), [1]);
    });
  });

  group('ClassificationScheduler.offer', () {
    test('starts one batch with the due tracks\' boxes and returns true', () {
      final fake = _FakeClassifier();
      final scheduler = ClassificationScheduler(
        classify: fake.call,
        onResult: (_, _, _) {},
      );

      final started = scheduler.offer(
        frameBytes: frame,
        frameWidth: 100,
        frameHeight: 100,
        candidates: [_c(1), _c(2)],
        sampledAt: _at(0),
      );

      expect(started, isTrue);
      expect(scheduler.isBusy, isTrue);
      expect(fake.calls.single, [_c(1).box, _c(2).box]);
    });

    test('does nothing while a batch is in flight', () {
      final fake = _FakeClassifier();
      final scheduler = ClassificationScheduler(
        classify: fake.call,
        onResult: (_, _, _) {},
      );
      scheduler.offer(
        frameBytes: frame,
        frameWidth: 100,
        frameHeight: 100,
        candidates: [_c(1)],
        sampledAt: _at(0),
      );

      final started = scheduler.offer(
        frameBytes: frame,
        frameWidth: 100,
        frameHeight: 100,
        candidates: [_c(2)],
        sampledAt: _at(125),
      );

      expect(started, isFalse);
      expect(fake.calls, hasLength(1));
      // Track 2 was never attempted, so it's still due once the batch ends.
      expect(scheduler.selectDue([_c(2)], _at(125)), [2]);
    });

    test('with nothing due, starts no batch', () {
      final fake = _FakeClassifier();
      final scheduler = ClassificationScheduler(
        classify: fake.call,
        onResult: (_, _, _) {},
      );

      expect(
        scheduler.offer(
          frameBytes: frame,
          frameWidth: 100,
          frameHeight: 100,
          candidates: const [],
          sampledAt: _at(0),
        ),
        isFalse,
      );
      expect(fake.calls, isEmpty);
      expect(scheduler.isBusy, isFalse);
    });

    test('delivers each result to its own track id, at the frame time',
        () async {
      final fake = _FakeClassifier();
      final results = <(int, ColonyHealth, DateTime)>[];
      final scheduler = ClassificationScheduler(
        classify: fake.call,
        onResult: (id, health, at) => results.add((id, health, at)),
      );
      scheduler.offer(
        frameBytes: frame,
        frameWidth: 100,
        frameHeight: 100,
        candidates: [_c(7), _c(9)],
        sampledAt: _at(250),
      );

      await fake.completeNext([_bleached, _healthy]);

      expect(results, [(7, _bleached, _at(250)), (9, _healthy, _at(250))]);
      expect(scheduler.isBusy, isFalse);
    });

    test('a null result is skipped and the track waits reclassifyEvery',
        () async {
      final fake = _FakeClassifier();
      final results = <int>[];
      final scheduler = ClassificationScheduler(
        classify: fake.call,
        onResult: (id, _, _) => results.add(id),
      );
      scheduler.offer(
        frameBytes: frame,
        frameWidth: 100,
        frameHeight: 100,
        candidates: [_c(1)],
        sampledAt: _at(0),
      );

      await fake.completeNext([null]);

      expect(results, isEmpty);
      expect(scheduler.selectDue([_c(1)], _at(500)), isEmpty);
    });

    test('a failed batch frees the scheduler and reports nothing', () async {
      final fake = _FakeClassifier();
      final results = <int>[];
      final scheduler = ClassificationScheduler(
        classify: fake.call,
        onResult: (id, _, _) => results.add(id),
      );
      scheduler.offer(
        frameBytes: frame,
        frameWidth: 100,
        frameHeight: 100,
        candidates: [_c(1)],
        sampledAt: _at(0),
      );

      await fake.failNext();

      expect(results, isEmpty);
      expect(scheduler.isBusy, isFalse);
    });

    test('a throwing onResult neither leaks nor blocks close', () async {
      final fake = _FakeClassifier();
      final scheduler = ClassificationScheduler(
        classify: fake.call,
        onResult: (_, _, _) => throw StateError('setState after dispose'),
      );
      scheduler.offer(
        frameBytes: frame,
        frameWidth: 100,
        frameHeight: 100,
        candidates: [_c(1)],
        sampledAt: _at(0),
      );

      await fake.completeNext([_healthy]);

      expect(scheduler.isBusy, isFalse);
      await expectLater(scheduler.close(), completes);
    });

    test('an all-null batch (classifier not loaded) is not reported',
        () async {
      final fake = _FakeClassifier();
      final batches = <(Duration, int)>[];
      final scheduler = ClassificationScheduler(
        classify: fake.call,
        onResult: (_, _, _) {},
        onBatchComplete: (elapsed, n) => batches.add((elapsed, n)),
      );
      scheduler.offer(
        frameBytes: frame,
        frameWidth: 100,
        frameHeight: 100,
        candidates: [_c(1), _c(2)],
        sampledAt: _at(0),
      );

      await fake.completeNext([null, null]);

      expect(batches, isEmpty);
    });

    test('reports batch duration and labelled-crop count', () async {
      final fake = _FakeClassifier();
      var clockMs = 0;
      final batches = <(Duration, int)>[];
      final scheduler = ClassificationScheduler(
        classify: fake.call,
        onResult: (_, _, _) {},
        onBatchComplete: (elapsed, n) => batches.add((elapsed, n)),
        now: () => _at(clockMs),
      );
      scheduler.offer(
        frameBytes: frame,
        frameWidth: 100,
        frameHeight: 100,
        candidates: [_c(1), _c(2)],
        sampledAt: _at(0),
      );

      clockMs = 45;
      await fake.completeNext([_healthy, null]);

      // Two crops, one labelled: the null one doesn't count.
      expect(batches, [(const Duration(milliseconds: 45), 1)]);
    });

    test('after close, offers are refused and late results dropped', () async {
      final fake = _FakeClassifier();
      final results = <int>[];
      final scheduler = ClassificationScheduler(
        classify: fake.call,
        onResult: (id, _, _) => results.add(id),
      );
      scheduler.offer(
        frameBytes: frame,
        frameWidth: 100,
        frameHeight: 100,
        candidates: [_c(1)],
        sampledAt: _at(0),
      );

      final closed = scheduler.close();
      await fake.completeNext([_healthy]);
      await closed;

      expect(results, isEmpty);
      expect(
        scheduler.offer(
          frameBytes: frame,
          frameWidth: 100,
          frameHeight: 100,
          candidates: [_c(2)],
          sampledAt: _at(1000),
        ),
        isFalse,
      );
    });
  });
}
