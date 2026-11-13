import 'dart:math';

import 'transect_session.dart';

/// Issue #2: TB 2019-04's random transect placement (Fig. 3) -- a random
/// distance along the station's 75 m axis and a random 0-25 m swim-out
/// perpendicular to it -- plus the station fields a station transect carries
/// into `insertSession`.

/// The station is 75 × 25 m (TB 2019-04, Annex 1 §1).
const kStationAxisM = 75.0;
const kStationSwimoutM = 25.0;

class RandomPlacement {
  const RandomPlacement({required this.alongM, required this.swimoutM});

  final double alongM;
  final double swimoutM;
}

/// Rounded to 0.1 m: a diver reads a tape to the decimeter at best, and a
/// rounded number is what gets written on the slate. [rng] is injected so
/// tests can seed it.
RandomPlacement generateRandomPlacement(Random rng) {
  double draw(double max) => (rng.nextDouble() * max * 10).round() / 10;
  return RandomPlacement(alongM: draw(kStationAxisM), swimoutM: draw(kStationSwimoutM));
}

String? _rangeError(String text, double max) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;
  final value = double.tryParse(trimmed);
  if (value == null || value < 0 || value > max) {
    return 'Enter 0-${max.toStringAsFixed(0)} m';
  }
  return null;
}

/// `null` for a blank (not recorded) or in-range entry. Outside the station
/// is an error, not a hint: the transect would not be in the station.
String? alongError(String text) => _rangeError(text, kStationAxisM);
String? swimoutError(String text) => _rangeError(text, kStationSwimoutM);

/// What a station transect adds to a [TransectSession] at insert. One value
/// instead of seven constructor parameters on Setup -> Live, so the Live
/// screen's change stays a single line.
class TransectPlacement {
  const TransectPlacement({
    required this.stationId,
    required this.transectNumber,
    required this.captureSource,
    this.depthStartM,
    this.depthEndM,
    this.randomAlongM,
    this.randomSwimoutM,
  });

  final int stationId;
  final int transectNumber;
  final CaptureSource captureSource;
  final double? depthStartM;
  final double? depthEndM;
  final double? randomAlongM;
  final double? randomSwimoutM;

  TransectSession applyTo(TransectSession session) => session.copyWith(
        stationId: stationId,
        transectNumber: transectNumber,
        captureSource: captureSource,
        depthStartM: depthStartM,
        depthEndM: depthEndM,
        randomAlongM: randomAlongM,
        randomSwimoutM: randomSwimoutM,
      );
}
