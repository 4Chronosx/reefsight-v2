import 'dart:io';

import 'package:csv/csv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/services/geo_fix.dart';
import 'package:reefsight_mobile/services/health_history_recorder.dart';
import 'package:reefsight_mobile/services/recount.dart';
import 'package:reefsight_mobile/services/report_exporter.dart';
import 'package:reefsight_mobile/services/session_summary.dart';
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

    // Sub-plan 18 step 6: the photo paths (relative to the app's documents
    // directory, as stored) and the sample they show.
    test('writes the photo columns, empty for a colony with no photo', () async {
      final withPhoto = TrackedColonyRecord(
        sessionId: 1,
        trackId: 3,
        healthLabel: 'CORAL_BL',
        healthHistory: const [],
        firstSeenAt: DateTime.utc(2026, 1, 1, 8),
        lastSeenAt: DateTime.utc(2026, 1, 1, 8, 1),
        photoPath: 'colony_photos/session1_track3.jpg',
        photoCropPath: 'colony_photos/session1_track3_crop.jpg',
        photoLabel: 'CORAL_BL',
        photoConfidence: 0.876,
      );
      final path = await ReportExporter.exportCsv(
        outputDirectory: tempDir.path,
        session: session,
        colonies: [withPhoto, colony(trackId: 4)],
      );

      final rows = const CsvToListConverter(shouldParseNumbers: false)
          .convert(File(path).readAsStringSync());
      String cell(int row, String header) =>
          rows[row][ReportExporter.csvHeaders.indexOf(header)] as String;
      expect(cell(1, 'Photo Path'), 'colony_photos/session1_track3.jpg');
      expect(cell(1, 'Photo Crop Path'), 'colony_photos/session1_track3_crop.jpg');
      expect(cell(1, 'Photo Label'), 'CORAL_BL');
      expect(cell(1, 'Photo Confidence'), '0.88');
      for (final header in ['Photo Path', 'Photo Crop Path', 'Photo Label', 'Photo Confidence']) {
        expect(cell(2, header), '');
      }
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

  // Sub-plan 14 step 6: the recount and its comparison, in the session CSV
  // and in Surveys' one-row-per-recounted-session export.
  group('Recount comparison export', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('report_exporter_recount_test');
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    Future<List<List<dynamic>>> readRows(String path) async =>
        const CsvToListConverter(shouldParseNumbers: false)
            .convert(await File(path).readAsString());

    Map<String, String> asMap(List<dynamic> headers, List<dynamic> row) =>
        Map.fromIterables(headers.map((h) => '$h'), row.map((cell) => '$cell'));

    // App: 3 colonies, 2 classified, 1 bleached (50 %).
    final appColonies = [
      colony(trackId: 1, healthLabel: 'CORAL'),
      colony(trackId: 2, healthLabel: 'CORAL_BL'),
      colony(trackId: 3),
    ];

    TransectSession session({Recount? recount, bool hidden = true}) => TransectSession(
          startedAt: DateTime.utc(2026, 10, 2, 1, 5),
          tapeLengthMeters: 50,
          siteName: 'Day-as',
          observerName: 'Observer A',
          resultsHidden: hidden,
          resultsRevealedAt: recount?.at,
          recount: recount,
        );

    // Recount: 4 colonies, 1 bleached (25 %).
    final recount = Recount(
      total: 4,
      bleached: 1,
      countedBy: 'B. Counter',
      at: DateTime.utc(2026, 10, 2, 3),
      blinded: true,
    );

    void expectComparison(Map<String, String> row) {
      expect(row['Results Hidden'], 'true');
      expect(row['Recount Total'], '4');
      expect(row['Recount Bleached'], '1');
      expect(row['Recount By'], 'B. Counter');
      expect(row['Recount At'], '2026-10-02T03:00:00.000Z');
      expect(row['Recount Blinded'], 'true');
      expect(row['App Total'], '3');
      expect(row['App Bleached'], '1');
      expect(row['App Classified'], '2');
      expect(row['Count Error'], '-1');
      expect(row['Count Error (%)'], '-25.00');
      expect(row['App Prevalence (%)'], '50.00');
      expect(row['Recount Prevalence (%)'], '25.00');
      expect(row['Prevalence Diff (pp)'], '25.00');
    }

    test('the session CSV carries the recount and the comparison', () async {
      final path = await ReportExporter.exportSessionCsv(
        outputDirectory: tempDir.path,
        session: session(recount: recount),
        colonies: appColonies,
      );

      final rows = await readRows(path);
      expect(rows.first, ReportExporter.sessionCsvHeaders);
      expectComparison(asMap(rows.first, rows[1]));
    });

    test('with no recount, the recount and comparison cells are empty', () async {
      final path = await ReportExporter.exportSessionCsv(
        outputDirectory: tempDir.path,
        session: session(hidden: false),
        colonies: appColonies,
      );

      final rows = await readRows(path);
      final row = asMap(rows.first, rows[1]);
      expect(row['Results Hidden'], 'false');
      expect(row['App Total'], '3');
      for (final column in [
        'Recount Total',
        'Recount Blinded',
        'Count Error',
        'Count Error (%)',
        'Prevalence Diff (pp)',
      ]) {
        expect(row[column], '', reason: column);
      }
    });

    test('Surveys export writes one row per recounted session', () async {
      final path = await ReportExporter.exportRecountComparisonsCsv(
        outputDirectory: tempDir.path,
        sessions: [
          SessionSummary(
            session: session(recount: recount),
            colonyCount: 3,
            bleachedCount: 1,
            classifiedCount: 2,
          ),
          SessionSummary(
            session: session(hidden: false),
            colonyCount: 5,
            bleachedCount: 0,
            classifiedCount: 5,
          ),
        ],
        exportedAt: DateTime.utc(2026, 10, 2, 4, 30),
      );

      expect(
        path.split(RegExp(r'[\\/]')).last,
        'reefsight_recount_comparisons_2026-10-02T04-30-00.csv',
      );
      final rows = await readRows(path);
      expect(rows, hasLength(2), reason: 'header plus the one recounted session');
      expect(rows.first, ReportExporter.recountComparisonsCsvHeaders);
      final row = asMap(rows.first, rows[1]);
      expect(row['Site'], 'Day-as');
      expect(row['Started At'], '2026-10-02T01:05:00.000Z');
      expect(row['Tape Length (m)'], '50.0');
      expectComparison(row);
    });
  });

  // Sub-plan 17: the intervals the app shows, in the session CSV so the
  // thesis can quote the same numbers. Filled whenever colonies are given,
  // below the small-sample threshold too (that rule is the executive tab's).
  group('Interval columns (sub-plan 17)', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('report_exporter_interval_test');
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    final session = TransectSession(
      startedAt: DateTime.utc(2026, 10, 2, 1, 5),
      tapeLengthMeters: 50,
      siteName: 'Day-as',
    );

    Future<Map<String, String>> exportRow(List<TrackedColonyRecord>? colonies) async {
      final path = await ReportExporter.exportSessionCsv(
        outputDirectory: tempDir.path,
        session: session,
        colonies: colonies,
      );
      final rows = const CsvToListConverter(shouldParseNumbers: false)
          .convert(await File(path).readAsString());
      expect(rows.first, ReportExporter.sessionCsvHeaders);
      return Map.fromIterables(rows.first.map((h) => '$h'), rows[1].map((c) => '$c'));
    }

    test('carries prevalence and density with their 95% bounds', () async {
      // 18 of 100 bleached on a 50 m x 1 m belt.
      final row = await exportRow([
        for (var i = 0; i < 100; i++)
          colony(trackId: i + 1, healthLabel: i < 18 ? 'CORAL_BL' : 'CORAL'),
      ]);

      expect(row['Prevalence (%)'], '18.00');
      expect(row['Prevalence 95% Low (%)'], '11.70');
      expect(row['Prevalence 95% High (%)'], '26.67');
      expect(row['Density (/m²)'], '2.000');
      expect(double.parse(row['Density 95% Low (/m²)']!), closeTo(81.364 / 50, 1e-3));
      expect(double.parse(row['Density 95% High (/m²)']!), closeTo(121.63 / 50, 1e-3));
    });

    test('without colonies, or with none classified, the cells are empty', () async {
      final withoutColonies = await exportRow(null);
      final noneClassified = await exportRow([colony(trackId: 1)]);

      for (final column in ['Prevalence (%)', 'Prevalence 95% Low (%)', 'Density (/m²)']) {
        expect(withoutColonies[column], '', reason: column);
      }
      expect(noneClassified['Prevalence (%)'], '');
      expect(noneClassified['Prevalence 95% High (%)'], '');
      expect(noneClassified['Density (/m²)'], '0.020');
    });
  });
}
