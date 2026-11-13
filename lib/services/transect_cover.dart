/// Issue #1 (schema v11): cached % cover for one transect and one category
/// (a TB code or a major category), recomputed whenever the transect's
/// points change. The station summary is computed from these rows, never
/// stored (`docs/reefsight-v2-blueprint.md` §4 and §6). Computing them is #6;
/// this is only the row.
class TransectCoverRow {
  TransectCoverRow({
    required this.sessionId,
    required this.categoryCode,
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
        'points': points,
        'total_points': totalPoints,
        'percent': percent,
        'uses_expert': usesExpert ? 1 : 0,
      };

  static TransectCoverRow fromMap(Map<String, Object?> map) => TransectCoverRow(
        sessionId: map['session_id'] as int,
        categoryCode: map['category_code'] as String,
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
      other.points == points &&
      other.totalPoints == totalPoints &&
      other.percent == percent &&
      other.usesExpert == usesExpert;

  @override
  int get hashCode => Object.hash(sessionId, categoryCode, points, totalPoints, percent, usesExpert);

  @override
  String toString() => 'TransectCoverRow(session $sessionId, $categoryCode: '
      '$points/$totalPoints = $percent%${usesExpert ? ', expert' : ''})';
}
