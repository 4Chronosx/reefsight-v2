import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import 'db_enum.dart';
import 'lens_calibration.dart';
import 'transect_frame.dart' show NormPoint;

/// Issue #14: the pool test's capture set (alignment doc §6, build order
/// step 2; protocol in `../docs/underwater-lens-calibration-protocol.md`).
///
/// Each still is saved with what notebook 31 needs to use it -- the lens,
/// air or water, what was photographed, the tape-measured distance, the tilt
/// -- in one `manifest.json` beside the photos, so no paper recording sheet
/// has to be matched up afterwards. The set is shared as one zip.
///
/// Layout (`<documents>/calibration_captures/`):
/// ```
/// <capture_id>/manifest.json
/// <capture_id>/shot_001.jpg ...
/// reefsight_calibration_<capture_id>.zip   (written on share)
/// ```
/// The loaded lens calibration lives apart from the sets, in
/// `<documents>/calibration/lens_calibration.json` ([LensCalibrationFile]).

const kCaptureManifestFormat = 'reefsight-calibration-captures';
const kCaptureManifestVersion = 1;

/// What a calibration still shows.
enum CalibrationTarget with DbEnum {
  /// The laminated checkerboard, at varied angles: fits the lens.
  checkerboard('checkerboard'),

  /// The 1 × 1 m square, flat, straight below at a measured distance:
  /// checks the fit (field of view against distance).
  square('square'),

  /// Laser dots on a flat surface at a measured distance: scores the
  /// distance method.
  laser('laser');

  const CalibrationTarget(this.db);
  @override
  final String db;
}

/// The laser pair found in a still, and the distance it gave with the
/// calibration loaded at the time (if any).
class LaserReading {
  const LaserReading({
    required this.ax,
    required this.ay,
    required this.bx,
    required this.by,
    required this.ambiguous,
    this.estimatedDistanceM,
    this.calibrationId,
  });

  /// The two dots, full-resolution pixels of the saved still.
  final double ax, ay, bx, by;
  final bool ambiguous;
  final double? estimatedDistanceM;
  final String? calibrationId;

  Map<String, Object?> toJson() => {
        'ax': ax,
        'ay': ay,
        'bx': bx,
        'by': by,
        'ambiguous': ambiguous,
        if (estimatedDistanceM != null) 'estimated_distance_m': estimatedDistanceM,
        if (calibrationId != null) 'calibration_id': calibrationId,
      };

  static LaserReading fromJson(Map<dynamic, dynamic> j) => LaserReading(
        ax: _req(j, 'ax'),
        ay: _req(j, 'ay'),
        bx: _req(j, 'bx'),
        by: _req(j, 'by'),
        ambiguous: j['ambiguous'] == true,
        estimatedDistanceM: _opt(j, 'estimated_distance_m'),
        calibrationId: j['calibration_id'] is String ? j['calibration_id'] as String : null,
      );
}

class CalibrationShot {
  const CalibrationShot({
    required this.file,
    required this.lens,
    required this.medium,
    required this.target,
    required this.capturedAt,
    this.knownDistanceM,
    this.tiltDeg,
    this.squareCorners,
    this.laser,
  });

  /// The still's file name inside the set's folder.
  final String file;
  final CameraLens lens;
  final CalibrationMedium medium;
  final CalibrationTarget target;
  final DateTime capturedAt;

  /// Tape-measured camera-to-target distance (lens to the target's plane).
  final double? knownDistanceM;
  final double? tiltDeg;

  /// The 1 m square's corners as marked on the phone (TL, TR, BR, BL),
  /// normalized like `transect_frames.corners_json`.
  final List<NormPoint>? squareCorners;
  final LaserReading? laser;

  CalibrationShot copyWith({String? file, List<NormPoint>? squareCorners, LaserReading? laser}) => CalibrationShot(
        file: file ?? this.file,
        lens: lens,
        medium: medium,
        target: target,
        capturedAt: capturedAt,
        knownDistanceM: knownDistanceM,
        tiltDeg: tiltDeg,
        squareCorners: squareCorners ?? this.squareCorners,
        laser: laser ?? this.laser,
      );

  Map<String, Object?> toJson() => {
        'file': file,
        'lens': lens.db,
        'medium': medium.db,
        'target': target.db,
        'captured_at': capturedAt.toIso8601String(),
        if (knownDistanceM != null) 'known_distance_m': knownDistanceM,
        if (tiltDeg != null) 'tilt_deg': tiltDeg,
        if (squareCorners != null) 'square_corners': [for (final c in squareCorners!) [c.x, c.y]],
        if (laser != null) 'laser': laser!.toJson(),
      };

  static CalibrationShot fromJson(Object? raw) {
    if (raw is! Map) throw const FormatException('each shot must be an object');
    final file = raw['file'];
    if (file is! String || !_safeName.hasMatch(file)) throw FormatException('bad shot file name: $file');
    final lens = enumFromDb(CameraLens.values, raw['lens']);
    final medium = enumFromDb(CalibrationMedium.values, raw['medium']);
    final target = enumFromDb(CalibrationTarget.values, raw['target']);
    if (lens == null || medium == null || target == null) {
      throw FormatException('shot $file: unknown lens, medium or target');
    }
    final at = raw['captured_at'];
    final capturedAt = at is String ? DateTime.tryParse(at) : null;
    if (capturedAt == null) throw FormatException('shot $file: bad captured_at');
    final rawCorners = raw['square_corners'];
    List<NormPoint>? corners;
    if (rawCorners != null) {
      if (rawCorners is! List || rawCorners.length != 4) throw FormatException('shot $file: four corners expected');
      corners = [
        for (final c in rawCorners)
          if (c is List && c.length == 2 && c[0] is num && c[1] is num)
            (x: (c[0] as num).toDouble(), y: (c[1] as num).toDouble())
          else
            throw FormatException('shot $file: bad corner'),
      ];
    }
    final laser = raw['laser'];
    return CalibrationShot(
      file: file,
      lens: lens,
      medium: medium,
      target: target,
      capturedAt: capturedAt,
      knownDistanceM: _opt(raw, 'known_distance_m'),
      tiltDeg: _opt(raw, 'tilt_deg'),
      squareCorners: corners,
      laser: laser is Map ? LaserReading.fromJson(laser) : null,
    );
  }
}

/// Plain file names only: a manifest can't point outside its folder.
final _safeName = RegExp(r'^[A-Za-z0-9_-][A-Za-z0-9_.-]*\.jpe?g$');

double _req(Map<dynamic, dynamic> j, String key) {
  final v = j[key];
  if (v is! num || !v.isFinite) throw FormatException('$key must be a finite number');
  return v.toDouble();
}

double? _opt(Map<dynamic, dynamic> j, String key) {
  final v = j[key];
  if (v == null) return null;
  if (v is! num || !v.isFinite) throw FormatException('$key must be a finite number');
  return v.toDouble();
}

class CaptureManifest {
  CaptureManifest({required this.captureId, required this.created, this.laserBaselineM, List<CalibrationShot>? shots})
      : shots = shots ?? [];

  final String captureId;
  final DateTime created;

  /// Centre-to-centre spacing of the two lasers, measured on the housing.
  double? laserBaselineM;
  final List<CalibrationShot> shots;

  Map<String, Object?> toJson() => {
        'format': kCaptureManifestFormat,
        'version': kCaptureManifestVersion,
        'capture_id': captureId,
        'created': created.toIso8601String(),
        if (laserBaselineM != null) 'laser_baseline_m': laserBaselineM,
        'shots': [for (final s in shots) s.toJson()],
      };

  static CaptureManifest parse(String text) {
    final Object? root;
    try {
      root = jsonDecode(text);
    } on FormatException {
      throw const FormatException('manifest is not JSON');
    }
    if (root is! Map || root['format'] != kCaptureManifestFormat) {
      throw const FormatException('not a calibration capture manifest');
    }
    final version = root['version'];
    if (version is! int || version < 1 || version > kCaptureManifestVersion) {
      throw FormatException('unsupported manifest version: $version');
    }
    final id = root['capture_id'];
    final created = root['created'] is String ? DateTime.tryParse(root['created'] as String) : null;
    if (id is! String || id.isEmpty || created == null) throw const FormatException('manifest id or date missing');
    final shots = root['shots'];
    if (shots is! List) throw const FormatException('manifest has no shot list');
    return CaptureManifest(
      captureId: id,
      created: created,
      laserBaselineM: _opt(root, 'laser_baseline_m'),
      shots: [for (final s in shots) CalibrationShot.fromJson(s)],
    );
  }
}

String _stamp(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}${two(t.month)}${two(t.day)}_${two(t.hour)}${two(t.minute)}${two(t.second)}';
}

/// One capture set on disk. Every change rewrites `manifest.json` through a
/// temp file and a rename, so a crash mid-write leaves the previous manifest.
class CalibrationCaptureStore {
  CalibrationCaptureStore._(this.directory, this.manifest);

  final Directory directory;
  final CaptureManifest manifest;

  String get captureId => manifest.captureId;

  static String capturesRoot(String documentsPath) => p.join(documentsPath, 'calibration_captures');

  /// Starts a new set, named by the time (`yyyyMMdd_HHmmss`, the notebooks'
  /// `RUN_ID` style); a second set in the same second gets a suffix.
  static Future<CalibrationCaptureStore> create(String documentsPath, {DateTime? now}) async {
    final created = now ?? DateTime.now();
    final base = _stamp(created);
    final root = capturesRoot(documentsPath);
    var id = base;
    for (var n = 2; await Directory(p.join(root, id)).exists(); n++) {
      id = '${base}_$n';
    }
    final dir = await Directory(p.join(root, id)).create(recursive: true);
    final store = CalibrationCaptureStore._(dir, CaptureManifest(captureId: id, created: created));
    await store._save();
    return store;
  }

  /// Reopens a set; throws [FormatException] on a bad manifest.
  static Future<CalibrationCaptureStore> open(String directoryPath) async {
    final dir = Directory(directoryPath);
    final manifest = CaptureManifest.parse(await File(p.join(dir.path, 'manifest.json')).readAsString());
    return CalibrationCaptureStore._(dir, manifest);
  }

  /// The sets on the phone, newest first.
  static Future<List<String>> listSets(String documentsPath) async {
    final root = Directory(capturesRoot(documentsPath));
    if (!await root.exists()) return const [];
    final dirs = [
      await for (final e in root.list())
        if (e is Directory && await File(p.join(e.path, 'manifest.json')).exists()) e.path,
    ]..sort((a, b) => b.compareTo(a));
    return dirs;
  }

  String pathOf(CalibrationShot shot) => p.join(directory.path, shot.file);

  /// Copies the camera's temp still into the set as the next `shot_NNN.jpg`
  /// and records [shot] (its `file` is filled in here).
  Future<CalibrationShot> addShot(String tempJpegPath, CalibrationShot shot) async {
    final name = 'shot_${(manifest.shots.length + 1).toString().padLeft(3, '0')}.jpg';
    final target = p.join(directory.path, name);
    final staged = File('$target.tmp');
    await File(tempJpegPath).copy(staged.path);
    await staged.rename(target);
    final saved = shot.copyWith(file: name);
    manifest.shots.add(saved);
    await _save();
    return saved;
  }

  Future<void> updateShot(int index, CalibrationShot shot) async {
    if (shot.file != manifest.shots[index].file) throw ArgumentError('a shot keeps its file');
    manifest.shots[index] = shot;
    await _save();
  }

  Future<void> setLaserBaseline(double metres) async {
    if (!(metres > 0 && metres < 1)) throw ArgumentError.value(metres, 'metres', 'must be between 0 and 1 m');
    manifest.laserBaselineM = metres;
    await _save();
  }

  /// Zips the set (stored, not deflated: JPEGs don't compress) beside the
  /// set folders; returns its path.
  Future<String> writeZip() async {
    final zipPath = p.join(directory.parent.path, 'reefsight_calibration_$captureId.zip');
    final encoder = ZipFileEncoder();
    encoder.create(zipPath, level: DeflateLevel.none);
    try {
      await encoder.addFile(File(p.join(directory.path, 'manifest.json')), '$captureId/manifest.json');
      for (final s in manifest.shots) {
        await encoder.addFile(File(pathOf(s)), '$captureId/${s.file}');
      }
    } finally {
      await encoder.close();
    }
    return zipPath;
  }

  Future<void> _save() async {
    final target = p.join(directory.path, 'manifest.json');
    final staged = File('$target.tmp');
    await staged.writeAsString(const JsonEncoder.withIndent('  ').convert(manifest.toJson()), flush: true);
    await staged.rename(target);
  }
}

/// A calibration file is a few kB; anything far larger is the wrong file.
const kMaxCalibrationFileBytes = 256 * 1024;

/// The lens calibration the phone measures with: imported from notebook 31's
/// `lens_calibration.json` (AirDrop / Files), validated, then kept in app
/// storage. A bad import never replaces the one already loaded.
class LensCalibrationFile {
  LensCalibrationFile(this.documentsPath);

  final String documentsPath;

  String get path => p.join(documentsPath, 'calibration', 'lens_calibration.json');

  /// The saved calibration, or `null` when none was imported. A saved file
  /// that no longer parses (written by a newer app) also reads as `null`.
  Future<LensCalibration?> load() async {
    final file = File(path);
    if (!await file.exists()) return null;
    try {
      return LensCalibration.parse(await file.readAsString());
    } on FormatException {
      return null;
    }
  }

  /// Validates [sourcePath] and saves it as the calibration. Throws
  /// [FormatException] for a file that isn't a valid calibration.
  Future<LensCalibration> import(String sourcePath) async {
    final source = File(sourcePath);
    if (await source.length() > kMaxCalibrationFileBytes) {
      throw const FormatException('file is too large to be a lens calibration');
    }
    final text = await source.readAsString();
    final calibration = LensCalibration.parse(text);
    final target = File(path);
    await target.parent.create(recursive: true);
    final staged = File('$path.tmp');
    await staged.writeAsString(text, flush: true);
    await staged.rename(target.path);
    return calibration;
  }
}
