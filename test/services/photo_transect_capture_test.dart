import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:reefsight_mobile/services/photo_transect_capture.dart';
import 'package:reefsight_mobile/services/photo_transect_store.dart';
import 'package:reefsight_mobile/services/station.dart';
import 'package:reefsight_mobile/services/transect_database.dart';
import 'package:reefsight_mobile/services/transect_frame.dart';
import 'package:reefsight_mobile/services/transect_session.dart';

// Issue #4: the capture flow's state -- one still per meter mark along the
// tape, a meter counter that moves on to the next one still to do, retake,
// mark missing, resume after leaving, and finishing the transect.

Uint8List _jpeg(int width, int height) => Uint8List.fromList([
      0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x11, 0x08, //
      height >> 8, height & 0xFF, width >> 8, width & 0xFF,
      0x03, 0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01, 0xFF, 0xD9,
    ]);

void main() {
  late Directory docs;
  late TransectDatabase db;
  late int sessionId;
  late PhotoTransectStore store;
  var shots = 0;
  var now = DateTime.utc(2026, 11, 15, 2);

  Future<String> takePicture() async {
    final f = File(p.join(docs.path, 'camera_${shots++}.jpg'))..writeAsBytesSync(_jpeg(4032, 3024));
    return f.path;
  }

  Future<PhotoTransectCapture> capture({double tape = 50}) async {
    final c = PhotoTransectCapture(
      db: db,
      store: store,
      sessionId: sessionId,
      tapeLengthMeters: tape,
      clock: () => now = now.add(const Duration(seconds: 5)),
    );
    await c.load();
    return c;
  }

  setUp(() async {
    docs = Directory.systemTemp.createTempSync('reefsight_capture_');
    db = await TransectDatabase.openInMemoryForTest();
    final stationId = await db.insertStation(Station(
      code: 'ALG-S1',
      surveyType: SurveyType.photoTransect,
      frameMode: FrameMode.physical,
      surveyedOn: DateTime(2026, 11, 15),
      siteName: 'Alegria MPA',
      createdAt: DateTime.utc(2026, 11, 15, 1),
    ));
    sessionId = await db.insertSession(TransectSession(
      startedAt: DateTime.utc(2026, 11, 15, 2),
      tapeLengthMeters: 50,
      stationId: stationId,
      transectNumber: 1,
      captureSource: CaptureSource.inAppPhotos,
    ));
    store = PhotoTransectStore(documentsDirectory: docs.path, sessionId: sessionId);
  });
  tearDown(() async {
    await db.close();
    docs.deleteSync(recursive: true);
  });

  test('a 50 m tape has 51 meter marks, 0 to 50, all to do, starting at 0', () async {
    final c = await capture();
    expect(c.meters.length, 51);
    expect(c.meters.first, 0);
    expect(c.meters.last, 50);
    expect(c.current, 0);
    expect(c.pendingCount, 51);
    expect(c.isComplete, isFalse);
  });

  test('a shorter tape has fewer marks; a fractional length rounds down', () async {
    expect((await capture(tape: 20)).meters.length, 21);
    expect((await capture(tape: 30.6)).meters.last, 30);
  });

  test('a shot saves a frame with meter, size, time and tilt, and moves on', () async {
    final c = await capture();
    final frame = await c.capture(takePicture, tiltDeg: 3.4);

    expect(frame.meterMark, 0);
    expect(frame.source, FrameSource.inApp);
    expect(frame.widthPx, 4032);
    expect(frame.heightPx, 3024);
    expect(frame.tiltDeg, 3.4);
    expect(frame.capturedAt, isNotNull);
    expect(File(store.absolutePath(frame.imagePath)).existsSync(), isTrue);

    expect(c.statusOf(0), MeterStatus.captured);
    expect(c.current, 1);
    final saved = (await db.framesForSession(sessionId)).single;
    expect(saved.id, frame.id);
    expect(saved.tiltDeg, 3.4);
  });

  test('without a tilt reading the frame is still saved, with no tilt', () async {
    final c = await capture();
    final frame = await c.capture(takePicture);
    expect(frame.tiltDeg, isNull);
  });

  test('a retake replaces the photo at that meter and deletes the old file', () async {
    final c = await capture();
    final first = await c.capture(takePicture, tiltDeg: 12);
    await c.capture(takePicture);
    c.select(0);
    final retake = await c.capture(takePicture, tiltDeg: 1);

    expect(File(store.absolutePath(first.imagePath)).existsSync(), isFalse);
    expect(File(store.absolutePath(retake.imagePath)).existsSync(), isTrue);
    final frames = await db.framesForSession(sessionId);
    expect(frames.length, 2);
    expect(frames.first.tiltDeg, 1);
    expect(c.current, 2, reason: 'after a retake it goes back to the next meter still to do');
  });

  test('marking a meter missing records it, drops any photo there, and moves on', () async {
    final c = await capture();
    final shot = await c.capture(takePicture);
    c.select(0);
    await c.markMissing();

    expect(c.statusOf(0), MeterStatus.missing);
    expect(File(store.absolutePath(shot.imagePath)).existsSync(), isFalse);
    expect((await db.framesForSession(sessionId)).single.isMissing, isTrue);
    expect(c.current, 1);
  });

  test('the counter skips meters already done and wraps back to an earlier gap', () async {
    final c = await capture(tape: 3);
    c.select(1);
    await c.capture(takePicture);
    expect(c.current, 2);
    await c.capture(takePicture);
    expect(c.current, 3);
    await c.capture(takePicture);
    expect(c.current, 0, reason: 'meter 0 is the only one left');
    await c.markMissing();
    expect(c.isComplete, isTrue);
    expect(c.current, 0, reason: 'nothing left to do: it stays put');
    expect(c.capturedCount, 3);
    expect(c.missingCount, 1);
  });

  test('select, next and previous stay within the tape', () async {
    final c = await capture(tape: 2);
    c.previous();
    expect(c.current, 0);
    c.next();
    c.next();
    c.next();
    expect(c.current, 2);
    expect(() => c.select(7), throwsArgumentError);
  });

  test('leaving and coming back resumes at the first meter still to do', () async {
    final first = await capture();
    await first.capture(takePicture);
    await first.capture(takePicture);
    await first.markMissing();

    final resumed = await capture();
    expect(resumed.capturedCount, 2);
    expect(resumed.missingCount, 1);
    expect(resumed.current, 3);
    expect(resumed.frameAt(0)?.imagePath, isNotEmpty);
  });

  test('a failed database write deletes the new file and keeps the meter as it was', () async {
    final c = await capture();
    await db.close();
    await expectLater(c.capture(takePicture), throwsA(anything));
    expect(Directory(p.join(docs.path, PhotoTransectStore.folder)).listSync(), isEmpty);
    expect(c.statusOf(0), MeterStatus.pending);
    expect(c.current, 0);
    expect(c.busy, isFalse);
    db = await TransectDatabase.openInMemoryForTest(); // for tearDown
  });

  test('a second shot while one is saving is refused', () async {
    final c = await capture();
    final a = c.capture(takePicture);
    await expectLater(c.capture(takePicture), throwsStateError);
    await a;
  });

  test('finishing closes the transect', () async {
    final c = await capture();
    await c.capture(takePicture);
    await c.finish();
    expect((await db.sessionById(sessionId))!.endedAt, isNotNull);
  });

  test('listeners hear every change', () async {
    final c = await capture();
    var heard = 0;
    c.addListener(() => heard++);
    c.select(4);
    await c.capture(takePicture);
    expect(heard, greaterThanOrEqualTo(2));
  });
}
