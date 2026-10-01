import 'dart:collection';

/// One snapshot of [LiveLoopMetrics] over its rolling window.
class LiveLoopSummary {
  const LiveLoopSummary({
    required this.eventsPerSecond,
    required this.updatesPerSecond,
    required this.gapP50Ms,
    required this.gapP95Ms,
    required this.gapMaxMs,
    required this.meanDetections,
    required this.classificationsPerSecond,
    required this.meanBatchMs,
  });

  /// Streaming events received from the native segmentation view.
  final double eventsPerSecond;

  /// `BoTSortTracker.update` calls -- the number sub-plan 08 converts
  /// `trackBuffer` (frames) into seconds with.
  final double updatesPerSecond;

  /// Gaps between consecutive tracker updates, `null` with fewer than two
  /// updates in the window.
  final int? gapP50Ms;
  final int? gapP95Ms;
  final int? gapMaxMs;

  final double? meanDetections;
  final double classificationsPerSecond;
  final double? meanBatchMs;

  /// One line for the diagnostics overlay and the debug log.
  String format() {
    String gap(int? ms) => ms?.toString() ?? '--';
    String num1(double? v) => v?.toStringAsFixed(1) ?? '--';
    return 'ev/s ${num1(eventsPerSecond)}  '
        'upd/s ${num1(updatesPerSecond)}  '
        'gap p50/p95/max ${gap(gapP50Ms)}/${gap(gapP95Ms)}/${gap(gapMaxMs)}ms  '
        'det ${num1(meanDetections)}  '
        'cls/s ${num1(classificationsPerSecond)}  '
        'batch ${meanBatchMs?.toStringAsFixed(0) ?? '--'}ms';
  }
}

/// Rolling-window timing of the live loop (sub-plan 09, step 1: "events/s,
/// tracker updates/s, and the distribution of gaps between updates"), so the
/// update rate sub-plan 08 tunes `trackBuffer` against is measured rather
/// than assumed to be the nominal `inferenceFrequency`.
///
/// Rates are `(n - 1) / (last - first)` over the samples still in the
/// window, i.e. intervals per second of stream actually observed -- so a
/// steady 8 Hz stream reads 8.0 whether the window has filled yet or not.
/// Classifications/s is divided by the same observed event span.
///
/// Cheap enough to run unconditionally; only *showing* it is behind the
/// diagnostics setting.
class LiveLoopMetrics {
  LiveLoopMetrics({
    this.window = const Duration(seconds: 10),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final Duration window;
  final DateTime Function() _now;

  final _events = Queue<({DateTime at, int detections})>();
  final _updates = Queue<DateTime>();
  final _batches = Queue<({DateTime at, Duration elapsed, int n})>();

  void recordEvent({required int detectionCount}) {
    final now = _now();
    _events.add((at: now, detections: detectionCount));
    _prune(now);
  }

  void recordTrackerUpdate() {
    final now = _now();
    _updates.add(now);
    _prune(now);
  }

  void recordBatch({required Duration elapsed, required int classifications}) {
    final now = _now();
    _batches.add((at: now, elapsed: elapsed, n: classifications));
    _prune(now);
  }

  LiveLoopSummary summary() {
    _prune(_now());

    final eventSpan = _spanSeconds(_events.map((e) => e.at));
    final updateSpan = _spanSeconds(_updates);

    final gaps = <int>[];
    DateTime? previous;
    for (final at in _updates) {
      if (previous != null) gaps.add(at.difference(previous).inMilliseconds);
      previous = at;
    }
    gaps.sort();

    final classifications = _batches.fold<int>(0, (sum, b) => sum + b.n);

    return LiveLoopSummary(
      eventsPerSecond: eventSpan == 0 ? 0 : (_events.length - 1) / eventSpan,
      updatesPerSecond: updateSpan == 0 ? 0 : (_updates.length - 1) / updateSpan,
      gapP50Ms: _nearestRank(gaps, 0.50),
      gapP95Ms: _nearestRank(gaps, 0.95),
      gapMaxMs: gaps.isEmpty ? null : gaps.last,
      meanDetections: _events.isEmpty
          ? null
          : _events.fold<int>(0, (sum, e) => sum + e.detections) /
                _events.length,
      classificationsPerSecond: eventSpan == 0 ? 0 : classifications / eventSpan,
      meanBatchMs: _batches.isEmpty
          ? null
          : _batches.fold<int>(0, (sum, b) => sum + b.elapsed.inMicroseconds) /
                _batches.length /
                1000,
    );
  }

  void _prune(DateTime now) {
    final cutoff = now.subtract(window);
    while (_events.isNotEmpty && _events.first.at.isBefore(cutoff)) {
      _events.removeFirst();
    }
    while (_updates.isNotEmpty && _updates.first.isBefore(cutoff)) {
      _updates.removeFirst();
    }
    while (_batches.isNotEmpty && _batches.first.at.isBefore(cutoff)) {
      _batches.removeFirst();
    }
  }

  static double _spanSeconds(Iterable<DateTime> times) {
    if (times.length < 2) return 0;
    return times.last.difference(times.first).inMicroseconds / 1e6;
  }

  /// Nearest-rank percentile of an already-sorted list.
  static int? _nearestRank(List<int> sorted, double p) {
    if (sorted.isEmpty) return null;
    final rank = (p * sorted.length).ceil().clamp(1, sorted.length);
    return sorted[rank - 1];
  }
}
