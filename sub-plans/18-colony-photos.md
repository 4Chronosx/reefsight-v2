# Sub-plan 18 — A photo of every colony in the report

Roadmap position: **S3** on the stakeholder track (`sub-plans/model-accuracy-roadmap.md`, "Stakeholder
track"). It works best after sub-plan 11, which checkpoints colony records, so photos survive a crash too.

## Why

LGU readers trust pictures more than counts: "these 6 colonies were bleached", with the 6 photos, is a
finding they can act on and forward. The panel and the field team get a quick visual check without opening
the video (sub-plan 16). The same images are also free labelling material for ML sub-plan 2.

## Problem (verified in code, 2026-10-01)
The app already cuts these images and throws them away. `BleachingClassifier.classifyBatch` decodes each
frame once, cuts a 224×224 crop per colony on an isolate (`_cropAndResizeAllToJpeg`), predicts, and returns
only `ColonyHealth`. The crop bytes are dropped. Nothing about a colony's appearance is stored, except its
mask PNG, which isn't viewable as a photo.

## Decisions
1. **Two images per colony, from its most confident confident sample** (the highest top-1 confidence at or
   above `classifyConfFloor`, sub-plan 10):
   - **context photo**: the box expanded ×1.5, longest side 320 px, JPEG q85. This is what people look at.
   - **classifier crop**: the exact 224×224 input the label came from. Useful for the technical tab and for
     ML sub-plan 2.

   A colony with no confident sample keeps its most confident uncertain sample's images, marked uncertain.
   A colony never classified has no photo.
2. **Cut both in the existing isolate pass.** The frame is already decoded there, so the context crop costs
   only one more `copyCrop`, resize and encode. The batch returns bytes with each result. Only the current
   best per track is kept in memory: about 30 KB per colony, so ~6 MB for 200 colonies.
3. **Written to disk at checkpoint and finalize** (sub-plan 11, and finalize until 11 lands) under
   `colony_photos/`, with relative paths in two new nullable columns. Store paths relative to the documents
   directory, because absolute sandbox paths break on reinstall (the problem `resolveTransectVideo` already
   works around).
4. **Sync (sub-plan 07):** photos join the masks tier. They're small, so they're not capped like video.

## Steps
1. `classifyBatch` returns `List<({ColonyHealth? health, Uint8List? crop, Uint8List? context})>`. The
   isolate job also cuts the context crop. Thread it through `ClassificationScheduler.onResult` and
   `LiveFrameProcessor.onHealth`, keeping the existing result order and null handling.
2. In the screen, a `BestColonyPhoto` tracker per track keeps the images of the highest-confidence sample,
   preferring confident over uncertain.
3. Schema bump (`photo_path`, `photo_crop_path`) plus a migration test, and writes at checkpoint/finalize
   (write a file only when that track's best photo changed since the last write).
4. **Executive tab:** a "Bleached colonies" strip of context photos, tappable to enlarge. If there are none:
   "No bleached colonies found". If prevalence is unreliable (sub-plan 17's small-n rule), label the strip
   "Colonies the app marked bleached".
5. **Technical tab:** a thumbnail on each `_ColonyDetailRow`. Tapping it shows both images side by side,
   plus the label and confidence.
6. **CSV:** `photo_path` and `photo_crop_path` columns. The share sheet offers "Share report with photos",
   zipping the photos folder only if a zip package is already a dependency; otherwise share the files as a
   list.

## Tests
- `BestColonyPhoto`: higher confidence replaces lower, confident beats uncertain, null images are ignored.
- Scheduler and processor still deliver results in order, with the extra bytes passed through, using
  updated fakes.
- Persistence: paths written once per changed best, relative paths resolve after a simulated container
  move.
- Summary widget tests: the bleached strip renders photos, the empty state, and the small-n wording.

## Done when
- After a device transect, Summary shows a photo for every classified colony, and the executive tab shows
  the bleached ones.
- The photos survive reinstall-style path changes and appear in the CSV.

## Implementation notes (2026-10-03)
Built as planned, with these deviations. The reasoning is in `docs/colony-photos-capture-and-storage.md`.
- **Best photo per label, not per colony** (code-review finding). A colony's label is a weighted
  average, so its single most confident sample can carry the other label. Keeping the best of each label
  and storing the one that matches the colony's final label keeps a healthy-looking photo out of
  "Bleached colonies". Files are named `session{S}_track{T}_{label}.jpg`.
- **Four columns, not two** (schema v9): `photo_path`, `photo_crop_path`, plus `photo_label` and
  `photo_confidence`. These record the sample the photo shows. Re-deriving them from `health_history`
  could pick a different sample (a tie, or a sample whose photo failed to encode), so the label shown
  could disagree with the image, and ML sub-plan 2 needs each crop paired with its own label.
- **Result type:** `classifyBatch` returns `List<ClassifiedCrop?>` (a non-null `health` plus optional
  `crop`/`context`) rather than a record with a nullable health. A crop with no label is useless here,
  so an unclassified box is still just `null`.
- **Context box:** each `ClassificationCandidate` also carries `contextBox` (the detection box), because
  its `box` is the classifier crop window (sub-plan 10), not the detection.
- **Memory:** image bytes are held only until written. After that, only each track's rank
  (confident, confidence) is kept.
- **Checkpoint writes:** `SessionCheckpointer.beforeSnapshot` writes changed photos inside the write
  queue, before the snapshot. A failed photo write is counted like any checkpoint failure, and the rows
  are still written. Finalize flushes once more after the live loop is closed.
- **Sharing:** "Share report with photos" is a second button next to "Export & Share CSV", shown only
  when photos exist. It shares the context photos only, as a list (no zip package is a dependency).
- **Staged writes:** both images go to temp files before either is renamed, so a failed write leaves
  the previous photo intact.
- **Executive strip:** bleached colonies without a photo (sessions from before this change) are
  counted under the strip ("N bleached colonies have no photo.").
