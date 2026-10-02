import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:reefsight_mobile/services/device_checks.dart';
import 'package:reefsight_mobile/services/geo_fix.dart';
import 'package:reefsight_mobile/services/health_aggregator.dart';
import 'package:reefsight_mobile/services/health_history_recorder.dart';
import 'package:sqflite/sqflite.dart' show Database, openDatabase;
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

  // Sub-plan 13 step 3: thermal peak and rise count (schema v5).
  group('TransectDatabase schema v5', () {
    test('upgrading a v4 file keeps existing rows; thermal columns read back null',
        () async {
      final dir = await Directory.systemTemp.createTemp('reefsight_v4_');
      addTearDown(() => dir.delete(recursive: true));

      // The v4 sessions table exactly as `_createSchema` wrote it before v5.
      final v4 = await openDatabase(
        p.join(dir.path, 'reefsight.db'),
        version: 4,
        singleInstance: false,
        onCreate: (db, version) async {
          await _createPreV9ColoniesTable(db);
          await db.execute('''
            CREATE TABLE transect_sessions (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              started_at TEXT NOT NULL,
              ended_at TEXT,
              tape_length_meters REAL NOT NULL,
              belt_width_meters REAL NOT NULL,
              site_name TEXT,
              observer_name TEXT,
              video_path TEXT,
              last_checkpoint_at TEXT,
              interruption_count INTEGER,
              first_interrupted_at TEXT,
              last_interrupted_at TEXT
            )
          ''');
        },
      );
      final sessionId = await v4.insert('transect_sessions', {
        'started_at': DateTime.utc(2026, 1, 1).toIso8601String(),
        'tape_length_meters': 50.0,
        'belt_width_meters': 1.0,
        'interruption_count': 1,
      });
      await v4.close();

      final db = await TransectDatabase.open(dir.path);

      final stored = await db.sessionById(sessionId);
      expect(stored!.interruptionCount, 1);
      expect(stored.thermalPeak, isNull);
      expect(stored.thermalRiseCount, isNull);

      await db.recordThermal(sessionId, ThermalLevel.serious, 1);
      expect((await db.sessionById(sessionId))!.thermalPeak, ThermalLevel.serious);

      // Closed before the temp dir is deleted (Windows holds the file open).
      await db.close();
    });

    test('recordThermal overwrites with the latest peak and count', () async {
      final db = await TransectDatabase.openInMemoryForTest();
      addTearDown(db.close);
      final sessionId = await db.insertSession(
        TransectSession(startedAt: DateTime.utc(2026, 1, 1), tapeLengthMeters: 10),
      );

      await db.recordThermal(sessionId, ThermalLevel.serious, 1);
      await db.recordThermal(sessionId, ThermalLevel.critical, 3);

      final stored = await db.sessionById(sessionId);
      expect(stored!.thermalPeak, ThermalLevel.critical);
      expect(stored.thermalRiseCount, 3);
    });

    test('an unrecognised stored thermal value reads back as null', () {
      final session = TransectSession.fromMap({
        'started_at': DateTime.utc(2026, 1, 1).toIso8601String(),
        'tape_length_meters': 10.0,
        'belt_width_meters': 1.0,
        'thermal_peak': 'molten',
      });
      expect(session.thermalPeak, isNull);
    });
  });

  // Sub-plan 12: entry/exit GPS fixes (schema v6).
  group('TransectDatabase schema v6', () {
    final entry = GeoFix(
      lat: 10.2501,
      lon: 123.9502,
      accuracyM: 8,
      at: DateTime.utc(2026, 10, 2, 1),
      source: GeoFixSource.gps,
    );
    final exit = GeoFix(
      lat: 10.2505,
      lon: 123.9502,
      at: DateTime.utc(2026, 10, 2, 2),
      source: GeoFixSource.manual,
    );

    test('upgrading a v5 file keeps existing rows; fixes read back null', () async {
      final dir = await Directory.systemTemp.createTemp('reefsight_v5_');
      addTearDown(() => dir.delete(recursive: true));

      // The v5 sessions table exactly as `_createSchema` wrote it before v6.
      final v5 = await openDatabase(
        p.join(dir.path, 'reefsight.db'),
        version: 5,
        singleInstance: false,
        onCreate: (db, version) async {
          await _createPreV9ColoniesTable(db);
          await db.execute('''
            CREATE TABLE transect_sessions (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              started_at TEXT NOT NULL,
              ended_at TEXT,
              tape_length_meters REAL NOT NULL,
              belt_width_meters REAL NOT NULL,
              site_name TEXT,
              observer_name TEXT,
              video_path TEXT,
              last_checkpoint_at TEXT,
              interruption_count INTEGER,
              first_interrupted_at TEXT,
              last_interrupted_at TEXT,
              thermal_peak TEXT,
              thermal_rise_count INTEGER
            )
          ''');
        },
      );
      final sessionId = await v5.insert('transect_sessions', {
        'started_at': DateTime.utc(2026, 1, 1).toIso8601String(),
        'tape_length_meters': 50.0,
        'belt_width_meters': 1.0,
        'site_name': 'Day-as',
        'thermal_peak': 'fair',
      });
      await v5.close();

      final db = await TransectDatabase.open(dir.path);

      final stored = await db.sessionById(sessionId);
      expect(stored!.siteName, 'Day-as');
      expect(stored.thermalPeak, ThermalLevel.fair);
      expect(stored.entryFix, isNull);
      expect(stored.exitFix, isNull);

      expect(await db.recordExitFix(sessionId, exit), isTrue);
      expect((await db.sessionById(sessionId))!.exitFix, exit);

      await db.close();
    });

    test('insertSession stores the entry fix; no exit fix yet', () async {
      final db = await TransectDatabase.openInMemoryForTest();
      addTearDown(db.close);
      final sessionId = await db.insertSession(
        TransectSession(
          startedAt: DateTime.utc(2026, 10, 2, 1, 5),
          tapeLengthMeters: 50,
          entryFix: entry,
        ),
      );

      final stored = await db.sessionById(sessionId);
      expect(stored!.entryFix, entry);
      expect(stored.exitFix, isNull);
    });

    test('a session started with no fix stores none', () async {
      final db = await TransectDatabase.openInMemoryForTest();
      addTearDown(db.close);
      final sessionId = await db.insertSession(
        TransectSession(startedAt: DateTime.utc(2026, 10, 2), tapeLengthMeters: 50),
      );

      final stored = await db.sessionById(sessionId);
      expect(stored!.entryFix, isNull);
      expect(stored.exitFix, isNull);
    });

    test('recordExitFix writes once; a second write changes nothing', () async {
      final db = await TransectDatabase.openInMemoryForTest();
      addTearDown(db.close);
      final sessionId = await db.insertSession(
        TransectSession(
          startedAt: DateTime.utc(2026, 10, 2, 1, 5),
          tapeLengthMeters: 50,
          entryFix: entry,
        ),
      );
      await db.closeSession(sessionId, DateTime.utc(2026, 10, 2, 1, 50));

      expect(await db.recordExitFix(sessionId, exit), isTrue);
      final second = GeoFix(
        lat: 0,
        lon: 0,
        at: DateTime.utc(2026, 10, 3),
        source: GeoFixSource.gps,
      );
      expect(await db.recordExitFix(sessionId, second), isFalse);

      final stored = await db.sessionById(sessionId);
      expect(stored!.exitFix, exit);
      // The entry fix and session times are untouched.
      expect(stored.entryFix, entry);
      expect(stored.endedAt, DateTime.utc(2026, 10, 2, 1, 50));
    });

    test('listSessions carries the fixes', () async {
      final db = await TransectDatabase.openInMemoryForTest();
      addTearDown(db.close);
      final sessionId = await db.insertSession(
        TransectSession(
          startedAt: DateTime.utc(2026, 10, 2),
          tapeLengthMeters: 50,
          entryFix: entry,
        ),
      );
      await db.recordExitFix(sessionId, exit);

      final summary = (await db.listSessions()).single;
      expect(summary.session.entryFix, entry);
      expect(summary.session.exitFix, exit);
    });
  });

  group('TransectDatabase schema v7', () {
    Future<int> insert(TransectDatabase db, {bool resultsHidden = false}) => db.insertSession(
          TransectSession(
            startedAt: DateTime.utc(2026, 10, 2, 1),
            tapeLengthMeters: 50,
            resultsHidden: resultsHidden,
          ),
        );

    test('upgrading a v6 file keeps existing rows; recount columns read back unset',
        () async {
      final dir = await Directory.systemTemp.createTemp('reefsight_v6_');
      addTearDown(() => dir.delete(recursive: true));

      // The v6 sessions table exactly as `_createSchema` wrote it before v7.
      final v6 = await openDatabase(
        p.join(dir.path, 'reefsight.db'),
        version: 6,
        singleInstance: false,
        onCreate: (db, version) async {
          await _createPreV9ColoniesTable(db);
          await db.execute('''
            CREATE TABLE transect_sessions (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              started_at TEXT NOT NULL,
              ended_at TEXT,
              tape_length_meters REAL NOT NULL,
              belt_width_meters REAL NOT NULL,
              site_name TEXT,
              observer_name TEXT,
              video_path TEXT,
              last_checkpoint_at TEXT,
              interruption_count INTEGER,
              first_interrupted_at TEXT,
              last_interrupted_at TEXT,
              thermal_peak TEXT,
              thermal_rise_count INTEGER,
              entry_lat REAL, entry_lon REAL, entry_accuracy_m REAL,
              entry_at TEXT, entry_source TEXT,
              exit_lat REAL, exit_lon REAL, exit_accuracy_m REAL,
              exit_at TEXT, exit_source TEXT
            )
          ''');
        },
      );
      final sessionId = await v6.insert('transect_sessions', {
        'started_at': DateTime.utc(2026, 1, 1).toIso8601String(),
        'tape_length_meters': 50.0,
        'belt_width_meters': 1.0,
        'site_name': 'Day-as',
        'entry_lat': 10.25,
        'entry_lon': 123.95,
        'entry_at': DateTime.utc(2026, 1, 1).toIso8601String(),
        'entry_source': 'gps',
      });
      await v6.close();

      final db = await TransectDatabase.open(dir.path);
      addTearDown(db.close);

      final stored = await db.sessionById(sessionId);
      expect(stored!.siteName, 'Day-as');
      expect(stored.entryFix, isNotNull);
      expect(stored.resultsHidden, isFalse);
      expect(stored.resultsRevealedAt, isNull);
      expect(stored.recount, isNull);
      expect(stored.resultsCurrentlyHidden, isFalse);

      // An old survey's recount can only be unblinded: it was never hidden.
      expect(
        await db.recordRecount(sessionId,
            total: 10, bleached: 2, countedBy: 'A. Diver', at: DateTime.utc(2026, 1, 2)),
        isTrue,
      );
      expect((await db.sessionById(sessionId))!.recount!.blinded, isFalse);
    });

    test('results_hidden round-trips and hides results until revealed', () async {
      final db = await TransectDatabase.openInMemoryForTest();
      addTearDown(db.close);
      final hiddenId = await insert(db, resultsHidden: true);
      final shownId = await insert(db);

      final hidden = await db.sessionById(hiddenId);
      expect(hidden!.resultsHidden, isTrue);
      expect(hidden.resultsCurrentlyHidden, isTrue);
      expect((await db.sessionById(shownId))!.resultsCurrentlyHidden, isFalse);
    });

    test('a recount entered while hidden is stored blinded and reveals results', () async {
      final db = await TransectDatabase.openInMemoryForTest();
      addTearDown(db.close);
      final sessionId = await insert(db, resultsHidden: true);
      final at = DateTime.utc(2026, 10, 2, 3);

      expect(
        await db.recordRecount(sessionId,
            total: 12, bleached: 3, countedBy: 'B. Counter', at: at),
        isTrue,
      );

      final stored = (await db.sessionById(sessionId))!;
      final recount = stored.recount!;
      expect(recount.total, 12);
      expect(recount.bleached, 3);
      expect(recount.countedBy, 'B. Counter');
      expect(recount.at, at);
      expect(recount.blinded, isTrue);
      expect(stored.resultsRevealedAt, at);
      expect(stored.resultsCurrentlyHidden, isFalse);
    });

    test('recordRecount writes once; a second write changes nothing', () async {
      final db = await TransectDatabase.openInMemoryForTest();
      addTearDown(db.close);
      final sessionId = await insert(db, resultsHidden: true);

      expect(
        await db.recordRecount(sessionId,
            total: 12, bleached: 3, countedBy: 'B', at: DateTime.utc(2026, 10, 2, 3)),
        isTrue,
      );
      expect(
        await db.recordRecount(sessionId,
            total: 99, bleached: 0, countedBy: 'C', at: DateTime.utc(2026, 10, 2, 4)),
        isFalse,
      );

      final recount = (await db.sessionById(sessionId))!.recount!;
      expect(recount.total, 12);
      expect(recount.countedBy, 'B');
    });

    test('revealing without a recount makes a later recount unblinded', () async {
      final db = await TransectDatabase.openInMemoryForTest();
      addTearDown(db.close);
      final sessionId = await insert(db, resultsHidden: true);
      final revealedAt = DateTime.utc(2026, 10, 2, 3);

      expect(await db.revealResults(sessionId, revealedAt), isTrue);
      // Write-once: a second reveal keeps the first time.
      expect(await db.revealResults(sessionId, DateTime.utc(2026, 10, 3)), isFalse);

      var stored = (await db.sessionById(sessionId))!;
      expect(stored.resultsHidden, isTrue, reason: 'the plan to recount stays on record');
      expect(stored.resultsRevealedAt, revealedAt);
      expect(stored.resultsCurrentlyHidden, isFalse);

      await db.recordRecount(sessionId,
          total: 5, bleached: 1, countedBy: 'B', at: DateTime.utc(2026, 10, 2, 5));
      stored = (await db.sessionById(sessionId))!;
      expect(stored.recount!.blinded, isFalse);
      // The recount doesn't move the earlier reveal time.
      expect(stored.resultsRevealedAt, revealedAt);
    });

    test('a recount on a session that was never hidden is unblinded', () async {
      final db = await TransectDatabase.openInMemoryForTest();
      addTearDown(db.close);
      final sessionId = await insert(db);

      await db.recordRecount(sessionId,
          total: 5, bleached: 1, countedBy: 'B', at: DateTime.utc(2026, 10, 2, 5));
      expect((await db.sessionById(sessionId))!.recount!.blinded, isFalse);
    });

    test('recordRecount rejects impossible counts and a blank counter', () async {
      final db = await TransectDatabase.openInMemoryForTest();
      addTearDown(db.close);
      final sessionId = await insert(db, resultsHidden: true);
      final at = DateTime.utc(2026, 10, 2, 5);

      expect(
        () => db.recordRecount(sessionId, total: 3, bleached: 4, countedBy: 'B', at: at),
        throwsArgumentError,
      );
      expect(
        () => db.recordRecount(sessionId, total: -1, bleached: 0, countedBy: 'B', at: at),
        throwsArgumentError,
      );
      expect(
        () => db.recordRecount(sessionId, total: 3, bleached: 1, countedBy: '  ', at: at),
        throwsArgumentError,
      );
      expect((await db.sessionById(sessionId))!.recount, isNull);
    });

    test('listSessions counts classified colonies and carries the recount', () async {
      final db = await TransectDatabase.openInMemoryForTest();
      addTearDown(db.close);
      final sessionId = await insert(db, resultsHidden: true);
      final seen = DateTime.utc(2026, 10, 2, 1, 10);
      for (final (trackId, label) in [
        (1, HealthAggregator.healthyLabel),
        (2, HealthAggregator.bleachedLabel),
        (3, null),
      ]) {
        await db.upsertColony(
          TrackedColonyRecord(
            sessionId: sessionId,
            trackId: trackId,
            healthLabel: label,
            healthHistory: const [],
            firstSeenAt: seen,
            lastSeenAt: seen,
          ),
        );
      }
      await db.recordRecount(sessionId,
          total: 4, bleached: 1, countedBy: 'B', at: DateTime.utc(2026, 10, 2, 5));

      final summary = (await db.listSessions()).single;
      expect(summary.colonyCount, 3);
      expect(summary.bleachedCount, 1);
      expect(summary.classifiedCount, 2);
      expect(summary.session.recount!.total, 4);
    });
  });

  group('TransectDatabase schema v8', () {
    test('upgrading a v7 file keeps existing rows; videoStartedAt reads back null', () async {
      final dir = await Directory.systemTemp.createTemp('reefsight_v7_');
      addTearDown(() => dir.delete(recursive: true));

      // The v7 sessions table exactly as `_createSchema` wrote it before v8.
      final v7 = await openDatabase(
        p.join(dir.path, 'reefsight.db'),
        version: 7,
        singleInstance: false,
        onCreate: (db, version) async {
          await _createPreV9ColoniesTable(db);
          await db.execute('''
            CREATE TABLE transect_sessions (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              started_at TEXT NOT NULL,
              ended_at TEXT,
              tape_length_meters REAL NOT NULL,
              belt_width_meters REAL NOT NULL,
              site_name TEXT,
              observer_name TEXT,
              video_path TEXT,
              last_checkpoint_at TEXT,
              interruption_count INTEGER,
              first_interrupted_at TEXT,
              last_interrupted_at TEXT,
              thermal_peak TEXT,
              thermal_rise_count INTEGER,
              entry_lat REAL, entry_lon REAL, entry_accuracy_m REAL,
              entry_at TEXT, entry_source TEXT,
              exit_lat REAL, exit_lon REAL, exit_accuracy_m REAL,
              exit_at TEXT, exit_source TEXT,
              results_hidden INTEGER,
              results_revealed_at TEXT,
              recount_total INTEGER,
              recount_bleached INTEGER,
              recount_by TEXT,
              recount_at TEXT,
              recount_blinded INTEGER
            )
          ''');
        },
      );
      final sessionId = await v7.insert('transect_sessions', {
        'started_at': DateTime.utc(2026, 1, 1).toIso8601String(),
        'tape_length_meters': 50.0,
        'belt_width_meters': 1.0,
        'site_name': 'Day-as',
        'video_path': '/old/transect_2026-01-01T00-00-02-000Z.mov',
      });
      await v7.close();

      final db = await TransectDatabase.open(dir.path);
      addTearDown(db.close);

      final stored = await db.sessionById(sessionId);
      expect(stored!.siteName, 'Day-as');
      expect(stored.videoPath, '/old/transect_2026-01-01T00-00-02-000Z.mov');
      expect(stored.videoStartedAt, isNull);
    });

    test('closeSession stores videoStartedAt; omitting it leaves the column alone', () async {
      final db = await TransectDatabase.openInMemoryForTest();
      addTearDown(db.close);
      final id = await db.insertSession(
        TransectSession(startedAt: DateTime.utc(2026, 10, 2, 1), tapeLengthMeters: 50),
      );
      final videoStart = DateTime.utc(2026, 10, 2, 1, 0, 2, 400);

      await db.closeSession(
        id,
        DateTime.utc(2026, 10, 2, 1, 30),
        videoPath: '/docs/transect.mov',
        videoStartedAt: videoStart,
      );
      expect((await db.sessionById(id))!.videoStartedAt, videoStart);

      await db.closeSession(id, DateTime.utc(2026, 10, 2, 1, 31));
      expect((await db.sessionById(id))!.videoStartedAt, videoStart);
    });
  });

  group('TransectDatabase schema v9', () {
    test('upgrading a v8 file keeps colony rows; the photo columns read back null', () async {
      final dir = await Directory.systemTemp.createTemp('reefsight_v8_');
      addTearDown(() => dir.delete(recursive: true));

      // The v8 colonies table exactly as `_createSchema` wrote it before v9.
      final v8 = await openDatabase(
        p.join(dir.path, 'reefsight.db'),
        version: 8,
        singleInstance: false,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE tracked_colonies (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              session_id INTEGER NOT NULL,
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
      await v8.insert('tracked_colonies', {
        'session_id': 1,
        'track_id': 4,
        'health_label': 'CORAL',
        'health_history': '[]',
        'first_seen_at': DateTime.utc(2026, 1, 1).toIso8601String(),
        'last_seen_at': DateTime.utc(2026, 1, 1).toIso8601String(),
      });
      await v8.close();

      final db = await TransectDatabase.open(dir.path);
      addTearDown(db.close);

      final colony = (await db.colonyRowsForSession(1)).single;
      expect(colony.healthLabel, 'CORAL');
      expect(colony.photoPath, isNull);
      expect(colony.photoCropPath, isNull);
      expect(colony.photoLabel, isNull);
      expect(colony.photoConfidence, isNull);
    });

    test('upsertColonies stores and reads back the photo columns', () async {
      final db = await TransectDatabase.openInMemoryForTest();
      addTearDown(db.close);
      final sessionId = await db.insertSession(
        TransectSession(startedAt: DateTime.utc(2026, 1, 1), tapeLengthMeters: 50),
      );

      await db.upsertColonies([
        TrackedColonyRecord(
          sessionId: sessionId,
          trackId: 9,
          healthHistory: const [],
          firstSeenAt: DateTime.utc(2026, 1, 1),
          lastSeenAt: DateTime.utc(2026, 1, 1),
          photoPath: 'colony_photos/session2_track9.jpg',
          photoCropPath: 'colony_photos/session2_track9_crop.jpg',
          photoLabel: 'CORAL_BL',
          photoConfidence: 0.91,
        ),
      ]);

      final colony = (await db.colonyRowsForSession(sessionId)).single;
      expect(colony.photoPath, 'colony_photos/session2_track9.jpg');
      expect(colony.photoCropPath, 'colony_photos/session2_track9_crop.jpg');
      expect(colony.photoLabel, 'CORAL_BL');
      expect(colony.photoConfidence, 0.91);
    });
  });
}

/// Every real database has had `tracked_colonies` since v1; the older
/// migration fixtures above build only the table their version changed, so
/// v9's colony `ALTER`s need this one too. Its shape before v9.
Future<void> _createPreV9ColoniesTable(Database db) => db.execute('''
  CREATE TABLE tracked_colonies (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id INTEGER NOT NULL,
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
