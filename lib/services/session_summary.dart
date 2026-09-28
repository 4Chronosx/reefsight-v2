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
  });

  final TransectSession session;
  final int colonyCount;
  final int bleachedCount;
}
