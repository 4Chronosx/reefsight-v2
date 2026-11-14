import 'category_mapping.dart';
import 'tb_categories.dart';

/// Issue #6: the CoralscapesV2 SegFormer
/// (`EPFL-ECEO/segformer-b5-finetuned-coralscapesv2-1024-1024`) class to TB
/// 2017-05 category mapping that seeds `category_map`.
///
/// **Draft, to be reviewed with CCEF** (alignment doc §7). The class names
/// are the model's own `id2label` (ids 0-39), copied verbatim from its
/// `config.json` at commit c61183ec on 2026-11-14; the test pins them
/// against `test/fixtures/coralscapesv2_id2label.json`. Changing a row here
/// is safe, **with a bump of `TransectDatabase._schemaVersion`**: the
/// upgrade re-seeds through `TransectDatabase.seedCategoryMap`, which
/// re-maps the stored points of this model's transects and drops their
/// cached cover. Without the bump, existing installs keep the old rows.
const kCoralscapesModelId = 'coralscapesv2-segformer-b5';

/// Model class -> TB code, in id order.
const _coralscapesCodes = <String, String>{
  'unlabeled': 'TWB',
  'seagrass': 'OT',
  'trash': 'TWB',
  'other coral dead': 'DC',
  'other coral bleached': 'BLEC',
  'sand': 'S',
  'other coral alive': 'HCX',
  'human': 'TWB',
  'transect tools': 'TWB',
  'fish': 'TWB',
  'algae covered substrate': 'DCA',
  'other animal': 'OT',
  'unknown hard substrate': 'RCK',
  'background': 'TWB',
  'dark': 'TWB',
  'transect line': 'TWB',
  'massive/meandering bleached': 'BLEC',
  'massive/meandering alive': 'CM',
  'rubble': 'R',
  'branching bleached': 'BLEC',
  'branching dead': 'DC',
  'millepora': 'CME',
  'branching alive': 'CB',
  'massive/meandering dead': 'DC',
  'clam': 'OT',
  'acropora alive': 'ACX',
  'sea cucumber': 'OT',
  'turbinaria': 'HCX',
  'table acropora alive': 'ACT',
  'sponge': 'SP',
  'anemone': 'OT',
  'pocillopora alive': 'CB',
  'table acropora dead': 'DC',
  'meandering bleached': 'BLEC',
  'stylophora alive': 'CB',
  'sea urchin': 'OT',
  'meandering alive': 'CM',
  'meandering dead': 'DC',
  'crown of thorn': 'OT',
  // Excluded as in the draft (§7). Open for CCEF: CPCe might score an empty
  // shell as other biota or abiotic instead.
  'dead clam': 'TWB',
};

/// The seed rows. The major category and the excluded flag follow from the
/// code (`tb_categories.dart`), so the two can't disagree.
List<CategoryMapping> coralscapesMapping() => [
      for (final MapEntry(key: modelClass, value: code) in _coralscapesCodes.entries)
        CategoryMapping(
          modelId: kCoralscapesModelId,
          modelClass: modelClass,
          categoryCode: code,
          majorCategory: tbCategory(code).major.db,
          excluded: isExcludedCode(code),
        ),
    ];
