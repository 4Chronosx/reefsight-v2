import '../tracking/strack.dart';

/// Which tracks count as colonies (sub-plan 08 step 4): only tracks the
/// tracker has **confirmed** (`STrack.isActivated`), i.e. matched in at least
/// a second frame (tracks on a session's very first frame are confirmed
/// immediately, as in the reference).
///
/// BoT-SORT's `update` also returns unconfirmed tracks -- a detection seen
/// once, not yet matched again. Counting those overcounted dense reefs badly
/// on sub-plan 08's held-out CoralVOS videos (+49 against 141 colonies; +7
/// counting confirmed tracks only), because every one-frame false positive
/// became a "colony". Standard ByteTrack-family practice doesn't output
/// unconfirmed tracks at all. See `docs/botsort-tracking-accuracy-on-coralvos.md`
/// -- including that this rule was adopted after seeing the test-set result.
///
/// The tracker itself is unchanged (parity with the reference holds); this
/// only decides what is tallied and persisted. Unconfirmed tracks are still
/// drawn on the live overlay.
class ConfirmedSightings {
  /// First/last time each **confirmed** track was seen. The key set is the
  /// session's colony list: what the tally shows and finalize persists. A
  /// track's first-seen time is when it first appeared, even if it was
  /// confirmed a frame later.
  final Map<int, DateTime> firstSeenAt = {};
  final Map<int, DateTime> lastSeenAt = {};

  /// Unconfirmed tracks' first appearance, kept until they're confirmed or
  /// gone. An unconfirmed track is removed the first update it isn't matched,
  /// so an id missing from an update's tracks can never return unconfirmed:
  /// pruning on absence keeps this map as small as the current tracks.
  final Map<int, DateTime> _pending = {};

  /// Records one tracker update's [tracks] at [now].
  void observe(Iterable<STrack> tracks, DateTime now) {
    final present = <int>{};
    for (final track in tracks) {
      final id = track.trackId;
      present.add(id);
      if (track.isActivated) {
        firstSeenAt.putIfAbsent(id, () => _pending.remove(id) ?? now);
        lastSeenAt[id] = now;
      } else {
        _pending.putIfAbsent(id, () => now);
      }
    }
    _pending.removeWhere((id, _) => !present.contains(id));
  }

  /// Number of unconfirmed tracks currently pending. Diagnostic only.
  int get pendingCount => _pending.length;
}
