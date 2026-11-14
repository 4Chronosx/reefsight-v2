import 'genus_tag.dart';
import 'transect_session.dart';

/// Issue #10: a station's generic diversity -- the number of distinct genus
/// groups (TB 2019-04 TAUs, `tau_catalogue.dart`) that an expert tagged,
/// reported **per transect** and **across the station** (alignment doc §10).
/// The station figure is the one graded, on TB 2019-04 Table 2 (Licuanan et
/// al. 2019), until CCEF confirms how they count it.
///
/// Diversity comes from tags only, so it doesn't wait for the cover analysis:
/// a transect with tags counts whether or not its points are all labeled. A
/// station with no tags has no figure and no grade -- "not tagged" is not
/// "category D". Reasoning in `../docs/expert-review-and-tau-diversity.md`.

/// TB 2019-04 Table 2's diversity categories. The bulletin gives letters
/// only (no words, unlike the hard coral scale).
enum DiversityGrade {
  a('A'),
  b('B'),
  c('C'),
  d('D');

  const DiversityGrade(this.letter);
  final String letter;
}

/// A >26 · B >22–26 · C >18–22 · D 0–18 TAUs. Counts are whole numbers, so
/// the bands are A ≥ 27, B 23–26, C 19–22, D 0–18.
DiversityGrade gradeDiversity(int tauCount) {
  if (tauCount < 0) throw ArgumentError.value(tauCount, 'tauCount', 'Must be >= 0');
  if (tauCount > 26) return DiversityGrade.a;
  if (tauCount > 22) return DiversityGrade.b;
  if (tauCount > 18) return DiversityGrade.c;
  return DiversityGrade.d;
}

/// The scale as the summary prints it.
const kDiversityScale = 'A >26 · B >22–26 · C >18–22 · D 0–18 TAUs (TB 2019-04 Table 2)';

/// Where a station has no genus tags yet, so no diversity.
const kNoDiversityYet = 'No genus tags yet: diversity appears once an expert tags genus groups (TAUs).';

String noTagsFlag(int? transectNumber) => 'T${transectNumber ?? '?'} has no genus tags';

/// One transect's distinct TAUs, sorted by code.
class TransectDiversity {
  const TransectDiversity(this.transect, this.taus);

  final TransectSession transect;
  final List<String> taus;

  int get count => taus.length;
}

class StationDiversity {
  const StationDiversity._(this.transects, this.stationTaus, this.flags);

  /// [transects] in the order given (by number, as `transectsForStation`
  /// returns them); tags of any other transect are ignored.
  factory StationDiversity.compute(List<TransectSession> transects, List<GenusTag> tags) {
    final bySession = <int, Set<String>>{for (final t in transects) t.id!: <String>{}};
    for (final tag in tags) {
      bySession[tag.sessionId]?.add(tag.tauCode);
    }
    final per = [for (final t in transects) TransectDiversity(t, bySession[t.id!]!.toList()..sort())];
    final union = {for (final t in per) ...t.taus}.toList()..sort();
    final flags = union.isEmpty
        ? const [kNoDiversityYet]
        : [for (final t in per) if (t.count == 0) noTagsFlag(t.transect.transectNumber)];
    return StationDiversity._(per, union, flags);
  }

  final List<TransectDiversity> transects;

  /// Distinct TAUs across all the transects, sorted by code.
  final List<String> stationTaus;
  final List<String> flags;

  bool get hasTags => stationTaus.isNotEmpty;

  /// `null` with no tags at all.
  int? get stationCount => hasTags ? stationTaus.length : null;
  DiversityGrade? get grade => hasTags ? gradeDiversity(stationTaus.length) : null;

  String? get gradeLine => hasTags ? '$stationCount TAUs: category ${grade!.letter}' : null;
}
