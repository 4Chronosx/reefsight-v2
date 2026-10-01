# Sub-plan 16 — Tap a colony, see it in the transect video

Roadmap position: **S1** on the stakeholder track (`sub-plans/model-accuracy-roadmap.md`, "Stakeholder
track").

## Why

Every number in the report rests on detections nobody can check from the report itself. The transect video
is already recorded and already playable from Summary: `VideoPlayerScreen`, from the transect-video work.
Each colony already has `firstSeenAt` and `lastSeenAt`. Linking the two lets three audiences check any colony
in seconds:
- **The field team** can confirm or dispute a detection or a health label. That also feeds the corrections
  layer, which is future work.
- **The academic panel** can spot-check during the defense demo.
- **LGU readers** can see the actual colony behind "bleached".

For the cost, this is the single biggest boost to trust in the app.

## Problem (verified in code, 2026-10-01)
- **The video's start time isn't stored.** `TransectRecorder.start` is called from `_startRecording` only
  *after* `_startSession` has opened the DB and inserted the session row, so video time zero ≠
  `session.startedAt`. The gap is variable, from DB open plus insert. Without the recording start time, a
  colony's wall-clock `firstSeenAt` can't be turned into a position in the video.
- `VideoPlayerScreen(file:, title:)` takes no start position.

## Decisions
1. **Store the recording's own start time** (`video_started_at`, ISO-8601 UTC). Stamp it when
   `TransectRecorder.start` returns successfully. The native recorder may start writing a little after
   that call returns (the forked plugin's `AVCaptureMovieFileOutput`). So:
2. **Seek to 2 s before the colony's first sighting**, which absorbs that start latency and gives context.
   Clamp at 0 and at the video's duration.
3. **The jump target is `firstSeenAt`.** A "best view" (the frame of the most confident sample) would be
   nicer, but it needs per-sample timestamps mapped to the video. The health history has those, so it's a
   possible follow-up, not part of v1.
4. **Older sessions** (no `video_started_at`) fall back to `startedAt` as video zero, with a visible note:
   "position approximate (recorded before video timing was stored)".

## Steps
1. **Schema bump** (nullable `video_started_at` on `transect_sessions`), plus the model field and migration
   test. Set it from `_startRecording` after `_recorder.start` succeeds.
2. **`VideoPlayerScreen` gets an optional `startAt: Duration`.** After `initialize()`, `seekTo(startAt)`,
   then play. Show the colony's track ID and its time window in the title ("Colony #12 · 03:41–03:52").
3. **Summary, technical tab:** each `_ColonyDetailRow` gets a play affordance when the session's video file
   resolves (`resolveTransectVideo`). It opens the player at `firstSeenAt − videoStart − 2 s`. Put the
   offset maths in a pure function (`videoOffsetFor(colony, session)`) so it's unit-tested.
4. **Executive tab:** none. Track IDs and video scrubbing are technical detail (sub-plan 06's audience
   split). Sub-plan 18's photos are the executive-tab evidence instead.

## Tests
- `videoOffsetFor`:
  - normal case
  - pre-roll clamps at 0 for a colony seen in the first 2 s
  - clamps at duration
  - falls back to `startedAt` when `video_started_at` is null, flagging it as approximate
- Summary widget test: the play button appears only when a video exists, and builds the player with the
  right `startAt` (inject a navigator observer or a player-builder seam).

## Done when
- On a device, tapping a colony's play button on Summary opens the transect video within ~2 s before that
  colony first appears.
- Sessions recorded before this change still open, with the "approximate" note.
