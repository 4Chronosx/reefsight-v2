import 'dart:convert';

import 'db_enum.dart';

/// Issue #1 (schema v11): one scored image of a transect -- a photo-transect
/// still (one per meter, TB 2017-05) or a sampled video frame (preliminary,
/// #13). Its 10 random points are `FramePoint` rows
/// (`docs/reefsight-v2-blueprint.md` §4, `transect_frames`).

/// A position inside an image, normalized to 0-1 on each axis.
typedef NormPoint = ({double x, double y});

enum FrameSource with DbEnum {
  inApp('in_app'),
  imported('imported'),
  videoFrame('video_frame');

  const FrameSource(this.db);
  @override
  final String db;
}

/// Where a frame's four corners came from.
enum CornerSource with DbEnum {
  manual('manual'),
  copied('copied'),
  autoDetected('auto_detected'),
  virtual('virtual');

  const CornerSource(this.db);
  @override
  final String db;
}

/// How the camera-to-reef distance was measured (virtual mode, #14-15).
enum DistanceMethod with DbEnum {
  laser('laser'),
  tape('tape'),
  arkit('arkit');

  const DistanceMethod(this.db);
  @override
  final String db;
}

/// [TransectFrame.excludeReason] of a meter the diver marked as missing in
/// photo capture (#4).
const kMissingMeterReason = 'missing';

class TransectFrame {
  /// A meter mark the diver couldn't photograph (#4): a row with no image,
  /// excluded from scoring. Keeping it as a row (rather than no row) tells a
  /// skipped meter apart from one not reached yet, and `UNIQUE (session_id,
  /// meter_mark)` keeps each meter either captured or missing, never both.
  factory TransectFrame.missingMeter({
    required int sessionId,
    required double meterMark,
    DateTime? markedAt,
  }) =>
      TransectFrame(
        sessionId: sessionId,
        meterMark: meterMark,
        imagePath: '',
        source: FrameSource.inApp,
        capturedAt: markedAt,
        excluded: true,
        excludeReason: kMissingMeterReason,
      );

  TransectFrame({
    this.id,
    required this.sessionId,
    this.meterMark,
    this.videoTimeMs,
    required this.imagePath,
    required this.source,
    this.widthPx,
    this.heightPx,
    this.cameraMake,
    this.cameraModel,
    this.capturedAt,
    this.corners,
    this.cornerSource,
    this.tiltDeg,
    this.distanceM,
    this.distanceMethod,
    this.checksPassed,
    this.fisheyeFlag,
    this.excluded = false,
    this.excludeReason,
  }) {
    final c = corners;
    if (c != null && c.length != 4) {
      throw ArgumentError.value(c.length, 'corners', 'A frame needs exactly 4 corners');
    }
  }

  /// `null` before the row has been inserted.
  final int? id;
  final int sessionId;

  /// Position along the tape, 0-50 m; unique per transect. `null` for a
  /// preliminary video frame, which has [videoTimeMs] instead.
  final double? meterMark;
  final int? videoTimeMs;

  /// The copy in app storage, relative to the documents directory.
  final String imagePath;
  final FrameSource source;

  /// Pixel size -- the summary flags images under 5 MP.
  final int? widthPx;
  final int? heightPx;

  /// From EXIF, when present.
  final String? cameraMake;
  final String? cameraModel;

  /// From EXIF, or the app's clock for in-app captures.
  final DateTime? capturedAt;

  /// The four corners of the 1 × 1 m area, in image order, normalized.
  final List<NormPoint>? corners;
  final CornerSource? cornerSource;

  /// Phone tilt from vertical, if known.
  final double? tiltDeg;

  /// Camera-to-reef distance (virtual mode).
  final double? distanceM;
  final DistanceMethod? distanceMethod;

  /// Whether the virtual-mode checks passed.
  final bool? checksPassed;

  /// A fisheye image is suspected.
  final bool? fisheyeFlag;

  /// Dropped from scoring, with [excludeReason].
  final bool excluded;
  final String? excludeReason;

  /// A [TransectFrame.missingMeter] row: no image to show or score.
  bool get isMissing => imagePath.isEmpty && excludeReason == kMissingMeterReason;

  static String? cornersToJson(List<NormPoint>? corners) =>
      corners == null ? null : jsonEncode([for (final c in corners) [c.x, c.y]]);

  static List<NormPoint>? cornersFromJson(Object? raw) {
    if (raw == null) return null;
    final list = jsonDecode(raw as String) as List;
    return [
      for (final pair in list.cast<List>())
        (x: (pair[0] as num).toDouble(), y: (pair[1] as num).toDouble()),
    ];
  }

  /// Column names match `transect_database.dart`'s `transect_frames` table.
  Map<String, Object?> toMap() => {
        'id': id,
        'session_id': sessionId,
        'meter_mark': meterMark,
        'video_time_ms': videoTimeMs,
        'image_path': imagePath,
        'source': source.db,
        'width_px': widthPx,
        'height_px': heightPx,
        'camera_make': cameraMake,
        'camera_model': cameraModel,
        'captured_at': capturedAt?.toIso8601String(),
        'corners_json': cornersToJson(corners),
        'corner_source': cornerSource?.db,
        'tilt_deg': tiltDeg,
        'distance_m': distanceM,
        'distance_method': distanceMethod?.db,
        'checks_passed': boolToDb(checksPassed),
        'fisheye_flag': boolToDb(fisheyeFlag),
        'excluded': excluded ? 1 : 0,
        'exclude_reason': excludeReason,
      };

  /// Throws on an unknown `source` -- the column's CHECK constraint means it
  /// can't happen on this schema.
  static TransectFrame fromMap(Map<String, Object?> map) {
    final source = enumFromDb(FrameSource.values, map['source']);
    if (source == null) throw FormatException('Unknown frame source: ${map['source']}');
    return TransectFrame(
      id: map['id'] as int?,
      sessionId: map['session_id'] as int,
      meterMark: (map['meter_mark'] as num?)?.toDouble(),
      videoTimeMs: map['video_time_ms'] as int?,
      imagePath: map['image_path'] as String,
      source: source,
      widthPx: map['width_px'] as int?,
      heightPx: map['height_px'] as int?,
      cameraMake: map['camera_make'] as String?,
      cameraModel: map['camera_model'] as String?,
      capturedAt: dateTimeFromDb(map['captured_at']),
      corners: cornersFromJson(map['corners_json']),
      cornerSource: enumFromDb(CornerSource.values, map['corner_source']),
      tiltDeg: (map['tilt_deg'] as num?)?.toDouble(),
      distanceM: (map['distance_m'] as num?)?.toDouble(),
      distanceMethod: enumFromDb(DistanceMethod.values, map['distance_method']),
      checksPassed: boolFromDb(map['checks_passed']),
      fisheyeFlag: boolFromDb(map['fisheye_flag']),
      excluded: map['excluded'] == 1,
      excludeReason: map['exclude_reason'] as String?,
    );
  }
}
