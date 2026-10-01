import 'dart:async';

import 'package:reefsight_mobile/services/geo_fix.dart';
import 'package:reefsight_mobile/services/location_provider.dart';

/// A fixed GPS fix near Cordova, for tests that need one.
GeoFix testGpsFix({double lat = 10.2541, double lon = 123.9502, double accuracyM = 8}) =>
    GeoFix(
      lat: lat,
      lon: lon,
      accuracyM: accuracyM,
      at: DateTime.utc(2026, 10, 2, 1),
      source: GeoFixSource.gps,
    );

/// Scripted [LocationProvider] for sub-plan 12's GPS card. The real one is
/// `geolocator`'s platform channel, which doesn't exist under
/// `flutter test`. Returns [results] in order, repeating the last; with
/// [hold] set, every call waits on it first (to see "Acquiring…").
class FakeLocationProvider implements LocationProvider {
  FakeLocationProvider(this.results) : assert(results.isNotEmpty);

  FakeLocationProvider.fix([GeoFix? fix]) : this([LocationFix(fix ?? testGpsFix())]);

  FakeLocationProvider.failure([LocationFailureKind kind = LocationFailureKind.timeout])
      : this([LocationFailure(kind)]);

  final List<LocationResult> results;
  Completer<void>? hold;
  int calls = 0;

  @override
  Future<LocationResult> current() async {
    final result = results[calls < results.length ? calls : results.length - 1];
    calls++;
    final gate = hold;
    if (gate != null) await gate.future;
    return result;
  }
}
