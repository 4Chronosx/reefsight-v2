// Tracker replay for notebook 27 (machine-learning-pipeline/notebooks/27_cordova_offline_pipeline.ipynb,
// sub-plans/ml-03-cordova-end-to-end-eval.md step 4): feeds each clip's detections from the
// notebook's pass 1 through the app's real tracker -- built by `TrackerConfig.build`, with camera
// motion compensation -- and tallies colonies with the app's `ConfirmedSightings`, so the colony
// list is the shipped code's, not a Python reimplementation's.
//
//   dart run tool/cordova_replay.dart --run-dir <notebook 27 run folder>
//
// Reads, per clip folder <run-dir>/clips/<clip>/:
//   replay_input.json   {"hz", "frame_width", "frame_height", ...} written by the notebook
//   updates.csv         update,frame_idx,t_sec        (one row per tracker update, 1-based)
//   dets.csv            update,det,x1,y1,x2,y2,conf   (detections in full-frame pixels)
//   cmc/u<update>.png   the update's frame, grayscale, at the reduced size `decodeCmcFrame` would
//                       produce on the phone (optional per update: missing = no CMC that update)
// Writes, per clip folder:
//   tracker_assignments.csv   update,track_id,det,activated   (every track update() returned)
//   tracker_colonies.csv      track_id,first_seen_sec,last_seen_sec   (confirmed tracks = colonies)
//   tracker_replay.json       tracker settings and counts
// plus <run-dir>/tracker_replay_log.txt. Re-running overwrites these outputs, never the inputs.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:reefsight_mobile/tracking/cmc_frames.dart';
import 'package:reefsight_mobile/tracking/tracker_config.dart';

import 'src/cordova_replay_lib.dart';

Never _fail(String message) {
  stderr.writeln('cordova_replay: $message');
  exit(64);
}

/// The update's CMC frame as a [ScaledGrayscaleFrame], as `decodeCmcFrame` hands it to the
/// tracker on the phone; `null` if the file is missing or unreadable.
ScaledGrayscaleFrame? _loadCmcFrame(String path, int fullWidth) {
  if (!File(path).existsSync()) return null;
  final mat = cv.imread(path, flags: cv.IMREAD_GRAYSCALE);
  try {
    if (mat.isEmpty || mat.cols == 0) return null;
    return ScaledGrayscaleFrame(
      width: mat.cols,
      height: mat.rows,
      pixels: Uint8List.fromList(mat.data),
      scale: fullWidth / mat.cols,
    );
  } finally {
    mat.dispose();
  }
}

void main(List<String> args) {
  String? runDirArg;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--run-dir' && i + 1 < args.length) {
      runDirArg = args[++i];
    } else if (args[i] == '--help') {
      stdout.writeln('See the header comment of tool/cordova_replay.dart.');
      return;
    } else {
      _fail('unknown argument "${args[i]}" (expected --run-dir PATH)');
    }
  }
  if (runDirArg == null) _fail('--run-dir PATH is required');
  final runDir = Directory(runDirArg);
  final clipsDir = Directory('${runDir.path}/clips');
  if (!clipsDir.existsSync()) _fail('no ${clipsDir.path} -- run notebook 27 pass 1 first');

  final logFile = File('${runDir.path}/tracker_replay_log.txt');
  if (logFile.existsSync()) logFile.deleteSync();
  void log(String msg) {
    stdout.writeln(msg);
    logFile.writeAsStringSync('$msg\n', mode: FileMode.append);
  }

  final clips = clipsDir.listSync().whereType<Directory>()
      .where((d) => File('${d.path}/replay_input.json').existsSync()).toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  if (clips.isEmpty) _fail('no clip folders with replay_input.json under ${clipsDir.path}');

  log('cordova_replay ${DateTime.now().toIso8601String()} on ${runDir.path}');
  log('Tracker: TrackerConfig (trackHigh ${TrackerConfig.trackHighThresh}, trackLow '
      '${TrackerConfig.trackLowThresh}, newTrack ${TrackerConfig.newTrackThresh}, match '
      '${TrackerConfig.matchThresh}, buffer ${TrackerConfig.trackBufferSeconds}s, cmc ${TrackerConfig.cmc}), '
      'colonies = ConfirmedSightings');

  final summary = <String, dynamic>{};
  for (final clip in clips) {
    final name = clip.uri.pathSegments.where((s) => s.isNotEmpty).last;
    final input = jsonDecode(File('${clip.path}/replay_input.json').readAsStringSync()) as Map<String, dynamic>;
    final hz = (input['hz'] as num).toDouble();
    final fullWidth = (input['frame_width'] as num).toInt();
    final updates = parseUpdates(File('${clip.path}/updates.csv').readAsStringSync());
    final detections = parseDetections(File('${clip.path}/dets.csv').readAsStringSync());

    final watch = Stopwatch()..start();
    final result = replayClip(
      updates: updates,
      detections: detections,
      hz: hz,
      frameFor: (u) => _loadCmcFrame('${clip.path}/cmc/u${u.toString().padLeft(6, '0')}.png', fullWidth),
    );
    File('${clip.path}/tracker_assignments.csv').writeAsStringSync(formatAssignments(result.assignments));
    File('${clip.path}/tracker_colonies.csv').writeAsStringSync(formatColonies(result.sightings));

    final nDets = detections.values.fold<int>(0, (n, d) => n + d.length);
    final clipSummary = {
      'hz': hz,
      'track_buffer_updates': TrackerConfig.trackBufferFor(hz),
      'updates': updates.length,
      'cmc_frames': result.cmcFrames,
      'detections': nDets,
      'track_ids_returned': result.assignments.map((a) => a.trackId).toSet().length,
      'colonies': result.sightings.firstSeenAt.length,
      'seconds': watch.elapsedMilliseconds / 1000,
    };
    File('${clip.path}/tracker_replay.json')
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(clipSummary));
    summary[name] = clipSummary;
    log('[$name] ${updates.length} updates (${result.cmcFrames} with CMC), $nDets detections -> '
        '${clipSummary['colonies']} colonies (${clipSummary['track_ids_returned']} track ids incl. '
        'unconfirmed), ${clipSummary['seconds']} s');
    if (result.cmcFrames < updates.length) {
      log('  WARNING: ${updates.length - result.cmcFrames} updates had no CMC frame');
    }
  }
  log('Done: ${summary.length} clips, '
      '${summary.values.fold<int>(0, (n, s) => n + (s['colonies'] as int))} colonies');
}
