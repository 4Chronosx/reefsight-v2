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
_(fill in: before / after — events/s, updates/s, gap p50/p95, classifications/s)_
