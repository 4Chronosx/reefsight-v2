# Sub-plan 10 — Classifier input that matches its training data, and an "uncertain" outcome

Roadmap position: **3a** (`sub-plans/model-accuracy-roadmap.md`). It depends on sub-plan 09's
classification scheduler. ML sub-plan 2 (`sub-plans/ml-02-classifier-pipeline-crops.md`) trains on
crops cut to the spec defined here, so **the crop spec below is a contract** that the Python harvest
code must reproduce exactly.

## Problem (verified 2026-09-29)

- The shipped classifier (NMFS-OSI yolo11n-cls) was trained on **224×224 patches around annotation
  points in top-down Hawaiian photoquadrats** (`datasets/corals_bleaching/README.md`). Those are
  texture close-ups of coral surface.
- `bleaching_classifier.dart:27-34` crops the **whole detection box** (often several colonies plus
  sand) and resizes it with `copyResize(width: 224, height: 224)`, **stretching non-square boxes**.
- Every detection gets a forced `CORAL`/`CORAL_BL` label. The classifier has no "not coral" output,
  so false-positive detections (sand, rubble, clams) feed straight into bleaching prevalence. Pale
  substrate plausibly leans toward `CORAL_BL`.

## Crop spec v1 (the contract)

Input: the frame, the detection box (pixels) and the detection's mask.
1. **Binarise the mask** at 0.5.
2. **Anchor point:** the mask pixel furthest from the mask boundary (distance-transform maximum),
   mapped to frame pixels. This is the point deepest inside the colony.
3. **Side length:** `s = min(box.width, box.height)`, clamped to `[64, min(frameW, frameH)]` px.
4. **Square window** of side `s` centred on the anchor, shifted (not shrunk) to stay inside the frame.
5. **Coverage** = fraction of the window's pixels that are mask foreground. If coverage < **0.6**,
   don't classify this sample. It counts as `insufficient view`, not as a classification.
6. **Resize** the window to 224×224 **uniformly** (it's square, so nothing stretches). Use bilinear
   interpolation and JPEG quality 95.

Name it `CropStyle.insideMaskSquare`. Keep two more styles selectable behind a debug setting, for
ML sub-plan 2's comparison and for debugging:
- `boxStretch`: today's behavior, kept for before/after comparison
- `boxSquarePad`: the box padded to a square with the frame's own pixels, then resized

ML sub-plan 2 step 3 measures which style the classifier does best on. If `insideMaskSquare` loses,
switch the default and bump the spec to v2 in this file. Don't edit v1 in place.

## Steps

### 0. Verify the mask's coordinate space (blocking)
`colony_size.dart` documents that `YOLOResult.mask`'s grid-to-box relationship is **unverified**. The
masks are built inside the precompiled YOLO core package, not the vendored fork
(`third_party/ultralytics_yolo/ios/.../YOLOView.swift:1908-1917` only forwards
`result.masks.masks[i]`), so this can't be settled by reading source. On-device, log for a few
detections: the mask grid's rows×cols, the box size, and the frame size. Then decide whether the grid
is (a) box-local, (b) full-frame, or (c) model-input (640-letterboxed) space. Write the answer into
`colony_size.dart`'s doc comment as well. **Size estimates depend on this too.** If the answer isn't
(a), `maskAreaPixels` is currently wrong.

### 1. Implement the crop spec
- In `crop_geometry.dart`, add the anchor, window and coverage computation as a **pure function**
  (mask + box + frame size → window + coverage) with unit tests: a colony at the frame edge, a
  thin/elongated mask, an empty mask, and a mask smaller than the 64 px floor.
- Compute the distance transform on the mask grid itself, which is small. A two-pass chamfer distance
  in pure Dart is enough, and `opencv_dart`'s `distanceTransform` is an option if `imgproc` is
  already compiled in (see the `pubspec.yaml` note).
- `BleachingClassifier` takes a `CropStyle` (default `insideMaskSquare`).

### 2. Gating before classification
The scheduler (sub-plan 09) only classifies a track sample if:
- the detection's confidence ≥ `classifySegFloor`. Start from sub-plan 08 step 3's score histogram,
  or use 0.4 as a placeholder until it exists.
- crop coverage ≥ 0.6

### 3. An "uncertain" outcome
- A classification with top-1 confidence < `classifyConfFloor` (start at **0.7**; binary top-1 is
  always ≥ 0.5) is recorded in the health history with `uncertain: true` and **not** fed to
  `HealthAggregator`.
- A track's health label is `null` (shown as **Uncertain**) until it has at least `minConfidentSamples`
  (start at 2) confident samples.
- `transect_metrics.dart`'s `bleachingPrevalence` already excludes `healthLabel == null` from both
  numerator and denominator (verified, lines 71-83), so prevalence is automatically computed over
  confidently classified colonies only.
- The summary shows **"N colonies · M classified · K uncertain"** so the denominator is visible, not
  hidden. Check `health_chip.dart` and `summary_screen.dart` render the null label as "Uncertain",
  not as a blank or a default colour.
- Adding `uncertain` to the health history JSON is additive. Check that the sub-plan 07 cloud-sync
  record schema tolerates the extra field, or add it.

### 4. Tests
- Crop geometry unit tests (step 1).
- Aggregator/scheduler tests: low-confidence samples don't move the label; the label stays null
  below `minConfidentSamples`.
- Widget test: the summary with a mix of classified and uncertain colonies shows the right three
  numbers.

## Done when
- The mask coordinate space is verified and documented (and `maskAreaPixels` fixed if needed).
- The live app crops with `insideMaskSquare` by default, skips low-coverage and low-confidence
  samples, and shows uncertain colonies explicitly.
- Tests pass. The crop spec in this file is the one ML sub-plan 2 implements in Python.

## Status (2026-10-01)

Steps 1–4 are implemented. All 216 tests pass and `flutter analyze` is clean. **Step 0 (on-device)
is still open**, so the first "Done when" bullet isn't met yet.

### Python parity for crop spec v1 (ML sub-plan 2 must match these)
- **Mask threshold** is `>= 0.5`, assuming 0–1 values. Step 0's log prints the actual value range.
- **Distance transform** is a two-pass 3-4 chamfer **in mask-grid cells**, not pixels. Cells
  outside the grid count as background. On a non-square box the grid's cells aren't square in
  pixels, and that's accepted for v1.
- **Tie-break** goes to the maximum-distance cell nearest the foreground centroid in grid units. If
  that's still tied, it's the first in row-major order.
- **Anchor pixel** is the centre of the anchor cell's rect, under the box-local assumption.
- **Side** is `round(min(box w, h))`, clamped to `[min(64, shorter frame edge), shorter frame
  edge]`.
- **Window left/top** is `round(anchor − side/2)`, then clamped to `[0, frame − side]`. Dart's
  `round()` rounds half away from zero, while Python's `round()` rounds half to even. Use
  `math.floor(x + 0.5)` for non-negative values in Python.
- **Coverage** is computed exactly: the area of each foreground cell rect that overlaps the window,
  divided by side².
- **Resize** to 224×224 is bilinear (`img.Interpolation.linear`), and the JPEG is quality 95.

### Where it lives
- Crop spec v1: `lib/services/crop_geometry.dart`, in `CropStyle`, `deepestMaskCell` and
  `computeClassifierCrop`.
  - The anchor uses a two-pass 3-4 chamfer distance on the mask grid. Cells outside the grid count
    as background.
  - **Ties** (for example a uniform-thickness strip) go to the tied cell nearest the mask centroid.
    Without that, the scan order would pick one end. The Python implementation in ML sub-plan 2
    must apply the same tie-break.
  - Window pixels are integers. `round()` is applied to the centred left/top, and the window is then
    shifted into the frame. Coverage is computed exactly, as the area of each mask cell's rect that
    overlaps the window.
- Thresholds: `lib/services/classification_policy.dart` (`classifySegFloor` 0.4, `minCoverage` 0.6,
  `classifyConfFloor` 0.7, `minConfidentSamples` 2).
- Gating: `LiveFrameProcessor._candidates`.
  - A candidate must be confirmed, have score ≥ 0.4, and be due. The crop is then cut.
  - Insufficient view (no mask, or coverage < 0.6) isn't stamped as an attempt, so the track stays
    due, but the same track isn't re-cropped for 250 ms (`insufficientViewRetry`). The overlay's
    `skip N` therefore counts samples, not 8 Hz events. The count also depends on the scheduler
    being free, since frames with a batch in flight aren't evaluated at all.
- CSV export writes a `null` label as `UNCERTAIN`. The Summary's Healthy/Bleached bars divide by
  classified colonies, matching the prevalence sentence.
- Not done from review: persisting the crop style per session. It's a debug setting, and it's
  logged in the debug "live loop" line. Also not done: gating score at 0.6 instead of 0.4. BoT-SORT
  second-pass matches at 0.4–0.6 do get classified. Revisit with sub-plan 08's score histogram.
  - The coverage gate applies only to `insideMaskSquare`. The box styles report coverage 1.0.
- Uncertain:
  - `HealthAggregator` ignores below-floor samples and returns `null` until it has 2 confident ones.
  - `HealthHistoryRecorder` keeps every sample and flags low ones `uncertain`. The flag is written
    to the `health_history` JSON. Rows written before this have no key and read as `false`.
  - Summary shows "N colonies · M classified · K uncertain". `HealthChip` shows `null` as
    "Uncertain".
- Debug: Settings → Diagnostics → "Classifier crop" picks the style. It's read once per transect.

### Step 0: how to run it
In a debug build, turn on "Show diagnostics on Live" and start a transect with colonies in view.
The log prints `ReefSight: mask geometry (sub-plan 10 step 0): mask R x C, box W x H at (x, y),
frame FW x FH` for the first 10 masked detections. Read it as follows:
- **R×C tracks the box's aspect and size** (it differs per detection): the grid is box-local. The
  current code is right, and only the doc comments need updating.
- **R×C is the same for every detection and matches the frame's aspect**: it's full-frame. Change
  `_maskCellRect` in `crop_geometry.dart` and `maskAreaPixels` in `colony_size.dart` to index the
  frame instead of the box.
- **R×C is 160×160 or 640×640 regardless of the frame**: it's model-input (letterboxed). Map
  through the letterbox in those same two places.

Record the answer here and in `colony_size.dart`'s doc comment, then remove `_logMaskGeometry` from
`live_transect_screen.dart`.

### Cloud sync (sub-plan 07)
07 isn't implemented yet. Its `colonies.health_history_json` will carry the new optional
`uncertain` field as-is, since it's the same JSON text.
