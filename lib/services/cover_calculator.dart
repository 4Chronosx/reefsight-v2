import 'frame_point.dart';
import 'tb_categories.dart';
import 'transect_cover.dart';
import 'transect_frame.dart';

/// Issue #6: one transect's % cover, as CPCe works it out (TB 2017-05;
/// blueprint §6): points in a category ÷ points counted × 100, where the
/// points counted are every point on a frame that isn't excluded, less those
/// whose code is TWB (tape, wand, shadow, fish, divers ...). A reviewer's
/// code (#10) replaces the model's.
///
/// Rows come at two levels ([CoverLevel]): every TB code present, plus BLEC
/// always (% bleached coral is a headline number even at 0); and every
/// counted major category (HC, DC, AA, OB, AB) always, so 0 % hard coral is
/// a row and not a missing one. BLEC counts toward HC.
class CoverComputation {
  const CoverComputation({
    required this.rows,
    required this.framesScored,
    required this.allPoints,
    required this.excludedPoints,
    required this.unlabeledPoints,
  });

  /// Empty unless [isComplete].
  final List<TransectCoverRow> rows;

  /// Frames not excluded that have points.
  final int framesScored;

  /// Points on those frames (CPCe's "total points").
  final int allPoints;

  /// Of [allPoints], the TWB ones.
  final int excludedPoints;

  /// Of [allPoints], those with no label yet (not analyzed, or the model's
  /// class isn't in the mapping).
  final int unlabeledPoints;

  /// CPCe's "points excluding tape, shadow and wand".
  int get countedPoints => allPoints - excludedPoints - unlabeledPoints;

  /// Every point labeled and at least one counted. Until then there is no
  /// cover to report -- a partial percentage would look like a real one.
  bool get isComplete => unlabeledPoints == 0 && countedPoints > 0;
}

/// [points] must all be on [frames] (the transect's own); throws
/// [ArgumentError] for one that isn't, or for a code not in the TB
/// catalogue.
CoverComputation computeCover(int sessionId, List<TransectFrame> frames, List<FramePoint> points) {
  final scorable = {for (final f in frames) f.id: !f.excluded};
  final framesWithPoints = <int>{};
  final byCode = <String, int>{};
  var all = 0, excluded = 0, unlabeled = 0;
  var usesExpert = false;

  for (final point in points) {
    final keep = scorable[point.frameId];
    if (keep == null) throw ArgumentError('Point ${point.id} is on frame ${point.frameId}, not this transect');
    if (!keep) continue;
    framesWithPoints.add(point.frameId);
    all++;
    final code = point.effectiveCategoryCode;
    if (code == null) {
      unlabeled++;
      continue;
    }
    if (isExcludedCode(code)) {
      excluded++;
    } else {
      byCode[code] = (byCode[code] ?? 0) + 1;
    }
    if (point.expertCategoryCode != null) usesExpert = true;
  }

  final total = all - excluded - unlabeled;
  final complete = unlabeled == 0 && total > 0;
  final rows = <TransectCoverRow>[];
  if (complete) {
    TransectCoverRow row(CoverLevel level, String code, int n) => TransectCoverRow(
          sessionId: sessionId,
          categoryCode: code,
          level: level,
          points: n,
          totalPoints: total,
          percent: n / total * 100,
          usesExpert: usesExpert,
        );
    byCode.putIfAbsent('BLEC', () => 0);
    for (final code in byCode.keys.toList()..sort()) {
      rows.add(row(CoverLevel.code, code, byCode[code]!));
    }
    for (final major in MajorCategory.values.where((m) => m != MajorCategory.twb)) {
      final n = byCode.entries.where((e) => tbCategory(e.key).major == major).fold(0, (s, e) => s + e.value);
      rows.add(row(CoverLevel.major, major.db, n));
    }
  }
  return CoverComputation(
    rows: rows,
    framesScored: framesWithPoints.length,
    allPoints: all,
    excludedPoints: excluded,
    unlabeledPoints: unlabeled,
  );
}
