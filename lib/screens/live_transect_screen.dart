import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';

import '../constants/app_colors.dart';
import '../services/bleaching_classifier.dart';
import '../services/colony_size.dart';
import '../services/health_aggregator.dart';
import '../services/health_history_recorder.dart';
import '../services/mask_storage.dart';
import '../services/model_assets.dart';
import '../services/tracked_colony_record.dart';
import '../services/transect_database.dart';
import '../services/transect_recorder.dart';
import '../services/transect_session.dart';
import '../tracking/bot_sort_tracker.dart';
import '../tracking/strack.dart';
import '../tracking/tracker_detection.dart';
import 'summary_screen.dart';

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
  const LiveTransectScreen({
    super.key,
    required this.tapeLengthMeters,
    this.siteName,
    this.observerName,
  });

  /// Physical marked transect tape length, collected up front by
  /// `TransectSetupScreen` (sub-plan 5) -- this screen no longer prompts
  /// for it itself, since diving straight into the camera/segmentation view
  /// before that's known left no natural place for a blocking dialog that
  /// also felt right on a glove-operated touchscreen.
  final double tapeLengthMeters;
  final String? siteName;
  final String? observerName;

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
  final _healthHistoryRecorder = HealthHistoryRecorder();
  late final TransectRecorder _recorder;

  // Sub-plan 4 (storage-and-metrics): populated once `_startSession()`
  // resolves the diver-entered tape length and opens the on-device DB.
  // `_firstSeenAt`'s key set is the authoritative "every track this session
  // ever saw" list used at session-stop finalize (task 7) -- it's set the
  // moment a track id first appears, regardless of whether health/size/mask
  // data was ever successfully captured for it.
  TransectDatabase? _db;
  int? _sessionId;
  final Map<int, DateTime> _firstSeenAt = {};
  final Map<int, DateTime> _lastSeenAt = {};
  final Map<int, List<List<double>>> _latestMasks = {};
  String? _persistError;

  // `_startSession()` runs fire-and-forget from a post-frame callback, and
  // can still be mid-flight (awaiting the dialog, the DB open, or the
  // insert) when `dispose()` runs -- without tracking it, dispose()'s
  // finalize could run before _db/_sessionId are even set (silently
  // dropping the session and leaking the DB handle `_startSession` goes on
  // to open), and `_startRecording()` could fire after `_recorder.stop()`
  // already ran. `_disposed` lets `_startSession` bail out of its own
  // remaining work; `_sessionStartFuture` lets dispose() defer finalize
  // until `_startSession` has actually finished setting `_db`/`_sessionId`.
  bool _disposed = false;
  Future<void>? _sessionStartFuture;

  // Guards `_finalizeSession()` against running twice: the diver's explicit
  // "End Transect" button (below) and `dispose()`'s own finalize chain can
  // now both reach it (e.g. the button runs it, then the resulting
  // `Navigator.pop`/screen teardown triggers `dispose()`, whose chain would
  // otherwise re-run it). `TransectRecorder.stop()` is already idempotent
  // (a no-op once stopped); this makes finalize idempotent the same way.
  bool _finalized = false;

  // Guards `_endTransect()` (below) against double-tap; also lets the UI
  // show a busy state on the button.
  bool _endingTransect = false;
  String? _endTransectError;

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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _sessionStartFuture = _startSession();
    });
  }

  /// Opens the on-device DB and inserts the session row (tape length +
  /// site/observer metadata already collected by `TransectSetupScreen`
  /// before this screen was pushed) -- then starts recording regardless of
  /// whether that succeeded, since recording (sub-plan 3) is deliberately
  /// independent of the storage layer's own failures.
  ///
  /// Checks [_disposed] after every await: if the screen was torn down
  /// while this was still in flight, `dispose()` has already stopped the
  /// recorder (starting it now would leave an orphaned recording) and is
  /// waiting on [_sessionStartFuture] to run finalize itself (bailing here
  /// without setting `_db`/`_sessionId` would otherwise leak the DB handle
  /// and silently drop the session).
  Future<void> _startSession() async {
    TransectDatabase? db;
    try {
      final documentsDir = await getApplicationDocumentsDirectory();
      db = await TransectDatabase.open(documentsDir.path);
      final sessionId = await db.insertSession(
        TransectSession(
          startedAt: DateTime.now().toUtc(),
          tapeLengthMeters: widget.tapeLengthMeters,
          siteName: widget.siteName,
          observerName: widget.observerName,
        ),
      );
      _db = db;
      _sessionId = sessionId;
    } catch (error) {
      await db?.close();
      debugPrint('ReefSight: failed to start transect session: $error');
      if (mounted) setState(() => _persistError = error.toString());
    }

    if (_disposed) return;
    await _startRecording();
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
    _disposed = true;

    // Fire-and-forget: dispose() can't be async. Errors are logged, not
    // surfaced to UI that's about to be torn down anyway.
    _recorder.stop().catchError((Object error) {
      debugPrint('ReefSight: failed to stop recording: $error');
    });

    // Chained after `_sessionStartFuture` rather than called directly: if
    // `_startSession()` is still awaiting its dialog/DB-open/insert, running
    // finalize now would see `_db`/`_sessionId` still null and no-op,
    // silently dropping the session once `_startSession()` finishes and
    // sets them afterward. Waiting for that future first guarantees
    // finalize sees whatever `_startSession()` ultimately set (including
    // "never started," which is still a correct no-op).
    (_sessionStartFuture ?? Future.value()).then((_) => _finalizeSession()).catchError(
      (Object error) {
        debugPrint('ReefSight: failed to finalize transect session: $error');
      },
    );

    _classifier.dispose().catchError((Object error) {
      debugPrint('ReefSight: failed to dispose classifier: $error');
    });
    _yoloController.dispose();
    super.dispose();
  }

  /// Persists every track this session ever saw (`_firstSeenAt`'s key set)
  /// as a finalized [TrackedColonyRecord], then closes the session and the
  /// DB handle. A no-op if [_startSession] never got as far as opening a DB
  /// (e.g. the diver never entered a tape length).
  Future<void> _finalizeSession() async {
    if (_finalized) return;
    _finalized = true;

    final db = _db;
    final sessionId = _sessionId;
    if (db == null || sessionId == null) return;

    try {
      final documentsDir = await getApplicationDocumentsDirectory();
      for (final trackId in _firstSeenAt.keys) {
        final mask = _latestMasks[trackId];
        final maskPath = mask == null
            ? null
            : await MaskStorage.save(
                outputDirectory: documentsDir.path,
                sessionId: sessionId,
                trackId: trackId,
                mask: mask,
              );

        await db.upsertColony(
          TrackedColonyRecord(
            sessionId: sessionId,
            trackId: trackId,
            healthLabel: _healthAggregator.currentLabel(trackId),
            healthHistory: _healthHistoryRecorder.samplesFor(trackId),
            sizePx: _latestSizePx[trackId],
            firstSeenAt: _firstSeenAt[trackId]!,
            lastSeenAt: _lastSeenAt[trackId]!,
            maskPath: maskPath,
          ),
        );
      }
      await db.closeSession(sessionId, DateTime.now().toUtc());
    } finally {
      await db.close();
    }
  }

  /// Diver-initiated "End Transect" -- stops recording, finalizes and
  /// closes the session (reusing [_finalizeSession], guarded against the
  /// double-run `dispose()` would otherwise cause once this screen pops),
  /// then hands off to [SummaryScreen] for the session just closed. Falls
  /// back to a plain pop if no session was ever opened (e.g. storage
  /// failed at start) -- there's nothing for Summary to load in that case.
  ///
  /// Awaits [_sessionStartFuture] first, exactly like `dispose()` does --
  /// without this, tapping the button while `_startSession()` is still
  /// mid-flight would read `_sessionId` as `null` (falling back to a plain
  /// pop instead of opening Summary) *and* set [_finalized] before
  /// `_startSession()` ever sets `_db`/`_sessionId`, so neither this call
  /// nor `dispose()`'s own deferred finalize would ever persist the
  /// session -- silent data loss, not a visible failure.
  Future<void> _endTransect() async {
    if (_endingTransect) return;
    setState(() {
      _endingTransect = true;
      _endTransectError = null;
    });

    try {
      await (_sessionStartFuture ?? Future.value());
      final sessionId = _sessionId;
      await _recorder.stop();
      await _finalizeSession();

      if (!mounted) return;
      if (sessionId != null) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => SummaryScreen(sessionId: sessionId)),
        );
      } else {
        Navigator.of(context).pop();
      }
    } catch (error) {
      debugPrint('ReefSight: failed to end transect: $error');
      if (mounted) {
        setState(() {
          _endingTransect = false;
          _endTransectError = error.toString();
        });
      }
    }
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
        final now = DateTime.now().toUtc();
        setState(() {
          _latestTracks = tracks;
          for (final track in tracks) {
            _firstSeenAt.putIfAbsent(track.trackId, () => now);
            _lastSeenAt[track.trackId] = now;

            final payload = track.payload;
            if (payload is! _DetectionPayload) continue;

            _healthAggregator.record(track.trackId, payload.health);
            _healthHistoryRecorder.record(track.trackId, payload.health, now);

            final mask = payload.mask;
            if (mask != null) {
              _latestMasks[track.trackId] = mask;
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
                persistError: _persistError,
              ),
            ),
          ),
          // Running tally (Spec's "Live screen" line: "detection/
          // segmentation overlay + a running tally (colonies seen,
          // tentative healthy/bleached count)") -- distinct from the
          // per-track debug overlay above.
          Positioned(
            top: 12,
            right: 12,
            child: SafeArea(
              child: _TallyBadge(
                seenCount: _firstSeenAt.length,
                healthyCount: _firstSeenAt.keys
                    .where((id) =>
                        _healthAggregator.currentLabel(id) ==
                        HealthAggregator.healthyLabel)
                    .length,
                bleachedCount: _firstSeenAt.keys
                    .where((id) =>
                        _healthAggregator.currentLabel(id) ==
                        HealthAggregator.bleachedLabel)
                    .length,
              ),
            ),
          ),
          // Large, glove-friendly tap target (DIVEVOLK SeaTouch housing,
          // Spec's "Diver interaction" note) -- ends the transect and
          // hands off to the report (SummaryScreen).
          Positioned(
            right: 12,
            bottom: 12,
            child: SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (_endTransectError != null)
                    Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      constraints: const BoxConstraints(maxWidth: 220),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        'Failed to end transect: $_endTransectError',
                        style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                      ),
                    ),
                  SizedBox(
                    height: 56,
                    child: ElevatedButton.icon(
                      onPressed: _endingTransect ? null : _endTransect,
                      icon: _endingTransect
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.stop_circle_outlined),
                      label: Text(_endingTransect ? 'Ending...' : 'End Transect'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.bleached,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TallyBadge extends StatelessWidget {
  const _TallyBadge({
    required this.seenCount,
    required this.healthyCount,
    required this.bleachedCount,
  });

  final int seenCount;
  final int healthyCount;
  final int bleachedCount;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.grid_view_rounded, color: Colors.white70, size: 14),
          const SizedBox(width: 6),
          Text(
            '$seenCount seen   ✓$healthyCount   ✗$bleachedCount',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w600,
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
    required this.persistError,
  });

  final double? segProcessingMs;
  final List<STrack> tracks;
  final HealthAggregator healthAggregator;
  final Map<int, double> sizesPx;
  final String? segmentationError;
  final String? recordingError;
  final String? persistError;

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
          if (persistError != null)
            Text(
              'Storage error: $persistError',
              style: const TextStyle(color: Colors.redAccent, fontSize: 12),
            ),
        ],
      ),
    );
  }
}
