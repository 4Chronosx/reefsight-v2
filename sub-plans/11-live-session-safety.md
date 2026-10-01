# Sub-plan 11 — Live session safety: keep the screen awake, never lose a dive's colonies

Roadmap position: **A1** on the app track (`sub-plans/model-accuracy-roadmap.md`, "App track"). This is the
first app item, because both problems can silently ruin a field dive, and both must be fixed before the
controlled-environment test.

## Problem (verified in code, 2026-10-01)

1. **Nothing keeps the screen on during Live.** No code in `lib/` disables the iOS idle timer: there's no
   `wakelock` or `idleTimerDisabled` anywhere. iOS doesn't disable Auto-Lock just because the camera is
   running. If the phone auto-locks mid-transect, the app goes to the background, the capture session is
   interrupted, and both inference and recording stop. Nobody in the water can tap to wake it, because the
   housing is sealed and the diver is busy. `wakelock_plus` is already in `pubspec.lock` as a transitive
   dependency, so using it adds no new package to the build.
2. **Colony records are written only at the end.** `live_transect_screen.dart` `_finalizeSession` is the
   only place that calls `db.upsertColony`. The session row is inserted at the start, but every tracked
   colony lives in memory until End Transect. If the app crashes, iOS kills it, or it's backgrounded for too
   long, the survey keeps its session row (`endedAt` null, shown as "Incomplete") with **zero colonies**.
   The Spec ("Recording & crash resilience") accepts losing an unfinalized *video*. It doesn't accept
   losing the survey data.

## Steps

### 1. Keep the screen awake for exactly the Live session
- Promote `wakelock_plus` to a direct dependency, at the version already resolved in `pubspec.lock`.
- Enable it in `LiveTransectScreen.initState`, and disable it in `dispose` and at the end of `_endTransect`.
  Wrap both calls in the file's fire-and-forget `.catchError(...)`-and-log pattern. A wakelock failure must
  never block the transect.
- Put the calls behind a small injectable `ScreenAwake` interface, with the real implementation using
  `WakelockPlus`, so a test can verify enable and disable are paired.

### 2. Checkpoint colony records during the transect
New `lib/services/session_checkpointer.dart`:
- Every **10 s** while Live is running, upsert a `TrackedColonyRecord` for every track whose state changed
  since the last checkpoint: new track, new health sample, new size, or a later `lastSeenAt`.
- **Records only, no masks.** Mask PNGs are written at finalize, as they are now. A crashed session keeps
  its counts, health and sizes (`size_px` is in the row), with `mask_path` null.
- **Serialize writes.** A checkpoint and `_finalizeSession` must never overlap. Chain both through one
  `Future` queue, so finalize waits for an in-flight checkpoint and nothing starts after finalize.
- **Verify first** that `upsertColony` really upserts on `(session_id, track_id)`. If it inserts, add the
  unique constraint and a migration (schema v4) before relying on repeated writes.
- Snapshot the in-memory maps before awaiting, the same way `_finalizeSession` already does since
  sub-plan 09.

### 3. Checkpoint on interruption
- Observe `AppLifecycleState` in the Live screen. On `inactive` or `paused` (phone call, notification
  centre, low-power kill warning), run a checkpoint **immediately**. It's the last chance before iOS may
  kill the app.
- Record interruptions on the session: a count and the first and last interruption times. The report
  should be able to say "the app was interrupted twice during this transect". This is additive: nullable
  columns in the same schema bump as step 2, if one is needed, otherwise its own.

### 4. Show what was kept
- Summary for an incomplete session: show "Incomplete — the app stopped at HH:MM. N colonies were saved
  up to then." The data comes from the last checkpoint time. Surveys already shows the Incomplete badge
  (sub-plan 06).
- Sessions stay immutable (Spec, Cloud sync). An incomplete session isn't closed or edited later, only
  labelled.

## Rules
- Fire-and-forget never applies to data writes. Checkpoint failures are logged *and* counted on the
  diagnostics overlay ("checkpoint failed ×N"), not swallowed.
- No change to the tracker or classification path. The checkpointer only reads the screen's existing maps.

## Tests
- Wakelock: enable on init, disable on dispose and on end, using a fake `ScreenAwake`.
- Checkpointer, with real SQLite through `sqflite_common_ffi`, following `test/flutter_test_config.dart`:
  - records exist after a checkpoint with no finalize (the simulated crash)
  - finalize after several checkpoints leaves exactly one row per track, with masks
  - a checkpoint requested during finalize doesn't run
  - a lifecycle `paused` triggers a checkpoint
- Summary widget test for the incomplete-session message.

## Done when
- The screen can't auto-lock during Live, verified on a device with Auto-Lock set to 30 s.
- Killing the app mid-transect, by swiping it away on a device, leaves the session's colonies in SQLite,
  and Summary shows them as an incomplete survey.
- Tests pass, and a `docs/` explainer covers what is and isn't recoverable after a crash.
