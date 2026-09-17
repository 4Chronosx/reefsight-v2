import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/services/health_history_recorder.dart';
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
}
