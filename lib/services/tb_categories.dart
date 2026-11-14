import 'db_enum.dart';

/// Issue #6: the TB 2017-05 benthic categories a scoring point can carry,
/// and the major category each rolls up to in the CPCe sheet
/// (`docs/denr-tb-2019-04-alignment.md` §1b). A point's code comes either
/// from the model through `category_map` or from a reviewer (#10), who
/// enters a code, not a model class -- so whether a point counts toward the
/// total has to follow from the code alone: only TWB (tape, wand, shadow and
/// everything else that isn't benthos) is left out, as CPCe does.
///
/// The six major categories are the blueprint's (§4, `category_map`). The
/// sample CPCe sheet in TB 2017-05 lists macroalgae and Halimeda as majors of
/// their own; until CCEF settles it they are grouped under algae (AA).
enum MajorCategory with DbEnum {
  hc('HC'),
  dc('DC'),
  aa('AA'),
  ob('OB'),
  ab('AB'),
  twb('TWB');

  const MajorCategory(this.db);
  @override
  final String db;
}

class TbCategory {
  const TbCategory(this.code, this.name, this.major);

  final String code;
  final String name;
  final MajorCategory major;
}

const _hc = MajorCategory.hc;

/// Every code, by code. ACX, HCX and RCK aren't TB life-forms: ACX and HCX
/// hold hard coral whose growth form the model can't tell (its "acropora
/// alive", "other coral alive", "turbinaria"), and RCK is English et al.
/// (1997)'s rock, for "unknown hard substrate". All three are to be reviewed
/// with CCEF along with the mapping.
const kTbCategories = <String, TbCategory>{
  'ACB': TbCategory('ACB', 'Acropora branching', _hc),
  'ACD': TbCategory('ACD', 'Acropora digitate', _hc),
  'ACS': TbCategory('ACS', 'Acropora sub-massive', _hc),
  'ACT': TbCategory('ACT', 'Acropora tabulate', _hc),
  'ACX': TbCategory('ACX', 'Acropora, form unknown', _hc),
  'CB': TbCategory('CB', 'Coral branching', _hc),
  'CE': TbCategory('CE', 'Coral encrusting', _hc),
  'CF': TbCategory('CF', 'Coral foliose', _hc),
  'CM': TbCategory('CM', 'Coral massive', _hc),
  'CS': TbCategory('CS', 'Coral sub-massive', _hc),
  'CME': TbCategory('CME', 'Millepora', _hc),
  'CHL': TbCategory('CHL', 'Heliopora', _hc),
  'CMR': TbCategory('CMR', 'Mushroom coral', _hc),
  'HCX': TbCategory('HCX', 'Hard coral, form unknown', _hc),
  // Bleached coral is still live coral: it counts toward hard coral cover,
  // and is reported on its own as % bleached coral (CPCe sheet subcategory).
  'BLEC': TbCategory('BLEC', 'Bleached coral', _hc),
  'DC': TbCategory('DC', 'Dead coral', MajorCategory.dc),
  'DCA': TbCategory('DCA', 'Dead coral with algae', MajorCategory.dc),
  'AA': TbCategory('AA', 'Algal assemblage', MajorCategory.aa),
  'CA': TbCategory('CA', 'Coralline algae', MajorCategory.aa),
  'HA': TbCategory('HA', 'Halimeda', MajorCategory.aa),
  'MA': TbCategory('MA', 'Macroalgae', MajorCategory.aa),
  'SC': TbCategory('SC', 'Soft coral', MajorCategory.ob),
  'SP': TbCategory('SP', 'Sponge', MajorCategory.ob),
  'ZO': TbCategory('ZO', 'Zoanthids', MajorCategory.ob),
  'OT': TbCategory('OT', 'Other animals', MajorCategory.ob),
  // Counted (CPCe counts unknowns), grouped with other biota for now.
  'UNID': TbCategory('UNID', 'Unidentified', MajorCategory.ob),
  'R': TbCategory('R', 'Rubble', MajorCategory.ab),
  'S': TbCategory('S', 'Sand', MajorCategory.ab),
  'SI': TbCategory('SI', 'Silt', MajorCategory.ab),
  'RCK': TbCategory('RCK', 'Rock', MajorCategory.ab),
  'TWB': TbCategory('TWB', 'Tape, wand, shadow and other non-benthos', MajorCategory.twb),
};

bool isTbCode(String code) => kTbCategories.containsKey(code);

/// Throws [ArgumentError] for a code not in [kTbCategories] -- a typo must
/// not quietly count as something.
TbCategory tbCategory(String code) {
  final category = kTbCategories[code];
  if (category == null) throw ArgumentError.value(code, 'code', 'Not a TB 2017-05 category code');
  return category;
}

/// Left out of the point total, like tape and shadow in CPCe.
bool isExcludedCode(String code) => tbCategory(code).major == MajorCategory.twb;
