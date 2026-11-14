import 'dart:io';

import 'package:csv/csv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:reefsight_mobile/services/cover_calculator.dart';
import 'package:reefsight_mobile/services/geo_fix.dart';
import 'package:reefsight_mobile/services/health_history_recorder.dart';
import 'package:reefsight_mobile/services/recount.dart';
import 'package:reefsight_mobile/services/report_exporter.dart';
import 'package:reefsight_mobile/services/session_summary.dart';
import 'package:reefsight_mobile/services/station.dart';
import 'package:reefsight_mobile/services/station_checks.dart';
import 'package:reefsight_mobile/services/station_summary.dart';
import 'package:reefsight_mobile/services/tracked_colony_record.dart';
import 'package:reefsight_mobile/services/transect_cover.dart';
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

    // Issue #3: a colony-count station transect's files carry the station
    // and transect, in the name (T1-T5 no longer sort by start time alone)
    // and in four columns at the end -- the earlier columns stay put.
    group('station transects (#3)', () {
      final station = Station(
        id: 3,
        code: 'ALG S1/x',
        surveyType: SurveyType.colonyCount,
        surveyedOn: DateTime(2026, 11, 15),
        createdAt: DateTime.utc(2026, 11, 14),
      );
      final t2 = TransectSession(
        startedAt: DateTime.utc(2026, 11, 15, 2),
        tapeLengthMeters: 50,
        siteName: 'Alegria MPA',
        stationId: 3,
        transectNumber: 2,
      );

      test('the station columns come last, after the existing ones', () {
        final headers = ReportExporter.sessionCsvHeaders;
        expect(headers.sublist(headers.length - 4), [
          'Station',
          'Transect',
          'Survey Type',
          'Report Scope',
        ]);
        expect(headers.first, 'Site');
      });

      test('both files are named with the sanitized station and T-number', () async {
        final colonyPath = await ReportExporter.exportCsv(
          outputDirectory: tempDir.path,
          session: t2,
          colonies: const [],
          station: station,
        );
        final sessionPath = await ReportExporter.exportSessionCsv(
          outputDirectory: tempDir.path,
          session: t2,
          station: station,
        );

        final name = p.basename(colonyPath);
        expect(name, startsWith('reefsight_Alegria_MPA_ALG_S1_x_T2_2026-11-15T02-00-00'));
        expect(sessionPath, colonyPath.replaceFirst(RegExp(r'\.csv$'), '_session.csv'));
        expect(p.equals(p.dirname(colonyPath), tempDir.path), isTrue);
      });

      test('the session row says which station and that it is research', () async {
        final path = await ReportExporter.exportSessionCsv(
          outputDirectory: tempDir.path,
          session: t2,
          station: station,
        );
        final row = Map.fromIterables(
          ReportExporter.sessionCsvHeaders,
          (await readRows(path))[1].map((cell) => cell.toString()),
        );
        expect(row['Station'], 'ALG S1/x');
        expect(row['Transect'], '2');
        expect(row['Survey Type'], 'colony_count');
        expect(row['Report Scope'], kResearchScopeNote);
      });

      test('a quick transect leaves them empty and keeps its old name', () async {
        final quick = TransectSession(
          startedAt: DateTime.utc(2026, 11, 15, 2),
          tapeLengthMeters: 50,
          siteName: 'Alegria MPA',
        );
        final path = await ReportExporter.exportSessionCsv(
          outputDirectory: tempDir.path,
          session: quick,
        );
        final row = Map.fromIterables(
          ReportExporter.sessionCsvHeaders,
          (await readRows(path))[1].map((cell) => cell.toString()),
        );
        for (final column in ['Station', 'Transect', 'Survey Type', 'Report Scope']) {
          expect(row[column], '', reason: column);
        }
        expect(
          p.basename(path),
          'reefsight_Alegria_MPA_2026-11-15T02-00-00_session.csv',
        );
      });
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

  // A cell starting with = + - @ (or tab / CR) is a formula to Excel. Free
  // text gets a leading apostrophe; numbers, negative ones included, don't.
  group('ReportExporter.csvSafe', () {
    test('prefixes text that would be read as a formula', () {
      for (final risky in ['=1+1', '+A1', '-cmd', '@SUM(A1)', '\t=1', '\r=1']) {
        expect(ReportExporter.csvSafe(risky), "'$risky", reason: risky);
      }
    });

    test('leaves numbers, negative numeric text and ordinary text alone', () {
      for (final safe in <Object?>[-3, 4.5, '-12.50', '-0.5', 'Alegria MPA', '', null, true]) {
        expect(ReportExporter.csvSafe(safe), safe, reason: '$safe');
      }
    });

    test('applies to the session CSV\'s free text too', () async {
      final dir = Directory.systemTemp.createTempSync('reefsight_safe_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = await ReportExporter.exportSessionCsv(
        outputDirectory: dir.path,
        session: TransectSession(
          startedAt: DateTime.utc(2026, 11, 15),
          tapeLengthMeters: 50,
          siteName: '=HYPERLINK("x")',
          observerName: 'Diver A',
        ),
      );
      final rows = const CsvToListConverter(shouldParseNumbers: false, eol: '\n')
          .convert(File(path).readAsStringSync().replaceAll('\r\n', '\n'));
      expect(rows[1][0], '\'=HYPERLINK("x")');
      expect(rows[1][1], 'Diver A');
    });
  });

  // Issue #8: the station sheet in TB 2017-05's CPCe layout -- a column per
  // transect, then mean, SD and SE.
  group('ReportExporter.exportStationCpceCsv', () {
    late Directory tempDir;
    setUp(() => tempDir = Directory.systemTemp.createTempSync('reefsight_cpce_'));
    tearDown(() => tempDir.deleteSync(recursive: true));

    Station station({SurveyType type = SurveyType.photoTransect, String site = 'Alegria MPA'}) => Station(
          id: 1,
          code: 'ALG/S1',
          name: 'Alegria north',
          surveyType: type,
          frameMode: type == SurveyType.photoTransect ? FrameMode.physical : null,
          surveyedOn: DateTime(2026, 11, 15),
          siteName: site,
          depthMinM: 4,
          depthMaxM: 5.5,
          observerName: 'Diver A',
          createdAt: DateTime.utc(2026, 11, 15),
        );

    /// Transect [n]: [hc] points of CB, [bleached] of BLEC, the rest of 100
    /// sand, plus [excluded] TWB points; 11 frames.
    StationTransectCover transect(int n, int hc, {int bleached = 0, int excluded = 0}) {
      TransectCoverRow row(CoverLevel level, String code, int points) => TransectCoverRow(
            sessionId: n,
            categoryCode: code,
            level: level,
            points: points,
            totalPoints: 100,
            percent: points.toDouble(),
          );
      final sand = 100 - hc - bleached;
      return StationTransectCover(
        transect: TransectSession(
          id: n,
          startedAt: DateTime.utc(2026, 11, 15, n),
          tapeLengthMeters: n == 2 ? 30 : 50,
          stationId: 1,
          transectNumber: n,
          depthStartM: 4.5,
          depthEndM: 5,
          modelId: 'coralscapesv2-segformer-b5',
          analyzedOn: AnalyzedOn.laptop,
        ),
        cover: CoverComputation(
          rows: [
            row(CoverLevel.code, 'CB', hc),
            row(CoverLevel.code, 'BLEC', bleached),
            row(CoverLevel.code, 'S', sand),
            row(CoverLevel.major, 'HC', hc + bleached),
            row(CoverLevel.major, 'DC', 0),
            row(CoverLevel.major, 'AA', 0),
            row(CoverLevel.major, 'OB', 0),
            row(CoverLevel.major, 'AB', sand),
          ],
          framesScored: 11,
          allPoints: 100 + excluded,
          excludedPoints: excluded,
          unlabeledPoints: 0,
        ),
      );
    }

    Future<(String, List<List<dynamic>>)> export(StationCoverSummary summary) async {
      final path = await ReportExporter.exportStationCpceCsv(outputDirectory: tempDir.path, summary: summary);
      final rows = const CsvToListConverter(shouldParseNumbers: false, eol: '\n')
          .convert(File(path).readAsStringSync().replaceAll('\r\n', '\n'));
      return (path, rows);
    }

    List<dynamic> rowOf(List<List<dynamic>> rows, String first) => rows.firstWhere((r) => r.first == first);

    final three = [transect(1, 30, bleached: 10, excluded: 10), transect(2, 40), transect(3, 50, bleached: 5)];

    test('is named for the site, station and survey day, sanitized', () async {
      final (path, _) = await export(StationCoverSummary.compute(station(), three));
      expect(p.basename(path), 'reefsight_Alegria_MPA_ALG_S1_cpce_2026-11-15.csv');
      expect(p.dirname(path), tempDir.path);
    });

    // TB 2017-05 Figure 6: counts first (no statistics), then the major
    // categories with MEAN, STD. DEV. and STD. ERROR, the TWB row over all
    // points, a 100 % check row, then every subcategory grouped by major.
    test('follows the CPCe sheet: counts, then majors with mean, SD and SE', () async {
      final (_, rows) = await export(StationCoverSummary.compute(station(), three));
      expect(rowOf(rows, 'TRANSECT NAME'), ['TRANSECT NAME', 'T1', 'T2', 'T3']);
      expect(rowOf(rows, 'Number of frames'), ['Number of frames', '11', '11', '11']);
      expect(rowOf(rows, 'Total points'), ['Total points', '110', '100', '100']);
      expect(rowOf(rows, 'Total points (minus tape+wand+shadow)'),
          ['Total points (minus tape+wand+shadow)', '100', '100', '100']);
      expect(rowOf(rows, 'MAJOR CATEGORY (% of transect)'),
          ['MAJOR CATEGORY (% of transect)', '', '', '', 'MEAN', 'STD. DEV.', 'STD. ERROR']);
      // HC: 40, 40, 55 -> mean 45, SD 8.66, SE 5.00.
      expect(rowOf(rows, 'HARD CORAL (HC)'), ['HARD CORAL (HC)', '40.00', '40.00', '55.00', '45.00', '8.66', '5.00']);
      // TWB is over all points: 10 / 110.
      expect(rowOf(rows, 'TAPE, WAND, SHADOW AND OTHER (TWB)').sublist(1, 4), ['9.09', '0.00', '0.00']);
      expect(rowOf(rows, 'Sum (excluding tape+shadow+wand)'),
          ['Sum (excluding tape+shadow+wand)', '100.00', '100.00', '100.00']);
    });

    test('lists every subcategory under its major, zeros included', () async {
      final (_, rows) = await export(StationCoverSummary.compute(station(), three));
      final labels = rows.map((r) => r.first).toList();
      final start = labels.indexOf('SUBCATEGORIES (% of transect)');
      expect(start, greaterThan(labels.indexOf('Sum (excluding tape+shadow+wand)')));
      expect(labels.sublist(start + 1, start + 3), ['HARD CORAL (HC)', 'Acropora branching (ACB)']);
      expect(rowOf(rows, 'Bleached coral (BLEC)'),
          ['Bleached coral (BLEC)', '10.00', '0.00', '5.00', '5.00', '5.00', '2.89']);
      expect(rowOf(rows, 'Mushroom coral (CMR)').sublist(1), ['0.00', '0.00', '0.00', '0.00', '0.00', '0.00']);
      expect(labels, containsAllInOrder(['DEAD CORAL (DC)', 'ALGAE (AA)', 'OTHER BIOTA (OB)', 'ABIOTIC (AB)']));
      expect(rowOf(rows, 'Sand (S)').sublist(1, 4), ['60.00', '60.00', '45.00']);
    });

    test('gives each transect\'s tape, depths and expert use after the table', () async {
      final (_, rows) = await export(StationCoverSummary.compute(station(), three));
      expect(rowOf(rows, 'Tape length (m)'), ['Tape length (m)', '50', '30', '50']);
      expect(rowOf(rows, 'Depth end (m)').sublist(1), ['5.0', '5.0', '5.0']);
      expect(rowOf(rows, 'Uses expert corrections')[1], 'no');
    });

    test('neutralizes free text Excel would read as a formula', () async {
      final risky = station().copyWith(code: '=1+1', name: '+SUM(A1)', observerName: '@cmd');
      final (path, rows) = await export(StationCoverSummary.compute(risky, three));
      expect(rowOf(rows, 'Station')[1], "'=1+1");
      expect(rowOf(rows, 'Name')[1], "'+SUM(A1)");
      expect(rowOf(rows, 'Observer')[1], "'@cmd");
      expect(p.basename(path), contains('_1_1_cpce_'));
    });

    test('ends with the station mean, grade, bleaching and flags', () async {
      final (_, rows) = await export(StationCoverSummary.compute(station(), three));
      expect(rowOf(rows, 'Hard coral cover (station mean, %)')[1], '45.0');
      expect(rowOf(rows, 'Hard coral grade (TB 2019-04)')[1], 'A (Excellent)');
      expect(rowOf(rows, 'Bleached coral (station mean, %)')[1], '5.0');
      expect(rowOf(rows, 'Transects analyzed')[1], '3');
      expect(rows.any((r) => r.first == 'Flag' && r[1] == 'T2: Tape is 30 m, not 50 m'), isTrue);
    });

    test('carries the station header', () async {
      final (_, rows) = await export(StationCoverSummary.compute(station(), three));
      expect(rowOf(rows, 'Station')[1], 'ALG/S1');
      expect(rowOf(rows, 'Survey type')[1], 'Photo transect');
      expect(rowOf(rows, 'Frame mode')[1], 'Physical frame');
      expect(rowOf(rows, 'Depth range (m)')[1], '4.0-5.5');
      expect(rowOf(rows, 'Model')[1], 'coralscapesv2-segformer-b5');
      expect(rowOf(rows, 'Analyzed on')[1], 'laptop');
      expect(rows.first.first, isNot(kPreliminaryStamp));
    });

    test('one transect leaves SD and SE blank', () async {
      final (_, rows) = await export(StationCoverSummary.compute(station(), [transect(1, 30)]));
      expect(rowOf(rows, 'HARD CORAL (HC)').sublist(1), ['30.00', '30.00', '', '']);
    });

    test('a preliminary station is stamped in its name, first line and grade', () async {
      final (path, rows) =
          await export(StationCoverSummary.compute(station(type: SurveyType.preliminaryVideo), three));
      expect(p.basename(path), startsWith('PRELIMINARY_reefsight_'));
      expect(rows.first.first, kPreliminaryStamp);
      expect(rowOf(rows, 'Hard coral grade (TB 2019-04)')[1], 'A (Excellent), indicative');
      expect(rowOf(rows, 'Report scope')[1], kPreliminaryStamp);
    });

    test('a station with no analyzed transects says so instead of a table', () async {
      final (_, rows) = await export(StationCoverSummary.compute(station(), const []));
      expect(rows.any((r) => r.first == 'TRANSECT NAME'), isFalse);
      expect(rowOf(rows, 'Transects analyzed')[1], '0');
      expect(rowOf(rows, 'Hard coral grade (TB 2019-04)')[1], '');
    });
  });
}
