// Building blocks for `tool/track_eval.dart` (sub-plan 08's offline tracking harness), kept free of
// file-system and CLI concerns so `test/tool/track_eval_test.dart` can exercise them directly.
//
// Conventions shared with tracking-validation/notebooks/01 and 02 (see
// docs/coralvos-tracking-pseudo-ground-truth.md, "Output format"):
// - frames are 1-based within each subsampled sequence;
// - boxes are 0-based pixel `x, y, w, h` on the 1280x720 frame;
// - GT class 1 is a scored colony, class 8 an ignore region.
import 'package:reefsight_mobile/tracking/bot_sort_tracker.dart';
import 'package:reefsight_mobile/tracking/camera_motion_compensation.dart';
import 'package:reefsight_mobile/tracking/linalg.dart' as linalg;
import 'package:reefsight_mobile/tracking/tracker_detection.dart';

/// One evaluation arm: the tracker's parameters plus the two harness-level knobs (the detection
/// confidence floor and CMC on/off). Defaults are exactly what the app runs today: a bare
/// `BoTSortTracker()` (the reference's MOT17 defaults), the `ultralytics_yolo` plugin's default
/// 0.25 confidence cutoff (never overridden by the app, sub-plan 08 "found 2026-10-02"), and no CMC.
class EvalConfig {
  const EvalConfig({
    this.trackHighThresh = 0.6,
    this.trackLowThresh = 0.1,
    this.newTrackThresh = 0.7,
    this.matchThresh = 0.8,
    this.trackBuffer = 30,
    this.fuseScore = true,
    this.detFloor = 0.25,
    this.cmc = false,
  });

  final double trackHighThresh;
  final double trackLowThresh;
  final double newTrackThresh;
  final double matchThresh;

  /// In tracker updates, not seconds -- see [bufferUpdatesFor].
  final int trackBuffer;
  final bool fuseScore;

  /// Detections scoring below this never reach the tracker, modelling the plugin's cutoff.
  final double detFloor;
  final bool cmc;

  static const keys = {
    'trackHighThresh',
    'trackLowThresh',
    'newTrackThresh',
    'matchThresh',
    'trackBuffer',
    'trackBufferSeconds',
    'fuseScore',
    'detFloor',
    'cmc',
  };

  /// Returns a copy with [overrides] applied. `trackBufferSeconds` is converted to updates at
  /// [hz], so a sweep can be written in seconds and stay meaningful if the update rate changes.
  EvalConfig withOverrides(Map<String, dynamic> overrides, {required double hz}) {
    final unknown = overrides.keys.where((k) => k != 'name' && !keys.contains(k)).toList();
    if (unknown.isNotEmpty) {
      throw ArgumentError('Unknown EvalConfig keys: $unknown (expected one of $keys)');
    }
    if (overrides.containsKey('trackBuffer') && overrides.containsKey('trackBufferSeconds')) {
      throw ArgumentError('Give trackBuffer (updates) or trackBufferSeconds, not both');
    }
    double d(String k, double fallback) => (overrides[k] as num?)?.toDouble() ?? fallback;
    final seconds = (overrides['trackBufferSeconds'] as num?)?.toDouble();
    return EvalConfig(
      trackHighThresh: d('trackHighThresh', trackHighThresh),
      trackLowThresh: d('trackLowThresh', trackLowThresh),
      newTrackThresh: d('newTrackThresh', newTrackThresh),
      matchThresh: d('matchThresh', matchThresh),
      trackBuffer: seconds != null
          ? bufferUpdatesFor(seconds: seconds, hz: hz)
          : (overrides['trackBuffer'] as int?) ?? trackBuffer,
      fuseScore: (overrides['fuseScore'] as bool?) ?? fuseScore,
      detFloor: d('detFloor', detFloor),
      cmc: (overrides['cmc'] as bool?) ?? cmc,
    );
  }

  /// Deterministic arm name, used when a sweep arm doesn't name itself.
  String get label => 'h${trackHighThresh.toStringAsFixed(2)}_l${trackLowThresh.toStringAsFixed(2)}'
      '_n${newTrackThresh.toStringAsFixed(2)}_m${matchThresh.toStringAsFixed(2)}_b$trackBuffer'
      '_f${detFloor.toStringAsFixed(2)}${fuseScore ? '' : '_nofuse'}${cmc ? '_cmc' : ''}';

  Map<String, dynamic> toJson({double? hz}) => {
        'trackHighThresh': trackHighThresh,
        'trackLowThresh': trackLowThresh,
        'newTrackThresh': newTrackThresh,
        'matchThresh': matchThresh,
        'trackBuffer': trackBuffer,
        if (hz != null)
          'trackBufferSecondsEquivalent': double.parse((trackBuffer / hz).toStringAsFixed(3)),
        'fuseScore': fuseScore,
        'detFloor': detFloor,
        'cmc': cmc,
      };
}

/// `trackBuffer` is counted in tracker updates. At [hz] updates/second, [seconds] of lost-track
/// memory is `round(seconds * hz)` updates (e.g. the shipped 30 updates is 3.75 s at 8 Hz, not the
/// ~1 s it means on 30 fps MOT17 video). Note the reference's pruning order lets a lost track be
/// re-found for one update past that (it survives `trackBuffer + 1` empty updates; pinned by
/// test/tool/track_eval_test.dart), so the real horizon is one update longer than this nominal value.
int bufferUpdatesFor({required double seconds, required double hz}) {
  if (seconds <= 0 || hz <= 0) {
    throw ArgumentError('seconds and hz must be positive (got $seconds, $hz)');
  }
  final updates = (seconds * hz).round();
  return updates < 1 ? 1 : updates;
}

/// Expands a sweep spec into named arms, each applied on top of [base]:
/// `{"base": {...}, "arms": [{"name": "x", ...}, ...], "grid": {"key": [v1, v2], ...}}`.
/// `base` is optional; `arms` and `grid` may each be omitted, and both are used if both are given
/// (explicit arms first, then the grid's cartesian product in key order).
List<(String, EvalConfig)> expandSweep(
  Map<String, dynamic> spec, {
  required EvalConfig base,
  required double hz,
}) {
  final unknown = spec.keys.where((k) => !{'base', 'arms', 'grid'}.contains(k)).toList();
  if (unknown.isNotEmpty) throw ArgumentError('Unknown sweep keys: $unknown');
  // Map<String, dynamic>.from: accepts decoded JSON and hand-built Dart map literals alike.
  Map<String, dynamic> asMap(Object? v) =>
      v == null ? const {} : Map<String, dynamic>.from(v as Map);
  final sweepBase = base.withOverrides(asMap(spec['base']), hz: hz);
  final arms = <(String, EvalConfig)>[];
  for (final arm in (spec['arms'] as List<dynamic>?) ?? const []) {
    final overrides = asMap(arm);
    final config = sweepBase.withOverrides(overrides, hz: hz);
    arms.add(((overrides['name'] as String?) ?? config.label, config));
  }
  final grid = asMap(spec['grid']);
  if (grid.isNotEmpty) {
    var combos = <Map<String, dynamic>>[{}];
    for (final entry in grid.entries) {
      final values = entry.value as List<dynamic>;
      combos = [
        for (final combo in combos)
          for (final v in values) {...combo, entry.key: v},
      ];
    }
    for (final combo in combos) {
      final config = sweepBase.withOverrides(combo, hz: hz);
      arms.add((config.label, config));
    }
  }
  if (arms.isEmpty) throw ArgumentError('Sweep spec defines no arms (need "arms" and/or "grid")');
  final names = arms.map((a) => a.$1).toList();
  final dupes = names.where((n) => names.indexOf(n) != names.lastIndexOf(n)).toSet();
  if (dupes.isNotEmpty) throw ArgumentError('Duplicate arm names: $dupes');
  return arms;
}

Iterable<List<String>> _csvRows(String content) => content
    .split('\n')
    .map((l) => l.trim())
    .where((l) => l.isNotEmpty)
    .map((l) => l.split(','));

/// Parses notebook 02's MOTChallenge detection file (`frame,-1,x,y,w,h,conf,-1,-1,-1`) into
/// per-frame detections, in file order. No confidence floor is applied here (see
/// [EvalConfig.detFloor]), so one parse serves every arm of a sweep.
Map<int, List<TrackerDetection>> parseMotDetections(String content) {
  final byFrame = <int, List<TrackerDetection>>{};
  for (final r in _csvRows(content)) {
    final x = double.parse(r[2]), y = double.parse(r[3]);
    final w = double.parse(r[4]), h = double.parse(r[5]);
    if (w <= 0 || h <= 0) continue;
    byFrame.putIfAbsent(int.parse(r[0]), () => []).add(
          TrackerDetection(x1: x, y1: y, x2: x + w, y2: y + h, score: double.parse(r[6])),
        );
  }
  return byFrame;
}

/// The oracle diagnostic (sub-plan 08, "Evaluation harness" item 5): notebook 01's scored GT
/// boxes (class [colonyClass] only, not ignore regions) fed to the tracker as perfect detections
/// with score 1.0. Separates tracker error from detector error.
Map<int, List<TrackerDetection>> parseGtAsOracle(String content, {int colonyClass = 1}) {
  final byFrame = <int, List<TrackerDetection>>{};
  for (final r in _csvRows(content)) {
    if (int.parse(r[7]) != colonyClass) continue;
    final x = double.parse(r[2]), y = double.parse(r[3]);
    final w = double.parse(r[4]), h = double.parse(r[5]);
    byFrame.putIfAbsent(int.parse(r[0]), () => []).add(
          TrackerDetection(x1: x, y1: y, x2: x + w, y2: y + h, score: 1.0),
        );
  }
  return byFrame;
}

/// One tracker output box: exactly one entry of the list `BoTSortTracker.update` returned on
/// [frame], which is also what the app counts (`LiveFrameProcessor` -> `_handleTracks`).
class MotRow {
  const MotRow(this.frame, this.trackId, this.tlbr, this.score, this.activated);

  final int frame;
  final int trackId;
  final List<double> tlbr;
  final double score;

  /// `STrack.isActivated`. BoT-SORT's `update` also returns unconfirmed (not yet activated) tracks,
  /// and the app counts those too; this flag lets the metrics notebook count it both ways.
  final bool activated;
}

/// The warp [CameraMotionCompensator] estimates for each of frames 1..[numFrames], in order.
/// Warps depend only on the frames, never on tracker parameters, so a sweep computes them once
/// per sequence and replays them in every arm ([ReplayCompensator]) instead of re-running optical
/// flow per arm.
List<linalg.Matrix> computeWarps({
  required int numFrames,
  required GrayscaleFrame Function(int frame) frameLoader,
  int downscale = 2,
}) {
  final cmc = CameraMotionCompensator(downscale: downscale);
  try {
    return [for (var f = 1; f <= numFrames; f++) cmc.apply(frameLoader(f))];
  } finally {
    cmc.dispose();
  }
}

/// Hands the tracker precomputed warps in order, one per `apply` call. `BoTSortTracker` calls
/// `apply` exactly once per `update` that has a frame, so replaying [computeWarps]'s output gives
/// the same result as live CMC (pinned by test/tool/track_eval_test.dart).
class ReplayCompensator extends CameraMotionCompensator {
  ReplayCompensator(this._warps);

  final List<linalg.Matrix> _warps;
  var _next = 0;

  @override
  linalg.Matrix apply(GrayscaleFrame frame) => _warps[_next++];
}

/// Stand-in frame for [ReplayCompensator], which ignores it; the tracker only needs a non-null
/// frame to call the compensator.
const _replayFrame = GrayscaleFrame(width: 0, height: 0, pixels: []);

/// Runs one sequence through a fresh [BoTSortTracker] built from [config]. `update` is called on
/// **every** frame 1..[numFrames], including frames with no detections, as the app's decoupled
/// live loop does (`live_frame_processor.dart`). When `config.cmc` is set, CMC uses [warps] (from
/// [computeWarps]) if given, otherwise live optical flow on [frameLoader]'s grayscale frames.
List<MotRow> runSequence({
  required int numFrames,
  required Map<int, List<TrackerDetection>> detections,
  required EvalConfig config,
  GrayscaleFrame Function(int frame)? frameLoader,
  List<linalg.Matrix>? warps,
  int cmcDownscale = 2,
}) {
  if (config.cmc && frameLoader == null && warps == null) {
    throw ArgumentError('config.cmc is set but neither warps nor a frameLoader was given');
  }
  if (config.cmc && warps != null && warps.length != numFrames) {
    throw ArgumentError('${warps.length} warps for $numFrames frames');
  }
  final replay = config.cmc && warps != null;
  final CameraMotionCompensator? compensator = !config.cmc
      ? null
      : replay
          ? ReplayCompensator(warps)
          : CameraMotionCompensator(downscale: cmcDownscale);
  final tracker = BoTSortTracker(
    trackHighThresh: config.trackHighThresh,
    trackLowThresh: config.trackLowThresh,
    newTrackThresh: config.newTrackThresh,
    trackBuffer: config.trackBuffer,
    matchThresh: config.matchThresh,
    fuseScore: config.fuseScore,
    cameraMotionCompensator: compensator,
  );
  final rows = <MotRow>[];
  try {
    for (var f = 1; f <= numFrames; f++) {
      final dets = [
        for (final d in detections[f] ?? const <TrackerDetection>[])
          if (d.score >= config.detFloor) d,
      ];
      final frame = !config.cmc ? null : (replay ? _replayFrame : frameLoader!(f));
      final tracks = tracker.update(dets, frame: frame);
      for (final t in tracks) {
        rows.add(MotRow(f, t.trackId, t.tlbr, t.score, t.isActivated));
      }
    }
  } finally {
    compensator?.dispose();
  }
  return rows;
}

/// MOTChallenge tracker rows: `frame,id,x,y,w,h,conf,-1,activated,-1`. Column 7 stays -1 because
/// TrackEval reads it as the tracker's class; the activated flag goes in the otherwise-unused
/// column 8.
String formatMot(List<MotRow> rows) {
  final sb = StringBuffer();
  for (final r in rows) {
    final x = r.tlbr[0], y = r.tlbr[1], w = r.tlbr[2] - r.tlbr[0], h = r.tlbr[3] - r.tlbr[1];
    sb.writeln('${r.frame},${r.trackId},${x.toStringAsFixed(2)},${y.toStringAsFixed(2)},'
        '${w.toStringAsFixed(2)},${h.toStringAsFixed(2)},${r.score.toStringAsFixed(4)},-1,'
        '${r.activated ? 1 : 0},-1');
  }
  return sb.toString();
}

/// Per-sequence counts for the run log: unique IDs are what the app would report as colonies.
Map<String, int> summarize(List<MotRow> rows) => {
      'rows': rows.length,
      'unique_ids': rows.map((r) => r.trackId).toSet().length,
      'unique_activated_ids': rows.where((r) => r.activated).map((r) => r.trackId).toSet().length,
    };
