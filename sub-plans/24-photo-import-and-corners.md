# Sub-plan 24 — Photo import and frame corner editor (issue #5)

Roadmap position: **M1**, the fifth issue of the DENR-aligned version (`4Chronosx/reefsight-v2` #5).
It is built on the station screens (`21-station-screens.md`) and on photo capture
(`23-photo-transect-capture.md`). It carries out §9 of `docs/denr-tb-2019-04-alignment.md`
(importing photos). The reasoning is written up in
`../docs/photo-import-ordering-and-frame-corners.md`.

## Starting point

- A photo-transect station with frame mode `imported_mixed` already got
  `CaptureSource.importedPhotos` in Setup, but `buildCaptureScreen` sent it to the placeholder.
- Schema v11's `transect_frames` already had every column needed: `source imported`,
  `camera_make/model`, `captured_at`, `corners_json`, `corner_source`, `fisheye_flag` and
  `exclude_reason`. **There is no schema change.**
- There was no picker package and no EXIF reader. `package:image` 4.10 has `decodeJpgExif`.

## What was built

- **Metadata** (`lib/services/photo_metadata.dart`):
  - `parseJpegMetadata` reads the SOF size and the EXIF make, model, `DateTimeOriginal` and
    `OffsetTimeOriginal`, orientation and 35 mm focal length.
  - Width and height are swapped for orientations 5–8, so they match the photo as displayed.
  - `DartJpegMetadataReader` reads only the first 512 KB.
  - `NativePhotoMetadataReader` handles HEIC and anything else, through a new `photoMetadata`
    method on the `reefsight/device` channel (ImageIO, in `AppDelegate.swift`).
  - `RoutingMetadataReader` picks a reader by magic bytes. A failure gives empty metadata; it
    never throws.
- **Order and checks** (`photo_import_order.dart`, `photo_import_checks.dart`):
  - `sortForImport` sorts by EXIF time when every photo has one, otherwise all by filename.
  - `naturalCompare` sorts filenames the way a person expects (`IMG_9` before `IMG_10`).
  - The checks: `kMinPixels` (now also used by #4's Review), `isUnder5Mp`, `isSizeUnknown`,
    `expectedFrameCount` (`floor(tape) + 1`), `frameCountFarOff` (±3), `cameraCount`,
    `isActionCamera` and `suspectFisheye`.
- **Storage:** `PhotoTransectStore.importCopy` **copies** (never moves) a photo to
  `transect_photos/session<id>_imp<NNN>_<ms>.<ext>`, staged as `.tmp` and then renamed.
- **Data layer** (`transect_database.dart`):
  - `saveImportedFrames` writes the whole ordered set in one transaction. Kept rows (and their
    points) are moved to new meters, parked at `-id` first to avoid the unique-constraint clash.
    New rows are inserted. Unlisted rows are deleted with their points and returned, so their
    files can be deleted after the commit. The cover is cleared only on a real change.
  - `updateFrameCorners` and `setFrameExcluded` are now transactional, clear stale points and
    cover, and throw on an unknown id.
  - `TransectFrame.missingMeter(source:)` lets an imported gap stay `imported`.
  - `kNoFrameReason = 'no_frame'`.
- **Controller** (`photo_import.dart`): `PhotoImport` (a `ChangeNotifier`) holds a draft of
  `PhotoSlot` / `GapSlot` entries, where position is the meter mark. It covers:
  - `addPhotos`: copy and read one at a time, with progress; a failed copy is skipped and named;
  - `move`, `insertGap`, `drop` and `setLensMode`;
  - `save`, `discard` (deletes copies that were never saved) and `load` (fills missing meters
    with gaps);
  - a busy guard.
- **Pickers** (`photo_source.dart`, new dependencies `image_picker ^1.2.3` and
  `file_picker ^11.0.3`): Photos uses `pickMultiImage(requestFullMetadata: true)`. Files uses
  `FilePicker.pickFiles(type: custom, …)`, because `FileType.image` opens Photos on iOS.
- **Import screen** (`photo_import_screen.dart`):
  - From Photos and From Files buttons, and progress while copying.
  - A reorderable list of thumbnails showing meter, name, time, camera and flags. The checks and
    the GoPro lens question scroll with the list.
  - Each item's menu has Insert gap and Remove.
  - Save order stays disabled while photos run past the tape end. A count of photos still without
    corners is shown.
  - Leaving with unsaved changes asks before discarding.
- **Corner editor** (`frame_corner_editor_screen.dart` and `frame_corners.dart`):
  - Four 56 dp handles sit on a photo inset by half a handle, so a corner at the edge keeps its
    full touch target.
  - Previous, Copy previous, No frame visible, Save corners, Next.
  - After each save it moves on to the next photo still without corners.
  - Corners are put in image order and must be convex and at least 1 % of the photo.
- **Routing:** `buildCaptureScreen` sends `importedMixed` stations to `PhotoImportScreen`. The #4
  Review screen gains a **Corners** action, so in-app stills get corners too.
- **Info.plist:** an `NSPhotoLibraryUsageDescription` string.

## Decisions

1. **HEIC goes through native ImageIO** and JPEG through Dart (answer to plan question 1). The Dart
   path covers GoPros and is testable on Windows.
2. **Fisheye:** every GoPro is suspected unless the diver answers Linear, once per import. Other
   cameras are flagged only at a 35 mm-equivalent focal length of 12 mm or less (plan question 2).
3. **Import is for `importedMixed` stations; the corner editor is shared** with in-app capture
   (plan question 3).
4. **The order rule is time if every photo has one, else filename.** A second pick is appended,
   not merged.
5. **Corners, width and height refer to the photo as displayed** (EXIF orientation applied).
   Consumers (#6, #7) must apply EXIF orientation before using raw pixels.
6. **A reorder keeps points; moving corners drops them.** Points sit on the image, not the meter.
7. **Checks flag and never block**, except photos past the tape end, which have no meter to go to.

## Review fixes

A `flutter-reviewer` pass on 2026-11-14 found one HIGH and four MED issues. All are fixed with
regression tests.

- **HIGH, "From Files" opened Photos.** `FileType.image` makes file_picker's iOS side open PHPicker.
  It now uses `FileType.custom` with jpg, jpeg, heic, heif and png.
- **MED, the fisheye flag was lost on re-save.** Only the flag is stored, not the focal length, so a
  re-save re-derived it as false. Saved non-GoPro photos now keep their saved flag
  (`ImportedPhoto.savedFisheyeFlag`).
- **MED, gaps shared one key.** They were `const GapSlot()`, so `ObjectKey` collided once there
  were two gaps. Gaps are now distinct instances.
- **MED, every Save corners wiped scored points.** An identical corners and source save is now a
  no-op. A source-only change keeps the points and cover.
- **MED, edge corners were hard to grab.** Handles were centred on the corner inside a Stack the
  size of the photo, so half the touch target lay outside it. The photo is now inset by half a
  handle inside a larger box.
- **LOW, Save wasn't atomic** on a `no_frame` photo. `updateFrameCorners` now lifts the exclusion
  in the same transaction.
- **LOW, Copy previous used leftover corners** from a `no_frame` photo. It now skips them.
- **LOW, an identical re-save with gaps cleared the cover.** Gaps now count as a change only if
  they moved.

Not changed:

- **Orphan copies after an app kill mid-import.** `_unsaved` is in memory only. These files carry
  the `session<id>_` prefix, so the survey delete sweeps them. The picker's own temp copies sit in
  tmp, which iOS clears.
- **Dispose closing the DB mid-save.** `PopScope` blocks leaving while busy, so no route can be
  removed during a save today.
- **Previous/Next silently drop unsaved drags.** Accepted for now. Worth a confirm if divers
  complain.

## Verification

- `flutter test`: **826 passed**. `flutter analyze`: **no issues** (2026-11-14).
- New suites:
  - `photo_metadata_test.dart` (18);
  - `photo_import_order_test.dart` (16);
  - `photo_import_frames_test.dart` (21);
  - `photo_import_test.dart` (15);
  - `frame_corners_test.dart` (9);
  - `test/screens/photo_import_screen_test.dart` (5).
- `station_screens_test.dart`'s routing test now expects `PhotoImportScreen` for `importedMixed`.
- **Still to check on the iPhone 14:**
  - a GoPro JPEG set through Files (the document picker opens, and the order follows EXIF time);
  - an iPhone HEIC set through Photos (the ImageIO path: size, time and camera filled in);
  - a portrait photo (corners line up after the orientation swap);
  - the Photos permission text;
  - dragging a corner near the screen edge with gloves through the housing, and topside.

## Next

#6, category mapping, point sampling and transect cover. Points go inside `corners_json`, in the
coordinate frame of the photo as displayed.
