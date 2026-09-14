# Sub-plan 1 — Scaffold + model integration

Dev Plan Track 3, §1-3, §5. Foundation step: nothing downstream can be built or tested without this.
Crop-and-classify (§5) is included here, not in sub-plan 3, because it only needs the two model weights
below — not the BoT-SORT port (sub-plan 2) or a tracker. Both weights are already trained and verified
(`coralvos_primary` coverage-benchmarked; NMFS-OSI classifier scored 92.5% on our leakage-safe test
split), so there's no training uncertainty left to justify deferring the integration test — better to
surface real crop→classify issues (confidence sanity on real coral crops, concurrent two-model compute
cost) this early than to wait on sub-plan 2.

## Steps
1. `flutter create` inside `mobile/` (this repo, not a new one — see `../CLAUDE.md`).
2. Add `ultralytics_yolo` plugin + `camera` package. No `tflite_flutter`, no hand-written inference —
   Spec Phase C settled this.
3. Export Stage B (`coralvos_primary`) and Stage C (verified NMFS-OSI classifier) `.pt` weights to
   whatever format the plugin needs (Core ML per Spec's iPhone 14 target); place under `assets/models/`.
4. Wire `YOLOView` (segmentation, live) per `YOLOInstanceManager`'s concurrent multi-model pattern —
   two models loaded side by side, not sequentially reloaded.
5. **Crop-and-classify (Track 3 §5)** — each segmentation box/mask from `YOLOView` cropped to 224×224,
   run through `YOLOTask.classify`. No matching step: the crop comes directly from the segmentation
   model's own output, so there's nothing to spatially match against a separate detector's boxes.
6. No custom `predict()` loop, no custom preprocessing (Track 3 §3) — confirmed by Track 1 Step 1's
   ablation (raw + augmentation beat preprocessing), so there's nothing to keep consistent between
   training and inference.

## Done when
- App runs on-device, `YOLOView` shows live segmentation overlay from `coralvos_primary`.
- A live segmentation box, cropped to 224×224 and run through `YOLOTask.classify` with the NMFS-OSI
  weights, produces a sane health label — the full crop→classify chain working end to end, not just
  both models loading independently.
- Both models run concurrently without one blocking the other (verify via `YOLOInstanceManager`, not
  by eyeballing frame rate).
- Note: this does NOT require track IDs — tracker integration is sub-plan 3's job, and crop-classify
  here should work fine with no tracker running at all.

## Open risk (Spec, "Open Items")
Compute budget with detection + segmentation + Dart-side tracking (sub-plan 2) all running together
has never been stress-tested on the real target device. Flag early if this step alone is already tight.
