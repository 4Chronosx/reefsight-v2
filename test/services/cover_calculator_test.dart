import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/services/cover_calculator.dart';
import 'package:reefsight_mobile/services/frame_point.dart';
import 'package:reefsight_mobile/services/transect_cover.dart';
import 'package:reefsight_mobile/services/transect_frame.dart';

// Issue #6: % cover per transect, CPCe-style -- points in a category ÷
// points counted × 100, with tape, wand and shadow (TWB) left out of the
// total (TB 2017-05; blueprint §6). Worked by hand below.

const _session = 7;

TransectFrame _frame(int id, double meter, {bool excluded = false}) => TransectFrame(
      id: id,
      sessionId: _session,
      meterMark: meter,
      imagePath: 'm$meter.jpg',
      source: FrameSource.inApp,
      excluded: excluded,
    );

/// Points for [frameId] with these codes, in order.
List<FramePoint> _points(int frameId, List<String?> codes, {Map<int, String> expert = const {}}) => [
      for (var i = 0; i < codes.length; i++)
        FramePoint(
          frameId: frameId,
          pointIndex: i,
          xNorm: 0.5,
          yNorm: 0.5,
          categoryCode: codes[i],
          expertCategoryCode: expert[i],
          expertName: expert[i] == null ? null : 'J. Reviewer',
        ),
    ];

List<String> _n(int n, String code) => List.filled(n, code);

TransectCoverRow _row(CoverComputation c, CoverLevel level, String code) =>
    c.rows.singleWhere((r) => r.level == level && r.categoryCode == code);

void main() {
  // Frame 1: 4 TWB, 3 CB, 2 BLEC, 1 S.  Frame 2: 5 CB, 3 DC, 2 DCA.
  // Frame 3: 6 S, 2 ACT, 2 SP.  30 points, 26 counted.
  final frames = [_frame(1, 0), _frame(2, 1), _frame(3, 2)];
  final points = [
    ..._points(1, [..._n(4, 'TWB'), ..._n(3, 'CB'), ..._n(2, 'BLEC'), 'S']),
    ..._points(2, [..._n(5, 'CB'), ..._n(3, 'DC'), ..._n(2, 'DCA')]),
    ..._points(3, [..._n(6, 'S'), ..._n(2, 'ACT'), ..._n(2, 'SP')]),
  ];

  group('a fully labeled transect', () {
    final c = computeCover(_session, frames, points);

    test('counts every point but TWB', () {
      expect(c.isComplete, isTrue);
      expect(c.framesScored, 3);
      expect(c.allPoints, 30);
      expect(c.excludedPoints, 4);
      expect(c.unlabeledPoints, 0);
      expect(c.countedPoints, 26);
      expect(c.rows.every((r) => r.totalPoints == 26 && r.sessionId == _session), isTrue);
    });

    test('% per TB code', () {
      expect(_row(c, CoverLevel.code, 'CB').points, 8);
      expect(_row(c, CoverLevel.code, 'CB').percent, closeTo(8 / 26 * 100, 1e-9));
      expect(_row(c, CoverLevel.code, 'ACT').percent, closeTo(2 / 26 * 100, 1e-9));
      expect(_row(c, CoverLevel.code, 'DC').points, 3);
      expect(_row(c, CoverLevel.code, 'DCA').points, 2);
      expect(_row(c, CoverLevel.code, 'S').points, 7);
      expect(_row(c, CoverLevel.code, 'SP').points, 2);
      expect(c.rows.where((r) => r.categoryCode == 'TWB'), isEmpty);
    });

    test('bleached coral is reported on its own and counts toward hard coral', () {
      expect(_row(c, CoverLevel.code, 'BLEC').points, 2);
      expect(_row(c, CoverLevel.code, 'BLEC').percent, closeTo(2 / 26 * 100, 1e-9));
      expect(_row(c, CoverLevel.major, 'HC').points, 12);
      expect(_row(c, CoverLevel.major, 'HC').percent, closeTo(12 / 26 * 100, 1e-9));
    });

    test('% per major category, DC and AA apart from the codes of the same name', () {
      expect(_row(c, CoverLevel.major, 'DC').points, 5);
      expect(_row(c, CoverLevel.major, 'AB').points, 7);
      expect(_row(c, CoverLevel.major, 'OB').points, 2);
      expect(_row(c, CoverLevel.major, 'AA').points, 0);
      expect(c.rows.where((r) => r.level == CoverLevel.major).map((r) => r.categoryCode).toSet(),
          {'HC', 'DC', 'AA', 'OB', 'AB'});
    });

    test('the majors add up to 100 %', () {
      final total = c.rows.where((r) => r.level == CoverLevel.major).fold(0.0, (s, r) => s + r.percent);
      expect(total, closeTo(100, 1e-9));
    });

    test('no expert corrections were used', () {
      expect(c.rows.any((r) => r.usesExpert), isFalse);
    });
  });

  test('BLEC is reported as 0 % when nothing is bleached', () {
    final c = computeCover(_session, [_frame(1, 0)], _points(1, _n(10, 'CB')));
    expect(_row(c, CoverLevel.code, 'BLEC').points, 0);
    expect(_row(c, CoverLevel.code, 'BLEC').percent, 0);
    expect(_row(c, CoverLevel.major, 'HC').percent, 100);
  });

  test('an excluded frame\'s points are left out entirely', () {
    final c = computeCover(
      _session,
      [_frame(1, 0), _frame(2, 1, excluded: true)],
      [..._points(1, _n(10, 'S')), ..._points(2, _n(10, 'CB'))],
    );
    expect(c.framesScored, 1);
    expect(c.allPoints, 10);
    expect(_row(c, CoverLevel.code, 'S').percent, 100);
    expect(c.rows.where((r) => r.categoryCode == 'CB'), isEmpty);
  });

  test('an expert correction replaces the model\'s label, and is recorded', () {
    final c = computeCover(
      _session,
      [_frame(1, 0)],
      _points(1, _n(10, 'S'), expert: {0: 'CB', 1: 'TWB'}),
    );
    expect(c.countedPoints, 9);
    expect(_row(c, CoverLevel.code, 'CB').points, 1);
    expect(_row(c, CoverLevel.code, 'S').points, 8);
    expect(c.rows.every((r) => r.usesExpert), isTrue);
  });

  test('a point not labeled yet makes the transect incomplete, with no rows', () {
    final c = computeCover(_session, [_frame(1, 0)], _points(1, [..._n(9, 'S'), null]));
    expect(c.isComplete, isFalse);
    expect(c.unlabeledPoints, 1);
    expect(c.rows, isEmpty);
  });

  test('a transect with every point excluded has nothing to report', () {
    final c = computeCover(_session, [_frame(1, 0)], _points(1, _n(10, 'TWB')));
    expect(c.isComplete, isFalse);
    expect(c.countedPoints, 0);
    expect(c.rows, isEmpty);
  });

  test('a transect with no points has nothing to report', () {
    final c = computeCover(_session, frames, const []);
    expect(c.isComplete, isFalse);
    expect(c.framesScored, 0);
    expect(c.rows, isEmpty);
  });

  test('an unknown code throws rather than being counted', () {
    expect(() => computeCover(_session, [_frame(1, 0)], _points(1, ['XYZ'])), throwsArgumentError);
  });

  test('a point on a frame of another transect is a caller bug', () {
    expect(
      () => computeCover(_session, [_frame(1, 0)], _points(99, ['S'])),
      throwsArgumentError,
    );
  });
}
