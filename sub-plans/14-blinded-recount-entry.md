# Sub-plan 14 — Blinded manual recount, entered in the app

Roadmap position: **A4** on the app track (`sub-plans/model-accuracy-roadmap.md`, "App track"). It feeds
`sub-plans/ml-03-cordova-end-to-end-eval.md` steps 4–5 and the Spec's Phase E "post-transect metric
validation".

## Why

Phase E validates the app's survey numbers against a **manual expert recount** of the same transect, using
mean absolute error or percentage-point difference. Today the recount would live on a paper sheet and be
compared by hand. Two open items make the app the right place for it:
- **Spec open item: recount blinding.** "Who does this, and whether they're blinded to the system's output,
  not yet decided." ml-03 step 1 says the counter must not see the app's output first. But Summary opens
  automatically after End Transect (sub-plan 06 step 4), so whoever holds the phone sees the app's numbers
  straight away.
- **The comparison should be recorded with the survey**, not reconstructed later, so the thesis table
  comes straight from data.

## Decisions
1. **Blinding is chosen per transect, at Setup:** "Recount planned — hide the app's results until it's
   entered". When on, Summary shows no counts, prevalence, chart or tally until the recount is entered.
   Live's running tally is also hidden for that transect, because the diver would see it. The detection
   overlay stays, since the diver needs it to aim the camera.
2. **What's recounted:** total colonies and colonies bleached along the tape, as in the ml-03 recount
   sheet. Sizes are left out for now, because a diver's size estimates are too rough to score
   size-frequency against. They can be added later as optional fields.
3. **Write-once, like the exit fix (sub-plan 12).** The recount is entered once and is read-only after
   that. The record says whether it was entered **blind**, meaning before the results were ever shown on
   this phone, so an unblinded recount is still usable but labelled.
4. **Who counted** is recorded as free text (`recount_by`). Deciding *who* should count is the open item,
   and the field team decides it. The app records whichever choice they make.

## Data model (the next schema version after sub-plan 12)
Nullable on `transect_sessions`:
- `results_hidden` (0/1, set at Setup)
- `recount_total`, `recount_bleached` (INT)
- `recount_by` (TEXT)
- `recount_at` (ISO-8601 UTC)
- `recount_blinded` (0/1: entered while results were still hidden)

## Steps
1. **Schema and model**, with a migration test from the previous version.
2. **Setup:** the "Recount planned" switch, which sets `results_hidden`.
3. **Live:** when `results_hidden` is set, the tally HUD shows elapsed time only. The diagnostics overlay
   is also suppressed for that transect, because it lists health labels.
4. **Summary with results hidden:**
   - Only the header and a recount form are shown: total, bleached ≤ total, counted by.
   - Saving writes once with `recount_blinded = true`, then reveals the report.
   - A **"Reveal without recount"** action exists for when no recount will happen. It asks for
     confirmation and makes any later recount `recount_blinded = false`.
5. **Summary with results shown:**
   - An "Add recount" entry, which is unblinded.
   - Once a recount exists, the technical tab shows the comparison:
     - app count vs recount, as an absolute and a percentage error
     - app bleaching prevalence vs recount prevalence, in percentage points
   - It notes that app prevalence is over *classified* colonies (sub-plan 10), while the recount's is
     over all counted colonies.
6. **Export:**
   - The comparison goes into sub-plan 12's `<base>_session.csv`.
   - Surveys gets **"Export recount comparisons"**, one CSV row per recounted session. That's the raw
     table behind the Phase E MAE.
7. **Paper trail.** Close the Spec's blinding open item as "app-enforced per transect; who counts is
   recorded" once the field team agrees. Add a `docs/` explainer.

## Tests
- Model and migration.
- Summary widget tests:
  - hidden mode shows no numbers until the recount is entered
  - a blind recount is stored with `recount_blinded = true` and the report is revealed
  - "Reveal without recount" makes a later recount unblinded
  - comparison numbers are correct for a known case, including prevalence-denominator wording
- Live: the tally is hidden when `results_hidden` is set.
- Export test for the comparisons CSV.

## Done when
- A transect run with "Recount planned" hides every app number on the phone until the recount is entered.
- The comparison shows on Summary and appears in both exports, ready for ml-03 step 5's table.

## Implementation notes (2026-10-02)
Implemented as written, except for the points below. Rationale: `../../docs/blinded-recount-entry.md`.
- **Schema v7**, because sub-plan 12 had already used v6. It adds the six listed columns plus one more,
  **`results_revealed_at`** (ISO-8601 UTC). "Reveal without recount" needs a stored state: without it,
  reopening the survey would hide the results again, and setting `results_hidden` back to 0 would lose
  the fact that a recount was planned. Results are hidden while
  `results_hidden = 1 AND results_revealed_at IS NULL` (`TransectSession.resultsCurrentlyHidden`).
- **`recount_blinded` is computed in SQL**, in `TransectDatabase.recordRecount`'s single write-once
  UPDATE, from the row itself. The UI never passes it in. The same UPDATE reveals a hidden session.
  `revealResults` is write-once too.
- **Four more places that showed results are hidden.** None of them was named in the steps above:
  - Summary's incomplete-session notice (it now says "Incomplete." with no colony count)
  - the End Transect sheet's colony count
  - Home's "N% bleached"
  - the Surveys card's count and bleaching bar
- "Counted by" is required. Summary keeps the previous report on screen while it reloads, so saving a
  recount from the Technical tab doesn't jump back to the Executive tab.
- The session CSV gets 14 recount/app/comparison columns, filled from the colonies Summary passes in.
  The comparisons CSV is `reefsight_recount_comparisons_<UTC time>.csv`.
- Paper trail: a note in sub-plan 07 (the new write-once groups and sync), and a note under the Spec's
  blinding item, which stays **[OPEN]** until the field team decides.
- **Verified:** `dart analyze`: no issues; `flutter test`: 360 passed.
- **Still open:**
  - A device check: run a hidden transect from Setup to Summary, recount, export, and confirm the
    recording has no burned-in overlay.
  - `LiveTransectScreen`'s gating (tally, diagnostics, End sheet) is only covered through the widgets it
    passes values to, not on the screen itself, which can't run headlessly.
