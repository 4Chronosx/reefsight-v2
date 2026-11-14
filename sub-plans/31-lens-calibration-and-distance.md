# Sub-plan 31: Underwater lens calibration and distance measurement (issue #14)

Roadmap position: **M4**, the first step of the virtual frame; #15 (virtual square and auto-capture) builds on it.
It follows `docs/denr-tb-2019-04-alignment.md` §6, build order steps 2–3. Reasoning and verification:
`../docs/underwater-lens-calibration-and-distance.md`. Pool checklist: `../docs/underwater-lens-calibration-protocol.md`.

## Starting point

- Stills always came from `back.first`, the main lens. There was no way to choose the ultra-wide.
- No lens model: the frame's area was known only from the physical frame's corners (#5).
- Schema v11 already had `transect_frames.distance_m`, `distance_method` and `checks_passed`. **No migration.**

## Decisions (approved with the plan, 2026-11-15)

| # | Decision |
|---|---|
| D1 | Tolerance **±10 cm over 1.0–1.4 m**; every pool shot in range must pass (`kDistanceToleranceM`, `summarizeDistanceAccuracy`). |
| D2 | **Checkerboard** for the fit; the 1 m square is the held-out check. |
| D3 | Tools built **before** the pool test; the geometry doesn't depend on the method chosen. |
| D4 | Lasers optional for the first pool session. |

## What was built

- `lib/services/lens_calibration.dart`:
  - `CameraLens` (main / ultra-wide), `CalibrationMedium`;
  - `LensIntrinsics`: OpenCV pinhole + 5-term distortion, `projectNormalized`, and `undistortPixel` (Newton, kept
    to the polynomial's rising branch);
  - `LensCalibration.parse`: refuses the whole file on any bad field.
- `lib/services/scale_estimation.dart`:
  - `distanceFromDotPair` (Z = B / undistorted gap), `cmPerPxAt`, `footprintAt`;
  - `squareCornersAt` and `projectSquareEdge` (for #15);
  - D1's `withinDistanceTolerance` and `summarizeDistanceAccuracy`.
- `lib/services/laser_dot_detector.dart`: green-halo mask, with bright cores counted only next to a halo; blobs
  and `pickDotPair` (ambiguous flag); never throws.
- `lib/services/still_camera.dart`: `pickBackCamera` and `PluginStillCameraOpener(lens:)`. The default is still
  the main lens, so photo capture (#4) is unchanged.
- `lib/services/calibration_capture.dart`:
  - capture sets (`manifest.json` and `shot_NNN.jpg`, atomic writes, safe file names, zip);
  - `LensCalibrationFile` (import with validation and a size cap; a bad import keeps the old calibration).
- `lib/screens/lens_calibration_screen.dart` (Settings → Diagnostics → **Lens calibration**):
  - lens, medium and target selectors; tape distance and laser spacing; live tilt;
  - corner marking after square shots (`square_corner_marker_screen.dart`);
  - a laser distance readout against the tape (±10 cm); load calibration; share set.
- `machine-learning-pipeline/notebooks/31_underwater_lens_calibration.ipynb` (written, **not run**):
  - fits each lens and medium, the housing ratio, the square and laser distance checks with the phone-vs-notebook
    dot cross-check, a bias report, footprint, the ARKit verdict;
  - writes `research_logs/lens_calibration/<RUN_ID>/` (`log.txt`, `lens_calibration.json`, `accuracy.csv`,
    `results.json`) and `latest_run.txt`.

## Tests

- New: `lens_calibration_test` (21), `scale_estimation_test` (13), `laser_dot_detector_test` (9),
  `still_camera_test` (4), `calibration_capture_test` (11), `lens_calibration_screen_test` (9).
- Full suite: 1170 passing; `flutter analyze` clean (2026-11-15).

## Not done / next

1. **Pool session** per the protocol, then run notebook 31, AirDrop `lens_calibration.json` to the phone and load it.
2. Check on the device that the ultra-wide opens and that the phone's and the notebook's dot positions agree
   (orientation).
3. **Done when** for #14: notebook 31's laser summary passes D1. Then choose the method (lasers expected). An
   ARKit or tape path would need its own plan.
4. #15: draw the square with `projectSquareEdge`, gate on tilt, distance and steadiness, and save the distance
   fields.
