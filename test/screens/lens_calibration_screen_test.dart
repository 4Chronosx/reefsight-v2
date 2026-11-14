import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:reefsight_mobile/screens/lens_calibration_screen.dart';
import 'package:reefsight_mobile/services/calibration_capture.dart';
import 'package:reefsight_mobile/services/laser_dot_detector.dart';
import 'package:reefsight_mobile/services/lens_calibration.dart';

import '../support/fake_capture.dart';

// Issue #14: the pool test's capture tool. The camera, tilt sensor, file
// picker, share sheet and dot detector are fakes; file writes are real, so
// taps that save run inside `runAsync`.

void main() {
  late Directory docs;
  late FakeStillCamera camera;
  late FakeTiltSource tilt;
  late List<CameraLens> opened;
  late List<String> shared;

  // Two dots 250 px apart about the centre of a 3024 × 4032 still.
  const dotA = DotBlob(x: 1387, y: 2016, areaPx: 300);
  const dotB = DotBlob(x: 1637, y: 2016, areaPx: 300);
  const portraitDetection = LaserDetection(
    blobs: [dotA, dotB],
    pair: DotPair(a: dotA, b: dotB, ambiguous: false),
    imageWidth: 3024,
    imageHeight: 4032,
  );
  late LaserDetection detection;

  setUp(() {
    detection = portraitDetection;
    docs = Directory.systemTemp.createTempSync('reefsight_calib_screen_');
    camera = FakeStillCamera(docs);
    tilt = FakeTiltSource();
    opened = [];
    shared = [];
  });
  tearDown(() {
    // On Windows the corner marker's Image.file can still hold the still
    // open; a leftover temp folder is harmless.
    try {
      docs.deleteSync(recursive: true);
    } on FileSystemException {
      // ignore
    }
  });

  void writeCalibration() {
    final file = File(LensCalibrationFile(docs.path).path)..parent.createSync(recursive: true);
    file.writeAsStringSync(jsonEncode({
      'format': kLensCalibrationFormat,
      'version': 1,
      'calibration_id': 'pool1',
      'lenses': [
        {
          'lens': 'main',
          'medium': 'water',
          'image_width': 3024,
          'image_height': 4032,
          'fx': 3000.0,
          'fy': 3000.0,
          'cx': 1512.0,
          'cy': 2016.0,
          'distortion': [0, 0, 0, 0, 0],
        },
      ],
    }));
  }

  /// Lets real file work finish: polls (up to 10 s, so a loaded machine running the whole suite
  /// doesn't flake) until [until] holds and nothing is saving.
  Future<void> settle(WidgetTester tester, {bool Function()? until}) async {
    for (var i = 0; i < 100; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
      if (i >= 1 && find.text('Saving…').evaluate().isEmpty && (until?.call() ?? true)) break;
    }
    await tester.pumpAndSettle();
  }

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(
        home: LensCalibrationScreen(
          cameraOpenerFor: (lens) {
            opened.add(lens);
            return FakeStillCameraOpener(camera);
          },
          tiltSource: tilt,
          documentsDirectory: () async => docs.path,
          pickCalibrationFile: () async => null,
          shareZip: (zip) async => shared.add(zip),
          detectDots: (_) async => detection,
        ),
      ));
    });
    await settle(tester, until: () => find.text('Opening camera…').evaluate().isEmpty);
  }

  Future<void> tapAndSave(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await settle(tester);
  }

  Future<CaptureManifest> manifest() async {
    final sets = await CalibrationCaptureStore.listSets(docs.path);
    return (await CalibrationCaptureStore.open(sets.single)).manifest;
  }

  Future<void> chooseTarget(WidgetTester tester, String label) async {
    await tester.ensureVisible(find.text(label));
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  testWidgets('a checkerboard shot is saved with lens, medium and tilt', (tester) async {
    await open(tester);
    expect(opened, [CameraLens.main]);
    tilt.controller.add(3.2);
    await tester.pump();
    expect(find.text('Tilt 3.2°'), findsOneWidget);

    await tapAndSave(tester, find.byKey(const Key('calib-capture')));
    final shot = (await tester.runAsync(manifest))!.shots.single;
    expect(shot.target, CalibrationTarget.checkerboard);
    expect(shot.lens, CameraLens.main);
    expect(shot.medium, CalibrationMedium.water);
    expect(shot.tiltDeg, 3.2);
    expect(shot.knownDistanceM, isNull);
    expect(find.textContaining(': 1 shots'), findsOneWidget);
  });

  testWidgets('switching to the ultra-wide reopens the camera on that lens', (tester) async {
    await open(tester);
    await tapAndSave(tester, find.text('Ultra-wide 0.5×'));
    expect(opened, [CameraLens.main, CameraLens.ultraWide]);
  });

  testWidgets('a laser shot needs the tape distance', (tester) async {
    await open(tester);
    await chooseTarget(tester, 'Lasers');
    await tapAndSave(tester, find.byKey(const Key('calib-capture')));
    expect(find.textContaining('Enter the tape-measured distance'), findsOneWidget);
    expect(await tester.runAsync(() => CalibrationCaptureStore.listSets(docs.path)), isEmpty);
  });

  testWidgets('without a calibration, a laser shot records the dots and asks for one', (tester) async {
    await open(tester);
    expect(find.text('No calibration loaded'), findsOneWidget);
    await chooseTarget(tester, 'Lasers');
    await tester.enterText(find.byKey(const Key('calib-distance')), '1.2');
    await tapAndSave(tester, find.byKey(const Key('calib-capture')));
    expect(find.textContaining('Load a calibration'), findsOneWidget);
    final shot = (await tester.runAsync(manifest))!.shots.single;
    expect(shot.laser!.ax, 1387);
    expect(shot.laser!.estimatedDistanceM, isNull);
  });

  testWidgets('with a calibration, a laser shot reads the distance against the tape', (tester) async {
    writeCalibration();
    await open(tester);
    expect(find.textContaining('Calibration pool1: main ✓'), findsOneWidget);
    await chooseTarget(tester, 'Lasers');
    await tester.enterText(find.byKey(const Key('calib-distance')), '1,25'); // comma decimal accepted
    await tapAndSave(tester, find.byKey(const Key('calib-capture')));
    // 10 cm over 250 px with f = 3000 px: 1.200 m, 5 cm short of the tape.
    expect(find.textContaining('1.200 m'), findsOneWidget);
    expect(find.textContaining('within ±10 cm'), findsOneWidget);
    final m = (await tester.runAsync(manifest))!;
    expect(m.laserBaselineM, 0.10);
    expect(m.shots.single.knownDistanceM, 1.25);
    expect(m.shots.single.laser!.estimatedDistanceM, closeTo(1.2, 1e-9));
    expect(m.shots.single.laser!.calibrationId, 'pool1');
  });

  testWidgets('a still of another size than the calibration gives no distance', (tester) async {
    writeCalibration();
    detection = const LaserDetection(
      blobs: [dotA, dotB],
      pair: DotPair(a: dotA, b: dotB, ambiguous: false),
      imageWidth: 4032, // landscape: the orientation went wrong somewhere
      imageHeight: 3024,
    );
    await open(tester);
    await chooseTarget(tester, 'Lasers');
    await tester.enterText(find.byKey(const Key('calib-distance')), '1.2');
    await tapAndSave(tester, find.byKey(const Key('calib-capture')));
    expect(find.textContaining('calibration is for 3024 × 4032'), findsOneWidget);
    final shot = (await tester.runAsync(manifest))!.shots.single;
    expect(shot.laser!.ax, 1387); // the dots are still recorded
    expect(shot.laser!.estimatedDistanceM, isNull);
  });

  testWidgets('an air shot reads the distance with the air calibration', (tester) async {
    writeCalibration(); // water only
    await open(tester);
    await tester.tap(find.text('Air'));
    await tester.pumpAndSettle();
    await chooseTarget(tester, 'Lasers');
    await tester.enterText(find.byKey(const Key('calib-distance')), '1.2');
    await tapAndSave(tester, find.byKey(const Key('calib-capture')));
    expect(find.textContaining('main/air'), findsOneWidget);
    expect((await tester.runAsync(manifest))!.shots.single.laser!.estimatedDistanceM, isNull);
  });

  testWidgets('a square shot opens the corner marker and saves the corners', (tester) async {
    await open(tester);
    await chooseTarget(tester, '1 m square');
    await tester.enterText(find.byKey(const Key('calib-distance')), '1.2');
    await tapAndSave(tester, find.byKey(const Key('calib-capture')));
    expect(find.text('Mark the 1 m square'), findsOneWidget);
    await tapAndSave(tester, find.byKey(const Key('square-save')));
    expect(find.textContaining('with its corners'), findsOneWidget);
    final shot = (await tester.runAsync(manifest))!.shots.single;
    expect(shot.squareCorners, hasLength(4));
    expect(shot.knownDistanceM, 1.2);
  });

  testWidgets('share zips the set', (tester) async {
    await open(tester);
    await tapAndSave(tester, find.byKey(const Key('calib-share')));
    expect(find.text('Take some shots first.'), findsOneWidget);
    await tapAndSave(tester, find.byKey(const Key('calib-capture')));
    await tapAndSave(tester, find.byKey(const Key('calib-share')));
    expect(shared, hasLength(1));
    expect(p.basename(shared.single), startsWith('reefsight_calibration_'));
  });
}
