import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:reefsight_mobile/services/health_history_recorder.dart';
import 'package:sqflite/sqflite.dart' show openDatabase;
import 'package:reefsight_mobile/services/tracked_colony_record.dart';
import 'package:reefsight_mobile/services/transect_database.dart';
import 'package:reefsight_mobile/services/transect_session.dart';

// Sub-plan 4 (storage-and-metrics), task 5 + step 2 ("Model integration --
// confirm the stored schema actually round-trips everything sub-plan 3
// produces"). Opens a real in-memory SQLite DB via
// `sqflite_common_ffi` (see test/flutter_test_config.dart) -- not a mock --
// so this test is the actual round-trip check the sub-plan calls for, not
// just a shape assertion.

void main() {
  group('TransectDatabase', () {
    late TransectDatabase db;

    setUp(() async {
      db = await TransectDatabase.openInMemoryForTest();
    });

    tearDown(() async {
      await db.close();
    });

    test('insertSession assigns an id and the session round-trips', () async {
      final session = TransectSession(
        startedAt: DateTime.utc(2026, 1, 1, 8),
        tapeLengthMeters: 10,
      );

      final id = await db.insertSession(session);
      final stored = await db.sessionById(id);

      expect(stored, isNotNull);
      expect(stored!.id, id);
      expect(stored.startedAt, session.startedAt);
      expect(stored.endedAt, isNull);
      expect(stored.tapeLengthMeters, 10);
      expect(stored.beltWidthMeters, 1.0);
    });

    test('insertSession round-trips siteName/observerName', () async {
      final id = await db.insertSession(
        TransectSession(
          startedAt: DateTime.utc(2026, 1, 1),
          tapeLengthMeters: 10,
          siteName: 'Marigondon Reef',
          observerName: 'C. Zaballa',
        ),
      );

      final stored = await db.sessionById(id);

      expect(stored!.siteName, 'Marigondon Reef');
      expect(stored.observerName, 'C. Zaballa');
    });

    test('closeSession sets endedAt', () async {
      final id = await db.insertSession(
        TransectSession(
          startedAt: DateTime.utc(2026, 1, 1),
          tapeLengthMeters: 10,
        ),
      );
      final endedAt = DateTime.utc(2026, 1, 1, 0, 30);

      await db.closeSession(id, endedAt);
      final stored = await db.sessionById(id);

      expect(stored!.endedAt, endedAt);
    });

    test('upsertColony round-trips every field, including health history '
        'and null species', () async {
      final sessionId = await db.insertSession(
        TransectSession(
          startedAt: DateTime.utc(2026, 1, 1),
          tapeLengthMeters: 10,
        ),
      );

      final record = TrackedColonyRecord(
        sessionId: sessionId,
        trackId: 7,
        species: null,
        speciesConfidence: null,
        healthLabel: 'CORAL_BL',
        healthHistory: [
          HealthHistorySample(
            label: 'CORAL',
            confidence: 0.6,
            at: DateTime.utc(2026, 1, 1, 12, 0),
          ),
          HealthHistorySample(
            label: 'CORAL_BL',
            confidence: 0.9,
            at: DateTime.utc(2026, 1, 1, 12, 1),
          ),
        ],
        sizePx: 1234.5,
        firstSeenAt: DateTime.utc(2026, 1, 1, 12, 0),
        lastSeenAt: DateTime.utc(2026, 1, 1, 12, 1),
        maskPath: '/documents/masks/session1_track7.png',
      );

      await db.upsertColony(record);
      final rows = await db.colonyRowsForSession(sessionId);

      expect(rows, hasLength(1));
      final stored = rows.single;
      expect(stored.trackId, 7);
      expect(stored.species, isNull);
      expect(stored.healthLabel, 'CORAL_BL');
      expect(stored.healthHistory, hasLength(2));
      expect(stored.healthHistory[1].confidence, 0.9);
      expect(stored.sizePx, 1234.5);
      expect(stored.maskPath, '/documents/masks/session1_track7.png');
    });

    test('upsertColony called twice for the same session+track updates the '
        'row instead of duplicating it', () async {
      final sessionId = await db.insertSession(
        TransectSession(
          startedAt: DateTime.utc(2026, 1, 1),
          tapeLengthMeters: 10,
        ),
      );

      Future<void> upsert(String? healthLabel) => db.upsertColony(
            TrackedColonyRecord(
              sessionId: sessionId,
              trackId: 7,
              healthLabel: healthLabel,
              healthHistory: const [],
              firstSeenAt: DateTime.utc(2026, 1, 1),
              lastSeenAt: DateTime.utc(2026, 1, 1),
            ),
          );

      await upsert('CORAL');
      await upsert('CORAL_BL');

      final rows = await db.colonyRowsForSession(sessionId);
      expect(rows, hasLength(1));
      expect(rows.single.healthLabel, 'CORAL_BL');
    });

    test('colonyRowsForSession only returns rows for that session', () async {
      final sessionA = await db.insertSession(
        TransectSession(
          startedAt: DateTime.utc(2026, 1, 1),
          tapeLengthMeters: 10,
        ),
      );
      final sessionB = await db.insertSession(
        TransectSession(
          startedAt: DateTime.utc(2026, 1, 2),
          tapeLengthMeters: 10,
        ),
      );

      Future<void> upsert(int sessionId, int trackId) => db.upsertColony(
            TrackedColonyRecord(
              sessionId: sessionId,
              trackId: trackId,
              healthHistory: const [],
              firstSeenAt: DateTime.utc(2026, 1, 1),
              lastSeenAt: DateTime.utc(2026, 1, 1),
            ),
          );

      await upsert(sessionA, 1);
      await upsert(sessionB, 2);

      final rowsA = await db.colonyRowsForSession(sessionA);
      expect(rowsA, hasLength(1));
      expect(rowsA.single.trackId, 1);
    });
  });

  // Sub-plan 6 (ui-ux-overhaul), step 2: the only data-layer addition --
  // read-only, no schema change. Backs the Surveys (history) tab, which
  // otherwise has no way to list what's already in SQLite.
  group('TransectDatabase.listSessions', () {
    late TransectDatabase db;

    setUp(() async {
      db = await TransectDatabase.openInMemoryForTest();
    });

    tearDown(() async {
      await db.close();
    });

    Future<int> insertSession(DateTime startedAt, {DateTime? endedAt}) async {
      final id = await db.insertSession(
        TransectSession(startedAt: startedAt, tapeLengthMeters: 50),
      );
      if (endedAt != null) {
        await db.closeSession(id, endedAt);
      }
      return id;
    }

    Future<void> insertColony(
      int sessionId,
      int trackId, {
      String? healthLabel,
    }) =>
        db.upsertColony(
          TrackedColonyRecord(
            sessionId: sessionId,
            trackId: trackId,
            healthLabel: healthLabel,
            healthHistory: const [],
            firstSeenAt: DateTime.utc(2026, 1, 1),
            lastSeenAt: DateTime.utc(2026, 1, 1),
          ),
        );

    test('returns sessions newest-started first', () async {
      final older = await insertSession(DateTime.utc(2026, 1, 1));
      final newer = await insertSession(DateTime.utc(2026, 1, 3));
      final middle = await insertSession(DateTime.utc(2026, 1, 2));

      final summaries = await db.listSessions();

      expect(
        summaries.map((s) => s.session.id).toList(),
        [newer, middle, older],
      );
    });

    test('counts colonies and bleached colonies per session, not N+1', () async {
      final sessionId = await insertSession(DateTime.utc(2026, 1, 1));
      await insertColony(sessionId, 1, healthLabel: 'CORAL');
      await insertColony(sessionId, 2, healthLabel: 'CORAL_BL');
      await insertColony(sessionId, 3, healthLabel: 'CORAL_BL');
      await insertColony(sessionId, 4); // unclassified

      final summaries = await db.listSessions();

      expect(summaries, hasLength(1));
      expect(summaries.single.colonyCount, 4);
      expect(summaries.single.bleachedCount, 2);
    });

    test('a session with zero colonies reports zero counts, not null', () async {
      await insertSession(DateTime.utc(2026, 1, 1));

      final summaries = await db.listSessions();

      expect(summaries, hasLength(1));
      expect(summaries.single.colonyCount, 0);
      expect(summaries.single.bleachedCount, 0);
    });

    test('a session with ended_at IS NULL is listed as incomplete', () async {
      final inProgressId = await insertSession(DateTime.utc(2026, 1, 1));
      await insertSession(DateTime.utc(2026, 1, 2), endedAt: DateTime.utc(2026, 1, 2, 1));

      final summaries = await db.listSessions();
      final inProgress =
          summaries.firstWhere((s) => s.session.id == inProgressId);

      expect(inProgress.session.endedAt, isNull);
    });
  });

  // Sub-plan 11 steps 2-3: checkpoint/interruption columns (schema v4).
  group('TransectDatabase schema v4', () {
    test('upgrading a v3 file keeps existing rows; new columns read back null',
        () async {
      final dir = await Directory.systemTemp.createTemp('reefsight_v3_');
      addTearDown(() => dir.delete(recursive: true));

      // The v3 schema exactly as `_createSchema` wrote it before v4.
      final v3 = await openDatabase(
        p.join(dir.path, 'reefsight.db'),
        version: 3,
        singleInstance: false,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE transect_sessions (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              started_at TEXT NOT NULL,
              ended_at TEXT,
              tape_length_meters REAL NOT NULL,
              belt_width_meters REAL NOT NULL,
              site_name TEXT,
              observer_name TEXT,
              video_path TEXT
            )
          ''');
          await db.execute('''
            CREATE TABLE tracked_colonies (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              session_id INTEGER NOT NULL REFERENCES transect_sessions(id),
              track_id INTEGER NOT NULL,
              species TEXT,
              species_confidence REAL,
              health_label TEXT,
              health_history TEXT NOT NULL,
              size_px REAL,
              first_seen_at TEXT NOT NULL,
              last_seen_at TEXT NOT NULL,
              mask_path TEXT,
              UNIQUE(session_id, track_id)
            )
          ''');
        },
      );
      final sessionId = await v3.insert('transect_sessions', {
        'started_at': DateTime.utc(2026, 1, 1).toIso8601String(),
        'tape_length_meters': 50.0,
        'belt_width_meters': 1.0,
        'site_name': 'Marigondon Reef',
      });
      await v3.close();

      final db = await TransectDatabase.open(dir.path);

      final stored = await db.sessionById(sessionId);
      expect(stored!.siteName, 'Marigondon Reef');
      expect(stored.lastCheckpointAt, isNull);
      expect(stored.interruptionCount, isNull);
      expect(stored.firstInterruptedAt, isNull);
      expect(stored.lastInterruptedAt, isNull);

      await db.recordCheckpoint(sessionId, DateTime.utc(2026, 1, 1, 0, 5));
      await db.recordInterruption(sessionId, DateTime.utc(2026, 1, 1, 0, 6));
      final updated = await db.sessionById(sessionId);
      expect(updated!.lastCheckpointAt, DateTime.utc(2026, 1, 1, 0, 5));
      expect(updated.interruptionCount, 1);

      // Closed before the temp dir is deleted (Windows holds the file open).
      await db.close();
    });

    test('upsertColonies writes every record, and replaces on '
        '(session_id, track_id)', () async {
      final db = await TransectDatabase.openInMemoryForTest();
      addTearDown(db.close);
      final sessionId = await db.insertSession(
        TransectSession(startedAt: DateTime.utc(2026, 1, 1), tapeLengthMeters: 10),
      );

      TrackedColonyRecord colony(int trackId, {String? maskPath}) =>
          TrackedColonyRecord(
            sessionId: sessionId,
            trackId: trackId,
            healthHistory: const [],
            firstSeenAt: DateTime.utc(2026, 1, 1),
            lastSeenAt: DateTime.utc(2026, 1, 1),
            maskPath: maskPath,
          );

      await db.upsertColonies([colony(1), colony(2)]);
      await db.upsertColonies([colony(2, maskPath: 'm/2.png'), colony(3)]);

      final rows = await db.colonyRowsForSession(sessionId);
      expect(rows.map((r) => r.trackId), unorderedEquals([1, 2, 3]));
      expect(rows.firstWhere((r) => r.trackId == 2).maskPath, 'm/2.png');
    });

    test('recordInterruption keeps the first time and moves the last', () async {
      final db = await TransectDatabase.openInMemoryForTest();
      addTearDown(db.close);
      final sessionId = await db.insertSession(
        TransectSession(startedAt: DateTime.utc(2026, 1, 1), tapeLengthMeters: 10),
      );

      await db.recordInterruption(sessionId, DateTime.utc(2026, 1, 1, 0, 3));
      await db.recordInterruption(sessionId, DateTime.utc(2026, 1, 1, 0, 9));

      final stored = await db.sessionById(sessionId);
      expect(stored!.interruptionCount, 2);
      expect(stored.firstInterruptedAt, DateTime.utc(2026, 1, 1, 0, 3));
      expect(stored.lastInterruptedAt, DateTime.utc(2026, 1, 1, 0, 9));
    });
  });
}
