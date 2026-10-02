import 'dart:async';
import 'dart:io' show FileSystemException;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/services/device_checks.dart';
import 'package:reefsight_mobile/services/health_history_recorder.dart';
import 'package:reefsight_mobile/services/session_checkpointer.dart';
import 'package:reefsight_mobile/services/tracked_colony_record.dart';
import 'package:reefsight_mobile/services/transect_database.dart';
import 'package:reefsight_mobile/services/transect_session.dart';

// Sub-plan 11 steps 2-3: colony rows are checkpointed during Live, so a
// crashed or killed session keeps its colonies. Real SQLite via
// `sqflite_common_ffi` (see test/flutter_test_config.dart), not a mock --
// the "simulated crash" below is simply never calling finalize.

void main() {
  late TransectDatabase db;
  late int sessionId;
  late Map<int, TrackedColonyRecord> live;
  late DateTime clock;

  TrackedColonyRecord record(
    int trackId, {
    DateTime? lastSeenAt,
    double? sizePx,
    String? maskPath,
    List<HealthHistorySample> history = const [],
    String? photoPath,
    double? photoConfidence,
  }) {
    return TrackedColonyRecord(
      sessionId: sessionId,
      trackId: trackId,
      healthHistory: history,
      sizePx: sizePx,
      firstSeenAt: DateTime.utc(2026, 10, 1, 9),
      lastSeenAt: lastSeenAt ?? DateTime.utc(2026, 10, 1, 9),
      maskPath: maskPath,
      photoPath: photoPath,
      photoLabel: photoPath == null ? null : 'CORAL_BL',
      photoConfidence: photoConfidence,
    );
  }

  SessionCheckpointer checkpointer({
    void Function(Object)? onFailure,
    Future<void> Function()? beforeSnapshot,
  }) {
    return SessionCheckpointer(
      db: db,
      sessionId: sessionId,
      snapshot: () => live.values.toList(),
      beforeSnapshot: beforeSnapshot,
      now: () => clock,
      onFailure: onFailure,
    );
  }

  Future<Map<int, TrackedColonyRecord>> rowsByTrack() async {
    final rows = await db.colonyRowsForSession(sessionId);
    return {for (final row in rows) row.trackId: row};
  }

  setUp(() async {
    db = await TransectDatabase.openInMemoryForTest();
    sessionId = await db.insertSession(
      TransectSession(startedAt: DateTime.utc(2026, 10, 1, 9), tapeLengthMeters: 50),
    );
    live = {};
    clock = DateTime.utc(2026, 10, 1, 9, 5);
  });

  tearDown(() async {
    await db.close();
  });

  group('SessionCheckpointer.checkpoint', () {
    test('rows exist after a checkpoint with no finalize (simulated crash)',
        () async {
      live[1] = record(1, sizePx: 120);
      live[2] = record(2, sizePx: 340);

      await checkpointer().checkpoint();

      final rows = await rowsByTrack();
      expect(rows.keys, unorderedEquals([1, 2]));
      expect(rows[2]!.sizePx, 340);
      expect(rows[1]!.maskPath, isNull);

      final session = await db.sessionById(sessionId);
      expect(session!.endedAt, isNull);
      expect(session.lastCheckpointAt, clock);
    });

    test('only rewrites tracks that changed since the last checkpoint',
        () async {
      final cp = checkpointer();
      live[1] = record(1);
      live[2] = record(2);
      await cp.checkpoint();
      final before = await rowsByTrack();

      // `ConflictAlgorithm.replace` gives a rewritten row a new rowid, so an
      // unchanged id means the row wasn't touched.
      live[2] = record(2, lastSeenAt: DateTime.utc(2026, 10, 1, 9, 1));
      await cp.checkpoint();
      final after = await rowsByTrack();

      expect(after[1]!.id, before[1]!.id);
      expect(after[2]!.id, isNot(before[2]!.id));
      expect(after[2]!.lastSeenAt, DateTime.utc(2026, 10, 1, 9, 1));
    });

    test('a new health sample counts as a change', () async {
      final cp = checkpointer();
      live[1] = record(1);
      await cp.checkpoint();

      live[1] = record(1, history: [
        HealthHistorySample(
          label: 'CORAL',
          confidence: 0.9,
          at: DateTime.utc(2026, 10, 1, 9, 2),
        ),
      ]);
      await cp.checkpoint();

      final rows = await rowsByTrack();
      expect(rows[1]!.healthHistory, hasLength(1));
    });

    test('updates last_checkpoint_at even when no track changed', () async {
      final cp = checkpointer();
      live[1] = record(1);
      await cp.checkpoint();

      clock = DateTime.utc(2026, 10, 1, 9, 6);
      await cp.checkpoint();

      final session = await db.sessionById(sessionId);
      expect(session!.lastCheckpointAt, DateTime.utc(2026, 10, 1, 9, 6));
    });

    test('a failed write is counted and reported, not thrown', () async {
      final failures = <Object>[];
      final cp = checkpointer(onFailure: failures.add);
      live[1] = record(1);
      await db.close();

      await cp.checkpoint();

      expect(cp.failureCount, 1);
      expect(failures, hasLength(1));

      // Reopen so tearDown's close() has something to close.
      db = await TransectDatabase.openInMemoryForTest();
    });

    test('a failed checkpoint is retried on the next one', () async {
      var failNext = true;
      final cp = SessionCheckpointer(
        db: db,
        sessionId: sessionId,
        snapshot: () {
          if (failNext) {
            failNext = false;
            throw StateError('snapshot failed');
          }
          return live.values.toList();
        },
        now: () => clock,
      );
      live[1] = record(1);

      await cp.checkpoint();
      await cp.checkpoint();

      expect(cp.failureCount, 1);
      expect((await rowsByTrack()).keys, [1]);
    });
  });

  group('SessionCheckpointer.finalize', () {
    test('finalize after several checkpoints leaves one row per track, with '
        'masks', () async {
      final cp = checkpointer();
      live[1] = record(1);
      await cp.checkpoint();
      live[2] = record(2);
      await cp.checkpoint();
      live[1] = record(1, lastSeenAt: DateTime.utc(2026, 10, 1, 9, 3));
      await cp.checkpoint();

      await cp.finalize(() async {
        await db.upsertColonies([
          for (final r in live.values)
            record(r.trackId, maskPath: 'masks/${r.trackId}.png'),
        ]);
        await db.closeSession(sessionId, DateTime.utc(2026, 10, 1, 9, 10));
      });

      final rows = await db.colonyRowsForSession(sessionId);
      expect(rows, hasLength(2));
      expect(rows.map((r) => r.maskPath),
          unorderedEquals(['masks/1.png', 'masks/2.png']));
      expect((await db.sessionById(sessionId))!.endedAt, isNotNull);
    });

    test('a checkpoint requested during finalize does not run', () async {
      final cp = checkpointer();
      live[1] = record(1);
      final gate = Completer<void>();

      final finalizing = cp.finalize(() => gate.future);
      live[99] = record(99);
      await cp.checkpoint();
      gate.complete();
      await finalizing;

      expect((await rowsByTrack()).keys, isNot(contains(99)));
    });

    test('a checkpoint requested after finalize does not run', () async {
      final cp = checkpointer();
      await cp.finalize(() async {});

      live[1] = record(1);
      await cp.checkpoint();

      expect(await db.colonyRowsForSession(sessionId), isEmpty);
      expect(cp.failureCount, 0);
    });

    test('finalize errors propagate to the caller', () async {
      final cp = checkpointer();

      await expectLater(
        cp.finalize(() async => throw StateError('finalize failed')),
        throwsStateError,
      );
    });
  });

  group('SessionCheckpointer.handleLifecycle', () {
    test('paused triggers an immediate checkpoint and records an interruption',
        () async {
      final cp = checkpointer();
      live[1] = record(1);

      await cp.handleLifecycle(AppLifecycleState.paused);

      expect((await rowsByTrack()).keys, [1]);
      final session = await db.sessionById(sessionId);
      expect(session!.interruptionCount, 1);
      expect(session.firstInterruptedAt, clock);
      expect(session.lastInterruptedAt, clock);
    });

    test('inactive -> hidden -> paused is one interruption, not three',
        () async {
      final cp = checkpointer();

      await cp.handleLifecycle(AppLifecycleState.inactive);
      await cp.handleLifecycle(AppLifecycleState.hidden);
      await cp.handleLifecycle(AppLifecycleState.paused);

      expect((await db.sessionById(sessionId))!.interruptionCount, 1);
    });

    test('a second interruption after resuming is counted, with first and '
        'last times', () async {
      final cp = checkpointer();
      final first = clock;

      await cp.handleLifecycle(AppLifecycleState.inactive);
      await cp.handleLifecycle(AppLifecycleState.resumed);
      clock = DateTime.utc(2026, 10, 1, 9, 8);
      await cp.handleLifecycle(AppLifecycleState.inactive);

      final session = await db.sessionById(sessionId);
      expect(session!.interruptionCount, 2);
      expect(session.firstInterruptedAt, first);
      expect(session.lastInterruptedAt, DateTime.utc(2026, 10, 1, 9, 8));
    });

    test('resumed alone neither checkpoints nor counts', () async {
      final cp = checkpointer();
      live[1] = record(1);

      await cp.handleLifecycle(AppLifecycleState.resumed);

      expect(await db.colonyRowsForSession(sessionId), isEmpty);
      expect((await db.sessionById(sessionId))!.interruptionCount, isNull);
    });

    test('is a no-op once finalized', () async {
      final cp = checkpointer();
      await cp.finalize(() async {});
      live[1] = record(1);

      await cp.handleLifecycle(AppLifecycleState.paused);

      expect(await db.colonyRowsForSession(sessionId), isEmpty);
      expect((await db.sessionById(sessionId))!.interruptionCount, isNull);
    });
  });

  // Sub-plan 13 step 3: the thermal peak goes through the same write queue,
  // so it can't land on a DB that finalize has already closed.
  group('SessionCheckpointer.recordThermal', () {
    test('writes the peak and rise count to the session', () async {
      final cp = checkpointer();

      await cp.recordThermal(ThermalLevel.serious, 2);

      final stored = await db.sessionById(sessionId);
      expect(stored!.thermalPeak, ThermalLevel.serious);
      expect(stored.thermalRiseCount, 2);
    });

    test('a failed write is counted and reported, not thrown', () async {
      final failures = <Object>[];
      final cp = checkpointer(onFailure: failures.add);
      await db.close();

      await cp.recordThermal(ThermalLevel.critical, 1);

      expect(cp.failureCount, 1);
      expect(failures, hasLength(1));

      // Reopen so tearDown's close() has something to close.
      db = await TransectDatabase.openInMemoryForTest();
    });

    test('is a no-op once finalized', () async {
      final cp = checkpointer();
      await cp.finalize(() async {});

      await cp.recordThermal(ThermalLevel.critical, 1);

      expect((await db.sessionById(sessionId))!.thermalPeak, isNull);
    });
  });

  // Sub-plan 18 step 3: colony photos are written at each checkpoint, just
  // before the snapshot, so the rows can carry their paths.
  group('SessionCheckpointer photos', () {
    test('beforeSnapshot runs inside each checkpoint, before the snapshot', () async {
      final order = <String>[];
      final cp = SessionCheckpointer(
        db: db,
        sessionId: sessionId,
        snapshot: () {
          order.add('snapshot');
          return live.values.toList();
        },
        beforeSnapshot: () async => order.add('photos'),
        now: () => clock,
      );

      await cp.checkpoint();
      await cp.checkpoint();

      expect(order, ['photos', 'snapshot', 'photos', 'snapshot']);
    });

    test('a new or better photo counts as a change', () async {
      final cp = checkpointer();
      live[1] = record(1);
      await cp.checkpoint();

      live[1] = record(1, photoPath: 'colony_photos/session1_track1.jpg', photoConfidence: 0.8);
      await cp.checkpoint();
      expect((await rowsByTrack())[1]!.photoConfidence, 0.8);

      // Same path (the file was overwritten), better sample.
      live[1] = record(1, photoPath: 'colony_photos/session1_track1.jpg', photoConfidence: 0.9);
      await cp.checkpoint();
      expect((await rowsByTrack())[1]!.photoConfidence, 0.9);
    });

    test('a failed photo write is counted, and the rows are still written', () async {
      final failures = <Object>[];
      final cp = checkpointer(
        onFailure: failures.add,
        beforeSnapshot: () async => throw const FileSystemException('disk full'),
      );
      live[1] = record(1);

      await cp.checkpoint();

      expect(cp.failureCount, 1);
      expect(failures.single, isA<FileSystemException>());
      expect((await rowsByTrack()).keys, [1]);
    });
  });
}
