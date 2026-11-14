import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/services/tb_categories.dart';

// Issue #6: the TB 2017-05 code catalogue -- every code a point can carry,
// model-mapped or expert-corrected, and the major category it rolls up to.

void main() {
  test('every code rolls up to one of the six major categories', () {
    for (final category in kTbCategories.values) {
      expect(MajorCategory.values, contains(category.major), reason: category.code);
      expect(kTbCategories[category.code], same(category), reason: 'keyed by its own code');
    }
  });

  test('the bulletin hard-coral life-forms and bleached coral are hard coral', () {
    for (final code in ['ACB', 'ACD', 'ACS', 'ACT', 'CB', 'CE', 'CF', 'CM', 'CS', 'CME', 'CHL', 'CMR', 'BLEC']) {
      expect(tbCategory(code).major, MajorCategory.hc, reason: code);
    }
  });

  test('the ReefSight form-unknown codes are hard coral too', () {
    expect(tbCategory('ACX').major, MajorCategory.hc);
    expect(tbCategory('HCX').major, MajorCategory.hc);
  });

  test('major categories for the other groups (D3, D4)', () {
    expect(tbCategory('DC').major, MajorCategory.dc);
    expect(tbCategory('DCA').major, MajorCategory.dc);
    for (final code in ['AA', 'CA', 'HA', 'MA']) {
      expect(tbCategory(code).major, MajorCategory.aa, reason: code);
    }
    for (final code in ['SC', 'SP', 'ZO', 'OT', 'UNID']) {
      expect(tbCategory(code).major, MajorCategory.ob, reason: code);
    }
    for (final code in ['R', 'S', 'SI', 'RCK']) {
      expect(tbCategory(code).major, MajorCategory.ab, reason: code);
    }
  });

  test('only tape, wand and shadow (TWB) is excluded from the point total', () {
    expect(isExcludedCode('TWB'), isTrue);
    final counted = kTbCategories.keys.where((c) => c != 'TWB');
    expect(counted.where(isExcludedCode), isEmpty);
  });

  test('an unknown code throws rather than counting as something', () {
    expect(() => tbCategory('XYZ'), throwsArgumentError);
    expect(() => isExcludedCode('cb'), throwsArgumentError);
    expect(isTbCode('CB'), isTrue);
    expect(isTbCode('cb'), isFalse);
  });

  test('major categories keep their stored spelling', () {
    expect(MajorCategory.values.map((m) => m.db), ['HC', 'DC', 'AA', 'OB', 'AB', 'TWB']);
  });
}
