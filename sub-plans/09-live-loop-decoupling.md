# Sub-plan 9 — Live loop: update the tracker every frame, classify off the critical path

Roadmap position: **1a** (`sub-plans/model-accuracy-roadmap.md`). It must land before sub-plan 08's
threshold tuning, because 08 assumes the tracker sees 8 updates per second.

## Problem (verified in code, 2026-09-29)

`live_transect_screen.dart` `_handleStreamingData` (lines 379-475):
1. **Frames are dropped while classification runs.** `if (_isProcessing) return;` (line 385) throws
   away every streaming event that arrives during processing.
2. **Classification is sequential and repeats the frame decode.** Each detection runs
   `await _classifier.classifyCrop(...)` in turn (lines 415-437). Each call decodes the *full* frame
   JPEG on an isolate, crops, re-encodes, then runs native predict. A frame with N detections means N
   full-frame decodes before the tracker sees it.
3. **Empty frames never reach the tracker.** Lines 391-397 and 410 return before `_tracker.update` when
   there are no detections. Lost tracks don't age, the Kalman filter doesn't predict forward, and
   `trackBuffer` stops meaning a fixed amount of time.

Consequence (a hypothesis until step 1 measures it): the tracker gets sparse, irregular updates. On a
moving diver the same colony moves too far between updates to pass the IoU match, so it gets a new ID
and is **double-counted**. Every colony is also reclassified on every processed frame, which wastes
most of the classifier budget on colonies already classified many times.

## Steps

### 1. Measure first
Add debug-only instrumentation (behind a `kDebugMode` or settings flag, off in release):
- timestamps of every streaming event received
- timestamps of every `_tracker.update` call
- number of detections per frame
- time spent in classification per processed frame

Log a rolling summary: events/s, tracker updates/s, and the distribution of gaps between updates.
Run it once on-device (tank, pool, or pointed at a printed reef photo) to get the **before** numbers.
If on-device isn't possible yet, get the same numbers from a widget test with a fake classifier that
has realistic latency (~30-60 ms).

### 2. Update the tracker on every streaming event
- Every event calls `_tracker.update(detections)` synchronously, **including an empty list**, before
  any classification work.
- Add a unit test: `update([])` on a tracker with live tracks moves them to lost, and after
  `trackBuffer` empty updates they're removed. This must match the Python reference's behavior on
  empty frames. Add a parity fixture if the reference's output for an empty-frame sequence can be
  generated with `tracking-validation/notebooks/generate_reference_fixtures.ipynb`.
- Keep `_DetectionPayload` carrying the mask as it does now. Health **no longer rides on the
  detection payload**; it's keyed by track ID (step 3).

### 3. A classification scheduler, keyed by track ID
New `lib/services/classification_scheduler.dart`:
- After each tracker update, choose which **confirmed, currently-tracked** tracks are *due* for
  classification. A track is due if it has never been classified, or if at least `reclassifyEvery`
  (start with 1.0 s, expressed in seconds, not updates) has passed since its last classification.
- Cap work per frame at `maxPerFrame` (start with 3), prioritising tracks never classified before and
  then the tracks waiting longest.
- **At most one classification batch in flight at a time.** If a batch is still running when the next
  frame arrives, the tracker still updates. The scheduler just doesn't start another batch, and
  nothing waits on it.
- **Decode each frame once per batch.** Change `BleachingClassifier` to take one frame and a list of
  regions, then decode, crop and resize all of them in a single `compute` call, and predict each crop.
- When results come back, pass them to `_healthAggregator.record(trackId, ...)` and
  `_healthHistoryRecorder.record(...)` for **that track ID**. Drop results for tracks that have since
  been removed.
- Leave the crop geometry as it is today. Sub-plan 10 replaces the crop; this sub-plan only changes
  *when* and *how often* crops are classified.

### 4. Measure again
Repeat step 1's measurement and record both sets of numbers in this file, below.
**Target:** tracker updates/s ≈ streaming events/s (≈ `inferenceFrequency`), with no gaps longer
than ~2× the nominal interval, apart from real stalls in the native stream.

## Rules
- `BoTSortTracker` itself is not changed. Parity fixtures must keep passing.
- The Spec's per-colony health rule ("confidence-weighted average across all frames a colony is
  tracked in") becomes "…across all classified samples of that colony". Note that wording change in
  the Spec's "Per-colony decisions" section once this lands.

## Done when
- The tracker is updated on every streaming event, including empty ones, with a test proving
  empty-frame aging.
- Classification runs through the scheduler, never blocks the tracker, and decodes each frame once
  per batch.
- Before/after update-rate numbers are recorded below. Sub-plan 08 can then use the measured rate as
  its real `trackBuffer` conversion factor.

## Measurements

### Simulated (2026-10-01)
`test/services/live_frame_processor_test.dart`, group "simulated 8 Hz stream": a perfect 8 Hz event
stream for 10 s, 3 colonies in frame drifting slowly, fake classifier at 60 ms per crop, run
through the same `LiveFrameProcessor` the app uses, in legacy and decoupled mode. It isolates what
the *loop* does to the update rate. The native stream has no stalls here, so this is a lower bound
on the real-world gaps.

| Loop | events/s | tracker updates/s | gap p50 / p95 / max | classifications/s | mean batch |
|---|---|---|---|---|---|
| Before (legacy) | 8.0 | **4.0** | 250 / 250 / 250 ms | 12.0 | 58 ms (1 crop) |
| After (decoupled) | 8.0 | **8.0** | 125 / 125 / 125 ms | 3.0 | 175 ms (≤3 crops) |

With 3 colonies, the legacy loop spends 180 ms classifying each processed frame, so every other
event is dropped and the tracker runs at half the stream rate. It also reclassifies every colony
on every processed frame: 12 crops/s, 4× the decoupled loop's 3/s (≈1 per colony per second). The
gap grows with colony count (N × crop latency), so a busier reef would be worse.

### On-device (pending)
Run Live with Settings → Diagnostics → "Show diagnostics on Live" on, once with "Legacy live loop
(baseline)" on and once off, pointed at the same scene. Read the loop line on the overlay, or the
`ReefSight: live loop (legacy|decoupled): …` debug log (every 5 s in debug builds). Record both
here, then delete the legacy path (`LiveFrameProcessor._handleLegacy`,
`AppSettings.legacyLiveLoop`, and its Settings switch).

| Loop | events/s | tracker updates/s | gap p50 / p95 / max | classifications/s | mean batch |
|---|---|---|---|---|---|
| Before (legacy) | | | | | |
| After (decoupled) | | | | | |

Sub-plan 08 should use the on-device **after** updates/s as its `trackBuffer` frames→seconds factor.

## Implementation notes (2026-10-01)
- `lib/services/live_frame_processor.dart`: the per-event logic, pulled out of the screen so it is
  testable without the native view. `lib/services/classification_scheduler.dart`: step 3.
  `lib/services/live_loop_metrics.dart`: steps 1/4.
- **Decided: late results are kept.** A classification result for a track that was lost or removed
  while its batch ran is still recorded under that track id, because finalize persists every track
  ever seen and the sample is real evidence about that colony. Results are dropped only after the
  session is finalized (screen) or the processor is closed (dispose). This differs from step 3's
  "drop results for tracks that have since been removed".
- **Empty-frame aging test:** it already existed at tracker level
  (`test/tracking/bot_sort_tracker_test.dart`, "a track is removed after being missed for
  track_buffer frames"). The new test proves the *loop* now feeds empty frames to the tracker
  (`live_frame_processor_test.dart`, "an event with no detections still advances the tracker"). No
  Python parity fixture was added for empty-frame sequences. That would need a notebook run, and
  the tracker code is unchanged.
- Fixed along the way: `_finalizeSession` iterated `_firstSeenAt.keys` across awaits while
  streaming events could still add ids. It now closes the frame processor first (freezing the loop)
  and iterates a snapshot.
- The legacy/decoupled choice is read once when Live opens and is fixed for that transect.
  Switching mid-session could let a stale legacy update rewind the tracker. So toggle it in
  Settings *between* the two measurement transects.
- Review follow-ups not done (low impact, noted for later): the scheduler and metrics use the wall
  clock (`DateTime.now`), so a backward clock step stalls scheduling until it catches up. A
  monotonic `Stopwatch` clock would fix it. `_lastAttemptAt` is never pruned, at one entry per
  track id, so it's tiny. One failing crop inside the isolate loses the whole batch (all nulls,
  retried 1 s later).
