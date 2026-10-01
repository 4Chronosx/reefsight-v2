import 'dart:async';

import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';

import 'geo_fix.dart';

/// Sub-plan 12 step 2: one topside position fix, behind an interface so
/// widget tests can substitute a fake (same pattern as `device_info.dart`'s
/// `BatteryInfo`/`StorageInfo`). Only ever called on the surface -- Setup
/// before descent, Summary after surfacing. Never during Live: there's no
/// GPS signal underwater.
abstract interface class LocationProvider {
  /// Never throws: every failure comes back as a [LocationFailure] with a
  /// reason the diver can act on.
  Future<LocationResult> current();
}

sealed class LocationResult {
  const LocationResult();
}

class LocationFix extends LocationResult {
  const LocationFix(this.fix);

  final GeoFix fix;
}

/// The distinct ways a fix can fail (step 2: "permission denied, location
/// services off and timeout as distinct, user-readable states").
enum LocationFailureKind {
  servicesOff,
  permissionDenied,
  permissionDeniedForever,
  timeout,
  error,
}

class LocationFailure extends LocationResult {
  const LocationFailure(this.kind);

  final LocationFailureKind kind;

  /// One line for the GPS card. Each ends by pointing at manual entry, the
  /// always-available fallback (decision 4).
  String get reason => switch (kind) {
        LocationFailureKind.servicesOff =>
          'Location is off. Turn it on in Settings, or enter the position manually.',
        LocationFailureKind.permissionDenied =>
          'Location permission was denied. Retry to be asked again, or enter it manually.',
        LocationFailureKind.permissionDeniedForever =>
          'Location permission is off for ReefSight. Allow it in Settings, or enter it manually.',
        LocationFailureKind.timeout =>
          'No GPS fix within 20 s. Move to open sky and retry, or enter it manually.',
        LocationFailureKind.error =>
          "Couldn't read the position. Retry, or enter it manually.",
      };
}

/// [LocationProvider] from `geolocator`: best accuracy, with a time limit
/// so a phone under a boat canopy doesn't spin forever.
class GeolocatorLocationProvider implements LocationProvider {
  const GeolocatorLocationProvider({this.timeLimit = const Duration(seconds: 20)});

  final Duration timeLimit;

  @override
  Future<LocationResult> current() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        return const LocationFailure(LocationFailureKind.servicesOff);
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      switch (permission) {
        case LocationPermission.denied:
          return const LocationFailure(LocationFailureKind.permissionDenied);
        case LocationPermission.deniedForever:
          return const LocationFailure(LocationFailureKind.permissionDeniedForever);
        case LocationPermission.whileInUse:
        case LocationPermission.always:
        case LocationPermission.unableToDetermine:
          break;
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: LocationSettings(
          accuracy: LocationAccuracy.best,
          timeLimit: timeLimit,
        ),
      );
      return LocationFix(
        GeoFix(
          lat: position.latitude,
          lon: position.longitude,
          // geolocator reports 0 when the platform gives no accuracy.
          accuracyM: position.accuracy > 0 ? position.accuracy : null,
          at: position.timestamp,
          source: GeoFixSource.gps,
        ),
      );
    } on TimeoutException {
      return const LocationFailure(LocationFailureKind.timeout);
    } on LocationServiceDisabledException {
      return const LocationFailure(LocationFailureKind.servicesOff);
    } on PermissionDeniedException {
      return const LocationFailure(LocationFailureKind.permissionDenied);
    } on MissingPluginException {
      // No plugin (e.g. under `flutter test` without a fake).
      return const LocationFailure(LocationFailureKind.error);
    } catch (_) {
      return const LocationFailure(LocationFailureKind.error);
    }
  }
}
