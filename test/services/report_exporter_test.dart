import 'dart:io';

import 'package:csv/csv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/services/geo_fix.dart';
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

    // Sub-plan 10: a null label is the app's verdict "Uncertain" (too few
    // confident samples), not missing data -- so it's written explicitly,
    // never as a fabricated CORAL/CORAL_BL.
    test('an uncertain colony (null health label) writes UNCERTAIN, not a '
        'fabricated label', () async {
      final path = await ReportExporter.exportCsv(
        outputDirectory: tempDir.path,
        session: session,
        colonies: [colony(trackId: 5, healthLabel: null)],
      );

      final rows = const CsvToListConverter()
          .convert(File(path).readAsStringSync());
      expect(rows[1][1], 'UNCERTAIN');
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

  // Sub-plan 12 step 5: a second, small `<base>_session.csv` with the
  // session identity and both GPS fixes. The colony CSV is unchanged.
  group('ReportExporter.exportSessionCsv', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('report_exporter_session_test');
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    final entry = GeoFix(
      lat: 10.25,
      lon: 123.95,
      accuracyM: 8,
      at: DateTime.utc(2026, 10, 2, 1),
      source: GeoFixSource.gps,
    );
    final exit = GeoFix(
      lat: 10.25045,
      lon: 123.95,
      at: DateTime.utc(2026, 10, 2, 2),
      source: GeoFixSource.manual,
    );

    Future<List<List<dynamic>>> readRows(String path) async =>
        const CsvToListConverter(shouldParseNumbers: false)
            .convert(await File(path).readAsString());

    test('is named after the colony CSV, with a _session suffix', () async {
      final session = TransectSession(
        startedAt: DateTime.utc(2026, 10, 2, 1, 5),
        tapeLengthMeters: 50,
        siteName: 'Day-as',
      );
      final colonyPath = await ReportExporter.exportCsv(
        outputDirectory: tempDir.path,
        session: session,
        colonies: const [],
      );
      final sessionPath = await ReportExporter.exportSessionCsv(
        outputDirectory: tempDir.path,
        session: session,
      );

      expect(sessionPath, colonyPath.replaceFirst(RegExp(r'\.csv$'), '_session.csv'));
    });

    test('writes one row with both fixes, their sources and the distance', () async {
      final session = TransectSession(
        startedAt: DateTime.utc(2026, 10, 2, 1, 5),
        endedAt: DateTime.utc(2026, 10, 2, 1, 50),
        tapeLengthMeters: 50,
        siteName: 'Day-as',
        observerName: 'Observer A',
        entryFix: entry,
        exitFix: exit,
      );
      final path = await ReportExporter.exportSessionCsv(
        outputDirectory: tempDir.path,
        session: session,
      );

      final rows = await readRows(path);
      expect(rows, hasLength(2));
      expect(rows.first, ReportExporter.sessionCsvHeaders);
      final row = Map.fromIterables(
        ReportExporter.sessionCsvHeaders,
        rows[1].map((cell) => cell.toString()),
      );
      expect(row['Site'], 'Day-as');
      expect(row['Observer'], 'Observer A');
      expect(row['Tape Length (m)'], '50.0');
      expect(row['Started At'], '2026-10-02T01:05:00.000Z');
      expect(row['Ended At'], '2026-10-02T01:50:00.000Z');
      expect(row['Entry Lat'], '10.25');
      expect(row['Entry Lon'], '123.95');
      expect(row['Entry Accuracy (m)'], '8.0');
      expect(row['Entry At'], '2026-10-02T01:00:00.000Z');
      expect(row['Entry Source'], 'gps');
      expect(row['Exit Lat'], '10.25045');
      expect(row['Exit Accuracy (m)'], '');
      expect(row['Exit Source'], 'manual');
      expect(row['Entry-Exit Distance (m)'], '50.0');
    });

    test('missing fixes and times are empty cells, not placeholders', () async {
      final session = TransectSession(
        startedAt: DateTime.utc(2026, 10, 2, 1, 5),
        tapeLengthMeters: 50,
      );
      final path = await ReportExporter.exportSessionCsv(
        outputDirectory: tempDir.path,
        session: session,
      );

      final row = Map.fromIterables(
        ReportExporter.sessionCsvHeaders,
        (await readRows(path))[1].map((cell) => cell.toString()),
      );
      expect(row['Site'], '');
      expect(row['Ended At'], '');
      for (final column in [
        'Entry Lat',
        'Entry Source',
        'Exit Lat',
        'Exit Source',
        'Entry-Exit Distance (m)',
      ]) {
        expect(row[column], '', reason: column);
      }
    });
  });
}
