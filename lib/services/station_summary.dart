import 'dart:math';

import 'cover_calculator.dart';
import 'station.dart';
import 'station_checks.dart';
import 'tb_categories.dart';
import 'transect_cover.dart';
import 'transect_session.dart';

/// Issue #8: a station's % cover summary across its transects, as TB 2017-05's
/// CPCe sheet reports it and TB 2019-04 grades it (`docs/reefsight-v2-blueprint.md`
/// §6; reasoning in `../docs/station-summary-statistics-and-grading.md`).
///
/// - The **transect is the unit of replication**: each category's transect
///   percentages are averaged, and points are never pooled. A code a transect
///   doesn't have is 0 % there, so the mean is over every analyzed transect.
/// - **SD is the sample SD** (n − 1), as CPCe's Excel sheets work it out, and
///   **SE = SD ÷ √n**. With one transect there is no SD or SE.
/// - Only transects whose cover is complete (every point labeled) count
///   toward n. The others are named in the flags, and n is what the TB
///   2019-04 minimum of 3 is checked against.
/// - The hard coral **grade comes from the station mean as shown**, to one
///   decimal ([gradeHardCoral]), so a sheet can't say "44.0 %" next to an A.

/// TB 2019-04's hard coral cover scale (Licuanan et al. 2017), which TB
/// 2017-05 words as Excellent, Good, Fair and Poor.
enum CoverGrade {
  a('A', 'Excellent'),
  b('B', 'Good'),
  c('C', 'Fair'),
  d('D', 'Poor');

  const CoverGrade(this.letter, this.word);
  final String letter;
  final String word;
}

/// A percentage as the summary shows it: one decimal.
String formatPercent1(double percent) => percent.toStringAsFixed(1);

/// A >44 % · B >33–44 % · C >22–33 % · D 0–22 %, on [meanPercent] rounded to
/// one decimal ([formatPercent1]) -- the value the screen and the sheet show.
CoverGrade gradeHardCoral(double meanPercent) {
  final shown = double.parse(formatPercent1(meanPercent));
  if (shown > 44) return CoverGrade.a;
  if (shown > 33) return CoverGrade.b;
  if (shown > 22) return CoverGrade.c;
  return CoverGrade.d;
}

/// Where a station has no analyzed transect yet, so no summary.
const kNoSummaryYet = 'The station summary appears once a transect has been analyzed.';

/// Shown when one transect gives a mean but no spread.
const kFlagNoSpread = 'One transect: no SD or SE';

/// On every preliminary screen, report and export (alignment doc §7).
const kPreliminaryStamp = 'Preliminary — not for official reporting (TB 2019-04 reconnaissance only)';

/// The five counted major categories' names, by their code.
const kMajorNames = {
  'HC': 'Hard coral',
  'DC': 'Dead coral',
  'AA': 'Algae',
  'OB': 'Other biota',
  'AB': 'Abiotic',
};

/// One transect's input: the session and its cover as `computeCover` (or
/// `TransectDatabase.refreshTransectCover`) worked it out, counts included.
class StationTransectCover {
  const StationTransectCover({required this.transect, required this.cover});

  final TransectSession transect;
  final CoverComputation cover;

  /// "T2", or "T?" for a transect with no number.
  String get label => 'T${transect.transectNumber ?? '?'}';

  bool get usesExpert => cover.rows.any((r) => r.usesExpert);
}

/// One row of the summary: a category's percentage in each analyzed
/// transect (in [StationCoverSummary.analyzed] order), and their mean, SD
/// and SE.
class CategoryStat {
  CategoryStat({required this.level, required this.code, required this.name, required this.percents}) {
    if (percents.isEmpty) throw ArgumentError('A category needs at least one transect');
  }

  final CoverLevel level;
  final String code;
  final String name;
  final List<double> percents;

  int get n => percents.length;

  double get mean => percents.reduce((a, b) => a + b) / n;

  /// Sample SD (n − 1); `null` with one transect.
  double? get sd {
    if (n < 2) return null;
    final m = mean;
    return sqrt(percents.fold(0.0, (s, p) => s + (p - m) * (p - m)) / (n - 1));
  }

  /// SD ÷ √n; `null` with one transect.
  double? get se {
    final s = sd;
    return s == null ? null : s / sqrt(n);
  }
}

class StationCoverSummary {
  const StationCoverSummary._({
    required this.station,
    required this.analyzed,
    required this.notAnalyzed,
    required this.majors,
    required this.codes,
    required this.flags,
  });

  /// Throws [ArgumentError] for a colony-count station: its results are
  /// research, never pooled into a bulletin summary (#3).
  factory StationCoverSummary.compute(Station station, List<StationTransectCover> transects) {
    if (!reportsBulletinCover(station.surveyType)) {
      throw ArgumentError('A ${station.surveyType.db} station has no cover summary');
    }
    const unnumbered = 1 << 30;
    final ordered = [...transects]..sort((a, b) =>
        (a.transect.transectNumber ?? unnumbered).compareTo(b.transect.transectNumber ?? unnumbered));
    final analyzed = [for (final t in ordered) if (t.cover.isComplete) t];
    final notAnalyzed = [for (final t in ordered) if (!t.cover.isComplete) t];

    List<CategoryStat> stats(CoverLevel level, Iterable<String> codes, String Function(String) name) {
      if (analyzed.isEmpty) return const [];
      return [for (final code in codes) _statOf(analyzed, level, code, name(code))];
    }

    final present = {
      for (final t in analyzed)
        for (final r in t.cover.rows)
          if (r.level == CoverLevel.code) r.categoryCode,
    };
    final catalogue = kTbCategories.keys.toList();
    final codes = present.toList()..sort((a, b) => catalogue.indexOf(a).compareTo(catalogue.indexOf(b)));

    final n = analyzed.length;
    return StationCoverSummary._(
      station: station,
      analyzed: analyzed,
      notAnalyzed: [for (final t in notAnalyzed) t.transect],
      majors: stats(CoverLevel.major, kMajorNames.keys, (code) => kMajorNames[code]!),
      codes: stats(CoverLevel.code, codes, (code) => tbCategory(code).name),
      flags: [
        ...stationFlags(station, n),
        if (n == 1) kFlagNoSpread,
        for (final t in ordered)
          for (final flag in transectFlags(t.transect)) '${t.label}: $flag',
        for (final t in notAnalyzed) '${t.label} not analyzed: left out of the summary',
      ],
    );
  }

  /// [level] [code]'s percentage in each of [analyzed], 0 where absent.
  static CategoryStat _statOf(List<StationTransectCover> analyzed, CoverLevel level, String code, String name) =>
      CategoryStat(
        level: level,
        code: code,
        name: name,
        percents: [
          for (final t in analyzed)
            t.cover.rows.where((r) => r.level == level && r.categoryCode == code).firstOrNull?.percent ?? 0,
        ],
      );

  /// TB 2017-05 Figure 6's subcategory block: every counted TB code, zeros
  /// included, grouped by major (HC, DC, AA, OB, AB) and by name within
  /// each, as CPCe lists its code file. Empty with no analyzed transect.
  List<CategoryStat> catalogueStats() {
    if (analyzed.isEmpty) return const [];
    return [
      for (final major in kMajorNames.keys)
        for (final c in kTbCategories.values.where((c) => c.major.db == major).toList()
          ..sort((a, b) => a.name.compareTo(b.name)))
          _statOf(analyzed, CoverLevel.code, c.code, c.name),
    ];
  }

  /// CPCe's "TAPE, SHADOW, BLOCKS, IND (TWB)" row: excluded points as a
  /// percentage of **all** points, unlike every other row, which is over
  /// the points counted. `null` with no analyzed transect.
  CategoryStat? get excludedStat {
    if (analyzed.isEmpty) return null;
    return CategoryStat(
      level: CoverLevel.major,
      code: 'TWB',
      name: 'Tape, wand, shadow and other',
      percents: [for (final t in analyzed) t.cover.excludedPoints / t.cover.allPoints * 100],
    );
  }

  final Station station;

  /// Transects with complete cover, by number: the columns T1…Tn.
  final List<StationTransectCover> analyzed;

  /// Transects set up but not (fully) scored, by number.
  final List<TransectSession> notAnalyzed;

  /// HC, DC, AA, OB, AB, always all five (empty with no analyzed transect).
  final List<CategoryStat> majors;

  /// Every TB code present in any analyzed transect, BLEC always, in
  /// catalogue order (which groups them by major).
  final List<CategoryStat> codes;

  /// TB 2019-04 checks and the transects left out, in display order.
  final List<String> flags;

  int get n => analyzed.length;

  bool get isPreliminary => station.surveyType == SurveyType.preliminaryVideo;

  CategoryStat? get hardCoral => majors.where((m) => m.code == 'HC').firstOrNull;

  CategoryStat? get bleached => codes.where((c) => c.code == 'BLEC').firstOrNull;

  CoverGrade? get grade {
    final hc = hardCoral;
    return hc == null ? null : gradeHardCoral(hc.mean);
  }

  /// "B (Good)", or "B (Good), indicative" for a preliminary station.
  String? get gradeLine {
    final g = grade;
    if (g == null) return null;
    return '${g.letter} (${g.word})${isPreliminary ? ', indicative' : ''}';
  }

  bool get usesExpert => analyzed.any((t) => t.usesExpert);
}
