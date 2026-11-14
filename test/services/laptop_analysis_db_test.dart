import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/services/analysis_manifest.dart';
import 'package:reefsight_mobile/services/coralscapes_mapping.dart';
import 'package:reefsight_mobile/services/station.dart';
import 'package:reefsight_mobile/services/transect_cover.dart';
import 'package:reefsight_mobile/services/transect_database.dart';
import 'package:reefsight_mobile/services/transect_frame.dart';
import 'package:reefsight_mobile/services/transect_session.dart';

// Issue #7 in the database: `applyAnalysisResults` checks a laptop results
// file against this phone's transects, writes the model labels, records
// where the analysis ran, and rebuilds cover -- all or nothing. Real SQLite
// (test/flutter_test_config.dart).

const _corners = <NormPoint>[(x: 0.1, y: 0.1), (x: 0.9, y: 0.1), (x: 0.9, y: 0.9), (x: 0.1, y: 0.9)];
final _at = DateTime.utc(2026, 11, 16, 10, 15);

Station _station({SurveyType type = SurveyType.photoTransect}) => Station(
      code: 'ALG-S1',
      surveyType: type,
      frameMode: type == SurveyType.photoTransect ? FrameMode.physical : null,
      surveyedOn: DateTime(2026, 11, 15),
      createdAt: DateTime.utc(2026, 11, 15, 1),
    );

TransectSession _transect(int stationId, int number) => TransectSession(
      startedAt: DateTime.utc(2026, 11, 15, 2),
      tapeLengthMeters: 50,
      stationId: stationId,
      transectNumber: number,
      captureSource: CaptureSource.inAppPhotos,
      pointsPerFrame: 10,
    );

TransectFrame _frame(int sessionId, double meter) => TransectFrame(
      sessionId: sessionId,
      meterMark: meter,
      imagePath: 'frames/$sessionId/m$meter.jpg',
      source: FrameSource.inApp,
      corners: _corners,
      cornerSource: CornerSource.manual,
    );

/// What the notebook would send back for [sessionId]: [classOf] picks each
/// point's class from its frame's meter and its index.
Future<TransectResults> _resultsFor(
  TransectDatabase db,
  int sessionId,
  String Function(double meter, int index) classOf,
) async {
  final session = (await db.sessionById(sessionId))!;
  final frames = await db.framesForSession(sessionId);
  return TransectResults(
    sessionId: sessionId,
    pointSeed: session.pointSeed!,
    frames: [
      for (final f in frames)
        FrameResults(
          frameId: f.id!,
          corners: f.corners!,
          points: [
            for (final p in await db.pointsForFrame(f.id!))
              PointResult(pointId: p.id!, modelClass: classOf(f.meterMark!, p.pointIndex), confidence: 0.9),
          ],
        ),
    ],
  );
}

AnalysisResults _file(List<TransectResults> transects, {String modelId = kCoralscapesModelId}) =>
    AnalysisResults(modelId: modelId, runId: '20261116_101500', transects: transects);

/// Meter 0: all branching coral. Meter 1: half sand, half tape (excluded).
String _reef(double meter, int index) => meter == 0 ? 'branching alive' : (index < 5 ? 'sand' : 'transect line');

TransectCoverRow _row(List<TransectCoverRow> rows, String code, [CoverLevel level = CoverLevel.code]) =>
    rows.singleWhere((r) => r.categoryCode == code && r.level == level);

void main() {
  late TransectDatabase db;
  late int stationId;
  late int t1;

  setUp(() async {
    db = await TransectDatabase.openInMemoryForTest();
    stationId = await db.insertStation(_station());
    t1 = await db.insertSession(_transect(stationId, 1));
    await db.insertFrame(_frame(t1, 0));
    await db.insertFrame(_frame(t1, 1));
    await db.ensureFramePoints(t1, newSeed: () => 987654321);
  });
  tearDown(() => db.closeForTest());

  test('labels every point, records the laptop run and rebuilds cover', () async {
    final imports = await db.applyAnalysisResults(_file([await _resultsFor(db, t1, _reef)]), at: _at);

    final result = imports.single;
    expect(result.sessionId, t1);
    expect(result.pointsLabeled, 20);
    expect(result.staleFrameIds, isEmpty);
    expect(result.complete, isTrue);

    final points = await db.pointsForSession(t1);
    expect(points.map((p) => p.categoryCode).toSet(), {'CB', 'S', 'TWB'});
    expect(points.first.modelClass, 'branching alive');
    expect(points.first.modelConfidence, 0.9);

    // 5 tape points don't count: 10 CB + 5 S of 15.
    final cover = await db.coverForSession(t1);
    expect(_row(cover, 'CB').points, 10);
    expect(_row(cover, 'CB').totalPoints, 15);
    expect(_row(cover, 'CB').percent, closeTo(66.667, 0.001));
    expect(_row(cover, 'S').percent, closeTo(33.333, 0.001));
    expect(_row(cover, 'HC', CoverLevel.major).percent, closeTo(66.667, 0.001));

    final session = (await db.sessionById(t1))!;
    expect(session.analysisStatus, AnalysisStatus.done);
    expect(session.analyzedOn, AnalyzedOn.laptop);
    expect(session.modelId, kCoralscapesModelId);
    expect(session.analyzedAt, _at);
  });

  test('importing the same file again changes nothing', () async {
    final file = _file([await _resultsFor(db, t1, _reef)]);
    await db.applyAnalysisResults(file, at: _at);
    final before = await db.coverForSession(t1);
    await db.applyAnalysisResults(file, at: _at);
    final after = await db.coverForSession(t1);
    expect([for (final r in after) r.toMap()], [for (final r in before) r.toMap()]);
  });

  test("a reviewer's corrections survive a re-import", () async {
    final file = _file([await _resultsFor(db, t1, _reef)]);
    await db.applyAnalysisResults(file, at: _at);
    final point = (await db.pointsForSession(t1)).first;
    await db.setExpertCategory(point.id!, 'DC', by: 'CCEF reviewer', at: _at);

    await db.applyAnalysisResults(file, at: _at);
    final again = (await db.pointsForSession(t1)).first;
    expect(again.categoryCode, 'CB');
    expect(again.expertCategoryCode, 'DC');
    expect(_row(await db.coverForSession(t1), 'DC').points, 1);
  });

  test('a frame whose corners moved since the export is skipped as stale', () async {
    final file = _file([await _resultsFor(db, t1, _reef)]);
    final frames = await db.framesForSession(t1);
    final moved = [for (final c in _corners) (x: c.x + 0.01, y: c.y)];
    await db.updateFrameCorners(frames.last.id!, moved, CornerSource.manual);

    // Not resampled yet: the moved frame has no points at all, so the other
    // frame's labels alone would look like a complete cover. They must not.
    final result = (await db.applyAnalysisResults(file, at: _at)).single;
    expect(result.staleFrameIds, [frames.last.id]);
    expect(result.pointsLabeled, 10);
    expect(result.complete, isFalse);
    expect(await db.coverForSession(t1), isEmpty);
    final session = (await db.sessionById(t1))!;
    expect(session.analysisStatus, AnalysisStatus.pending);
    expect(session.modelId, kCoralscapesModelId);
  });

  test('a frame resampled after its corners moved (then moved back) is stale too', () async {
    final file = _file([await _resultsFor(db, t1, _reef)]);
    final frames = await db.framesForSession(t1);
    await db.updateFrameCorners(frames.last.id!, [for (final c in _corners) (x: c.x + 0.01, y: c.y)], CornerSource.manual);
    await db.updateFrameCorners(frames.last.id!, _corners, CornerSource.manual);
    await db.ensureFramePoints(t1);

    final result = (await db.applyAnalysisResults(file, at: _at)).single;
    expect(result.staleFrameIds, [frames.last.id]);
    expect(result.complete, isFalse);
    expect(await db.coverForSession(t1), isEmpty);
  });

  test('a frame retaken since the export is stale; the rest still imports', () async {
    final file = _file([await _resultsFor(db, t1, _reef)]);
    final old = (await db.framesForSession(t1)).last;
    await db.replaceFrameAtMeter(_frame(t1, 1));

    final result = (await db.applyAnalysisResults(file, at: _at)).single;
    expect(result.staleFrameIds, [old.id]);
    expect(result.pointsLabeled, 10);
    expect(result.complete, isFalse);
    expect((await db.sessionById(t1))!.analysisStatus, AnalysisStatus.pending);
  });

  test('when every frame is stale the transect is not marked as analyzed', () async {
    final file = _file([await _resultsFor(db, t1, _reef)]);
    for (final f in await db.framesForSession(t1)) {
      await db.updateFrameCorners(f.id!, [for (final c in _corners) (x: c.x, y: c.y + 0.01)], CornerSource.manual);
    }
    final result = (await db.applyAnalysisResults(file, at: _at)).single;
    expect(result.pointsLabeled, 0);
    final session = (await db.sessionById(t1))!;
    expect(session.analyzedOn, isNull);
    expect(session.analyzedAt, isNull);
    expect(session.analysisStatus, isNull);
  });

  test('frames the file does not cover leave the transect pending', () async {
    final results = await _resultsFor(db, t1, _reef);
    final partial = TransectResults(sessionId: t1, pointSeed: results.pointSeed, frames: [results.frames.first]);
    final result = (await db.applyAnalysisResults(_file([partial]), at: _at)).single;
    expect(result.pointsLabeled, 10);
    expect(result.complete, isFalse);
    expect((await db.sessionById(t1))!.analysisStatus, AnalysisStatus.pending);
  });

  group('rejects the whole file, writing nothing, for', () {
    Future<void> expectRejected(AnalysisResults file) async {
      await expectLater(db.applyAnalysisResults(file, at: _at), throwsArgumentError);
      expect((await db.pointsForSession(t1)).every((p) => p.modelClass == null), isTrue);
      expect((await db.sessionById(t1))!.analysisStatus, isNull);
    }

    test('a class the model map does not know', () async {
      await expectRejected(_file([await _resultsFor(db, t1, (m, i) => i == 3 ? 'unicorn' : 'sand')]));
    });

    test('a model with no category map', () async {
      await expectRejected(_file([await _resultsFor(db, t1, _reef)], modelId: 'some-other-model'));
    });

    test('a different point seed (points were sampled differently)', () async {
      final r = await _resultsFor(db, t1, _reef);
      await expectRejected(_file([TransectResults(sessionId: t1, pointSeed: r.pointSeed + 1, frames: r.frames)]));
    });

    test('an unknown transect', () async {
      final r = await _resultsFor(db, t1, _reef);
      await expectRejected(_file([TransectResults(sessionId: 999, pointSeed: r.pointSeed, frames: r.frames)]));
    });

    test('a frame of another transect', () async {
      final t2 = await db.insertSession(_transect(stationId, 2));
      final other = await db.insertFrame(_frame(t2, 0));
      final r = await _resultsFor(db, t1, _reef);
      final wrong = FrameResults(frameId: other, corners: _corners, points: r.frames.first.points);
      await expectRejected(_file([TransectResults(sessionId: t1, pointSeed: r.pointSeed, frames: [wrong])]));
    });

    test('a point of another frame', () async {
      final r = await _resultsFor(db, t1, _reef);
      final swapped = FrameResults(frameId: r.frames.first.frameId, corners: _corners, points: r.frames.last.points);
      await expectRejected(_file([TransectResults(sessionId: t1, pointSeed: r.pointSeed, frames: [swapped])]));
    });

    test('a bad second transect, even when the first is fine', () async {
      final t2 = await db.insertSession(_transect(stationId, 2));
      await db.insertFrame(_frame(t2, 0));
      await db.ensureFramePoints(t2);
      final good = await _resultsFor(db, t1, _reef);
      final bad = await _resultsFor(db, t2, (m, i) => 'unicorn');
      await expectRejected(_file([good, bad]));
    });

    test("another station's transects, when imported on this station's screen", () async {
      final other = await db.insertStation(_station());
      final r = await _resultsFor(db, t1, _reef);
      await expectLater(db.applyAnalysisResults(_file([r]), at: _at, stationId: other), throwsArgumentError);
      expect((await db.pointsForSession(t1)).every((p) => p.modelClass == null), isTrue);
      // The right station accepts the same file.
      await db.applyAnalysisResults(_file([r]), at: _at, stationId: stationId);
      expect((await db.sessionById(t1))!.analysisStatus, AnalysisStatus.done);
    });

    test('a colony-count transect', () async {
      final colonyStation = await db.insertStation(_station(type: SurveyType.colonyCount));
      final colony = await db.insertSession(_transect(colonyStation, 1));
      final r = await _resultsFor(db, t1, _reef);
      await expectRejected(_file([r, TransectResults(sessionId: colony, pointSeed: 1, frames: const [])]));
    });
  });
}
