import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:reefsight_mobile/services/category_mapping.dart';
import 'package:reefsight_mobile/services/coralscapes_mapping.dart';
import 'package:reefsight_mobile/services/frame_point.dart';
import 'package:reefsight_mobile/services/point_sampler.dart';
import 'package:reefsight_mobile/services/station.dart';
import 'package:reefsight_mobile/services/transect_cover.dart';
import 'package:reefsight_mobile/services/transect_database.dart';
import 'package:reefsight_mobile/services/transect_frame.dart';
import 'package:reefsight_mobile/services/transect_session.dart';
import 'package:sqflite/sqflite.dart' show openDatabase;

// Issue #6 in the database: schema v12's cover level, the seeded
// CoralscapesV2 mapping (and re-mapping when it changes), seeded point
// sampling, and the cover cache that every scoring change drops and
// `refreshTransectCover` rebuilds. Real SQLite (test/flutter_test_config.dart).

const _corners = <NormPoint>[(x: 0.1, y: 0.1), (x: 0.9, y: 0.1), (x: 0.9, y: 0.9), (x: 0.1, y: 0.9)];

Station _station({SurveyType type = SurveyType.photoTransect}) => Station(
      code: 'ALG-S1',
      surveyType: type,
      frameMode: type == SurveyType.photoTransect ? FrameMode.physical : null,
      surveyedOn: DateTime(2026, 11, 15),
      siteName: 'Alegria MPA',
      createdAt: DateTime.utc(2026, 11, 15, 1),
    );

TransectSession _transect(int stationId, {int? seed, String? modelId = kCoralscapesModelId}) => TransectSession(
      startedAt: DateTime.utc(2026, 11, 15, 2),
      tapeLengthMeters: 50,
      stationId: stationId,
      transectNumber: 1,
      captureSource: CaptureSource.inAppPhotos,
      pointsPerFrame: 10,
      pointSeed: seed,
      modelId: modelId,
    );

TransectFrame _frame(int sessionId, double meter, {List<NormPoint>? corners = _corners, bool excluded = false}) =>
    TransectFrame(
      sessionId: sessionId,
      meterMark: meter,
      imagePath: 'frames/$sessionId/m$meter.jpg',
      source: FrameSource.inApp,
      corners: corners,
      cornerSource: corners == null ? null : CornerSource.manual,
      excluded: excluded,
    );

void main() {
  group('schema v12', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('reefsight_v12_'));
    tearDown(() => dir.delete(recursive: true));

    test('a fresh install has the cover level in the key (v12)', () async {
      await (await TransectDatabase.open(dir.path)).close();
      final raw = await openDatabase(p.join(dir.path, 'reefsight.db'), singleInstance: false);
      addTearDown(raw.close);
      expect((await raw.rawQuery('PRAGMA user_version')).single.values.single, 13);
      final columns = {for (final r in await raw.rawQuery('PRAGMA table_info(transect_cover)')) r['name']: r['pk']};
      expect(columns['level'], isNot(0));
      expect(columns['category_code'], isNot(0));
    });

    test('a v11 file upgrades: the old cover cache is dropped and rebuilt with a level', () async {
      final path = p.join(dir.path, 'reefsight.db');
      await (await TransectDatabase.open(dir.path)).close();
      // Turn the file back into a v11 one, with a v11-shaped cover row.
      final raw = await openDatabase(path, singleInstance: false);
      await raw.execute('DROP INDEX idx_genus_tags_tape');
      await raw.execute('DROP TABLE genus_tags');
      await raw.execute('DROP TABLE transect_cover');
      await raw.execute('''
        CREATE TABLE transect_cover (
          session_id INTEGER NOT NULL REFERENCES transect_sessions(id),
          category_code TEXT NOT NULL, points INTEGER NOT NULL, total_points INTEGER NOT NULL,
          percent REAL NOT NULL, uses_expert INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (session_id, category_code))
      ''');
      await raw.insert('transect_sessions', {'started_at': '2026-11-15T02:00:00Z', 'tape_length_meters': 50, 'belt_width_meters': 1});
      await raw.insert('transect_cover', {'session_id': 1, 'category_code': 'HC', 'points': 1, 'total_points': 2, 'percent': 50});
      await raw.execute('PRAGMA user_version = 11');
      await raw.close();

      final db = await TransectDatabase.open(dir.path);
      addTearDown(db.close);
      expect(await db.coverForSession(1), isEmpty);
      await db.replaceTransectCover(1, [
        TransectCoverRow(sessionId: 1, categoryCode: 'DC', level: CoverLevel.code, points: 1, totalPoints: 4, percent: 25),
        TransectCoverRow(sessionId: 1, categoryCode: 'DC', level: CoverLevel.major, points: 2, totalPoints: 4, percent: 50),
      ]);
      expect(await db.coverForSession(1), hasLength(2));
    });
  });

  group('category map seeding', () {
    late TransectDatabase db;
    setUp(() async => db = await TransectDatabase.openInMemoryForTest());
    tearDown(() => db.close());

    test('the CoralscapesV2 mapping is there on open', () async {
      final map = await db.categoryMapFor(kCoralscapesModelId);
      expect(map, hasLength(40));
      expect(map.toSet(), coralscapesMapping().toSet());
    });

    test('seeding the same mapping again changes nothing', () async {
      expect(await db.seedCategoryMap(kCoralscapesModelId, coralscapesMapping()), isFalse);
    });

    test('a changed mapping re-maps that model\'s points and drops their cover', () async {
      final station = await db.insertStation(_station());
      final mine = await db.insertSession(_transect(station));
      final frame = await db.insertFrame(_frame(mine, 0));
      await db.ensureFramePoints(mine);
      final points = await db.pointsForFrame(frame);
      for (final pt in points) {
        await db.setPointModelLabel(pt.id!, modelClass: 'turbinaria', confidence: 0.9, categoryCode: 'HCX');
      }
      await db.refreshTransectCover(mine);
      expect(await db.coverForSession(mine), isNotEmpty);

      final revised = [
        for (final m in coralscapesMapping())
          m.modelClass == 'turbinaria'
              ? CategoryMapping(modelId: m.modelId, modelClass: m.modelClass, categoryCode: 'CF', majorCategory: 'HC')
              : m,
      ];
      expect(await db.seedCategoryMap(kCoralscapesModelId, revised), isTrue);

      expect((await db.pointsForFrame(frame)).map((pt) => pt.categoryCode).toSet(), {'CF'});
      expect(await db.coverForSession(mine), isEmpty);
      expect((await db.categoryMapFor(kCoralscapesModelId)).singleWhere((m) => m.modelClass == 'turbinaria').categoryCode,
          'CF');
    });

    test('a class dropped from the mapping is gone, and its points are unlabeled again', () async {
      final station = await db.insertStation(_station());
      final mine = await db.insertSession(_transect(station));
      final frame = await db.insertFrame(_frame(mine, 0));
      await db.ensureFramePoints(mine);
      final pt = (await db.pointsForFrame(frame)).first;
      await db.setPointModelLabel(pt.id!, modelClass: 'clam', categoryCode: 'OT');

      await db.seedCategoryMap(
        kCoralscapesModelId,
        coralscapesMapping().where((m) => m.modelClass != 'clam').toList(),
      );
      expect(await db.categoryMapFor(kCoralscapesModelId), hasLength(39));
      final back = (await db.pointsForFrame(frame)).first;
      expect(back.modelClass, 'clam');
      expect(back.categoryCode, isNull);
    });

    test('another model\'s transects are left alone', () async {
      final station = await db.insertStation(_station());
      final other = await db.insertSession(_transect(station, modelId: 'some-other-model'));
      final frame = await db.insertFrame(_frame(other, 0));
      await db.ensureFramePoints(other);
      final pt = (await db.pointsForFrame(frame)).first;
      await db.setPointModelLabel(pt.id!, modelClass: 'turbinaria', categoryCode: 'CF');

      await db.seedCategoryMap(kCoralscapesModelId, [
        for (final m in coralscapesMapping())
          m.modelClass == 'turbinaria'
              ? CategoryMapping(modelId: m.modelId, modelClass: m.modelClass, categoryCode: 'CE', majorCategory: 'HC')
              : m,
      ]);
      expect((await db.pointsForFrame(frame)).first.categoryCode, 'CF');
    });

    test('rejects rows for another model, unknown codes, or a major that disagrees with the code', () async {
      final good = coralscapesMapping();
      CategoryMapping first(CategoryMapping Function(CategoryMapping) edit) => edit(good.first);
      for (final bad in [
        first((m) => CategoryMapping(modelId: 'x', modelClass: m.modelClass, categoryCode: m.categoryCode, majorCategory: m.majorCategory, excluded: m.excluded)),
        first((m) => CategoryMapping(modelId: m.modelId, modelClass: m.modelClass, categoryCode: 'XYZ', majorCategory: 'HC')),
        first((m) => CategoryMapping(modelId: m.modelId, modelClass: m.modelClass, categoryCode: 'CB', majorCategory: 'AB')),
        first((m) => CategoryMapping(modelId: m.modelId, modelClass: m.modelClass, categoryCode: 'CB', majorCategory: 'HC', excluded: true)),
      ]) {
        await expectLater(
          db.seedCategoryMap(kCoralscapesModelId, [bad, ...good.skip(1)]),
          throwsArgumentError,
          reason: '$bad',
        );
      }
      expect((await db.categoryMapFor(kCoralscapesModelId)).toSet(), good.toSet());
    });
  });

  group('ensureFramePoints', () {
    late TransectDatabase db;
    late int station;
    setUp(() async {
      db = await TransectDatabase.openInMemoryForTest();
      station = await db.insertStation(_station());
    });
    tearDown(() => db.close());

    test('gives a transect with no seed one, and keeps it', () async {
      final t = await db.insertSession(_transect(station));
      await db.insertFrame(_frame(t, 0));
      await db.ensureFramePoints(t, newSeed: () => 777);
      expect((await db.sessionById(t))!.pointSeed, 777);
      await db.ensureFramePoints(t, newSeed: () => 888);
      expect((await db.sessionById(t))!.pointSeed, 777);
    });

    test('places 10 points per frame at the seeded positions', () async {
      final t = await db.insertSession(_transect(station, seed: 42));
      final f1 = await db.insertFrame(_frame(t, 1));
      final f2 = await db.insertFrame(_frame(t, 2));
      expect(await db.ensureFramePoints(t), 20);

      for (final (frame, meter) in [(f1, 1.0), (f2, 2.0)]) {
        final points = await db.pointsForFrame(frame);
        expect(points.map((pt) => pt.pointIndex), List.generate(10, (i) => i));
        final expected = samplePoints(42, frameKey(meterMark: meter, videoTimeMs: null), 10);
        expect([for (final pt in points) (x: pt.xNorm, y: pt.yNorm)], expected);
        expect(points.every((pt) => pt.categoryCode == null && pt.modelClass == null), isTrue);
      }
    });

    test('is idempotent: frames that have points keep them', () async {
      final t = await db.insertSession(_transect(station, seed: 42));
      final f = await db.insertFrame(_frame(t, 0));
      await db.ensureFramePoints(t);
      final before = await db.pointsForFrame(f);
      expect(await db.ensureFramePoints(t), 0);
      expect((await db.pointsForFrame(f)).map((pt) => pt.id), before.map((pt) => pt.id));
    });

    test('skips frames that can\'t be scored: excluded, missing, or with no corners', () async {
      final t = await db.insertSession(_transect(station, seed: 42));
      final excluded = await db.insertFrame(_frame(t, 0, excluded: true));
      final noCorners = await db.insertFrame(_frame(t, 1, corners: null));
      final missing = await db.insertFrame(TransectFrame.missingMeter(sessionId: t, meterMark: 2));
      final ok = await db.insertFrame(_frame(t, 3));
      expect(await db.ensureFramePoints(t), 10);
      for (final f in [excluded, noCorners, missing]) {
        expect(await db.pointsForFrame(f), isEmpty);
      }
      expect(await db.pointsForFrame(ok), hasLength(10));
    });

    test('uses the transect\'s points per frame', () async {
      final t = await db.insertSession(_transect(station, seed: 42).copyWith(pointsPerFrame: 25));
      final f = await db.insertFrame(_frame(t, 0));
      await db.ensureFramePoints(t);
      expect(await db.pointsForFrame(f), hasLength(25));
    });

    test('a colony-count transect takes no points', () async {
      final colonyStation = await db.insertStation(_station(type: SurveyType.colonyCount));
      final t = await db.insertSession(_transect(colonyStation));
      await expectLater(db.ensureFramePoints(t), throwsArgumentError);
    });

    test('an unknown transect throws', () async {
      await expectLater(db.ensureFramePoints(9999), throwsArgumentError);
    });
  });

  group('cover cache', () {
    late TransectDatabase db;
    late int t;
    late int frame;
    setUp(() async {
      db = await TransectDatabase.openInMemoryForTest();
      t = await db.insertSession(_transect(await db.insertStation(_station()), seed: 42));
      frame = await db.insertFrame(_frame(t, 0));
      await db.ensureFramePoints(t);
    });
    tearDown(() => db.close());

    Future<void> labelAll(String modelClass) async {
      final code = (await db.categoryMapFor(kCoralscapesModelId)).singleWhere((m) => m.modelClass == modelClass).categoryCode;
      for (final pt in await db.pointsForFrame(frame)) {
        await db.setPointModelLabel(pt.id!, modelClass: modelClass, confidence: 0.9, categoryCode: code);
      }
    }

    test('refreshTransectCover stores a complete transect\'s rows', () async {
      await labelAll('sand');
      final c = await db.refreshTransectCover(t);
      expect(c.isComplete, isTrue);
      final cached = await db.coverForSession(t);
      expect(cached.toSet(), c.rows.toSet());
      expect(cached.singleWhere((r) => r.level == CoverLevel.code && r.categoryCode == 'S').percent, 100);
    });

    test('an incomplete transect has no cached cover', () async {
      final c = await db.refreshTransectCover(t);
      expect(c.isComplete, isFalse);
      expect(c.unlabeledPoints, 10);
      expect(await db.coverForSession(t), isEmpty);
    });

    test('a new model label drops the cached cover', () async {
      await labelAll('sand');
      await db.refreshTransectCover(t);
      final pt = (await db.pointsForFrame(frame)).first;
      await db.setPointModelLabel(pt.id!, modelClass: 'branching alive', categoryCode: 'CB');
      expect(await db.coverForSession(t), isEmpty);
    });

    test('an expert correction drops the cached cover', () async {
      await labelAll('sand');
      await db.refreshTransectCover(t);
      final pt = (await db.pointsForFrame(frame)).first;
      await db.setExpertCategory(pt.id!, 'CB', by: 'J. Reviewer', at: DateTime.utc(2026, 11, 20));
      expect(await db.coverForSession(t), isEmpty);
      final c = await db.refreshTransectCover(t);
      expect(c.rows.every((r) => r.usesExpert), isTrue);
    });

    test('new points drop the cached cover', () async {
      await labelAll('sand');
      await db.refreshTransectCover(t);
      await db.insertFrame(_frame(t, 1));
      await db.ensureFramePoints(t);
      expect(await db.coverForSession(t), isEmpty);
    });

    test('codes outside the TB catalogue are rejected at write time', () async {
      final pt = (await db.pointsForFrame(frame)).first;
      await expectLater(db.setExpertCategory(pt.id!, 'cb', by: 'J. Reviewer', at: DateTime.utc(2026, 11, 20)),
          throwsArgumentError);
      await expectLater(db.setPointModelLabel(pt.id!, modelClass: 'x', categoryCode: 'XYZ'), throwsArgumentError);
      final other = await db.insertFrame(_frame(t, 5));
      await expectLater(
        db.insertFramePoints([FramePoint(frameId: other, pointIndex: 0, xNorm: 0.5, yNorm: 0.5, categoryCode: 'XYZ')]),
        throwsArgumentError,
      );
      await expectLater(
        db.insertFramePoints([FramePoint(frameId: other, pointIndex: 0, xNorm: 0.5, yNorm: 0.5, expertCategoryCode: 'cb')]),
        throwsArgumentError,
      );
      expect(await db.pointsForFrame(other), isEmpty);
    });
  });

  // The issue's "done when": given labeled points, each transect shows the
  // right % cover per TB category, bleached coral included.
  test('end to end: model classes through the mapping to % cover, bleached coral included', () async {
    final db = await TransectDatabase.openInMemoryForTest();
    addTearDown(db.close);
    final t = await db.insertSession(_transect(await db.insertStation(_station()), seed: 2026));
    final frames = [for (var m = 0; m < 3; m++) await db.insertFrame(_frame(t, m.toDouble()))];
    await db.ensureFramePoints(t);
    final map = {for (final m in await db.categoryMapFor(kCoralscapesModelId)) m.modelClass: m.categoryCode};

    // Per frame: 2 transect line, 3 branching alive, 1 branching bleached,
    // 2 sand, 1 table acropora alive, 1 branching dead. 24 of 30 counted.
    const classes = [
      'transect line', 'transect line', 'branching alive', 'branching alive', 'branching alive',
      'branching bleached', 'sand', 'sand', 'table acropora alive', 'branching dead', //
    ];
    for (final f in frames) {
      final points = await db.pointsForFrame(f);
      for (var i = 0; i < 10; i++) {
        await db.setPointModelLabel(points[i].id!, modelClass: classes[i], categoryCode: map[classes[i]]);
      }
    }

    final c = await db.refreshTransectCover(t);
    expect(c.countedPoints, 24);
    expect(c.excludedPoints, 6);
    double pct(CoverLevel level, String code) =>
        c.rows.singleWhere((r) => r.level == level && r.categoryCode == code).percent;
    expect(pct(CoverLevel.code, 'CB'), closeTo(9 / 24 * 100, 1e-9));
    expect(pct(CoverLevel.code, 'BLEC'), closeTo(3 / 24 * 100, 1e-9));
    expect(pct(CoverLevel.code, 'ACT'), closeTo(3 / 24 * 100, 1e-9));
    expect(pct(CoverLevel.code, 'S'), closeTo(6 / 24 * 100, 1e-9));
    expect(pct(CoverLevel.major, 'HC'), closeTo(15 / 24 * 100, 1e-9));
    expect(pct(CoverLevel.major, 'DC'), closeTo(3 / 24 * 100, 1e-9));
  });

  // Issue #8: the station summary's input -- every transect with its cover
  // rebuilt and its counts, which the cache alone doesn't hold.
  group('stationCoverInputs', () {
    late TransectDatabase db;
    late int station;
    setUp(() async {
      db = await TransectDatabase.openInMemoryForTest();
      station = await db.insertStation(_station());
    });
    tearDown(() => db.close());

    Future<int> transect(int number, {required bool labeled}) async {
      final t = await db.insertSession(_transect(station, seed: 42).copyWith(transectNumber: number));
      final f = await db.insertFrame(_frame(t, 0));
      await db.insertFrame(_frame(t, 1, excluded: true));
      await db.ensureFramePoints(t);
      if (labeled) {
        for (final pt in await db.pointsForFrame(f)) {
          await db.setPointModelLabel(pt.id!, modelClass: 'sand', confidence: 0.9, categoryCode: 'S');
        }
      }
      return t;
    }

    test('returns each transect by number with its cover and counts', () async {
      final t2 = await transect(2, labeled: true);
      final t1 = await transect(1, labeled: false);
      final inputs = await db.stationCoverInputs(station);
      expect(inputs.map((i) => i.transect.id), [t1, t2]);
      expect(inputs[0].cover.isComplete, isFalse);
      expect(inputs[1].cover.isComplete, isTrue);
      expect(inputs[1].cover.framesScored, 1);
      expect(inputs[1].cover.allPoints, 10);
      expect(inputs[1].cover.countedPoints, 10);
      // The cache is rebuilt on the way.
      expect(await db.coverForSession(t2), isNotEmpty);
    });

    test('a station with no transects has no inputs', () async {
      expect(await db.stationCoverInputs(station), isEmpty);
    });

    test('a colony-count station is refused', () async {
      final colony = await db.insertStation(_station(type: SurveyType.colonyCount));
      expect(() => db.stationCoverInputs(colony), throwsArgumentError);
    });

    test('an unknown station is refused', () async {
      expect(() => db.stationCoverInputs(999), throwsArgumentError);
    });
  });
}
