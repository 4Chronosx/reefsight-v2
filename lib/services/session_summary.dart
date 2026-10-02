import 'transect_session.dart';

/// One row for the Surveys (history) tab: a [session] plus the two counts
/// that tab needs to render without re-querying `tracked_colonies` per row
/// (`TransectDatabase.listSessions()`, sub-plan 6 step 2 -- the only
/// data-layer addition in that sub-plan, read-only, no schema change).
class SessionSummary {
  const SessionSummary({
    required this.session,
    required this.colonyCount,
    required this.bleachedCount,
    required this.classifiedCount,
  });

  final TransectSession session;
  final int colonyCount;
  final int bleachedCount;

  /// Colonies with a confident health label -- the app's prevalence
  /// denominator (sub-plan 10), needed by the recount comparisons export
  /// (sub-plan 14).
  final int classifiedCount;
}
