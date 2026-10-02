import 'dart:convert';

import 'health_history_recorder.dart';

/// One tracked colony's full record, per `ReefSight_Specification.md`'s
/// "Storage" line: "one row per tracked colony: track ID, species +
/// confidence, health label + confidence history across frames, first/
/// last-seen timestamp, size estimate, reference path to its mask file."
///
/// [species]/[speciesConfidence] are `null` on every row this cycle -- the
/// shipping Stage B segmentation model (`ModelAssets.stageBSegmentation`) is
/// single-class (`nc: 1`, "coral", in every Stage B arm so far), not the future
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
    this.photoPath,
    this.photoCropPath,
    this.photoLabel,
    this.photoConfidence,
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

  /// Sub-plan 18: the colony's context photo and exact classifier crop
  /// (`ColonyPhotoStore`), as paths *relative to the documents directory* --
  /// resolve with `resolveColonyPhoto`. `null` if the colony was never
  /// classified. The photo is the best sample *with the colony's own label*
  /// when there is one. [photoLabel]/[photoConfidence] are that sample's
  /// classification, stored rather than re-derived from the history (which
  /// also holds samples whose photo failed to encode, and ties).
  final String? photoPath;
  final String? photoCropPath;
  final String? photoLabel;
  final double? photoConfidence;

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
                    'uncertain': sample.uncertain,
                  })
              .toList(growable: false),
        ),
        'size_px': sizePx,
        'first_seen_at': firstSeenAt.toIso8601String(),
        'last_seen_at': lastSeenAt.toIso8601String(),
        'mask_path': maskPath,
        'photo_path': photoPath,
        'photo_crop_path': photoCropPath,
        'photo_label': photoLabel,
        'photo_confidence': photoConfidence,
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
              // Added by sub-plan 10; rows written before it have no key.
              uncertain: (entry['uncertain'] as bool?) ?? false,
            ),
          )
          .toList(growable: false),
      sizePx: (map['size_px'] as num?)?.toDouble(),
      firstSeenAt: DateTime.parse(map['first_seen_at'] as String),
      lastSeenAt: DateTime.parse(map['last_seen_at'] as String),
      maskPath: map['mask_path'] as String?,
      photoPath: map['photo_path'] as String?,
      photoCropPath: map['photo_crop_path'] as String?,
      photoLabel: map['photo_label'] as String?,
      photoConfidence: (map['photo_confidence'] as num?)?.toDouble(),
    );
  }
}
