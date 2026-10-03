import 'bot_sort_tracker.dart';
import 'cmc_frames.dart';

/// The tracker configuration the live app runs, chosen in sub-plan 08
/// (`mobile/sub-plans/08-botsort-accuracy.md`) on the 6 CoralVOS tuning
/// videos at 8.33 Hz with the shipped Stage B detector (`coralscapes_v3`);
/// see `docs/botsort-tracking-accuracy-on-coralvos.md`. Tuned for that
/// detector's score distribution -- re-tune if Stage B changes.
///
/// Everything else in [BoTSortTracker] stays at the reference's defaults
/// (e.g. `fuseScore`), and the tracker itself is unchanged: these are
/// parameters, so the reference-parity fixtures still hold.
abstract final class TrackerConfig {
  /// MOT17 default 0.6. Sub-plan 08: 0.35-0.45 were indistinguishable on
  /// IDF1; 0.35 won the pre-registered count-error tie-break.
  static const trackHighThresh = 0.35;

  /// Unchanged (MOT17 default). Inert in the app: the plugin's 0.25
  /// confidence cutoff drops everything below it first.
  static const trackLowThresh = 0.1;

  /// MOT17 default 0.7 -- the main lever: at 0.7 more than half of the
  /// detector's mostly-correct detections could never start a track
  /// (undercounting); 0.55 overcounts, 0.65 undercounts again.
  static const newTrackThresh = 0.6;

  /// Unchanged (MOT17 default); 0.7 and 0.9 both scored worse.
  static const matchThresh = 0.8;

  /// Lost-track memory in **seconds**, converted to tracker updates at the
  /// live update rate by [trackBufferFor] -- so a change in inference rate
  /// can't silently change what it means. 3.75 s is the shipped 30 updates
  /// at 8 Hz; CoralVOS's short clips couldn't distinguish 2-5 s.
  static const trackBufferSeconds = 3.75;

  /// Camera motion compensation on: with a handheld camera it cut ID
  /// switches by ~3/4 on the tuning set (sub-plan 08 step 2).
  static const cmc = true;

  /// [trackBufferSeconds] in tracker updates at [updateHz] updates/second.
  /// (The reference's pruning order lets a lost track survive one update
  /// past this -- see `tool/src/track_eval_lib.dart`'s `bufferUpdatesFor`.)
  static int trackBufferFor(double updateHz) {
    final updates = (trackBufferSeconds * updateHz).round();
    return updates < 1 ? 1 : updates;
  }

  /// A tracker with this configuration. With [cmc], it expects a
  /// [ScaledGrayscaleFrame] from [decodeCmcFrame] on each `update`.
  static BoTSortTracker build({required double updateHz, bool cmc = TrackerConfig.cmc}) =>
      BoTSortTracker(
        trackHighThresh: trackHighThresh,
        trackLowThresh: trackLowThresh,
        newTrackThresh: newTrackThresh,
        trackBuffer: trackBufferFor(updateHz),
        matchThresh: matchThresh,
        cameraMotionCompensator: cmc ? ScaledFrameCompensator() : null,
      );
}
