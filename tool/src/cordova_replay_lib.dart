// Building blocks of tool/cordova_replay.dart: replays one clip's pre-computed detections through
// the tracker exactly as the live app builds it (`TrackerConfig.build`) and tallies colonies with
// the app's own `ConfirmedSightings`. Kept free of file and video I/O so it's testable headlessly.
import 'package:reefsight_mobile/services/confirmed_sightings.dart';
import 'package:reefsight_mobile/tracking/camera_motion_compensation.dart';
import 'package:reefsight_mobile/tracking/tracker_config.dart';
import 'package:reefsight_mobile/tracking/tracker_detection.dart';

/// One tracker update: its 1-based index, the source video frame, and the time since the video
/// start.
typedef ReplayUpdate = ({int update, int frameIdx, double tSec});

Iterable<List<String>> _csvRows(String content, String name, int columns) sync* {
  final lines = content.split(RegExp(r'\r?\n')).where((l) => l.trim().isNotEmpty).toList();
  if (lines.isEmpty) throw FormatException('$name is empty (no header)');
  for (final line in lines.skip(1)) {
    final cells = line.split(',');
    if (cells.length != columns) {
      throw FormatException('$name: expected $columns columns, got ${cells.length}: "$line"');
    }
    yield cells;
  }
}

/// Parses `updates.csv` (`update,frame_idx,t_sec`). Updates must be 1, 2, 3, ... in order, since
/// the tracker counts updates, not frames.
List<ReplayUpdate> parseUpdates(String content) {
  final updates = [
    for (final c in _csvRows(content, 'updates.csv', 3))
      (update: int.parse(c[0]), frameIdx: int.parse(c[1]), tSec: double.parse(c[2])),
  ];
  for (var i = 0; i < updates.length; i++) {
    if (updates[i].update != i + 1) {
      throw FormatException('updates.csv is not contiguous: row ${i + 1} is update ${updates[i].update}');
    }
  }
  return updates;
}

/// Parses `dets.csv` (`update,det,x1,y1,x2,y2,conf`) into each update's detections, with the
/// detection's index within its frame as the payload. Zero- or negative-area boxes are dropped, as
/// `LiveFrameProcessor._parseDetections` does before the tracker sees them.
Map<int, List<TrackerDetection>> parseDetections(String content) {
  final byUpdate = <int, List<TrackerDetection>>{};
  for (final c in _csvRows(content, 'dets.csv', 7)) {
    final x1 = double.parse(c[2]), y1 = double.parse(c[3]);
    final x2 = double.parse(c[4]), y2 = double.parse(c[5]);
    if (x2 <= x1 || y2 <= y1) continue;
    (byUpdate[int.parse(c[0])] ??= []).add(
      TrackerDetection(x1: x1, y1: y1, x2: x2, y2: y2, score: double.parse(c[6]), payload: int.parse(c[1])),
    );
  }
  return byUpdate;
}

/// One track the tracker returned at one update. [det] is the index of the detection it was
/// matched to in that update's frame.
class ReplayAssignment {
  const ReplayAssignment({
    required this.update,
    required this.trackId,
    required this.det,
    required this.activated,
  });

  final int update;
  final int trackId;
  final int det;
  final bool activated;
}

class ReplayResult {
  ReplayResult(this.assignments, this.sightings, this.cmcFrames);

  /// Every track `BoTSortTracker.update` returned, confirmed or not.
  final List<ReplayAssignment> assignments;

  /// The app's colony tally: its key set is the colony list.
  final ConfirmedSightings sightings;

  /// Updates that had a CMC frame.
  final int cmcFrames;
}

/// Seconds since the video start as a UTC [DateTime], so [ConfirmedSightings] can be used as is.
DateTime timeAt(double tSec) =>
    DateTime.fromMicrosecondsSinceEpoch((tSec * 1e6).round(), isUtc: true);

double secondsOf(DateTime t) => t.microsecondsSinceEpoch / 1e6;

/// Replays [updates] through `TrackerConfig.build(updateHz: hz, cmc: cmc)`. [frameFor] returns
/// an update's CMC frame (a [GrayscaleFrame], ideally a `ScaledGrayscaleFrame`), or `null` for
/// none, in which case that update runs without motion compensation, as the live app does when a
/// frame won't decode.
ReplayResult replayClip({
  required List<ReplayUpdate> updates,
  required Map<int, List<TrackerDetection>> detections,
  required double hz,
  bool cmc = TrackerConfig.cmc,
  GrayscaleFrame? Function(int update)? frameFor,
}) {
  final tracker = TrackerConfig.build(updateHz: hz, cmc: cmc);
  final sightings = ConfirmedSightings();
  final assignments = <ReplayAssignment>[];
  var cmcFrames = 0;
  for (final u in updates) {
    final frame = cmc ? frameFor?.call(u.update) : null;
    if (frame != null) cmcFrames++;
    final tracks = tracker.update(detections[u.update] ?? const [], frame: frame);
    sightings.observe(tracks, timeAt(u.tSec));
    for (final t in tracks) {
      final det = t.payload;
      if (det is! int) {
        throw StateError('update ${u.update}: track ${t.trackId} has no detection index payload');
      }
      assignments.add(ReplayAssignment(
        update: u.update,
        trackId: t.trackId,
        det: det,
        activated: t.isActivated,
      ));
    }
  }
  return ReplayResult(assignments, sightings, cmcFrames);
}

/// `tracker_assignments.csv`: one row per returned track per update.
String formatAssignments(List<ReplayAssignment> rows) {
  final sb = StringBuffer()..writeln('update,track_id,det,activated');
  for (final r in rows) {
    sb.writeln('${r.update},${r.trackId},${r.det},${r.activated ? 1 : 0}');
  }
  return sb.toString();
}

/// `tracker_colonies.csv`: the confirmed tracks, i.e. the colonies the app would count, with
/// first/last seen in seconds since the video start.
String formatColonies(ConfirmedSightings sightings) {
  final sb = StringBuffer()..writeln('track_id,first_seen_sec,last_seen_sec');
  for (final id in sightings.firstSeenAt.keys.toList()..sort()) {
    sb.writeln('$id,${secondsOf(sightings.firstSeenAt[id]!).toStringAsFixed(3)},'
        '${secondsOf(sightings.lastSeenAt[id]!).toStringAsFixed(3)}');
  }
  return sb.toString();
}
