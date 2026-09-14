# Sub-plan 3 — Recording isolation + tracking integration

Dev Plan Track 3, §4, §6-7. Wires sub-plan 1's live crop→classify output into sub-plan 2's tracker.
Crop-and-classify itself (§5) now lives in sub-plan 1 — it was moved there because it only needs the
two model weights (already trained and verified), not the tracker; this sub-plan is what actually
needs sub-plan 2 (BoT-SORT port) finished first, since tracker integration is its whole point.

## Steps
1. **Recording/inference isolation** — one continuous video file recorded per transect, independent of
   the inference pipeline, so an inference-side failure doesn't lose footage. Residual risk (a full app
   crash can still lose an unfinalized recording) is accepted, not engineered around further.
2. **Tracker integration** — segmentation boxes (and the per-crop classify output sub-plan 1 already
   produces) feed the Dart BoT-SORT port (sub-plan 2) frame by frame, producing track IDs. No separate
   matching/alignment step: the crop and its class label are already tied to the segmentation box that
   feeds the tracker, nothing to reconcile between two independent detectors.
3. **Per-colony health aggregation** — confidence-weighted average of health classification across all
   frames a colony is tracked in (project-specific design choice, not literature-derived — stated
   explicitly in the Dev Plan; don't present it as more validated than it is in writeups).

## Done when
- A live session produces, per tracked colony: a stable track ID, a mask-derived size, and a
  confidence-weighted health label — from camera frames in, without a separate matching/alignment step
  anywhere in the pipeline.
- Recording keeps working even if inference throws mid-session (test this deliberately, don't just
  assume the isolation holds).
