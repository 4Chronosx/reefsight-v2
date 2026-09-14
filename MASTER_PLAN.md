# ReefSight mobile — master plan

Source of truth: `ReefSight_Specification.md` (Phase C) and `ReefSight_Development_Plan.md` (Tracks 2-3).
This file is a build-order index over those, not a replacement for them — re-read the originals before
any non-trivial architecture decision.

## Where this starts from

- `mobile/` is currently empty. Nothing scaffolded yet.
- An earlier standalone prototype exists at `../reefsight` (sibling directory, separate repo) — full
  Flutter app, but built on an architecture this project's Specification has since superseded: raw
  `tflite_flutter` + hand-written inference/NMS instead of the `ultralytics_yolo` plugin's `YOLOView`,
  and DeepSORT+OSNet Re-ID instead of BoT-SORT without Re-ID. **Its CV/inference/tracking layer is not
  a foundation to build on.** Its UI screens, Provider state pattern, domain data models
  (`ColonyRecord`/`QuadratRecord`/`TransectModel`), transect geofencing, CSV export, and design system
  are largely independent of the CV architecture and worth adapting once there's something real to wire
  them to — not before.
- Models ready now: Stage B `coralvos_primary`, Stage C the verified NMFS-OSI classifier (both interim —
  see `CLAUDE.md`). Cordova fine-tune and the field-annotation-dependent work are deferred, not blocking.

## Build order and why

1. **Scaffold + model integration** (`sub-plans/01-scaffold-and-models.md`) — Track 3 §1-3, §5.
   Foundation: nothing else can be built or tested without a running app that can actually run the two
   models live. Includes crop-and-classify (§5) even though Track 3 lists it later — it only needs the
   two model weights, both already trained and verified (`coralvos_primary` coverage-benchmarked,
   NMFS-OSI classifier at 92.5% on our leakage-safe test split), so there's no reason to gate it on the
   tracker. Verifying the full crop→classify chain this early surfaces real model-integration issues
   sooner rather than later.
2. **BoT-SORT Dart port** (`sub-plans/02-botsort-port.md`) — Track 2 §1-5. Pure Dart algorithm work,
   validated against the reference Python implementation's recorded outputs — can proceed largely in
   parallel with step 1 once step 1's detection output format is known, since the tracker consumes
   detections as plain data, not live camera frames.
3. **Recording isolation + tracking integration** (`sub-plans/03-crop-classify-and-tracking.md`) —
   Track 3 §4, §6-7. Wires steps 1 and 2 together: recording isolation, tracker integration (feeding
   sub-plan 1's boxes and crop-classify output into sub-plan 2's tracker), per-colony health
   aggregation. This is the step that actually needs both prior steps done — crop-classify itself
   moved to step 1.
4. **Storage + transect metrics** (`sub-plans/04-storage-and-metrics.md`) — Track 3 §8-10. SQLite
   persistence and the post-transect analysis (density, size-frequency, bleaching prevalence) that
   only make sense once tracked, health-labeled colonies exist to compute them from.
5. **UI, reporting, and v1 salvage** (`sub-plans/05-ui-and-reporting.md`) — Track 3 §11-12, plus where
   v1's screens/widgets/geofencing/export get adapted in. Deliberately last: UI can be built against
   the real data models from step 4 instead of guessing at their shape, and this is where most of v1's
   genuinely reusable work actually plugs in.

## Explicitly out of scope for now

- Cordova-specific classifier fine-tuning (blocked on field annotations, deferred to "next week" per
  the working session that made this call — revisit `sub-plans/track1-handoff.md` "Do these first" #1
  before treating it as unblocked).
- Camera motion compensation (`opencv_dart`) — Dev Plan Track 2 §5 explicitly sequences this *after*
  the base tracker works, not alongside it.
- Hobologger ingestion (Track 3 §12) — last item in Track 3 for a reason; nothing upstream depends on it.
