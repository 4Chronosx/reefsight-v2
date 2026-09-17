import 'dart:io';

import 'package:csv/csv.dart';
import 'package:share_plus/share_plus.dart';

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
        colony.healthLabel ?? '',
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

  static Future<String> exportCsv({
    required String outputDirectory,
    required TransectSession session,
    required List<TrackedColonyRecord> colonies,
  }) async {
    final rows = <List<dynamic>>[
      csvHeaders,
      ...colonies.map(_csvRow),
    ];
    final csvString = const ListToCsvConverter().convert(rows);

    final timestamp = session.startedAt
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-')
        .substring(0, 19);
    final filename = 'reefsight_${_sanitizeForFilename(session.siteName)}_$timestamp.csv';

    final file = File('$outputDirectory/$filename');
    await file.writeAsString(csvString);
    return file.path;
  }

  static Future<void> shareCsv(String filePath) async {
    await Share.shareXFiles(
      [XFile(filePath)],
      subject: 'ReefSight Transect Report',
      text: 'Coral reef health survey report from ReefSight.',
    );
  }
}
