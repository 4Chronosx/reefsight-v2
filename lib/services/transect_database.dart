import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

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

  static Future<TransectDatabase> open(String directory) async {
    final db = await openDatabase(
      p.join(directory, 'reefsight.db'),
      version: 1,
      onCreate: (db, version) => _createSchema(db),
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
      version: 1,
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
        belt_width_meters REAL NOT NULL
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
        UNIQUE(session_id, track_id)
      )
    ''');
  }

  Future<int> insertSession(TransectSession session) async {
    final map = session.toMap()..remove('id');
    return _db.insert(_sessionsTable, map);
  }

  Future<void> closeSession(int sessionId, DateTime endedAt) async {
    await _db.update(
      _sessionsTable,
      {'ended_at': endedAt.toIso8601String()},
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

  Future<void> close() => _db.close();
}
