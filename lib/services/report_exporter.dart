import 'dart:io';

import 'package:csv/csv.dart';
import 'package:share_plus/share_plus.dart';

import 'geo_fix.dart';
import 'recount_comparison.dart';
import 'report_data.dart';
import 'session_summary.dart';
import 'tracked_colony_record.dart';
import 'transect_session.dart';

/// Sub-plan 5 (ui-and-reporting), task 6. Adapted from v1's
/// `report_exporter.dart`: same static export/share shape, but columns
/// match `TrackedColonyRecord`'s actual fields instead of v1's
/// `ColonyRecord` (no lat/lon/quadrat/temperature/turbidity/pH -- this
/// schema has none of those; environmental data will come from Hobologger
/// ingestion, a separate sub-plan-5 item, not per-colony).
///
/// [outputDirectory] is a caller-supplied parameter rather than resolved
/// internally via `path_provider` -- mirrors `mask_storage.dart`'s pattern,
/// keeping this testable with a real temp directory (see
/// `report_exporter_test.dart`) instead of mocking a platform channel.
class ReportExporter {
  const ReportExporter._();

  /// The Health Label value for a colony with no confident label.
  static const String uncertainLabel = 'UNCERTAIN';

  static const List<String> csvHeaders = [
    'Track ID',
    'Health Label',
    'Size (px²)',
    'First Seen At',
    'Last Seen At',
    'Mask Path',
    // Sub-plan 18: relative to the app's documents directory, as stored.
    'Photo Path',
    'Photo Crop Path',
    'Photo Label',
    'Photo Confidence',
  ];

  static List<dynamic> _csvRow(TrackedColonyRecord colony) => [
        colony.trackId,
        // Sub-plan 10: null is the "Uncertain" verdict, written explicitly
        // so CSV readers can tell it apart from a missing value.
        colony.healthLabel ?? uncertainLabel,
        colony.sizePx?.toStringAsFixed(1) ?? '',
        colony.firstSeenAt.toIso8601String(),
        colony.lastSeenAt.toIso8601String(),
        colony.maskPath ?? '',
        colony.photoPath ?? '',
        colony.photoCropPath ?? '',
        colony.photoLabel ?? '',
        colony.photoConfidence?.toStringAsFixed(2) ?? '',
      ];

  /// Whitelists `[A-Za-z0-9_-]`, replacing everything else (including
  /// `/`/`\`/`..`/Windows-reserved characters) with `_` -- [siteName] is
  /// unrestricted free text from `TransectSetupScreen`, and this string
  /// becomes a path segment (see [exportCsv] below). A path separator or
  /// `..` making it through unescaped would let a site name like
  /// `"x/../reefsight"` write outside `outputDirectory` -- in the worst
  /// case, into the same directory `TransectDatabase` uses for
  /// `reefsight.db`, silently clobbering the survey database with a CSV.
  static String _sanitizeForFilename(String? siteName) {
    final trimmed = siteName?.trim();
    if (trimmed == null || trimmed.isEmpty) return 'Unknown_Site';
    return trimmed.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_');
  }

  /// `reefsight_<site>_<start time>` -- shared by the colony CSV and the
  /// session CSV, so the two files from one transect sort together.
  static String _baseName(TransectSession session) {
    final timestamp = session.startedAt
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-')
        .substring(0, 19);
    return 'reefsight_${_sanitizeForFilename(session.siteName)}_$timestamp';
  }

  static Future<String> _write(
    String outputDirectory,
    String filename,
    List<List<dynamic>> rows,
  ) async {
    final file = File('$outputDirectory/$filename');
    await file.writeAsString(const ListToCsvConverter().convert(rows));
    return file.path;
  }

  static Future<String> exportCsv({
    required String outputDirectory,
    required TransectSession session,
    required List<TrackedColonyRecord> colonies,
  }) {
    return _write(outputDirectory, '${_baseName(session)}.csv', [
      csvHeaders,
      ...colonies.map(_csvRow),
    ]);
  }

  /// Sub-plan 12 step 5: the session CSV's columns. Times are ISO-8601 UTC;
  /// a missing value is an empty cell. The distance is the entry-exit QA
  /// check, never a metric.
  static const List<String> sessionCsvHeaders = [
    'Site',
    'Observer',
    'Tape Length (m)',
    'Belt Width (m)',
    'Started At',
    'Ended At',
    'Entry Lat',
    'Entry Lon',
    'Entry Accuracy (m)',
    'Entry At',
    'Entry Source',
    'Exit Lat',
    'Exit Lon',
    'Exit Accuracy (m)',
    'Exit At',
    'Exit Source',
    'Entry-Exit Distance (m)',
    ..._recountHeaders,
    ..._intervalHeaders,
  ];

  /// Sub-plan 17: the prevalence and density the app shows, with their 95%
  /// bounds (Wilson on bleached/classified; exact Poisson on the count over
  /// the belt area) -- so the thesis quotes the same intervals. Filled
  /// whenever the colonies are given, below the executive tab's small-sample
  /// threshold too. Sampling uncertainty only.
  static const List<String> _intervalHeaders = [
    'Prevalence (%)',
    'Prevalence 95% Low (%)',
    'Prevalence 95% High (%)',
    'Density (/m²)',
    'Density 95% Low (/m²)',
    'Density 95% High (/m²)',
  ];

  static List<dynamic> _intervalCells(TransectReport? report) {
    final prevalence = report?.prevalence;
    final density = report?.densityInterval;
    String percent(double? fraction) => _fixed(fraction == null ? null : fraction * 100);
    String perArea(double? value) => value?.toStringAsFixed(3) ?? '';
    return [
      percent(prevalence?.fraction),
      percent(prevalence?.interval.low),
      percent(prevalence?.interval.high),
      perArea(report?.densityPerSquareMeter),
      perArea(density?.low),
      perArea(density?.high),
    ];
  }

  /// Sub-plan 14 step 6: the recount, the app's counts, and the comparison
  /// -- appended to the session CSV and repeated in Surveys' comparisons
  /// export. Percentages have two decimals; a missing value is an empty
  /// cell. App prevalence is over classified colonies, the recount's over
  /// all counted colonies (see `RecountComparison`).
  static const List<String> _recountHeaders = [
    'Results Hidden',
    'Recount Total',
    'Recount Bleached',
    'Recount By',
    'Recount At',
    'Recount Blinded',
    'App Total',
    'App Bleached',
    'App Classified',
    'Count Error',
    'Count Error (%)',
    'App Prevalence (%)',
    'Recount Prevalence (%)',
    'Prevalence Diff (pp)',
  ];

  /// Sub-plan 14 step 6: Surveys' "Export recount comparisons" -- one row
  /// per recounted session, the raw table behind Phase E's MAE.
  static const List<String> recountComparisonsCsvHeaders = [
    'Site',
    'Observer',
    'Started At',
    'Tape Length (m)',
    ..._recountHeaders,
  ];

  static String _fixed(double? value) => value?.toStringAsFixed(2) ?? '';

  /// The [_recountHeaders] cells. The app's counts are `null` when the
  /// caller doesn't have them, leaving those and the comparison empty.
  static List<dynamic> _recountCells(
    TransectSession session, {
    int? appTotal,
    int? appBleached,
    int? appClassified,
  }) {
    final recount = session.recount;
    final comparison =
        recount == null || appTotal == null || appBleached == null || appClassified == null
            ? null
            : RecountComparison(
                appTotal: appTotal,
                appBleached: appBleached,
                appClassified: appClassified,
                recount: recount,
              );
    return [
      session.resultsHidden,
      recount?.total ?? '',
      recount?.bleached ?? '',
      recount?.countedBy ?? '',
      recount?.at.toIso8601String() ?? '',
      recount?.blinded ?? '',
      appTotal ?? '',
      appBleached ?? '',
      appClassified ?? '',
      comparison?.countError ?? '',
      _fixed(comparison?.countErrorPercent),
      _fixed(comparison?.appPrevalencePercent),
      _fixed(comparison?.recountPrevalencePercent),
      _fixed(comparison?.prevalenceDiffPp),
    ];
  }

  static List<dynamic> _fixCells(GeoFix? fix) => [
        fix?.lat ?? '',
        fix?.lon ?? '',
        fix?.accuracyM ?? '',
        fix?.at.toIso8601String() ?? '',
        fix?.source.name ?? '',
      ];

  /// Sub-plan 12 step 5: a second, small `<base>_session.csv` -- one header
  /// row and one data row with the session identity and both GPS fixes
  /// (with source and accuracy). Kept separate so the colony CSV's columns
  /// stay unchanged.
  ///
  /// Sub-plan 14: also the recount and, given the session's [colonies],
  /// the app's counts and the comparison.
  static Future<String> exportSessionCsv({
    required String outputDirectory,
    required TransectSession session,
    List<TrackedColonyRecord>? colonies,
  }) {
    final entry = session.entryFix;
    final exit = session.exitFix;
    final report = colonies == null
        ? null
        : TransectReport(session: session, colonies: colonies);
    return _write(outputDirectory, '${_baseName(session)}_session.csv', [
      sessionCsvHeaders,
      [
        session.siteName ?? '',
        session.observerName ?? '',
        session.tapeLengthMeters,
        session.beltWidthMeters,
        session.startedAt.toIso8601String(),
        session.endedAt?.toIso8601String() ?? '',
        ..._fixCells(entry),
        ..._fixCells(exit),
        entry != null && exit != null ? distanceMeters(entry, exit).toStringAsFixed(1) : '',
        ..._recountCells(
          session,
          appTotal: report?.totalColonies,
          appBleached: report?.bleachedCount,
          appClassified: report?.classifiedCount,
        ),
        ..._intervalCells(report),
      ],
    ]);
  }

  /// Sub-plan 14 step 6: every session in [sessions] that has a recount,
  /// one row each -- `reefsight_recount_comparisons_<time>.csv`.
  /// [exportedAt] names the file (default now, UTC).
  static Future<String> exportRecountComparisonsCsv({
    required String outputDirectory,
    required List<SessionSummary> sessions,
    DateTime? exportedAt,
  }) {
    final stamp = (exportedAt ?? DateTime.now()).toUtc().toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-')
        .substring(0, 19);
    return _write(outputDirectory, 'reefsight_recount_comparisons_$stamp.csv', [
      recountComparisonsCsvHeaders,
      for (final summary in sessions)
        if (summary.session.recount != null)
          [
            summary.session.siteName ?? '',
            summary.session.observerName ?? '',
            summary.session.startedAt.toIso8601String(),
            summary.session.tapeLengthMeters,
            ..._recountCells(
              summary.session,
              appTotal: summary.colonyCount,
              appBleached: summary.bleachedCount,
              appClassified: summary.classifiedCount,
            ),
          ],
    ]);
  }

  /// Shares the exported CSVs together (colony + session, sub-plan 12).
  static Future<void> shareCsv(List<String> filePaths) async {
    await Share.shareXFiles(
      [for (final path in filePaths) XFile(path)],
      subject: 'ReefSight Transect Report',
      text: 'Coral reef health survey report from ReefSight.',
    );
  }

  /// Sub-plan 18 step 6: the CSVs plus the colony photo files, as one list
  /// of files -- no zip package is a dependency, so none is added for this.
  static Future<void> shareReportWithPhotos(
    List<String> csvPaths,
    List<String> photoPaths,
  ) async {
    await Share.shareXFiles(
      [for (final path in [...csvPaths, ...photoPaths]) XFile(path)],
      subject: 'ReefSight Transect Report',
      text: 'Coral reef health survey report from ReefSight, with colony photos.',
    );
  }

  /// Shares the continuous transect recording (`TransectRecorder`, via the
  /// forked `ultralytics_yolo` plugin -- `mobile/third_party/ultralytics_yolo`'s
  /// `PATCH.md`). [filePath] is `TransectSession.videoPath`, set at session
  /// finalize; the caller is responsible for checking it's non-null and the
  /// file still exists before calling this.
  static Future<void> shareVideo(String filePath) async {
    await Share.shareXFiles(
      [XFile(filePath)],
      subject: 'ReefSight Transect Video',
      text: 'Dive transect recording from ReefSight.',
    );
  }
}
