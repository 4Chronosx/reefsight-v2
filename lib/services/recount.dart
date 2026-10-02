/// Sub-plan 14 (`mobile/sub-plans/14-blinded-recount-entry.md`): the
/// manual expert recount of a transect that the Spec's Phase E
/// "post-transect metric validation" compares the app's numbers against.
/// Entered once on Summary and read-only after that, like the exit fix
/// (sub-plan 12) -- `TransectDatabase.recordRecount`.
library;

class Recount {
  Recount({
    required this.total,
    required this.bleached,
    required this.countedBy,
    required DateTime at,
    required this.blinded,
  }) : at = at.toUtc();

  /// Colonies counted along the tape, and how many of them were bleached --
  /// the two numbers on ml-03's recount sheet. Sizes are left out (decision
  /// 2): a diver's size estimates are too rough to score against.
  final int total;
  final int bleached;

  /// Free text: who counted. Deciding who *should* count is the Spec's open
  /// item; the app only records the field team's choice (decision 4).
  final String countedBy;

  /// When the recount was entered, always UTC.
  final DateTime at;

  /// Entered before the app's results were ever shown on this phone
  /// (decision 3). Decided in SQL at write time, never by the caller.
  final bool blinded;

  /// `null` unless every column is present -- a partial row is treated as no
  /// recount, not guessed at.
  static Recount? fromColumns(Map<String, Object?> map) {
    final total = map['recount_total'];
    final bleached = map['recount_bleached'];
    final countedBy = map['recount_by'];
    final at = map['recount_at'];
    final blinded = map['recount_blinded'];
    if (total is! int ||
        bleached is! int ||
        countedBy is! String ||
        at is! String ||
        blinded is! int) {
      return null;
    }
    return Recount(
      total: total,
      bleached: bleached,
      countedBy: countedBy,
      at: DateTime.parse(at),
      blinded: blinded == 1,
    );
  }

  /// The five `recount_*` columns -- `TransectSession.toMap` writes these.
  static Map<String, Object?> toColumns(Recount? recount) => {
        'recount_total': recount?.total,
        'recount_bleached': recount?.bleached,
        'recount_by': recount?.countedBy,
        'recount_at': recount?.at.toIso8601String(),
        'recount_blinded': recount == null ? null : (recount.blinded ? 1 : 0),
      };
}
