import 'dart:io';

import 'package:csv/csv.dart';
import 'package:share_plus/share_plus.dart';

import 'geo_fix.dart';
import 'recount_comparison.dart';
import 'report_data.dart';
import 'session_summary.dart';
import 'station.dart';
import 'station_checks.dart';
import 'station_summary.dart';
import 'tb_categories.dart';
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
  /// session CSV, so the two files from one transect sort together. Issue
  /// #3: a station transect is `reefsight_<site>_<station>_T<n>_<start>`,
  /// so a station's T1-T5 are told apart by name; the station code is free
  /// text too, so it is sanitized the same way.
  static String _baseName(TransectSession session, Station? station) {
    final timestamp = session.startedAt
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-')
        .substring(0, 19);
    final site = _sanitizeForFilename(session.siteName);
    if (station == null) return 'reefsight_${site}_$timestamp';
    final number = session.transectNumber;
    final transect = number == null ? '' : '_T$number';
    return 'reefsight_${site}_${_sanitizeForFilename(station.code)}${transect}_$timestamp';
  }

  static Future<String> _write(
    String outputDirectory,
    String filename,
    List<List<dynamic>> rows,
  ) async {
    final file = File('$outputDirectory/$filename');
    await file.writeAsString(const ListToCsvConverter().convert([
      for (final row in rows) [for (final cell in row) csvSafe(cell)],
    ]));
    return file.path;
  }

  static final _formulaStart = RegExp(r'^[=+\-@\t\r]');

  /// Issue #8: text starting with `=`, `+`, `-`, `@`, a tab or a carriage
  /// return is run as a formula by Excel and other spreadsheets ("CSV
  /// injection"). Site, station, observer and other free text are typed by
  /// the diver, so every exported cell goes through this: such text gets a
  /// leading apostrophe, which spreadsheets show as plain text. Numbers, and
  /// text that is a plain number (a negative difference like "-12.50"), are
  /// left alone.
  static Object? csvSafe(Object? cell) {
    if (cell is! String || !_formulaStart.hasMatch(cell) || num.tryParse(cell) != null) return cell;
    return "'$cell";
  }

  static Future<String> exportCsv({
    required String outputDirectory,
    required TransectSession session,
    required List<TrackedColonyRecord> colonies,
    Station? station,
  }) {
    return _write(outputDirectory, '${_baseName(session, station)}.csv', [
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
    ..._stationHeaders,
  ];

  /// Issue #3: last, so every earlier column keeps its position for
  /// existing sheets and scripts. Empty for a quick transect. "Report
  /// Scope" says a colony-count transect is research, outside the
  /// bulletins (alignment doc §10).
  static const List<String> _stationHeaders = [
    'Station',
    'Transect',
    'Survey Type',
    'Report Scope',
  ];

  static List<dynamic> _stationCells(TransectSession session, Station? station) {
    if (station == null) return const ['', '', '', ''];
    return [
      station.code,
      session.transectNumber ?? '',
      station.surveyType.db,
      reportsBulletinCover(station.surveyType) ? '' : kResearchScopeNote,
    ];
  }

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
    Station? station,
  }) {
    final entry = session.entryFix;
    final exit = session.exitFix;
    final report = colonies == null
        ? null
        : TransectReport(session: session, colonies: colonies);
    return _write(outputDirectory, '${_baseName(session, station)}_session.csv', [
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
        ..._stationCells(session, station),
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

  static String _isoDay(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// Issue #8: `reefsight_<site>_<station>_cpce_<survey day>.csv`, with
  /// `PRELIMINARY_` in front for a preliminary station, so the stamp is on
  /// the file before anyone opens it (alignment doc §7).
  static String stationCpceFilename(Station station) {
    final prefix = station.surveyType == SurveyType.preliminaryVideo ? 'PRELIMINARY_' : '';
    return '${prefix}reefsight_${_sanitizeForFilename(station.siteName)}_'
        '${_sanitizeForFilename(station.code)}_cpce_${_isoDay(station.surveyedOn)}.csv';
  }

  static String _meters(double m) => m == m.roundToDouble() ? m.toStringAsFixed(0) : m.toString();

  /// Issue #8: the station sheet in the layout of TB 2017-05's CPCe sample
  /// (alignment doc §1b): a header, then a table with a column per analyzed
  /// transect (T1…Tn) and then Mean, SD and SE -- the counts (frames, total
  /// points, points excluded as tape, wand and shadow, points counted), each
  /// major category's % cover and each TB code's -- and the station result:
  /// mean hard coral cover, its TB 2019-04 grade, mean % bleached coral, and
  /// every flag. Percentages have two decimals in the table; the result
  /// lines show one, the precision the grade is taken at. A blank cell is a
  /// value that doesn't exist (SD with one transect), never a zero.
  static Future<String> exportStationCpceCsv({
    required String outputDirectory,
    required StationCoverSummary summary,
  }) {
    final station = summary.station;
    final t = summary.analyzed;
    final stamp = summary.isPreliminary ? kPreliminaryStamp : null;
    String depth(double? m) => m?.toStringAsFixed(1) ?? '?';
    String joined(Iterable<String?> values) => {...values.nonNulls}.join('; ');
    String yesNo(bool value) => value ? 'yes' : 'no';

    // TB 2017-05 Figure 6: counts and per-transect details have a value per
    // transect and no statistics.
    List<dynamic> perTransect(String label, Object? Function(StationTransectCover) value) =>
        [label, for (final x in t) value(x) ?? ''];

    List<dynamic> statRow(String label, CategoryStat s) =>
        [label, for (final v in s.percents) _fixed(v), _fixed(s.mean), _fixed(s.sd), _fixed(s.se)];

    List<dynamic> blockHeader(String label) =>
        [label, for (final _ in t) '', 'MEAN', 'STD. DEV.', 'STD. ERROR'];

    String majorLabel(String code) => '${kMajorNames[code]!.toUpperCase()} ($code)';
    final excluded = summary.excludedStat;
    final catalogue = summary.catalogueStats();

    final hc = summary.hardCoral;
    final bleached = summary.bleached;
    return _write(outputDirectory, stationCpceFilename(station), [
      if (stamp != null) [stamp],
      ['ReefSight station summary (CPCe layout, TB 2017-05)'],
      ['Station', station.code],
      ['Name', station.name ?? ''],
      ['Site', station.siteName ?? ''],
      ['Surveyed on', _isoDay(station.surveyedOn)],
      ['Survey type', surveyTypeLabel(station.surveyType)],
      ['Frame mode', station.frameMode == null ? '' : frameModeLabel(station.frameMode!)],
      ['Observer', station.observerName ?? ''],
      ['Reef zone', station.reefZone == null ? '' : reefZoneLabel(station.reefZone!)],
      [
        'Depth range (m)',
        station.depthMinM == null && station.depthMaxM == null
            ? ''
            : '${depth(station.depthMinM)}-${depth(station.depthMaxM)}',
      ],
      ['Deep edge (lat, lon, accuracy m, at, source)', ..._fixCells(station.deepEdgeFix)],
      ['Model', joined(t.map((x) => x.transect.modelId))],
      ['Analyzed on', joined(t.map((x) => x.transect.analyzedOn?.db))],
      ['Uses expert corrections', yesNo(summary.usesExpert)],
      ['Report scope', stamp ?? 'TB 2017-05 photo transect method; graded on the TB 2019-04 scale'],
      [],
      if (t.isNotEmpty && excluded != null) ...[
        ['TRANSECT NAME', for (final x in t) x.label],
        perTransect('Number of frames', (x) => x.cover.framesScored),
        perTransect('Total points', (x) => x.cover.allPoints),
        perTransect('Total points (minus tape+wand+shadow)', (x) => x.cover.countedPoints),
        [],
        blockHeader('MAJOR CATEGORY (% of transect)'),
        for (final m in summary.majors) statRow(majorLabel(m.code), m),
        // Over all points, as in CPCe; every other row is over points counted.
        statRow('TAPE, WAND, SHADOW AND OTHER (TWB)', excluded),
        [
          'Sum (excluding tape+shadow+wand)',
          for (var i = 0; i < t.length; i++) _fixed(summary.majors.fold<double>(0, (s, m) => s + m.percents[i])),
        ],
        [],
        blockHeader('SUBCATEGORIES (% of transect)'),
        for (final major in kMajorNames.keys) ...[
          [majorLabel(major)],
          for (final c in catalogue)
            if (tbCategory(c.code).major.db == major) statRow('${c.name} (${c.code})', c),
        ],
        [],
        ['TRANSECT DETAILS', for (final x in t) x.label],
        perTransect('Tape length (m)', (x) => _meters(x.transect.tapeLengthMeters)),
        perTransect('Depth start (m)', (x) => x.transect.depthStartM),
        perTransect('Depth end (m)', (x) => x.transect.depthEndM),
        perTransect('Uses expert corrections', (x) => yesNo(x.usesExpert)),
        [],
      ],
      ['Transects analyzed', summary.n],
      ['Hard coral cover (station mean, %)', hc == null ? '' : formatPercent1(hc.mean)],
      ['Hard coral grade (TB 2019-04)', summary.gradeLine ?? ''],
      ['Bleached coral (station mean, %)', bleached == null ? '' : formatPercent1(bleached.mean)],
      for (final flag in summary.flags) ['Flag', flag],
    ]);
  }

  /// Issue #8: shares the station sheet through the share sheet (#9 makes
  /// the organized .zip).
  static Future<void> shareStationSheet(String filePath, {required bool preliminary}) async {
    await Share.shareXFiles(
      [XFile(filePath)],
      subject: preliminary ? 'ReefSight station summary (PRELIMINARY)' : 'ReefSight station summary',
      text: preliminary
          ? '$kPreliminaryStamp. Station cover summary in the CPCe layout.'
          : 'Station cover summary in the CPCe layout (TB 2017-05), graded on the TB 2019-04 scale.',
    );
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
