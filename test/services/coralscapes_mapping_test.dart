import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/services/coralscapes_mapping.dart';
import 'package:reefsight_mobile/services/tb_categories.dart';

// Issue #6: the draft CoralscapesV2 -> TB 2017-05 mapping (alignment doc §7,
// to be reviewed with CCEF). The fixture is the model's own `id2label`,
// copied verbatim, so a class name typed differently here fails loudly
// instead of leaving that class's points unmapped.

Map<String, String> _id2label() {
  final json = jsonDecode(File('test/fixtures/coralscapesv2_id2label.json').readAsStringSync()) as Map;
  return (json['id2label'] as Map).cast<String, String>();
}

void main() {
  final mapping = coralscapesMapping();
  final byClass = {for (final m in mapping) m.modelClass: m};

  test('maps every one of the model\'s 40 labels exactly once, and nothing else', () {
    final labels = _id2label().values.toSet();
    expect(labels, hasLength(40));
    expect(mapping, hasLength(40));
    expect(byClass.keys.toSet(), labels);
  });

  test('every row is for the CoralscapesV2 model', () {
    expect(mapping.every((m) => m.modelId == kCoralscapesModelId), isTrue);
  });

  test('every code is in the catalogue, under its catalogue major category', () {
    for (final m in mapping) {
      expect(isTbCode(m.categoryCode), isTrue, reason: m.modelClass);
      expect(m.majorCategory, tbCategory(m.categoryCode).major.db, reason: m.modelClass);
    }
  });

  test('excluded exactly when the code is TWB', () {
    for (final m in mapping) {
      expect(m.excluded, m.categoryCode == 'TWB', reason: m.modelClass);
    }
    expect(
      mapping.where((m) => m.excluded).map((m) => m.modelClass).toSet(),
      {
        'unlabeled', 'transect line', 'transect tools', 'human', 'fish', 'trash', 'dark', 'background',
        'dead clam', //
      },
    );
  });

  test('every bleached class is BLEC, every dead coral class is DC', () {
    for (final m in mapping) {
      if (m.modelClass.endsWith(' bleached')) expect(m.categoryCode, 'BLEC', reason: m.modelClass);
      if (m.modelClass.endsWith(' dead') && m.modelClass != 'dead clam') {
        expect(m.categoryCode, 'DC', reason: m.modelClass);
      }
    }
  });

  test('the draft choices for the gaps (D2, D4)', () {
    expect(byClass['table acropora alive']!.categoryCode, 'ACT');
    expect(byClass['acropora alive']!.categoryCode, 'ACX');
    expect(byClass['other coral alive']!.categoryCode, 'HCX');
    expect(byClass['turbinaria']!.categoryCode, 'HCX');
    expect(byClass['millepora']!.categoryCode, 'CME');
    expect(byClass['algae covered substrate']!.categoryCode, 'DCA');
    expect(byClass['unknown hard substrate']!.categoryCode, 'RCK');
    expect(byClass['other animal']!.categoryCode, 'OT');
    expect(byClass['seagrass']!.categoryCode, 'OT');
    expect(byClass['crown of thorn']!.categoryCode, 'OT');
  });
}
