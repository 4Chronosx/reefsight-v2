import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'category_mapping.dart';
import 'device_checks.dart';
import 'frame_point.dart';
import 'geo_fix.dart';
import 'health_aggregator.dart';
import 'session_summary.dart';
import 'station.dart';
import 'tracked_colony_record.dart';
import 'transect_cover.dart';
import 'transect_frame.dart';
import 'transect_session.dart';

/// On-device SQLite persistence (`sqflite`, locked by
/// `ReefSight_Specification.md`'s "Storage" section) for a transect run and
/// its tracked colonies.
///
/// No session concept is named in the schema line itself ("one row per
/// tracked colony..."), but density needs a scoped colony count and a tape
/// length to divide by (`transect_metrics.dart`'s `density`) -- `
/// transect_sessions` is the minimal addition that makes that well-defined,
/// not a speculative extra layer.
class TransectDatabase {
  TransectDatabase._(this._db, {bool ignoreClose = false}) : _ignoreClose = ignoreClose;

  final Database _db;
  final bool _ignoreClose;

  static const _sessionsTable = 'transect_sessions';
  static const _coloniesTable = 'tracked_colonies';

  // Schema v11 (issue #1, `docs/reefsight-v2-blueprint.md` §3-5).
  static const _stationsTable = 'stations';
  static const _framesTable = 'transect_frames';
  static const _pointsTable = 'frame_points';
  static const _categoryMapTable = 'category_map';
  static const _coverTable = 'transect_cover';

  /// Bumped from 1 -> 2 when `site_name`/`observer_name` were added to
  /// `transect_sessions` (sub-plan 5, task 2), and 2 -> 3 when `video_path`
  /// was added (transect video export/share) -- `onCreate` only runs for a
  /// brand-new database file, so any device with an existing
  /// `reefsight.db` from before either change needs `onUpgrade` to actually
  /// gain the new columns, or every subsequent `insertSession()` throws
  /// `no such column: ...`. 3 -> 4 added the checkpoint/interruption
  /// columns (sub-plan 11: live session safety). 4 -> 5 added the thermal
  /// peak and rise count (sub-plan 13: pre-dive checks). 5 -> 6 added the
  /// entry/exit GPS fix columns (sub-plan 12). 6 -> 7 added the hidden-
  /// results and manual recount columns (sub-plan 14). 7 -> 8 added
  /// `video_started_at` (sub-plan 16: colony video jump). 8 -> 9 added the
  /// colony photo columns to `tracked_colonies` (sub-plan 18). 9 -> 10
  /// added the session's classifier settings (crop style + thresholds).
  /// 10 -> 11 added stations, transect frames, frame points, the category
  /// map and cached transect cover, plus the station/transect columns on
  /// `transect_sessions` (issue #1, the DENR TB 2019-04 version).
  static const _schemaVersion = 11;

  /// `singleInstance: false`: every caller (Home, Surveys, Settings, Summary,
  /// Live) opens, queries, then `close()`s its own handle. With sqflite's
  /// default `singleInstance: true` they all share ONE cached connection, so
  /// whichever tab finishes first closes it out from under the others --
  /// `AppShell`'s `IndexedStack` builds Home/Surveys/Settings at once, and
  /// the loser's query threw `database_closed` (Settings then sat on
  /// "Loading..." forever, since its `FutureBuilder` treated the error as
  /// no-data-yet).
  static Future<TransectDatabase> open(String directory) async {
    final db = await openDatabase(
      p.join(directory, 'reefsight.db'),
      version: _schemaVersion,
      singleInstance: false,
      onCreate: (db, version) => _createSchema(db),
      onUpgrade: (db, oldVersion, newVersion) => _upgradeSchema(db, oldVersion),
      onOpen: (db) => db.execute('PRAGMA foreign_keys = ON'),
    );
    return TransectDatabase._(db);
  }

  /// Opens an in-memory database -- for tests only (see
  /// `test/flutter_test_config.dart`'s `sqflite_common_ffi` setup, which
  /// this relies on to have a `databaseFactory` at all under `flutter test`).
  ///
  /// `singleInstance: false` per sqflite's own documented guidance for
  /// in-memory DBs: `inMemoryDatabasePath` is a fixed `":memory:"` key, and
  /// the default `singleInstance: true` caching can otherwise hand back a
  /// *shared* cached instance across separate `openInMemoryForTest()` calls
  /// instead of an independent database per call.
  ///
  /// [ignoreClose] (issue #2): screens open and close the database per
  /// operation, which would close a shared in-memory test database after
  /// the first one. With it set, [close] does nothing and the test calls
  /// [closeForTest] in its tear-down.
  static Future<TransectDatabase> openInMemoryForTest({bool ignoreClose = false}) async {
    final db = await openDatabase(
      inMemoryDatabasePath,
      version: _schemaVersion,
      singleInstance: false,
      onCreate: (db, version) => _createSchema(db),
      onOpen: (db) => db.execute('PRAGMA foreign_keys = ON'),
    );
    return TransectDatabase._(db, ignoreClose: ignoreClose);
  }

  static Future<void> _createSchema(Database db) async {
    // Before `transect_sessions`, which references it.
    await db.execute(_stationsTableSql);
    await db.execute('''
      CREATE TABLE $_sessionsTable (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        started_at TEXT NOT NULL,
        ended_at TEXT,
        tape_length_meters REAL NOT NULL,
        belt_width_meters REAL NOT NULL,
        site_name TEXT,
        observer_name TEXT,
        video_path TEXT,
        video_started_at TEXT,
        last_checkpoint_at TEXT,
        interruption_count INTEGER,
        first_interrupted_at TEXT,
        last_interrupted_at TEXT,
        thermal_peak TEXT,
        thermal_rise_count INTEGER,
        ${_fixColumnsSql('entry')},
        ${_fixColumnsSql('exit')},
        ${_recountColumns.join(',\n        ')},
        ${_settingsColumns.join(',\n        ')},
        ${_stationSessionColumns.join(',\n        ')}
      )
    ''');
    await db.execute('''
      CREATE TABLE $_coloniesTable (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id INTEGER NOT NULL REFERENCES $_sessionsTable(id),
        track_id INTEGER NOT NULL,
        species TEXT,
        species_confidence REAL,
        health_label TEXT,
        health_history TEXT NOT NULL,
        size_px REAL,
        first_seen_at TEXT NOT NULL,
        last_seen_at TEXT NOT NULL,
        mask_path TEXT,
        ${_photoColumns.join(',\n        ')},
        UNIQUE(session_id, track_id)
      )
    ''');
    for (final sql in _v11ChildTablesSql) {
      await db.execute(sql);
    }
    await db.execute(_stationTransectIndexSql);
  }

  /// Applies each version bump between [oldVersion] and [_schemaVersion] in
  /// order -- 1 -> 2 added `site_name`/`observer_name`, 2 -> 3 added
  /// `video_path`, 3 -> 4 added the checkpoint/interruption columns, 4 -> 5
  /// added `thermal_peak`/`thermal_rise_count`, 5 -> 6 added the
  /// `entry_*`/`exit_*` GPS fix columns, 6 -> 7 added `results_hidden`,
  /// `results_revealed_at` and the `recount_*` columns, 7 -> 8 added
  /// `video_started_at`, 8 -> 9 added the `photo_*` colony columns, 9 -> 10
  /// added `crop_style` and the `threshold_*` session columns.
  /// Nullable `ALTER TABLE ... ADD COLUMN` is safe on existing rows (they
  /// read back as `null`, matching `TransectSession.fromMap`'s
  /// already-nullable handling of every added column).
  ///
  /// No constraint migration was needed for sub-plan 11's repeated colony
  /// writes: `UNIQUE(session_id, track_id)` has been in `_createSchema`
  /// since v1, so `upsertColony` has always really upserted.
  static Future<void> _upgradeSchema(Database db, int oldVersion) async {
    if (oldVersion < 2) {
      await db.execute('ALTER TABLE $_sessionsTable ADD COLUMN site_name TEXT');
      await db.execute('ALTER TABLE $_sessionsTable ADD COLUMN observer_name TEXT');
    }
    if (oldVersion < 3) {
      await db.execute('ALTER TABLE $_sessionsTable ADD COLUMN video_path TEXT');
    }
    if (oldVersion < 4) {
      await db.execute('ALTER TABLE $_sessionsTable ADD COLUMN last_checkpoint_at TEXT');
      await db.execute('ALTER TABLE $_sessionsTable ADD COLUMN interruption_count INTEGER');
      await db.execute('ALTER TABLE $_sessionsTable ADD COLUMN first_interrupted_at TEXT');
      await db.execute('ALTER TABLE $_sessionsTable ADD COLUMN last_interrupted_at TEXT');
    }
    if (oldVersion < 5) {
      await db.execute('ALTER TABLE $_sessionsTable ADD COLUMN thermal_peak TEXT');
      await db.execute('ALTER TABLE $_sessionsTable ADD COLUMN thermal_rise_count INTEGER');
    }
    if (oldVersion < 6) {
      for (final prefix in ['entry', 'exit']) {
        for (final column in _fixColumns(prefix)) {
          await db.execute('ALTER TABLE $_sessionsTable ADD COLUMN $column');
        }
      }
    }
    if (oldVersion < 7) {
      for (final column in _recountColumns) {
        await db.execute('ALTER TABLE $_sessionsTable ADD COLUMN $column');
      }
    }
    if (oldVersion < 8) {
      await db.execute('ALTER TABLE $_sessionsTable ADD COLUMN video_started_at TEXT');
    }
    if (oldVersion < 9) {
      for (final column in _photoColumns) {
        await db.execute('ALTER TABLE $_coloniesTable ADD COLUMN $column');
      }
    }
    if (oldVersion < 10) {
      for (final column in _settingsColumns) {
        await db.execute('ALTER TABLE $_sessionsTable ADD COLUMN $column');
      }
    }
    if (oldVersion < 11) {
      await db.execute(_stationsTableSql);
      for (final column in _stationSessionColumns) {
        await db.execute('ALTER TABLE $_sessionsTable ADD COLUMN $column');
      }
      for (final sql in _v11ChildTablesSql) {
        await db.execute(sql);
      }
      await db.execute(_stationTransectIndexSql);
    }
  }

  /// v11: a station (TB 2019-04) groups 3-5 transects. The CHECK lists are
  /// frozen on disk -- SQLite can't alter a CHECK in place, so a new survey
  /// type or frame mode needs a table rebuild in its own migration, not just
  /// a new Dart enum value. The deep-edge fix uses `GeoFix.toColumns`'s five
  /// columns (prefix `deep_edge`), like the transect entry/exit fixes.
  static final _stationsTableSql = '''
    CREATE TABLE $_stationsTable (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      code TEXT NOT NULL,
      name TEXT,
      survey_type TEXT NOT NULL
        CHECK (survey_type IN ('photo_transect', 'preliminary_video', 'colony_count')),
      frame_mode TEXT CHECK (frame_mode IN ('physical', 'virtual', 'imported_mixed')),
      surveyed_on TEXT NOT NULL,
      site_name TEXT,
      reef_zone TEXT,
      depth_min_m REAL,
      depth_max_m REAL,
      ${_fixColumnsSql(Station.deepEdgePrefix)},
      marker_placed INTEGER,
      observer_name TEXT,
      notes TEXT,
      created_at TEXT NOT NULL
    )
  ''';

  /// v11's `transect_sessions` columns -- names match `TransectSession.toMap`.
  /// All nullable, so every survey from before v11 reads back with them
  /// `null` and stays a standalone (station-less) survey. `REFERENCES` on an
  /// added column is allowed because its default is NULL.
  static const _stationSessionColumns = [
    'station_id INTEGER REFERENCES $_stationsTable(id)',
    'transect_number INTEGER',
    'capture_source TEXT',
    'depth_start_m REAL',
    'depth_end_m REAL',
    'random_along_m REAL',
    'random_swimout_m REAL',
    'points_per_frame INTEGER',
    'point_seed INTEGER',
    'analysis_status TEXT',
    'analyzed_at TEXT',
    'model_id TEXT',
    'analyzed_on TEXT',
  ];

  /// A transect number is unique within its station. Partial, so the
  /// standalone surveys (`station_id IS NULL`) are never constrained.
  static const _stationTransectIndexSql = '''
    CREATE UNIQUE INDEX idx_sessions_station_transect
      ON $_sessionsTable(station_id, transect_number) WHERE station_id IS NOT NULL
  ''';

  /// v11's tables that hang off a transect, in dependency order. `genus_tags`
  /// comes with #10 and `drive_uploads` is deferred with the in-app Drive
  /// upload, so neither is here. No `ON DELETE CASCADE` (matching
  /// `tracked_colonies`): [deleteSession] removes the children explicitly.
  static const _v11ChildTablesSql = [
    '''
    CREATE TABLE $_framesTable (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id INTEGER NOT NULL REFERENCES $_sessionsTable(id),
      meter_mark REAL,
      video_time_ms INTEGER,
      image_path TEXT NOT NULL,
      source TEXT NOT NULL CHECK (source IN ('in_app', 'imported', 'video_frame')),
      width_px INTEGER,
      height_px INTEGER,
      camera_make TEXT,
      camera_model TEXT,
      captured_at TEXT,
      corners_json TEXT,
      corner_source TEXT,
      tilt_deg REAL,
      distance_m REAL,
      distance_method TEXT,
      checks_passed INTEGER,
      fisheye_flag INTEGER,
      excluded INTEGER NOT NULL DEFAULT 0,
      exclude_reason TEXT,
      UNIQUE (session_id, meter_mark)
    )
    ''',
    '''
    CREATE TABLE $_pointsTable (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      frame_id INTEGER NOT NULL REFERENCES $_framesTable(id),
      point_index INTEGER NOT NULL,
      x_norm REAL NOT NULL,
      y_norm REAL NOT NULL,
      model_class TEXT,
      model_confidence REAL,
      category_code TEXT,
      expert_category_code TEXT,
      expert_name TEXT,
      reviewed_at TEXT,
      UNIQUE (frame_id, point_index)
    )
    ''',
    '''
    CREATE TABLE $_categoryMapTable (
      model_id TEXT NOT NULL,
      model_class TEXT NOT NULL,
      category_code TEXT NOT NULL,
      major_category TEXT NOT NULL,
      excluded INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (model_id, model_class)
    )
    ''',
    '''
    CREATE TABLE $_coverTable (
      session_id INTEGER NOT NULL REFERENCES $_sessionsTable(id),
      category_code TEXT NOT NULL,
      points INTEGER NOT NULL,
      total_points INTEGER NOT NULL,
      percent REAL NOT NULL,
      uses_expert INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (session_id, category_code)
    )
    ''',
  ];

  /// v10: the classifier settings a session ran with -- names match
  /// `TransectSession.toMap` and `ClassificationThresholds.toColumns`.
  static const _settingsColumns = [
    'crop_style TEXT',
    'threshold_seg_floor REAL',
    'threshold_min_coverage REAL',
    'threshold_conf_floor REAL',
    'threshold_min_samples INTEGER',
  ];

  /// Sub-plan 18's columns -- names match `TrackedColonyRecord.toMap`.
  /// Paths are relative to the documents directory.
  static const _photoColumns = [
    'photo_path TEXT',
    'photo_crop_path TEXT',
    'photo_label TEXT',
    'photo_confidence REAL',
  ];

  /// Sub-plan 14's columns -- names match `TransectSession.toMap` and
  /// `Recount.toColumns`. Flags are 0/1, times ISO-8601 UTC.
  static const _recountColumns = [
    'results_hidden INTEGER',
    'results_revealed_at TEXT',
    'recount_total INTEGER',
    'recount_bleached INTEGER',
    'recount_by TEXT',
    'recount_at TEXT',
    'recount_blinded INTEGER',
  ];

  /// Sub-plan 12's five columns per GPS fix -- names match
  /// `GeoFix.toColumns`. `<prefix>_at` is ISO-8601 UTC, `<prefix>_source`
  /// is `gps` or `manual`.
  static List<String> _fixColumns(String prefix) => [
        '${prefix}_lat REAL',
        '${prefix}_lon REAL',
        '${prefix}_accuracy_m REAL',
        '${prefix}_at TEXT',
        '${prefix}_source TEXT',
      ];

  static String _fixColumnsSql(String prefix) => _fixColumns(prefix).join(',\n        ');

  /// A station transect must carry its number: the partial unique index
  /// treats NULLs as distinct, so a numberless one would slip past it and
  /// past [nextTransectNumber].
  Future<int> insertSession(TransectSession session) async {
    if (session.stationId != null && session.transectNumber == null) {
      throw ArgumentError('A station transect needs a transectNumber');
    }
    final map = session.toMap()..remove('id');
    return _db.insert(_sessionsTable, map);
  }

  /// [videoPath] is optional -- omitted (or `null`) leaves the column
  /// untouched rather than overwriting a previously-set path with `null`,
  /// matching every existing caller/test that doesn't pass it. Same for
  /// [videoStartedAt] (sub-plan 16).
  Future<void> closeSession(
    int sessionId,
    DateTime endedAt, {
    String? videoPath,
    DateTime? videoStartedAt,
  }) async {
    final values = {'ended_at': endedAt.toIso8601String()};
    if (videoPath != null) values['video_path'] = videoPath;
    if (videoStartedAt != null) values['video_started_at'] = videoStartedAt.toUtc().toIso8601String();
    await _db.update(
      _sessionsTable,
      values,
      where: 'id = ?',
      whereArgs: [sessionId],
    );
  }

  Future<TransectSession?> sessionById(int sessionId) async {
    final rows = await _db.query(
      _sessionsTable,
      where: 'id = ?',
      whereArgs: [sessionId],
    );
    if (rows.isEmpty) return null;
    return TransectSession.fromMap(rows.single);
  }

  /// Inserts a new row, or replaces the existing one for the same
  /// `(session_id, track_id)` pair -- a colony's row is finalized once per
  /// session (see `live_transect_screen.dart`'s session-stop handling,
  /// task 7), and re-running that finalize step should update, not
  /// duplicate.
  Future<void> upsertColony(TrackedColonyRecord record) async {
    final map = record.toMap()..remove('id');
    await _db.insert(
      _coloniesTable,
      map,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// [upsertColony] for many records in one transaction -- all or nothing,
  /// and one round trip instead of N. Used by `SessionCheckpointer`
  /// (sub-plan 11), where a checkpoint on `AppLifecycleState.paused` may
  /// have only a few seconds before iOS suspends or kills the app, and by
  /// the Live screen's finalize.
  Future<void> upsertColonies(List<TrackedColonyRecord> records) async {
    if (records.isEmpty) return;
    await _db.transaction((txn) async {
      final batch = txn.batch();
      for (final record in records) {
        batch.insert(
          _coloniesTable,
          record.toMap()..remove('id'),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  /// Stamps when Live last checkpointed this session's colonies (sub-plan
  /// 11) -- what Summary reports as "the app stopped at HH:MM" for a
  /// session that never reached End Transect.
  Future<void> recordCheckpoint(int sessionId, DateTime at) async {
    await _db.update(
      _sessionsTable,
      {'last_checkpoint_at': at.toIso8601String()},
      where: 'id = ?',
      whereArgs: [sessionId],
    );
  }

  /// Counts one interruption (Live left the foreground), keeping the first
  /// interruption time and moving the last -- sub-plan 11 step 3. A single
  /// UPDATE, so the increment can't race a concurrent read-modify-write.
  Future<void> recordInterruption(int sessionId, DateTime at) async {
    final stamp = at.toIso8601String();
    await _db.rawUpdate('''
      UPDATE $_sessionsTable
      SET interruption_count = COALESCE(interruption_count, 0) + 1,
          first_interrupted_at = COALESCE(first_interrupted_at, ?),
          last_interrupted_at = ?
      WHERE id = ?
    ''', [stamp, stamp, sessionId]);
  }

  /// Stores the session's thermal peak and rise count so far -- sub-plan 13
  /// step 3. Overwrites rather than increments: `DeviceHealthMonitor` owns
  /// the running values, so a repeated write is harmless.
  Future<void> recordThermal(int sessionId, ThermalLevel peak, int rises) async {
    await _db.update(
      _sessionsTable,
      {'thermal_peak': peak.name, 'thermal_rise_count': rises},
      where: 'id = ?',
      whereArgs: [sessionId],
    );
  }

  /// Stores the exit GPS fix, recorded from Summary after surfacing --
  /// sub-plan 12 decision 3. Write-once, and the only field written to a
  /// survey after End Transect: the `exit_lat IS NULL` guard is in the
  /// same UPDATE, so a second call (double tap, two Summary screens) can't
  /// overwrite the first. Returns whether this call stored the fix.
  Future<bool> recordExitFix(int sessionId, GeoFix fix) async {
    final changed = await _db.update(
      _sessionsTable,
      fix.toColumns('exit'),
      where: 'id = ? AND exit_lat IS NULL',
      whereArgs: [sessionId],
    );
    return changed == 1;
  }

  /// Stores the manual recount -- sub-plan 14 decision 3. Write-once, like
  /// [recordExitFix]: the `recount_at IS NULL` guard is in the same UPDATE.
  ///
  /// `recount_blinded` is decided here in SQL from the row itself, never by
  /// the caller: it's 1 only if results were hidden at Setup and never
  /// revealed before this write, so a stale screen can't mislabel an
  /// unblinded recount as blind. A hidden session's results are revealed by
  /// the same write (SQLite evaluates every SET against the old row, so the
  /// CASE sees the pre-write `results_revealed_at`). Returns whether this
  /// call stored the recount.
  Future<bool> recordRecount(
    int sessionId, {
    required int total,
    required int bleached,
    required String countedBy,
    required DateTime at,
  }) async {
    final by = countedBy.trim();
    if (total < 0 || bleached < 0 || bleached > total) {
      throw ArgumentError('Need 0 <= bleached ($bleached) <= total ($total)');
    }
    if (by.isEmpty) throw ArgumentError('countedBy is required');
    final stamp = at.toUtc().toIso8601String();
    final changed = await _db.rawUpdate('''
      UPDATE $_sessionsTable
      SET recount_total = ?,
          recount_bleached = ?,
          recount_by = ?,
          recount_at = ?,
          recount_blinded = CASE
            WHEN results_hidden = 1 AND results_revealed_at IS NULL THEN 1 ELSE 0 END,
          results_revealed_at = CASE
            WHEN results_hidden = 1 THEN COALESCE(results_revealed_at, ?)
            ELSE results_revealed_at END
      WHERE id = ? AND recount_at IS NULL
    ''', [total, bleached, by, stamp, stamp, sessionId]);
    return changed == 1;
  }

  /// "Reveal without recount" -- sub-plan 14 step 4. Write-once; any recount
  /// entered after this is stored unblinded. `results_hidden` stays 1, so
  /// the record keeps that a recount was planned. Returns whether this call
  /// revealed anything.
  Future<bool> revealResults(int sessionId, DateTime at) async {
    final changed = await _db.update(
      _sessionsTable,
      {'results_revealed_at': at.toUtc().toIso8601String()},
      where: 'id = ? AND results_hidden = 1 AND results_revealed_at IS NULL',
      whereArgs: [sessionId],
    );
    return changed == 1;
  }

  /// Deletes a survey from this phone: its frame points, frames, cached
  /// cover and colony rows, then the session row, in one transaction (none
  /// of the child tables has `ON DELETE CASCADE`, and foreign keys are on --
  /// leaving any child row behind makes the session delete fail). The
  /// station, if any, stays: it is the diver's to delete. Returns the deleted session, so
  /// the caller can remove its files (`session_files.dart`), or `null` if
  /// there was no such session. `AUTOINCREMENT` never reuses the id, so a
  /// later survey can't inherit the deleted one's `session<id>_*` files.
  ///
  /// Phone only: this reverses decision 8 ("surveys are irreversible field
  /// data") for the device, not for cloud sync, which stays append-only
  /// (`docs/survey-deletion.md`).
  Future<TransectSession?> deleteSession(int sessionId) => _db.transaction((txn) async {
        final rows = await txn.query(
          _sessionsTable,
          where: 'id = ?',
          whereArgs: [sessionId],
        );
        if (rows.isEmpty) return null;
        await txn.rawDelete('''
          DELETE FROM $_pointsTable
          WHERE frame_id IN (SELECT id FROM $_framesTable WHERE session_id = ?)
        ''', [sessionId]);
        await txn.delete(_framesTable, where: 'session_id = ?', whereArgs: [sessionId]);
        await txn.delete(_coverTable, where: 'session_id = ?', whereArgs: [sessionId]);
        await txn.delete(_coloniesTable, where: 'session_id = ?', whereArgs: [sessionId]);
        await txn.delete(_sessionsTable, where: 'id = ?', whereArgs: [sessionId]);
        return TransectSession.fromMap(rows.single);
      });

  Future<List<TrackedColonyRecord>> colonyRowsForSession(
    int sessionId,
  ) async {
    final rows = await _db.query(
      _coloniesTable,
      where: 'session_id = ?',
      whereArgs: [sessionId],
    );
    return rows.map(TrackedColonyRecord.fromMap).toList(growable: false);
  }

  /// Every session, newest-started first, each paired with its colony count
  /// and bleached-colony count -- backs the Surveys (history) tab (sub-plan
  /// 6 step 2). One `LEFT JOIN ... GROUP BY` query rather than N+1: a
  /// session with zero colonies still gets one row out of the join (with
  /// `c.id` null), so `COUNT(c.id)` correctly reads 0 rather than being
  /// skipped. Rows with `ended_at IS NULL` (app killed mid-dive) are
  /// included -- Surveys must list and flag them as incomplete, not hide
  /// them: listing is the only way that data is ever seen again, and the
  /// diver decides whether to keep it ([deleteSession]).
  Future<List<SessionSummary>> listSessions() => _sessionSummaries();

  /// Issue #2: the Surveys tab's **Unassigned** group -- every survey not in
  /// a station (all of them before v11, and quick transects since). Station
  /// transects are listed under their station instead.
  Future<List<SessionSummary>> listUnassignedSessions() =>
      _sessionSummaries(where: 's.station_id IS NULL');

  /// Sub-plan 19 step 2: the latest survey of the same site before
  /// [before], for the Executive tab's "compared with the last survey".
  /// "Same site" is the site name trimmed and case-insensitive for now
  /// (SQLite's `LOWER` folds ASCII only; Cordova's site names are ASCII) --
  /// proper site identity is future work (sub-plan 12). Skips incomplete
  /// sessions (a partial transect isn't comparable) and sessions whose
  /// results are still hidden for a blinded recount (sub-plan 14): showing
  /// their prevalence here would unblind it (`results_hidden` is NULL on
  /// rows from before schema v7, which were never hidden). Issue #3: skips
  /// the other transects of [excludingId]'s own station too -- they are
  /// replicates of one survey, not an earlier one -- and photo/preliminary
  /// station transects, which have no colonies to compare. `null` when [siteName] is
  /// missing or blank, or nothing matches. [before] is compared as a
  /// `DateTime` rather than in SQL because `started_at` strings aren't
  /// stored normalized to UTC.
  Future<SessionSummary?> previousSessionForSite(
    String? siteName, {
    required DateTime before,
    required int excludingId,
  }) async {
    final site = siteName?.trim().toLowerCase() ?? '';
    if (site.isEmpty) return null;
    final candidates = await _sessionSummaries(
      where: '''
        LOWER(TRIM(s.site_name)) = ?
        AND s.ended_at IS NOT NULL
        AND (COALESCE(s.results_hidden, 0) != 1 OR s.results_revealed_at IS NOT NULL)
        AND s.id != ?
        AND (s.station_id IS NULL
             OR (s.station_id IS NOT (SELECT station_id FROM $_sessionsTable WHERE id = ?)
                 AND s.station_id IN (SELECT id FROM $_stationsTable WHERE survey_type = ?)))
      ''',
      whereArgs: [site, excludingId, excludingId, SurveyType.colonyCount.db],
    );
    for (final candidate in candidates) {
      if (candidate.session.startedAt.isBefore(before)) return candidate;
    }
    return null;
  }

  Future<List<SessionSummary>> _sessionSummaries({
    String? where,
    List<Object?> whereArgs = const [],
  }) async {
    final rows = await _db.rawQuery('''
      SELECT s.*,
             COUNT(c.id) AS colony_count,
             SUM(CASE WHEN c.health_label = ? THEN 1 ELSE 0 END) AS bleached_count,
             COUNT(c.health_label) AS classified_count
      FROM $_sessionsTable s
      LEFT JOIN $_coloniesTable c ON c.session_id = s.id
      ${where == null ? '' : 'WHERE $where'}
      GROUP BY s.id
      ORDER BY s.started_at DESC, s.id DESC
    ''', [HealthAggregator.bleachedLabel, ...whereArgs]);

    return rows
        .map(
          (row) => SessionSummary(
            session: TransectSession.fromMap(row),
            colonyCount: (row['colony_count'] as num?)?.toInt() ?? 0,
            bleachedCount: (row['bleached_count'] as num?)?.toInt() ?? 0,
            classifiedCount: (row['classified_count'] as num?)?.toInt() ?? 0,
          ),
        )
        .toList(growable: false);
  }

  // ---------------------------------------------------------------------
  // Schema v11 (issue #1): stations, transect frames, points, category map
  // and cover. Screens arrive in #2 onwards; cover computation in #6.
  // ---------------------------------------------------------------------

  /// A blank code, or a frame mode that doesn't fit the survey type (photo
  /// transects need one; preliminary and colony count must not have one),
  /// is the caller's bug, not a field condition -- thrown, like
  /// [recordRecount]'s checks.
  static Map<String, Object?> _stationRow(Station station) {
    if (station.code.trim().isEmpty) throw ArgumentError('Station code is required');
    if (station.needsFrameMode && station.frameMode == null) {
      throw ArgumentError('A photo-transect station needs a frame mode');
    }
    if (!station.needsFrameMode && station.frameMode != null) {
      throw ArgumentError('Only photo-transect stations have a frame mode');
    }
    return station.toMap()
      ..remove('id')
      ..['code'] = station.code.trim();
  }

  /// `async` so a bad station fails the returned future rather than
  /// throwing before there is one.
  Future<int> insertStation(Station station) async =>
      _db.insert(_stationsTable, _stationRow(station));

  /// Rewrites every column of the station's row. Survey type and frame mode
  /// are rewritten too: blocking that once a station has transects is for
  /// the setup screens (#2) to decide, with the diver in front of them.
  Future<void> updateStation(Station station) async {
    final id = station.id;
    if (id == null) throw ArgumentError('updateStation needs a stored station (id is null)');
    await _db.update(_stationsTable, _stationRow(station), where: 'id = ?', whereArgs: [id]);
  }

  Future<Station?> stationById(int stationId) async {
    final rows = await _db.query(_stationsTable, where: 'id = ?', whereArgs: [stationId]);
    if (rows.isEmpty) return null;
    return Station.fromMap(rows.single);
  }

  /// Every station, newest created first, each with its transect count --
  /// one `LEFT JOIN ... GROUP BY`, like [listSessions].
  Future<List<StationSummary>> listStations() async {
    final rows = await _db.rawQuery('''
      SELECT st.*, COUNT(s.id) AS transect_count
      FROM $_stationsTable st
      LEFT JOIN $_sessionsTable s ON s.station_id = st.id
      GROUP BY st.id
      ORDER BY st.created_at DESC, st.id DESC
    ''');
    return rows
        .map(
          (row) => StationSummary(
            station: Station.fromMap(row),
            transectCount: (row['transect_count'] as num?)?.toInt() ?? 0,
          ),
        )
        .toList(growable: false);
  }

  /// A station's transects, by transect number.
  Future<List<TransectSession>> transectsForStation(int stationId) async {
    final rows = await _db.query(
      _sessionsTable,
      where: 'station_id = ?',
      whereArgs: [stationId],
      orderBy: 'transect_number, id',
    );
    return rows.map(TransectSession.fromMap).toList(growable: false);
  }

  /// Issue #3: a station's transects with their colony counts, keyed by
  /// session id -- the colony-count station screen's per-transect results
  /// (one query, like [listSessions]).
  Future<Map<int, SessionSummary>> colonyResultsForStation(int stationId) async {
    final summaries = await _sessionSummaries(where: 's.station_id = ?', whereArgs: [stationId]);
    return {for (final s in summaries) s.session.id!: s};
  }

  /// One past the station's highest transect number (1 for a new station).
  /// Not a gap-filler: after deleting transect 2 of 1-3 it still says 4, so
  /// numbers already on a datasheet are never reused. The 3-5 limit is the
  /// setup screen's (#2) to enforce.
  Future<int> nextTransectNumber(int stationId) async {
    final rows = await _db.rawQuery(
      'SELECT MAX(transect_number) AS n FROM $_sessionsTable WHERE station_id = ?',
      [stationId],
    );
    return ((rows.single['n'] as num?)?.toInt() ?? 0) + 1;
  }

  /// Moves a transect's cover analysis to [status]. [modelId], [analyzedOn]
  /// and [at] (stored as `analyzed_at`) are written only when given, so
  /// re-queueing a finished transect as `pending` keeps the record of the
  /// last run until a new one replaces it.
  Future<void> setAnalysisStatus(
    int sessionId,
    AnalysisStatus status, {
    String? modelId,
    AnalyzedOn? analyzedOn,
    DateTime? at,
  }) async {
    await _db.update(
      _sessionsTable,
      {
        'analysis_status': status.db,
        'model_id': ?modelId,
        'analyzed_on': ?analyzedOn?.db,
        'analyzed_at': ?at?.toUtc().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [sessionId],
    );
  }

  /// Issue #3: colony count is a research mode reported separately from the
  /// bulletins (alignment doc §10), so its transects never get frames,
  /// points or cover -- nothing downstream can mix them into a station
  /// cover summary. Writing them is the caller's bug: thrown.
  Future<void> _rejectColonyCount(int sessionId, String what) async {
    final rows = await _db.rawQuery('''
      SELECT st.survey_type AS type
      FROM $_sessionsTable s JOIN $_stationsTable st ON st.id = s.station_id
      WHERE s.id = ?
    ''', [sessionId]);
    if (rows.isNotEmpty && rows.single['type'] == SurveyType.colonyCount.db) {
      throw ArgumentError('Colony-count transect $sessionId takes no $what (research mode, #3)');
    }
  }

  /// Throws a [DatabaseException] for a second frame at the same meter mark
  /// of the same transect (`UNIQUE (session_id, meter_mark)`). Video frames
  /// have no meter mark, and NULLs never collide in SQLite. Throws an
  /// [ArgumentError] for a colony-count transect (#3); points need a frame,
  /// so this guards them too.
  Future<int> insertFrame(TransectFrame frame) async {
    await _rejectColonyCount(frame.sessionId, 'frames');
    return _db.insert(_framesTable, frame.toMap()..remove('id'));
  }

  /// Issue #4: saves a photo-transect still (or a missing-meter row) at its
  /// meter mark, replacing whatever was there -- a retake, or a missing
  /// meter photographed after all. The old row's points go with it (they
  /// were scored on the old image), and so does the transect's cached cover,
  /// all in the same transaction, so a failed
  /// insert leaves the meter as it was. Returns the new row's id and the
  /// replaced frame, if any, so the caller can delete its image file.
  ///
  /// Throws [ArgumentError] for a frame with no meter mark (a video frame)
  /// or for a colony-count transect (#3).
  Future<({int id, TransectFrame? replaced})> replaceFrameAtMeter(TransectFrame frame) async {
    final meter = frame.meterMark;
    if (meter == null) throw ArgumentError('A photo-transect frame needs a meter mark');
    await _rejectColonyCount(frame.sessionId, 'frames');
    return _db.transaction((txn) async {
      final rows = await txn.query(
        _framesTable,
        where: 'session_id = ? AND meter_mark = ?',
        whereArgs: [frame.sessionId, meter],
      );
      final replaced = rows.isEmpty ? null : TransectFrame.fromMap(rows.single);
      if (replaced != null) {
        await txn.delete(_pointsTable, where: 'frame_id = ?', whereArgs: [replaced.id]);
        await txn.delete(_framesTable, where: 'id = ?', whereArgs: [replaced.id]);
        // The cached cover (#7) was worked out from the old image's points:
        // stale now, so it goes too and is recomputed on the next analysis.
        await txn.delete(_coverTable, where: 'session_id = ?', whereArgs: [frame.sessionId]);
      }
      final id = await txn.insert(_framesTable, frame.toMap()..remove('id'));
      return (id: id, replaced: replaced);
    });
  }

  /// Along the tape: by meter mark, then video time for preliminary frames.
  Future<List<TransectFrame>> framesForSession(int sessionId) async {
    final rows = await _db.query(
      _framesTable,
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'meter_mark, video_time_ms, id',
    );
    return rows.map(TransectFrame.fromMap).toList(growable: false);
  }

  Future<void> updateFrameCorners(int frameId, List<NormPoint> corners, CornerSource source) async {
    if (corners.length != 4) {
      throw ArgumentError.value(corners.length, 'corners', 'A frame needs exactly 4 corners');
    }
    await _db.update(
      _framesTable,
      {'corners_json': TransectFrame.cornersToJson(corners), 'corner_source': source.db},
      where: 'id = ?',
      whereArgs: [frameId],
    );
  }

  /// Drops a frame from scoring, or brings it back. Bringing it back clears
  /// the reason.
  Future<void> setFrameExcluded(int frameId, {required bool excluded, String? reason}) async {
    await _db.update(
      _framesTable,
      {'excluded': excluded ? 1 : 0, 'exclude_reason': excluded ? reason : null},
      where: 'id = ?',
      whereArgs: [frameId],
    );
  }

  /// Inserts a frame's scoring points in one transaction: all or nothing,
  /// so a duplicate `(frame_id, point_index)` leaves the frame as it was.
  Future<void> insertFramePoints(List<FramePoint> points) async {
    if (points.isEmpty) return;
    await _db.transaction((txn) async {
      final batch = txn.batch();
      for (final point in points) {
        batch.insert(_pointsTable, point.toMap()..remove('id'));
      }
      await batch.commit(noResult: true);
    });
  }

  Future<List<FramePoint>> pointsForFrame(int frameId) async {
    final rows = await _db.query(
      _pointsTable,
      where: 'frame_id = ?',
      whereArgs: [frameId],
      orderBy: 'point_index',
    );
    return rows.map(FramePoint.fromMap).toList(growable: false);
  }

  /// Every point of every frame of a transect, in [framesForSession]'s frame
  /// order -- what the cover calculation (#6) reads. Includes excluded
  /// frames' points; the caller drops them with the frame list.
  Future<List<FramePoint>> pointsForSession(int sessionId) async {
    final rows = await _db.rawQuery('''
      SELECT p.*
      FROM $_pointsTable p
      JOIN $_framesTable f ON f.id = p.frame_id
      WHERE f.session_id = ?
      ORDER BY f.meter_mark, f.video_time_ms, f.id, p.point_index
    ''', [sessionId]);
    return rows.map(FramePoint.fromMap).toList(growable: false);
  }

  /// Stores the model's answer at a point (#6, #7, #12). Overwrites -- a
  /// re-run of the analysis replaces the previous model's label -- but never
  /// touches the expert columns.
  Future<void> setPointModelLabel(
    int pointId, {
    required String? modelClass,
    double? confidence,
    String? categoryCode,
  }) async {
    await _db.update(
      _pointsTable,
      {'model_class': modelClass, 'model_confidence': confidence, 'category_code': categoryCode},
      where: 'id = ?',
      whereArgs: [pointId],
    );
  }

  /// A reviewer's correction (#10). The model's label stays as it was, so
  /// the disagreement is kept for validation (#16) and retraining.
  Future<void> setExpertCategory(
    int pointId,
    String categoryCode, {
    required String by,
    required DateTime at,
  }) async {
    final code = categoryCode.trim();
    final reviewer = by.trim();
    if (code.isEmpty) throw ArgumentError('categoryCode is required');
    if (reviewer.isEmpty) throw ArgumentError('A reviewer name is required');
    await _db.update(
      _pointsTable,
      {
        'expert_category_code': code,
        'expert_name': reviewer,
        'reviewed_at': at.toUtc().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [pointId],
    );
  }

  /// Inserts or replaces mappings by `(model_id, model_class)`, in one
  /// transaction. Seeding the CoralscapesV2 mapping is #6.
  Future<void> upsertCategoryMappings(List<CategoryMapping> mappings) async {
    if (mappings.isEmpty) return;
    await _db.transaction((txn) async {
      final batch = txn.batch();
      for (final mapping in mappings) {
        batch.insert(_categoryMapTable, mapping.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
  }

  /// One model's mapping, by class name. Empty for a model with none yet.
  Future<List<CategoryMapping>> categoryMapFor(String modelId) async {
    final rows = await _db.query(
      _categoryMapTable,
      where: 'model_id = ?',
      whereArgs: [modelId],
      orderBy: 'model_class',
    );
    return rows.map(CategoryMapping.fromMap).toList(growable: false);
  }

  /// Replaces a transect's cached cover with [rows], in one transaction --
  /// a category that's gone from the new result is gone from the cache, not
  /// left over from the last run. Every row must be for [sessionId], and it
  /// must not be a colony-count transect (#3).
  Future<void> replaceTransectCover(int sessionId, List<TransectCoverRow> rows) async {
    for (final row in rows) {
      if (row.sessionId != sessionId) {
        throw ArgumentError('Cover row for session ${row.sessionId} passed for session $sessionId');
      }
    }
    await _rejectColonyCount(sessionId, 'cover');
    await _db.transaction((txn) async {
      await txn.delete(_coverTable, where: 'session_id = ?', whereArgs: [sessionId]);
      final batch = txn.batch();
      for (final row in rows) {
        batch.insert(_coverTable, row.toMap());
      }
      await batch.commit(noResult: true);
    });
  }

  Future<List<TransectCoverRow>> coverForSession(int sessionId) async {
    final rows = await _db.query(
      _coverTable,
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'category_code',
    );
    return rows.map(TransectCoverRow.fromMap).toList(growable: false);
  }

  Future<void> close() => _ignoreClose ? Future.value() : _db.close();

  /// Closes a database opened with `openInMemoryForTest(ignoreClose: true)`.
  Future<void> closeForTest() => _db.close();
}
