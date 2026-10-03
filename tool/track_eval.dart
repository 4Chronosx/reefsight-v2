// Offline tracking harness for sub-plan 08 (mobile/sub-plans/08-botsort-accuracy.md): feeds
// notebook 02's detections (or notebook 01's GT boxes, with --oracle) through the app's real
// `BoTSortTracker` and writes MOTChallenge tracker output that
// tracking-validation/notebooks/03_tracking_metrics.ipynb scores with TrackEval.
//
//   dart run tool/track_eval.dart [options]
//
// Options (defaults = the tracker exactly as the app ships it today):
//   --stride N             GT/detection stride to evaluate (default 3, i.e. 25/3 = 8.33 Hz)
//   --split tune|test|all  which sequences (default tune; test is the held-out set -- run it once)
//   --gt-run ID            notebook 01 run (default: groundtruth/latest_run.txt)
//   --dets-run ID          notebook 02 run (default: detections/latest_run.txt)
//   --oracle               feed GT colony boxes (score 1.0) instead of detections
//   --name NAME            arm name for a single-arm run (default: "baseline", or the config label)
//   --sweep FILE.json      run every arm in a sweep spec (see expandSweep in src/track_eval_lib.dart)
//   --track-high X  --track-low X  --new-track X  --match X     tracker thresholds
//   --buffer N | --buffer-s SECONDS                              trackBuffer in updates or seconds
//   --det-floor X          confidence cutoff before the tracker (default 0.25, the plugin's)
//   --cmc                  camera motion compensation on (loads each frame as grayscale)
//   --cmc-downscale N      CameraMotionCompensator downscale (default 2)
//   --no-fuse-score        fuseScore off
//
// Output: tracking-validation/runs_tracking/tracker/<RUN_ID>/ with run.json, log.txt and
// stride<S>/CORALVOS-<split>/<arm>/data/<seq>.txt (TrackEval's tracker layout), plus
// runs_tracking/tracker/latest_run.txt, written last.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:reefsight_mobile/tracking/camera_motion_compensation.dart';
import 'package:reefsight_mobile/tracking/linalg.dart' as linalg;
import 'package:reefsight_mobile/tracking/tracker_detection.dart';

import 'src/track_eval_lib.dart';

const _valueOptions = {
  'stride', 'split', 'gt-run', 'dets-run', 'name', 'sweep', 'track-high', 'track-low',
  'new-track', 'match', 'buffer', 'buffer-s', 'det-floor', 'cmc-downscale',
};
const _flagOptions = {'oracle', 'cmc', 'no-fuse-score', 'help'};

Never _fail(String message) {
  stderr.writeln('track_eval: $message');
  exit(64);
}

(Map<String, String>, Set<String>) _parseArgs(List<String> args) {
  final values = <String, String>{};
  final flags = <String>{};
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (!a.startsWith('--')) _fail('unexpected argument "$a"');
    final key = a.substring(2);
    if (_flagOptions.contains(key)) {
      flags.add(key);
    } else if (_valueOptions.contains(key)) {
      if (i + 1 >= args.length) _fail('--$key needs a value');
      values[key] = args[++i];
    } else {
      _fail('unknown option --$key');
    }
  }
  return (values, flags);
}

Directory _repoRoot() {
  var dir = Directory.current.absolute;
  while (!Directory('${dir.path}/BoT-SORT').existsSync()) {
    final parent = dir.parent;
    if (parent.path == dir.path) _fail('could not find the repo root (no BoT-SORT/ above cwd)');
    dir = parent;
  }
  return dir;
}

String _runId(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}${two(t.month)}${two(t.day)}_${two(t.hour)}${two(t.minute)}${two(t.second)}';
}

String _resolveRun(Directory stageRoot, String? requested) {
  if (requested != null) return requested;
  final pointer = File('${stageRoot.path}/latest_run.txt');
  if (!pointer.existsSync()) _fail('no ${pointer.path} -- run the producing notebook first');
  return pointer.readAsStringSync().trim();
}

Map<String, dynamic> _readJson(String path) {
  final file = File(path);
  if (!file.existsSync()) _fail('missing $path');
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

double _num(Map<String, String> values, String key, double fallback) {
  final raw = values[key];
  if (raw == null) return fallback;
  return double.tryParse(raw) ?? _fail('--$key expects a number, got "$raw"');
}

/// Loads a source frame as a grayscale [GrayscaleFrame] for CMC, at the image's native resolution
/// (1280x720 for CoralVOS); the compensator downscales internally.
GrayscaleFrame _loadGray(String path) {
  final mat = cv.imread(path, flags: cv.IMREAD_GRAYSCALE);
  try {
    if (mat.isEmpty) _fail('could not read $path');
    return GrayscaleFrame(width: mat.cols, height: mat.rows, pixels: Uint8List.fromList(mat.data));
  } finally {
    mat.dispose();
  }
}

void main(List<String> args) {
  final (values, flags) = _parseArgs(args);
  if (flags.contains('help')) {
    stdout.writeln('See the header comment of tool/track_eval.dart for options.');
    return;
  }

  final repo = _repoRoot();
  final runsRoot = Directory('${repo.path}/tracking-validation/runs_tracking');
  final gtRun = _resolveRun(Directory('${runsRoot.path}/groundtruth'), values['gt-run']);
  final gtDir = '${runsRoot.path}/groundtruth/$gtRun';
  final gtResult = _readJson('$gtDir/result.json');
  final gtConfig = gtResult['config'] as Map<String, dynamic>;
  final benchmark = gtConfig['benchmark'] as String;
  final sourceFps = (gtConfig['source_fps'] as num).toDouble();
  final strides = (gtConfig['strides'] as List<dynamic>).cast<int>();

  final stride = int.tryParse(values['stride'] ?? '3') ?? _fail('--stride expects an integer');
  if (!strides.contains(stride)) _fail('GT run $gtRun has strides $strides, not $stride');
  final hz = sourceFps / stride;

  final split = values['split'] ?? 'tune';
  if (!{'tune', 'test', 'all'}.contains(split)) _fail('--split must be tune, test or all');
  final sequences = [
    for (final s in (gtResult['sequences'] as List<dynamic>).cast<Map<String, dynamic>>())
      if (split == 'all' || s['split'] == split) (s['seq'] as String, s['split'] as String),
  ];
  if (sequences.isEmpty) _fail('no $split sequences in GT run $gtRun');

  final oracle = flags.contains('oracle');
  String? detsRun;
  Map<String, dynamic>? detsResult;
  if (!oracle) {
    detsRun = _resolveRun(Directory('${runsRoot.path}/detections'), values['dets-run']);
    detsResult = _readJson('${runsRoot.path}/detections/$detsRun/result.json');
    if (detsResult['gt_run_id'] != gtRun) {
      _fail('detections run $detsRun was made on GT run ${detsResult['gt_run_id']}, not $gtRun '
          '-- re-run notebook 02 or pass matching --gt-run/--dets-run');
    }
  }

  final base = const EvalConfig().withOverrides({
    if (values.containsKey('track-high')) 'trackHighThresh': _num(values, 'track-high', 0),
    if (values.containsKey('track-low')) 'trackLowThresh': _num(values, 'track-low', 0),
    if (values.containsKey('new-track')) 'newTrackThresh': _num(values, 'new-track', 0),
    if (values.containsKey('match')) 'matchThresh': _num(values, 'match', 0),
    if (values.containsKey('buffer'))
      'trackBuffer': int.tryParse(values['buffer']!) ?? _fail('--buffer expects an integer'),
    if (values.containsKey('buffer-s')) 'trackBufferSeconds': _num(values, 'buffer-s', 0),
    if (values.containsKey('det-floor')) 'detFloor': _num(values, 'det-floor', 0),
    if (flags.contains('cmc')) 'cmc': true,
    if (flags.contains('no-fuse-score')) 'fuseScore': false,
  }, hz: hz);
  final cmcDownscale = int.tryParse(values['cmc-downscale'] ?? '2') ??
      _fail('--cmc-downscale expects an integer');

  final List<(String, EvalConfig)> arms;
  if (values.containsKey('sweep')) {
    arms = expandSweep(_readJson(values['sweep']!), base: base, hz: hz);
  } else {
    final isDefault = base.label == const EvalConfig().label;
    arms = [(values['name'] ?? (isDefault ? 'baseline' : base.label), base)];
  }
  final prefixed = [for (final (name, c) in arms) ((oracle ? 'oracle_' : '') + name, c)];

  final runId = _runId(DateTime.now());
  final outDir = Directory('${runsRoot.path}/tracker/$runId')..createSync(recursive: true);
  final logFile = File('${outDir.path}/log.txt');
  void log(String msg) {
    stdout.writeln(msg);
    logFile.writeAsStringSync('$msg\n', mode: FileMode.append);
  }

  log('RUN_ID = $runId');
  log('GT run $gtRun, stride $stride (${hz.toStringAsFixed(2)} Hz), split $split, '
      '${sequences.length} sequences');
  log(oracle
      ? 'Input: ORACLE (GT colony boxes, score 1.0)'
      : 'Input: detections run $detsRun (${detsResult!['stage_b_source']} '
          'run ${detsResult['stage_b_source_run']})');
  if (split != 'tune') {
    log('WARNING: split "$split" includes the held-out test set. Score it once, with the final '
        'configuration only (sub-plan 08, "Held-out means held out").');
  }

  // Inputs per sequence, parsed once and shared by every arm.
  final inputs = <String, (int, Map<int, List<TrackerDetection>>, List<String>)>{};
  for (final (seq, seqSplit) in sequences) {
    final seqDir = '$gtDir/gt/stride$stride/$benchmark-$seqSplit/$seq';
    final frameMap = File('$seqDir/frame_map.csv').readAsLinesSync().skip(1)
        .where((l) => l.trim().isNotEmpty).map((l) => l.split(',')).toList();
    for (var i = 0; i < frameMap.length; i++) {
      if (int.parse(frameMap[i][0]) != i + 1) _fail('$seq frame_map.csv is not contiguous');
    }
    final images = [for (final r in frameMap) '${repo.path}/${r[2]}'];
    final dets = oracle
        ? parseGtAsOracle(File('$seqDir/gt/gt.txt').readAsStringSync())
        : parseMotDetections(
            File('${runsRoot.path}/detections/$detsRun/stride$stride/$seq.txt').readAsStringSync());
    inputs[seq] = (frameMap.length, dets, images);
  }

  // CMC warps depend only on the frames, so they're estimated once per sequence and replayed in
  // every CMC arm (identical to live CMC -- see ReplayCompensator).
  final warps = <String, List<linalg.Matrix>>{};
  if (prefixed.any((a) => a.$2.cmc)) {
    final watch = Stopwatch()..start();
    for (final (seq, _) in sequences) {
      final (numFrames, _, images) = inputs[seq]!;
      warps[seq] = computeWarps(
        numFrames: numFrames,
        frameLoader: (f) => _loadGray(images[f - 1]),
        downscale: cmcDownscale,
      );
    }
    log('CMC warps estimated once for ${sequences.length} sequences '
        '(${(watch.elapsedMilliseconds / 1000).toStringAsFixed(1)} s), replayed in every CMC arm');
  }

  final armResults = <String, dynamic>{};
  for (final (name, config) in prefixed) {
    log('\n=== arm $name: ${jsonEncode(config.toJson(hz: hz))}');
    final perSeq = <String, dynamic>{};
    final watch = Stopwatch()..start();
    for (final (seq, seqSplit) in sequences) {
      final (numFrames, dets, images) = inputs[seq]!;
      final rows = runSequence(
        numFrames: numFrames,
        detections: dets,
        config: config,
        warps: config.cmc ? warps[seq] : null,
      );
      final dataDir = Directory('${outDir.path}/stride$stride/$benchmark-$seqSplit/$name/data')
        ..createSync(recursive: true);
      File('${dataDir.path}/$seq.txt').writeAsStringSync(formatMot(rows));
      final summary = summarize(rows);
      perSeq[seq] = {'split': seqSplit, ...summary};
      log('  $seq [$seqSplit]: ${summary['unique_ids']} track ids '
          '(${summary['unique_activated_ids']} ever activated), ${summary['rows']} boxes');
    }
    log('  (${(watch.elapsedMilliseconds / 1000).toStringAsFixed(1)} s)');
    armResults[name] = {'config': config.toJson(hz: hz), 'sequences': perSeq};
  }

  File('${outDir.path}/run.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert({
    'run_id': runId,
    'gt_run_id': gtRun,
    'detections_run_id': detsRun,
    'stage_b_source': detsResult?['stage_b_source'],
    'stage_b_source_run': detsResult?['stage_b_source_run'],
    'oracle': oracle,
    'stride': stride,
    'hz': hz,
    'split': split,
    'cmc_downscale': cmcDownscale,
    'benchmark': benchmark,
    'arms': armResults,
    'layout': 'stride<S>/<benchmark>-<split>/<arm>/data/<seq>.txt; rows '
        'frame,id,x,y,w,h,conf,-1,activated,-1 (every track BoTSortTracker.update returned)',
  }));
  File('${runsRoot.path}/tracker/latest_run.txt').writeAsStringSync('$runId\n');
  log('\nlatest_run.txt -> $runId');
}
