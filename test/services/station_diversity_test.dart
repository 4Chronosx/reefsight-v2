import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/services/genus_tag.dart';
import 'package:reefsight_mobile/services/station_diversity.dart';
import 'package:reefsight_mobile/services/transect_session.dart';

// Issue #10: generic diversity -- distinct TAUs per transect and across the
// station, the station figure graded on TB 2019-04 Table 2.

TransectSession _t(int id, int number) => TransectSession(
      id: id,
      startedAt: DateTime.utc(2026, 11, 15, 2),
      tapeLengthMeters: 50,
      stationId: 1,
      transectNumber: number,
    );

GenusTag _tag(int sessionId, String code, {int? frameId}) =>
    GenusTag(stationId: 1, sessionId: sessionId, frameId: frameId, tauCode: code);

void main() {
  group('gradeDiversity (D5: A >26 · B >22–26 · C >18–22 · D 0–18)', () {
    test('band edges', () {
      expect(gradeDiversity(0), DiversityGrade.d);
      expect(gradeDiversity(18), DiversityGrade.d);
      expect(gradeDiversity(19), DiversityGrade.c);
      expect(gradeDiversity(22), DiversityGrade.c);
      expect(gradeDiversity(23), DiversityGrade.b);
      expect(gradeDiversity(26), DiversityGrade.b);
      expect(gradeDiversity(27), DiversityGrade.a);
      expect(gradeDiversity(59), DiversityGrade.a);
    });

    test('a negative count is a bug, not a grade', () {
      expect(() => gradeDiversity(-1), throwsArgumentError);
    });
  });

  group('StationDiversity.compute', () {
    final transects = [_t(10, 1), _t(11, 2), _t(12, 3)];

    test('per transect: distinct TAUs, frame and tape tags together, sorted', () {
      final d = StationDiversity.compute(transects, [
        _tag(10, 'PORM', frameId: 1),
        _tag(10, 'PORM', frameId: 2),
        _tag(10, 'ACB', frameId: 2),
        _tag(10, 'HEL'),
        _tag(11, 'PORM', frameId: 3),
      ]);
      expect(d.transects.map((t) => t.transect.transectNumber), [1, 2, 3]);
      expect(d.transects[0].taus, ['ACB', 'HEL', 'PORM']);
      expect(d.transects[0].count, 3);
      expect(d.transects[1].taus, ['PORM']);
      expect(d.transects[2].count, 0);
    });

    test('per station: the union across transects, not their sum, graded', () {
      final codes = List.generate(25, (i) => 'X$i');
      final d = StationDiversity.compute(transects, [
        for (final c in codes.take(20)) _tag(10, c),
        for (final c in codes.skip(5)) _tag(11, c),
      ]);
      expect(d.transects[0].count, 20);
      expect(d.transects[1].count, 20);
      expect(d.stationCount, 25);
      expect(d.grade, DiversityGrade.b);
    });

    test('no tags at all: no count, no grade (not D), and the reason', () {
      final d = StationDiversity.compute(transects, const []);
      expect(d.hasTags, isFalse);
      expect(d.stationCount, isNull);
      expect(d.grade, isNull);
      expect(d.flags, [kNoDiversityYet]);
    });

    test('transects without tags are flagged by number', () {
      final d = StationDiversity.compute(transects, [_tag(11, 'PORM')]);
      expect(d.stationCount, 1);
      expect(d.flags, ['T1 has no genus tags', 'T3 has no genus tags']);
    });

    test('tags of a transect not passed in are ignored', () {
      final d = StationDiversity.compute([_t(10, 1)], [_tag(10, 'PORM'), _tag(99, 'ACB')]);
      expect(d.stationCount, 1);
      expect(d.stationTaus, ['PORM']);
    });

    test('gradeLine', () {
      final d = StationDiversity.compute([_t(10, 1)], [_tag(10, 'PORM')]);
      expect(d.gradeLine, '1 TAUs: category D');
      expect(StationDiversity.compute([_t(10, 1)], const []).gradeLine, isNull);
    });
  });
}
