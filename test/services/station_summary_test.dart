import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/services/cover_calculator.dart';
import 'package:reefsight_mobile/services/frame_point.dart';
import 'package:reefsight_mobile/services/station.dart';
import 'package:reefsight_mobile/services/station_checks.dart';
import 'package:reefsight_mobile/services/station_summary.dart';
import 'package:reefsight_mobile/services/tb_categories.dart';
import 'package:reefsight_mobile/services/transect_cover.dart';
import 'package:reefsight_mobile/services/transect_frame.dart';
import 'package:reefsight_mobile/services/transect_session.dart';

// Issue #8: the station summary's statistics and grade (blueprint §6;
// sub-plan 27). Each transect's cover goes through the real `computeCover`,
// so these numbers are what the database would cache.

Station _station({SurveyType type = SurveyType.photoTransect, double? depthMaxM}) => Station(
      id: 1,
      code: 'ALG-S1',
      surveyType: type,
      frameMode: type == SurveyType.photoTransect ? FrameMode.physical : null,
      surveyedOn: DateTime(2026, 11, 15),
      depthMaxM: depthMaxM,
      createdAt: DateTime.utc(2026, 11, 15),
    );

TransectSession _session(int n, {double tape = 50, double? depthEndM}) => TransectSession(
      id: n,
      startedAt: DateTime.utc(2026, 11, 15, n),
      tapeLengthMeters: tape,
      stationId: 1,
      transectNumber: n,
      depthEndM: depthEndM,
    );

/// Transect [n] with [counts] points per TB code, 10 to a frame. A `null`
/// key is an unlabeled point.
StationTransectCover _transect(
  int n,
  Map<String?, int> counts, {
  double tape = 50,
  double? depthEndM,
}) {
  final codes = [for (final e in counts.entries) ...List.filled(e.value, e.key)];
  final frames = <TransectFrame>[];
  final points = <FramePoint>[];
  for (var i = 0; i < codes.length; i++) {
    final frameId = n * 1000 + i ~/ 10;
    if (i % 10 == 0) {
      frames.add(TransectFrame(
        id: frameId,
        sessionId: n,
        meterMark: (i ~/ 10).toDouble(),
        imagePath: 'f$frameId.jpg',
        source: FrameSource.inApp,
      ));
    }
    points.add(FramePoint(
      id: n * 1000 + i,
      frameId: frameId,
      pointIndex: i % 10,
      xNorm: 0.5,
      yNorm: 0.5,
      categoryCode: codes[i],
    ));
  }
  return StationTransectCover(
    transect: _session(n, tape: tape, depthEndM: depthEndM),
    cover: computeCover(n, frames, points),
  );
}

CategoryStat _stat(StationCoverSummary s, CoverLevel level, String code) =>
    [...s.majors, ...s.codes].singleWhere((c) => c.level == level && c.code == code);

void main() {
  group('gradeHardCoral', () {
    test('follows TB 2019-04: A >44, B >33-44, C >22-33, D 0-22', () {
      expect(gradeHardCoral(100), CoverGrade.a);
      expect(gradeHardCoral(44.1), CoverGrade.a);
      expect(gradeHardCoral(44.0), CoverGrade.b);
      expect(gradeHardCoral(33.1), CoverGrade.b);
      expect(gradeHardCoral(33.0), CoverGrade.c);
      expect(gradeHardCoral(22.1), CoverGrade.c);
      expect(gradeHardCoral(22.0), CoverGrade.d);
      expect(gradeHardCoral(0), CoverGrade.d);
    });

    test('grades the mean as shown, to one decimal', () {
      // 44.04 shows as "44.0%", so it must not be an A.
      expect(gradeHardCoral(44.04), CoverGrade.b);
      expect(gradeHardCoral(44.06), CoverGrade.a);
      expect(gradeHardCoral(22.049), CoverGrade.d);
    });

    test('has the bulletin words', () {
      expect(CoverGrade.values.map((g) => '${g.letter} ${g.word}'),
          ['A Excellent', 'B Good', 'C Fair', 'D Poor']);
    });
  });

  group('StationCoverSummary', () {
    test('averages transect percentages: mean, sample SD and SE', () {
      final s = StationCoverSummary.compute(_station(), [
        _transect(1, {'CB': 30, 'S': 70}),
        _transect(2, {'CB': 40, 'S': 60}),
        _transect(3, {'CB': 50, 'S': 50}),
      ]);
      final hc = s.hardCoral!;
      expect(hc.percents, [30, 40, 50]);
      expect(hc.mean, closeTo(40, 1e-9));
      expect(hc.sd, closeTo(10, 1e-9));
      expect(hc.se, closeTo(10 / sqrt(3), 1e-9));
      expect(s.grade, CoverGrade.b);
      expect(s.flags, isEmpty);
    });

    test('does not pool points: transects with different totals weigh the same', () {
      // Pooled, this would be 30/110 = 27.3 %; averaged it is (20 + 100) / 2.
      final s = StationCoverSummary.compute(_station(), [
        _transect(1, {'CB': 20, 'S': 80}),
        _transect(2, {'CB': 10}),
      ]);
      expect(s.hardCoral!.mean, closeTo(60, 1e-9));
    });

    test('a code missing from a transect counts as 0 % there', () {
      final s = StationCoverSummary.compute(_station(), [
        _transect(1, {'CB': 10, 'SP': 10, 'S': 80}),
        _transect(2, {'CB': 10, 'S': 90}),
      ]);
      final sp = _stat(s, CoverLevel.code, 'SP');
      expect(sp.percents, [10, 0]);
      expect(sp.mean, closeTo(5, 1e-9));
    });

    test('BLEC is always reported and counts toward hard coral', () {
      final s = StationCoverSummary.compute(_station(), [
        _transect(1, {'CB': 20, 'BLEC': 10, 'S': 70}),
        _transect(2, {'CB': 30, 'S': 70}),
        _transect(3, {'CB': 25, 'BLEC': 5, 'S': 70}),
      ]);
      expect(s.bleached!.percents, [10, 0, 5]);
      expect(s.hardCoral!.percents, [30, 30, 30]);
      expect(s.hardCoral!.sd, 0);
    });

    test('rows come majors first, then codes in catalogue order', () {
      final s = StationCoverSummary.compute(_station(), [
        _transect(1, {'S': 40, 'CB': 30, 'DC': 10, 'ACB': 20}),
      ]);
      expect(s.majors.map((m) => m.code), ['HC', 'DC', 'AA', 'OB', 'AB']);
      expect(s.codes.map((c) => c.code), ['ACB', 'CB', 'BLEC', 'DC', 'S']);
      expect(s.codes.first.name, 'Acropora branching');
    });

    test('tape and shadow points are left out of the total', () {
      final s = StationCoverSummary.compute(_station(), [
        _transect(1, {'CB': 45, 'S': 45, 'TWB': 10}),
      ]);
      expect(s.hardCoral!.percents.single, closeTo(50, 1e-9));
      expect(s.analyzed.single.cover.excludedPoints, 10);
    });

    test('one transect: a mean, no SD or SE, and the minimum flag', () {
      final s = StationCoverSummary.compute(_station(), [
        _transect(1, {'CB': 50, 'S': 50}),
      ]);
      expect(s.hardCoral!.mean, 50);
      expect(s.hardCoral!.sd, isNull);
      expect(s.hardCoral!.se, isNull);
      expect(s.flags, containsAll([kFlagFewTransects, kFlagNoSpread]));
    });

    test('five transects: no count flag', () {
      final s = StationCoverSummary.compute(_station(), [
        for (var n = 1; n <= 5; n++) _transect(n, {'CB': 10 * n, 'S': 100 - 10 * n}),
      ]);
      expect(s.n, 5);
      expect(s.flags, isEmpty);
    });

    test('an unscored transect is left out of n and named in the flags', () {
      final s = StationCoverSummary.compute(_station(), [
        _transect(1, {'CB': 30, 'S': 70}),
        _transect(2, {'CB': 3, null: 7}),
        _transect(3, {'CB': 50, 'S': 50}),
        _transect(4, {'CB': 40, 'S': 60}),
      ]);
      expect(s.n, 3);
      expect(s.analyzed.map((t) => t.transect.transectNumber), [1, 3, 4]);
      expect(s.notAnalyzed.map((t) => t.transectNumber), [2]);
      expect(s.hardCoral!.mean, closeTo(40, 1e-9));
      expect(s.flags, ['T2 not analyzed: left out of the summary']);
    });

    test('below 3 analyzed transects is flagged even with 3 set up', () {
      final s = StationCoverSummary.compute(_station(), [
        _transect(1, {'CB': 30, 'S': 70}),
        _transect(2, {null: 10}),
        _transect(3, {'CB': 50, 'S': 50}),
      ]);
      expect(s.n, 2);
      expect(s.flags, contains(kFlagFewTransects));
    });

    test('orders transects by number', () {
      final s = StationCoverSummary.compute(_station(), [
        _transect(3, {'CB': 50, 'S': 50}),
        _transect(1, {'CB': 30, 'S': 70}),
      ]);
      expect(s.analyzed.map((t) => t.transect.transectNumber), [1, 3]);
      expect(s.hardCoral!.percents, [30, 50]);
    });

    test('no analyzed transects: no stats and no grade', () {
      final s = StationCoverSummary.compute(_station(), [_transect(1, {null: 10})]);
      expect(s.n, 0);
      expect(s.hardCoral, isNull);
      expect(s.bleached, isNull);
      expect(s.grade, isNull);
      expect(s.majors, isEmpty);
    });

    test('flags a deep station, a deep transect and a short tape', () {
      final s = StationCoverSummary.compute(_station(depthMaxM: 7), [
        _transect(1, {'CB': 30, 'S': 70}, depthEndM: 6.5),
        _transect(2, {'CB': 30, 'S': 70}, tape: 30),
        _transect(3, {'CB': 30, 'S': 70}),
      ]);
      expect(s.flags, [
        kFlagStationTooDeep,
        'T1: $kFlagTransectTooDeep',
        'T2: Tape is 30 m, not 50 m',
      ]);
    });

    test('a photo-transect station is official, a preliminary one indicative', () {
      final rows = [_transect(1, {'CB': 50, 'S': 50})];
      final photo = StationCoverSummary.compute(_station(), rows);
      final prelim = StationCoverSummary.compute(_station(type: SurveyType.preliminaryVideo), rows);
      expect(photo.isPreliminary, isFalse);
      expect(prelim.isPreliminary, isTrue);
      expect(prelim.grade, CoverGrade.a);
      expect(prelim.gradeLine, 'A (Excellent), indicative');
      expect(photo.gradeLine, 'A (Excellent)');
    });

    test('a colony-count station has no cover summary', () {
      expect(
        () => StationCoverSummary.compute(_station(type: SurveyType.colonyCount), const []),
        throwsArgumentError,
      );
    });

    // TB 2017-05 Figure 6: every code of the code file is listed, zeros
    // included, under its major, alphabetically.
    test('catalogueStats lists every counted code, zero-filled, by major then name', () {
      final s = StationCoverSummary.compute(_station(), [
        _transect(1, {'CB': 30, 'S': 70}),
        _transect(2, {'CB': 40, 'S': 60}),
      ]);
      final all = s.catalogueStats();
      expect(all.map((c) => c.code).toSet(), {
        for (final c in kTbCategories.values)
          if (c.major != MajorCategory.twb) c.code,
      });
      final hc = all.takeWhile((c) => tbCategory(c.code).major == MajorCategory.hc).map((c) => c.name).toList();
      expect(hc, [...hc]..sort());
      expect(hc.first, 'Acropora branching');
      expect(all.singleWhere((c) => c.code == 'CMR').percents, [0, 0]);
      expect(all.singleWhere((c) => c.code == 'CB').percents, [30, 40]);
    });

    test('excludedStat is TWB over all points, as the CPCe sheet has it', () {
      final s = StationCoverSummary.compute(_station(), [
        _transect(1, {'CB': 45, 'S': 45, 'TWB': 10}),
        _transect(2, {'CB': 50, 'S': 50}),
      ]);
      final twb = s.excludedStat!;
      expect(twb.code, 'TWB');
      expect(twb.percents, [closeTo(10, 1e-9), 0]);
      expect(twb.mean, closeTo(5, 1e-9));
    });

    test('no analyzed transects: no catalogue and no TWB row', () {
      final s = StationCoverSummary.compute(_station(), const []);
      expect(s.catalogueStats(), isEmpty);
      expect(s.excludedStat, isNull);
    });

    test('says whether any transect used expert corrections', () {
      final s = StationCoverSummary.compute(_station(), [_transect(1, {'CB': 50, 'S': 50})]);
      expect(s.analyzed.single.usesExpert, isFalse);
    });
  });
}
