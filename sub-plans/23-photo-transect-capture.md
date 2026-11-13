# Sub-plan 23 — Photo transect capture with level indicator (issue #4)

Roadmap position: **M1**, fourth issue of the DENR-aligned version (`4Chronosx/reefsight-v2` #4),
built on the station screens (`21-station-screens.md`). It carries out `docs/denr-tb-2019-04-alignment.md`
§1b (TB 2017-05: one still per meter, 1 × 1 m frame, at least 5 MP) and §6 build order step 1 (the
level indicator). The reasoning is written up in `../docs/photo-transect-capture-and-tilt.md`.

## Starting point

- #2 already inserted the photo-transect session in Setup and handed it to an injected `OpenCapture`,
  which pointed at `CapturePlaceholderScreen`.
- Schema v11's `transect_frames` already had every column this needed (`meter_mark`, `tilt_deg`,
  `width_px`/`height_px`, `excluded`/`exclude_reason`, `UNIQUE (session_id, meter_mark)`).
- The `camera` plugin was already in pubspec but unused (Live uses `YOLOView`'s own session).
- There was no motion-sensor package.

## What was built

- **Level indicator** (`lib/services/tilt.dart`, new dependency `sensors_plus ^7.1.1`):
  - `tiltFromVerticalDeg(x, y, z) = acos(|z| / |g|)`.
  - `TiltFilter`, an EMA (α 0.2) on the gravity vector.
  - `tiltLevelOf`: at most 5° is level, at most 10° near, otherwise off (`kLevelToleranceDeg`,
    `kNearToleranceDeg`).
  - `TiltSource` / `SensorsPlusTiltSource`.
- **Storage** (`lib/services/photo_transect_store.dart`):
  - `PhotoTransectStore` moves the camera's temp JPEG to
    `transect_photos/session<id>_m<NN>_<epoch ms>.jpg`, staged as `.tmp` and then renamed. The path
    is stored relative.
  - `jpegPixelSize` reads the SOF header, so the 12 MP image is never fully decoded.
  - `session_files.dart` now sweeps `transect_photos/` on survey delete.
- **Data layer:**
  - `TransectDatabase.replaceFrameAtMeter`, in one transaction: delete the old row, its points and
    the transect's cached cover, then insert the new row. It returns the replaced frame so its file
    can be deleted after the commit.
  - `TransectFrame.missingMeter` and `isMissing`, with `kMissingMeterReason = 'missing'`.
- **Capture state** (`lib/services/photo_transect_capture.dart`):
  - `PhotoTransectCapture` (a `ChangeNotifier`) tracks meters 0 to `floor(tape)`, each pending,
    captured or missing.
  - After each shot it moves to the next pending meter, wrapping round.
  - Supports retake, mark missing, finish (`closeSession`), and resume through `load()`.
  - Has a busy guard.
  - The new file is deleted only if the DB write fails before its commit.
- **Camera** (`lib/services/still_camera.dart`): `StillCamera` / `PluginStillCameraOpener`. Back
  camera, `ResolutionPreset.max`, JPEG, flash off, no audio, capture orientation locked to portrait.
- **Screen** (`lib/screens/photo_transect_capture_screen.dart`):
  - Black, housing-friendly layout: 48 pt meter counter, tilt box, 104 dp shutter (amber "retake"
    when the meter has a photo), 72 dp previous/next, 64 dp Mark missing and Review.
  - Wakelock while open.
  - The camera is released in the background and reopened on resume.
  - A camera error shows "Try again".
  - Review is a grid of every meter (thumbnail, tilt in its level colour, Missing, Under 5 MP).
    Tapping a tile goes back to that meter to retake it. Finish asks first if meters are left.
- **Routing:**
  - `buildCaptureScreen(start)` sends a photo-transect station with a physical or virtual frame to
    capture. Imported (#5) and preliminary (#13) stay on the placeholder.
  - Setup's default `OpenCapture` is now `pushCapture`.
  - Station detail reopens through `buildCapture` (injectable), so tapping a transect resumes
    capture or review.
- **Info.plist:** the camera usage string now mentions photo-transect stills.

## Decisions

1. **A missing meter is an excluded row with no image**, not "no row" and not a schema v12 column.
   See the explainer for why.
2. **Tilt is advisory in Physical mode** and never blocks the shutter. Virtual mode (#14–15) will
   gate on it.
3. **Virtual-frame stations use this screen for now**, with tilt shown and no distance checks.
4. **Retake deletes the old frame's points and the transect's cached cover.** Both were worked out
   from the old image. A first capture leaves the cover alone.
5. **Finish sets `ended_at` but doesn't lock the transect.** Reopening still allows retakes.
6. **The `camera` plugin, not `YOLOView`**, because full-resolution stills are needed and no
   segmentation runs during capture.

## Review fixes

A `flutter-reviewer` pass on 2026-11-14 found no HIGH defects. It confirmed the tilt axis, the SOF
offsets, the retake ordering, and that the `session1_` sweep can't match `session10_`. Fixed:

- **MED, back while saving.** Leaving mid-shot closed the DB under the write and lost the shot.
  `PopScope(canPop: !busy)` now blocks it.
- **MED, orientation.** Pointing down, the phone reports face-up, so stills could come out rotated
  by however the diver last held it. Fix: `lockCaptureOrientation(portraitUp)`.
- **MED, mark missing over a photo.** One stray tap deleted the photo. It now asks first ("Keep
  photo" / "Mark missing").
- **LOW, lifecycle:**
  - The camera is released on `paused`/`hidden` only, not `inactive` (a banner or Control Center).
  - The release is deferred while a shot is saving.
  - Reopening awaits the old controller's dispose.
  - A camera that finishes opening after the app was backgrounded is dropped.
- **LOW, stale cover.** A retake now clears the transect's cached cover in the same transaction.
- **LOW, the catch was too wide.** File clean-up now covers only the DB write, never the steps
  after the commit.
- **LOW, stale tilt.** A sensor error clears the reading, so the next shot saves no tilt rather
  than an old one.

Not changed: whether iOS `ResolutionPreset.max` gives 4:3 12 MP or 16:9 about 8 MP. It still meets
the 5 MP minimum either way, and `width_px`/`height_px` will show it on the device.

## Verification

- `flutter test`: **744 passed**. `flutter analyze`: **no issues** (2026-11-14).
- New suites:
  - `tilt_test.dart` (12);
  - `photo_transect_frames_test.dart` (20, including the cover tests);
  - `photo_transect_capture_test.dart` (13);
  - `photo_transect_capture_screen_test.dart` (8, including the confirm and sensor-error tests).
- `station_screens_test.dart` gains a `buildCaptureScreen` routing test, and its #2 end-to-end test
  now opens the capture screen (fake camera) for each of T1–T3.
- **Still to check on the iPhone 14:**
  - Still size and aspect (Review shows "Under 5 MP" if low).
  - Tilt reads about 0° flat and about 90° upright.
  - A full 51-meter run, including an app kill partway through and resume.
  - The camera reopens after switching apps.
  - Taps work through the DIVEVOLK housing.

## Next

#5, photo import (an imported-mixed frame mode station still lands on the placeholder).
