import 'dart:async';

import 'package:flutter/widgets.dart';

import 'device_checks.dart';
import 'tracked_colony_record.dart';
import 'transect_database.dart';

/// Builds the current colony records from the Live screen's in-memory maps,
/// with `maskPath: null` -- masks are written only at finalize. Must be
/// synchronous: that makes the snapshot atomic with respect to the screen's
/// own map updates (`_handleTracks`/`_handleHealth`), without the
/// checkpointer touching the tracker or classification path at all.
typedef ColonySnapshot = List<TrackedColonyRecord> Function();

/// Periodically writes a Live session's colony rows to SQLite, so a crash,
/// an iOS kill, or a long background stay doesn't lose the survey --
/// sub-plan 11 steps 2-3.
///
/// Before this, `_finalizeSession` (End Transect) was the only place colony
/// rows were written: a session that never reached it kept its session row
/// and zero colonies.
///
/// Every write -- checkpoints, interruption records, and the screen's
/// finalize -- runs through one `Future` queue, so they never overlap:
/// [finalize] waits for an in-flight checkpoint, and once it's been
/// requested, no checkpoint starts again.
class SessionCheckpointer {
  SessionCheckpointer({
    required TransectDatabase db,
    required int sessionId,
    required ColonySnapshot snapshot,
    this.interval = const Duration(seconds: 10),
    DateTime Function()? now,
    this.onFailure,
  })  : _db = db,
        _sessionId = sessionId,
        _snapshot = snapshot,
        _now = now ?? (() => DateTime.now().toUtc());

  final TransectDatabase _db;
  final int _sessionId;
  final ColonySnapshot _snapshot;
  final DateTime Function() _now;

  /// How often [start]'s timer checkpoints. 10 s bounds what a crash can
  /// lose to the last 10 s of changes, at the cost of one small transaction
  /// (changed rows only) every 10 s.
  final Duration interval;

  /// Called after a failed write, once [failureCount] is incremented -- the
  /// Live screen redraws its diagnostics overlay ("checkpoint failed ×N").
  final void Function(Object error)? onFailure;

  /// Failed checkpoint or interruption writes. Never swallowed silently:
  /// logged, counted here, and reported through [onFailure].
  int get failureCount => _failureCount;
  int _failureCount = 0;

  bool get isClosed => _closed;
  bool _closed = false;

  Timer? _timer;
  Future<void> _queue = Future.value();
  Future<void>? _finalizing;
  bool _foreground = true;

  /// What each track looked like at its last successful write. A track is
  /// rewritten only when this changes: new track, new health sample, new
  /// size, new label, or a later `lastSeenAt`.
  final Map<int, (DateTime, int, double?, String?)> _written = {};

  static (DateTime, int, double?, String?) _fingerprint(
    TrackedColonyRecord record,
  ) =>
      (
        record.lastSeenAt,
        record.healthHistory.length,
        record.sizePx,
        record.healthLabel,
      );

  /// Starts checkpointing every [interval]. A no-op if already started or
  /// already finalized.
  void start() {
    if (_closed || _timer != null) return;
    _timer = Timer.periodic(interval, (_) => checkpoint());
  }

  /// Writes every track that changed since the last checkpoint, then stamps
  /// the session's `last_checkpoint_at`. Completes normally even when the
  /// write fails (see [failureCount]); does nothing once [finalize] has been
  /// requested.
  Future<void> checkpoint() {
    if (_closed) return Future.value();
    return _enqueue(_runCheckpoint);
  }

  Future<void> _runCheckpoint() async {
    // Re-checked here, not only in `checkpoint()`: a checkpoint queued
    // before finalize was requested, but not yet started, must not run
    // after it either.
    if (_closed) return;
    try {
      final changed = [
        for (final record in _snapshot())
          if (_written[record.trackId] != _fingerprint(record)) record,
      ];
      await _db.upsertColonies(changed);
      await _db.recordCheckpoint(_sessionId, _now());
      for (final record in changed) {
        _written[record.trackId] = _fingerprint(record);
      }
    } catch (error) {
      _fail('checkpoint', error);
    }
  }

  /// Sub-plan 11 step 3. On leaving the foreground (`inactive`, `hidden` or
  /// `paused`: a phone call, the notification centre, an app switch, a
  /// low-power warning), records one interruption and checkpoints
  /// immediately -- it may be the last chance before iOS kills the app.
  /// Only the transition out of `resumed` counts, so the usual
  /// `inactive -> hidden -> paused` sequence is one interruption, not three.
  Future<void> handleLifecycle(AppLifecycleState state) {
    final wasForeground = _foreground;
    _foreground = state == AppLifecycleState.resumed;
    if (_closed || !wasForeground || _foreground) return Future.value();
    if (state == AppLifecycleState.detached) return Future.value();

    final at = _now();
    final interruption = _enqueue(() async {
      if (_closed) return;
      try {
        await _db.recordInterruption(_sessionId, at);
      } catch (error) {
        _fail('interruption record', error);
      }
    });
    return Future.wait([interruption, checkpoint()]);
  }

  /// Sub-plan 13 step 3: stores the thermal peak and rise count the moment
  /// they change, so a crash mid-transect keeps them. Queued like every
  /// other write, so it can't land after finalize has closed the DB.
  Future<void> recordThermal(ThermalLevel peak, int rises) {
    if (_closed) return Future.value();
    return _enqueue(() async {
      if (_closed) return;
      try {
        await _db.recordThermal(_sessionId, peak, rises);
      } catch (error) {
        _fail('thermal record', error);
      }
    });
  }

  /// Stops all further checkpoints, waits for an in-flight one, then runs
  /// [body] -- the Live screen's own finalize (mask writes, final upserts,
  /// `closeSession`, closing the DB). Errors from [body] propagate.
  /// Idempotent: a second call returns the first call's future.
  Future<void> finalize(Future<void> Function() body) {
    return _finalizing ??= () {
      _closed = true;
      _timer?.cancel();
      _timer = null;
      return _enqueue(body);
    }();
  }

  /// Chains [job] after everything already queued. The queue itself never
  /// holds an error, so one failed job can't block the ones after it; the
  /// returned future still carries [job]'s own error to its caller.
  Future<void> _enqueue(Future<void> Function() job) {
    final result = _queue.then((_) => job());
    _queue = result.catchError((Object _) {});
    return result;
  }

  void _fail(String what, Object error) {
    _failureCount++;
    debugPrint('ReefSight: session $what failed (×$_failureCount): $error');
    onFailure?.call(error);
  }
}
