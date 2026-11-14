import 'dart:convert';

import 'package:path/path.dart' as p;

import 'cover_calculator.dart';
import 'frame_point.dart';
import 'point_sampler.dart';
import 'station.dart';
import 'transect_frame.dart';
import 'transect_session.dart';

/// Issue #7: the two files exchanged with the laptop notebook
/// (`machine-learning-pipeline/notebooks/28_coralscapes_laptop_cover.ipynb`)
/// while the cover segmenter can't run on the phone.
///
/// - The **manifest** (app -> laptop) lists each scorable frame of a station's
///   photo transects: its photo, its four corners, and its sampled points,
///   each with its position in the 1 × 1 m area and in the photo. The app
///   places the points (`ensureFramePoints`), so the notebook needs neither
///   the seeded sampler nor the homography -- it recomputes the photo
///   positions only to check them.
/// - The **results** (laptop -> app) give each point the model's raw class
///   and confidence. The app maps classes to TB codes through `category_map`,
///   so the mapping lives in one place.
///
/// Pure: no IO. Zipping and sharing are in `laptop_analysis.dart`, the
/// checks against the database in `TransectDatabase.applyAnalysisResults`.
/// The format is specified in `docs/laptop-analysis-exchange-format.md`.

const kManifestFormat = 'reefsight-analysis';
const kResultsFormat = 'reefsight-analysis-results';
const kAnalysisFormatVersion = 1;

/// One transect's rows, as read from the database.
typedef ManifestTransect = ({TransectSession session, List<TransectFrame> frames, List<FramePoint> points});

/// A photo to put in the package: [imagePath] as stored (relative to the
/// documents directory), [entry] its name inside the package.
typedef ManifestImage = ({String imagePath, String entry});

class AnalysisManifest {
  const AnalysisManifest(this.json, this.images);

  /// `manifest.json`'s content.
  final Map<String, Object?> json;

  /// The photos it refers to, in manifest order.
  final List<ManifestImage> images;

  /// The number of points sent.
  int get pointCount => [
        for (final t in json['transects'] as List)
          for (final f in (t as Map)['frames'] as List) ((f as Map)['points'] as List).length,
      ].fold(0, (a, b) => a + b);
}

/// Frames that are excluded, have no photo or corners, or have no points
/// yet are left out; so is a transect left with no frames.
AnalysisManifest buildAnalysisManifest({
  required Station station,
  required List<ManifestTransect> transects,
  required String modelId,
  required DateTime exportedAt,
}) {
  final images = <ManifestImage>[];
  final transectJson = <Map<String, Object?>>[];
  for (final t in transects) {
    final byFrame = <int, List<FramePoint>>{};
    for (final point in t.points) {
      (byFrame[point.frameId] ??= []).add(point);
    }
    final frames = <Map<String, Object?>>[];
    for (final frame in t.frames) {
      final corners = frame.corners;
      final points = byFrame[frame.id];
      if (frame.excluded || frame.imagePath.isEmpty || corners == null || points == null) continue;
      points.sort((a, b) => a.pointIndex.compareTo(b.pointIndex));
      final entry = 'photos/T${t.session.transectNumber ?? t.session.id}/'
          '${_frameName(frame)}${_extension(frame.imagePath)}';
      images.add((imagePath: frame.imagePath, entry: entry));
      frames.add({
        'frame_id': frame.id,
        'meter_mark': frame.meterMark,
        'video_time_ms': frame.videoTimeMs,
        'image': entry,
        'width_px': frame.widthPx,
        'height_px': frame.heightPx,
        'corners': [for (final c in corners) [c.x, c.y]],
        'points': [for (final point in points) _pointJson(corners, point)],
      });
    }
    if (frames.isEmpty) continue;
    transectJson.add({
      'session_id': t.session.id,
      'transect_number': t.session.transectNumber,
      'point_seed': t.session.pointSeed,
      'points_per_frame': t.session.pointsPerFrame,
      'frames': frames,
    });
  }
  final d = station.surveyedOn;
  return AnalysisManifest({
    'format': kManifestFormat,
    'version': kAnalysisFormatVersion,
    'exported_at': exportedAt.toUtc().toIso8601String(),
    'model_id': modelId,
    'station': {
      'id': station.id,
      'code': station.code,
      'name': station.name,
      'site_name': station.siteName,
      'surveyed_on': '${d.year.toString().padLeft(4, '0')}-${_two(d.month)}-${_two(d.day)}',
      'survey_type': station.surveyType.db,
    },
    'transects': transectJson,
  }, images);
}

Map<String, Object?> _pointJson(List<NormPoint> corners, FramePoint point) {
  final img = frameToImage(corners, (x: point.xNorm, y: point.yNorm));
  return {
    'point_id': point.id,
    'index': point.pointIndex,
    'u': point.xNorm,
    'v': point.yNorm,
    'img_x': img.x,
    'img_y': img.y,
  };
}

String _two(int n) => n.toString().padLeft(2, '0');

/// `m00`, `m12_5`; a frame with no meter mark (never on a photo transect)
/// falls back to its id.
String _frameName(TransectFrame frame) {
  final m = frame.meterMark;
  if (m == null) return 'f${frame.id}';
  if (m == m.roundToDouble()) return 'm${_two(m.round())}';
  return 'm${_two(m.truncate())}_${m.toString().split('.').last}';
}

String _extension(String path) {
  final ext = p.extension(path).toLowerCase();
  return ext.isEmpty ? '.jpg' : ext;
}

// ---------------------------------------------------------------- results

class PointResult {
  const PointResult({required this.pointId, required this.modelClass, this.confidence});

  final int pointId;

  /// The model's class at the point, exactly as in its `id2label`.
  final String modelClass;

  /// The class's softmax probability at the point, 0-1.
  final double? confidence;
}

class FrameResults {
  const FrameResults({required this.frameId, required this.corners, required this.points});

  final int frameId;

  /// The corners the notebook used, as sent: a frame whose corners have
  /// changed in the app since is stale (its points were resampled).
  final List<NormPoint> corners;
  final List<PointResult> points;
}

class TransectResults {
  const TransectResults({required this.sessionId, required this.pointSeed, required this.frames});

  final int sessionId;
  final int pointSeed;
  final List<FrameResults> frames;
}

/// What [TransectDatabase.applyAnalysisResults] did to one transect.
class AnalysisImport {
  const AnalysisImport({
    required this.sessionId,
    required this.pointsLabeled,
    required this.staleFrameIds,
    required this.cover,
    required this.complete,
  });

  final int sessionId;
  final int pointsLabeled;

  /// Frames skipped because they changed after the export (corners moved,
  /// retaken, deleted): export and analyze again to label them.
  final List<int> staleFrameIds;

  /// The rebuilt cover, counts included; no rows unless [complete].
  final CoverComputation cover;

  /// Every scorable frame of the transect has points, nothing was stale,
  /// every point is labeled and at least one counts: the analysis is `done`.
  final bool complete;
}

class AnalysisResults {
  const AnalysisResults({required this.modelId, this.runId, this.modelRevision, required this.transects});

  final String modelId;

  /// The notebook run (`runs_cover/<run_id>/`) and the Hugging Face commit
  /// of the weights, for the record.
  final String? runId;
  final String? modelRevision;
  final List<TransectResults> transects;
}

/// Reads a results file, checking its shape; throws a [FormatException]
/// saying what's wrong. Whether its ids, seeds and classes match this
/// phone's data is checked by `TransectDatabase.applyAnalysisResults`.
AnalysisResults parseAnalysisResults(String text) {
  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException {
    throw const FormatException('Not a JSON file');
  }
  final root = _map(decoded, 'the file');
  if (root['format'] != kResultsFormat) {
    throw FormatException(root['format'] == kManifestFormat
        ? 'This is the exported manifest, not the results file'
        : 'Not a ReefSight analysis results file');
  }
  final version = root['version'];
  if (version != kAnalysisFormatVersion) {
    throw FormatException('Results format version $version is not supported (expected $kAnalysisFormatVersion)');
  }
  final transects = _list(root['transects'], 'transects');
  if (transects.isEmpty) throw const FormatException('The results file has no transects');
  final sessions = <int>{};
  final parsed = <TransectResults>[];
  for (final (i, raw) in transects.indexed) {
    final t = _map(raw, 'transect ${i + 1}');
    final sessionId = _int(t['session_id'], 'session_id');
    if (!sessions.add(sessionId)) throw FormatException('Transect $sessionId appears twice');
    final frameIds = <int>{};
    final frames = <FrameResults>[];
    for (final rawFrame in _list(t['frames'], 'frames of transect $sessionId')) {
      final f = _map(rawFrame, 'a frame of transect $sessionId');
      final frameId = _int(f['frame_id'], 'frame_id');
      if (!frameIds.add(frameId)) throw FormatException('Frame $frameId appears twice');
      frames.add(FrameResults(
        frameId: frameId,
        corners: _corners(f['corners'], frameId),
        points: _points(f['points'], frameId),
      ));
    }
    parsed.add(TransectResults(
      sessionId: sessionId,
      pointSeed: _int(t['point_seed'], 'point_seed of transect $sessionId'),
      frames: frames,
    ));
  }
  return AnalysisResults(
    modelId: _string(root['model_id'], 'model_id'),
    runId: _optString(root['run_id'], 'run_id'),
    modelRevision: _optString(root['model_revision'], 'model_revision'),
    transects: parsed,
  );
}

List<NormPoint> _corners(Object? raw, int frameId) {
  final list = _list(raw, 'corners of frame $frameId');
  if (list.length != 4) throw FormatException('Frame $frameId has ${list.length} corners, not 4');
  final corners = <NormPoint>[];
  for (final c in list) {
    final pair = _list(c, 'a corner of frame $frameId');
    if (pair.length != 2 || pair.any((v) => v is! num)) {
      throw FormatException('A corner of frame $frameId is not an [x, y] pair');
    }
    corners.add((x: (pair[0] as num).toDouble(), y: (pair[1] as num).toDouble()));
  }
  return corners;
}

List<PointResult> _points(Object? raw, int frameId) {
  final ids = <int>{};
  final points = <PointResult>[];
  for (final rawPoint in _list(raw, 'points of frame $frameId')) {
    final pt = _map(rawPoint, 'a point of frame $frameId');
    final id = _int(pt['point_id'], 'point_id');
    if (!ids.add(id)) throw FormatException('Point $id appears twice');
    final cls = _string(pt['model_class'], 'model_class of point $id');
    final conf = pt['confidence'];
    if (conf != null && (conf is! num || conf < 0 || conf > 1)) {
      throw FormatException('Point $id has confidence $conf, outside 0-1');
    }
    points.add(PointResult(pointId: id, modelClass: cls, confidence: (conf as num?)?.toDouble()));
  }
  return points;
}

Map<String, Object?> _map(Object? v, String what) =>
    v is Map ? v.cast<String, Object?>() : throw FormatException('Expected an object for $what');

List<Object?> _list(Object? v, String what) =>
    v is List ? v.cast<Object?>() : throw FormatException('Expected a list for $what');

int _int(Object? v, String what) => v is int ? v : throw FormatException('Expected a whole number for $what');

String _string(Object? v, String what) =>
    v is String && v.trim().isNotEmpty ? v : throw FormatException('Expected text for $what');

String? _optString(Object? v, String what) => v == null ? null : _string(v, what);
