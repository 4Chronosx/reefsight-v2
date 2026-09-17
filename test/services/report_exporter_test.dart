import 'dart:io';

import 'package:csv/csv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/services/health_history_recorder.dart';
import 'package:reefsight_mobile/services/report_exporter.dart';
import 'package:reefsight_mobile/services/tracked_colony_record.dart';
import 'package:reefsight_mobile/services/transect_session.dart';

// Sub-plan 5 (ui-and-reporting), task 6: CSV export, adapted from v1's
// `report_exporter.dart` to `TrackedColonyRecord`'s actual columns (no
// lat/lon/quadrat/temperature/turbidity/pH -- this schema has none of
// those). Mirrors `mask_storage_test.dart`'s pattern: `outputDirectory` is
// a caller-supplied parameter, so this is testable with a real temp
// directory instead of mocking `path_provider`'s platform channel.

TrackedColonyRecord colony({
  required int trackId,
  String? healthLabel,
  double? sizePx,
}) {
  final now = DateTime.utc(2026, 1, 1, 8);
  return TrackedColonyRecord(
    sessionId: 1,
    trackId: trackId,
    healthLabel: healthLabel,
    healthHistory: const <HealthHistorySample>[],
    sizePx: sizePx,
    firstSeenAt: now,
    lastSeenAt: now.add(const Duration(minutes: 1)),
  );
}

void main() {
  group('ReportExporter.exportCsv', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('report_exporter_test');
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    final session = TransectSession(
      id: 1,
      startedAt: DateTime.utc(2026, 1, 1, 8),
      tapeLengthMeters: 10,
      siteName: 'Marigondon Reef',
    );

    test('writes one CSV row per colony plus a header row', () async {
      final path = await ReportExporter.exportCsv(
        outputDirectory: tempDir.path,
        session: session,
        colonies: [
          colony(trackId: 1, healthLabel: 'CORAL', sizePx: 120.5),
          colony(trackId: 2, healthLabel: 'CORAL_BL'),
        ],
      );

      final file = File(path);
      expect(file.existsSync(), isTrue);

      final rows = const CsvToListConverter().convert(file.readAsStringSync());
      expect(rows, hasLength(3)); // header + 2 colonies
      expect(rows[0], ReportExporter.csvHeaders);
      expect(rows[1][0], 1); // Track ID
      expect(rows[1][1], 'CORAL');
      expect(rows[2][0], 2);
      expect(rows[2][1], 'CORAL_BL');
    });

    test('an unclassified colony (null health label) writes an empty '
        'field, not a fabricated one', () async {
      final path = await ReportExporter.exportCsv(
        outputDirectory: tempDir.path,
        session: session,
        colonies: [colony(trackId: 5, healthLabel: null)],
      );

      final rows = const CsvToListConverter()
          .convert(File(path).readAsStringSync());
      expect(rows[1][1], '');
    });

    test('filename is scoped by site name and session start time', () async {
      final path = await ReportExporter.exportCsv(
        outputDirectory: tempDir.path,
        session: session,
        colonies: const [],
      );

      expect(path, contains('Marigondon_Reef'));
      expect(path, endsWith('.csv'));
    });

    test('a site name containing path separators or ".." does not escape '
        'outputDirectory', () async {
      final maliciousSession = TransectSession(
        id: 1,
        startedAt: DateTime.utc(2026, 1, 1, 8),
        tapeLengthMeters: 10,
        siteName: '../../reefsight',
      );

      final path = await ReportExporter.exportCsv(
        outputDirectory: tempDir.path,
        session: maliciousSession,
        colonies: const [],
      );

      expect(path, startsWith(tempDir.path));
      expect(File(path).parent.path, tempDir.path);
    });
  });
}
