import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart' show debugPrint;

import 'bleaching_classifier.dart';

/// A confirmed, currently-tracked colony that could be classified this
/// frame: its track id and the box it was detected at *in this frame*.
class ClassificationCandidate {
  const ClassificationCandidate({required this.trackId, required this.box});

  final int trackId;
  final Rect box;
}

/// Classifies every box in [boxes] against one frame -- see
/// [BleachingClassifier.classifyBatch]. One result per box, `null` where
/// that box couldn't be classified.
typedef BatchClassify =
    Future<List<ColonyHealth?>> Function(
      Uint8List frameBytes,
      List<Rect> boxes, {
      required int frameWidth,
      required int frameHeight,
    });

/// Decides which tracks get classified and when, off the tracker's critical
/// path (sub-plan 09, step 3).
///
/// Before this, every detection in every processed frame was classified
/// before the tracker could update, so the tracker waited on the classifier
/// and every colony was reclassified on every frame. Now the tracker updates
/// first and calls [offer], which never waits:
/// - A track is *due* if it has never been attempted, or its last attempt
///   was at least [reclassifyEvery] ago (seconds, not frames, so it doesn't
///   depend on the update rate).
/// - At most [maxPerFrame] due tracks per batch: never-attempted tracks
///   first, then the longest-waiting.
/// - At most one batch in flight. While one runs, [offer] starts nothing --
///   tracks not picked stay due for a later frame.
///
/// "Attempted" is stamped when a batch *starts*, so a failed or `null`
/// classification also waits [reclassifyEvery] before being retried rather
/// than taking the next batch's slot again.
///
/// Results go to [onResult] by track id, timestamped with the frame they
/// were sampled from. A result for a track that has since been lost or
/// removed is still delivered: it's a real sample of that colony, and
/// session finalize persists removed tracks too. Only [close] stops delivery.
class ClassificationScheduler {
  ClassificationScheduler({
    required BatchClassify classify,
    required this.onResult,
    this.reclassifyEvery = const Duration(seconds: 1),
    this.maxPerFrame = 3,
    this.onBatchComplete,
    DateTime Function()? now,
  }) : _classify = classify,
       _now = now ?? DateTime.now;

  final BatchClassify _classify;
  final void Function(int trackId, ColonyHealth health, DateTime sampledAt)
  onResult;
  final Duration reclassifyEvery;
  final int maxPerFrame;

  /// Batch wall time and number of boxes in it, for `LiveLoopMetrics`.
  final void Function(Duration elapsed, int classifications)? onBatchComplete;

  final DateTime Function() _now;

  final Map<int, DateTime> _lastAttemptAt = {};
  Future<void>? _inFlight;
  bool _closed = false;

  bool get isBusy => _inFlight != null;

  /// The track ids [offer] would classify from [candidates] at [at], in
  /// priority order. Doesn't consider whether a batch is in flight.
  List<int> selectDue(List<ClassificationCandidate> candidates, DateTime at) {
    final neverAttempted = <int>[];
    final overdue = <({int trackId, DateTime last})>[];
    for (final candidate in candidates) {
      final last = _lastAttemptAt[candidate.trackId];
      if (last == null) {
        neverAttempted.add(candidate.trackId);
      } else if (at.difference(last) >= reclassifyEvery) {
        overdue.add((trackId: candidate.trackId, last: last));
      }
    }
    overdue.sort((a, b) => a.last.compareTo(b.last));

    return [
      ...neverAttempted,
      ...overdue.map((o) => o.trackId),
    ].take(maxPerFrame).toList(growable: false);
  }

  /// Starts a classification batch for this frame's due tracks, unless one
  /// is already running, nothing is due, or the scheduler is closed. Returns
  /// whether a batch started. Never waits on the batch itself.
  bool offer({
    required Uint8List frameBytes,
    required int frameWidth,
    required int frameHeight,
    required List<ClassificationCandidate> candidates,
    required DateTime sampledAt,
  }) {
    if (_closed || _inFlight != null) return false;

    final due = selectDue(candidates, sampledAt);
    if (due.isEmpty) return false;

    final boxById = {for (final c in candidates) c.trackId: c.box};
    for (final id in due) {
      _lastAttemptAt[id] = sampledAt;
    }

    _inFlight = _runBatch(
      frameBytes,
      due,
      [for (final id in due) boxById[id]!],
      frameWidth: frameWidth,
      frameHeight: frameHeight,
      sampledAt: sampledAt,
    ).whenComplete(() => _inFlight = null);
    return true;
  }

  Future<void> _runBatch(
    Uint8List frameBytes,
    List<int> trackIds,
    List<Rect> boxes, {
    required int frameWidth,
    required int frameHeight,
    required DateTime sampledAt,
  }) async {
    final startedAt = _now();
    List<ColonyHealth?> results;
    try {
      results = await _classify(
        frameBytes,
        boxes,
        frameWidth: frameWidth,
        frameHeight: frameHeight,
      );
    } catch (error) {
      debugPrint('ReefSight: classification batch failed: $error');
      return;
    }
    // Callbacks run inside a try too: an exception escaping here would
    // otherwise leave `_inFlight` completing with an error nobody listens to,
    // and make `close()` rethrow -- skipping the classifier's dispose.
    try {
      // Only crops that actually produced a label count, so a classifier
      // that isn't loaded yet (all nulls, instantly) doesn't inflate the
      // measured classifications/s and batch time.
      final classified = results.where((r) => r != null).length;
      if (classified > 0) {
        onBatchComplete?.call(_now().difference(startedAt), classified);
      }
      if (_closed) return;

      for (var i = 0; i < trackIds.length && i < results.length; i++) {
        final health = results[i];
        if (health != null) onResult(trackIds[i], health, sampledAt);
      }
    } catch (error) {
      debugPrint('ReefSight: classification result handling failed: $error');
    }
  }

  /// Refuses further [offer]s and drops any in-flight batch's results.
  /// Completes once that batch (if any) has finished, so the classifier can
  /// be disposed safely afterwards. Never throws.
  Future<void> close() async {
    _closed = true;
    try {
      await _inFlight;
    } catch (_) {
      // `_runBatch` already logs; close() must still let dispose proceed.
    }
  }
}
