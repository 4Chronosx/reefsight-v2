import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';

import '../services/app_settings.dart';
import '../services/bleaching_classifier.dart';
import '../services/colony_size.dart';
import '../services/device_health_monitor.dart';
import '../services/device_info.dart';
import '../services/health_aggregator.dart';
import '../services/health_history_recorder.dart';
import '../services/live_frame_processor.dart';
import '../services/live_loop_metrics.dart';
import '../services/mask_storage.dart';
import '../services/model_assets.dart';
import '../services/screen_awake.dart';
import '../services/session_checkpointer.dart';
import '../services/tracked_colony_record.dart';
import '../services/transect_database.dart';
import '../services/transect_recorder.dart';
import '../services/transect_session.dart';
import '../tracking/bot_sort_tracker.dart';
import '../tracking/strack.dart';
import '../widgets/glove_button.dart';
import '../widgets/live/device_health_badge.dart';
import '../widgets/live/diagnostics_overlay.dart';
import '../widgets/live/end_transect_sheet.dart';
import '../widgets/live/live_error_banner.dart';
import '../widgets/live/recording_indicator.dart';
import '../widgets/live/tally_hud.dart';
import '../widgets/underwater_background.dart';
import 'app_shell.dart';
import 'summary_screen.dart';

/// Live segmentation + crop-classify + tracking screen (sub-plan 3:
/// `mobile/sub-plans/03-crop-classify-and-tracking.md`).
///
/// Per streaming event ([LiveFrameProcessor], sub-plan 09): every frame's
/// detections -- each carrying its own mask + box as an opaque payload --
/// feed [BoTSortTracker.update] straight away, empty frames included. There
/// is no separate matching/alignment step: a detection's payload is exactly
/// the mask/box that came from the same segmentation box the tracker is
/// matching by geometry, so whichever output [STrack] a detection matches,
/// its payload comes along for free (see `tracking/strack.dart`'s `payload`
/// field). Health is classified afterwards, off the tracker's path, by track
/// id: confirmed tracks are cropped from their box in that frame and
/// classified about once a second each (`ClassificationScheduler`).
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
    this.screenAwake = const WakelockScreenAwake(),
    this.storageInfo = const PlatformDeviceInfo(),
    this.batteryInfo = const BatteryPlusInfo(),
    this.thermalInfo = const PlatformDeviceInfo(),
  });

  /// Physical marked transect tape length, collected up front by
  /// `TransectSetupScreen` (sub-plan 5) -- this screen no longer prompts
  /// for it itself, since diving straight into the camera/segmentation view
  /// before that's known left no natural place for a blocking dialog that
  /// also felt right on a glove-operated touchscreen.
  final double tapeLengthMeters;
  final String? siteName;
  final String? observerName;

  /// Keeps the screen from auto-locking for exactly this Live session
  /// (sub-plan 11 step 1). Injectable for tests.
  final ScreenAwake screenAwake;

  /// Storage, battery and heat during Live (sub-plan 13 step 3). Injectable
  /// for consistency with [screenAwake].
  final StorageInfo storageInfo;
  final BatteryInfo batteryInfo;
  final ThermalInfo thermalInfo;

  @override
  State<LiveTransectScreen> createState() => _LiveTransectScreenState();
}

/// One frame's mask + health for a single detection, carried opaquely
/// through the tracker via [TrackerDetection.payload] / [STrack.payload].
class _LiveTransectScreenState extends State<LiveTransectScreen>
    with WidgetsBindingObserver {
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

  // Sub-plan 11 (live session safety). The checkpointer is created once
  // `_startSession` has a DB and session id, and from then on every colony
  // write -- periodic checkpoints and the final one in `_finalizeSession` --
  // goes through its single queue.
  late final ScreenAwakeLease _screenAwake;
  SessionCheckpointer? _checkpointer;

  // Sub-plan 13 step 3: HUD badge, plus the thermal peak and rise count on
  // the session. A change is written through the checkpointer's queue as it
  // happens (so a crash keeps it), and once more at finalize (covering one
  // that landed before `_startSession` created the checkpointer).
  late final DeviceHealthMonitor _deviceHealth;

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

  // Sub-plan 09: per-event tracking + scheduled classification, and the
  // loop timing it's measured by. The compute budget (Spec Open Item #1) is
  // now bounded by the scheduler -- at most `maxPerFrame` crops per batch,
  // one batch in flight -- instead of by dropping whole frames.
  final _loopMetrics = LiveLoopMetrics();
  late final LiveFrameProcessor _frameProcessor;
  LiveLoopSummary? _loopSummary;
  DateTime? _lastLoopLogAt;

  double? _segProcessingMs;
  List<STrack> _latestTracks = const [];
  final Map<int, double> _latestSizePx = {};
  String? _segmentationError;
  String? _recordingError;

  // --- Sub-plan 6 (ui-ux-overhaul), step 6: presentation-only state. None
  // of this feeds `_handleStreamingData`, `_startSession`, or
  // `_finalizeSession` -- it only drives the HUD (decision 5).
  bool _modelLoaded = false;
  final _liveStartedAt = DateTime.now();
  Timer? _tickTimer;

  @override
  void initState() {
    super.initState();
    // Sub-plan 11: no auto-lock mid-transect, and a checkpoint the moment
    // the app leaves the foreground (`didChangeAppLifecycleState`).
    _screenAwake = ScreenAwakeLease(widget.screenAwake)..acquire();
    _deviceHealth = DeviceHealthMonitor(
      storage: widget.storageInfo,
      battery: widget.batteryInfo,
      thermal: widget.thermalInfo,
      onThermalChange: (peak, rises) => _checkpointer?.recordThermal(peak, rises),
    )..start();
    WidgetsBinding.instance.addObserver(this);
    _recorder = TransectRecorder(
      startRecording: _yoloController.startRecording,
      stopRecording: _yoloController.stopRecording,
    );
    _classifier.load().catchError((Object error) {
      debugPrint('ReefSight: classifier failed to load: $error');
    });
    _frameProcessor = LiveFrameProcessor(
      tracker: _tracker,
      classify: _classifier.classifyBatch,
      onTracks: _handleTracks,
      onHealth: _handleHealth,
      metrics: _loopMetrics,
      // Read once: the loop and crop are fixed for this Live session.
      useLegacyLoop: AppSettings.instance.legacyLiveLoop.value,
      cropStyle: AppSettings.instance.cropStyle.value,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _sessionStartFuture = _startSession();
    });

    // Decision 7: Live is locked to landscape; every other screen defaults
    // to portrait (`main.dart`). Fire-and-forget -- a failure here shouldn't
    // block the rest of `initState`, matching this file's existing
    // `.catchError(...)`-and-log pattern for non-critical platform calls.
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]).catchError((Object error) {
      debugPrint('ReefSight: failed to lock landscape orientation: $error');
    });

    // Drives the tally/recording HUD's elapsed-time display once a second.
    // Pure UI refresh -- `_handleStreamingData` already triggers its own
    // `setState` on every processed frame regardless of this timer.
    _tickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
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
      _checkpointer = SessionCheckpointer(
        db: db,
        sessionId: sessionId,
        snapshot: () => [
          for (final trackId in _firstSeenAt.keys) _colonyRecord(sessionId, trackId),
        ],
        onFailure: (_) {
          if (mounted) setState(() {});
        },
      );
      // Not started if dispose() already ran: its finalize is waiting on
      // this future and will close the checkpointer itself.
      if (!_disposed) _checkpointer!.start();
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
    _tickTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _screenAwake.release();
    _deviceHealth.dispose();

    // Decision 7: restore the app-wide portrait default (`main.dart`) on
    // leaving Live. Fire-and-forget, same reasoning as the lock in
    // `initState` and as `_recorder.stop()` below -- this is UI-only and
    // must not delay or interact with the session finalize chain underneath.
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]).catchError((Object error) {
      debugPrint('ReefSight: failed to restore portrait orientation: $error');
    });

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

    // Close the processor first: it stops accepting events and waits out any
    // in-flight classification batch, so the classifier isn't torn down
    // mid-predict.
    // `close()` never throws, and `whenComplete` disposes regardless.
    _frameProcessor.close().whenComplete(_classifier.dispose).catchError((
      Object error,
    ) {
      debugPrint('ReefSight: failed to dispose classifier: $error');
    });
    _yoloController.dispose();
    super.dispose();
  }

  /// Persists every track this session ever saw (`_firstSeenAt`'s key set)
  /// as a finalized [TrackedColonyRecord], then closes the session and the
  /// DB handle. A no-op if [_startSession] never got as far as opening a DB
  /// (e.g. the diver never entered a tape length).
  ///
  /// Sub-plan 11: runs through [SessionCheckpointer.finalize], which stops
  /// further checkpoints and waits out an in-flight one first, so the two
  /// never write -- or close the DB -- under each other.
  Future<void> _finalizeSession() async {
    if (_finalized) return;
    _finalized = true;

    final checkpointer = _checkpointer;
    if (checkpointer == null) {
      await _frameProcessor.close();
      return;
    }
    await checkpointer.finalize(_writeFinalColonies);
  }

  /// One track's current record from the in-memory maps. Shared by the
  /// periodic checkpoint (no mask) and finalize (with the saved mask).
  TrackedColonyRecord _colonyRecord(
    int sessionId,
    int trackId, {
    String? maskPath,
  }) {
    return TrackedColonyRecord(
      sessionId: sessionId,
      trackId: trackId,
      healthLabel: _healthAggregator.currentLabel(trackId),
      healthHistory: _healthHistoryRecorder.samplesFor(trackId),
      sizePx: _latestSizePx[trackId],
      firstSeenAt: _firstSeenAt[trackId]!,
      lastSeenAt: _lastSeenAt[trackId]!,
      maskPath: maskPath,
    );
  }

  Future<void> _writeFinalColonies() async {
    // Freeze the live loop first, so no new track ids, masks or sizes land
    // while the loop below awaits mask writes and upserts. Idempotent with
    // dispose()'s own close().
    await _frameProcessor.close();

    final db = _db;
    final sessionId = _sessionId;
    if (db == null || sessionId == null) return;

    try {
      final documentsDir = await getApplicationDocumentsDirectory();
      final records = <TrackedColonyRecord>[];
      // A snapshot: streaming events keep arriving while this loop awaits
      // mask writes, and a new track id landing in `_firstSeenAt`
      // mid-iteration would throw a concurrent-modification error and abort
      // the finalize.
      for (final trackId in _firstSeenAt.keys.toList()) {
        final mask = _latestMasks[trackId];
        final maskPath = mask == null
            ? null
            : await MaskStorage.save(
                outputDirectory: documentsDir.path,
                sessionId: sessionId,
                trackId: trackId,
                mask: mask,
              );
        records.add(_colonyRecord(sessionId, trackId, maskPath: maskPath));
      }
      await db.upsertColonies(records);
      final thermalPeak = _deviceHealth.thermalPeak;
      if (thermalPeak != null) {
        await db.recordThermal(sessionId, thermalPeak, _deviceHealth.thermalRises);
      }
      await db.closeSession(
        sessionId,
        DateTime.now().toUtc(),
        videoPath: _recorder.currentOutputPath,
      );
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
      // The transect is over; Summary may auto-lock normally. Not released
      // on failure -- the diver is still on this screen and may retry.
      _screenAwake.release();

      if (!mounted) return;

      // Sub-plan 6 (ui-ux-overhaul) step 4: "Fix the back-stack after a
      // survey... using `pushAndRemoveUntil` down to the shell route." The
      // old `pushReplacement` left Setup directly underneath Summary, so
      // pressing back from Summary landed on the setup form instead of
      // Home. Restoring portrait here (in addition to `dispose()`'s own
      // restore, harmless if it runs twice) avoids a landscape-then-portrait
      // flash while the route transition to Summary is in flight.
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
      if (!mounted) return;

      if (sessionId != null) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => SummaryScreen(sessionId: sessionId)),
          ModalRoute.withName(AppShell.routeName),
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

  /// Sub-plan 11 step 3: leaving the foreground (call, notification
  /// centre, app switch) checkpoints immediately and is recorded on the
  /// session. On return, the wakelock is reasserted in case the OS dropped
  /// it while backgrounded.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _checkpointer?.handleLifecycle(state);
    if (state == AppLifecycleState.resumed && !_finalized && !_disposed) {
      _screenAwake.acquire();
    }
  }

  void _handleStreamingData(Map<String, dynamic> event) {
    final segProcessingMs = (event['processingTimeMs'] as num?)?.toDouble();
    if (segProcessingMs != null) _segProcessingMs = segProcessingMs;

    // Synchronous: the tracker has seen this event by the time this returns
    // (sub-plan 09). `_handleTracks` below does the setState.
    _frameProcessor.handleEvent(event);
    _logLoopSummary();
    _logMaskGeometry(event);
  }

  int _maskGeometryLogged = 0;

  /// Sub-plan 10, step 0 (on-device, temporary): which coordinate space is
  /// `YOLOResult.mask`'s grid in -- box-local, full-frame, or the model's
  /// 640-letterboxed input? Comparing the grid's rows x cols against the box
  /// and frame sizes for a few detections settles it; the value range says
  /// whether the 0.5 threshold is right (0-1 vs 0-255). Every debug build
  /// logs it -- not gated on diagnostics, so the first device run can't
  /// miss it -- for the first 10 masked detections per session. Remove once
  /// the answer is recorded in `colony_size.dart`. Until then crop spec v1
  /// assumes box-local, 0-1 masks.
  void _logMaskGeometry(Map<String, dynamic> event) {
    if (!kDebugMode || _maskGeometryLogged >= 10) return;
    final raw = event['detections'];
    if (raw is! List) return;
    for (final map in raw.whereType<Map>()) {
      if (_maskGeometryLogged >= 10) return;
      final result = YOLOResult.fromMap(map);
      final mask = result.mask;
      if (mask == null || mask.isEmpty) continue;
      _maskGeometryLogged++;
      final box = result.boundingBox;
      var minValue = double.infinity, maxValue = double.negativeInfinity;
      for (final row in mask) {
        for (final v in row) {
          if (v < minValue) minValue = v;
          if (v > maxValue) maxValue = v;
        }
      }
      debugPrint(
        'ReefSight: mask geometry (sub-plan 10 step 0): '
        'mask ${mask.length}x${mask.first.length} (rows x cols), '
        'values ${minValue.toStringAsFixed(2)}..${maxValue.toStringAsFixed(2)}, '
        'box ${box.width.toStringAsFixed(1)}x${box.height.toStringAsFixed(1)} '
        'at (${box.left.toStringAsFixed(1)}, ${box.top.toStringAsFixed(1)}), '
        'frame ${event['imageWidth']}x${event['imageHeight']}',
      );
    }
  }

  /// Sub-plan 09 steps 1/4: while diagnostics are on, refresh the overlay's
  /// loop line, and in debug builds log it every 5 s for the before/after
  /// record. The overlay picks the new line up on `_handleTracks`' setState.
  void _logLoopSummary() {
    if (!AppSettings.instance.showDiagnostics.value) return;
    final summary = _loopMetrics.summary();
    _loopSummary = summary;

    final now = DateTime.now();
    final last = _lastLoopLogAt;
    if (!kDebugMode ||
        (last != null && now.difference(last) < const Duration(seconds: 5))) {
      return;
    }
    _lastLoopLogAt = now;
    final loop = _frameProcessor.useLegacyLoop ? 'legacy' : 'decoupled';
    final crop = _frameProcessor.cropStyle.name;
    final thermal = _deviceHealth.health.value?.thermalLevel?.name ?? '--';
    debugPrint(
      'ReefSight: live loop ($loop, $crop): ${summary.format()} thermal=$thermal',
    );
  }

  /// Called by [LiveFrameProcessor] after every tracker update.
  ///
  /// Size/mask bookkeeping happens inside the same setState block as the
  /// rebuild trigger so it stays atomic with what's displayed -- splitting
  /// them (mutate, then separately setState) would let a future early-return
  /// between the two show stale data.
  void _handleTracks(List<STrack> tracks) {
    if (!mounted) return;
    final now = DateTime.now().toUtc();
    setState(() {
      _latestTracks = tracks;
      for (final track in tracks) {
        _firstSeenAt.putIfAbsent(track.trackId, () => now);
        _lastSeenAt[track.trackId] = now;

        final payload = track.payload;
        if (payload is! LiveDetectionPayload) continue;

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

  /// Called by [LiveFrameProcessor]'s scheduler with each classification
  /// result, keyed by the track it was sampled from. Results are kept even
  /// if that track has since been lost or removed -- finalize persists every
  /// track ever seen -- and dropped only once the session is finalized.
  void _handleHealth(int trackId, ColonyHealth health, DateTime sampledAt) {
    if (_finalized || !mounted) return;
    setState(() {
      _healthAggregator.record(trackId, health);
      _healthHistoryRecorder.record(trackId, health, sampledAt.toUtc());
    });
  }

  /// Opens the confirm sheet (sub-plan step 6 + decision: "Tapping it opens
  /// a confirm sheet... Tapping twice by accident underwater must not end a
  /// dive") and only proceeds to the real, guarded `_endTransect()` if the
  /// diver confirms. Shared by the End Transect button and the `PopScope`
  /// back/edge-swipe guard below -- neither path touches session state
  /// directly, both funnel into the same `_endTransect()` (decision 5).
  Future<void> _confirmEndTransect() async {
    final confirmed = await showEndTransectSheet(
      context,
      colonyCount: _firstSeenAt.length,
    );
    if (!confirmed) return;
    await _endTransect();
  }

  @override
  Widget build(BuildContext context) {
    final elapsed = DateTime.now().difference(_liveStartedAt);

    return PopScope(
      // Decision: "Back and edge-swipe guard: `PopScope(canPop: false)`
      // routes to the same confirm sheet" -- a back swipe mid-dive no
      // longer tears the screen down silently.
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        await _confirmEndTransect();
      },
      child: Scaffold(
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
                if (mounted) {
                  setState(() {
                    _segmentationError = null;
                    _modelLoaded = true;
                  });
                }
              },
            ),
            // Loading state (sub-plan step 6): shown over `YOLOView`, which
            // stays mounted underneath so `onModelLoad`/`onModelError` still
            // fire -- this is an overlay, not a replacement widget.
            if (!_modelLoaded)
              const Positioned.fill(
                child: UnderwaterBackground(
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(color: Colors.white),
                        SizedBox(height: 16),
                        Text(
                          'Loading coral model…',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            // Recording indicator, top-left -- decision 7's landscape HUD
            // layout.
            Positioned(
              left: 12,
              top: 12,
              child: SafeArea(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    RecordingIndicator(
                      isRecording: _recorder.isRecording,
                      elapsed: elapsed,
                      errorMessage: _recordingError,
                    ),
                    // Sub-plan 13 step 3: heat, battery or storage needing
                    // attention -- beside the indicator, on the HUD edge,
                    // never over the frame (sub-plan 06 decision 4).
                    const SizedBox(width: 8),
                    ValueListenableBuilder<DeviceHealth?>(
                      valueListenable: _deviceHealth.health,
                      builder: (context, health, _) => DeviceHealthBadge(health: health),
                    ),
                  ],
                ),
              ),
            ),
            // Running tally, top edge -- Spec's "Live screen" line:
            // "detection/segmentation overlay + a running tally (colonies
            // seen, tentative healthy/bleached count)."
            Positioned(
              top: 12,
              right: 12,
              child: SafeArea(
                child: TallyHud(
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
                  elapsed: elapsed,
                ),
              ),
            ),
            // Error banners across the top -- never over the centre of the
            // frame (decision 4).
            if (_segmentationError != null || _persistError != null)
              Positioned(
                top: 64,
                left: 12,
                right: 12,
                child: SafeArea(
                  top: false,
                  child: Column(
                    children: [
                      if (_segmentationError != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: LiveErrorBanner(
                            message: 'Segmentation model error',
                            detail: _segmentationError!,
                          ),
                        ),
                      if (_persistError != null)
                        LiveErrorBanner(
                          message: 'Storage error',
                          detail: _persistError!,
                        ),
                    ],
                  ),
                ),
              ),
            // Debug overlay (per-track list + seg timing): hidden by
            // default, toggled from Settings ("Show diagnostics"), docked
            // to the left edge when shown (sub-plan step 6).
            ValueListenableBuilder<bool>(
              valueListenable: AppSettings.instance.showDiagnostics,
              builder: (context, showDiagnostics, _) {
                if (!showDiagnostics) return const SizedBox.shrink();
                return Positioned(
                  left: 12,
                  bottom: 12,
                  child: SafeArea(
                    child: DiagnosticsOverlay(
                      segProcessingMs: _segProcessingMs,
                      loopSummary: _loopSummary?.format(),
                      tracks: _latestTracks,
                      healthAggregator: _healthAggregator,
                      sizesPx: _latestSizePx,
                      checkpointFailures: _checkpointer?.failureCount ?? 0,
                      thermal: _deviceHealth.health.value?.thermalLevel,
                    ),
                  ),
                );
              },
            ),
            // Large, glove-friendly End Transect control on the trailing
            // (right) edge -- decision 7 (thumb rests on that side of the
            // housing) and decision 4 (single destructive action, 64 dp).
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
                        padding:
                            const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        constraints: const BoxConstraints(maxWidth: 240),
                        decoration: BoxDecoration(
                          color: Colors.black87,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          'Failed to end transect: $_endTransectError',
                          style: const TextStyle(color: Colors.redAccent, fontSize: 13),
                        ),
                      ),
                    // Explicit width: the theme's ElevatedButton
                    // `minimumSize` is `Size.fromHeight(...)` (infinite min
                    // width), and this `Positioned` only pins right/bottom,
                    // so without a bound the button can't lay out and never
                    // paints -- the "no stop button" bug.
                    SizedBox(
                      width: 220,
                      child: GloveButton(
                        label: _endingTransect ? 'Ending...' : 'End Transect',
                        icon: Icons.stop_circle_outlined,
                        destructive: true,
                        inWater: true,
                        busy: _endingTransect,
                        onPressed: _confirmEndTransect,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
