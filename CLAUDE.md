# CLAUDE.md — mobile/

Directory-scoped supplement to the repo root `.claude/CLAUDE.md` (still applies — read it first).

## Scope

Flutter app (Track 3 of `ReefSight_Development_Plan.md`) plus the Dart BoT-SORT port (Track 2).
Architecture is locked in `ReefSight_Specification.md`, Phase C, and `ReefSight_Development_Plan.md`,
Tracks 2-3 — read both before changing structure here, not just this file or `MASTER_PLAN.md`.

## Working conventions specific to this folder

- **Dart/Flutter code here can be run and tested normally** — the root CLAUDE.md's no-execution
  rule is Python-only (`machine-learning-pipeline/` notebooks). `flutter test`, `flutter run`,
  `dart analyze` etc. are all fine to run yourself here.
- **`ultralytics_yolo` Flutter plugin, used directly via `YOLOView`/`YOLOTask.classify`.** No custom
  `predict()` loop, no custom image preprocessing, no raw `tflite_flutter` integration — the
  Specification (Phase C, "Live inference") explicitly settled this. An earlier standalone prototype
  (`../reefsight`, not this repo) built the opposite (hand-rolled TFLite + DeepSORT + OSNet Re-ID) and
  was assessed and set aside for that reason — see the session history / `sub-plans/` here for why,
  and don't reintroduce that pattern.
- **BoT-SORT, no Re-ID.** The Dart tracker is a direct port of `NirAharon/BoT-SORT`'s
  `tracker/kalman_filter.py`, `tracker/matching.py`, `tracker/bot_sort.py` — not an independently
  designed tracker, and not DeepSORT. Validate against the original Python implementation's recorded
  outputs on the same test sequences, per root `CLAUDE.md`'s BoT-SORT porting rule.
- **Models are interim, not final.** Stage B: `coralvos_primary` (`research_logs/stage_b/coralvos_primary/`).
  Stage C: NMFS-OSI's published YOLO11n-cls classifier, verified on this project's own leakage-safe
  NOAA split (`research_logs/stage_c/external_noaa_model_eval/`) — not yet Cordova-fine-tuned; that's
  deferred pending field team annotations (`sub-plans/track1-handoff.md`, "Do these first" #1).
- **`assets/models/` here should hold exported model files** (Core ML / whatever the plugin needs),
  exported from the `.pt` weights above — don't retrain here.

## See

- `MASTER_PLAN.md` — build order and current status.
- `sub-plans/` — one file per phase, same pattern as the repo's top-level `sub-plans/`.
