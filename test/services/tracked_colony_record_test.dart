import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/services/health_history_recorder.dart';
import 'package:reefsight_mobile/services/tracked_colony_record.dart';

// Sub-plan 4 (storage-and-metrics), task 2: the row shape locked by
// ReefSight_Specification.md's "Storage" section -- "one row per tracked
// colony: track ID, species + confidence, health label + confidence history
// across frames, first/last-seen timestamp, size estimate, reference path
// to its mask file." `species`/`speciesConfidence` are nullable because the
// currently-shipping `coralvos_primary` segmentation model is single-class
// (nc: 1, "coral") -- no species model exists yet (mobile/CLAUDE.md,
// "Models are interim, not final"). `sizePx` stays in pixels per this
// sub-plan's resolved scope (no pixel-to-real-world calibration mechanism
// exists in the docs or code).

void main() {
  group('TrackedColonyRecord', () {
    TrackedColonyRecord buildRecord({int? id}) => TrackedColonyRecord(
          id: id,
          sessionId: 1,
          trackId: 7,
          species: null,
          speciesConfidence: null,
          healthLabel: 'CORAL_BL',
          healthHistory: [
            HealthHistorySample(
              label: 'CORAL',
              confidence: 0.6,
              at: DateTime.utc(2026, 1, 1, 12, 0),
            ),
            HealthHistorySample(
              label: 'CORAL_BL',
              confidence: 0.9,
              at: DateTime.utc(2026, 1, 1, 12, 1),
            ),
          ],
          sizePx: 1234.5,
          firstSeenAt: DateTime.utc(2026, 1, 1, 12, 0),
          lastSeenAt: DateTime.utc(2026, 1, 1, 12, 1),
          maskPath: '/documents/masks/session1_track7.png',
        );

    test('round-trips every field through toMap/fromMap', () {
      final record = buildRecord(id: 42);
      final restored = TrackedColonyRecord.fromMap(record.toMap());

      expect(restored.id, record.id);
      expect(restored.sessionId, record.sessionId);
      expect(restored.trackId, record.trackId);
      expect(restored.species, isNull);
      expect(restored.speciesConfidence, isNull);
      expect(restored.healthLabel, record.healthLabel);
      expect(restored.sizePx, record.sizePx);
      expect(restored.firstSeenAt, record.firstSeenAt);
      expect(restored.lastSeenAt, record.lastSeenAt);
      expect(restored.maskPath, record.maskPath);
    });

    test('round-trips the full health history sequence, in order', () {
      final record = buildRecord();
      final restored = TrackedColonyRecord.fromMap(record.toMap());

      expect(restored.healthHistory, hasLength(2));
      expect(restored.healthHistory[0].label, 'CORAL');
      expect(restored.healthHistory[0].confidence, 0.6);
      expect(restored.healthHistory[0].at, DateTime.utc(2026, 1, 1, 12, 0));
      expect(restored.healthHistory[1].label, 'CORAL_BL');
      expect(restored.healthHistory[1].confidence, 0.9);
    });

    test('round-trips an empty health history', () {
      final record = TrackedColonyRecord(
        sessionId: 1,
        trackId: 7,
        healthHistory: const [],
        firstSeenAt: DateTime.utc(2026, 1, 1),
        lastSeenAt: DateTime.utc(2026, 1, 1),
      );

      final restored = TrackedColonyRecord.fromMap(record.toMap());

      expect(restored.healthHistory, isEmpty);
    });

    test('round-trips a populated species + confidence', () {
      final record = TrackedColonyRecord(
        sessionId: 1,
        trackId: 7,
        species: 'Porites',
        speciesConfidence: 0.75,
        healthHistory: const [],
        firstSeenAt: DateTime.utc(2026, 1, 1),
        lastSeenAt: DateTime.utc(2026, 1, 1),
      );

      final restored = TrackedColonyRecord.fromMap(record.toMap());

      expect(restored.species, 'Porites');
      expect(restored.speciesConfidence, 0.75);
    });

    test('id is null before insertion and preserved once assigned', () {
      final unsaved = buildRecord();
      expect(unsaved.id, isNull);

      final saved = buildRecord(id: 5);
      expect(saved.id, 5);
    });
  });
}
