/// Sub-plan 12 (`mobile/sub-plans/12-entry-exit-gps.md`): the Spec's
/// "surface GPS fix at dive entry/exit only" (`ReefSight_Specification.md`,
/// Phase C, "Density, positioning, and sync"). Two topside fixes per
/// transect -- entry on Setup before descent, exit on Summary after
/// surfacing. Neither ever feeds a metric: density still divides by the
/// physical tape length. The entry-exit distance is a QA check for a human
/// to compare against the tape, nothing more.
library;

import 'dart:math' as math;

/// Where a fix came from, so the report can say which is which (decision 4).
enum GeoFixSource { gps, manual }

class GeoFix {
  GeoFix({
    required this.lat,
    required this.lon,
    this.accuracyM,
    required DateTime at,
    required this.source,
  }) : at = at.toUtc();

  /// Decimal degrees, WGS84.
  final double lat;
  final double lon;

  /// Horizontal accuracy radius from the GPS. `null` for a manual fix.
  final double? accuracyM;

  /// When the fix was taken (or typed in), always UTC.
  final DateTime at;

  final GeoFixSource source;

  /// The five `transect_sessions` columns for this fix, named
  /// `<prefix>_lat`, `<prefix>_lon`, ... -- `TransectSession.toMap` calls
  /// this with `entry` and `exit`.
  Map<String, Object?> toColumns(String prefix) => {
        '${prefix}_lat': lat,
        '${prefix}_lon': lon,
        '${prefix}_accuracy_m': accuracyM,
        '${prefix}_at': at.toIso8601String(),
        '${prefix}_source': source.name,
      };

  /// [toColumns] for a missing fix: every column `null`.
  static Map<String, Object?> nullColumns(String prefix) => {
        '${prefix}_lat': null,
        '${prefix}_lon': null,
        '${prefix}_accuracy_m': null,
        '${prefix}_at': null,
        '${prefix}_source': null,
      };

  /// `null` unless lat, lon, time and a recognised source are all present
  /// -- a partial row is treated as no fix, not guessed at.
  static GeoFix? fromColumns(Map<String, Object?> map, String prefix) {
    final lat = map['${prefix}_lat'];
    final lon = map['${prefix}_lon'];
    final at = map['${prefix}_at'];
    final source = GeoFixSource.values.asNameMap()[map['${prefix}_source']];
    if (lat is! num || lon is! num || at is! String || source == null) return null;
    return GeoFix(
      lat: lat.toDouble(),
      lon: lon.toDouble(),
      accuracyM: (map['${prefix}_accuracy_m'] as num?)?.toDouble(),
      at: DateTime.parse(at),
      source: source,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is GeoFix &&
      other.lat == lat &&
      other.lon == lon &&
      other.accuracyM == accuracyM &&
      other.at == at &&
      other.source == source;

  @override
  int get hashCode => Object.hash(lat, lon, accuracyM, at, source);

  @override
  String toString() => 'GeoFix(${formatFix(this)}, ${at.toIso8601String()})';
}

/// Mean Earth radius (IUGG), in meters.
const double _earthRadiusM = 6371008.8;

double _haversineM(double lat1, double lon1, double lat2, double lon2) {
  double rad(double deg) => deg * math.pi / 180;
  final dLat = rad(lat2 - lat1);
  final dLon = rad(lon2 - lon1);
  final h = math.pow(math.sin(dLat / 2), 2) +
      math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.pow(math.sin(dLon / 2), 2);
  return 2 * _earthRadiusM * math.asin(math.min(1, math.sqrt(h)));
}

/// Great-circle distance between two fixes. With each fix good to roughly
/// ±5-10 m, this is a sanity check against the tape length, not a
/// measurement.
double distanceMeters(GeoFix a, GeoFix b) => _haversineM(a.lat, a.lon, b.lat, b.lon);

/// Cordova, Cebu -- the study site. Manual entries far from here are
/// probably swapped lat/lon or a dropped minus sign.
const double cordovaLat = 10.2536;
const double cordovaLon = 123.9497;

/// Whether a point is within [maxKm] of Cordova. Used only for a
/// non-blocking hint on manual entry, never to reject a value.
bool isNearCordova(double lat, double lon, {double maxKm = 50}) =>
    _haversineM(lat, lon, cordovaLat, cordovaLon) <= maxKm * 1000;

String? _rangeError(String text, double limit, String name) {
  final value = double.tryParse(text.trim());
  if (value == null) return 'Enter $name in decimal degrees';
  if (value < -limit || value > limit) {
    return '$name must be between -${limit.toStringAsFixed(0)} and ${limit.toStringAsFixed(0)}';
  }
  return null;
}

/// Manual-entry validation: `null` when [text] is a latitude in -90..90.
String? latitudeError(String text) => _rangeError(text, 90, 'Latitude');

/// Manual-entry validation: `null` when [text] is a longitude in -180..180.
String? longitudeError(String text) => _rangeError(text, 180, 'Longitude');

/// `10.3256° N, 123.9468° E`.
String formatCoordinates(double lat, double lon) =>
    '${lat.abs().toStringAsFixed(4)}° ${lat < 0 ? 'S' : 'N'}, '
    '${lon.abs().toStringAsFixed(4)}° ${lon < 0 ? 'W' : 'E'}';

/// `±8 m · 10.3256° N, 123.9468° E` for GPS, `manual · ...` for a typed-in
/// fix, so the source is visible wherever the fix is shown.
String formatFix(GeoFix fix) {
  final accuracy = fix.accuracyM;
  final prefix = fix.source == GeoFixSource.manual
      ? 'manual'
      : accuracy == null
          ? 'GPS'
          : '±${accuracy.toStringAsFixed(0)} m';
  return '$prefix · ${formatCoordinates(fix.lat, fix.lon)}';
}
