import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:reefsight_mobile/services/category_mapping.dart';
import 'package:reefsight_mobile/services/frame_point.dart';
import 'package:reefsight_mobile/services/geo_fix.dart';
import 'package:reefsight_mobile/services/health_aggregator.dart';
import 'package:reefsight_mobile/services/station.dart';
import 'package:reefsight_mobile/services/transect_cover.dart';
import 'package:reefsight_mobile/services/transect_database.dart';
import 'package:reefsight_mobile/services/transect_frame.dart';
import 'package:reefsight_mobile/services/transect_session.dart';
import 'package:sqflite/sqflite.dart' show Database, DatabaseException, openDatabase;

// Issue #1: schema v11 (stations, transect frames, frame points, category
// map, transect cover) -- `docs/reefsight-v2-blueprint.md` §3-5. Real SQLite
// through `sqflite_common_ffi` (test/flutter_test_config.dart). The v1-v10
// migration groups stay in `transect_database_test.dart`.

const _v11Tables = ['stations', 'transect_frames', 'frame_points', 'category_map', 'transect_cover'];

Station _station({
  String code = 'ALG-S1',
  SurveyType type = SurveyType.photoTransect,
  FrameMode? mode = FrameMode.physical,
  DateTime? createdAt,
}) =>
    Station(
      code: code,
      surveyType: type,
      frameMode: mode,
      surveyedOn: DateTime(2026, 11, 15),
      siteName: 'Alegria MPA',
      createdAt: createdAt ?? DateTime.utc(2026, 11, 15, 1),
    );

TransectSession _transect(int? stationId, int? number) => TransectSession(
      startedAt: DateTime.utc(2026, 11, 15, 2),
      tapeLengthMeters: 50,
      stationId: stationId,
      transectNumber: number,
      captureSource: CaptureSource.inAppPhotos,
      pointsPerFrame: 10,
      pointSeed: 42,
    );

TransectFrame _frame(int sessionId, double meter) => TransectFrame(
      sessionId: sessionId,
      meterMark: meter,
      imagePath: 'frames/$sessionId/m$meter.jpg',
      source: FrameSource.inApp,
    );

List<FramePoint> _tenPoints(int frameId) => [
      for (var i = 0; i < 10; i++)
        FramePoint(frameId: frameId, pointIndex: i, xNorm: i / 10, yNorm: 1 - i / 10),
    ];

Future<Set<String>> _tableNames(Database db) async => (await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table'",
    ))
        .map((r) => r['name'] as String)
        .toSet();

/// `PRAGMA table_info` as comparable strings -- order-insensitive, because an
/// upgraded table has its added columns at the end.
Future<Set<String>> _columns(Database db, String table) async =>
    (await db.rawQuery('PRAGMA table_info($table)'))
        .map((r) => '${r['name']} ${r['type']} nn=${r['notnull']} pk=${r['pk']} '
            'default=${r['dflt_value']}')
        .toSet();

void main() {
  group('TransectDatabase schema v11: structure', () {
    late Directory dir;

    setUp(() async => dir = await Directory.systemTemp.createTemp('reefsight_v11_'));
    tearDown(() => dir.delete(recursive: true));

    test('a fresh install has the v11 tables and the station/transect index', () async {
      final db = await TransectDatabase.open(dir.path);
      await db.close();

      final raw = await openDatabase(p.join(dir.path, 'reefsight.db'), singleInstance: false);
      addTearDown(raw.close);
      expect((await raw.rawQuery('PRAGMA user_version')).single.values.single, 12);
      expect(await _tableNames(raw), containsAll(_v11Tables));
      expect(await _tableNames(raw), isNot(contains('genus_tags')));
      expect(await _tableNames(raw), isNot(contains('drive_uploads')));
      final index = await raw.rawQuery(
        "SELECT sql FROM sqlite_master WHERE name = 'idx_sessions_station_transect'",
      );
      expect(index.single['sql'], contains('WHERE station_id IS NOT NULL'));
    });

    test('a v10 file upgrades: old sessions and colonies read back unchanged', () async {
      final path = p.join(dir.path, 'reefsight.db');
      final v10 = await openDatabase(
        path,
        version: 10,
        singleInstance: false,
        onCreate: (db, version) => _createV10Schema(db),
      );
      final sessionId = await v10.insert('transect_sessions', {
        'started_at': DateTime.utc(2026, 10, 4, 1).toIso8601String(),
        'ended_at': DateTime.utc(2026, 10, 4, 2).toIso8601String(),
        'tape_length_meters': 20.0,
        'belt_width_meters': 1.0,
        'site_name': 'Alegria MPA',
        'observer_name': 'C. Zaballa',
        'results_hidden': 0,
        'crop_style': 'boxStretch',
      });
      await v10.insert('tracked_colonies', {
        'session_id': sessionId,
        'track_id': 1,
        'health_label': HealthAggregator.bleachedLabel,
        'health_history': '[]',
        'first_seen_at': DateTime.utc(2026, 10, 4, 1, 5).toIso8601String(),
        'last_seen_at': DateTime.utc(2026, 10, 4, 1, 6).toIso8601String(),
      });
      await v10.close();

      final db = await TransectDatabase.open(dir.path);
      addTearDown(db.close);

      final session = (await db.sessionById(sessionId))!;
      expect(session.siteName, 'Alegria MPA');
      expect(session.tapeLengthMeters, 20);
      expect(session.endedAt, DateTime.utc(2026, 10, 4, 2));
      expect(session.stationId, isNull);
      expect(session.transectNumber, isNull);
      expect(session.captureSource, isNull);
      expect(session.depthStartM, isNull);
      expect(session.pointsPerFrame, isNull);
      expect(session.pointSeed, isNull);
      expect(session.analysisStatus, isNull);
      expect(session.modelId, isNull);
      expect(session.analyzedOn, isNull);

      final summaries = await db.listSessions();
      expect(summaries.single.colonyCount, 1);
      expect(summaries.single.bleachedCount, 1);
      expect((await db.colonyRowsForSession(sessionId)).single.trackId, 1);
      expect(await db.framesForSession(sessionId), isEmpty);
      expect(await db.coverForSession(sessionId), isEmpty);
      expect(await db.listStations(), isEmpty);

      // The old survey can still be deleted after the upgrade.
      expect(await db.deleteSession(sessionId), isNotNull);
    });

    test('an upgraded v10 file has the same schema as a fresh install', () async {
      final freshDir = await Directory.systemTemp.createTemp('reefsight_v11_fresh_');
      addTearDown(() => freshDir.delete(recursive: true));
      await (await TransectDatabase.open(freshDir.path)).close();

      final v10 = await openDatabase(
        p.join(dir.path, 'reefsight.db'),
        version: 10,
        singleInstance: false,
        onCreate: (db, version) => _createV10Schema(db),
      );
      await v10.close();
      await (await TransectDatabase.open(dir.path)).close();

      final fresh = await openDatabase(p.join(freshDir.path, 'reefsight.db'), singleInstance: false);
      addTearDown(fresh.close);
      final upgraded = await openDatabase(p.join(dir.path, 'reefsight.db'), singleInstance: false);
      addTearDown(upgraded.close);

      expect(await _tableNames(upgraded), await _tableNames(fresh));
      for (final table in ['transect_sessions', 'tracked_colonies', ..._v11Tables]) {
        expect(await _columns(upgraded, table), await _columns(fresh, table), reason: table);
      }
    });
  });

  group('TransectDatabase schema v11: constraints', () {
    late TransectDatabase db;

    setUp(() async => db = await TransectDatabase.openInMemoryForTest());
    tearDown(() => db.close());

    test('a transect number is unique within a station only', () async {
      final a = await db.insertStation(_station(code: 'A'));
      final b = await db.insertStation(_station(code: 'B'));
      await db.insertSession(_transect(a, 1));
      await db.insertSession(_transect(b, 1));
      await expectLater(db.insertSession(_transect(a, 1)), throwsA(isA<DatabaseException>()));
    });

    test('sessions without a station may share (null) transect numbers', () async {
      await db.insertSession(_transect(null, null));
      await db.insertSession(_transect(null, null));
      await db.insertSession(_transect(null, 1));
      await db.insertSession(_transect(null, 1));
      expect(await db.listSessions(), hasLength(4));
    });

    test('a station transect without a number is rejected', () async {
      final station = await db.insertStation(_station());
      await expectLater(db.insertSession(_transect(station, null)), throwsArgumentError);
    });

    test('a transect must point at an existing station', () async {
      await expectLater(db.insertSession(_transect(999, 1)), throwsA(isA<DatabaseException>()));
    });

    test('one frame per meter mark per transect', () async {
      final station = await db.insertStation(_station());
      final session = await db.insertSession(_transect(station, 1));
      await db.insertFrame(_frame(session, 3));
      await expectLater(db.insertFrame(_frame(session, 3)), throwsA(isA<DatabaseException>()));
    });

    test('preliminary frames (no meter mark) are not limited by that rule', () async {
      final station = await db.insertStation(
        _station(type: SurveyType.preliminaryVideo, mode: null),
      );
      final session = await db.insertSession(_transect(station, 1));
      for (final ms in [0, 2000, 4000]) {
        await db.insertFrame(
          TransectFrame(
            sessionId: session,
            videoTimeMs: ms,
            imagePath: 'v/$ms.jpg',
            source: FrameSource.videoFrame,
          ),
        );
      }
      expect(await db.framesForSession(session), hasLength(3));
    });

    test('one point per index per frame', () async {
      final station = await db.insertStation(_station());
      final session = await db.insertSession(_transect(station, 1));
      final frame = await db.insertFrame(_frame(session, 0));
      await db.insertFramePoints(_tenPoints(frame));
      await expectLater(
        db.insertFramePoints([FramePoint(frameId: frame, pointIndex: 0, xNorm: 0.5, yNorm: 0.5)]),
        throwsA(isA<DatabaseException>()),
      );
      // All-or-nothing: the failed batch added nothing.
      expect(await db.pointsForFrame(frame), hasLength(10));
    });

    test('the bulletin CHECK constraints reject unknown values in raw SQL', () async {
      // The Dart enums can't produce these, so go through a raw handle.
      final dir = await Directory.systemTemp.createTemp('reefsight_v11_check_');
      addTearDown(() => dir.delete(recursive: true));
      await (await TransectDatabase.open(dir.path)).close();
      final raw = await openDatabase(p.join(dir.path, 'reefsight.db'), singleInstance: false);
      addTearDown(raw.close);

      await expectLater(
        raw.insert('stations', {
          'code': 'X',
          'survey_type': 'manta_tow',
          'surveyed_on': '2026-11-15',
          'created_at': '2026-11-15T00:00:00.000Z',
        }),
        throwsA(isA<DatabaseException>()),
      );
      await expectLater(
        raw.insert('stations', {
          'code': 'X',
          'survey_type': 'photo_transect',
          'frame_mode': 'drone',
          'surveyed_on': '2026-11-15',
          'created_at': '2026-11-15T00:00:00.000Z',
        }),
        throwsA(isA<DatabaseException>()),
      );
    });
  });

  group('TransectDatabase stations', () {
    late TransectDatabase db;

    setUp(() async => db = await TransectDatabase.openInMemoryForTest());
    tearDown(() => db.close());

    test('insertStation and stationById round-trip, including the deep-edge fix', () async {
      final fix = GeoFix(
        lat: 10.25,
        lon: 123.95,
        accuracyM: 5,
        at: DateTime.utc(2026, 11, 15, 1),
        source: GeoFixSource.gps,
      );
      final id = await db.insertStation(
        Station(
          code: 'ALG-S1',
          surveyType: SurveyType.photoTransect,
          frameMode: FrameMode.virtual,
          surveyedOn: DateTime(2026, 11, 15),
          reefZone: ReefZone.reefCrest,
          deepEdgeFix: fix,
          markerPlaced: false,
          createdAt: DateTime.utc(2026, 11, 15),
        ),
      );
      final back = (await db.stationById(id))!;
      expect(back.id, id);
      expect(back.frameMode, FrameMode.virtual);
      expect(back.reefZone, ReefZone.reefCrest);
      expect(back.deepEdgeFix, fix);
      expect(back.markerPlaced, isFalse);
      expect(await db.stationById(id + 1), isNull);
    });

    test('a blank code is rejected', () async {
      await expectLater(db.insertStation(_station(code: '  ')), throwsArgumentError);
    });

    test('photo transects need a frame mode; the other types must not have one', () async {
      await expectLater(db.insertStation(_station(mode: null)), throwsArgumentError);
      await expectLater(
        db.insertStation(_station(type: SurveyType.colonyCount, mode: FrameMode.physical)),
        throwsArgumentError,
      );
      expect(await db.insertStation(_station(type: SurveyType.colonyCount, mode: null)), isPositive);
    });

    test('updateStation rewrites the row', () async {
      final id = await db.insertStation(_station());
      final stored = (await db.stationById(id))!;
      await db.updateStation(stored.copyWith(notes: 'Strong current', depthMaxM: 6.5));
      final back = (await db.stationById(id))!;
      expect(back.notes, 'Strong current');
      expect(back.depthMaxM, 6.5);
      expect(back.code, 'ALG-S1');
    });

    test('updateStation without an id is rejected', () async {
      await expectLater(db.updateStation(_station()), throwsArgumentError);
    });

    test('listStations is newest first, with a transect count', () async {
      final older = await db.insertStation(_station(code: 'OLD', createdAt: DateTime.utc(2026, 11, 1)));
      final newer = await db.insertStation(_station(code: 'NEW', createdAt: DateTime.utc(2026, 11, 15)));
      await db.insertSession(_transect(older, 1));
      await db.insertSession(_transect(older, 2));
      await db.insertSession(_transect(null, null)); // a legacy survey, no station

      final list = await db.listStations();
      expect(list.map((s) => s.station.id), [newer, older]);
      expect(list.map((s) => s.transectCount), [0, 2]);
    });
  });

  group('TransectDatabase transects', () {
    late TransectDatabase db;
    late int station;

    setUp(() async {
      db = await TransectDatabase.openInMemoryForTest();
      station = await db.insertStation(_station());
    });
    tearDown(() => db.close());

    test('transectsForStation is ordered by transect number', () async {
      await db.insertSession(_transect(station, 3));
      await db.insertSession(_transect(station, 1));
      await db.insertSession(_transect(null, null));
      final list = await db.transectsForStation(station);
      expect(list.map((t) => t.transectNumber), [1, 3]);
      expect(list.first.pointSeed, 42);
    });

    test('listUnassignedSessions has only the surveys without a station (#2)', () async {
      await db.insertSession(_transect(station, 1));
      final loose = await db.insertSession(_transect(null, null));
      final unassigned = await db.listUnassignedSessions();
      expect(unassigned.map((s) => s.session.id), [loose]);
      expect((await db.listSessions()).length, 2);
    });

    test('ignoreClose: close() is a no-op, closeForTest() really closes', () async {
      final shared = await TransectDatabase.openInMemoryForTest(ignoreClose: true);
      await shared.close();
      expect(await shared.listStations(), isEmpty);
      await shared.closeForTest();
      expect(shared.listStations(), throwsA(anything));
    });

    test('nextTransectNumber is one past the highest used', () async {
      expect(await db.nextTransectNumber(station), 1);
      await db.insertSession(_transect(station, 1));
      await db.insertSession(_transect(station, 3));
      expect(await db.nextTransectNumber(station), 4);
    });

    test('setAnalysisStatus records the model and when it finished', () async {
      final id = await db.insertSession(_transect(station, 1));
      await db.setAnalysisStatus(id, AnalysisStatus.running);
      expect((await db.sessionById(id))!.analysisStatus, AnalysisStatus.running);

      await db.setAnalysisStatus(
        id,
        AnalysisStatus.done,
        modelId: 'coralscapesv2-segformer-b5',
        analyzedOn: AnalyzedOn.laptop,
        at: DateTime.utc(2026, 11, 16, 9),
      );
      final done = (await db.sessionById(id))!;
      expect(done.analysisStatus, AnalysisStatus.done);
      expect(done.modelId, 'coralscapesv2-segformer-b5');
      expect(done.analyzedOn, AnalyzedOn.laptop);
      expect(done.analyzedAt, DateTime.utc(2026, 11, 16, 9));
    });

    test('setAnalysisStatus leaves the model fields alone when not given', () async {
      final id = await db.insertSession(_transect(station, 1));
      await db.setAnalysisStatus(
        id,
        AnalysisStatus.done,
        modelId: 'm1',
        analyzedOn: AnalyzedOn.phone,
        at: DateTime.utc(2026, 11, 16),
      );
      await db.setAnalysisStatus(id, AnalysisStatus.pending);
      final back = (await db.sessionById(id))!;
      expect(back.analysisStatus, AnalysisStatus.pending);
      expect(back.modelId, 'm1');
      expect(back.analyzedOn, AnalyzedOn.phone);
    });
  });

  group('TransectDatabase frames and points', () {
    late TransectDatabase db;
    late int session;

    setUp(() async {
      db = await TransectDatabase.openInMemoryForTest();
      session = await db.insertSession(_transect(await db.insertStation(_station()), 1));
    });
    tearDown(() => db.close());

    test('framesForSession is ordered by meter mark', () async {
      await db.insertFrame(_frame(session, 10));
      await db.insertFrame(_frame(session, 0));
      await db.insertFrame(_frame(session, 5));
      final frames = await db.framesForSession(session);
      expect(frames.map((f) => f.meterMark), [0, 5, 10]);
      expect(frames.first.id, isNotNull);
    });

    test('updateFrameCorners and setFrameExcluded', () async {
      final id = await db.insertFrame(_frame(session, 0));
      const corners = [(x: 0.0, y: 0.0), (x: 1.0, y: 0.0), (x: 1.0, y: 1.0), (x: 0.0, y: 1.0)];
      await db.updateFrameCorners(id, corners, CornerSource.copied);
      await db.setFrameExcluded(id, excluded: true, reason: 'frame not visible');

      var frame = (await db.framesForSession(session)).single;
      expect(frame.corners, corners);
      expect(frame.cornerSource, CornerSource.copied);
      expect(frame.excluded, isTrue);
      expect(frame.excludeReason, 'frame not visible');

      await db.setFrameExcluded(id, excluded: false);
      frame = (await db.framesForSession(session)).single;
      expect(frame.excluded, isFalse);
      expect(frame.excludeReason, isNull);
    });

    test('pointsForSession returns every point of every frame, in order', () async {
      final f2 = await db.insertFrame(_frame(session, 2));
      final f1 = await db.insertFrame(_frame(session, 1));
      await db.insertFramePoints(_tenPoints(f2));
      await db.insertFramePoints(_tenPoints(f1));

      final points = await db.pointsForSession(session);
      expect(points, hasLength(20));
      expect(points.take(10).every((pt) => pt.frameId == f1), isTrue);
      expect(points.take(10).map((pt) => pt.pointIndex), List.generate(10, (i) => i));
      expect((await db.pointsForFrame(f2)).map((pt) => pt.pointIndex), List.generate(10, (i) => i));
    });

    test('model labels and expert corrections are stored separately', () async {
      final frame = await db.insertFrame(_frame(session, 0));
      await db.insertFramePoints(_tenPoints(frame));
      final point = (await db.pointsForFrame(frame)).first;

      await db.setPointModelLabel(
        point.id!,
        modelClass: 'branching bleached',
        confidence: 0.8,
        categoryCode: 'BLEC',
      );
      await db.setExpertCategory(point.id!, 'CB', by: 'J. Reviewer', at: DateTime.utc(2026, 11, 20));

      final back = (await db.pointsForFrame(frame)).first;
      expect(back.modelClass, 'branching bleached');
      expect(back.modelConfidence, 0.8);
      expect(back.categoryCode, 'BLEC');
      expect(back.expertCategoryCode, 'CB');
      expect(back.expertName, 'J. Reviewer');
      expect(back.reviewedAt, DateTime.utc(2026, 11, 20));
      expect(back.effectiveCategoryCode, 'CB');
    });

    test('an expert correction needs a reviewer name', () async {
      final frame = await db.insertFrame(_frame(session, 0));
      await db.insertFramePoints(_tenPoints(frame));
      final point = (await db.pointsForFrame(frame)).first;
      await expectLater(
        db.setExpertCategory(point.id!, 'CB', by: ' ', at: DateTime.utc(2026, 11, 20)),
        throwsArgumentError,
      );
    });
  });

  group('TransectDatabase category map and cover', () {
    late TransectDatabase db;
    late int session;

    setUp(() async {
      db = await TransectDatabase.openInMemoryForTest();
      session = await db.insertSession(_transect(await db.insertStation(_station()), 1));
    });
    tearDown(() => db.close());

    test('category mappings are versioned by model and upsert', () async {
      await db.upsertCategoryMappings(const [
        CategoryMapping(modelId: 'm1', modelClass: 'sand', categoryCode: 'S', majorCategory: 'AB'),
        CategoryMapping(modelId: 'm1', modelClass: 'tape', categoryCode: 'TWB', majorCategory: 'TWB'),
        CategoryMapping(modelId: 'm2', modelClass: 'sand', categoryCode: 'S', majorCategory: 'AB'),
      ]);
      await db.upsertCategoryMappings(const [
        CategoryMapping(
          modelId: 'm1',
          modelClass: 'tape',
          categoryCode: 'TWB',
          majorCategory: 'TWB',
          excluded: true,
        ),
      ]);

      final m1 = await db.categoryMapFor('m1');
      expect(m1, hasLength(2));
      expect(m1.firstWhere((m) => m.modelClass == 'tape').excluded, isTrue);
      expect(await db.categoryMapFor('m2'), hasLength(1));
      expect(await db.categoryMapFor('unknown'), isEmpty);
    });

    test('replaceTransectCover replaces rather than adds', () async {
      await db.replaceTransectCover(session, [
        TransectCoverRow(sessionId: session, categoryCode: 'HC', points: 100, totalPoints: 400, percent: 25),
        TransectCoverRow(sessionId: session, categoryCode: 'S', points: 300, totalPoints: 400, percent: 75),
      ]);
      await db.replaceTransectCover(session, [
        TransectCoverRow(
          sessionId: session,
          categoryCode: 'HC',
          points: 120,
          totalPoints: 400,
          percent: 30,
          usesExpert: true,
        ),
      ]);
      final cover = await db.coverForSession(session);
      expect(cover.single.categoryCode, 'HC');
      expect(cover.single.percent, 30);
      expect(cover.single.usesExpert, isTrue);
    });

    test('replaceTransectCover rejects rows for another session', () async {
      await expectLater(
        db.replaceTransectCover(session, [
          TransectCoverRow(sessionId: session + 1, categoryCode: 'HC', points: 1, totalPoints: 1, percent: 100),
        ]),
        throwsArgumentError,
      );
    });
  });

  // Issue #3: colony count is a research mode, reported separately -- its
  // transects never get bulletin frames or cover, so nothing can mix them
  // into a station cover summary (alignment doc §10).
  group('TransectDatabase colony-count transects (#3)', () {
    late TransectDatabase db;
    late int colony;

    setUp(() async {
      db = await TransectDatabase.openInMemoryForTest();
      final station = await db.insertStation(_station(type: SurveyType.colonyCount, mode: null));
      colony = await db.insertSession(
        _transect(station, 1).copyWith(captureSource: CaptureSource.legacyColony),
      );
    });
    tearDown(() => db.close());

    test('take no cover rows', () async {
      await expectLater(
        db.replaceTransectCover(colony, [
          TransectCoverRow(sessionId: colony, categoryCode: 'HC', points: 1, totalPoints: 10, percent: 10),
        ]),
        throwsArgumentError,
      );
      expect(await db.coverForSession(colony), isEmpty);
    });

    test('take no frames (so no points either)', () async {
      await expectLater(db.insertFrame(_frame(colony, 0)), throwsArgumentError);
      expect(await db.framesForSession(colony), isEmpty);
    });

    test('photo transects and station-less sessions still take frames and cover', () async {
      final photo = await db.insertSession(_transect(await db.insertStation(_station(code: 'P1')), 1));
      final quick = await db.insertSession(_transect(null, null));
      for (final id in [photo, quick]) {
        await db.insertFrame(_frame(id, 0));
        await db.replaceTransectCover(id, [
          TransectCoverRow(sessionId: id, categoryCode: 'HC', points: 1, totalPoints: 10, percent: 10),
        ]);
        expect(await db.coverForSession(id), hasLength(1));
      }
    });
  });

  // Issue #3: transects of one station are replicates, not repeat surveys,
  // so the Executive tab never compares T2 with T1 of the same station.
  group('TransectDatabase.previousSessionForSite with stations (#3)', () {
    late TransectDatabase db;

    setUp(() async => db = await TransectDatabase.openInMemoryForTest());
    tearDown(() => db.close());

    Future<int> ended(int? station, int? number, DateTime at) async {
      final id = await db.insertSession(
        _transect(station, number).copyWith(startedAt: at, siteName: 'Alegria MPA'),
      );
      await db.closeSession(id, at.add(const Duration(minutes: 40)));
      return id;
    }

    test('skips earlier transects of the same station', () async {
      final oct = await ended(null, null, DateTime.utc(2026, 10, 4, 2));
      final station = await db.insertStation(_station(type: SurveyType.colonyCount, mode: null));
      await ended(station, 1, DateTime.utc(2026, 11, 15, 2));
      final t2At = DateTime.utc(2026, 11, 15, 3);
      final t2 = await ended(station, 2, t2At);

      final previous = await db.previousSessionForSite('Alegria MPA', before: t2At, excludingId: t2);

      expect(previous?.session.id, oct);
    });

    // Review fix: a photo or preliminary transect has no colonies, so a
    // colony transect compared with it would read "down from 0 colonies".
    test('never compares with a photo or preliminary station transect', () async {
      final photo = await db.insertStation(_station(code: 'P1'));
      final quick = await ended(null, null, DateTime.utc(2026, 10, 1, 2));
      await ended(photo, 1, DateTime.utc(2026, 10, 4, 2));
      final colony = await db.insertStation(_station(code: 'C1', type: SurveyType.colonyCount, mode: null));
      final at = DateTime.utc(2026, 11, 15, 2);
      final current = await ended(colony, 1, at);

      final previous = await db.previousSessionForSite('Alegria MPA', before: at, excludingId: current);

      expect(previous?.session.id, quick);
    });

    test('still finds a transect of another station', () async {
      final s1 = await db.insertStation(_station(code: 'S1', type: SurveyType.colonyCount, mode: null));
      final s2 = await db.insertStation(_station(code: 'S2', type: SurveyType.colonyCount, mode: null));
      final other = await ended(s1, 1, DateTime.utc(2026, 10, 4, 2));
      final at = DateTime.utc(2026, 11, 15, 2);
      final current = await ended(s2, 1, at);

      final previous = await db.previousSessionForSite('Alegria MPA', before: at, excludingId: current);

      expect(previous?.session.id, other);
    });

    test('a quick transect still compares with an earlier station transect', () async {
      final station = await db.insertStation(_station(type: SurveyType.colonyCount, mode: null));
      final t1 = await ended(station, 1, DateTime.utc(2026, 11, 15, 2));
      final at = DateTime.utc(2026, 11, 15, 4);
      final quick = await ended(null, null, at);

      final previous = await db.previousSessionForSite('Alegria MPA', before: at, excludingId: quick);

      expect(previous?.session.id, t1);
    });
  });

  group('TransectDatabase.deleteSession with v11 rows', () {
    test('removes the transect\'s frames, points and cover too', () async {
      final db = await TransectDatabase.openInMemoryForTest();
      addTearDown(db.close);
      final station = await db.insertStation(_station());
      final keep = await db.insertSession(_transect(station, 1));
      final drop = await db.insertSession(_transect(station, 2));
      for (final id in [keep, drop]) {
        final frame = await db.insertFrame(_frame(id, 0));
        await db.insertFramePoints(_tenPoints(frame));
        await db.replaceTransectCover(id, [
          TransectCoverRow(sessionId: id, categoryCode: 'HC', points: 2, totalPoints: 10, percent: 20),
        ]);
      }

      expect(await db.deleteSession(drop), isNotNull);

      expect(await db.sessionById(drop), isNull);
      expect(await db.framesForSession(drop), isEmpty);
      expect(await db.pointsForSession(drop), isEmpty);
      expect(await db.coverForSession(drop), isEmpty);
      // The station and its other transect are untouched.
      expect(await db.stationById(station), isNotNull);
      expect(await db.pointsForSession(keep), hasLength(10));
      expect(await db.coverForSession(keep), hasLength(1));
      expect(await db.nextTransectNumber(station), 2);
    });
  });
}

/// The exact v10 schema (`transect_database.dart` before issue #1), frozen
/// here so the upgrade test starts from a real v10 file, not today's
/// `_createSchema`.
Future<void> _createV10Schema(Database db) async {
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
      video_started_at TEXT,
      last_checkpoint_at TEXT,
      interruption_count INTEGER,
      first_interrupted_at TEXT,
      last_interrupted_at TEXT,
      thermal_peak TEXT,
      thermal_rise_count INTEGER,
      entry_lat REAL,
      entry_lon REAL,
      entry_accuracy_m REAL,
      entry_at TEXT,
      entry_source TEXT,
      exit_lat REAL,
      exit_lon REAL,
      exit_accuracy_m REAL,
      exit_at TEXT,
      exit_source TEXT,
      results_hidden INTEGER,
      results_revealed_at TEXT,
      recount_total INTEGER,
      recount_bleached INTEGER,
      recount_by TEXT,
      recount_at TEXT,
      recount_blinded INTEGER,
      crop_style TEXT,
      threshold_seg_floor REAL,
      threshold_min_coverage REAL,
      threshold_conf_floor REAL,
      threshold_min_samples INTEGER
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
      photo_path TEXT,
      photo_crop_path TEXT,
      photo_label TEXT,
      photo_confidence REAL,
      UNIQUE(session_id, track_id)
    )
  ''');
}
