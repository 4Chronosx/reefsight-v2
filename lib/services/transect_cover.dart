import 'db_enum.dart';

/// Whether a [TransectCoverRow] is for a TB 2017-05 code or a major category.
/// Both levels share some spellings (DC is dead coral and the dead-coral
/// group, AA algal assemblage and the algae group), so the level is part of
/// the row's key (schema v12, #6).
enum CoverLevel with DbEnum {
  code('code'),
  major('major');

  const CoverLevel(this.db);
  @override
  final String db;
}

/// Issue #1 (schema v11, level added in v12 by #6): cached % cover for one
/// transect and one category -- a TB code or a major category, per [level]
/// -- dropped whenever the transect's points change and rebuilt by
/// `TransectDatabase.refreshTransectCover`. The station summary is computed
/// from these rows, never stored (`docs/reefsight-v2-blueprint.md` §4, §6).
class TransectCoverRow {
  TransectCoverRow({
    required this.sessionId,
    required this.categoryCode,
    this.level = CoverLevel.code,
    required this.points,
    required this.totalPoints,
    required this.percent,
    this.usesExpert = false,
  }) {
    if (totalPoints < 0 || points < 0 || points > totalPoints) {
      throw ArgumentError('Need 0 <= points ($points) <= totalPoints ($totalPoints)');
    }
  }

  final int sessionId;
  final String categoryCode;
  final CoverLevel level;

  /// Points in this category.
  final int points;

  /// Points counted after exclusions (tape, shadow, ...).
  final int totalPoints;

  /// points ÷ totalPoints × 100.
  final double percent;

  /// Computed with expert corrections applied (#10).
  final bool usesExpert;

  Map<String, Object?> toMap() => {
        'session_id': sessionId,
        'category_code': categoryCode,
        'level': level.db,
        'points': points,
        'total_points': totalPoints,
        'percent': percent,
        'uses_expert': usesExpert ? 1 : 0,
      };

  static TransectCoverRow fromMap(Map<String, Object?> map) => TransectCoverRow(
        sessionId: map['session_id'] as int,
        categoryCode: map['category_code'] as String,
        level: enumFromDb(CoverLevel.values, map['level']) ?? CoverLevel.code,
        points: map['points'] as int,
        totalPoints: map['total_points'] as int,
        percent: (map['percent'] as num).toDouble(),
        usesExpert: map['uses_expert'] == 1,
      );

  @override
  bool operator ==(Object other) =>
      other is TransectCoverRow &&
      other.sessionId == sessionId &&
      other.categoryCode == categoryCode &&
      other.level == level &&
      other.points == points &&
      other.totalPoints == totalPoints &&
      other.percent == percent &&
      other.usesExpert == usesExpert;

  @override
  int get hashCode => Object.hash(sessionId, categoryCode, level, points, totalPoints, percent, usesExpert);

  @override
  String toString() => 'TransectCoverRow(session $sessionId, ${level.db} $categoryCode: '
      '$points/$totalPoints = $percent%${usesExpert ? ', expert' : ''})';
}
