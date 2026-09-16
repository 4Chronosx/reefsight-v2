import 'camera_motion_compensation.dart';
import 'matching.dart' as matching;
import 'strack.dart';
import 'track_state.dart';
import 'tracker_detection.dart';

/// Direct Dart port of BoT-SORT's `tracker/bot_sort.py` `BoTSORT` class,
/// with the Re-ID branches removed (this project doesn't use appearance
/// embeddings — see `ReefSight_Development_Plan.md` Track 2's full
/// rationale). Camera motion compensation ([cameraMotionCompensator], sub-
/// plan 2 step 5) is optional and off by default: when no compensator is
/// given, or a caller doesn't pass a [GrayscaleFrame] to [update], behavior
/// is exactly `cmc_method='none'` (identity warp) — unchanged from before
/// this step existed, so the frame-less path's existing parity tests keep
/// passing untouched.
class BoTSortTracker {
  BoTSortTracker({
    this.trackHighThresh = 0.6,
    this.trackLowThresh = 0.1,
    this.newTrackThresh = 0.7,
    this.trackBuffer = 30,
    this.matchThresh = 0.8,
    this.fuseScore = true,
    this.cameraMotionCompensator,
  }) {
    STrack.resetIdCounter();
  }

  final double trackHighThresh;
  final double trackLowThresh;
  final double newTrackThresh;
  final int trackBuffer;
  final double matchThresh;

  /// Estimates and corrects for camera motion between frames before
  /// matching, mirroring the reference's `self.gmc.apply(...)` +
  /// `STrack.multi_gmc(...)` calls. `null` (the default) disables CMC
  /// entirely, matching `cmc_method='none'`.
  final CameraMotionCompensator? cameraMotionCompensator;

  /// Whether to fuse detection confidence into the IoU cost (the paper's
  /// design). BoT-SORT's own demo CLI defaults this off via an unrelated
  /// `--fuse-score`/`mot20` flag interaction; this port defaults it on and
  /// keeps it explicit so the Python validation driver (sub-plan step 4)
  /// can be configured to match exactly.
  final bool fuseScore;

  int get _maxTimeLost => trackBuffer;

  int _frameId = 0;
  List<STrack> _trackedStracks = [];
  List<STrack> _lostStracks = [];
  final List<STrack> _removedStracks = [];

  /// Currently tracked (non-removed, non-lost) tracks, matching the
  /// reference's `output_stracks`.
  List<STrack> get tracks => List.unmodifiable(_trackedStracks);

  /// Advances the tracker by one frame given this frame's [detections].
  /// Pass [frame] to enable camera motion compensation for this call (only
  /// takes effect if [cameraMotionCompensator] was also provided at
  /// construction). Returns the updated [tracks].
  List<STrack> update(
    List<TrackerDetection> detections, {
    GrayscaleFrame? frame,
  }) {
    _frameId++;
    final activated = <STrack>[];
    final refound = <STrack>[];
    final lost = <STrack>[];
    final removed = <STrack>[];

    final highDets = <TrackerDetection>[];
    final lowDets = <TrackerDetection>[];
    for (final d in detections) {
      if (d.score > trackHighThresh) {
        highDets.add(d);
      } else if (d.score > trackLowThresh && d.score < trackHighThresh) {
        // Strictly between the two thresholds, matching the reference's
        // `inds_second = (scores > low) & (scores < high)` — a detection
        // scoring exactly `trackHighThresh` falls into neither bucket.
        lowDets.add(d);
      }
    }

    final detectionTracks = [
      for (final d in highDets) STrack(d.tlwh, d.score, payload: d.payload),
    ];

    final unconfirmed = <STrack>[];
    final trackedStracks = <STrack>[];
    for (final t in _trackedStracks) {
      if (!t.isActivated) {
        unconfirmed.add(t);
      } else {
        trackedStracks.add(t);
      }
    }

    final strackPool = matching.jointTracks(trackedStracks, _lostStracks);
    for (final t in strackPool) {
      t.predict();
    }

    final compensator = cameraMotionCompensator;
    if (compensator != null && frame != null) {
      final warp = compensator.apply(frame);
      for (final t in strackPool) {
        t.applyWarp(warp);
      }
      for (final t in unconfirmed) {
        t.applyWarp(warp);
      }
    }

    var iousDists = matching.iouDistance(strackPool, detectionTracks);
    if (fuseScore) {
      iousDists = matching.fuseScore(iousDists, detectionTracks);
    }
    final firstResult = matching.linearAssignment(
      iousDists,
      matchThresh,
      rows: strackPool.length,
      cols: detectionTracks.length,
    );

    for (final pair in firstResult.matches) {
      final track = strackPool[pair[0]];
      final det = detectionTracks[pair[1]];
      if (track.state == TrackState.tracked) {
        track.update(det, _frameId);
        activated.add(track);
      } else {
        track.reActivate(det, _frameId);
        refound.add(track);
      }
    }

    final secondDetectionTracks = [
      for (final d in lowDets) STrack(d.tlwh, d.score, payload: d.payload),
    ];
    final remainingTracked = [
      for (final i in firstResult.unmatchedA)
        if (strackPool[i].state == TrackState.tracked) strackPool[i],
    ];
    final secondDists = matching.iouDistance(
      remainingTracked,
      secondDetectionTracks,
    );
    final secondResult = matching.linearAssignment(
      secondDists,
      0.5,
      rows: remainingTracked.length,
      cols: secondDetectionTracks.length,
    );

    for (final pair in secondResult.matches) {
      final track = remainingTracked[pair[0]];
      final det = secondDetectionTracks[pair[1]];
      if (track.state == TrackState.tracked) {
        track.update(det, _frameId);
        activated.add(track);
      } else {
        track.reActivate(det, _frameId);
        refound.add(track);
      }
    }
    for (final i in secondResult.unmatchedA) {
      final track = remainingTracked[i];
      if (track.state != TrackState.lost) {
        track.markLost();
        lost.add(track);
      }
    }

    final remainingHighDets = [
      for (final i in firstResult.unmatchedB) detectionTracks[i],
    ];
    var unconfirmedDists = matching.iouDistance(
      unconfirmed,
      remainingHighDets,
    );
    if (fuseScore) {
      unconfirmedDists = matching.fuseScore(
        unconfirmedDists,
        remainingHighDets,
      );
    }
    final unconfirmedResult = matching.linearAssignment(
      unconfirmedDists,
      0.7,
      rows: unconfirmed.length,
      cols: remainingHighDets.length,
    );

    for (final pair in unconfirmedResult.matches) {
      unconfirmed[pair[0]].update(remainingHighDets[pair[1]], _frameId);
      activated.add(unconfirmed[pair[0]]);
    }
    for (final i in unconfirmedResult.unmatchedA) {
      unconfirmed[i].markRemoved();
      removed.add(unconfirmed[i]);
    }

    for (final i in unconfirmedResult.unmatchedB) {
      final track = remainingHighDets[i];
      if (track.score < newTrackThresh) continue;
      track.activate(_frameId);
      activated.add(track);
    }

    for (final t in _lostStracks) {
      if (_frameId - t.endFrame > _maxTimeLost) {
        t.markRemoved();
        removed.add(t);
      }
    }

    _trackedStracks =
        _trackedStracks.where((t) => t.state == TrackState.tracked).toList();
    _trackedStracks = matching.jointTracks(_trackedStracks, activated);
    _trackedStracks = matching.jointTracks(_trackedStracks, refound);
    _lostStracks = matching.subTracks(_lostStracks, _trackedStracks);
    _lostStracks.addAll(lost);
    _lostStracks = matching.subTracks(_lostStracks, _removedStracks);
    _removedStracks.addAll(removed);

    final (dedupedTracked, dedupedLost) = matching.removeDuplicateTracks(
      _trackedStracks,
      _lostStracks,
    );
    _trackedStracks = dedupedTracked;
    _lostStracks = dedupedLost;

    return List.unmodifiable(_trackedStracks);
  }
}
