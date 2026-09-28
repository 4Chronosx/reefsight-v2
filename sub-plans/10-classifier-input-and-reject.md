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
