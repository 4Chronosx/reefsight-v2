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
  Future<void> stop() async {
    if (!_isRecording) return;
    await _stopRecording();
    _isRecording = false;
  }

  static String _defaultFileName() {
    final timestamp = DateTime.now()
        .toUtc()
        .toIso8601String()
        .replaceAll(RegExp('[:.]'), '-');
    return 'transect_$timestamp.mov';
  }
}
