/// One transect run: identity plus the physical tape length that serves as
/// the density denominator.
///
/// Per `ReefSight_Specification.md` ("Density, positioning, and sync"): the
/// denominator is the physically marked transect tape/line, never GPS- or
/// software-derived distance -- [tapeLengthMeters] is read off that tape,
/// not computed. [beltWidthMeters] defaults to `1.0`, matching NOAA NCRMP's
/// 10m x 1m belt-transect convention (Dev Plan Track 3 §9-10) cited as the
/// literature precedent for this metric's structure; it's overridable
/// because the belt width itself isn't the settled decision, only "use the
/// tape, not GPS" is.
class TransectSession {
  TransectSession({
    this.id,
    required this.startedAt,
    this.endedAt,
    required this.tapeLengthMeters,
    this.beltWidthMeters = 1.0,
  });

  /// `null` before the row has been inserted and assigned a rowid.
  final int? id;

  final DateTime startedAt;

  /// `null` while the transect is still in progress.
  final DateTime? endedAt;

  final double tapeLengthMeters;
  final double beltWidthMeters;

  TransectSession copyWith({
    int? id,
    DateTime? startedAt,
    DateTime? endedAt,
    double? tapeLengthMeters,
    double? beltWidthMeters,
  }) {
    return TransectSession(
      id: id ?? this.id,
      startedAt: startedAt ?? this.startedAt,
      endedAt: endedAt ?? this.endedAt,
      tapeLengthMeters: tapeLengthMeters ?? this.tapeLengthMeters,
      beltWidthMeters: beltWidthMeters ?? this.beltWidthMeters,
    );
  }

  /// Column names match `transect_database.dart`'s `transect_sessions`
  /// table exactly -- this is the single source of truth for that mapping.
  Map<String, Object?> toMap() => {
        'id': id,
        'started_at': startedAt.toIso8601String(),
        'ended_at': endedAt?.toIso8601String(),
        'tape_length_meters': tapeLengthMeters,
        'belt_width_meters': beltWidthMeters,
      };

  static TransectSession fromMap(Map<String, Object?> map) {
    final endedAtRaw = map['ended_at'] as String?;
    return TransectSession(
      id: map['id'] as int?,
      startedAt: DateTime.parse(map['started_at'] as String),
      endedAt: endedAtRaw == null ? null : DateTime.parse(endedAtRaw),
      tapeLengthMeters: (map['tape_length_meters'] as num).toDouble(),
      beltWidthMeters: (map['belt_width_meters'] as num).toDouble(),
    );
  }
}
