import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/services/live_loop_metrics.dart';

// Sub-plan 09 (live-loop decoupling), step 1: "events/s, tracker updates/s,
// and the distribution of gaps between updates" over a rolling window. The
// clock is injected so these numbers are exact rather than timing-dependent.

/// A settable clock: tests advance `now` by hand between records.
class _Clock {
  DateTime now = DateTime.utc(2026, 10, 1, 9);
  void advance(int ms) => now = now.add(Duration(milliseconds: ms));
}

void main() {
  group('LiveLoopMetrics', () {
    test('an empty window reports zeros and no gaps', () {
      final clock = _Clock();
      final metrics = LiveLoopMetrics(now: () => clock.now);

      final s = metrics.summary();

      expect(s.eventsPerSecond, 0);
      expect(s.updatesPerSecond, 0);
      expect(s.gapP50Ms, isNull);
      expect(s.gapP95Ms, isNull);
      expect(s.gapMaxMs, isNull);
    });

    test('a steady 8 Hz stream reports 8 events/s and 125 ms gaps', () {
      final clock = _Clock();
      final metrics = LiveLoopMetrics(now: () => clock.now);

      // 81 events 125 ms apart span exactly 10 s.
      for (var i = 0; i <= 80; i++) {
        metrics.recordEvent(detectionCount: 2);
        metrics.recordTrackerUpdate();
        if (i < 80) clock.advance(125);
      }

      final s = metrics.summary();
      expect(s.eventsPerSecond, closeTo(8, 0.01));
      expect(s.updatesPerSecond, closeTo(8, 0.01));
      expect(s.gapP50Ms, 125);
      expect(s.gapP95Ms, 125);
      expect(s.gapMaxMs, 125);
      expect(s.meanDetections, 2);
    });

    test('skipped updates show up as fewer updates/s and longer gaps', () {
      final clock = _Clock();
      final metrics = LiveLoopMetrics(now: () => clock.now);

      // Every event arrives, but only every 4th one reaches the tracker --
      // the "dropped while classifying" pattern sub-plan 09 is measuring.
      for (var i = 0; i <= 80; i++) {
        metrics.recordEvent(detectionCount: 1);
        if (i % 4 == 0) metrics.recordTrackerUpdate();
        if (i < 80) clock.advance(125);
      }

      final s = metrics.summary();
      expect(s.eventsPerSecond, closeTo(8, 0.01));
      expect(s.updatesPerSecond, closeTo(2, 0.01));
      expect(s.gapP50Ms, 500);
      expect(s.gapMaxMs, 500);
    });

    test('p95 picks out a rare long stall that p50 hides', () {
      final clock = _Clock();
      final metrics = LiveLoopMetrics(now: () => clock.now);

      // 19 gaps of 100 ms, then one 1000 ms stall: 20 gaps in all.
      metrics.recordTrackerUpdate();
      for (var i = 0; i < 19; i++) {
        clock.advance(100);
        metrics.recordTrackerUpdate();
      }
      clock.advance(1000);
      metrics.recordTrackerUpdate();

      final s = metrics.summary();
      expect(s.gapP50Ms, 100);
      // Nearest-rank p95 of 20 samples is the 19th smallest.
      expect(s.gapP95Ms, 100);
      expect(s.gapMaxMs, 1000);
    });

    test('samples older than the window are dropped', () {
      final clock = _Clock();
      final metrics = LiveLoopMetrics(
        window: const Duration(seconds: 2),
        now: () => clock.now,
      );

      for (var i = 0; i < 10; i++) {
        metrics.recordEvent(detectionCount: 5);
        clock.advance(100);
      }
      clock.advance(5000);
      metrics.recordEvent(detectionCount: 1);

      final s = metrics.summary();
      expect(s.meanDetections, 1);
    });

    test('rates divide by elapsed time until the window has filled', () {
      final clock = _Clock();
      final metrics = LiveLoopMetrics(now: () => clock.now);

      // 5 events over 1 s (well inside the 10 s window).
      for (var i = 0; i <= 4; i++) {
        metrics.recordEvent(detectionCount: 0);
        if (i < 4) clock.advance(250);
      }

      expect(metrics.summary().eventsPerSecond, closeTo(4, 0.01));
    });

    test('batches report classifications/s and mean batch time', () {
      final clock = _Clock();
      final metrics = LiveLoopMetrics(now: () => clock.now);

      metrics.recordEvent(detectionCount: 3);
      metrics.recordBatch(
        elapsed: const Duration(milliseconds: 40),
        classifications: 3,
      );
      clock.advance(1000);
      metrics.recordEvent(detectionCount: 3);
      metrics.recordBatch(
        elapsed: const Duration(milliseconds: 60),
        classifications: 1,
      );

      final s = metrics.summary();
      expect(s.classificationsPerSecond, closeTo(4, 0.01));
      expect(s.meanBatchMs, closeTo(50, 0.01));
    });

    test('format() is a single line naming every number', () {
      final clock = _Clock();
      final metrics = LiveLoopMetrics(now: () => clock.now);
      metrics.recordEvent(detectionCount: 1);
      metrics.recordTrackerUpdate();
      clock.advance(125);
      metrics.recordEvent(detectionCount: 1);
      metrics.recordTrackerUpdate();

      final line = metrics.summary().format();

      expect(line, isNot(contains('\n')));
      for (final key in ['ev/s', 'upd/s', 'gap', 'trk', 'cls/s']) {
        expect(line, contains(key));
      }
    });

    test('timed tracker updates report mean and p95 cost (sub-plan 08 CMC latency)', () {
      final clock = _Clock();
      final metrics = LiveLoopMetrics(now: () => clock.now);
      for (final ms in [4, 6, 8, 10, 22]) {
        metrics.recordTrackerUpdate(elapsed: Duration(milliseconds: ms));
        clock.advance(125);
      }
      metrics.recordTrackerUpdate(); // untimed: counts toward the rate only

      final s = metrics.summary();
      expect(s.updatesPerSecond, closeTo(8, 0.01));
      expect(s.updateMeanMs, closeTo(10, 0.001));
      expect(s.updateP95Ms, 22);
      expect(s.format(), contains('trk mean/p95 10.0/22.0ms'));
      expect(LiveLoopMetrics(now: () => clock.now).summary().updateMeanMs, isNull);
    });
  });
}
