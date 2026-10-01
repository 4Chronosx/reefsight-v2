import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/services/geo_fix.dart';

// Sub-plan 12 (entry/exit GPS): the two topside fixes per transect. Pure
// value logic -- distance (a QA check shown next to the tape length, never
// a metric), the near-Cordova sanity hint for manual entry, display
// formatting, and the column mapping `TransectSession` uses.

GeoFix _fix(double lat, double lon, {double? accuracyM, GeoFixSource source = GeoFixSource.gps}) =>
    GeoFix(
      lat: lat,
      lon: lon,
      accuracyM: accuracyM,
      at: DateTime.utc(2026, 10, 2, 1),
      source: source,
    );

void main() {
  group('distanceMeters', () {
    test('one degree of latitude is ~111.2 km', () {
      expect(distanceMeters(_fix(0, 0), _fix(1, 0)), closeTo(111195, 1));
    });

    test('is zero for the same point', () {
      expect(distanceMeters(_fix(10.3, 123.9), _fix(10.3, 123.9)), 0);
    });

    test('a ~50 m transect near Cordova reads as ~50 m', () {
      // 0.00045 deg latitude ~= 50.04 m.
      final d = distanceMeters(_fix(10.2500, 123.9500), _fix(10.25045, 123.9500));
      expect(d, closeTo(50.0, 0.5));
    });
  });

  group('isNearCordova', () {
    test('Cordova itself is near', () {
      expect(isNearCordova(10.25, 123.95), isTrue);
    });

    test('swapped lat/lon is not near', () {
      expect(isNearCordova(123.95, 10.25), isFalse);
    });

    test('a missing minus sign on longitude is not near', () {
      expect(isNearCordova(10.25, -123.95), isFalse);
    });

    test('about 60 km away is not near; about 30 km is', () {
      expect(isNearCordova(10.25 + 0.54, 123.95), isFalse); // ~60 km north
      expect(isNearCordova(10.25 + 0.27, 123.95), isTrue); // ~30 km north
    });
  });

  group('coordinate validation', () {
    test('latitude must parse and be within -90..90', () {
      expect(latitudeError('10.3256'), isNull);
      expect(latitudeError('-90'), isNull);
      expect(latitudeError('90.1'), isNotNull);
      expect(latitudeError(''), isNotNull);
      expect(latitudeError('abc'), isNotNull);
    });

    test('longitude must parse and be within -180..180', () {
      expect(longitudeError('123.9468'), isNull);
      expect(longitudeError('-180'), isNull);
      expect(longitudeError('180.5'), isNotNull);
      expect(longitudeError(' '), isNotNull);
    });
  });

  group('formatting', () {
    test('formats hemispheres with four decimals', () {
      expect(formatCoordinates(10.32561, 123.94679), '10.3256° N, 123.9468° E');
      expect(formatCoordinates(-33.5, -70.25), '33.5000° S, 70.2500° W');
    });

    test('a GPS fix shows its accuracy first', () {
      expect(
        formatFix(_fix(10.32561, 123.94679, accuracyM: 7.6)),
        '±8 m · 10.3256° N, 123.9468° E',
      );
    });

    test('a manual fix says manual instead of an accuracy', () {
      expect(
        formatFix(_fix(10.3256, 123.9468, source: GeoFixSource.manual)),
        'manual · 10.3256° N, 123.9468° E',
      );
    });
  });

  group('column mapping', () {
    test('round-trips through prefixed columns', () {
      final fix = _fix(10.3256, 123.9468, accuracyM: 8);
      final columns = fix.toColumns('entry');

      expect(columns.keys, [
        'entry_lat',
        'entry_lon',
        'entry_accuracy_m',
        'entry_at',
        'entry_source',
      ]);
      expect(columns['entry_at'], '2026-10-02T01:00:00.000Z');
      expect(columns['entry_source'], 'gps');
      expect(GeoFix.fromColumns(columns, 'entry'), fix);
    });

    test('null columns read back as no fix', () {
      expect(GeoFix.fromColumns(GeoFix.nullColumns('exit'), 'exit'), isNull);
      expect(GeoFix.fromColumns(const {}, 'exit'), isNull);
    });

    test('an unrecognised source reads back as no fix rather than a guess', () {
      final columns = _fix(1, 2).toColumns('exit')..['exit_source'] = 'sextant';
      expect(GeoFix.fromColumns(columns, 'exit'), isNull);
    });

    test('a local time is stored as UTC', () {
      final fix = GeoFix(
        lat: 1,
        lon: 2,
        at: DateTime.utc(2026, 10, 2, 1).toLocal(),
        source: GeoFixSource.manual,
      );
      expect(fix.toColumns('entry')['entry_at'], '2026-10-02T01:00:00.000Z');
    });
  });
}
