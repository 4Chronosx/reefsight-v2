import 'db_enum.dart';

/// Issue #1 (schema v11): one of a frame's random scoring points, as in CPCe
/// (TB 2017-05: 10 per frame). The model's label and a reviewer's correction
/// are kept side by side -- corrections are evidence for validation (#16)
/// and retraining, so they never overwrite the model's answer
/// (`docs/reefsight-v2-blueprint.md` §4, `frame_points`).
class FramePoint {
  FramePoint({
    this.id,
    required this.frameId,
    required this.pointIndex,
    required this.xNorm,
    required this.yNorm,
    this.modelClass,
    this.modelConfidence,
    this.categoryCode,
    this.expertCategoryCode,
    this.expertName,
    this.reviewedAt,
  }) {
    if (pointIndex < 0) throw ArgumentError.value(pointIndex, 'pointIndex', 'Must be >= 0');
    if (xNorm < 0 || xNorm > 1) throw ArgumentError.value(xNorm, 'xNorm', 'Must be in 0..1');
    if (yNorm < 0 || yNorm > 1) throw ArgumentError.value(yNorm, 'yNorm', 'Must be in 0..1');
  }

  /// `null` before the row has been inserted.
  final int? id;
  final int frameId;

  /// 0-based; unique per frame.
  final int pointIndex;

  /// Position inside the frame's 1 × 1 m area, 0-1 on each axis.
  final double xNorm;
  final double yNorm;

  /// The segmenter's raw class at the point, e.g. "branching bleached".
  final String? modelClass;
  final double? modelConfidence;

  /// [modelClass] mapped to a TB 2017-05 code through `category_map`.
  final String? categoryCode;

  /// A reviewer's correction (#10), with who made it and when.
  final String? expertCategoryCode;
  final String? expertName;
  final DateTime? reviewedAt;

  /// The code that counts toward cover: the reviewer's, when there is one.
  String? get effectiveCategoryCode => expertCategoryCode ?? categoryCode;

  /// Column names match `transect_database.dart`'s `frame_points` table.
  Map<String, Object?> toMap() => {
        'id': id,
        'frame_id': frameId,
        'point_index': pointIndex,
        'x_norm': xNorm,
        'y_norm': yNorm,
        'model_class': modelClass,
        'model_confidence': modelConfidence,
        'category_code': categoryCode,
        'expert_category_code': expertCategoryCode,
        'expert_name': expertName,
        'reviewed_at': reviewedAt?.toIso8601String(),
      };

  static FramePoint fromMap(Map<String, Object?> map) => FramePoint(
        id: map['id'] as int?,
        frameId: map['frame_id'] as int,
        pointIndex: map['point_index'] as int,
        xNorm: (map['x_norm'] as num).toDouble(),
        yNorm: (map['y_norm'] as num).toDouble(),
        modelClass: map['model_class'] as String?,
        modelConfidence: (map['model_confidence'] as num?)?.toDouble(),
        categoryCode: map['category_code'] as String?,
        expertCategoryCode: map['expert_category_code'] as String?,
        expertName: map['expert_name'] as String?,
        reviewedAt: dateTimeFromDb(map['reviewed_at']),
      );
}
