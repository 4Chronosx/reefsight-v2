import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../services/calibration_capture.dart';
import '../services/laser_dot_detector.dart';
import '../services/lens_calibration.dart';
import '../services/scale_estimation.dart';
import '../services/still_camera.dart';
import '../services/tilt.dart';
import '../services/transect_frame.dart' show NormPoint;
import 'square_corner_marker_screen.dart';

/// Issue #14: the pool test's capture tool (Settings → Diagnostics → Lens
/// calibration; protocol in `../docs/underwater-lens-calibration-protocol.md`).
///
/// - Takes stills on the **main or ultra-wide** lens, each tagged with the
///   medium (air/water), the target (checkerboard / 1 m square / laser dots),
///   the tape-measured distance and the live tilt, into one capture set
///   (`calibration_capture.dart`), shared as a zip for notebook 31.
/// - After a **square** shot, the diver marks its corners.
/// - After a **laser** shot, the dots are found and -- once a calibration is
///   loaded -- the distance is read and compared with the tape, against the
///   ±10 cm tolerance (decision D1): the issue's "estimate camera-to-bottom
///   distance underwater", on real pool photos.
/// - **Load calibration** imports notebook 31's `lens_calibration.json`.
///
/// Diagnostics only: nothing here touches surveys or the database.
class LensCalibrationScreen extends StatefulWidget {
  const LensCalibrationScreen({
    super.key,
    this.cameraOpenerFor = pluginOpenerFor,
    this.tiltSource = const SensorsPlusTiltSource(),
    this.documentsDirectory = calibrationDocumentsPath,
    this.pickCalibrationFile = pickCalibrationJson,
    this.shareZip = shareCalibrationZip,
    this.detectDots = detectDotsInFile,
  });

  final StillCameraOpener Function(CameraLens lens) cameraOpenerFor;
  final TiltSource tiltSource;
  final Future<String> Function() documentsDirectory;
  final Future<String?> Function() pickCalibrationFile;
  final Future<void> Function(String zipPath) shareZip;
  final Future<LaserDetection> Function(String imagePath) detectDots;

  @override
  State<LensCalibrationScreen> createState() => _LensCalibrationScreenState();
}

StillCameraOpener pluginOpenerFor(CameraLens lens) => PluginStillCameraOpener(lens: lens);

Future<String> calibrationDocumentsPath() async => (await getApplicationDocumentsDirectory()).path;

/// `FileType.custom` goes through the Files app on iOS (`photo_source.dart`).
Future<String?> pickCalibrationJson() async {
  final result = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: const ['json']);
  return result?.files.singleOrNull?.path;
}

Future<void> shareCalibrationZip(String zipPath) async {
  await Share.shareXFiles([XFile(zipPath, mimeType: 'application/zip')], subject: 'ReefSight lens calibration set');
}

/// Off the UI isolate: decoding a 12 MP still takes a moment.
Future<LaserDetection> detectDotsInFile(String imagePath) async {
  final bytes = await File(imagePath).readAsBytes();
  return Isolate.run(() => detectLaserDots(bytes));
}

class _LensCalibrationScreenState extends State<LensCalibrationScreen> {
  CameraLens _lens = CameraLens.main;
  CalibrationMedium _medium = CalibrationMedium.water;
  CalibrationTarget _target = CalibrationTarget.checkerboard;
  final _distance = TextEditingController();
  final _baselineCm = TextEditingController(text: '10');

  StillCamera? _camera;
  Object? _cameraError;
  StreamSubscription<double>? _tiltSub;
  double? _tilt;
  String? _docs;
  CalibrationCaptureStore? _store;
  LensCalibration? _calibration;
  bool _busy = false;
  String? _message;
  bool _messageIsError = false;

  @override
  void initState() {
    super.initState();
    _tiltSub = widget.tiltSource.tiltDegrees().listen((t) {
      if (mounted) setState(() => _tilt = t);
    });
    _init();
  }

  Future<void> _init() async {
    try {
      final docs = await widget.documentsDirectory();
      final calibration = await LensCalibrationFile(docs).load();
      if (!mounted) return;
      setState(() {
        _docs = docs;
        _calibration = calibration;
      });
    } catch (e) {
      _say('Storage unavailable: $e', error: true);
    }
    await _openCamera();
  }

  Future<void> _openCamera() async {
    final old = _camera;
    if (mounted) {
      setState(() {
        _camera = null;
        _cameraError = null;
      });
    }
    await old?.dispose();
    try {
      final camera = await widget.cameraOpenerFor(_lens).open();
      if (!mounted) {
        await camera.dispose();
        return;
      }
      setState(() => _camera = camera);
    } catch (e) {
      if (mounted) setState(() => _cameraError = e);
    }
  }

  @override
  void dispose() {
    _tiltSub?.cancel();
    _camera?.dispose();
    _distance.dispose();
    _baselineCm.dispose();
    super.dispose();
  }

  void _say(String text, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _message = text;
      _messageIsError = error;
    });
  }

  double? _parse(TextEditingController c) => double.tryParse(c.text.trim().replaceAll(',', '.'));

  Future<void> _capture() async {
    final camera = _camera, docs = _docs;
    if (camera == null || docs == null || _busy) return;
    final distance = _parse(_distance);
    final needsDistance = _target != CalibrationTarget.checkerboard;
    if (needsDistance && (distance == null || distance <= 0 || distance > 5)) {
      _say('Enter the tape-measured distance, in metres (e.g. 1.2).', error: true);
      return;
    }
    final baselineCm = _parse(_baselineCm);
    if (_target == CalibrationTarget.laser && (baselineCm == null || baselineCm <= 0 || baselineCm >= 100)) {
      _say('Enter the laser spacing measured on the housing, in cm.', error: true);
      return;
    }
    setState(() => _busy = true);
    try {
      final store = _store ??= await CalibrationCaptureStore.create(docs);
      final temp = await camera.takePicture();
      var shot = await store.addShot(
        temp,
        CalibrationShot(
          file: '',
          lens: _lens,
          medium: _medium,
          target: _target,
          capturedAt: DateTime.now(),
          knownDistanceM: needsDistance ? distance : null,
          tiltDeg: _tilt,
        ),
      );
      final index = store.manifest.shots.length - 1;
      var note = 'Saved ${shot.file}.';
      if (_target == CalibrationTarget.square && mounted) {
        final corners = await Navigator.of(context).push<List<NormPoint>>(
          MaterialPageRoute(
            builder: (_) => SquareCornerMarkerScreen(
              imagePath: store.pathOf(shot),
              aspectRatio: camera.portraitAspectRatio,
            ),
          ),
        );
        if (corners != null) {
          shot = shot.copyWith(squareCorners: corners);
          await store.updateShot(index, shot);
          note = 'Saved ${shot.file} with its corners.';
        } else {
          note = 'Saved ${shot.file} without corners.';
        }
      }
      if (_target == CalibrationTarget.laser) {
        final baselineM = baselineCm! / 100;
        if (store.manifest.laserBaselineM != baselineM) await store.setLaserBaseline(baselineM);
        note = await _readLaser(store, index, shot, baselineM, distance!);
      }
      _say(note);
    } catch (e) {
      _say('Capture failed: $e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String> _readLaser(
    CalibrationCaptureStore store,
    int index,
    CalibrationShot shot,
    double baselineM,
    double tapeM,
  ) async {
    final detection = await widget.detectDots(store.pathOf(shot));
    final pair = detection.pair;
    if (pair == null) {
      return 'Saved ${shot.file}. ${detection.error ?? 'No laser pair found (${detection.blobs.length} green spots).'}';
    }
    final intrinsics = _calibration?.forLens(_lens, shot.medium);
    // Pixel coordinates only mean something in the image size the lens was calibrated at: a still
    // of another size or orientation would give a quietly wrong distance.
    final w = detection.imageWidth, h = detection.imageHeight;
    final sizeMatches = intrinsics != null &&
        w != null &&
        h != null &&
        (w - intrinsics.imageWidth).abs() <= 2 &&
        (h - intrinsics.imageHeight).abs() <= 2;
    final estimate = !sizeMatches
        ? null
        : distanceFromDotPair(lens: intrinsics, dotA: pair.a.point, dotB: pair.b.point, baselineM: baselineM);
    await store.updateShot(
      index,
      shot.copyWith(
        laser: LaserReading(
          ax: pair.a.x,
          ay: pair.a.y,
          bx: pair.b.x,
          by: pair.b.y,
          ambiguous: pair.ambiguous,
          estimatedDistanceM: estimate?.distanceM,
          calibrationId: estimate == null ? null : _calibration!.calibrationId,
        ),
      ),
    );
    final gap = 'Dots ${pair.gapPx.toStringAsFixed(0)} px apart${pair.ambiguous ? ' (ambiguous: check by eye)' : ''}';
    if (estimate == null) {
      if (intrinsics == null) {
        return '$gap. Load a calibration with ${_lens.db}/${shot.medium.db} to read the distance.';
      }
      if (!sizeMatches) {
        return '$gap. No distance: the calibration is for ${intrinsics.imageWidth} × ${intrinsics.imageHeight} '
            'px and this still is ${w ?? '?'} × ${h ?? '?'}.';
      }
      return '$gap. Outside the calibrated range of the lens.';
    }
    final errCm = (estimate.distanceM - tapeM) * 100;
    final ok = withinDistanceTolerance(estimate.distanceM, tapeM);
    return '$gap → ${estimate.distanceM.toStringAsFixed(3)} m '
        '(tape ${tapeM.toStringAsFixed(2)} m, ${errCm >= 0 ? '+' : ''}${errCm.toStringAsFixed(1)} cm, '
        '${ok ? 'within' : 'OUTSIDE'} ±${(kDistanceToleranceM * 100).round()} cm), '
        '${estimate.cmPerPx.toStringAsFixed(3)} cm/px.';
  }

  Future<void> _loadCalibration() async {
    final docs = _docs;
    if (docs == null) return;
    try {
      final path = await widget.pickCalibrationFile();
      if (path == null) return;
      final calibration = await LensCalibrationFile(docs).import(path);
      if (!mounted) return;
      setState(() => _calibration = calibration);
      _say('Loaded calibration ${calibration.calibrationId}.');
    } on FormatException catch (e) {
      _say('Not loaded: ${e.message}. The previous calibration is kept.', error: true);
    } catch (e) {
      _say('Not loaded: $e', error: true);
    }
  }

  Future<void> _share() async {
    final store = _store;
    if (store == null || store.manifest.shots.isEmpty) {
      _say('Take some shots first.', error: true);
      return;
    }
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.shareZip(await store.writeZip());
    } catch (e) {
      _say('Share failed: $e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _calibrationSummary() {
    final c = _calibration;
    if (c == null) return 'No calibration loaded';
    String mark(CameraLens l) => c.forLens(l, CalibrationMedium.water) == null ? '✗' : '✓';
    return 'Calibration ${c.calibrationId}: main ${mark(CameraLens.main)}, '
        'ultra-wide ${mark(CameraLens.ultraWide)} (water)';
  }

  @override
  Widget build(BuildContext context) {
    final camera = _camera;
    final store = _store;
    final tilt = _tilt;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Lens calibration'),
        actions: [
          IconButton(
            key: const Key('calib-share'),
            tooltip: 'Share set',
            onPressed: _busy ? null : _share,
            icon: const Icon(Icons.ios_share),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AspectRatio(
                aspectRatio: camera?.portraitAspectRatio ?? 3 / 4,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (camera != null)
                      camera.buildPreview()
                    else
                      ColoredBox(
                        color: Colors.black,
                        child: Center(
                          child: Text(
                            _cameraError == null ? 'Opening camera…' : 'Camera unavailable: $_cameraError',
                            style: const TextStyle(color: Colors.white),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                    Positioned(
                      left: 8,
                      top: 8,
                      child: DecoratedBox(
                        decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(6)),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          child: Text(
                            tilt == null ? 'Tilt –' : 'Tilt ${tilt.toStringAsFixed(1)}°',
                            key: const Key('calib-tilt'),
                            style: const TextStyle(color: Colors.white),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              SegmentedButton<CameraLens>(
                key: const Key('calib-lens'),
                segments: const [
                  ButtonSegment(value: CameraLens.main, label: Text('Main 1×')),
                  ButtonSegment(value: CameraLens.ultraWide, label: Text('Ultra-wide 0.5×')),
                ],
                selected: {_lens},
                onSelectionChanged: _busy
                    ? null
                    : (s) {
                        setState(() => _lens = s.single);
                        _openCamera();
                      },
              ),
              const SizedBox(height: 8),
              SegmentedButton<CalibrationMedium>(
                key: const Key('calib-medium'),
                segments: const [
                  ButtonSegment(value: CalibrationMedium.air, label: Text('Air')),
                  ButtonSegment(value: CalibrationMedium.water, label: Text('Water')),
                ],
                selected: {_medium},
                onSelectionChanged: (s) => setState(() => _medium = s.single),
              ),
              const SizedBox(height: 8),
              SegmentedButton<CalibrationTarget>(
                key: const Key('calib-target'),
                segments: const [
                  ButtonSegment(value: CalibrationTarget.checkerboard, label: Text('Checkerboard')),
                  ButtonSegment(value: CalibrationTarget.square, label: Text('1 m square')),
                  ButtonSegment(value: CalibrationTarget.laser, label: Text('Lasers')),
                ],
                selected: {_target},
                onSelectionChanged: (s) => setState(() => _target = s.single),
              ),
              const SizedBox(height: 8),
              if (_target != CalibrationTarget.checkerboard)
                TextField(
                  key: const Key('calib-distance'),
                  controller: _distance,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Tape-measured distance (m)',
                    helperText: "From the camera lens to the target's plane",
                  ),
                ),
              if (_target == CalibrationTarget.laser)
                TextField(
                  key: const Key('calib-baseline'),
                  controller: _baselineCm,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Laser spacing on the housing (cm)'),
                ),
              const SizedBox(height: 12),
              FilledButton.icon(
                key: const Key('calib-capture'),
                onPressed: camera == null || _docs == null || _busy ? null : _capture,
                icon: const Icon(Icons.camera_alt),
                label: Text(_busy ? 'Saving…' : 'Capture'),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(64)),
              ),
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _message!,
                    key: const Key('calib-message'),
                    style: TextStyle(color: _messageIsError ? Theme.of(context).colorScheme.error : null),
                  ),
                ),
              const Divider(height: 24),
              Text(
                store == null
                    ? 'No set yet: the first shot starts one.'
                    : 'Set ${store.captureId}: ${store.manifest.shots.length} shots',
                key: const Key('calib-set'),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  key: const Key('calib-new-set'),
                  onPressed: store == null || _busy ? null : () => setState(() => _store = null),
                  child: const Text('Start a new set'),
                ),
              ),
              const SizedBox(height: 8),
              Text(_calibrationSummary(), key: const Key('calib-summary')),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  key: const Key('calib-load'),
                  onPressed: _docs == null ? null : _loadCalibration,
                  child: const Text('Load calibration (lens_calibration.json)'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
