# Sub-plan 2 — BoT-SORT Dart port

Dev Plan Track 2, §1-5. Pure Dart algorithm work — testable headlessly (`flutter test`), no device
needed. Can proceed largely in parallel with sub-plan 1 once its detection output shape is known.

## Steps
1. Port `tracker/kalman_filter.py` → Dart. Constant-velocity Kalman filter, motion state only.
2. Port `tracker/matching.py` → Dart. IoU cost matrix + Hungarian assignment. **No appearance/Re-ID
   term** — explicitly excluded (mobile compute budget; pretrained person-Re-ID embeddings don't
   transfer to coral colonies; see Dev Plan Track 2's full rationale, including the honestly-reported
   counter-evidence for schooling-fish tracking that doesn't apply to static, non-overlapping colonies).
3. Port `tracker/bot_sort.py` → Dart. Orchestration: predict → match → update → age/delete → spawn.
4. **Validate against the original Python implementation's recorded outputs on the same test
   sequences** — this is the actual acceptance criterion, not "looks reasonable." No automated
   Python→Dart port-checking tool exists; this has to be a deliberate, project-specific verification
   pass (run the Python reference on fixed sequences, capture outputs, assert the Dart port matches).
5. Camera motion compensation via `opencv_dart` (from BoT-SORT's own `cmc.cpp`) — **only after the
   base tracker (steps 1-4) works**, not alongside it. Don't front-load this.

## Explicitly not building
DeepSORT, appearance embeddings, a Re-ID model, or an independently-designed tracker. If a Dart Kalman
filter/Hungarian-matching reference is useful while porting, `../reefsight`'s `SORTTracker` shows one
working implementation of the general pattern — but it is not BoT-SORT and not what gets shipped;
treat it as orientation, not a source to translate from.

## Done when
- Dart tracker's per-frame track IDs and state transitions (tentative→confirmed→deleted) match the
  Python reference's recorded output on the same fixed test sequences — not just "similar," matching.
- Test suite covers what `../reefsight`'s `sort_tracker_test.dart` already demonstrates is worth
  covering for this class of tracker (lifecycle, assignment correctness, multi-object isolation,
  deletion timeout) — useful as a checklist of cases to test, even though the implementation differs.
