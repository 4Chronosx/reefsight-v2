import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/services/recount.dart';
import 'package:reefsight_mobile/services/recount_comparison.dart';

// Sub-plan 14 step 5: the app-vs-recount numbers behind Phase E's MAE /
// percentage-point comparison.

Recount _recount(int total, int bleached) => Recount(
      total: total,
      bleached: bleached,
      countedBy: 'B',
      at: DateTime.utc(2026, 10, 2),
      blinded: true,
    );

void main() {
  test('a known case: count error, percent error and prevalence difference', () {
    // App: 22 colonies, 20 classified, 5 bleached -> 25 %.
    // Recount: 20 colonies, 4 bleached -> 20 %.
    final c = RecountComparison(
      appTotal: 22,
      appBleached: 5,
      appClassified: 20,
      recount: _recount(20, 4),
    );
    expect(c.countError, 2);
    expect(c.absoluteCountError, 2);
    expect(c.countErrorPercent, closeTo(10.0, 1e-9));
    expect(c.appPrevalencePercent, closeTo(25.0, 1e-9));
    expect(c.recountPrevalencePercent, closeTo(20.0, 1e-9));
    expect(c.prevalenceDiffPp, closeTo(5.0, 1e-9));
  });

  test('an undercount is negative; the absolute error is not', () {
    final c = RecountComparison(
      appTotal: 8,
      appBleached: 0,
      appClassified: 8,
      recount: _recount(10, 1),
    );
    expect(c.countError, -2);
    expect(c.absoluteCountError, 2);
    expect(c.countErrorPercent, closeTo(-20.0, 1e-9));
    expect(c.prevalenceDiffPp, closeTo(-10.0, 1e-9));
  });

  test('a zero recount has no percent error or recount prevalence', () {
    final c = RecountComparison(
      appTotal: 3,
      appBleached: 1,
      appClassified: 2,
      recount: _recount(0, 0),
    );
    expect(c.countError, 3);
    expect(c.countErrorPercent, isNull);
    expect(c.recountPrevalencePercent, isNull);
    expect(c.prevalenceDiffPp, isNull);
  });

  test('no classified colonies means no app prevalence', () {
    final c = RecountComparison(
      appTotal: 4,
      appBleached: 0,
      appClassified: 0,
      recount: _recount(4, 1),
    );
    expect(c.appPrevalencePercent, isNull);
    expect(c.prevalenceDiffPp, isNull);
    expect(c.countError, 0);
    expect(c.countErrorPercent, 0);
  });
}
