import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:ultralytics_yolo/ultralytics_yolo.dart';

import '../tracking/bot_sort_tracker.dart';
import '../tracking/strack.dart';
import '../tracking/tracker_detection.dart';
import 'bleaching_classifier.dart';
import 'classification_policy.dart';
import 'classification_scheduler.dart';
import 'crop_geometry.dart';
import 'live_loop_metrics.dart';

/// What a detection carries through [BoTSortTracker] as its opaque
/// `payload`: the segmentation mask and the box it was detected at. Health
/// no longer rides on the payload (sub-plan 09, step 2) -- it's classified
/// later, by track id, through [ClassificationScheduler].
class LiveDetectionPayload {
  const LiveDetectionPayload({
    required this.box,
    this.mask,
    this.score = 1.0,
  });

  final Rect box;
  final List<List<double>>? mask;

  /// The segmentation confidence of this detection, gated against
  /// `ClassificationPolicy.classifySegFloor` before classifying (sub-plan 10).
  final double score;
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
    this.cropStyle = CropStyle.insideMaskSquare,
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

  /// How classifier crops are cut (sub-plan 10). Fixed per session, like
  /// [useLegacyLoop]. Ignored by the legacy loop, which keeps its old crop.
  final CropStyle cropStyle;

  final DateTime Function() _now;
  late final ClassificationScheduler _scheduler;

  /// After an insufficient view, how long before that track's crop is tried
  /// again. Much shorter than `reclassifyEvery` -- the colony may come into
  /// full view a moment later -- but long enough that a colony sitting
  /// half-out of frame isn't re-cropped (distance transform + coverage) on
  /// every 8 Hz event, and the overlay's `skip` counts samples, not events.
  static const insufficientViewRetry = Duration(milliseconds: 250);
  final Map<int, DateTime> _insufficientRetryAt = {};

  /// Called after every tracker update with the tracker's current tracks.
  /// Each one's `payload` is a [LiveDetectionPayload] from this frame.
  final void Function(List<STrack> tracks) onTracks;

  /// Called with each classification result, by track id, timestamped with
  /// the frame it was sampled from. Carries the crop and context photo it
  /// came from (sub-plan 18).
  final void Function(int trackId, ClassifiedCrop result, DateTime sampledAt)
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

    // A busy scheduler would refuse the offer anyway, so skip the crop work.
    if (frame == null || _scheduler.isBusy) return;
    final sampledAt = _now();
    _scheduler.offer(
      frameBytes: frame.bytes,
      frameWidth: frame.width,
      frameHeight: frame.height,
      candidates: _candidates(tracks, frame.width, frame.height, sampledAt),
      sampledAt: sampledAt,
    );
  }

  /// This frame's classifiable tracks, each with the crop window to classify
  /// (sub-plan 10, steps 1-2). A track is a candidate only if it is
  /// confirmed, its detection scored at least `classifySegFloor`, and it is
  /// due; its crop is then cut under [cropStyle]. An `insideMaskSquare` crop
  /// with no usable mask, or coverage below `minCoverage`, is "insufficient
  /// view": not classified and not stamped as attempted, so the track stays
  /// due and is retried after [insufficientViewRetry].
  List<ClassificationCandidate> _candidates(
    List<STrack> tracks,
    int frameWidth,
    int frameHeight,
    DateTime at,
  ) {
    final candidates = <ClassificationCandidate>[];
    for (final track in tracks) {
      final payload = track.payload;
      if (!track.isActivated || payload is! LiveDetectionPayload) continue;
      if (payload.score < ClassificationPolicy.classifySegFloor) continue;
      if (!_scheduler.isDue(track.trackId, at)) continue;
      final retryAt = _insufficientRetryAt[track.trackId];
      if (retryAt != null && at.isBefore(retryAt)) continue;

      final crop = computeClassifierCrop(
        style: cropStyle,
        box: payload.box,
        mask: payload.mask,
        frameWidth: frameWidth,
        frameHeight: frameHeight,
      );
      if (crop == null ||
          (cropStyle == CropStyle.insideMaskSquare &&
              crop.coverage < ClassificationPolicy.minCoverage)) {
        metrics?.recordInsufficientView();
        _insufficientRetryAt[track.trackId] = at.add(insufficientViewRetry);
        continue;
      }
      candidates.add(
        ClassificationCandidate(
          trackId: track.trackId,
          box: crop.window,
          contextBox: payload.box,
        ),
      );
    }
    return candidates;
  }

  Future<void> _handleLegacy(
    List<TrackerDetection> detections,
    ({Uint8List bytes, int width, int height}) frame,
  ) async {
    final healthByPayload = <LiveDetectionPayload, ClassifiedCrop>{};
    for (final detection in detections) {
      final payload = detection.payload! as LiveDetectionPayload;
      final startedAt = _now();
      try {
        final results = await _classify(
          frame.bytes,
          [payload.box],
          frameWidth: frame.width,
          frameHeight: frame.height,
          contextBoxes: [payload.box],
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
            payload: LiveDetectionPayload(
              box: r.boundingBox,
              mask: r.mask,
              score: r.confidence,
            ),
          ),
        )
        .toList(growable: false);
  }
}
