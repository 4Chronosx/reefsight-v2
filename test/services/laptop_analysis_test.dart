import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:reefsight_mobile/services/analysis_manifest.dart';
import 'package:reefsight_mobile/services/coralscapes_mapping.dart';
import 'package:reefsight_mobile/services/cover_calculator.dart';
import 'package:reefsight_mobile/services/laptop_analysis.dart';
import 'package:reefsight_mobile/services/station.dart';
import 'package:reefsight_mobile/services/transect_cover.dart';
import 'package:reefsight_mobile/services/transect_database.dart';
import 'package:reefsight_mobile/services/transect_frame.dart';
import 'package:reefsight_mobile/services/transect_session.dart';

// Issue #7: the station package (zip) the laptop notebook reads, and the
// import of its results file -- end to end, with a stand-in for the notebook
// that answers the exported manifest. Real SQLite and a real temp directory.

const _corners = <NormPoint>[(x: 0.1, y: 0.1), (x: 0.9, y: 0.1), (x: 0.9, y: 0.9), (x: 0.1, y: 0.9)];

Station _station(SurveyType type) => Station(
      code: 'ALG/S1',
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

/// The notebook's part: read the manifest, answer every point.
String _notebookAnswer(Map<String, Object?> manifest, String Function(int index) classOf) => jsonEncode({
      'format': kResultsFormat,
      'version': kAnalysisFormatVersion,
      'run_id': '20261116_101500',
      'model_id': manifest['model_id'],
      'transects': [
        for (final t in (manifest['transects'] as List).cast<Map>())
          {
            'session_id': t['session_id'],
            'point_seed': t['point_seed'],
            'frames': [
              for (final f in (t['frames'] as List).cast<Map>())
                {
                  'frame_id': f['frame_id'],
                  'corners': f['corners'],
                  'points': [
                    for (final pt in (f['points'] as List).cast<Map>())
                      {'point_id': pt['point_id'], 'model_class': classOf(pt['index'] as int), 'confidence': 0.8},
                  ],
                },
            ],
          },
      ],
    });

CoverComputation _cover({required bool complete}) => CoverComputation(
      rows: const [],
      framesScored: 1,
      allPoints: 10,
      excludedPoints: 0,
      unlabeledPoints: complete ? 0 : 10,
    );

void main() {
  late Directory docs;
  late Directory out;
  late TransectDatabase db;

  setUp(() async {
    docs = await Directory.systemTemp.createTemp('reefsight_docs_');
    out = await Directory.systemTemp.createTemp('reefsight_out_');
    db = await TransectDatabase.openInMemoryForTest();
  });
  tearDown(() async {
    await db.closeForTest();
    await docs.delete(recursive: true);
    await out.delete(recursive: true);
  });

  /// A photo station with T1 (2 frames, plus one missing meter) and T2
  /// (1 frame); every photo is a real file under [docs].
  Future<({int station, int t1, int t2})> seed() async {
    final station = await db.insertStation(_station(SurveyType.photoTransect));
    final t1 = await db.insertSession(_transect(station, 1));
    final t2 = await db.insertSession(_transect(station, 2));
    for (final (session, meter) in [(t1, 0.0), (t1, 1.0), (t2, 0.0)]) {
      final rel = 'photo_transects/$session/m$meter.jpg';
      final file = File(p.join(docs.path, rel));
      await file.create(recursive: true);
      await file.writeAsBytes([0xFF, 0xD8, session, meter.toInt(), 0xFF, 0xD9]);
      await db.insertFrame(TransectFrame(
        sessionId: session,
        meterMark: meter,
        imagePath: rel,
        source: FrameSource.inApp,
        widthPx: 4032,
        heightPx: 3024,
        corners: _corners,
        cornerSource: CornerSource.manual,
      ));
    }
    await db.insertFrame(TransectFrame.missingMeter(sessionId: t1, meterMark: 2));
    return (station: station, t1: t1, t2: t2);
  }

  Future<AnalysisExport> export(int station) => LaptopAnalysis.exportStation(
        db,
        station,
        documentsPath: docs.path,
        outputDirectory: out,
        now: DateTime.utc(2026, 11, 16, 1),
      );

  Archive unzip(String path) => ZipDecoder().decodeBytes(File(path).readAsBytesSync());

  group('exportStation', () {
    test('writes one zip: a folder with the manifest, a README and every photo', () async {
      final ids = await seed();
      final exported = await export(ids.station);

      expect(p.basename(exported.zipPath), 'ALG_S1_2026-11-15_analysis.zip');
      expect(exported.transects, 2);
      expect(exported.frames, 3);
      expect(exported.points, 30);

      final zip = unzip(exported.zipPath);
      const root = 'ALG_S1_2026-11-15_analysis';
      expect(zip.files.map((f) => f.name).toSet(), {
        '$root/manifest.json',
        '$root/README.txt',
        '$root/photos/T1/m00.jpg',
        '$root/photos/T1/m01.jpg',
        '$root/photos/T2/m00.jpg',
      });
      expect(zip.findFile('$root/photos/T1/m01.jpg')!.content, [0xFF, 0xD8, ids.t1, 1, 0xFF, 0xD9]);

      final manifest = jsonDecode(utf8.decode(zip.findFile('$root/manifest.json')!.content)) as Map;
      expect(manifest['format'], kManifestFormat);
      expect(manifest['model_id'], kCoralscapesModelId);
      expect((manifest['transects'] as List).length, 2);
    });

    test('samples the points first and marks the transects pending', () async {
      final ids = await seed();
      await export(ids.station);
      expect(await db.pointsForSession(ids.t1), hasLength(20));
      final t1 = (await db.sessionById(ids.t1))!;
      expect(t1.pointSeed, isNotNull);
      expect(t1.analysisStatus, AnalysisStatus.pending);
    });

    test('a second export samples nothing new: the same points go out again', () async {
      final ids = await seed();
      await export(ids.station);
      final firstPoints = [for (final pt in await db.pointsForSession(ids.t1)) pt.id];
      await export(ids.station);
      expect([for (final pt in await db.pointsForSession(ids.t1)) pt.id], firstPoints);
    });

    test('a done transect stays done when the station is exported again', () async {
      final ids = await seed();
      await db.setAnalysisStatus(ids.t2, AnalysisStatus.done);
      await export(ids.station);
      expect((await db.sessionById(ids.t2))!.analysisStatus, AnalysisStatus.done);
    });

    test('refuses a colony-count station', () async {
      final station = await db.insertStation(_station(SurveyType.colonyCount));
      await expectLater(export(station), throwsArgumentError);
    });

    test('refuses a station with nothing to score yet', () async {
      final station = await db.insertStation(_station(SurveyType.photoTransect));
      await db.insertSession(_transect(station, 1));
      await expectLater(export(station), throwsStateError);
      expect(out.listSync(), isEmpty);
    });

    test('refuses, leaving no zip behind, when a photo file is missing', () async {
      final ids = await seed();
      await File(p.join(docs.path, 'photo_transects/${ids.t2}/m0.0.jpg')).delete();
      await expectLater(export(ids.station), throwsStateError);
      expect(out.listSync(), isEmpty);
    });
  });

  group('importResults', () {
    test('done when: the notebook answers the export, and cover shows for every transect', () async {
      final ids = await seed();
      final exported = await export(ids.station);
      final zip = unzip(exported.zipPath);
      final manifest = jsonDecode(
        utf8.decode(zip.files.firstWhere((f) => f.name.endsWith('manifest.json')).content),
      ) as Map<String, Object?>;

      // 3 of every 10 points are branching coral, the rest sand.
      final answer = _notebookAnswer(manifest, (i) => i < 3 ? 'branching alive' : 'sand');
      final imports = await LaptopAnalysis.importResults(db, answer, now: DateTime.utc(2026, 11, 16, 9));

      expect(imports.map((i) => i.sessionId), [ids.t1, ids.t2]);
      expect(imports.every((i) => i.complete), isTrue);
      for (final t in [ids.t1, ids.t2]) {
        final hc = (await db.coverForSession(t))
            .singleWhere((r) => r.level == CoverLevel.major && r.categoryCode == 'HC');
        expect(hc.percent, closeTo(30, 1e-9));
        final session = (await db.sessionById(t))!;
        expect(session.analysisStatus, AnalysisStatus.done);
        expect(session.analyzedOn, AnalyzedOn.laptop);
      }
    });

    test('passes the format error through for a file that is not results', () async {
      await expectLater(LaptopAnalysis.importResults(db, '{"format": "reefsight-analysis"}'), throwsFormatException);
    });
  });

  test('describeImport sums up what happened, stale frames included', () {
    expect(
      describeImport([
        AnalysisImport(sessionId: 1, pointsLabeled: 500, staleFrameIds: const [], cover: _cover(complete: true), complete: true),
        AnalysisImport(sessionId: 2, pointsLabeled: 490, staleFrameIds: const [7], cover: _cover(complete: false), complete: false),
      ]),
      '990 points labeled in 2 transects. 1 frame had moved corners and was skipped: '
      'export and analyze again to label it.',
    );
    expect(
      describeImport([
        AnalysisImport(sessionId: 1, pointsLabeled: 500, staleFrameIds: const [], cover: _cover(complete: true), complete: true),
      ]),
      '500 points labeled in 1 transect.',
    );
  });
}
