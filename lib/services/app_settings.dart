import 'package:flutter/foundation.dart';

import 'classification_policy.dart';
import 'crop_geometry.dart';

/// App-wide runtime settings that don't need persistence (sub-plan 6,
/// ui-ux-overhaul, step 7: "stored in-memory ... whichever needs no new
/// dependency"). Resets on relaunch -- acceptable for a diagnostics toggle a
/// field tester flips on only for the current session; SQLite would need a
/// schema change, which sub-plan step 2 rules out for this sub-plan.
class AppSettings {
  AppSettings._();

  static final instance = AppSettings._();

  /// Live screen's per-track debug overlay (pre-sub-plan-6
  /// `_PerformanceAndTracksOverlay`, extracted to `DiagnosticsOverlay` in
  /// this sub-plan) is hidden by default and toggled here (sub-plan step 6).
  /// Kept, not removed, because it's useful for field debugging and thesis
  /// screenshots.
  final showDiagnostics = ValueNotifier<bool>(false);

  /// Sub-plan 09 (live-loop decoupling) measurement baseline: runs Live with
  /// the pre-sub-plan-09 loop (frames dropped while classifying, empty
  /// frames skipped) so one device session can record before *and* after
  /// numbers. Off by default; remove with the legacy path once the numbers
  /// are recorded in `mobile/sub-plans/09-live-loop-decoupling.md`.
  final legacyLiveLoop = ValueNotifier<bool>(false);

  /// Sub-plan 10: how classifier crops are cut. `insideMaskSquare` is the
  /// spec'd default; the box styles exist for ML sub-plan 2's comparison
  /// and for debugging. Read once when Live opens, like [legacyLiveLoop].
  final cropStyle = ValueNotifier<CropStyle>(CropStyle.insideMaskSquare);

  /// Classification thresholds (sub-plan 10's starting values by default),
  /// overridable for comparing runs on the same footage. Read once when
  /// Live opens, like [cropStyle], and logged at transect start.
  final classificationThresholds = ValueNotifier<ClassificationThresholds>(
    ClassificationThresholds.defaults,
  );
}
