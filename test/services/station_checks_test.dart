import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/services/station.dart';
import 'package:reefsight_mobile/services/station_checks.dart';
import 'package:reefsight_mobile/services/transect_placement.dart';
import 'package:reefsight_mobile/services/transect_session.dart';

// Issue #2: the pure rules behind the station and transect setup screens --
// TB 2019-04's random placement, the depth and tape flags, transect
// numbering and the status line. The screens only display these.

Station _station({double? depthMaxM, SurveyType type = SurveyType.photoTransect}) => Station(
      id: 1,
      code: 'ALG-S1',
      surveyType: type,
      frameMode: type == SurveyType.photoTransect ? FrameMode.physical : null,
      surveyedOn: DateTime(2026, 11, 15),
      depthMaxM: depthMaxM,
      createdAt: DateTime.utc(2026, 11, 14),
    );

TransectSession _transect({
  double tape = 50,
  double? depthStartM,
  double? depthEndM,
  DateTime? endedAt,
  AnalysisStatus? analysisStatus,
}) =>
    TransectSession(
      startedAt: DateTime.utc(2026, 11, 15, 1),
      endedAt: endedAt,
      tapeLengthMeters: tape,
      stationId: 1,
      transectNumber: 1,
      depthStartM: depthStartM,
      depthEndM: depthEndM,
      analysisStatus: analysisStatus,
    );

void main() {
  group('generateRandomPlacement', () {
    test('stays inside the 75 x 25 m station, rounded to 0.1 m', () {
      final rng = Random(7);
      for (var i = 0; i < 500; i++) {
        final p = generateRandomPlacement(rng);
        expect(p.alongM, inInclusiveRange(0, kStationAxisM));
        expect(p.swimoutM, inInclusiveRange(0, kStationSwimoutM));
        expect((p.alongM * 10).roundToDouble(), closeTo(p.alongM * 10, 1e-9));
        expect((p.swimoutM * 10).roundToDouble(), closeTo(p.swimoutM * 10, 1e-9));
      }
    });

    test('the same seed gives the same numbers', () {
      final a = generateRandomPlacement(Random(42));
      final b = generateRandomPlacement(Random(42));
      expect(a.alongM, b.alongM);
      expect(a.swimoutM, b.swimoutM);
    });
  });

  group('placement range errors', () {
    test('along the axis: 0-75 m', () {
      expect(alongError(''), isNull);
      expect(alongError('0'), isNull);
      expect(alongError('75'), isNull);
      expect(alongError('75.1'), isNotNull);
      expect(alongError('-1'), isNotNull);
      expect(alongError('abc'), isNotNull);
    });

    test('swim-out: 0-25 m', () {
      expect(swimoutError(''), isNull);
      expect(swimoutError('25'), isNull);
      expect(swimoutError('25.5'), isNotNull);
    });
  });

  group('TransectPlacement.applyTo', () {
    test('writes the station fields onto a session', () {
      const placement = TransectPlacement(
        stationId: 4,
        transectNumber: 2,
        captureSource: CaptureSource.legacyColony,
        depthStartM: 4.5,
        depthEndM: 5,
        randomAlongM: 12.3,
        randomSwimoutM: 8.1,
      );
      final session = placement.applyTo(
        TransectSession(startedAt: DateTime.utc(2026, 11, 15), tapeLengthMeters: 50),
      );
      expect(session.stationId, 4);
      expect(session.transectNumber, 2);
      expect(session.captureSource, CaptureSource.legacyColony);
      expect(session.depthStartM, 4.5);
      expect(session.depthEndM, 5);
      expect(session.randomAlongM, 12.3);
      expect(session.randomSwimoutM, 8.1);
    });
  });

  group('flags', () {
    test('depth: exactly 6 m is fine, deeper is flagged', () {
      expect(depthOverLimit(null), isFalse);
      expect(depthOverLimit(6), isFalse);
      expect(depthOverLimit(6.1), isTrue);
    });

    test('tape: only 50 m is standard', () {
      expect(tapeNotStandard(50), isFalse);
      expect(tapeNotStandard(50.5), isTrue);
      expect(tapeNotStandard(30), isTrue);
    });

    test('station: depth over 6 m and fewer than 3 transects', () {
      expect(stationFlags(_station(depthMaxM: 5), 3), isEmpty);
      expect(stationFlags(_station(depthMaxM: 7), 3), [kFlagStationTooDeep]);
      expect(stationFlags(_station(), 2), [kFlagFewTransects]);
      expect(stationFlags(_station(depthMaxM: 7), 0), [kFlagStationTooDeep, kFlagFewTransects]);
    });

    test('transect: either end over 6 m, and a non-50 m tape', () {
      expect(transectFlags(_transect(depthStartM: 5, depthEndM: 6)), isEmpty);
      expect(transectFlags(_transect(depthEndM: 6.5)), [kFlagTransectTooDeep]);
      expect(transectFlags(_transect(tape: 75)), ['Tape is 75 m, not 50 m']);
    });
  });

  group('transect numbers', () {
    test('defaults to the next number while it is free and at most 5', () {
      expect(defaultTransectNumber(const {}, 1), 1);
      expect(defaultTransectNumber(const {1, 2}, 3), 3);
    });

    test('falls back to the lowest free number past T5', () {
      // T2 deleted from T1-T5: next is 6, so offer T2.
      expect(defaultTransectNumber(const {1, 3, 4, 5}, 6), 2);
    });

    test('null when all five are used', () {
      expect(defaultTransectNumber(const {1, 2, 3, 4, 5}, 6), isNull);
    });
  });

  group('transectStatus', () {
    test('colony count: in progress until ended', () {
      expect(transectStatus(_transect(), SurveyType.colonyCount), 'In progress');
      expect(
        transectStatus(_transect(endedAt: DateTime.utc(2026, 11, 15, 2)), SurveyType.colonyCount),
        'Complete',
      );
    });

    test('photo and preliminary: awaiting capture, then the analysis status', () {
      expect(transectStatus(_transect(), SurveyType.photoTransect), 'Awaiting capture');
      expect(
        transectStatus(_transect(analysisStatus: AnalysisStatus.done), SurveyType.photoTransect),
        'Analysis done',
      );
    });
  });

  test('labels exist for every enum value', () {
    for (final v in SurveyType.values) {
      expect(surveyTypeLabel(v), isNotEmpty);
    }
    for (final v in FrameMode.values) {
      expect(frameModeLabel(v), isNotEmpty);
    }
    for (final v in ReefZone.values) {
      expect(reefZoneLabel(v), isNotEmpty);
    }
  });

  // Issue #3: the one filter the station summary (#8) uses, so colony
  // counts never reach a bulletin cover summary.
  test('only photo and preliminary transects report bulletin cover', () {
    expect(reportsBulletinCover(SurveyType.photoTransect), isTrue);
    expect(reportsBulletinCover(SurveyType.preliminaryVideo), isTrue);
    expect(reportsBulletinCover(SurveyType.colonyCount), isFalse);
  });

  test('the research-scope note names the bulletins it is outside of', () {
    expect(kResearchScopeNote, contains('TB 2019-04'));
    expect(kResearchScopeNote, contains('TB 2017-05'));
  });
}
