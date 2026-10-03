import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'device_checks.dart';
import 'geo_fix.dart';
import 'health_aggregator.dart';
import 'session_summary.dart';
import 'tracked_colony_record.dart';
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
  TransectDatabase._(this._db);

  final Database _db;

  static const _sessionsTable = 'transect_sessions';
  static const _coloniesTable = 'tracked_colonies';

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
  static const _schemaVersion = 10;

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
  static Future<TransectDatabase> openInMemoryForTest() async {
    final db = await openDatabase(
      inMemoryDatabasePath,
      version: _schemaVersion,
      singleInstance: false,
      onCreate: (db, version) => _createSchema(db),
      onOpen: (db) => db.execute('PRAGMA foreign_keys = ON'),
    );
    return TransectDatabase._(db);
  }

  static Future<void> _createSchema(Database db) async {
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
        ${_settingsColumns.join(',\n        ')}
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
  }

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

  Future<int> insertSession(TransectSession session) async {
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

  /// Deletes a survey from this phone: its colony rows, then the session row,
  /// in one transaction (`tracked_colonies.session_id` has no `ON DELETE
  /// CASCADE`, and foreign keys are on). Returns the deleted session, so
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

  /// Sub-plan 19 step 2: the latest survey of the same site before
  /// [before], for the Executive tab's "compared with the last survey".
  /// "Same site" is the site name trimmed and case-insensitive for now
  /// (SQLite's `LOWER` folds ASCII only; Cordova's site names are ASCII) --
  /// proper site identity is future work (sub-plan 12). Skips incomplete
  /// sessions (a partial transect isn't comparable) and sessions whose
  /// results are still hidden for a blinded recount (sub-plan 14): showing
  /// their prevalence here would unblind it (`results_hidden` is NULL on
  /// rows from before schema v7, which were never hidden). `null` when [siteName] is
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
      ''',
      whereArgs: [site, excludingId],
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

  Future<void> close() => _db.close();
}
