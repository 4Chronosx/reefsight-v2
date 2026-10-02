import 'device_checks.dart';
import 'geo_fix.dart';
import 'recount.dart';

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
    this.videoStartedAt,
    this.lastCheckpointAt,
    this.interruptionCount,
    this.firstInterruptedAt,
    this.lastInterruptedAt,
    this.thermalPeak,
    this.thermalRiseCount,
    this.entryFix,
    this.exitFix,
    this.resultsHidden = false,
    this.resultsRevealedAt,
    this.recount,
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

  /// When the recording started -- stamped once `TransectRecorder.start`
  /// returns, so it is video time zero, unlike [startedAt] (which precedes
  /// the DB open and insert). Sub-plan 16 maps a colony's `firstSeenAt` to a
  /// video position with it (`videoOffsetFor`). Written with [videoPath] at
  /// finalize; `null` if recording never started, and on every session
  /// recorded before schema v8.
  final DateTime? videoStartedAt;

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

  /// The hottest iOS thermal state Live saw, and how many times the state
  /// stepped up -- sub-plan 13 step 3. They explain a frame-rate drop in the
  /// report and the thesis. `null` if the state was never readable (not
  /// iOS) or the session predates schema v5.
  final ThermalLevel? thermalPeak;
  final int? thermalRiseCount;

  /// Sub-plan 12: the Spec's surface GPS fixes. [entryFix] is taken on
  /// Setup before descent and stored at insert; [exitFix] is recorded from
  /// Summary after surfacing (`TransectDatabase.recordExitFix`, write-once
  /// -- the only field written after End Transect). Either may be `null`:
  /// a missing fix never blocks a dive. Neither feeds any metric.
  final GeoFix? entryFix;
  final GeoFix? exitFix;

  /// Sub-plan 14 decision 1: "Recount planned" was switched on at Setup, so
  /// Live and Summary hide the app's numbers until the recount is entered.
  /// Stays `true` after the reveal, so the record keeps that a recount was
  /// planned. `false` for every session before schema v7.
  final bool resultsHidden;

  /// When a hidden session's results were first shown on this phone: on
  /// saving the recount, or on "Reveal without recount". Write-once
  /// (`TransectDatabase.revealResults`/`recordRecount`).
  final DateTime? resultsRevealedAt;

  /// The manual recount, write-once (`TransectDatabase.recordRecount`).
  final Recount? recount;

  /// Whether the app's numbers must stay off screen right now.
  bool get resultsCurrentlyHidden => resultsHidden && resultsRevealedAt == null;

  TransectSession copyWith({
    int? id,
    DateTime? startedAt,
    DateTime? endedAt,
    double? tapeLengthMeters,
    double? beltWidthMeters,
    String? siteName,
    String? observerName,
    String? videoPath,
    DateTime? videoStartedAt,
    DateTime? lastCheckpointAt,
    int? interruptionCount,
    DateTime? firstInterruptedAt,
    DateTime? lastInterruptedAt,
    ThermalLevel? thermalPeak,
    int? thermalRiseCount,
    GeoFix? entryFix,
    GeoFix? exitFix,
    bool? resultsHidden,
    DateTime? resultsRevealedAt,
    Recount? recount,
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
      videoStartedAt: videoStartedAt ?? this.videoStartedAt,
      lastCheckpointAt: lastCheckpointAt ?? this.lastCheckpointAt,
      interruptionCount: interruptionCount ?? this.interruptionCount,
      firstInterruptedAt: firstInterruptedAt ?? this.firstInterruptedAt,
      lastInterruptedAt: lastInterruptedAt ?? this.lastInterruptedAt,
      thermalPeak: thermalPeak ?? this.thermalPeak,
      thermalRiseCount: thermalRiseCount ?? this.thermalRiseCount,
      entryFix: entryFix ?? this.entryFix,
      exitFix: exitFix ?? this.exitFix,
      resultsHidden: resultsHidden ?? this.resultsHidden,
      resultsRevealedAt: resultsRevealedAt ?? this.resultsRevealedAt,
      recount: recount ?? this.recount,
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
        'video_started_at': videoStartedAt?.toIso8601String(),
        'last_checkpoint_at': lastCheckpointAt?.toIso8601String(),
        'interruption_count': interruptionCount,
        'first_interrupted_at': firstInterruptedAt?.toIso8601String(),
        'last_interrupted_at': lastInterruptedAt?.toIso8601String(),
        'thermal_peak': thermalPeak?.name,
        'thermal_rise_count': thermalRiseCount,
        ...entryFix?.toColumns('entry') ?? GeoFix.nullColumns('entry'),
        ...exitFix?.toColumns('exit') ?? GeoFix.nullColumns('exit'),
        'results_hidden': resultsHidden ? 1 : 0,
        'results_revealed_at': resultsRevealedAt?.toIso8601String(),
        ...Recount.toColumns(recount),
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
      videoStartedAt: _parseNullable(map['video_started_at']),
      lastCheckpointAt: _parseNullable(map['last_checkpoint_at']),
      interruptionCount: map['interruption_count'] as int?,
      firstInterruptedAt: _parseNullable(map['first_interrupted_at']),
      lastInterruptedAt: _parseNullable(map['last_interrupted_at']),
      thermalPeak: ThermalLevel.values.asNameMap()[map['thermal_peak']],
      thermalRiseCount: map['thermal_rise_count'] as int?,
      entryFix: GeoFix.fromColumns(map, 'entry'),
      exitFix: GeoFix.fromColumns(map, 'exit'),
      resultsHidden: map['results_hidden'] == 1,
      resultsRevealedAt: _parseNullable(map['results_revealed_at']),
      recount: Recount.fromColumns(map),
    );
  }
}
