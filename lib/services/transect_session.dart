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
    this.siteName,
    this.observerName,
    this.videoPath,
    this.lastCheckpointAt,
    this.interruptionCount,
    this.firstInterruptedAt,
    this.lastInterruptedAt,
  });

  /// `null` before the row has been inserted and assigned a rowid.
  final int? id;

  final DateTime startedAt;

  /// `null` while the transect is still in progress.
  final DateTime? endedAt;

  final double tapeLengthMeters;
  final double beltWidthMeters;

  /// Diver-entered at transect setup (sub-plan 5's `TransectSetupScreen`),
  /// same field as v1's `SurveyMetadata.siteName`/`.observerName` --
  /// `null`, not a placeholder string, when never entered, so the report UI
  /// can tell "not recorded" apart from an empty-string default.
  final String? siteName;
  final String? observerName;

  /// Path to the continuous transect recording (`TransectRecorder`,
  /// `mobile/third_party/ultralytics_yolo`'s recording patch -- see that
  /// fork's `PATCH.md`), set once at session finalize
  /// (`live_transect_screen.dart`'s `_finalizeSession`). `null` if
  /// recording never started or the session never finalized (e.g. app
  /// killed mid-dive).
  final String? videoPath;

  /// When `SessionCheckpointer` last wrote this session's colony rows during
  /// Live (sub-plan 11). For an incomplete session (`endedAt == null`) this
  /// is the best record of when the app stopped. `null` before the first
  /// checkpoint, and on every session recorded before schema v4.
  final DateTime? lastCheckpointAt;

  /// How many times Live left the foreground (phone call, notification
  /// centre, app switch) during this transect, with the first and last of
  /// those times -- sub-plan 11 step 3. `null` (not 0) if it never happened
  /// or the session predates schema v4.
  final int? interruptionCount;
  final DateTime? firstInterruptedAt;
  final DateTime? lastInterruptedAt;

  TransectSession copyWith({
    int? id,
    DateTime? startedAt,
    DateTime? endedAt,
    double? tapeLengthMeters,
    double? beltWidthMeters,
    String? siteName,
    String? observerName,
    String? videoPath,
    DateTime? lastCheckpointAt,
    int? interruptionCount,
    DateTime? firstInterruptedAt,
    DateTime? lastInterruptedAt,
  }) {
    return TransectSession(
      id: id ?? this.id,
      startedAt: startedAt ?? this.startedAt,
      endedAt: endedAt ?? this.endedAt,
      tapeLengthMeters: tapeLengthMeters ?? this.tapeLengthMeters,
      beltWidthMeters: beltWidthMeters ?? this.beltWidthMeters,
      siteName: siteName ?? this.siteName,
      observerName: observerName ?? this.observerName,
      videoPath: videoPath ?? this.videoPath,
      lastCheckpointAt: lastCheckpointAt ?? this.lastCheckpointAt,
      interruptionCount: interruptionCount ?? this.interruptionCount,
      firstInterruptedAt: firstInterruptedAt ?? this.firstInterruptedAt,
      lastInterruptedAt: lastInterruptedAt ?? this.lastInterruptedAt,
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
        'site_name': siteName,
        'observer_name': observerName,
        'video_path': videoPath,
        'last_checkpoint_at': lastCheckpointAt?.toIso8601String(),
        'interruption_count': interruptionCount,
        'first_interrupted_at': firstInterruptedAt?.toIso8601String(),
        'last_interrupted_at': lastInterruptedAt?.toIso8601String(),
      };

  static DateTime? _parseNullable(Object? raw) =>
      raw == null ? null : DateTime.parse(raw as String);

  static TransectSession fromMap(Map<String, Object?> map) {
    final endedAtRaw = map['ended_at'] as String?;
    return TransectSession(
      id: map['id'] as int?,
      startedAt: DateTime.parse(map['started_at'] as String),
      endedAt: endedAtRaw == null ? null : DateTime.parse(endedAtRaw),
      tapeLengthMeters: (map['tape_length_meters'] as num).toDouble(),
      beltWidthMeters: (map['belt_width_meters'] as num).toDouble(),
      siteName: map['site_name'] as String?,
      observerName: map['observer_name'] as String?,
      videoPath: map['video_path'] as String?,
      lastCheckpointAt: _parseNullable(map['last_checkpoint_at']),
      interruptionCount: map['interruption_count'] as int?,
      firstInterruptedAt: _parseNullable(map['first_interrupted_at']),
      lastInterruptedAt: _parseNullable(map['last_interrupted_at']),
    );
  }
}
