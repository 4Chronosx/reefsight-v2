import 'dart:convert';

import 'health_history_recorder.dart';

/// One tracked colony's full record, per `ReefSight_Specification.md`'s
/// "Storage" line: "one row per tracked colony: track ID, species +
/// confidence, health label + confidence history across frames, first/
/// last-seen timestamp, size estimate, reference path to its mask file."
///
/// [species]/[speciesConfidence] are `null` on every row this cycle -- the
/// shipping `coralvos_primary` segmentation model is single-class (`nc: 1`,
/// "coral"; see `machine-learning-pipeline/datasets_converted/
/// coralvos_primary_blend/data_coralvos_primary.yaml`), not the future
/// per-forward-pass species model the Specification describes. The columns
/// exist now for forward compatibility, not populated by fabrication.
///
/// [sizePx] stays in raw pixel area (matches `colony_size.dart`'s current
/// scope) -- no pixel-to-real-world calibration mechanism exists in the
/// docs or code for this sub-plan.
class TrackedColonyRecord {
  TrackedColonyRecord({
    this.id,
    required this.sessionId,
    required this.trackId,
    this.species,
    this.speciesConfidence,
    this.healthLabel,
    required this.healthHistory,
    this.sizePx,
    required this.firstSeenAt,
    required this.lastSeenAt,
    this.maskPath,
  });

  /// `null` before the row has been inserted and assigned a rowid.
  final int? id;

  final int sessionId;
  final int trackId;

  final String? species;
  final double? speciesConfidence;

  /// The final aggregated label (see `HealthAggregator.currentLabel`),
  /// `null` if the colony was never successfully classified.
  final String? healthLabel;

  /// Raw per-frame classifications (see `HealthHistoryRecorder`), in
  /// recorded order.
  final List<HealthHistorySample> healthHistory;

  final double? sizePx;
  final DateTime firstSeenAt;
  final DateTime lastSeenAt;

  /// Path to the persisted mask file (see `MaskStorage`), `null` if no mask
  /// was ever available for this track.
  final String? maskPath;

  /// Column names match `transect_database.dart`'s `tracked_colonies` table
  /// exactly -- this is the single source of truth for that mapping.
  /// [healthHistory] is stored as a JSON-encoded TEXT column: at one
  /// transect's colony count, a separate history table buys nothing a JSON
  /// blob doesn't already give.
  Map<String, Object?> toMap() => {
        'id': id,
        'session_id': sessionId,
        'track_id': trackId,
        'species': species,
        'species_confidence': speciesConfidence,
        'health_label': healthLabel,
        'health_history': jsonEncode(
          healthHistory
              .map((sample) => {
                    'label': sample.label,
                    'confidence': sample.confidence,
                    'at': sample.at.toIso8601String(),
                  })
              .toList(growable: false),
        ),
        'size_px': sizePx,
        'first_seen_at': firstSeenAt.toIso8601String(),
        'last_seen_at': lastSeenAt.toIso8601String(),
        'mask_path': maskPath,
      };

  static TrackedColonyRecord fromMap(Map<String, Object?> map) {
    final historyRaw = jsonDecode(map['health_history'] as String) as List;
    return TrackedColonyRecord(
      id: map['id'] as int?,
      sessionId: map['session_id'] as int,
      trackId: map['track_id'] as int,
      species: map['species'] as String?,
      speciesConfidence: (map['species_confidence'] as num?)?.toDouble(),
      healthLabel: map['health_label'] as String?,
      healthHistory: historyRaw
          .cast<Map<String, Object?>>()
          .map(
            (entry) => HealthHistorySample(
              label: entry['label'] as String,
              confidence: (entry['confidence'] as num).toDouble(),
              at: DateTime.parse(entry['at'] as String),
            ),
          )
          .toList(growable: false),
      sizePx: (map['size_px'] as num?)?.toDouble(),
      firstSeenAt: DateTime.parse(map['first_seen_at'] as String),
      lastSeenAt: DateTime.parse(map['last_seen_at'] as String),
      maskPath: map['mask_path'] as String?,
    );
  }
}
