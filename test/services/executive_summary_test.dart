import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/services/executive_summary.dart';
import 'package:reefsight_mobile/services/geo_fix.dart';
import 'package:reefsight_mobile/services/health_aggregator.dart';
import 'package:reefsight_mobile/services/report_data.dart';
import 'package:reefsight_mobile/services/session_summary.dart';
import 'package:reefsight_mobile/services/tracked_colony_record.dart';
import 'package:reefsight_mobile/services/transect_metrics.dart';
import 'package:reefsight_mobile/services/transect_session.dart';

// Sub-plan 19 step 1: every wording decision on the Executive tab.

final _oct5 = DateTime(2026, 10, 5, 8, 30);
final _sep12 = DateTime(2026, 9, 12, 9);

TransectSession _session({
  int id = 2,
  DateTime? startedAt,
  String? site = 'Gilutongan',
  String? observer = 'J. Cruz',
  double tape = 50,
  GeoFix? entryFix,
  bool ended = true,
}) =>
    TransectSession(
      id: id,
      startedAt: startedAt ?? _oct5,
      endedAt: ended ? (startedAt ?? _oct5).add(const Duration(hours: 1)) : null,
      tapeLengthMeters: tape,
      siteName: site,
      observerName: observer,
      entryFix: entryFix,
    );

/// [bleached] bleached, [healthy] healthy and [uncertain] unlabelled
/// colonies.
TransectReport _report({
  int bleached = 0,
  int healthy = 0,
  int uncertain = 0,
  TransectSession? session,
}) {
  var trackId = 0;
  TrackedColonyRecord colony(String? label) => TrackedColonyRecord(
        sessionId: 2,
        trackId: ++trackId,
        healthLabel: label,
        healthHistory: const [],
        firstSeenAt: _oct5,
        lastSeenAt: _oct5,
      );
  return TransectReport(
    session: session ?? _session(),
    colonies: [
      for (var i = 0; i < bleached; i++) colony(HealthAggregator.bleachedLabel),
      for (var i = 0; i < healthy; i++) colony(HealthAggregator.healthyLabel),
      for (var i = 0; i < uncertain; i++) colony(null),
    ],
  );
}

SessionSummary _previous({required int bleached, required int classified, String? site}) =>
    SessionSummary(
      session: _session(id: 1, startedAt: _sep12, site: site ?? 'Gilutongan'),
      colonyCount: classified,
      bleachedCount: bleached,
      classifiedCount: classified,
    );

void main() {
  group('status sentence', () {
    test('normal survey: count, tape, site, date, then the prevalence sentence', () {
      final report = _report(bleached: 6, healthy: 24, uncertain: 4);
      final summary = ExecutiveSummary.build(report);

      expect(
        summary.statusSentence,
        startsWith('34 coral colonies were surveyed along the 50 m transect at Gilutongan '
            'on 5 Oct 2026. '),
      );
      expect(summary.statusSentence, endsWith(report.prevalence!.executiveSentence));
    });

    test('one colony is singular; a fractional tape length keeps its decimal', () {
      final report = _report(healthy: 1, session: _session(tape: 25.5));

      expect(
        ExecutiveSummary.build(report).statusSentence,
        startsWith('1 coral colony was surveyed along the 25.5 m transect'),
      );
    });

    test('small n uses the too-few wording', () {
      final summary = ExecutiveSummary.build(_report(bleached: 2, healthy: 4));

      expect(
        summary.statusSentence,
        endsWith('Too few classified colonies to estimate bleaching reliably (n = 6).'),
      );
    });

    test('colonies but none classified', () {
      final summary = ExecutiveSummary.build(_report(uncertain: 3));

      expect(
        summary.statusSentence,
        '3 coral colonies were surveyed along the 50 m transect at Gilutongan on 5 Oct 2026. '
        'None could be assessed for bleaching.',
      );
    });

    test('zero colonies', () {
      expect(
        ExecutiveSummary.build(_report()).statusSentence,
        'No coral colonies were recorded along the 50 m transect at Gilutongan on 5 Oct 2026.',
      );
    });

    test('no site name leaves the site out rather than inventing one', () {
      final report = _report(healthy: 1, session: _session(site: '  '));

      expect(
        ExecutiveSummary.build(report).statusSentence,
        startsWith('1 coral colony was surveyed along the 50 m transect on 5 Oct 2026.'),
      );
    });
  });

  group('severity word (Hughes et al. 2017)', () {
    test('added only when the whole interval is above 30%', () {
      // 20/40: Wilson 35.2-64.8%.
      final summary = ExecutiveSummary.build(_report(bleached: 20, healthy: 20));

      expect(summary.severity, BleachingSeverity.severe);
      expect(summary.statusSentence, contains('severe bleaching'));
      expect(summary.statusSentence, contains('Hughes et al. (2017)'));
    });

    test('"extreme" when the whole interval is above 60%', () {
      // 38/40: Wilson 83.5-98.6%.
      final summary = ExecutiveSummary.build(_report(bleached: 38, healthy: 2));

      expect(summary.severity, BleachingSeverity.extreme);
      expect(summary.statusSentence, contains('extreme bleaching'));
    });

    test('no word when the interval crosses 30%, even with the estimate above it', () {
      // 12/30: 40%, Wilson 24.6-57.7%.
      final summary = ExecutiveSummary.build(_report(bleached: 12, healthy: 18));

      expect(summary.severity, isNull);
      expect(summary.statusSentence, isNot(contains('Hughes')));
    });

    test('no word below the reliability threshold, however high the share', () {
      final summary = ExecutiveSummary.build(_report(bleached: 9));

      expect(summary.severity, isNull);
    });

    test('the cut-offs are strict: an interval starting exactly at a cut-off is not above it', () {
      expect(bleachingSeverityFor(const ConfidenceInterval(0.30, 0.5), reliable: true), isNull);
      expect(
        bleachingSeverityFor(const ConfidenceInterval(0.3001, 0.5), reliable: true),
        BleachingSeverity.severe,
      );
      expect(
        bleachingSeverityFor(const ConfidenceInterval(0.60, 0.9), reliable: true),
        BleachingSeverity.severe,
      );
      expect(
        bleachingSeverityFor(const ConfidenceInterval(0.6001, 0.9), reliable: true),
        BleachingSeverity.extreme,
      );
      expect(bleachingSeverityFor(const ConfidenceInterval(0.7, 0.9), reliable: false), isNull);
    });
  });

  group('comparison with the last survey of this site', () {
    test('none without a previous survey', () {
      expect(ExecutiveSummary.build(_report(bleached: 20, healthy: 20)).comparison, isNull);
    });

    test('"up" only when the intervals separate', () {
      // Now 20/40 (35.2-64.8%), then 2/40 (1.4-16.5%).
      final comparison = ExecutiveSummary.build(
        _report(bleached: 20, healthy: 20),
        previous: _previous(bleached: 2, classified: 40),
      ).comparison!;

      expect(comparison.direction, ComparisonDirection.up);
      expect(comparison.text, 'Up from 5% at the last survey of this site (12 Sep 2026).');
    });

    test('"down" only when the intervals separate', () {
      final comparison = ExecutiveSummary.build(
        _report(bleached: 2, healthy: 38),
        previous: _previous(bleached: 20, classified: 40),
      ).comparison!;

      expect(comparison.direction, ComparisonDirection.down);
      expect(comparison.text, 'Down from 50% at the last survey of this site (12 Sep 2026).');
    });

    test('"similar" when the intervals overlap, even with different percentages', () {
      final comparison = ExecutiveSummary.build(
        _report(bleached: 6, healthy: 14),
        previous: _previous(bleached: 4, classified: 20),
      ).comparison!;

      expect(comparison.direction, ComparisonDirection.similar);
      expect(
        comparison.text,
        'Similar to the last survey of this site (12 Sep 2026): 20% then, 30% now; '
        'the difference is within the uncertainty.',
      );
    });

    test('not compared when this survey has too few classified colonies', () {
      final comparison = ExecutiveSummary.build(
        _report(bleached: 5),
        previous: _previous(bleached: 2, classified: 40),
      ).comparison!;

      expect(comparison.direction, ComparisonDirection.notComparable);
      expect(
        comparison.text,
        'Not compared with the last survey of this site (12 Sep 2026): '
        'too few classified colonies this time.',
      );
    });

    test('not compared when the last survey had too few classified colonies', () {
      final comparison = ExecutiveSummary.build(
        _report(bleached: 20, healthy: 20),
        previous: _previous(bleached: 0, classified: 3),
      ).comparison!;

      expect(comparison.direction, ComparisonDirection.notComparable);
      expect(comparison.text, endsWith('too few classified colonies then.'));
    });

    test('a previous survey from a different site, or a later one, is ignored', () {
      final otherSite = ExecutiveSummary.build(
        _report(bleached: 20, healthy: 20),
        previous: _previous(bleached: 2, classified: 40, site: 'Alegria'),
      );
      final later = ExecutiveSummary.build(
        _report(bleached: 20, healthy: 20, session: _session(startedAt: DateTime(2026, 8, 1))),
        previous: _previous(bleached: 2, classified: 40),
      );

      expect(otherSite.comparison, isNull);
      expect(later.comparison, isNull);
    });

    test('an unfinished survey is not compared, and gets no severity word', () {
      // 20/40 would be "up" and "severe" if the transect had been finished.
      final summary = ExecutiveSummary.build(
        _report(bleached: 20, healthy: 20, session: _session(ended: false)),
        previous: _previous(bleached: 2, classified: 40),
      );

      expect(summary.severity, isNull);
      expect(summary.comparison!.direction, ComparisonDirection.notComparable);
      expect(
        summary.comparison!.text,
        'Not compared with the last survey of this site (12 Sep 2026): '
        'this survey ended before the transect was finished.',
      );
    });
  });

  group('fixed text and survey details', () {
    test('two limitation lines', () {
      expect(ExecutiveSummary.build(_report()).limitations, hasLength(2));
    });

    test('details list date, site, observer and tape; entry position when recorded', () {
      final withFix = _report(
        session: _session(
          entryFix: GeoFix(
            lat: 10.25123,
            lon: 123.94567,
            accuracyM: 6,
            at: _oct5,
            source: GeoFixSource.gps,
          ),
        ),
      );

      expect(ExecutiveSummary.build(withFix).details, [
        ('Date', '5 Oct 2026, 08:30'),
        ('Site', 'Gilutongan'),
        ('Observer', 'J. Cruz'),
        ('Tape length', '50 m'),
        ('Entry position', '10.25123, 123.94567'),
      ]);
      expect(
        ExecutiveSummary.build(_report(session: _session(site: null, observer: null))).details,
        [
          ('Date', '5 Oct 2026, 08:30'),
          ('Site', 'Not recorded'),
          ('Observer', 'Not recorded'),
          ('Tape length', '50 m'),
        ],
      );
    });
  });
}
