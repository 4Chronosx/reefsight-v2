import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../constants/app_colors.dart';
import '../services/app_database.dart';
import '../services/photo_import_checks.dart' show kMinPixels;
import '../services/photo_transect_capture.dart';
import '../services/photo_transect_store.dart';
import '../services/screen_awake.dart';
import '../services/station.dart';
import '../services/still_camera.dart';
import '../services/tilt.dart';
import '../services/transect_database.dart';
import '../services/transect_frame.dart';
import '../widgets/glove_button.dart';
import 'frame_corner_editor_screen.dart';

/// The app's documents directory -- the capture screen's default, injected
/// because `path_provider` has no platform channel under `flutter test`.
Future<String> appDocumentsPath() async => (await getApplicationDocumentsDirectory()).path;

/// Issue #4: in-app photo-transect capture (TB 2017-05, physical frame):
/// one still per meter mark with a meter counter, the level indicator, a
/// big shutter, retake (tap a meter in Review, shoot again) and mark
/// missing. Each still is saved as it's taken (`PhotoTransectCapture`), so
/// the screen can be left and reopened at any point.
///
/// Built for the DIVEVOLK housing: dark background, large text and
/// controls (64 dp in-water minimum, sub-plan 6 decision 4), taps only --
/// no swipes or long presses, which a housing's touch window handles
/// badly. The level is advisory in Physical mode (the pole holds the
/// angle): it never blocks the shutter.
class PhotoTransectCaptureScreen extends StatefulWidget {
  const PhotoTransectCaptureScreen({
    super.key,
    required this.station,
    required this.sessionId,
    required this.transectNumber,
    this.openDatabase = openAppDatabase,
    this.cameraOpener = const PluginStillCameraOpener(),
    this.tiltSource = const SensorsPlusTiltSource(),
    this.screenAwake = const WakelockScreenAwake(),
    this.documentsDirectory = appDocumentsPath,
  });

  final Station station;
  final int sessionId;
  final int transectNumber;
  final DatabaseOpener openDatabase;
  final StillCameraOpener cameraOpener;
  final TiltSource tiltSource;
  final ScreenAwake screenAwake;
  final Future<String> Function() documentsDirectory;

  @override
  State<PhotoTransectCaptureScreen> createState() => _PhotoTransectCaptureScreenState();
}

class _PhotoTransectCaptureScreenState extends State<PhotoTransectCaptureScreen>
    with WidgetsBindingObserver {
  late final ScreenAwakeLease _awake = ScreenAwakeLease(widget.screenAwake);
  TransectDatabase? _db;
  PhotoTransectCapture? _capture;
  Object? _loadError;

  StillCamera? _camera;
  Object? _cameraError;
  bool _openingCamera = false;

  StreamSubscription<double>? _tiltSub;
  double? _tilt;
  bool _disposed = false;

  String get _title => '${widget.station.code} · T${widget.transectNumber}';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _awake.acquire();
    _tiltSub = widget.tiltSource.tiltDegrees().listen(
      (t) {
        if (mounted) setState(() => _tilt = t);
      },
      onError: (Object error) {
        debugPrint('ReefSight: tilt reading failed: $error');
        // Never save a stale reading as this shot's tilt.
        if (mounted) setState(() => _tilt = null);
      },
    );
    _load();
    _openCamera();
  }

  Future<void> _load() async {
    try {
      final db = await widget.openDatabase();
      if (_disposed) {
        await db.close();
        return;
      }
      _db = db;
      final session = await db.sessionById(widget.sessionId);
      if (session == null) throw StateError('Transect ${widget.sessionId} is not on this phone');
      final docs = await widget.documentsDirectory();
      final capture = PhotoTransectCapture(
        db: db,
        store: PhotoTransectStore(documentsDirectory: docs, sessionId: widget.sessionId),
        sessionId: widget.sessionId,
        tapeLengthMeters: session.tapeLengthMeters,
      );
      await capture.load();
      if (_disposed) return;
      capture.addListener(_onCaptureChanged);
      setState(() => _capture = capture);
    } catch (error) {
      debugPrint('ReefSight: opening photo capture failed: $error');
      if (mounted) setState(() => _loadError = error);
    }
  }

  void _onCaptureChanged() {
    if (_releaseWhenIdle && !(_capture?.busy ?? false)) {
      _releaseWhenIdle = false;
      _releaseCamera();
    }
    if (mounted) setState(() {});
  }

  /// The app went to the background while a shot was saving: the camera is
  /// let go once the shot is done, not under it.
  bool _releaseWhenIdle = false;
  Future<void>? _cameraDisposing;

  bool get _inBackground {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == AppLifecycleState.paused || state == AppLifecycleState.hidden;
  }

  Future<void> _openCamera() async {
    if (_openingCamera || _camera != null) return;
    _openingCamera = true;
    if (mounted) setState(() => _cameraError = null);
    try {
      // A quick return from the background: the old controller first.
      await _cameraDisposing;
      final camera = await widget.cameraOpener.open();
      if (_disposed || _inBackground) {
        // Backgrounded while it opened: `resumed` opens a fresh one.
        await camera.dispose();
        return;
      }
      setState(() => _camera = camera);
    } catch (error) {
      debugPrint('ReefSight: opening the camera failed: $error');
      if (mounted) setState(() => _cameraError = error);
    } finally {
      _openingCamera = false;
    }
  }

  Future<void> _releaseCamera() async {
    final camera = _camera;
    if (camera == null) return;
    _camera = null;
    if (mounted && !_disposed) setState(() {});
    final disposing = _cameraDisposing = camera.dispose();
    await disposing;
    if (identical(_cameraDisposing, disposing)) _cameraDisposing = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // iOS stops the camera in the background; let it go, and reopen it
    // (and reassert the wakelock) on return. Not on `inactive` alone (a
    // banner, Control Center): that would kill a shot for nothing. Never
    // under a shot being saved.
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      if (_capture?.busy ?? false) {
        _releaseWhenIdle = true;
      } else {
        _releaseCamera();
      }
    } else if (state == AppLifecycleState.resumed) {
      _releaseWhenIdle = false;
      _awake.acquire();
      _openCamera();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _tiltSub?.cancel();
    _capture?.removeListener(_onCaptureChanged);
    _camera?.dispose();
    _awake.release();
    _db?.close();
    super.dispose();
  }

  Future<void> _shoot() async {
    final capture = _capture;
    final camera = _camera;
    if (capture == null || camera == null || capture.busy) return;
    final meter = capture.current;
    try {
      await capture.capture(camera.takePicture, tiltDeg: _tilt);
    } catch (error) {
      debugPrint('ReefSight: saving the photo at $meter m failed: $error');
      _snack('Could not save the photo at ${_m(meter)}: $error');
    }
  }

  Future<void> _markMissing() async {
    final capture = _capture;
    if (capture == null || capture.busy) return;
    final meter = capture.current;
    if (capture.statusOf(meter) == MeterStatus.captured) {
      // One stray gloved tap mustn't delete a photo.
      final go = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Delete the photo at ${_m(meter)}?'),
          content: const Text('Marking this meter missing deletes the photo already taken here.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep photo')),
            TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Mark missing')),
          ],
        ),
      );
      if (go != true || !mounted) return;
    }
    try {
      await capture.markMissing();
    } catch (error) {
      debugPrint('ReefSight: marking $meter m missing failed: $error');
      _snack('Could not mark ${_m(meter)} missing: $error');
    }
  }

  Future<void> _openReview() async {
    final capture = _capture;
    if (capture == null) return;
    final result = await Navigator.of(context).push<_ReviewResult>(
      MaterialPageRoute(builder: (_) => _ReviewScreen(title: _title, capture: capture)),
    );
    if (!mounted || result == null) return;
    switch (result) {
      case _GoToMeter(:final meter):
        capture.select(meter);
      case _Finished():
        Navigator.of(context).pop();
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    // No leaving while a shot is saving: dispose closes the database under it.
    return PopScope(
      canPop: !(_capture?.busy ?? false),
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          title: Text(_title),
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
        ),
        body: SafeArea(child: _body()),
      ),
    );
  }

  Widget _body() {
    final error = _loadError;
    if (error != null) return _Message(text: 'Could not open this transect: $error');
    final capture = _capture;
    if (capture == null) return const Center(child: CircularProgressIndicator());

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Row(
            children: [
              Expanded(child: _MeterCounter(capture: capture)),
              _LevelIndicator(tiltDeg: _tilt),
            ],
          ),
        ),
        Expanded(child: _preview()),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _RoundButton(
                key: const ValueKey('previous-meter'),
                icon: Icons.chevron_left,
                label: 'Previous meter',
                onPressed: capture.busy ? null : capture.previous,
              ),
              _Shutter(
                busy: capture.busy,
                retake: capture.statusOf(capture.current) != MeterStatus.pending,
                onPressed: _camera == null || capture.busy ? null : _shoot,
              ),
              _RoundButton(
                key: const ValueKey('next-meter'),
                icon: Icons.chevron_right,
                label: 'Next meter',
                onPressed: capture.busy ? null : capture.next,
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Row(
            children: [
              Expanded(
                child: GloveButton(
                  key: const ValueKey('mark-missing'),
                  label: 'Mark missing',
                  icon: Icons.block,
                  inWater: true,
                  onPressed: capture.busy ? null : _markMissing,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: GloveButton(
                  key: const ValueKey('open-review'),
                  label: 'Review',
                  icon: Icons.grid_view,
                  inWater: true,
                  onPressed: capture.busy ? null : _openReview,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _preview() {
    final camera = _camera;
    final error = _cameraError;
    if (error != null) {
      return _Message(
        text: 'The camera did not open: $error',
        action: GloveButton(label: 'Try again', inWater: true, onPressed: _openCamera),
      );
    }
    if (camera == null) return const Center(child: CircularProgressIndicator());
    return Center(
      child: AspectRatio(
        aspectRatio: camera.portraitAspectRatio,
        child: Stack(
          fit: StackFit.expand,
          children: [
            camera.buildPreview(),
            // A centre mark to line up on the frame; the real 1 × 1 m
            // frame is what's scored (corners, #6).
            const IgnorePointer(child: Center(child: Icon(Icons.add, color: Colors.white70, size: 40))),
          ],
        ),
      ),
    );
  }
}

String _m(double meter) => '${meter.round()} m';

String _tiltText(double tilt) => '${tilt.toStringAsFixed(1)}°';

Color _tiltColor(TiltLevel level) => switch (level) {
      TiltLevel.level => AppColors.healthy,
      TiltLevel.near => Colors.amber,
      TiltLevel.off => AppColors.bleached,
      TiltLevel.unknown => AppColors.unknown,
    };

String _tiltLabel(TiltLevel level) => switch (level) {
      TiltLevel.level => 'Level',
      TiltLevel.near => 'Near level',
      TiltLevel.off => 'Tilted',
      TiltLevel.unknown => 'No reading',
    };

class _MeterCounter extends StatelessWidget {
  const _MeterCounter({required this.capture});
  final PhotoTransectCapture capture;

  @override
  Widget build(BuildContext context) {
    final done = capture.capturedCount + capture.missingCount;
    final status = capture.statusOf(capture.current);
    return Column(
      key: const ValueKey('meter-counter'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _m(capture.current),
          style: const TextStyle(color: Colors.white, fontSize: 48, fontWeight: FontWeight.bold, height: 1),
        ),
        const SizedBox(height: 4),
        Text(
          '$done of ${capture.meters.length} done',
          style: const TextStyle(color: Colors.white70, fontSize: 18),
        ),
        if (status != MeterStatus.pending)
          Text(
            status == MeterStatus.captured ? 'Has a photo: shoot to retake' : 'Marked missing',
            style: const TextStyle(color: Colors.amber, fontSize: 16, fontWeight: FontWeight.w600),
          ),
      ],
    );
  }
}

class _LevelIndicator extends StatelessWidget {
  const _LevelIndicator({required this.tiltDeg});
  final double? tiltDeg;

  @override
  Widget build(BuildContext context) {
    final tilt = tiltDeg;
    final level = tiltLevelOf(tilt);
    final color = _tiltColor(level);
    return Semantics(
      label: 'Tilt ${tilt == null ? 'unknown' : _tiltText(tilt)}, ${_tiltLabel(level)}',
      child: Container(
        width: 120,
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(color: color, width: 4),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          children: [
            Text(
              tilt == null ? '--' : _tiltText(tilt),
              style: TextStyle(color: color, fontSize: 30, fontWeight: FontWeight.bold),
            ),
            Text(_tiltLabel(level), style: TextStyle(color: color, fontSize: 16, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}

class _Shutter extends StatelessWidget {
  const _Shutter({required this.busy, required this.retake, required this.onPressed});
  final bool busy;
  final bool retake;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: retake ? 'Retake photo' : 'Take photo',
      child: SizedBox(
        width: 104,
        height: 104,
        child: ElevatedButton(
          key: const ValueKey('shutter'),
          onPressed: onPressed,
          style: ElevatedButton.styleFrom(
            shape: const CircleBorder(side: BorderSide(color: Colors.white, width: 5)),
            backgroundColor: retake ? Colors.amber : AppColors.primary,
            foregroundColor: Colors.white,
            padding: EdgeInsets.zero,
          ),
          child: busy
              ? const CircularProgressIndicator(color: Colors.white)
              : Icon(retake ? Icons.refresh : Icons.camera_alt, size: 48),
        ),
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({super.key, required this.icon, required this.label, required this.onPressed});
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 72,
        height: 72,
        child: IconButton.filled(
          tooltip: label,
          onPressed: onPressed,
          iconSize: 44,
          icon: Icon(icon),
        ),
      );
}

class _Message extends StatelessWidget {
  const _Message({required this.text, this.action});
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(text, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 18)),
              if (action != null) ...[const SizedBox(height: 16), action!],
            ],
          ),
        ),
      );
}

sealed class _ReviewResult {
  const _ReviewResult();
}

class _GoToMeter extends _ReviewResult {
  const _GoToMeter(this.meter);
  final double meter;
}

class _Finished extends _ReviewResult {
  const _Finished();
}

/// Every meter mark with its thumbnail, tilt and flags (tilt over
/// [kLevelToleranceDeg], under 5 MP, missing). Tapping one goes back to
/// capture at that meter to retake it; Finish records the transect as done.
class _ReviewScreen extends StatefulWidget {
  const _ReviewScreen({required this.title, required this.capture});
  final String title;
  final PhotoTransectCapture capture;

  @override
  State<_ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<_ReviewScreen> {
  bool _finishing = false;

  PhotoTransectCapture get _c => widget.capture;

  Future<void> _finish() async {
    if (_c.pendingCount > 0) {
      final go = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Finish with meters left?'),
          content: Text('${_c.pendingCount} meters have no photo and are not marked missing.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep capturing')),
            TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Finish')),
          ],
        ),
      );
      if (go != true || !mounted) return;
    }
    setState(() => _finishing = true);
    try {
      await _c.finish();
      if (mounted) Navigator.of(context).pop(const _Finished());
    } catch (error) {
      debugPrint('ReefSight: finishing the transect failed: $error');
      if (!mounted) return;
      setState(() => _finishing = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not finish: $error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final summary = '${_c.capturedCount} photo${_c.capturedCount == 1 ? '' : 's'} · '
        '${_c.missingCount} missing · ${_c.pendingCount} to do';
    return Scaffold(
      appBar: AppBar(
        title: Text('Review ${widget.title}'),
        actions: [
          // #5: the corner editor works on in-app stills too.
          TextButton.icon(
            key: const ValueKey('open-corners'),
            onPressed: _c.capturedCount == 0 || _finishing
                ? null
                : () => Navigator.of(context).push(MaterialPageRoute<void>(
                      builder: (_) => FrameCornerEditorScreen(
                        db: _c.db,
                        sessionId: _c.sessionId,
                        documentsDirectory: _c.store.documentsDirectory,
                        title: widget.title,
                      ),
                    )),
            icon: const Icon(Icons.crop_free),
            label: const Text('Corners'),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(summary, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            ),
            Expanded(
              child: GridView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 180,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 0.8,
                ),
                itemCount: _c.meters.length,
                itemBuilder: (context, i) {
                  final meter = _c.meters[i];
                  return _MeterTile(
                    meter: meter,
                    status: _c.statusOf(meter),
                    frame: _c.frameAt(meter),
                    imageFile: (f) => File(_c.store.absolutePath(f.imagePath)),
                    onTap: () => Navigator.of(context).pop(_GoToMeter(meter)),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: double.infinity,
                child: GloveButton(
                  key: const ValueKey('finish-transect'),
                  label: 'Finish transect',
                  icon: Icons.check,
                  busy: _finishing,
                  onPressed: _finish,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}


class _MeterTile extends StatelessWidget {
  const _MeterTile({
    required this.meter,
    required this.status,
    required this.frame,
    required this.imageFile,
    required this.onTap,
  });

  final double meter;
  final MeterStatus status;
  final TransectFrame? frame;
  final File Function(TransectFrame) imageFile;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final f = frame;
    final tilt = f?.tiltDeg;
    final lowRes = f != null && f.widthPx != null && f.heightPx != null && f.widthPx! * f.heightPx! < kMinPixels;
    final Widget picture = switch (status) {
      MeterStatus.captured => Image.file(
          imageFile(f!),
          fit: BoxFit.cover,
          cacheWidth: 360,
          errorBuilder: (_, _, _) => const Center(child: Icon(Icons.broken_image_outlined, size: 40)),
        ),
      MeterStatus.missing => const Center(child: Text('Missing', style: TextStyle(fontWeight: FontWeight.bold))),
      MeterStatus.pending => const Center(child: Text('To do', style: TextStyle(color: AppColors.unknown))),
    };
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Ink(
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: status == MeterStatus.missing ? AppColors.bleached : AppColors.unknown,
            width: 2,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ClipRRect(borderRadius: const BorderRadius.vertical(top: Radius.circular(10)), child: picture),
            ),
            Padding(
              padding: const EdgeInsets.all(6),
              child: Row(
                children: [
                  Text('m ${meter.round()}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  const Spacer(),
                  if (tilt != null)
                    Flexible(
                      child: Text(
                        _tiltText(tilt),
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: _tiltColor(tiltLevelOf(tilt)), fontWeight: FontWeight.w600),
                      ),
                    ),
                ],
              ),
            ),
            if (lowRes)
              const Padding(
                padding: EdgeInsets.fromLTRB(6, 0, 6, 6),
                child: Text('Under 5 MP', style: TextStyle(color: AppColors.bleached, fontSize: 12)),
              ),
          ],
        ),
      ),
    );
  }
}
