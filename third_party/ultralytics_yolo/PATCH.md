# Local fork: recording support

Vendored from `ultralytics_yolo` v0.6.14 (pub.dev), overridden via
`mobile/pubspec.yaml`'s `dependency_overrides`. Adds an
`AVCaptureMovieFileOutput` as a second output on the existing
`AVCaptureSession` (iOS only) so a transect can be recorded to a continuous
file independent of live inference — see
`mobile/sub-plans/03-crop-classify-and-tracking.md` step 1.

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

## Known open item

`stopRecording()`'s Dart future now resolves only once
`AVCaptureFileOutputRecordingDelegate` reports the file finished (not
merely once `stopRecording()` was called) — verify this on-device as part
of sub-plan 3 task 7's recording-isolation test, since it's unverified
Swift.
