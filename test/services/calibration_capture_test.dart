import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:reefsight_mobile/services/calibration_capture.dart';
import 'package:reefsight_mobile/services/lens_calibration.dart';

// Issue #14: the pool-test capture set (Settings → Diagnostics → Lens
// calibration). Every still carries the lens, medium, target and the
// tape-measured distance, so notebook 31 can fit the lens and score the
// distance estimates without a separate recording sheet.

void main() {
  late Directory docs;
  late File jpeg;

  setUp(() async {
    docs = await Directory.systemTemp.createTemp('calib_');
    jpeg = File(p.join(docs.path, 'camera_tmp.jpg'))..writeAsBytesSync([0xFF, 0xD8, 1, 2, 3, 0xFF, 0xD9]);
  });
  tearDown(() => docs.delete(recursive: true));

  CalibrationShot shot({
    CalibrationTarget target = CalibrationTarget.square,
    double? distance = 1.2,
  }) =>
      CalibrationShot(
        file: '',
        lens: CameraLens.main,
        medium: CalibrationMedium.water,
        target: target,
        knownDistanceM: distance,
        tiltDeg: 2.5,
        capturedAt: DateTime(2026, 11, 20, 10, 15, 3),
      );

  test('a new set gets a timestamped folder and an empty manifest', () async {
    final store = await CalibrationCaptureStore.create(docs.path, now: DateTime(2026, 11, 20, 10, 15));
    expect(store.captureId, '20261120_101500');
    expect(p.basename(store.directory.path), '20261120_101500');
    final manifest = jsonDecode(File(p.join(store.directory.path, 'manifest.json')).readAsStringSync()) as Map;
    expect(manifest['format'], kCaptureManifestFormat);
    expect(manifest['shots'], isEmpty);
  });

  test('adding a shot copies the still and records it in the manifest', () async {
    final store = await CalibrationCaptureStore.create(docs.path, now: DateTime(2026, 11, 20, 10, 15));
    final saved = await store.addShot(jpeg.path, shot());
    expect(saved.file, 'shot_001.jpg');
    expect(File(p.join(store.directory.path, 'shot_001.jpg')).readAsBytesSync(), jpeg.readAsBytesSync());

    final again = await CalibrationCaptureStore.open(store.directory.path);
    final s = again.manifest.shots.single;
    expect(s.lens, CameraLens.main);
    expect(s.medium, CalibrationMedium.water);
    expect(s.target, CalibrationTarget.square);
    expect(s.knownDistanceM, 1.2);
    expect(s.tiltDeg, 2.5);
    expect(s.capturedAt, DateTime(2026, 11, 20, 10, 15, 3));
  });

  test('shot files are numbered in order', () async {
    final store = await CalibrationCaptureStore.create(docs.path);
    await store.addShot(jpeg.path, shot());
    final second = await store.addShot(jpeg.path, shot(target: CalibrationTarget.checkerboard, distance: null));
    expect(second.file, 'shot_002.jpg');
    expect(store.manifest.shots.map((s) => s.file), ['shot_001.jpg', 'shot_002.jpg']);
  });

  test('corners and a laser reading can be added to a shot later', () async {
    final store = await CalibrationCaptureStore.create(docs.path);
    await store.addShot(jpeg.path, shot());
    const corners = [(x: 0.1, y: 0.1), (x: 0.9, y: 0.1), (x: 0.9, y: 0.9), (x: 0.1, y: 0.9)];
    await store.updateShot(
      0,
      store.manifest.shots[0].copyWith(
        squareCorners: corners,
        laser: const LaserReading(
          ax: 100,
          ay: 200,
          bx: 400,
          by: 205,
          ambiguous: false,
          estimatedDistanceM: 1.18,
          calibrationId: 'cal1',
        ),
      ),
    );
    final again = await CalibrationCaptureStore.open(store.directory.path);
    final s = again.manifest.shots.single;
    expect(s.squareCorners, corners);
    expect(s.laser!.estimatedDistanceM, 1.18);
    expect(s.laser!.calibrationId, 'cal1');
    expect(s.laser!.bx, 400);
  });

  test('the laser baseline is stored with the set', () async {
    final store = await CalibrationCaptureStore.create(docs.path);
    await store.setLaserBaseline(0.10);
    expect((await CalibrationCaptureStore.open(store.directory.path)).manifest.laserBaselineM, 0.10);
    expect(() => store.setLaserBaseline(0), throwsArgumentError);
  });

  test('the zip holds the manifest and every still under the set id', () async {
    final store = await CalibrationCaptureStore.create(docs.path, now: DateTime(2026, 11, 20, 10, 15));
    await store.addShot(jpeg.path, shot());
    await store.addShot(jpeg.path, shot());
    final zip = await store.writeZip();
    expect(p.basename(zip), 'reefsight_calibration_20261120_101500.zip');
    final names = ZipDecoder().decodeBytes(File(zip).readAsBytesSync()).files.map((f) => f.name).toSet();
    expect(names, {
      '20261120_101500/manifest.json',
      '20261120_101500/shot_001.jpg',
      '20261120_101500/shot_002.jpg',
    });
  });

  test('a manifest with a file name escaping the folder is refused', () async {
    final store = await CalibrationCaptureStore.create(docs.path);
    final path = p.join(store.directory.path, 'manifest.json');
    final json = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
    json['shots'] = [
      {...shot().toJson(), 'file': '../evil.jpg'},
    ];
    File(path).writeAsStringSync(jsonEncode(json));
    expect(() => CalibrationCaptureStore.open(store.directory.path), throwsFormatException);
  });

  group('LensCalibrationFile', () {
    String calibrationJson() => jsonEncode({
          'format': kLensCalibrationFormat,
          'version': 1,
          'calibration_id': 'run42',
          'lenses': [
            {
              'lens': 'main',
              'medium': 'water',
              'image_width': 3024,
              'image_height': 4032,
              'fx': 3800.0,
              'fy': 3800.0,
              'cx': 1512.0,
              'cy': 2016.0,
              'distortion': [0, 0, 0, 0, 0],
            },
          ],
        });

    test('nothing imported yet: no calibration', () async {
      expect(await LensCalibrationFile(docs.path).load(), isNull);
    });

    test('importing a valid file saves it for later sessions', () async {
      final src = File(p.join(docs.path, 'picked.json'))..writeAsStringSync(calibrationJson());
      final imported = await LensCalibrationFile(docs.path).import(src.path);
      expect(imported.calibrationId, 'run42');
      expect((await LensCalibrationFile(docs.path).load())!.calibrationId, 'run42');
    });

    test('importing a bad file keeps the previous calibration', () async {
      final good = File(p.join(docs.path, 'good.json'))..writeAsStringSync(calibrationJson());
      final bad = File(p.join(docs.path, 'bad.json'))..writeAsStringSync('{"format": "nope"}');
      final store = LensCalibrationFile(docs.path);
      await store.import(good.path);
      await expectLater(store.import(bad.path), throwsFormatException);
      expect((await store.load())!.calibrationId, 'run42');
    });

    test('an oversized file is refused before parsing', () async {
      final big = File(p.join(docs.path, 'big.json'))..writeAsStringSync(' ' * (kMaxCalibrationFileBytes + 1));
      await expectLater(LensCalibrationFile(docs.path).import(big.path), throwsFormatException);
    });
  });
}
