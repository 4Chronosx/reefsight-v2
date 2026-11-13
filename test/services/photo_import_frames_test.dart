import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:reefsight_mobile/services/frame_point.dart';
import 'package:reefsight_mobile/services/photo_transect_store.dart';
import 'package:reefsight_mobile/services/station.dart';
import 'package:reefsight_mobile/services/transect_cover.dart';
import 'package:reefsight_mobile/services/transect_database.dart';
import 'package:reefsight_mobile/services/transect_frame.dart';
import 'package:reefsight_mobile/services/transect_session.dart';

// Issue #5: saving an imported photo transect -- the whole ordered set in
// one transaction, re-saved after a reorder without tripping
// `UNIQUE (session_id, meter_mark)` -- and the corner editor's write, which
// makes the frame's points (placed inside the corners) stale.

Station _station(SurveyType type) => Station(
      code: 'ALG-S2',
      surveyType: type,
      frameMode: type == SurveyType.photoTransect ? FrameMode.importedMixed : null,
      surveyedOn: DateTime(2026, 11, 15),
      siteName: 'Alegria MPA',
      createdAt: DateTime.utc(2026, 11, 15, 1),
    );

TransectSession _transect(int stationId) => TransectSession(
      startedAt: DateTime.utc(2026, 11, 15, 2),
      tapeLengthMeters: 50,
      stationId: stationId,
      transectNumber: 1,
      captureSource: CaptureSource.importedPhotos,
    );

TransectFrame _imported(int sessionId, double meter, String path, {int? id}) => TransectFrame(
      id: id,
      sessionId: sessionId,
      meterMark: meter,
      imagePath: path,
      source: FrameSource.imported,
      widthPx: 4000,
      heightPx: 3000,
      cameraMake: 'GoPro',
      cameraModel: 'HERO11 Black',
      capturedAt: DateTime(2026, 11, 15, 9, meter.toInt()),
      fisheyeFlag: false,
    );

TransectFrame _with(TransectFrame f, {double? meter, int? id, bool? fisheye}) => TransectFrame.fromMap(f.toMap()
  ..['meter_mark'] = meter ?? f.meterMark
  ..['id'] = id ?? f.id
  ..['fisheye_flag'] = fisheye == null ? f.toMap()['fisheye_flag'] : (fisheye ? 1 : 0));

List<FramePoint> _points(int frameId) =>
    [for (var i = 0; i < 10; i++) FramePoint(frameId: frameId, pointIndex: i, xNorm: 0.5, yNorm: 0.5)];

TransectCoverRow _cover(int sessionId) =>
    TransectCoverRow(sessionId: sessionId, categoryCode: 'HC', points: 4, totalPoints: 10, percent: 40);

void main() {
  test('missingMeter can be an imported gap', () {
    final gap = TransectFrame.missingMeter(sessionId: 1, meterMark: 23, source: FrameSource.imported);
    expect(gap.source, FrameSource.imported);
    expect(gap.isMissing, isTrue);
    expect(TransectFrame.missingMeter(sessionId: 1, meterMark: 23).source, FrameSource.inApp);
  });

  group('TransectDatabase.saveImportedFrames', () {
    late TransectDatabase db;
    late int sessionId;

    setUp(() async {
      db = await TransectDatabase.openInMemoryForTest();
      final stationId = await db.insertStation(_station(SurveyType.photoTransect));
      sessionId = await db.insertSession(_transect(stationId));
    });
    tearDown(() => db.close());

    test('a first save inserts every frame and gap, in meter order', () async {
      final result = await db.saveImportedFrames(sessionId, [
        _imported(sessionId, 0, 'p/a.jpg'),
        TransectFrame.missingMeter(sessionId: sessionId, meterMark: 1, source: FrameSource.imported),
        _imported(sessionId, 2, 'p/b.jpg'),
      ]);
      expect(result.removed, isEmpty);
      final frames = await db.framesForSession(sessionId);
      expect(frames.map((f) => f.meterMark), [0, 1, 2]);
      expect(frames.map((f) => f.imagePath), ['p/a.jpg', '', 'p/b.jpg']);
      expect(frames[1].isMissing, isTrue);
      expect(frames.first.cameraModel, 'HERO11 Black');
    });

    test('re-saving with two photos swapped keeps their rows, ids and points', () async {
      await db.saveImportedFrames(sessionId, [_imported(sessionId, 0, 'p/a.jpg'), _imported(sessionId, 1, 'p/b.jpg')]);
      final saved = await db.framesForSession(sessionId);
      final a = saved[0], b = saved[1];
      await db.insertFramePoints(_points(a.id!));

      final result = await db.saveImportedFrames(sessionId, [_with(b, meter: 0), _with(a, meter: 1)]);

      expect(result.removed, isEmpty);
      final frames = await db.framesForSession(sessionId);
      expect(frames.map((f) => f.imagePath), ['p/b.jpg', 'p/a.jpg']);
      expect(frames.map((f) => f.id), [b.id, a.id]);
      // Points sit on the image, not the meter: a reorder doesn't move them.
      expect(await db.pointsForFrame(a.id!), hasLength(10));
    });

    test('a photo dropped on re-save is deleted with its points and handed back', () async {
      await db.saveImportedFrames(sessionId, [_imported(sessionId, 0, 'p/a.jpg'), _imported(sessionId, 1, 'p/b.jpg')]);
      final saved = await db.framesForSession(sessionId);
      await db.insertFramePoints(_points(saved[1].id!));

      final result = await db.saveImportedFrames(sessionId, [saved[0]]);

      expect(result.removed.map((f) => f.imagePath), ['p/b.jpg']);
      expect((await db.framesForSession(sessionId)).map((f) => f.imagePath), ['p/a.jpg']);
      expect(await db.pointsForSession(sessionId), isEmpty);
    });

    test('gaps are rewritten each save: a gap moved to another meter', () async {
      await db.saveImportedFrames(sessionId, [
        _imported(sessionId, 0, 'p/a.jpg'),
        TransectFrame.missingMeter(sessionId: sessionId, meterMark: 1, source: FrameSource.imported),
        _imported(sessionId, 2, 'p/b.jpg'),
      ]);
      final saved = (await db.framesForSession(sessionId)).where((f) => !f.isMissing).toList();
      final result = await db.saveImportedFrames(sessionId, [
        _with(saved[0], meter: 0),
        _with(saved[1], meter: 1),
        TransectFrame.missingMeter(sessionId: sessionId, meterMark: 2, source: FrameSource.imported),
      ]);
      expect(result.removed.where((f) => !f.isMissing), isEmpty, reason: 'a gap row has no file to delete');
      final frames = await db.framesForSession(sessionId);
      expect(frames.map((f) => f.imagePath), ['p/a.jpg', 'p/b.jpg', '']);
    });

    test('a fisheye answer changed at re-save is written to kept rows', () async {
      await db.saveImportedFrames(sessionId, [_imported(sessionId, 0, 'p/a.jpg')]);
      final a = (await db.framesForSession(sessionId)).single;
      await db.saveImportedFrames(sessionId, [_with(a, fisheye: true)]);
      expect((await db.framesForSession(sessionId)).single.fisheyeFlag, isTrue);
    });

    test('any change clears the cached cover; an identical re-save keeps it', () async {
      await db.saveImportedFrames(sessionId, [_imported(sessionId, 0, 'p/a.jpg'), _imported(sessionId, 1, 'p/b.jpg')]);
      final saved = await db.framesForSession(sessionId);
      await db.replaceTransectCover(sessionId, [_cover(sessionId)]);

      await db.saveImportedFrames(sessionId, saved);
      expect(await db.coverForSession(sessionId), hasLength(1));

      await db.saveImportedFrames(sessionId, [_with(saved[1], meter: 0), _with(saved[0], meter: 1)]);
      expect(await db.coverForSession(sessionId), isEmpty);
    });

    test('an identical re-save of a set with gaps keeps the cover; moving a gap clears it', () async {
      TransectFrame gap(double m) =>
          TransectFrame.missingMeter(sessionId: sessionId, meterMark: m, source: FrameSource.imported);
      await db.saveImportedFrames(sessionId, [_imported(sessionId, 0, 'p/a.jpg'), gap(1), _imported(sessionId, 2, 'p/b.jpg')]);
      final photos = (await db.framesForSession(sessionId)).where((f) => !f.isMissing).toList();
      await db.replaceTransectCover(sessionId, [_cover(sessionId)]);

      await db.saveImportedFrames(sessionId, [photos[0], gap(1), photos[1]]);
      expect(await db.coverForSession(sessionId), hasLength(1));

      await db.saveImportedFrames(sessionId, [_with(photos[0], meter: 0), _with(photos[1], meter: 1), gap(2)]);
      expect(await db.coverForSession(sessionId), isEmpty);
    });

    test('in-app frames already on the transect are kept if listed, like any row', () async {
      final inApp = await db.replaceFrameAtMeter(TransectFrame(
        sessionId: sessionId,
        meterMark: 0,
        imagePath: 'p/inapp.jpg',
        source: FrameSource.inApp,
      ));
      final row = (await db.framesForSession(sessionId)).single;
      await db.saveImportedFrames(sessionId, [_with(row, meter: 1), _imported(sessionId, 0, 'p/a.jpg')]);
      final frames = await db.framesForSession(sessionId);
      expect(frames.map((f) => f.source), [FrameSource.imported, FrameSource.inApp]);
      expect(frames.last.id, inApp.id);
    });

    test('rejects two frames at one meter, a frame with no meter, and a stranger\'s row', () async {
      await expectLater(
        db.saveImportedFrames(sessionId, [_imported(sessionId, 0, 'p/a.jpg'), _imported(sessionId, 0, 'p/b.jpg')]),
        throwsArgumentError,
      );
      await expectLater(
        db.saveImportedFrames(sessionId, [
          TransectFrame(sessionId: sessionId, imagePath: 'p/v.jpg', source: FrameSource.imported, videoTimeMs: 1),
        ]),
        throwsArgumentError,
      );
      await expectLater(db.saveImportedFrames(sessionId, [_imported(sessionId, 0, 'p/a.jpg', id: 999)]), throwsArgumentError);
      await expectLater(db.saveImportedFrames(sessionId, [_imported(sessionId + 1, 0, 'p/a.jpg')]), throwsArgumentError);
      expect(await db.framesForSession(sessionId), isEmpty, reason: 'nothing half-written');
    });

    test('a colony-count transect is refused', () async {
      final colonyStation = await db.insertStation(_station(SurveyType.colonyCount));
      final colony = await db.insertSession(TransectSession(
        startedAt: DateTime.utc(2026, 11, 15, 3),
        tapeLengthMeters: 50,
        stationId: colonyStation,
        transectNumber: 1,
        captureSource: CaptureSource.legacyColony,
      ));
      await expectLater(db.saveImportedFrames(colony, [_imported(colony, 0, 'p/a.jpg')]), throwsArgumentError);
    });
  });

  group('TransectDatabase.updateFrameCorners', () {
    late TransectDatabase db;
    late int sessionId;

    setUp(() async {
      db = await TransectDatabase.openInMemoryForTest();
      final stationId = await db.insertStation(_station(SurveyType.photoTransect));
      sessionId = await db.insertSession(_transect(stationId));
    });
    tearDown(() => db.close());

    const square = [(x: 0.1, y: 0.1), (x: 0.9, y: 0.1), (x: 0.9, y: 0.9), (x: 0.1, y: 0.9)];

    test("moving the corners drops that frame's points and the transect's cover", () async {
      await db.saveImportedFrames(sessionId, [_imported(sessionId, 0, 'p/a.jpg'), _imported(sessionId, 1, 'p/b.jpg')]);
      final frames = await db.framesForSession(sessionId);
      await db.insertFramePoints(_points(frames[0].id!));
      await db.insertFramePoints(_points(frames[1].id!));
      await db.replaceTransectCover(sessionId, [_cover(sessionId)]);

      await db.updateFrameCorners(frames[0].id!, square, CornerSource.manual);

      final back = (await db.framesForSession(sessionId)).first;
      expect(back.corners, square);
      expect(back.cornerSource, CornerSource.manual);
      expect(await db.pointsForFrame(frames[0].id!), isEmpty);
      expect(await db.pointsForFrame(frames[1].id!), hasLength(10), reason: 'other frames untouched');
      expect(await db.coverForSession(sessionId), isEmpty);
    });

    test('re-saving the same corners keeps scored points and cover (review fix)', () async {
      await db.saveImportedFrames(sessionId, [_imported(sessionId, 0, 'p/a.jpg')]);
      final frame = (await db.framesForSession(sessionId)).single;
      await db.updateFrameCorners(frame.id!, square, CornerSource.manual);
      await db.insertFramePoints(_points(frame.id!));
      await db.replaceTransectCover(sessionId, [_cover(sessionId)]);

      await db.updateFrameCorners(frame.id!, square, CornerSource.manual);

      expect(await db.pointsForFrame(frame.id!), hasLength(10));
      expect(await db.coverForSession(sessionId), hasLength(1));
    });

    test('corners on a "no frame visible" photo lift that exclusion in the same write', () async {
      await db.saveImportedFrames(sessionId, [_imported(sessionId, 0, 'p/a.jpg')]);
      final frame = (await db.framesForSession(sessionId)).single;
      await db.setFrameExcluded(frame.id!, excluded: true, reason: kNoFrameReason);

      await db.updateFrameCorners(frame.id!, square, CornerSource.manual);

      final back = (await db.framesForSession(sessionId)).single;
      expect(back.excluded, isFalse);
      expect(back.excludeReason, isNull);
      expect(back.corners, square);
    });

    test('an unknown frame id is an error, not a silent no-op', () async {
      await expectLater(db.updateFrameCorners(424242, square, CornerSource.manual), throwsArgumentError);
    });
  });

  group('TransectDatabase.setFrameExcluded', () {
    test("changes which frames count, so it clears the transect's cover", () async {
      final db = await TransectDatabase.openInMemoryForTest();
      addTearDown(db.close);
      final stationId = await db.insertStation(_station(SurveyType.photoTransect));
      final sessionId = await db.insertSession(_transect(stationId));
      await db.saveImportedFrames(sessionId, [_imported(sessionId, 0, 'p/a.jpg')]);
      final frame = (await db.framesForSession(sessionId)).single;
      await db.replaceTransectCover(sessionId, [_cover(sessionId)]);

      await db.setFrameExcluded(frame.id!, excluded: true, reason: kNoFrameReason);

      final back = (await db.framesForSession(sessionId)).single;
      expect(back.excluded, isTrue);
      expect(back.excludeReason, kNoFrameReason);
      expect(back.isMissing, isFalse);
      expect(await db.coverForSession(sessionId), isEmpty);
    });
  });

  group('PhotoTransectStore.importCopy', () {
    late Directory docs;
    late Directory source;
    setUp(() async {
      docs = await Directory.systemTemp.createTemp('reefsight_docs_');
      source = await Directory.systemTemp.createTemp('reefsight_src_');
    });
    tearDown(() async {
      await docs.delete(recursive: true);
      await source.delete(recursive: true);
    });

    test('copies (never moves) the original, keeping its extension', () async {
      final original = File(p.join(source.path, 'GOPR0042.JPG'))..writeAsBytesSync([1, 2, 3]);
      final store = PhotoTransectStore(documentsDirectory: docs.path, sessionId: 7);

      final relative = await store.importCopy(original.path, index: 3, at: DateTime.fromMillisecondsSinceEpoch(1000));

      expect(relative, 'transect_photos/session7_imp003_1000.jpg');
      expect(File(store.absolutePath(relative)).readAsBytesSync(), [1, 2, 3]);
      expect(original.existsSync(), isTrue, reason: 'the source file is never changed');
      expect(File('${store.absolutePath(relative)}.tmp').existsSync(), isFalse);
    });

    test('a HEIC keeps .heic; a file with no extension gets .img', () async {
      final heic = File(p.join(source.path, 'IMG_0001.HEIC'))..writeAsBytesSync([0]);
      final bare = File(p.join(source.path, 'photo'))..writeAsBytesSync([0]);
      final store = PhotoTransectStore(documentsDirectory: docs.path, sessionId: 7);
      final at = DateTime.fromMillisecondsSinceEpoch(5);
      expect(await store.importCopy(heic.path, index: 0, at: at), endsWith('.heic'));
      expect(await store.importCopy(bare.path, index: 1, at: at), endsWith('.img'));
    });

    test('a missing source throws and leaves nothing behind', () async {
      final store = PhotoTransectStore(documentsDirectory: docs.path, sessionId: 7);
      await expectLater(
        store.importCopy(p.join(source.path, 'gone.jpg'), index: 0, at: DateTime(2026)),
        throwsA(isA<FileSystemException>()),
      );
      final dir = Directory(p.join(docs.path, PhotoTransectStore.folder));
      expect(dir.existsSync() ? dir.listSync() : const [], isEmpty);
    });
  });
}
