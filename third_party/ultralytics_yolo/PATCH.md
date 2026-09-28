# Local fork: recording support + landscape video-orientation fix

Vendored from `ultralytics_yolo` v0.6.14 (pub.dev), overridden via
`mobile/pubspec.yaml`'s `dependency_overrides`. Adds an
`AVCaptureMovieFileOutput` as a second output on the existing
`AVCaptureSession` (iOS only) so a transect can be recorded to a continuous
file independent of live inference — see
`mobile/sub-plans/03-crop-classify-and-tracking.md` step 1.

Also fixes a bug where `LiveTransectScreen`'s landscape orientation lock
(`SystemChrome.setPreferredOrientations`, decision 7) didn't reach the
native camera: the preview container was correctly landscape-shaped, but
the actual video frames stayed tagged/rotated `.portrait`. Root cause:
`YOLOView.start()` picks the capture session's initial `videoOrientation`
via `currentVideoOrientation()` at `init()` time, before the view is
attached to a window — `window?.windowScene?.interfaceOrientation` is
`nil` then, and `UIDevice.current.orientation` was always `.unknown`
because nothing enabled device-orientation notifications — so it fell back
to `.portrait` and nothing ever re-corrected it afterward.

**Not compiled/run yet in this session** (Windows, no Xcode) — written
against the vendored source, needs a real build to confirm. Android is
untouched/out of scope (project targets iPhone 14 only,
`ReefSight_Specification.md` "Device & platform").

## Files changed vs. upstream v0.6.14

- `ios/ultralytics_yolo/Sources/ultralytics_yolo/VideoCapture.swift`
  - Added `movieOutput` (`AVCaptureMovieFileOutput`) property + `addOutput`
    call in `setUpCamera`.
  - Added `startRecording(to:completion:)` / `stopRecording(completion:)`.
  - Added `AVCaptureFileOutputRecordingDelegate` conformance
    (`fileOutput(_:didFinishRecordingTo:from:error:)`).
- `ios/ultralytics_yolo/Sources/ultralytics_yolo/YOLOView.swift`
  - Added `startRecording(to:completion:)` / `stopRecording(completion:)`
    public passthrough methods, mirroring the existing `setZoomLevel`
    pattern.
  - Landscape video-orientation fix: added `didMoveToWindow()` override
    that re-syncs `videoCapture`'s orientation once the view is actually
    attached to a window; re-syncs it again in `start()`'s setup-completion
    closure (the more reliably-timed of the two, since `setUp`'s
    permission-check + background-queue hop means it runs after the view
    has landed in its window, unlike `didMoveToWindow`, which can fire
    before that); `setUpOrientationChangeNotification()` now also calls
    `UIDevice.current.beginGeneratingDeviceOrientationNotifications()` (paired
    with `endGeneratingDeviceOrientationNotifications()` in `deinit`) so the
    existing `orientationDidChangeNotification` observer actually fires on
    physical rotation instead of being permanently silent.
- `ios/ultralytics_yolo/Sources/ultralytics_yolo/SwiftYOLOPlatformView.swift`
  - Added `"startRecording"` / `"stopRecording"` method-channel cases,
    mirroring the existing `"setZoomLevel"` case.
- `lib/widgets/yolo_controller.dart`
  - Added `YOLOViewController.startRecording(String path)` /
    `.stopRecording()`.
- `lib/yolo_view.dart`
  - Added matching passthrough on the `YOLOView` state class.

## Re-applying after an upstream version bump

The diff is intentionally small and localized to the five files above, each
change mirroring an existing pattern in that same file (`setZoomLevel` /
`setTorchMode`). Diff this fork against the new upstream version and
re-apply the same five blocks; nothing here depends on internals outside
these files.

## Known open items

`stopRecording()`'s Dart future now resolves only once
`AVCaptureFileOutputRecordingDelegate` reports the file finished (not
merely once `stopRecording()` was called) — verify this on-device as part
of sub-plan 3 task 7's recording-isolation test, since it's unverified
Swift.

The landscape video-orientation fix above is also unverified Swift (same
"Not compiled/run yet" caveat at the top of this file) — confirm on-device
that `LiveTransectScreen`'s live preview now shows an upright landscape
feed filling the screen, not a rotated/letterboxed portrait feed.
