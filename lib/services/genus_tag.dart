import 'db_enum.dart';

/// Issue #10 (schema v13): an expert's tag of a genus group (a TB 2019-04
/// TAU, `tau_catalogue.dart`) seen on a transect -- in one of its photos
/// ([frameId]), or along the tape but in no photo ([frameId] `null`).
/// Diversity is the number of distinct [tauCode]s, per transect and across
/// the station (`station_summary.dart`, `StationDiversity`).
class GenusTag {
  const GenusTag({
    this.id,
    required this.stationId,
    required this.sessionId,
    this.frameId,
    required this.tauCode,
    this.taggedBy,
    this.taggedAt,
  });

  /// `null` before the row has been inserted.
  final int? id;
  final int stationId;
  final int sessionId;
  final int? frameId;
  final String tauCode;
  final String? taggedBy;
  final DateTime? taggedAt;

  /// Column names match `transect_database.dart`'s `genus_tags` table.
  Map<String, Object?> toMap() => {
        'id': id,
        'station_id': stationId,
        'session_id': sessionId,
        'frame_id': frameId,
        'tau_code': tauCode,
        'tagged_by': taggedBy,
        'tagged_at': taggedAt?.toUtc().toIso8601String(),
      };

  static GenusTag fromMap(Map<String, Object?> map) => GenusTag(
        id: map['id'] as int?,
        stationId: map['station_id'] as int,
        sessionId: map['session_id'] as int,
        frameId: map['frame_id'] as int?,
        tauCode: map['tau_code'] as String,
        taggedBy: map['tagged_by'] as String?,
        taggedAt: dateTimeFromDb(map['tagged_at']),
      );

  @override
  String toString() => 'GenusTag($tauCode, transect $sessionId, ${frameId == null ? 'tape' : 'frame $frameId'})';
}
