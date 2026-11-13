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
  **Planned exception (decided 2026-11-13):** the CoralscapesV2 SegFormer cover segmenter runs on the
  phone through a native Core ML bridge, because it isn't a YOLO model. This applies to that one model
  only; YOLO models stay on the plugin. It goes ahead only if the iPhone 14 speed test (#11) passes,
  and is built in #12, which also updates this bullet and the Specification. Until then, that model
  runs on a laptop (#7). Don't treat work on #11 or #12 as a violation of this rule.
- **BoT-SORT, no Re-ID.** The Dart tracker is a direct port of `NirAharon/BoT-SORT`'s
  `tracker/kalman_filter.py`, `tracker/matching.py`, `tracker/bot_sort.py` — not an independently
  designed tracker, and not DeepSORT. Validate against the original Python implementation's recorded
  outputs on the same test sequences, per root `CLAUDE.md`'s BoT-SORT porting rule.
- **Models are interim, not final.** Stage B: `coralscapes_v3` since 2026-10-02 (`research_logs/stage_b/coralscapes_v3/`;
  won 24c under ml-01's ship rule, provisional until v4 and the transect check are in; was `coralvos_primary`),
  bundled as `assets/models/stage_b_seg.mlpackage.zip`.
  Stage C: NMFS-OSI's published YOLO11n-cls classifier, verified on this project's own leakage-safe
  NOAA split (`research_logs/stage_c/external_noaa_model_eval/`) — not yet Cordova-fine-tuned; that's
  deferred pending field team annotations (`sub-plans/track1-handoff.md`, "Do these first" #1).
- **`assets/models/` here should hold exported model files** (Core ML / whatever the plugin needs),
  exported from the `.pt` weights above — don't retrain here.

## Current direction: DENR-aligned version

The next version aligns with DENR-BMB Technical Bulletins 2019-04 and 2017-05. Development is tracked
in GitHub issues #1–#19 (`4Chronosx/reefsight-v2`, milestones M1–M5); work them in order.

- **Stations** group 3–5 transects (the existing `sessions` table) and give the reportable summary:
  mean, SD and SE of % cover across transects, hard coral grade A–D, % bleached coral, diversity.
- **Three survey types**, fixed per station: **Photo transect** (official: one still per meter from
  1.2 m with a 1 × 1 m frame; captured with a physical frame, a virtual frame, or imported from
  another camera), **Preliminary** (live video, bulletin-style output stamped PRELIMINARY), and
  **Colony count** (the existing YOLOv8n-seg + BoT-SORT + classifier flow, reported separately).
- **Cover analysis:** 10 seeded random points per frame, labeled by the CoralscapesV2 SegFormer
  (39 classes) and mapped to TB 2017-05 categories through a versioned `category_map` table.
- **Sharing:** organized .zip through the iOS share sheet. In-app Google Drive upload is deferred.
- **Schema v11** (stations, transect frames, frame points, category map, transect cover) is designed in
  `docs/reefsight-v2-blueprint.md`.

## See

- `docs/reefsight-v2-blueprint.md` — diagrams, schema v11 and the station summary rules.
- `docs/denr-tb-2019-04-alignment.md` — the reasoning and decisions behind the DENR-aligned version
  (copy of the project-folder doc; keep the two in step).
- `MASTER_PLAN.md` — build order and current status.
- `sub-plans/` — one file per phase, same pattern as the repo's top-level `sub-plans/`.
