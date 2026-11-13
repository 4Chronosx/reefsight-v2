import 'db_enum.dart';
import 'geo_fix.dart';

/// Issue #1 (schema v11): a 75 × 25 m monitoring station (DENR-BMB TB
/// 2019-04) that groups 3-5 transects -- rows of `transect_sessions` with
/// `station_id` set. Survey type and frame mode live here, not on the
/// transect, so one station's transects can't mix them
/// (`docs/reefsight-v2-blueprint.md` §4, `stations`).

/// The three survey types, fixed per station.
enum SurveyType with DbEnum {
  /// Official: one still per meter, scored with 10 random points (TB 2017-05).
  photoTransect('photo_transect'),

  /// Live video, bulletin-style output stamped PRELIMINARY (#13).
  preliminaryVideo('preliminary_video'),

  /// The original YOLOv8n-seg + BoT-SORT + classifier flow, reported
  /// separately from the bulletin cover summaries (#3).
  colonyCount('colony_count');

  const SurveyType(this.db);
  @override
  final String db;
}

/// How a photo transect's 1 × 1 m area is defined. Only photo transects have
/// one.
enum FrameMode with DbEnum {
  physical('physical'),
  virtual('virtual'),
  importedMixed('imported_mixed');

  const FrameMode(this.db);
  @override
  final String db;
}

enum ReefZone with DbEnum {
  reefFlat('reef_flat'),
  reefCrest('reef_crest'),
  upperSlope('upper_slope'),
  lowerSlope('lower_slope');

  const ReefZone(this.db);
  @override
  final String db;
}

class Station {
  Station({
    this.id,
    required this.code,
    this.name,
    required this.surveyType,
    this.frameMode,
    required DateTime surveyedOn,
    this.siteName,
    this.reefZone,
    this.depthMinM,
    this.depthMaxM,
    this.deepEdgeFix,
    this.markerPlaced,
    this.observerName,
    this.notes,
    required this.createdAt,
  }) : surveyedOn = DateTime(surveyedOn.year, surveyedOn.month, surveyedOn.day);

  /// `null` before the row has been inserted.
  final int? id;

  /// Short ID, e.g. `ALG-S1`.
  final String code;
  final String? name;
  final SurveyType surveyType;

  /// Set for photo transects only (`TransectDatabase.insertStation` checks).
  final FrameMode? frameMode;

  /// The survey day, as a local calendar date (stored `YYYY-MM-DD`).
  final DateTime surveyedOn;

  /// Site or MPA name -- a sites table comes later.
  final String? siteName;
  final ReefZone? reefZone;

  /// Station depth range; the summary flags a maximum over 6 m (TB 2019-04).
  final double? depthMinM;
  final double? depthMaxM;

  /// Surface GPS fix of the station's deeper edge. Stored through
  /// [GeoFix.toColumns] with the `deep_edge` prefix, like the transect
  /// entry/exit fixes, so it records whether it was GPS or typed in.
  final GeoFix? deepEdgeFix;

  /// Whether a permanent concrete-block marker was placed.
  final bool? markerPlaced;
  final String? observerName;
  final String? notes;
  final DateTime createdAt;

  static const deepEdgePrefix = 'deep_edge';

  /// Whether this station's survey type needs a [frameMode].
  bool get needsFrameMode => surveyType == SurveyType.photoTransect;

  Station copyWith({
    int? id,
    String? code,
    String? name,
    SurveyType? surveyType,
    FrameMode? frameMode,
    DateTime? surveyedOn,
    String? siteName,
    ReefZone? reefZone,
    double? depthMinM,
    double? depthMaxM,
    GeoFix? deepEdgeFix,
    bool? markerPlaced,
    String? observerName,
    String? notes,
    DateTime? createdAt,
  }) {
    return Station(
      id: id ?? this.id,
      code: code ?? this.code,
      name: name ?? this.name,
      surveyType: surveyType ?? this.surveyType,
      frameMode: frameMode ?? this.frameMode,
      surveyedOn: surveyedOn ?? this.surveyedOn,
      siteName: siteName ?? this.siteName,
      reefZone: reefZone ?? this.reefZone,
      depthMinM: depthMinM ?? this.depthMinM,
      depthMaxM: depthMaxM ?? this.depthMaxM,
      deepEdgeFix: deepEdgeFix ?? this.deepEdgeFix,
      markerPlaced: markerPlaced ?? this.markerPlaced,
      observerName: observerName ?? this.observerName,
      notes: notes ?? this.notes,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  static String _isoDate(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// Column names match `transect_database.dart`'s `stations` table.
  Map<String, Object?> toMap() => {
        'id': id,
        'code': code,
        'name': name,
        'survey_type': surveyType.db,
        'frame_mode': frameMode?.db,
        'surveyed_on': _isoDate(surveyedOn),
        'site_name': siteName,
        'reef_zone': reefZone?.db,
        'depth_min_m': depthMinM,
        'depth_max_m': depthMaxM,
        ...deepEdgeFix?.toColumns(deepEdgePrefix) ?? GeoFix.nullColumns(deepEdgePrefix),
        'marker_placed': boolToDb(markerPlaced),
        'observer_name': observerName,
        'notes': notes,
        'created_at': createdAt.toIso8601String(),
      };

  /// Throws on an unknown `survey_type`: unlike the optional fields, a
  /// station without one can't be summarized at all, and the column's CHECK
  /// constraint means it can't happen on this schema.
  static Station fromMap(Map<String, Object?> map) {
    final type = enumFromDb(SurveyType.values, map['survey_type']);
    if (type == null) throw FormatException('Unknown survey_type: ${map['survey_type']}');
    return Station(
      id: map['id'] as int?,
      code: map['code'] as String,
      name: map['name'] as String?,
      surveyType: type,
      frameMode: enumFromDb(FrameMode.values, map['frame_mode']),
      surveyedOn: DateTime.parse(map['surveyed_on'] as String),
      siteName: map['site_name'] as String?,
      reefZone: enumFromDb(ReefZone.values, map['reef_zone']),
      depthMinM: (map['depth_min_m'] as num?)?.toDouble(),
      depthMaxM: (map['depth_max_m'] as num?)?.toDouble(),
      deepEdgeFix: GeoFix.fromColumns(map, deepEdgePrefix),
      markerPlaced: boolFromDb(map['marker_placed']),
      observerName: map['observer_name'] as String?,
      notes: map['notes'] as String?,
      createdAt: DateTime.parse(map['created_at'] as String),
    );
  }
}

/// One row for a station list: the station plus how many transects it has
/// (`TransectDatabase.listStations`), without a query per row.
class StationSummary {
  const StationSummary({required this.station, required this.transectCount});

  final Station station;
  final int transectCount;
}
