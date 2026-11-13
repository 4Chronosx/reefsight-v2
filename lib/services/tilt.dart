import 'dart:async';
import 'dart:math' as math;

import 'package:sensors_plus/sensors_plus.dart';

/// Issue #4: the level indicator (alignment doc §6, build order step 1).
///
/// The photo transect method wants the camera pointing straight down at the
/// 1 × 1 m frame. A tilted camera biases cover -- near coral looks larger
/// than far coral -- so the tilt is shown live and saved with every still
/// (`transect_frames.tilt_deg`). In Physical mode the pole holds the angle
/// and the indicator is advisory; Virtual mode (#14-15) will gate on it.

/// Within this, the shot counts as level. §6's starting tolerance, to be
/// tuned on data.
const kLevelToleranceDeg = 5.0;

/// Past [kLevelToleranceDeg] but within this, the indicator warns; beyond
/// it, it shows the shot as off.
const kNearToleranceDeg = 10.0;

/// The angle between the back camera's axis and straight down, in degrees
/// (0-90), from an accelerometer reading of gravity in the phone's frame.
///
/// The back camera looks along the phone's -z axis, so a phone lying flat
/// (camera down) reads gravity entirely on z: 0°. Face up and face down give
/// the same tilt -- only the angle from the vertical matters, not which way
/// the screen faces. The units of the reading don't matter. `null` when the
/// reading has no gravity in it (a zero sample).
double? tiltFromVerticalDeg(double x, double y, double z) {
  final magnitude = math.sqrt(x * x + y * y + z * z);
  if (magnitude < 1e-6) return null;
  final cosine = (z.abs() / magnitude).clamp(0.0, 1.0);
  return math.acos(cosine) * 180 / math.pi;
}

/// Smooths the raw accelerometer stream so the readout doesn't jitter with
/// every hand tremor or surge: an exponential moving average of the gravity
/// vector (filtering the vector, not the angle, keeps it right near 0°,
/// where the angle can't go negative).
class TiltFilter {
  TiltFilter({this.alpha = 0.2}) {
    if (!(alpha > 0 && alpha <= 1)) {
      throw ArgumentError.value(alpha, 'alpha', 'must be in (0, 1]');
    }
  }

  /// The weight of each new sample: higher reacts faster, lower is smoother.
  final double alpha;

  double? _x, _y, _z;

  /// Adds one accelerometer sample. A zero sample is ignored.
  void add(double x, double y, double z) {
    if (tiltFromVerticalDeg(x, y, z) == null) return;
    if (_x == null) {
      _x = x;
      _y = y;
      _z = z;
      return;
    }
    _x = _x! + alpha * (x - _x!);
    _y = _y! + alpha * (y - _y!);
    _z = _z! + alpha * (z - _z!);
  }

  /// The smoothed tilt, or `null` before the first usable sample.
  double? get tiltDeg => _x == null ? null : tiltFromVerticalDeg(_x!, _y!, _z!);
}

enum TiltLevel { level, near, off, unknown }

TiltLevel tiltLevelOf(double? tiltDeg) {
  if (tiltDeg == null) return TiltLevel.unknown;
  if (tiltDeg <= kLevelToleranceDeg) return TiltLevel.level;
  if (tiltDeg <= kNearToleranceDeg) return TiltLevel.near;
  return TiltLevel.off;
}

/// A stream of smoothed tilt readings, in degrees. Behind an interface
/// because `sensors_plus` has no platform channel under `flutter test`.
abstract interface class TiltSource {
  Stream<double> tiltDegrees();
}

/// The real [TiltSource]: the accelerometer (which includes gravity) at the
/// UI rate, through a [TiltFilter].
class SensorsPlusTiltSource implements TiltSource {
  const SensorsPlusTiltSource();

  @override
  Stream<double> tiltDegrees() {
    final filter = TiltFilter();
    return accelerometerEventStream(samplingPeriod: SensorInterval.uiInterval)
        .map((e) {
          filter.add(e.x, e.y, e.z);
          return filter.tiltDeg;
        })
        .where((t) => t != null)
        .cast<double>();
  }
}
