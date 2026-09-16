import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';

import '../services/bleaching_classifier.dart';
import '../services/colony_size.dart';
import '../services/health_aggregator.dart';
import '../services/model_assets.dart';
import '../services/transect_recorder.dart';
import '../tracking/bot_sort_tracker.dart';
import '../tracking/strack.dart';
import '../tracking/tracker_detection.dart';

/// Live segmentation + crop-classify + tracking screen (sub-plan 3:
/// `mobile/sub-plans/03-crop-classify-and-tracking.md`).
///
/// Per frame: every segmentation box is classified (no longer just the top
/// one -- that simplification was sub-plan 1's, before a tracker existed to
/// give each detection a stable identity), then all of this frame's
/// detections -- each carrying its own mask + health as an opaque payload --
/// feed [BoTSortTracker.update]. There is no separate matching/alignment
/// step: a detection's payload is exactly the mask/health that came from the
/// same segmentation box the tracker is matching by geometry, so whichever
/// output [STrack] a detection matches, its payload comes along for free
/// (see `tracking/strack.dart`'s `payload` field).
///
/// Recording (sub-plan 3 step 1) runs through [TransectRecorder], wired to
/// the forked `ultralytics_yolo` plugin's native recorder
/// (`third_party/ultralytics_yolo`, see its `PATCH.md`) -- independent of
/// this screen's classify/tracking logic, so a caught exception here can't
/// stop the recording.
class LiveTransectScreen extends StatefulWidget {
  const LiveTransectScreen({super.key});

  @override
  State<LiveTransectScreen> createState() => _LiveTransectScreenState();
}

/// One frame's mask + health for a single detection, carried opaquely
/// through the tracker via [TrackerDetection.payload] / [STrack.payload].
class _DetectionPayload {
  const _DetectionPayload({this.mask, this.health});

  final List<List<double>>? mask;
  final ColonyHealth? health;
}

class _LiveTransectScreenState extends State<LiveTransectScreen> {
  final _classifier = BleachingClassifier(
    modelAssetPath: ModelAssets.nmfsOsiBleachingClassifier,
  );
  final _yoloController = YOLOViewController();
  final _tracker = BoTSortTracker();
  final _healthAggregator = HealthAggregator();
  late final TransectRecorder _recorder;

  // Compute-budget guard (Spec Open Item #1): never let a new frame's
  // classify+track round start while the previous one is still running.
  // Classifying every detection in a frame (not just the top one, now that
  // there's a tracker to give each a stable identity) means this round's
  // duration scales with detection count per frame -- acceptable for the
  // sparse, non-overlapping colonies this project targets, but flagged here
  // since it hasn't been stress-tested with many colonies in frame at once
  // (Spec's "Open risk").
  bool _isProcessing = false;

  double? _segProcessingMs;
  List<STrack> _latestTracks = const [];
  final Map<int, double> _latestSizePx = {};
  String? _segmentationError;
  String? _recordingError;

  @override
  void initState() {
    super.initState();
    _recorder = TransectRecorder(
      startRecording: _yoloController.startRecording,
      stopRecording: _yoloController.stopRecording,
    );
    _classifier.load().catchError((Object error) {
      debugPrint('ReefSight: classifier failed to load: $error');
    });
    _startRecording();
  }

  Future<void> _startRecording() async {
    try {
      final documentsDir = await getApplicationDocumentsDirectory();
      await _recorder.start(documentsDir.path);
    } catch (error) {
      debugPrint('ReefSight: failed to start recording: $error');
      if (mounted) setState(() => _recordingError = error.toString());
    }
  }

  @override
  void dispose() {
    // Fire-and-forget: dispose() can't be async. Errors are logged, not
    // surfaced to UI that's about to be torn down anyway.
    _recorder.stop().catchError((Object error) {
      debugPrint('ReefSight: failed to stop recording: $error');
    });
    _classifier.dispose().catchError((Object error) {
      debugPrint('ReefSight: failed to dispose classifier: $error');
    });
    _yoloController.dispose();
    super.dispose();
  }

  void _handleStreamingData(Map<String, dynamic> event) async {
    final segProcessingMs = (event['processingTimeMs'] as num?)?.toDouble();
    if (segProcessingMs != null && mounted) {
      setState(() => _segProcessingMs = segProcessingMs);
    }

    if (_isProcessing) return;

    final detectionsRaw = event['detections'] as List<dynamic>?;
    final frameBytes = event['originalImage'] as Uint8List?;
    final frameWidth = event['imageWidth'] as int?;
    final frameHeight = event['imageHeight'] as int?;
    if (detectionsRaw == null ||
        detectionsRaw.isEmpty ||
        frameBytes == null ||
        frameWidth == null ||
        frameHeight == null) {
      return;
    }

    // TrackerDetection requires a strictly positive width/height (its own
    // doc comment: a degenerate box reaches KalmanFilter.initiate() as zero
    // variance and divides by zero in linalg.invert() instead of failing
    // loudly) -- filtered here rather than trusted from the raw model
    // output, since crop_geometry.dart's own floor/ceil clamping (used for
    // the classify crop) doesn't apply to this raw float box.
    final detections = detectionsRaw
        .whereType<Map>()
        .map(YOLOResult.fromMap)
        .where((r) => r.boundingBox.width > 0 && r.boundingBox.height > 0)
        .toList(growable: false);
    if (detections.isEmpty) return;

    _isProcessing = true;
    try {
      final trackerDetections = <TrackerDetection>[];
      for (final result in detections) {
        ColonyHealth? health;
        try {
          health = await _classifier.classifyCrop(
            frameBytes,
            result.boundingBox,
            frameWidth: frameWidth,
            frameHeight: frameHeight,
          );
        } catch (error) {
          debugPrint('ReefSight: classifyCrop failed for one detection: $error');
        }
        trackerDetections.add(
          TrackerDetection(
            x1: result.boundingBox.left,
            y1: result.boundingBox.top,
            x2: result.boundingBox.right,
            y2: result.boundingBox.bottom,
            score: result.confidence,
            payload: _DetectionPayload(mask: result.mask, health: health),
          ),
        );
      }

      final tracks = _tracker.update(trackerDetections);

      // Aggregator/size mutations happen inside the same setState block as
      // the rebuild trigger so they stay atomic with what's displayed --
      // splitting them (mutate, then separately setState) would let a
      // future early-return between the two show stale data.
      if (mounted) {
        setState(() {
          _latestTracks = tracks;
          for (final track in tracks) {
            final payload = track.payload;
            if (payload is! _DetectionPayload) continue;

            _healthAggregator.record(track.trackId, payload.health);

            final mask = payload.mask;
            if (mask != null) {
              final box = track.tlwh;
              _latestSizePx[track.trackId] = maskAreaPixels(
                mask,
                boxWidthPx: box[2],
                boxHeightPx: box[3],
              );
            }
          }
        });
      }
    } finally {
      _isProcessing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          YOLOView(
            controller: _yoloController,
            modelPath: ModelAssets.coralvosPrimarySegmentation,
            task: YOLOTask.segment,
            streamingConfig: const YOLOStreamingConfig.custom(
              includeOriginalImage: true,
              // Per-instance masks (mask-derived size, sub-plan 3 task 6)
              // are opt-in -- without this, YOLOResult.mask stays null.
              includeMasks: true,
              // Caps both inference and how often a full camera frame is
              // shipped over the platform channel -- Spec's "Target: 5-8
              // fps" (ReefSight_Specification.md:88), not an arbitrary
              // number.
              inferenceFrequency: 8,
            ),
            onStreamingData: _handleStreamingData,
            onModelError: (error, modelPath, task) {
              debugPrint(
                'ReefSight: segmentation model error for $modelPath ($task): $error',
              );
              if (mounted) setState(() => _segmentationError = error.toString());
            },
            onModelLoad: (modelPath, task) {
              debugPrint('ReefSight: segmentation model loaded: $modelPath ($task)');
              if (mounted) setState(() => _segmentationError = null);
            },
          ),
          Positioned(
            left: 12,
            bottom: 12,
            child: SafeArea(
              child: _PerformanceAndTracksOverlay(
                segProcessingMs: _segProcessingMs,
                tracks: _latestTracks,
                healthAggregator: _healthAggregator,
                sizesPx: _latestSizePx,
                segmentationError: _segmentationError,
                recordingError: _recordingError,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PerformanceAndTracksOverlay extends StatelessWidget {
  const _PerformanceAndTracksOverlay({
    required this.segProcessingMs,
    required this.tracks,
    required this.healthAggregator,
    required this.sizesPx,
    required this.segmentationError,
    required this.recordingError,
  });

  final double? segProcessingMs;
  final List<STrack> tracks;
  final HealthAggregator healthAggregator;
  final Map<int, double> sizesPx;
  final String? segmentationError;
  final String? recordingError;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'seg: ${segProcessingMs?.toStringAsFixed(1) ?? '--'}ms   '
            'tracks: ${tracks.length}',
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
          for (final track in tracks)
            Text(
              '#${track.trackId}: '
              '${healthAggregator.currentLabel(track.trackId) ?? '--'} '
              '(${sizesPx[track.trackId]?.toStringAsFixed(0) ?? '--'}px²)',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          if (segmentationError != null)
            Text(
              'Segmentation model error: $segmentationError',
              style: const TextStyle(color: Colors.redAccent, fontSize: 12),
            ),
          if (recordingError != null)
            Text(
              'Recording error: $recordingError',
              style: const TextStyle(color: Colors.redAccent, fontSize: 12),
            ),
        ],
      ),
    );
  }
}
