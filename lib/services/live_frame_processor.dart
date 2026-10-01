import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:ultralytics_yolo/ultralytics_yolo.dart';

import '../tracking/bot_sort_tracker.dart';
import '../tracking/strack.dart';
import '../tracking/tracker_detection.dart';
import 'bleaching_classifier.dart';
import 'classification_scheduler.dart';
import 'live_loop_metrics.dart';

/// What a detection carries through [BoTSortTracker] as its opaque
/// `payload`: the segmentation mask and the box it was detected at. Health
/// no longer rides on the payload (sub-plan 09, step 2) -- it's classified
/// later, by track id, through [ClassificationScheduler].
class LiveDetectionPayload {
  const LiveDetectionPayload({required this.box, this.mask});

  final Rect box;
  final List<List<double>>? mask;
}

/// The live screen's per-streaming-event logic (sub-plan 09), kept out of
/// the widget so it can be driven from tests without the native `YOLOView`.
///
/// Decoupled loop (the default): every event -- including one with no
/// detections -- goes straight to [BoTSortTracker.update], synchronously,
/// so lost tracks age and the Kalman filter predicts forward at the stream's
/// own rate and `trackBuffer` keeps meaning a fixed amount of time. Only
/// then are this frame's confirmed tracks offered to a
/// [ClassificationScheduler], which never makes the next event wait.
///
/// Legacy loop ([useLegacyLoop], a debug-only baseline, fixed per session):
/// the pre-sub-plan-09 behaviour, kept so one device can measure before
/// *and* after.
/// Events that arrive while the previous one is still being classified are
/// dropped, empty frames never reach the tracker, and every detection is
/// classified in turn (one decode per detection) before the tracker update.
/// Remove it once sub-plan 09's measurements are recorded.
class LiveFrameProcessor {
  LiveFrameProcessor({
    required BoTSortTracker tracker,
    required BatchClassify classify,
    required this.onTracks,
    required this.onHealth,
    this.metrics,
    this.useLegacyLoop = false,
    Duration reclassifyEvery = const Duration(seconds: 1),
    int maxPerFrame = 3,
    DateTime Function()? now,
  }) : _tracker = tracker,
       _classify = classify,
       _now = now ?? DateTime.now {
    _scheduler = ClassificationScheduler(
      classify: classify,
      onResult: onHealth,
      reclassifyEvery: reclassifyEvery,
      maxPerFrame: maxPerFrame,
      onBatchComplete: (elapsed, n) =>
          metrics?.recordBatch(elapsed: elapsed, classifications: n),
      now: _now,
    );
  }

  final BoTSortTracker _tracker;
  final BatchClassify _classify;

  /// Fixed for the processor's lifetime (one Live session): switching loops
  /// mid-session could let a stale legacy update rewind the tracker after
  /// newer decoupled ones, and run two classifier calls at once.
  final bool useLegacyLoop;
  final DateTime Function() _now;
  late final ClassificationScheduler _scheduler;

  /// Called after every tracker update with the tracker's current tracks.
  /// Each one's `payload` is a [LiveDetectionPayload] from this frame.
  final void Function(List<STrack> tracks) onTracks;

  /// Called with each classification result, by track id, timestamped with
  /// the frame it was sampled from.
  final void Function(int trackId, ColonyHealth health, DateTime sampledAt)
  onHealth;

  final LiveLoopMetrics? metrics;

  bool _closed = false;
  Future<void>? _legacyInFlight;

  /// Handles one `YOLOView.onStreamingData` event. Returns as soon as the
  /// tracker has been updated (decoupled loop) -- classification carries on
  /// in the background.
  void handleEvent(Map<String, dynamic> event) {
    if (_closed) return;

    final detections = _parseDetections(event['detections']);
    metrics?.recordEvent(detectionCount: detections.length);

    final frameBytes = event['originalImage'] as Uint8List?;
    final frameWidth = event['imageWidth'] as int?;
    final frameHeight = event['imageHeight'] as int?;
    final frame = frameBytes == null || frameWidth == null || frameHeight == null
        ? null
        : (bytes: frameBytes, width: frameWidth, height: frameHeight);

    if (useLegacyLoop) {
      if (_legacyInFlight != null || detections.isEmpty || frame == null) {
        return;
      }
      _legacyInFlight = _handleLegacy(detections, frame).whenComplete(
        () => _legacyInFlight = null,
      );
      return;
    }

    final tracks = _tracker.update(detections);
    metrics?.recordTrackerUpdate();
    onTracks(tracks);

    if (frame == null) return;
    _scheduler.offer(
      frameBytes: frame.bytes,
      frameWidth: frame.width,
      frameHeight: frame.height,
      candidates: [
        for (final track in tracks)
          if (track.isActivated && track.payload is LiveDetectionPayload)
            ClassificationCandidate(
              trackId: track.trackId,
              box: (track.payload! as LiveDetectionPayload).box,
            ),
      ],
      sampledAt: _now(),
    );
  }

  Future<void> _handleLegacy(
    List<TrackerDetection> detections,
    ({Uint8List bytes, int width, int height}) frame,
  ) async {
    final healthByPayload = <LiveDetectionPayload, ColonyHealth>{};
    for (final detection in detections) {
      final payload = detection.payload! as LiveDetectionPayload;
      final startedAt = _now();
      try {
        final results = await _classify(
          frame.bytes,
          [payload.box],
          frameWidth: frame.width,
          frameHeight: frame.height,
        );
        final health = results.isEmpty ? null : results.first;
        if (health != null) healthByPayload[payload] = health;
      } catch (error) {
        debugPrint('ReefSight: classifyCrop failed for one detection: $error');
      }
      metrics?.recordBatch(
        elapsed: _now().difference(startedAt),
        classifications: 1,
      );
    }
    if (_closed) return;

    try {
      final tracks = _tracker.update(detections);
      metrics?.recordTrackerUpdate();
      onTracks(tracks);

      final sampledAt = _now();
      for (final track in tracks) {
        final health = healthByPayload[track.payload];
        if (health != null) onHealth(track.trackId, health, sampledAt);
      }
    } catch (error) {
      debugPrint('ReefSight: legacy live loop update failed: $error');
    }
  }

  /// Ignores further events and drops in-flight classification results.
  /// Completes once in-flight classification has finished, so the
  /// classifier can be disposed safely afterwards. Never throws.
  Future<void> close() async {
    _closed = true;
    await _scheduler.close();
    try {
      await _legacyInFlight;
    } catch (_) {
      // `_handleLegacy` already logs; close() must still let dispose proceed.
    }
  }

  /// Parses the plugin's raw detection maps into tracker detections.
  ///
  /// [TrackerDetection] requires a strictly positive width/height (its own
  /// doc comment: a degenerate box reaches `KalmanFilter.initiate()` as zero
  /// variance and divides by zero in `linalg.invert()` instead of failing
  /// loudly), so degenerate boxes are filtered here rather than trusted from
  /// the raw model output.
  static List<TrackerDetection> _parseDetections(Object? raw) {
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map(YOLOResult.fromMap)
        .where((r) => r.boundingBox.width > 0 && r.boundingBox.height > 0)
        .map(
          (r) => TrackerDetection(
            x1: r.boundingBox.left,
            y1: r.boundingBox.top,
            x2: r.boundingBox.right,
            y2: r.boundingBox.bottom,
            score: r.confidence,
            payload: LiveDetectionPayload(box: r.boundingBox, mask: r.mask),
          ),
        )
        .toList(growable: false);
  }
}
