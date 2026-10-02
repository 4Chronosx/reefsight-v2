import 'report_data.dart';
import 'session_summary.dart';
import 'transect_metrics.dart';
import 'transect_session.dart';

/// Sub-plan 19: what the Executive tab says, built from one transect's
/// report and the last survey of the same site. Pure Dart, like
/// `report_data.dart`, so every wording decision is unit-tested here rather
/// than in the widget tree.
///
/// Written for the Municipal Environment and Natural Resources Office and
/// the Gilutongan/Alegria MPA boards (sub-plan 19 step 0): plain language,
/// and no management actions. No track IDs, confidences or size-frequency
/// -- those belong on the Technical tab.
class ExecutiveSummary {
  const ExecutiveSummary._({
    required this.statusSentence,
    required this.severity,
    required this.comparison,
    required this.details,
  });

  /// [previous] is the latest earlier survey of the same site
  /// (`TransectDatabase.previousSessionForSite`). One from another site, or
  /// not before this one, is ignored rather than trusted.
  static ExecutiveSummary build(TransectReport report, {SessionSummary? previous}) {
    final session = report.session;
    final estimate = report.prevalence;
    // An unfinished transect (app killed mid-dive) is a partial sample:
    // no severity word, and no verdict against the last survey.
    final finished = session.endedAt != null;
    final severity = estimate == null || !finished
        ? null
        : bleachingSeverityFor(estimate.interval, reliable: estimate.reliable);
    return ExecutiveSummary._(
      statusSentence: _statusSentence(report, estimate, severity),
      severity: severity,
      comparison: _isEarlierSameSite(previous, session)
          ? SurveyComparison._between(estimate, previous!, currentFinished: finished)
          : null,
      details: _details(session),
    );
  }

  /// Section 1: what was surveyed, then sub-plan 17's prevalence sentence
  /// (or its too-few wording), then the cited severity word if any.
  final String statusSentence;

  /// `null` unless the whole interval is above a Hughes et al. cut-off.
  final BleachingSeverity? severity;

  /// Section 2. `null` when there is no earlier survey of this site.
  final SurveyComparison? comparison;

  /// Section 5: fixed until the Phase E diver recounts are in.
  List<String> get limitations => const [
        'One transect is a sample, not the whole reef.',
        "The app's healthy/bleached labels are still being checked against diver recounts.",
      ];

  /// Section 6: label and value pairs, in display order.
  final List<(String, String)> details;

  static String _statusSentence(
    TransectReport report,
    PrevalenceEstimate? estimate,
    BleachingSeverity? severity,
  ) {
    final session = report.session;
    final site = _siteName(session);
    final where = '${formatTapeLength(session.tapeLengthMeters)} transect'
        '${site == null ? '' : ' at $site'} on ${formatShortDate(session.startedAt)}';
    final total = report.totalColonies;
    if (total == 0) return 'No coral colonies were recorded along the $where.';

    final surveyed = total == 1
        ? '1 coral colony was surveyed along the $where.'
        : '$total coral colonies were surveyed along the $where.';
    if (estimate == null) return '$surveyed None could be assessed for bleaching.';
    final scale = severity == null ? '' : ' ${severity.sentence}';
    return '$surveyed ${estimate.executiveSentence}$scale';
  }

  static bool _isEarlierSameSite(SessionSummary? previous, TransectSession current) {
    if (previous == null) return false;
    final site = _normalizedSite(current.siteName);
    return site != null &&
        _normalizedSite(previous.session.siteName) == site &&
        previous.session.startedAt.isBefore(current.startedAt);
  }

  static List<(String, String)> _details(TransectSession session) {
    final local = session.startedAt.toLocal();
    final fix = session.entryFix;
    return [
      ('Date', '${formatShortDate(local)}, ${_twoDigits(local.hour)}:${_twoDigits(local.minute)}'),
      ('Site', _siteName(session) ?? 'Not recorded'),
      ('Observer', _trimmedOrNull(session.observerName) ?? 'Not recorded'),
      ('Tape length', formatTapeLength(session.tapeLengthMeters)),
      if (fix != null)
        ('Entry position', '${fix.lat.toStringAsFixed(5)}, ${fix.lon.toStringAsFixed(5)}'),
    ];
  }

  static String? _siteName(TransectSession session) => _trimmedOrNull(session.siteName);

  /// "Same site" for now: trimmed and case-insensitive, matching
  /// `TransectDatabase.previousSessionForSite`.
  static String? _normalizedSite(String? site) => _trimmedOrNull(site)?.toLowerCase();

  static String? _trimmedOrNull(String? text) {
    final trimmed = text?.trim() ?? '';
    return trimmed.isEmpty ? null : trimmed;
  }
}

/// The only two severity words Hughes et al. (2017) define: "severe" is an
/// aerial score above 30% of corals bleached, "extreme" above 60%. The
/// paper never says "low" or "moderate", so neither does the app. Citation
/// and the checked quotes: `sub-plans/19-executive-summary.md`, step 0.
enum BleachingSeverity {
  severe(0.30, 'severe bleaching (over 30% of colonies)'),
  extreme(0.60, 'extreme bleaching (over 60% of colonies)');

  const BleachingSeverity(this.cutOff, this._phrase);

  /// The share of colonies bleached that the whole interval must be above.
  final double cutOff;
  final String _phrase;

  /// Names the source and its scope: Hughes et al. scored whole reefs from
  /// the air, not one belt transect.
  String get sentence =>
      'On the scale Hughes et al. (2017) use for whole reefs, this is $_phrase.';
}

/// The highest Hughes et al. word whose cut-off the whole 95% interval is
/// strictly above, or `null`. Judged on the interval's lower end, not the
/// point estimate, so a percentage that is only uncertain never gets a
/// word; and never below sub-plan 17's reliability threshold.
BleachingSeverity? bleachingSeverityFor(ConfidenceInterval interval, {required bool reliable}) {
  if (!reliable) return null;
  BleachingSeverity? highest;
  for (final severity in BleachingSeverity.values) {
    if (interval.low > severity.cutOff) highest = severity;
  }
  return highest;
}

enum ComparisonDirection { up, down, similar, notComparable }

/// Section 2: this survey against the last one of the same site. "Up" or
/// "down" only when the two 95% intervals don't overlap, so an LGU never
/// reacts to noise; both surveys must also be over the reliability
/// threshold.
class SurveyComparison {
  const SurveyComparison._(this.direction, this.text);

  factory SurveyComparison._between(
    PrevalenceEstimate? current,
    SessionSummary previous, {
    required bool currentFinished,
  }) {
    final then = PrevalenceEstimate.of(
      bleached: previous.bleachedCount,
      classified: previous.classifiedCount,
    );
    final when = formatShortDate(previous.session.startedAt);
    final notComparedPrefix = 'Not compared with the last survey of this site ($when):';
    if (!currentFinished) {
      return SurveyComparison._(
        ComparisonDirection.notComparable,
        '$notComparedPrefix this survey ended before the transect was finished.',
      );
    }
    final notCompared = '$notComparedPrefix too few classified colonies';
    if (current == null || !current.reliable) {
      return SurveyComparison._(ComparisonDirection.notComparable, '$notCompared this time.');
    }
    if (then == null || !then.reliable) {
      return SurveyComparison._(ComparisonDirection.notComparable, '$notCompared then.');
    }
    final thenPercent = _percent(then.fraction);
    if (current.interval.low > then.interval.high) {
      return SurveyComparison._(
        ComparisonDirection.up,
        'Up from $thenPercent at the last survey of this site ($when).',
      );
    }
    if (current.interval.high < then.interval.low) {
      return SurveyComparison._(
        ComparisonDirection.down,
        'Down from $thenPercent at the last survey of this site ($when).',
      );
    }
    return SurveyComparison._(
      ComparisonDirection.similar,
      'Similar to the last survey of this site ($when): $thenPercent then, '
      '${_percent(current.fraction)} now; the difference is within the uncertainty.',
    );
  }

  final ComparisonDirection direction;
  final String text;

  static String _percent(double fraction) => '${(fraction * 100).toStringAsFixed(0)}%';
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// "5 Oct 2026", in local time. The year stays in: a report is read long
/// after the dive.
String formatShortDate(DateTime at) {
  final local = at.toLocal();
  return '${local.day} ${_months[local.month - 1]} ${local.year}';
}

/// "50 m", or "25.5 m" for a fractional tape.
String formatTapeLength(double meters) => meters == meters.roundToDouble()
    ? '${meters.toStringAsFixed(0)} m'
    : '${meters.toStringAsFixed(1)} m';

String _twoDigits(int value) => value.toString().padLeft(2, '0');
