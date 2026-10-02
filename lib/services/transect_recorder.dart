import 'dart:ui' show AppLifecycleState;

/// Lifecycle wrapper for one transect's continuous video recording
/// (sub-plan 3 step 1).
///
/// The actual native start/stop is injected as plain functions rather than
/// this class depending directly on the forked `ultralytics_yolo`
/// `YOLOViewController`'s recording methods -- keeps this file testable
/// without a real platform channel / native camera session, and keeps the
/// coupling to the fork's exact API surface localized to whoever
/// constructs this (the live transect screen).
class TransectRecorder {
  TransectRecorder({
    required Future<void> Function(String outputPath) startRecording,
    required Future<void> Function() stopRecording,
    String Function()? fileNameBuilder,
  })  : _startRecording = startRecording,
        _stopRecording = stopRecording,
        _fileNameBuilder = fileNameBuilder ?? _defaultFileName;

  final Future<void> Function(String outputPath) _startRecording;
  final Future<void> Function() _stopRecording;
  final String Function() _fileNameBuilder;

  bool _isRecording = false;
  String? _currentOutputPath;

  bool get isRecording => _isRecording;

  /// The most recent recording's output path -- set on [start] and, unlike
  /// [isRecording], NOT cleared by [stop], so callers can still read where
  /// the finished file landed.
  String? get currentOutputPath => _currentOutputPath;

  /// Starts a new recording under [outputDirectory]. Calling this while
  /// already recording is a no-op that returns the existing path (matches
  /// "one continuous file per transect" -- a second start() mid-transect
  /// isn't a new file).
  Future<String> start(String outputDirectory) async {
    if (_isRecording) return _currentOutputPath!;

    final path = '$outputDirectory/${_fileNameBuilder()}';
    await _startRecording(path);
    _isRecording = true;
    _currentOutputPath = path;
    return path;
  }

  /// Stops the current recording. A no-op if nothing is recording.
  ///
  /// A failed stop still ends the recording here (the error propagates): the
  /// native side has nothing more to stop, and retrying would fail again.
  Future<void> stop() async {
    if (!_isRecording) return;
    try {
      await _stopRecording();
    } finally {
      _isRecording = false;
    }
  }

  static String _defaultFileName() {
    final timestamp = DateTime.now()
        .toUtc()
        .toIso8601String()
        .replaceAll(RegExp('[:.]'), '-');
    return 'transect_$timestamp.mov';
  }
}

/// Polls [condition] every [interval] until it holds (`true`) or [timeout]
/// passes (`false`). The Live screen uses it to wait for the camera's
/// platform view to attach before recording: the view is created after the
/// first frame, and a start sent before then never reached the camera.
Future<bool> waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 10),
  Duration interval = const Duration(milliseconds: 100),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) return false;
    await Future<void>.delayed(interval);
  }
  return true;
}

/// The Live screen's recording-issue line when the app leaves the
/// foreground mid-recording, or `null` when [state] doesn't interrupt it.
/// iOS stops the camera in the background (`hidden`, then `paused`), and
/// the recording isn't restarted on return, so the REC timer would keep
/// counting video that doesn't exist. `inactive` (Control Centre, a
/// notification banner) leaves the camera running. [elapsed] is the Live
/// screen's own REC time, so the stamp matches what the diver saw.
String? recordingInterruptedMessage(
  AppLifecycleState state, {
  required bool recording,
  required Duration elapsed,
}) {
  if (!recording) return null;
  if (state != AppLifecycleState.hidden && state != AppLifecycleState.paused) return null;
  final minutes = elapsed.inMinutes.toString().padLeft(2, '0');
  final seconds = (elapsed.inSeconds % 60).toString().padLeft(2, '0');
  return 'Interrupted at $minutes:$seconds - nothing after this is recorded';
}
