import 'dart:convert';

import 'db_enum.dart';

/// Issue #14: the underwater lens calibration (alignment doc §6, build order
/// step 2). The housing's flat window bends light at the glass, so the
/// lens's field of view and distortion underwater differ from in air (about
/// 1.33× narrower near the centre). Notebook 31
/// (`machine-learning-pipeline/notebooks/31_underwater_lens_calibration.ipynb`)
/// fits OpenCV's pinhole + Brown-Conrady model to checkerboard photos taken
/// through the housing in a pool, per lens and medium, and writes this file.
/// The diver loads it on the phone (Settings → Diagnostics → Lens
/// calibration), so a new calibration needs no app rebuild.
///
/// Coordinates are those of the still **as saved**: portrait, the shape
/// `StillCamera` locks every capture to. Reasoning and the pool protocol:
/// `../docs/underwater-lens-calibration-and-distance.md`.

/// The file's `format` tag, so another JSON file picked by mistake is
/// refused rather than half-read.
const kLensCalibrationFormat = 'reefsight-lens-calibration';

/// The newest file version this app reads.
const kLensCalibrationVersion = 1;

/// The iPhone 14's two back lenses.
enum CameraLens with DbEnum {
  /// The 1× wide lens (26 mm equivalent).
  main('main'),

  /// The 0.5× ultra-wide (13 mm equivalent), strong barrel distortion.
  ultraWide('ultra_wide');

  const CameraLens(this.db);
  @override
  final String db;
}

/// What the camera looked through when calibrated. Only `water` is used for
/// measuring; `air` is kept to show how much the housing changes the lens.
enum CalibrationMedium with DbEnum {
  air('air'),
  water('water');

  const CalibrationMedium(this.db);
  @override
  final String db;
}

/// A point on the undistorted normalized image plane (x = X/Z, y = Y/Z for a
/// point at camera coordinates X, Y, Z), or a pixel position.
typedef PlanePoint = ({double x, double y});

/// One lens's intrinsics: OpenCV's camera matrix and its five distortion
/// coefficients `[k1, k2, p1, p2, k3]`.
class LensIntrinsics {
  LensIntrinsics({
    required this.lens,
    required this.medium,
    required this.imageWidth,
    required this.imageHeight,
    required this.fx,
    required this.fy,
    required this.cx,
    required this.cy,
    required List<double> distortion,
    this.rmsPx,
    this.imagesUsed,
  }) : distortion = List.unmodifiable(distortion) {
    if (this.distortion.length != 5) {
      throw ArgumentError.value(distortion, 'distortion', 'needs [k1, k2, p1, p2, k3]');
    }
  }

  final CameraLens lens;
  final CalibrationMedium medium;
  final int imageWidth;
  final int imageHeight;
  final double fx, fy, cx, cy;
  final List<double> distortion;

  /// The calibration's RMS reprojection error, in pixels.
  final double? rmsPx;
  final int? imagesUsed;

  double get _k1 => distortion[0];
  double get _k2 => distortion[1];
  double get _p1 => distortion[2];
  double get _p2 => distortion[3];
  double get _k3 => distortion[4];

  /// Applies the distortion to an undistorted normalized point.
  PlanePoint distortNormalized(double x, double y) {
    final r2 = x * x + y * y;
    final radial = 1 + r2 * (_k1 + r2 * (_k2 + r2 * _k3));
    return (
      x: x * radial + 2 * _p1 * x * y + _p2 * (r2 + 2 * x * x),
      y: y * radial + _p1 * (r2 + 2 * y * y) + 2 * _p2 * x * y,
    );
  }

  /// Where an undistorted normalized point lands in the image, in pixels.
  PlanePoint projectNormalized(double x, double y) {
    final d = distortNormalized(x, y);
    return (x: fx * d.x + cx, y: fy * d.y + cy);
  }

  /// The undistorted normalized point a pixel came from: the inverse of
  /// [projectNormalized]. Newton's method on the distortion polynomial
  /// (OpenCV's own fixed-point iteration converges slowly at the edge of an
  /// ultra-wide). Throws [RangeError] where the polynomial folds back -- past
  /// the edge of the range the calibration was fitted on.
  PlanePoint undistortPixel(double u, double v) {
    final xd = (u - cx) / fx, yd = (v - cy) / fy;
    var x = xd, y = yd;
    for (var i = 0; i < 50; i++) {
      final d = distortNormalized(x, y);
      final ex = d.x - xd, ey = d.y - yd;
      if (ex.abs() < 1e-14 && ey.abs() < 1e-14) break;
      final r2 = x * x + y * y;
      final radial = 1 + r2 * (_k1 + r2 * (_k2 + r2 * _k3));
      final dRadial = _k1 + r2 * (2 * _k2 + 3 * r2 * _k3);
      // The Jacobian of distortNormalized at (x, y).
      final a = radial + 2 * x * x * dRadial + 2 * _p1 * y + 6 * _p2 * x;
      final b = 2 * x * y * dRadial + 2 * _p1 * x + 2 * _p2 * y;
      final d2 = radial + 2 * y * y * dRadial + 6 * _p1 * y + 2 * _p2 * x;
      final det = a * d2 - b * b;
      if (det.abs() < 1e-12 || !det.isFinite) break;
      x -= (d2 * ex - b * ey) / det;
      y -= (a * ey - b * ex) / det;
      if (!x.isFinite || !y.isFinite) break;
    }
    final d = distortNormalized(x, y);
    if (x.isFinite && y.isFinite && (d.x - xd).abs() < 1e-9 && (d.y - yd).abs() < 1e-9 && _onRisingBranch(x, y)) {
      return (x: x, y: y);
    }
    throw RangeError('pixel ($u, $v) is outside the calibrated range of the ${lens.db} lens');
  }

  bool _onRisingBranch(double x, double y) {
    final r2 = x * x + y * y;
    final radial = 1 + r2 * (_k1 + r2 * (_k2 + r2 * _k3));
    final dRadial = _k1 + r2 * (2 * _k2 + 3 * r2 * _k3);
    // r_d = r · radial(r²) must still be increasing in r: past its peak the
    // polynomial folds back and maps outer rays onto inner pixels (or mirrors
    // them through the centre) -- a root of the equation, not a real ray.
    return radial > 0 && radial + 2 * r2 * dRadial > 0;
  }

  Map<String, Object?> toJson() => {
        'lens': lens.db,
        'medium': medium.db,
        'image_width': imageWidth,
        'image_height': imageHeight,
        'fx': fx,
        'fy': fy,
        'cx': cx,
        'cy': cy,
        'distortion': distortion,
        if (rmsPx != null) 'rms_px': rmsPx,
        if (imagesUsed != null) 'n_images': imagesUsed,
      };

  static LensIntrinsics _fromJson(Object? raw) {
    if (raw is! Map) throw const FormatException('each lens must be an object');
    final lens = enumFromDb(CameraLens.values, raw['lens']);
    if (lens == null) throw FormatException('unknown lens: ${raw['lens']}');
    final medium = enumFromDb(CalibrationMedium.values, raw['medium']);
    if (medium == null) throw FormatException('unknown medium: ${raw['medium']}');
    final width = _int(raw, 'image_width'), height = _int(raw, 'image_height');
    if (width <= 0 || height <= 0) throw const FormatException('image size must be positive');
    if (width > height) {
      throw const FormatException('image size must be portrait (stills are saved portrait)');
    }
    final fx = _num(raw, 'fx'), fy = _num(raw, 'fy');
    if (fx <= 0 || fy <= 0) throw const FormatException('focal lengths must be positive');
    final cx = _num(raw, 'cx'), cy = _num(raw, 'cy');
    if (cx < 0 || cx > width || cy < 0 || cy > height) {
      throw const FormatException('principal point is outside the image');
    }
    final rawDist = raw['distortion'];
    if (rawDist is! List || (rawDist.length != 4 && rawDist.length != 5)) {
      throw const FormatException('distortion must be [k1, k2, p1, p2] or [k1, k2, p1, p2, k3]');
    }
    final dist = [
      for (final d in rawDist)
        if (d is num && d.isFinite) d.toDouble() else throw const FormatException('bad distortion term'),
      if (rawDist.length == 4) 0.0,
    ];
    final rms = raw['rms_px'];
    final n = raw['n_images'];
    return LensIntrinsics(
      lens: lens,
      medium: medium,
      imageWidth: width,
      imageHeight: height,
      fx: fx,
      fy: fy,
      cx: cx,
      cy: cy,
      distortion: dist,
      rmsPx: rms is num && rms.isFinite ? rms.toDouble() : null,
      imagesUsed: n is int ? n : null,
    );
  }
}

double _num(Map<dynamic, dynamic> raw, String key) {
  final v = raw[key];
  if (v is! num || !v.isFinite) throw FormatException('$key must be a finite number');
  return v.toDouble();
}

int _int(Map<dynamic, dynamic> raw, String key) {
  final v = raw[key];
  if (v is! int) throw FormatException('$key must be an integer');
  return v;
}

/// A calibration file: one [LensIntrinsics] per lens and medium.
class LensCalibration {
  LensCalibration({required this.calibrationId, this.created, required List<LensIntrinsics> lenses})
      : lenses = List.unmodifiable(lenses);

  /// The notebook run that produced it (its `RUN_ID`), recorded with every
  /// measurement so a number can be traced to the calibration behind it.
  final String calibrationId;
  final String? created;
  final List<LensIntrinsics> lenses;

  LensIntrinsics? forLens(CameraLens lens, CalibrationMedium medium) {
    for (final l in lenses) {
      if (l.lens == lens && l.medium == medium) return l;
    }
    return null;
  }

  /// Reads and validates a calibration file. Throws [FormatException] on
  /// anything malformed: a bad file is refused whole, never half-loaded.
  static LensCalibration parse(String text) {
    final Object? root;
    try {
      root = jsonDecode(text);
    } on FormatException {
      throw const FormatException('not a JSON file');
    }
    if (root is! Map) throw const FormatException('not a calibration object');
    if (root['format'] != kLensCalibrationFormat) {
      throw const FormatException('not a ReefSight lens calibration file');
    }
    final version = root['version'];
    if (version is! int || version < 1 || version > kLensCalibrationVersion) {
      throw FormatException('unsupported calibration version: $version');
    }
    final id = root['calibration_id'];
    if (id is! String || id.isEmpty) throw const FormatException('calibration_id is missing');
    final rawLenses = root['lenses'];
    if (rawLenses is! List || rawLenses.isEmpty) throw const FormatException('no lenses in the file');
    final lenses = [for (final l in rawLenses) LensIntrinsics._fromJson(l)];
    final seen = <(CameraLens, CalibrationMedium)>{};
    for (final l in lenses) {
      if (!seen.add((l.lens, l.medium))) {
        throw FormatException('${l.lens.db} / ${l.medium.db} appears twice');
      }
    }
    final created = root['created'];
    return LensCalibration(calibrationId: id, created: created is String ? created : null, lenses: lenses);
  }

  Map<String, Object?> toJson() => {
        'format': kLensCalibrationFormat,
        'version': kLensCalibrationVersion,
        'calibration_id': calibrationId,
        if (created != null) 'created': created,
        'lenses': [for (final l in lenses) l.toJson()],
      };
}
