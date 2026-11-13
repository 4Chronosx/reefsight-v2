import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/screens/photo_transect_capture_screen.dart';
import 'package:reefsight_mobile/services/station.dart';
import 'package:reefsight_mobile/services/transect_database.dart';
import 'package:reefsight_mobile/services/transect_session.dart';

import '../support/fake_capture.dart';

// Issue #4: the capture screen with a fake camera and tilt source -- meter
// counter, level readout, shutter, mark missing, review and finish. File
// writes are real, so taps that save run inside `runAsync`.

void main() {
  late Directory docs;
  late TransectDatabase db;
  late Station station;
  late int sessionId;
  late FakeStillCamera camera;
  late FakeTiltSource tilt;
  late FakeScreenAwake awake;

  setUp(() async {
    docs = Directory.systemTemp.createTempSync('reefsight_capture_screen_');
    db = await TransectDatabase.openInMemoryForTest(ignoreClose: true);
    final stationId = await db.insertStation(Station(
      code: 'ALG-S1',
      surveyType: SurveyType.photoTransect,
      frameMode: FrameMode.physical,
      surveyedOn: DateTime(2026, 11, 15),
      siteName: 'Alegria MPA',
      createdAt: DateTime.utc(2026, 11, 15, 1),
    ));
    station = (await db.stationById(stationId))!;
    sessionId = await db.insertSession(TransectSession(
      startedAt: DateTime.utc(2026, 11, 15, 2),
      tapeLengthMeters: 50,
      stationId: stationId,
      transectNumber: 2,
      captureSource: CaptureSource.inAppPhotos,
    ));
    camera = FakeStillCamera(docs);
    tilt = FakeTiltSource();
    awake = FakeScreenAwake();
  });
  tearDown(() async {
    await db.closeForTest();
    try {
      docs.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows: the review's Image.file can still hold a thumbnail open.
    }
  });

  Widget screen({bool cameraFails = false}) => MaterialApp(
        home: PhotoTransectCaptureScreen(
          station: station,
          sessionId: sessionId,
          transectNumber: 2,
          openDatabase: () async => db,
          cameraOpener: FakeStillCameraOpener(camera, fail: cameraFails),
          tiltSource: tilt,
          screenAwake: awake,
          documentsDirectory: () async => docs.path,
        ),
      );

  Future<void> open(WidgetTester tester, {bool cameraFails = false}) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(screen(cameraFails: cameraFails));
    await tester.pumpAndSettle();
  }

  /// Taps [finder] and lets the real file and DB work finish.
  Future<void> tapAndSave(WidgetTester tester, Finder finder) async {
    await tester.runAsync(() async {
      await tester.tap(finder);
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
  }

  testWidgets('shows the station, meter counter and live tilt, and keeps the screen awake', (tester) async {
    await open(tester);
    expect(find.text('ALG-S1 · T2'), findsOneWidget);
    expect(find.byKey(const ValueKey('meter-counter')), findsOneWidget);
    expect(find.text('0 m'), findsOneWidget);
    expect(find.text('0 of 51 done'), findsOneWidget);
    expect(awake.enabled, 1);

    tilt.controller.add(3.04);
    await tester.pump();
    expect(find.text('3.0°'), findsOneWidget);
    expect(find.text('Level'), findsOneWidget);

    tilt.controller.add(14);
    await tester.pump();
    expect(find.text('14.0°'), findsOneWidget);
    expect(find.text('Tilted'), findsOneWidget);
  });

  testWidgets('the shutter saves the still with the tilt and moves to the next meter', (tester) async {
    await open(tester);
    tilt.controller.add(2.5);
    await tester.pump();

    await tapAndSave(tester, find.byKey(const ValueKey('shutter')));

    expect(find.text('1 m'), findsOneWidget);
    expect(find.text('1 of 51 done'), findsOneWidget);
    final frames = await tester.runAsync(() => db.framesForSession(sessionId));
    expect(frames!.single.meterMark, 0);
    expect(frames.single.tiltDeg, 2.5);
    expect(frames.single.widthPx, 4032);
  });

  testWidgets('a meter can be marked missing', (tester) async {
    await open(tester);
    await tapAndSave(tester, find.byKey(const ValueKey('mark-missing')));
    expect(find.text('1 m'), findsOneWidget);
    final frames = await tester.runAsync(() => db.framesForSession(sessionId));
    expect(frames!.single.isMissing, isTrue);
  });

  testWidgets('review lists each meter with its tilt, and Finish closes the transect', (tester) async {
    await open(tester);
    tilt.controller.add(7);
    await tester.pump();
    await tapAndSave(tester, find.byKey(const ValueKey('shutter')));
    await tapAndSave(tester, find.byKey(const ValueKey('mark-missing')));

    await tester.tap(find.byKey(const ValueKey('open-review')));
    await tester.pumpAndSettle();
    expect(find.text('m 0'), findsOneWidget);
    expect(find.text('7.0°'), findsWidgets);
    expect(find.text('m 1'), findsOneWidget);
    expect(find.text('Missing'), findsWidgets);
    expect(find.textContaining('1 photo'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('finish-transect')));
    await tester.pumpAndSettle();
    expect(find.text('Finish with meters left?'), findsOneWidget);
    await tapAndSave(tester, find.widgetWithText(TextButton, 'Finish'));
    expect(find.byType(PhotoTransectCaptureScreen), findsNothing, reason: 'Finish leaves capture');
    final session = await tester.runAsync(() => db.sessionById(sessionId));
    expect(session!.endedAt, isNotNull);
  });

  testWidgets('reopening resumes at the first meter still to do', (tester) async {
    await open(tester);
    await tapAndSave(tester, find.byKey(const ValueKey('shutter')));
    await tapAndSave(tester, find.byKey(const ValueKey('shutter')));

    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(camera.disposed, isTrue);
    expect(awake.disabled, greaterThanOrEqualTo(1));

    await tester.pumpWidget(screen());
    await tester.pumpAndSettle();
    expect(find.text('2 m'), findsOneWidget);
    expect(find.text('2 of 51 done'), findsOneWidget);
  });

  testWidgets('a camera that will not open says so, with a retry', (tester) async {
    await open(tester, cameraFails: true);
    expect(find.textContaining('camera permission denied'), findsOneWidget);
    expect(find.widgetWithText(ElevatedButton, 'Try again'), findsOneWidget);
  });

  // Review fix: one stray gloved tap mustn't delete a photo.
  testWidgets('marking a meter that has a photo missing asks first, and Keep photo keeps it', (tester) async {
    await open(tester);
    await tapAndSave(tester, find.byKey(const ValueKey('shutter')));
    await tester.tap(find.byKey(const ValueKey('previous-meter')));
    await tester.pumpAndSettle();
    expect(find.text('0 m'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('mark-missing')));
    await tester.pumpAndSettle();
    expect(find.text('Delete the photo at 0 m?'), findsOneWidget);
    await tester.tap(find.text('Keep photo'));
    await tester.pumpAndSettle();
    var frames = await tester.runAsync(() => db.framesForSession(sessionId));
    expect(frames!.single.isMissing, isFalse);

    await tester.tap(find.byKey(const ValueKey('mark-missing')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Mark missing'));
    // The save began in the fake zone (the first tap): let its real file
    // delete land, then flush its continuation, a few times over.
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    frames = await tester.runAsync(() => db.framesForSession(sessionId));
    expect(frames!.single.isMissing, isTrue);
  });

  // Review fix: a stalled or failed sensor never leaves its last reading on
  // the next shot.
  testWidgets('a tilt sensor error clears the reading, so the shot saves no tilt', (tester) async {
    await open(tester);
    tilt.controller.add(4);
    await tester.pump();
    tilt.controller.addError(StateError('sensor gone'));
    await tester.pump();
    expect(find.text('No reading'), findsOneWidget);

    await tapAndSave(tester, find.byKey(const ValueKey('shutter')));
    final frames = await tester.runAsync(() => db.framesForSession(sessionId));
    expect(frames!.single.tiltDeg, isNull);
  });
}
