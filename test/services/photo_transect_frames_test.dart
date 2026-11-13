import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:reefsight_mobile/services/frame_point.dart';
import 'package:reefsight_mobile/services/photo_transect_store.dart';
import 'package:reefsight_mobile/services/session_files.dart';
import 'package:reefsight_mobile/services/transect_cover.dart';
import 'package:reefsight_mobile/services/station.dart';
import 'package:reefsight_mobile/services/transect_database.dart';
import 'package:reefsight_mobile/services/transect_frame.dart';
import 'package:reefsight_mobile/services/transect_session.dart';

// Issue #4: storing photo-transect stills -- one `transect_frames` row per
// meter, a retake replaces the row (and its points), a missing meter is an
// excluded row with no image, and the files live under `transect_photos/`.

Station _station(SurveyType type) => Station(
      code: 'ALG-S1',
      surveyType: type,
      frameMode: type == SurveyType.photoTransect ? FrameMode.physical : null,
      surveyedOn: DateTime(2026, 11, 15),
      siteName: 'Alegria MPA',
      createdAt: DateTime.utc(2026, 11, 15, 1),
    );

TransectSession _transect(int stationId) => TransectSession(
      startedAt: DateTime.utc(2026, 11, 15, 2),
      tapeLengthMeters: 50,
      stationId: stationId,
      transectNumber: 1,
      captureSource: CaptureSource.inAppPhotos,
    );

TransectFrame _still(int sessionId, double meter, String path, {double tilt = 2}) => TransectFrame(
      sessionId: sessionId,
      meterMark: meter,
      imagePath: path,
      source: FrameSource.inApp,
      widthPx: 4032,
      heightPx: 3024,
      capturedAt: DateTime.utc(2026, 11, 15, 2, 10),
      tiltDeg: tilt,
    );

/// A minimal JPEG: SOI, an APP0 segment, then SOF0 with the given size.
Uint8List _jpegHeader(int width, int height, {int sof = 0xC0}) => Uint8List.fromList([
      0xFF, 0xD8, // SOI
      0xFF, 0xE0, 0x00, 0x06, 0x4A, 0x46, 0x49, 0x46, // APP0, length 6
      0xFF, sof, 0x00, 0x11, 0x08, // SOFn, length 17, precision 8
      height >> 8, height & 0xFF, width >> 8, width & 0xFF,
      0x03, 0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01,
      0xFF, 0xD9,
    ]);

void main() {
  group('TransectFrame.missingMeter', () {
    test('is an excluded row with no image', () {
      final f = TransectFrame.missingMeter(sessionId: 3, meterMark: 17);
      expect(f.isMissing, isTrue);
      expect(f.excluded, isTrue);
      expect(f.excludeReason, kMissingMeterReason);
      expect(f.imagePath, isEmpty);
      expect(f.source, FrameSource.inApp);
    });

    test('a captured still is not missing, and neither is an excluded one', () {
      expect(_still(3, 1, 'a.jpg').isMissing, isFalse);
      final excluded = TransectFrame.fromMap(
        _still(3, 1, 'a.jpg').toMap()
          ..['excluded'] = 1
          ..['exclude_reason'] = 'blurred',
      );
      expect(excluded.isMissing, isFalse);
    });

    test('survives a round trip through the row map', () {
      final back = TransectFrame.fromMap(
        TransectFrame.missingMeter(sessionId: 3, meterMark: 17).toMap()..['id'] = 9,
      );
      expect(back.isMissing, isTrue);
      expect(back.meterMark, 17);
    });
  });

  group('TransectDatabase.replaceFrameAtMeter', () {
    late TransectDatabase db;
    late int sessionId;

    setUp(() async {
      db = await TransectDatabase.openInMemoryForTest();
      final stationId = await db.insertStation(_station(SurveyType.photoTransect));
      sessionId = await db.insertSession(_transect(stationId));
    });
    tearDown(() => db.close());

    test('a first capture inserts, and nothing was replaced', () async {
      final result = await db.replaceFrameAtMeter(_still(sessionId, 0, 'p/m0.jpg'));
      expect(result.replaced, isNull);
      final frames = await db.framesForSession(sessionId);
      expect(frames.single.id, result.id);
      expect(frames.single.tiltDeg, 2);
    });

    test('a retake replaces the row at that meter and hands back the old one', () async {
      await db.replaceFrameAtMeter(_still(sessionId, 4, 'p/m4_a.jpg', tilt: 9));
      await db.replaceFrameAtMeter(_still(sessionId, 5, 'p/m5.jpg'));
      final retake = await db.replaceFrameAtMeter(_still(sessionId, 4, 'p/m4_b.jpg', tilt: 1));

      expect(retake.replaced?.imagePath, 'p/m4_a.jpg');
      final frames = await db.framesForSession(sessionId);
      expect(frames.map((f) => f.meterMark), [4, 5]);
      expect(frames.first.imagePath, 'p/m4_b.jpg');
      expect(frames.first.tiltDeg, 1);
    });

    test("a retake drops the old frame's points with it", () async {
      final first = await db.replaceFrameAtMeter(_still(sessionId, 4, 'p/m4_a.jpg'));
      await db.insertFramePoints([
        for (var i = 0; i < 10; i++) FramePoint(frameId: first.id, pointIndex: i, xNorm: 0.5, yNorm: 0.5),
      ]);
      final retake = await db.replaceFrameAtMeter(_still(sessionId, 4, 'p/m4_b.jpg'));

      expect(await db.pointsForFrame(first.id), isEmpty);
      expect(await db.pointsForFrame(retake.id), isEmpty);
      expect(await db.pointsForSession(sessionId), isEmpty);
    });

    test("a retake clears the transect's cached cover, which was worked out from the old image", () async {
      await db.replaceFrameAtMeter(_still(sessionId, 4, 'p/m4_a.jpg'));
      await db.replaceTransectCover(sessionId, [
        TransectCoverRow(sessionId: sessionId, categoryCode: 'HC', points: 4, totalPoints: 10, percent: 40),
      ]);
      await db.replaceFrameAtMeter(_still(sessionId, 4, 'p/m4_b.jpg'));
      expect(await db.coverForSession(sessionId), isEmpty);
    });

    test('a first capture leaves the cover alone (nothing it was worked out from changed)', () async {
      await db.replaceTransectCover(sessionId, [
        TransectCoverRow(sessionId: sessionId, categoryCode: 'HC', points: 4, totalPoints: 10, percent: 40),
      ]);
      await db.replaceFrameAtMeter(_still(sessionId, 9, 'p/m9.jpg'));
      expect(await db.coverForSession(sessionId), hasLength(1));
    });

    test('a meter can be marked missing, and a missing meter captured later', () async {
      await db.replaceFrameAtMeter(_still(sessionId, 7, 'p/m7.jpg'));
      final missing = await db.replaceFrameAtMeter(TransectFrame.missingMeter(sessionId: sessionId, meterMark: 7));
      expect(missing.replaced?.imagePath, 'p/m7.jpg');
      expect((await db.framesForSession(sessionId)).single.isMissing, isTrue);

      final captured = await db.replaceFrameAtMeter(_still(sessionId, 7, 'p/m7_b.jpg'));
      expect(captured.replaced?.isMissing, isTrue);
      expect((await db.framesForSession(sessionId)).single.isMissing, isFalse);
    });

    test('another transect at the same meter is untouched', () async {
      final otherStation = await db.insertStation(_station(SurveyType.photoTransect));
      final other = await db.insertSession(_transect(otherStation));
      await db.replaceFrameAtMeter(_still(other, 3, 'o/m3.jpg'));
      final result = await db.replaceFrameAtMeter(_still(sessionId, 3, 'p/m3.jpg'));

      expect(result.replaced, isNull);
      expect((await db.framesForSession(other)).single.imagePath, 'o/m3.jpg');
    });

    test('a frame without a meter mark is rejected', () async {
      final videoFrame = TransectFrame(
        sessionId: sessionId,
        videoTimeMs: 1000,
        imagePath: 'v.jpg',
        source: FrameSource.videoFrame,
      );
      expect(() => db.replaceFrameAtMeter(videoFrame), throwsArgumentError);
    });

    test('a colony-count transect still takes no frames (#3)', () async {
      final colonyStation = await db.insertStation(_station(SurveyType.colonyCount));
      final colony = await db.insertSession(_transect(colonyStation));
      expect(() => db.replaceFrameAtMeter(_still(colony, 0, 'c.jpg')), throwsArgumentError);
    });
  });

  group('jpegPixelSize', () {
    test('reads the size from a baseline SOF0', () {
      expect(jpegPixelSize(_jpegHeader(4032, 3024)), (width: 4032, height: 3024));
    });

    test('reads a progressive SOF2 too', () {
      expect(jpegPixelSize(_jpegHeader(1920, 1080, sof: 0xC2)), (width: 1920, height: 1080));
    });

    test('is null for something that is not a JPEG, or is cut short', () {
      expect(jpegPixelSize(Uint8List.fromList([0x89, 0x50, 0x4E, 0x47])), isNull);
      expect(jpegPixelSize(Uint8List.sublistView(_jpegHeader(4032, 3024), 0, 14)), isNull);
      expect(jpegPixelSize(Uint8List(0)), isNull);
    });
  });

  group('PhotoTransectStore', () {
    late Directory docs;
    late File capture;

    setUp(() {
      docs = Directory.systemTemp.createTempSync('reefsight_photo_store_');
      capture = File(p.join(docs.path, 'tmp_capture.jpg'))..writeAsBytesSync(_jpegHeader(4032, 3024));
    });
    tearDown(() => docs.deleteSync(recursive: true));

    test('saves a still under transect_photos with a relative path, and reads its size', () async {
      final store = PhotoTransectStore(documentsDirectory: docs.path, sessionId: 12);
      final saved = await store.save(capture.path, meterMark: 3, at: DateTime.utc(2026, 11, 15, 2, 0, 5));

      expect(saved.relativePath, startsWith('transect_photos/session12_m03_'));
      expect(saved.relativePath, endsWith('.jpg'));
      expect(File(store.absolutePath(saved.relativePath)).existsSync(), isTrue);
      expect(saved.width, 4032);
      expect(saved.height, 3024);
      expect(capture.existsSync(), isFalse, reason: 'the camera temp file is moved, not copied');
      expect(Directory(p.join(docs.path, 'transect_photos')).listSync().where((e) => e.path.endsWith('.tmp')),
          isEmpty);
    });

    test('two shots of the same meter get different files, so a retake never overwrites', () async {
      final store = PhotoTransectStore(documentsDirectory: docs.path, sessionId: 12);
      final a = await store.save(capture.path, meterMark: 3, at: DateTime.utc(2026, 11, 15, 2, 0, 5));
      capture.writeAsBytesSync(_jpegHeader(4032, 3024));
      final b = await store.save(capture.path, meterMark: 3, at: DateTime.utc(2026, 11, 15, 2, 0, 9));
      expect(a.relativePath, isNot(b.relativePath));
    });

    test('delete removes a stored file, and an empty or absent path is fine', () async {
      final store = PhotoTransectStore(documentsDirectory: docs.path, sessionId: 12);
      final saved = await store.save(capture.path, meterMark: 3, at: DateTime.utc(2026, 11, 15, 2));
      await store.delete(saved.relativePath);
      expect(File(store.absolutePath(saved.relativePath)).existsSync(), isFalse);
      await store.delete('');
      await store.delete('transect_photos/session12_m99_0.jpg');
    });

    test('a meter mark of 50 is zero-padded to two digits', () async {
      final store = PhotoTransectStore(documentsDirectory: docs.path, sessionId: 1);
      final saved = await store.save(capture.path, meterMark: 50, at: DateTime.utc(2026, 11, 15, 2));
      expect(p.posix.basename(saved.relativePath), startsWith('session1_m50_'));
    });

    test("deleting a survey sweeps its photos, and only its own", () async {
      final store = PhotoTransectStore(documentsDirectory: docs.path, sessionId: 12);
      final mine = await store.save(capture.path, meterMark: 0, at: DateTime.utc(2026, 11, 15, 2));
      final other = File(p.join(docs.path, PhotoTransectStore.folder, 'session13_m00_1.jpg'))
        ..writeAsBytesSync([1]);

      final removed = await deleteSessionFiles(
        TransectSession(
          id: 12,
          startedAt: DateTime.utc(2026, 11, 15, 2),
          endedAt: DateTime.utc(2026, 11, 15, 3),
          tapeLengthMeters: 50,
        ),
        documentsDirectory: docs.path,
      );
      expect(removed, 1);
      expect(File(store.absolutePath(mine.relativePath)).existsSync(), isFalse);
      expect(other.existsSync(), isTrue);
    });
  });
}
