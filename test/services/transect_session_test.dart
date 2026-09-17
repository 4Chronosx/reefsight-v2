import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/services/transect_session.dart';

// Sub-plan 4 (storage-and-metrics), task 2: a transect run's identity and
// the physical tape length that later serves as the density denominator
// (ReefSight_Specification.md, "Density, positioning, and sync" -- tape/
// line, never GPS- or pixel-derived). Belt width defaults to 1.0m, matching
// NCRMP's 10m x 1m belt-transect convention (Dev Plan Track 3 §9-10), and is
// overridable per session since it isn't itself the settled decision -- only
// "use the physical tape, not GPS" is.

void main() {
  group('TransectSession', () {
    test('defaults beltWidthMeters to 1.0 when not given', () {
      final session = TransectSession(
        id: 1,
        startedAt: DateTime.utc(2026, 1, 1),
        tapeLengthMeters: 10,
      );

      expect(session.beltWidthMeters, 1.0);
    });

    test('endedAt is null for an in-progress session', () {
      final session = TransectSession(
        id: 1,
        startedAt: DateTime.utc(2026, 1, 1),
        tapeLengthMeters: 10,
      );

      expect(session.endedAt, isNull);
    });

    test('copyWith replaces only the given fields', () {
      final started = DateTime.utc(2026, 1, 1);
      final ended = DateTime.utc(2026, 1, 1, 0, 30);
      final session = TransectSession(
        id: 1,
        startedAt: started,
        tapeLengthMeters: 10,
      );

      final closed = session.copyWith(endedAt: ended);

      expect(closed.id, 1);
      expect(closed.startedAt, started);
      expect(closed.tapeLengthMeters, 10);
      expect(closed.endedAt, ended);
    });

    test('round-trips through toMap/fromMap', () {
      final session = TransectSession(
        id: 1,
        startedAt: DateTime.utc(2026, 1, 1, 8),
        endedAt: DateTime.utc(2026, 1, 1, 8, 45),
        tapeLengthMeters: 10,
        beltWidthMeters: 2,
      );

      final restored = TransectSession.fromMap(session.toMap());

      expect(restored.id, session.id);
      expect(restored.startedAt, session.startedAt);
      expect(restored.endedAt, session.endedAt);
      expect(restored.tapeLengthMeters, session.tapeLengthMeters);
      expect(restored.beltWidthMeters, session.beltWidthMeters);
    });

    test('round-trips an in-progress session (null endedAt) through the map',
        () {
      final session = TransectSession(
        id: 1,
        startedAt: DateTime.utc(2026, 1, 1),
        tapeLengthMeters: 10,
      );

      final restored = TransectSession.fromMap(session.toMap());

      expect(restored.endedAt, isNull);
    });

    test('siteName/observerName default to null and round-trip through the '
        'map when set', () {
      final withoutMetadata = TransectSession(
        id: 1,
        startedAt: DateTime.utc(2026, 1, 1),
        tapeLengthMeters: 10,
      );
      expect(withoutMetadata.siteName, isNull);
      expect(withoutMetadata.observerName, isNull);

      final withMetadata = TransectSession(
        id: 1,
        startedAt: DateTime.utc(2026, 1, 1),
        tapeLengthMeters: 10,
        siteName: 'Marigondon Reef',
        observerName: 'C. Zaballa',
      );
      final restored = TransectSession.fromMap(withMetadata.toMap());

      expect(restored.siteName, 'Marigondon Reef');
      expect(restored.observerName, 'C. Zaballa');
    });
  });
}
