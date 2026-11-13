/// Issue #1 (schema v11): one row of the lookup from a segmenter's class to
/// a TB 2017-05 category, versioned by model so a new model brings its own
/// mapping (`docs/reefsight-v2-blueprint.md` §4, `category_map`). The table
/// ships empty here: seeding the CoralscapesV2 mapping is #6, which waits on
/// CCEF's review of the draft in `docs/denr-tb-2019-04-alignment.md` §7.
///
/// Codes stay strings, not enums, until that mapping is settled.
class CategoryMapping {
  const CategoryMapping({
    required this.modelId,
    required this.modelClass,
    required this.categoryCode,
    required this.majorCategory,
    this.excluded = false,
  });

  /// e.g. `coralscapesv2-segformer-b5`.
  final String modelId;

  /// The model's class name, e.g. "table acropora alive".
  final String modelClass;

  /// TB 2017-05 code, e.g. ACT, CB, BLEC, DC, S.
  final String categoryCode;

  /// HC · DC · AA · OB · AB · TWB.
  final String majorCategory;

  /// Not counted toward cover (tape, shadow, fish, divers), as in CPCe.
  final bool excluded;

  Map<String, Object?> toMap() => {
        'model_id': modelId,
        'model_class': modelClass,
        'category_code': categoryCode,
        'major_category': majorCategory,
        'excluded': excluded ? 1 : 0,
      };

  static CategoryMapping fromMap(Map<String, Object?> map) => CategoryMapping(
        modelId: map['model_id'] as String,
        modelClass: map['model_class'] as String,
        categoryCode: map['category_code'] as String,
        majorCategory: map['major_category'] as String,
        excluded: map['excluded'] == 1,
      );

  @override
  bool operator ==(Object other) =>
      other is CategoryMapping &&
      other.modelId == modelId &&
      other.modelClass == modelClass &&
      other.categoryCode == categoryCode &&
      other.majorCategory == majorCategory &&
      other.excluded == excluded;

  @override
  int get hashCode => Object.hash(modelId, modelClass, categoryCode, majorCategory, excluded);

  @override
  String toString() => 'CategoryMapping($modelId: $modelClass -> $categoryCode/$majorCategory'
      '${excluded ? ', excluded' : ''})';
}
