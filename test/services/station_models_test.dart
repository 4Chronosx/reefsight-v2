import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/services/category_mapping.dart';
import 'package:reefsight_mobile/services/frame_point.dart';
import 'package:reefsight_mobile/services/geo_fix.dart';
import 'package:reefsight_mobile/services/station.dart';
import 'package:reefsight_mobile/services/transect_cover.dart';
import 'package:reefsight_mobile/services/transect_frame.dart';
import 'package:reefsight_mobile/services/transect_session.dart';

// Issue #1 (schema v11): the map round trips of the station-era models,
// without a database. `transect_database_v11_test.dart` covers the SQL side.

void main() {
  group('Station', () {
    final fix = GeoFix(
      lat: 10.2536,
      lon: 123.9497,
      accuracyM: 6,
      at: DateTime.utc(2026, 11, 15, 1, 30),
      source: GeoFixSource.gps,
    );

    Station full() => Station(
          id: 3,
          code: 'ALG-S1',
          name: 'Alegria north',
          surveyType: SurveyType.photoTransect,
          frameMode: FrameMode.importedMixed,
          surveyedOn: DateTime(2026, 11, 15),
          siteName: 'Alegria MPA',
          reefZone: ReefZone.upperSlope,
          depthMinM: 3.5,
          depthMaxM: 5.8,
          deepEdgeFix: fix,
          markerPlaced: true,
          observerName: 'C. Zaballa',
          notes: 'Calm, good visibility',
          createdAt: DateTime.utc(2026, 11, 15, 1),
        );

    test('round-trips every field', () {
      final back = Station.fromMap(full().toMap());
      expect(back.id, 3);
      expect(back.code, 'ALG-S1');
      expect(back.name, 'Alegria north');
      expect(back.surveyType, SurveyType.photoTransect);
      expect(back.frameMode, FrameMode.importedMixed);
      expect(back.surveyedOn, DateTime(2026, 11, 15));
      expect(back.siteName, 'Alegria MPA');
      expect(back.reefZone, ReefZone.upperSlope);
      expect(back.depthMinM, 3.5);
      expect(back.depthMaxM, 5.8);
      expect(back.deepEdgeFix, fix);
      expect(back.markerPlaced, isTrue);
      expect(back.observerName, 'C. Zaballa');
      expect(back.notes, 'Calm, good visibility');
      expect(back.createdAt, DateTime.utc(2026, 11, 15, 1));
    });

    test('stores bulletin values, a plain date and the deep-edge GeoFix columns', () {
      final map = full().toMap();
      expect(map['survey_type'], 'photo_transect');
      expect(map['frame_mode'], 'imported_mixed');
      expect(map['reef_zone'], 'upper_slope');
      expect(map['surveyed_on'], '2026-11-15');
      expect(map['marker_placed'], 1);
      expect(map['deep_edge_lat'], 10.2536);
      expect(map['deep_edge_source'], 'gps');
    });

    test('optional fields read back null', () {
      final back = Station.fromMap(
        Station(
          code: 'ALG-S2',
          surveyType: SurveyType.colonyCount,
          surveyedOn: DateTime(2026, 11, 15),
          createdAt: DateTime.utc(2026, 11, 15),
        ).toMap(),
      );
      expect(back.frameMode, isNull);
      expect(back.reefZone, isNull);
      expect(back.deepEdgeFix, isNull);
      expect(back.markerPlaced, isNull);
    });

    test('an unknown reef zone reads back null instead of throwing', () {
      final map = full().toMap()..['reef_zone'] = 'back_reef';
      expect(Station.fromMap(map).reefZone, isNull);
    });
  });

  group('TransectSession v11 fields', () {
    test('round-trip', () {
      final session = TransectSession(
        startedAt: DateTime.utc(2026, 11, 15, 2),
        tapeLengthMeters: 50,
        stationId: 7,
        transectNumber: 2,
        captureSource: CaptureSource.importedPhotos,
        depthStartM: 4.2,
        depthEndM: 5.1,
        randomAlongM: 31.5,
        randomSwimoutM: 12.0,
        pointsPerFrame: 10,
        pointSeed: 123456789,
        analysisStatus: AnalysisStatus.done,
        analyzedAt: DateTime.utc(2026, 11, 16, 9),
        modelId: 'coralscapesv2-segformer-b5',
        analyzedOn: AnalyzedOn.laptop,
      );

      final map = session.toMap();
      expect(map['capture_source'], 'imported_photos');
      expect(map['analysis_status'], 'done');
      expect(map['analyzed_on'], 'laptop');

      final back = TransectSession.fromMap(map);
      expect(back.stationId, 7);
      expect(back.transectNumber, 2);
      expect(back.captureSource, CaptureSource.importedPhotos);
      expect(back.depthStartM, 4.2);
      expect(back.depthEndM, 5.1);
      expect(back.randomAlongM, 31.5);
      expect(back.randomSwimoutM, 12.0);
      expect(back.pointsPerFrame, 10);
      expect(back.pointSeed, 123456789);
      expect(back.analysisStatus, AnalysisStatus.done);
      expect(back.analyzedAt, DateTime.utc(2026, 11, 16, 9));
      expect(back.modelId, 'coralscapesv2-segformer-b5');
      expect(back.analyzedOn, AnalyzedOn.laptop);
    });

    test('a legacy session has every v11 field null', () {
      final back = TransectSession.fromMap(
        TransectSession(startedAt: DateTime.utc(2026, 1, 1), tapeLengthMeters: 50).toMap(),
      );
      expect(back.stationId, isNull);
      expect(back.transectNumber, isNull);
      expect(back.captureSource, isNull);
      expect(back.analysisStatus, isNull);
      expect(back.analyzedOn, isNull);
    });

    test('copyWith carries the v11 fields', () {
      final session = TransectSession(
        startedAt: DateTime.utc(2026, 1, 1),
        tapeLengthMeters: 50,
        stationId: 1,
        transectNumber: 1,
      );
      final copy = session.copyWith(transectNumber: 3);
      expect(copy.stationId, 1);
      expect(copy.transectNumber, 3);
    });
  });

  group('TransectFrame', () {
    const corners = [
      (x: 0.1, y: 0.1),
      (x: 0.9, y: 0.12),
      (x: 0.88, y: 0.9),
      (x: 0.11, y: 0.92),
    ];

    test('round-trips, with corners as JSON', () {
      final frame = TransectFrame(
        id: 5,
        sessionId: 2,
        meterMark: 12,
        imagePath: 'station1/t2/m12.jpg',
        source: FrameSource.imported,
        widthPx: 4000,
        heightPx: 3000,
        cameraMake: 'OM Digital',
        cameraModel: 'TG-7',
        capturedAt: DateTime.utc(2026, 11, 15, 2, 5),
        corners: corners,
        cornerSource: CornerSource.manual,
        tiltDeg: 4.5,
        distanceM: 1.2,
        distanceMethod: DistanceMethod.tape,
        checksPassed: true,
        fisheyeFlag: false,
        excluded: true,
        excludeReason: 'blurred',
      );

      final map = frame.toMap();
      expect(map['source'], 'imported');
      expect(map['corner_source'], 'manual');
      expect(map['corners_json'], isA<String>());
      expect(map['excluded'], 1);

      final back = TransectFrame.fromMap(map);
      expect(back.id, 5);
      expect(back.sessionId, 2);
      expect(back.meterMark, 12);
      expect(back.videoTimeMs, isNull);
      expect(back.imagePath, 'station1/t2/m12.jpg');
      expect(back.source, FrameSource.imported);
      expect(back.widthPx, 4000);
      expect(back.heightPx, 3000);
      expect(back.cameraMake, 'OM Digital');
      expect(back.cameraModel, 'TG-7');
      expect(back.capturedAt, DateTime.utc(2026, 11, 15, 2, 5));
      expect(back.corners, corners);
      expect(back.cornerSource, CornerSource.manual);
      expect(back.tiltDeg, 4.5);
      expect(back.distanceM, 1.2);
      expect(back.distanceMethod, DistanceMethod.tape);
      expect(back.checksPassed, isTrue);
      expect(back.fisheyeFlag, isFalse);
      expect(back.excluded, isTrue);
      expect(back.excludeReason, 'blurred');
    });

    test('defaults to not excluded, with no corners', () {
      final back = TransectFrame.fromMap(
        TransectFrame(
          sessionId: 1,
          videoTimeMs: 4500,
          imagePath: 'f.jpg',
          source: FrameSource.videoFrame,
        ).toMap(),
      );
      expect(back.excluded, isFalse);
      expect(back.corners, isNull);
      expect(back.checksPassed, isNull);
    });

    test('rejects anything but four corners', () {
      expect(
        () => TransectFrame(
          sessionId: 1,
          imagePath: 'f.jpg',
          source: FrameSource.inApp,
          corners: corners.sublist(0, 3),
        ),
        throwsArgumentError,
      );
    });
  });

  group('FramePoint', () {
    test('round-trips', () {
      final point = FramePoint(
        id: 9,
        frameId: 4,
        pointIndex: 3,
        xNorm: 0.25,
        yNorm: 0.75,
        modelClass: 'branching bleached',
        modelConfidence: 0.82,
        categoryCode: 'BLEC',
        expertCategoryCode: 'CB',
        expertName: 'J. Reviewer',
        reviewedAt: DateTime.utc(2026, 11, 20),
      );
      final back = FramePoint.fromMap(point.toMap());
      expect(back.id, 9);
      expect(back.frameId, 4);
      expect(back.pointIndex, 3);
      expect(back.xNorm, 0.25);
      expect(back.yNorm, 0.75);
      expect(back.modelClass, 'branching bleached');
      expect(back.modelConfidence, 0.82);
      expect(back.categoryCode, 'BLEC');
      expect(back.expertCategoryCode, 'CB');
      expect(back.expertName, 'J. Reviewer');
      expect(back.reviewedAt, DateTime.utc(2026, 11, 20));
    });

    test('effectiveCategoryCode prefers the expert correction', () {
      final model = FramePoint(frameId: 1, pointIndex: 0, xNorm: 0.5, yNorm: 0.5, categoryCode: 'DC');
      expect(model.effectiveCategoryCode, 'DC');
      final corrected = FramePoint.fromMap(model.toMap()..['expert_category_code'] = 'S');
      expect(corrected.effectiveCategoryCode, 'S');
    });

    test('rejects a position outside the frame', () {
      expect(
        () => FramePoint(frameId: 1, pointIndex: 0, xNorm: 1.2, yNorm: 0.5),
        throwsArgumentError,
      );
      expect(
        () => FramePoint(frameId: 1, pointIndex: -1, xNorm: 0.5, yNorm: 0.5),
        throwsArgumentError,
      );
    });
  });

  group('CategoryMapping and TransectCoverRow', () {
    test('CategoryMapping round-trips', () {
      const mapping = CategoryMapping(
        modelId: 'coralscapesv2-segformer-b5',
        modelClass: 'transect tools',
        categoryCode: 'TWB',
        majorCategory: 'TWB',
        excluded: true,
      );
      final back = CategoryMapping.fromMap(mapping.toMap());
      expect(back, mapping);
      expect(mapping.toMap()['excluded'], 1);
    });

    test('TransectCoverRow round-trips', () {
      final row = TransectCoverRow(
        sessionId: 2,
        categoryCode: 'HC',
        points: 120,
        totalPoints: 480,
        percent: 25,
        usesExpert: true,
      );
      final back = TransectCoverRow.fromMap(row.toMap());
      expect(back, row);
    });

    test('TransectCoverRow rejects points outside 0..totalPoints', () {
      expect(
        () => TransectCoverRow(
          sessionId: 1,
          categoryCode: 'HC',
          points: 5,
          totalPoints: 4,
          percent: 125,
        ),
        throwsArgumentError,
      );
    });
  });
}
