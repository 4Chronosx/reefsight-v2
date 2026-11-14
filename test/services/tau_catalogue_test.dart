import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/services/tau_catalogue.dart';

// Issue #10: TB 2019-04 Table 3, the Taxonomic Amalgamation Units an expert
// tags for generic diversity (Licuanan et al. 2017b).

void main() {
  test('holds Table 3 as printed: 59 units, each keyed by its own code', () {
    expect(kTaus, hasLength(59));
    for (final entry in kTaus.entries) {
      expect(entry.value.code, entry.key);
      expect(entry.value.name.trim(), isNotEmpty, reason: entry.key);
    }
  });

  test('codes and names are taken from the bulletin', () {
    expect(tau('PORM').name, 'Porites massive');
    expect(tau('ACB').name, 'Acropora branching');
    expect(tau('HEL').name, 'Heliopora');
    expect(tau('DIP').name, 'Diploastrea heliopora');
    // Table 3 prints Fungia under CMR, the life-form code for mushroom coral.
    expect(tau('CMR').name, 'Fungia');
    expect(tau('CM').name, 'Other massive corals');
  });

  test('the priority units (TB 2019-04 when there is no TAU expertise) are listed first, in order', () {
    expect(kPriorityTauCodes, ['PORB', 'PORE', 'PORM', 'ACB', 'ACC', 'ACD', 'ACH', 'ACT', 'ACR', 'HEL']);
    for (final code in kPriorityTauCodes) {
      expect(isTauCode(code), isTrue, reason: code);
    }
    final ordered = tausForPicker().map((t) => t.code).toList();
    expect(ordered.take(kPriorityTauCodes.length), kPriorityTauCodes);
    expect(ordered.toSet(), kTaus.keys.toSet());
    expect(ordered, hasLength(kTaus.length));
  });

  test('the rest of the picker is alphabetical by name', () {
    final rest = tausForPicker().skip(kPriorityTauCodes.length).map((t) => t.name).toList();
    expect(rest, [...rest]..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase())));
  });

  test('an unknown code throws, so a typo never counts as a genus group', () {
    expect(() => tau('PORX'), throwsArgumentError);
    expect(() => tau('porm'), throwsArgumentError);
    expect(isTauCode('BLEC'), isFalse);
  });
}
