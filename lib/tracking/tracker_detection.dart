/// A single frame's detection, decoupled from any specific detector/plugin
/// output (e.g. `ultralytics_yolo`'s `YOLOResult`) so the BoT-SORT port
/// stays testable headlessly, without a device or the live camera pipeline.
class TrackerDetection {
  const TrackerDetection({
    required this.x1,
    required this.y1,
    required this.x2,
    required this.y2,
    required this.score,
  }) : assert(
          x2 > x1 && y2 > y1,
          'TrackerDetection must have a positive width and height — a '
          'zero/negative-area box reaches KalmanFilter.initiate() as a zero '
          'variance, and linalg.invert() then divides by that zero instead '
          'of failing loudly.',
        );

  /// Top-left/bottom-right bounding box, same `(x1, y1, x2, y2)` convention
  /// as BoT-SORT's `tlbr`.
  final double x1;
  final double y1;
  final double x2;
  final double y2;

  /// Detection confidence in `[0, 1]`.
  final double score;

  double get width => x2 - x1;
  double get height => y2 - y1;

  /// `(top-left x, top-left y, width, height)` — the format BoT-SORT's
  /// `STrack` stores internally.
  List<double> get tlwh => [x1, y1, width, height];
}
