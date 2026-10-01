import 'dart:io';

import 'package:csv/csv.dart';
import 'package:share_plus/share_plus.dart';

import 'geo_fix.dart';
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
  ];

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
  static Future<String> exportSessionCsv({
    required String outputDirectory,
    required TransectSession session,
  }) {
    final entry = session.entryFix;
    final exit = session.exitFix;
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
